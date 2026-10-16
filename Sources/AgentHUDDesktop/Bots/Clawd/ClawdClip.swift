import CoreGraphics
import Foundation

/// What a Clawd loops through while its mark shows one state, as the director picks it for the mark.
enum ClawdLook: Hashable, Sendable, CaseIterable {
    case thinking
    /// A request failing and being tried again: thinking, held still.
    case retrying
    case edit, command, read, longCommand
    case compacting
    case permission, question, plan

    /// The looks of an agent at work, which hand over to each other prop to prop.
    var isWorking: Bool {
        switch self {
        case .thinking, .retrying, .edit, .command, .read, .longCommand: true
        case .compacting, .permission, .question, .plan: false
        }
    }

    /// The looks of an agent waiting for its person, which cut in at once.
    var isAttention: Bool {
        switch self {
        case .permission, .question, .plan: true
        default: false
        }
    }
}

/// A one-off a Clawd plays over its look, which then resumes.
enum ClawdEvent: Hashable, Sendable, CaseIterable {
    case start, failed, limitHit
}

/// A Clawd that is otherwise its logo showing up for a moment.
enum ClawdVisit: Hashable, Sendable, CaseIterable {
    case swaying, turning, glancing
    /// The visit of an agent asleep.
    case dozing

    /// The visits of an agent that is idle. None of them waves: a raised claw is a question.
    static let idle: [ClawdVisit] = [.swaying, .turning, .glancing]
}

/// What a Clawd on a reminder card plays once.
enum ClawdCard: Hashable, Sendable, CaseIterable {
    case done
    /// A reply after a turn of ten minutes or more.
    case longDone
    /// Usage reset, or credit added.
    case reset
}

/// The signs a Clawd carries over its head, highest first. A sign is drawn over the art, never painted into it.
enum ClawdSign: String, Hashable, Sendable, CaseIterable, Comparable {
    case permission = "!", question = "?", failed = "×", limited = "⧗", asleep = "z"

    /// Only one sign shows at a time: the one that comes first.
    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A shift in sprite pixels, x to the right and y down.
struct ClawdOffset: Hashable, Sendable {
    var x = 0, y = 0
    static let zero = ClawdOffset()

    /// The share `share` of this shift, eased and in whole pixels.
    func eased(_ share: CGFloat) -> ClawdOffset {
        let eased = BotMotion.easeInOut(min(1, max(0, share)))
        return ClawdOffset(x: Int((CGFloat(x) * eased).rounded()), y: Int((CGFloat(y) * eased).rounded()))
    }
}

/// Where a loop may be left for its outro.
enum ClawdExit: Hashable, Sendable {
    /// At the end of a cycle, or at once while its first frame is held.
    case cycleEnd
    /// After the frame showing now.
    case anyFrame
    /// Once this frame of the loop has shown, playing on to it if need be.
    case through(Int)
}

/// How a loop slows down once it has run a while, so that a long wait costs few frames. Times are seconds into the loop.
enum ClawdPace: Hashable, Sendable {
    case steady
    /// After `after`, each cycle is followed by its first frame held for `hold`.
    case resting(after: TimeInterval, hold: TimeInterval)
    /// After `after`, one cycle every `every`, its first frame held in between; after `slowAfter`, one every `slowEvery`.
    case waiting(after: TimeInterval, every: TimeInterval, slowAfter: TimeInterval, slowEvery: TimeInterval)
    /// After `after`, frame `hold` held and the frames `replay` played once every `every`.
    case replaying(after: TimeInterval, hold: Int, replay: ClosedRange<Int>, every: TimeInterval)
}

/// One look's clip, in the game's own frame numbers: how it comes in, the cycle it loops, and how it goes.
struct ClawdClip: Sendable {
    /// What tells two clips apart: two looks with one clip share it, and switching between them restarts nothing.
    let name: String
    let sprite: ClawdSpriteName
    /// From standing to the loop, when the clip comes in from a look that is not working, or from the logo.
    var intro: [ClawdFrame] = []
    /// From another working look's outro to the loop; nil when it is the intro.
    var entry: [ClawdFrame]?
    /// One cycle of the loop, in the clip's own sprite.
    var loop: [Int]
    /// From the loop back to standing.
    var outro: [ClawdFrame] = []
    var exit: ClawdExit = .cycleEnd
    /// Ticks of the 1/12 s grid each frame shows for: 1 at 12 fps, 2 at 6.
    var ticks = 1
    /// Where the clip draws its loop, eased in over the intro and out over the outro, for a prop that would spill too far.
    var offset = ClawdOffset.zero
    /// The sign the clip carries over its intro and its loop.
    var sign: ClawdSign?
    var pace = ClawdPace.steady
    /// A clip of an agent at work, which may carry the mini Clawd of its sub-agents.
    var working = false
    /// Where a working clip stands the still mini Clawd of its agent's sub-agents: its middle this many sprite pixels
    /// right of the body's, on the line the feet stand on. Nil where the clip's prop leaves no room for it.
    var miniShift: Int?

    var loopFrames: [ClawdFrame] { loop.map { ClawdFrame(sprite, $0) } }
}

/// A clip played once: an event, a visit, a greeting or a card.
struct ClawdShot: Sendable {
    struct Step: Hashable, Sendable {
        var frame: ClawdFrame
        var ticks = 1
        var sign: ClawdSign?
        var offset = ClawdOffset.zero
    }

    var steps: [Step]

    /// - sign: carried over the whole shot, or over `signDuring`, a range of `frames`' own numbers in their first sprite.
    /// - hold: a frame shown for that many seconds instead of one tick.
    /// - offset: drawn shifted, eased in over the first `easeIn` frames and out over the last `easeOut`.
    init(_ frames: [ClawdFrame], sign: ClawdSign? = nil, signDuring: ClosedRange<Int>? = nil,
         hold: (frame: ClawdFrame, seconds: TimeInterval)? = nil,
         offset: ClawdOffset = .zero, easeIn: Int = 0, easeOut: Int = 0) {
        let main = frames.first?.sprite
        steps = frames.enumerated().map { at, frame in
            let signed = signDuring.map { frame.sprite == main && $0.contains(frame.index) } ?? true
            var share: CGFloat = 1
            if at < easeIn { share = CGFloat(at) / CGFloat(easeIn) }
            if at >= frames.count - easeOut { share = min(share, CGFloat(frames.count - 1 - at) / CGFloat(max(1, easeOut))) }
            return Step(frame: frame, ticks: hold.map { $0.frame == frame ? ClawdTicks.of($0.seconds) : 1 } ?? 1,
                        sign: signed ? sign : nil, offset: offset.eased(share))
        }
    }
}

/// Clawd's time: every frame starts on the absolute 1/12 s grid, so every Clawd on every display steps together.
enum ClawdTicks {
    static let perSecond = 12
    static func of(_ seconds: TimeInterval) -> Int { max(1, Int((seconds * Double(perSecond)).rounded())) }
}

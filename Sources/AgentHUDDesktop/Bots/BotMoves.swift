import CoreGraphics
import Foundation

/// The moves the looks and events add to a bot, each a curve of time alone, so a bot knows when it next moves without
/// being stepped there. Offsets are shares of the mark's side with y running down, angles are degrees clockwise.
enum BotMoves {
    // MARK: Thinking

    /// Where a thinking bot looks: up, and to one side.
    static let ponderGaze = CGPoint(x: 0.4, y: -0.7)
    /// Degrees a thinking bot tilts toward where it looks.
    static let ponderTilt: CGFloat = 5
    /// Seconds a thinking bot's eyes stay on one side.
    static let ponder: TimeInterval = 2.5

    /// The side a thinking bot looks to at `now` on the shared clock, 1 for the right and −1 for the left. Every thinking
    /// bot looks the same way at once, so they all wake the clock together.
    static func ponderSide(at now: TimeInterval) -> CGFloat {
        Int((now / ponder + 1e-6).rounded(.down)) % 2 == 0 ? 1 : -1
    }

    /// When a thinking bot's eyes next go to the other side.
    static func nextPonder(after now: TimeInterval) -> TimeInterval {
        ((now / ponder + 1e-6).rounded(.down) + 1) * ponder
    }

    // MARK: Tools

    /// One beat of a working body: a bob, a tap, a frame of Clawd's spinner.
    static let beat: TimeInterval = 0.125
    /// A burst of work, then a rest until the cycle ends.
    static let burst: TimeInterval = 3, cycle: TimeInterval = 4.5
    /// Degrees per second a body that spins turns through a burst of work.
    static let busySpin: CGFloat = 14

    /// A burst is under way `time` seconds from the look's first beat.
    static func inBurst(_ time: TimeInterval) -> Bool { max(0, time).truncatingRemainder(dividingBy: cycle) < burst - 1e-6 }

    /// How far down a bot at work with a tool has bobbed, `time` seconds from its look's first beat: 0.04 of the side
    /// on every other beat of a burst, nothing through the rest.
    static func bob(at time: TimeInterval) -> CGFloat {
        guard inBurst(time) else { return 0 }
        return Int(max(0, time) / beat + 1e-6) % 2 == 1 ? 0.04 : 0
    }

    /// When a tool's bob next changes, in seconds from the look's first beat: the next beat through a burst, the next
    /// burst through a rest.
    static func nextBob(after time: TimeInterval) -> TimeInterval {
        let time = max(0, time)
        guard inBurst(time) else { return ((time / cycle + 1e-6).rounded(.down) + 1) * cycle }
        return ((time / beat + 1e-6).rounded(.down) + 1) * beat
    }

    // MARK: Waiting requests

    /// Seconds a wait is acted out in full; after them a bot is still between its moves.
    static let fullWait: TimeInterval = 8
    /// Seconds into a wait its first move comes, once the hop and the raise are over: where its loop begins.
    static let firstMove: TimeInterval = 1.2

    /// One of a waiting request's moves: which one it is, when the latest began, and when the next one begins, in seconds
    /// from the start of the look.
    struct Move: Equatable {
        var index: Int
        var start: TimeInterval?
        var next: TimeInterval
    }

    /// The moves of a waiting request: the first once the hop is over, then one every 2.6 s; once the request has
    /// waited two minutes, one every 8 s.
    static func move(at age: TimeInterval) -> Move {
        let first = firstMove, often = 2.6, rarely = 8.0
        guard age >= first else { return Move(index: -1, start: nil, next: first) }
        // The moves that start before two minutes come often, the rest rarely.
        let frequent = Int(((120 - first) / often).rounded(.up)), late = first + Double(frequent) * often
        // A move's own start counts as in it, however the division rounds.
        if age < late - 1e-9 {
            let index = Int((age - first) / often + 1e-9)
            return Move(index: index, start: first + Double(index) * often, next: first + Double(index + 1) * often)
        }
        let index = Int((age - late) / rarely + 1e-9)
        return Move(index: frequent + index, start: late + Double(index) * rarely, next: late + Double(index + 1) * rarely)
    }

    /// How long one move lasts: a knock for a permission, a tilt to the other side for a question, two nods for a plan.
    static func moveLength(_ look: BotLook) -> TimeInterval {
        switch look {
        case .question: 0.4
        case .plan: 0.6
        default: 0.55
        }
    }

    /// A knock, `time` seconds into it: a wobble that dies away.
    static func knock(_ time: TimeInterval) -> CGFloat {
        guard time >= 0, time < 0.55 else { return 0 }
        let x = CGFloat(time / 0.55)
        return 8 * sin(2 * .pi * 2.5 * x) * (1 - x)
    }

    /// How far a bot with a question tilts its head, `age` seconds into the look: 12° to one side, held, then over to
    /// the other with each move.
    static func questionTilt(at age: TimeInterval) -> CGFloat {
        let move = move(at: age)
        guard let start = move.start else { return 0 }
        let side: CGFloat = move.index % 2 == 0 ? 1 : -1, from = move.index == 0 ? 0 : -12 * side
        let x = CGFloat(min(1, (age - start) / moveLength(.question)))
        return from + (12 * side - from) * BotMotion.easeInOut(x)
    }

    /// How far down a bot nods over a plan, `time` seconds into the move: two small nods.
    static func nod(_ time: TimeInterval) -> CGFloat {
        guard time >= 0, time < moveLength(.plan) else { return 0 }
        let half = time / (moveLength(.plan) / 2)
        return 0.03 * sin(.pi * CGFloat(half - half.rounded(.down)))
    }

    // MARK: Events and greetings

    /// Seconds the hop of a start or a greeting lasts.
    static let hopSeconds: TimeInterval = 0.3

    /// How long an event plays. Pixel art plays its own, in whole steps of its art.
    static func length(of event: BotEvent, limbed: Bool) -> TimeInterval {
        switch event {
        case .start: limbed ? 8 * beat : hopSeconds
        case .failed: 1.5
        case .limitHit: limbed ? 8 * beat : 1.2
        }
    }

    /// A small hop, `time` seconds into it: up 0.06 of the side and down again.
    static func hop(_ time: TimeInterval) -> CGFloat {
        guard time >= 0, time < hopSeconds else { return 0 }
        let x = CGFloat(time / hopSeconds)
        return -0.06 * 4 * x * (1 - x)
    }

    /// How far aside a failed turn shakes the bot: 0.05 of the side, six times a second, dying away in half a second.
    static func shake(_ time: TimeInterval) -> CGFloat {
        guard time >= 0, time < 0.5 else { return 0 }
        return 0.05 * sin(2 * .pi * 6 * CGFloat(time)) * (1 - CGFloat(time / 0.5))
    }

    /// How far a failed turn has sagged the bot, from 0 to 1: after the shake it slumps, stays slumped, and comes back.
    static func sag(_ time: TimeInterval) -> CGFloat {
        switch time {
        case ..<0.5: 0
        case ..<0.75: BotMotion.easeInOut(CGFloat((time - 0.5) / 0.25))
        case ..<1.2: 1
        case ..<1.5: 1 - BotMotion.easeInOut(CGFloat((time - 1.2) / 0.3))
        default: 0
        }
    }

    /// A sigh at a limit, `time` seconds into it: the body stretches up, sinks below itself and comes back, from its feet.
    /// Also how far its eyes are open.
    static func sigh(_ time: TimeInterval) -> (scaleX: CGFloat, scaleY: CGFloat, open: CGFloat) {
        let u = CGFloat(max(0, time) / length(of: .limitHit, limbed: false))
        if u < 0.4 {
            let k = BotMotion.easeInOut(u / 0.4)
            return (1 - 0.04 * k, 1 + 0.07 * k, 1 - 0.7 * k)
        }
        if u < 0.7 {
            let k = BotMotion.easeInOut((u - 0.4) / 0.3)
            return (0.96 + 0.1 * k, 1.07 - 0.15 * k, 0.3 + 0.2 * k)
        }
        let k = BotMotion.easeInOut(min(1, (u - 0.7) / 0.3))
        return (1.06 - 0.06 * k, 0.92 + 0.08 * k, 0.5 + 0.5 * k)
    }
}

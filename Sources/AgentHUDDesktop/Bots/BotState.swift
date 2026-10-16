import AgentHUDCore
import CoreGraphics
import Foundation

/// The looping state a mark shows: what its agents are doing, as far as its bot acts it out. Cases run from the
/// highest to the lowest, the order a mark's sessions are merged in.
enum BotLook: Hashable, Sendable, CaseIterable {
    /// A tool waits for the user's approval.
    case permission
    /// The agent has asked the user a question.
    case question
    /// A plan waits for the user's approval.
    case plan
    /// Claude is compacting its context.
    case compacting
    /// A turn runs and no tool is open: the model is working something out.
    case thinking
    /// A turn runs a tool. Clawd plays a clip for each kind; every other bot has one motion for them all.
    case tool(BotTool)
    /// A turn runs, for a client whose logs carry no tool calls.
    case plain
    /// A session is in flight by evidence older than half an hour: nothing says what it is doing now.
    case noNews
    /// Nothing is in flight: the mark rests as its logo, with a brief bot visit now and then.
    case idle
    /// Every session of the mark has been idle for an hour or more, or it has none: a doze now and then.
    case asleep
    /// A reminder card's good news, a reply or a reset (`BotState.card`): the bot smiles. A dock never shows it.
    case done

    // Built in steps: as one sum of literals and a map, Xcode 16.4's type checker gives up on it.
    static let allCases: [BotLook] = {
        let tools: [BotLook] = BotTool.allCases.map { BotLook.tool($0) }
        let before: [BotLook] = [.permission, .question, .plan, .compacting, .thinking]
        let after: [BotLook] = [.plain, .noNews, .idle, .asleep, .done]
        return before + tools + after
    }()

    /// A request waits on the user.
    var isAttention: Bool { self == .permission || self == .question || self == .plan }

    /// A turn runs.
    var isWorking: Bool {
        switch self {
        case .compacting, .thinking, .tool, .plain: true
        default: false
        }
    }

    /// The mark rests as its logo.
    var isCalm: Bool { self == .noNews || self == .idle || self == .asleep }

    /// The mark stays where its logo is, with no hop and nothing raised.
    var staysInPlace: Bool { isWorking || isCalm }
}

/// The tool a working turn has open, or opened last.
enum BotTool: Hashable, Sendable, CaseIterable {
    case edit, command, read
    /// A shell command open for twenty seconds or more.
    case longCommand
}

/// Something that just happened to a mark's agent, played once over its look, which then carries on.
enum BotEvent: Hashable, Sendable, CaseIterable {
    /// Work begins after a long rest.
    case start
    /// A turn ended in an error.
    case failed
    /// A turn ended on a usage limit.
    case limitHit

    /// An event that waits longer than this to play, because the bot was busy or not yet up, is let go.
    static let freshness: TimeInterval = 3

    /// Of two events, the one to keep: failed over a limit hit over a start.
    var rank: Int {
        switch self {
        case .start: 0
        case .limitHit: 1
        case .failed: 2
        }
    }
}

/// A still sign a mark wears after an event, until its agent moves on. It never animates and needs no clock.
enum BotBadge: Hashable, Sendable {
    /// The agent's last turn failed.
    case failed
    /// The agent is held up by a usage limit.
    case limited
}

/// The good news a reminder card's bot greets. Clawd plays a clip of its own for each; every other bot smiles the same
/// way at all of them.
enum BotCard: Hashable, Sendable, CaseIterable {
    /// A turn ended with a reply.
    case done
    /// A reply to a turn of ten minutes or more.
    case longDone
    /// The usage was reset, or credit was added.
    case reset

    /// A turn at least this long earns the long reply's dance.
    static let longTurn: TimeInterval = 600

    /// The card for a reply to a turn that began at `start` and ended at `end`, as a `SessionCompletion` dates it. A turn
    /// whose start is not known gets the plain one.
    static func reply(from start: Date?, to end: Date) -> BotCard {
        guard let start, end.timeIntervalSince(start) >= longTurn else { return .done }
        return .longDone
    }
}

/// Which way a mark's agent's card stands from the mark, on a dock that keeps its marks beside the card it opens.
enum BotFacing: Hashable, Sendable {
    case left, right, up, down

    /// The card's side for a dock on `edge`: it opens on the dock's inner side.
    init(cardFrom edge: HUDEdge) {
        switch edge {
        case .top: self = .down
        case .bottom: self = .up
        case .left: self = .right
        case .right: self = .left
        }
    }

    /// The way to look, as a gaze `BotMotion.aim(from:to:)` gives: y runs down, and a card beside the mark is near.
    var aim: CGPoint {
        switch self {
        case .left: CGPoint(x: -0.6, y: 0)
        case .right: CGPoint(x: 0.6, y: 0)
        case .up: CGPoint(x: 0, y: -0.6)
        case .down: CGPoint(x: 0, y: 0.6)
        }
    }
}

/// Everything a mark is told about its agents at one moment.
struct BotState: Hashable, Sendable {
    var look: BotLook = .idle
    /// Sub-agents are running for the working session: a small, still copy of the body stands beside it.
    var subagents = false
    var badge: BotBadge? = nil
    /// The pointer rests on the mark, or its card is open. A resting mark, or one with a badge, comes up and greets;
    /// a busy one only turns its eyes to the pointer.
    var hovered = false
    /// The look holds still, with no clock: a turn quiet for three minutes, or a request being retried.
    var holds = false
    /// The news a `.done` look stands for.
    var card = BotCard.done
    /// The card a waiting request asks from stands beside the mark, this way. The bot stays raised and still with its
    /// eyes on the card, which says the rest; Clawd points at a card to its side and stands by one above or below it.
    /// Only a waiting request's look turns to it.
    var facing: BotFacing? = nil

    /// The phase that tells the same story, for callers that still speak in phases.
    var phase: BotPhase {
        if look.isAttention { return .asking }
        if look.isWorking { return .working }
        if look == .done { return .done }
        return hovered ? .opened : .idle
    }

    /// The sign a still logo shows for this state, with bots off or motion reduced: a waiting request's or a badge's,
    /// never one that belongs to a moving bot.
    var stillSign: BotSign? {
        var sign: BotSign?
        switch look {
        case .permission: sign = .exclamation
        case .question: sign = .question
        case .plan: sign = .lines
        default: break
        }
        return BotSign.shown(sign, badge.map(BotSign.init))
    }
}

extension BotState {
    /// A reminder card's state for its good news: `.done`, for `card`.
    init(card: BotCard) {
        self.init(look: .done, card: card)
    }
}

/// One event as a view is told of it: what happened and when, so a mark built again later does not play it twice,
/// and a mark told too late lets it go.
struct BotCue: Hashable, Sendable {
    var event: BotEvent
    var at: Date
}

/// What the agent behind a mark is doing, in the five phases marks were first told: each is now a `BotState`.
enum BotPhase: Sendable, Equatable {
    /// Nothing in flight: the mark rests as its logo, with a brief bot visit now and then.
    case idle
    /// A turn is running: the bot stays awake and acts in place.
    case working
    /// A turn is blocked on the user: the bot hops, stays raised and turns to face them.
    case asking
    /// A turn just ended: the bot smiles.
    case done
    /// The agent's own card is open, from a hover or a click: the bot is up and watches the pointer for as long as
    /// the card stays open.
    case opened

    /// The mark stays where its logo is, with no hop and nothing raised.
    var staysInPlace: Bool { self == .working || self == .idle || self == .opened }

    /// The state this phase stands for: working is the plain working look, asking a permission, opened an idle mark
    /// under the pointer.
    var state: BotState {
        switch self {
        case .idle: BotState()
        case .working: BotState(look: .plain)
        case .asking: BotState(look: .permission)
        case .done: BotState(look: .done)
        case .opened: BotState(look: .idle, hovered: true)
        }
    }
}

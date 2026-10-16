import Foundation

/// How a turn ended, as its client recorded the end: an answer, the user stopping it, an error, or a usage limit. Only a
/// structured end gives one, a reason the client wrote in a field of its own; a turn that went quiet, or ended without
/// saying why, has none, and neither does one still in flight. A stop is never a failure, and a limit is not one either.
public enum TurnOutcome: Hashable, Codable, Sendable {
    /// The agent answered and handed the turn back.
    case completed
    /// The user stopped the turn.
    case interrupted
    /// The turn ended on an error the client reported, such as an overloaded or failing service. A tool's error is part of
    /// a turn's work and never ends it.
    case failed
    /// A usage limit ended the turn. The limit lifts at `resetsAt` when the client said when, else at the session's next
    /// prompt.
    case limited(resetsAt: Date?)

    /// Whether a usage limit ended the turn.
    public var isLimited: Bool { if case .limited = self { true } else { false } }
}

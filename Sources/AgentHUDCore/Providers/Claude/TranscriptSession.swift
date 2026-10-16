import AgentHUDSupport
import Foundation

/// Compact summary of one transcript file; grows incrementally as the file is appended to.
public struct TranscriptSession: Hashable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let cwd: String?
    public let isSubagent: Bool
    public let startedAt: Date
    public let lastActivityAt: Date
    public let task: String?
    public let tokensIn: Int
    public let tokensOut: Int
    public let cacheReadTokens: Int
    public let dominantAgentId: String
    /// Raw model ids seen with their last timestamp, for model discovery.
    public let modelsSeen: [String: Date]
    /// `entrypoint` of the newest line: a transcript resumed from another surface keeps its id but changes client.
    public let entrypoint: String?
    /// Recent explicit turn ends of a main session, newest last; sub-agent transcripts never report any.
    public var completions: [SessionCompletion] = []
    /// True after a prompt or a working assistant, false after `end_turn` or an interruption, nil when never observed.
    public var turn: SessionTurn? = nil
    /// What a main log says its turn is busy with; nil for a sub-agent's log and one with no line of its session yet.
    public var activity: SessionActivity? = nil

    /// Whether this log has its session in flight at `now`, by the transcript rule of `SessionPhase.read(_:rule:at:)`
    /// without sub-agents. The limits are `SessionPhase.Limits`; `threshold` and `abandonedAfter` are not read.
    public func isLive(now: Date, threshold: TimeInterval, abandonedAfter: TimeInterval = UsageRefresh.abandonedTurnTimeout) -> Bool {
        SessionPhase.read(evidence(), rule: .transcript, at: now).inFlight
    }

    /// What this log says about its session, with the newest line of its sub-agents still at work and the client's latest
    /// request for approval.
    func evidence(subagentsAt: Date? = nil, approval: SessionPhase.Approval? = nil) -> SessionPhase.SourceEvidence {
        SessionPhase.SourceEvidence(turn: turn, lastWriteAt: lastActivityAt, subagentsAt: subagentsAt, approval: approval)
    }
}

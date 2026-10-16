import AgentHUDSupport
import Foundation

/// A request for the user waiting in a session, as a bot shows it: what kind of answer it wants and since when.
public struct AttentionRequest: Hashable, Sendable, Identifiable {
    /// What the request wants, in the order a mark shows them: an approval first, then a question, then a plan.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case permission, question, plan

        /// Higher shows first.
        public var rank: Int {
            switch self {
            case .permission: 2
            case .question: 1
            case .plan: 0
            }
        }
    }

    /// The permission request's id, or an id of the session's own for a wait no request on the HUD stands for.
    public let id: String
    public let sessionID: String
    public let kind: Kind
    /// When the client began to wait.
    public let at: Date

    public init(id: String, sessionID: String, kind: Kind, at: Date) {
        self.id = id; self.sessionID = sessionID; self.kind = kind; self.at = at
    }

    /// A request on the HUD: a plan to approve, a question to answer, or a call to allow.
    init(_ request: PermissionRequest) {
        self.init(id: request.id, sessionID: request.sessionID,
                  kind: request.isPlan ? .plan : request.isQuestion ? .question : .permission, at: request.at)
    }

    /// The order a mark takes requests in: the one that has waited longest first, then by id.
    public static func waitedLonger(_ lhs: AttentionRequest, _ rhs: AttentionRequest) -> Bool {
        lhs.at != rhs.at ? lhs.at < rhs.at : lhs.id < rhs.id
    }
}

/// What one session is doing now, as its mark's bot reads it: its phase, what its log says its turn is busy with, how
/// its last turn ended and the requests it waits on. Every time in it is one the session's sources wrote; nothing here
/// waits, holds or picks between sessions, which the mark's director does with its own clock.
public struct SessionLiveFacts: Hashable, Sendable, Identifiable {
    /// What a working session shows itself doing.
    public enum Look: String, Hashable, Sendable, CaseIterable {
        /// No call says what it does: the model is working on its own.
        case thinking
        case command, edit, read
        /// A shell command open for `longCommandAfter` or more.
        case longCommand
        /// A client whose log records no tool calls, so only that it works is known.
        case plain
    }

    public let sessionID: String
    /// The client's vendor, as the logo queue names it (`SessionSource.agentVendor`).
    public let vendor: String?
    /// Running, waiting for approval, idle, or unverified: in flight by evidence too old to vouch for, which shows as no
    /// news rather than work.
    public let phase: SessionPhase
    /// What the session's log says its turn is busy with. Nil for a client whose log records no tool calls.
    public let activity: SessionActivity?
    /// The newest turn, its start (the prompt, or the task its client started) and how it ended.
    public let turnID: String?
    public let turnStartedAt: Date?
    /// Why the newest turn ended, when it ended with a reason, and when it ended.
    public let outcome: TurnOutcome?
    public let endedAt: Date?
    /// When the usage limit that ended the newest turn lifts: the reset its client wrote, else the reset of the vendor's
    /// window that ran out, else when one of its windows began anew after the turn ended. Nil for a limit that lasts
    /// until the next prompt, and when no limit ended the turn.
    public let limitedUntil: Date?
    /// When the session's log last wrote anything; reading it again does not move it.
    public let observedAt: Date
    /// When the session last did something (`ReportView.Session.lastEventAt`).
    public let lastEventAt: Date
    /// The requests the session waits on, waited longest first.
    public let requests: [AttentionRequest]

    /// A shell command shows as a long command once it has been open this long.
    public static let longCommandAfter: TimeInterval = 20

    public init(sessionID: String, vendor: String?, phase: SessionPhase, activity: SessionActivity?, turnID: String?,
                turnStartedAt: Date?, outcome: TurnOutcome?, endedAt: Date?, limitedUntil: Date?, observedAt: Date,
                lastEventAt: Date, requests: [AttentionRequest]) {
        self.sessionID = sessionID; self.vendor = vendor; self.phase = phase; self.activity = activity
        self.turnID = turnID; self.turnStartedAt = turnStartedAt; self.outcome = outcome; self.endedAt = endedAt
        self.limitedUntil = limitedUntil; self.observedAt = observedAt; self.lastEventAt = lastEventAt
        self.requests = requests.sorted(by: AttentionRequest.waitedLonger)
    }

    public var id: String { sessionID }

    /// Whether a turn is in flight: running, or blocked on the user.
    public var isInFlight: Bool { phase.isInFlight }

    /// Whether the session was in flight when last read, too long ago to show as work.
    public var isUnverified: Bool { phase.state == .unverified }

    /// Whether the client's log records each tool call, so the session can show what it does; the others show plain work.
    public var reportsTools: Bool { activity != nil }

    /// What the session shows itself doing while it works, at `now`: the kind of the call still open, a shell command
    /// open `longCommandAfter` turning long, else the kind its calls kept, else thinking. A client that records no calls
    /// shows plain work. Turning a kept kind into thinking after a quiet while is the director's to decide.
    public func look(at now: Date) -> Look {
        guard let activity else { return .plain }
        if let open = activity.openCall, open.work == .shell, now.timeIntervalSince(open.at) >= Self.longCommandAfter {
            return .longCommand
        }
        switch activity.openCall?.work ?? activity.work {
        case .shell, .command: return .command
        case .edit: return .edit
        case .read: return .read
        case .agents, .question, nil: return .thinking
        }
    }

    /// Whether a call is still out with its tool, one that shows as no kind included.
    public var hasOpenCall: Bool { activity?.hasOpenCall ?? false }

    /// When the newest call was last seen: when it was made, or when its result came back if that is later.
    public var toolSeenAt: Date? { activity?.toolAt }

    /// Whether the session's sub-agents are at work, which the mark shows beside its look.
    public var subagents: Bool { activity?.delegating ?? false }

    /// Whether the conversation's newest line leaves the model to go on (`SessionActivity.awaitsModel`).
    public var awaitsModel: Bool { activity?.awaitsModel ?? true }

    /// Whether the client says it is trying a failed API request again.
    public var retrying: Bool { activity?.retrying ?? false }

    /// Whether the client is compacting the conversation at `now`: it said it began after the log's last line, at most
    /// `CompactionHooks.limit` ago.
    public func compacting(at now: Date) -> Bool {
        guard let since = activity?.compactingSince else { return false }
        return now.timeIntervalSince(since) < CompactionHooks.limit
    }

    /// Whether a usage limit ended the newest turn and has not lifted at `now`.
    public func limited(at now: Date) -> Bool {
        guard outcome?.isLimited == true else { return false }
        return limitedUntil.map { now < $0 } ?? true
    }

    /// Whether the newest turn failed.
    public var failed: Bool { outcome == .failed }

    /// When one of these facts changes at a time after `now` without anything new being read: an open shell command
    /// turning long, a compaction running out, a limit lifting. Nil when none will.
    public func nextChange(after now: Date) -> Date? {
        var times: [Date] = []
        if let open = activity?.openCall, open.work == .shell { times.append(open.at.addingTimeInterval(Self.longCommandAfter)) }
        if let since = activity?.compactingSince { times.append(since.addingTimeInterval(CompactionHooks.limit)) }
        if outcome?.isLimited == true, let limitedUntil { times.append(limitedUntil) }
        return times.filter { $0 > now }.min()
    }
}

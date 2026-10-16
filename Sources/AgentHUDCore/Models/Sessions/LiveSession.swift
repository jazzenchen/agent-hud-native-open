import Foundation

/// A coding-agent session read from local logs (running or recently finished).
public struct LiveSession: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let agentId: String
    public let task: String
    public let terminal: String?
    public let startedAt: Date
    public let endedAt: Date?
    /// The newest evidence of what the session is doing that its provider holds (`SessionPhase.SourceEvidence.newest`):
    /// its turn's latest observation, its log's last record, its sub-agents' newest line, its client's request for
    /// approval, or a process check that has its turn in flight. Reading the source again without new evidence does not
    /// move it, so a session whose source did not move reads the same from one pass to the next.
    public let observedAt: Date
    /// Share of the current quota window consumed by this session, in %.
    public let pctOfWindow: Double?
    public let tokensIn: Int
    public let tokensOut: Int
    public let cacheReadTokens: Int
    public let client: String?
    public let transcriptPath: String?
    /// The canonical ledger contribution when another provider meters this session; nil uses its transcript and id.
    public let usageKey: String?
    public let accountWide: Bool
    /// The directory the session works in; `terminal` names its last component.
    public let workingDirectory: String?
    /// Logs of the sub-agents this session started that do not lie under its own log's directory, such as Codex's.
    public let subagentTranscripts: [String]?
    /// The readable name assigned to a spawned agent by its source.
    public let agentName: String?
    /// The agents this session directly started, each with its own descendants.
    public let subagentSessions: [LiveSession]?
    /// When the session's source last recorded anything for it, a log's last line or newest event, where the provider
    /// reads that. Like `observedAt`, reading the log again does not move it.
    public let lastActivityAt: Date?
    /// Source-owned destination for returning to this session on this Mac; never encoded in a session report.
    public let navigationTarget: SessionNavigationTarget?
    /// What the session's log says its turn is busy with, from the clients whose logs record each tool call; nil for every
    /// other client. It changes with every call, so it stays on this Mac and is never encoded in a session report.
    public let activity: SessionActivity?

    public init(
        id: String,
        agentId: String,
        task: String,
        terminal: String?,
        startedAt: Date,
        endedAt: Date? = nil,
        pctOfWindow: Double?,
        tokensIn: Int,
        tokensOut: Int,
        client: String? = nil,
        transcriptPath: String? = nil,
        cacheReadTokens: Int = 0,
        accountWide: Bool = false,
        observedAt: Date? = nil,
        workingDirectory: String? = nil,
        subagentTranscripts: [String]? = nil,
        agentName: String? = nil,
        subagentSessions: [LiveSession]? = nil,
        lastActivityAt: Date? = nil,
        navigationTarget: SessionNavigationTarget? = nil,
        usageKey: String? = nil,
        activity: SessionActivity? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.task = task
        self.terminal = terminal
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.observedAt = observedAt ?? endedAt ?? startedAt
        self.pctOfWindow = pctOfWindow
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheReadTokens = cacheReadTokens
        self.client = client
        self.transcriptPath = transcriptPath
        self.usageKey = usageKey
        self.accountWide = accountWide
        self.workingDirectory = workingDirectory
        self.subagentTranscripts = subagentTranscripts.flatMap { $0.isEmpty ? nil : $0 }
        self.agentName = agentName
        self.subagentSessions = subagentSessions.flatMap { $0.isEmpty ? nil : $0 }
        self.lastActivityAt = lastActivityAt
        self.navigationTarget = navigationTarget
        self.activity = activity
    }

    /// Whether the source that read this session said a turn was still in flight. The log's own silence does not end
    /// it: an agent can spend minutes in one tool call.
    public var isLive: Bool { endedAt == nil }

    /// An internal Bot child known only through its billing contribution, without native conversation metadata.
    public var isBillingOnlyGrokBotSubagent: Bool { GrokBotUsage.isBillingOnlySubagent(self) }

    /// Running, as far as this Mac can still vouch for it: for `SessionPhase.Limits.vouched` after the newest evidence
    /// that has it in flight. Evidence older than a turn may stay quiet — a retained result, a Mac that stopped
    /// collecting — no longer speaks for the session.
    public func isLive(at now: Date) -> Bool {
        isLive && now.timeIntervalSince(observedAt) < SessionPhase.Limits.vouched
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentId, task, terminal, startedAt, endedAt, observedAt, pctOfWindow, tokensIn, tokensOut, client, transcriptPath, cacheReadTokens, accountWide
        case workingDirectory, subagentTranscripts, agentName, subagentSessions, lastActivityAt, usageKey
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), agentId: try c.decode(String.self, forKey: .agentId),
            task: try c.decode(String.self, forKey: .task), terminal: try c.decodeIfPresent(String.self, forKey: .terminal),
            startedAt: try c.decode(Date.self, forKey: .startedAt), endedAt: try c.decodeIfPresent(Date.self, forKey: .endedAt),
            pctOfWindow: try c.decodeIfPresent(Double.self, forKey: .pctOfWindow), tokensIn: try c.decode(Int.self, forKey: .tokensIn),
            tokensOut: try c.decode(Int.self, forKey: .tokensOut), client: try c.decodeIfPresent(String.self, forKey: .client),
            transcriptPath: try c.decodeIfPresent(String.self, forKey: .transcriptPath),
            cacheReadTokens: try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0,
            accountWide: try c.decodeIfPresent(Bool.self, forKey: .accountWide) ?? false,
            observedAt: try c.decodeIfPresent(Date.self, forKey: .observedAt),
            workingDirectory: try c.decodeIfPresent(String.self, forKey: .workingDirectory),
            subagentTranscripts: try c.decodeIfPresent([String].self, forKey: .subagentTranscripts),
            agentName: try c.decodeIfPresent(String.self, forKey: .agentName),
            subagentSessions: try c.decodeIfPresent([LiveSession].self, forKey: .subagentSessions),
            lastActivityAt: try c.decodeIfPresent(Date.self, forKey: .lastActivityAt),
            usageKey: try c.decodeIfPresent(String.self, forKey: .usageKey))
    }

    /// Every descendant, in the order of the tree; the top-level session list keeps only the roots.
    public var descendantSessions: [LiveSession] {
        (subagentSessions ?? []).flatMap { [$0] + $0.descendantSessions }
    }

    /// The working directory with the home folder written as `~`, or the project's name where only that is known.
    public var displayPath: String? {
        guard let workingDirectory else { return terminal }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory == home { return "~" }
        return workingDirectory.hasPrefix(home + "/") ? "~" + workingDirectory.dropFirst(home.count) : workingDirectory
    }

    /// When this session last did something, given the newest turn event its source reported for it. A source that
    /// reports no turns leaves the session's own end, or — while it runs — when its log last recorded anything, else the
    /// newest evidence that it runs.
    public func lastEvent(turnAt: Date?) -> Date {
        guard let turnAt else { return endedAt ?? lastActivityAt ?? observedAt }
        return max(turnAt, endedAt ?? startedAt)
    }

    public func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

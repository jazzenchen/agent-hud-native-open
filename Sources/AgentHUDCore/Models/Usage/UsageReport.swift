import Foundation

/// Metrics of one quota window, derived from its stored readings: burn rate, forecast and this week's cap hits.
public struct UsageInsights: Hashable, Codable, Sendable {
    public let burnRatePctPerHour: Double?
    /// Seconds until this quota window is exhausted at its recent burn rate.
    public let timeToExhaust: TimeInterval?
    /// How far the readings have come while they are too few for a burn rate; nil once there is one. Optional so
    /// reports written before sampling details were introduced still decode.
    public let sampling: QuotaSampling?
    public let capacityObservation: QuotaObservation?
    /// Matched event timestamps, rather than quarter-hour buckets, supplied by the combined ledger reader.
    public var exactCapacityEstimate: QuotaCapacityEstimate?
    public let weeklyCapHits: Int
    public let weeklyWaitTotal: TimeInterval
    public let weeklyWaitLongest: TimeInterval
    public let weeklyWaitLongestAt: Date?

    public init(
        burnRatePctPerHour: Double?,
        timeToExhaust: TimeInterval?,
        weeklyCapHits: Int,
        weeklyWaitTotal: TimeInterval,
        weeklyWaitLongest: TimeInterval,
        weeklyWaitLongestAt: Date?,
        sampling: QuotaSampling? = nil,
        capacityObservation: QuotaObservation? = nil,
        exactCapacityEstimate: QuotaCapacityEstimate? = nil
    ) {
        self.burnRatePctPerHour = burnRatePctPerHour
        self.timeToExhaust = timeToExhaust
        self.sampling = sampling
        self.capacityObservation = capacityObservation
        self.exactCapacityEstimate = exactCapacityEstimate
        self.weeklyCapHits = weeklyCapHits
        self.weeklyWaitTotal = weeklyWaitTotal
        self.weeklyWaitLongest = weeklyWaitLongest
        self.weeklyWaitLongestAt = weeklyWaitLongestAt
    }
}

/// Background indexing of local logs: how many sessions are ready out of the total to scan.
public struct IndexProgress: Hashable, Codable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var label: String { L10n.text("索引中 \(done)/\(total)", "Indexing \(done)/\(total)") }
}

/// Everything one poll returns.
public struct UsageReport: Hashable, Codable, Sendable {
    public let generatedAt: Date
    public let snapshots: [UsageSnapshot]
    public let sessions: [LiveSession]
    /// Explicit local turn completions, kept separate from archived/inactive sessions.
    public let completions: [SessionCompletion]
    /// Explicit current/recent turn observations; archived session activity is not a substitute.
    public let turns: [SessionTurn]
    /// Short note for the UI when quota data is missing or degraded ("等待 Claude Code 上报额度").
    public let notice: String?
    /// Agent rows the provider found in local data (e.g. Claude model families); the settings store merges them.
    public let discoveredAgents: [AgentDescriptor]
    /// Things that spend tokens (model families), as opposed to quota windows. Sessions and token charts key on these.
    public let consumers: [AgentDescriptor]
    /// Token totals in 15-minute periods, ordered by start, after overlapping logs were resolved. Charts sum these periods.
    public let usage: [UsageBucket]
    /// Non-nil while local logs are still being indexed; sessions and token figures are partial until then.
    public let indexing: IndexProgress?
    /// Per-window metrics; a Codex window must never display Claude's burn rate.
    public let insightsByAgent: [String: UsageInsights]
    public let subscriptions: [String: String]
    /// Optional so previously saved reports remain readable.
    public let services: [AgentService]?
    /// Authoritative pool inventory for each reporting provider. An empty set means no usable credentials.
    /// Nil keeps older cached reports decodable; it does not assert that their credentials are still valid.
    public let activeQuotaPoolIDs: [String: Set<String>]?
    /// Account inventory by provider name. A present key is that provider's authoritative list, an empty list included.
    /// Nil keeps older cached reports decodable.
    public let accounts: [String: [AccountObservation]]?
    /// Providers whose accounts must be forgotten now, for example after the user withdrew consent to read them.
    /// Their readings, rows and settings retire even when the provider did not report an account inventory.
    public let forgottenAccountProviders: Set<String>?
    /// Notices by vendor, or by `ClientHome.sourceKey` for a login whose account this run could not yet identify.
    public let sourceNotices: [String: String]
    /// The part of `sourceNotices` about readings, by vendor or client home: a quota or balance read that failed or could not be verified.
    /// Notices about local logs and hooks are only in `sourceNotices`. Nil when a report does not tell them apart, so that
    /// all of its source notices count. Written beside `readingIssues` for readers of the notice text.
    public let quotaNotices: [String: String]?
    /// What each vendor's provider said about its readings, by vendor or client home: a quota or balance read that failed or could not be verified,
    /// which holds back that vendor's alerts, status levels and retained sessions. A billing pool's rows answer to their own
    /// account's issue instead. Nil in a report that does not type its issues, whose `quotaNotices` then count as failed
    /// reads.
    public let readingIssues: [String: ReadingIssue]?
    /// Consumer ids covered by each quota row. Providers own the relationship between model and quota ids.
    public let consumerIdsByQuota: [String: Set<String>]
    public let billing: [APIBilling]
    /// One account-wide balance, shared by all Codex quota windows.
    public let codexResetCredits: CodexResetCredits?
    /// Time of the successful account/rateLimits/read, including responses without quota windows.
    public let codexResetCreditsObservedAt: Date?
    /// Where each session's tokens went, by session id. Optional so previously saved reports remain readable.
    public let sessionUsage: [String: SessionUsage]?
    /// Each window's models' recent reply speed, from the ledger's call events (`ReportView.replyRate(for:)`).
    public let replyRates: [String: QuotaReplyRate]?
    /// WorkBuddy's own metering of each session: credits, their attribution, and its context size; other sources meter
    /// nothing of their own.
    public let sessionCredits: [String: SessionCredits]?
    /// Every model's tokens today and over the last seven and thirty days; `usage` covers only the charts' week.
    public let periods: UsagePeriods?
    /// Prompt tokens calls sent again because the cache no longer held them, in `usage`'s periods, by model: cache writes
    /// where the call wrote to the cache, input otherwise (`UsageLedger.recachedBuckets(since:)`). It covers every
    /// session's calls, listed or not. Nil in a report that does not read them.
    public let recached: [UsageBucket]?
    /// When a provider last reported each row of `discoveredAgents`, in reports kept across passes; a single read and the
    /// demo have none. Rows it does not list are not shown, and a row unseen for the retention period leaves the report.
    public let rowSeenAt: [String: Date]?

    public init(
        generatedAt: Date,
        snapshots: [UsageSnapshot],
        sessions: [LiveSession],
        notice: String? = nil,
        discoveredAgents: [AgentDescriptor] = [],
        consumers: [AgentDescriptor]? = nil,
        usage: [UsageBucket] = [],
        indexing: IndexProgress? = nil,
        insightsByAgent: [String: UsageInsights] = [:],
        subscriptions: [String: String] = [:],
        sourceNotices: [String: String] = [:],
        quotaNotices: [String: String]? = nil,
        readingIssues: [String: ReadingIssue]? = nil,
        consumerIdsByQuota: [String: Set<String>] = [:],
        billing: [APIBilling] = [],
        codexResetCredits: CodexResetCredits? = nil,
        codexResetCreditsObservedAt: Date? = nil,
        completions: [SessionCompletion] = [],
        turns: [SessionTurn] = [],
        services: [AgentService]? = nil,
        activeQuotaPoolIDs: [String: Set<String>]? = nil,
        accounts: [String: [AccountObservation]]? = nil,
        forgottenAccountProviders: Set<String>? = nil,
        sessionUsage: [String: SessionUsage]? = nil, replyRates: [String: QuotaReplyRate]? = nil,
        sessionCredits: [String: SessionCredits]? = nil,
        periods: UsagePeriods? = nil,
        recached: [UsageBucket]? = nil,
        rowSeenAt: [String: Date]? = nil
    ) {
        self.sessionUsage = sessionUsage
        self.replyRates = replyRates
        self.sessionCredits = sessionCredits
        self.periods = periods
        self.recached = recached
        self.rowSeenAt = rowSeenAt
        self.accounts = accounts
        self.forgottenAccountProviders = forgottenAccountProviders
        self.services = services
        self.activeQuotaPoolIDs = activeQuotaPoolIDs
        self.completions = completions
        self.turns = turns
        self.codexResetCredits = codexResetCredits
        self.codexResetCreditsObservedAt = codexResetCreditsObservedAt
        self.billing = billing
        self.insightsByAgent = insightsByAgent
        self.subscriptions = subscriptions
        self.sourceNotices = sourceNotices
        self.quotaNotices = quotaNotices
        self.readingIssues = readingIssues
        self.consumerIdsByQuota = consumerIdsByQuota
        self.indexing = indexing
        self.generatedAt = generatedAt
        self.snapshots = snapshots
        self.sessions = sessions
        self.notice = notice
        self.discoveredAgents = discoveredAgents
        self.consumers = consumers ?? discoveredAgents
        self.usage = usage
    }

    public func snapshot(for agentId: String) -> UsageSnapshot? {
        snapshots.first { $0.agentId == agentId }
    }
}

import AgentHUDSupport
import Foundation

/// Providers that write their token events to the usage ledger themselves.
protocol LedgerRecording {}

/// Joins independent vendors, reading them one after another into one ledger pass. A missing or signed-out source
/// does not suppress another vendor's data, and a failing source keeps the usage it recorded before.
public struct CombinedUsageProvider: UsageProvider {
    public struct Source: Sendable {
        public let vendor: String
        public let provider: any UsageProvider
        public init(_ vendor: String, _ provider: any UsageProvider) { self.vendor = vendor; self.provider = provider }
    }
    /// The last result of every vendor, reused while its signals stay quiet.
    actor Results {
        struct Entry {
            let result: Result<UsageReport, UsageProviderError>
            let agents: [AgentDescriptor]
            let historyHours: Int
        }
        private var entries: [String: Entry] = [:]
        func entry(_ vendor: String) -> Entry? { entries[vendor] }
        func store(_ entry: Entry, for vendor: String) { entries[vendor] = entry }
        func reports() -> [String: UsageReport] { entries.compactMapValues { try? $0.result.get() } }

        /// Each session's breakdown with the counts it was read at, valid while the ledger keeps the writes it was read from.
        struct Breakdown: Sendable {
            let counts: [Int]
            let request: SessionUsageRequest
            let usage: SessionUsage?
        }
        private var breakdowns: [String: Breakdown] = [:]
        private var breakdownGeneration: Int?
        private var breakdownPriceRevision: String?
        /// The ledger's write mark when the breakdowns were read.
        private var breakdownMark = 0
        func breakdowns(generation: Int, priceRevision: String) -> (values: [String: Breakdown], mark: Int) {
            if breakdownGeneration != generation || breakdownPriceRevision != priceRevision {
                breakdowns = [:]; breakdownGeneration = generation; breakdownPriceRevision = priceRevision; breakdownMark = 0
            }
            return (breakdowns, breakdownMark)
        }
        func storeBreakdowns(_ values: [String: Breakdown], mark: Int, generation: Int, priceRevision: String) {
            guard breakdownGeneration == generation, breakdownPriceRevision == priceRevision else { return }
            breakdowns = values; breakdownMark = mark
        }
    }

    private let vendors: [Source]
    private let ledger: UsageLedger
    private let results = Results()
    /// The bot behind each Grok Bot routine run, which Cursor's account step keeps current.
    private let grokBotRoutineRuns: GrokBotRoutineRuns?
    public init(_ sources: [Source], ledger: UsageLedger = .inMemory()) {
        self.init(sources, ledger: ledger, grokBotRoutineRuns: nil)
    }

    init(_ sources: [Source], ledger: UsageLedger, grokBotRoutineRuns: GrokBotRoutineRuns?) {
        vendors = sources
        self.ledger = ledger
        self.grokBotRoutineRuns = grokBotRoutineRuns
    }

    /// - settings: the store the app collects with; GitHub Copilot's quota is read only while it holds the user's consent,
    ///   asked each time a reading is due.
    /// - persistent: false leaves the data directory as it is, for a read-only probe: no earlier version's file is
    ///   removed or imported and no account identity is remembered; pass a ledger in memory as well.
    public static func standard(settings: SettingsStore, ledger: UsageLedger = .open(), persistent: Bool = true) -> CombinedUsageProvider {
        if persistent { removeLegacyCaches(in: AppSupport.directory) }
        let routineRuns = GrokBotRoutineRuns(fileURL: persistent ? AppSupport.directory.appendingPathComponent("grok-bot-routine-runs.json") : nil)
        return CombinedUsageProvider([
            Source("Claude", ClaudeCodeProvider.standard(ledger: ledger, persistent: persistent)),
            Source("Codex", CodexUsageProvider.standard(ledger: ledger, persistent: persistent)),
            Source("DeepSeek", DeepSeekUsageProvider.standard(ledger: ledger)),
        ] + AdditionalSource.allCases.map {
            Source($0.vendor, AdditionalUsageProvider.standard($0, settings: settings, ledger: ledger, persistHistory: persistent,
                                                               grokBotRoutineRuns: $0 == .cursor ? routineRuns : nil))
        } + [Source("Open agents", OpenAgentUsageProvider.standard(ledger: ledger, persistHistory: persistent))],
            ledger: ledger, grokBotRoutineRuns: routineRuns)
    }

    public func refreshAccountUsage(historyHours: Int) async {
        for step in accountRefreshSteps { await step(historyHours) }
    }

    public var accountRefreshSteps: [AccountRefreshStep] { vendors.flatMap(\.provider.accountRefreshSteps) }

    public var watchedDirectories: [URL]? {
        var directories: [URL] = []
        for source in vendors {
            guard let watched = source.provider.watchedDirectories else { return nil }
            directories += watched
        }
        return directories
    }

    /// One source per vendor, so a change under one client's directories reads only that client.
    public var sources: [UsageSource] {
        vendors.map { UsageSource(name: $0.vendor, directories: $0.provider.watchedDirectories, accountSteps: $0.provider.accountRefreshSteps) }
    }

    public func fileChanges(_ paths: Set<String>?) async {
        for source in vendors { await source.provider.fileChanges(paths) }
    }

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        try await fetchUsage(agents: agents, historyHours: historyHours, sources: nil)
    }

    /// Vendors outside `names` keep their last result, unless they have none yet or it was read for other agents or hours.
    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int, sources names: Set<String>?) async throws -> UsageReport {
        await ledger.beginPass()
        var results: [(Int, UsageReport?, String?)] = []
        for (index, source) in vendors.enumerated() {
            let previous = await self.results.entry(source.vendor)
            let result: Result<UsageReport, UsageProviderError>
            if let previous, names.map({ !$0.contains(source.vendor) }) ?? false,
               previous.agents == agents, previous.historyHours == historyHours {
                result = previous.result
            } else {
                do { result = .success(try await source.provider.fetchUsage(agents: agents, historyHours: historyHours)) }
                catch { result = .failure(UsageProviderError(error.localizedDescription)) }
                await self.results.store(.init(result: result, agents: agents, historyHours: historyHours), for: source.vendor)
            }
            switch result {
            case .success(let report): results.append((index, report, nil))
            case .failure(let error): results.append((index, nil, error.message))
            }
        }
        await ledger.commitPass()
        let reports = results.compactMap { $0.1 }
        var notices: [String: String] = [:], quotaNotices: [String: String] = [:], issues: [String: ReadingIssue] = [:]
        for (index, report, error) in results {
            if let report {
                // Two sources can write one group's notice: a GLM plan only WorkBuddy carries files its read error there.
                notices.merge(report.sourceNotices, uniquingKeysWith: { old, new in old == new ? new : old + " · " + new })
                quotaNotices.merge(report.quotaNotices ?? report.sourceNotices, uniquingKeysWith: { _, new in new })
                issues.merge(report.typedReadingIssues, uniquingKeysWith: { _, new in new })
            }
            // An unclassified notice is a failed source. Explicitly classified account failures keep their scope.
            if let message = error ?? (report?.sourceNotices.isEmpty == true && report?.readingIssues == nil
                && report?.quotaNotices == nil ? report?.notice : nil) {
                notices[vendors[index].vendor] = message
                quotaNotices[vendors[index].vendor] = message
                issues[vendors[index].vendor] = .readFailed(message)
            }
        }
        guard !reports.isEmpty else { throw UsageProviderError(notices.keys.sorted().map { "\($0): \(notices[$0]!)" }.joined(separator: " · ")) }
        let now = reports.map(\.generatedAt).max() ?? Date()
        // The ledger holds every recorded source, including one whose refresh just failed; other providers report periods
        // themselves. The report carries all the ledger keeps, for the month the charts can show; providers still read
        // `historyHours` of their own logs.
        let reported = results.filter { !(vendors[$0.0].provider is any LedgerRecording) }.flatMap { $0.1?.usage ?? [] }
        let since = min(now.addingTimeInterval(-UsageLedger.retention), now.addingTimeInterval(-Double(historyHours) * 3600))
        let usage = ((try? await ledger.buckets(since: since)) ?? []) + reported
        // What calls sent again after the cache lapsed comes from the ledger too, so a range's figure covers its month of
        // sessions, not only those a report lists.
        let recached = try? await ledger.recachedBuckets(since: since)
        var periods = (try? await ledger.periods(endingAt: now)) ?? UsagePeriods()
        periods.add(reported, endingAt: now)
        let sessions = GrokBotUsage.merge(reports.flatMap(\.sessions), routineRuns: await grokBotRoutineRuns?.links ?? [:],
                                          listedSince: SessionWindow.start(at: now))
        let progress = reports.compactMap(\.indexing)
        let sessionUsage = await breakdowns(of: sessions)
        let consumerIdsByQuota = reports.reduce(into: [String: Set<String>]()) {
            $0.merge($1.consumerIdsByQuota, uniquingKeysWith: { $0.union($1) })
        }
        let replyRates = await replyRates(of: consumerIdsByQuota, reports: reports, now: now)
        return UsageReport(generatedAt: now, snapshots: Dictionary(grouping: reports.flatMap(\.snapshots), by: \.agentId).values.compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.agentId < $1.agentId },
                           sessions: sessions.sorted { a, b in
                               if a.isLive != b.isLive { return a.isLive }
                               return (a.endedAt ?? a.startedAt) > (b.endedAt ?? b.startedAt)
                           },
                           notice: notices.isEmpty ? nil : notices.keys.sorted().map { "\($0): \(notices[$0]!)" }.joined(separator: " · "),
                           discoveredAgents: UsageAggregation.consumersUnion(reports.map(\.discoveredAgents)), consumers: UsageAggregation.consumersUnion(reports.map(\.consumers)),
                           usage: usage.sorted { ($0.start, $0.account ?? "", $0.agentId) < ($1.start, $1.account ?? "", $1.agentId) },
                           indexing: progress.isEmpty ? nil : IndexProgress(done: progress.reduce(0) { $0 + $1.done }, total: progress.reduce(0) { $0 + $1.total }),
                           insightsByAgent: reports.reduce(into: [:]) { $0.merge($1.insightsByAgent, uniquingKeysWith: { _, new in new }) },
                           subscriptions: reports.reduce(into: [:]) { $0.merge($1.subscriptions, uniquingKeysWith: { _, new in new }) }, sourceNotices: notices,
                           quotaNotices: quotaNotices, readingIssues: issues,
                           consumerIdsByQuota: consumerIdsByQuota,
                           billing: Self.mergeBilling(reports.flatMap(\.billing)), codexResetCredits: reports.first { $0.codexResetCredits != nil }?.codexResetCredits,
                           codexResetCreditsObservedAt: reports.first { $0.codexResetCredits != nil }?.codexResetCreditsObservedAt,
                           completions: reports.flatMap(\.completions),
                           turns: reports.flatMap(\.turns), services: AgentService.merge(reports.map { $0.services ?? [] }),
                           activeQuotaPoolIDs: reports.compactMap(\.activeQuotaPoolIDs).reduce(into: [String: Set<String>]()) {
                               $0.merge($1, uniquingKeysWith: { $0.union($1) })
                           },
                           accounts: reports.compactMap(\.accounts).reduce(into: [String: [AccountObservation]]()) {
                               $0.merge($1, uniquingKeysWith: +)
                           },
                           forgottenAccountProviders: reports.compactMap(\.forgottenAccountProviders).reduce(nil) { ($0 ?? []).union($1) },
                           sessionUsage: sessionUsage, replyRates: replyRates,
                           sessionCredits: reports.compactMap(\.sessionCredits).reduce(into: [String: SessionCredits]()) { $0.merge($1) { _, new in new } },
                           periods: periods, recached: recached)
    }

    /// Where each session's tokens went. A session is read again when its counts move or when the ledger has written any
    /// log it is made of since its breakdown was read: sub-agents spend without the session's own log changing, and a
    /// source can record a session's events a pass or more after first reporting it.
    private func breakdowns(of roots: [LiveSession]) async -> [String: SessionUsage] {
        let sessions = roots.flatMap { [$0] + $0.descendantSessions }
        let generation = await ledger.generation, priceRevision = ModelPriceFeed.sourceInfo.revision
        let (known, mark) = await results.breakdowns(generation: generation, priceRevision: priceRevision)
        let changed = await ledger.changedKeys(after: mark), now = await ledger.writeMark
        var kept: [String: Results.Breakdown] = [:], requests: [SessionUsageRequest] = []
        for session in sessions {
            let counts = [session.tokensIn, session.tokensOut, session.cacheReadTokens], request = SessionUsageRequest(session)
            if let breakdown = known[session.id], breakdown.counts == counts, breakdown.request == request, !request.touches(changed) {
                kept[session.id] = breakdown
            } else {
                requests.append(request)
            }
        }
        if !requests.isEmpty, let read = try? await ledger.sessionUsage(requests) {
            let counts = Dictionary(sessions.map { ($0.id, [$0.tokensIn, $0.tokensOut, $0.cacheReadTokens]) }, uniquingKeysWith: { first, _ in first })
            for request in requests { kept[request.sessionID] = .init(counts: counts[request.sessionID] ?? [], request: request, usage: read[request.sessionID]) }
            await results.storeBreakdowns(kept, mark: now, generation: generation, priceRevision: priceRevision)
        } else {
            // Nothing could be read: keep what was known, and the mark it was read at, so the next pass reads it again.
            for request in requests { kept[request.sessionID] = known[request.sessionID] }
            await results.storeBreakdowns(kept, mark: requests.isEmpty ? now : mark, generation: generation, priceRevision: priceRevision)
        }
        return kept.compactMapValues(\.usage)
    }

    /// Each window's models' reply speed, from the gaps between its calls in the ledger: the last hour when it has
    /// calls, otherwise whatever the ledger still holds, so a quiet week still reads at its last observed speed. A
    /// pool whose own key left no calls borrows the speed of its models in other clients — how fast a GLM replies is
    /// the model's, not the credential's.
    private func replyRates(of consumersByWindow: [String: Set<String>], reports: [UsageReport], now: Date) async -> [String: QuotaReplyRate] {
        let poolProviders = reports.flatMap(\.discoveredAgents).reduce(into: [String: String]()) {
            if let provider = $1.billingPool?.provider { $0[$1.id] = provider }
        }
        let allDescriptors = UsageAggregation.consumersUnion(reports.map(\.consumers))
        let allConsumers = Set(allDescriptors.map(\.id))
        var consumers = consumersByWindow.reduce(into: [String: Set<String>]()) { result, pair in
            var ids = pair.value
            if let provider = poolProviders[pair.key] {
                ids.formUnion(allConsumers.filter { $0.localizedCaseInsensitiveContains(provider) })
            }
            result[pair.key] = ids
        }
        // An API balance has no window, but its models' speed reads the same under its block's key.
        for billing in reports.flatMap(\.billing) {
            let owned = Set(allDescriptors.filter { billing.contains($0) }.map(\.id))
            if !owned.isEmpty { consumers[billing.panelBlockKey] = owned }
        }
        let agents = Set(consumers.values.joined())
        guard !agents.isEmpty,
              let events = try? await ledger.replyEvents(agents: agents,
                    sinceMs: RecordCoding.milliseconds(now.addingTimeInterval(-7 * 86400)))
        else { return [:] }
        let horizon = RecordCoding.milliseconds(now.addingTimeInterval(-3600))
        let recent = events.filter { $0.atMs >= horizon }
        return consumers.compactMapValues {
            QuotaMath.replyRate(events: recent, consumers: $0) ?? QuotaMath.replyRate(events: events, consumers: $0)
        }
    }
    /// Each vendor's checks come from its last result, so a quiet vendor is read again only when its activity ages.
    public func sourceChecks() async -> [String: [Date]] {
        await results.reports().mapValues(\.activityChecks).filter { !$0.value.isEmpty }
    }

    /// Each vendor's next account reading comes from its last result: its quota moves while its own work runs. A vendor
    /// whose last read failed has no result to judge and keeps the account interval.
    public func accountChecks(since: [String: Date], spread: [String: TimeInterval], now: Date) async -> [String: Date] {
        let reports = await results.reports()
        return vendors.reduce(into: [:]) { due, vendor in
            guard let last = since[vendor.vendor], let report = reports[vendor.vendor] else { return }
            due[vendor.vendor] = report.accountCheck(since: last, now: now, seesLocalWork: vendor.provider.seesLocalWork,
                                                     spread: spread[vendor.vendor] ?? 0)
        }
    }

    /// Parse caches and report copies of earlier versions, replaced by the usage ledger.
    static func removeLegacyCaches(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") && ["transcripts-cache", "codex-transcripts-", "deepseek-transcripts-"].contains(where: name.hasPrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func mergeBilling(_ values: [APIBilling]) -> [APIBilling] {
        Dictionary(grouping: values, by: \.id).values.compactMap { observations in
            guard let latest = observations.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) else { return nil }
            // Costs come from the ledger; the newest observation that carries them is the most complete.
            let costs = observations.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                .first { !$0.costs.isEmpty || !$0.sessionCosts.isEmpty } ?? latest
            return APIBilling(vendor: latest.billingPool?.provider ?? latest.vendor, balances: latest.balances, isAvailable: latest.isAvailable,
                updatedAt: latest.updatedAt, costs: costs.costs, sessionCosts: costs.sessionCosts,
                notice: latest.notice, readingIssue: latest.readingIssue, billingPool: latest.billingPool)
        }.sorted { $0.id < $1.id }
    }

}

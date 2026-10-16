import Foundation

/// Harness exposes local usage, not subscription quota windows.
public actor DeepSeekUsageProvider: UsageProvider, LedgerRecording {
    private let directory: URL
    private let transcripts: DeepSeekTranscriptStore
    private let clock: @Sendable () -> Date
    private let readBalance: @Sendable () async throws -> DeepSeekBalance?
    private let readProcessStarts: @Sendable () async -> [Date]
    /// Where the balance's readings are kept for its trend.
    private let ledger: UsageLedger
    private var lastBalance: (at: Date, result: Result<DeepSeekBalance?, UsageProviderError>)?
    /// When each currency's balance runs out, as of the last reading.
    private var runsOut: [String: Date] = [:]
    private var lastProcessCheck: (at: Date, starts: [Date])?

    public init(directory: URL, transcripts: DeepSeekTranscriptStore,
                readBalance: @escaping @Sendable () async throws -> DeepSeekBalance? = { nil },
                readProcessStarts: @escaping @Sendable () async -> [Date] = { [] },
                ledger: UsageLedger = .inMemory(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.transcripts = transcripts; self.clock = clock
        self.readBalance = readBalance
        self.readProcessStarts = readProcessStarts
        self.ledger = ledger
    }

    public static func standard(ledger: UsageLedger) -> DeepSeekUsageProvider {
        let directory = DeepSeekLocator.dataDirectory
        return DeepSeekUsageProvider(directory: directory, transcripts: DeepSeekTranscriptStore(
            root: directory.appendingPathComponent("sessions"), ledger: ledger),
            readBalance: { try await DeepSeekBalanceClient(directory: directory).fetch() },
            readProcessStarts: { await DeepSeekRuntime.processStarts(directory: directory) }, ledger: ledger)
    }

    /// The billing account the balance's readings are kept under, as its cost buckets are.
    static let billing = "DeepSeek"

    public nonisolated var watchedDirectories: [URL]? { [transcripts.root] }
    public func fileChanges(_ paths: Set<String>?) async { await transcripts.fileChanges(paths) }

    public func refreshAccountUsage(historyHours: Int) async {
        guard DeepSeekLocator.isInstalled(directory: directory) else { return }
        let now = clock()
        do {
            let balance = try await readBalance()
            lastBalance = (now, .success(balance))
            runsOut = [:]
            guard let balance else { return }
            let ledger = ledger
            _ = try? await ledger.write { try $0.appendBalances(balance.balances, billing: Self.billing, at: now) }
            for item in balance.balances {
                let samples = (try? await ledger.balanceSamples(billing: Self.billing, currency: item.currency,
                                                                since: now.addingTimeInterval(-BalanceTrend.lookback))) ?? []
                runsOut[item.currency] = BalanceTrend.runsOutAt(samples, at: now)
            }
        } catch {
            if Task.isCancelled { return }
            lastBalance = (now, .failure(UsageProviderError(error.localizedDescription)))
        }
    }

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        let now = clock(), weekAgo = now.addingTimeInterval(-7 * 86400)
        let cutoff = min(weekAgo, now.addingTimeInterval(-Double(historyHours) * 3600))
        let indexed = await transcripts.index(since: cutoff)
        // Tokens and models come from every log of `historyHours`; sessions only from those active in the session window.
        let sessionStart = SessionWindow.start(at: now)
        let recent = indexed.sessions.filter {
            ($0.transcript.lastActivityAt ?? $0.transcript.startedAt ?? $0.modifiedAt) >= sessionStart
        }
        let processCheck = await processCheck(for: recent, now: now)
        let balance: DeepSeekBalance?, balanceAt: Date?, balanceNotice: String?
        switch lastBalance?.result {
        case .success(let value): (balance, balanceAt, balanceNotice) = (value, value == nil ? nil : lastBalance?.at, nil)
        case .failure(let error): (balance, balanceAt, balanceNotice) = (nil, nil, error.message)
        case nil: (balance, balanceAt, balanceNotice) = (nil, nil, nil)
        }
        let installed = DeepSeekLocator.isInstalled(directory: directory)
        let models = Set(indexed.sessions.flatMap { [$0.transcript.model] + $0.transcript.models }).sorted()
        let consumers = models.map { AgentDescriptor(id: "deepseek-model:\($0)", vendor: "DeepSeek", model: ModelCatalog.consumerName(of: "deepseek-model:\($0)"),
                                                     source: L10n.sourceDeepSeekSessions, enabled: true) }
        let sessions = recent.filter { !$0.transcript.isSubagent }.map { session in
            let t = session.transcript
            let evidence = t.evidence(processStarts: processCheck?.starts, checkedAt: processCheck?.at)
            return LiveSession(id: "deepseek:\(t.id!)", agentId: "deepseek-model:\(t.model)",
                               task: t.title ?? t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "DeepSeek Harness",
                               terminal: t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                               startedAt: t.startedAt ?? session.modifiedAt,
                               endedAt: SessionPhase.read(evidence, rule: .process, at: now).inFlight
                                   ? nil : (t.lastActivityAt ?? t.startedAt ?? session.modifiedAt),
                               pctOfWindow: nil, tokensIn: t.inputTokens, tokensOut: t.outputTokens,
                               client: "DeepSeek Harness", transcriptPath: session.path,
                               cacheReadTokens: t.cachedInputTokens, observedAt: evidence.newest, workingDirectory: t.cwd,
                               lastActivityAt: t.lastActivityAt, activity: t.activity ?? SessionActivity())
        }.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive }
            return (a.endedAt ?? a.startedAt) > (b.endedAt ?? b.startedAt)
        }
        let descriptor = AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "Harness",
                                         source: L10n.sourceDeepSeekSessions, enabled: false)
        let discovered = consumers.isEmpty
            ? (agents.contains { $0.id.hasPrefix("deepseek-model:") } ? [] : [descriptor]) : consumers
        let notice = [indexed.notice, balanceNotice].compactMap { $0 }.joined(separator: " · ")
        let costs = await transcripts.costs(since: cutoff)
        var sessionCosts: [String: [String: Decimal]] = [:]
        for session in recent {
            if let estimate = costs.logs[session.path] { sessionCosts["deepseek:\(session.transcript.id!)"] = estimate }
        }
        let balances = (balance?.balances ?? []).map {
            AccountBalance(currency: $0.currency, total: $0.total, granted: $0.granted, toppedUp: $0.toppedUp, runsOutAt: runsOut[$0.currency])
        }
        let billing = APIBilling(vendor: "DeepSeek", balances: balances, isAvailable: balance?.isAvailable,
                                 updatedAt: balanceAt, costs: costs.buckets, sessionCosts: sessionCosts, notice: balanceNotice,
                                 readingIssue: balanceNotice.map(ReadingIssue.readFailed))
        return UsageReport(generatedAt: now, snapshots: [], sessions: sessions,
                           notice: notice.isEmpty ? nil : notice, discoveredAgents: installed ? discovered : [], consumers: consumers,
                           indexing: indexed.indexing,
                           sourceNotices: notice.isEmpty ? [:] : ["DeepSeek": notice], quotaNotices: balanceNotice.map { ["DeepSeek": $0] } ?? [:],
                           readingIssues: balanceNotice.map { ["DeepSeek": .readFailed($0)] } ?? [:],
                           billing: installed ? [billing] : [],
                           completions: recent.flatMap { $0.transcript.completions ?? [] },
                           turns: recent.flatMap { $0.transcript.sessionTurns })
    }

    /// The process table's start times and when it was read. Process starts only decide a running turn whose log went
    /// quiet, so the table is inspected only once a log has recorded no event for a while, at most every 30 seconds. Nil
    /// means it was not consulted and the turn keeps running.
    private func processCheck(for sessions: [DeepSeekTranscriptStore.Session], now: Date) async -> (at: Date, starts: [Date])? {
        let quiet = sessions.contains { session in
            !session.transcript.isSubagent && session.transcript.sessionTurns.last?.state == .running
                && now.timeIntervalSince(session.transcript.lastActivityAt ?? session.modifiedAt) >= SessionPhase.Limits.processCheck
        }
        guard quiet else { lastProcessCheck = nil; return nil }
        if let last = lastProcessCheck, now.timeIntervalSince(last.at) < SessionPhase.Limits.processRecheck { return last }
        let starts = await readProcessStarts()
        lastProcessCheck = (now, starts)
        return (now, starts)
    }
}

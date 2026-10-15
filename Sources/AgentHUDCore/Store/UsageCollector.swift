import AgentHUDSupport
import Foundation

/// A host's extension points in the collection pipeline. Every hook runs on the main actor inside the pass that fetched
/// the report, while no provider reads and nothing writes the usage ledger, so a hook may read the ledger itself.
public struct UsageCollectionHooks {
    /// Hourly buckets providers load, including the current partial hour; asked before every local poll and account step.
    public var historyHours: @MainActor () -> Int
    /// Receives each report the provider returned, before it is displayed. The pass, and so the next pass, waits for it.
    public var publish: (@MainActor (UsageReport) async -> Void)?
    /// Turns the provider's report into the displayed report, for example to add other data. The result must keep the
    /// provider's discovered agents, accounts, active quota pools, completions and turns, which drive the agent list and
    /// the island.
    public var merge: (@MainActor (UsageReport) async -> UsageReport)?

    public init(historyHours: @escaping @MainActor () -> Int = { UsageStore.historyHours },
                publish: (@MainActor (UsageReport) async -> Void)? = nil,
                merge: (@MainActor (UsageReport) async -> UsageReport)? = nil) {
        self.historyHours = historyHours
        self.publish = publish
        self.merge = merge
    }
}

/// The collection pipeline. Every source only signals that it has new data: a file change under its directories, a finished
/// account step, one of its checks falling due, or its poll interval when it cannot name its directories. The collector
/// waits for those signals and reads the signalled sources, one read or account step at a time, handing each report to
/// the store. A source's account steps run when its own work, or one of its windows, makes a new reading worth taking.
@MainActor
final class UsageCollector {
    weak var store: UsageStore?
    private let provider: any UsageProvider
    private let settings: SettingsStore
    private let hooks: UsageCollectionHooks
    private var pollTask: Task<Void, Never>?
    /// Moves the store's clock on, so countdowns re-render, and confirms a quiet stretch as current data.
    private var clockTask: Task<Void, Never>?
    /// Wakes the waiting loop: a file change, a timer, a refresh, a settings change that needs a read.
    private var wake: AsyncStream<Void>.Continuation?
    /// One pass of the pipeline runs at a time; a request during a pass is served by the next one.
    private var isCollecting = false
    /// Account steps left in the current sweep, run one at a time between local reads.
    private var accountSteps: [(source: String, run: AccountRefreshStep)] = []
    /// When each source's account steps last ran; a source that has never run them is due at once.
    private var accountRunAt: [String: Date] = [:]
    /// How long past its time each source's next scheduled reading waits, drawn when its steps last ran.
    private var accountSpread: [String: TimeInterval] = [:]
    /// Consent to read GitHub Copilot's quota, and a look at the numbers, read accounts at once instead of when work moves them.
    private var sweptWithCopilotQuota: Bool?
    private var forcesAccounts = false
    /// The read of every local source that stands in for a file event the watch missed.
    private var fallbackReadAt: Date?
    private var sources: [UsageSource] = []
    private var fetchedAt: Date?
    private var fetchedAgents: [AgentDescriptor]?
    /// Every source must be read: at start, at the fallback read, after a refresh request or a changed agent list.
    private var needsFetch = true
    /// Sources signalled since their last read.
    private var signalled: Set<String> = []
    /// When each source was last read, so a check or poll interval counts from that source's own read.
    private var readAt: [String: Date] = [:]
    /// A failed read is tried again at this time.
    private var retryAt: Date?
    private var changes: FileChangeMonitor?
    /// Each recent session log's modification time and size when it was last looked at. A client that keeps its log
    /// open and appends to it, as Codex does, reaches the file watch late or not at all: a turn that started in a quiet
    /// session went unseen until the fallback read. These few logs are therefore looked at on a schedule as well.
    private var logSignatures: [String: String] = [:]
    private var logsCheckedAt: Date?
    /// How recently a session must have been active for its log to be looked at, and how many logs are.
    static let logCheckRecency: TimeInterval = 24 * 3600
    static let logCheckLimit = 64
    /// The provider's last report before the merge hook, numbered so a slower merge never replaces a newer one.
    private var local: (report: UsageReport, generation: Int)?
    private var generation = 0
    private var isMerging = false
    private var mergeRequested = false

    init(provider: any UsageProvider, settings: SettingsStore, hooks: UsageCollectionHooks) {
        self.provider = provider
        self.settings = settings
        self.hooks = hooks
        sources = provider.sources
    }

    func start() {
        stop()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        settings.onChange = { [weak self] change in self?.settingsChanged(change) }
        let directories = sources.compactMap(\.directories).flatMap { $0 }
        changes = directories.isEmpty ? nil : FileChangeMonitor(directories: directories, onChange: { continuation.yield() })
        pollTask = Task { [weak self] in
            var wakes = stream.makeAsyncIterator()
            while !Task.isCancelled {
                guard let pause = await self?.collect(force: false) else { return }
                // A cancelled timer must not wake the loop: only a timer that ran out yields.
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(pause)) } catch { return }
                    continuation.yield()
                }
                guard await wakes.next() != nil else { timer.cancel(); return }
                timer.cancel()
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let store = self.store else { return }
                store.now = store.clock()
                self.confirmQuiet(at: store.now)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        clockTask?.cancel()
        clockTask = nil
        wake?.finish()
        wake = nil
        changes = nil
        // Steps that did not run keep their source due, so a restart reads the accounts it owed.
        accountSteps = []
    }

    func refresh() async {
        // An explicit refresh is also a request to reconcile files even if a directory event is still in flight.
        await provider.fileChanges(nil)
        needsFetch = true
        _ = await collect(force: true)
        wake?.yield()
    }

    /// Reads every source's accounts in the next pass, whatever its work is doing; the request spacing still holds.
    func refreshAccounts() async {
        forcesAccounts = true
        await refresh()
    }

    /// A report installed directly is not the provider's; merging must not replace it.
    func forgetLocalReport() {
        local = nil
    }

    /// A settings change that collection follows wakes the loop at once, where it would wait for the next signal: a
    /// changed agent list is read from every source, and consent to read GitHub Copilot quota, given or withdrawn, reads
    /// Copilot's quota and every other account the request spacing allows. It wakes the next pass, serial like any other.
    /// Rows a pass merged from its own report ask for nothing.
    private func settingsChanged(_ change: SettingsStore.Change) {
        guard change != .discovery,
              settings.agents != fetchedAgents || settings.settings.readCopilotQuota != sweptWithCopilotQuota else { return }
        wake?.yield()
    }

    /// While nothing is signalled and file changes are watched, no change was missed: the data on screen is current.
    func confirmQuiet(at date: Date) {
        guard let store, !isCollecting, !needsFetch, signalled.isEmpty, retryAt == nil, changes?.isWatching != false,
              sources.allSatisfy({ $0.directories != nil }), date.timeIntervalSince(store.dataDate) >= 60 else { return }
        store.checkedAt = date
    }

    /// Merges the last provider report again without collecting. A local read in progress merges for it, or merges again
    /// once it returns when its own merge had already started.
    func remerge() async {
        guard hooks.merge != nil else { return }
        mergeRequested = true
        guard let store, !isMerging, !store.isRefreshing else { return }
        isMerging = true
        defer { isMerging = false }
        while mergeRequested, !store.isRefreshing, let merge = hooks.merge, let local {
            mergeRequested = false
            let merged = await merge(local.report)
            guard local.generation == self.local?.generation, store.isAccessAllowed else { continue }
            store.merged(merged)
        }
    }

    /// One pass: collects the signals, reads the signalled sources, then runs account steps within their budget.
    /// Returns how long to wait for the next signal that is known in advance; file changes wake the loop sooner.
    private func collect(force: Bool) async -> TimeInterval {
        guard let store, store.isAccessAllowed, !isCollecting else { return UsageRefresh.pollInterval }
        if let pausedUntil = store.pausedUntil, pausedUntil > store.clock() {
            return min(pausedUntil.timeIntervalSince(store.clock()), UsageRefresh.accountInterval)
        }
        store.pausedUntil = nil
        isCollecting = true
        defer { isCollecting = false }
        let started = Date()
        if fallbackReadAt.map({ started.timeIntervalSince($0) >= UsageRefresh.accountInterval }) ?? true {
            fallbackReadAt = started
            // The fallback read catches a change the watch missed and picks up directories created since the last one.
            changes?.update()
            needsFetch = true
        }
        let consent = settings.settings.readCopilotQuota
        if accountSteps.isEmpty {
            // Consent to read Copilot's quota follows the switch at once and is a look at every other account; a look
            // reads whatever the request spacing allows; otherwise every source waits until its own work, or one of its
            // windows, is worth a reading.
            let consented = sweptWithCopilotQuota != consent, looked = forcesAccounts || consented
            forcesAccounts = false
            sweptWithCopilotQuota = consent
            let due = await accountDue(at: started)
            accountSteps = sources.filter { source in
                if consented && source.name == AdditionalSource.copilot.vendor { return true }
                let spaced = (accountRunAt[source.name] ?? .distantPast).addingTimeInterval(UsageRefresh.accountRequestSpacing)
                return spaced <= started && (looked || due[source.name].map { $0 <= started } ?? false)
            }.flatMap { source in source.accountSteps.map { (source.name, $0) } }
        }
        await gatherSignals(at: started)
        if changes?.isWatching == false { await provider.fileChanges(nil) }
        let spacing = force ? 0 : fetchedAt.map { UsageRefresh.readSpacing - started.timeIntervalSince($0) } ?? 0
        if needsFetch || !signalled.isEmpty {
            if spacing <= 0 {
                let names: Set<String>? = needsFetch || signalled.contains("") ? nil : signalled
                await fetch(at: started, sources: names, into: store)
                if mergeRequested { await remerge() }
            }
        } else if started.timeIntervalSince(store.dataDate) >= 60, changes?.isWatching != false {
            store.checkedAt = started
        }
        if !accountSteps.isEmpty, !Task.isCancelled {
            let stepsStarted = Date()
            repeat {
                let step = accountSteps.removeFirst()
                accountRunAt[step.source] = Date()
                accountSpread[step.source] = .random(in: 0...UsageRefresh.accountSpread)
                await step.run(hooks.historyHours())
                if step.source.isEmpty { needsFetch = true } else { signalled.insert(step.source) }
            } while !accountSteps.isEmpty && !Task.isCancelled && Date().timeIntervalSince(stepsStarted) < UsageRefresh.accountStepBudget
        }
        return await pause(after: Date())
    }

    /// Turns what happened since the last pass into signalled sources.
    private func gatherSignals(at date: Date) async {
        if fetchedAgents != settings.agents { needsFetch = true }
        if let retryAt, retryAt <= date { needsFetch = true; self.retryAt = nil }
        if store?.isIndexing == true, fetchedAt.map({ date.timeIntervalSince($0) >= UsageRefresh.indexingInterval }) ?? true {
            needsFetch = true
        }
        if let changes, changes.isWatching {
            if let paths = changes.consumePaths() {
                if !paths.isEmpty {
                    await provider.fileChanges(paths)
                    signalled.formUnion(owners(of: paths))
                }
            } else {
                await provider.fileChanges(nil)
                needsFetch = true
            }
        }
        if changes?.isWatching == true, logsCheckedAt.map({ date.timeIntervalSince($0) >= UsageRefresh.pollInterval }) ?? true {
            logsCheckedAt = date
            let grown = Self.changedLogs(recentLogs(at: date), known: &logSignatures)
            if !grown.isEmpty {
                await provider.fileChanges(grown)
                signalled.formUnion(owners(of: grown))
            }
        }
        for source in polledSources where readAt[source].map({ date.timeIntervalSince($0) >= UsageRefresh.pollInterval }) ?? true {
            signalled.insert(source)
        }
        for (source, times) in await checks() {
            let since = readAt[source] ?? .distantPast
            if times.contains(where: { $0 > since && $0 <= date }) { signalled.insert(source) }
        }
    }

    /// The logs of the sessions most recently active, newest first: where a new turn is most likely to be written.
    private func recentLogs(at date: Date) -> [String] {
        let cutoff = date.addingTimeInterval(-Self.logCheckRecency)
        let recent = (local?.report.sessions ?? []).compactMap { session -> (path: String, at: Date)? in
            guard let path = session.transcriptPath else { return nil }
            let at = session.lastActivityAt ?? session.endedAt ?? session.startedAt
            return at >= cutoff ? (path, at) : nil
        }
        return recent.sorted { $0.at > $1.at }.prefix(Self.logCheckLimit).map(\.path)
    }

    /// The logs among `paths` whose modification time or size differs from what `known` holds, which then holds what
    /// they are now. A log seen for the first time is only noted: the read that listed it has just read it.
    static func changedLogs(_ paths: [String], known: inout [String: String]) -> Set<String> {
        var changed: Set<String> = [], next: [String: String] = [:]
        for path in paths {
            // A new URL does not answer from values cached by an earlier look.
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize else { continue }
            let signature = "\(modified.timeIntervalSince1970):\(size)"
            if let before = known[path], before != signature { changed.insert(path) }
            next[path] = signature
        }
        known = next
        return changed
    }

    /// Sources read on a schedule: those without directories, and every source while file changes cannot be watched.
    private var polledSources: [String] {
        sources.filter { $0.directories == nil || changes?.isWatching == false }.map(\.name)
    }

    /// The sources whose directories contain a changed path. File events name real paths, such as `/private/var` for
    /// `/var`, which Foundation's own path normalization hides, so each directory is compared as given and as `realpath` resolves it.
    private func owners(of paths: Set<String>) -> Set<String> {
        var owners: Set<String> = []
        for source in sources {
            guard let directories = source.directories else { continue }
            let prefixes = directories.flatMap { url -> [String] in
                let path = url.standardizedFileURL.path
                let resolved = url.resolvingSymlinksInPath().path
                return path == resolved ? [path] : [path, resolved]
            }
            if paths.contains(where: { path in prefixes.contains { path == $0 || path.hasPrefix($0 + "/") } }) {
                owners.insert(source.name)
            }
        }
        return owners
    }

    /// When each source's account steps are next worth running: what the provider asks for, the account interval and
    /// the source's spread when it names no time, and at once for a source that has never run them. No source runs
    /// twice within the request spacing, so a provider that wants a reading sooner than it allows one is asked once
    /// the spacing has passed.
    private func accountDue(at now: Date) async -> [String: Date] {
        let asked = await provider.accountChecks(since: accountRunAt, spread: accountSpread, now: now)
        return sources.reduce(into: [:]) { due, source in
            guard let last = accountRunAt[source.name] else { return due[source.name] = .distantPast }
            let interval = UsageRefresh.accountInterval + (accountSpread[source.name] ?? 0)
            due[source.name] = max(asked[source.name] ?? last.addingTimeInterval(interval),
                                   last.addingTimeInterval(UsageRefresh.accountRequestSpacing))
        }
    }

    /// Each source's check times; a provider that does not split itself is checked from the report it returned.
    private func checks() async -> [String: [Date]] {
        let checks = await provider.sourceChecks()
        guard checks.isEmpty, sources.count == 1, let report = local?.report else { return checks }
        return [sources[0].name: report.activityChecks]
    }

    /// The time until the next signal known in advance: an account step, a source's next account reading, the fallback
    /// read, a pending read held back by the read spacing, indexing, a poll interval, a check or a retry.
    private func pause(after now: Date) async -> TimeInterval {
        var times: [Date] = []
        if !accountSteps.isEmpty { times.append(now.addingTimeInterval(UsageRefresh.accountStepBudget)) }
        else { times += await accountDue(at: now).values }
        if let fallbackReadAt { times.append(fallbackReadAt.addingTimeInterval(UsageRefresh.accountInterval)) }
        if needsFetch || !signalled.isEmpty { times.append((fetchedAt ?? now).addingTimeInterval(UsageRefresh.readSpacing)) }
        if store?.isIndexing == true { times.append((fetchedAt ?? now).addingTimeInterval(UsageRefresh.indexingInterval)) }
        if let retryAt { times.append(retryAt) }
        for source in polledSources { times.append((readAt[source] ?? now).addingTimeInterval(UsageRefresh.pollInterval)) }
        if changes?.isWatching == true, !logSignatures.isEmpty {
            times.append((logsCheckedAt ?? now).addingTimeInterval(UsageRefresh.pollInterval))
        }
        for (_, dates) in await checks() { times += dates.filter { $0 > now } }
        let next = times.min() ?? now.addingTimeInterval(UsageRefresh.accountInterval)
        return max(0, next.timeIntervalSince(now))
    }

    /// The publish and merge hooks run here, before the pass can end.
    private func fetch(at date: Date, sources names: Set<String>?, into store: UsageStore) async {
        needsFetch = false
        store.isRefreshing = true
        defer { store.isRefreshing = false }
        do {
            let agents = settings.agents
            let fetched = try await provider.fetchUsage(agents: agents, historyHours: hooks.historyHours(), sources: names)
            let read = names ?? Set(sources.map(\.name))
            signalled.subtract(read)
            for name in read { readAt[name] = date }
            await hooks.publish?(fetched)
            mergeRequested = false
            let report = await hooks.merge?(fetched) ?? fetched
            guard store.isAccessAllowed, !Task.isCancelled else { needsFetch = true; return }
            let agentsUnchanged = settings.agents == agents
            settings.mergeDiscovered(from: report)
            // This pass consumed its captured input and its own discoveries, but not an edit made while it awaited.
            fetchedAgents = agentsUnchanged ? settings.agents : agents
            generation += 1
            local = (fetched, generation)
            store.collected(report)
            fetchedAt = date
        } catch {
            // Every source failed; the retry reads them all again instead of spinning on the same signals.
            signalled = []
            retryAt = date.addingTimeInterval(UsageRefresh.pollInterval)
            guard store.isAccessAllowed, !Task.isCancelled else { return }
            fetchedAt = date
            store.lastError = error.localizedDescription
        }
        store.now = store.clock()
    }
}

extension UsageReport {
    /// The times at which this report's activity changes with time alone: when a running turn reaches the age at which
    /// it no longer counts as current, and when a session whose source never said what its turn is doing reaches the
    /// age at which a quiet log ends it. A source is read again at these times instead of being polled.
    var activityChecks: [Date] {
        let margin: TimeInterval = 1
        var times = sessions.filter(\.isLive).map { $0.observedAt.addingTimeInterval(SessionPhase.Limits.quiet + margin) }
        for turn in turns where turn.state == .running {
            let observed = RecordCoding.date(turn.observedAtMs)
            times.append(observed.addingTimeInterval(SessionPhase.Limits.quiet + margin))
            times.append(observed.addingTimeInterval(UsageRefresh.activeTurnFreshness + margin))
            times.append(observed.addingTimeInterval(SessionPhase.Limits.abandoned + margin))
        }
        return times
    }

    /// When an account reading of this source is next worth taking, counted from `since`, when its steps last ran.
    /// A window moves only while work runs, so a running turn is read often, a session between turns slowly, and work
    /// that finished after the last reading once more. An idle source's windows change only when they reset, and a
    /// source that cannot see this Mac's work keeps the account interval. A reading that follows an interval or a reset
    /// waits `spread` past it; the one for work that just finished does not wait.
    func accountCheck(since: Date, now: Date, seesLocalWork: Bool, spread: TimeInterval = 0) -> Date {
        // A deadline remains due until an account request has actually run at or after it.
        // Comparing with `now` loses the scheduled refresh as soon as the deadline arrives.
        let reset = snapshots.filter { snapshot in
            discoveredAgents.first(where: { $0.id == snapshot.agentId }).map(isCurrent) ?? true
        }.compactMap(\.resetAt).filter { $0 > since }.min()
        func after(_ interval: TimeInterval) -> Date { since.addingTimeInterval(interval + spread) }
        let regular: Date
        let stale = now.addingTimeInterval(-UsageRefresh.activeTurnFreshness)
        if turns.contains(where: { $0.state == .running && RecordCoding.date($0.observedAtMs) > stale }) {
            regular = after(UsageRefresh.runningAccountInterval)
        } else if sessions.contains(where: { $0.isLive(at: now) }) {
            regular = after(UsageRefresh.liveAccountInterval)
        } else if !seesLocalWork {
            regular = after(UsageRefresh.accountInterval)
        } else if sessions.contains(where: { ($0.endedAt ?? .distantPast) > since }) {
            regular = now
        } else {
            regular = reset == nil || snapshots.contains(where: { ($0.resetAt ?? .distantFuture) <= since })
                ? after(UsageRefresh.accountInterval) : .distantFuture
        }
        return min(regular, reset?.addingTimeInterval(spread) ?? .distantFuture)
    }
}

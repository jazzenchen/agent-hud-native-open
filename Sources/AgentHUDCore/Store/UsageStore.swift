import Foundation
import Observation

/// Observable app state: the collected report, derived rows, glow appearance and stats selections.
@MainActor
@Observable
public final class UsageStore {
    public internal(set) var report: UsageReport? { didSet { reportGeneration += 1 } }
    public internal(set) var lastError: String?
    public internal(set) var pausedUntil: Date?
    public internal(set) var isRefreshing = false
    public internal(set) var statsRange: StatsRange = .hours24
    public var tokenBucketSize: TokenBucketSize = .hour1
    public var tokenDimensions: TokenDimensions = .fresh
    /// Explicitly picked token cards; nil shows recorded clients and clients connected to monitored services.
    public var pickedAgents: Set<String>?
    /// Keep every selectable range ready, including the partial hour at the start of the rolling window.
    public static var historyHours: Int { StatsRange.days7.hours + 1 }
    /// The statistics window's page. Pointing out a quota window turns to Tokens, focusing a session to Sessions.
    public var statsTab: StatsTab = .tokens
    /// The quota window the statistics window points out, set by whatever opened it.
    public var selectedQuotaId: String? { didSet { if selectedQuotaId != nil { statsTab = .tokens } } }
    /// The session the Sessions page shows in place of its list; nil shows the list.
    public var focusedSessionID: String? {
        didSet {
            if focusedSessionID != nil { statsTab = .sessions }
            if focusedSessionID != oldValue { focusedTurn = nil }
        }
    }
    /// The focused session's turn whose calls its page lays out, by its place in the session's breakdown.
    public var focusedTurn: Int? { didSet { if focusedTurn != oldValue { focusedTurnCalls = nil } } }
    /// The focused turn's calls once read, with the tools their logs name.
    public internal(set) var focusedTurnCalls: [TurnCall]?
    /// Where turns' calls are read from: the ledger a host's providers write.
    @ObservationIgnored public var ledger: UsageLedger?
    /// The calls a turn shows where there is no ledger to read them from, such as the demo's
    /// (`DemoData.turnCalls(session:turn:)`); without either, a turn shows none.
    @ObservationIgnored public var sampleTurnCalls: (@MainActor (LiveSession, SessionUsage.Turn) -> [TurnCall])?
    public var glowHidden = false
    /// Advances every few seconds so countdowns re-render.
    public internal(set) var now: Date
    /// The time the store runs on: the wall clock, or the demo's own (`DemoClock`).
    @ObservationIgnored public let clock: @Sendable () -> Date

    public let settings: SettingsStore
    private let accessAllowed: () -> Bool
    let collector: UsageCollector
    /// A later poll that found nothing changed extends the report's coverage.
    var checkedAt: Date?
    /// Counts the reports shown, so that a new one is told from the last without comparing them.
    @ObservationIgnored private var reportGeneration = 0
    /// The last view built, and what it was built from.
    @ObservationIgnored private var built: (generation: Int, agents: [AgentDescriptor], settings: Settings, approvals: [String],
                                            waiting: [String: Date], failure: String?, view: ReportView)?
    /// The HUD's token columns built from the current report up to one end, by period and models
    /// (`hudTokenColumns(consumerIDs:period:)`).
    @ObservationIgnored private var hudColumns: (generation: Int, end: Date, columns: [HUDColumnsKey: [TokenColumn]])?

    /// What one set of the HUD's token columns is built for.
    struct HUDColumnsKey: Hashable {
        let period: PanelTokenPeriod
        let consumerIDs: Set<String>?
    }

    /// `hooks` let a host choose the history window, receive each provider report and follow what each pass read.
    public init(provider: any UsageProvider, settings: SettingsStore, accessAllowed: @escaping () -> Bool = { true },
                hooks: UsageCollectionHooks = UsageCollectionHooks(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.accessAllowed = accessAllowed
        self.clock = clock
        now = clock()
        collector = UsageCollector(provider: provider, settings: settings, hooks: hooks)
        collector.store = self
    }

    public var isAccessAllowed: Bool { accessAllowed() }

    // MARK: Lifecycle

    public func start() {
        collector.start()
    }

    public func stop() {
        collector.stop()
    }

    /// Reads local data now unless a pass is already running, in which case the next pass reads it.
    public func refresh() async {
        await collector.refresh()
    }

    /// Reads the accounts again as soon as the next pass can, for when someone looks at the numbers instead of waiting
    /// for work to move them. Every provider's own request spacing still holds, so looking twice in a minute reads once.
    public func refreshAccounts() async {
        await collector.refreshAccounts()
    }

    /// Reads these logs now, for a host whose clients' hooks say something happened in them, such as a prompt submitted
    /// or a turn stopped. A hook is only a reminder: the store keeps nothing it says, and the log, read at once, says what
    /// happened. The next pass reads the sources that own them without waiting for a file event or the read spacing, and
    /// looks at them again for a moment after, while their clients may still be writing (`LogReminders`). The read is a
    /// pass like any other, serial with collection and as incremental; a pass under way leaves them to the next.
    public func remind(paths: Set<String>) {
        collector.remind(paths: paths)
    }

    /// Asks for a pass that reads the sources owning `paths` at `date`, on the wall clock, or at the next pass when nil,
    /// for a host that reads something of its own in the after-pass hook (`UsageCollectionHooks.afterPass`) and needs a
    /// pass by then that no file event may bring, such as a transcript it put off until that time. The pass waits for the
    /// read spacing as any pass does. A request is not a reminder: nothing changed, so the provider is told of no change,
    /// the hook is named none of the paths, and nothing is looked at again after it. Requests for one path keep the
    /// earliest time, and a path no watched source owns has every source read.
    public func requestPass(for paths: Set<String>, at date: Date? = nil) {
        collector.requestPass(for: paths, at: date)
    }

    /// Installs a report directly (snapshots, tests) without going through the provider.
    public func replace(report: UsageReport) {
        self.report = report
        collector.forgetLocalReport()
        checkedAt = nil
        lastError = nil
        now = clock()
    }

    /// A pass's report replaces the displayed one.
    func collected(_ report: UsageReport) {
        self.report = report
        checkedAt = nil
        lastError = nil
    }

    public func pause(for interval: TimeInterval) {
        pausedUntil = clock().addingTimeInterval(interval)
    }

    public func resume() {
        pausedUntil = nil
        Task { await refreshAccounts() }
    }

    public var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > now
    }

    // MARK: Derived

    /// What the Mac shows of the report now: its rows, balances, levels and sessions, with the sessions whose clients wait
    /// for an answer to a permission request or say they wait on the user (`PermissionRequests.shared`) waiting for
    /// approval, and every reading failed while the last pass failed to read any source. It is built again only when the
    /// report, the agent list, the settings, the waiting requests, a failed pass or the time changed, and reading it tracks
    /// all six.
    public var view: ReportView {
        let report = self.report, agents = settings.agents, preferences = settings.settings, now = self.now, failure = lastError
        let approvals = PermissionRequests.shared.pending, requests = approvals.map(\.id)
        let waiting = PermissionRequests.shared.waitingSessions
        if let built, built.generation == reportGeneration, built.view.now == now, built.agents == agents,
           built.settings == preferences, built.approvals == requests, built.waiting == waiting, built.failure == failure {
            return built.view
        }
        let view = ReportView(report: report, agents: agents, settings: preferences, approvals: approvals, waiting: waiting,
                              now: now, failure: failure)
        built = (reportGeneration, agents, preferences, requests, waiting, failure, view)
        return view
    }

    /// The HUD's token columns for `key` ending at `end`: built once for the report shown and that end, then kept, so a
    /// panel's body, evaluated on every pass, walks the report's buckets once a report rather than once a body. The
    /// caller reads the report through `dataDate`, so a body that is handed kept columns still follows a new report.
    func hudColumns(_ key: HUDColumnsKey, end: Date, build: () -> [TokenColumn]) -> [TokenColumn] {
        if hudColumns?.generation != reportGeneration || hudColumns?.end != end {
            hudColumns = (reportGeneration, end, [:])
        }
        if let columns = hudColumns?.columns[key] { return columns }
        let columns = build()
        hudColumns?.columns[key] = columns
        return columns
    }

    /// `view.visibleAgents`.
    public var visibleAgents: [AgentDescriptor] { view.visibleAgents }

    /// `view.enabledAgents`.
    public var enabledAgents: [AgentDescriptor] { view.enabledAgents }

    /// `view.rows`.
    public var rows: [AgentRow] { view.rows }

    public func row(for agentId: String) -> AgentRow? { view.rows.first { $0.id == agentId } }

    /// `view.forecastHint(for:)`.
    public func quotaForecastHint(for agentId: String) -> String? { view.forecastHint(for: agentId) }

    /// `view.tokensPerHour(for:)`.
    public func quotaTokensPerHour(for agentId: String) -> Double? { view.tokensPerHour(for: agentId) }

    /// `view.billing`.
    public var enabledBilling: [APIBilling] { view.billing }

    /// One of an account's balances' level, which follows `view.level(of:)`: none while the account's reading shows none.
    public func balanceLevel(_ balance: AccountBalance, billing: APIBilling) -> StatusLevel? {
        guard !balance.total.isNaN, view.assessment(of: billing).showsLevel else { return nil }
        return AlertPolicy.balanceLevel([balance], isAvailable: billing.isAvailable)
    }

    /// `view.levels`.
    public var levels: [StatusLevel] { view.levels }

    /// `view.alertPulseVendors`.
    public var alertPulseVendors: [String] { view.alertPulseVendors }

    public var isIndexing: Bool { report?.indexing != nil }

    /// Includes the brief interval before the first refresh starts; a failed fetch ends loading.
    public var isLoading: Bool { isAccessAllowed && report == nil && !isPaused && (isRefreshing || lastError == nil) }

    /// `view.maxUsedPct`.
    public var maxUsedPct: Double? { view.maxUsedPct }

    /// `view.sessions`, newest first.
    public var sessions: [LiveSession] { view.sessions.map(\.session) }

    /// How long after its last event a vendor still belongs in a logo queue.
    public static let queueRecency: TimeInterval = ReportView.queueRecency

    /// `view.queueVendors`.
    public var queueVendors: [(vendor: String, isWorking: Bool)] { view.queueVendors }

    /// `view.queueMarks`.
    public var queueMarks: [ReportView.QueueMark] { view.queueMarks }

    /// `view.workingVendors`.
    public var workingVendors: Set<String> { view.workingVendors }

    /// The session's source as the view reads it.
    public func sessionSource(_ session: LiveSession) -> SessionSource { view.session(for: session).source }

    /// `view.subscriptions`.
    public var subscriptions: [String: String] { view.subscriptions }

    /// The end of the data on screen: the report's time, or the latest poll that confirmed nothing changed.
    public var dataDate: Date { max(report?.generatedAt ?? now, checkedAt ?? .distantPast) }


    /// Whether live status is on for the session's vendor.
    public func liveStatusEnabled(for session: LiveSession) -> Bool { view.session(for: session).liveStatus }

    /// Running, including a turn blocked on the user: both are work in flight, and the panel tells them apart by colour.
    public func isSessionLive(_ session: LiveSession) -> Bool { view.phase(of: session).isInFlight }

    /// What the newest turn of this session is doing, when its source reported one.
    public func sessionState(_ session: LiveSession) -> SessionTurn.State? { view.session(for: session).turn?.state }

    public func isSessionWaiting(_ session: LiveSession) -> Bool { view.phase(of: session).state == .waitingForApproval }

    public func sessionStatusLabel(_ session: LiveSession) -> String {
        let shown = view.session(for: session)
        guard shown.liveStatus else { return L10n.text("状态显示已关闭", "Live status off") }
        switch shown.phase.state {
        case .unverified: return L10n.text("状态待更新", "Status out of date")
        case .waitingForApproval: return L10n.text("等待批准", "Needs approval")
        case .running, .idle: return Countdown.sessionLabel(shown.phase, now: now)
        }
    }

    /// `view.liveSessions`.
    public var liveSessions: [LiveSession] { view.liveSessions.map(\.session) }

    /// What the agent last said in the session's newest turn that carries a message; nothing while live status is off.
    public func sessionMessage(_ session: LiveSession) -> String? { view.session(for: session).message }

    public var hasLiveSession: Bool { view.sessions.contains { $0.phase.isInFlight } }

    public var updatedAt: Date? { report?.generatedAt }

    /// `view.rowGroups`.
    public var rowGroups: [(vendor: String, rows: [AgentRow])] { view.rowGroups }

    /// `view.accountSections(_:)`.
    public func accountSections(_ rows: [AgentRow]) -> [AccountSection] { view.accountSections(rows) }

    /// `view.accountNotice(for:)`.
    public func accountNotice(for section: AccountSection) -> String? { view.accountNotice(for: section) }

    /// `view.assessment(of:)` put into its header label.
    public func accountLabel(for account: AccountObservation) -> String { view.assessment(of: account).accountLabel(now: now) }
}

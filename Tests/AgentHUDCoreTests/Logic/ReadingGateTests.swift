#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

/// What each surface makes of one quota or balance reading: the notice that holds it back, its status level, the baselines
/// of quota alerts and reset credits, the menu figure, the account header, the reset column, the forecast hint, and what a
/// retained report and the settings keep of a window the read left out.
@MainActor
final class ReadingGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = ProviderAccount.identified(provider: "Codex", user: "a@example.com", workspace: "workspace-1")!
    private var window: AgentDescriptor {
        .init(id: account.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: account)
    }
    /// A window of the same account that the read under test leaves out.
    private var spark: AgentDescriptor {
        .init(id: account.windowID("codex:spark:primary"), vendor: "Codex", model: "Spark", source: "", enabled: true, account: account)
    }

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// A reading of the Codex window and its account, described by how it differs from a fresh one.
    private struct Reading {
        var age: TimeInterval = 60
        var remaining: Double = 25
        var resetIn: TimeInterval? = 2 * 3600
        var isCurrent = true
        var accountNotice: String?
        var sourceNotices: [String: String] = [:]
        var quotaNotices: [String: String]? = [:]
        /// Observations of the same account in other client homes.
        var otherHomes: [AccountObservation] = []
    }

    /// What each surface makes of a reading. The defaults are the answers for a fresh one.
    private struct Gates: Equatable {
        /// Why the reading is not to be trusted.
        var notice: String?
        /// The row's colour in the island, the glow and the menu.
        var level: StatusLevel? = .warning
        /// Quota alerts take the reading as the baseline the next reading is compared with.
        var startsAlerts = true
        /// Reset credits take the account's reading as their baseline.
        var startsCredits = true
        /// The menu bar's most used window.
        var menuFigure: Double? = 75
        var status = "Current account"
        var reset = "2h 00m"
        var hint: String? = "Exhausts ~1h"
        /// The retained report keeps the reading of a window this read left out.
        var keepsLeftOutWindow = false
        /// The settings keep that window's row.
        var keepsLeftOutRow = false
        /// Whose earlier sessions the retained report keeps.
        var keptSessions: [String] = []
    }

    @MainActor
    func testWhatEachSurfaceMakesOfACodexWindowReading() throws {
        let failedAccount = AccountObservation(account: account, home: "pi", observedAt: now.addingTimeInterval(-3600), isCurrent: false,
                                               quotaNotice: "offline")
        let cases: [(String, Reading, Gates)] = [
            ("a fresh reading", Reading(), Gates()),
            // The reset column passes over the vendor's notice. A reading without a level enters neither the menu figure nor
            // a hint, and the kept report and the settings both keep the window a failed read left out.
            ("the vendor's read failed", Reading(sourceNotices: ["Codex": "offline"], quotaNotices: ["Codex": "offline"]),
             Gates(notice: "offline", level: nil, startsAlerts: false, startsCredits: false, menuFigure: nil, status: "Last read 1m ago",
                   hint: nil, keepsLeftOutWindow: true, keepsLeftOutRow: true, keptSessions: ["Codex"])),
            // A notice about the vendor's logs holds nothing back.
            ("only the vendor's logs could not be read", Reading(sourceNotices: ["Codex": "logs unreadable"]), Gates()),
            ("a report that does not tell quota notices apart", Reading(sourceNotices: ["Codex": "offline"], quotaNotices: nil),
             Gates(notice: "offline", level: nil, startsAlerts: false, startsCredits: false, menuFigure: nil, status: "Last read 1m ago",
                   hint: nil, keepsLeftOutWindow: true, keepsLeftOutRow: true, keptSessions: ["Codex"])),
            ("the account's read failed", Reading(accountNotice: "offline"),
             Gates(notice: "offline", level: nil, startsAlerts: false, startsCredits: false, menuFigure: nil, status: "Last read 1m ago",
                   hint: nil, keepsLeftOutWindow: true, keepsLeftOutRow: true)),
            ("an earlier version's report that files the account's failure under the account's id",
             Reading(accountNotice: "offline", sourceNotices: [account.id: "offline"], quotaNotices: [account.id: "offline"]),
             Gates(notice: "offline", level: nil, startsAlerts: false, startsCredits: false, menuFigure: nil, status: "Last read 1m ago",
                   hint: nil, keepsLeftOutWindow: true, keepsLeftOutRow: true)),
            ("an earlier version's report that files a failed login under Codex login",
             Reading(sourceNotices: ["Codex login": "offline"], quotaNotices: ["Codex login": "offline"]),
             Gates()),
            // Filed under "Pi", the notice keeps the Pi client's earlier sessions as if its own read had failed.
            ("an earlier version's report that files a failed Pi login under Pi", Reading(sourceNotices: ["Pi": "offline"], quotaNotices: ["Pi": "offline"]),
             Gates(keptSessions: ["Pi"])),
            ("the account's read failed in a client home it has left", Reading(otherHomes: [failedAccount]), Gates()),
            ("a reading 29:59 old", Reading(age: 1799), Gates()),
            // A reading keeps its level however old; alerts and reset credits need one under 30 minutes old.
            ("a reading 30:00 old", Reading(age: 1800), Gates(startsAlerts: false, startsCredits: false)),
            ("a reading two hours old", Reading(age: 7200), Gates(startsAlerts: false, startsCredits: false, status: "Current account")),
            // A reading from the future is used nowhere.
            ("a reading 60 s in the future", Reading(age: -60),
             Gates(level: nil, startsAlerts: false, startsCredits: false, menuFigure: nil, hint: nil)),
            ("a reset that has passed", Reading(resetIn: -60), Gates(level: nil, startsAlerts: false, menuFigure: nil, reset: "Pending update",
                                                                     hint: nil)),
            // Running out after the reset, the hint gives the share used by then.
            ("a reset under a minute away", Reading(resetIn: 30), Gates(reset: "<1m", hint: "75% by reset")),
            ("no reset and a full window", Reading(remaining: 100, resetIn: nil),
             Gates(level: .ok, menuFigure: 0, reset: "—", hint: nil)),
            // Without a reset, only a full window is an alert baseline.
            ("no reset and a half-used window", Reading(remaining: 50, resetIn: nil),
             Gates(level: .ok, startsAlerts: false, menuFigure: 50, reset: "—", hint: nil)),
        ]
        let store = try makeStore([window])
        let settings = try makeSettings([window, spark])
        for (name, reading, expected) in cases {
            XCTAssertEqual(try gates(reading, store: store, settings: settings), expected, name)
        }
    }

    /// A vendor with several billing pools reads each on its own, so one pool's failed read holds back only its rows.
    @MainActor
    func testABillingPoolAnswersOnlyToItsOwnAccountBesideASiblingPool() throws {
        let pools = ["p", "q"].map {
            BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "scope-" + $0, evidence: .account, entitlement: "kimi-code")
        }
        let rows = pools.map {
            AgentDescriptor(id: $0.windowID("weekly"), vendor: "Kimi", model: "7d", source: "Pi", enabled: true, billingPool: $0,
                            account: ProviderAccount(pool: $0))
        }
        let store = try makeStore(rows)
        // The vendor's own notice is the failed pool's text only where a report does not tell quota notices apart.
        let cases: [(String, [String: String]?, String?)] = [
            ("a report that tells quota notices apart", [:], nil), ("a report that does not", nil, "Kimi pool p: rejected"),
        ]
        for (name, quotaNotices, vendorNotice) in cases {
            let report = UsageReport(generatedAt: now, snapshots: rows.map { snapshot($0, remaining: 25, at: now.addingTimeInterval(-60)) },
                sessions: [], discoveredAgents: rows, sourceNotices: ["Kimi": "Kimi pool p: rejected"], quotaNotices: quotaNotices,
                activeQuotaPoolIDs: ["Kimi": Set(pools.map(\.id))], accounts: ["Kimi": [
                    AccountObservation(account: ProviderAccount(pool: pools[0]), observedAt: now.addingTimeInterval(-60), quotaNotice: "rejected"),
                    AccountObservation(account: ProviderAccount(pool: pools[1]), observedAt: now.addingTimeInterval(-60)),
                ]])
            show(report, in: store)
            var alerts = QuotaAlertTracker()
            _ = alerts.update(report: report, agents: rows, now: now)
            let crossed = alerts.update(report: nextReading(of: rows), agents: rows, now: later).criticalAgentIDs
            XCTAssertEqual(rows.map { report.quotaNotice(for: $0) }, ["rejected", nil], name)
            XCTAssertEqual(report.quotaNotice(vendor: "Kimi"), vendorNotice, name)
            XCTAssertEqual(store.rows.map(\.level), [nil, .warning], name)
            XCTAssertEqual(rows.map { crossed.contains($0.id) }, [false, true], name)
            XCTAssertEqual(store.rows.map { row in row.account.map { store.accountLabel(for: $0) } }, ["Last read 1m ago", "Current account"], name)
        }
    }

    /// A reset alert lists the account's other windows that are exhausted until a later reset, among those whose readings
    /// show a level: however old, but not from the future.
    func testAResetAlertNamesExhaustedSiblingsWhateverTheirReadingsAge() {
        let weekly = AgentDescriptor(id: account.windowID("codex:codex:secondary"), vendor: "Codex", model: "Weekly", source: "",
                                     enabled: true, account: account)
        let cases: [(String, UsageSnapshot, [String])] = [
            ("an exhausted sibling", snapshot(weekly, remaining: 0, resetIn: 86400, at: now.addingTimeInterval(-60)), ["Weekly"]),
            ("an exhausted sibling read two hours ago", snapshot(weekly, remaining: 0, resetIn: 86400, at: now.addingTimeInterval(-7200)),
             ["Weekly"]),
            ("an exhausted sibling read in the future", snapshot(weekly, remaining: 0, resetIn: 86400, at: now.addingTimeInterval(60)), []),
            ("an exhausted sibling whose reset has passed", snapshot(weekly, remaining: 0, resetIn: -60, at: now.addingTimeInterval(-60)), []),
            ("an exhausted sibling without a reset", snapshot(weekly, remaining: 0, resetIn: nil, at: now.addingTimeInterval(-60)), []),
            ("a sibling with under half a point left", snapshot(weekly, remaining: 0.4, resetIn: 86400, at: now.addingTimeInterval(-60)),
             ["Weekly"]),
            ("a sibling with more than half a point left", snapshot(weekly, remaining: 0.6, resetIn: 86400, at: now.addingTimeInterval(-60)), []),
        ]
        let accounts = ["Codex": [AccountObservation(account: account, observedAt: now.addingTimeInterval(-60))]]
        for (name, sibling, expected) in cases {
            var tracker = QuotaAlertTracker()
            let before = now.addingTimeInterval(-300)
            _ = tracker.update(report: UsageReport(generatedAt: before, snapshots: [snapshot(window, remaining: 50, at: before)], sessions: [],
                                                   accounts: accounts), agents: [window, weekly], now: before)
            let restored = UsageReport(generatedAt: now, snapshots: [snapshot(window, remaining: 100, at: now.addingTimeInterval(-60)), sibling],
                                       sessions: [], accounts: accounts)
            let alerts = tracker.update(report: restored, agents: [window, weekly], now: now).alerts
            XCTAssertEqual(alerts.map(\.kind), [.reset], name)
            XCTAssertEqual(alerts.first?.otherExhaustedWindows.map(\.name), expected, name)
        }
    }

    /// An API balance takes its place in the glow between the quota rows around it, by the rules of a quota window: a
    /// balance whose read failed, or one read in the future, has no level and leaves the glow.
    @MainActor
    func testABalanceBetweenTwoQuotaRowsFollowsTheQuotaRules() throws {
        let (rows, store) = try balanceStore()
        func billing(_ total: Decimal, currency: String = "CNY", isAvailable: Bool? = true, age: TimeInterval = 60,
                     notice: String? = nil) -> APIBilling {
            APIBilling(vendor: "DeepSeek", balances: [AccountBalance(currency: currency, total: total, granted: 0, toppedUp: total)],
                       isAvailable: isAvailable, updatedAt: now.addingTimeInterval(-age), notice: notice)
        }
        let cases: [(String, APIBilling, [StatusLevel])] = [
            ("a fresh balance above its warning line", billing(50), [.warning, .ok, .ok]),
            ("a balance at its warning line", billing(10), [.warning, .warning, .ok]),
            ("an empty balance", billing(0), [.warning, .critical, .ok]),
            ("a balance the service marks unavailable", billing(50, isAvailable: false), [.warning, .critical, .ok]),
            ("an unavailable account without an amount",
             APIBilling(vendor: "DeepSeek", balances: [], isAvailable: false, updatedAt: now.addingTimeInterval(-60), notice: nil),
             [.warning, .critical, .ok]),
            ("the last balance kept after a failed read, two hours old", billing(8, age: 7200, notice: "offline"), [.warning, .ok]),
            ("a balance read two hours ago", billing(8, age: 7200), [.warning, .warning, .ok]),
            ("a balance read in the future", billing(8, age: -60), [.warning, .ok]),
            ("a balance in a currency without a warning line", billing(5, currency: "EUR"), [.warning, .ok, .ok]),
            ("a balance whose read never succeeded",
             APIBilling(vendor: "DeepSeek", balances: [], isAvailable: nil, updatedAt: nil, notice: "offline"), [.warning, .ok]),
        ]
        for (name, billing, expected) in cases {
            show(balanceReport(rows, billing: billing), in: store)
            XCTAssertEqual(store.levels, expected, name)
            XCTAssertEqual(store.maxUsedPct, 75, name)
        }
        XCTAssertEqual(store.rows.map(\.paletteIndex), [0, 1], "the quota rows number their palette colours without the balance")
    }

    /// A pass in which every source failed keeps the last report on screen, but every reading counts as failed: the windows
    /// and the balance lose their colours, and the accounts say when they were last read.
    @MainActor
    func testAPassInWhichEverySourceFailedTakesEveryWindowsColour() throws {
        let (rows, store) = try balanceStore()
        let billing = APIBilling(vendor: "DeepSeek", balances: [AccountBalance(currency: "CNY", total: 8, granted: 0, toppedUp: 8)],
                                 isAvailable: true, updatedAt: now.addingTimeInterval(-60), notice: nil)
        show(balanceReport(rows, billing: billing), in: store)
        XCTAssertEqual(store.levels, [.warning, .warning, .ok])
        store.lastError = "offline"
        XCTAssertEqual(store.levels, [])
        XCTAssertEqual(store.rows.map(\.level), [nil, nil])
        XCTAssertEqual(store.rows.map(\.assessment.status), [.readFailed(reason: "offline"), .readFailed(reason: "offline")])
        XCTAssertEqual(store.rows.compactMap(\.account).map { store.accountLabel(for: $0) }, ["Last read 1m ago", "Last read 1m ago"])
        XCTAssertNil(store.maxUsedPct)
        XCTAssertEqual(store.rows.map { $0.resetLabel(now: now) }, ["2h 00m", "2h 00m"])
        store.lastError = nil
        XCTAssertEqual(store.levels, [.warning, .warning, .ok], "the next pass that reads a source brings them back")
    }

    // MARK: Fixtures

    private var later: Date { now.addingTimeInterval(300) }

    @MainActor
    private func gates(_ reading: Reading, store: UsageStore, settings: SettingsStore) throws -> Gates {
        let at = now.addingTimeInterval(-reading.age)
        let report = UsageReport(generatedAt: now, snapshots: [snapshot(window, remaining: reading.remaining, resetIn: reading.resetIn, at: at)],
            sessions: [], discoveredAgents: [window], insightsByAgent: [window.id: insights],
            sourceNotices: reading.sourceNotices, quotaNotices: reading.quotaNotices,
            accounts: ["Codex": [AccountObservation(account: account, label: "a@example.com", observedAt: at, isCurrent: reading.isCurrent,
                                                    quotaNotice: reading.accountNotice, resetCredits: credits(1), quotaWindowIDs: [window.id])] + reading.otherHomes])
        show(report, in: store)
        let row = try XCTUnwrap(store.rows.first)
        var alerts = QuotaAlertTracker(), resets = ResetCreditTracker()
        _ = alerts.update(report: report, agents: [window], now: now)
        _ = resets.update(report: report, now: now)
        let next = nextReading(of: [window])
        settings.updateAgents { _ in [window, spark] }
        settings.mergeDiscovered(from: report)
        let retained = report.retainingReadings(from: earlier)
        return Gates(notice: report.quotaNotice(for: window), level: row.level,
                     startsAlerts: !alerts.update(report: next, agents: [window], now: later).criticalAgentIDs.isEmpty,
                     startsCredits: !resets.update(report: next, now: later).isEmpty,
                     menuFigure: store.maxUsedPct, status: row.account.map { store.accountLabel(for: $0) } ?? "no account",
                     reset: row.resetLabel(now: now), hint: store.quotaForecastHint(for: window.id),
                     keepsLeftOutWindow: retained.snapshot(for: spark.id) != nil,
                     keepsLeftOutRow: settings.agents.contains { $0.id == spark.id },
                     keptSessions: retained.sessions.map(\.id).sorted())
    }

    /// The report before the read under test: both windows of the account, and one earlier session each of Codex and of
    /// Pi, whose sessions are named after them.
    private var earlier: UsageReport {
        let at = now.addingTimeInterval(-600)
        let consumers = [AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "gpt-5", source: "", enabled: true),
                         AgentDescriptor(id: "pi-model:kimi-k2", vendor: "Pi", model: "kimi-k2", source: "", enabled: true)]
        return UsageReport(generatedAt: at, snapshots: [window, spark].map { snapshot($0, remaining: 40, at: at) },
            sessions: consumers.map {
                LiveSession(id: $0.vendor, agentId: $0.id, task: "task", terminal: nil, startedAt: at.addingTimeInterval(-3600), endedAt: at,
                            pctOfWindow: nil, tokensIn: 1, tokensOut: 1)
            }, discoveredAgents: [window, spark], consumers: consumers,
            accounts: ["Codex": [AccountObservation(account: account, observedAt: at, resetCredits: credits(1))]])
    }

    /// The next reading of `rows`: fresh, critical and with one more reset credit, so it raises an alert and a grant only
    /// where the reading before it was taken as a baseline.
    private func nextReading(of rows: [AgentDescriptor]) -> UsageReport {
        let accounts = Dictionary(grouping: Set(rows.compactMap(\.account)), by: \.provider).mapValues {
            $0.map { AccountObservation(account: $0, observedAt: later, resetCredits: credits(2)) }
        }
        return UsageReport(generatedAt: later, snapshots: rows.map { snapshot($0, remaining: 5, at: later) }, sessions: [],
                           discoveredAgents: rows, accounts: accounts)
    }

    /// A Codex window with 75% used and a Grok window with 40% used, on either side of a DeepSeek balance.
    @MainActor
    private func balanceStore() throws -> ([AgentDescriptor], UsageStore) {
        let grok = ProviderAccount.identified(provider: "Grok", user: "a@example.com", workspace: nil)!
        let rows = [window,
                    AgentDescriptor(id: "deepseek-model:deepseek-chat", vendor: "DeepSeek", model: "deepseek-chat", source: "", enabled: true),
                    AgentDescriptor(id: grok.windowID("grok"), vendor: "Grok", model: "Grok", source: "", enabled: true, account: grok)]
        return (rows, try makeStore(rows))
    }

    private func balanceReport(_ rows: [AgentDescriptor], billing: APIBilling) -> UsageReport {
        let at = now.addingTimeInterval(-60)
        return UsageReport(generatedAt: now, snapshots: [snapshot(rows[0], remaining: 25, at: at), snapshot(rows[2], remaining: 60, at: at)],
            sessions: [], discoveredAgents: rows, sourceNotices: billing.notice.map { ["DeepSeek": $0] } ?? [:],
            quotaNotices: billing.notice.map { ["DeepSeek": $0] } ?? [:], billing: [billing],
            accounts: Dictionary(grouping: rows.compactMap(\.account), by: \.provider).mapValues {
                $0.map { AccountObservation(account: $0, observedAt: at) }
            })
    }

    /// A reading of a five-hour window taken at `at`, whose reset is `resetIn` from now.
    private func snapshot(_ row: AgentDescriptor, remaining: Double, resetIn: TimeInterval? = 2 * 3600, at: Date) -> UsageSnapshot {
        UsageSnapshot(agentId: row.id, remainingPct: remaining, resetAt: resetIn.map(now.addingTimeInterval), windowDuration: 5 * 3600,
                      updatedAt: at)
    }

    private var insights: UsageInsights {
        UsageInsights(burnRatePctPerHour: 25, timeToExhaust: 3600, weeklyCapHits: 0, weeklyWaitTotal: 0, weeklyWaitLongest: 0,
                      weeklyWaitLongestAt: nil)
    }

    private func credits(_ count: Int) -> CodexResetCredits {
        CodexResetCredits(availableCount: count, credits: nil)
    }

    @MainActor
    private func show(_ report: UsageReport, in store: UsageStore) {
        store.replace(report: report)
        store.now = now
    }

    @MainActor
    private func makeStore(_ agents: [AgentDescriptor]) throws -> UsageStore {
        UsageStore(provider: DemoUsageProvider(), settings: try makeSettings(agents))
    }

    @MainActor
    private func makeSettings(_ agents: [AgentDescriptor]) throws -> SettingsStore {
        let suite = "ReadingGateTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SettingsStore(defaults: defaults, defaultAgents: agents)
    }
}
#endif

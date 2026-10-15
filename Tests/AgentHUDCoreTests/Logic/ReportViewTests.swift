#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// What a report view makes of a report: the same rows, balances, levels, sections, window metrics and sessions the store
/// answers with, as the report, the agent list, the settings and the time change.
@MainActor
final class ReportViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let current = ProviderAccount.identified(provider: "Codex", user: "current@example.com", workspace: nil)!
    private let other = ProviderAccount.identified(provider: "Codex", user: "other@example.com", workspace: nil)!
    private let pools = ["active", "inactive"].map {
        BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: $0, evidence: .account, entitlement: "coding-plan")
    }

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// The store answers as a view built afresh from its report, agent list, settings and time: before any report, after
    /// each of them changes, and on the demo's report.
    @MainActor
    func testTheViewAnswersAsTheStoreWhateverChanges() throws {
        let store = UsageStore(provider: DemoUsageProvider(), settings: try makeSettings(agents))
        assertAgrees(store, "no report")
        let steps: [(String, () -> Void)] = [
            ("a report", { store.replace(report: self.report()); store.now = self.now }),
            ("a report that keeps sightings", {
                store.replace(report: self.report(seen: self.agents.map(\.id).filter { $0 != "claude-weekly" }))
                store.now = self.now
            }),
            ("a row switched off", { store.settings.setAgent(id: "claude-session", enabled: false) }),
            ("Claude's live status off", { store.settings.update { $0.setLiveStatus(for: "Claude", enabled: false) } }),
            ("half an hour later", { store.now = self.now.addingTimeInterval(1801) }),
        ]
        for (name, step) in steps {
            step()
            assertAgrees(store, name)
        }
        let demo = UsageStore(provider: DemoUsageProvider(), settings: try makeSettings(DemoData.agents))
        demo.replace(report: DemoUsageProvider.report(agents: DemoData.agents, historyHours: UsageStore.historyHours, now: now))
        demo.now = now
        assertAgrees(demo, "the demo")
    }

    /// Without a consumer or a settings row, a session takes its vendor from a row of the report before its id's prefix.
    /// A session read from a copy, such as one an earlier report held, keeps what the copy says.
    func testASessionsVendorFromTheReportsRowsAndACopyOfASession() {
        let session = LiveSession(id: "s", agentId: "custom-model:x", task: "s", terminal: nil, startedAt: now.addingTimeInterval(-hour),
                                  pctOfWindow: nil, tokensIn: 1, tokensOut: 1, observedAt: now.addingTimeInterval(-60))
        let row = AgentDescriptor(id: "custom-model:x", vendor: "Cursor", model: "X", source: "", enabled: true)
        let view = ReportView(report: UsageReport(generatedAt: now, snapshots: [], sessions: [session], discoveredAgents: [row],
                                                  consumers: []), agents: [], settings: Settings(), now: now)
        XCTAssertEqual(view.session("s")?.source.vendor, "Cursor")
        XCTAssertEqual(view.session("s")?.phase.state, .running)
        let ended = LiveSession(id: "s", agentId: "claude-model:opus", task: "s", terminal: nil, startedAt: session.startedAt,
                                endedAt: now.addingTimeInterval(-60), pctOfWindow: nil, tokensIn: 1, tokensOut: 1)
        XCTAssertEqual(view.session(for: ended).source.vendor, "Claude")
        XCTAssertEqual(view.phase(of: ended), SessionPhase(state: .idle, since: ended.endedAt!, validUntil: nil))
    }

    func testVendorLocalNoticesBelongToCurrentAccounts() throws {
        let accounts = ["current", "retained"].map {
            ProviderAccount.identified(provider: "Antigravity", user: $0, workspace: nil)!
        }
        let agents = accounts.map {
            AgentDescriptor(id: $0.windowID("weekly"), vendor: "Antigravity", model: "Weekly", source: "", enabled: true, account: $0)
        }
        let warning = "Some local sessions could not be read; usage may be incomplete"
        let report = UsageReport(generatedAt: now, snapshots: agents.map {
            .init(agentId: $0.id, remainingPct: 100, updatedAt: now)
        }, sessions: [], discoveredAgents: agents, sourceNotices: ["Antigravity": warning], quotaNotices: [:], readingIssues: [:],
            accounts: ["Antigravity": [.init(account: accounts[0], observedAt: now),
                                       .init(account: accounts[1], observedAt: now.addingTimeInterval(-420), isCurrent: false)]])
        let view = ReportView(report: report, agents: agents, settings: Settings(), now: now)
        let sections = view.accountSections(view.rows)

        XCTAssertEqual(sections.map { view.accountNotice(for: $0) }, [warning])
        XCTAssertEqual(view.rows.map(\.usedPct), [0], "a local notice keeps the current account's quota reading")
        XCTAssertEqual(view.rows.map(\.level), [.ok])
        XCTAssertEqual(sections.compactMap(\.account).map(\.account), [accounts[0]], "former accounts do not create quota sections")
    }

    func testAccountNoticesKeepClientHomeAndAccountScope() {
        let claude = ["first", "second", "retained-home", "retained-account"].map {
            ProviderAccount.identified(provider: "Claude", user: $0, workspace: nil)!
        }
        let observations = [
            AccountObservation(account: claude[0], home: "first-home", observedAt: now),
            AccountObservation(account: claude[1], home: "second-home", observedAt: now),
            AccountObservation(account: claude[2], home: "old-home", observedAt: now, isCurrent: false,
                               readingIssue: .readFailed("Old home read failed")),
            AccountObservation(account: claude[3], observedAt: now, isCurrent: false,
                               readingIssue: .readFailed("Account read failed")),
            AccountObservation(account: ProviderAccount(pool: pools[0]), observedAt: now,
                               readingIssue: .readFailed("Pool read failed")),
            AccountObservation(account: ProviderAccount(pool: pools[1]), observedAt: now),
        ]
        let agents = observations.map {
            AgentDescriptor(id: $0.account.windowID("weekly"), vendor: $0.account.provider, model: "Weekly", source: "",
                            enabled: true, account: $0.account)
        }
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents,
            sourceNotices: ["Claude": "Some local sessions could not be read",
                            ClientHome.sourceKey(provider: "Claude", home: "first-home"): "First home logs could not be read",
                            ClientHome.sourceKey(provider: "Claude", home: "old-home"): "Old home read failed · Logs incomplete",
                            "Kimi": "Another pool failed"],
            quotaNotices: [:], readingIssues: [:], accounts: ["Claude": Array(observations.prefix(4)), "Kimi": Array(observations.suffix(2))])
        let view = ReportView(report: report, agents: agents, settings: Settings(), now: now)

        XCTAssertEqual(view.accountSections(view.rows).map { view.accountNotice(for: $0) }, [
            "First home logs could not be read", "Some local sessions could not be read",
            "Pool read failed", nil,
        ])
    }

    // MARK: Fixtures

    /// Every kind of row: two Claude windows and one switched off, an API row, two Kimi plan pools of which the report
    /// lists one as active, and Codex windows of the current account and another one.
    private var agents: [AgentDescriptor] {
        [AgentDescriptor(id: "claude-session", vendor: "Claude", model: "5h", source: "", enabled: true),
         AgentDescriptor(id: "claude-weekly", vendor: "Claude", model: "Weekly", source: "", enabled: true),
         AgentDescriptor(id: "claude-opus", vendor: "Claude", model: "Opus", source: "", enabled: false),
         AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true)]
        + pools.map {
            AgentDescriptor(id: $0.windowID("weekly"), vendor: "Kimi", model: "Weekly", source: "", enabled: true, billingPool: $0,
                            account: ProviderAccount(pool: $0))
        }
        + [current, other].map { AgentDescriptor(id: $0.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: $0) }
    }

    /// Readings fresh and stale, a pool whose read failed, a notice about Codex's hooks, a low balance, a window whose tokens
    /// are counted, and sessions running, waiting, out of date, finished, from the future and without a vendor.
    private func report(seen: [String]? = nil) -> UsageReport {
        func snapshot(_ id: String, _ remaining: Double, resetIn: TimeInterval, duration: TimeInterval, age: TimeInterval) -> UsageSnapshot {
            UsageSnapshot(agentId: id, remainingPct: remaining, resetAt: now.addingTimeInterval(resetIn), windowDuration: duration,
                          updatedAt: now.addingTimeInterval(-age))
        }
        func insights(_ burn: Double, exhaustsIn: TimeInterval) -> UsageInsights {
            UsageInsights(burnRatePctPerHour: burn, timeToExhaust: exhaustsIn, weeklyCapHits: 0, weeklyWaitTotal: 0, weeklyWaitLongest: 0,
                          weeklyWaitLongestAt: nil)
        }
        func session(_ id: String, _ agent: String, ended: TimeInterval? = nil, observed: TimeInterval) -> LiveSession {
            LiveSession(id: id, agentId: agent, task: id, terminal: nil, startedAt: now.addingTimeInterval(-5 * hour),
                        endedAt: ended.map(now.addingTimeInterval), pctOfWindow: nil, tokensIn: 1, tokensOut: 1,
                        observedAt: now.addingTimeInterval(observed))
        }
        func turn(_ session: String, _ provider: String, _ state: SessionTurn.State, started: TimeInterval?, observed: TimeInterval,
                  message: String? = nil) -> SessionTurn {
            SessionTurn(provider: provider, sessionID: session, turnID: session + String(observed), state: state,
                        startedAtMs: started.map { RecordCoding.milliseconds(now.addingTimeInterval($0)) },
                        observedAtMs: RecordCoding.milliseconds(now.addingTimeInterval(observed)), message: message)
        }
        let codex = [current, other].map { $0.windowID("codex") }
        let consumers = [("claude-model:opus", "Claude"), ("codex-model:gpt-5", "Codex"), ("grok-model:4", "Grok")].map {
            AgentDescriptor(id: $0.0, vendor: $0.1, model: $0.0, source: "", enabled: true)
        }
        return UsageReport(
            generatedAt: now,
            snapshots: [snapshot("claude-session", 40, resetIn: 2 * hour, duration: 5 * hour, age: 60),
                        snapshot("claude-weekly", 5, resetIn: 72 * hour, duration: 168 * hour, age: 2400),
                        snapshot(pools[0].windowID("weekly"), 50, resetIn: 24 * hour, duration: 168 * hour, age: 60),
                        snapshot(codex[0], 25, resetIn: hour, duration: 5 * hour, age: 60),
                        snapshot(codex[1], 70, resetIn: 3 * hour, duration: 5 * hour, age: 600)],
            sessions: [session("running", "claude-model:opus", observed: -60), session("waiting", "codex-model:gpt-5", observed: -30),
                       session("unvouched", "claude-model:opus", observed: -2 * hour),
                       session("ended", "grok-model:4", ended: -3 * hour, observed: -3 * hour),
                       session("future", "claude-model:opus", observed: 60), session("vendorless", "mystery-model:x", observed: -90)],
            discoveredAgents: agents, consumers: consumers,
            usage: [-4 * hour, -2 * hour, -hour].map { UsageBucket(start: now.addingTimeInterval($0), agentId: "claude-model:opus", tokensIn: 3000, tokensOut: 0) },
            insightsByAgent: ["claude-session": insights(10, exhaustsIn: 4 * hour), codex[0]: insights(25, exhaustsIn: hour)],
            subscriptions: ["Claude": "max", "Codex": "pro", "Grok": "super"],
            sourceNotices: ["Codex": "Codex hooks could not be read"], quotaNotices: [:],
            consumerIdsByQuota: ["claude-session": ["claude-model:opus"]],
            billing: [APIBilling(vendor: "DeepSeek", balances: [AccountBalance(currency: "CNY", total: 5, granted: 0, toppedUp: 5)],
                                 isAvailable: true, updatedAt: now, notice: nil)],
            turns: [turn("running", "claude", .completed, started: -4 * hour, observed: -3 * hour, message: "Done"),
                    turn("running", "claude", .running, started: -600, observed: -60),
                    turn("waiting", "codex", .waitingForApproval, started: -300, observed: -30, message: "Allow?"),
                    turn("unvouched", "claude", .running, started: nil, observed: -2 * hour),
                    turn("ended", "grok", .completed, started: -4 * hour, observed: -3 * hour + 10, message: "Finished"),
                    turn("ended", "claude", .running, started: -hour, observed: -hour),
                    turn("vendorless", "codex", .waitingForApproval, started: -600, observed: -120, message: "Allow the edit?")],
            activeQuotaPoolIDs: ["Kimi": [pools[0].id]],
            accounts: ["Codex": [AccountObservation(account: current, observedAt: now), AccountObservation(account: other, observedAt: now, isCurrent: false)],
                       "Kimi": [AccountObservation(account: ProviderAccount(pool: pools[0]), observedAt: now, quotaNotice: "rejected"),
                                AccountObservation(account: ProviderAccount(pool: pools[1]), observedAt: now)]],
            rowSeenAt: seen.map { Dictionary(uniqueKeysWithValues: $0.map { ($0, now) }) })
    }

    /// Compares the store's answers with those of a view built afresh from its report, agent list, settings and time.
    @MainActor
    private func assertAgrees(_ store: UsageStore, _ name: String) {
        let view = ReportView(report: store.report, agents: store.settings.agents, settings: store.settings.settings, now: store.now)
        XCTAssertEqual(view.visibleAgents, store.visibleAgents, name)
        XCTAssertEqual(view.enabledAgents, store.enabledAgents, name)
        XCTAssertEqual(view.rows, store.rows, name)
        XCTAssertEqual(view.rowGroups.map(\.vendor), store.rowGroups.map(\.vendor), name)
        XCTAssertEqual(view.rowGroups.map(\.rows), store.rowGroups.map(\.rows), name)
        XCTAssertEqual(view.billing, store.enabledBilling, name)
        XCTAssertEqual(view.levels, store.levels, name)
        XCTAssertEqual(view.alertPulseVendors, store.alertPulseVendors, name)
        XCTAssertEqual(view.maxUsedPct, store.maxUsedPct, name)
        XCTAssertEqual(view.subscriptions, store.subscriptions, name)
        for group in store.rowGroups {
            let sections = view.accountSections(group.rows), expected = store.accountSections(group.rows)
            XCTAssertEqual(sections.map(\.id), expected.map(\.id), name)
            XCTAssertEqual(sections.map(\.account), expected.map(\.account), name)
            XCTAssertEqual(sections.map(\.isCurrent), expected.map(\.isCurrent), name)
            XCTAssertEqual(sections.map(\.rows), expected.map(\.rows), name)
            XCTAssertEqual(sections.map { view.accountNotice(for: $0) }, expected.map { store.accountNotice(for: $0) }, name)
        }
        for row in store.rows {
            XCTAssertEqual(view.tokensPerHour(for: row.id), store.quotaTokensPerHour(for: row.id), name)
            XCTAssertEqual(view.forecastHint(for: row.id), store.quotaForecastHint(for: row.id), name)
            XCTAssertEqual(view.outlook(for: row.id), store.report?.snapshot(for: row.id).flatMap {
                row.assessment.showsLevel ? QuotaMath.outlook(snapshot: $0, insights: store.report?.insightsByAgent[row.id], now: store.now) : nil
            }, name)
        }
        XCTAssertEqual(view.sessions.map(\.session), store.sessions, name)
        XCTAssertEqual(view.liveSessions.map(\.session), store.liveSessions, name)
        XCTAssertEqual(view.workingVendors, store.workingVendors, name)
        XCTAssertEqual(view.queueVendors.map(\.vendor), store.queueVendors.map(\.vendor), name)
        XCTAssertEqual(view.queueVendors.map(\.isWorking), store.queueVendors.map(\.isWorking), name)
        for session in store.sessions {
            let shown = view.session(for: session)
            XCTAssertEqual(view.session(session.id), shown, name)
            XCTAssertEqual(shown.source, store.sessionSource(session), "\(name): \(session.id)")
            XCTAssertEqual(shown.turn?.state, store.sessionState(session), "\(name): \(session.id)")
            XCTAssertEqual(shown.message, store.sessionMessage(session), "\(name): \(session.id)")
            XCTAssertEqual(shown.liveStatus, store.liveStatusEnabled(for: session), "\(name): \(session.id)")
            XCTAssertEqual(shown.phase.isInFlight, store.isSessionLive(session), "\(name): \(session.id)")
            XCTAssertEqual(shown.phase.state == .waitingForApproval, store.isSessionWaiting(session), "\(name): \(session.id)")
            XCTAssertEqual(shown.lastEventAt, session.lastEvent(turnAt: store.report?.turns.filter { $0.sessionID == session.id }
                .map { RecordCoding.date($0.observedAtMs) }.max()), "\(name): \(session.id)")
        }
    }

    @MainActor
    private func makeSettings(_ agents: [AgentDescriptor]) throws -> SettingsStore {
        let suite = "ReportViewTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SettingsStore(defaults: defaults, defaultAgents: agents)
    }
}
#endif

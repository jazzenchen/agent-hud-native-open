#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// What the store makes of a session: whether it is live or blocked on the user, its state, label and last message, the
/// lists and vendors it counts in, whether anything is in flight, and how sessions are ordered and given a vendor.
final class SessionViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    /// A quota row with a fresh reading, so that the glow has a colour and breathes.
    private let quotaRow = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "5h", source: "", enabled: true)
    private let consumers = [
        AgentDescriptor(id: "claude-model:opus", vendor: "Claude", model: "Opus", source: "", enabled: true),
        AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: true),
        AgentDescriptor(id: "grok-model:4", vendor: "Grok", model: "4", source: "", enabled: true),
        AgentDescriptor(id: "pi-model:k2", vendor: "Pi", model: "K2", source: "", enabled: true),
        AgentDescriptor(id: "deepseek-model:v4", vendor: "DeepSeek", model: "V4", source: "", enabled: true),
    ]

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// The newest turn reported for the session. Every kind but `none` follows an older finished turn, which carries the
    /// session's last message; the newest carries none.
    private enum Newest: CaseIterable {
        case none, running, runningWithoutStart, waiting, completed, ended

        var state: SessionTurn.State? {
            switch self {
            case .none: return nil
            case .running, .runningWithoutStart: return .running
            case .waiting: return .waitingForApproval
            case .completed: return .completed
            case .ended: return .ended
            }
        }
    }

    /// What the store says about one session.
    private struct Answers: Equatable {
        var live: Bool
        var waiting: Bool
        var state: SessionTurn.State?
        var label: String
        var message: String?
        var liveSessions: [String]
        var hasLiveSession: Bool
        var workingVendors: Set<String>
    }

    /// A Claude session that started five hours ago, has ended two hours ago unless the source still has it in flight,
    /// and was last read `age` seconds ago; its newest turn started three hours ago and was heard from half an hour later.
    @MainActor
    func testWhatTheStoreSaysAboutASessionByLiveStatusSourceReadingAgeAndNewestTurn() throws {
        let store = try makeStore()
        let running = "5h 00m running", ended = "ended 2h ago", off = "Live status off"
        func same(_ label: String) -> [String] { Array(repeating: label, count: Newest.allCases.count) }
        // Live status, whether the source has the session in flight and how old its reading is; then whether the session
        // is live, and its label with each newest turn in the order of `Newest.allCases`. In flight, the label counts from
        // the turn's start, else from the session's.
        let rows: [(liveStatus: Bool, inFlight: Bool, age: TimeInterval, live: Bool, labels: [String])] = [
            (true, true, 1799.999, true, [running, "3h 00m running", running, "Needs approval", running, running]),
            (true, true, 1800, false, same("Status out of date")),
            (true, false, 1799.999, false, same(ended)),
            (true, false, 1800, false, same(ended)),
            (false, true, 1799.999, false, same(off)),
            (false, true, 1800, false, same(off)),
            (false, false, 1799.999, false, same(off)),
            (false, false, 1800, false, same(off)),
        ]
        for row in rows {
            store.settings.update { $0.setLiveStatus(for: "Claude", enabled: row.liveStatus) }
            for (newest, label) in zip(Newest.allCases, row.labels) {
                let session = session("s", ended: row.inFlight ? nil : -2 * hour, observed: -row.age)
                show([session], turns: turns(of: "s", newest: newest), in: store)
                // A waiting turn blocks only a live session; the state comes from the turns whatever else holds, the
                // message too unless live status is off, and everything that counts live sessions follows whether this one
                // is live.
                let expected = Answers(live: row.live, waiting: row.live && newest == .waiting, state: newest.state, label: label,
                                       message: newest == .none || !row.liveStatus ? nil : "Earlier answer", liveSessions: row.live ? ["s"] : [],
                                       hasLiveSession: row.live, workingVendors: row.live ? ["Claude"] : [])
                XCTAssertEqual(answers(session, in: store), expected, "\(row) with the newest turn \(newest)")
            }
        }
    }

    /// Newest last event first, then by id. A session without turns is dated by its end, or while in flight by the reading
    /// that last saw it, one from the future included; a session with turns by its newest turn of any provider.
    @MainActor
    func testSessionsAreOrderedByTheirLastEventThenById() throws {
        let store = try makeStore()
        let future = session("future", observed: 60), other = session("other-provider-turn", ended: -5000, observed: -5000)
        show([
            session("b-ended", ended: -600, observed: -600),
            session("a-ended", ended: -600, observed: -600),
            session("turnless", observed: -300),
            session("unvouched", observed: -2 * hour),
            future,
            session("turn-older-than-reading", observed: -30),
            other,
        ], turns: [
            turn("turn-older-than-reading", .running, started: -1200, observed: -1000),
            turn("other-provider-turn", .waitingForApproval, provider: "codex", started: -300, observed: -200, message: "Allow?"),
        ], in: store)
        XCTAssertEqual(store.sessions.map(\.id), ["future", "other-provider-turn", "turnless", "a-ended", "b-ended",
                                                  "turn-older-than-reading", "unvouched"])
        XCTAssertEqual(store.liveSessions.map(\.id), ["future", "turnless", "turn-older-than-reading"])
        XCTAssertEqual(store.sessionStatusLabel(future), "5h 00m running", "a reading from the future still vouches for the session")
        XCTAssertEqual([store.sessionState(other).map(\.rawValue), store.sessionMessage(other)], [nil, nil],
                       "another provider's turn dates a Claude session but gives it no state or message")
    }

    /// A session's newest turn is the one that started last, a turn without a start counting from when it was observed,
    /// then the one observed last, and of equals the later listed, whatever order its client listed them in; the message
    /// is the newest turn's that carries one. Sessions whose last events are equal go by vendor, then id.
    @MainActor
    func testTheNewestTurnStartedLastAndEqualLastEventsGoByVendorThenId() throws {
        let store = try makeStore()
        show([session("started-earlier", observed: -30), session("startless", observed: -30), session("tied", observed: -30),
              session("heard-later", observed: -30), session("a-codex", agent: "codex-model:gpt-5", ended: -600, observed: -600),
              session("b-claude", ended: -600, observed: -600)], turns: [
            turn("started-earlier", .running, id: "a", started: -100, observed: -50, message: "Newer"),
            turn("started-earlier", .completed, id: "b", started: -200, observed: -40, message: "Older"),
            turn("startless", .completed, id: "a", started: -300, observed: -250),
            turn("startless", .running, id: "b", started: nil, observed: -100),
            turn("tied", .completed, id: "a", started: -100, observed: -50, message: "First"),
            turn("tied", .completed, id: "b", started: -100, observed: -50, message: "Second"),
            turn("heard-later", .running, id: "a", started: -100, observed: -20),
            turn("heard-later", .completed, id: "b", started: -100, observed: -60),
        ], in: store)
        let view = store.view
        XCTAssertEqual(["started-earlier", "startless", "tied", "heard-later"].map { view.session($0)?.turn?.turnID }, ["a", "b", "b", "a"])
        XCTAssertEqual(view.session("started-earlier")?.message, "Newer")
        XCTAssertEqual(view.session("tied")?.message, "Second")
        XCTAssertEqual(view.session("heard-later")?.phase.state, .running)
        XCTAssertEqual(store.sessions.suffix(2).map(\.id), ["b-claude", "a-codex"])
    }

    /// The logo queue lists every row's vendor, once per row, then the vendors of sessions whose last event is at most a
    /// day old, when their live status is on and a vendor is known. A session still running whose last event is older
    /// counts as working without a place in the queue.
    @MainActor
    func testTheLogoQueueAddsTheVendorsOfSessionsActiveWithinADay() throws {
        let weekly = AgentDescriptor(id: "claude-weekly", vendor: "Claude", model: "Weekly", source: "", enabled: true)
        let store = try makeStore(agents: [quotaRow, weekly])
        store.settings.update { $0.setLiveStatus(for: "Pi", enabled: false) }
        show([
            session("edge", agent: "codex-model:gpt-5", started: -25 * hour, ended: -24 * hour, observed: -24 * hour),
            session("late", agent: "grok-model:4", started: -25 * hour, ended: -24 * hour - 0.001, observed: -24 * hour),
            session("off", agent: "pi-model:k2", ended: -hour, observed: -hour),
            session("unknown", agent: "mystery-model:x", ended: -hour, observed: -hour),
            session("old-turn", agent: "deepseek-model:v4", started: -26 * hour, observed: -60),
        ], turns: [turn("old-turn", .running, provider: "deepseek", started: -26 * hour, observed: -25 * hour)], in: store)
        XCTAssertEqual(store.queueVendors.map(\.vendor), ["Claude", "Claude", "Codex"])
        XCTAssertEqual(store.queueVendors.map(\.isWorking), [false, false, false])
        XCTAssertEqual(store.workingVendors, ["DeepSeek"])
    }

    /// The week's list keeps every session whose last event is at most seven days old, and drops one a millisecond older;
    /// a session the island shows live is on it whenever it started.
    @MainActor
    func testTheWeekListKeepsSessionsWhoseLastEventIsAtMostSevenDaysOld() throws {
        let store = try makeStore()
        let week = 7 * 24 * hour
        show([
            session("ends-at-start", started: -week - hour, ended: -week, observed: -week),
            session("ends-before", started: -week - hour, ended: -week - 0.001, observed: -week),
            session("starts-at-end", started: 0, observed: 0),
            session("starts-after", started: 0.001, observed: 0.001),
        ], in: store)
        XCTAssertEqual(store.statsSessions.map(\.id), ["starts-after", "starts-at-end", "ends-at-start"])
        XCTAssertEqual(store.liveSessions.map(\.id), ["starts-after", "starts-at-end"])
    }

    /// A session's vendor is its consumer's, else that of a settings row with its id, switched off or not, else the one
    /// its id implies; a session nothing names has none.
    @MainActor
    func testASessionsVendorComesFromItsConsumerASettingsRowOrItsId() throws {
        let store = try makeStore(agents: [
            AgentDescriptor(id: "custom-row", vendor: "Cursor", model: "Pro", source: "", enabled: false),
            AgentDescriptor(id: "claude-model:proxy", vendor: "Grok", model: "Proxy", source: "", enabled: true),
        ])
        let sessions = [("consumer", "claude-model:proxy"), ("row", "custom-row"), ("prefix", "deepseek-model:v4"), ("none", "mystery-model:x")]
            .map { session($0.0, agent: $0.1, observed: -60) }
        show(sessions, consumers: [AgentDescriptor(id: "claude-model:proxy", vendor: "Codex", model: "Proxy", source: "", enabled: true)],
             in: store)
        XCTAssertEqual(sessions.map { store.sessionSource($0).vendor }, ["Codex", "Cursor", "DeepSeek", nil])
    }

    /// A session without a vendor takes the turns of every provider under its id and answers to no live status switch:
    /// with every vendor's switched off, it still shows a Codex approval request and runs the glow, while no vendor counts
    /// as working. A Claude session with the same kind of turn ignores it.
    @MainActor
    func testASessionWithoutAVendorTakesAnyProvidersTurn() throws {
        let store = try makeStore()
        for vendor in SessionSource.agentVendors { store.settings.update { $0.setLiveStatus(for: vendor, enabled: false) } }
        let vendorless = session("vendorless", agent: "mystery-model:x", observed: -60)
        let named = session("named", observed: -60)
        show([vendorless, named], turns: ["vendorless", "named"].map {
            turn($0, .waitingForApproval, provider: "codex", started: -600, observed: -120, message: "Allow the edit?")
        }, in: store)
        XCTAssertEqual(answers(vendorless, in: store), Answers(
            live: true, waiting: true, state: .waitingForApproval, label: "Needs approval", message: "Allow the edit?",
            liveSessions: ["vendorless"], hasLiveSession: true, workingVendors: []))
        XCTAssertEqual(answers(named, in: store), Answers(
            live: false, waiting: false, state: nil, label: "Live status off", message: nil,
            liveSessions: ["vendorless"], hasLiveSession: true, workingVendors: []))
    }

    /// A session whose client waits for an answer to a permission request waits for approval for as long as the client
    /// waits, however its source reads it: since its turn in flight started, else since its own start, with the request as
    /// its last event. With live status off it shows no state, and once the client stops waiting the source decides again.
    @MainActor
    func testAPermissionRequestWaitingForAnAnswerMarksItsSessionWaitingForApproval() throws {
        let store = try makeStore()
        store.settings.update { $0.setLiveStatus(for: "Claude", enabled: false) }
        // The demo's requests: Claude's session demo-1 asked 38 s ago, Codex's demo-2 124 s ago and CodeBuddy's demo-3 71 s ago.
        PermissionRequests.shared.seedDemo(now: now)
        defer { for request in PermissionRequests.shared.pending { PermissionRequests.shared.withdraw(request.id) } }
        let codex = session("demo-2", agent: "codex-model:gpt-5", observed: -30)
        let buddy = session("demo-3", agent: "codebuddy-model:x", ended: -300, observed: -300)
        let claude = session("demo-1", observed: -30)
        show([codex, buddy, claude], turns: [turn("demo-2", .running, provider: "codex", started: -600, observed: -200)], in: store)
        let view = store.view
        XCTAssertEqual(view.session("demo-2")?.phase, SessionPhase(state: .waitingForApproval, since: now.addingTimeInterval(-600), validUntil: nil))
        XCTAssertEqual(view.session("demo-2")?.lastEventAt, now.addingTimeInterval(-124))
        XCTAssertEqual(view.session("demo-3")?.phase, SessionPhase(state: .waitingForApproval, since: buddy.startedAt, validUntil: nil),
                       "a client whose records never say it works still waits")
        XCTAssertEqual(view.session("demo-3")?.lastEventAt, now.addingTimeInterval(-71))
        XCTAssertEqual([codex, buddy, claude].map(store.sessionStatusLabel), ["Needs approval", "Needs approval", "Live status off"])
        XCTAssertEqual(store.liveSessions.map(\.id), ["demo-3", "demo-2"])
        XCTAssertEqual(store.workingVendors, ["Codex", "CodeBuddy"])

        for request in PermissionRequests.shared.pending { PermissionRequests.shared.withdraw(request.id) }
        XCTAssertEqual(store.view.session("demo-2")?.phase.state, .running)
        XCTAssertEqual(store.view.session("demo-3")?.phase.state, .idle)
    }

    /// The turns a host's hooks saw take the place of what the logs say wherever the hooks saw more: a Stop hook ends a turn
    /// the log still has running, and a prompt starts one the log has not shown, vouched for half an hour from the prompt.
    /// Work the log saw after the Stop hook keeps the log's phase, a log still vouched for keeps its phase against a hook
    /// turn past its half hour, and with live status off the hooks change nothing.
    @MainActor
    func testTheHooksTurnsChangeASessionAtTheStopHook() throws {
        let store = try makeStore()
        show([session("stopped", observed: -30), session("prompted", ended: -600, observed: -30), session("busy", observed: -30),
              session("long", observed: -30)], turns: [
            turn("stopped", .running, started: -600, observed: -60),
            turn("prompted", .completed, started: -900, observed: -600),
            turn("busy", .running, started: -600, observed: -10),
            turn("long", .running, started: -2400, observed: -40),
        ], in: store)
        store.hookTurns = [
            "stopped": .init(startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-20), isReportedTurn: true),
            "prompted": .init(startedAt: now.addingTimeInterval(-120), endedAt: nil, isReportedTurn: false),
            "busy": .init(startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-20), isReportedTurn: true),
            "long": .init(startedAt: now.addingTimeInterval(-2400), endedAt: nil, isReportedTurn: true),
        ]
        var view = store.view
        XCTAssertEqual(view.session("stopped")?.phase, SessionPhase(state: .idle, since: now.addingTimeInterval(-20), validUntil: nil))
        XCTAssertEqual(view.session("stopped")?.lastEventAt, now.addingTimeInterval(-20))
        XCTAssertEqual(view.session("prompted")?.phase,
                       SessionPhase(state: .running, since: now.addingTimeInterval(-120), validUntil: now.addingTimeInterval(1680)))
        XCTAssertEqual(view.session("busy")?.phase.state, .running)
        XCTAssertEqual(view.session("long")?.phase,
                       SessionPhase(state: .running, since: now.addingTimeInterval(-2400), validUntil: now.addingTimeInterval(1770)))
        XCTAssertEqual(store.sessions.map(\.id), ["busy", "stopped", "long", "prompted"])

        store.now = now.addingTimeInterval(1680)
        view = store.view
        XCTAssertEqual(view.session("prompted")?.phase, SessionPhase(state: .unverified, since: now.addingTimeInterval(-120), validUntil: nil))
        store.settings.update { $0.setLiveStatus(for: "Claude", enabled: false) }
        XCTAssertEqual(store.view.session("prompted")?.phase.state, .idle)
        XCTAssertEqual(store.view.session("prompted")?.lastEventAt, now.addingTimeInterval(-600))
    }

    /// What the agent said at the Stop hook is the session's message when the hook turn takes the log's place: the hook's
    /// turn is then the newest that carries one. Where the log saw more, the log's message stands, and with live status
    /// off there is none.
    @MainActor
    func testAStopHooksTextIsTheSessionsMessage() throws {
        let store = try makeStore()
        show([session("stopped", observed: -30), session("busy", observed: -30)], turns: [
            turn("stopped", .completed, id: "1", started: -900, observed: -700, message: "Earlier answer"),
            turn("stopped", .running, id: "2", started: -600, observed: -60),
            turn("busy", .running, started: -600, observed: -10, message: "Still working"),
        ], in: store)
        store.hookTurns = [
            "stopped": .init(startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-20), isReportedTurn: true, message: "All done"),
            "busy": .init(startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-20), isReportedTurn: true, message: "Stopped"),
        ]
        XCTAssertEqual(store.view.session("stopped")?.message, "All done")
        XCTAssertEqual(store.view.session("busy")?.message, "Still working")
        store.hookTurns["stopped"]?.message = nil
        XCTAssertEqual(store.view.session("stopped")?.message, "Earlier answer", "a Stop hook without words leaves the newest message")
        store.settings.update { $0.setLiveStatus(for: "Claude", enabled: false) }
        XCTAssertNil(store.view.session("busy")?.message)
    }

    /// A session in flight without turns is dated by when its log last recorded anything, which a read does not move, and
    /// a copy of the session keeps that date.
    @MainActor
    func testATurnlessSessionInFlightIsDatedByItsLogsLastWrite() throws {
        let store = try makeStore()
        let written = LiveSession(id: "written", agentId: "claude-model:opus", task: "written", terminal: nil,
                                  startedAt: now.addingTimeInterval(-hour), pctOfWindow: nil, tokensIn: 1, tokensOut: 1,
                                  observedAt: now.addingTimeInterval(-5), lastActivityAt: now.addingTimeInterval(-90))
        show([written, session("ended", ended: -60, observed: -60)], in: store)
        XCTAssertEqual(store.view.session("written")?.lastEventAt, now.addingTimeInterval(-90))
        XCTAssertEqual(store.sessions.map(\.id), ["ended", "written"], "the latest read does not lift it above a session that ended since")
        XCTAssertEqual(store.sessionStatusLabel(written), "1h 00m running")
        XCTAssertEqual(try JSONDecoder().decode(LiveSession.self, from: JSONEncoder().encode(written)).lastActivityAt, written.lastActivityAt)
    }

    // MARK: Fixtures

    @MainActor
    private func answers(_ session: LiveSession, in store: UsageStore) -> Answers {
        Answers(live: store.isSessionLive(session), waiting: store.isSessionWaiting(session), state: store.sessionState(session),
                label: store.sessionStatusLabel(session), message: store.sessionMessage(session),
                liveSessions: store.liveSessions.map(\.id), hasLiveSession: store.hasLiveSession, workingVendors: store.workingVendors)
    }

    /// The grid's turns: an older finished one with the last message, then the newest.
    private func turns(of session: String, newest: Newest) -> [SessionTurn] {
        guard let state = newest.state else { return [] }
        return [turn(session, .completed, id: "1", started: -5 * hour, observed: -4 * hour, message: "Earlier answer"),
                turn(session, state, id: "2", started: newest == .runningWithoutStart ? nil : -3 * hour, observed: -2.5 * hour)]
    }

    /// Times are seconds from now.
    private func session(_ id: String, agent: String = "claude-model:opus", started: TimeInterval = -5 * 3600, ended: TimeInterval? = nil,
                         observed: TimeInterval) -> LiveSession {
        LiveSession(id: id, agentId: agent, task: id, terminal: nil, startedAt: now.addingTimeInterval(started),
                    endedAt: ended.map { now.addingTimeInterval($0) }, pctOfWindow: nil, tokensIn: 1, tokensOut: 1,
                    observedAt: now.addingTimeInterval(observed))
    }

    private func turn(_ session: String, _ state: SessionTurn.State, id: String = "1", provider: String = "claude", started: TimeInterval?,
                      observed: TimeInterval, message: String? = nil) -> SessionTurn {
        SessionTurn(provider: provider, sessionID: session, turnID: id, state: state,
                    startedAtMs: started.map { RecordCoding.milliseconds(now.addingTimeInterval($0)) },
                    observedAtMs: RecordCoding.milliseconds(now.addingTimeInterval(observed)), message: message)
    }

    @MainActor
    private func show(_ sessions: [LiveSession], turns: [SessionTurn] = [], consumers: [AgentDescriptor]? = nil, in store: UsageStore) {
        store.replace(report: UsageReport(
            generatedAt: now,
            snapshots: [UsageSnapshot(agentId: quotaRow.id, remainingPct: 50, resetAt: now.addingTimeInterval(hour), updatedAt: now)],
            sessions: sessions, discoveredAgents: [quotaRow], consumers: consumers ?? self.consumers, turns: turns))
        store.now = now
    }

    @MainActor
    private func makeStore(agents: [AgentDescriptor]? = nil) throws -> UsageStore {
        let suite = "SessionViewTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: agents ?? [quotaRow]))
    }
}
#endif

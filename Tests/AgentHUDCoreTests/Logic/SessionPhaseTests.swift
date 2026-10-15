#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// A session's phase: what it is on the grid of sessions the store's own tests use, how the store's answers follow it,
/// and when a client's hook turn takes the place of a reading's phase.
@MainActor
final class SessionPhaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// The newest turn reported for the session. Every kind but `none` follows an older finished turn.
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

    /// What a phase counts from.
    private enum Since {
        case sessionStart, turnStart, turnHeard, reading, end
    }

    /// A Claude session that started five hours ago, has ended two hours ago unless the source still has it in flight, and
    /// was last read `age` seconds ago; its newest turn started three hours ago and was heard from half an hour later. In
    /// flight, a phase is vouched for until half an hour after the reading; the store is live exactly while a phase is in
    /// flight, blocked on the user while it waits for approval, and words its label from it.
    @MainActor
    func testThePhaseOnTheSessionGridAndTheStoresAnswers() throws {
        let store = try makeStore()
        let count = Newest.allCases.count
        func same<T>(_ value: T) -> [T] { Array(repeating: value, count: count) }
        // Outside the vouched window a phase counts from the last event: the reading or the end without turns, and with
        // them the later of the turn heard and the end.
        let heard = [Since.reading] + Array(repeating: Since.turnHeard, count: count - 1)
        // Live status, whether the source has the session in flight and how old its reading is; then, with each newest turn
        // in the order of `Newest.allCases`, the phase's state and what it counts from.
        let rows: [(liveStatus: Bool, inFlight: Bool, age: TimeInterval, states: [SessionPhase.State], since: [Since])] = [
            // In flight, from the turn's start, else the session's.
            (true, true, 1799.999, [.running, .running, .running, .waitingForApproval, .running, .running],
             [.sessionStart, .turnStart, .sessionStart, .turnStart, .sessionStart, .sessionStart]),
            (true, true, 1800, same(.unverified), heard),
            (true, false, 1799.999, same(.idle), same(.end)),
            (true, false, 1800, same(.idle), same(.end)),
            // With live status off, the last event.
            (false, true, 1799.999, same(.idle), heard),
            (false, true, 1800, same(.idle), heard),
            (false, false, 1799.999, same(.idle), same(.end)),
            (false, false, 1800, same(.idle), same(.end)),
        ]
        for row in rows {
            store.settings.update { $0.setLiveStatus(for: "Claude", enabled: row.liveStatus) }
            for (index, newest) in Newest.allCases.enumerated() {
                let session = session(ended: row.inFlight ? nil : -2 * hour, observed: -row.age)
                let turns = turns(newest: newest)
                store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [session], turns: turns))
                store.now = now
                let lastEventAt = session.lastEvent(turnAt: turns.map { RecordCoding.date($0.observedAtMs) }.max())
                let phase = SessionPhase(session: session, turn: turns.last, lastEventAt: lastEventAt, liveStatus: row.liveStatus, now: now)
                let since: Date = switch row.since[index] {
                case .sessionStart: session.startedAt
                case .turnStart: now.addingTimeInterval(-3 * hour)
                case .turnHeard: now.addingTimeInterval(-2.5 * hour)
                case .reading: session.observedAt
                case .end: now.addingTimeInterval(-2 * hour)
                }
                let name = "\(row) with the newest turn \(newest)", state = row.states[index]
                let inFlight = state == .running || state == .waitingForApproval
                XCTAssertEqual(phase, SessionPhase(state: state, since: since,
                                                   validUntil: inFlight ? session.observedAt.addingTimeInterval(1800) : nil), name)
                XCTAssertEqual(phase.nextChange, phase.validUntil, name)
                XCTAssertEqual(store.isSessionLive(session), phase.isInFlight, name)
                XCTAssertEqual(store.isSessionWaiting(session), phase.state == .waitingForApproval, name)
                XCTAssertEqual(store.sessionState(session), newest.state, name)
                let label = !row.liveStatus ? "Live status off" : phase.state == .unverified ? "Status out of date"
                    : phase.state == .waitingForApproval ? "Needs approval" : Countdown.sessionLabel(phase, now: now)
                XCTAssertEqual(store.sessionStatusLabel(session), label, name)
            }
        }
    }

    /// A hook turn is running since its start while open and idle since its end, and nothing bounds either.
    func testAHookTurnsPhase() {
        let start = now.addingTimeInterval(-600), end = now.addingTimeInterval(-60)
        XCTAssertEqual(SessionPhase(hook: .init(startedAt: start, endedAt: nil, isReportedTurn: true)),
                       SessionPhase(state: .running, since: start, validUntil: nil))
        XCTAssertEqual(SessionPhase(hook: .init(startedAt: start, endedAt: end, isReportedTurn: false)),
                       SessionPhase(state: .idle, since: end, validUntil: nil))
    }

    /// At a given time, an open hook turn runs for half an hour from its prompt, as a reading is vouched for, and is out of
    /// date after that; a stopped one is idle since its Stop hook.
    func testAHookTurnsPhaseAtATime() {
        let start = now.addingTimeInterval(-600), end = now.addingTimeInterval(-60)
        let open = SessionPhase.HookTurn(startedAt: start, endedAt: nil, isReportedTurn: true)
        XCTAssertEqual(SessionPhase(hook: open, now: start.addingTimeInterval(1799.999)),
                       SessionPhase(state: .running, since: start, validUntil: start.addingTimeInterval(1800)))
        XCTAssertEqual(SessionPhase(hook: open, now: start.addingTimeInterval(1800)), SessionPhase(state: .unverified, since: start, validUntil: nil))
        XCTAssertEqual(SessionPhase(hook: .init(startedAt: start, endedAt: end, isReportedTurn: false), now: now.addingTimeInterval(86400)),
                       SessionPhase(state: .idle, since: end, validUntil: nil))
    }

    /// A reading keeps its phase against a hook turn when it is in flight with work after the hook's end; when it reports
    /// the hook's turn open and waiting for approval, or that turn's end after the hook's start; and when it reports
    /// another turn, or none, that it dates after the hook's start. The hook wins everywhere else, and at equal times.
    func testWhenAHookTurnTakesThePlaceOfAReading() {
        let start = now.addingTimeInterval(-600), end = now.addingTimeInterval(-60), ms = 0.001
        let at = { (offset: TimeInterval) in self.now.addingTimeInterval(offset) }
        // The hook's end (nil while open), whether it is the reading's turn, the reading's state and since, the last event,
        // and whether the hook prevails.
        let cases: [(String, end: Date?, same: Bool, SessionPhase.State, since: Date, lastEvent: Date, prevails: Bool)] = [
            ("work in flight after the hook's end", end, true, .running, start, end.addingTimeInterval(ms), false),
            ("a wait for approval after the hook's end, of another turn", end, false, .waitingForApproval, at(-900), end.addingTimeInterval(ms), false),
            ("work in flight up to the hook's end", end, true, .running, start, end, true),
            ("a finished reading with a later event", end, true, .idle, start, end.addingTimeInterval(ms), true),
            ("the same turn open and waiting for approval", nil, true, .waitingForApproval, at(-900), start, false),
            ("the same turn ended after the hook's start", nil, true, .idle, start.addingTimeInterval(ms), start, false),
            ("the same turn out of date after the hook's start", nil, true, .unverified, start.addingTimeInterval(ms), start, false),
            ("the same turn ended at the hook's start", nil, true, .idle, start, start, true),
            ("the same turn running after the hook's start", nil, true, .running, start.addingTimeInterval(ms), start, true),
            ("the same turn waiting after the hook ended", end, true, .waitingForApproval, at(-900), end, true),
            ("the same turn ended after the hook's start, the hook ended", end, true, .idle, start.addingTimeInterval(ms), end, true),
            ("another turn after the hook's start", nil, false, .running, start.addingTimeInterval(ms), start, false),
            ("another turn ended after the hook's start, the hook ended", end, false, .idle, start.addingTimeInterval(ms), end, false),
            ("another turn at the hook's start", nil, false, .running, start, start, true),
            ("another turn before the hook's start", end, false, .waitingForApproval, at(-900), end, true),
        ]
        for (name, hookEnd, same, state, since, lastEvent, prevails) in cases {
            let hook = SessionPhase.HookTurn(startedAt: start, endedAt: hookEnd, isReportedTurn: same)
            let reading = SessionPhase(state: state, since: since, validUntil: nil)
            XCTAssertEqual(SessionPhase.hookPrevails(hook, over: reading, lastEventAt: lastEvent), prevails, name)
        }
    }

    // MARK: Fixtures

    /// Times are seconds from now.
    private func session(ended: TimeInterval?, observed: TimeInterval) -> LiveSession {
        LiveSession(id: "s", agentId: "claude-model:opus", task: "s", terminal: nil, startedAt: now.addingTimeInterval(-5 * hour),
                    endedAt: ended.map { now.addingTimeInterval($0) }, pctOfWindow: nil, tokensIn: 1, tokensOut: 1,
                    observedAt: now.addingTimeInterval(observed))
    }

    /// An older finished turn, then the newest.
    private func turns(newest: Newest) -> [SessionTurn] {
        guard let state = newest.state else { return [] }
        func ms(_ offset: TimeInterval) -> Int64 { RecordCoding.milliseconds(now.addingTimeInterval(offset)) }
        return [SessionTurn(provider: "claude", sessionID: "s", turnID: "1", state: .completed, startedAtMs: ms(-5 * hour),
                            observedAtMs: ms(-4 * hour), message: "Earlier answer"),
                SessionTurn(provider: "claude", sessionID: "s", turnID: "2", state: state,
                            startedAtMs: newest == .runningWithoutStart ? nil : ms(-3 * hour), observedAtMs: ms(-2.5 * hour))]
    }

    @MainActor
    private func makeStore() throws -> UsageStore {
        let suite = "SessionPhaseTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults))
    }
}
#endif

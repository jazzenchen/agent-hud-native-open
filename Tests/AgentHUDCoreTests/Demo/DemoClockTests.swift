#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class DemoClockTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testATimeWithoutAnOffsetIsLocalAndSecondsAreOptional() throws {
        let minute = try XCTUnwrap(DemoClock.parse("2026-10-12T09:41", timeZone: shanghai))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: minute),
                       DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 41, second: 0))
        XCTAssertEqual(DemoClock.parse("2026-10-12T09:41:30", timeZone: shanghai), minute.addingTimeInterval(30))
    }

    func testATimeThatNamesItsOffsetKeepsIt() {
        XCTAssertEqual(DemoClock.parse("2026-10-12T01:41:00Z", timeZone: shanghai),
                       DemoClock.parse("2026-10-12T09:41", timeZone: shanghai))
        XCTAssertEqual(DemoClock.parse("2026-10-12T09:41:00+08:00", timeZone: .gmt),
                       DemoClock.parse("2026-10-12T09:41", timeZone: shanghai))
    }

    func testTheDemoStartsAtTheTimeNamedAndRunsOnFromThere() throws {
        let start = try XCTUnwrap(DemoClock.parse("2026-10-12T09:41", timeZone: shanghai))
        let offset = DemoClock.offset(arguments: ["app", "--demo", "--demo-clock", "2026-10-12T09:41"], now: now, timeZone: shanghai)
        XCTAssertEqual(now.addingTimeInterval(offset), start)
        XCTAssertEqual(now.addingTimeInterval(30 + offset), start.addingTimeInterval(30))
    }

    func testTheWallClockStaysWithoutATimeThatReads() {
        XCTAssertEqual(DemoClock.offset(arguments: ["app", "--demo"], now: now), 0)
        XCTAssertEqual(DemoClock.offset(arguments: ["app", "--demo-clock"], now: now), 0)
        XCTAssertEqual(DemoClock.offset(arguments: ["app", "--demo-clock", "tomorrow"], now: now), 0)
        XCTAssertEqual(DemoClock.wallTime(of: DemoClock.now).timeIntervalSinceNow, 0, accuracy: 1)
    }

    /// A store given a clock shows that clock's time for the report it is handed, and counts a pause on it.
    @MainActor
    func testAStoreRunsOnTheClockItIsGiven() {
        let defaults = UserDefaults(suiteName: "DemoClockTests")!
        defaults.removePersistentDomain(forName: "DemoClockTests")
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        let fixed = now
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, clock: { fixed })
        XCTAssertEqual(store.now, fixed)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: 2, now: fixed, stage: nil))
        XCTAssertEqual(store.now, fixed)
        store.pause(for: 60)
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.pausedUntil, fixed.addingTimeInterval(60))
    }
}
#endif

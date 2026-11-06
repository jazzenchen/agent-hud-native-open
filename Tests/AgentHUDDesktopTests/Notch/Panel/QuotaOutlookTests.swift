import SwiftUI
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

/// What each surface says about the same quota window: the hover hint, the island row's burn-rate labels and the rate
/// the window's tokens are spent at.
final class QuotaOutlookTests: XCTestCase {
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

    /// One window: what is left, when it resets, how long its cycle is, and its burn rate and seconds to exhaustion.
    private struct Window {
        let name: String
        let remaining: Double
        let resetIn: TimeInterval?
        let duration: TimeInterval?
        let insights: (burn: Double?, exhaust: TimeInterval?)?
        /// How far the window's readings have come while they are too few for a burn rate.
        var sampling: QuotaSampling? = nil
        var replyRate: QuotaReplyRate? = nil
        var used: Int64? = nil
        var capacity: Int64? = nil
    }

    private var grid: [Window] {
        [
            .init(name: "untimed", remaining: 50, resetIn: nil, duration: 5 * hour, insights: (10, 5 * hour)),
            .init(name: "exhausted", remaining: 0, resetIn: 2 * hour, duration: 5 * hour, insights: (10, nil)),
            .init(name: "nearlyExhausted", remaining: 0.5, resetIn: 2 * hour, duration: 5 * hour, insights: (10, 3 * 60)),
            .init(name: "noCycle", remaining: 50, resetIn: 2 * hour, duration: nil, insights: (10, 5 * hour)),
            .init(name: "noInsights", remaining: 50, resetIn: 2 * hour, duration: 5 * hour, insights: nil),
            .init(name: "noUsage", remaining: 50, resetIn: 2 * hour, duration: 5 * hour, insights: (0, nil)),
            .init(name: "insufficientData", remaining: 50, resetIn: 2 * hour, duration: 5 * hour, insights: (nil, nil)),
            .init(name: "zeroTimeToExhaust", remaining: 50, resetIn: 2 * hour, duration: 5 * hour, insights: (10, 0)),
            .init(name: "infiniteTime", remaining: 50, resetIn: 2 * hour, duration: 5 * hour, insights: (10, .infinity)),
            .init(name: "exhaustsBeforeReset", remaining: 10, resetIn: 2 * hour, duration: 5 * hour, insights: (10, hour)),
            .init(name: "exhaustsAfterReset", remaining: 50, resetIn: 2 * hour, duration: 5 * hour, insights: (10, 5 * hour)),
            .init(name: "resetPassed", remaining: 50, resetIn: -10 * 60, duration: 5 * hour, insights: (10, 5 * hour)),
            .init(name: "weekly", remaining: 50, resetIn: 3 * 86400, duration: 7 * 86400, insights: (1, 50 * hour)),
            .init(name: "fullWindow", remaining: 100, resetIn: 2 * hour, duration: 5 * hour, insights: (nil, nil)),
            .init(name: "sampling", remaining: 99, resetIn: 2 * hour, duration: 5 * hour, insights: (nil, nil),
                  sampling: QuotaSampling(elapsed: 180, required: 15 * 60, afterReset: false)),
            .init(name: "resampling", remaining: 100, resetIn: 7 * 86400 - 600, duration: 7 * 86400, insights: (nil, nil),
                  sampling: QuotaSampling(elapsed: 30, required: hour, afterReset: true)),
        ]
    }

    /// What the surfaces say about one window.
    private struct Outlook: Equatable {
        /// The hover hint.
        var hint: String?
        /// How far ahead the island row puts the window running out before its reset.
        var exhaustsIn: TimeInterval?
        /// The share the island row projects to be used by the reset of a window that lasts past it.
        var projected: Double?
        /// The island row's burn-rate detail.
        var detail: String
        var tokensPerHour: Double?
    }

    @MainActor
    func testEverySurfaceOverTheSameWindows() throws {
        let hour = hour
        /// The week, weekday and time of a nearby exhaustion in this Mac's time zone.
        func at(_ interval: TimeInterval) -> String { ChartData.relativeWeekdayTime(now.addingTimeInterval(interval), now: now) }
        // The row says what the hint says, except that it gives the time a window runs out at before its reset.
        let expected: [(String, Outlook)] = [
            ("untimed", .init(hint: nil, exhaustsIn: nil, projected: nil, detail: "—", tokensPerHour: nil)),
            ("exhausted", .init(hint: "Exhausted", exhaustsIn: nil, projected: nil, detail: "Exhausted", tokensPerHour: 1000)),
            // Half a point left is exhausted.
            ("nearlyExhausted", .init(hint: "Exhausted", exhaustsIn: nil, projected: nil, detail: "Exhausted", tokensPerHour: 1000)),
            ("noCycle", .init(hint: "No estimate", exhaustsIn: nil, projected: nil, detail: "No estimate", tokensPerHour: nil)),
            ("noInsights", .init(hint: "Insufficient data", exhaustsIn: nil, projected: nil, detail: "Insufficient data", tokensPerHour: 1000)),
            ("noUsage", .init(hint: "No usage", exhaustsIn: nil, projected: nil, detail: "No usage", tokensPerHour: 1000)),
            ("insufficientData", .init(hint: "Insufficient data", exhaustsIn: nil, projected: nil, detail: "Insufficient data", tokensPerHour: 1000)),
            ("zeroTimeToExhaust", .init(hint: "Insufficient data", exhaustsIn: nil, projected: nil, detail: "Insufficient data", tokensPerHour: 1000)),
            ("infiniteTime", .init(hint: "Insufficient data", exhaustsIn: nil, projected: nil, detail: "Insufficient data", tokensPerHour: 1000)),
            ("exhaustsBeforeReset", .init(hint: "Exhausts ~1h", exhaustsIn: hour, projected: nil, detail: at(hour), tokensPerHour: 1000)),
            ("exhaustsAfterReset", .init(hint: "70% by reset", exhaustsIn: nil, projected: 70, detail: "70% by reset", tokensPerHour: 1000)),
            // A reading whose reset passed shows no level, so the row gives it no burn rate or token rate.
            ("resetPassed", .init(hint: "Insufficient data", exhaustsIn: nil, projected: nil, detail: "—", tokensPerHour: nil)),
            ("weekly", .init(hint: "Exhausts ~50h", exhaustsIn: 50 * hour, projected: nil, detail: at(50 * hour), tokensPerHour: 1167)),
            ("fullWindow", .init(hint: "Insufficient data", exhaustsIn: nil, projected: nil, detail: "Insufficient data", tokensPerHour: 1000)),
            // Readings too few for a burn rate say how far they have come, and whether they start again after a reset.
            ("sampling", .init(hint: "Collecting initial readings for a forecast\nSampled 3m; at least 15m of readings needed",
                               exhaustsIn: nil, projected: nil, detail: "Sampling", tokensPerHour: 1000)),
            ("resampling", .init(hint: "Quota reset; collecting new readings\nSampled less than 1m; at least 1h of readings needed",
                                 exhaustsIn: nil, projected: nil, detail: "Resampling", tokensPerHour: 0)),
        ]
        XCTAssertEqual(expected.map { $0.0 }, grid.map(\.name))
        try withStore(grid) { store in
            for (window, (name, outlook)) in zip(grid, expected) {
                let snapshot = try XCTUnwrap(store.report?.snapshot(for: window.name))
                let insights = store.report?.insightsByAgent[window.name]
                let metrics = try self.metrics(window.name, in: store)
                XCTAssertEqual(Outlook(hint: QuotaForecast.hint(snapshot: snapshot, insights: insights, now: now),
                                       exhaustsIn: metrics.exhaustsBeforeReset?.timeIntervalSince(now),
                                       projected: metrics.projectedAtReset,
                                       detail: metrics.detail(.burnRate, isLoading: false),
                                       tokensPerHour: store.quotaTokensPerHour(for: window.name)), outlook, name)
            }
            // The burn rate wears the warning colour, and its projection fills the track, for a window that ran out or runs
            // out before its reset.
            XCTAssertEqual(try grid.map(\.name).filter { try metrics($0, in: store).runsOut },
                           ["exhausted", "nearlyExhausted", "exhaustsBeforeReset", "weekly"])
        }
    }

    /// Multiline hints wrap within the popover instead of growing across the screen.
    @MainActor
    func testTheHoverShowsEveryLineOfAHint() {
        let agent = AgentDescriptor(id: "window", vendor: "Codex", model: "Weekly", source: "", enabled: true)
        func size(_ text: String) -> CGSize { NSHostingView(rootView: QuotaForecastDetails(agent: agent, hint: text)).fittingSize }
        func width(_ line: String) -> CGFloat {
            NSHostingView(rootView: Text(line).font(.ui(12, .medium)).monospacedDigit().fixedSize()).fittingSize.width
        }
        let first = "Quota reset; collecting new readings", second = "Sampled less than 1m; at least 15m of readings needed"
        let one = size(first), both = size(first + "\n" + second)
        XCTAssertGreaterThan(both.height, one.height + 10)
        XCTAssertGreaterThanOrEqual(both.width, min(width(second), 340) + 20 - 0.5)
        XCTAssertLessThanOrEqual(both.width, 360.5)
    }

    @MainActor
    func testCostHoverIncludesCapacityAndSharesExhaustionFormat() throws {
        try withStore([grid[9]]) { store in
            let old = try metrics("exhaustsBeforeReset", in: store)
            let priced = QuotaRowMetrics(row: old.row, insights: old.insights, outlook: old.outlook, now: now,
                                         tokensPerHour: old.tokensPerHour, cost: QuotaListCost(amounts: ["USD": 40], hours: 1),
                                         capacityEstimate: QuotaCapacityEstimate(tokens: 3333, amounts: ["USD": Decimal(400) / 9]))
            let hint = try XCTUnwrap(priced.hoverHint(.cost, fallback: "old duration"))
            XCTAssertEqual(hint.components(separatedBy: "\n").count, 2)
            XCTAssertTrue(hint.contains("Estimated total capacity: $44.44"))
            XCTAssertTrue(hint.contains("Estimated exhaustion: "))
            XCTAssertFalse(hint.contains("Used API equivalent"))
            XCTAssertFalse(hint.contains("locally recorded"))
            XCTAssertFalse(hint.contains("old duration"))
            XCTAssertEqual(priced.hoverHint(.quota, fallback: "old duration"), priced.hoverHint(.burnRate, fallback: "old duration"))
        }
    }

    @MainActor
    func testCostHoverExplainsMissingPrices() throws {
        try withStore([grid[9]]) { store in
            let old = try metrics("exhaustsBeforeReset", in: store)
            let priced = QuotaRowMetrics(row: old.row, insights: old.insights, outlook: old.outlook, now: now,
                                         tokensPerHour: nil, cost: QuotaListCost(amounts: ["USD": 40], hours: 1, hasUnpricedUsage: true),
                                         capacityEstimate: QuotaCapacityEstimate(tokens: 3333, amounts: nil, hasUnpricedUsage: true))
            let hint = try XCTUnwrap(priced.hoverHint(.cost, fallback: nil))
            XCTAssertTrue(hint.contains("Missing model prices"))
            XCTAssertEqual(hint.components(separatedBy: "\n").count, 2)
            XCTAssertFalse(hint.contains("$44.44"))
        }
    }

    @MainActor
    func testReplyRateHoverShowsOnlyExhaustionWhileTokenHoverAddsTheTotal() throws {
        var window = grid[9]
        window.replyRate = QuotaReplyRate(tokensPerSecond: 9.5, calls: 3, tokensOut: 570)
        try withStore([window]) { store in
            let row = try metrics(window.name, in: store)
            let requests = try XCTUnwrap(row.hoverHint(.tokens, fallback: "old\nmultiline hint"))
            let tokens = try XCTUnwrap(row.hoverHint(.consumed, fallback: "old\nmultiline hint"))
            XCTAssertTrue(requests.hasPrefix("Estimated exhaustion: "))
            XCTAssertFalse(requests.contains("Sampled"))
            XCTAssertTrue(tokens.hasPrefix("Estimated total tokens: 3.3k\n"))
            XCTAssertEqual(requests.components(separatedBy: "\n").count, 1)
            XCTAssertEqual(tokens.components(separatedBy: "\n").count, 2)
            XCTAssertEqual(requests.components(separatedBy: "\n").last, tokens.components(separatedBy: "\n").last)
            XCTAssertFalse(tokens.contains("multiline hint"))
        }
    }

    @MainActor
    func testCompactHoversHandleResetAndInsufficientSamplesWithoutAnExtraParagraph() throws {
        try withStore([grid[10], grid[14], grid[1]]) { store in
            let afterReset = try metrics("exhaustsAfterReset", in: store)
            XCTAssertEqual(afterReset.hoverHint(.cost, fallback: nil)?.components(separatedBy: "\n").last,
                           "Estimated exhaustion: Not before reset")
            let sampling = try metrics("sampling", in: store)
            XCTAssertEqual(sampling.hoverHint(.consumed, fallback: nil), "Estimated total tokens: —\nEstimated exhaustion: Sampling")
            let exhausted = try metrics("exhausted", in: store)
            XCTAssertEqual(exhausted.hoverHint(.tokens, fallback: nil)?.components(separatedBy: "\n").last,
                           "Estimated exhaustion: Exhausted")
        }
    }

    /// The row's other measures on one window of the grid, and a window that runs out a week or more ahead, which the
    /// row gives as a date rather than a weekday.
    @MainActor
    func testTheRowsOtherMeasuresAndAFarExhaustion() throws {
        let far = Window(name: "monthly", remaining: 50, resetIn: 20 * 86400, duration: 30 * 86400, insights: (0.2, 10 * 86400))
        var window = grid[9]
        window.replyRate = QuotaReplyRate(tokensPerSecond: 9.5, calls: 3, tokensOut: 570)
        try withStore([window, far]) { store in
            let row = try metrics("exhaustsBeforeReset", in: store)
            // The model the windows count has no list price, so the cycle has no cost.
            XCTAssertEqual(PanelMeasure.allCases.map { row.value($0) }, ["90%", "10.0%/h", "9.5/s", "3.0k", nil])
            XCTAssertEqual(PanelMeasure.allCases.map { row.detail($0, isLoading: false) },
                           ["2h 00m", ChartData.relativeWeekdayTime(now.addingTimeInterval(hour), now: now), "3 replies", "1.0k/h", "—"])
            XCTAssertEqual(store.view.consumed(for: window.name)?.used, 3000, "only the cycle's selected model counts")
            let date = now.addingTimeInterval(10 * 86400)
            XCTAssertEqual(try metrics("monthly", in: store).exhaustionTimeLabel, QuotaForecast.timeLabel(date, now: now))
        }
    }

    @MainActor
    func testReportedConsumptionUsesItsCapacityAndDoesNotInventAReplyRate() throws {
        var window = grid[9]
        window.used = 7500
        window.capacity = 30_000
        try withStore([window]) { store in
            let row = try metrics(window.name, in: store)
            XCTAssertEqual(row.value(.consumed), "7.5k", "the provider's cycle tally takes priority over local tokens")
            XCTAssertEqual(row.detail(.consumed, isLoading: false), "/ 30k")
            let hint = try XCTUnwrap(row.hoverHint(.consumed, fallback: nil))
            XCTAssertTrue(hint.hasPrefix("Estimated total tokens: 3.3k\n"), "provider-native credit counts must not be labelled as tokens")
            XCTAssertEqual(store.quotaTokensPerHour(for: window.name), 1000)
            XCTAssertNil(row.value(.tokens), "token consumption alone supplies no call timing")
            XCTAssertEqual(row.detail(.tokens, isLoading: false), "—")
        }
    }

    /// A window whose reading shows no level enters no calculation: its row keeps the share used and its reset, but shows
    /// no burn rate, projection or token rate, and neither the island nor the menu gives it a hint.
    @MainActor
    func testAWindowWhoseReadingShowsNoLevelHasNoForecast() throws {
        var window = grid[9]
        window.replyRate = QuotaReplyRate(tokensPerSecond: 12, calls: 4, tokensOut: 480)
        window.used = 7500
        window.capacity = 30_000
        try withStore([window], quotaNotices: ["Codex": "Codex quota could not be read"]) { store in
            let row = try metrics("exhaustsBeforeReset", in: store)
            XCTAssertNil(row.row.level)
            XCTAssertEqual(PanelMeasure.allCases.map { row.value($0) }, ["90%", nil, nil, nil, nil])
            XCTAssertEqual(PanelMeasure.allCases.map { row.detail($0, isLoading: false) }, ["2h 00m", "—", "—", "—", "—"])
            XCTAssertNil(row.exhaustsBeforeReset)
            XCTAssertNil(row.projectedAtReset)
            XCTAssertNil(store.quotaForecastHint(for: "exhaustsBeforeReset"))
            XCTAssertNil(store.quotaTokensPerHour(for: "exhaustsBeforeReset"))
            XCTAssertNil(store.view.replyRate(for: window.name))
            XCTAssertNil(store.view.consumed(for: window.name))
            XCTAssertNil(store.maxUsedPct)
        }
    }

    /// An explicit unknown reading is distinct from both known zero usage and a row awaiting its first reading.
    @MainActor
    func testUnknownQuotaShowsNAWhileKnownZeroAndInitialRowsKeepTheirMeaning() throws {
        let suite = "QuotaOutlookTests.unknown.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agent = AgentDescriptor(id: "grok", vendor: "Grok", model: "Weekly usage limit", source: "Test", enabled: true)
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: [agent]))
        store.replace(report: UsageReport(generatedAt: now,
            snapshots: [.init(agentId: agent.id, remainingPct: nil, resetAt: now.addingTimeInterval(2 * hour), updatedAt: now,
                              used: 7500, capacity: 30_000)],
            sessions: [], discoveredAgents: [agent],
            insightsByAgent: [agent.id: .init(burnRatePctPerHour: 10, timeToExhaust: hour, weeklyCapHits: 0,
                weeklyWaitTotal: 0, weeklyWaitLongest: 0, weeklyWaitLongestAt: nil)],
            replyRates: [agent.id: .init(tokensPerSecond: 12, calls: 4, tokensOut: 480)]))
        store.now = now
        let unknown = try metrics(agent.id, in: store)
        XCTAssertEqual(PanelMeasure.allCases.map { unknown.value($0) }, ["N/A", nil, nil, nil, nil])
        XCTAssertEqual(unknown.detail(.quota, isLoading: false), "2h 00m")
        XCTAssertNil(unknown.row.usedPct)
        XCTAssertNil(unknown.row.level)
        XCTAssertNil(unknown.projectedAtReset)

        store.replace(report: UsageReport(generatedAt: now,
            snapshots: [.init(agentId: agent.id, remainingPct: 100, updatedAt: now)], sessions: [], discoveredAgents: [agent]))
        XCTAssertEqual(try metrics(agent.id, in: store).value(.quota), "0%")
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: [agent]))
        XCTAssertEqual(try metrics(agent.id, in: store).value(.quota), "—")
    }

    /// A store showing `windows` at `now`, each counting the tokens of one model spent before, around and after now.
    @MainActor
    private func withStore(_ windows: [Window], quotaNotices: [String: String] = [:], indexing: IndexProgress? = nil, _ body: (UsageStore) throws -> Void) throws {
        let suite = "QuotaOutlookTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let agents = windows.map { AgentDescriptor(id: $0.name, vendor: "Codex", model: $0.name, source: "", enabled: true) }
        let usage = [(-6 * hour, "m", 4000), (-3 * hour, "m", 2000), (-hour, "m", 1000), (60, "m", 500), (-hour, "other", 9000)].map {
            UsageBucket(start: now.addingTimeInterval($0.0), agentId: $0.1, tokensIn: $0.2, tokensOut: 0)
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: agents))
        store.replace(report: UsageReport(
            generatedAt: now,
            snapshots: windows.map {
                UsageSnapshot(agentId: $0.name, remainingPct: $0.remaining, resetAt: $0.resetIn.map(now.addingTimeInterval),
                              windowDuration: $0.duration, updatedAt: now, used: $0.used, capacity: $0.capacity)
            },
            sessions: [], discoveredAgents: agents, usage: usage, indexing: indexing,
            insightsByAgent: Dictionary(uniqueKeysWithValues: windows.compactMap { window in
                window.insights.map {
                    (window.name, UsageInsights(burnRatePctPerHour: $0.burn, timeToExhaust: $0.exhaust, weeklyCapHits: 0, weeklyWaitTotal: 0,
                                                weeklyWaitLongest: 0, weeklyWaitLongestAt: nil, sampling: window.sampling,
                                                capacityObservation: QuotaObservation(start: now.addingTimeInterval(-3 * hour), end: now,
                                                    remainingAtStart: 100, remainingAtEnd: window.remaining)))
                }
            }),
            sourceNotices: quotaNotices, quotaNotices: quotaNotices,
            consumerIdsByQuota: Dictionary(uniqueKeysWithValues: windows.map { ($0.name, ["m"]) }),
            replyRates: Dictionary(uniqueKeysWithValues: windows.compactMap { window in window.replyRate.map { (window.name, $0) } })))
        store.now = now
        try body(store)
    }

    /// The island row's measures of one window, built from the store as the panel builds them.
    @MainActor
    private func metrics(_ id: String, in store: UsageStore) throws -> QuotaRowMetrics {
        QuotaRowMetrics(row: try XCTUnwrap(store.row(for: id)), insights: store.report?.insightsByAgent[id],
                        outlook: store.view.outlook(for: id), now: store.now, tokensPerHour: store.quotaTokensPerHour(for: id),
                        replyRate: store.view.replyRate(for: id), consumed: store.view.consumed(for: id),
                        cost: store.view.listCost(for: id), capacityEstimate: store.view.capacityEstimate(for: id))
    }

    @MainActor
    func testIndexingKeepsRecordedValuesButWithholdsTotalPredictions() throws {
        try withStore([grid[9]], indexing: IndexProgress(done: 1, total: 2)) { store in
            let row = try metrics("exhaustsBeforeReset", in: store)
            XCTAssertEqual(row.consumed?.used, 3000)
            XCTAssertNotNil(row.value(.consumed))
            XCTAssertNil(store.view.capacityEstimate(for: "exhaustsBeforeReset"))
            XCTAssertTrue(try XCTUnwrap(row.hoverHint(.consumed, fallback: nil)).hasPrefix("Estimated total tokens: —\n"))
            XCTAssertTrue(try XCTUnwrap(row.hoverHint(.consumed, fallback: nil)).contains("Estimated exhaustion: "))
        }
    }
}

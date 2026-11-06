import XCTest
@testable import AgentHUDCore

final class QuotaCostEstimateTests: XCTestCase {
    func testFullCycleEstimateUsesSpentMoneyAndConsumedShare() throws {
        let cost = QuotaListCost(amounts: ["USD": 40], hours: 2)
        XCTAssertEqual(cost.estimatedCapacity(usedPercent: 20), ["USD": 200])
        XCTAssertEqual(cost.estimatedCapacity(usedPercent: 100), ["USD": 40])
        XCTAssertEqual(cost.perHour("USD"), 20, "pace remains separate from capacity")
    }

    func testSmallInvalidAndUnpricedSamplesDoNotEstimate() {
        let cost = QuotaListCost(amounts: ["USD": 40], hours: 2)
        for share in [0.0, 4.99, -1, 101, .infinity, .nan] {
            XCTAssertNil(cost.estimatedCapacity(usedPercent: share))
        }
        XCTAssertNil(QuotaListCost(amounts: ["USD": 40], hours: 2, hasUnpricedUsage: true).estimatedCapacity(usedPercent: 20))
        XCTAssertNil(QuotaListCost(amounts: [:], hours: 2).estimatedCapacity(usedPercent: 20))
        XCTAssertNil(QuotaListCost(amounts: ["USD": -1], hours: 2).estimatedCapacity(usedPercent: 20))
    }

    func testCurrenciesAreEstimatedSeparately() {
        let cost = QuotaListCost(amounts: ["USD": 10, "CNY": 20], hours: 1)
        XCTAssertEqual(cost.estimatedCapacity(usedPercent: 25), ["USD": 40, "CNY": 80])
    }

    func testMissingModelPriceWithholdsCapacityWhileKeepingKnownSpend() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(agentId: "q", remainingPct: 80, resetAt: now.addingTimeInterval(3600),
                                     windowDuration: 7200, updatedAt: now)
        let known = "codex-model:gpt-6.1-sol", unknown = "codex-model:unknown-price-fixture"
        let buckets = [UsageBucket(start: now.addingTimeInterval(-1800), agentId: known, tokensIn: 1000, tokensOut: 10),
                       UsageBucket(start: now.addingTimeInterval(-900), agentId: unknown, tokensIn: 1000, tokensOut: 10)]
        let cost = try XCTUnwrap(QuotaMath.listCost(snapshot: snapshot, consumers: [known, unknown], usage: buckets,
                                                 regions: PriceRegions(report: nil), now: now))
        XCTAssertTrue(cost.hasUnpricedUsage)
        XCTAssertGreaterThan(cost.amounts["USD"] ?? 0, 0)
        XCTAssertNil(cost.estimatedCapacity(usedPercent: 20))
    }

    func testNearAndFarExhaustionAlwaysUseColonSeparatedClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10)))
        let near = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 13, minute: 7)))
        let far = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 13, minute: 7)))
        defer { L10n.setLanguage(.system) }
        for language in [AppLanguage.zhHans, .en] {
            L10n.setLanguage(language)
            for date in [near, far] {
                let label = QuotaForecast.timeLabel(date, now: now, calendar: calendar)
                XCTAssertTrue(label.hasSuffix("13:07"), label)
                XCTAssertFalse(label.contains("13时"), label)
            }
        }
    }
}

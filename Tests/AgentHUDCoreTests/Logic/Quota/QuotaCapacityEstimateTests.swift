import Foundation
import XCTest
@testable import AgentHUDCore

final class QuotaCapacityEstimateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let model = "codex-model:gpt-6.1-sol"
    private var snapshot: UsageSnapshot {
        UsageSnapshot(agentId: "q", remainingPct: 60, resetAt: now.addingTimeInterval(3600), windowDuration: 5 * 3600, updatedAt: now)
    }
    private var observation: QuotaObservation {
        .init(start: now.addingTimeInterval(-3600), end: now, remainingAtStart: 70, remainingAtEnd: 60)
    }
    private var usage: [UsageBucket] {
        [UsageBucket(start: now.addingTimeInterval(-7200), agentId: "other", tokensIn: 1, tokensOut: 0),
         UsageBucket(start: now.addingTimeInterval(-3600), agentId: model, tokensIn: 1000, tokensOut: 0),
         UsageBucket(start: now.addingTimeInterval(-900), agentId: model, tokensIn: 2000, tokensOut: 0),
         UsageBucket(start: now, agentId: model, tokensIn: 900_000, tokensOut: 0)]
    }
    private func estimate(_ values: [UsageBucket], observation: QuotaObservation? = nil) -> QuotaCapacityEstimate? {
        QuotaMath.capacityEstimate(snapshot: snapshot, observation: observation ?? self.observation, consumers: [model],
            usage: values, regions: PriceRegions(report: nil), now: now.addingTimeInterval(600))
    }
    func testPartialCycleUsesMatchedQuotaDeltaAndIgnoresCallsAfterTheReading() throws {
        let value = try XCTUnwrap(estimate(usage))
        XCTAssertEqual(value.tokens, 30_000, "3k over 10 percentage points, not over the cycle's 40% already spent")
        let cost = try XCTUnwrap(ModelCatalog.cost(agentId: model, summed: TokenKinds(input: 3000)))
        XCTAssertEqual(value.amounts?[cost.currency], cost.amount * 10)
    }
    func testNonemptyBucketsAcrossEitherObservationBoundaryWithholdEstimates() {
        let left = UsageBucket(start: observation.start.addingTimeInterval(-60), agentId: model, tokensIn: 1, tokensOut: 0)
        let right = UsageBucket(start: observation.end.addingTimeInterval(-60), agentId: model, tokensIn: 1, tokensOut: 0)
        XCTAssertNil(estimate(usage + [left]))
        XCTAssertNil(estimate(usage + [right]))
        let other = UsageBucket(start: observation.end.addingTimeInterval(-60), agentId: "other", tokensIn: 1, tokensOut: 0)
        XCTAssertNotNil(estimate(usage + [other]), "another client's edge bucket is outside this window")
    }
    func testMissingCoverageStaleObservationAndTinyDeltasDoNotProject() {
        XCTAssertNil(estimate(Array(usage.dropFirst(2))))
        let stale = QuotaObservation(start: observation.start, end: now, remainingAtStart: 70, remainingAtEnd: 59)
        XCTAssertNil(estimate(usage, observation: stale))
        let tiny = QuotaObservation(start: observation.start, end: now, remainingAtStart: 64, remainingAtEnd: 60)
        XCTAssertNil(estimate(usage, observation: tiny))
        XCTAssertNil(QuotaMath.capacityEstimate(snapshot: snapshot, observation: nil, consumers: [model], usage: usage,
                                               regions: PriceRegions(report: nil), now: now))
    }
    func testUnknownModelKeepsTokenEstimateWithoutInventingMoney() throws {
        let unknown = usage.map { UsageBucket(start: $0.start, agentId: "unknown", tokensIn: $0.tokensIn, tokensOut: 0) }
        let value = try XCTUnwrap(QuotaMath.capacityEstimate(snapshot: snapshot, observation: observation, consumers: ["unknown"],
            usage: unknown, regions: PriceRegions(report: nil), now: now))
        XCTAssertEqual(value.tokens, 30_000)
        XCTAssertNil(value.amounts)
        XCTAssertTrue(value.hasUnpricedUsage)
    }
    func testEarlyResetRestartsObservationAndRisesOrGapsDoNotBridge() throws {
        func sample(_ seconds: Double, _ remaining: Double) -> QuotaSample {
            QuotaSample(agentId: "q", timestamp: now.addingTimeInterval(seconds), remainingPct: remaining)
        }
        let early = UsageAnalytics.capacityObservation(samples: [sample(-7200, 20), sample(-3600, 100), sample(0, 90)],
            cycle: snapshot.cycle, now: now)
        XCTAssertEqual(early?.start, now.addingTimeInterval(-3600))
        XCTAssertEqual(early?.remainingAtStart, 100)
        XCTAssertNil(UsageAnalytics.capacityObservation(samples: [sample(-3600, 70), sample(-1800, 71), sample(0, 60)],
                                                       cycle: snapshot.cycle, now: now))
        let weekly = QuotaCycle(resetAt: now.addingTimeInterval(86400), duration: 7 * 86400)
        XCTAssertNil(UsageAnalytics.capacityObservation(samples: [sample(-36000, 70), sample(0, 60)], cycle: weekly, now: now))
    }
    func testOlderInsightsReportsDecodeWithNoProjectionEvidence() throws {
        let insights = UsageInsights(burnRatePctPerHour: 10, timeToExhaust: 3600, weeklyCapHits: 0,
            weeklyWaitTotal: 0, weeklyWaitLongest: 0, weeklyWaitLongestAt: nil)
        let decoded = try JSONDecoder().decode(UsageInsights.self, from: JSONEncoder().encode(insights))
        XCTAssertNil(decoded.capacityObservation)
    }
}

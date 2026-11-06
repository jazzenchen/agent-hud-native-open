import XCTest
@testable import AgentHUDCore

final class ModelPriceCacheTests: XCTestCase {
    func testUnchangedSessionBreakdownsAreInvalidatedByNewPriceContent() async throws {
        let cache = CombinedUsageProvider.Results()
        _ = await cache.breakdowns(generation: 1, priceRevision: "old-prices")
        let request = SessionUsageRequest(sessionID: "quiet-session", keys: ["unchanged-log"])
        await cache.storeBreakdowns(["quiet-session": .init(counts: [100, 50, 0], request: request, usage: nil)], mark: 5,
                                   generation: 1, priceRevision: "old-prices")
        let unchanged = await cache.breakdowns(generation: 1, priceRevision: "old-prices")
        XCTAssertEqual(Set(unchanged.values.keys), ["quiet-session"])
        XCTAssertEqual(unchanged.mark, 5)
        let repriced = await cache.breakdowns(generation: 1, priceRevision: "new-prices")
        XCTAssertTrue(repriced.values.isEmpty, "quiet sessions need fresh list costs even without new tokens or ledger writes")
        XCTAssertEqual(repriced.mark, 0)
        await cache.storeBreakdowns(unchanged.values, mark: 6, generation: 1, priceRevision: "old-prices")
        let lateWrite = await cache.breakdowns(generation: 1, priceRevision: "new-prices")
        XCTAssertTrue(lateWrite.values.isEmpty, "an older in-flight request cannot repopulate the new catalog's cache")
        await cache.storeBreakdowns(unchanged.values, mark: 6, generation: 1, priceRevision: "new-prices")
        let rebuiltLedger = await cache.breakdowns(generation: 2, priceRevision: "new-prices")
        XCTAssertTrue(rebuiltLedger.values.isEmpty, "ledger generation invalidation still applies")
    }
}

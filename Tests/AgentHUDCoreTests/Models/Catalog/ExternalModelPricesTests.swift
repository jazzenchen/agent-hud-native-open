import Foundation
import XCTest
@testable import AgentHUDCore

final class ExternalModelPricesTests: XCTestCase {
    private var row: [String: Any] { [
        "mode": "chat", "litellm_provider": "openai",
        "input_cost_per_token": 0.000001, "output_cost_per_token": 0.000005,
        "cache_read_input_token_cost": 0.00000005, "cache_creation_input_token_cost": 0.00000125,
        "input_cost_per_token_above_272k_tokens": 0.000002,
        "output_cost_per_token_above_272k_tokens": 0.0000075,
        "cache_read_input_token_cost_above_272k_tokens": 0.0000001,
        "cache_creation_input_token_cost_above_272k_tokens": 0.0000025,
    ] }
    func testFeedAddsNewModelsWithoutCompiledPriceEntriesAndPreservesTiers() throws {
        let data = try JSONSerialization.data(withJSONObject: ["new-model": row])
        let models = try ExternalModelPrices.parse(data)
        let model = try XCTUnwrap(models["new-model"])
        let price = try XCTUnwrap(model.price(in: .international)?.price)
        XCTAssertEqual(price.rates(prompt: 272_000).input, 1)
        XCTAssertEqual(price.rates(prompt: 272_000).cacheRead, Decimal(string: "0.05")!)
        XCTAssertEqual(price.rates(prompt: 272_000).cacheWrite, Decimal(string: "1.25")!)
        XCTAssertEqual(price.rates(prompt: 272_001).input, 2)
        XCTAssertEqual(price.rates(prompt: 272_001).output, Decimal(string: "7.5")!)
    }
    func testMalformedPricesAndProviderRoutesDoNotOverrideOfficialPrices() throws {
        var negative = row; negative["cache_read_input_token_cost"] = -1
        var incomplete = row; incomplete.removeValue(forKey: "output_cost_per_token_above_272k_tokens")
        let data = try JSONSerialization.data(withJSONObject: ["valid": row, "invalid": negative,
            "incomplete": incomplete, "gateway/valid": row])
        let parsed = try ExternalModelPrices.parse(data)
        XCTAssertEqual(Set(parsed.keys), ["valid"])
    }
    func testValidatedCacheWorksOfflineAndBrokenCacheFallsBackWithoutCrashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try JSONSerialization.data(withJSONObject: ["new-model": row])
        try data.write(to: url)
        let good = ExternalModelPrices(cacheURL: url)
        XCTAssertNotNil(good.model(named: "new-model"))
        XCTAssertEqual(good.sourceInfo.source, "LiteLLM")
        XCTAssertNotNil(good.sourceInfo.updatedAt)
        try Data("broken".utf8).write(to: url)
        let bad = ExternalModelPrices(cacheURL: url)
        XCTAssertNil(bad.model(named: "new-model"))
        XCTAssertEqual(bad.sourceInfo.source, "Built-in")
        XCTAssertNotNil(good.model(named: "new-model"), "a later bad file cannot alter a loaded good snapshot")
    }
    func testInvalidFeedIsRejected() throws {
        for data in [Data("{}".utf8), Data("[]".utf8), Data("not json".utf8)] {
            var rejected = false
            do { _ = try ExternalModelPrices.parse(data) } catch { rejected = true }
            XCTAssertTrue(rejected)
        }
    }
}

extension ExternalModelPricesTests {
    func testAnthropicUsesTheOneHourCacheWritePricesAtEachTier() throws {
        var anthropic = row
        anthropic["litellm_provider"] = "anthropic"
        anthropic["cache_creation_input_token_cost_above_1hr"] = 0.0000022
        anthropic["cache_creation_input_token_cost_above_1hr_above_272k_tokens"] = 0.0000044
        let data = try JSONSerialization.data(withJSONObject: ["claude-sample": anthropic])
        let model = try XCTUnwrap(ExternalModelPrices.parse(data)["claude-sample"])
        let price = try XCTUnwrap(model.price(in: .international)?.price)
        XCTAssertEqual(price.rates(prompt: 272_000).cacheWrite, Decimal(string: "2.2")!)
        XCTAssertEqual(price.rates(prompt: 272_001).cacheWrite, Decimal(string: "4.4")!)
    }

    func testUnsupportedProvidersAndBooleanRatesAreRejected() throws {
        var unsupported = row; unsupported["litellm_provider"] = "deepseek"
        var boolean = row; boolean["input_cost_per_token"] = true
        let data = try JSONSerialization.data(withJSONObject: ["valid": row, "unsupported": unsupported, "boolean": boolean])
        XCTAssertEqual(Set(try ExternalModelPrices.parse(data).keys), ["valid"])
    }

    func testRevisionFollowsPriceContentAndSourceMetadataTracksSuccessfulInstall() throws {
        let cache = ExternalModelPrices(cacheURL: nil)
        let first = try JSONSerialization.data(withJSONObject: ["new-model": row], options: [.sortedKeys])
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        cache.install(try ExternalModelPrices.parse(first), data: first, at: at)
        let revision = cache.sourceInfo.revision
        XCTAssertEqual(cache.sourceInfo.updatedAt, at)
        XCTAssertEqual(cache.sourceInfo.modelCount, 1)
        cache.install(try ExternalModelPrices.parse(first), data: first, at: at.addingTimeInterval(60))
        XCTAssertEqual(cache.sourceInfo.revision, revision, "checking unchanged content does not change the price revision")
        var changed = row; changed["output_cost_per_token"] = 0.000006
        let second = try JSONSerialization.data(withJSONObject: ["new-model": changed], options: [.sortedKeys])
        cache.install(try ExternalModelPrices.parse(second), data: second, at: at.addingTimeInterval(120))
        XCTAssertNotEqual(cache.sourceInfo.revision, revision)
    }
}

extension ExternalModelPricesTests {
    func testFeedCannotReplaceBuiltInRegionalOrPeakHourModels() throws {
        let data = try JSONSerialization.data(withJSONObject: ["valid": row,
            "glm-5-turbo": row, "deepseek-flash": row])
        XCTAssertEqual(Set(try ExternalModelPrices.parse(data).keys), ["valid"])
        XCTAssertEqual(ModelCatalog.model(for: "claude-model:glm-5-turbo")?.vendor, "GLM")
        XCTAssertEqual(ModelCatalog.model(for: "claude-model:deepseek-flash")?.peakHours, true)
    }
}

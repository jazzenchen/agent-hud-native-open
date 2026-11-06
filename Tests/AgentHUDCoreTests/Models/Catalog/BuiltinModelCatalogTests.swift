import Foundation
import XCTest
@testable import AgentHUDCore

final class BuiltinModelCatalogTests: XCTestCase {
    private var document: [String: Any] {
        let rates = ["input": "1.25", "cache_write": "1.5625", "cache_read": "0.05", "output": "5"]
        return ["schema_version": 1, "checked_on": "2026-09-25", "aliases": ["sample-latest": "sample"],
            "models": ["sample": ["vendor": "Sample", "global": true, "peak_hours": false, "context_window": 272_000,
                "prices": ["international": ["rates": rates, "tiers": [["from": 272_001, "rates": rates]]]]]]]
    }
    private func decode(_ value: [String: Any]) throws -> BuiltinModelCatalog {
        try BuiltinModelCatalog(data: JSONSerialization.data(withJSONObject: value))
    }
    func testBundledSnapshotLoadsEveryCanonicalModelAndAlias() throws {
        let catalog = BuiltinModelCatalog.shared
        XCTAssertFalse(catalog.models.isEmpty)
        XCTAssertEqual(ModelCatalog.checkedOn, catalog.checkedOn)
        for (alias, target) in catalog.aliases {
            XCTAssertEqual(catalog.models[alias], catalog.models[target], alias)
        }
        XCTAssertEqual(catalog.models["glm-5-turbo"]?.global, false)
        XCTAssertEqual(catalog.models["deepseek-flash"]?.peakHours, true)
        XCTAssertEqual(catalog.models["claude-opus-5-5"]?.contextWindow, 1_000_000)
    }
    func testSnapshotPreservesDecimalRatesTiersAndAliases() throws {
        let catalog = try decode(document)
        let model = try XCTUnwrap(catalog.models["sample"])
        XCTAssertEqual(catalog.models["sample-latest"], model)
        let price = try XCTUnwrap(model.price(in: .international)?.price)
        XCTAssertEqual(price.rates.cacheWrite, Decimal(string: "1.5625")!)
        XCTAssertEqual(price.tiers.first?.from, 272_001)
    }
    func testUnknownSchemaBrokenAliasAndInvalidRatesAreRejected() throws {
        var schema = document; schema["schema_version"] = 2
        var alias = document; alias["aliases"] = ["sample-latest": "missing"]
        var collision = document; collision["aliases"] = ["sample": "sample"]
        var chained = document; chained["aliases"] = ["sample-latest": "sample", "sample-old": "sample-latest"]
        for value in [schema, alias, collision, chained] {
            XCTAssertThrowsError(try decode(value))
        }
        for invalid in ["NaN", "-1", "1 dollar", ""] {
            var value = document
            var models = try XCTUnwrap(value["models"] as? [String: Any])
            var model = try XCTUnwrap(models["sample"] as? [String: Any])
            model["prices"] = ["international": ["rates": ["input": invalid, "cache_write": "1", "cache_read": "1", "output": "1"], "tiers": []]]
            models["sample"] = model; value["models"] = models
            XCTAssertThrowsError(try decode(value))
        }
    }
    func testUnknownRegionsMissingGlobalListAndRepeatedTierThresholdsAreRejected() throws {
        var models = try XCTUnwrap(document["models"] as? [String: Any])
        var model = try XCTUnwrap(models["sample"] as? [String: Any])
        let rates = ["input": "1", "cache_write": "1", "cache_read": "1", "output": "1"]
        let cases: [[String: Any]] = [
            ["unknown": ["rates": rates, "tiers": []]],
            ["china": ["rates": rates, "tiers": []]],
            ["international": ["rates": rates, "tiers": [["from": 10, "rates": rates], ["from": 10, "rates": rates]]]],
        ]
        for prices in cases {
            model["prices"] = prices; models["sample"] = model
            var value = document; value["models"] = models
            XCTAssertThrowsError(try decode(value))
        }
    }
}

import Foundation
import XCTest
@testable import AgentHUDCore

final class WindowsPricingExportTests: XCTestCase {
    func testExport() throws {
        guard let file = ProcessInfo.processInfo.environment["WINDOWS_PRICING_EXPORT"] else { throw XCTSkip("Asset build only") }
        func decimal(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
        func rates(_ value: ModelCatalog.Rates) -> [String: String] {
            ["input": decimal(value.input), "cache_write": decimal(value.cacheWrite),
             "cache": decimal(value.cacheRead), "output": decimal(value.output)]
        }
        var models: [String: Any] = [:]
        for (name, model) in ModelCatalog.models {
            var prices: [String: Any] = [:]
            for (region, price) in model.prices {
                prices[region.rawValue] = ["currency": region.currency, "rates": rates(price.rates),
                    "tiers": price.tiers.map { ["from": $0.from, "rates": rates($0.rates)] as [String: Any] }]
            }
            models[name] = ["vendor": model.vendor, "global": model.global, "peak_hours": model.peakHours,
                            "prices": prices, "context_window": model.contextWindow as Any? ?? NSNull()]
        }
        let result: [String: Any] = ["upstreamRevision": "bf19ac98da11fe0f5967f5a124d42f0da4bf2cf9",
            "checkedOn": ModelCatalog.checkedOn, "models": models, "vendorServices": ModelCatalog.vendorServices]
        let target = URL(fileURLWithPath: file)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: target)
        print("Original price catalog: \(models.count) exact model aliases")
    }
}

import Foundation

/// The bundled offline price snapshot is data; matching and billing arithmetic stay in ModelCatalog.
struct BuiltinModelCatalog: Sendable {
    let checkedOn: String
    let models: [String: ModelCatalog.Model]
    let aliases: [String: String]

    static let shared: BuiltinModelCatalog = {
        let bundle = Bundle.main.url(forResource: "AgentHUDOpen_AgentHUDCore", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        do {
            guard let url = bundle.url(forResource: "model-prices", withExtension: "json") else { throw CatalogError.invalidData }
            return try BuiltinModelCatalog(data: Data(contentsOf: url))
        } catch {
            assertionFailure("The bundled model-price snapshot is missing or invalid: \(error)")
            // A damaged release must leave prices unavailable, rather than inventing zero-cost calls.
            return BuiltinModelCatalog(checkedOn: "Unavailable", models: [:], aliases: [:])
        }
    }()

    enum CatalogError: Error { case invalidData }
    private init(checkedOn: String, models: [String: ModelCatalog.Model], aliases: [String: String]) {
        self.checkedOn = checkedOn; self.models = models; self.aliases = aliases
    }

    init(data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1, !document.models.isEmpty,
              document.checkedOn.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw CatalogError.invalidData }
        var models: [String: ModelCatalog.Model] = [:]
        for (name, raw) in document.models {
            guard Self.validName(name), !raw.vendor.isEmpty, !raw.prices.isEmpty,
                  raw.contextWindow.map({ $0 > 0 }) ?? true else { throw CatalogError.invalidData }
            var prices: [ModelCatalog.Region: ModelCatalog.Price] = [:]
            for (key, price) in raw.prices {
                guard let region = ModelCatalog.Region(rawValue: key) else { throw CatalogError.invalidData }
                var previous = 0
                let tiers = try price.tiers.map { tier in
                    guard tier.from > previous else { throw CatalogError.invalidData }
                    previous = tier.from
                    return ModelCatalog.Price.Tier(from: tier.from, rates: try tier.rates.decoded())
                }
                prices[region] = ModelCatalog.Price(rates: try price.rates.decoded(), tiers: tiers)
            }
            guard !raw.global || prices[.international] != nil else { throw CatalogError.invalidData }
            models[name] = ModelCatalog.Model(vendor: raw.vendor, prices: prices, global: raw.global,
                contextWindow: raw.contextWindow, peakHours: raw.peakHours)
        }
        for (alias, name) in document.aliases {
            guard Self.validName(alias), models[alias] == nil, let model = models[name], document.models[name] != nil else { throw CatalogError.invalidData }
            models[alias] = model
        }
        self.init(checkedOn: document.checkedOn, models: models, aliases: document.aliases)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name == name.lowercased() && !name.contains("/") && !name.contains("#")
    }

    private struct Document: Decodable {
        let schemaVersion: Int
        let checkedOn: String
        let models: [String: Model]
        let aliases: [String: String]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", checkedOn = "checked_on", models, aliases }
    }
    private struct Model: Decodable {
        let vendor: String
        let global: Bool
        let contextWindow: Int?
        let peakHours: Bool
        let prices: [String: Price]
        enum CodingKeys: String, CodingKey { case vendor, global, contextWindow = "context_window", peakHours = "peak_hours", prices }
    }
    private struct Price: Decodable { let rates: Rates; let tiers: [Tier] }
    private struct Tier: Decodable { let from: Int; let rates: Rates }
    private struct Rates: Decodable {
        let input: String
        let cacheWrite: String
        let cacheRead: String
        let output: String
        enum CodingKeys: String, CodingKey { case input, cacheWrite = "cache_write", cacheRead = "cache_read", output }
        func decoded() throws -> ModelCatalog.Rates {
            func amount(_ value: String) throws -> Decimal {
                guard value.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                      let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
                      !number.isNaN, number >= 0, number < 1_000_000 else { throw CatalogError.invalidData }
                return number
            }
            return try ModelCatalog.Rates(input: amount(input), cacheWrite: amount(cacheWrite), cacheRead: amount(cacheRead), output: amount(output))
        }
    }
}

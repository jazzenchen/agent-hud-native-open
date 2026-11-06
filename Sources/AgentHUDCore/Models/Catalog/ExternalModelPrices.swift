import CryptoKit
import CoreFoundation
import Foundation

/// Only price data is fetched. No SDK, remote code, API keys, usage, or account data is needed.
public struct ModelPriceSourceInfo: Hashable, Sendable {
    public let source: String
    public let updatedAt: Date?
    public let modelCount: Int
    public let revision: String
}

final class ExternalModelPrices: @unchecked Sendable {
    static let shared = ExternalModelPrices()
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static var cacheURL: URL { AppSupport.directory.appendingPathComponent("model-prices-litellm.json") }
    private let lock = NSLock()
    private var models: [String: ModelCatalog.Model] = [:]
    private var info = ModelPriceSourceInfo(source: "Built-in", updatedAt: nil, modelCount: 0, revision: "builtin-1")

    init(cacheURL: URL? = ExternalModelPrices.cacheURL) {
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let parsed = try? Self.parse(data), !parsed.isEmpty {
            let date = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            install(parsed, data: data, at: date)
        }
    }

    func model(named name: String) -> ModelCatalog.Model? { lock.withLock { models[name] } }
    var sourceInfo: ModelPriceSourceInfo { lock.withLock { info } }
    func install(_ parsed: [String: ModelCatalog.Model], data: Data, at date: Date?) {
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            models = parsed
            info = ModelPriceSourceInfo(source: "LiteLLM", updatedAt: date, modelCount: parsed.count, revision: revision)
        }
    }

    enum FeedError: Error { case invalidData }
    /// Adapt official global lists only. Keep the existing regional/peak-hour rules when a feed cannot express them.
    /// Provider routes and aliases are never flattened into a vendor's own price.
    static func parse(_ data: Data) throws -> [String: ModelCatalog.Model] {
        guard data.count <= 15_000_000, let rows = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedError.invalidData
        }
        let vendors = ["openai": "OpenAI", "anthropic": "Anthropic", "gemini": "Google", "xai": "xAI"]
        var result: [String: ModelCatalog.Model] = [:]
        for key in rows.keys.sorted() {
            guard let row = rows[key] as? [String: Any], let provider = row["litellm_provider"] as? String,
                  let vendor = vendors[provider], row["mode"] as? String == "chat" else { continue }
            let name = key.hasPrefix(provider + "/") ? String(key.dropFirst(provider.count + 1)) : key
            if let builtIn = ModelCatalog.models[name],
               builtIn.vendor != vendor || !builtIn.global || builtIn.peakHours { continue }
            guard !name.contains("/"), !name.contains("#"), name == name.lowercased(),
                  let input = rate(row, "input_cost_per_token"), let output = rate(row, "output_cost_per_token") else { continue }
            let writeKey = provider == "anthropic" ? "cache_creation_input_token_cost_above_1hr" : "cache_creation_input_token_cost"
            let readKey = "cache_read_input_token_cost"
            guard (row[readKey] == nil || rate(row, readKey) != nil),
                  (row[writeKey] == nil || rate(row, writeKey) != nil) else { continue }
            let read = rate(row, readKey) ?? input
            let write = rate(row, writeKey) ?? (provider == "anthropic" ? input * 2 : input)
            let base = ModelCatalog.Rates(input: input, cacheWrite: write, cacheRead: read, output: output)
            var tiers: [ModelCatalog.Price.Tier] = []
            var complete = true
            for field in row.keys.sorted() where field.hasPrefix("input_cost_per_token_above_") && field.hasSuffix("k_tokens") {
                let suffix = String(field.dropFirst("input_cost_per_token".count))
                let number = suffix.dropFirst("_above_".count).dropLast("k_tokens".count)
                guard let thousands = Int(number), (1...10_000).contains(thousands),
                      let longInput = rate(row, field), let longOutput = rate(row, "output_cost_per_token" + suffix) else {
                    complete = false; break
                }
                let longRead = rate(row, readKey + suffix) ?? (row[readKey] == nil ? longInput : nil)
                let longWrite = rate(row, writeKey + suffix) ?? (row[writeKey] == nil ? (provider == "anthropic" ? longInput * 2 : longInput) : nil)
                guard let longRead, let longWrite else { complete = false; break }
                tiers.append(.init(from: thousands * 1000 + 1,
                    rates: .init(input: longInput, cacheWrite: longWrite, cacheRead: longRead, output: longOutput)))
            }
            guard complete else { continue }
            result[name] = ModelCatalog.Model(vendor: vendor,
                prices: [.international: .init(rates: base, tiers: tiers.sorted { $0.from < $1.from })], global: true,
                contextWindow: ModelCatalog.models[name]?.contextWindow, peakHours: false)
        }
        guard !result.isEmpty else { throw FeedError.invalidData }
        return result
    }

    private static func rate(_ row: [String: Any], _ key: String) -> Decimal? {
        guard let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, (0...1).contains(value.doubleValue),
              let decimal = Decimal(string: value.stringValue, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return decimal * 1_000_000
    }
}

public actor ModelPriceFeed {
    public static let shared = ModelPriceFeed()
    private var lastAttempt: Date?
    public nonisolated static var sourceInfo: ModelPriceSourceInfo { ExternalModelPrices.shared.sourceInfo }

    /// Daily checks, one-hour retry after failure. A broken download leaves the last validated cache in service.
    public func refreshIfNeeded(now: Date = Date()) async {
        if let at = Self.sourceInfo.updatedAt, now.timeIntervalSince(at) < 86400 { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return }
        lastAttempt = now
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: ExternalModelPrices.sourceURL)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let parsed = try ExternalModelPrices.parse(data)
            let url = ExternalModelPrices.cacheURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            ExternalModelPrices.shared.install(parsed, data: data, at: now)
        } catch { /* Last known good prices, then the built-in list, remain available offline. */ }
    }
}

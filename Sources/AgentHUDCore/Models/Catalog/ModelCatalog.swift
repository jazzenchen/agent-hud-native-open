import Foundation

/// API list prices and context windows of the models agents call, for an estimate of what their calls would cost at the
/// vendor's API and how full a session's context is. Prices are per million tokens at the vendors' published rates, as
/// checked on `checkedOn`. A model missing here has no estimate; nothing is guessed from a name it does not carry exactly.
public enum ModelCatalog {
    public static let checkedOn = "2026-09-25"

    /// The platforms a vendor sells on: its international one, priced in US dollars, and its China-mainland one, priced in
    /// yuan, where the two lists differ. A vendor with one list for everyone has it as `international`.
    public enum Region: String, CaseIterable, Codable, Sendable {
        case international, china

        public var currency: String { self == .china ? "CNY" : "USD" }
    }

    public struct Rates: Hashable, Sendable {
        public let input: Decimal
        public let cacheWrite: Decimal
        public let cacheRead: Decimal
        /// Reasoning is billed as output everywhere.
        public let output: Decimal
    }

    /// One platform's list: the base rates and, for a call whose prompt reaches a tier, that tier's rates.
    public struct Price: Hashable, Sendable {
        public struct Tier: Hashable, Sendable {
            /// The shortest prompt, in tokens, the tier applies to.
            public let from: Int
            public let rates: Rates
        }

        public let rates: Rates
        /// Ascending by `from`.
        public let tiers: [Tier]

        public func rates(prompt: Int) -> Rates { rates(tier: tier(prompt: prompt)) }

        /// The tier a prompt of `prompt` tokens reaches, as an index into `tiers`; nil below the first.
        func tier(prompt: Int) -> Int? { tiers.lastIndex { prompt >= $0.from } }

        /// The rates of a tier `tier(prompt:)` found.
        func rates(tier: Int?) -> Rates { tier.map { tiers[$0].rates } ?? rates }
    }

    public struct Model: Hashable, Sendable {
        public let vendor: String
        public let prices: [Region: Price]
        /// One list for everyone, whichever platform a call went through.
        public let global: Bool
        /// The published window; nil where the client reports it with every call.
        public let contextWindow: Int?
        /// DeepSeek bills twice its off-peak rates in Beijing working hours.
        public let peakHours: Bool

        /// The list a call on `region` is priced by: that platform's, or the one list of a global vendor. A regional
        /// model a platform does not sell has no price there.
        public func price(in region: Region) -> (price: Price, region: Region)? {
            if let price = prices[region] { return (price, region) }
            return global ? prices[.international].map { ($0, .international) } : nil
        }
    }

    /// An amount of money and its currency; list prices are never converted.
    public struct Cost: Hashable, Sendable {
        public let amount: Decimal
        public let currency: String
    }

    /// What some usage would cost at list price, per currency, and the models that had tokens but no price.
    public struct ListCost: Hashable, Sendable {
        public var amounts: [String: Decimal] = [:]
        public var unpriced: [String] = []

        /// "≈$12.30 · ≈¥45.60": US dollars first, each currency as it was priced.
        public var text: String {
            amounts.keys.sorted { $0 == "USD" || ($1 != "USD" && $0 < $1) }
                .map { "≈" + MoneyFormat.amount(amounts[$0]!, currency: $0) }.joined(separator: " · ")
        }
    }

    /// What each kind of some tokens would cost at list price, all in the currency of the list that priced them.
    public struct KindCosts: Hashable, Sendable {
        public let currency: String
        /// The kinds that had tokens; a kind without tokens is absent.
        public let amounts: [TokenKind: Decimal]

        public var total: Decimal { amounts.values.reduce(0, +) }
    }

    /// The catalog name of a consumer id: the model its client called, after the client's `<source>-model:` prefix and
    /// before a `#` that names the provider the call went through, without a dated snapshot suffix or Claude Code's 1M
    /// marker. Whichever client made the call, the same model has the same list price, so Claude Code pointed at
    /// DeepSeek's API prices its calls as DeepSeek's. A gateway's name for a model, such as `openai/gpt-5.5`, names a
    /// model the gateway sells at its own price, so it has none here.
    static func name(of agentId: String) -> String? {
        guard let prefix = agentId.range(of: "-model:") else { return nil }
        var name = agentId[prefix.upperBound...].prefix { $0 != "#" }.lowercased()
        if name.hasSuffix("[1m]") { name.removeLast(4) }
        if let date = name.range(of: #"-[0-9]{8}$|-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) { name.removeSubrange(date) }
        return name.isEmpty ? nil : name
    }

    /// Models their vendor sells as a product under a name of its own, by the id clients log, with the routes that are
    /// that product's own services.
    static let products: [String: (name: String, services: Set<String>)] = [
        // Kimi Code's plan model, which Kimi's docs and OpenCode's list of providers call Kimi For Coding.
        "kimi-for-coding": ("Kimi For Coding", ["kimi-code", "kimi-coding", "kimi-for-coding", "kimi-code-plan-cn", "kimi-code-plan-global"]),
    ]

    /// A consumer's name as every surface writes it, from its id alone: the model its client logged, after the client's
    /// `<source>-model:` prefix, then " · " and the route after `#` that the calls went through, unless the name already
    /// shows the route. A route that prefixes the model (`kimi-code/kimi-for-coding` through `kimi-code`) is left out of
    /// both, a model its vendor sells under a name of its own reads as that name, without the route where the route is
    /// one of the product's own services (Kimi For Coding), and a Claude Code model reads as its family and version
    /// (Opus 4.5). An id without a model is its own name.
    public static func consumerName(of agentId: String) -> String {
        guard let marker = agentId.range(of: "-model:") else { return agentId }
        let rest = agentId[marker.upperBound...]
        var name = String(rest.prefix { $0 != "#" })
        let route = rest.firstIndex(of: "#").map { String(rest[rest.index(after: $0)...]) } ?? ""
        var showsRoute = route.isEmpty
        if !route.isEmpty, name.lowercased().hasPrefix(route.lowercased() + "/") {
            name.removeFirst(route.count + 1)
            showsRoute = true
        }
        if name.isEmpty { name = "Unknown" }
        if let product = products[name.lowercased()] {
            name = product.name
            showsRoute = showsRoute || product.services.contains(route.lowercased())
        } else if agentId[..<marker.lowerBound] == "claude", let model = ClaudeModelInfo.parse(name) {
            name = model.displayName
        }
        return showsRoute ? name : name + " · " + route
    }

    /// The model a consumer called, where its list price applies: a consumer that names the provider it went through is
    /// priced only when that provider is the vendor's own API or plan (`vendorServices`).
    public static func model(for agentId: String) -> Model? {
        guard let model = listed(agentId) else { return nil }
        guard let mark = agentId.firstIndex(of: "#") else { return model }
        return vendorServices[String(agentId[agentId.index(after: mark)...])] == model.vendor ? model : nil
    }

    /// The model a consumer called, whichever provider served it.
    private static func listed(_ agentId: String) -> Model? {
        name(of: agentId).flatMap { ExternalModelPrices.shared.model(named: $0) ?? models[$0] }
    }

    /// What one call would cost at list price on the platform it went through, in that platform's currency: at the tier
    /// its prompt reaches, and at DeepSeek's peak rates when made in Beijing working hours. nil when the model has no
    /// price there.
    public static func cost(agentId: String, kinds: TokenKinds, region: Region = .international, at date: Date? = nil) -> Cost? {
        guard let listing = listing(for: agentId, in: region) else { return nil }
        return cost(kinds, tier: listing.tier(of: kinds), on: listing, at: date)
    }

    /// A consumer's model and the list its calls are priced by on one platform, looked up once for any number of calls.
    struct Listing {
        let model: Model
        let price: Price
        let region: Region

        /// The tier a call's prompt reaches: its input, cache writes and cache reads.
        func tier(of call: TokenKinds) -> Int? { price.tier(prompt: call.input + call.cacheWrite + call.cacheRead) }
    }

    /// The list a consumer's calls are priced by on `region`; nil when its model has no price there.
    static func listing(for agentId: String, in region: Region = .international) -> Listing? {
        guard let model = model(for: agentId), let list = model.price(in: region) else { return nil }
        return Listing(model: model, price: list.price, region: list.region)
    }

    /// What calls whose prompts reach the same `tier` would cost together, all made at `date`: what each would cost on
    /// its own, added up, since every rate is per token.
    static func cost(_ kinds: TokenKinds, tier: Int?, on listing: Listing, at date: Date? = nil) -> Cost {
        Cost(amount: amount(kinds, at: listing.price.rates(tier: tier)) * factor(listing.model, at: date), currency: listing.region.currency)
    }

    /// What calls counted together would cost. A sum says nothing of any one call's prompt, so it is priced at the base
    /// rates; `date` is when the calls were made, for DeepSeek's peak hours.
    public static func cost(agentId: String, summed kinds: TokenKinds, region: Region = .international, at date: Date? = nil) -> Cost? {
        guard let model = model(for: agentId), let list = model.price(in: region) else { return nil }
        return Cost(amount: amount(kinds, at: list.price.rates) * factor(model, at: date), currency: list.region.currency)
    }

    /// Each model's counted tokens at list price, on the platform `region` names for it, added up per currency. `peak` is
    /// the part of those tokens counted in DeepSeek's peak hours. nil when no model with tokens has a price.
    public static func cost(of tokens: [String: TokenKinds], peak: [String: TokenKinds] = [:],
                            region: (String) -> Region = { _ in .international }) -> ListCost? {
        var cost = ListCost(), priced = false
        for (agentId, kinds) in tokens where !kinds.isEmpty {
            guard let model = model(for: agentId), let list = model.price(in: region(agentId)) else {
                cost.unpriced.append(agentId)
                continue
            }
            let busy = model.peakHours ? peak[agentId] ?? TokenKinds() : TokenKinds()
            cost.amounts[list.region.currency, default: 0] += amount(kinds - busy, at: list.price.rates) + amount(busy, at: list.price.rates) * 2
            priced = true
        }
        cost.unpriced.sort()
        return priced ? cost : nil
    }

    /// What a usage bucket's tokens would cost at list price, kind by kind, on the platform `regions` finds its client on:
    /// the China list in yuan for a client on the China platform, the international list in US dollars otherwise, and
    /// DeepSeek's peak rates for a bucket that starts in its peak hours. A bucket sums calls, so it is priced at the base
    /// rates, as the Tokens page prices its buckets. nil when the model has no list price on that platform.
    public static func cost(of bucket: UsageBucket, regions: PriceRegions) -> KindCosts? {
        guard let model = model(for: bucket.agentId), let list = model.price(in: regions.region(for: bucket.agentId)) else { return nil }
        let rates = list.price.rates, kinds = bucket.kinds, factor = factor(model, at: bucket.start)
        var amounts: [TokenKind: Decimal] = [:]
        for kind in TokenKind.allCases where kinds[kind] > 0 {
            let rate: Decimal = switch kind {
            case .input: rates.input
            case .cacheWrite: rates.cacheWrite
            case .cacheRead: rates.cacheRead
            case .output, .reasoning: rates.output
            }
            amounts[kind] = Decimal(kinds[kind]) * rate * factor / 1_000_000
        }
        return KindCosts(currency: list.region.currency, amounts: amounts)
    }

    private static func amount(_ kinds: TokenKinds, at rates: Rates) -> Decimal {
        (Decimal(kinds.input) * rates.input + Decimal(kinds.cacheWrite) * rates.cacheWrite
            + Decimal(kinds.cacheRead) * rates.cacheRead + Decimal(kinds.output + kinds.reasoning) * rates.output) / 1_000_000
    }

    private static func factor(_ model: Model, at date: Date?) -> Decimal {
        model.peakHours && date.map(isPeak) == true ? 2 : 1
    }

    /// DeepSeek's peak hours: 9:00–12:00 and 14:00–18:00 Beijing time, Monday to Friday. Its Chinese public holidays are
    /// off-peak too; the catalog does not know them, so they count as peak.
    public static func isPeak(_ date: Date) -> Bool {
        let day = beijing.component(.weekday, from: date), hour = beijing.component(.hour, from: date)
        return (2...6).contains(day) && ((9..<12).contains(hour) || (14..<18).contains(hour))
    }

    private static let beijing: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()

    /// The context window a call ran in: what the client reported, else the published window. Claude Code does not
    /// report it, and a Claude model runs with 200K or 1M, so a model this Mac has seen hold more than 200K counts as 1M.
    public static func contextWindow(agentId: String, reported: Int?, largestSeen: Int?) -> Int? {
        if let reported, reported > 0 { return reported }
        let published = listed(agentId)?.contextWindow ?? (agentId.hasPrefix("claude-model:") ? 200_000 : nil)
        guard let published else { return nil }
        return (largestSeen ?? 0) > published ? max(published, 1_000_000) : published
    }
}

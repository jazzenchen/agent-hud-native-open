import Foundation

/// What a window's reading and recent pace say about the rest of its cycle, weighed in the order of the cases: a
/// window without a reset has no outlook, an empty one is exhausted, one of unknown length has no estimate, and a pace
/// of nothing is no usage.
public enum QuotaOutlook: Hashable, Sendable {
    /// The window has no reset time.
    case untimed
    /// Nothing is left.
    case exhausted
    /// The window's length is unknown, so there is no pace to go by.
    case noEstimate
    /// The recent pace uses nothing.
    case noUsage
    /// The readings give no time for the window to run out.
    case insufficientData
    /// At the recent pace the rest lasts `in` seconds; `beforeReset` says whether that ends before the window resets.
    case exhausts(in: TimeInterval, beforeReset: Bool)
}

/// Quota calculations shared by the providers, the store, the alerts and the desktop, as pure functions of readings
/// and time.
public enum QuotaMath {
    /// The share of a window left when its service reports the share used, kept within 0...100.
    public static func remaining(usedPercent: Double) -> Double {
        max(0, min(100, 100 - usedPercent))
    }

    /// Where a window's insights start reading its stored readings, for every provider whatever the statistics range: a
    /// week back, or the start of its current cycle when that is earlier, so the burn rate of a longer window sees its
    /// whole cycle. A week back for a window without a reading.
    public static func historyStart(for snapshot: UsageSnapshot?, now: Date) -> Date {
        let lookback = now.addingTimeInterval(-AlertPolicy.insightsLookback)
        return min(lookback, snapshot?.cycle?.start ?? lookback)
    }

    /// A window's burn rate, how long its rest lasts at that rate, and the times it hit its cap, from its stored readings
    /// since `historyStart(for:now:)`. The burn rate takes the readings of the current cycle; cap hits are counted over
    /// the last week. Without a reading there is no burn rate, only cap hits. A series too short for a burn rate has its
    /// sampling progress instead.
    public static func insights(snapshot: UsageSnapshot?, samples: [QuotaSample], now: Date) -> UsageInsights {
        let pace: (burnRate: BurnRate?, sampling: QuotaSampling?) = snapshot?.remainingPct == nil ? (nil, nil)
            : UsageAnalytics.pace(samples: samples, cycle: snapshot?.cycle, now: now)
        let burn = pace.burnRate
        let week = now.addingTimeInterval(-AlertPolicy.insightsLookback)
        let caps = UsageAnalytics.capStats(samples: samples.filter { $0.timestamp >= week }, now: now)
        return UsageInsights(burnRatePctPerHour: burn?.pctPerHour,
                             timeToExhaust: snapshot.flatMap(\.remainingPct).flatMap { burn?.timeToExhaust(remainingPct: $0) },
                             weeklyCapHits: caps.hits, weeklyWaitTotal: caps.totalWait,
                             weeklyWaitLongest: caps.longestWait, weeklyWaitLongestAt: caps.longestAt,
                             sampling: pace.sampling)
    }

    /// The window's outlook at `now`.
    public static func outlook(snapshot: UsageSnapshot, insights: UsageInsights?, now: Date) -> QuotaOutlook {
        guard snapshot.resetAt != nil else { return .untimed }
        guard let remaining = snapshot.remainingPct else { return .noEstimate }
        if remaining <= AlertPolicy.exhaustedRemaining { return .exhausted }
        guard snapshot.cycle != nil else { return .noEstimate }
        if insights?.burnRatePctPerHour == 0 { return .noUsage }
        guard let exhaustion = exhaustion(insights: insights, resetAt: snapshot.resetAt, now: now) else { return .insufficientData }
        return .exhausts(in: exhaustion.interval, beforeReset: exhaustion.beforeReset)
    }

    /// How long a window's rest lasts at its recent pace, and whether that ends before the window resets, whatever
    /// else the outlook weighs first. A window without a reset counts as running out before it. Nil when the pace
    /// gives no time.
    public static func exhaustion(insights: UsageInsights?, resetAt: Date?, now: Date) -> (interval: TimeInterval, beforeReset: Bool)? {
        guard let interval = insights?.timeToExhaust, interval > 0, interval.isFinite else { return nil }
        return (interval, resetAt.map { interval < $0.timeIntervalSince(now) } ?? true)
    }

    /// The share of the window used by its reset at the recent pace, at most all of it. Nil without a pace or a reset
    /// still ahead.
    public static func projectedUsedAtReset(usedPct: Double, insights: UsageInsights?, resetAt: Date?, now: Date) -> Double? {
        guard let rate = insights?.burnRatePctPerHour, let resetAt, resetAt > now else { return nil }
        return min(100, usedPct + rate * resetAt.timeIntervalSince(now) / 3600)
    }

    /// Tokens per hour the window's consumers spent over the observed part of its current cycle; usage from before
    /// `usage` begins is not guessed at.
    public static func tokensPerHour(snapshot: UsageSnapshot, consumers: Set<String>, usage: [UsageBucket], now: Date) -> Double? {
        guard !consumers.isEmpty, let cycle = snapshot.cycle, let oldest = usage.first?.start else { return nil }
        let start = max(cycle.start, oldest)
        let hours = now.timeIntervalSince(start) / 3600
        guard hours > 0 else { return nil }
        let tokens = usage.reduce(0) { total, bucket in
            consumers.contains(bucket.agentId) && bucket.start >= start && bucket.start < now ? total + bucket.total : total
        }
        return (Double(tokens) / hours).rounded()
    }

    /// The tokens the window's consumers spent over the observed part of its current cycle; usage from before `usage`
    /// begins is not guessed at. Nil where the cycle is unknown or there are no consumers.
    public static func tokensTotal(snapshot: UsageSnapshot, consumers: Set<String>, usage: [UsageBucket], now: Date) -> Int? {
        guard !consumers.isEmpty, let cycle = snapshot.cycle, let oldest = usage.first?.start else { return nil }
        let start = max(cycle.start, oldest)
        let tokens = usage.reduce(0) { total, bucket in
            consumers.contains(bucket.agentId) && bucket.start >= start && bucket.start < now
                ? total + bucket.total + bucket.cacheReadTokens : total
        }
        return tokens
    }

    /// How far apart two calls can sit before the stretch between them reads as idle rather than generation: past it
    /// the span belongs to the person or a tool run the log cannot time, not to the model replying.
    public static let replyGapCap: TimeInterval = 120

    /// Output tokens per second of replying. A call whose log recorded its own time (queue + first token + decode)
    /// times itself; one without falls back to the gap since the previous call in its own log, capped at
    /// `replyGapCap`, with longer gaps idle. Calls are grouped by contribution so two sessions' timelines never
    /// borrow each other's spans. Per-sample guards drop bursts (span < 100ms, rate > 10000/s, output < 10 tokens)
    /// and stalls (span > 10min). Other models' calls keep their place in the log; only a selected consumer's call
    /// adds its output and span. Nil when no call qualifies.
    public static func replyRate(events: [UsageLedger.ReplyEvent], consumers: Set<String>) -> QuotaReplyRate? {
        var byLog: [Int64: [UsageLedger.ReplyEvent]] = [:]
        for event in events {
            byLog[event.contribution, default: []].append(event)
        }
        var out = 0, span = 0.0, calls = 0
        for events in byLog.values {
            let sorted = events.sorted { $0.atMs < $1.atMs }
            for (index, after) in sorted.enumerated() {
                guard consumers.contains(after.agent), after.out >= 10 else { continue }
                // A recorded duration is the call's own time and may run minutes; a gap since the previous call is
                // the nearest measure where none was recorded, so it keeps the idle cap, and a log's first call has
                // no measure at all.
                let seconds = after.durationMs.map { Double($0) / 1000 }
                    ?? (index > 0 ? Double(after.atMs - sorted[index - 1].atMs) / 1000 : 0)
                let cap = after.durationMs != nil ? 600.0 : replyGapCap
                guard seconds >= 0.1, seconds <= cap else { continue }
                guard Double(after.out) / seconds <= 10_000 else { continue }
                out += after.out
                span += seconds
                calls += 1
            }
        }
        guard span > 0 else { return nil }
        return QuotaReplyRate(tokensPerSecond: Double(out) / span, calls: calls, tokensOut: out)
    }

    /// What the tokens the window's consumers spent over the observed part of its current cycle would cost at list
    /// price, currency by currency. An estimate: a subscription is not billed by the token, and a model without a list
    /// price is left out. Nil when the cycle is unknown or nothing priced was spent in it.
    public static func listCost(snapshot: UsageSnapshot, consumers: Set<String>, usage: [UsageBucket], regions: PriceRegions,
                                now: Date) -> QuotaListCost? {
        guard !consumers.isEmpty, let cycle = snapshot.cycle, let oldest = usage.first?.start else { return nil }
        let start = max(cycle.start, oldest)
        let hours = now.timeIntervalSince(start) / 3600
        guard hours > 0 else { return nil }
        var amounts: [String: Decimal] = [:]
        for bucket in usage where consumers.contains(bucket.agentId) && bucket.start >= start && bucket.start < now {
            guard let cost = ModelCatalog.cost(of: bucket, regions: regions) else { continue }
            amounts[cost.currency, default: 0] += cost.total
        }
        return amounts.isEmpty ? nil : QuotaListCost(amounts: amounts, hours: hours)
    }
}

/// A quota window's consumed amount over the observed part of its current cycle, in the window's own unit (tokens,
/// credits, minutes), with the cycle's size where the source reports one.
public struct QuotaConsumption: Hashable, Sendable {
    public let used: Int64
    public let capacity: Int64?

    public init(used: Int64, capacity: Int64? = nil) {
        self.used = used
        self.capacity = capacity
    }
}

/// How fast a window's models reply: their output tokens per second of active turn, so the idle stretches between
/// prompts weigh nothing. A turn's span ends at its last call, so tool time inside a turn counts as active.
public struct QuotaReplyRate: Hashable, Codable, Sendable {
    public let tokensPerSecond: Double
    /// How many calls the rate averages over.
    public let calls: Int
    /// The output tokens those calls produced.
    public let tokensOut: Int

    public init(tokensPerSecond: Double, calls: Int, tokensOut: Int) {
        self.tokensPerSecond = tokensPerSecond
        self.calls = calls
        self.tokensOut = tokensOut
    }
}

/// The list price of what a quota window's consumers spent over the observed part of its current cycle. Currencies
/// stay apart and are never converted or added.
public struct QuotaListCost: Hashable, Sendable {
    /// The amount in each currency that had priced tokens.
    public let amounts: [String: Decimal]
    /// How long the observed part of the cycle is, in hours; above zero.
    public let hours: Double

    public init(amounts: [String: Decimal], hours: Double) {
        self.amounts = amounts
        self.hours = hours
    }

    /// The currencies in code order, so the one shown first does not change from pass to pass.
    public var currencies: [String] { amounts.keys.sorted() }

    /// The amount spent per hour in a currency over the observed part of the cycle.
    public func perHour(_ currency: String) -> Decimal? {
        amounts[currency].map { $0 / Decimal(hours) }
    }
}

public extension ReportView {
    /// What this quota window's tokens over the observed part of its current cycle would cost at list price: an
    /// estimate, since a subscription is not billed by the token.
    func listCost(for agentId: String) -> QuotaListCost? {
        guard counts(agentId), let report, let snapshot = report.snapshot(for: agentId),
              let consumers = report.consumerIdsByQuota[agentId] else { return nil }
        return QuotaMath.listCost(snapshot: snapshot, consumers: consumers, usage: report.usage,
                                  regions: PriceRegions(report: report), now: now)
    }
}

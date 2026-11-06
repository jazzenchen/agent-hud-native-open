import Foundation

/// Two quota readings in the same uninterrupted series. Optional in reports predating capacity estimates.
public struct QuotaObservation: Hashable, Codable, Sendable {
    public let start: Date
    public let end: Date
    public let remainingAtStart: Double
    public let remainingAtEnd: Double
    public init(start: Date, end: Date, remainingAtStart: Double, remainingAtEnd: Double) {
        self.start = start; self.end = end; self.remainingAtStart = remainingAtStart; self.remainingAtEnd = remainingAtEnd
    }
}

/// Full-window projections from local usage and quota consumption over exactly the same observed interval.
public struct QuotaCapacityEstimate: Hashable, Sendable {
    public let tokens: Int
    public let amounts: [String: Decimal]?
    public let hasUnpricedUsage: Bool
    public init(tokens: Int, amounts: [String: Decimal]?, hasUnpricedUsage: Bool = false) {
        self.tokens = tokens; self.amounts = amounts; self.hasUnpricedUsage = hasUnpricedUsage
    }
}

extension UsageAnalytics {
    /// Share the pace's observed interval, never crossing an early reset, an upward adjustment or a long gap.
    static func capacityObservation(samples: [QuotaSample], cycle: QuotaCycle?, now: Date) -> QuotaObservation? {
        guard let cycle, now >= cycle.start, now < cycle.resetAt else { return nil }
        let sampled = sampledQuota(samples, cycle: cycle, now: now)
        guard let earliest = sampled.first, let last = sampled.last else { return nil }
        let first = sampled.last { $0.timestamp <= last.timestamp.addingTimeInterval(-cycle.paceInterval) } ?? earliest
        guard last.timestamp.timeIntervalSince(first.timestamp) >= cycle.sampleInterval else { return nil }
        let raw = samples.filter { $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp }
            .sorted { $0.timestamp < $1.timestamp }
        guard !zip(raw, raw.dropFirst()).contains(where: { before, after in
            after.timestamp.timeIntervalSince(before.timestamp) > 6 * 3600 || after.remainingPct > before.remainingPct
        }) else { return nil }
        return QuotaObservation(start: first.timestamp, end: last.timestamp,
            remainingAtStart: first.remainingPct, remainingAtEnd: last.remainingPct)
    }
}

extension QuotaMath {
    /// Quarter-hour buckets cannot be split by a quota reading's timestamp. If either edge cuts nonempty usage,
    /// wait for a clean interval instead of attributing a whole bucket or inventing a time-proportional split.
    public static func capacityEstimate(snapshot: UsageSnapshot, observation: QuotaObservation?, consumers: Set<String>,
                                        usage: [UsageBucket], regions: PriceRegions, now: Date) -> QuotaCapacityEstimate? {
        guard let observation, let cycle = snapshot.cycle, !consumers.isEmpty,
              observation.start >= cycle.start, observation.start < observation.end,
              observation.end <= snapshot.updatedAt, snapshot.updatedAt <= now, now < cycle.resetAt,
              let remaining = snapshot.remainingPct, abs(remaining - observation.remainingAtEnd) < 0.000001,
              observation.remainingAtStart.isFinite, observation.remainingAtEnd.isFinite,
              (0...100).contains(observation.remainingAtStart), (0...100).contains(observation.remainingAtEnd),
              let oldest = usage.map(\.start).min(), oldest <= observation.start else { return nil }
        let consumed = observation.remainingAtStart - observation.remainingAtEnd
        guard (5...100).contains(consumed) else { return nil }
        var tokens = 0, amounts: [String: Decimal] = [:], unpriced = false
        for bucket in usage where consumers.contains(bucket.agentId) && bucket.start < observation.end && bucket.end > observation.start {
            let (fresh, freshOverflow) = bucket.tokensIn.addingReportingOverflow(bucket.tokensOut)
            let (total, overflow) = fresh.addingReportingOverflow(bucket.cacheReadTokens)
            guard !freshOverflow, !overflow, bucket.tokensIn >= 0, bucket.tokensOut >= 0, bucket.cacheReadTokens >= 0 else { return nil }
            guard total > 0 else { continue }
            guard bucket.start >= observation.start, bucket.end <= observation.end else { return nil }
            let (sum, sumOverflow) = tokens.addingReportingOverflow(total)
            guard !sumOverflow else { return nil }
            tokens = sum
            if let cost = ModelCatalog.cost(of: bucket, regions: regions) { amounts[cost.currency, default: 0] += cost.total }
            else { unpriced = true }
        }
        let estimate = (Double(tokens) * 100 / consumed).rounded()
        guard estimate.isFinite, estimate > 0, estimate < Double(Int.max) else { return nil }
        let priced = QuotaListCost(amounts: amounts, hours: observation.end.timeIntervalSince(observation.start) / 3600,
                                  hasUnpricedUsage: unpriced).estimatedCapacity(usedPercent: consumed)
        return QuotaCapacityEstimate(tokens: Int(estimate), amounts: priced, hasUnpricedUsage: unpriced)
    }
}

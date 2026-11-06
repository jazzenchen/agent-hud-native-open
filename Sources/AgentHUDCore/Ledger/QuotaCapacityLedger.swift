import Foundation
import AgentHUDSupport

struct QuotaCapacityLedgerKey: Hashable {
    let observation: QuotaObservation
    let consumers: Set<String>
}
struct QuotaCapacityLedgerGroup: Hashable {
    let quarter: Int64
    let consumer: String
}
struct QuotaCapacityLedgerCalls {
    let tokens: Int
    let groups: [QuotaCapacityLedgerGroup: TokenKinds]
}
struct QuotaCapacityLedgerCache {
    let mark: Int
    let generation: Int
    var values: [QuotaCapacityLedgerKey: QuotaCapacityLedgerCalls] = [:]
}

extension UsageLedger {
    /// Match raw calls in (start, end] to the quota readings. Missing calls contribute nothing.
    /// Cache counts only, so each projection uses the catalog's current prices without depending on a price provider.
    public func quotaCapacityEstimate(snapshot: UsageSnapshot, observation: QuotaObservation?, consumers: Set<String>,
                                      regions: PriceRegions, now: Date) throws -> QuotaCapacityEstimate? {
        guard let observation,
              let consumed = QuotaMath.capacityConsumed(snapshot: snapshot, observation: observation, consumers: consumers, now: now),
              let calls = try quotaCapacityCalls(observation: observation, consumers: consumers) else { return nil }
        let projected = (Double(calls.tokens) * 100 / consumed).rounded()
        guard projected.isFinite, projected > 0, projected < Double(Int.max) else { return nil }
        let listings = Dictionary(uniqueKeysWithValues: consumers.compactMap { id in
            ModelCatalog.listing(for: id, in: regions.region(for: id)).map { (id, $0) }
        })
        var amounts: [String: Decimal] = [:], unpriced = false
        for (group, kinds) in calls.groups {
            if let listing = listings[group.consumer] {
                // Keep the HUD's base-rate cost convention and the buckets' peak-hour timestamp.
                let cost = ModelCatalog.cost(kinds, tier: nil, on: listing, at: RecordCoding.date(group.quarter))
                amounts[cost.currency, default: 0] += cost.amount
            } else { unpriced = true }
        }
        let money = QuotaListCost(amounts: amounts, hours: observation.end.timeIntervalSince(observation.start) / 3600,
                                 hasUnpricedUsage: unpriced).estimatedCapacity(usedPercent: consumed)
        return QuotaCapacityEstimate(tokens: Int(projected), amounts: money, hasUnpricedUsage: unpriced)
    }

    private func quotaCapacityCalls(observation: QuotaObservation, consumers: Set<String>) throws -> QuotaCapacityLedgerCalls? {
        if quotaCapacityRead?.mark != writeMark || quotaCapacityRead?.generation != generation {
            quotaCapacityRead = QuotaCapacityLedgerCache(mark: writeMark, generation: generation)
        }
        let key = QuotaCapacityLedgerKey(observation: observation, consumers: consumers)
        if let cached = quotaCapacityRead?.values[key] { return cached }
        let ids = String(decoding: try JSONEncoder().encode(consumers.sorted()), as: UTF8.self)
        var tokens = 0, groups: [QuotaCapacityLedgerGroup: TokenKinds] = [:], invalid = false
        try storage.connection.query("""
            SELECT e.timestamp_ms, a.name, e.tokens_in, e.tokens_out, e.cache_read, e.cache_write, e.reasoning
            FROM usage_event e JOIN contribution c ON c.id = e.contribution_id JOIN agent a ON a.id = e.agent
            WHERE c.counted = 1 AND e.timestamp_ms > ? AND e.timestamp_ms <= ?
              AND a.name IN (SELECT value FROM json_each(?))
            """, [.integer(RecordCoding.milliseconds(observation.start)), .integer(RecordCoding.milliseconds(observation.end)), .text(ids)]) { row in
            let input = Int(row.int(2)), output = Int(row.int(3)), read = Int(row.int(4))
            let write = Int(row.int(5)), reasoning = Int(row.int(6))
            let (fresh, firstOverflow) = input.addingReportingOverflow(output)
            let (total, secondOverflow) = fresh.addingReportingOverflow(read)
            let (sum, thirdOverflow) = tokens.addingReportingOverflow(total)
            guard !firstOverflow, !secondOverflow, !thirdOverflow, [input, output, read, write, reasoning].allSatisfy({ $0 >= 0 }) else {
                invalid = true; return
            }
            tokens = sum
            guard total > 0 else { return }
            let group = QuotaCapacityLedgerGroup(quarter: row.int(0) / Self.bucketMilliseconds * Self.bucketMilliseconds,
                                                consumer: row.text(1) ?? "")
            groups[group, default: TokenKinds()] += TokenKinds(tokensIn: input, tokensOut: output, cacheRead: read,
                                                               cacheWrite: write, reasoning: reasoning)
        }
        guard !invalid, tokens > 0 else { return nil }
        let result = QuotaCapacityLedgerCalls(tokens: tokens, groups: groups)
        if (quotaCapacityRead?.values.count ?? 0) >= 64 { quotaCapacityRead?.values = [:] }
        quotaCapacityRead?.values[key] = result
        return result
    }
}

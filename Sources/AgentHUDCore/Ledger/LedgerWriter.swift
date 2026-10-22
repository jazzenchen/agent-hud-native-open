import AgentHUDSupport
import Foundation

/// Statements of one atomic ledger write.
public struct LedgerWriter {
    let storage: LedgerStorage

    public func fileStates(source: String) throws -> [String: UsageLedger.FileState] {
        var result: [String: UsageLedger.FileState] = [:]
        try storage.connection.query("SELECT path, signature, state, file_group FROM source_file WHERE source = ?", [.text(source)]) { row in
            result[row.text(0) ?? ""] = UsageLedger.FileState(signature: row.text(1) ?? "", state: row.blob(2), group: row.text(3))
        }
        return result
    }

    public func setFile(source: String, path: String, state: UsageLedger.FileState) throws {
        try storage.connection.run("""
            INSERT INTO source_file (source, path, signature, state, file_group) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (source, path) DO UPDATE SET signature = excluded.signature, state = excluded.state, file_group = excluded.file_group
            """, [.text(source), .text(path), .text(state.signature), state.state.map { .blob($0) } ?? .null, .nullable(state.group)])
    }

    public func removeFile(source: String, path: String) throws {
        try storage.connection.run("DELETE FROM source_file WHERE source = ? AND path = ?", [.text(source), .text(path)])
    }

    /// Moves a file's stored state to the path `new`, replacing any state stored there.
    public func renameFile(source: String, path old: String, to new: String) throws {
        guard old != new else { return }
        try removeFile(source: source, path: new)
        try storage.connection.run("UPDATE source_file SET path = ? WHERE source = ? AND path = ?", [.text(new), .text(source), .text(old)])
    }

    /// Gives a contribution the key `new` with everything it holds: its usage, costs, marks and counting flag, which stay
    /// in the buckets as they are. Whatever the ledger held under `new` goes first. Nothing happens when it holds nothing
    /// under `old`.
    public func rename(source: String, contribution old: String, to new: String) throws {
        var found = false
        try storage.connection.query("SELECT 1 FROM contribution WHERE source = ? AND key = ?", [.text(source), .text(old)]) { _ in found = true }
        guard old != new, found else { return }
        try remove(source: source, contribution: new)
        try storage.connection.run("UPDATE contribution SET key = ? WHERE source = ? AND key = ?", [.text(new), .text(source), .text(old)])
        storage.touch(old)
        storage.touch(new)
    }

    /// Moves a consumer's usage to the id `new`, adding it to usage already recorded there. Nothing happens when the
    /// ledger does not know `old`.
    public func moveConsumer(_ old: String, to new: String) throws {
        guard old != new, let from = storage.knownAgentID(old) else { return }
        let connection = storage.connection
        try connection.query("SELECT DISTINCT c.key FROM usage_event e JOIN contribution c ON c.id = e.contribution_id WHERE e.agent = ?",
                             [.integer(from)]) { storage.touch($0.text(0) ?? "") }
        guard let to = storage.knownAgentID(new) else {
            try connection.run("UPDATE agent SET name = ? WHERE id = ?", [.text(new), .integer(from)])
            storage.moved(from, to: new, joining: nil)
            return
        }
        try connection.run("UPDATE usage_event SET agent = ? WHERE agent = ?", [.integer(to), .integer(from)])
        try connection.run("""
            INSERT INTO usage_bucket (start_ms, source, account, agent, tokens_in, tokens_out, cache_read, cache_write, reasoning)
            SELECT start_ms, source, account, ?, tokens_in, tokens_out, cache_read, cache_write, reasoning FROM usage_bucket WHERE agent = ?
            ON CONFLICT (start_ms, source, account, agent) DO UPDATE SET tokens_in = tokens_in + excluded.tokens_in,
                tokens_out = tokens_out + excluded.tokens_out, cache_read = cache_read + excluded.cache_read,
                cache_write = cache_write + excluded.cache_write, reasoning = reasoning + excluded.reasoning
            """, [.integer(to), .integer(from)])
        try connection.run("""
            INSERT INTO model_context (agent, largest) SELECT ?, largest FROM model_context WHERE agent = ?
            ON CONFLICT (agent) DO UPDATE SET largest = MAX(largest, excluded.largest)
            """, [.integer(to), .integer(from)])
        for table in ["usage_bucket", "model_context"] { try connection.run("DELETE FROM \(table) WHERE agent = ?", [.integer(from)]) }
        try connection.run("DELETE FROM agent WHERE id = ?", [.integer(from)])
        storage.moved(from, to: new, joining: to)
    }

    /// Records where a contribution's turns start and where its client compacted the conversation; marks already
    /// recorded stay as they are.
    public func addMarks(source: String, contribution: String, account: String? = nil, marks: [UsageLedger.Mark]) throws {
        guard !marks.isEmpty else { return }
        storage.touch(contribution)
        let id = try contributionID(source: source, key: contribution, account: account), cutoff = cutoff()
        for mark in marks where RecordCoding.milliseconds(mark.timestamp) >= cutoff {
            try storage.connection.run("INSERT OR IGNORE INTO session_mark (contribution_id, at_ms, kind) VALUES (?, ?, ?)",
                [.integer(id.id), .integer(RecordCoding.milliseconds(mark.timestamp)), .integer(Int64(mark.kind.rawValue))])
        }
    }

    /// Adds events or corrects events with the same key; other events of the contribution stay.
    /// A contribution that is not `counted` keeps its events out of the buckets, such as an older copy of a moved log.
    public func upsert(source: String, contribution: String, account: String? = nil, counted: Bool? = nil, events: [UsageLedger.Event]) throws {
        if let counted { try setCounted(source: source, contribution: contribution, account: account, counted: counted) }
        guard !events.isEmpty else { return }
        storage.touch(contribution)
        let id = try contributionID(source: source, key: contribution, account: account)
        try storage.connection.run("UPDATE contribution SET digest = NULL WHERE id = ?", [.integer(id.id)])
        let cutoff = cutoff(), billed = try hasCosts(id)
        for event in events where RecordCoding.milliseconds(event.timestamp) >= cutoff {
            try write(event, contribution: id, billed: billed)
        }
    }

    /// Makes `events` the whole contribution, or with `since` only its events from then on, keeping older ones that a
    /// reader no longer returns. An unchanged contribution is left untouched.
    public func replace(source: String, contribution: String, account: String? = nil, events: [UsageLedger.Event], since: Date? = nil) throws {
        let floor = max(cutoff(), since.map(RecordCoding.milliseconds) ?? .min)
        let kept = events.filter { RecordCoding.milliseconds($0.timestamp) >= floor }.sorted { $0.key < $1.key }
        let digest = Self.digest(kept, account: account, since: since)
        var stored: (id: Int64, account: String, digest: Int64?)?
        try storage.connection.query("SELECT id, account, digest FROM contribution WHERE source = ? AND key = ?",
                                     [.text(source), .text(contribution)]) { row in
            stored = (row.int(0), row.text(1) ?? "", row.isNull(2) ? nil : row.int(2))
        }
        if let stored, stored.digest == digest { return }
        storage.touch(contribution)
        if let stored {
            if since == nil || stored.account != (account ?? "") {
                try remove(source: source, contribution: contribution)
            } else {
                try removeEvents(of: try contributionID(source: source, key: contribution, account: account), at: floor...Int64.max)
            }
        }
        if kept.isEmpty {
            guard stored != nil else { return }
            // Nothing left to count: an emptied contribution goes, one that still holds older events remembers this answer.
            try storage.connection.run("""
                DELETE FROM contribution WHERE source = ? AND key = ? AND NOT EXISTS (SELECT 1 FROM usage_event WHERE contribution_id = contribution.id)
                AND NOT EXISTS (SELECT 1 FROM cost_amount WHERE contribution_id = contribution.id)
                AND NOT EXISTS (SELECT 1 FROM session_mark WHERE contribution_id = contribution.id)
                """, [.text(source), .text(contribution)])
            try storage.connection.run("UPDATE contribution SET digest = ? WHERE source = ? AND key = ?", [.integer(digest), .text(source), .text(contribution)])
            return
        }
        let id = try contributionID(source: source, key: contribution, account: account)
        for event in kept { try write(event, contribution: id, billed: false) }
        try storage.connection.run("UPDATE contribution SET digest = ? WHERE id = ?", [.integer(digest), .integer(id.id)])
    }

    /// Moves a contribution's events into or out of the buckets without rewriting them.
    public func setCounted(source: String, contribution: String, account: String? = nil, counted: Bool) throws {
        let id = try contributionID(source: source, key: contribution, account: account)
        guard id.counted != counted else { return }
        storage.touch(contribution)
        try applyTotals(of: id, sign: counted ? 1 : -1)
        try storage.connection.run("UPDATE contribution SET counted = ? WHERE id = ?", [.integer(counted ? 1 : 0), .integer(id.id)])
    }

    public func remove(source: String, contribution: String) throws {
        guard let found = try existingContribution(source: source, key: contribution) else { return }
        storage.touch(contribution)
        if found.counted { try applyTotals(of: found, sign: -1) }
        try storage.connection.run("DELETE FROM usage_event WHERE contribution_id = ?", [.integer(found.id)])
        try storage.connection.run("DELETE FROM cost_amount WHERE contribution_id = ?", [.integer(found.id)])
        try storage.connection.run("DELETE FROM session_mark WHERE contribution_id = ?", [.integer(found.id)])
        try storage.connection.run("DELETE FROM contribution WHERE id = ?", [.integer(found.id)])
    }

    /// Deletes a contribution's events, costs and marks timed within `times`, in the ledger's milliseconds, with their
    /// share of the buckets; the contribution and the rest of its usage stay.
    func removeUsage(source: String, contribution: String, at times: ClosedRange<Int64>) throws {
        guard let found = try existingContribution(source: source, key: contribution) else { return }
        storage.touch(contribution)
        try removeEvents(of: found, at: times)
    }

    /// Deletes a contribution's events, costs and marks timed within `times`, with their share of the buckets.
    private func removeEvents(of found: ContributionID, at times: ClosedRange<Int64>) throws {
        if found.counted { try applyTotals(of: found, sign: -1, at: times) }
        let bounds: [SQLiteConnection.Value] = [.integer(found.id), .integer(times.lowerBound), .integer(times.upperBound)]
        try storage.connection.run("DELETE FROM usage_event WHERE contribution_id = ? AND timestamp_ms BETWEEN ? AND ?", bounds)
        try storage.connection.run("DELETE FROM cost_amount WHERE contribution_id = ? AND timestamp_ms BETWEEN ? AND ?", bounds)
        try storage.connection.run("DELETE FROM session_mark WHERE contribution_id = ? AND at_ms BETWEEN ? AND ?", bounds)
    }

    /// Adds (`sign` 1) or subtracts (-1) what a contribution holds within `times` to the usage and cost buckets.
    private func applyTotals(of found: ContributionID, sign: Int64, at times: ClosedRange<Int64> = Int64.min...Int64.max) throws {
        var usage: [(start: Int64, agent: Int64, tokens: StoredTokens)] = []
        try storage.connection.query("""
            SELECT timestamp_ms / ? * ?, agent, SUM(tokens_in), SUM(tokens_out), SUM(cache_read), SUM(cache_write), SUM(reasoning)
            FROM usage_event WHERE contribution_id = ? AND timestamp_ms BETWEEN ? AND ? GROUP BY 1, 2
            """, [.integer(UsageLedger.bucketMilliseconds), .integer(UsageLedger.bucketMilliseconds), .integer(found.id),
                  .integer(times.lowerBound), .integer(times.upperBound)]) { row in
            usage.append((row.int(0), row.int(1), StoredTokens(tokensIn: row.int(2), tokensOut: row.int(3), cacheRead: row.int(4),
                                                             cacheWrite: row.int(5), reasoning: row.int(6))))
        }
        for entry in usage {
            try addUsage(start: entry.start, source: found.source, account: found.account, agent: entry.agent, tokens: entry.tokens.scaled(sign))
        }
        var costs: [(String, Int64, String, Int64, Int64)] = []
        try storage.connection.query("""
            SELECT billing, timestamp_ms / ? * ?, currency, SUM(amount_pico), COUNT(*) FROM cost_amount
            WHERE contribution_id = ? AND timestamp_ms BETWEEN ? AND ? GROUP BY 1, 2, 3
            """, [.integer(UsageLedger.bucketMilliseconds), .integer(UsageLedger.bucketMilliseconds), .integer(found.id),
                  .integer(times.lowerBound), .integer(times.upperBound)]) { row in
            costs.append((row.text(0) ?? "", row.int(1), row.text(2) ?? "", row.int(3), row.int(4)))
        }
        for (billing, start, currency, amount, events) in costs {
            try addCost(billing: billing, start: start, currency: currency, amount: sign * amount, events: sign * events)
        }
    }

    /// Every contribution key the source has written.
    public func contributions(source: String) throws -> Set<String> {
        var result: Set<String> = []
        try storage.connection.query("SELECT key FROM contribution WHERE source = ?", [.text(source)]) { result.insert($0.text(0) ?? "") }
        return result
    }

    public func appendSamples(_ samples: [QuotaSample], scope: String) throws {
        for sample in samples {
            // Readings keep their exact time, in the date's own representation; cycle boundaries compare against it.
            try storage.connection.run("INSERT OR REPLACE INTO quota_sample (scope, window_id, observed_at, remaining) VALUES (?, ?, ?, ?)",
                [.text(scope), .text(sample.agentId), .real(sample.timestamp.timeIntervalSinceReferenceDate), .real(sample.remainingPct)])
        }
    }

    public func removeSamples(scope: String) throws {
        try storage.connection.run("DELETE FROM quota_sample WHERE scope = ?", [.text(scope)])
    }

    /// Keeps a billing account's balances as read at `timestamp`, one reading per currency.
    public func appendBalances(_ balances: [AccountBalance], billing: String, at timestamp: Date) throws {
        for balance in balances {
            try storage.connection.run("""
                INSERT OR REPLACE INTO balance_sample (billing, currency, observed_ms, amount_pico) VALUES (?, ?, ?, ?)
                """, [.text(billing), .text(balance.currency), .integer(RecordCoding.milliseconds(timestamp)), .integer(Self.pico(balance.total))])
        }
    }

    // MARK: Internals

    private struct ContributionID { let id: Int64; let source: String; let account: String; let counted: Bool }

    /// Only billed contributions pay for cost lookups; the rest never had a cost row.
    private func hasCosts(_ contribution: ContributionID) throws -> Bool {
        var found = false
        try storage.connection.query("SELECT 1 FROM cost_amount WHERE contribution_id = ? LIMIT 1", [.integer(contribution.id)]) { _ in found = true }
        return found
    }

    /// A contribution the ledger already holds, without adding one.
    private func existingContribution(source: String, key: String) throws -> ContributionID? {
        var found: ContributionID?
        try storage.connection.query("SELECT id, account, counted FROM contribution WHERE source = ? AND key = ?", [.text(source), .text(key)]) { row in
            found = ContributionID(id: row.int(0), source: source, account: row.text(1) ?? "", counted: row.int(2) != 0)
        }
        return found
    }

    private func contributionID(source: String, key: String, account: String?) throws -> ContributionID {
        try storage.connection.run("INSERT OR IGNORE INTO contribution (source, key, account) VALUES (?, ?, ?)",
                                   [.text(source), .text(key), .text(account ?? "")])
        var found: ContributionID?
        try storage.connection.query("SELECT id, account, counted FROM contribution WHERE source = ? AND key = ?", [.text(source), .text(key)]) { row in
            found = ContributionID(id: row.int(0), source: source, account: row.text(1) ?? "", counted: row.int(2) != 0)
        }
        return found!
    }

    /// One stored event's counts, in the ledger's integers.
    struct StoredTokens: Equatable {
        var tokensIn: Int64, tokensOut: Int64, cacheRead: Int64, cacheWrite: Int64, reasoning: Int64

        func scaled(_ sign: Int64) -> StoredTokens {
            StoredTokens(tokensIn: sign * tokensIn, tokensOut: sign * tokensOut, cacheRead: sign * cacheRead,
                         cacheWrite: sign * cacheWrite, reasoning: sign * reasoning)
        }
        var isZero: Bool { self == StoredTokens(tokensIn: 0, tokensOut: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0) }
    }

    private struct StoredEvent: Equatable {
        let timestamp: Int64, agent: Int64, tokens: StoredTokens, window: Int64
        var duration: Int64? = nil, ttft: Int64? = nil
    }

    private func write(_ event: UsageLedger.Event, contribution: ContributionID, billed: Bool) throws {
        let key = Self.eventKey(event.key), timestamp = RecordCoding.milliseconds(event.timestamp)
        let agent = try storage.agentID(event.agentId)
        var old: StoredEvent?
        try storage.connection.query("""
            SELECT timestamp_ms, agent, tokens_in, tokens_out, cache_read, cache_write, reasoning, context_window, duration_ms, ttft_ms
            FROM usage_event WHERE contribution_id = ? AND event = ?
            """, [.integer(contribution.id), .integer(key)]) { row in
            old = StoredEvent(timestamp: row.int(0), agent: row.int(1), tokens: StoredTokens(tokensIn: row.int(2), tokensOut: row.int(3),
                              cacheRead: row.int(4), cacheWrite: row.int(5), reasoning: row.int(6)), window: row.int(7),
                              duration: row.isNull(8) ? nil : row.int(8), ttft: row.isNull(9) ? nil : row.int(9))
        }
        let values = StoredEvent(timestamp: timestamp, agent: agent, tokens: StoredTokens(tokensIn: Int64(event.tokensIn),
            tokensOut: Int64(event.tokensOut), cacheRead: Int64(event.cacheReadTokens), cacheWrite: Int64(event.cacheWriteTokens),
            reasoning: Int64(event.reasoningTokens)), window: Int64(event.contextWindow ?? 0),
            duration: event.durationMs, ttft: event.ttftMs)
        if let old, old == values {
            // Usage is unchanged; costs may still be new for an event first seen without a price.
        } else {
            if let old, contribution.counted {
                try addUsage(start: Self.bucket(old.timestamp), source: contribution.source, account: contribution.account, agent: old.agent,
                             tokens: old.tokens.scaled(-1))
            }
            try storage.connection.run("""
                INSERT OR REPLACE INTO usage_event (contribution_id, event, timestamp_ms, agent, tokens_in, tokens_out, cache_read,
                    cache_write, reasoning, context_window, duration_ms, ttft_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.integer(contribution.id), .integer(key), .integer(timestamp), .integer(agent),
                      .integer(values.tokens.tokensIn), .integer(values.tokens.tokensOut), .integer(values.tokens.cacheRead),
                      .integer(values.tokens.cacheWrite), .integer(values.tokens.reasoning), .integer(values.window),
                      .nullable(values.duration), .nullable(values.ttft)])
            if contribution.counted {
                try addUsage(start: Self.bucket(timestamp), source: contribution.source, account: contribution.account, agent: agent,
                             tokens: values.tokens)
            }
            try storage.noteContext(agent: agent, tokens: values.tokens.tokensIn + values.tokens.cacheRead)
        }
        if billed || event.billingID != nil { try writeCosts(event, key: key, timestamp: timestamp, contribution: contribution) }
    }

    private func writeCosts(_ event: UsageLedger.Event, key: Int64, timestamp: Int64, contribution: ContributionID) throws {
        var old: [String: (timestamp: Int64, billing: String, amount: Int64)] = [:]
        try storage.connection.query("""
            SELECT currency, timestamp_ms, billing, amount_pico FROM cost_amount WHERE contribution_id = ? AND event = ?
            """, [.integer(contribution.id), .integer(key)]) { row in
            old[row.text(0) ?? ""] = (row.int(1), row.text(2) ?? "", row.int(3))
        }
        // The empty currency counts every billed event, so a bucket can tell which currencies priced all of them.
        var new: [String: (timestamp: Int64, billing: String, amount: Int64)] = [:]
        if let billing = event.billingID {
            new[""] = (timestamp, billing, 0)
            for (currency, amount) in event.costs ?? [:] where !currency.isEmpty {
                new[currency] = (timestamp, billing, Self.pico(amount))
            }
        }
        for (currency, value) in old where new[currency].map({ $0 != value }) ?? true {
            if contribution.counted {
                try addCost(billing: value.billing, start: Self.bucket(value.timestamp), currency: currency, amount: -value.amount, events: -1)
            }
            try storage.connection.run("DELETE FROM cost_amount WHERE contribution_id = ? AND event = ? AND currency = ?",
                                       [.integer(contribution.id), .integer(key), .text(currency)])
        }
        for (currency, value) in new where old[currency].map({ $0 != value }) ?? true {
            try storage.connection.run("""
                INSERT INTO cost_amount (contribution_id, event, currency, timestamp_ms, billing, amount_pico) VALUES (?, ?, ?, ?, ?, ?)
                """, [.integer(contribution.id), .integer(key), .text(currency), .integer(value.timestamp), .text(value.billing), .integer(value.amount)])
            if contribution.counted {
                try addCost(billing: value.billing, start: Self.bucket(value.timestamp), currency: currency, amount: value.amount, events: 1)
            }
        }
    }

    private func addUsage(start: Int64, source: String, account: String, agent: Int64, tokens: StoredTokens) throws {
        guard !tokens.isZero else { return }
        try storage.connection.run("""
            INSERT INTO usage_bucket (start_ms, source, account, agent, tokens_in, tokens_out, cache_read, cache_write, reasoning)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (start_ms, source, account, agent) DO UPDATE SET tokens_in = tokens_in + excluded.tokens_in,
                tokens_out = tokens_out + excluded.tokens_out, cache_read = cache_read + excluded.cache_read,
                cache_write = cache_write + excluded.cache_write, reasoning = reasoning + excluded.reasoning
            """, [.integer(start), .text(source), .text(account), .integer(agent), .integer(tokens.tokensIn), .integer(tokens.tokensOut),
                  .integer(tokens.cacheRead), .integer(tokens.cacheWrite), .integer(tokens.reasoning)])
        if tokens.tokensIn < 0 || tokens.tokensOut < 0 || tokens.cacheRead < 0 {
            try storage.connection.run("""
                DELETE FROM usage_bucket WHERE start_ms = ? AND source = ? AND account = ? AND agent = ?
                AND tokens_in = 0 AND tokens_out = 0 AND cache_read = 0
                """, [.integer(start), .text(source), .text(account), .integer(agent)])
        }
    }

    private func addCost(billing: String, start: Int64, currency: String, amount: Int64, events: Int64) throws {
        try storage.connection.run("""
            INSERT INTO cost_bucket (billing, start_ms, currency, amount_pico, events) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (billing, start_ms, currency) DO UPDATE SET amount_pico = amount_pico + excluded.amount_pico,
                events = events + excluded.events
            """, [.text(billing), .integer(start), .text(currency), .integer(amount), .integer(events)])
        if events < 0 {
            try storage.connection.run("DELETE FROM cost_bucket WHERE billing = ? AND start_ms = ? AND currency = ? AND events <= 0",
                                       [.text(billing), .integer(start), .text(currency)])
        }
    }

    static func bucket(_ milliseconds: Int64) -> Int64 {
        milliseconds / UsageLedger.bucketMilliseconds * UsageLedger.bucketMilliseconds
    }

    /// Events older than the retention would be deleted by the next expiry, so they are not written.
    private func cutoff() -> Int64 {
        storage.retention.map { Self.bucket(RecordCoding.milliseconds(Date().addingTimeInterval(-$0))) } ?? .min
    }

    /// Prices are exact decimals with far fewer than twelve fractional digits.
    static func pico(_ amount: Decimal) -> Int64 {
        NSDecimalNumber(decimal: amount * 1_000_000_000_000).int64Value
    }

    static func decimal(_ value: (Int64, Int64)) -> Decimal { Decimal(value.0) / 1_000_000_000_000 }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    static func eventKey(_ key: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }

    static func digest(_ events: [UsageLedger.Event], account: String?, since: Date?) -> Int64 {
        var text = (account ?? "") + "\u{4}" + (since.map { String(RecordCoding.milliseconds($0)) } ?? "")
        for event in events {
            text += "\u{1}\(event.key)\u{2}\(RecordCoding.milliseconds(event.timestamp))\u{2}\(event.agentId)\u{2}\(event.tokensIn)"
                + "\u{2}\(event.tokensOut)\u{2}\(event.cacheReadTokens)\u{2}\(event.billingID ?? "")"
                + "\u{2}\(event.cacheWriteTokens)\u{2}\(event.reasoningTokens)\u{2}\(event.contextWindow ?? 0)"
            for currency in (event.costs ?? [:]).keys.sorted() { text += "\u{3}\(currency)=\(event.costs![currency]!)" }
        }
        return eventKey(text)
    }
}

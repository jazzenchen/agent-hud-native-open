import XCTest
@testable import AgentHUDCore

final class UsageLedgerTests: XCTestCase, @unchecked Sendable {
    private let base = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 900))

    private func event(_ key: String, minute: Double, agent: String = "claude-model:opus", input: Int, output: Int = 0,
                       cache: Int = 0, costs: [String: Decimal]? = nil) -> UsageLedger.Event {
        UsageLedger.Event(key: key, timestamp: base.addingTimeInterval(minute * 60), agentId: agent, tokensIn: input, tokensOut: output,
                          cacheReadTokens: cache, billingID: costs == nil ? nil : "DeepSeek", costs: costs)
    }

    func testCorrectionsAndRepeatsKeepBucketsExact() async throws {
        let ledger = UsageLedger.inMemory(), now = base.addingTimeInterval(3600)
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [
            self.event("m1", minute: 1, input: 100, output: 10), self.event("m2", minute: 16, input: 50, cache: 7),
        ]) }
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [self.event("m1", minute: 1, input: 100, output: 10)]) }
        var buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [100, 50], "a repeated event counts once")
        XCTAssertEqual(buckets.map(\.start), [base, base.addingTimeInterval(900)])
        // A later line corrects an earlier attempt and can move it into another period.
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [self.event("m1", minute: 20, input: 120, output: 12)]) }
        buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.tokensIn, 170)
        XCTAssertEqual(buckets.first?.tokensOut, 12)
        XCTAssertEqual(buckets.first?.cacheReadTokens, 7)
        let tokens = try await ledger.tokens(source: "claude", since: base.addingTimeInterval(18 * 60))
        XCTAssertEqual(tokens, ["a.jsonl": 132])
        _ = now
    }

    func testPeriodsSumEachModelSinceMidnightAndOverSevenAndThirtyDays() async throws {
        let ledger = UsageLedger.inMemory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        try await ledger.write { try $0.upsert(source: "claude", contribution: "a.jsonl", events: [
            self.event("today", minute: 0, input: 100), self.event("last-night", minute: -600, input: 20),
            self.event("last-week", minute: -14_400, agent: "codex-model:gpt", input: 5),
            self.event("last-month", minute: -57_600, input: 1_000),
        ]) }
        // `base` is 08:00 UTC, so the day began eight hours before it.
        let periods = try await ledger.periods(endingAt: base.addingTimeInterval(2 * 3600), calendar: calendar)
        XCTAssertEqual(periods.tokens[.today], ["claude-model:opus": TokenKinds(input: 100)])
        XCTAssertEqual(periods.tokens[.days7], ["claude-model:opus": TokenKinds(input: 120)])
        XCTAssertEqual(periods.tokens[.days30], ["claude-model:opus": TokenKinds(input: 120), "codex-model:gpt": TokenKinds(input: 5)])
    }

    func testPeriodsSetDeepSeeksPeakHoursApart() async throws {
        let ledger = UsageLedger.inMemory()
        // `base` is a Friday, 16:00 in Beijing and inside the afternoon peak; four hours later it is off-peak.
        try await ledger.write { try $0.upsert(source: "claude", contribution: "d.jsonl", events: [
            self.event("busy", minute: 0, agent: "claude-model:deepseek-v4-pro", input: 100),
            self.event("quiet", minute: 240, agent: "claude-model:deepseek-v4-pro", input: 50),
            self.event("other", minute: 0, input: 7),
        ]) }
        let periods = try await ledger.periods(endingAt: base.addingTimeInterval(5 * 3600))
        XCTAssertEqual(periods.tokens[.days7]?["claude-model:deepseek-v4-pro"], TokenKinds(input: 150))
        XCTAssertEqual(periods.peak[.days7], ["claude-model:deepseek-v4-pro": TokenKinds(input: 100)], "only a model billed by the hour is split")
        XCTAssertTrue(ModelCatalog.isPeak(base))
    }

    func testReplacingAContributionOnlyWritesChanges() async throws {
        let ledger = UsageLedger.inMemory()
        let first = [event("e1", minute: 2, agent: "copilot-model:gpt", input: 10), event("e2", minute: 3, agent: "copilot-model:gpt", input: 5)]
        try await ledger.write { try $0.replace(source: "copilot", contribution: "s", events: first) }
        // Uncounted events leave the buckets; rewriting the contribution would count them again.
        try await ledger.write { try $0.setCounted(source: "copilot", contribution: "s", counted: false) }
        try await ledger.write { try $0.replace(source: "copilot", contribution: "s", events: first.reversed()) }
        let unchanged = try await ledger.buckets(since: base)
        XCTAssertTrue(unchanged.isEmpty, "an identical contribution is not rewritten")
        try await ledger.write { try $0.setCounted(source: "copilot", contribution: "s", counted: true) }
        try await ledger.write { try $0.replace(source: "copilot", contribution: "s", events: [self.event("e1", minute: 2, agent: "copilot-model:gpt", input: 12)]) }
        let replaced = try await ledger.buckets(since: base)
        XCTAssertEqual(replaced.map(\.tokensIn), [12])
        try await ledger.write { try $0.remove(source: "copilot", contribution: "s") }
        let removed = try await ledger.buckets(since: base)
        XCTAssertTrue(removed.isEmpty)
        let keys = try await ledger.write { try $0.contributions(source: "copilot") }
        XCTAssertTrue(keys.isEmpty)
    }

    func testUncountedCopiesStayOutOfBuckets() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "codex", contribution: "sessions/a.jsonl", events: [self.event("u1", minute: 1, agent: "codex-model:gpt", input: 10)])
            try writer.upsert(source: "codex", contribution: "archived/a.jsonl", counted: false,
                              events: [self.event("u1", minute: 1, agent: "codex-model:gpt", input: 10)])
        }
        var buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [10], "only the counted copy of a moved log adds up")
        try await ledger.write { writer in
            try writer.setCounted(source: "codex", contribution: "sessions/a.jsonl", counted: false)
            try writer.setCounted(source: "codex", contribution: "archived/a.jsonl", counted: true)
            try writer.upsert(source: "codex", contribution: "archived/a.jsonl", events: [self.event("u2", minute: 2, agent: "codex-model:gpt", input: 5)])
        }
        buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [15])
        try await ledger.write { try $0.remove(source: "codex", contribution: "sessions/a.jsonl") }
        buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [15], "removing the uncounted copy changes nothing")
    }

    func testSessionUsageJoinsSubagentLogsAndReadsTheLatestPrompt() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/s1.jsonl", events: [
                self.event("m1", minute: 1, input: 100, output: 10, cache: 900),
                self.event("m2", minute: 20, input: 30, output: 5, cache: 1_000),
            ])
            try writer.upsert(source: "claude", contribution: "p/s1/subagents/agent-a.jsonl",
                              events: [self.event("a1", minute: 18, agent: "claude-model:haiku", input: 40, output: 4)])
            // A sibling session whose path shares the prefix text but not the directory.
            try writer.upsert(source: "claude", contribution: "p/s10.jsonl", events: [self.event("x", minute: 2, input: 999)])
            try writer.upsert(source: "hermes", contribution: "h1", events: [self.event("h", minute: 3, agent: "hermes-model:m", input: 7)])
        }
        let usage = try await ledger.sessionUsage([
            SessionUsageRequest(sessionID: "s1", keys: ["p/s1.jsonl", "s1"], subagentPrefix: "p/s1/", callLog: "p/s1.jsonl"),
            SessionUsageRequest(sessionID: "h1", keys: ["h1"]),
            SessionUsageRequest(sessionID: "gone", keys: ["nothing"]),
        ])
        let s1 = try XCTUnwrap(usage["s1"])
        XCTAssertEqual(s1.models.map(\.agentId), ["claude-model:opus", "claude-model:haiku"])
        XCTAssertEqual(s1.total, .init(tokensIn: 170, tokensOut: 19, cacheReadTokens: 1_900))
        XCTAssertEqual(s1.subagents, .init(tokensIn: 40, tokensOut: 4))
        XCTAssertEqual(s1.periods.map(\.start), [base, base.addingTimeInterval(900), base.addingTimeInterval(900)])
        XCTAssertEqual(s1.periods.map(\.agentId), ["claude-model:opus", "claude-model:haiku", "claude-model:opus"])
        XCTAssertEqual(s1.periods.map(\.tokens.tokensIn), [100, 40, 30])
        XCTAssertEqual(s1.calls, 3)
        XCTAssertEqual(s1.contextTokens, 1_030, "the latest call of the session's own log, fresh input plus cache reads")
        XCTAssertNil(usage["h1"]?.contextTokens, "a source read whole does not record each call")
        XCTAssertEqual(usage["h1"]?.total.tokensIn, 7)
        XCTAssertNil(usage["gone"])
    }

    private func call(_ key: String, _ minute: Double, agent: String = "claude-model:claude-opus-5", input: Int, write: Int = 0, output: Int,
                      reasoning: Int = 0, cache: Int = 0) -> UsageLedger.Event {
        UsageLedger.Event(key: key, timestamp: base.addingTimeInterval(minute * 60), agentId: agent, tokensIn: input, tokensOut: output,
                          cacheReadTokens: cache, cacheWriteTokens: write, reasoningTokens: reasoning)
    }

    private func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func testSessionUsageSplitsKindsIntoTurnsWithContextAndListPrice() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/s.jsonl", events: [
                self.call("m0", 0.5, input: 10, output: 5),
                self.call("m1", 1, input: 1_000, write: 800, output: 300, reasoning: 100, cache: 5_000),
                self.call("m2", 2, input: 200, write: 150, output: 50, cache: 6_000),
                self.call("m3", 11, input: 400, write: 300, output: 90, reasoning: 40, cache: 2_000),
            ])
            try writer.addMarks(source: "claude", contribution: "p/s.jsonl", marks: [
                .init(.prompt, at: self.at(60)), .init(.prompt, at: self.at(600)), .init(.prompt, at: self.at(700)), .init(.compaction, at: self.at(630)),
            ])
            // A sub-agent's own prompt starts no turn of the session; its call joins the turn running at the time.
            try writer.upsert(source: "claude", contribution: "p/s/subagents/agent-a.jsonl", events: [
                self.call("a1", 1.5, agent: "claude-model:claude-haiku-4-5-20251001", input: 70, write: 20, output: 7, cache: 900),
            ])
            try writer.addMarks(source: "claude", contribution: "p/s/subagents/agent-a.jsonl", marks: [.init(.prompt, at: self.at(85))])
        }
        let read = try await ledger.sessionUsage([
            SessionUsageRequest(sessionID: "s", keys: ["p/s.jsonl", "s"], subagentPrefix: "p/s/", callLog: "p/s.jsonl"),
        ])
        let usage = try XCTUnwrap(read["s"])
        XCTAssertEqual(usage.turns.map(\.start), [self.at(30), self.at(60), self.at(600)], "calls before the first prompt form a turn of their own")
        XCTAssertEqual(usage.turnCount, 3, "a prompt no call followed adds no turn")
        XCTAssertEqual(usage.turns.map(\.calls), [1, 3, 1])
        XCTAssertEqual(usage.turns[1].tokens.kinds, TokenKinds(cacheWrite: 970, input: 300, reasoning: 100, output: 257, cacheRead: 11_900))
        XCTAssertEqual(usage.turns.map(\.contextTokens), [10, 6_200, 2_400], "a turn's context is its own log's last call")
        XCTAssertEqual(usage.turns.map(\.compacted), [false, false, true])
        XCTAssertEqual(usage.turns.map(\.subagents), [nil, .init(tokensIn: 70, tokensOut: 7, cacheReadTokens: 900, cacheWriteTokens: 20), nil])
        XCTAssertEqual(usage.turns.map(\.listCost), ["0.000175", "0.025215", "0.00675"].map { Decimal(string: $0) }, "the turns add up to the session")
        XCTAssertEqual(usage.total.kinds.reasoning, 140)
        XCTAssertEqual(usage.contextWindow, 1_000_000, "the published window of the model the session's own log called last")
        // Opus 5: $5 input, $10 one-hour cache writes, $0.50 cache reads, $25 output. Haiku 4.5: $1, $2, $0.10, $5.
        XCTAssertEqual(usage.listCost, Decimal(string: "0.03214"))
        let buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.cacheWriteTokens }, 1_270)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.reasoningTokens }, 140)

        // A model without a list price leaves the estimate unknown; a removed log takes its marks along.
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/s.jsonl", events: [self.call("m4", 12, agent: "claude-model:claude-next", input: 1, output: 1)])
        }
        let unpriced = try await ledger.sessionUsage([SessionUsageRequest(sessionID: "s", keys: ["p/s.jsonl"])])["s"]
        XCTAssertNil(unpriced?.listCost)
        XCTAssertEqual(unpriced?.contextWindow, 200_000, "an unlisted Claude model runs with 200K until one of its calls held more")
        try await ledger.write { try $0.remove(source: "claude", contribution: "p/s.jsonl") }
        try await ledger.write { try $0.upsert(source: "claude", contribution: "p/s.jsonl", events: [self.call("m5", 13, input: 1, output: 1)]) }
        let reread = try await ledger.sessionUsage([SessionUsageRequest(sessionID: "s", keys: ["p/s.jsonl"])])["s"]
        XCTAssertEqual(reread?.turns.map(\.start), [], "the removed log's prompts went with it")
    }

    func testSessionUsageMarksContextSentAgainAndThePeakBeforeACompaction() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/r.jsonl", events: [
                self.call("r1", 1, input: 1_000, write: 1_000, output: 10),
                self.call("r2", 2, input: 200, write: 200, output: 10, cache: 1_000),
                // Back after the cache lapsed: the whole prompt is written again.
                self.call("r3", 70, input: 1_300, write: 1_250, output: 10),
                self.call("r4", 71, input: 100, write: 100, output: 10, cache: 1_300),
                // A compaction shrinks the prompt, which sends nothing again.
                self.call("r5", 72, input: 100, write: 100, output: 10, cache: 200),
                // Another model reads none of the cache.
                self.call("r6", 90, agent: "claude-model:claude-sonnet-5", input: 700, write: 700, output: 10),
            ])
            try writer.addMarks(source: "claude", contribution: "p/r.jsonl", marks: [
                .init(.prompt, at: self.at(60)), .init(.prompt, at: self.at(70 * 60)), .init(.compaction, at: self.at(71.5 * 60)),
                .init(.prompt, at: self.at(90 * 60)),
            ])
        }
        let read = try await ledger.sessionUsage([SessionUsageRequest(sessionID: "r", keys: ["p/r.jsonl"], callLog: "p/r.jsonl")])
        let usage = try XCTUnwrap(read["r"])
        XCTAssertEqual(usage.turns.map(\.recachedTokens), [nil, 1_300, 700])
        XCTAssertEqual(usage.turns.map(\.contextTokens), [1_200, 300, 700])
        XCTAssertEqual(usage.turns.map(\.peakContextTokens), [nil, 1_400, nil], "the turn reached 1,400 before its compaction")
        XCTAssertEqual(usage.turns.map(\.compacted), [false, true, false])
    }

    func testRecachedBucketsCountEveryMarkedLogAndFollowItsWrites() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/r.jsonl", events: [
                self.call("r1", 1, input: 1_000, write: 1_000, output: 10),
                self.call("r2", 2, input: 200, write: 200, output: 10, cache: 1_000),
                self.call("r3", 70, input: 1_300, write: 1_250, output: 10),
                self.call("r4", 71, input: 100, write: 100, output: 10, cache: 1_300),
                self.call("r5", 72, input: 100, write: 100, output: 10, cache: 200),
                self.call("r6", 90, agent: "claude-model:claude-sonnet-5", input: 700, write: 700, output: 10),
            ])
            try writer.addMarks(source: "claude", contribution: "p/r.jsonl", marks: [
                .init(.prompt, at: self.at(60)), .init(.prompt, at: self.at(70 * 60)), .init(.compaction, at: self.at(71.5 * 60)),
                .init(.prompt, at: self.at(90 * 60)),
            ])
            // A log that marks no prompts, such as a sub-agent's, is not a session's own log of every call.
            try writer.upsert(source: "claude", contribution: "p/r/subagents/agent-a.jsonl", events: [
                self.call("a1", 1, input: 1_000, output: 10), self.call("a2", 70, input: 1_000, output: 10),
            ])
        }
        func sent(_ buckets: [UsageBucket]) -> [String] {
            buckets.map { "\(Int($0.start.timeIntervalSince(base)))s \($0.agentId) \($0.kinds.cacheWrite)w \($0.kinds.input)i" }
        }
        let first = try await ledger.recachedBuckets(since: base)
        XCTAssertEqual(sent(first), ["3600s claude-model:claude-opus-5 1300w 0i", "5400s claude-model:claude-sonnet-5 700w 0i"],
                       "the same calls a session's turns count, by the period and model of each")
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/r.jsonl", events: [
                self.call("r7", 199, input: 100, output: 10, cache: 700),
                self.call("r8", 200, input: 2_000, output: 10),
            ])
        }
        let second = try await ledger.recachedBuckets(since: base.addingTimeInterval(5_000))
        XCTAssertEqual(sent(second), ["5400s claude-model:claude-sonnet-5 700w 0i", "11700s claude-model:claude-opus-5 0w 2000i"],
                       "a log written since is read again, and periods before `since` are left out")
    }

    func testRecachedViewsOnlyFlagCallsWhenCacheReadsFall() async throws {
        let ledger = UsageLedger.inMemory()
        let log = "p/r.jsonl"
        let agent = "codex-model:gpt-6.1-sol"
        try await ledger.write { writer in
            try writer.upsert(source: "codex", contribution: log, events: [
                self.call("before-compaction", 1, agent: agent, input: 2_133, output: 10, cache: 445_056),
                self.call("after-compaction", 2, agent: agent, input: 17_591, output: 10, cache: 12_032),
                self.call("same-cache", 3, agent: agent, input: 18_225, output: 10, cache: 12_032),
                self.call("more-cache", 4, agent: agent, input: 18_500, output: 10, cache: 13_000),
                self.call("cache-drop", 5, agent: agent, input: 32_000, output: 10),
                self.call("still-no-cache", 6, agent: agent, input: 33_000, output: 10),
            ])
            try writer.addMarks(source: "codex", contribution: log, marks: [
                .init(.prompt, at: self.at(60)), .init(.compaction, at: self.at(90)), .init(.prompt, at: self.at(180)),
            ])
        }
        let request = SessionUsageRequest(sessionID: "r", keys: [log], callLog: log)
        let read = try await ledger.sessionUsage([request])
        let turns = try XCTUnwrap(read["r"]).turns
        XCTAssertEqual(turns.map(\.recachedTokens), [nil, 32_000])

        let calls = try await ledger.turnCalls(request, from: self.at(180), through: self.at(360))
        XCTAssertEqual(calls.map(\.recached), [nil, nil, 32_000, nil])

        let buckets = try await ledger.recachedBuckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [32_000])
    }

    func testTurnCallsListATurnsCallsWithTheirContextCacheAndPrice() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/s.jsonl", events: [
                self.call("m1", 1, input: 1_000, write: 800, output: 300, reasoning: 100, cache: 5_000),
                self.call("m2", 2, input: 200, write: 150, output: 50, cache: 6_000),
                // Back after the cache lapsed: the call before the turn tells that the whole prompt was written again.
                self.call("m3", 70, input: 6_300, write: 6_300, output: 10),
            ])
            try writer.addMarks(source: "claude", contribution: "p/s.jsonl", marks: [.init(.prompt, at: self.at(60)), .init(.prompt, at: self.at(70 * 60))])
            try writer.upsert(source: "claude", contribution: "p/s/subagents/agent-a.jsonl", events: [
                self.call("a1", 1.5, agent: "claude-model:claude-haiku-4-5-20251001", input: 70, write: 20, output: 7, cache: 900),
            ])
        }
        let request = SessionUsageRequest(sessionID: "s", keys: ["p/s.jsonl"], subagentPrefix: "p/s/", callLog: "p/s.jsonl")
        let read = try await ledger.sessionUsage([request])
        let turns = try XCTUnwrap(read["s"]).turns
        let first = try await ledger.turnCalls(request, from: turns[0].start, through: turns[0].end)
        XCTAssertEqual(first.map(\.own), [true, false, true])
        XCTAssertEqual(first.map(\.log), ["p/s.jsonl", "p/s/subagents/agent-a.jsonl", "p/s.jsonl"])
        XCTAssertEqual(first.map(\.context), [6_000, nil, 6_200], "only the log that records every call tells the context")
        XCTAssertEqual(first.map(\.listCost), ["0.019", "0.000215", "0.006"].map { Decimal(string: $0) })
        XCTAssertEqual(first.reduce(SessionUsage.Tokens()) { $0 + $1.tokens }, turns[0].tokens, "a turn's calls add up to it")
        let second = try await ledger.turnCalls(request, from: turns[1].start, through: turns[1].end)
        XCTAssertEqual(second.map(\.recached), [6_300])
    }

    func testSessionUsageTakesSubagentLogsNamedOneByOne() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.upsert(source: "codex", contribution: "r/parent.jsonl", events: [self.event("p", minute: 1, agent: "codex-model:gpt-5", input: 100)])
            try writer.upsert(source: "codex", contribution: "r/child.jsonl", events: [self.event("c", minute: 2, agent: "codex-model:gpt-5", input: 30)])
        }
        let usage = try await ledger.sessionUsage([SessionUsageRequest(sessionID: "parent", keys: ["r/parent.jsonl"], subagentKeys: ["r/child.jsonl"],
                                                                        callLog: "r/parent.jsonl")])
        XCTAssertEqual(usage["parent"]?.total.tokensIn, 130)
        XCTAssertEqual(usage["parent"]?.subagents?.tokensIn, 30)
        XCTAssertEqual(usage["parent"]?.contextTokens, 100, "the context is the session's own latest call")
    }

    func testAFinishedSessionsBreakdownFollowsLogsWrittenAfterItWasRead() async throws {
        let ledger = UsageLedger.inMemory()
        let parent = LiveSession(id: "s1", agentId: "claude-model:opus", task: "Task", terminal: nil, startedAt: base,
                                 endedAt: base.addingTimeInterval(600), pctOfWindow: nil, tokensIn: 100, tokensOut: 10, transcriptPath: "p/s1.jsonl")
        let whole = LiveSession(id: "w1", agentId: "hermes-model:m", task: "Task", terminal: nil, startedAt: base,
                                endedAt: base.addingTimeInterval(600), pctOfWindow: nil, tokensIn: 7, tokensOut: 0)
        let provider = CombinedUsageProvider([.init("A", Reporting(sessions: [parent, whole]))], ledger: ledger)
        try await ledger.write { try $0.upsert(source: "claude", contribution: "p/s1.jsonl", events: [self.event("m1", minute: 1, input: 100, output: 10)]) }
        let first = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(first.sessionUsage?["s1"]?.total.tokensIn, 100)
        XCTAssertNil(first.sessionUsage?["w1"], "the source has not recorded the session yet")
        // Neither session's counts move: a sub-agent's log and a whole-file source's events arrive a pass later.
        try await ledger.write { writer in
            try writer.upsert(source: "claude", contribution: "p/s1/subagents/agent-a.jsonl",
                              events: [self.event("a1", minute: 2, agent: "claude-model:haiku", input: 40, output: 4)])
            try writer.replace(source: "hermes", contribution: "w1", events: [self.event("h", minute: 3, agent: "hermes-model:m", input: 7)])
        }
        let second = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(second.sessionUsage?["s1"]?.total.tokensIn, 140)
        XCTAssertEqual(second.sessionUsage?["s1"]?.subagents?.tokensIn, 40)
        XCTAssertEqual(second.sessionUsage?["w1"]?.total.tokensIn, 7)
    }

    func testChildDetailsHaveTheirOwnBreakdownsAndRefreshWhenDescendantsSpend() async throws {
        let ledger = UsageLedger.inMemory()
        let grandchild = LiveSession(id: "grandchild", agentId: "codex-model:gpt-5", task: "Task", terminal: nil,
            startedAt: base, pctOfWindow: nil, tokensIn: 7, tokensOut: 0, transcriptPath: "r/grandchild.jsonl")
        let child = LiveSession(id: "child", agentId: grandchild.agentId, task: "Task", terminal: nil,
            startedAt: base, pctOfWindow: nil, tokensIn: 30, tokensOut: 0, transcriptPath: "r/child.jsonl",
            subagentTranscripts: ["r/grandchild.jsonl", "r/guardian.jsonl"], subagentSessions: [grandchild])
        let root = LiveSession(id: "root", agentId: child.agentId, task: "Task", terminal: nil,
            startedAt: base, pctOfWindow: nil, tokensIn: 100, tokensOut: 0, transcriptPath: "r/root.jsonl",
            subagentTranscripts: ["r/child.jsonl", "r/grandchild.jsonl", "r/guardian.jsonl"], subagentSessions: [child])
        let provider = CombinedUsageProvider([.init("Codex", Reporting(sessions: [root]))], ledger: ledger)
        try await ledger.write { writer in
            for (name, tokens) in [("root", 100), ("child", 30), ("grandchild", 7), ("guardian", 9)] {
                try writer.upsert(source: "codex", contribution: "r/\(name).jsonl",
                                  events: [self.event(name, minute: 1, agent: "codex-model:gpt-5", input: tokens)])
            }
        }
        let first = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(first.sessions.map(\.id), ["root"])
        XCTAssertEqual(first.sessionUsage?["root"]?.total.tokensIn, 146)
        XCTAssertEqual(first.sessionUsage?["child"]?.total.tokensIn, 46)
        XCTAssertEqual(first.sessionUsage?["child"]?.subagents?.tokensIn, 16)
        XCTAssertEqual(first.sessionUsage?["grandchild"]?.total.tokensIn, 7)
        try await ledger.write { try $0.upsert(source: "codex", contribution: "r/grandchild.jsonl",
            events: [self.event("next", minute: 2, agent: "codex-model:gpt-5", input: 4)]) }
        let second = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(second.sessionUsage?["root"]?.total.tokensIn, 150)
        XCTAssertEqual(second.sessionUsage?["child"]?.total.tokensIn, 50)
        XCTAssertEqual(second.sessionUsage?["grandchild"]?.total.tokensIn, 11,
                       "unchanged session counters do not hide a descendant's newly indexed usage")
    }

    func testWindowedReplacementKeepsOlderEvents() async throws {
        let ledger = UsageLedger.inMemory(), since = base.addingTimeInterval(3600)
        try await ledger.write { try $0.replace(source: "hermes", contribution: "s", events: [
            self.event("old", minute: 10, agent: "hermes-model:m", input: 7), self.event("new", minute: 70, agent: "hermes-model:m", input: 5),
        ]) }
        // A reader whose window starts at `since` no longer returns the older event, and corrects the newer one.
        try await ledger.write { try $0.replace(source: "hermes", contribution: "s", events: [
            self.event("new", minute: 70, agent: "hermes-model:m", input: 6),
        ], since: since) }
        let buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.tokensIn), [7, 6])
    }

    func testAccountImportsKeepTheirOwnBuckets() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.replace(source: "cursor", contribution: "conversation", account: "account:abc",
                               events: [self.event("c1", minute: 1, agent: "cursor-model:auto", input: 30)])
            try writer.upsert(source: "claude", contribution: "b.jsonl", events: [self.event("m", minute: 2, agent: "cursor-model:auto", input: 4)])
        }
        let buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.account), [nil, "account:abc"])
        XCTAssertEqual(buckets.map(\.tokensIn), [4, 30])
    }

    func testAMovedConsumerTakesItsNewIdOrJoinsTheUsageThere() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { writer in
            try writer.replace(source: "open-agents", contribution: "s1", events: [self.event("a", minute: 1, agent: "pi-model:old-a", input: 10)])
            try writer.replace(source: "open-agents", contribution: "s2", events: [
                self.event("b", minute: 2, agent: "pi-model:old-b", input: 20), self.event("c", minute: 3, agent: "pi-model:new-b", input: 5),
            ])
        }
        try await ledger.moveConsumers(["pi-model:old-a": "pi-model:new-a", "pi-model:old-b": "pi-model:new-b", "pi-model:none": "pi-model:x"])
        let buckets = try await ledger.buckets(since: base)
        XCTAssertEqual(buckets.map(\.agentId), ["pi-model:new-a", "pi-model:new-b"], "no bucket keeps an old id")
        XCTAssertEqual(buckets.map(\.tokensIn), [10, 25], "usage already under the new id adds up with the moved usage")
        let usage = try await ledger.sessionUsage([SessionUsageRequest(sessionID: "s2", keys: ["s2"])])
        XCTAssertEqual(usage["s2"]?.models.map(\.agentId), ["pi-model:new-b"])
    }

    func testCostsStayUnknownWhereAnEventHadNoPrice() async throws {
        let ledger = UsageLedger.inMemory()
        try await ledger.write { try $0.upsert(source: "deepseek", contribution: "s1", events: [
            self.event("r1", minute: 1, agent: "deepseek-model:flash", input: 1000, costs: ["CNY": Decimal(string: "0.0015")!, "USD": Decimal(string: "0.00022")!]),
            self.event("r2", minute: 2, agent: "deepseek-model:flash", input: 2000, costs: ["CNY": Decimal(string: "0.003")!]),
            self.event("r3", minute: 20, agent: "deepseek-model:flash", input: 10, costs: ["CNY": Decimal(string: "0.000015")!]),
        ]) }
        let costs = try await ledger.costBuckets(since: base)
        XCTAssertEqual(costs["DeepSeek"]?.map(\.amounts), [["CNY": Decimal(string: "0.0045")!], ["CNY": Decimal(string: "0.000015")!]],
                       "USD is missing where one event had no USD price")
        let sessions = try await ledger.contributionCosts(source: "deepseek")
        XCTAssertEqual(sessions["s1"], ["CNY": Decimal(string: "0.004515")!])
        try await ledger.write { try $0.upsert(source: "deepseek", contribution: "s1", events: [
            self.event("r2", minute: 2, agent: "deepseek-model:flash", input: 2000, costs: ["CNY": Decimal(string: "0.003")!, "USD": Decimal(string: "0.00044")!]),
        ]) }
        let corrected = try await ledger.costBuckets(since: base)
        XCTAssertEqual(corrected["DeepSeek"]?.first?.amounts["USD"], Decimal(string: "0.00066")!)
    }

    func testFailedPassRollsBackAndSignalsProviders() async throws {
        let ledger = UsageLedger.inMemory()
        await ledger.beginPass()
        try await ledger.write { try $0.setFile(source: "claude", path: "/a.jsonl", state: .init(signature: "1:2", state: Data("{}".utf8))) }
        do {
            try await ledger.write { writer -> Void in
                try writer.upsert(source: "claude", contribution: "/a.jsonl", events: [self.event("m", minute: 1, input: 1)])
                throw UsageProviderError("parse failed")
            }
            XCTFail("the write should throw")
        } catch {}
        await ledger.commitPass()
        let files = try await ledger.fileStates(source: "claude")
        XCTAssertEqual(files["/a.jsonl"]?.signature, "1:2", "writes before a failed provider still commit")
        let buckets = try await ledger.buckets(since: base)
        XCTAssertTrue(buckets.isEmpty, "the failed provider's writes roll back to its savepoint")
    }

    func testExpiryDeletesWholeBucketsAndPersistsAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let now = Date()
        let old = now.addingTimeInterval(-UsageLedger.retention - 3600), recent = now.addingTimeInterval(-3600)
        do {
            let ledger = try UsageLedger(url: url, expires: true)
            try await ledger.write { writer in
                try writer.upsert(source: "codex", contribution: "s", events: [
                    UsageLedger.Event(key: "old", timestamp: old, agentId: "codex-model:gpt", tokensIn: 5, tokensOut: 1),
                    UsageLedger.Event(key: "new", timestamp: recent, agentId: "codex-model:gpt", tokensIn: 7, tokensOut: 2),
                ])
                try writer.appendSamples([QuotaSample(agentId: "codex", timestamp: recent, remainingPct: 40)], scope: "codex")
            }
            try await ledger.expire(now: now)
        }
        let reopened = try UsageLedger(url: url)
        let buckets = try await reopened.buckets(since: .distantPast)
        XCTAssertEqual(buckets.map(\.tokensIn), [7])
        let samples = try await reopened.samples(scope: "codex", windowID: "codex", since: .distantPast)
        XCTAssertEqual(samples.map(\.remainingPct), [40])
    }

    func testBalanceReadingsAreKeptForADayInEachCurrency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        @Sendable func balances(_ cny: String, _ usd: String) -> [AccountBalance] {
            [AccountBalance(currency: "CNY", total: Decimal(string: cny)!, granted: 0, toppedUp: Decimal(string: cny)!),
             AccountBalance(currency: "USD", total: Decimal(string: usd)!, granted: 0, toppedUp: Decimal(string: usd)!)]
        }
        do {
            let ledger = try UsageLedger(url: url, expires: true)
            try await ledger.write { writer in
                try writer.appendBalances(balances("12.34", "2.5"), billing: "DeepSeek", at: now.addingTimeInterval(-BalanceTrend.lookback - 60))
                try writer.appendBalances(balances("8.85", "2"), billing: "DeepSeek", at: now.addingTimeInterval(-3600))
                try writer.appendBalances(balances("8.8", "1.99"), billing: "DeepSeek", at: now)
                try writer.appendBalances(balances("8.8", "1.99"), billing: "DeepSeek", at: now)
            }
            try await ledger.expire(now: now)
        }
        let reopened = try UsageLedger(url: url)
        let cny = try await reopened.balanceSamples(billing: "DeepSeek", currency: "CNY", since: .distantPast)
        XCTAssertEqual(cny, [BalanceSample(timestamp: now.addingTimeInterval(-3600), amount: Decimal(string: "8.85")!),
                             BalanceSample(timestamp: now, amount: Decimal(string: "8.8")!)], "a day's readings, each once, as exact amounts")
        let usd = try await reopened.balanceSamples(billing: "DeepSeek", currency: "USD", since: now)
        XCTAssertEqual(usd.map(\.amount), [Decimal(string: "1.99")!])
        let other = try await reopened.balanceSamples(billing: "pool:other", currency: "CNY", since: .distantPast)
        XCTAssertTrue(other.isEmpty)
    }

    /// A ledger from a version that kept no balances gains their table when it opens.
    func testALedgerWrittenBeforeBalancesWereKeptGainsTheirTable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        do {
            let ledger = try UsageLedger(url: url)
            try await ledger.write { try $0.appendSamples([QuotaSample(agentId: "codex", timestamp: now, remainingPct: 40)], scope: "codex") }
        }
        do {
            let earlier = try SQLiteConnection(url: url)
            try earlier.execute("DROP TABLE balance_sample; PRAGMA user_version = 3;")
        }
        let reopened = try UsageLedger(url: url)
        try await reopened.write { try $0.appendBalances([AccountBalance(currency: "CNY", total: 5, granted: 0, toppedUp: 5)], billing: "DeepSeek", at: now) }
        let balances = try await reopened.balanceSamples(billing: "DeepSeek", currency: "CNY", since: .distantPast)
        XCTAssertEqual(balances.map(\.amount), [5])
        let samples = try await reopened.samples(scope: "codex", windowID: "codex", since: .distantPast)
        XCTAssertEqual(samples.map(\.remainingPct), [40], "what the ledger held stays")
    }
}

/// A source that reports the same sessions on every pass.
private struct Reporting: UsageProvider {
    let sessions: [LiveSession]
    func fetchUsage(agents: [AgentDescriptor], historyHours: Int) throws -> UsageReport {
        UsageReport(generatedAt: sessions.map(\.observedAt).max() ?? Date(), snapshots: [], sessions: sessions)
    }
}

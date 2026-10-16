import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// What a Claude Code log says its turn is busy with and how the turn ended, read from the lines' first and last bytes.
final class ClaudeActivityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// The keys current builds write after the message, in their order.
    private let tail = #""userType":"external","entrypoint":"cli","cwd":"/p","sessionId":"s-act","version":"2.1.295","gitBranch":"main"}"#

    private func stamp(_ second: Double) -> String { iso.format(base.addingTimeInterval(second)) }

    private func prompt(_ text: String, at second: Double) -> String {
        #"{"parentUuid":null,"isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u\#(second)","timestamp":"\#(stamp(second))",\#(tail)"#
    }

    private func call(_ tool: String, id: String, at second: Double, input: String = #"{"command":"swift test"}"#) -> String {
        #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_\#(id)","type":"message","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":\#(input)}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":9}},"requestId":"req_\#(id)","type":"assistant","uuid":"a\#(second)","timestamp":"\#(stamp(second))",\#(tail)"#
    }

    private func result(_ id: String, at second: Double) -> String {
        #"{"parentUuid":"a","isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":[{"type":"text","text":"ok"}]}]},"uuid":"r\#(second)","timestamp":"\#(stamp(second))","toolUseResult":[{"type":"text","text":"ok"}],\#(tail)"#
    }

    /// A failed command's result, which writes its call after the output.
    private func failedResult(_ id: String, at second: Double) -> String {
        let output = String(repeating: "error: build failed\\n", count: 300)
        return #"{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Exit code 1\n\#(output)","is_error":true,"tool_use_id":"\#(id)"}]},"uuid":"f\#(second)","timestamp":"\#(stamp(second))",\#(tail)"#
    }

    private func thinking(at second: Double) -> String {
        #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_t\#(second)","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"Weighing the \"type\":\"tool_use\" options","signature":"CAQS"}],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":9}},"type":"assistant","uuid":"t\#(second)","timestamp":"\#(stamp(second))",\#(tail)"#
    }

    private func answer(_ text: String, stop: String = "end_turn", at second: Double) -> String {
        #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_e\#(second)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"\#(stop)","stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":9}},"type":"assistant","uuid":"e\#(second)","timestamp":"\#(stamp(second))",\#(tail)"#
    }

    /// The message Claude Code writes in the model's place when the API failed, as 2.1.295 writes it.
    private func apiError(_ error: String, at second: Double, resetsAt: Int? = nil) -> String {
        let limits = resetsAt.map { #""apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":\#($0),"rateLimitType":"five_hour"}},"quotaLimits":{"status":"rejected","resetsAt":\#($0),"unifiedRateLimitFallbackAvailable":false,"rateLimitType":"five_hour","isUsingOverage":false},"# } ?? ""
        return #"{"parentUuid":"p","isSidechain":false,"type":"assistant","uuid":"x\#(second)","timestamp":"\#(stamp(second))","message":{"id":"msg_x\#(second)","container":null,"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"API Error"}],"context_management":null},"requestId":"req_x",\#(limits)"error":"\#(error)","isApiErrorMessage":true,"apiErrorStatus":429,"perTurnEffort":"xhigh",\#(tail)"#
    }

    private func retry(_ attempt: Int, at second: Double) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"api_error","level":"error","error":{"message":"Connection lost","formatted":"Connection lost while your computer was asleep","isNetworkDown":false,"rateLimits":null,"noResponse":null},"retryInMs":618,"retryAttempt":\#(attempt),"maxRetries":10,"source":"connection_retry","timestamp":"\#(stamp(second))","uuid":"y\#(second)",\#(tail)"#
    }

    private func stopSummary(at second: Double) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"stop_hook_summary","hookCount":1,"timestamp":"\#(stamp(second))","uuid":"s\#(second)",\#(tail)"#
    }

    private func parse(_ lines: [String]) -> [TranscriptEvent] {
        FastTranscriptParser.parse(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func read(_ accumulator: inout TranscriptAccumulator, _ lines: String...) {
        accumulator.ingest(parse(lines))
    }

    // MARK: Parsing

    func testTheFastParserReadsCallsResultsThinkingAndAPIErrorsAsTheJSONParserDoes() throws {
        let lines = [call("Bash", id: "toolu_A", at: 1), result("toolu_A", at: 2), failedResult("toolu_B", at: 3), thinking(at: 4),
                     call("mcp__hud__layout", id: "toolu_C", at: 5, input: #"{"type":"thinking","name":"Read"}"#),
                     apiError("rate_limit", at: 6, resetsAt: 1_800_018_000), apiError("server_error", at: 7), retry(3, at: 8),
                     answer("Done", at: 9)]
        let fast = parse(lines), slow = ClaudeTranscriptParser.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(fast.count, lines.count)
        XCTAssertEqual(fast.map(\.toolName), ["Bash", nil, nil, nil, "mcp__hud__layout", nil, nil, nil, nil])
        XCTAssertEqual(fast.map(\.toolUseID), ["toolu_A", nil, nil, nil, "toolu_C", nil, nil, nil, nil])
        XCTAssertEqual(fast.map(\.toolResultID), [nil, "toolu_A", "toolu_B", nil, nil, nil, nil, nil, nil],
                       "a failed command's result names its call after the output, past the line's prefix")
        XCTAssertEqual(fast.map(\.isThinking), [false, false, false, true, false, false, false, false, false],
                       "only the block's own type counts, never the same words inside a call's input or a thought")
        XCTAssertEqual(fast.map(\.apiError), [nil, nil, nil, nil, nil, "rate_limit", "server_error", nil, nil])
        XCTAssertEqual(fast[5].limitResetsAt, Date(timeIntervalSince1970: 1_800_018_000))
        XCTAssertNil(fast[6].limitResetsAt, "an error that is no limit says nothing of one")
        XCTAssertEqual(fast.map(\.retryAttempt), [nil, nil, nil, nil, nil, nil, nil, 3, nil])
        XCTAssertEqual(fast[7].role, .other)
        for key in [\TranscriptEvent.toolName, \.toolUseID, \.toolResultID, \.apiError] {
            XCTAssertEqual(fast.map { $0[keyPath: key] }, slow.map { $0[keyPath: key] })
        }
        XCTAssertEqual(fast.map(\.isThinking), slow.map(\.isThinking))
        XCTAssertEqual(fast.map(\.limitResetsAt), slow.map(\.limitResetsAt))
        XCTAssertEqual(fast.map(\.retryAttempt), slow.map(\.retryAttempt))
        XCTAssertEqual(fast.map(\.model)[5], "<synthetic>")
    }

    // MARK: Turn ends

    func testAnAPIErrorEndsTheTurnLimitedUntilItsResetOrFailed() throws {
        var accumulator = TranscriptAccumulator(path: "/p/s-act.jsonl", isSubagent: false)
        read(&accumulator, prompt("Build it", at: 0), call("Bash", id: "toolu_1", at: 1), result("toolu_1", at: 2),
             apiError("rate_limit", at: 3, resetsAt: 1_800_018_000))
        var turn = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(turn.state, .ended, "a rate-limited turn is over, not running quietly for half an hour")
        XCTAssertEqual(turn.outcome, .limited(resetsAt: Date(timeIntervalSince1970: 1_800_018_000)))
        XCTAssertEqual(turn.observedAtMs, RecordCoding.milliseconds(base.addingTimeInterval(3)))
        XCTAssertEqual(accumulator.build()?.completions, [], "a limit is no completion")

        read(&accumulator, stopSummary(at: 4))
        XCTAssertEqual(accumulator.build()?.turn?.outcome, .limited(resetsAt: Date(timeIntervalSince1970: 1_800_018_000)),
                       "a later Stop summary does not turn the limit into a quiet end")
        read(&accumulator, prompt("Try again", at: 60))
        turn = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(turn.state, .running)
        XCTAssertNil(turn.outcome, "the next prompt lifts the limit")

        read(&accumulator, apiError("billing_error", at: 61))
        XCTAssertEqual(accumulator.build()?.turn?.outcome, .limited(resetsAt: nil), "without a reset it lasts until the next prompt")
        read(&accumulator, prompt("Once more", at: 70), apiError("server_error", at: 75))
        XCTAssertEqual(accumulator.build()?.turn?.outcome, .failed)
        XCTAssertEqual(accumulator.build()?.turn?.state, .ended)
    }

    func testAStopIsInterruptedAnAnswerCompletedAndASilentEndHasNoReason() throws {
        var accumulator = TranscriptAccumulator(path: "/p/s-act.jsonl", isSubagent: false)
        read(&accumulator, prompt("Build it", at: 0), answer("Done", at: 5))
        XCTAssertEqual(accumulator.build()?.turn?.outcome, .completed)
        read(&accumulator, prompt("Again", at: 10), call("Bash", id: "toolu_1", at: 11), prompt("[Request interrupted by user for tool use]", at: 12))
        XCTAssertEqual(accumulator.build()?.turn?.state, .ended)
        XCTAssertEqual(accumulator.build()?.turn?.outcome, .interrupted, "a stop is never a failure")
        XCTAssertFalse(accumulator.build()?.activity?.hasOpenCall ?? true, "the interrupted call is not left open")

        read(&accumulator, prompt("Write it", at: 20), answer("Partly", stop: "max_tokens", at: 25), stopSummary(at: 26))
        XCTAssertEqual(accumulator.build()?.turn?.state, .completed)
        XCTAssertNil(accumulator.build()?.turn?.outcome, "a turn the Stop hooks close without an end_turn ends without a reason")

        read(&accumulator, answer("Picking up the agent's report", stop: "tool_use", at: 40))
        XCTAssertEqual(accumulator.build()?.turn?.state, .running, "woken without a prompt, the turn runs again")
        XCTAssertNil(accumulator.build()?.turn?.outcome)

        read(&accumulator, apiError("server_error", at: 50))
        let restored = try JSONDecoder().decode(TranscriptAccumulator.self, from: JSONEncoder().encode(accumulator))
        XCTAssertEqual(restored.build()?.turn?.outcome, .failed, "the reason a turn ended survives a restart")
        XCTAssertEqual(restored.build()?.activity, accumulator.build()?.activity, "what the turn is busy with survives a restart")
    }

    // MARK: Activity

    func testTheKindFollowsTheOpenCallElseTheNewestCallReadElseStays() throws {
        var accumulator = TranscriptAccumulator(path: "/p/s-act.jsonl", isSubagent: false)
        read(&accumulator, prompt("Build it", at: 0))
        var activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertNil(activity.work, "nothing was called yet")
        XCTAssertEqual(activity.line, .prompt)
        XCTAssertTrue(activity.awaitsModel)

        read(&accumulator, call("Bash", id: "toolu_1", at: 1))
        activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertEqual(activity.openCall, .init(id: "toolu_1", work: .shell, at: base.addingTimeInterval(1)))
        XCTAssertEqual(activity.work, .shell)
        XCTAssertFalse(activity.awaitsModel, "a call is out with its tool")

        // The command's result and a whole read call come in one read: the newest call read gives the kind.
        read(&accumulator, result("toolu_1", at: 30), call("Read", id: "toolu_2", at: 31, input: #"{"file_path":"/p/a"}"#),
             result("toolu_2", at: 31.5))
        activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertNil(activity.openCall)
        XCTAssertEqual(activity.work, .read, "a call caught closed still says what the turn does")
        XCTAssertEqual(activity.toolAt, base.addingTimeInterval(31.5), "the newest call was last seen at its result")
        XCTAssertEqual(activity.line, .result)

        read(&accumulator, thinking(at: 40))
        activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertEqual(activity.work, .read, "a read with no call keeps the kind")
        XCTAssertEqual(activity.line, .thinking)
        XCTAssertTrue(activity.awaitsModel)

        read(&accumulator, call("TodoWrite", id: "toolu_3", at: 41, input: #"{"todos":[]}"#), result("toolu_3", at: 42),
             call("AskUserQuestion", id: "toolu_4", at: 43, input: #"{"questions":[]}"#), result("toolu_4", at: 50))
        XCTAssertEqual(accumulator.build()?.activity?.work, .read, "tools no group names, and questions, never change the kind")

        // Two calls out at once: the newest open one gives the kind, then the one still open.
        read(&accumulator, call("Bash", id: "toolu_5", at: 60), call("Grep", id: "toolu_6", at: 61, input: #"{"pattern":"x"}"#))
        XCTAssertEqual(accumulator.build()?.activity?.work, .read)
        read(&accumulator, result("toolu_6", at: 62))
        activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertEqual(activity.work, .shell, "the call still open outranks the one that came back")
        XCTAssertEqual(activity.openCall?.id, "toolu_5")
        read(&accumulator, failedResult("toolu_5", at: 70))
        XCTAssertFalse(try XCTUnwrap(accumulator.build()?.activity).hasOpenCall, "a failed command still answers its call")

        read(&accumulator, call("Agent", id: "toolu_7", at: 80, input: #"{"prompt":"look"}"#),
             call("mcp__github__search", id: "toolu_8", at: 81, input: #"{"q":"x"}"#))
        activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertTrue(activity.delegating, "an open Agent call is sub-agents at work")
        XCTAssertEqual(activity.work, .command, "an MCP tool is a command; starting an agent is no kind of its own")

        read(&accumulator, prompt("Next", at: 90))
        activity = try XCTUnwrap(accumulator.build()?.activity)
        XCTAssertFalse(activity.hasOpenCall)
        XCTAssertFalse(activity.delegating)
        XCTAssertNil(activity.work, "a new turn starts with no kind")
        XCTAssertNil(activity.toolAt)
    }

    func testAPromptOlderThanTheTurnLeavesItsCallsOpen() throws {
        var accumulator = TranscriptAccumulator(path: "/p/s-act.jsonl", isSubagent: false)
        read(&accumulator, prompt("Build it", at: 10), call("Bash", id: "toolu_1", at: 11))
        read(&accumulator, prompt("Written late", at: 5))
        XCTAssertEqual(accumulator.build()?.activity?.openCall?.id, "toolu_1", "a prompt that starts no turn starts no activity either")
        XCTAssertEqual(accumulator.build()?.activity?.line, .call)
    }

    func testOnlyARetrysOwnLineSaysTheAPIIsRetried() throws {
        var accumulator = TranscriptAccumulator(path: "/p/s-act.jsonl", isSubagent: false)
        read(&accumulator, prompt("Build it", at: 0), retry(1, at: 5))
        XCTAssertEqual(accumulator.build()?.activity?.retrying, true)
        XCTAssertEqual(accumulator.build()?.activity?.line, .prompt, "a system line is not part of the conversation")
        read(&accumulator, retry(2, at: 10))
        XCTAssertEqual(accumulator.build()?.activity?.retrying, true)
        read(&accumulator, thinking(at: 20))
        XCTAssertEqual(accumulator.build()?.activity?.retrying, false, "the model answered")
        read(&accumulator, apiError("server_error", at: 30))
        XCTAssertEqual(accumulator.build()?.activity?.line, .error)
        XCTAssertFalse(try XCTUnwrap(accumulator.build()?.activity).awaitsModel)
    }

    func testOnlyAMainLogKeepsActivity() {
        var subagent = TranscriptAccumulator(path: "/p/s-act/subagents/agent-a.jsonl", isSubagent: true)
        read(&subagent, prompt("Look", at: 0), call("Bash", id: "toolu_1", at: 1))
        XCTAssertNil(subagent.build()?.activity, "a sub-agent's calls are its parent's sub-agents at work, not its calls")
        var main = TranscriptAccumulator(path: "/p/s-act.jsonl", isSubagent: false)
        let sidechain = call("Bash", id: "toolu_s", at: 2).replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
        read(&main, prompt("Look", at: 0), sidechain)
        XCTAssertEqual(main.build()?.activity?.hasOpenCall, false, "an older build's sub-agent lines in the parent's log are not its calls")
    }

    // MARK: Provider

    func testTheProviderAddsSubagentsAndACompactionNewerThanTheLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("projects/-p", isDirectory: true)
        let agents = project.appendingPathComponent("s-act/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Double { now.addingTimeInterval(-seconds).timeIntervalSince(base) }
        let log = project.appendingPathComponent("s-act.jsonl")
        try ([prompt("Build it", at: ago(120)), call("Bash", id: "toolu_1", at: ago(100)), result("toolu_1", at: ago(90))]
            .joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        try (prompt("Look", at: ago(80)) + "\n" + call("Read", id: "toolu_a", at: ago(10)).replacingOccurrences(
                of: #""isSidechain":false"#, with: #""isSidechain":true"#) + "\n")
            .write(to: agents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)
        let compactions = root.appendingPathComponent("compaction", isDirectory: true)
        try CompactionHooks.record(source: .claude, data: Data(#"{"session_id":"s-act","hook_event_name":"PreCompact","trigger":"auto"}"#.utf8),
                                   now: now.addingTimeInterval(-60), directory: compactions)
        let provider = ClaudeCodeProvider(engine: nil, transcripts: ClaudeTranscriptStore(root: root.appendingPathComponent("projects")),
                                          history: QuotaHistoryStore(), compactionsDirectory: compactions)
        XCTAssertTrue(provider.watchedDirectories?.contains(compactions) == true, "a compaction's record wakes a read")

        var report = try await provider.fetchUsage(agents: [], historyHours: 24)
        var activity = try XCTUnwrap(report.sessions.first?.activity)
        XCTAssertEqual(activity.work, .shell)
        XCTAssertNotNil(activity.subagentsAt, "the sub-agent's own log moves")
        XCTAssertTrue(activity.delegating)
        XCTAssertEqual(activity.compactingSince.map { $0.timeIntervalSince1970.rounded() }, now.addingTimeInterval(-60).timeIntervalSince1970.rounded(),
                       "compaction began after the log's last line")

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"parentUuid":null,"isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto"},"timestamp":"\#(stamp(ago(5)))",\#(tail)"# + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: log.path)
        report = try await provider.fetchUsage(agents: [], historyHours: 24)
        activity = try XCTUnwrap(report.sessions.first?.activity)
        XCTAssertNil(activity.compactingSince, "the boundary ends it")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.sessions[0])) as? [String: Any]
        XCTAssertNil(encoded?["activity"], "what a turn is busy with never leaves this Mac in a session report")
    }

    func testOnlyAnAutomaticCompactionNewerThanTheLogCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try CompactionHooks.record(source: .claude, data: Data(#"{"session_id":"a","hook_event_name":"PreCompact","trigger":"auto"}"#.utf8), now: base, directory: directory)
        try CompactionHooks.record(source: .claude, data: Data(#"{"session_id":"m","hook_event_name":"PreCompact","trigger":"manual"}"#.utf8), now: base, directory: directory)
        try CompactionHooks.record(source: .claude, data: Data(#"{"hook_event_name":"PreCompact","trigger":"auto"}"#.utf8), now: base, directory: directory)
        let read = CompactionHooks.read(source: .claude, now: base.addingTimeInterval(10), directory: directory)
        XCTAssertEqual(Set(read.keys), ["a", "m"], "a record without a session is dropped")
        XCTAssertEqual(CompactionHooks.since(read["a"], lastLineAt: base.addingTimeInterval(-1)), base)
        XCTAssertNil(CompactionHooks.since(read["m"], lastLineAt: base.addingTimeInterval(-1)), "a /compact the user typed is not shown")
        XCTAssertNil(CompactionHooks.since(read["a"], lastLineAt: base.addingTimeInterval(1)), "a newer line ends it")
        XCTAssertTrue(CompactionHooks.read(source: .claude, now: base.addingTimeInterval(CompactionHooks.limit + 1), directory: directory).isEmpty,
                      "a compaction begun five minutes ago is over")
    }
}

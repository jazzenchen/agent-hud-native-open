import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// What a Codex rollout says its running turn is busy with, read from the first bytes of its calls and their outputs,
/// and why its turns end.
final class CodexActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var ordinal = 0

    private let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private func stamp(_ second: Double) -> String { iso.format(start.addingTimeInterval(second)) }

    /// A line as Codex writes it: its time, its place and its type first, then the payload, whose own type leads.
    private func line(_ type: String, _ payload: String, at second: Double) -> String {
        ordinal += 1
        return #"{"timestamp":"\#(stamp(second))","ordinal":\#(ordinal),"type":"\#(type)","payload":\#(payload)}"#
    }

    private func event(_ payload: String, at second: Double) -> String { line("event_msg", payload, at: second) }

    private func started(_ turn: String, at second: Double) -> String {
        event(#"{"type":"task_started","turn_id":"\#(turn)","started_at":1800000000}"#, at: second)
    }

    private func custom(_ name: String, id: String, at second: Double) -> String {
        line("response_item", #"{"type":"custom_tool_call","id":"ctc_\#(id)","status":"completed","call_id":"\#(id)","name":"\#(name)","input":"ls -la","internal_chat_message_metadata_passthrough":{"turn_id":"t"}}"#, at: second)
    }

    private func function(_ name: String, namespace: String? = nil, id: String, arguments: String = "{}", at second: Double) -> String {
        let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: [arguments]), as: UTF8.self).dropFirst().dropLast()
        let space = namespace.map { #""namespace":"\#($0)","# } ?? ""
        return line("response_item", #"{"type":"function_call","id":"fc_\#(id)","name":"\#(name)",\#(space)"arguments":\#(escaped),"call_id":"\#(id)","internal_chat_message_metadata_passthrough":{"turn_id":"t"}}"#, at: second)
    }

    private func output(_ id: String, custom: Bool = false, at second: Double) -> String {
        let type = custom ? "custom_tool_call_output" : "function_call_output"
        let body = String(repeating: "x", count: 4000)
        return line("response_item", #"{"type":"\#(type)","id":"o_\#(id)","call_id":"\#(id)","output":"\#(body)","internal_chat_message_metadata_passthrough":{"turn_id":"t"}}"#, at: second)
    }

    private func item(_ type: String, at second: Double) -> String {
        event(#"{"type":"item_completed","thread_id":"th","turn_id":"t","item":{"type":"\#(type)","id":"i","path":"/p/a.png","changes":{}},"started_at_ms":1,"completed_at_ms":2}"#, at: second)
    }

    private func read(_ transcript: inout CodexTranscript, _ lines: String...) {
        _ = CodexRollouts.ingest(Data((lines.joined(separator: "\n") + "\n").utf8), at: 0, into: &transcript)
    }

    private func session(at second: Double = 0) -> String {
        line("session_meta", #"{"id":"codex-s","timestamp":"\#(stamp(second))","cwd":"/p","source":"cli","originator":"codex_cli_rs"}"#, at: second)
    }

    func testAnOpenCallSaysWhatTheTurnDoesUntilItsOutputComesBack() throws {
        var t = CodexTranscript()
        read(&t, session(), custom("exec", id: "call_before", at: 0.5))
        XCTAssertNil(t.activity, "a call before any turn of this rollout is not its work")

        read(&t, started("t", at: 1), custom("exec", id: "call_1", at: 2))
        var activity = try XCTUnwrap(t.activity)
        XCTAssertEqual(activity.openCall, .init(id: "call_1", work: .shell, at: start.addingTimeInterval(2)))
        XCTAssertEqual(activity.work, .shell)
        XCTAssertEqual(t.sessionTurns.last?.observedAtMs, RecordCoding.milliseconds(start.addingTimeInterval(2)), "a call dates the turn")

        // A long argument list puts a function call's id far past the line's first bytes.
        read(&t, output("call_1", custom: true, at: 3),
             function("js", namespace: "mcp__cua_repl", id: "call_2", arguments: String(repeating: "await page.click();", count: 200), at: 4))
        activity = try XCTUnwrap(t.activity)
        XCTAssertEqual(activity.openCall?.id, "call_2")
        XCTAssertEqual(activity.work, .command, "a js call is a command")
        read(&t, output("call_2", at: 5))
        activity = try XCTUnwrap(t.activity)
        XCTAssertFalse(activity.hasOpenCall)
        XCTAssertEqual(activity.work, .command, "with nothing open the turn keeps the kind its last call gave")
        XCTAssertEqual(activity.line, .result)
        XCTAssertTrue(activity.awaitsModel)

        read(&t, item("FileChange", at: 6))
        XCTAssertEqual(t.activity?.work, .edit, "a file changed in this read says the turn edits")
        read(&t, item("ImageView", at: 7))
        XCTAssertEqual(t.activity?.work, .read)
        read(&t, item("Reasoning", at: 8), function("untrusted_input", id: "call_3", at: 9), output("call_3", at: 9.5))
        XCTAssertEqual(t.activity?.work, .read, "neither reasoning nor a tool no group names changes the kind")

        read(&t, function("spawn_agent", namespace: "collaboration", id: "call_4", at: 10))
        activity = try XCTUnwrap(t.activity)
        XCTAssertTrue(activity.delegating, "spawning an agent is sub-agents at work")
        XCTAssertEqual(activity.work, .read)
        read(&t, output("call_4", at: 11), function("wait_agent", namespace: "collaboration", id: "call_5", at: 12))
        XCTAssertTrue(try XCTUnwrap(t.activity).delegating, "and so is waiting on them")
        read(&t, output("call_5", at: 40), function("request_user_input_async", id: "call_6", at: 41))
        activity = try XCTUnwrap(t.activity)
        XCTAssertFalse(activity.delegating)
        XCTAssertEqual(activity.askedAt, start.addingTimeInterval(41), "Desktop asks the user through a call of its own")

        read(&t, event(#"{"type":"task_complete","turn_id":"t","last_agent_message":"Done"}"#, at: 50))
        activity = try XCTUnwrap(t.activity)
        XCTAssertFalse(activity.hasOpenCall, "nothing of a finished turn is still open")
        XCTAssertNil(activity.askedAt)
        read(&t, custom("exec", id: "call_late", at: 51))
        XCTAssertFalse(try XCTUnwrap(t.activity).hasOpenCall, "a call outside a running turn is not read")

        read(&t, started("t2", at: 60))
        activity = try XCTUnwrap(t.activity)
        XCTAssertNil(activity.work, "a new turn starts with no kind")
        XCTAssertEqual(activity.line, .prompt)
        let restored = try JSONDecoder().decode(CodexTranscript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(restored.activity, t.activity)
    }

    func testEveryShellToolCodexHasIsAShellCommand() throws {
        // The shell tool types a Codex config can pick: a function call named `shell_command`, or a local shell call
        // with no name, whose output is a function call's.
        var t = CodexTranscript()
        read(&t, session(), started("t", at: 1), function("shell_command", id: "call_1", arguments: #"{"command":"cargo test"}"#, at: 2))
        XCTAssertEqual(t.activity?.openCall?.work, .shell)
        read(&t, output("call_1", at: 3),
             line("response_item", #"{"type":"local_shell_call","id":"lsc_1","call_id":"call_2","status":"in_progress","action":{"type":"exec","command":["ls"]}}"#, at: 4))
        let activity = try XCTUnwrap(t.activity)
        XCTAssertEqual(activity.openCall, .init(id: "call_2", work: .shell, at: start.addingTimeInterval(4)))
        read(&t, output("call_2", at: 5))
        XCTAssertFalse(try XCTUnwrap(t.activity).hasOpenCall)
    }

    func testATurnEndsCompletedLimitedFailedOrInterruptedByWhatTheRolloutSays() throws {
        var t = CodexTranscript()
        read(&t, session())
        let ends: [(String, TurnOutcome?)] = [
            (#"{"type":"task_complete","turn_id":"t1","last_agent_message":"Done"}"#, .completed),
            (#"{"type":"task_complete","turn_id":"t2","last_agent_message":null,"error":{"message":"You've hit your usage limit.","codex_error_info":"usage_limit_exceeded"}}"#, .limited(resetsAt: nil)),
            (#"{"type":"task_complete","turn_id":"t3","last_agent_message":null,"error":{"message":"Overloaded","codex_error_info":"server_overloaded"}}"#, .failed),
            (#"{"type":"task_complete","turn_id":"t4","last_agent_message":null,"error":{"message":"x","codex_error_info":"other"}}"#, .failed),
            (#"{"type":"task_complete","turn_id":"t5","error":{"message":"x","codex_error_info":{"usage_limit_exceeded":{"plan":"plus"}}}}"#, .limited(resetsAt: nil)),
            (#"{"type":"task_complete","turn_id":"t6","error":"stream closed"}"#, .failed),
            (#"{"type":"turn_aborted","turn_id":"t7","reason":"interrupted"}"#, .interrupted),
            (#"{"type":"turn_aborted","turn_id":"t8","reason":"replaced"}"#, nil),
        ]
        for (index, (end, outcome)) in ends.enumerated() {
            let second = Double(index * 10)
            read(&t, started("t\(index + 1)", at: second + 1), custom("exec", id: "call_\(index)", at: second + 2), event(end, at: second + 5))
            let turn = try XCTUnwrap(t.sessionTurns.last)
            XCTAssertEqual(turn.outcome, outcome, end)
            XCTAssertNotEqual(turn.state, .running, end)
            XCTAssertFalse(t.activity?.hasOpenCall ?? true, "the call the turn left open is closed with it")
        }
        XCTAssertEqual(t.completions?.count, 1, "only the answered turn completes")
        XCTAssertEqual(t.evidence.turn?.outcome, nil, "the evidence carries the newest turn as it ended")
        let restored = try JSONDecoder().decode(CodexTranscript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(restored.sessionTurns.map(\.outcome), t.sessionTurns.map(\.outcome), "why a turn ended survives a restart")
    }

    func testTheProviderHandsTheActivityToTheSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)", isDirectory: true)
        let day = root.appendingPathComponent("sessions/2026/10/16", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Double { now.addingTimeInterval(-seconds).timeIntervalSince(start) }
        let lines = [session(at: ago(40)), started("t", at: ago(30)), custom("exec", id: "call_1", at: ago(25))]
        try (lines.joined(separator: "\n") + "\n").write(to: day.appendingPathComponent("rollout-2026-10-16T00-00-00-codex-s.jsonl"),
                                                          atomically: true, encoding: .utf8)
        let provider = CodexUsageProvider(readLimits: { throw UsageProviderError("signed out") },
                                          transcripts: CodexTranscriptStore(roots: [root.appendingPathComponent("sessions")]),
                                          history: QuotaHistoryStore())
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertNil(session.endedAt)
        XCTAssertEqual(session.activity?.openCall?.work, .shell)
    }
}

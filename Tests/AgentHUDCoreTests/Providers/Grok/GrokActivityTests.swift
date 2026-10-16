import XCTest
@testable import AgentHUDCore

/// What a Grok CLI log says its running turn is busy with: its tool calls and their updates, read each time the log is.
final class GrokActivityTests: XCTestCase {
    private let start: Int64 = 1_788_800_000_000

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("s")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func update(_ second: Int64, _ update: [String: Any]) -> String {
        let line: [String: Any] = ["method": "session/update", "params": ["sessionId": "s", "update": update,
            "_meta": ["eventId": "e\(second)", "promptId": "p", "agentTimestampMs": start + second * 1000]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    private func read(_ url: URL, _ lines: [String]) throws -> ProviderSession {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return try XCTUnwrap(GrokSessions.read(url).sessions.first)
    }

    func testACallOpensWithItsKindAndClosesWhenItsUpdateSaysItFinished() throws {
        let url = try directory().appendingPathComponent("updates.jsonl")
        var lines = [update(0, ["sessionUpdate": "user_message_chunk"]),
                     update(1, ["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "run_terminal_command",
                                "_meta": ["x.ai/tool": ["name": "run_terminal_command"]]])]
        var activity = try XCTUnwrap(try read(url, lines).activity)
        XCTAssertEqual(activity.openCall?.work, .shell, "the tool's name says it runs a command")
        lines.append(update(2, ["sessionUpdate": "tool_call_update", "toolCallId": "c1", "kind": "execute"]))
        activity = try XCTUnwrap(try read(url, lines).activity)
        XCTAssertEqual(activity.openCall, .init(id: "c1", work: .shell, at: Date(timeIntervalSince1970: Double(start) / 1000 + 1)),
                       "an update that names the kind keeps when the call was made")

        lines += [update(5, ["sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed"]),
                  update(6, ["sessionUpdate": "tool_call", "toolCallId": "c2", "title": "list_dir",
                             "_meta": ["x.ai/tool": ["name": "list_dir", "kind": "list"]]]),
                  update(7, ["sessionUpdate": "tool_call_update", "toolCallId": "c2", "status": "completed"])]
        activity = try XCTUnwrap(try read(url, lines).activity)
        XCTAssertFalse(activity.hasOpenCall)
        XCTAssertEqual(activity.work, .read, "the turn's newest call says what it does")

        lines.append(update(9, ["sessionUpdate": "turn_completed", "prompt_id": "p", "stop_reason": "cancelled"]))
        let session = try read(url, lines)
        XCTAssertEqual(session.turns.map(\.outcome), [.interrupted])
        XCTAssertEqual(session.activity?.hasOpenCall, false)
    }
}

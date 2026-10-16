import XCTest
@testable import AgentHUDCore

/// What a Harness log says its running turn is busy with, and why its turns end.
final class DeepSeekActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1788787140)

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }

    private var header: Data {
        json(["type": "session", "version": 0, "id": "main", "createdAt": now.addingTimeInterval(-10).timeIntervalSince1970 * 1000,
              "cwd": "/test/project", "delegationDepth": 0])
    }

    private func event(_ type: String, seq: Int, data: [String: Any], answers: [Int]? = nil) -> Data {
        var object: [String: Any] = ["type": type, "seq": seq, "time": now.addingTimeInterval(Double(seq)).timeIntervalSince1970 * 1000, "data": data]
        object["sourceEventSeqs"] = answers
        return json(object)
    }

    private func call(_ name: String, seq: Int, turn: Int = 1) -> Data {
        event("tool/call", seq: seq, data: ["turn": turn, "step": 1, "callId": "call_\(seq)", "name": name])
    }

    private func result(_ call: Int, seq: Int, turn: Int = 1) -> Data {
        event("tool/result", seq: seq, data: ["turn": turn, "step": 1], answers: [call])
    }

    private func end(_ turn: Int, seq: Int, reason: [String: Any]) -> Data {
        event("turn/end", seq: seq, data: ["turn": turn, "reason": reason])
    }

    /// One read of the log, as the store makes it.
    private func read(_ transcript: inout DeepSeekTranscript, _ lines: Data...) throws {
        for line in lines { try transcript.ingest(line) }
        transcript.settleActivity()
    }

    func testACallIsOpenUntilItsResultNamesIt() throws {
        var t = DeepSeekTranscript()
        try read(&t, header, call("bash", seq: 0))
        XCTAssertNil(t.activity, "a call before any turn is not the turn's work")
        try read(&t, event("turn/start", seq: 1, data: ["turn": 1]), call("bash", seq: 2))
        var activity = try XCTUnwrap(t.activity)
        XCTAssertEqual(activity.openCall?.work, .shell)
        XCTAssertEqual(activity.openCall?.at, now.addingTimeInterval(2))

        try read(&t, result(2, seq: 3), call("read", seq: 4), result(4, seq: 5))
        activity = try XCTUnwrap(t.activity)
        XCTAssertFalse(activity.hasOpenCall, "a result answers the call whose line it names")
        XCTAssertEqual(activity.work, .read)
        try read(&t, call("todo_write", seq: 6), result(6, seq: 7), call("subagent", seq: 8))
        activity = try XCTUnwrap(t.activity)
        XCTAssertEqual(activity.work, .read, "a to-do list says nothing of what the turn does")
        XCTAssertTrue(activity.delegating)

        try read(&t, end(1, seq: 9, reason: ["kind": "error", "error": ["code": "RATE_LIMIT"]]))
        XCTAssertEqual(t.sessionTurns.last?.outcome, .limited(resetsAt: nil))
        XCTAssertFalse(try XCTUnwrap(t.activity).hasOpenCall, "nothing of a finished turn is still open")
        let restored = try JSONDecoder().decode(DeepSeekTranscript.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(restored.sessionTurns.last?.outcome, .limited(resetsAt: nil))
    }

    func testATurnEndsCompletedFailedOrWithoutAReasonByItsEndsKind() throws {
        let ends: [([String: Any], TurnOutcome?)] = [
            (["kind": "completed"], .completed),
            (["kind": "error", "error": ["code": "SERVER"]], .failed),
            (["kind": "error", "error": ["code": "TRANSPORT"]], .failed),
            (["kind": "error", "error": ["code": "RATE_LIMIT"]], .limited(resetsAt: nil)),
            (["kind": "max-tokens"], nil),
        ]
        for (reason, outcome) in ends {
            var t = DeepSeekTranscript()
            try read(&t, header, event("turn/start", seq: 0, data: ["turn": 1]), end(1, seq: 1, reason: reason))
            XCTAssertEqual(t.sessionTurns.map(\.outcome), [outcome], "\(reason)")
        }
    }
}

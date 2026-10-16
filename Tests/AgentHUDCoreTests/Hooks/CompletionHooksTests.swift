import Foundation
import XCTest
@testable import AgentHUDCore

final class CompletionHooksTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1788800000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func json(_ value: [String: Any]) throws -> ProviderJSON {
        try .read(JSONSerialization.data(withJSONObject: value))
    }

    func testGrokNamespacedCompletionSurvivesUsageLogPrecedence() async throws {
        let root = try directory(), session = root.appendingPathComponent("sessions/%2Ffixture/s")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let logs: [[String: Any]] = [
            ["method": "session/update", "params": ["sessionId": "s", "_meta": ["eventId": "user", "promptId": "p", "agentTimestampMs": 1788800000000],
                "update": ["sessionUpdate": "user_message_chunk"]]],
            ["method": "_x.ai/session/update", "params": ["sessionId": "s", "_meta": ["eventId": "done", "agentTimestampMs": 1788800002000],
                "update": ["sessionUpdate": "turn_completed", "prompt_id": "p", "stop_reason": "end_turn",
                    "usage": ["inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 60, "modelUsage": ["grok-test": [:]]]]]]
        ]
        let lines = try (logs + [logs[1]]).map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        try #"{"ts":"2026-09-07T16:53:21Z","sid":"s","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100,"completion_tokens":20,"cached_prompt_tokens":60}}"#
            .write(to: root.appendingPathComponent("unified.jsonl"), atomically: true, encoding: .utf8)
        let result = await AdditionalLocalStore(source: .grok, roots: [root]).index(since: now.addingTimeInterval(-10))
        let item = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(item.events.count, 1)
        XCTAssertEqual(item.events[0].input, 40)
        XCTAssertEqual(item.completions.count, 1)
        XCTAssertEqual(item.completions[0].model, "grok-test")
        XCTAssertEqual(item.completions[0].startedAt, now)
        XCTAssertEqual(item.turns.count, 1)
        XCTAssertEqual(item.turns[0].turnID, "p")
        XCTAssertEqual(item.turns[0].state, .completed)
    }

    func testGrokAbortedOrUnknownStopDoesNotNotify() throws {
        for reason in ["cancelled", "max_tokens", "error", ""] {
            let directory = try directory(), url = directory.appendingPathComponent("updates.jsonl")
            let payload = try json(["method": "_x.ai/session/update", "params": ["sessionId": directory.lastPathComponent,
                "_meta": ["eventId": "done", "agentTimestampMs": 1788800000000],
                "update": ["sessionUpdate": "turn_completed", "stop_reason": reason]]])
            try JSONEncoder().encode(payload).write(to: url)
            let item = try XCTUnwrap(GrokSessions.read(url).sessions.first)
            XCTAssertTrue(item.completions.isEmpty)
            XCTAssertEqual(item.turns.first?.state, .ended)
            XCTAssertEqual(item.turns.first?.outcome, reason == "cancelled" ? .interrupted : nil, reason)
        }
    }

    func testAntigravityStopRecordsEveryFinishedTurn() throws {
        let directory = try directory()
        // The payload agy sends when a turn ends; `executionNum` stays 0 on every turn of a conversation.
        var payload: [String: Any] = ["conversationId": "s", "executionNum": 0, "terminationReason": "NO_TOOL_CALL",
            "fullyIdle": true, "error": "", "modelName": "gemini-test", "workspacePaths": ["/work/project"]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try CompletionHooks.record(source: .antigravity, data: data, now: now, directory: directory)
        try CompletionHooks.record(source: .antigravity, data: data, now: now.addingTimeInterval(5), directory: directory)
        let events = try CompletionHooks.read(source: .antigravity, since: now.addingTimeInterval(-1), directory: directory)
            .sorted { $0.completedAt < $1.completedAt }
        XCTAssertEqual(events.map(\.completedAt), [now, now.addingTimeInterval(5)])
        XCTAssertEqual(events[0].sessionID, "antigravity:s")
        XCTAssertEqual(events[0].navigationTarget, .antigravityConversation(id: "s"))
        let saved = try Data(contentsOf: directory.appendingPathComponent("antigravity/\(events[0].id).json"))
        XCTAssertNil(try JSONDecoder().decode(SessionCompletion.self, from: saved).navigationTarget,
                     "the local reader reconstructs the destination; completion reports never encode it")
        XCTAssertEqual(events[0].model, "gemini-test")
        XCTAssertEqual(events[0].task, "Antigravity · project")
        payload["fullyIdle"] = false
        XCTAssertNil(try CompletionHooks.completion(source: .antigravity, payload: json(payload), now: now))
        payload["fullyIdle"] = true
        for reason in ["model_stop", "ERROR", "USER_CANCELED", "MAX_INVOCATIONS", "HALTED_STEP"] {
            payload["terminationReason"] = reason
            XCTAssertNil(try CompletionHooks.completion(source: .antigravity, payload: json(payload), now: now))
        }
        payload["terminationReason"] = "NO_TOOL_CALL"; payload["error"] = "failure"
        XCTAssertNil(try CompletionHooks.completion(source: .antigravity, payload: json(payload), now: now))
    }

    func testCursorInboxStripsUnneededDataAndDoesNotReplay() async throws {
        let directory = try directory()
        var payload: [String: Any] = ["conversation_id": "s", "generation_id": "g", "hook_event_name": "stop",
            "status": "completed", "model_id": "cursor-test", "workspace_roots": ["/work/project"],
            "user_email": "private@example.test", "prompt": "private fixture text"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try CompletionHooks.record(source: .cursor, data: data, now: now, directory: directory)
        try CompletionHooks.record(source: .cursor, data: data, now: now.addingTimeInterval(1), directory: directory)
        let events = try CompletionHooks.read(source: .cursor, since: now.addingTimeInterval(-1), directory: directory)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].completedAt, now)
        let saved = try String(contentsOf: directory.appendingPathComponent("cursor/\(events[0].id).json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("private"))
        for state in ["error", "aborted", "unknown"] {
            payload["status"] = state
            XCTAssertNil(try CompletionHooks.completion(source: .cursor, payload: json(payload), now: now))
        }
        let provider = AdditionalUsageProvider(source: .cursor, readQuota: { throw ProviderFailure.login("Cursor") },
            readSessions: { _ in ProviderSessions() }, history: QuotaHistoryStore(),
            readCompletions: { _ in events }, clock: { self.now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let agents: [AgentDescriptor] = []
        var tracker = IslandEventTracker(startedAt: now.addingTimeInterval(-1))
        XCTAssertEqual(tracker.update(report: report, agents: agents, now: now).completions.count, 1)
        XCTAssertTrue(tracker.update(report: report, agents: agents, now: now).completions.isEmpty)
        var restarted = IslandEventTracker(startedAt: now.addingTimeInterval(1))
        XCTAssertTrue(restarted.update(report: report, agents: agents, now: now.addingTimeInterval(2)).completions.isEmpty)
    }

    func testTheRunningAppTakesOverAHandlerAnotherCopyWrote() throws {
        let current = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        // Another build still installed, a translocated copy, the disk image the app came on, and an app since deleted.
        let others = [URL(fileURLWithPath: "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open"),
                      URL(fileURLWithPath: "/private/var/folders/x1/T/AppTranslocation/5D1C/d/Agent HUD.app/Contents/MacOS/Agent HUD"),
                      URL(fileURLWithPath: "/Volumes/Agent HUD/Agent HUD.app/Contents/MacOS/Agent HUD"),
                      URL(fileURLWithPath: "/Users/me/.Trash/Agent HUD.app/Contents/MacOS/Agent HUD")]
        for source in CompletionHooks.Source.allCases {
            let home = try directory(), file = source.configuration(home: home)
            let ours = { HookCommand.make(executable: $0, arguments: "--completion-hook \(source.rawValue)") }
            let installed = { source.format.commands(in: try ProviderFiles.json(file).objectValue ?? [:]) }
            for other in others {
                for enabled in [false, true] {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(ProviderJSON.object(try source.format.updating([:], command: ours(other)))).write(to: file)
                    try CompletionHooks.configure(source, enabled: enabled, executable: current, home: home)
                    XCTAssertEqual(try installed(), enabled ? [ours(current)] : [],
                                   "\(source): the handler \(other.path) wrote is \(enabled ? "taken over" : "removed")")
                }
            }
            let taken = try Data(contentsOf: file)
            XCTAssertThrowsError(try CompletionHooks.configure(source, enabled: true, executable: others[2], home: home))
            XCTAssertEqual(try Data(contentsOf: file), taken, "\(source): an app running from its disk image writes nothing")
        }
    }

    func testAntigravityKeepsTheEntryAsTheUserLeftItAndOnlyMovesTheCommand() throws {
        let home = try directory(), file = CompletionHooks.Source.antigravity.configuration(home: home)
        let first = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        try CompletionHooks.configure(.antigravity, enabled: true, executable: first, home: home)
        // Switched off in agy's own hooks file, with a longer wait, beside a second handler an older copy left.
        var object = try XCTUnwrap(ProviderFiles.json(file).objectValue)
        var entry = try XCTUnwrap(object["agent-hud"]?.objectValue)
        entry["enabled"] = .bool(false)
        entry["Stop"] = .array([.object(["type": .string("command"), "command": .string(HookCommand.make(executable: first,
            arguments: "--completion-hook antigravity")), "timeout": .integer(30)]),
            .object(["type": .string("command"), "command": .string("'/Volumes/Agent HUD/Agent HUD' --completion-hook antigravity")])])
        object["agent-hud"] = .object(entry)
        try JSONEncoder().encode(ProviderJSON.object(object)).write(to: file)

        let moved = URL(fileURLWithPath: "/Users/me/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        try CompletionHooks.configure(.antigravity, enabled: true, executable: moved, home: home)
        let kept = try ProviderFiles.json(file)["agent-hud"]
        XCTAssertEqual(kept["enabled"].boolValue, false, "a hook the user switched off stays off")
        XCTAssertFalse(CompletionHooks.isInstalled(.antigravity, home: home))
        XCTAssertEqual(kept["Stop"].arrayValue?.count, 1, "the entry keeps one handler, the running copy's")
        XCTAssertEqual(kept["Stop"].arrayValue?.first?["command"].stringValue,
                       HookCommand.make(executable: moved, arguments: "--completion-hook antigravity"))
        XCTAssertEqual(kept["Stop"].arrayValue?.first?["timeout"].numberValue, 30)
    }

    func testInstallationPreservesOtherHooksAndCanBeRemoved() throws {
        let home = try directory(), executable = home.appendingPathComponent("Agent's HUD.app/Contents/MacOS/Agent HUD")
        for source in CompletionHooks.Source.allCases {
            let url = source.configuration(home: home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = source == .cursor ? #"{"version":1,"hooks":{"stop":[{"command":"other-command"}],"sessionStart":[]}}"#
                : #"{"other-hook":{"Stop":[{"command":"other-command"}]}}"#
            try original.write(to: url, atomically: true, encoding: .utf8)
            for _ in 0..<2 { try CompletionHooks.configure(source, enabled: true, executable: executable, home: home) }
            XCTAssertTrue(CompletionHooks.isInstalled(source, home: home))
            let installed = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(installed.contains("other-command"))
            XCTAssertEqual(installed.components(separatedBy: "--completion-hook").count, 2)
            try CompletionHooks.configure(source, enabled: false, executable: executable, home: home)
            XCTAssertFalse(CompletionHooks.isInstalled(source, home: home))
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("other-command"))
        }
    }
}

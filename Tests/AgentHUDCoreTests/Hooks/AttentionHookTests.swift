#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// Claude Code telling Agent HUD it needs the user, and what the transcript makes of it.
final class AttentionHookTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func notify(_ payload: [String: Any], at date: Date, in directory: URL) throws {
        try AttentionHooks.record(source: .claude, data: JSONSerialization.data(withJSONObject: payload), now: date, directory: directory)
    }

    private func turn(_ state: SessionTurn.State, observedAt: Date, message: String? = nil) -> SessionTurn {
        SessionTurn(provider: "claude", sessionID: "s", turnID: "t", state: state,
                    startedAtMs: RecordCoding.milliseconds(observedAt.addingTimeInterval(-60)),
                    observedAtMs: RecordCoding.milliseconds(observedAt), message: message)
    }

    func testOneRequestPerSessionIsKeptWithWhatTheClientSaidItWants() throws {
        let inbox = try directory()
        try notify(["session_id": "s", "hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"],
                   at: now, in: inbox)
        try notify(["session_id": "s", "hook_event_name": "Notification", "message": "Claude needs your permission to use Edit"],
                   at: now.addingTimeInterval(30), in: inbox)
        try notify(["hook_event_name": "Notification", "message": "no session"], at: now, in: inbox)
        let requests = AttentionHooks.read(source: .claude, now: now.addingTimeInterval(60), directory: inbox)
        XCTAssertEqual(requests.count, 1, "only the latest request of a session matters")
        XCTAssertEqual(requests["s"]?.message, "Claude needs your permission to use Edit")
        XCTAssertEqual(requests["s"]?.at, now.addingTimeInterval(30))
        XCTAssertTrue(AttentionHooks.read(source: .claude, now: now.addingTimeInterval(AttentionHooks.retention + 60), directory: inbox).isEmpty,
                      "a request nobody answered is forgotten")
    }

    func testARunningTurnWaitsForApprovalUntilTheTranscriptMovesOn() throws {
        let inbox = try directory()
        try notify(["session_id": "s", "message": "Claude needs your permission to use Bash"], at: now, in: inbox)
        let requests = AttentionHooks.read(source: .claude, now: now.addingTimeInterval(10), directory: inbox)

        let waiting = ClaudeCodeProvider.awaiting([turn(.running, observedAt: now.addingTimeInterval(-5), message: "Running the tests")],
                                                 requests: requests)
        XCTAssertEqual(waiting.map(\.state), [.waitingForApproval])
        XCTAssertEqual(waiting.first?.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(waiting.first?.observedAtMs, RecordCoding.milliseconds(now))
        XCTAssertEqual(waiting.first?.startedAtMs, RecordCoding.milliseconds(now.addingTimeInterval(-65)), "the turn still began when it began")

        let answered = ClaudeCodeProvider.awaiting([turn(.running, observedAt: now.addingTimeInterval(5))], requests: requests)
        XCTAssertEqual(answered.map(\.state), [.running], "a transcript line after the request means it was answered")
        let finished = ClaudeCodeProvider.awaiting([turn(.completed, observedAt: now.addingTimeInterval(-5))], requests: requests)
        XCTAssertEqual(finished.map(\.state), [.completed], "an idle prompt is waiting for a reply, not for approval")

        // A sub-agent that keeps working after the request does not answer it.
        let working = ClaudeCodeProvider.turn(waiting[0], agentsWorkingAt: now.addingTimeInterval(20))
        XCTAssertEqual(working.state, .waitingForApproval)
        XCTAssertEqual(working.observedAtMs, RecordCoding.milliseconds(now.addingTimeInterval(20)))
        XCTAssertEqual(ClaudeCodeProvider.turn(finished[0], agentsWorkingAt: now.addingTimeInterval(20)).state, .running)
    }

    func testTheHookIsInstalledBesideWhateverElseTheSettingsHold() throws {
        let home = try directory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["model": "opus", "hooks": ["Notification": [["hooks": [["type": "command", "command": "say hi"]]]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)

        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        XCTAssertFalse(AttentionHooks.isActive(.claude, home: home))
        try AttentionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        XCTAssertTrue(AttentionHooks.isActive(.claude, home: home))
        let updated = try XCTUnwrap(try ProviderJSON.read(Data(contentsOf: settings)).objectValue)
        XCTAssertEqual(updated["model"]?.stringValue, "opus", "nothing else in the file is touched")
        let commands = (updated["hooks"]?["Notification"].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }
            .compactMap { $0["command"].stringValue }
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains("say hi"))
        XCTAssertTrue(commands.contains { $0.hasSuffix(" --attention-hook claude") })
        let ours = (updated["hooks"]?["Notification"].arrayValue ?? []).first { group in
            (group["hooks"].arrayValue ?? []).contains { $0["command"].stringValue?.hasSuffix(" --attention-hook claude") == true }
        }
        XCTAssertEqual(ours?["matcher"].stringValue, "permission_prompt|agent_needs_input",
                       "the client filters by notification type, so a sign-in notice never reads as a request")

        try AttentionHooks.configure(.claude, enabled: false, executable: executable, home: home)
        XCTAssertFalse(AttentionHooks.isActive(.claude, home: home))
        let removed = try XCTUnwrap(try ProviderJSON.read(Data(contentsOf: settings)).objectValue)
        XCTAssertEqual((removed["hooks"]?["Notification"].arrayValue ?? []).count, 1, "the other handler stays")
    }

    func testTheRunningAppTakesOverEveryHandlerAndSwitchingOffTakesThemAllOut() throws {
        let home = try directory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        func handlers(_ executables: String...) throws {
            try JSONSerialization.data(withJSONObject: ["hooks": ["Notification": [["hooks": executables.map { executable in
                ["type": "command", "command": "'\(executable)' --attention-hook claude"] }]]]]).write(to: settings)
        }
        let installed = { AttentionHooks.commands(in: try AttentionHooks.configuration(.claude, home: home), source: .claude) }
        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        // Another build still installed, the disk image the app was first opened from, and an app since deleted.
        let others = ["/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open",
                      "/Volumes/Agent HUD/Agent HUD.app/Contents/MacOS/Agent HUD", "/tmp/Gone.app/Contents/MacOS/Gone"]
        try handlers(others[0], others[1], executable.path, others[2])
        try AttentionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        XCTAssertEqual(try installed(), ["'\(executable.path)' --attention-hook claude"], "whichever copy wrote them, the one that runs takes them over")
        try handlers(others[0], executable.path, others[2])
        try AttentionHooks.configure(.claude, enabled: false, executable: executable, home: home)
        XCTAssertEqual(try installed(), [], "switching hooks off takes out every handler of Agent HUD's")

        try handlers(others[0])
        XCTAssertThrowsError(try AttentionHooks.configure(.claude, enabled: true,
            executable: URL(fileURLWithPath: "/Volumes/Agent HUD/Agent HUD.app/Contents/MacOS/Agent HUD"), home: home))
        XCTAssertEqual(try installed(), ["'\(others[0])' --attention-hook claude"], "an app running from its disk image writes nothing")
    }

    func testAHomeWithoutTheClientIsLeftAlone() throws {
        let home = try directory()
        XCTAssertFalse(AttentionHooks.Source.claude.isInstalled(home: home), "no engine and no transcripts means no client")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        XCTAssertTrue(AttentionHooks.Source.claude.isInstalled(home: home))
    }

    func testAnUnreadableSettingsLayoutIsNeverRewritten() throws {
        let home = try directory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks": "everything off"}"#.utf8).write(to: settings)
        XCTAssertThrowsError(try AttentionHooks.configure(.claude, enabled: true,
            executable: URL(fileURLWithPath: "/tmp/hud"), home: home))
        XCTAssertEqual(try Data(contentsOf: settings), Data(#"{"hooks": "everything off"}"#.utf8))
    }
}
#endif

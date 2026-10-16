import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// Claude Code telling Agent HUD it begins compacting a session, and how its PreCompact hook is installed.
final class CompactionHookTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func compact(_ payload: [String: Any], at date: Date, in directory: URL) throws {
        try CompactionHooks.record(source: .claude, data: JSONSerialization.data(withJSONObject: payload), now: date, directory: directory)
    }

    func testOneCompactionPerSessionIsKeptWithWhatStartedIt() throws {
        let inbox = try directory()
        try compact(["session_id": "s", "hook_event_name": "PreCompact", "trigger": "manual", "custom_instructions": ""], at: now, in: inbox)
        try compact(["session_id": "s", "hook_event_name": "PreCompact", "trigger": "auto"], at: now.addingTimeInterval(30), in: inbox)
        let read = CompactionHooks.read(source: .claude, now: now.addingTimeInterval(40), directory: inbox)
        XCTAssertEqual(read, ["s": .init(sessionID: "s", at: now.addingTimeInterval(30), trigger: "auto")], "only the latest one matters")
        XCTAssertTrue(read["s"]?.isAutomatic == true)
        let files = try FileManager.default.contentsOfDirectory(at: inbox.appendingPathComponent("claude"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(String(decoding: try Data(contentsOf: files[0]), as: UTF8.self).range(of: "custom_instructions"),
                     "what the user asked compaction to keep never leaves the payload")
    }

    func testARecordTooOldToCountIsForgottenAtTheNextCompaction() throws {
        // Only the last five minutes count, and every collection pass reads every record kept.
        let inbox = try directory()
        for hour in stride(from: 23, through: 1, by: -1) {
            try compact(["session_id": "s\(hour)", "hook_event_name": "PreCompact", "trigger": "auto"],
                        at: now.addingTimeInterval(-Double(hour) * 3600), in: inbox)
        }
        try compact(["session_id": "recent", "hook_event_name": "PreCompact", "trigger": "auto"], at: now.addingTimeInterval(-60), in: inbox)
        try compact(["session_id": "fresh", "hook_event_name": "PreCompact", "trigger": "auto"], at: now, in: inbox)
        XCTAssertEqual(try HookInbox(directory: inbox, source: "claude").files().count, 2)
        XCTAssertEqual(CompactionHooks.read(source: .claude, now: now, directory: inbox).keys.sorted(), ["fresh", "recent"])
    }

    func testASubAgentsCompactionIsNotItsSessions() throws {
        // Claude Code runs the hook inside a sub-agent with the session's own id and the sub-agent's beside it. The
        // sub-agent's log takes the boundary and every line after it, so the session's log could never end it.
        let inbox = try directory()
        try compact(["session_id": "s", "agent_id": "a1", "hook_event_name": "PreCompact", "trigger": "auto"], at: now, in: inbox)
        XCTAssertEqual(CompactionHooks.read(source: .claude, now: now.addingTimeInterval(10), directory: inbox), [:])
        try compact(["session_id": "s", "hook_event_name": "PreCompact", "trigger": "auto"], at: now, in: inbox)
        XCTAssertEqual(CompactionHooks.read(source: .claude, now: now.addingTimeInterval(10), directory: inbox).keys.sorted(), ["s"])
    }

    func testTheHookIsInstalledForAutomaticCompactionBesideWhateverElseTheSettingsHold() throws {
        let home = try directory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["model": "opus", "hooks": ["PreCompact": [["matcher": "manual", "hooks": [["type": "command", "command": "~/bin/save"]]]]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)

        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        XCTAssertFalse(CompactionHooks.isActive(.claude, home: home))
        try CompactionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        XCTAssertTrue(CompactionHooks.isActive(.claude, home: home))
        let updated = try XCTUnwrap(try ProviderJSON.read(Data(contentsOf: settings)).objectValue)
        XCTAssertEqual(updated["model"]?.stringValue, "opus", "nothing else in the file is touched")
        let groups = updated["hooks"]?["PreCompact"].arrayValue ?? []
        XCTAssertEqual(groups.count, 2)
        let ours = groups.first { group in
            (group["hooks"].arrayValue ?? []).contains { $0["command"].stringValue == "'\(executable.path)' --session-origin-hook claude" }
        }
        XCTAssertEqual(ours?["matcher"].stringValue, "auto", "a /compact the user types runs while the session waits, and is not shown")
        XCTAssertEqual(ours?["hooks"].arrayValue?.first?["async"], .bool(true), "a report: the client compacts without waiting for the app")
        XCTAssertEqual(ours?["hooks"].arrayValue?.first?["timeout"], .integer(5))

        let other = URL(fileURLWithPath: "/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open")
        try CompactionHooks.configure(.claude, enabled: true, executable: other, home: home)
        XCTAssertEqual(CompactionHooks.commands(in: try CompactionHooks.configuration(.claude, home: home), source: .claude),
                       ["'\(other.path)' --session-origin-hook claude"], "the copy that runs takes the handler over")

        try CompactionHooks.configure(.claude, enabled: false, executable: other, home: home)
        XCTAssertFalse(CompactionHooks.isActive(.claude, home: home))
        let removed = try XCTUnwrap(try ProviderJSON.read(Data(contentsOf: settings)).objectValue)
        XCTAssertEqual(removed["hooks"]?["PreCompact"].arrayValue?.count, 1, "the user's own handler stays")
        XCTAssertEqual(removed["hooks"]?["PreCompact"].arrayValue?.first?["matcher"].stringValue, "manual")
    }

    func testSwitchingClientHooksOnAndOffInstallsAndRemovesIt() throws {
        let home = try directory()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        SessionObservers.configure(executable: executable, enabled: true, home: home)
        XCTAssertTrue(CompactionHooks.isActive(.claude, home: home))
        SessionObservers.configure(executable: executable, enabled: false, home: home)
        XCTAssertFalse(CompactionHooks.isActive(.claude, home: home))

        let bare = try directory()
        SessionObservers.configure(executable: executable, enabled: true, home: bare)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent(".claude/settings.json").path),
                       "a home without Claude Code is left alone")
    }

    func testTheHookRunsTheOriginCommandWhichEveryBuildWithItHandlesQuietly() throws {
        // A hook names one executable path, and an older copy may sit at it. A flag that copy did not know would start it
        // whole; the origin hook's command it knows, and it records nothing for an event that is not one of its own.
        XCTAssertEqual(CompactionHooks.arguments(.claude), ClaudeSessionOrigins.arguments)
        XCTAssertFalse(ClaudeSessionOrigins.events.contains(CompactionHooks.Source.claude.event))

        let origins = try directory(), compactions = try directory()
        let compaction = try JSONSerialization.data(withJSONObject: ["session_id": "s", "hook_event_name": "PreCompact", "trigger": "auto"])
        try ClaudeSessionOrigins.record(data: compaction, target: nil, now: now, directory: origins)
        XCTAssertEqual(ClaudeSessionOrigins.read(directory: origins), [:], "a compaction is no origin")
        try CompactionHooks.record(source: .claude, data: compaction, now: now, directory: compactions)
        XCTAssertEqual(CompactionHooks.read(source: .claude, now: now, directory: compactions).keys.sorted(), ["s"])

        let start = try JSONSerialization.data(withJSONObject: ["session_id": "t", "hook_event_name": "SessionStart", "source": "startup"])
        try CompactionHooks.record(source: .claude, data: start, now: now, directory: compactions)
        XCTAssertEqual(CompactionHooks.read(source: .claude, now: now, directory: compactions).keys.sorted(), ["s"],
                       "a session starting is no compaction")
        XCTAssertEqual(HookEntry.handle(arguments: ["/hud", "--compaction-hook", "claude"]), 0,
                       "no flag of its own: it ends quietly, as any hook's flag this build does not know")
    }
}

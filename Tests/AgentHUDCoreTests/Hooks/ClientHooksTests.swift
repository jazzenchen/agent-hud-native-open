#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// The copy of the app that runs keeps Agent HUD's handlers in the clients' files pointed at itself; switching client
/// hooks off takes them all out and adds nothing back.
final class ClientHooksTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func commands(_ url: URL) throws -> [String] {
        let hooks = try ProviderJSON.read(Data(contentsOf: url))["hooks"]
        return (hooks.objectValue ?? [:]).values.flatMap { $0.arrayValue ?? [] }
            .flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }.sorted()
    }

    func testTheSwitchIsOnUntilTurnedOff() throws {
        XCTAssertTrue(Settings().clientHooks)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data(#"{"glowRange":12}"#.utf8)).clientHooks)
        let off = Settings().with { $0.clientHooks = false }
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off)).clientHooks)
    }

    func testTurningHooksOffRemovesOurHandlersAndLeavesTheRest() throws {
        let home = try directory()
        for folder in [".claude/projects", ".qwen/projects"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // The user's own hook, and a notification hook another build of the app added while it ran.
        let claude = home.appendingPathComponent(".claude/settings.json")
        try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/bin/lint"]]]],
            "SessionStart": [["matcher": "startup|resume", "hooks": [["type": "command", "command": "~/bin/session-log"]]]],
            "UserPromptSubmit": [["hooks": [["type": "command", "command": "~/bin/prompt-log"]]]],
            "Notification": [["matcher": "permission_prompt", "hooks": [["type": "command",
                "command": "'/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open' --attention-hook claude"]]]]]]).write(to: claude)

        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        SessionObservers.configure(executable: executable, enabled: true, home: home)
        let qwen = home.appendingPathComponent(".qwen/settings.json")
        XCTAssertEqual(try commands(claude), ["'\(executable.path)' --attention-hook claude", "'\(executable.path)' --permission-hook claude",
                                              "'\(executable.path)' --session-origin-hook claude", "'\(executable.path)' --session-origin-hook claude",
                                              "~/bin/lint", "~/bin/prompt-log", "~/bin/session-log"],
                       "approval, notification and both origin callbacks beside the user's hooks, all the running copy's")
        let installed = try ProviderJSON.read(Data(contentsOf: claude))
        for event in ClaudeSessionOrigins.events {
            XCTAssertEqual((installed["hooks"][event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }
                .compactMap { $0["command"].stringValue }.filter { $0.hasSuffix(" --session-origin-hook claude") },
                           ["'\(executable.path)' --session-origin-hook claude"], "one origin callback under each event")
        }
        XCTAssertEqual(try ProviderJSON.read(Data(contentsOf: claude))["hooks"]["Notification"].arrayValue?.first?["matcher"].stringValue,
                       "permission_prompt", "the handler taken over keeps its matcher")
        XCTAssertEqual(try commands(qwen).count, 2, "approval and stop hooks")

        SessionObservers.configure(executable: executable, enabled: false, home: home)
        XCTAssertEqual(try commands(claude), ["~/bin/lint", "~/bin/prompt-log", "~/bin/session-log"])
        let removed = try ProviderJSON.read(Data(contentsOf: claude))
        XCTAssertEqual(removed["model"].stringValue, "opus")
        XCTAssertEqual(removed["hooks"]["SessionStart"].arrayValue?.first?["matcher"].stringValue, "startup|resume")
        XCTAssertEqual(try commands(qwen), [])
    }

    func testASettingsFileKeptAsALinkIsWrittenWhereItLeadsAndKeepsItsPermissions() throws {
        let home = try directory(), dotfiles = try directory()
        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        let claude = dotfiles.appendingPathComponent("claude.json"), cursor = dotfiles.appendingPathComponent("cursor/hooks.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: claude)
        try Data(#"{"version":1}"#.utf8).write(to: cursor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claude.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: cursor.path)
        // One link names its file from the directory it sits in, the other by its whole path.
        let claudeLink = home.appendingPathComponent(".claude/settings.json"), cursorLink = home.appendingPathComponent(".cursor/hooks.json")
        for link in [claudeLink, cursorLink] {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: claudeLink.path, withDestinationPath: "../../\(dotfiles.lastPathComponent)/claude.json")
        try FileManager.default.createSymbolicLink(atPath: cursorLink.path, withDestinationPath: cursor.path)

        try PermissionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        try AttentionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        try CompletionHooks.configure(.cursor, enabled: true, executable: executable, home: home)
        for (link, file, permissions) in [(claudeLink, claude, 0o600), (cursorLink, cursor, 0o640)] {
            XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "\(link.lastPathComponent) stays a link")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, permissions)
        }
        XCTAssertEqual(try commands(claude).count, 2)
        XCTAssertEqual(try ProviderJSON.read(Data(contentsOf: claude))["model"].stringValue, "opus")
        XCTAssertTrue(CompletionHooks.isInstalled(.cursor, home: home))
    }

    func testRemovingNeverCreatesAFileTheClientDidNotHave() throws {
        let home = try directory(), executable = URL(fileURLWithPath: "/tmp/hud")
        for source in CompletionHooks.Source.allCases {
            try CompletionHooks.configure(source, enabled: false, executable: executable, home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.configuration(home: home).path), source.rawValue)
        }
        for source in PermissionHooks.Source.allCases {
            try PermissionHooks.configure(source, enabled: false, executable: executable, home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.configuration(home: home).path), source.rawValue)
        }
    }
}
#endif

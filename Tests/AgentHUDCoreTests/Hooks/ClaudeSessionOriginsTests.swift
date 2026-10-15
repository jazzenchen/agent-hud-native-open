#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import Foundation
import XCTest
@testable import AgentHUDCore

final class ClaudeSessionOriginsTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let native = "/Users/test/.local/share/claude/versions/2.1.292"
    private let terminal = ["CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w2t3p4:exact-pane"]

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func payload(_ event: String = "UserPromptSubmit", source: String = "resume") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["session_id": "native-session", "hook_event_name": event, "source": source,
                                                   "prompt": "Do not retain this content", "cwd": "/private/workspace"])
    }

    func testNativeVersionedEngineAndExactNpmScriptUseTheirOwnPane() {
        let shell = HookProcessOrigins.Ancestor(executable: "/bin/sh", arguments: ["sh", "-c", "hook"])
        let engine = HookProcessOrigins.Ancestor(executable: native, arguments: ["claude", "--resume", "native-session"])
        XCTAssertEqual(ClaudeSessionOrigins.navigationTarget(ancestors: [shell, engine], environment: terminal,
                                                             executablePaths: [native]), .iTermSession(id: "w2t3p4:exact-pane"))
        let npm = "/Users/test/npm/node_modules/@anthropic-ai/claude-code/cli.js"
        let node = HookProcessOrigins.Ancestor(executable: "/opt/homebrew/bin/node", arguments: ["node", npm, "--continue"])
        XCTAssertEqual(ClaudeSessionOrigins.navigationTarget(ancestors: [shell, node], environment: terminal,
                                                             executablePaths: [npm]), .iTermSession(id: "w2t3p4:exact-pane"))
        let unrelated = HookProcessOrigins.Ancestor(executable: "/opt/homebrew/bin/node", arguments: ["node", "/tmp/sdk.js"])
        XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [shell, unrelated, engine], environment: terminal,
                                                           executablePaths: [native]), "never borrow an outer engine's inherited pane")
        XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [engine], environment: terminal,
                                                           executablePaths: ["/other/claude"]), "the kernel path must be an installed engine")
    }

    func testNonterminalEntrypointsAndHeadlessModesIgnoreInheritedTerminalVariables() {
        let engine = HookProcessOrigins.Ancestor(executable: native, arguments: ["claude"])
        for entrypoint in ["sdk-cli", "sdk-ts", "sdk-py", "claude-vscode", "claude-desktop", "claude-desktop-3p", "local-agent", "remote", ""] {
            var environment = terminal
            environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint
            XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [engine], environment: environment,
                                                               executablePaths: [native]), entrypoint)
        }
        var missing = terminal
        missing["CLAUDE_CODE_ENTRYPOINT"] = nil
        XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [engine], environment: missing, executablePaths: [native]))
        for mode in ["-p", "--print", "--background", "--bg", "--init-only", "--input-format=stream-json", "--output-format=json"] {
            let process = HookProcessOrigins.Ancestor(executable: native, arguments: ["claude", mode])
            XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [process], environment: terminal,
                                                               executablePaths: [native]), mode)
        }
        XCTAssertTrue(ClaudeSessionOrigins.interactive(["claude", "--append-system-prompt", "--print", "--model=claude-sonnet-4-6", "--", "-p"]),
                      "a literal option value and a prompt after -- cannot name a mode")
        XCTAssertTrue(ClaudeSessionOrigins.interactive(["claude", "--ide"]), "connecting a terminal CLI to an IDE leaves its TUI in the pane")
    }

    func testTerminalEvidenceRequiresDirectITermWithoutTmux() {
        let engine = HookProcessOrigins.Ancestor(executable: native, arguments: ["claude"])
        for replacement in [["TERM_PROGRAM": "vscode"], ["TERM_PROGRAM": "Apple_Terminal"],
                            ["ITERM_SESSION_ID": ""], ["TMUX": "/tmp/tmux,1,0"]] {
            let environment = terminal.merging(replacement, uniquingKeysWith: { _, value in value })
            XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [engine], environment: environment,
                                                               executablePaths: [native]))
        }
    }

    func testLatestRecordResumesInAnotherPaneAndExplicitlyClearsWithoutProducingCompletions() throws {
        let inbox = try directory()
        try ClaudeSessionOrigins.record(data: payload("SessionStart", source: "startup"), target: .iTermSession(id: "pane-A"), now: now, directory: inbox)
        try ClaudeSessionOrigins.record(data: payload("SessionStart", source: "resume"), target: .iTermSession(id: "pane-B"),
                                        now: now.addingTimeInterval(1), directory: inbox)
        XCTAssertEqual(ClaudeSessionOrigins.read(directory: inbox)["native-session"]?.target, .iTermSession(id: "pane-B"))
        try ClaudeSessionOrigins.record(data: payload(), target: nil, now: now.addingTimeInterval(2), directory: inbox)
        XCTAssertNil(try XCTUnwrap(ClaudeSessionOrigins.read(directory: inbox)["native-session"]).target)
        try ClaudeSessionOrigins.record(data: payload(), target: .iTermSession(id: "pane-A"), now: now, directory: inbox)
        XCTAssertEqual(ClaudeSessionOrigins.read(directory: inbox)["native-session"]?.at, now.addingTimeInterval(2))
        try ClaudeSessionOrigins.record(data: payload("Stop"), target: .iTermSession(id: "pane-A"), now: now.addingTimeInterval(3), directory: inbox)
        XCTAssertEqual(ClaudeSessionOrigins.read(directory: inbox)["native-session"]?.at, now.addingTimeInterval(2))
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["sessionID", "at", "host"], "records contain no prompt, cwd, environment or argv")
    }

    func testDesktopHostUsesVerifiedEngineAndDesktopAncestryWithoutBorrowingTerminal() {
        let engine = HookProcessOrigins.Ancestor(executable: "/Users/test/Library/Application Support/Claude/claude-code/2.1.284/claude.app/Contents/MacOS/claude",
                                                 arguments: ["claude", "--print", "--input-format", "stream-json"], bundleIdentifier: "com.anthropic.claude-code")
        let desktop = HookProcessOrigins.Ancestor(executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"],
                                                  bundleIdentifier: "com.anthropic.claudefordesktop")
        for entrypoint in ["claude-desktop", "claude-desktop-3p", "local-agent"] {
            var environment = terminal
            environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint
            XCTAssertEqual(ClaudeSessionOrigins.host(ancestors: [engine, desktop], environment: environment, executablePaths: []),
                           entrypoint == "local-agent" ? .cowork : .desktop)
            XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [engine, desktop], environment: environment, executablePaths: []))
            XCTAssertEqual(ClaudeSessionOrigins.host(ancestors: [engine], environment: environment, executablePaths: []), .unsupported,
                           "a Desktop marker without the installed application's ancestry cannot change the origin")
        }
        var headless = terminal
        headless["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cli"
        XCTAssertEqual(ClaudeSessionOrigins.host(ancestors: [engine], environment: headless, executablePaths: []), .cli)
        XCTAssertNil(ClaudeSessionOrigins.navigationTarget(ancestors: [engine], environment: headless, executablePaths: []))
        headless["CLAUDE_CODE_ENTRYPOINT"] = "claude-vscode"
        XCTAssertEqual(ClaudeSessionOrigins.host(ancestors: [engine, desktop], environment: headless, executablePaths: []), .unsupported)
    }

    func testPriorRecordsKeepTheirTerminalOrExplicitClearWhenDesktopMappingBecomesAvailable() throws {
        for target in [nil, SessionNavigationTarget.iTermSession(id: "pane-A")] {
            let current = ClaudeSessionOrigins.Event(sessionID: "native-session", at: now, target: target)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
            json["host"] = nil
            let prior = try JSONDecoder().decode(ClaudeSessionOrigins.Event.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(prior.host, target == nil ? .unsupported : .cli)
            XCTAssertEqual(prior.target, target)
        }
    }

    func testConfigurationPreservesForeignMixedHooksAndDisabledHookSetting() throws {
        let home = try directory(), configured = try directory(), inbox = try directory().appendingPathComponent("origins")
        let settings = configured.appendingPathComponent("settings.json")
        let user: [String: Any] = ["type": "command", "command": "~/bin/log-session", "timeout": 17]
        let old = "'/Applications/Old.app/Contents/MacOS/Old' --session-origin-hook claude"
        try JSONSerialization.data(withJSONObject: ["disableAllHooks": true, "other": ["kept": true], "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "~/bin/stop"]]]],
            "SessionStart": [["matcher": "resume", "extra": "kept", "hooks": [user, ["type": "command", "command": old, "timeout": 23]]],
                             ["hooks": [["type": "command", "command": old]]]],
            "UserPromptSubmit": [["hooks": [user]]]]]).write(to: settings)
        let executable = URL(fileURLWithPath: "/Applications/HUD.app/Contents/MacOS/HUD"), environment = ["CLAUDE_CONFIG_DIR": configured.path]
        try ClaudeSessionOrigins.configure(enabled: true, executable: executable, home: home, environment: environment, directory: inbox)
        var updated = try ProviderJSON.read(Data(contentsOf: settings))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertEqual(updated["disableAllHooks"].boolValue, true)
        XCTAssertEqual(updated["other"]["kept"].boolValue, true)
        XCTAssertEqual(updated["hooks"]["Stop"].arrayValue?.first?["hooks"].arrayValue?.first?["command"].stringValue, "~/bin/stop")
        let start = try XCTUnwrap(updated["hooks"]["SessionStart"].arrayValue)
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start[0]["matcher"].stringValue, "resume")
        XCTAssertEqual(start[0]["extra"].stringValue, "kept")
        XCTAssertEqual(start[0]["hooks"].arrayValue?.last?["timeout"].countValue, 23)
        for event in ClaudeSessionOrigins.events {
            let commands = (updated["hooks"][event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }
            XCTAssertEqual(commands.filter { $0.hasSuffix(" --session-origin-hook claude") }, ["'\(executable.path)' --session-origin-hook claude"])
            XCTAssertTrue(commands.contains("~/bin/log-session"))
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: settings.path)
        try ClaudeSessionOrigins.configure(enabled: true, executable: executable, home: home, environment: environment, directory: inbox)
        XCTAssertEqual(try settings.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, timestamp)
        try ClaudeSessionOrigins.configure(enabled: false, executable: executable, home: home, environment: environment, directory: inbox)
        updated = try ProviderJSON.read(Data(contentsOf: settings))
        for event in ClaudeSessionOrigins.events {
            XCTAssertEqual((updated["hooks"][event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }, ["~/bin/log-session"])
        }
        XCTAssertEqual(updated["disableAllHooks"].boolValue, true)
    }

    func testInvalidSettingsAreNotRewrittenAndRemovingAbsentHooksCreatesNothing() throws {
        let home = try directory(), inbox = home.appendingPathComponent("origins"), executable = URL(fileURLWithPath: "/tmp/hud")
        try ClaudeSessionOrigins.configure(enabled: false, executable: executable, home: home, environment: [:], directory: inbox)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"hooks":{"SessionStart":[],"UserPromptSubmit":"invalid"}}"#.utf8)
        try original.write(to: settings)
        XCTAssertThrowsError(try ClaudeSessionOrigins.configure(enabled: true, executable: executable, home: home, environment: [:], directory: inbox))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
    }
}
#endif

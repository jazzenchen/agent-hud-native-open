#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import Foundation
import XCTest
@testable import AgentHUDCore

final class CodexSessionOriginsTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let nativeID = "d4cfa512-589c-4f4f-a2c0-855b93ae405f"
    private let terminal: [String: String] = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w2t3p4:exact-session"]

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func payload(_ event: String = "UserPromptSubmit") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["session_id": nativeID, "hook_event_name": event,
                                                    "prompt": "Content that must not be persisted", "cwd": "/private/workspace"])
    }

    private func codex(_ arguments: String...) -> CodexSessionOrigins.Ancestor {
        .init(executable: "/Users/test/.bun/install/global/node_modules/@openai/codex/vendor/bin/codex", arguments: ["codex"] + arguments)
    }

    func testNearestNativeHostDistinguishesCLIAndDesktopFromTheirServers() {
        let shell = CodexSessionOrigins.Ancestor(executable: "/bin/sh", arguments: ["sh", "-c", "hook"])
        let desktop = CodexSessionOrigins.Ancestor(executable: "/Applications/Renamed.app/Contents/MacOS/Codex",
                                                   arguments: ["Codex"], bundleIdentifier: "com.openai.codex")
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [shell, codex()]), .cli)
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [shell, codex("--no-daemon", "-m", "gpt-5.6-sol")]), .cli)
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [shell, codex("-c", "source=app-server", "exec", "hello")]), .cli)
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [codex("--model=test", "resume", nativeID)]), .cli)
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [shell, codex("app-server"), desktop]), .desktop)
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [codex("app-server"), codex()]), .daemon,
                       "a server callback cannot inherit its outer CLI's terminal")
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [codex("app-server", "--managed-daemon"), desktop]), .daemon,
                       "the managed shared daemon has no per-session terminal even when Desktop is an ancestor")
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [codex("desktop-daemon"), codex()]), .daemon)
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [shell, .init(executable: "/usr/bin/node", arguments: ["node"]), codex()]), .unknown,
                       "do not search past an unverified host for a convenient CLI")
        XCTAssertEqual(CodexSessionOrigins.host(ancestors: [codex("mcp-server")]), .unknown)
        XCTAssertEqual(CodexSessionOrigins.invocation(["codex", "--config"]), .unknown)
    }

    func testLatestSourceClearsTerminalAndDesktopRestoresItsThread() throws {
        let inbox = try directory()
        try CodexSessionOrigins.record(data: payload("SessionStart"), host: .cli, environment: terminal, now: now, directory: inbox)
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.target, .iTermSession(id: "w2t3p4:exact-session"))

        try CodexSessionOrigins.record(data: payload(), host: .cli, environment: [:], now: now.addingTimeInterval(1), directory: inbox)
        let cleared = try XCTUnwrap(CodexSessionOrigins.read(directory: inbox)[nativeID])
        XCTAssertNil(cleared.target, "the record remains present so a provider can clear an old target")
        XCTAssertEqual(cleared.host, .cli)
        XCTAssertEqual(cleared.at, now.addingTimeInterval(1))

        try CodexSessionOrigins.record(data: payload(), host: .desktop, environment: terminal, now: now.addingTimeInterval(2), directory: inbox)
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.target, .codexThread(id: nativeID),
                       "Desktop ignores inherited terminal variables")
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.host, .desktop)
        try CodexSessionOrigins.record(data: payload(), host: .daemon, environment: terminal, now: now.addingTimeInterval(3), directory: inbox)
        XCTAssertNil(try XCTUnwrap(CodexSessionOrigins.read(directory: inbox)[nativeID]).target,
                     "shared daemon callbacks clear old origins without taking their process environment")
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.host, .daemon)
        try CodexSessionOrigins.record(data: payload(), host: .cli, environment: terminal, now: now, directory: inbox)
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.at, now.addingTimeInterval(3), "an older callback cannot win")
        try CodexSessionOrigins.record(data: payload(), host: .unknown, environment: terminal, now: now.addingTimeInterval(4), directory: inbox)
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.at, now.addingTimeInterval(3))

        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "origins are replaced per session; no completion is produced")
        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(Set(stored.keys), ["sessionID", "at", "host"], "the local record contains neither prompt, cwd nor process argv")
        XCTAssertEqual(stored["host"] as? String, "daemon")
    }

    func testTerminalCaptureRequiresDirectITermWithoutTmuxAndAnOriginEvent() throws {
        let inbox = try directory()
        for environment in [["TERM_PROGRAM": "Apple_Terminal", "ITERM_SESSION_ID": "inherited"],
                            terminal.merging(["TMUX": "/tmp/tmux,1,0"], uniquingKeysWith: { _, new in new }),
                            ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": ""]] {
            try CodexSessionOrigins.record(data: payload(), host: .cli, environment: environment, now: now, directory: inbox)
            XCTAssertNil(try XCTUnwrap(CodexSessionOrigins.read(directory: inbox)[nativeID]).target)
        }
        try CodexSessionOrigins.record(data: payload("Stop"), host: .cli, environment: terminal, now: now.addingTimeInterval(1), directory: inbox)
        XCTAssertEqual(CodexSessionOrigins.read(directory: inbox)[nativeID]?.at, now, "Stop is not a second completion or origin owner")
        let unknown = try directory().appendingPathComponent("not-created")
        try CodexSessionOrigins.record(data: payload(), host: .unknown, environment: terminal, now: now, directory: unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testConfigurationPreservesUserHooksAndDeduplicatesOnlyOwnedHandlers() throws {
        let home = try directory(), inbox = try directory().appendingPathComponent("watch-before-callback")
        let settings = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "'/Applications/Old.app/Contents/MacOS/Old' --session-origin-hook codex"
        let user: [String: Any] = ["type": "command", "command": "~/bin/session-log", "timeout": 17]
        try JSONSerialization.data(withJSONObject: ["features": ["hooks": false], "unknown": true, "hooks": [
            "PermissionRequest": [["hooks": [["type": "command", "command": "~/bin/permission"]]]],
            "SessionStart": [["matcher": "resume", "unknown": "kept", "hooks": [user, ["type": "command", "command": old, "timeout": 23]]],
                             ["hooks": [["type": "command", "command": old]]]],
            "UserPromptSubmit": [["hooks": [user]]]]]).write(to: settings)
        let executable = URL(fileURLWithPath: "/Applications/HUD.app/Contents/MacOS/HUD")
        try CodexSessionOrigins.configure(enabled: true, executable: executable, home: home, environment: [:], directory: inbox)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path))
        var updated = try ProviderJSON.read(Data(contentsOf: settings))
        XCTAssertEqual(updated["features"]["hooks"].boolValue, false)
        XCTAssertEqual(updated["unknown"].boolValue, true)
        XCTAssertEqual(updated["hooks"]["PermissionRequest"].arrayValue?.first?["hooks"].arrayValue?.first?["command"].stringValue, "~/bin/permission")
        let start = try XCTUnwrap(updated["hooks"]["SessionStart"].arrayValue)
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start[0]["matcher"].stringValue, "resume")
        XCTAssertEqual(start[0]["unknown"].stringValue, "kept")
        XCTAssertEqual(start[0]["hooks"].arrayValue?.last?["timeout"].countValue, 23)
        for event in CodexSessionOrigins.events {
            let commands = (updated["hooks"][event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }
            XCTAssertEqual(commands.filter { $0.hasSuffix(" --session-origin-hook codex") }, ["'\(executable.path)' --session-origin-hook codex"])
            XCTAssertTrue(commands.contains("~/bin/session-log"))
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: settings.path)
        try CodexSessionOrigins.configure(enabled: true, executable: executable, home: home, environment: [:], directory: inbox)
        XCTAssertEqual(try settings.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, timestamp)
        try CodexSessionOrigins.configure(enabled: false, executable: executable, home: home, environment: [:], directory: inbox)
        updated = try ProviderJSON.read(Data(contentsOf: settings))
        for event in CodexSessionOrigins.events {
            XCTAssertEqual((updated["hooks"][event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }, ["~/bin/session-log"])
        }
    }

    func testInvalidLayoutAndRemovingAbsentHooksDoNotCreateOrRewriteFiles() throws {
        let home = try directory(), inbox = home.appendingPathComponent("origins"), executable = URL(fileURLWithPath: "/tmp/hud")
        try CodexSessionOrigins.configure(enabled: false, executable: executable, home: home, environment: [:], directory: inbox)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
        let settings = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"hooks":{"SessionStart":[] ,"UserPromptSubmit":"invalid"}}"#.utf8)
        try original.write(to: settings)
        XCTAssertThrowsError(try CodexSessionOrigins.configure(enabled: true, executable: executable, home: home, environment: [:], directory: inbox))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
    }

    func testKernelArgumentParsingStopsBeforeEnvironment() {
        var count: Int32 = 3
        var buffer = withUnsafeBytes(of: &count) { Data($0) }
        buffer.append(Data("/native/codex\0\0codex\0app-server\0--managed-daemon\0AUTH=never-decode\0".utf8))
        XCTAssertEqual(CodexSessionOrigins.processArguments(buffer), ["codex", "app-server", "--managed-daemon"])
        XCTAssertNil(CodexSessionOrigins.processArguments(Data([0, 0, 0, 0])))
    }
}
#endif

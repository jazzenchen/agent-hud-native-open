#if !os(Windows)
// Providers/Grok/GrokSessionOriginsTests.swift tests macOS-side sockets and home layouts.
import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokSessionOriginsTests: XCTestCase {
    private let process = CodexTerminalOrigins.ProcessIdentity(pid: 42, uid: 501, startSeconds: 100,
        startMicroseconds: 50, executable: "/home/.grok/downloads/grok-1.0.46-macos-aarch64")
    private let environment = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:exact-pane"]

    func testExactActiveSessionUsesItsOwnNativeProcessAndPane() throws {
        let registry = try records([("conversation", 42)])
        let targets = GrokSessionOrigins.targets(in: registry, sessionIDs: ["grok:conversation", "grok:other"], uid: 501,
            process: { $0 == 42 ? self.process : nil }, arguments: { _ in self.kernelArguments() })
        XCTAssertEqual(targets, ["grok:conversation": .iTermSession(id: "w0t0p0:exact-pane")])
    }

    func testMultiSessionPagerAndAmbiguousSessionDoNotClaimCurrentConversation() throws {
        for rows in [[("conversation", Int32(42)), ("other", 42)], [("conversation", 42), ("conversation", 43)]] {
            XCTAssertTrue(GrokSessionOrigins.targets(in: try records(rows), sessionIDs: ["grok:conversation"], uid: 501,
                process: { _ in self.process }, arguments: { _ in self.kernelArguments() }).isEmpty)
        }
    }

    func testExitedOrReusedPIDAndProcessNewerThanRegistryHaveNoTarget() throws {
        let registry = try records([("conversation", 42)])
        var calls = 0
        let targets = GrokSessionOrigins.targets(in: registry, sessionIDs: ["grok:conversation"], uid: 501, process: { _ in
            calls += 1
            return calls == 1 ? self.process : nil
        }, arguments: { _ in self.kernelArguments() })
        XCTAssertTrue(targets.isEmpty)
        let reused = CodexTerminalOrigins.ProcessIdentity(pid: 42, uid: 501, startSeconds: 201,
            startMicroseconds: 0, executable: process.executable)
        XCTAssertNil(GrokSessionOrigins.target(process: process, rechecked: reused, openedAt: Date(timeIntervalSince1970: 200),
            arguments: ["grok"], environment: environment, uid: 501))
        XCTAssertNil(GrokSessionOrigins.target(process: reused, rechecked: reused, openedAt: Date(timeIntervalSince1970: 200),
            arguments: ["grok"], environment: environment, uid: 501))
        XCTAssertTrue(GrokSessionOrigins.targets(in: Data("[]".utf8), sessionIDs: ["grok:conversation"], uid: 501,
            process: { _ in self.process }, arguments: { _ in self.kernelArguments() }).isEmpty,
            "a refresh after registry removal clears the prior target")
    }

    func testHeadlessOtherUserExecutableAndInheritedMultiplexerPaneAreRejected() {
        for argv in [["grok", "-p", "fixture"], ["grok", "--single=fixture"], ["grok", "--prompt-file", "fixture"],
                     ["grok", "--output-format=json"]] {
            XCTAssertNil(target(arguments: argv))
        }
        XCTAssertNil(target(uid: 502))
        for executable in ["/usr/bin/node", "/bin/grok-bot", "/bin/grok-unrelated"] {
            let other = CodexTerminalOrigins.ProcessIdentity(pid: 42, uid: 501, startSeconds: 100,
                startMicroseconds: 50, executable: executable)
            XCTAssertNil(GrokSessionOrigins.target(process: other, rechecked: other, openedAt: Date(timeIntervalSince1970: 200),
                arguments: ["grok"], environment: environment, uid: 501))
        }
        for env in [["TERM_PROGRAM": "Apple_Terminal", "ITERM_SESSION_ID": "inherited"],
                    ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "inherited", "TMUX": "/tmp/tmux"],
                    ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": " "]] {
            XCTAssertNil(target(environment: env))
        }
    }

    func testInferenceUsageKeepsUpdatesTranscriptForConversationSync() {
        let updates = ProviderSession(id: "grok:conversation", title: "Exact conversation", path: "/sessions/conversation/updates.jsonl", client: "Grok CLI")
        let inference = ProviderSession(id: updates.id, title: "Inference", path: "/logs/unified.jsonl", client: "Grok CLI")
        XCTAssertEqual(GrokSessions.merge([inference, updates]).first?.path, updates.path)
        XCTAssertEqual(GrokSessions.merge([inference, updates]).first?.title, updates.title)
    }

    private func target(arguments: [String] = ["grok"], environment: [String: String]? = nil, uid: uid_t = 501) -> SessionNavigationTarget? {
        GrokSessionOrigins.target(process: process, rechecked: process, openedAt: Date(timeIntervalSince1970: 200),
            arguments: arguments, environment: environment ?? self.environment, uid: uid)
    }

    private func records(_ rows: [(String, Int32)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows.map { ["session_id": $0.0, "pid": $0.1,
            "cwd": "/same-workspace", "opened_at": "1970-01-01T00:03:20.000000Z"] as [String: Any] })
    }

    private func kernelArguments() -> Data {
        var argc: Int32 = 1
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data((process.executable + "\0\0grok\0TERM_PROGRAM=iTerm.app\0ITERM_SESSION_ID=w0t0p0:exact-pane\0API_KEY=fixture-unused\0\0").utf8))
        return data
    }
}
#endif

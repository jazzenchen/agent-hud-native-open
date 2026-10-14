#if !os(Windows)
// Providers/Codex/CodexTerminalOriginsTests.swift tests macOS-side sockets and home layouts.
import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class CodexTerminalOriginsTests: XCTestCase {
    private let process = CodexTerminalOrigins.ProcessIdentity(pid: 42, uid: 501, startSeconds: 100,
                                                              startMicroseconds: 50, executable: "/cli/bin/codex")
    private let environment = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w2t0p1:exact-pane"]

    func testRequiresPureNativeIPv4LoopbackOrigin() throws {
        XCTAssertEqual(CodexTerminalOrigins.port(try XCTUnwrap(URL(string: "http://127.0.0.1:12345"))), 12345)
        for value in ["https://127.0.0.1:12345", "http://localhost:12345", "http://192.0.2.1:12345",
                      "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
                      "http://user@127.0.0.1:12345", "http://127.0.0.1:12345/mcp",
                      "http://127.0.0.1:12345?token=ignored", "http://127.0.0.1:12345#ignored"] {
            XCTAssertNil(CodexTerminalOrigins.port(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testLiveCodexIdentityResolvesItsOwnPane() {
        XCTAssertEqual(CodexTerminalOrigins.target(process: process, rechecked: process, arguments: ["codex", "--model", "test"],
                                                   environment: environment, uid: 501), .iTermSession(id: "w2t0p1:exact-pane"))
    }

    func testExitPIDReuseDifferentUserAndNonTUICannotSupplyAnOrigin() {
        let reused = CodexTerminalOrigins.ProcessIdentity(pid: 42, uid: 501, startSeconds: 101,
                                                          startMicroseconds: 50, executable: process.executable)
        for rechecked in [nil, reused] {
            XCTAssertNil(CodexTerminalOrigins.target(process: process, rechecked: rechecked, arguments: ["codex"],
                                                      environment: environment, uid: 501))
        }
        XCTAssertNil(CodexTerminalOrigins.target(process: process, rechecked: process, arguments: ["codex"],
                                                  environment: environment, uid: 502))
        let other = CodexTerminalOrigins.ProcessIdentity(pid: 42, uid: 501, startSeconds: 100,
                                                         startMicroseconds: 50, executable: "/cli/bin/node")
        XCTAssertNil(CodexTerminalOrigins.target(process: other, rechecked: other, arguments: ["codex"],
                                                  environment: environment, uid: 501))
        for arguments in [["codex", "app-server", "--managed-daemon"], ["codex", "app-server"], ["codex", "mcp"]] {
            XCTAssertNil(CodexTerminalOrigins.target(process: process, rechecked: process, arguments: arguments,
                                                      environment: environment, uid: 501))
        }
    }

    func testInheritedIDInOtherTerminalOrTmuxCannotSupplyAnOrigin() {
        for env in [["TERM_PROGRAM": "Apple_Terminal", "ITERM_SESSION_ID": "inherited"],
                    ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "inherited", "TMUX": "/tmp/tmux"],
                    ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": ""]] {
            XCTAssertNil(CodexTerminalOrigins.target(process: process, rechecked: process, arguments: ["codex"],
                                                      environment: env, uid: 501))
        }
    }

    func testKernelBufferDecodesOnlyTerminalVariablesAfterArgv() {
        var count: Int32 = 3
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(Data("/cli/bin/codex\0\0codex\0--model\0ITERM_SESSION_ID=prompt\0API_KEY=do-not-decode\0TERM_PROGRAM=iTerm.app\0ITERM_SESSION_ID=w2t0p1:exact-pane\0TMUX=\0\0".utf8))
        XCTAssertEqual(CodexTerminalOrigins.terminalEnvironment(data), environment.merging(["TMUX": ""]) { _, last in last })
        XCTAssertNil(CodexTerminalOrigins.terminalEnvironment(Data()))
        XCTAssertNil(CodexTerminalOrigins.terminalEnvironment(data.prefix(12)))
    }
}
#endif

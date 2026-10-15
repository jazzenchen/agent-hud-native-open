#if !os(Windows)
// These follow SIGTERM and SIGKILL, which the Windows side replaces with termination.
import XCTest
@testable import AgentHUDCore

final class ChildProcessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func killGrandchild(_ output: ChildProcess.Output) {
        if let pid = Int32(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
    }

    func testGrandchildHoldingThePipesDoesNotDelayExitOrDeadline() async throws {
        var started = Date()
        let exited = try await ChildProcess.run(shell, ["-c", "sleep 30 & echo $!"], timeout: 5, stdoutLimit: 1024)
        killGrandchild(exited)
        XCTAssertEqual(exited.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "returns at the child's exit, not at pipe EOF")

        started = Date()
        let running = try await ChildProcess.run(shell, ["-c", "sleep 30 & echo $!; exec sleep 30"], timeout: 1, stdoutLimit: 1024)
        killGrandchild(running)
        XCTAssertNil(running.status)
        XCTAssertFalse(running.stdout.isEmpty, "output written before the deadline is kept")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testChildIgnoringSIGTERMIsKilled() async throws {
        let child = try ChildProcess(shell, ["-c", "trap '' TERM; echo ready; while :; do sleep 0.1; done"], stdoutLimit: 1024)
        let ready = try await child.line(before: Date().addingTimeInterval(2))
        XCTAssertEqual(ready, "ready")
        child.stop()
        try await child.waitForExit(before: Date().addingTimeInterval(1))
        XCTAssertNil(child.output.status, "SIGTERM is ignored")
        try await child.waitForExit(before: Date().addingTimeInterval(ChildProcess.grace + 1))
        XCTAssertEqual(child.output.status, SIGKILL)
    }

    func testLargeOutputIsDrainedUpToItsCaps() async throws {
        let output = try await ChildProcess.run(shell, ["-c", "head -c 2000000 /dev/zero >&2; head -c 2000000 /dev/zero"],
                                                timeout: 5, stdoutLimit: 1024 * 1024)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stderr.count, ChildProcess.stderrLimit)
        XCTAssertEqual(output.stdout.count, 1024 * 1024)
        XCTAssertTrue(output.truncated)
    }

    func testLinesStopAtTheAnswerAndEndWithTheExit() async throws {
        let server = try ChildProcess(shell, ["-c", "read -r request; echo noise; echo \"reply $request\"; sleep 30"], input: true, stdoutLimit: 1024)
        defer { server.stop() }
        try server.write(Data("ping\n".utf8))
        let started = Date()
        var answer: String?
        while let line = try await server.line(before: Date().addingTimeInterval(2)) {
            if line.hasPrefix("reply") { answer = line; break }
        }
        XCTAssertEqual(answer, "reply ping")
        XCTAssertNil(server.output.status)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let short = try ChildProcess(shell, ["-c", "echo one; printf two"], stdoutLimit: 1024)
        var lines: [String] = []
        while let line = try await short.line(before: Date().addingTimeInterval(2)) { lines.append(line) }
        XCTAssertEqual(lines, ["one"], "an unterminated last line is not a line")
        XCTAssertEqual(short.output.status, 0)
    }

    func testALineWaiterReturnsOnceStdoutPassesItsCap() async throws {
        let child = try ChildProcess(shell, ["-c", "head -c 4096 /dev/zero; exec sleep 30"], stdoutLimit: 1024)
        defer { child.stop() }
        let started = Date()
        let line = try await child.line(before: Date().addingTimeInterval(10))
        XCTAssertNil(line, "no whole line is left once bytes were lost")
        XCTAssertTrue(child.output.truncated)
        XCTAssertNil(child.output.status, "the child still runs")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the waiter does not sit out its deadline")
    }

    func testCancellationStopsTheChild() async throws {
        let child = try ChildProcess(URL(fileURLWithPath: "/bin/sleep"), ["30"], stdoutLimit: 1024)
        let waiting = Task { try await child.waitForExit(before: Date().addingTimeInterval(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        try await child.waitForExit(before: Date().addingTimeInterval(1))
        XCTAssertEqual(child.output.status, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
#endif

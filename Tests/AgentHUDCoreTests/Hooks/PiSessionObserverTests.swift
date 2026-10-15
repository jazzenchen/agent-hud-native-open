#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import XCTest
@testable import AgentHUDCore

final class PiSessionObserverTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PiObserverTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    private func observation(_ state: SessionTurn.State, age: TimeInterval = 0, turnID: String = "turn") -> PiSessionObserver.Observation {
        .init(version: 1, sessionID: "pi:session", sessionFile: nil, workspace: "/workspace", title: "Pi task",
              model: "model", providerID: "provider", turnID: turnID, state: state,
              startedAtMs: Int64(now.addingTimeInterval(-300 - age).timeIntervalSince1970 * 1000),
              observedAtMs: Int64(now.addingTimeInterval(-age).timeIntervalSince1970 * 1000))
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func report(_ local: OpenAgentLocalStore.Result, ledger: UsageLedger = .inMemory()) async throws -> UsageReport {
        let now = now
        let provider = OpenAgentUsageProvider(credentials: { [] }, sessions: { _ in local },
            fetchQuota: { _, _ in throw ProviderFailure.format }, history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
        return try await provider.fetchUsage(agents: [], historyHours: 168)
    }

    func testInstallHonorsCustomHomePreservesOtherExtensionsAndIsReversible() async throws {
        let home = try temporaryHome(), custom = home.appendingPathComponent("custom-agent")
        let env = ["PI_CODING_AGENT_DIR": custom.path]
        let other = custom.appendingPathComponent("extensions/other.ts")
        try write(Data("other extension".utf8), to: other)
        for _ in 0..<2 { try PiSessionObserver.configure(enabled: true, home: home, environment: env) }
        XCTAssertTrue(PiSessionObserver.isInstalled(home: home, environment: env))
        XCTAssertFalse(PiSessionObserver.isInstalled(home: home, environment: [:]))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other extension")
        try PiSessionObserver.configure(enabled: false, home: home, environment: env)
        XCTAssertFalse(PiSessionObserver.isInstalled(home: home, environment: env))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let occupied = custom.appendingPathComponent("extensions/agent-hud.ts")
        try write(Data("unrelated".utf8), to: occupied)
        XCTAssertThrowsError(try PiSessionObserver.configure(enabled: true, home: home, environment: env))
        XCTAssertThrowsError(try PiSessionObserver.configure(enabled: false, home: home, environment: env))
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "unrelated")
    }

    func testAutomaticSetupOnlyInstallsForAnExistingPiDirectory() async throws {
        let home = try temporaryHome(), custom = home.appendingPathComponent("custom-agent")
        let env = ["PI_CODING_AGENT_DIR": custom.path]
        try PiSessionObserver.configureIfAvailable(home: home, environment: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try PiSessionObserver.configureIfAvailable(home: home, environment: env)
        XCTAssertTrue(PiSessionObserver.isInstalled(home: home, environment: env))
    }

    func testSettingsTellWhetherTheExtensionIsInPlaceAndWhetherThisPiReportsAnEnd() async throws {
        let home = try temporaryHome(), paths = OpenAgentPaths(home: home, environment: [:])
        XCTAssertEqual(PiSessionObserver.fileState(home: home, environment: [:]), .missing)
        try PiSessionObserver.configure(enabled: true, home: home, environment: [:])
        XCTAssertEqual(PiSessionObserver.fileState(home: home, environment: [:]), .installed)
        try write(Data("// Someone else's extension\n".utf8), to: paths.pi.appendingPathComponent("extensions/agent-hud.ts"))
        XCTAssertEqual(PiSessionObserver.fileState(home: home, environment: [:]), .foreign)

        func recorded(_ version: String?) throws -> String? {
            let settings = version.map { #"{"lastChangelogVersion":"\#($0)","theme":"light"}"# } ?? #"{"theme":"light"}"#
            try write(Data(settings.utf8), to: paths.pi.appendingPathComponent("settings.json"))
            return PiSessionObserver.unsupportedVersion(home: home, environment: [:])
        }
        XCTAssertEqual(try recorded("0.73.1"), "0.73.1", "the last release under the old package name has no agent_settled")
        XCTAssertEqual(try recorded("0.80.3"), "0.80.3")
        XCTAssertNil(try recorded("0.80.5"))
        XCTAssertNil(try recorded("0.87.1"))
        XCTAssertNil(try recorded(nil), "a Pi that never opened an interactive session recorded no version")
        XCTAssertNil(try recorded("latest"))
    }

    func testTheSessionsOwnLogNamesItOverTheObserversSnapshot() async throws {
        let home = try temporaryHome(), paths = OpenAgentPaths(home: home, environment: [:])
        try write(JSONEncoder().encode(observation(.completed)), to: paths.piTurns.appendingPathComponent("turn.json"))
        let transcript = paths.pi.appendingPathComponent("sessions/workspace/session.jsonl")
        let header = #"{"type":"session","id":"session","cwd":"/workspace","timestamp":"\#(now.addingTimeInterval(-600).ISO8601Format())"}"#
        try write(Data(header.utf8), to: transcript)
        let store = OpenAgentLocalStore(paths: paths)
        let observed = await store.index(since: now.addingTimeInterval(-86400))
        XCTAssertEqual(observed.sessions.map(\.title), ["Pi task"], "without a name or a message in the log, the observer's title stands")
        try write(Data((header + "\n" + #"{"type":"session_info","id":"i","name":"Renamed while idle"}"#).utf8), to: transcript)
        let renamed = await store.index(since: now.addingTimeInterval(-86400))
        XCTAssertEqual(renamed.sessions.map(\.title), ["Renamed while idle"], "a name given after the turn settled beats the observer's copy")
    }

    func testRunningBeforeFirstResponseThenUsageAndCompletionMergeIntoOneSession() async throws {
        let home = try temporaryHome(), paths = OpenAgentPaths(home: home, environment: [:])
        let observerFile = paths.piTurns.appendingPathComponent("turn.json")
        try write(JSONEncoder().encode(observation(.running)), to: observerFile)
        let store = OpenAgentLocalStore(paths: paths)
        let local = await store.index(since: now.addingTimeInterval(-86400))
        func recorded(_ ledger: UsageLedger) async throws -> [UsageBucket] { try await ledger.buckets(since: .distantPast) }
        let runningLedger = UsageLedger.inMemory(), completedLedger = UsageLedger.inMemory(), cachedLedger = UsageLedger.inMemory()
        let running = try await report(local, ledger: runningLedger)
        XCTAssertEqual(running.sessions.count, 1)
        XCTAssertTrue(try XCTUnwrap(running.sessions.first).isLive)
        XCTAssertEqual(running.consumers.first?.model, "model · provider")
        XCTAssertEqual(running.turns.first?.state, .running)
        let runningUsage = try await recorded(runningLedger)
        XCTAssertEqual(runningUsage.reduce(0) { $0 + $1.total }, 0)

        let transcript = paths.pi.appendingPathComponent("sessions/workspace/session.jsonl")
        try write(Data("""
        {"type":"session","id":"session","cwd":"/workspace","timestamp":"\(now.addingTimeInterval(-600).ISO8601Format())"}
        {"type":"message","id":"response","timestamp":"\(now.addingTimeInterval(-10).ISO8601Format())","message":{"role":"assistant","model":"model","provider":"provider","usage":{"input":10,"output":5,"cacheRead":20,"cacheWrite":2},"stopReason":"stop"}}
        """.utf8), to: transcript)
        try write(JSONEncoder().encode(observation(.completed)), to: observerFile)
        let completed = try await report(await store.index(since: now.addingTimeInterval(-86400)), ledger: completedLedger)
        XCTAssertEqual(completed.sessions.count, 1)
        let session = try XCTUnwrap(completed.sessions.first)
        XCTAssertFalse(session.isLive)
        XCTAssertEqual(session.tokensIn, 12)
        XCTAssertEqual(session.tokensOut, 5)
        XCTAssertEqual(session.cacheReadTokens, 20)
        XCTAssertEqual(session.task, "Pi task")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(session.transcriptPath)).resolvingSymlinksInPath(), transcript.resolvingSymlinksInPath())
        let completedUsage = try await recorded(completedLedger)
        XCTAssertEqual(completedUsage.reduce(0) { $0 + $1.total }, 17, "input with cache writes plus output")
        XCTAssertEqual(completed.completions.count, 1)
        XCTAssertEqual(completed.turns.first?.state, .completed)
        let cached = try await report(await store.index(since: now.addingTimeInterval(-86400)), ledger: cachedLedger)
        let cachedUsage = try await recorded(cachedLedger)
        XCTAssertEqual(cachedUsage, completedUsage)
        XCTAssertEqual(cached.turns, completed.turns, "A poll must not manufacture a newer source timestamp")
    }

    func testErrorsStaleRunsAndHistoricalCompletionDoNotFinishNewRun() async throws {
        var running = observation(.running).session
        running.turns.insert(observation(.completed, age: 600, turnID: "old").turn, at: 0)
        let active = try await report(.init(sessions: [running]))
        XCTAssertTrue(try XCTUnwrap(active.sessions.first).isLive)
        for value in [observation(.ended), observation(.running, age: 121)] {
            let result = try await report(.init(sessions: [value.session]))
            XCTAssertFalse(try XCTUnwrap(result.sessions.first).isLive)
            XCTAssertTrue(result.completions.isEmpty)
            XCTAssertEqual(result.turns.last?.state, .ended)
        }
        XCTAssertThrowsError(try PiSessionObserver.read(Data("{}".utf8)))
    }

    func testLatestObserverOwnsNavigationAndCanClearAnOlderTerminal() async throws {
        let home = try temporaryHome(), paths = OpenAgentPaths(home: home, environment: [:])
        var captured = observation(.completed, age: 60, turnID: "captured")
        captured.navigationTarget = .iTermSession(id: "w0t0p0:exact-terminal")
        try write(JSONEncoder().encode(captured), to: paths.piTurns.appendingPathComponent("captured.json"))
        let transcript = paths.pi.appendingPathComponent("sessions/workspace/session.jsonl")
        try write(Data("""
        {"type":"session","id":"session","cwd":"/workspace","timestamp":"\(now.ISO8601Format())"}
        """.utf8), to: transcript)
        let store = OpenAgentLocalStore(paths: paths)
        let capturedReport = try await report(await store.index(since: now.addingTimeInterval(-86400)))
        XCTAssertEqual(capturedReport.sessions.first?.navigationTarget, captured.navigationTarget,
                       "the usage log cannot overwrite a destination its source observer captured")
        XCTAssertEqual(capturedReport.completions.first?.navigationTarget, captured.navigationTarget)

        var relocated = observation(.completed, age: 30, turnID: "relocated")
        relocated.navigationTarget = .iTermSession(id: "w1t2p0:new-terminal")
        try write(JSONEncoder().encode(relocated), to: paths.piTurns.appendingPathComponent("relocated.json"))
        let moved = try await report(await store.index(since: now.addingTimeInterval(-86400)))
        XCTAssertEqual(moved.completions.count, 2)
        XCTAssertTrue(moved.completions.allSatisfy { $0.navigationTarget == relocated.navigationTarget },
                      "past turns return to the session's current terminal after a resume elsewhere")

        let unsupported = observation(.completed, turnID: "unsupported")
        try write(JSONEncoder().encode(unsupported), to: paths.piTurns.appendingPathComponent("unsupported.json"))
        let current = try await report(await store.index(since: now.addingTimeInterval(-86400)))
        XCTAssertNil(current.sessions.first?.navigationTarget, "a newer source without an exact target clears the older destination")
        XCTAssertEqual(current.completions.count, 3)
        XCTAssertTrue(current.completions.allSatisfy { $0.navigationTarget == nil },
                      "the latest unsupported source clears destinations for every past turn")
        let oldRecord = try PiSessionObserver.read(JSONEncoder().encode(unsupported))
        XCTAssertNil(oldRecord.navigationTarget, "observer records before navigation capture remain readable")
    }

    func testNativeExtensionLifecycleRetriesHeartbeatAndPrivacy() async throws {
        let home = try temporaryHome()
        let script = home.appendingPathComponent("observer.mjs"), test = home.appendingPathComponent("test.mjs")
        try write(Data(PiSessionObserver.script.utf8), to: script)
        try write(Data(#"""
        import assert from 'node:assert/strict';
        import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
        import { join } from 'node:path';
        import observer from './observer.mjs';
        process.env.PI_CODING_AGENT_DIR = process.argv[2];
        delete process.env.TMUX;
        process.env.TERM_PROGRAM = 'Apple_Terminal';
        process.env.ITERM_SESSION_ID = 'inherited-terminal';
        let timer, cleared = 0, clock = 1789000000000;
        Date.now = () => ++clock;
        globalThis.setInterval = (fn, ms) => { assert.equal(ms, 15000); timer = fn; return { unref() {} }; };
        globalThis.clearInterval = () => { cleared++; };
        const handlers = new Map();
        const pi = { on: (name, handler) => handlers.set(name, handler) };
        const ctx = { cwd: '/workspace', model: { id: 'model', provider: 'provider' },
          sessionManager: { getSessionId: () => 'session', getSessionFile: () => undefined, getSessionName: () => 'Task' } };
        const emit = (name, event = {}) => handlers.get(name)?.(event, ctx);
        const directory = join(process.argv[2], 'agent-hud', 'turns');
        const rows = () => readdirSync(directory).filter(f => f.endsWith('.json')).map(f => JSON.parse(readFileSync(join(directory, f), 'utf8')));
        observer(pi);
        emit('session_start');
        emit('agent_start');
        const first = rows()[0];
        assert.equal(first.state, 'running');
        assert.equal(first.sessionFile, undefined);
        assert.equal(first.navigationTarget, undefined, 'an inherited iTerm id does not make another terminal an iTerm target');
        emit('message_end', { message: { role: 'assistant', stopReason: 'error', content: 'private prompt', usage: { input: 99 } } });
        const beating = cleared;
        emit('agent_end');
        assert.equal(cleared, beating + 1, 'a run that ends stops its heartbeat, since older Pi never settles it');
        emit('agent_start'); // retry, still the same logical turn
        assert.equal(rows()[0].turnID, first.turnID);
        assert.equal(rows()[0].state, 'running');
        timer();
        assert.ok(rows()[0].observedAtMs > first.observedAtMs);
        emit('message_end', { message: { role: 'assistant', stopReason: 'stop' } });
        emit('agent_end'); // queued follow-up must not trigger completion
        assert.equal(rows()[0].state, 'running');
        emit('agent_settled');
        assert.equal(rows()[0].state, 'completed');
        const completedAt = rows()[0].observedAtMs;
        emit('session_shutdown');
        assert.equal(rows()[0].observedAtMs, completedAt);
        for (const reason of ['error', 'aborted', 'length']) {
          emit('agent_start');
          emit('message_end', { message: { role: 'assistant', stopReason: reason } });
          emit('agent_settled');
        }
        emit('agent_start');
        emit('session_shutdown');
        assert.equal(rows().filter(r => r.state === 'completed').length, 1);
        assert.equal(rows().filter(r => r.state === 'ended').length, 4);
        assert.ok(cleared >= 5);
        assert.equal(JSON.stringify(rows()).includes('private prompt'), false);
        assert.equal(JSON.stringify(rows()).includes('usage'), false);
        assert.equal(JSON.stringify(rows()).includes('content'), false);
        for (const [program, id, tmux, expected] of [
          ['iTerm.app', 'w7t2p0:exact-terminal', '', { kind: 'iTermSession', id: 'w7t2p0:exact-terminal' }],
          ['iTerm.app', 'w7t2p0:exact-terminal', '/tmp/tmux,123,0', undefined],
          ['Apple_Terminal', 'w7t2p0:exact-terminal', '', undefined],
          ['iTerm.app', '', '', undefined],
        ]) {
          process.env.TERM_PROGRAM = program;
          process.env.ITERM_SESSION_ID = id;
          process.env.TMUX = tmux;
          emit('agent_start');
          emit('message_end', { message: { role: 'assistant', stopReason: 'stop' } });
          emit('agent_settled');
          const latest = rows().sort((a, b) => b.observedAtMs - a.observedAtMs)[0];
          assert.deepEqual(latest.navigationTarget, expected);
        }
        // An unwritable inbox cannot break an agent run.
        process.env.PI_CODING_AGENT_DIR = join(process.argv[2], 'blocked');
        writeFileSync(process.env.PI_CODING_AGENT_DIR, 'file instead of directory');
        observer(pi);
        emit('agent_start'); emit('agent_settled');
        console.log('Pi native lifecycle checks passed');
        """#.utf8), to: test)
        let output = try await ProviderCommand.run("/usr/bin/env", ["node", test.path, home.path])
        XCTAssertTrue(output.contains("Pi native lifecycle checks passed"), output)
    }
}
#endif

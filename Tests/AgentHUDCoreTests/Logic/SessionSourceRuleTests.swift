import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// When each client's source says a session is still in flight, and how it rewrites the turns it reports, one
/// millisecond either side of every limit. Offsets are seconds from `base`.
final class SessionSourceRuleTests: XCTestCase, @unchecked Sendable {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A clock a test moves between reads.
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
    private func ms(_ offset: TimeInterval) -> Int64 { RecordCoding.milliseconds(at(offset)) }

    /// An internet time with milliseconds, assembled from whole numbers so no rounding moves it.
    private func stamp(_ offset: TimeInterval) -> String {
        let milliseconds = ms(offset)
        let whole = Date(timeIntervalSince1970: TimeInterval(milliseconds / 1000)).ISO8601Format()
        return String(whole.dropLast()) + "." + String(String(1000 + milliseconds % 1000).dropFirst()) + "Z"
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Writes `lines` and dates the file at `modified`, so a store's cutoff and quiet clocks never see the real time.
    private func write(_ lines: [String], to file: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    // MARK: Claude

    private enum ClaudeLine { case prompt, working, answer, interruption, toolResult, attachment }

    private func claude(_ line: ClaudeLine, _ offset: TimeInterval, text: String? = nil, sidechain: Bool = false) -> TranscriptEvent {
        let role: TranscriptEvent.Role, words: String?, stop: String?
        switch line {
        case .prompt: (role, words, stop) = (.user, "Build it", nil)
        case .interruption: (role, words, stop) = (.user, "[Request interrupted by user]", nil)
        case .toolResult: (role, words, stop) = (.user, nil, nil)
        case .working: (role, words, stop) = (.assistant, text, "tool_use")
        case .answer: (role, words, stop) = (.assistant, text, "end_turn")
        case .attachment: (role, words, stop) = (.other, nil, nil)
        }
        let assistant = role == .assistant
        return TranscriptEvent(timestamp: at(offset), role: role, model: assistant ? "claude-test" : nil, inputTokens: 0, cacheCreationTokens: 0,
                               cacheReadTokens: 0, outputTokens: 0, text: words, sessionId: "s", cwd: nil,
                               messageId: assistant ? "m\(offset)" : nil, stopReason: stop, isSidechain: sidechain,
                               isPrompt: line == .prompt || line == .interruption)
    }

    private func claudeLog(_ lines: [TranscriptEvent], path: String = "/p/s.jsonl") -> TranscriptSession {
        var accumulator = TranscriptAccumulator(path: path, isSubagent: path.contains("/subagents/"))
        accumulator.ingest(lines)
        return accumulator.build()!
    }

    func testAClaudeLogIsInFlightByItsTurnAndHowLongItHasBeenQuiet() {
        let quiet: [TimeInterval] = [119.999, 120, 1799.999, 1800]
        let logs: [(name: String, lines: [TranscriptEvent], turn: SessionTurn.State?, observed: Int64?, live: [Bool])] = [
            ("no turn", [claude(.toolResult, 0)], nil, nil, [true, false, false, false]),
            ("running since a prompt", [claude(.prompt, -10), claude(.working, 0)], .running, ms(0), [true, true, true, false]),
            ("running without a prompt", [claude(.working, 0)], .running, ms(0), [true, false, false, false]),
            ("completed", [claude(.prompt, -10), claude(.answer, 0)], .completed, ms(0), [false, false, false, false]),
            ("ended by an interruption", [claude(.prompt, -10), claude(.interruption, 0)], .ended, ms(0), [false, false, false, false]),
            // Quiet counts from the log's last line of any kind; a line outside the conversation does not date the turn.
            ("running without a prompt, then an attachment", [claude(.working, -100), claude(.attachment, 0)], .running, ms(-100),
             [true, false, false, false]),
        ]
        for log in logs {
            let session = claudeLog(log.lines)
            XCTAssertEqual(session.turn?.state, log.turn, log.name)
            XCTAssertEqual(session.turn?.observedAtMs, log.observed, log.name)
            XCTAssertEqual(session.lastActivityAt, base, log.name)
            XCTAssertEqual(quiet.map { session.isLive(now: at($0), threshold: ClaudeCodeProvider.liveThreshold) }, log.live, log.name)
        }
    }

    func testAClaudeSessionRunsWhileItsTurnOrASubagentIsAtWorkUntilEitherIsAbandoned() async throws {
        let root = try directory().appendingPathComponent("projects", isDirectory: true)
        let project = root.appendingPathComponent("-p", isDirectory: true)
        func line(_ session: String, _ type: String, _ message: String, at offset: TimeInterval, sidechain: Bool = false) -> String {
            #"{"isSidechain":\#(sidechain),"sessionId":"\#(session)","cwd":"/p","type":"\#(type)","message":\#(message),"timestamp":"\#(stamp(offset))"}"#
        }
        func prompt(_ session: String, at offset: TimeInterval, sidechain: Bool = false) -> String {
            line(session, "user", #"{"role":"user","content":"Research the options"}"#, at: offset, sidechain: sidechain)
        }
        func assistant(_ session: String, _ id: String, stop: String, at offset: TimeInterval, sidechain: Bool = false) -> String {
            line(session, "assistant", #"{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"…"}],"stop_reason":\#(stop),"usage":{"input_tokens":1,"output_tokens":1}}"#,
                 at: offset, sidechain: sidechain)
        }
        // One agent is in a tool call; the other started a sub-agent and ended its own turn. Both last wrote at `base`.
        try write([prompt("rule-alone", at: -600), assistant("rule-alone", "msg_tool", stop: #""tool_use""#, at: 0)],
                  to: project.appendingPathComponent("rule-alone.jsonl"), modified: base)
        try write([prompt("rule-parent", at: -600), assistant("rule-parent", "msg_launch", stop: #""tool_use""#, at: -598),
                   assistant("rule-parent", "msg_wait", stop: #""end_turn""#, at: -590)],
                  to: project.appendingPathComponent("rule-parent.jsonl"), modified: at(-590))
        try write([prompt("rule-parent", at: -597, sidechain: true), assistant("rule-parent", "msg_a1", stop: "null", at: 0, sidechain: true)],
                  to: project.appendingPathComponent("rule-parent/subagents/agent-a1.jsonl"), modified: base)
        let clock = Clock(base)
        let provider = ClaudeCodeProvider(engine: nil, transcripts: ClaudeTranscriptStore(roots: [root]), history: QuotaHistoryStore(),
                                          clock: { clock.now })

        clock.now = at(1799.999)
        let working = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(working.sessions.map(\.id), ["rule-alone", "rule-parent"])
        XCTAssertEqual(working.sessions.map(\.endedAt), [nil, nil])
        XCTAssertEqual(working.turns.map(\.sessionID), ["rule-alone", "rule-parent"])
        XCTAssertEqual(working.turns.map(\.state), [.running, .running])
        XCTAssertEqual(working.turns.map(\.observedAtMs), [ms(0), ms(0)], "the finished turn is dated by the sub-agent's line")
        XCTAssertEqual(working.turns.map(\.startedAtMs), [ms(-600), ms(-600)])

        clock.now = at(1800)
        let abandoned = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(abandoned.sessions.map(\.endedAt), [base, at(-590)])
        XCTAssertEqual(abandoned.turns.map(\.state), [.running, .completed], "an abandoned turn is reported as its log left it")
        XCTAssertEqual(abandoned.turns.map(\.observedAtMs), [ms(0), ms(-590)])
    }

    func testAClaudeApprovalRequestNewerThanTheTurnMakesItWait() throws {
        let inbox = try directory()
        /// The requests read at the moment one is made at `offset`.
        func request(at offset: TimeInterval, message: String? = "Claude needs your permission to use Bash") throws -> [String: AttentionHooks.Event] {
            var payload: [String: Any] = ["session_id": "s", "hook_event_name": "Notification"]
            payload["message"] = message
            try AttentionHooks.record(source: .claude, data: JSONSerialization.data(withJSONObject: payload), now: at(offset), directory: inbox)
            return AttentionHooks.read(source: .claude, now: at(offset), directory: inbox)
        }
        /// The turn the provider reports, with the sub-agents still at work 10 s after `base`.
        func reported(_ session: TranscriptSession, _ requests: [String: AttentionHooks.Event], subagents: [TranscriptSession] = []) -> SessionTurn? {
            ClaudeCodeProvider.turns([session], agentsWorkingAt: ClaudeCodeProvider.workingAgents(subagents, now: at(10)), requests: requests).first
        }
        let running = claudeLog([claude(.prompt, -60), claude(.working, 0, text: "Reading the file")])

        let answered = try XCTUnwrap(reported(running, try request(at: 0)))
        XCTAssertEqual(answered.state, .running, "a request no newer than the turn's last line was answered")
        XCTAssertEqual(answered.observedAtMs, ms(0))
        let asked = try XCTUnwrap(reported(running, try request(at: 0.001)))
        XCTAssertEqual(asked.state, .waitingForApproval)
        XCTAssertEqual(asked.observedAtMs, ms(0.001))
        XCTAssertEqual(asked.startedAtMs, ms(-60))
        XCTAssertEqual(asked.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(reported(running, try request(at: 0.001, message: nil))?.message, "Reading the file",
                       "without words of its own, a request keeps the turn's answer")

        // A sub-agent writing after the request dates the waiting turn without answering it. A finished turn it keeps
        // busy runs again, whatever the request says.
        let subagent = claudeLog([claude(.prompt, -30, sidechain: true), claude(.working, 5, sidechain: true)], path: "/p/s/subagents/agent-a.jsonl")
        let waiting = try XCTUnwrap(reported(running, try request(at: 0.001), subagents: [subagent]))
        XCTAssertEqual([waiting.state], [.waitingForApproval])
        XCTAssertEqual(waiting.observedAtMs, ms(5))
        let finished = claudeLog([claude(.prompt, -60), claude(.answer, 0)])
        let resumed = try XCTUnwrap(reported(finished, try request(at: 0.001), subagents: [subagent]))
        XCTAssertEqual([resumed.state], [.running])
        XCTAssertEqual(resumed.observedAtMs, ms(5))

        // A request is read while it is younger than a day and no more than a minute ahead of the reader's clock.
        _ = try request(at: 0)
        for (read, kept) in [(86399.999, true), (86400, false), (-60, true), (-60.001, false)] {
            XCTAssertEqual(AttentionHooks.read(source: .claude, now: at(read), directory: inbox)["s"]?.at, kept ? base : nil, "read at \(read)")
        }
    }

    // MARK: Codex

    private func codexLine(_ payload: [String: Any], at offset: TimeInterval, type: String = "event_msg") -> String {
        json(["type": type, "timestamp": stamp(offset), "payload": payload])
    }

    private func codexStart(_ turn: String?) -> [String: Any] { turn.map { ["type": "task_started", "turn_id": $0] } ?? ["type": "task_started"] }

    private func rolloutLines(guardian: Bool = false, _ events: [(payload: [String: Any], at: TimeInterval)]) -> [String] {
        let source: Any = guardian ? ["subagent": ["other": "guardian"]] : "cli"
        return [codexLine(["id": "rollout", "source": source], at: -86400, type: "session_meta")] + events.map { codexLine($0.payload, at: $0.at) }
    }

    private func rollout(guardian: Bool = false, _ events: [(payload: [String: Any], at: TimeInterval)]) -> CodexTranscript {
        var transcript = CodexTranscript()
        for line in rolloutLines(guardian: guardian, events) { transcript.ingest(Data(line.utf8)) }
        return transcript
    }

    func testACodexRolloutIsInFlightByItsNewestTurnAndItsNewestEvent() {
        let ages: [TimeInterval] = [119.999, 120, 1799.999, 1800]
        let tokens: [String: Any] = ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 10, "output_tokens": 1]]]
        let message: [String: Any] = ["type": "agent_message", "message": "Working on it"]
        // The events of each rollout, the newest `age` seconds before the read, and whether it is in flight at each age.
        let rollouts: [(name: String, rollout: (TimeInterval) -> CodexTranscript, live: [Bool])] = [
            ("a guardian", { self.rollout(guardian: true, [(self.codexStart("t1"), -$0)]) }, [false, false, false, false]),
            ("a rollout without activity", { _ in self.rollout([]) }, [false, false, false, false]),
            ("no turn", { self.rollout([(tokens, -$0)]) }, [true, false, false, false]),
            ("newest turn running", { self.rollout([(self.codexStart("t1"), -$0)]) }, [true, true, true, false]),
            ("newest turn running, heard from since it started", { self.rollout([(self.codexStart("t1"), -7200), (message, -$0)]) },
             [true, true, true, false]),
            ("newest turn completed", { self.rollout([(self.codexStart("t1"), -$0 - 10), (["type": "task_complete", "turn_id": "t1"], -$0)]) },
             [false, false, false, false]),
            ("newest turn aborted", { self.rollout([(self.codexStart("t1"), -$0 - 10), (["type": "turn_aborted", "turn_id": "t1"], -$0)]) },
             [false, false, false, false]),
        ]
        for item in rollouts {
            XCTAssertEqual(ages.map { item.rollout($0).isLive(now: base, modifiedAt: base) }, item.live, item.name)
        }
        // Quiet is the newest event's age, whatever the file's date says.
        XCTAssertFalse(rollout([(codexStart("t1"), -7200)]).isLive(now: base, modifiedAt: at(-1)))
        XCTAssertTrue(rollout([(codexStart("t1"), -1)]).isLive(now: base, modifiedAt: at(-1800)))
    }

    func testARolloutWrittenWithoutNewEventsLeavesItsSessionEnded() async throws {
        let dir = try directory(), now = base
        try write(rolloutLines([(codexStart("t1"), -1800)]), to: dir.appendingPathComponent("rollout-stale.jsonl"), modified: at(-1))
        let provider = CodexUsageProvider(readLimits: { throw UsageProviderError("signed out") }, transcripts: CodexTranscriptStore(roots: [dir]),
                                          history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.sessions.map(\.endedAt), [at(-1800)],
                       "a file written a second ago does not keep a turn last heard from half an hour ago running")
        XCTAssertEqual(report.sessions.map(\.lastActivityAt), [at(-1800)])
    }

    func testAClaudeLogWithoutATurnIsDatedByItsLastLine() async throws {
        let root = try directory().appendingPathComponent("projects", isDirectory: true)
        let result = #"{"sessionId":"turnless","cwd":"/p","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"timestamp":"\#(stamp(-30))"}"#
        try write([result], to: root.appendingPathComponent("-p/turnless.jsonl"), modified: at(-30))
        let now = base
        let report = try await ClaudeCodeProvider(engine: nil, transcripts: ClaudeTranscriptStore(roots: [root]), history: QuotaHistoryStore(),
                                                  clock: { now }).fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.turns, [])
        XCTAssertEqual(report.sessions.map(\.endedAt), [nil], "a log without a turn is in flight while it is fresh")
        XCTAssertEqual(report.sessions.map(\.lastActivityAt), [at(-30)])
    }

    func testACodexTurnWithoutAnIdKeepsTheSessionInFlightBehindAFinishedReportedTurn() async throws {
        let events: [(payload: [String: Any], at: TimeInterval)] = [
            (codexStart("t1"), -30), (["type": "task_complete", "turn_id": "t1"], -20), (codexStart(nil), -10),
        ]
        let transcript = rollout(events)
        XCTAssertTrue(transcript.isLive(now: base, modifiedAt: at(-10)))
        XCTAssertEqual(transcript.sessionTurns.map(\.turnID), ["t1"], "a turn without an id is not reported")
        XCTAssertEqual(transcript.sessionTurns.map(\.state), [.completed])

        let dir = try directory(), now = base
        try write(rolloutLines(events), to: dir.appendingPathComponent("rollout-idless.jsonl"), modified: at(-10))
        let provider = CodexUsageProvider(readLimits: { throw UsageProviderError("signed out") }, transcripts: CodexTranscriptStore(roots: [dir]),
                                          history: QuotaHistoryStore(), clock: { now })
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.sessions.map(\.id), ["rollout"])
        XCTAssertNil(report.sessions.first?.endedAt)
        XCTAssertEqual(report.turns.map(\.state), [.completed])
    }

    // MARK: DeepSeek

    private func harness(_ events: [(type: String, data: [String: Any], at: TimeInterval)], id: String = "main") -> [String] {
        [json(["type": "session", "version": 0, "id": id, "createdAt": at(-3600).timeIntervalSince1970 * 1000, "cwd": "/work"])]
            + events.enumerated().map { index, event in
                json(["type": event.type, "seq": index, "time": at(event.at).timeIntervalSince1970 * 1000, "data": event.data])
            }
    }

    func testADeepSeekTurnIsInFlightWhileAHarnessProcessPredatesIt() throws {
        func transcript(_ lines: [String]) throws -> DeepSeekTranscript {
            var value = DeepSeekTranscript()
            for line in lines { try value.ingest(Data(line.utf8)) }
            return value
        }
        let running = try transcript(harness([("turn/start", ["turn": 1], -600)]))
        // A log that recorded only a turn's end has the one kind of turn without a start, and it is never running.
        let unstarted = try transcript(harness([("turn/end", ["turn": 1, "reason": ["kind": "completed"]], -600)]))
        XCTAssertEqual(unstarted.sessionTurns.map(\.startedAtMs), [nil])
        let tables: [[Date]?] = [nil, [], [at(-601)], [at(-600)], [at(-599)]]
        XCTAssertEqual(tables.map(running.isLive(processStarts:)), [true, false, true, true, false])
        XCTAssertEqual(tables.map(unstarted.isLive(processStarts:)), [false, false, false, false, false])
    }

    func testTheDeepSeekProcessTableIsReadForAQuietRunningTurnAtMostEvery30Seconds() async throws {
        let root = try directory()
        // The turn's last event is at `base`. A rename written later records no activity, so the file's date does not count.
        try write(harness([("turn/start", ["turn": 1], 0), ("session/title", ["title": "Renamed"], 100)], id: "quiet"),
                  to: root.appendingPathComponent("work/quiet/session.jsonl"), modified: at(100))
        final class Table: @unchecked Sendable { var starts: [Date] = []; var reads = 0 }
        let table = Table(), clock = Clock(base)
        let provider = DeepSeekUsageProvider(directory: root, transcripts: DeepSeekTranscriptStore(root: root),
                                             readProcessStarts: { table.reads += 1; return table.starts }, clock: { clock.now })
        func live(at offset: TimeInterval) async throws -> [Bool] {
            clock.now = at(offset)
            return try await provider.fetchUsage(agents: [], historyHours: 24).sessions.map(\.isLive)
        }
        var result = try await live(at: 119.999)
        XCTAssertEqual(result, [true], "a log whose newest event is less than 120 s old is not checked")
        XCTAssertEqual(table.reads, 0)
        result = try await live(at: 120)
        XCTAssertEqual(result, [false], "no Harness process holds the turn, though the file was written 20 s ago")
        XCTAssertEqual(table.reads, 1)
        table.starts = [at(-1)]
        result = try await live(at: 149.999)
        XCTAssertEqual(result, [false], "the last answer stands for 30 s")
        XCTAssertEqual(table.reads, 1)
        result = try await live(at: 150)
        XCTAssertEqual(result, [true])
        XCTAssertEqual(table.reads, 2)
        result = try await live(at: 86400)
        XCTAssertEqual(result, [true], "however long the log is quiet, the process decides")
        XCTAssertEqual(table.reads, 3)
    }

    func testOneQuietDeepSeekSessionPutsEverySessionToTheProcessTable() async throws {
        let root = try directory(), quiet = root.appendingPathComponent("work/quiet/session.jsonl")
        try write(harness([("turn/start", ["turn": 1], -600)], id: "quiet"), to: quiet, modified: base)
        try write(harness([("turn/start", ["turn": 1], 170)], id: "fresh"), to: root.appendingPathComponent("work/fresh/session.jsonl"), modified: at(179))
        let clock = Clock(at(180))
        let provider = DeepSeekUsageProvider(directory: root, transcripts: DeepSeekTranscriptStore(root: root),
                                             readProcessStarts: { [] }, clock: { clock.now })
        let both = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(both.sessions.map(\.id).sorted(), ["deepseek:fresh", "deepseek:quiet"])
        XCTAssertEqual(both.sessions.map(\.isLive), [false, false], "a log written a second ago ends with the quiet one")
        try FileManager.default.removeItem(at: quiet)
        clock.now = at(181)
        let alone = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(alone.sessions.map(\.isLive), [true], "without a quiet running turn the table is not read")
    }

    /// A turn whose process outlives it is vouched for by the process check, not by its log: quiet for 40 minutes, it is
    /// still live, dated by when the table was read, which the 30-second recheck moves and a read between rechecks does not.
    func testAQuietDeepSeekTurnWhoseProcessLivesIsVouchedForByTheProcessCheck() async throws {
        let root = try directory()
        try write(harness([("turn/start", ["turn": 1], -2400)], id: "quiet"), to: root.appendingPathComponent("work/quiet/session.jsonl"),
                  modified: at(-2400))
        let clock = Clock(base), harnessStarted = at(-3000)
        let provider = DeepSeekUsageProvider(directory: root, transcripts: DeepSeekTranscriptStore(root: root),
                                             readProcessStarts: { [harnessStarted] }, clock: { clock.now })
        func session() async throws -> LiveSession {
            let sessions = try await provider.fetchUsage(agents: [], historyHours: 24).sessions
            return try XCTUnwrap(sessions.first)
        }
        let first = try await session()
        XCTAssertNil(first.endedAt)
        XCTAssertEqual(first.observedAt, base, "the process check is the newest evidence")
        XCTAssertTrue(first.isLive(at: base), "a log quiet for 40 minutes does not make the turn out of date")
        clock.now = at(29)
        let between = try await session()
        XCTAssertEqual(between, first, "a read between two checks finds no new evidence")
        clock.now = at(30)
        let rechecked = try await session()
        XCTAssertEqual(rechecked.observedAt, at(30))
        XCTAssertTrue(rechecked.isLive(at: at(30)))
    }

    // MARK: Evidence

    /// A session is dated by the newest evidence its source holds, which reading an unchanged log again does not move:
    /// two passes over the same logs give the same sessions, in flight or not, and a session in flight stays vouched for
    /// from its log's last line.
    func testTwoPassesOverUnchangedLogsGiveTheSameSessions() async throws {
        let claudeRoot = try directory().appendingPathComponent("projects", isDirectory: true)
        func claudeLine(_ session: String, _ type: String, _ message: String, at offset: TimeInterval) -> String {
            #"{"sessionId":"\#(session)","cwd":"/p","type":"\#(type)","message":\#(message),"timestamp":"\#(stamp(offset))"}"#
        }
        func prompt(_ session: String, at offset: TimeInterval) -> String {
            claudeLine(session, "user", #"{"role":"user","content":"Build it"}"#, at: offset)
        }
        func assistant(_ session: String, stop: String, at offset: TimeInterval) -> String {
            claudeLine(session, "assistant", #"{"id":"m\#(Int(offset))","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"…"}],"stop_reason":"\#(stop)","usage":{"input_tokens":1,"output_tokens":1}}"#,
                       at: offset)
        }
        try write([prompt("idle", at: -900), assistant("idle", stop: "end_turn", at: -890)],
                  to: claudeRoot.appendingPathComponent("-p/idle.jsonl"), modified: at(-890))
        try write([prompt("busy", at: -300), assistant("busy", stop: "tool_use", at: -240)],
                  to: claudeRoot.appendingPathComponent("-p/busy.jsonl"), modified: at(-240))
        let codexRoot = try directory()
        try write(rolloutLines([(codexStart("t1"), -900), (["type": "task_complete", "turn_id": "t1"], -890)]),
                  to: codexRoot.appendingPathComponent("rollout-idle.jsonl"), modified: at(-890))
        let clock = Clock(base)
        let claude = ClaudeCodeProvider(engine: nil, transcripts: ClaudeTranscriptStore(roots: [claudeRoot]), history: QuotaHistoryStore(),
                                        clock: { clock.now })
        let codex = CodexUsageProvider(readLimits: { throw UsageProviderError("signed out") },
                                       transcripts: CodexTranscriptStore(roots: [codexRoot]), history: QuotaHistoryStore(), clock: { clock.now })
        let claudeBefore = try await claude.fetchUsage(agents: [], historyHours: 24).sessions
        let codexBefore = try await codex.fetchUsage(agents: [], historyHours: 24).sessions
        XCTAssertEqual(claudeBefore.map(\.id), ["busy", "idle"])
        XCTAssertEqual(claudeBefore.map(\.observedAt), [at(-240), at(-890)], "each is dated by its log's last line")
        XCTAssertEqual(codexBefore.map(\.observedAt), [at(-890)])
        clock.now = at(600)
        let claudeAfter = try await claude.fetchUsage(agents: [], historyHours: 24).sessions
        let codexAfter = try await codex.fetchUsage(agents: [], historyHours: 24).sessions
        XCTAssertEqual(claudeAfter, claudeBefore, "ten minutes on, unchanged logs give the same sessions")
        XCTAssertEqual(codexAfter, codexBefore)
        XCTAssertTrue(try XCTUnwrap(claudeAfter.first).isLive(at: clock.now), "a tool call keeps its session vouched for")
        XCTAssertFalse(try XCTUnwrap(claudeAfter.first).isLive(at: at(1560)), "for half an hour after the log's last line")
    }

    // MARK: Clients whose logs and Stop hooks report turns

    private func turn(_ state: SessionTurn.State, observed offset: TimeInterval, id: String = "t", provider: String = "Grok",
                      session: String = "grok:s") -> SessionTurn {
        SessionTurn(provider: provider, sessionID: session, turnID: id, state: state, startedAtMs: ms(offset - 60), observedAtMs: ms(offset))
    }

    private func grok(_ turns: [SessionTurn], lastActivity: TimeInterval = -5) -> ProviderSession {
        ProviderSession(id: "grok:s", title: "Task", client: "Grok CLI", startedAt: at(min(-3600, lastActivity)), lastActivity: at(lastActivity),
                        turns: turns)
    }

    /// A read at `base` of these sessions, with Stop hooks that fired at `stops`.
    private func additional(_ sessions: [ProviderSession], stops: [TimeInterval] = []) async throws -> UsageReport {
        let now = base, hooks = stops.map {
            SessionCompletion(sessionID: "grok:s", vendor: "Grok", turnID: "stop-\($0)", task: "Task", model: "grok-test", startedAt: nil,
                              completedAt: at($0))
        }
        return try await AdditionalUsageProvider(source: .grok, readQuota: { ProviderQuota() }, readSessions: { _ in ProviderSessions(sessions: sessions) },
                                                 history: QuotaHistoryStore(), readCompletions: { _ in hooks }, clock: { now })
            .fetchUsage(agents: [], historyHours: 24)
    }

    func testAnAdditionalClientSessionFollowsItsLatestObservedTurn() async throws {
        let cases: [(name: String, turns: [SessionTurn], live: Bool)] = [
            ("the running turn observed last", [turn(.running, observed: -10, id: "a"), turn(.completed, observed: -20, id: "b")], true),
            ("the finished turn observed last", [turn(.completed, observed: -10, id: "a"), turn(.running, observed: -20, id: "b")], false),
            ("a running turn tied with a later-listed one", [turn(.running, observed: -10, id: "a"), turn(.completed, observed: -10, id: "b")], true),
            ("a running turn tied with an earlier-listed one", [turn(.completed, observed: -10, id: "a"), turn(.running, observed: -10, id: "b")], false),
            ("a running turn quiet for 1799.999 s", [turn(.running, observed: -1799.999)], true),
            ("a running turn quiet for 1800 s", [turn(.running, observed: -1800)], false),
            // A turn waiting for approval is in flight as a running one is, until it too is abandoned.
            ("a turn waiting for approval", [turn(.waitingForApproval, observed: -10)], true),
            ("a turn waiting for approval quiet for 1800 s", [turn(.waitingForApproval, observed: -1800)], false),
            ("no turn", [], false),
        ]
        for item in cases {
            let report = try await additional([grok(item.turns)])
            XCTAssertEqual(report.sessions.map(\.endedAt), [item.live ? nil : at(-5)], item.name)
            XCTAssertEqual(report.turns, item.turns, "\(item.name): the turns are reported as the log left them")
        }
        let justNow = try await additional([grok([], lastActivity: 0)])
        XCTAssertEqual(justNow.sessions.map(\.endedAt), [base], "without a turn a session is never in flight, however recent")
    }

    func testAStopHookAtOrAfterARunningTurnsObservationCompletesIt() async throws {
        let cases: [(stop: TimeInterval, state: SessionTurn.State, observed: Int64)] = [
            (-60.001, .running, ms(-60)), (-60, .completed, ms(-60)), (-59.999, .completed, ms(-59.999)),
        ]
        for item in cases {
            let report = try await additional([grok([turn(.running, observed: -60)])], stops: [item.stop])
            XCTAssertEqual(report.turns.map(\.state), [item.state], "stop at \(item.stop)")
            XCTAssertEqual(report.turns.map(\.observedAtMs), [item.observed], "stop at \(item.stop)")
            XCTAssertEqual(report.sessions.map(\.isLive), [item.state == .running], "stop at \(item.stop)")
            XCTAssertEqual(report.completions.count, 1)
        }
        // Every running turn it follows, not only the newest, at the session's latest stop; the newest turn is chosen after.
        let two = [turn(.running, observed: -120, id: "a"), turn(.running, observed: -30, id: "b")]
        let between = try await additional([grok(two)], stops: [-60])
        XCTAssertEqual(between.turns.map(\.state), [.completed, .running])
        XCTAssertEqual(between.turns.map(\.observedAtMs), [ms(-60), ms(-30)])
        XCTAssertEqual(between.sessions.map(\.isLive), [true])
        let after = try await additional([grok(two)], stops: [-100, -10])
        XCTAssertEqual(after.turns.map(\.state), [.completed, .completed])
        XCTAssertEqual(after.turns.map(\.observedAtMs), [ms(-10), ms(-10)], "an earlier stop of the same session is not used")
        XCTAssertEqual(after.sessions.map(\.isLive), [false])
        let finished = try await additional([grok([turn(.completed, observed: -60), turn(.waitingForApproval, observed: -50, id: "w")])], stops: [-10])
        XCTAssertEqual(finished.turns.map(\.state), [.completed, .completed])
        XCTAssertEqual(finished.turns.map(\.observedAtMs), [ms(-60), ms(-10)],
                       "a stop completes a turn waiting for approval as it does a running one, and leaves a finished turn alone")
    }

    /// Under every rule a turn waiting for approval is in flight as a running one is, and ends the same ways.
    func testEveryRuleCountsATurnWaitingForApprovalAsInFlight() {
        let waiting = turn(.waitingForApproval, observed: -10)
        // The rule, what the source read, and whether the session is still in flight half an hour after it was last heard.
        let rules: [(SessionPhase.SourceRule, SessionPhase.SourceEvidence, later: Bool)] = [
            (.transcript, .init(turn: waiting, lastWriteAt: at(-10)), false),
            (.rollout, .init(turn: waiting, lastWriteAt: at(-10)), false),
            // However quiet the log is, the process decides.
            (.process, .init(turn: waiting, lastWriteAt: at(-10), processOutlivesTurn: true), true),
            (.turns, .init(turn: waiting), false),
        ]
        for (rule, evidence, later) in rules {
            XCTAssertTrue(SessionPhase.read(evidence, rule: rule, at: base).inFlight, "\(rule)")
            XCTAssertEqual(SessionPhase.read(evidence, rule: rule, at: at(1790)).inFlight, later, "\(rule) half an hour later")
        }
        XCTAssertFalse(SessionPhase.read(.init(turn: waiting, lastWriteAt: at(-10), processOutlivesTurn: false), rule: .process, at: base).inFlight,
                       "a turn no process predates has lost its client")
        XCTAssertEqual(SessionPhase.lapsed(turn(.waitingForApproval, observed: -120), at: base).state, .ended, "a heartbeat that stopped ends it")
        XCTAssertEqual(SessionPhase.lapsed(turn(.waitingForApproval, observed: -119.999), at: base).state, .waitingForApproval)
    }

    func testAnAdditionalClientSessionThatEndedBeforeTheReadWindowIsDropped() async throws {
        let window = -AlertPolicy.insightsLookback
        let kept = try await additional([grok([], lastActivity: window)])
        XCTAssertEqual(kept.sessions.count, 1)
        let dropped = try await additional([grok([], lastActivity: window - 0.001)])
        XCTAssertEqual(dropped.sessions.count, 0)
    }

    func testACopilotPromptJoinsTheTurnWithin120SecondsOfItsLastObservation() async throws {
        let file = try directory().appendingPathComponent("session-state/s1/events.jsonl")
        func line(_ type: String, _ offset: TimeInterval, id: String, subagent: Bool = false, data: [String: Any] = [:]) -> String {
            var object: [String: Any] = ["type": type, "data": data, "id": id, "timestamp": stamp(offset)]
            if subagent { object["agentId"] = "sub" }
            return json(object)
        }
        func stop(_ reason: String, subagent: Bool = false) -> String {
            line("hook.start", -380, id: "h", subagent: subagent, data: ["hookType": "agentStop", "input": ["stopReason": reason]])
        }
        func copilot(_ id: String, _ state: SessionTurn.State, started: TimeInterval, observed: TimeInterval,
                     outcome: TurnOutcome? = nil) -> SessionTurn {
            SessionTurn(provider: "GitHub Copilot", sessionID: "copilot:s1", turnID: id, state: state, startedAtMs: ms(started), observedAtMs: ms(observed),
                        outcome: outcome)
        }
        // A prompt opens the turn at -990; the agent's loop last observed it at -980.
        let opening = [line("session.start", -1000, id: "e0", data: ["context": ["cwd": "/work"]]),
                       line("user.message", -990, id: "u1", data: ["content": "Fix the login test"]), line("assistant.turn_start", -980, id: "l1")]
        let cases: [(name: String, tail: [String], turns: [SessionTurn])] = [
            ("a prompt 119.999 s later", [line("user.message", -860.001, id: "u2")], [copilot("u1", .running, started: -990, observed: -860.001)]),
            ("a prompt 120 s later", [line("user.message", -860, id: "u2")],
             [copilot("u1", .running, started: -990, observed: -980), copilot("u2", .running, started: -860, observed: -860)]),
            ("a sub-agent's prompt 119.999 s later", [line("user.message", -860.001, id: "p", subagent: true)],
             [copilot("u1", .running, started: -990, observed: -860.001)]),
            ("a sub-agent's prompt 120 s later", [line("user.message", -860, id: "p", subagent: true)],
             [copilot("u1", .running, started: -990, observed: -980)]),
            ("a sub-agent's turn end", [line("assistant.turn_end", -380, id: "l2", subagent: true)],
             [copilot("u1", .running, started: -990, observed: -380)]),
            ("the agent's own turn end", [line("assistant.turn_end", -380, id: "l2")], [copilot("u1", .running, started: -990, observed: -380)]),
            ("a sub-agent's stop and abort", [stop("end_turn", subagent: true), line("abort", -380, id: "a", subagent: true)],
             [copilot("u1", .running, started: -990, observed: -980)]),
            ("the agent's stop at the end of its turn", [stop("end_turn")],
             [copilot("u1", .completed, started: -990, observed: -380, outcome: .completed)]),
            ("the agent's stop for another reason", [stop("max_tokens")], [copilot("u1", .ended, started: -990, observed: -380)]),
            ("an abort", [line("abort", -380, id: "a")], [copilot("u1", .ended, started: -990, observed: -380, outcome: .interrupted)]),
            ("a shutdown", [line("session.shutdown", -380, id: "sd")], [copilot("u1", .ended, started: -990, observed: -380)]),
        ]
        for item in cases {
            try write(opening + item.tail, to: file, modified: base)
            XCTAssertEqual(try CopilotSessions.read(file).sessions.first?.turns, item.turns, item.name)
        }
        // The turn a late prompt left behind stays running in the report beside the newest one, which the session follows.
        try write(opening + [line("user.message", -860, id: "u2"), stop("end_turn")], to: file, modified: base)
        let session = try XCTUnwrap(CopilotSessions.read(file).sessions.first), now = base
        let report = try await AdditionalUsageProvider(source: .copilot, readQuota: { ProviderQuota() }, readSessions: { _ in ProviderSessions(sessions: [session]) },
                                                       history: QuotaHistoryStore(), clock: { now }).fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.turns, [copilot("u1", .running, started: -990, observed: -980),
                                      copilot("u2", .completed, started: -860, observed: -380, outcome: .completed)])
        XCTAssertEqual(report.sessions.map(\.isLive), [false])
    }

    // MARK: Open agents

    private func openAgent(_ client: OpenAgentSource, _ turns: [SessionTurn]) -> OpenAgentSession {
        OpenAgentSession(id: "\(client.rawValue):s", client: client, title: "Task", path: "", start: at(-3600), end: at(-5), turns: turns)
    }

    private func openAgents(_ sessions: [OpenAgentSession]) async throws -> UsageReport {
        let now = base
        return try await OpenAgentUsageProvider(credentials: { [] }, sessions: { _ in .init(sessions: sessions) }, fetchQuota: { _, _ in ProviderQuota() },
                                                history: QuotaHistoryStore(), clock: { now }).fetchUsage(agents: [], historyHours: 24)
    }

    func testPiEndsATurnWhoseHeartbeatStoppedAndKimiAbandonsOneAfter30Minutes() async throws {
        func pi(observed offset: TimeInterval, id: String = "t") -> SessionTurn { turn(.running, observed: offset, id: id, provider: "Pi", session: "pi:s") }
        func kimi(_ state: SessionTurn.State, observed offset: TimeInterval, id: String = "t") -> SessionTurn {
            turn(state, observed: offset, id: id, provider: "Kimi", session: "kimi:s")
        }
        let cases: [(name: String, session: OpenAgentSession, live: Bool, states: [SessionTurn.State])] = [
            ("Pi beat 119.999 s ago", openAgent(.pi, [pi(observed: -119.999)]), true, [.running]),
            ("Pi beat 120 s ago", openAgent(.pi, [pi(observed: -120)]), false, [.ended]),
            ("an older Pi turn that stopped beating", openAgent(.pi, [pi(observed: -200, id: "a"), pi(observed: -10, id: "b")]), true, [.ended, .running]),
            ("Kimi observed 120 s ago", openAgent(.kimi, [kimi(.running, observed: -120)]), true, [.running]),
            ("Kimi observed 1799.999 s ago", openAgent(.kimi, [kimi(.running, observed: -1799.999)]), true, [.running]),
            ("Kimi observed 1800 s ago", openAgent(.kimi, [kimi(.running, observed: -1800)]), false, [.running]),
            ("a running Kimi turn listed before a finished one",
             openAgent(.kimi, [kimi(.running, observed: -10, id: "a"), kimi(.completed, observed: -20, id: "b")]), false, [.running, .completed]),
        ]
        for item in cases {
            let report = try await openAgents([item.session])
            XCTAssertEqual(report.sessions.map(\.endedAt), [item.live ? nil : at(-5)], item.name)
            XCTAssertEqual(report.turns.map(\.state), item.states, item.name)
            XCTAssertEqual(report.turns.map(\.observedAtMs), item.session.turns.map(\.observedAtMs), "\(item.name): an ended turn keeps its time")
        }
    }

    func testAnOpenCodeSessionIsNeverInFlight() async throws {
        let reply = try ProviderJSON.read(Data(#"{"role":"assistant","modelID":"m","providerID":"p","time":{"created":\#(ms(-1))},"tokens":{"input":1,"output":1}}"#.utf8))
        let session = try XCTUnwrap(OpenAgentParser.openCodeMessage(reply, id: "m", sessionID: "s", path: "/m.json"))
        let report = try await openAgents([session])
        XCTAssertEqual(report.sessions.map(\.endedAt), [at(-1)], "a reply a second ago")
        XCTAssertEqual(report.turns, [])
    }

    // MARK: Combined and retained reports

    /// A vendor whose reads return these reports in turn, and fail once they run out.
    private actor Reads: UsageProvider {
        private var reports: [UsageReport]
        init(_ reports: [UsageReport]) { self.reports = reports }
        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) throws -> UsageReport {
            guard !reports.isEmpty else { throw UsageProviderError("signed out") }
            return reports.removeFirst()
        }
    }

    private func session(_ id: String, started: TimeInterval, ended: TimeInterval? = nil, read: TimeInterval = 0) -> LiveSession {
        LiveSession(id: id, agentId: "\(id)-model", task: "Task", terminal: nil, startedAt: at(started), endedAt: ended.map(at), pctOfWindow: nil,
                    tokensIn: 1, tokensOut: 1, observedAt: at(read))
    }

    private func vendorReport(_ vendor: String, _ sessions: [LiveSession], at offset: TimeInterval = 0) -> UsageReport {
        UsageReport(generatedAt: at(offset), snapshots: [], sessions: sessions,
                    consumers: sessions.map { AgentDescriptor(id: $0.agentId, vendor: vendor, model: "Model", source: "", enabled: true) },
                    turns: sessions.map { SessionTurn(provider: vendor, sessionID: $0.id, turnID: "t", state: $0.isLive ? .running : .completed,
                                                      startedAtMs: RecordCoding.milliseconds($0.startedAt), observedAtMs: RecordCoding.milliseconds($0.observedAt)) })
    }

    func testCombinedAndRetainedReportsListSessionsInFlightFirst() async throws {
        let claude = [session("claude-ended", started: -600, ended: -10), session("claude-live", started: -9000, read: -7200)]
        let codex = [session("codex-ended", started: -900, ended: -100), session("codex-live", started: -60)]
        let order = ["codex-live", "claude-live", "claude-ended", "codex-ended"]
        let combined = CombinedUsageProvider([.init("Claude", Reads([vendorReport("Claude", claude), vendorReport("Claude", claude)])),
                                              .init("Codex", Reads([vendorReport("Codex", codex), vendorReport("Codex", codex)]))])
        let retained = RetainedUsageProvider(provider: combined)
        let first = try await retained.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(first.sessions.map(\.id), order, "in flight by start, then ended by end; a reading two hours old still counts as in flight")
        let second = try await retained.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(second.sessions.map(\.id), order)
    }

    func testAVendorThatIsNotReadAgainOrFailsKeepsItsSessionsAsLastRead() async throws {
        let before = vendorReport("Claude", [session("claude-live", started: -600, read: -60)], at: -60)
        let after = vendorReport("Claude", [session("claude-live", started: -600, read: 0)])
        let codex = vendorReport("Codex", [session("codex-live", started: -60, read: 0)])

        // A vendor left out of a pass keeps its last result, turns included, and its readings age.
        let partial = CombinedUsageProvider([.init("Claude", Reads([before, after])), .init("Codex", Reads([codex, codex]))])
        _ = try await partial.fetchUsage(agents: [], historyHours: 24, sources: nil)
        let codexOnly = try await partial.fetchUsage(agents: [], historyHours: 24, sources: ["Codex"])
        XCTAssertEqual(codexOnly.sessions.map(\.id), ["codex-live", "claude-live"])
        XCTAssertEqual(codexOnly.sessions.map(\.observedAt), [base, at(-60)])
        XCTAssertEqual(codexOnly.turns.map(\.sessionID), ["claude-live", "codex-live"])

        // A vendor whose read fails keeps its sessions from the last report it made, but not their turns.
        let failing = RetainedUsageProvider(provider: CombinedUsageProvider([.init("Claude", Reads([before])), .init("Codex", Reads([codex, codex]))]))
        _ = try await failing.fetchUsage(agents: [], historyHours: 24)
        let failed = try await failing.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(failed.quotaNotices?["Claude"], "signed out")
        XCTAssertEqual(failed.sessions.map(\.id), ["codex-live", "claude-live"])
        XCTAssertEqual(failed.sessions.map(\.observedAt), [base, at(-60)])
        XCTAssertEqual(failed.sessions.map(\.isLive), [true, true])
        XCTAssertEqual(failed.turns.map(\.sessionID), ["codex-live"])
    }

    func testTheRestartCopyKeepsSessionsWithoutTheirTurns() async throws {
        let file = try directory().appendingPathComponent("report.json")
        let completion = SessionCompletion(sessionID: "claude-live", vendor: "Claude", turnID: "t0", task: "Task", model: "Model", startedAt: nil,
                                           completedAt: at(-120))
        let live = vendorReport("Claude", [session("claude-live", started: -600, read: -30)], at: -30)
        let report = UsageReport(generatedAt: live.generatedAt, snapshots: [], sessions: live.sessions, consumers: live.consumers,
                                 completions: [completion], turns: live.turns)
        let saving = RetainedUsageProvider(provider: Reads([report]), cacheURL: file)
        let read = try await saving.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(read.turns.count, 1)
        XCTAssertEqual(read.completions, [completion])
        let restored = try XCTUnwrap(RetainedUsageProvider(provider: Reads([]), cacheURL: file).initialReport)
        XCTAssertEqual(restored.sessions, report.sessions, "an in-flight session comes back in flight, read when it was")
        XCTAssertEqual(restored.turns, [])
        XCTAssertEqual(restored.completions, [])
    }
}

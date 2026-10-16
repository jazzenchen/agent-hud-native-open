import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// What each mark of a logo queue hands its bot: its sessions' facts and the requests they wait on.
final class QueueMarkTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    private func facts(_ activity: SessionActivity?, outcome: TurnOutcome? = nil, limitedUntil: Date? = nil) -> SessionLiveFacts {
        SessionLiveFacts(sessionID: "s", vendor: "Claude", phase: SessionPhase(state: .running, since: at(-60), validUntil: nil),
                         activity: activity, turnID: "t", turnStartedAt: at(-60), outcome: outcome, endedAt: nil,
                         limitedUntil: limitedUntil, observedAt: at(-1), lastEventAt: at(-1), requests: [])
    }

    // MARK: Facts

    func testAShellCommandTurnsLongAfterTwentySecondsAndTheKindStaysOnceItCloses() {
        var activity = SessionActivity()
        activity.startTurn()
        XCTAssertEqual(facts(activity).look(at: now), .thinking, "no call yet: the model works on its own")
        activity.open("bash", work: .shell, at: at(-5))
        activity.settle()
        let open = facts(activity)
        XCTAssertEqual(open.look(at: now), .command)
        XCTAssertEqual(open.look(at: at(14.9)), .command)
        XCTAssertEqual(open.look(at: at(15)), .longCommand, "a shell command open for twenty seconds is a long one")
        XCTAssertEqual(open.nextChange(after: now), at(15))
        XCTAssertNil(open.nextChange(after: at(15)))
        XCTAssertTrue(open.hasOpenCall)

        activity.close("bash", at: at(20))
        activity.settle()
        XCTAssertEqual(facts(activity).look(at: at(60)), .command, "a closed call keeps its kind; turning it into thinking is the director's")
        XCTAssertEqual(facts(activity).toolSeenAt, at(20))
        XCTAssertFalse(facts(activity).hasOpenCall)

        activity.open("mcp", work: .command, at: at(30))
        activity.settle()
        XCTAssertEqual(facts(activity).look(at: at(120)), .command, "only a shell command runs long")
        activity.open("edit", work: .edit, at: at(31))
        activity.settle()
        XCTAssertEqual(facts(activity).look(at: at(32)), .edit)
        activity.open("task", work: .agents, at: at(33))
        activity.settle()
        XCTAssertEqual(facts(activity).look(at: at(34)), .edit, "sub-agents show beside the look, not as one")
        XCTAssertTrue(facts(activity).subagents)
        XCTAssertEqual(facts(nil).look(at: now), .plain, "a client that records no calls shows plain work")
        XCTAssertFalse(facts(nil).reportsTools)
    }

    func testCompactionRunsOutAfterFiveMinutesAndALimitAtItsReset() {
        var activity = SessionActivity()
        activity.compactingSince = at(-10)
        let compacting = facts(activity)
        XCTAssertTrue(compacting.compacting(at: now))
        XCTAssertFalse(compacting.compacting(at: at(290)))
        XCTAssertEqual(compacting.nextChange(after: now), at(290))

        let limited = facts(activity, outcome: .limited(resetsAt: at(600)), limitedUntil: at(600))
        XCTAssertTrue(limited.limited(at: now))
        XCTAssertFalse(limited.limited(at: at(600)))
        XCTAssertTrue(facts(nil, outcome: .limited(resetsAt: nil)).limited(at: at(86400)), "with no reset known, until the next prompt")
        XCTAssertFalse(facts(nil, outcome: .failed).limited(at: now))
        XCTAssertTrue(facts(nil, outcome: .failed).failed)
        XCTAssertFalse(facts(nil, outcome: .interrupted).failed, "a stop is never a failure")
    }

    // MARK: Marks

    private func agent(_ id: String, _ vendor: String, enabled: Bool = false) -> AgentDescriptor {
        AgentDescriptor(id: id, vendor: vendor, model: id, source: "", enabled: enabled)
    }

    private func session(_ id: String, _ agent: String, ended: TimeInterval? = nil, observed: TimeInterval,
                         activity: SessionActivity? = nil) -> LiveSession {
        LiveSession(id: id, agentId: agent, task: id, terminal: nil, startedAt: at(-3600), endedAt: ended.map(at), pctOfWindow: nil,
                    tokensIn: 1, tokensOut: 1, observedAt: at(observed), lastActivityAt: at(observed), activity: activity)
    }

    private func turn(_ session: String, _ provider: String, _ state: SessionTurn.State, started: TimeInterval, observed: TimeInterval,
                      outcome: TurnOutcome? = nil) -> SessionTurn {
        SessionTurn(provider: provider, sessionID: session, turnID: session + "-turn", state: state,
                    startedAtMs: RecordCoding.milliseconds(at(started)), observedAtMs: RecordCoding.milliseconds(at(observed)),
                    outcome: outcome)
    }

    private func request(_ id: String, session: String, tool: String, at offset: TimeInterval, question: Bool = false) -> PermissionRequest {
        PermissionRequest(id: id, source: .claude, sessionID: session, toolName: tool, summary: tool, detail: nil, cwd: nil,
                          questions: question ? [PermissionQuestion(question: "Which?", options: [.init(label: "A")])] : [],
                          at: at(offset))
    }

    func testEachMarkCarriesItsVendorsSessionsAndTheRequestsTheyWaitOn() throws {
        let claudeRow = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "Session", source: "", enabled: true)
        let consumers = [agent("claude-model:opus", "Claude"), agent("codex-model:gpt-5", "Codex"), agent("cursor-model:auto", "Cursor")]
        var working = SessionActivity()
        working.startTurn()
        working.open("toolu_1", work: .shell, at: at(-30))
        working.settle()
        var asking = SessionActivity()
        asking.open("call_q", work: .question, at: at(-8))
        let sessions = [
            session("working", "claude-model:opus", observed: -2, activity: working),
            session("limited", "claude-model:opus", ended: -300, observed: -300, activity: SessionActivity()),
            session("planning", "claude-model:opus", observed: -5, activity: SessionActivity()),
            session("stale", "claude-model:opus", observed: -2 * 3600, activity: SessionActivity()),
            session("codex", "codex-model:gpt-5", observed: -3, activity: asking),
            session("cursor", "cursor-model:auto", observed: -4),
            session("old", "cursor-model:auto", ended: -2 * 86400, observed: -2 * 86400),
        ]
        let turns = [
            turn("working", "claude", .running, started: -60, observed: -2),
            turn("limited", "claude", .ended, started: -400, observed: -300, outcome: .limited(resetsAt: nil)),
            turn("planning", "claude", .running, started: -50, observed: -5),
            turn("stale", "claude", .running, started: -2 * 3600 - 60, observed: -2 * 3600),
            turn("codex", "codex", .running, started: -20, observed: -3),
        ]
        let report = UsageReport(generatedAt: now, snapshots: [
            UsageSnapshot(agentId: claudeRow.id, remainingPct: 0, resetAt: at(1800), windowDuration: 5 * 3600, updatedAt: now),
        ], sessions: sessions, consumers: consumers, turns: turns)
        let approvals = [request("plan", session: "planning", tool: "ExitPlanMode", at: -4),
                         request("ask", session: "planning", tool: "AskUserQuestion", at: -6, question: true)]
        let view = ReportView(report: report, agents: [claudeRow], settings: Settings(), approvals: approvals,
                              waiting: ["cursor": at(-4)], now: now)

        let marks = view.queueMarks
        XCTAssertEqual(marks.map(\.key), ["Claude", "ChatGPT", "Cursor"], "Codex is drawn as OpenAI's mark")
        XCTAssertEqual(marks.map(\.vendor), ["Claude", "Codex", "Cursor"], "a mark is drawn as the first of its vendors")
        XCTAssertEqual(marks.map(\.isWorking), view.queueVendors.map(\.isWorking), "a mark works exactly when its vendor does")
        let claude = try XCTUnwrap(marks.first)
        XCTAssertEqual(claude.exhaustedUntil, at(1800), "the session window ran out")
        XCTAssertEqual(Set(claude.sessions.map(\.sessionID)), ["working", "limited", "planning", "stale"])

        let shell = try XCTUnwrap(claude.sessions.first { $0.sessionID == "working" })
        XCTAssertEqual(shell.look(at: now), .longCommand, "its shell command has been open for half a minute")
        XCTAssertEqual(shell.turnStartedAt, at(-60))
        XCTAssertEqual(shell.observedAt, at(-2))
        XCTAssertNil(shell.outcome)
        XCTAssertTrue(shell.isInFlight)

        let limited = try XCTUnwrap(claude.sessions.first { $0.sessionID == "limited" })
        XCTAssertEqual(limited.outcome, .limited(resetsAt: nil))
        XCTAssertEqual(limited.endedAt, at(-300))
        XCTAssertEqual(limited.limitedUntil, at(1800), "a limit without a reset of its own lifts with the window that ran out")
        XCTAssertTrue(limited.limited(at: now))
        XCTAssertFalse(limited.isInFlight)

        let stale = try XCTUnwrap(claude.sessions.first { $0.sessionID == "stale" })
        XCTAssertTrue(stale.isUnverified, "in flight by evidence two hours old is no news, never work")

        let planning = try XCTUnwrap(claude.sessions.first { $0.sessionID == "planning" })
        XCTAssertEqual(planning.phase.state, .waitingForApproval)
        XCTAssertEqual(planning.requests.map(\.kind), [.question, .plan], "waited longest first")
        XCTAssertEqual(claude.waitedLongest?.id, "ask")

        let codex = try XCTUnwrap(marks.first { $0.key == "ChatGPT" }?.sessions.first)
        XCTAssertEqual(codex.requests.map(\.kind), [.question], "Codex Desktop's own question call waits for an answer")
        XCTAssertEqual(codex.requests.first?.at, at(-8))
        let cursor = try XCTUnwrap(marks.last)
        XCTAssertEqual(cursor.sessions.map(\.sessionID), ["cursor"], "a session last heard of two days ago is not the mark's")
        XCTAssertEqual(cursor.requests.map(\.kind), [.permission], "a client that says it waits without a card waits for approval")
        XCTAssertEqual(cursor.sessions.first?.look(at: now), .plain)
    }

    func testALimitWithNoResetOfItsOwnLiftsOnceTheWindowHasReset() throws {
        let row = AgentDescriptor(id: "codex-session", vendor: "Codex", model: "Session", source: "", enabled: true)
        let consumer = agent("codex-model:gpt-5", "Codex")
        let sessions = [session("limited", "codex-model:gpt-5", ended: -300, observed: -300, activity: SessionActivity())]
        let turns = [turn("limited", "codex", .ended, started: -400, observed: -300, outcome: .limited(resetsAt: nil))]
        func limit(_ snapshot: UsageSnapshot?, at offset: TimeInterval) throws -> SessionLiveFacts {
            let report = UsageReport(generatedAt: at(offset), snapshots: snapshot.map { [$0] } ?? [], sessions: sessions,
                                     consumers: [consumer], turns: turns)
            let view = ReportView(report: report, agents: [row], settings: Settings(), now: at(offset))
            return try XCTUnwrap(view.queueMarks.first { $0.key == "ChatGPT" }?.sessions.first)
        }
        let window: TimeInterval = 5 * 3600
        let spent = UsageSnapshot(agentId: row.id, remainingPct: 0, resetAt: at(1800), windowDuration: window, updatedAt: now)
        let before = try limit(spent, at: 0)
        XCTAssertEqual(before.limitedUntil, at(1800), "it lifts with the window that ran out")
        XCTAssertTrue(before.limited(at: now))

        let pending = try limit(spent, at: 1805)
        XCTAssertFalse(pending.limited(at: at(1805)), "the window reset, though no reading has said so yet")
        let refilled = UsageSnapshot(agentId: row.id, remainingPct: 100, resetAt: at(1800 + window), windowDuration: window,
                                     updatedAt: at(1850))
        let after = try limit(refilled, at: 1900)
        XCTAssertEqual(after.limitedUntil, at(1800), "the window that began after the limit lifted it")
        XCTAssertFalse(after.limited(at: at(1900)))

        // A window that began before the turn ended says nothing of the limit, nor does a vendor with no window read.
        let running = UsageSnapshot(agentId: row.id, remainingPct: 40, resetAt: at(3600), windowDuration: window, updatedAt: now)
        XCTAssertTrue(try limit(running, at: 0).limited(at: now))
        XCTAssertTrue(try limit(nil, at: 0).limited(at: now), "with no reset known, until the next prompt")
    }

    func testGroksUsedUpWindowMarksEachOfItsClients() throws {
        // Grok's account windows are drawn as the clients that ran on them, each a mark of its own.
        let account = ProviderAccount.identified(provider: "Grok", user: "user", workspace: "team")!
        let row = AgentDescriptor(id: account.windowID("grok"), vendor: "Grok", model: "grok", source: "", enabled: true,
                                  account: account)
        let sessions = ["Grok CLI", "Grok Bot"].map { client in
            LiveSession(id: client, agentId: "grok-model:test", task: client, terminal: nil, startedAt: at(-60), pctOfWindow: nil,
                        tokensIn: 1, tokensOut: 1, client: client, observedAt: now)
        }
        let report = UsageReport(generatedAt: now, snapshots: [.init(agentId: row.id, remainingPct: 0, resetAt: at(1800), updatedAt: now)],
                                 sessions: sessions, accounts: ["Grok": [.init(account: account, observedAt: now)]])
        let marks = ReportView(report: report, agents: [row], settings: Settings(), now: now).queueMarks
        XCTAssertEqual(Set(marks.map(\.key)), ["Grok", "Grok Bot"])
        for mark in marks { XCTAssertEqual(mark.exhaustedUntil, at(1800), mark.key) }
    }

    func testANotificationOnlyWaitAndLiveStatusOff() throws {
        let consumer = agent("claude-model:opus", "Claude")
        // A turn waiting for approval with no request on the HUD: Claude Code's notification hook said so.
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session("s", "claude-model:opus", observed: -1)],
                                 consumers: [consumer], turns: [turn("s", "claude", .waitingForApproval, started: -60, observed: -7)])
        let view = ReportView(report: report, agents: [], settings: Settings(), now: now)
        let facts = try XCTUnwrap(view.queueMarks.first?.sessions.first)
        XCTAssertEqual(facts.requests, [AttentionRequest(id: "waiting:s", sessionID: "s", kind: .permission, at: at(-7))])

        var settings = Settings()
        settings.setLiveStatus(for: "Claude", enabled: false)
        let off = ReportView(report: report, agents: [], settings: settings, now: now)
        XCTAssertEqual(off.queueMarks.map(\.key), [], "a vendor whose live status is off has not run, as far as the queue says")
    }
}

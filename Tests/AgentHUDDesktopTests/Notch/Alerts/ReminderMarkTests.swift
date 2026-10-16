import AgentHUDCore
import XCTest
@testable import AgentHUDDesktop

/// Which bot, or which logo, each reminder card shows.
final class ReminderMarkTests: XCTestCase {
    private func request(_ tool: String, questions: [PermissionQuestion] = []) -> PermissionRequest {
        PermissionRequest(id: tool, source: .claude, sessionID: "reminder", toolName: tool, summary: tool, detail: nil,
                          cwd: nil, questions: questions, at: Date())
    }

    func testARequestsBotAsksForWhatItWaitsFor() {
        XCTAssertEqual(ReminderMark.request(request("Bash")), .bot(BotState(look: .permission)))
        XCTAssertEqual(ReminderMark.request(request("ExitPlanMode")), .bot(BotState(look: .plan)))
        let question = request("AskUserQuestion", questions: [PermissionQuestion(question: "Which?", header: "Pick",
                                                                                  options: [], multiSelect: false)])
        XCTAssertTrue(question.isQuestion)
        XCTAssertEqual(ReminderMark.request(question), .bot(BotState(look: .question)))
    }

    func testAReplyIsGreetedAndALongTurnsReplyDancedFor() {
        let end = Date()
        func reply(after seconds: TimeInterval?) -> SessionCompletion {
            SessionCompletion(sessionID: "s", vendor: "Claude", turnID: "t", task: "Task", model: "m",
                              startedAt: seconds.map { end.addingTimeInterval(-$0) }, completedAt: end)
        }
        XCTAssertEqual(ReminderMark.reply(reply(after: 83)), .bot(BotState(card: .done)))
        XCTAssertEqual(ReminderMark.reply(reply(after: 600)), .bot(BotState(card: .longDone)))
        XCTAssertEqual(ReminderMark.reply(reply(after: nil)), .bot(BotState(card: .done)), "a turn of unknown length")
    }

    func testAResetIsGoodNewsAndAWindowUsedUpWearsALimitsSign() {
        let agent = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "5h", source: "", enabled: true)
        XCTAssertEqual(ReminderMark.quota(.preview(.reset, agent: agent)), .bot(BotState(card: .reset)))
        XCTAssertEqual(ReminderMark.quota(.preview(.exhaustion, agent: agent)), .logo(nil), "running low is the plain logo")
        let now = Date()
        let empty = QuotaAlert(kind: .exhaustion, agent: agent,
                               snapshot: UsageSnapshot(agentId: agent.id, remainingPct: 0, resetAt: now.addingTimeInterval(3600),
                                                       updatedAt: now))
        XCTAssertEqual(ReminderMark.quota(empty), .logo(.hourglass))
        XCTAssertEqual(ReminderMark.credit, .bot(BotState(card: .reset)))
    }
}

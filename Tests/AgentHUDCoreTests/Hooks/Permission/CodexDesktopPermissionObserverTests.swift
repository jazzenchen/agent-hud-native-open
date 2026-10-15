#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

@MainActor
final class CodexDesktopPermissionObserverTests: XCTestCase {
    private func pending(threadID: String = "desktop-thread") throws -> CodexDesktopPermissions.Pending {
        let wire = JSONValue.object([
            "id": .integer(7), "method": .string("mcpServer/elicitation/request"),
            "params": .object([
                "threadId": .string(threadID), "mode": .string("form"),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"), "connector_id": .string("computer-use"),
                    "tool_name": .string("use_app"),
                    "tool_params": .object(["app": .string("app.agenthud")]),
                    "persist": .array([.string("session"), .string("always")]),
                ]),
            ]),
        ])
        return try XCTUnwrap(CodexDesktopPermissions.pending(.object(["requests": .array([wire])]),
            threadID: threadID, ownerClientID: "desktop-owner", now: Date()).first)
    }

    func testDismissalSurvivesFailedReadingAndEndsOnlyWithTheOwnersCompleteSnapshot() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let item = try pending()
        let waiting = CodexDesktopPermissions.Snapshot(pending: [item], observedThreadIDs: [item.threadID])
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request])
        queue.resolve(item.id, .leave)
        observer.reconcile(.init(pending: [], observedThreadIDs: []))
        observer.reconcile(waiting)
        XCTAssertTrue(queue.pending.isEmpty, "a disconnect cannot undo the user's dismissal")
        observer.reconcile(.init(pending: [], observedThreadIDs: [item.threadID]))
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request], "a subsequent native request can be displayed")
        observer.stop()
    }

    func testReadingOneThreadCannotSettleAnotherThreadsDismissal() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let first = try pending(threadID: "first"), second = try pending(threadID: "second")
        observer.reconcile(.init(pending: [first, second], observedThreadIDs: ["first", "second"]))
        queue.resolve(second.id, .leave)
        observer.reconcile(.init(pending: [], observedThreadIDs: ["first"]))
        observer.reconcile(.init(pending: [second], observedThreadIDs: ["second"]))
        XCTAssertTrue(queue.pending.isEmpty)
        observer.stop()
    }

    func testExternalAnswerWithdrawsTheCardAndStoppingResetsObservation() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let item = try pending()
        let waiting = CodexDesktopPermissions.Snapshot(pending: [item], observedThreadIDs: [item.threadID])
        observer.reconcile(waiting)
        observer.reconcile(.init(pending: [], observedThreadIDs: [item.threadID]))
        XCTAssertTrue(queue.pending.isEmpty)
        observer.reconcile(waiting)
        queue.resolve(item.id, .leave)
        observer.stop()
        observer.reconcile(waiting)
        XCTAssertEqual(queue.pending, [item.request])
        observer.stop()
    }

    func testLongThreadRestsTenTimesItsReadAndKeepsItsCardMeanwhile() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let long = try pending(threadID: "long"), ids: Set = ["long", "short"]
        XCTAssertEqual(observer.due(ids, at: 100), ids)
        observer.reconcile(.init(pending: [long], observedThreadIDs: ids, readSeconds: ["long": 0.7, "short": 0.1]), at: 100)
        XCTAssertEqual(observer.due(ids, at: 102), ["short"], "the next pass asks only the thread that answered quickly")
        observer.reconcile(.init(pending: [], observedThreadIDs: ["short"], readSeconds: ["short": 0.1]), resting: ["long"], at: 102)
        XCTAssertEqual(queue.pending, [long.request], "a thread that was not asked keeps its card")
        XCTAssertEqual(observer.due(ids, at: 106), ["short"])
        XCTAssertEqual(observer.due(ids, at: 107), ids)
        observer.reconcile(.init(pending: [], observedThreadIDs: ids, readSeconds: ["long": 0.7, "short": 0.1]), at: 107)
        XCTAssertTrue(queue.pending.isEmpty, "the next reading of the long thread withdraws what Desktop answered")
        XCTAssertEqual(observer.due(["short"], at: 107.5), [])
        XCTAssertEqual(observer.due(ids, at: 107.6), ["long"], "a thread that left the list starts without a rest")
        observer.stop()
    }

    func testFailedReadingHidesItsCardThroughTheRestThatFollows() throws {
        let queue = PermissionRequests(), observer = CodexDesktopPermissionObserver(requests: queue, client: .init())
        let item = try pending()
        observer.reconcile(.init(pending: [item], observedThreadIDs: [item.threadID], readSeconds: [item.threadID: 0.1]), at: 100)
        observer.reconcile(.init(pending: [], observedThreadIDs: [], readSeconds: [item.threadID: 3]), at: 102)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(observer.due([item.threadID], at: 131), [])
        observer.reconcile(.init(pending: [], observedThreadIDs: []), resting: [item.threadID], at: 104)
        XCTAssertTrue(queue.pending.isEmpty, "a rest carries over what was shown, and a failed reading showed nothing")
        XCTAssertEqual(observer.due([item.threadID], at: 132), [item.threadID])
        observer.stop()
    }

    func testOnlyLiveDesktopDestinationsIncludingChildrenAreObserved() {
        func session(_ id: String, live: Bool = true, target: Bool = true, children: [LiveSession]? = nil) -> LiveSession {
            .init(id: id, agentId: "codex", task: "Task", terminal: nil, startedAt: Date(),
                  endedAt: live ? nil : Date(), pctOfWindow: nil, tokensIn: 0, tokensOut: 0,
                  subagentSessions: children, navigationTarget: target ? .codexThread(id: id) : nil)
        }
        let parent = session("parent", children: [session("child"), session("ended-child", live: false)])
        XCTAssertEqual(CodexDesktopPermissionObserver.threadIDs(in: [parent, session("ended", live: false), session("cli", target: false)]),
                       ["parent", "child"])
    }
}
#endif

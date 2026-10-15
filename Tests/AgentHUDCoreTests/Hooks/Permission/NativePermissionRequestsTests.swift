#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class NativePermissionRequestsTests: XCTestCase {
    private func request(_ id: String = "antigravity-step", at: Date = Date()) -> PermissionRequest {
        .init(id: id, source: .antigravity, sessionID: "antigravity:conversation", toolName: "run_command",
              summary: "Allow rendering test stills?", detail: "node src/render.mjs stills --times 4.5,14,22.6",
              cwd: "/tmp/project", at: at)
    }

    func testNativeSnapshotTracksOnlyTheRequestsTheClientStillWaitsFor() async {
        let queue = PermissionRequests(), item = request()
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in XCTFail("reading must not answer") }
        queue.updateNativeRequests([request()], source: .antigravity) { _, _ in XCTFail("reading must not answer") }
        XCTAssertEqual(queue.pending, [item], "refreshing keeps one card and its original expiry")
        XCTAssertEqual(item.badge, "BASH")
        XCTAssertNil(item.alwaysAllow)
        queue.updateNativeRequests([], source: .antigravity) { _, _ in XCTFail("withdrawal must not answer") }
        XCTAssertTrue(queue.pending.isEmpty, "a choice made in Antigravity removes the card")
    }

    func testLeavingKeepsTheNativePromptUnansweredWithoutRepeatingTheCard() async {
        let queue = PermissionRequests(), item = request()
        var replies = 0
        let answer: @MainActor (PermissionRequest, PermissionDecision) async throws -> Void = { _, _ in replies += 1 }
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        queue.resolve(item.id, .leave)
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(replies, 0)
        queue.updateNativeRequests([], source: .antigravity, answer: answer)
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        XCTAssertEqual(queue.pending.count, 1, "a later native request can be shown")
    }

    func testAnExplicitAnswerIsSentOnce() async {
        let queue = PermissionRequests(), item = request()
        var decisions: [PermissionDecision] = []
        let answer: @MainActor (PermissionRequest, PermissionDecision) async throws -> Void = { _, decision in decisions.append(decision) }
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        queue.resolve(item.id, .deny)
        queue.resolve(item.id, .allow)
        for _ in 0..<20 where decisions.isEmpty { await Task.yield() }
        XCTAssertEqual(decisions, [.deny])
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        XCTAssertTrue(queue.pending.isEmpty, "a refresh while the client applies the answer does not repeat it")
    }

    func testEventStreamDismissalNeedsAnExplicitSettlementFromItsOwnSource() async {
        let queue = PermissionRequests(), item = request()
        let answer: @MainActor (PermissionRequest, PermissionDecision) async throws -> Void = { _, _ in XCTFail("reading must not answer") }
        queue.updateNativeRequests([item], source: .antigravity, preservesDismissals: true, answer: answer)
        queue.resolve(item.id, .leave)
        queue.updateNativeRequests([], source: .antigravity, preservesDismissals: true, answer: answer)
        queue.settleNativeRequest(item.id, source: .deepseek)
        queue.updateNativeRequests([item], source: .antigravity, preservesDismissals: true, answer: answer)
        XCTAssertTrue(queue.pending.isEmpty, "neither a disconnected stream nor another source settles the prompt")
        queue.settleNativeRequest(item.id, source: .antigravity)
        queue.updateNativeRequests([item], source: .antigravity, preservesDismissals: true, answer: answer)
        XCTAssertEqual(queue.pending, [item])
        queue.settleNativeRequest(item.id, source: .deepseek)
        XCTAssertEqual(queue.pending, [item], "settlement does not remove another source's visible card")
        queue.settleNativeRequest(item.id, source: .antigravity)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testFailedReadingPreservesDismissalUntilACompleteSnapshotSettlesIt() async {
        let queue = PermissionRequests(), item = request()
        let answer: @MainActor (PermissionRequest, PermissionDecision) async throws -> Void = { _, _ in XCTFail("reading must not answer") }
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        queue.resolve(item.id, .leave)
        queue.removeNativeRequests(source: .antigravity)
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        XCTAssertTrue(queue.pending.isEmpty, "a temporary read failure does not end the native prompt")
        queue.updateNativeRequests([], source: .antigravity, answer: answer)
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        XCTAssertEqual(queue.pending, [item])
        queue.removeNativeRequests(source: .antigravity)
        XCTAssertTrue(queue.pending.isEmpty)
        queue.updateNativeRequests([item], source: .antigravity, answer: answer)
        XCTAssertEqual(queue.pending, [item], "an unanswered visible card returns after a successful reading")
    }

    func testStoppingCancelsAnAnswerStillInPreflight() async {
        let queue = PermissionRequests(), item = request()
        var preflight: CheckedContinuation<Void, Never>?
        var writes = 0
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in
            await withCheckedContinuation { preflight = $0 }
            try Task.checkCancellation()
            writes += 1
        }
        queue.resolve(item.id, .allow)
        for _ in 0..<30 where preflight == nil { await Task.yield() }
        XCTAssertNotNil(preflight)
        queue.stopNativeRequests(source: .antigravity)
        preflight?.resume()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(writes, 0)
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in }
        XCTAssertEqual(queue.pending, [item], "starting again observes the prompt after cancelling the old answer")
        queue.stop()
    }

    func testFailedDeliveryCanBeRetriedWhileTheClientStillWaits() async {
        enum Failure: Error { case unavailable }
        let queue = PermissionRequests(), item = request()
        var attempted = false
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in
            attempted = true
            throw Failure.unavailable
        }
        queue.resolve(item.id, .allow)
        for _ in 0..<20 where !attempted { await Task.yield() }
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in }
        XCTAssertEqual(queue.pending.count, 1)
    }

    func testExpiryAndStoppingNeverAnswerTheNativeClient() async throws {
        let queue = PermissionRequests(), item = request(at: .distantPast)
        queue.holdTime = 0
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in XCTFail("expiry must not answer") }
        for _ in 0..<30 where !queue.pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(queue.pending.isEmpty)
        queue.updateNativeRequests([item], source: .antigravity) { _, _ in XCTFail("expiry must not answer") }
        XCTAssertTrue(queue.pending.isEmpty)
        queue.stop()
        queue.holdTime = 600
        queue.updateNativeRequests([request()], source: .antigravity) { _, _ in XCTFail("stopping must not answer") }
        XCTAssertEqual(queue.pending.count, 1, "starting again observes the native prompt anew")
        queue.stop()
        XCTAssertTrue(queue.pending.isEmpty)
    }
}
#endif

#if !os(Windows)
// Antigravity's native approvals are macOS-only, and the Windows compiler's solver cannot type-check these long test bodies yet.
import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

final class AntigravityPermissionsTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let endpoint = AntigravityService.Endpoint(pid: 42,
        base: URL(string: "https://127.0.0.1:42111/exa.language_server_pb.LanguageServerService/")!, token: "fixture-token")

    private func step(status: ProviderJSON = .string("CORTEX_STEP_STATUS_WAITING"),
                      target: String = "node src/render.mjs stills --times 4.5,14,22.6",
                      description: String = "Rendering test stills", action: String = "command", interaction: String = "permission") -> ProviderJSON {
        .object([
            "stepIndex": .integer(109),
            "step": .object([
                "status": status,
                "metadata": .object([
                    "createdAt": .string("2026-10-04T07:00:00Z"),
                    "toolCall": .object(["name": .string("run_command")]),
                    "sourceTrajectoryStepInfo": .object([
                        "cascadeId": .string("cascade"), "trajectoryId": .string("trajectory"), "stepIndex": .integer(109),
                    ]),
                ]),
                "requestedInteraction": .object([
                    interaction: .object([
                        "resource": .object(["action": .string(action), "target": .string(target)]),
                        "actionDescription": .string(description), "suggestedPersistPattern": .string("node src/render.mjs:*"),
                    ]),
                ]),
            ]),
        ])
    }

    private func summary(_ steps: [ProviderJSON]) -> ProviderJSON {
        .object(["trajectorySummaries": .object([
            "cascade": .object([
                "trajectoryId": .string("trajectory"), "waitingSteps": .array(steps),
                "workspaces": .array([.object(["workspaceFolderAbsoluteUri": .string("file:///Users/me/video")])]),
            ]),
        ])])
    }

    private func pending() throws -> AntigravityPermissions.Pending {
        try XCTUnwrap(AntigravityPermissions.pending(summary([step()]), endpoint: endpoint, now: now).first)
    }

    private actor Transport {
        var responses: [ProviderJSON]
        var requests: [URLRequest] = []
        init(_ responses: [ProviderJSON]) { self.responses = responses }
        func send(_ request: URLRequest) throws -> Data {
            requests.append(request)
            guard !responses.isEmpty else { throw ProviderFailure.format }
            return try JSONEncoder().encode(responses.removeFirst())
        }
    }

    private actor Gate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func client(_ transport: Transport, endpoints: [AntigravityService.Endpoint]? = nil) -> AntigravityPermissions {
        var client = AntigravityPermissions()
        let locations = endpoints ?? [endpoint], now = now
        client.discover = { _ in locations }
        client.clock = { now }
        client.http.send = { try await transport.send($0) }
        return client
    }

    func testOnlyActualWaitingPermissionsAppearAndKeepNativeContext() throws {
        let rows = try AntigravityPermissions.pending(summary([
            step(), step(status: .string("CORTEX_STEP_STATUS_DONE")), step(status: .integer(2)),
            step(interaction: "askQuestion"), step(interaction: "runCommand"),
        ]), endpoint: endpoint, now: now)
        let request = try XCTUnwrap(rows.first?.request)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(request.source, .antigravity)
        XCTAssertEqual(request.sessionID, "antigravity:cascade")
        XCTAssertEqual(request.toolName, "run_command")
        XCTAssertEqual(request.summary, "Rendering test stills")
        XCTAssertEqual(request.detail, "node src/render.mjs stills --times 4.5,14,22.6")
        XCTAssertEqual(request.cwd, "/Users/me/video")
        XCTAssertEqual(request.at, now, "an old tool creation time must not expire a newly discovered waiting permission")
        XCTAssertEqual(request.badge, "BASH")
        XCTAssertNil(request.alwaysAllow, "native one-time approvals offer no invented persistent rule")
        XCTAssertEqual(try AntigravityPermissions.pending(summary([step(status: .integer(9))]), endpoint: endpoint, now: now).count, 1)
    }

    func testPollingReadsSummariesOnlyAndWithdrawnRequestsDisappear() async throws {
        let transport = Transport([summary([step()]), .object([:])]), client = client(transport)
        let first = try await client.fetch(), withdrawn = try await client.fetch()
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(withdrawn.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["GetAllCascadeTrajectories", "GetAllCascadeTrajectories"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "fixture-token" })
        for request in requests {
            XCTAssertEqual(try ProviderJSON.read(XCTUnwrap(request.httpBody)), .object([:]))
        }
    }

    func testAPartialServiceFailureDoesNotPublishAnIncompleteSnapshot() async throws {
        let other = AntigravityService.Endpoint(pid: 43,
            base: URL(string: "https://127.0.0.1:42112/exa.language_server_pb.LanguageServerService/")!, token: "other-fixture-token")
        let transport = Transport([summary([step()])]), client = client(transport, endpoints: [endpoint, other])
        do {
            _ = try await client.fetch()
            XCTFail("a failed process must not make its waiting requests look withdrawn")
        } catch { XCTAssertTrue(error is AntigravityPermissions.Failure) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "both discovered services were queried")
    }

    func testARememberedServiceThatQuitIsLookedForAgainBeforeTheClientIsUnavailable() async throws {
        let quit = AntigravityService.Endpoint(pid: 43,
            base: URL(string: "https://127.0.0.1:42112/exa.language_server_pb.LanguageServerService/")!, token: "other-fixture-token")
        var client = client(Transport([]))
        let endpoint = endpoint, answer = try JSONEncoder().encode(summary([step()])), calls = Calls()
        // The remembered pair holds a service that has quit; the fresh search finds only the one still running.
        client.discover = { fresh in
            await calls.searched(fresh)
            return fresh ? [endpoint] : [endpoint, quit]
        }
        client.http.send = { request in
            await calls.requested(request.url?.port)
            guard request.url?.port == 42111 else { throw ProviderFailure.format }
            return answer
        }
        let fetched = try await client.fetch()
        XCTAssertEqual(fetched.count, 1, "the running service's request stays on screen when another service quits")
        let searches = await calls.searches, ports = await calls.ports
        XCTAssertEqual(searches, [false, true])
        XCTAssertEqual(ports, [42111, 42112, 42111])
    }

    private actor Calls {
        var searches: [Bool] = []
        var ports: [Int?] = []
        func searched(_ fresh: Bool) { searches.append(fresh) }
        func requested(_ port: Int?) { ports.append(port) }
    }

    func testEachProcessCanAnswerThroughAnAlternativeEndpoint() async throws {
        let alternative = AntigravityService.Endpoint(pid: endpoint.pid,
            base: URL(string: "https://127.0.0.1:42112/exa.language_server_pb.LanguageServerService/")!, token: endpoint.token)
        let other = AntigravityService.Endpoint(pid: 43,
            base: URL(string: "https://127.0.0.1:42113/exa.language_server_pb.LanguageServerService/")!, token: "other-fixture-token")
        let transport = Transport([.array([]), summary([step()]), .object([:])])
        let client = client(transport, endpoints: [endpoint, alternative, other])
        let fetched = try await client.fetch()
        XCTAssertEqual(fetched.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.compactMap { $0.url?.port }, [42111, 42112, 42113])
    }

    func testCancellingDiscoveryPreventsEveryNativeRequest() async throws {
        let entered = Gate(), resume = Gate(), transport = Transport([]), request = try pending()
        var client = client(transport)
        let endpoint = endpoint
        client.discover = { _ in
            await entered.open()
            await resume.wait()
            return [endpoint]
        }
        let cancellable = client
        let answer = Task { try await cancellable.resolve(.allow, for: request) }
        await entered.wait()
        answer.cancel()
        await resume.open()
        do {
            try await answer.value
            XCTFail("a stopped discovery must never continue to approval")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellingWhilePreflightIsReadingNeverSendsAnAnswer() async throws {
        let entered = Gate(), resume = Gate(), transport = Transport([summary([step()])]), request = try pending()
        var client = client(transport)
        client.http.send = { nativeRequest in
            if nativeRequest.url?.lastPathComponent == "GetAllCascadeTrajectories" {
                await entered.open()
                await resume.wait()
            }
            return try await transport.send(nativeRequest)
        }
        let cancellable = client
        let answer = Task { try await cancellable.resolve(.allow, for: request) }
        await entered.wait()
        answer.cancel()
        await resume.open()
        do {
            try await answer.value
            XCTFail("a stopped preflight must never send the approval")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["GetAllCascadeTrajectories"])
    }

    func testAllowAndDenyRecheckTheRequestThenUseOnlyOnceScope() async throws {
        for decision in [PermissionDecision.allow, .deny] {
            let transport = Transport([summary([step()]), .object([:])]), client = client(transport)
            try await client.resolve(decision, for: pending())
            let requests = await transport.requests
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["GetAllCascadeTrajectories", "HandleCascadeUserInteraction"])
            let body = try ProviderJSON.read(XCTUnwrap(requests.last?.httpBody))
            XCTAssertEqual(body, .object([
                "cascadeId": .string("cascade"),
                "interaction": .object([
                    "trajectoryId": .string("trajectory"), "stepIndex": .integer(109),
                    "permission": .object(["allow": .bool(decision == .allow), "scope": .string("PERMISSION_SCOPE_ONCE")]),
                ]),
            ]))
        }
    }

    func testLeavingOrUnsupportedDecisionsNeverMutateTheClient() async throws {
        let transport = Transport([]), client = client(transport), request = try pending()
        try await client.resolve(.leave, for: request)
        for decision in [PermissionDecision.allowAlways(.object([:])), .answer(["question": .init(custom: "answer")])] {
            do {
                try await client.resolve(decision, for: request)
                XCTFail("unsupported native decisions must be refused")
            } catch { XCTAssertTrue(error is AntigravityPermissions.Failure) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testWithdrawnCompletedOrChangedPermissionsAreNeverAnswered() async throws {
        for snapshot in [summary([]), summary([step(status: .string("CORTEX_STEP_STATUS_DONE"))]),
                         summary([step(target: "different command")]), summary([step(description: "Different action")]),
                         summary([step(action: "unsandboxed")])] {
            let transport = Transport([snapshot]), client = client(transport)
            do {
                try await client.resolve(.allow, for: pending())
                XCTFail("a stale permission must never be answered")
            } catch { XCTAssertTrue(error is AntigravityPermissions.Failure) }
            let requests = await transport.requests
            XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["GetAllCascadeTrajectories"])
        }
    }

    func testChangedApprovalSubjectAtTheSameStepGetsANewCardIdentity() throws {
        let original = try pending()
        for changed in [step(target: "different command"), step(description: "Different action"), step(action: "unsandboxed")] {
            let replacement = try XCTUnwrap(AntigravityPermissions.pending(summary([changed]), endpoint: endpoint, now: now).first)
            XCTAssertEqual(replacement.stepIndex, original.stepIndex)
            XCTAssertNotEqual(replacement.id, original.id, "a changed callback must never stay behind the previous card")
        }
        let polledAgain = try XCTUnwrap(AntigravityPermissions.pending(summary([step()]), endpoint: endpoint, now: now.addingTimeInterval(1)).first)
        XCTAssertEqual(polledAgain.id, original.id, "arrival time is not part of the native permission identity")
    }

    func testAReplacedServerCannotReceiveAnOldAnswer() async throws {
        for replacement in [AntigravityService.Endpoint(pid: 43, base: endpoint.base, token: endpoint.token),
                            AntigravityService.Endpoint(pid: endpoint.pid, base: endpoint.base, token: "new-fixture-token")] {
            let transport = Transport([]), client = client(transport, endpoints: [replacement])
            do {
                try await client.resolve(.allow, for: pending())
                XCTFail("the request belongs to the original service")
            } catch { XCTAssertTrue(error is AntigravityPermissions.Failure) }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testAnAlreadyAnsweredRequestCannotBeReplayed() async throws {
        let transport = Transport([summary([step()]), .object([:]), summary([])]), client = client(transport), request = try pending()
        try await client.resolve(.allow, for: request)
        do {
            try await client.resolve(.allow, for: request)
            XCTFail("the client has already consumed this permission")
        } catch { XCTAssertTrue(error is AntigravityPermissions.Failure) }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "HandleCascadeUserInteraction" }.count, 1)
    }

    /// Explicit read-only smoke check. No approval or rejection is ever sent by this probe.
    func testInstalledAntigravityPermissionsReadOnlyProbe() async throws {
        guard ProcessInfo.processInfo.environment["AGENT_HUD_PROBE_ANTIGRAVITY"] == "1" else {
            throw XCTSkip("Set AGENT_HUD_PROBE_ANTIGRAVITY=1 for a read-only native permission probe")
        }
        let pending = try await AntigravityPermissions().fetch()
        XCTAssertTrue(pending.allSatisfy { $0.request.source == .antigravity })
        print("Antigravity permission probe: waiting=\(pending.count)")
    }
}
#endif

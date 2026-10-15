#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// Captured questions from hosts exposing the `host.describe` / question event-stream API.
@MainActor
final class DeepSeekQuestionsTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let port = 3080

    /// A frame exactly as the host pushed it during a live session.
    private func frame(rpcID: String = "afbc4073-a9cb-44bf-9e0e-ec41948f8505",
                       session: String = "session-85d81a47-8249-4078-9d52-8f085746740a",
                       method: String = "question/requested",
                       payload: ProviderJSON? = nil) -> ProviderJSON {
        .object([
            "type": .string("server-request"), "rpcId": .string(rpcID),
            "method": .string(method),
            "payload": payload ?? .object([
                "type": .string("question/requested"), "sessionId": .string(session),
                "questions": .array([
                    .object([
                        "id": .string("choice"),
                        "question": .string("请选择一个选项：您希望如何继续？"),
                        "header": .string("选择"),
                        "options": .array([
                            .object(["description": .string("选择此项表示确认或继续。"), "label": .string("选项 A")]),
                            .object(["description": .string("选择此项表示跳过或取消。"), "label": .string("选项 B")]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private func describe(version: String = "0.0.1") -> ProviderJSON {
        .object(["type": .string("server-response"), "rpcId": .string("probe"),
                 "result": .object(["ok": .bool(true), "value": .object([
                    "version": .string(version), "provider": .string("glmtest"), "model": .string("glm-4.7"),
                    "cwd": .string("/Users/me/work"), "home": .string("/Users/me"),
                 ])])])
    }

    private func pending(rpcID: String = "afbc4073-a9cb-44bf-9e0e-ec41948f8505") throws -> DeepSeekQuestions.Pending {
        let frame = try XCTUnwrap(DeepSeekQuestions.Frame.read(frame(rpcID: rpcID)))
        return DeepSeekQuestions.pending(frame, port: port, now: now)
    }

    func testFrameReadsAQuestionAndRefusesWhatItCannotAnswerInFull() async throws {
        let read = try XCTUnwrap(DeepSeekQuestions.Frame.read(frame()))
        XCTAssertEqual(read.rpcID, "afbc4073-a9cb-44bf-9e0e-ec41948f8505")
        XCTAssertEqual(read.sessionID, "session-85d81a47-8249-4078-9d52-8f085746740a")
        XCTAssertEqual(read.questions.count, 1)
        XCTAssertEqual(read.questions[0].id, "choice")
        XCTAssertEqual(read.questions[0].answerKey, "choice")
        XCTAssertEqual(read.questions[0].question, "请选择一个选项：您希望如何继续？")
        XCTAssertEqual(read.questions[0].options.map(\.label), ["选项 A", "选项 B"])
        XCTAssertFalse(read.questions[0].multiSelect)

        // Not a question frame, no session, or an entry the HUD cannot read in full — each is left whole to the
        // host's own surface rather than half-read.
        XCTAssertNil(DeepSeekQuestions.Frame.read(frame(method: "session/prompt")))
        XCTAssertNil(DeepSeekQuestions.Frame.read(frame(payload: .object(["questions": .array([])]))))
        XCTAssertNil(DeepSeekQuestions.Frame.read(frame(session: "", payload: .object([
            "sessionId": .string(""), "questions": .array([.object(["question": .string("Q")])]),
        ]))))
        XCTAssertNil(DeepSeekQuestions.Frame.read(frame(payload: .object([
            "sessionId": .string("session-x"), "questions": .array([.object(["question": .string("Q")])]),
        ]))))
    }

    func testPendingCarriesTheHarnessContextOnTheRequest() async throws {
        let waiting = try pending()
        XCTAssertEqual(waiting.request.source, .deepseek)
        XCTAssertEqual(waiting.request.vendor, "DeepSeek")
        XCTAssertEqual(waiting.request.sessionID, "deepseek:session-85d81a47-8249-4078-9d52-8f085746740a")
        XCTAssertEqual(waiting.request.toolName, "AskUserQuestion")
        XCTAssertEqual(waiting.request.badge, "ASK")
        XCTAssertEqual(waiting.request.summary, "请选择一个选项：您希望如何继续？")
        XCTAssertEqual(waiting.request.id, "deepseek:\(port):afbc4073-a9cb-44bf-9e0e-ec41948f8505")
        XCTAssertEqual(waiting.rpcID, "afbc4073-a9cb-44bf-9e0e-ec41948f8505")
        XCTAssertEqual(waiting.port, port)
        XCTAssertEqual(waiting.request.at, now)
        XCTAssertNil(waiting.request.alwaysAllow, "Harness offers no rule suggestion, so there is no invented one")
    }

    /// An offered label goes back under `selected`, the user's own words under `custom`, a skip as an empty
    /// `selected` — the shapes the host accepted live — with every question in the batch covered.
    func testAnswerMapsChoicesCustomWordsAndSkips() async throws {
        let waiting = try pending()
        let question = waiting.request.questions[0].answerKey
        func entry(_ decision: PermissionDecision) throws -> (selected: [String], custom: String?) {
            let body = try DeepSeekQuestions.answer(decision, for: waiting)
            XCTAssertEqual(body["type"].stringValue, "client-response")
            XCTAssertEqual(body["rpcId"].stringValue, waiting.rpcID)
            let value = try XCTUnwrap(body["result"]["value"].objectValue)
            XCTAssertEqual(value["sessionId"]?.stringValue, "session-85d81a47-8249-4078-9d52-8f085746740a")
            let answer = try XCTUnwrap(value["answer"]?.objectValue)
            let answers = try XCTUnwrap(answer["answers"]?.arrayValue)
            XCTAssertEqual(answers.count, 1, "every question in the batch is covered")
            let entry = try XCTUnwrap(answers[0].objectValue)
            XCTAssertEqual(entry["id"]?.stringValue, "choice", "echo the caller's stable id, not the displayed text")
            return (entry["selected"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
                    entry["custom"]?.stringValue)
        }
        XCTAssertEqual(try entry(.answer([question: .init(selected: ["选项 A"])])).selected, ["选项 A"])
        XCTAssertEqual(try entry(.answer([question: .init(custom: "自己想想")])).custom, "自己想想")
        XCTAssertEqual(try entry(.answer([question: .init(selected: ["选项 A"])])).custom, nil)
        XCTAssertEqual(try entry(.answer([:])).selected, [], "a question left open is skipped")
        let choice = try DeepSeekQuestions.answer(.answer([question: .init(selected: ["选项 A"])]), for: waiting)
        let chosen = try XCTUnwrap(choice["result"]["value"]["answer"]["answers"].arrayValue?.first?.objectValue)
        XCTAssertNil(chosen["custom"], "optional strings are omitted; null fails Harness's output schema")
        let skipped = try DeepSeekQuestions.answer(.answer([:]), for: waiting)
        let skip = try XCTUnwrap(skipped["result"]["value"]["answer"]["answers"].arrayValue?.first?.objectValue)
        XCTAssertNil(skip["custom"], "skipping also omits optional custom text")
    }

    func testMultiSelectPreservesLabelsAndSupplementWithoutParsingText() async throws {
        let json = frame(payload: .object([
            "sessionId": .string("session-multi"),
            "questions": .array([
                .object([
                    "id": .string("both"), "question": .string("选哪些？"), "multiSelect": .bool(true),
                    "options": .array([
                        .object(["label": .string("甲, 乙")]), .object(["label": .string("丙")]),
                    ]),
                ]),
            ]),
        ]))
        let frame = try XCTUnwrap(DeepSeekQuestions.Frame.read(json))
        let waiting = DeepSeekQuestions.pending(frame, port: port, now: now)
        let question = waiting.request.questions[0].answerKey
        let body = try DeepSeekQuestions.answer(.answer([question: .init(selected: ["甲, 乙", "丙"], custom: "丙, 再想想")]), for: waiting)
        let answer = try XCTUnwrap(body["result"]["value"]["answer"].objectValue)
        let entry = try XCTUnwrap(try XCTUnwrap(answer["answers"]?.arrayValue)[0].objectValue)
        XCTAssertEqual(entry["id"]?.stringValue, "both")
        XCTAssertEqual(entry["selected"]?.arrayValue?.compactMap { $0.stringValue }, ["甲, 乙", "丙"])
        XCTAssertEqual(entry["custom"]?.stringValue, "丙, 再想想")
    }

    func testEqualQuestionTextKeepsIndependentAnswersByID() async throws {
        let questions: [ProviderJSON] = ["first", "second"].map { id in
            .object(["id": .string(id), "question": .string("Continue?"),
                     "options": .array([.object(["label": .string("Yes")]), .object(["label": .string("No")])])])
        }
        let json = frame(payload: .object(["sessionId": .string("session"), "questions": .array(questions)]))
        let read = try XCTUnwrap(DeepSeekQuestions.Frame.read(json))
        let waiting = DeepSeekQuestions.pending(read, port: port, now: now)
        let body = try DeepSeekQuestions.answer(.answer([
            "first": .init(selected: ["Yes"]), "second": .init(selected: ["No"]),
        ]), for: waiting)
        let answers = try XCTUnwrap(body["result"]["value"]["answer"]["answers"].arrayValue)
        XCTAssertEqual(answers.map { $0["id"].stringValue }, ["first", "second"])
        XCTAssertEqual(answers.map { $0["selected"].arrayValue?.first?.stringValue }, ["Yes", "No"])
    }

    func testFrameRequiresUniqueStableIDsAndLeavesUnreadPlansToHarness() async throws {
        func read(_ questions: [ProviderJSON]) -> DeepSeekQuestions.Frame? {
            DeepSeekQuestions.Frame.read(frame(payload: .object([
                "sessionId": .string("session"), "questions": .array(questions),
            ])))
        }
        let question: [String: ProviderJSON] = [
            "id": .string("choice"), "question": .string("Continue?"),
            "options": .array([.object(["label": .string("Yes")])]),
        ]
        var missing = question
        missing.removeValue(forKey: "id")
        XCTAssertNil(read([.object(missing)]))
        var empty = question
        empty["id"] = .string("  ")
        XCTAssertNil(read([.object(empty)]))
        XCTAssertNil(read([.object(question), .object(question)]))
        var plan = question
        plan["intent"] = .object(["kind": .string("plan-review"), "approve": .string("Yes")])
        XCTAssertNil(read([.object(plan)]), "a plan requires Harness's native review surface")
        var detail = question
        detail["detail"] = .string("# Complete plan\nChange production settings")
        XCTAssertNil(read([.object(detail)]), "supporting detail must not be dropped while offering a decision")
        XCTAssertNil(read([.object(question), .object(plan)]), "one unread question leaves the whole batch native")
    }

    func testAnswerRefusesWhatIsNotAnAnswer() async throws {
        let waiting = try pending()
        XCTAssertThrowsError(try DeepSeekQuestions.answer(.allow, for: waiting))
        XCTAssertThrowsError(try DeepSeekQuestions.answer(.deny, for: waiting))
    }

    func testReceiptsAcceptedAndRefused() async throws {
        XCTAssertTrue(DeepSeekQuestions.accepted(.object([
            "type": .string("server-response"), "rpcId": .string("x"),
            "result": .object(["ok": .bool(true), "value": .object(["accepted": .bool(true)])]),
        ])))
        XCTAssertFalse(DeepSeekQuestions.accepted(.object([
            "type": .string("server-response"), "rpcId": .string("x"),
            "result": .object(["ok": .bool(true), "value": .object(["accepted": .bool(false), "reason": .string("not-pending")])]),
        ])))
        XCTAssertEqual(try DeepSeekQuestions.receipt(.object([
            "type": .string("server-response"), "result": .object([
                "ok": .bool(true), "value": .object(["accepted": .bool(false), "reason": .string("not-pending")]),
            ]),
        ])), .notPending)
        XCTAssertThrowsError(try DeepSeekQuestions.receipt(.object([
            "type": .string("server-response"), "result": .object([
                "ok": .bool(true), "value": .object(["accepted": .bool(false), "reason": .string("invalid-answer")]),
            ]),
        ])), "an unknown rejection does not prove the question is settled")
        XCTAssertThrowsError(try DeepSeekQuestions.receipt(.object([
            "type": .string("server-response"), "result": .object(["ok": .bool(true), "value": .object([:])]),
        ])))
        XCTAssertThrowsError(try DeepSeekQuestions.receipt(.object([
            "type": .string("server-response"), "result": .object(["ok": .bool(false)]),
        ])))
    }

    /// A describe call decides the port is a Harness web host by its fields; a failure result or a foreign
    /// server is not.
    func testDescribeReadsTheHostAndRefusesTheRest() async throws {
        XCTAssertTrue(try DeepSeekQuestions.Endpoint.describe(describe()))
        XCTAssertThrowsError(try DeepSeekQuestions.Endpoint.describe(.object([
            "type": .string("server-response"), "rpcId": .string("probe"),
            "result": .object(["ok": .bool(false), "error": .string("NO_HANDLER")]),
        ])))
        // A server that answers but carries none of the host's fields is alive, and still not a question host.
        XCTAssertFalse(try DeepSeekQuestions.Endpoint.describe(.object([
            "type": .string("server-response"), "rpcId": .string("probe"),
            "result": .object(["ok": .bool(true), "value": .object(["detail": .string("a foreign server")])]),
        ])))
    }

    func testConfirmedHostProtocolSendsDescribeAndExactAnswer() async throws {
        let describeData = try JSONEncoder().encode(describe())
        var client = DeepSeekQuestions()
        client.http = ProviderHTTP(send: { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3080/api/host.describe")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try ProviderJSON.read(try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body["type"].stringValue, "client-request")
            XCTAssertEqual(body["method"].stringValue, "host.describe")
            XCTAssertEqual(body["payload"], .object([:]))
            return describeData
        })
        let confirmed = try await client.describe(port: port)
        XCTAssertTrue(confirmed)

        let waiting = try pending()
        let body = try DeepSeekQuestions.answer(.answer(["choice": .init(selected: ["选项 A"])]), for: waiting)
        let receiptData = try JSONEncoder().encode(ProviderJSON.object([
            "type": .string("server-response"), "rpcId": .string(waiting.rpcID),
            "result": .object(["ok": .bool(true), "value": .object(["accepted": .bool(true)])]),
        ]))
        client.http = ProviderHTTP(send: { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3080/api/respond")
            XCTAssertEqual(try ProviderJSON.read(try XCTUnwrap(request.httpBody)), body)
            return receiptData
        })
        let reply = try await client.send(body, port: port)
        XCTAssertEqual(try DeepSeekQuestions.receipt(reply), .accepted)
    }

    func testAuthenticatedIncompatibleHostIsNotConfirmed() async throws {
        var client = DeepSeekQuestions()
        client.http = ProviderHTTP(send: { _ in throw ProviderHTTPError(status: 401) })
        do {
            _ = try await client.describe(port: port)
            XCTFail("a host requiring a different authenticated API must stay native")
        } catch let error as ProviderHTTPError {
            XCTAssertEqual(error.status, 401)
        }
    }

    /// Discovery takes the web-profile processes, their named port or the default, and nothing else.
    @MainActor
    func testDiscoveryReadsWebProfileProcessesOnly() async throws {
        let command = "node /opt/homebrew/Cellar/node/26.0.0/bin/dsh --profile web --port 4599 --no-open"
        let inspector: @Sendable (String, [String]) async throws -> String = { _, _ in
            """
              101 /Applications/Safari.app/Contents/MacOS/Safari
              202 \(command)
              303 sh -c 'dsh --profile headless'
            """
        }
        let ports = await DeepSeekQuestionObserver.discoverPorts(inspect: inspector)
        XCTAssertEqual(ports, [4599])
        let withDefault = await DeepSeekQuestionObserver.discoverPorts(inspect: { _, _ in
            "  404 /usr/local/bin/dsh --profile web --no-open"
        })
        XCTAssertEqual(withDefault, [DeepSeekQuestionObserver.defaultPort])
        let nothing = await DeepSeekQuestionObserver.discoverPorts(inspect: { _, _ in "" })
        XCTAssertTrue(nothing.isEmpty)
        XCTAssertTrue(DeepSeekQuestionObserver.isHarness(command))
        XCTAssertFalse(DeepSeekQuestionObserver.isHarness("sh -c 'dsh --profile headless'"))
        XCTAssertFalse(DeepSeekQuestionObserver.isHarness("/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    /// A source the HUD can name everywhere it names clients: its vendor, its home under `$DSH_HOME`, and no hook.
    func testTheDeepseekSourceNamesTheClientWithoutInstallingAnything() async throws {
        let source = PermissionHooks.Source.deepseek
        XCTAssertEqual(source.vendor, "DeepSeek")
        XCTAssertFalse(source.usesHook)
        XCTAssertFalse(source.supportsPermissionUpdates)
        XCTAssertEqual(source.sessionID("session-1"), "deepseek:session-1")
        XCTAssertTrue(source.unanswerableTools.isEmpty)
        XCTAssertTrue(PermissionHooks.commands(in: [:], source: source).isEmpty)
        // A native source has no hook file to read and never counts as one the hook channel serves.
        XCTAssertFalse(PermissionHooks.isActive(source, home: URL(fileURLWithPath: "/tmp/nowhere-at-all")))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".dsh/sessions"), withIntermediateDirectories: true)
        XCTAssertTrue(source.isInstalled(home: home))
    }
}
#endif

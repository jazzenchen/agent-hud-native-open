#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import Foundation
import SQLite3
import XCTest
@testable import AgentHUDCore

final class TencentBuddyProviderTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1788800000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func json(_ text: String) throws -> ProviderJSON { try .read(Data(text.utf8)) }
    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func line(_ type: String, role: String? = "assistant", status: String? = "completed", id: String? = nil, message: String? = nil,
                      trace: String? = nil, ms: Int = 1788800000000, usage: String? = #"{"inputTokens":100,"outputTokens":10,"totalTokens":110,"inputTokensDetails":[{"cached_tokens":60}]}"#) -> String {
        let fields = [#""type":"\#(type)""#, role.map { #""role":"\#($0)""# }, status.map { #""status":"\#($0)""# }, id.map { #""id":"\#($0)""# },
                      #""timestamp":\#(ms),"sessionId":"s1","cwd":"/Users/alice/repo""#,
                      #""providerData":{"model":"glm-5.3","requestModelId":"auto""# + (message.map { #","messageId":"\#($0)""# } ?? "")
                        + (trace.map { #","traceId":"\#($0)""# } ?? "") + (usage.map { #","usage":\#($0)"# } ?? "") + "}"]
        return "{" + fields.compactMap { $0 }.joined(separator: ",") + "}"
    }

    func testFieldSetsMapToDisjointDimensions() async throws {
        let cases: [(String, [Int])] = [
            (#"{"input_tokens":24486,"output_tokens":3,"total_tokens":24489,"cache_read_input_tokens":14720}"#, [9766, 3, 14720]),
            (#"{"prompt_tokens":140732,"completion_tokens":635,"total_tokens":141367,"prompt_cache_hit_tokens":76032}"#, [64700, 635, 76032]),
            (#"{"inputTokens":21817,"outputTokens":425,"totalTokens":22242,"inputTokensDetails":[{"cached_tokens":12544}],"outputTokensDetails":[{"reasoning_tokens":355}]}"#, [9273, 425, 12544]),
            (#"{"prompt_tokens":3,"completion_tokens":2,"prompt_cache_hit_tokens":4,"prompt_cache_write_tokens":4,"completion_thinking_tokens":5}"#, [7, 7, 4]),
            (#"{"inputTokens":7,"outputTokens":2,"cacheTokens":10}"#, [7, 2, 10]),
            (#"{"inputTokens":100,"outputTokens":5,"cacheTokens":100,"cachedMissTokens":0}"#, [0, 5, 100]),
            (#"{"inputTokens":50,"outputTokens":5,"totalTokens":55,"cacheCreationInputTokens":20,"reasoningTokens":3}"#, [50, 5, 0])
        ]
        for (usage, expected) in cases {
            let tokens = try XCTUnwrap(TencentBuddySessions.tokens(json(usage)), usage)
            XCTAssertEqual([tokens.input, tokens.output, tokens.cache], expected, usage)
        }
        XCTAssertNil(try TencentBuddySessions.tokens(json(#"{"inputTokens":0,"outputTokens":0}"#)))
        XCTAssertThrowsError(try TencentBuddySessions.tokens(json(#"{"inputTokens":10,"outputTokens":5,"totalTokens":15,"cacheTokens":20}"#)))
        XCTAssertThrowsError(try TencentBuddySessions.tokens(json(#"{"inputTokens":-1,"outputTokens":5}"#)))
    }

    func testOnlyCompletedResponsesCountOncePerIdentity() async throws {
        let url = try directory().appendingPathComponent("projects/repo/s1.jsonl")
        try write([
            line("message", role: "user", status: nil, usage: nil),
            line("message", status: "in_progress", message: "streaming"),
            line("message", message: "m1", usage: #"{"inputTokens":100,"outputTokens":4,"totalTokens":104}"#),
            line("function_call", role: nil, status: nil, message: "m1", trace: "t1", ms: 1788800001000),
            line("function_call", role: nil, status: nil, trace: "t2"),
            line("function_call", role: nil, status: nil, id: "call-1"),
            line("function_call", role: nil, status: nil, id: "call-2"),
            line("function_call", role: nil, status: nil),
            line("function_call", role: nil, status: nil, message: "untimed", ms: 0)
        ], to: url)
        let result = try TencentBuddySessions.read(url, source: .codebuddy)
        XCTAssertNotNil(result.notice, "A usage line without a time is excluded visibly")
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(session.id, "codebuddy:s1")
        XCTAssertEqual(session.title, "repo")
        XCTAssertEqual(session.client, "CodeBuddy Code")
        XCTAssertEqual(Set(session.events.map(\.id)), ["message:m1", "trace:t2", "s1:item:call-1", "s1:item:call-2", "s1:s1:line-8"])
        let merged = try XCTUnwrap(session.events.first { $0.id == "message:m1" })
        XCTAssertEqual([merged.input, merged.output, merged.cacheRead], [40, 10, 60], "The larger observation of one response wins")
        XCTAssertEqual(merged.model, "glm-5.3")
        XCTAssertTrue(session.events.filter { $0.id != "message:m1" }.allSatisfy { $0.input == 40 && $0.output == 10 }, "Equal distinct requests are kept")
    }

    func testEngineTitlesAndWorkBuddyNamesReplaceTheFolderName() async throws {
        let home = try directory()
        let titled = [line("message", message: "m1"), #"{"type":"topic","id":"t1","topic":"Refactor the parser"}"#,
                      #"{"type":"ai-title","id":"a1","aiTitle":"Parser refactor","sessionId":"s1"}"#,
                      #"{"type":"ai-title","id":"a2","aiTitle":"(No content)","sessionId":"s1"}"#]
        let url = home.appendingPathComponent(".codebuddy/projects/repo/s1.jsonl")
        try write(titled, to: url)
        XCTAssertEqual(try TencentBuddySessions.read(url, source: .codebuddy).sessions.first?.title, "Parser refactor",
                       "a generated title beats the topic, and a placeholder is passed over")
        try write(titled + [#"{"type":"custom-title","id":"c1","customTitle":"My parser","sessionId":"s1"}"#,
                            #"{"type":"ai-title","id":"a3","aiTitle":"Later title","sessionId":"s1"}"#], to: url)
        XCTAssertEqual(try TencentBuddySessions.read(url, source: .codebuddy).sessions.first?.title, "My parser", "the name the user gave wins")

        // WorkBuddy's app keeps names, a rename from its sidebar included, in its database beside the transcripts.
        try write(titled, to: home.appendingPathComponent(".workbuddy/projects/repo/s1.jsonl"))
        try write([line("message", message: "m2").replacingOccurrences(of: #""sessionId":"s1""#, with: #""sessionId":"s2""#)],
                  to: home.appendingPathComponent(".workbuddy/projects/repo/s2.jsonl"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent(".workbuddy/workbuddy.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, custom_title TEXT, title TEXT);
            INSERT INTO sessions VALUES ('s1', '/Users/alice/repo', 'Renamed in the sidebar', 'Parser refactor'), ('s2', '/Users/alice/repo', NULL, 'Generated by the app');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let result = await AdditionalLocalStore(source: .workbuddy, roots: WorkBuddySessions.roots(home: home, environment: [:]))
            .index(since: now.addingTimeInterval(-86400 * 365))
        XCTAssertEqual(result.sessions.map(\.title), ["Renamed in the sidebar", "Generated by the app"])
    }

    func testCodeBuddyAndWorkBuddyStaySeparateAndSubagentsJoinTheirParent() async throws {
        let home = try directory()
        let lines = [line("message", message: "m1")]
        for folder in [".codebuddy", ".workbuddy"] {
            try write(lines, to: home.appendingPathComponent("\(folder)/projects/repo/s1.jsonl"))
            try write([line("function_call", role: nil, status: nil, message: "sub", ms: 1788800005000)],
                      to: home.appendingPathComponent("\(folder)/projects/repo/s1/subagents/agent-1.jsonl"))
            try write([line("message", message: "ignored")], to: home.appendingPathComponent("\(folder)/projects/repo/s1/tool-results/ignored.jsonl"))
        }
        let custom = try directory()
        XCTAssertEqual(CodeBuddySessions.roots(home: home, environment: ["CODEBUDDY_CONFIG_DIR": custom.path]).map(\.path), [custom.appendingPathComponent("projects").path])
        var ids: [String] = []
        for source in [AdditionalSource.codebuddy, .workbuddy] {
            let roots = try XCTUnwrap(source.layout).roots(home: home, environment: [:])
            let result = await AdditionalLocalStore(source: source, roots: roots).index(since: now.addingTimeInterval(-86400 * 365))
            XCTAssertNil(result.notice)
            let session = try XCTUnwrap(result.sessions.first)
            XCTAssertEqual(result.sessions.count, 1)
            XCTAssertEqual(session.title, "repo")
            XCTAssertEqual(session.path?.hasSuffix("repo/s1.jsonl"), true)
            XCTAssertEqual(session.lastActivity, Date(timeIntervalSince1970: 1788800005))
            XCTAssertEqual(session.events.count, 2)
            ids += [session.id] + session.events.compactMap { $0.usage(source: source).eventID } + session.events.map { $0.usage(source: source).agentId }
        }
        XCTAssertEqual(Set(ids), ["codebuddy:s1", "codebuddy:message:m1", "codebuddy:message:sub", "codebuddy-model:glm-5.3",
                                  "workbuddy:s1", "workbuddy:message:m1", "workbuddy:message:sub", "workbuddy-model:glm-5.3"])
    }

    func testStopHookUsesTranscriptTailOrCallbackTime() async throws {
        let transcript = try directory().appendingPathComponent("s1.jsonl")
        try write([line("message", message: "earlier"), line("message", message: "final"), line("function_call", role: nil, status: nil, message: "tool")], to: transcript)
        var payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1", "transcript_path": transcript.path, "cwd": "/Users/alice/repo", "stop_hook_active": false]
        func completion() throws -> SessionCompletion? {
            try CompletionHooks.completion(source: .codebuddy, payload: .read(JSONSerialization.data(withJSONObject: payload)), now: now)
        }
        let finished = try XCTUnwrap(completion())
        XCTAssertEqual(finished.sessionID, "codebuddy:s1")
        XCTAssertEqual(finished.id, SessionCompletion(sessionID: "codebuddy:s1", vendor: "CodeBuddy", turnID: "final", task: "", model: "", startedAt: nil, completedAt: now).id)
        XCTAssertEqual(finished.task, "CodeBuddy · repo")
        XCTAssertEqual(finished.model, "glm-5.3")
        try write([line("message", message: "final"), line("message", role: "user", status: nil, usage: nil)], to: transcript)
        let pending = try XCTUnwrap(completion(), "The new turn's answer is not written yet")
        XCTAssertEqual(pending.id, SessionCompletion(sessionID: "codebuddy:s1", vendor: "CodeBuddy", turnID: "stop-1788800000000", task: "", model: "", startedAt: nil, completedAt: now).id)
        XCTAssertEqual(pending.model, "CodeBuddy")
        payload["transcript_path"] = transcript.appendingPathExtension("missing").path
        XCTAssertEqual(try completion()?.id, pending.id)
        for event in ["StopFailure", "SubagentStop", "SessionEnd"] {
            payload["hook_event_name"] = event
            XCTAssertNil(try completion())
        }
        payload["hook_event_name"] = "Stop"; payload["session_id"] = ""
        XCTAssertNil(try completion())
    }
}
#endif

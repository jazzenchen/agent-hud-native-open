import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

final class CopilotProviderTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1788800000)
    private func json(_ text: String) throws -> ProviderJSON { try .read(Data(text.utf8)) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ url: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var values: [String] { lock.withLock { names } }
        func record(_ name: String) { lock.withLock { names.append(name) } }
    }

    @MainActor
    func testQuotaSettingDefaultsOffAndIsReadThroughTheSettingsStore() async throws {
        XCTAssertFalse(Settings().readCopilotQuota)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(#"{"glowRange":12}"#.utf8)).readCopilotQuota)
        let enabled = Settings().with { $0.readCopilotQuota = true }
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(enabled)), enabled)
        let suite = "CopilotProviderTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(enabled), forKey: SettingsStore.Keys.settings)
        let settings = SettingsStore(defaults: defaults)
        let consented = CopilotClient.consent(in: settings)
        let saved = await consented()
        XCTAssertTrue(saved, "consent saved in the settings is kept")
        settings.update { $0.readCopilotQuota = false }
        let withdrawn = await consented()
        XCTAssertFalse(withdrawn, "the switch counts from the moment it moves")
    }

    func testQuotaWithoutConsentTouchesNoCredentialOrNetwork() async throws {
        let calls = Calls()
        let http = ProviderHTTP(send: { _ in calls.record("request"); return Data("{}".utf8) })
        let off = try await CopilotClient(enabled: { false }, token: { calls.record("token"); return "fixture" }, http: http).fetch()
        XCTAssertTrue(off.windows.isEmpty)
        XCTAssertNil(off.notice)
        XCTAssertTrue(off.forgetAccounts, "withdrawn consent forgets the account instead of keeping its last readings")
        XCTAssertEqual(calls.values, [])
        let signedOut = try await CopilotClient(enabled: { true }, token: { calls.record("token"); return nil }, http: http).fetch()
        XCTAssertTrue(signedOut.windows.isEmpty)
        XCTAssertNotNil(signedOut.notice)
        XCTAssertEqual(calls.values, ["token"])
    }

    /// Usage-based billing. The fixtures are derived from VS Code's reader of this answer (`parseQuotas` and
    /// `IQuotaSnapshotData`, microsoft/vscode afedf379) and GitHub's billing docs, not captured from an account.
    func testUsageBasedBillingNamesThePremiumSnapshotAsCredits() throws {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let credits = try CopilotClient.parse(json(#"{"copilot_plan":"individual_pro","access_type_sku":"monthly_subscriber_quota","token_based_billing":true,"quota_reset_date":"2026-10-01","quota_reset_date_utc":"2026-10-01T00:00:00.000Z","quota_snapshots":{"chat":{"entitlement":"0","quota_remaining":0,"percent_remaining":100,"unlimited":true,"has_quota":false,"overage_count":0,"overage_entitlement":0,"overage_permitted":false},"completions":{"entitlement":"0","quota_remaining":0,"percent_remaining":100,"unlimited":true,"has_quota":false,"overage_count":0,"overage_entitlement":0,"overage_permitted":false},"premium_interactions":{"entitlement":"1500","quota_remaining":1200,"percent_remaining":80,"unlimited":false,"has_quota":false,"quota_reset_at":1790812800,"overage_count":0,"overage_entitlement":0,"overage_permitted":false}}}"#))
        XCTAssertEqual(credits.windows.map(\.id), ["copilot:premium_interactions"], "the window keeps its id when its unit changes")
        XCTAssertEqual(credits.windows.map(\.label), ["AI credits"])
        XCTAssertEqual(credits.windows.map(\.remaining), [80])
        XCTAssertEqual(credits.windows.first?.reset, Date(timeIntervalSince1970: 1790812800))
        // A Free plan under usage-based billing counts its chat snapshot in credits too; its premium snapshot has none.
        let free = try CopilotClient.parse(json(#"{"copilot_plan":"free","access_type_sku":"free_limited_copilot","token_based_billing":true,"quota_snapshots":{"chat":{"entitlement":"50","quota_remaining":40,"percent_remaining":80,"unlimited":false},"completions":{"entitlement":"2000","quota_remaining":1000,"percent_remaining":50,"unlimited":false},"premium_interactions":{"entitlement":"0","quota_remaining":0,"percent_remaining":0,"unlimited":false}}}"#))
        XCTAssertEqual(free.windows.map(\.id), ["copilot:chat", "copilot:completions"])
        XCTAssertEqual(free.windows.map(\.label), ["AI credits", "Code completions"])
        XCTAssertEqual(free.windows.map(\.shortLabel), ["Credits", "Completions"])
        // Newer backends call the premium snapshot premium_models; a plan on premium requests keeps its name.
        let requests = try CopilotClient.parse(json(#"{"copilot_plan":"individual","quota_reset_date":"2026-10-01","quota_snapshots":{"premium_models":{"entitlement":"300","remaining":150,"percent_remaining":50,"unlimited":false}}}"#))
        XCTAssertEqual(requests.windows.map(\.id), ["copilot:premium_interactions"])
        XCTAssertEqual(requests.windows.map(\.label), ["Premium requests"])
        XCTAssertEqual(requests.windows.first?.reset, Date(timeIntervalSince1970: 1790812800))
        let both = try CopilotClient.parse(json(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":30,"unlimited":false},"premium_models":{"entitlement":300,"remaining":150,"unlimited":false}}}"#))
        XCTAssertEqual(both.windows.map(\.remaining), [10], "the premium_interactions snapshot is read where both are sent")
    }

    func testQuotaRequestAndSnapshots() async throws {
        let body = #"{"copilot_plan":"individual","quota_reset_date":"2026-10-01","quota_snapshots":{"chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true},"completions":{"entitlement":0,"remaining":0,"percent_remaining":100,"quota_id":"completions"},"premium_interactions":{"entitlement":300,"remaining":-6,"percent_remaining":-2,"unlimited":false},"code_review":{"entitlement":"50","remaining":"20"}}}"#
        let calls = Calls()
        let client = CopilotClient(enabled: { true }, token: { "fixture-token" }, http: ProviderHTTP(send: { request in
            calls.record("\(request.url!.absoluteString) \(request.value(forHTTPHeaderField: "Authorization") ?? "") \(request.value(forHTTPHeaderField: "Editor-Version") ?? "")")
            return Data((request.url!.path == "/user" ? #"{"id":1234,"login":"octo-fixture"}"# : body).utf8)
        }))
        let quota = try await client.fetch()
        XCTAssertEqual(calls.values, ["https://api.github.com/copilot_internal/user token fixture-token vscode/1.96.2",
                                      "https://api.github.com/user token fixture-token vscode/1.96.2"])
        XCTAssertEqual(quota.account, .identified(provider: "GitHub Copilot", user: "github.com:1234", workspace: nil))
        XCTAssertEqual(quota.label, "octo-fixture")
        XCTAssertFalse(quota.forgetAccounts)
        XCTAssertEqual(quota.plan, "individual")
        XCTAssertEqual(quota.windows.map(\.id), ["copilot:premium_interactions", "copilot:code_review"])
        XCTAssertEqual(quota.windows.map(\.remaining), [0, 40])
        XCTAssertEqual(quota.windows[0].reset, Date(timeIntervalSince1970: 1790812800))
        XCTAssertNil(quota.windows[0].duration)
        let free = try CopilotClient.parse(json(#"{"copilot_plan":"free","limited_user_quotas":{"chat":40,"completions":2000},"monthly_quotas":{"chat":50,"completions":0},"limited_user_reset_date":"2026-09-20"}"#))
        XCTAssertEqual(free.windows.map(\.id), ["copilot:chat"])
        XCTAssertEqual(free.windows.first?.remaining, 80)
        XCTAssertThrowsError(try CopilotClient.parse(json("[]")))
    }

    @MainActor
    func testAccountInventoryUsesTheVendorAndWithdrawnConsentRetiresRows() async throws {
        final class Consent: @unchecked Sendable { var on = true }
        let consent = Consent(), vendor = AdditionalSource.copilot.vendor
        let snapshot = #"{"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":150}}}"#
        let client = CopilotClient(enabled: { consent.on }, token: { "fixture-token" }, http: ProviderHTTP(send: { request in
            Data((request.url!.path == "/user" ? #"{"id":1234,"login":"octo-fixture"}"# : snapshot).utf8)
        }))
        let clock = now
        let copilot = AdditionalUsageProvider(source: .copilot, readQuota: { try await client.fetch() }, readSessions: { _ in .init() },
            history: QuotaHistoryStore(), clock: { clock })
        let retained = RetainedUsageProvider(provider: copilot)
        await retained.refreshAccountUsage(historyHours: 24)
        let signedIn = try await retained.fetchUsage(agents: [], historyHours: 24)
        let observation = try XCTUnwrap(signedIn.accounts?[vendor]?.first)
        XCTAssertEqual(observation.account.provider, vendor, "inventory lookups use account.provider")
        XCTAssertEqual(observation.label, "octo-fixture")
        XCTAssertEqual(signedIn.discoveredAgents.map(\.id), [observation.account.windowID("copilot:premium_interactions")])
        let suite = "CopilotProviderTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: [])
        settings.mergeDiscovered(signedIn.discoveredAgents, accounts: signedIn.accounts)
        XCTAssertEqual(settings.agents.map(\.id), signedIn.discoveredAgents.map(\.id))
        consent.on = false
        await retained.refreshAccountUsage(historyHours: 24)
        let withdrawn = try await retained.fetchUsage(agents: settings.agents, historyHours: 24)
        XCTAssertTrue(withdrawn.snapshots.isEmpty)
        XCTAssertEqual(withdrawn.accounts?[vendor], [])
        settings.mergeDiscovered(withdrawn.discoveredAgents, accounts: withdrawn.accounts)
        XCTAssertTrue(settings.agents.isEmpty, "withdrawing consent removes the Copilot rows from settings")
    }

    func testTokenSourcesInOrder() throws {
        let calls = Calls(), home = try directory()
        let hosts = "ghe.example.com:\n    oauth_token: enterprise\ngithub.com:\n    users:\n        octo:\n            oauth_token: from-file\n    user: octo\n"
        func credentials(_ environment: [String: String], keychain: String?) -> CopilotCredentials {
            CopilotCredentials(environment: environment, home: home,
                keychain: { calls.record("keychain \($0)"); return keychain },
                file: { calls.record($0.path); return hosts })
        }
        XCTAssertEqual(credentials(["GH_TOKEN": " env-gh ", "GITHUB_TOKEN": "env-github"], keychain: "stored").token(), "env-gh")
        XCTAssertEqual(credentials(["GH_TOKEN": "", "GITHUB_TOKEN": "env-github"], keychain: "stored").token(), "env-github")
        XCTAssertEqual(calls.values, [])
        let encoded = "go-keyring-base64:" + Data("from-keychain".utf8).base64EncodedString()
        XCTAssertEqual(credentials([:], keychain: encoded).token(), "from-keychain")
        XCTAssertEqual(calls.values, ["keychain gh:github.com"])
        XCTAssertEqual(credentials([:], keychain: nil).token(), "from-file")
        XCTAssertEqual(calls.values.last, home.appendingPathComponent(".config/gh/hosts.yml").path)
        XCTAssertEqual(credentials(["XDG_CONFIG_HOME": "/xdg"], keychain: nil).hostsFile.path, "/xdg/gh/hosts.yml")
        XCTAssertEqual(credentials(["GH_CONFIG_DIR": "/gh", "XDG_CONFIG_HOME": "/xdg"], keychain: nil).hostsFile.path, "/gh/hosts.yml")
        XCTAssertNil(CopilotCredentials.hostsToken("ghe.example.com:\n    oauth_token: enterprise\n"))
    }

    func testSessionLogDifferencesShutdownSnapshotsAndTracksTurns() throws {
        let root = try directory(), folder = root.appendingPathComponent("session-state/s1")
        let second = #"{"type":"session.shutdown","data":{"currentModel":"gpt-5.4","modelMetrics":{"gpt-5.4":{"usage":{"inputTokens":31067,"outputTokens":129,"cacheReadTokens":25968,"reasoningTokens":80}},"auto":{"usage":{"inputTokens":500,"outputTokens":50,"cacheReadTokens":0}}}},"id":"sd2","timestamp":"2026-09-08T02:00:00.000Z"}"#
        try write(folder.appendingPathComponent("events.jsonl"), [
            #"{"type":"session.start","data":{"sessionId":"s1","selectedModel":"auto","startTime":"2026-09-08T00:00:00.000Z","context":{"cwd":"/work/app"}},"id":"e1","timestamp":"2026-09-08T00:00:00.000Z","parentId":null}"#,
            #"{"type":"user.message","data":{"content":"fix"},"id":"u1","timestamp":"2026-09-08T00:00:01.000Z"}"#,
            #"{"type":"assistant.turn_start","data":{"turnId":"0"},"id":"t1","timestamp":"2026-09-08T00:00:02.000Z"}"#,
            #"{"type":"assistant.message","data":{"content":unparsed body"#,
            #"{"type":"user.message","agentId":"sub","data":{"content":"delegated"},"id":"u-sub","timestamp":"2026-09-08T00:00:03.000Z"}"#,
            #"{"type":"assistant.turn_end","data":{"turnId":"0"},"id":"t2","timestamp":"2026-09-08T00:00:04.000Z"}"#,
            #"{"type":"hook.start","data":{"hookInvocationId":"h","hookType":"agentStop","input":{"sessionId":"s1","stopReason":"end_turn"}},"id":"h1","timestamp":"2026-09-08T00:00:05.000Z"}"#,
            #"{"type":"session.shutdown","data":{"currentModel":"gpt-5.4","modelMetrics":{"gpt-5.4":{"usage":{"inputTokens":21067,"outputTokens":29,"cacheReadTokens":19968,"cacheWriteTokens":0,"reasoningTokens":22}}}},"id":"sd1","timestamp":"2026-09-08T00:01:00.000Z"}"#,
            #"{"type":"user.message","data":{"content":"again"},"id":"u2","timestamp":"2026-09-08T01:00:00.000Z"}"#,
            #"{"type":"abort","data":{"reason":"user_initiated"},"id":"a1","timestamp":"2026-09-08T01:00:05.000Z"}"#,
            #"{"type":"user.message","data":{"content":"third"},"id":"u3","timestamp":"2026-09-08T01:10:00.000Z"}"#,
            second, second,
        ])
        try "id: s1\nname: \"Fix \\\"login\\\"\"\nsummary: Fallback\n".write(to: folder.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let item = try XCTUnwrap(CopilotSessions.read(folder.appendingPathComponent("events.jsonl")).sessions.first)
        XCTAssertEqual(item.id, "copilot:s1")
        XCTAssertEqual(item.title, "Fix \"login\"")
        XCTAssertEqual(item.workspace, "/work/app")
        XCTAssertEqual(item.events.map(\.id), ["copilot:s1:shutdown:sd1:gpt-5.4", "copilot:s1:shutdown:sd2:auto", "copilot:s1:shutdown:sd2:gpt-5.4"])
        XCTAssertEqual(item.events.map(\.input), [1099, 500, 4000])
        XCTAssertEqual(item.events.map(\.output), [29, 50, 100])
        XCTAssertEqual(item.events.map(\.cacheRead), [19968, 0, 6000])
        XCTAssertEqual(Set(item.events.map(\.model)), ["gpt-5.4"])
        XCTAssertEqual(item.turns.map(\.turnID), ["u1", "u2", "u3"])
        XCTAssertEqual(item.turns.map(\.state), [.completed, .ended, .ended])
        XCTAssertEqual(item.turns.map(\.outcome), [.completed, .interrupted, nil], "an abort is the user's stop; a shutdown says nothing")
        XCTAssertEqual(item.turns[0].observedAtMs, 1788825605000)
        XCTAssertTrue(item.completions.isEmpty, "Completions come from the agentStop hook")
    }

    func testWorkspaceReadsTheBlockScalarOfALongName() throws {
        let url = try directory().appendingPathComponent("workspace.yaml")
        try "id: s1\nname: |-\n  Investigate the flaky login test\n  on CI\nsummary: >\n  Folded\n  summary\nuser_named: false\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let values = CopilotSessions.workspace(url)
        XCTAssertEqual(values["name"], "Investigate the flaky login test\non CI")
        XCTAssertEqual(values["summary"], "Folded summary")
    }

    func testTracesOwnUsageOfCoveredSessions() async throws {
        let root = try directory()
        try write(root.appendingPathComponent("session-state/s1/events.jsonl"), [
            #"{"type":"session.start","data":{"context":{"cwd":"/work/app"}},"id":"e1","timestamp":"2026-09-08T00:00:00.000Z"}"#,
            #"{"type":"session.shutdown","data":{"modelMetrics":{"gpt-5.4":{"usage":{"inputTokens":1000,"outputTokens":20,"cacheReadTokens":200}}}},"id":"sd1","timestamp":"2026-09-08T00:01:00.000Z"}"#,
        ])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("session-state/s1/checkpoints"), withIntermediateDirectories: true)
        let chat = #"{"type":"span","traceId":"trace-1","spanId":"chat-1","name":"chat gpt-5.4","startTime":[1788800001,500000000],"attributes":{"gen_ai.operation.name":"chat","gen_ai.response.model":"gpt-5.4","gen_ai.usage.input_tokens":1000,"gen_ai.usage.output_tokens":20,"gen_ai.usage.cache_read_input_tokens":200}}"#
        try write(root.appendingPathComponent("otel/run/copilot.jsonl"), [
            #"{"type":"span","traceId":"trace-1","spanId":"invoke","name":"invoke_agent","startTime":[1788800000,0],"attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.conversation.id":"s1","gen_ai.usage.input_tokens":999,"gen_ai.usage.output_tokens":99}}"#,
            chat, chat,
            #"{"type":"span","traceId":"trace-1","spanId":"tool","name":"execute_tool rg","attributes":{"gen_ai.operation.name":"execute_tool"}}"#,
            #"{"type":"span","traceId":"trace-2","spanId":"chat-2","name":"chat claude","startTime":[1788800002,0],"attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"other","gen_ai.request.model":"claude","gen_ai.usage.input_tokens":"7","gen_ai.usage.output_tokens":"9"}}"#,
        ])
        let roots = CopilotSessions.roots(home: root, environment: ["COPILOT_HOME": root.path])
        let result = await AdditionalLocalStore(source: .copilot, roots: roots).index(since: .distantPast)
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.sessions.map(\.id), ["copilot:other", "copilot:s1"])
        let covered = result.sessions[1]
        XCTAssertEqual(covered.title, "app")
        XCTAssertEqual(covered.events.map(\.id), ["copilot:s1:otel:trace-1:chat-1"])
        XCTAssertEqual(covered.events.map { [$0.input, $0.output, $0.cacheRead] }, [[800, 20, 200]])
        XCTAssertEqual(covered.events.first?.timestamp, Date(timeIntervalSince1970: 1788800001.5))
        XCTAssertEqual(result.sessions[0].events.map { "\($0.model) \($0.input) \($0.output)" }, ["claude 7 9"])
        XCTAssertEqual(roots.map(\.lastPathComponent), ["session-state", "otel"])
        let exporter = CopilotSessions.roots(home: root, environment: [CopilotSessions.exporterVariable: "/exports/copilot.jsonl"])
        XCTAssertEqual(exporter.map(\.path), [root.path + "/.copilot/session-state", root.path + "/.copilot/otel", "/exports"])
    }

    func testAgentStopHookRecordsOnlyEndTurnInItsOwnFile() throws {
        XCTAssertNil(CopilotHookFormat.completion(try json(#"{"sessionId":"s1","stopReason":"error"}"#), now: now))
        let completion = try XCTUnwrap(CompletionHooks.completion(source: .copilot,
            payload: json(#"{"sessionId":"s1","timestamp":1788800000000,"cwd":"/work/app","stopReason":"end_turn","stop_hook_active":false}"#), now: now))
        XCTAssertEqual(completion.sessionID, "copilot:s1")
        XCTAssertEqual(completion.id, RecordCoding.hash(["GitHub Copilot", "copilot:s1", "stop-1788800000000"]))
        XCTAssertEqual(completion.task, "GitHub Copilot · app")
        let home = try directory(), executable = home.appendingPathComponent("Agent HUD")
        let url = CompletionHooks.Source.copilot.configuration(home: home)
        try CompletionHooks.configure(.copilot, enabled: false, executable: executable, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try write(url, [#"{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"notify-send done"}],"sessionStart":[]}}"#])
        try CompletionHooks.configure(.copilot, enabled: true, executable: executable, home: home)
        let hooks = try ProviderFiles.json(url)["hooks"]
        XCTAssertEqual(hooks["sessionStart"], .array([]))
        XCTAssertEqual(hooks["agentStop"].arrayValue?.count, 2)
        XCTAssertEqual(hooks["agentStop"].arrayValue?.last?["timeoutSec"], .integer(5))
        XCTAssertEqual(hooks["agentStop"].arrayValue?.last?["bash"].stringValue, "'\(executable.path)' --completion-hook copilot")
    }
}

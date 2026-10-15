import XCTest
@testable import AgentHUDCore

/// Which windows are their provider's plan-wide quota (`AgentDescriptor.allModels`), and which limit a subset of the
/// plan's models or features, as each provider reads them.
final class PlanWideWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_800_000)

    private func json(_ text: String) throws -> ProviderJSON { try .read(Data(text.utf8)) }
    private func flags(_ quota: ProviderQuota) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: quota.windows.map { ($0.id, $0.allModels) })
    }

    private static let cursor = #"{"membershipType":"pro","individualUsage":{"plan":{"enabled":true,"totalPercentUsed":10,"autoPercentUsed":20,"apiPercentUsed":30},"overall":{"enabled":true,"used":10,"limit":100},"onDemand":{"enabled":true,"used":5,"limit":50}},"teamUsage":{"pooled":{"enabled":true,"used":1,"limit":10}}}"#
    private static let glm = #"{"success":true,"code":200,"data":{"planName":"Pro","limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":25},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":5}]}}"#

    func testCursorsModelPoolsLimitSomeOfThePlansModels() async throws {
        XCTAssertEqual(flags(try CursorClient.parseQuota(json(Self.cursor))), [
            "cursor": true, "cursor:models": false, "cursor:third-party": false, "cursor:personal": true, "cursor:team": true, "cursor:extra": true,
        ])
    }

    func testAntigravityGroupsLimitTheirModelsWhereTheAccountHasSeveral() async throws {
        let gemini = #"{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","displayName":"Five Hour Limit","remainingFraction":0.5},{"bucketId":"gemini-7d","displayName":"Weekly Limit","remainingFraction":0.75}]}"#
        let others = #"{"displayName":"Claude and GPT models","buckets":[{"bucketId":"third-party-7d","displayName":"Weekly Limit","remainingFraction":1}]}"#
        XCTAssertEqual(flags(try AntigravityClient.summary(json(#"{"groups":[\#(gemini)]}"#))),
                       ["antigravity:gemini-5h": true, "antigravity:gemini-7d": true], "a single group is the plan's quota")
        XCTAssertEqual(flags(try AntigravityClient.summary(json(#"{"groups":[\#(gemini),\#(others)]}"#))),
                       ["antigravity:gemini-5h": false, "antigravity:gemini-7d": false, "antigravity:third-party-7d": false])
        func status(_ labels: [String]) throws -> ProviderJSON {
            let configs = labels.enumerated().map { #"{"label":"\#($1)","modelOrAlias":{"model":"M\#($0)"},"quotaInfo":{"remainingFraction":0.5}}"# }
            return try json(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[\#(configs.joined(separator: ","))]}}}"#)
        }
        XCTAssertEqual(flags(try AntigravityClient.userStatus(status(["Gemini 3 Pro", "Gemini 3 Flash"]))), ["antigravity:legacy:gemini": true],
                       "the earlier quota of one family")
        XCTAssertEqual(flags(try AntigravityClient.userStatus(status(["Gemini 3 Pro", "Claude Sonnet 5"]))),
                       ["antigravity:legacy:gemini": false, "antigravity:legacy:claude-gpt": false])
    }

    func testCopilotsChatAndCompletionsLimitOneFeature() async throws {
        let requests = try json(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":150,"unlimited":false},"chat":{"entitlement":50,"remaining":40,"unlimited":false},"completions":{"entitlement":2000,"remaining":1000,"unlimited":false},"agent":{"entitlement":10,"remaining":5,"unlimited":false}}}"#)
        XCTAssertEqual(flags(try CopilotClient.parse(requests)), [
            "copilot:premium_interactions": true, "copilot:chat": false, "copilot:completions": false, "copilot:agent": true,
        ])
        let credits = try json(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":1500,"remaining":1200,"unlimited":false}}}"#)
        XCTAssertEqual(flags(try CopilotClient.parse(credits)), ["copilot:premium_interactions": true])
        // A Free plan under usage-based billing counts its chat in the plan's AI credits.
        let free = try json(#"{"copilot_plan":"free","access_type_sku":"free_limited_copilot","token_based_billing":true,"quota_snapshots":{"chat":{"entitlement":"50","quota_remaining":40,"percent_remaining":80,"unlimited":false},"completions":{"entitlement":"2000","quota_remaining":1000,"percent_remaining":50,"unlimited":false}}}"#)
        XCTAssertEqual(flags(try CopilotClient.parse(free)), ["copilot:chat": true, "copilot:completions": false])
        let limited = try json(#"{"limited_user_quotas":{"chat":40,"completions":1000},"monthly_quotas":{"chat":50,"completions":2000}}"#)
        XCTAssertEqual(flags(try CopilotClient.parse(limited)), ["copilot:chat": false, "copilot:completions": false], "a Free plan's counts")
    }

    func testPoolsArePlanWideExceptGLMsMCPWindow() async throws {
        let glm = OpenAgentCredentials.credential(.glmChina, token: "fixture-key", client: "Claude")
        XCTAssertEqual(try OpenAgentQuotaClient.parse(json(Self.glm), credential: glm, now: now).windows.map(\.allModels), [true, true, false],
                       "MCP calls, not the plan's models")
        let kimi = OpenAgentCredentials.credential(.kimi, token: "fixture-key", client: "Kimi")
        let usages = try json(#"{"usages":{"limit_5h":{"used_ratio":0.25},"limit_7d":{"used_ratio":0.2},"limit_month_total":{"used_ratio":0.4}}}"#)
        XCTAssertEqual(try OpenAgentQuotaClient.parse(usages, credential: kimi, now: now).windows.map(\.allModels), [true, true, true])
        let go = OpenAgentCredentials.credential(.go, token: "fixture-key", client: "OpenCode")
        let usage = try json(#"{"usage":{"rolling":{"percent":1},"weekly":{"percent":1},"monthly":{"percent":1}}}"#)
        XCTAssertEqual(try OpenAgentQuotaClient.parse(usage, credential: go, now: now).windows.map(\.allModels), [true, true, true])
        let grok = try json(#"{"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"onDemandCap":{"val":100},"onDemandUsed":{"val":10}}}"#)
        XCTAssertEqual(flags(try GrokClient.parse(grok)), ["grok": true, "grok:extra": true])
    }

    /// The providers carry the flag onto the rows the Mac shows and a host publishes.
    func testTheRowsCarryTheFlag() async throws {
        var cursor = try CursorClient.parseQuota(json(Self.cursor))
        cursor.account = ProviderAccount(provider: "Cursor", user: "user", workspace: "", evidence: .account)
        let read = cursor, now = now
        let additional = AdditionalUsageProvider(source: .cursor, readQuota: { read }, readSessions: { _ in ProviderSessions() },
                                                 history: QuotaHistoryStore(), clock: { now })
        let rows = try await additional.fetchAccountAndLocalUsage(agents: [], historyHours: 24).discoveredAgents
        XCTAssertEqual(rows.map(\.windowKey), ["cursor", "cursor:models", "cursor:third-party", "cursor:personal", "cursor:team", "cursor:extra"])
        XCTAssertEqual(rows.map(\.allModels), [true, false, false, true, true, true])
        let credential = OpenAgentCredentials.credential(.glmChina, token: "fixture-key", client: "Claude"), answer = try json(Self.glm)
        let pools = OpenAgentUsageProvider(credentials: { [credential] }, sessions: { _ in .init() },
                                           fetchQuota: { try OpenAgentQuotaClient.parse(answer, credential: $0, now: $1) },
                                           history: QuotaHistoryStore(), clock: { now })
        let windows = try await pools.fetchAccountAndLocalUsage(agents: [], historyHours: 24).discoveredAgents
        XCTAssertEqual(windows.map(\.allModels), [true, true, false])
    }
}

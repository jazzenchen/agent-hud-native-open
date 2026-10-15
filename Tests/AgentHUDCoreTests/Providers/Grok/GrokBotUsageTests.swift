import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokBotUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBillingUsageJoinsNativeMetadataWithoutWritingOrDisplayingItTwice() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        try fixture.writeTranscript([fixture.prompt("prompt", sequence: 1), fixture.reply("reply", sequence: 2)])
        var bot = try GrokBotSessions.read(fixture.roster)
        bot.sessions[0].workspace = "/synthetic/project"
        let billing = try CursorClient.parseEvents([
            row(conversation: fixture.agent, model: "grok-bot-default", at: -55, input: 10, output: 5, cache: 20, write: 2),
            row(conversation: fixture.agent, model: "grok-bot-cua", at: -5, input: 30, output: 7, cache: 40, write: 3),
        ], account: "billing-account")
        let billingID = try XCTUnwrap(billing.sessions.first?.id)
        let ledger = UsageLedger.inMemory()
        let provider = combined(bot: bot, billing: billing, ledger: ledger)

        for _ in 0..<2 {
            let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
            let session = try XCTUnwrap(report.sessions.first)
            XCTAssertEqual(report.sessions.count, 1, "the account import and native cache represent one displayed session")
            XCTAssertEqual(session.id, fixture.sessionID)
            XCTAssertEqual(session.client, "Grok Bot")
            XCTAssertEqual(session.task, "Synthetic conversation")
            XCTAssertEqual(session.transcriptPath, fixture.transcript.path)
            XCTAssertEqual(session.workingDirectory, "/synthetic/project")
            XCTAssertEqual(session.navigationTarget, .grokBotAgent(id: fixture.agent))
            XCTAssertEqual(session.usageKey, billingID)
            XCTAssertEqual(session.agentId, "cursor-model:grok-bot-cua")
            XCTAssertEqual(session.tokensIn, 45)
            XCTAssertEqual(session.tokensOut, 12)
            XCTAssertEqual(session.cacheReadTokens, 60)
            XCTAssertTrue(session.accountWide)
            XCTAssertEqual(session.startedAt, now.addingTimeInterval(-60))
            XCTAssertEqual(session.lastActivityAt, now.addingTimeInterval(-5))
            XCTAssertFalse(session.isLive)

            let usage = try XCTUnwrap(report.sessionUsage?[fixture.sessionID])
            XCTAssertEqual(usage.calls, 2)
            XCTAssertEqual(usage.total, .init(tokensIn: 45, tokensOut: 12, cacheReadTokens: 60, cacheWriteTokens: 5))
            XCTAssertNil(usage.subagents, "billing contributions are the Bot's own calls")
            XCTAssertEqual(Set(usage.models.map(\.agentId)), ["cursor-model:grok-bot-default", "cursor-model:grok-bot-cua"])
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 45)
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensOut }, 12)
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.cacheReadTokens }, 60)
            let billingAccount = ProviderAccount(provider: "Cursor", user: "billing-owner", workspace: "", evidence: .account)
            XCTAssertEqual(Set(report.usage.compactMap(\.account)), [billingAccount.id], "the join preserves the billing account's canonical scope")

            let request = SessionUsageRequest(session)
            XCTAssertTrue(request.keys.contains(billingID))
            XCTAssertTrue(request.subagentKeys.isEmpty)
            let calls = try await ledger.turnCalls(request, from: now.addingTimeInterval(-60), through: now)
            XCTAssertEqual(calls.count, 2)
            XCTAssertTrue(calls.allSatisfy(\.own))
            XCTAssertEqual(Set(calls.map(\.source)), ["cursor"])
            XCTAssertEqual(Set(calls.map(\.log)), [billingID])

            let turns = GrokBotConversation.turns(at: fixture.transcript, sessionID: session.id,
                                                   since: .distantPast, limit: 10, now: now)
            XCTAssertEqual(turns.first?.prompt, "Synthetic prompt")
            XCTAssertEqual(turns.first?.reply, "Synthetic reply")
            let restored = try JSONDecoder().decode(LiveSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.usageKey, billingID, "the own-usage reference survives the restart report")
        }

        let contributions = try await ledger.write { writer in
            ["cursor": try writer.contributions(source: "cursor"), "grok": try writer.contributions(source: "grok")]
        }
        XCTAssertEqual(contributions["cursor"], [billingID])
        XCTAssertEqual(contributions["grok"], [], "joining display metadata must not create another metered contribution")
    }

    func testOnlyAnExactNativeIDCanJoin() async throws {
        let bot = metadata(agent: "native-agent")
        let cases: [(String, String)] = [
            ("native-agent-extra", "grok-bot-default"),
            ("native", "grok-bot-default"),
        ]
        for (conversation, model) in cases {
            let billing = try CursorClient.parseEvents([row(conversation: conversation, model: model)], account: "account-a")
            let report = try await combined(bot: bot, billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
            XCTAssertEqual(report.sessions.count, 2)
            let native = try XCTUnwrap(report.sessions.first { $0.client == "Grok Bot" })
            XCTAssertEqual(native.tokensIn, 0)
            XCTAssertNil(native.usageKey)
        }
    }

    func testBillingOnlySubagentsStayOutOfSessionsWithoutLosingOrDuplicatingUsage() async throws {
        let ids = ["sand-subagent-11111111-1111-1111-1111-111111111111",
                   "sand-subagent-22222222-2222-2222-2222-222222222222",
                   "sand-subagent-33333333-3333-3333-3333-333333333333"]
        let models = ["grok-bot-default", "grok-bot-cua", "ordinary-model"]
        let billing = try CursorClient.parseEvents(zip(ids, models).map { row(conversation: $0, model: $1) }, account: "billing-account")
        let ledger = UsageLedger.inMemory()
        let provider = combined(bot: .init(), billing: billing, ledger: ledger)
        let account = ProviderAccount(provider: "Cursor", user: "billing-owner", workspace: "", evidence: .account)
        let requests = billing.sessions.map { SessionUsageRequest(sessionID: $0.id, keys: [$0.id]) }
        for _ in 0..<2 {
            let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
            let view = ReportView(report: report, agents: [], settings: Settings(), now: now)
            XCTAssertTrue(view.sessions.isEmpty, "a billing identity alone does not establish a readable native conversation")
            XCTAssertEqual(Set(report.sessions.map(\.id)), Set(billing.sessions.map(\.id)), "billing records remain available for accounting")
            XCTAssertEqual(Set(report.sessionUsage?.keys.map { $0 } ?? []), Set(billing.sessions.map(\.id)))
            XCTAssertEqual(Set(report.consumers.map(\.vendor)), ["Cursor"])
            XCTAssertEqual(Set(report.usage.compactMap(\.account)), [account.id])
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 36)
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensOut }, 15)
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.cacheReadTokens }, 60)

            let storedUsage = try await ledger.sessionUsage(requests)
            for (id, model) in zip(ids, models) {
                let key = "cursor-account:billing-account:" + id
                let usage = try XCTUnwrap(storedUsage[key])
                XCTAssertEqual(usage.calls, 1)
                XCTAssertEqual(usage.total, .init(tokensIn: 12, tokensOut: 5, cacheReadTokens: 20, cacheWriteTokens: 2))
                XCTAssertEqual(usage.models.map(\.agentId), ["cursor-model:" + model])
                let calls = try await ledger.turnCalls(.init(sessionID: key, keys: [key]),
                    from: now.addingTimeInterval(-60), through: now)
                XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(calls.first?.source, "cursor")
                XCTAssertEqual(calls.first?.log, key)
            }
        }
        let contributions = try await ledger.write { writer in
            ["cursor": try writer.contributions(source: "cursor"), "grok": try writer.contributions(source: "grok")]
        }
        XCTAssertEqual(Set(contributions["cursor"] ?? []), Set(billing.sessions.map(\.id)))
        XCTAssertEqual(contributions["grok"], [])
    }

    func testBillingOnlySubagentsDoNotHideNativeMainBotsOrOrdinaryCursorSessions() async throws {
        let bot = metadata(agent: "native-main-bot")
        let child = "sand-subagent-fixture-child"
        let billing = try CursorClient.parseEvents([
            row(conversation: child),
            row(conversation: "ordinary-cursor-conversation", model: "ordinary-model"),
        ], account: "account-a")
        let report = try await combined(bot: bot, billing: billing)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let shown = ReportView(report: report, agents: [], settings: Settings(), now: now).sessions.map(\.session)
        XCTAssertEqual(Set(shown.map(\.id)), [bot.sessions[0].id, "cursor-account:account-a:ordinary-cursor-conversation"])
        XCTAssertEqual(report.sessions.count, 3)
        let native = try XCTUnwrap(shown.first { $0.id == bot.sessions[0].id })
        XCTAssertEqual(native.client, "Grok Bot")
        XCTAssertEqual(native.task, "Native title")
        XCTAssertEqual(native.navigationTarget, .grokBotAgent(id: "native-main-bot"))
        XCTAssertEqual(native.tokensIn, 0)
        XCTAssertNil(native.usageKey, "the child billing identity must not be attached to an unrelated Bot")
        let cursor = try XCTUnwrap(shown.first { $0.client == "Cursor" })
        XCTAssertEqual(cursor.agentId, "cursor-model:ordinary-model")
        XCTAssertEqual(cursor.tokensIn, 12)
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 24, "hidden child usage remains in the account totals")
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensOut }, 10)
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.cacheReadTokens }, 40)
    }

    func testRestoredBillingOnlySubagentsAreHiddenEvenWithTheOldCursorClientLabel() async throws {
        let child = "sand-subagent-fixture-child"
        let ids = ["cursor-account:account-a:" + child, "cursor-account:account-a:ordinary-conversation",
                   GrokBotCache.sessionID(account: "bot-account", agent: child)]
        let sessions = ids.map { id in
            LiveSession(id: id, agentId: "cursor-model:grok-bot-default", task: "Cached title", terminal: nil,
                        startedAt: now.addingTimeInterval(-60), endedAt: now.addingTimeInterval(-5),
                        pctOfWindow: nil, tokensIn: 12, tokensOut: 5, client: "Cursor", accountWide: false)
        }
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: sessions)
        let restored = try JSONDecoder().decode(UsageReport.self, from: JSONEncoder().encode(report))
        let view = ReportView(report: restored, agents: [], settings: Settings(), now: now)
        XCTAssertEqual(Set(view.sessions.map(\.id)), Set(ids.dropFirst()), "native identity and ordinary Cursor remain visible after cache restoration")
        XCTAssertEqual(restored.sessions.count, 3, "presentation does not discard billing bookkeeping")
    }

    func testBillingSubagentIDsWithNativeTranscriptOrNavigationRemainVisible() async {
        let child = "sand-subagent-fixture-child"
        let path = LiveSession(id: "cursor-account:account-a:" + child, agentId: "cursor-model:ordinary-model",
            task: "Native transcript", terminal: nil, startedAt: now, pctOfWindow: nil, tokensIn: 12, tokensOut: 5,
            client: "Grok Bot", transcriptPath: "/synthetic/subagent-transcript.blob")
        let navigation = LiveSession(id: "cursor-account:account-b:" + child, agentId: "cursor-model:ordinary-model",
            task: "Native destination", terminal: nil, startedAt: now, pctOfWindow: nil, tokensIn: 12, tokensOut: 5,
            client: "Grok Bot", navigationTarget: .grokBotAgent(id: child))
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [path, navigation])
        let view = ReportView(report: report, agents: [], settings: Settings(), now: now)
        XCTAssertEqual(Set(view.sessions.map(\.id)), [path.id, navigation.id])
    }

    func testModelNamesAndSimilarOrMissingIDsDoNotEstablishBotOrigin() async throws {
        let ids: [String?] = ["ordinary-conversation", "sand-subagent", "sand-subagent-", "other-sand-subagent-child",
                              "sand-subagent-child:other", nil]
        let billing = try CursorClient.parseEvents(ids.map { row(conversation: $0) }, account: "account-a")
        let report = try await combined(bot: .init(), billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, ids.count)
        XCTAssertEqual(ReportView(report: report, agents: [], settings: Settings(), now: now).sessions.count, ids.count)
        XCTAssertTrue(report.sessions.allSatisfy { $0.client == "Cursor" && $0.usageKey == nil })
        XCTAssertEqual(Set(report.sessions.map(\.agentId)), ["cursor-model:grok-bot-default"])
    }

    func testSubagentNativeMetadataStillJoinsItsExactBillingIdentity() async throws {
        let id = "sand-subagent-fixture-child"
        var bot = metadata(agent: id)
        bot.sessions[0].path = "/synthetic/subagent-transcript.blob"
        let billing = try CursorClient.parseEvents([row(conversation: id)], account: "account-a")
        let report = try await combined(bot: bot, billing: billing)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(report.sessions.count, 1, "a known child keeps one native session, rather than a separate billing row")
        XCTAssertEqual(ReportView(report: report, agents: [], settings: Settings(), now: now).sessions.map(\.id), [session.id])
        XCTAssertEqual(session.id, GrokBotCache.sessionID(account: "bot-account", agent: id))
        XCTAssertEqual(session.task, "Native title")
        XCTAssertEqual(session.transcriptPath, "/synthetic/subagent-transcript.blob")
        XCTAssertEqual(session.navigationTarget, .grokBotAgent(id: id))
        XCTAssertEqual(session.client, "Grok Bot")
        XCTAssertEqual(session.tokensIn, 12)
        XCTAssertEqual(session.usageKey, billing.sessions.first?.id)
        XCTAssertEqual(report.sessionUsage?[session.id]?.calls, 1)
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 12)
        XCTAssertNil(session.subagentSessions)
    }

    func testAnExactNativeIDJoinsAnOrdinaryModelWithoutChangingItsIdentity() async throws {
        let billing = try CursorClient.parseEvents([row(conversation: "native-agent", model: "cursor-grok-4.6-medium")], account: "account-a")
        let report = try await combined(bot: metadata(agent: "native-agent"), billing: billing)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(report.sessions.count, 1)
        XCTAssertEqual(session.client, "Grok Bot")
        XCTAssertEqual(session.tokensIn, 12)
        XCTAssertEqual(session.agentId, "cursor-model:cursor-grok-4.6-medium")
        XCTAssertEqual(session.usageKey, billing.sessions.first?.id)
        XCTAssertEqual(report.sessionUsage?[session.id]?.models.map(\.agentId), ["cursor-model:cursor-grok-4.6-medium"])
    }

    func testTheNativeNavigationIDMustAgreeWithTheAccountScopedBotIdentity() async throws {
        var bot = metadata(agent: "native-agent")
        bot.sessions[0].navigationTarget = .grokBotAgent(id: "other-agent")
        let billing = try CursorClient.parseEvents([row(conversation: "other-agent")], account: "account-a")
        let report = try await combined(bot: bot, billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 2)
        XCTAssertNil(report.sessions.first { $0.client == "Grok Bot" }?.usageKey)
    }

    func testAmbiguousBillingAccountsDoNotAttachUsageToOneNativeSession() async throws {
        let first = try CursorClient.parseEvents([row(conversation: "native-agent")], account: "account-a")
        let second = try CursorClient.parseEvents([row(conversation: "native-agent")], account: "account-b")
        let billing = ProviderSessions(sessions: first.sessions + second.sessions)
        let report = try await combined(bot: metadata(agent: "native-agent"), billing: billing)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 3)
        XCTAssertEqual(report.sessions.filter { $0.client == "Cursor" }.count, 2)
        let native = try XCTUnwrap(report.sessions.first { $0.client == "Grok Bot" })
        XCTAssertEqual(native.tokensIn, 0)
        XCTAssertNil(native.usageKey)
    }

    func testAmbiguousNativeAccountPartitionsDoNotConsumeBillingUsage() async throws {
        let first = metadata(agent: "native-agent", account: "bot-account-a")
        let second = metadata(agent: "native-agent", account: "bot-account-b")
        let bot = ProviderSessions(sessions: first.sessions + second.sessions)
        let billing = try CursorClient.parseEvents([row(conversation: "native-agent")], account: "account-a")
        let report = try await combined(bot: bot, billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 3)
        XCTAssertEqual(report.sessions.filter { $0.client == "Cursor" }.count, 1)
        XCTAssertTrue(report.sessions.filter { $0.client == "Grok Bot" }.allSatisfy { $0.usageKey == nil && $0.tokensIn == 0 })
    }

    func testSwitchingBotAccountsRemovesTheAttachedNativeSession() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let billing = try CursorClient.parseEvents([row(conversation: fixture.agent)], account: "account-a")
        let ledger = UsageLedger.inMemory()
        let cursor = provider(.cursor, sessions: billing, ledger: ledger)
        let grok = AdditionalUsageProvider(source: .grok, readQuota: { .init() }, readSessions: { _ in
            (try? GrokBotSessions.read(fixture.roster)) ?? .init()
        }, history: QuotaHistoryStore(), clock: { fixture.now }, ledger: ledger)
        let combined = CombinedUsageProvider([.init("Cursor", cursor), .init("Grok", grok)], ledger: ledger)
        let first = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.sessions.first?.client, "Grok Bot")
        try fixture.writeAccount("other-bot-account")
        let second = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(second.sessions.first?.client, "Cursor")
        XCTAssertNil(second.sessions.first?.transcriptPath)
        XCTAssertNil(second.sessions.first?.usageKey)
    }

    func testRoutineRunBecomesASubagentOfItsBotAndCountsInItsTotalOnce() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let bot = try GrokBotSessions.read(fixture.roster)
        let billing = try CursorClient.parseEvents([
            row(conversation: fixture.agent, at: -50, input: 10, output: 5, cache: 20, write: 2),
            row(conversation: "sand-subagent-run-a", model: "grok-bot-automation", at: -40, input: 100, output: 7, cache: 300, write: 0),
            row(conversation: "sand-subagent-run-a", model: "grok-bot-automation", at: -30, input: 50, output: 3, cache: 400, write: 0),
            row(conversation: "sand-subagent-unexplained", at: -20, input: 1000, output: 9, cache: 0, write: 0),
        ], account: "billing-account")
        let runID = try XCTUnwrap(billing.sessions.first { $0.id.hasSuffix("sand-subagent-run-a") }?.id)
        let now = now, agent = fixture.agent
        let runs = GrokBotRoutineRuns(directory: fixture.directory, clock: { now })
        await runs.refresh(billed: billing.sessions.map(\.id)) { _ in
            GrokBotRoutineRunsTests.reply([(agent, #"{"id":"daily","name":"Daily digest","runs":[{"id":"run-a","startedAt":1799999960000}]}"#)])
        }
        let ledger = UsageLedger.inMemory()
        let provider = combined(bot: bot, billing: billing, ledger: ledger, routineRuns: runs)

        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(Set(report.sessions.map(\.id)), [fixture.sessionID, "cursor-account:billing-account:sand-subagent-unexplained"])
        let session = try XCTUnwrap(report.sessions.first { $0.id == fixture.sessionID })
        XCTAssertEqual(session.tokensIn, 12, "the bot's own counts stay its own")
        XCTAssertEqual(session.subagentTranscripts, [runID])
        let run = try XCTUnwrap(session.subagentSessions?.first)
        XCTAssertEqual(session.subagentSessions?.count, 1)
        XCTAssertEqual(run.id, runID, "the run keeps its billing id, its ledger contribution")
        XCTAssertEqual(run.agentName, "Daily digest")
        XCTAssertEqual(run.client, "Grok Bot")
        XCTAssertEqual(run.agentId, "cursor-model:grok-bot-automation")
        XCTAssertEqual([run.tokensIn, run.tokensOut, run.cacheReadTokens], [150, 10, 700])
        XCTAssertNil(run.transcriptPath)

        let usage = try XCTUnwrap(report.sessionUsage?[fixture.sessionID])
        XCTAssertEqual(usage.total, .init(tokensIn: 162, tokensOut: 15, cacheReadTokens: 720, cacheWriteTokens: 2))
        XCTAssertEqual(usage.subagents, .init(tokensIn: 150, tokensOut: 10, cacheReadTokens: 700))
        XCTAssertEqual(report.sessionUsage?[runID]?.total, .init(tokensIn: 150, tokensOut: 10, cacheReadTokens: 700))
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 1162, "every billed call is still counted once")

        let unexplained = try XCTUnwrap(report.sessions.first { $0.id.hasSuffix("sand-subagent-unexplained") })
        XCTAssertTrue(unexplained.isBillingOnlyGrokBotSubagent, "a sub-agent no record names stays out of the session lists")
        XCTAssertNil(unexplained.subagentSessions)
        let view = ReportView(report: report, agents: [], settings: Settings(), now: now)
        XCTAssertEqual(view.sessions.map(\.id), [fixture.sessionID])
        XCTAssertEqual(view.session(runID)?.id, runID, "the run opens from its bot's page")
    }

    func testRunOfABotWithoutBillingOfItsOwnNestsAndARunOfAnUnknownBotStaysApart() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let bot = try GrokBotSessions.read(fixture.roster)
        let billing = try CursorClient.parseEvents([
            row(conversation: "sand-subagent-run-a", model: "grok-bot-automation", at: -40),
            row(conversation: "sand-subagent-run-b", model: "grok-bot-automation", at: -30),
        ], account: "billing-account")
        let now = now, agent = fixture.agent
        let runs = GrokBotRoutineRuns(directory: fixture.directory, clock: { now })
        await runs.refresh(billed: billing.sessions.map(\.id)) { _ in
            GrokBotRoutineRunsTests.reply([(agent, #"{"id":"daily","runs":[{"id":"run-a"}]}"#),
                                           ("deleted-bot", #"{"id":"gone","runs":[{"id":"run-b"}]}"#)])
        }
        let report = try await combined(bot: bot, billing: billing, routineRuns: runs).fetchAccountAndLocalUsage(agents: [], historyHours: 168)

        let session = try XCTUnwrap(report.sessions.first { $0.id == fixture.sessionID })
        XCTAssertNil(session.usageKey)
        XCTAssertEqual(session.subagentSessions?.map(\.id), ["cursor-account:billing-account:sand-subagent-run-a"])
        XCTAssertEqual(session.subagentSessions?.first?.agentName, "daily")
        XCTAssertEqual(report.sessionUsage?[fixture.sessionID]?.subagents, .init(tokensIn: 12, tokensOut: 5, cacheReadTokens: 20, cacheWriteTokens: 2))
        XCTAssertTrue(report.sessions.contains { $0.id == "cursor-account:billing-account:sand-subagent-run-b" && $0.isBillingOnlyGrokBotSubagent })
    }

    private func metadata(agent: String, account: String = "bot-account") -> ProviderSessions {
        var session = ProviderSession(id: GrokBotCache.sessionID(account: account, agent: agent), title: "Native title", client: "Grok Bot")
        session.startedAt = now.addingTimeInterval(-60)
        session.lastActivity = now.addingTimeInterval(-10)
        session.navigationTarget = .grokBotAgent(id: agent)
        return ProviderSessions(sessions: [session])
    }

    private func row(conversation: String?, model: String = "grok-bot-default", at: TimeInterval = -5,
                     input: Int64 = 10, output: Int64 = 5, cache: Int64 = 20, write: Int64 = 2) -> ProviderJSON {
        var value: [String: ProviderJSON] = ["timestamp": .integer(Int64(now.addingTimeInterval(at).timeIntervalSince1970 * 1000)),
                 "model": .string(model),
                 "tokenUsage": .object(["inputTokens": .integer(input), "outputTokens": .integer(output),
                                        "cacheReadTokens": .integer(cache), "cacheWriteTokens": .integer(write)])]
        if let conversation { value["conversationId"] = .string(conversation) }
        return .object(value)
    }

    private func provider(_ source: AdditionalSource, sessions: ProviderSessions, ledger: UsageLedger) -> AdditionalUsageProvider {
        let now = now
        return AdditionalUsageProvider(source: source, readQuota: {
            source == .cursor ? .init(account: ProviderAccount(provider: "Cursor", user: "billing-owner", workspace: "", evidence: .account)) : .init()
        }, readSessions: { _ in sessions },
                                       history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
    }

    private func combined(bot: ProviderSessions, billing: ProviderSessions, ledger: UsageLedger = .inMemory(),
                          routineRuns: GrokBotRoutineRuns? = nil) -> CombinedUsageProvider {
        CombinedUsageProvider([.init("Cursor", provider(.cursor, sessions: billing, ledger: ledger)),
                               .init("Grok", provider(.grok, sessions: bot, ledger: ledger))], ledger: ledger, grokBotRoutineRuns: routineRuns)
    }
}

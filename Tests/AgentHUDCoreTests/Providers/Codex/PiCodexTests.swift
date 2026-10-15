import Foundation
import XCTest
@testable import AgentHUDCore

final class PiCodexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = #"{"account_id":"workspace","email":"A@Example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_at":1800018000},"secondary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_at":1800604800}},"additional_rate_limits":[{"metered_feature":"base_model_inference","limit_name":"gpt-reserve","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1800604800}}}],"rate_limit_reset_credits":{"available_count":2}}"#

    func testBackendMappingSharesNativeAccountAndWindowIds() async throws {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let limits = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let native = try JSONDecoder().decode(CodexRateLimits.self, from: Data(#"{"accountId":"workspace","account":{"email":"a@example.com"},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1800018000}}}}"#.utf8))
        XCTAssertEqual(limits.providerAccount(home: "pi"), native.providerAccount(home: ""))
        XCTAssertEqual(limits.rows(home: "pi").first?.id, native.rows(home: "").first?.id)
        XCTAssertEqual(limits.rows.map(\.label), ["5h limit", "Weekly limit", "Luna Reserve · Weekly limit"])
        XCTAssertEqual(limits.rows.map(\.shortLabel), ["5h", "Weekly", "Reserve"])
        XCTAssertEqual(limits.rows.first?.window.remainingPct, 80)
        XCTAssertEqual(limits.rateLimitResetCredits?.availableCount, 2)
        XCTAssertThrowsError(try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "another-workspace"))
        XCTAssertThrowsError(try PiCodexClient.parse(Data("{}".utf8), expectedAccount: "workspace"))
        XCTAssertThrowsError(try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "\"used_percent\":20,", with: "").utf8), expectedAccount: "workspace"))
    }

    func testReadsOnlyPiAccessTokenAndDoesNotMutateCredentials() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        let content = #"{"openai-codex":{"type":"oauth","access":"test-access","refresh":"never-use","accountId":"workspace","expires":1800100000000}}"#
        try content.write(to: file, atomically: true, encoding: .utf8)
        let client = PiCodexClient(directory: dir, http: ProviderHTTP(send: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "workspace")
            XCTAssertNil(request.httpBody)
            return Data(Self.payload.utf8)
        }))
        let value = try await client.fetch(now: now)
        XCTAssertEqual(value?.account?.email, "A@Example.com")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), content)
        do { _ = try await client.fetch(now: now.addingTimeInterval(100_001)); XCTFail("expired token must stay with Pi") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Pi")) }
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        let absent = try await client.fetch(now: now)
        XCTAssertNil(absent)
    }

    func testSameAccountHasOneSetOfWindowsAndDistinctAccountsStaySeparate() async throws {
        let a = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let b = try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "A@Example.com", with: "b@example.com").utf8), expectedAccount: "workspace")
        for (pi, expected) in [(a, 1), (b, 2)] {
            let provider = CodexUsageProvider(readLimits: { a }, transcripts: CodexTranscriptStore(roots: []),
                history: QuotaHistoryStore(), clock: { [now] in now }, readPiLimits: { pi })
            await provider.refreshAccountUsage(historyHours: 24)
            let report = try await provider.fetchUsage(agents: [], historyHours: 24)
            XCTAssertEqual(report.accounts?["Codex"]?.count, expected)
            XCTAssertEqual(report.snapshots.count, expected * 3)
            XCTAssertEqual(Set(report.snapshots.map(\.agentId)).count, report.snapshots.count)
            for account in report.accounts?["Codex"] ?? [] {
                XCTAssertEqual(report.resetCredits(for: account.account.id)?.availableCount, 2)
            }
            if expected == 2 { XCTAssertNil(report.codexResetCredits, "legacy unscoped credits cannot describe two accounts") }
        }
    }

    func testPiFailureDoesNotSuppressNativeResetAndFailedWindowDoesNotNotify() async throws {
        let a = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let b = try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "A@Example.com", with: "b@example.com").utf8), expectedAccount: "workspace")
        let steps = Steps([.success(b), .failure(UsageProviderError("Pi offline"))])
        let clock = TestClock(now)
        let provider = CodexUsageProvider(readLimits: { a }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { clock.now }, readPiLimits: { try await steps.next() })
        await provider.refreshAccountUsage(historyHours: 24)
        clock.advance(61)
        await provider.refreshAccountUsage(historyHours: 24)
        let source = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(source.notice, "Pi offline")
        let combined = CombinedUsageProvider([.init("Codex", provider)])
        let report = try await combined.fetchUsage(agents: [], historyHours: 24)
        let native = try XCTUnwrap(report.discoveredAgents.first { $0.account == a.providerAccount(home: "") })
        let pi = try XCTUnwrap(report.discoveredAgents.first { $0.account == b.providerAccount(home: "pi") })
        XCTAssertNil(report.quotaNotice(for: native))
        XCTAssertEqual(report.quotaNotice(for: pi), "Pi offline")
        XCTAssertEqual(report.accounts?["Codex"]?.first { $0.account == b.providerAccount(home: "pi") }?.readingIssue, .readFailed("Pi offline"),
                       "the failure is the Pi account's own")
        XCTAssertEqual(report.sourceNotices, [:], "no other account shows it")
        XCTAssertEqual(report.readingIssues, [:])
        XCTAssertEqual(report.snapshot(for: pi.id)?.updatedAt, now, "failure never renews the old reading")
        XCTAssertEqual(report.accounts?["Codex"]?.count, 2)
        let view = ReportView(report: report, agents: report.discoveredAgents, settings: Settings(), now: clock.now)
        let sections = view.accountSections(view.rows)
        XCTAssertNil(view.accountNotice(for: try XCTUnwrap(sections.first { $0.id == native.account?.id })))
        XCTAssertEqual(view.accountNotice(for: try XCTUnwrap(sections.first { $0.id == pi.account?.id })), "Pi offline")
    }

    func testRestartKeepsExpiredPiNoticeOnItsCachedAccountAndClearsItOnRecovery() async throws {
        let native = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let pi = try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "A@Example.com", with: "b@example.com").utf8),
                                       expectedAccount: "workspace")
        let clock = TestClock(now)
        let original = CodexUsageProvider(readLimits: { native }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { clock.now }, readPiLimits: { pi }, piHome: "pi:alternate")
        await original.refreshAccountUsage(historyHours: 24)
        let saved = try JSONDecoder().decode(UsageReport.self, from: JSONEncoder().encode(
            try await original.fetchUsage(agents: [], historyHours: 24).restartCopy))

        clock.advance(61)
        let steps = Steps([.failure(UsageProviderError("Pi login expired")), .success(pi)])
        let restarted = CodexUsageProvider(readLimits: { native }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { clock.now }, readPiLimits: { try await steps.next() }, piHome: "pi:alternate")
        let combined = CombinedUsageProvider([.init("Codex", restarted)])
        let fresh = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 24)
        let failed = fresh.retainingReadings(from: saved)
        let nativeID = native.providerAccount(home: "").id, piID = pi.providerAccount(home: "pi:alternate").id
        let view = ReportView(report: failed, agents: failed.discoveredAgents, settings: Settings(), now: clock.now)
        let sections = view.accountSections(view.rows)
        XCTAssertEqual(view.rowGroups.map(\.vendor), ["Codex"], "both clients use the same subscription provider")
        XCTAssertEqual(sections.count, 2)
        let nativeSection = try XCTUnwrap(sections.first { $0.id == nativeID })
        let piSection = try XCTUnwrap(sections.first { $0.id == piID })
        XCTAssertNil(view.accountNotice(for: nativeSection))
        XCTAssertEqual(view.accountNotice(for: piSection), "Pi login expired")
        XCTAssertEqual(view.assessment(of: try XCTUnwrap(nativeSection.account)).status, .normal)
        XCTAssertEqual(view.assessment(of: try XCTUnwrap(piSection.account)).status, .readFailed(reason: "Pi login expired"))
        XCTAssertEqual(failed.observation(accountID: piID)?.observedAt, now, "a failure keeps the original reading time")
        XCTAssertTrue(try XCTUnwrap(failed.observation(accountID: piID)).isCurrent, "a failed identity read does not confirm sign-out")
        XCTAssertEqual(failed.resetCredits(for: nativeID)?.availableCount, 2)
        XCTAssertTrue(nativeSection.rows.allSatisfy { $0.assessment.confirmsEvents })
        XCTAssertTrue(piSection.rows.allSatisfy { !$0.assessment.showsLevel })

        clock.advance(61)
        let recovered = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 24).retainingReadings(from: failed)
        let recoveredView = ReportView(report: recovered, agents: recovered.discoveredAgents, settings: Settings(), now: clock.now)
        XCTAssertTrue(recoveredView.accountSections(recoveredView.rows).allSatisfy { recoveredView.accountNotice(for: $0) == nil })
        XCTAssertTrue(try XCTUnwrap(recovered.observation(accountID: piID)).isCurrent)
        XCTAssertEqual(recovered.observation(accountID: piID)?.observedAt, clock.now)
    }

    func testSameAccountResetProducesOneEventPerWindowAndOneHistorySample() async throws {
        let a = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let reset = try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "used_percent\":20", with: "used_percent\":0")
            .replacingOccurrences(of: "used_percent\":30", with: "used_percent\":0").utf8), expectedAccount: "workspace")
        let native = Steps([.success(a), .success(reset)]), pi = Steps([.success(a), .success(reset)])
        let clock = TestClock(now), history = QuotaHistoryStore()
        let provider = CodexUsageProvider(readLimits: { try await native.next()! }, transcripts: CodexTranscriptStore(roots: []),
            history: history, clock: { clock.now }, readPiLimits: { try await pi.next() })
        var tracker = QuotaAlertTracker()
        await provider.refreshAccountUsage(historyHours: 24)
        let first = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertTrue(tracker.update(report: first, agents: first.discoveredAgents, now: clock.now).alerts.isEmpty)
        clock.advance(61)
        await provider.refreshAccountUsage(historyHours: 24)
        let second = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(tracker.update(report: second, agents: second.discoveredAgents, now: clock.now).alerts.count, 2)
        let count = await history.count
        XCTAssertEqual(count, 6, "three windows sampled twice, irrespective of client count")
    }

    func testLatestLoginOwnsOneAccountAcrossFailuresPollingAndRestart() async throws {
        let native = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let pi = try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "used_percent\":20", with: "used_percent\":40").utf8),
                                       expectedAccount: "workspace")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("identities.json")
        let clock = TestClock(now), nativeLogin = TestClock(now.addingTimeInterval(-100)), piLogin = now.addingTimeInterval(-50)
        let steps = Steps([.success(pi), .failure(UsageProviderError("Pi login expired")), .failure(UsageProviderError("Pi login expired"))])
        let provider = CodexUsageProvider(readLimits: { native }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { clock.now }, readPiLimits: { try await steps.next() }, piHome: "pi:alternate",
            identityCacheURL: cache, readLoginAt: { $0 == "pi:alternate" ? piLogin : nativeLogin.now })
        let combined = CombinedUsageProvider([.init("Codex", provider)])
        let first = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 24)
        XCTAssertEqual(first.accounts?["Codex"]?.count, 1)
        XCTAssertEqual(first.accounts?["Codex"]?.first?.client, "Pi")
        XCTAssertEqual(first.snapshots.count, 3)
        XCTAssertEqual(first.snapshots.first?.remainingPct, 60, "the selected client's reading belongs to the account")
        let firstView = ReportView(report: first, agents: first.discoveredAgents, settings: Settings(), now: clock.now)
        XCTAssertEqual(firstView.rowGroups.map(\.vendor), ["Codex"])

        clock.advance(61)
        let failed = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 24)
        let failedView = ReportView(report: failed, agents: failed.discoveredAgents, settings: Settings(), now: clock.now)
        XCTAssertEqual(failedView.rowGroups.map(\.vendor), ["Codex"])
        XCTAssertEqual(failed.accounts?["Codex"]?.first?.client, "Pi", "a successful native poll cannot take reading ownership")
        XCTAssertEqual(failedView.accountSections(failedView.rows).count, 1)
        XCTAssertEqual(failedView.accountNotice(for: try XCTUnwrap(failedView.accountSections(failedView.rows).first)), "Pi login expired")
        XCTAssertEqual(failed.snapshots.first?.updatedAt, now)

        nativeLogin.advance(150)
        clock.advance(61)
        let switched = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 24)
        let switchedView = ReportView(report: switched, agents: switched.discoveredAgents, settings: Settings(), now: clock.now)
        XCTAssertEqual(switchedView.rowGroups.map(\.vendor), ["Codex"], "a later sign-in keeps the subscription group")
        XCTAssertEqual(switched.accounts?["Codex"]?.first?.client, "Codex", "a later sign-in changes the reading client")
        XCTAssertNil(switchedView.accountNotice(for: try XCTUnwrap(switchedView.accountSections(switchedView.rows).first)))
        XCTAssertEqual(switched.accounts?["Codex"]?.count, 1)

        let restarted = CodexUsageProvider(readLimits: { native }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { clock.now }, readPiLimits: { pi }, piHome: "pi:alternate", identityCacheURL: cache)
        await restarted.refreshAccountUsage(historyHours: 24)
        let restored = try await restarted.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(restored.accounts?["Codex"]?.first?.client, "Codex", "unknown sign-in times preserve the confirmed client")
        XCTAssertEqual(restored.accounts?["Codex"]?.count, 1)
    }

    func testCachedPiOwnerSurvivesAnExpiredLoginOnTheFirstRead() async throws {
        let limits = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace"), now = now
        let cached = AccountObservation(account: limits.providerAccount(home: "pi:alternate"), home: "pi:alternate", client: "Pi",
                                        observedAt: now.addingTimeInterval(-100))
        let earlier = UsageReport(generatedAt: cached.observedAt,
            snapshots: limits.rows(home: cached.home).map {
                UsageSnapshot(agentId: $0.id, remainingPct: $0.window.remainingPct, updatedAt: cached.observedAt)
            }, sessions: [], discoveredAgents: limits.rows(home: cached.home).map(\.descriptor), accounts: ["Codex": [cached]])
        let provider = CodexUsageProvider(readLimits: { limits }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { now }, readPiLimits: { throw UsageProviderError("Pi login expired") },
            piHome: "pi:alternate", initialAccounts: [cached])
        await provider.refreshAccountUsage(historyHours: 24)
        let fresh = try await provider.fetchUsage(agents: [], historyHours: 24)
        let report = fresh.retainingReadings(from: earlier)
        let view = ReportView(report: report, agents: report.discoveredAgents, settings: Settings(), now: now)
        XCTAssertEqual(view.rowGroups.map(\.vendor), ["Codex"])
        XCTAssertEqual(report.accounts?["Codex"]?.count, 1)
        XCTAssertEqual(view.accountNotice(for: try XCTUnwrap(view.accountSections(view.rows).first)), "Pi login expired")
        XCTAssertNil(report.sourceNotices["Codex"], "the failure never becomes a notice for another client")
        XCTAssertEqual(report.snapshots.first?.updatedAt, cached.observedAt, "another client's poll cannot renew the owner's reading")
    }

    func testChangingNativeHomeReplacesItsPersistedReadingOwner() async throws {
        let limits = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("identities.json"), clock = TestClock(now)
        let original = CodexUsageProvider(readLimits: { limits }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), home: "native-old", clock: { clock.now }, identityCacheURL: cache)
        await original.refreshAccountUsage(historyHours: 24)
        let originalReport = try await original.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(originalReport.accounts?["Codex"]?.first?.home, "native-old")

        clock.advance(61)
        let restarted = CodexUsageProvider(readLimits: { limits }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), home: "native-new", clock: { clock.now }, identityCacheURL: cache)
        await restarted.refreshAccountUsage(historyHours: 24)
        let report = try await restarted.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.accounts?["Codex"]?.count, 1)
        XCTAssertEqual(report.accounts?["Codex"]?.first?.home, "native-new")
        XCTAssertEqual(report.accounts?["Codex"]?.first?.client, "Codex")
        XCTAssertEqual(report.snapshots.count, 3)
        XCTAssertTrue(report.snapshots.allSatisfy { $0.updatedAt == clock.now })
    }

    func testChangingPiHomeReplacesItsOwnerRestoredFromTheLastReport() async throws {
        let native = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace")
        let pi = try PiCodexClient.parse(Data(Self.payload.replacingOccurrences(of: "A@Example.com", with: "b@example.com").utf8),
                                       expectedAccount: "workspace")
        let cached = AccountObservation(account: pi.providerAccount(home: "pi:old"), home: "pi:old", client: "Pi",
                                        observedAt: now.addingTimeInterval(-100))
        let now = now
        let restarted = CodexUsageProvider(readLimits: { native }, transcripts: CodexTranscriptStore(roots: []),
            history: QuotaHistoryStore(), clock: { now }, readPiLimits: { pi }, piHome: "pi:new",
            readLoginAt: { _ in now.addingTimeInterval(-1000) }, initialAccounts: [cached])
        await restarted.refreshAccountUsage(historyHours: 24)
        let report = try await restarted.fetchUsage(agents: [], historyHours: 24)
        let observation = try XCTUnwrap(report.accounts?["Codex"]?.first { $0.account == cached.account })
        XCTAssertEqual(report.accounts?["Codex"]?.count, 2)
        XCTAssertEqual(observation.home, "pi:new")
        XCTAssertEqual(observation.client, "Pi")
        XCTAssertEqual(observation.observedAt, now)
        XCTAssertEqual(report.snapshots.count, 6)
        XCTAssertTrue(report.snapshots.allSatisfy { $0.updatedAt == now })
    }

    func testLoginTimeUsesAuthenticationTimeAndNeverTokenRefreshTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        func token(_ claims: [String: Double]) throws -> String {
            "e30." + (try JSONSerialization.data(withJSONObject: claims)).base64EncodedString() + ".signature"
        }
        for issued in [now.timeIntervalSince1970, now.timeIntervalSince1970 + 3600] {
            let data = try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": token([
                "auth_time": now.timeIntervalSince1970 - 100, "iat": issued])]])
            try data.write(to: file)
            XCTAssertEqual(CodexLoginTime.native(in: directory), now.addingTimeInterval(-100))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
        let data = try JSONSerialization.data(withJSONObject: ["openai-codex": ["access": token(["iat": now.timeIntervalSince1970])]])
        try data.write(to: file)
        XCTAssertNil(CodexLoginTime.pi(in: directory), "a token's issue time is not a sign-in time")
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    /// An unread Pi login's failure belongs to its client home, without holding back native quota or Pi transcripts.
    func testAPiLoginThatWasNeverReadKeepsItsOwnNotice() async throws {
        let a = try PiCodexClient.parse(Data(Self.payload.utf8), expectedAccount: "workspace"), now = now
        let provider = CodexUsageProvider(readLimits: { a }, transcripts: CodexTranscriptStore(roots: []), history: QuotaHistoryStore(),
                                          clock: { now }, readPiLimits: { throw UsageProviderError("Pi offline") })
        await provider.refreshAccountUsage(historyHours: 24)
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.sourceNotices, ["Codex@pi": "Pi offline"])
        XCTAssertEqual(report.readingIssues, ["Codex@pi": .readFailed("Pi offline")])
        XCTAssertEqual(report.quotaNotices, ["Codex@pi": "Pi offline"])
        let native = try XCTUnwrap(report.discoveredAgents.first)
        XCTAssertEqual(report.status(of: .window(native)), .normal)
        let pi = AgentDescriptor(id: "pi-model:kimi-k2", vendor: "Pi", model: "kimi-k2", source: "", enabled: true)
        let earlier = UsageReport(generatedAt: now.addingTimeInterval(-600), snapshots: [], sessions: [
            LiveSession(id: "pi-session", agentId: pi.id, task: "task", terminal: nil, startedAt: now.addingTimeInterval(-3600),
                        endedAt: now.addingTimeInterval(-600), pctOfWindow: nil, tokensIn: 1, tokensOut: 1)
        ], consumers: [pi])
        XCTAssertEqual(report.retainingReadings(from: earlier).sessions.map(\.id), [], "the Pi client's last sessions are not kept")
    }

    private actor Steps {
        var values: [Result<CodexRateLimits, UsageProviderError>]
        init(_ values: [Result<CodexRateLimits, UsageProviderError>]) { self.values = values }
        func next() throws -> CodexRateLimits? { try values.removeFirst().get() }
    }
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
    }
}

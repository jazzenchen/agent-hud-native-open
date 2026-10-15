#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class RetainedUsageProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPartialFailureKeepsQuotaBalanceCreditsAndObservationTimes() async throws {
        let good = report(at: now, remaining: 64, balance: 12, credits: 2)
        let partial = report(at: now.addingTimeInterval(3600), remaining: nil, balance: nil, credits: nil)
        let provider = RetainedUsageProvider(provider: SequenceProvider([good, partial]))
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        let result = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(result.snapshots, good.snapshots)
        XCTAssertEqual(result.billing.first?.balances, good.billing.first?.balances)
        XCTAssertEqual(result.billing.first?.updatedAt, now)
        XCTAssertEqual(result.codexResetCredits?.availableCount, 2)
        XCTAssertEqual(result.codexResetCreditsObservedAt, now)
        XCTAssertEqual(result.subscriptions["Codex"], "Pro")
    }

    func testSuccessfulZeroReplacesPreviousValues() async throws {
        let provider = RetainedUsageProvider(provider: SequenceProvider([
            report(at: now, remaining: 64, balance: 12, credits: 2),
            report(at: now.addingTimeInterval(3600), remaining: 0, balance: 0, credits: 0)
        ]))
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        let result = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(result.snapshots.first?.remainingPct, 0)
        XCTAssertEqual(result.snapshots.first?.updatedAt, now.addingTimeInterval(3600))
        XCTAssertEqual(result.billing.first?.balances.first?.total, 0)
        XCTAssertEqual(result.codexResetCredits?.availableCount, 0)
    }

    func testOfflineRestartRestoresTheLastSuccessfulReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.json")
        let good = report(at: now, remaining: 64, balance: 12, credits: 2)
        let first = RetainedUsageProvider(provider: SequenceProvider([good]), cacheURL: file)
        _ = try await first.fetchUsage(agents: [], historyHours: 24)
        let restarted = RetainedUsageProvider(provider: SequenceProvider([]), cacheURL: file)
        XCTAssertEqual(restarted.initialReport, good.startingRowClocks())
        do {
            _ = try await restarted.fetchUsage(agents: [], historyHours: 24)
            XCTFail("A cached report must not turn a failed refresh into success")
        } catch { XCTAssertEqual(error.localizedDescription, "offline") }
        XCTAssertEqual(restarted.initialReport, good.startingRowClocks())
    }

    func testRestartCopyIsRewrittenAtMostOncePerInterval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.json")
        let reports = [0, 5, 61].map { report(at: now.addingTimeInterval($0), remaining: 64 - $0 / 10, balance: 12, credits: 2) }
        let provider = RetainedUsageProvider(provider: SequenceProvider(reports), cacheURL: file, saveInterval: 60)
        func saved() throws -> Date? { try JSONDecoder().decode(UsageReport.self, from: Data(contentsOf: file)).generatedAt }
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(try saved(), now, "The first reading is saved at once")
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(try saved(), now, "A poll inside the interval does not rewrite the copy")
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(try saved(), now.addingTimeInterval(61))
    }

    func testOfflineRestartPreservesCachedPlansAndTokenHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.json")
        let pool = OpenAgentCredentials.credential(.kimi, token: "fixture-key", client: "Pi").pool
        let id = pool.windowID("weekly")
        let usage = UsageBucket(start: now, agentId: "pi-model", tokensIn: 10, tokensOut: 20)
        let saved = UsageReport(generatedAt: now, snapshots: [.init(agentId: id, remainingPct: 90, updatedAt: now)],
            sessions: [],
            discoveredAgents: [.init(id: id, vendor: "Kimi", model: "7d", source: "Pi", enabled: true, billingPool: pool)],
            consumers: [.init(id: "pi-model", vendor: "Pi", model: "model", source: "local", enabled: true)],
            usage: [usage], subscriptions: [pool.id: "Allegretto"],
            services: [.init(client: "Pi", provider: "Kimi", product: .plan, accountID: pool.id)])
        try JSONEncoder().encode(saved).write(to: file)
        let restarted = RetainedUsageProvider(provider: SequenceProvider([]), cacheURL: file)
        XCTAssertEqual(restarted.initialReport, saved)
    }

    func testRestartCopyWithFieldsOfEarlierVersionsStillLoads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.json")
        let saved = report(at: now, remaining: 64, balance: 12, credits: 2)
        let current = try XCTUnwrap(String(data: JSONEncoder().encode(saved), encoding: .utf8))
        let insights = #"{"weeklyCapHits":1,"weeklyWaitTotal":0,"weeklyWaitLongest":0,"weeklyShare":{},"windowSessionCount":2,"windowUsedPct":28}"#
        let earlier = #""history":[{"agentId":"codex","hourStart":0,"remainingStart":90,"remainingEnd":80,"tokens":0}],"#
            + #""activity":{"tokensByModel":[]},"insights":"# + insights + #","subscriptionType":"max","#
        try Data(("{" + earlier + current.dropFirst()).utf8).write(to: file)
        XCTAssertEqual(RetainedUsageProvider(provider: SequenceProvider([]), cacheURL: file).initialReport, saved)
        XCTAssertEqual(try JSONDecoder().decode(UsageInsights.self, from: Data(insights.utf8)).weeklyCapHits, 1)
    }

    @MainActor
    func testFailedRefreshKeepsVisibleReadingsAndExposesTheError() async {
        let suite = "RetainedUsageTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = report(at: now, remaining: 64, balance: 12, credits: 2)
        let provider = RetainedUsageProvider(provider: SequenceProvider([good]))
        let store = UsageStore(provider: provider, settings: SettingsStore(defaults: defaults))
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.report, good.startingRowClocks())
        XCTAssertEqual(store.lastError, "offline")
        store.stop()
    }

    @MainActor
    func testRetainedSessionDoesNotBecomeFreshWhenAnotherSourceUpdates() async throws {
        let current = Date(), old = current.addingTimeInterval(-86400)
        let agent = AgentDescriptor(id: "pi-model:test", vendor: "Pi", model: "test", source: "local", enabled: true)
        let session = LiveSession(id: "pi:old", agentId: agent.id, task: "old task", terminal: nil,
            startedAt: old, pctOfWindow: nil, tokensIn: 10, tokensOut: 2, observedAt: old)
        let previous = UsageReport(generatedAt: old, snapshots: [], sessions: [session],
            consumers: [agent])
        let incoming = UsageReport(generatedAt: current, snapshots: [], sessions: [],
            sourceNotices: ["Pi": "local read failed"])
        let provider = RetainedUsageProvider(provider: SequenceProvider([previous, incoming]))
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        let retained = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(retained.sessions, [session])
        XCTAssertNil(retained.sessions.first?.endedAt, "Failure is not an observed completion")
        XCTAssertEqual(try JSONDecoder().decode(UsageReport.self, from: JSONEncoder().encode(retained)).sessions, [session])
        let suite = "StaleSessionTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: provider, settings: SettingsStore(defaults: defaults))
        store.replace(report: retained)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertFalse(store.hasLiveSession)
        XCTAssertEqual(store.sessionStatusLabel(session), L10n.text("状态待更新", "Status out of date"))
    }

    func testOnlyAQuotaNoticeKeepsTheSessionsASourceNoLongerReports() async throws {
        let agent = AgentDescriptor(id: "grok-model:test", vendor: "Grok", model: "test", source: "local", enabled: true)
        let session = LiveSession(id: "grok:old", agentId: agent.id, task: "old task", terminal: nil,
            startedAt: now, pctOfWindow: nil, tokensIn: 10, tokensOut: 2, observedAt: now)
        let previous = UsageReport(generatedAt: now, snapshots: [], sessions: [session], consumers: [agent])
        func next(quotaNotices: [String: String]) -> UsageReport {
            UsageReport(generatedAt: now.addingTimeInterval(60), snapshots: [], sessions: [],
                        sourceNotices: ["Grok": "Grok log formats overlap"], quotaNotices: quotaNotices)
        }
        let provider = RetainedUsageProvider(provider: SequenceProvider([
            previous, next(quotaNotices: [:]), previous, next(quotaNotices: ["Grok": "Sign in to Grok CLI, then refresh quota"]),
        ]))
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        let local = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(local.sourceNotices["Grok"], "Grok log formats overlap")
        XCTAssertTrue(local.sessions.isEmpty, "a notice about local logs keeps nothing its read no longer has")
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        let failed = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(failed.sessions, [session])
    }

    func testGrokQuotaFailureCannotRestoreBotSessionsFromAnotherAccountPartition() async throws {
        let agent = AgentDescriptor(id: "grok-model:Unknown", vendor: "Grok", model: "Unknown", source: "local", enabled: true)
        func session(_ id: String, client: String) -> LiveSession {
            LiveSession(id: id, agentId: agent.id, task: "Synthetic session", terminal: nil, startedAt: now,
                        pctOfWindow: nil, tokensIn: 0, tokensOut: 0, client: client, observedAt: now)
        }
        let cli = session("grok:cli", client: "Grok CLI")
        let old = session("grok-bot:old:agent", client: "Grok Bot"), current = session("grok-bot:current:agent", client: "Grok Bot")
        let previous = UsageReport(generatedAt: now, snapshots: [], sessions: [cli, old], consumers: [agent])
        let changed = UsageReport(generatedAt: now.addingTimeInterval(60), snapshots: [], sessions: [current],
                                  quotaNotices: ["Grok": "Quota unavailable"], readingIssues: ["Grok": .readFailed("Quota unavailable")])
        let signedOut = UsageReport(generatedAt: now.addingTimeInterval(120), snapshots: [], sessions: [],
                                    quotaNotices: ["Grok": "Quota unavailable"], readingIssues: ["Grok": .readFailed("Quota unavailable")])
        let provider = RetainedUsageProvider(provider: SequenceProvider([previous, changed, signedOut]))
        _ = try await provider.fetchUsage(agents: [], historyHours: 24)
        let switched = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(Set(switched.sessions.map(\.id)), [cli.id, current.id])
        let out = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(out.sessions.map(\.id), [cli.id], "quota failure retains CLI history, but not a removed Bot roster")
    }

    func testARowUnseenForTheRetentionPeriodRetiresWithItsReading() async throws {
        let kept = AgentDescriptor(id: "kept", vendor: "Antigravity", model: "Gemini", source: "", enabled: true)
        let gone = AgentDescriptor(id: "gone", vendor: "Antigravity", model: "Claude", source: "", enabled: true)
        func pass(_ date: Date, _ rows: [AgentDescriptor]) -> UsageReport {
            UsageReport(generatedAt: date, snapshots: rows.map { .init(agentId: $0.id, remainingPct: 50, updatedAt: date) },
                        sessions: [], discoveredAgents: rows)
        }
        let retention = QuotaHistoryStore.retention
        let provider = RetainedUsageProvider(provider: SequenceProvider([
            pass(now, [kept, gone]), pass(now.addingTimeInterval(retention - 60), [kept]), pass(now.addingTimeInterval(retention + 60), [kept]),
        ]))
        let first = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(first.rowSeenAt, ["kept": now, "gone": now])
        let within = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(within.discoveredAgents.map(\.id), ["kept", "gone"], "a row missing for less than the retention period stays")
        XCTAssertEqual(within.rowSeenAt?["gone"], now)
        XCTAssertNotNil(within.snapshot(for: "gone"))
        let after = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(after.discoveredAgents.map(\.id), ["kept"])
        XCTAssertNil(after.snapshot(for: "gone"))
        XCTAssertEqual(after.rowSeenAt, ["kept": now.addingTimeInterval(retention + 60)])
    }

    func testRowsFromAReportThatKeptNoSightingsStartTheirClockAtTheNextPass() async throws {
        let old = AgentDescriptor(id: "old", vendor: "Antigravity", model: "Gemini", source: "", enabled: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = UsageReport(generatedAt: now.addingTimeInterval(-90 * 86400), snapshots: [], sessions: [], discoveredAgents: [old])
        try JSONEncoder().encode(saved).write(to: file)
        let later = now
        let provider = RetainedUsageProvider(provider: SequenceProvider([
            UsageReport(generatedAt: later, snapshots: [], sessions: [], discoveredAgents: []),
        ]), cacheURL: file)
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.discoveredAgents.map(\.id), ["old"], "an upgrade does not retire rows it never timed")
        XCTAssertEqual(report.rowSeenAt, ["old": later])
    }

    private func report(at date: Date, remaining: Double?, balance: Decimal?, credits: Int?) -> UsageReport {
        let descriptor = AgentDescriptor(id: "codex", vendor: "Codex", model: "5h", source: "", enabled: true)
        return UsageReport(generatedAt: date,
            snapshots: remaining.map { [.init(agentId: "codex", remainingPct: $0, resetAt: now.addingTimeInterval(60), updatedAt: date)] } ?? [],
            sessions: [], discoveredAgents: [descriptor], subscriptions: remaining == nil ? [:] : ["Codex": "Pro"],
            sourceNotices: remaining == nil ? ["Codex": "offline"] : [:],
            billing: [.init(vendor: "DeepSeek", balances: balance.map { [.init(currency: "CNY", total: $0, granted: 0, toppedUp: $0)] } ?? [],
                isAvailable: balance.map { $0 > 0 }, updatedAt: balance == nil ? nil : date, costs: [], notice: nil)],
            codexResetCredits: credits.map { .init(availableCount: $0, credits: nil) },
            codexResetCreditsObservedAt: credits == nil ? nil : date)
    }
}

private actor SequenceProvider: UsageProvider {
    var reports: [UsageReport]
    init(_ reports: [UsageReport]) { self.reports = reports }
    func fetchUsage(agents: [AgentDescriptor], historyHours: Int) throws -> UsageReport {
        guard !reports.isEmpty else { throw UsageProviderError("offline") }
        return reports.removeFirst()
    }
}
#endif

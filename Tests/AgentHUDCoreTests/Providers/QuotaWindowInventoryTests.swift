#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class QuotaWindowInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = ProviderAccount.identified(provider: "Antigravity", user: "current@example.com", workspace: "team")!
    private let historical = ProviderAccount.identified(provider: "Antigravity", user: "old@example.com", workspace: "team")!
    private let modernKeys = ["antigravity:gemini-weekly", "antigravity:gemini-5h", "antigravity:3p-weekly", "antigravity:3p-5h"]
    private let legacyKeys = ["antigravity:legacy:gemini", "antigravity:legacy:claude-gpt"]
    private let summaryJSON = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","remainingFraction":0.7},{"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","remainingFraction":0.8}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","remainingFraction":0.9}]}]}"#

    func testSuccessfulSummaryRetiresLegacyOmittedBucketAndFormerAccountWhileWindowSwitchesRemain() async throws {
        let initialRows = (legacyKeys + modernKeys).map { row($0, account: current) }
            + [row(modernKeys[0], account: historical, enabled: false), row(modernKeys[2], account: historical, enabled: false)]
        let previous = savedReport(initialRows, at: now.addingTimeInterval(-60))
        let incoming = try await report(summary(), at: now)
        let updated = incoming.retainingReadings(from: previous)
        let currentIDs = Set(modernKeys.prefix(3).map(current.windowID))
        XCTAssertEqual(Set(updated.discoveredAgents.map(\.id)), currentIDs)
        XCTAssertEqual(Set(updated.snapshots.map(\.agentId)), currentIDs)
        XCTAssertEqual(Set(updated.rowSeenAt?.keys ?? Dictionary<String, Date>().keys), currentIDs)
        for key in legacyKeys + [modernKeys[3]] {
            XCTAssertNil(updated.snapshot(for: current.windowID(key)))
            XCTAssertNil(updated.consumerIdsByQuota[current.windowID(key)])
        }
        XCTAssertNil(updated.snapshot(for: historical.windowID(modernKeys[0])))
        XCTAssertNil(updated.observation(accountID: historical.id))

        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: initialRows)
        settings.setAgent(id: current.windowID(modernKeys[0]), enabled: false)
        let expected = settings.agents.filter { currentIDs.contains($0.id) }
        settings.mergeDiscovered(from: updated)
        XCTAssertEqual(settings.agents.map(\.id), expected.map(\.id))
        XCTAssertEqual(settings.agents.map(\.enabled), expected.map(\.enabled))
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: updated)
        XCTAssertEqual(Set(groups.flatMap(\.agents).map(\.id)), currentIDs)
    }

    func testSummaryThenLegacyFallbackKeepsModernReadingsWithoutDuplicatingThatAccount() async throws {
        let first = try await report(summary(), at: now)
        let fallback = try await report(legacy(account: current), at: now.addingTimeInterval(60))
        XCTAssertNil(fallback.observation(accountID: current.id)?.quotaWindowIDs)
        let held = fallback.retainingReadings(from: first.startingRowClocks())
        XCTAssertEqual(Set(held.discoveredAgents.map(\.id)), Set(first.discoveredAgents.map(\.id)))
        XCTAssertEqual(held.snapshots, first.snapshots, "Fallback does not refresh the modern windows' observation times")
        XCTAssertTrue(held.completeQuotaWindowInventories.isEmpty, "A fallback cannot impersonate a complete summary")
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: first.discoveredAgents)
        settings.mergeDiscovered(from: fallback)
        XCTAssertEqual(Set(settings.agents.map(\.id)), Set(first.discoveredAgents.map(\.id)), "Raw Settings merges use the same schema boundary")
        let next = try await report(summary(), at: now.addingTimeInterval(120))
        let refreshed = next.retainingReadings(from: held)
        XCTAssertEqual(Set(refreshed.discoveredAgents.map(\.id)), Set(first.discoveredAgents.map(\.id)))
        XCTAssertTrue(refreshed.snapshots.allSatisfy { $0.updatedAt == next.generatedAt })
    }

    func testMixedRestartCacheDropsSameAccountLegacyEvenWhenSummaryIsUnavailable() async throws {
        let oldRows = (modernKeys + legacyKeys).map { row($0, account: current) }
            + legacyKeys.map { row($0, account: historical, enabled: false) }
        let previous = savedReport(oldRows, at: now.addingTimeInterval(-60))
        let fallback = try await report(legacy(account: current), at: now)
        let held = fallback.retainingReadings(from: previous)
        let expected = Set(modernKeys.map(current.windowID))
        XCTAssertEqual(Set(held.discoveredAgents.map(\.id)), expected)
        XCTAssertEqual(Set(held.snapshots.map(\.agentId)), expected)
        XCTAssertEqual(Set(held.rowSeenAt?.keys ?? Dictionary<String, Date>().keys), expected)
        XCTAssertEqual(Set(held.consumerIdsByQuota.keys), expected)
        XCTAssertNotNil(held.snapshot(for: current.windowID(modernKeys[3])), "A fallback cannot retire an omitted modern bucket")
        XCTAssertTrue(held.completeQuotaWindowInventories.isEmpty)
        XCTAssertEqual(held.snapshot(for: current.windowID(modernKeys[0]))?.updatedAt, previous.generatedAt)

        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: oldRows)
        settings.mergeDiscovered(from: held)
        XCTAssertEqual(Set(settings.agents.map(\.id)), expected, "Stored legacy preferences retire with the report's superseded rows")
        let rawSettings = SettingsStore(defaults: try makeDefaults(), defaultAgents: oldRows)
        rawSettings.mergeDiscovered(fallback.discoveredAgents, accounts: held.accounts)
        XCTAssertEqual(Set(rawSettings.agents.map(\.id)), expected, "Raw discovery also removes pre-existing schema duplicates")
    }

    func testLegacyStillShowsForAnotherAccountOrAfterEveryModernWindowRetires() async throws {
        let first = try await report(summary(), at: now)
        let other = try await report(legacy(account: historical), at: now.addingTimeInterval(60))
        let switched = other.retainingReadings(from: first.startingRowClocks())
        XCTAssertEqual(Set(switched.discoveredAgents.filter { $0.account == historical }.map(\.windowKey)), Set(legacyKeys))
        XCTAssertTrue(switched.discoveredAgents.allSatisfy { $0.account == historical }, "the replaced account's modern windows retire")
        let later = now.addingTimeInterval(QuotaHistoryStore.retention + 60)
        let fallback = try await report(legacy(account: current), at: later)
        let expired = fallback.retainingReadings(from: first.startingRowClocks())
        XCTAssertEqual(Set(expired.discoveredAgents.map(\.windowKey)), Set(legacyKeys), "Expired modern rows must not suppress the only available fallback")
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: first.discoveredAgents)
        settings.mergeDiscovered(from: expired)
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: expired)
        XCTAssertEqual(Set(groups.flatMap(\.agents).map(\.windowKey)), Set(legacyKeys), "Saved preferences for expired rows do not suppress present fallback windows")
        let freshFallback = try await report(legacy(account: current), at: now)
        XCTAssertEqual(Set(freshFallback.discoveredAgents.map(\.windowKey)), Set(legacyKeys))
    }

    func testEnabledBucketWithoutReadingKeepsItsLastValueAndPresenceButDisabledBucketRetires() async throws {
        let previous = savedReport(modernKeys.map { row($0, account: current) }, at: now.addingTimeInterval(-QuotaHistoryStore.retention - 60))
        let missing = try summary(extraBucket: #",{"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining"}"#)
        let incoming = try await report(missing, at: now)
        XCTAssertEqual(incoming.observation(accountID: current.id)?.quotaWindowIDs, Set(modernKeys.map(current.windowID)))
        XCTAssertNil(incoming.snapshot(for: current.windowID(modernKeys[3])))
        let kept = incoming.retainingReadings(from: previous)
        XCTAssertEqual(kept.snapshot(for: current.windowID(modernKeys[3]))?.updatedAt, previous.generatedAt)
        XCTAssertEqual(kept.rowSeenAt?[current.windowID(modernKeys[3])], now, "Explicit presence renews retention even without a new value")
        XCTAssertEqual(kept.discoveredAgents.count, 4)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: previous.discoveredAgents)
        settings.mergeDiscovered(from: kept)
        XCTAssertEqual(settings.agents.count, 4)

        let disabled = try summary(extraBucket: #",{"bucketId":"3p-5h","disabled":true,"remainingFraction":1}"#)
        let removed = try await report(disabled, at: now.addingTimeInterval(60)).retainingReadings(from: kept)
        settings.mergeDiscovered(from: removed)
        XCTAssertNil(removed.snapshot(for: current.windowID(modernKeys[3])))
        XCTAssertFalse(settings.agents.contains { $0.id == current.windowID(modernKeys[3]) })
    }

    func testEmptySummaryIsExplicitInventoryAndNeverFallsBackToLegacy() async throws {
        let endpoint = AntigravityService.Endpoint(pid: 1,
            base: URL(string: "https://127.0.0.1:42111/exa.language_server_pb.LanguageServerService/")!, token: "fixture-token")
        let client = AntigravityClient(http: ProviderHTTP(send: { request in
            if request.url?.lastPathComponent == "RetrieveUserQuotaSummary" { return Data(#"{"groups":[]}"#.utf8) }
            return Data(#"{"userStatus":{"email":"current@example.com","teamId":"team","cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.5}}]}}}"#.utf8)
        }))
        let quota = try await client.quota(from: endpoint)
        XCTAssertTrue(quota.windows.isEmpty)
        XCTAssertEqual(quota.quotaWindowIDs, [])
        XCTAssertEqual(quota.account, current)
        let previous = savedReport([row(modernKeys[0], account: current), row(modernKeys[0], account: historical)], at: now.addingTimeInterval(-60))
        let incoming = try await report(quota, at: now)
        let updated = incoming.retainingReadings(from: previous)
        XCTAssertTrue(updated.discoveredAgents.isEmpty)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: previous.discoveredAgents)
        settings.mergeDiscovered(from: updated)
        XCTAssertTrue(settings.agents.isEmpty)
    }

    func testCompletenessRequiresExplicitInventoryCurrentAccountAndSoundReadAndSurvivesCopies() async throws {
        let previous = savedReport([row(modernKeys[0], account: current)], at: now.addingTimeInterval(-60))
        let cases: [(Set<String>?, Bool, ReadingIssue?, ReadingIssue?)] = [
            (nil, true, nil, nil), ([], false, nil, nil), ([], true, .readFailed("offline"), nil), ([], true, nil, .readFailed("offline")),
        ]
        for (inventory, isCurrent, ownIssue, sourceIssue) in cases {
            let account = AccountObservation(account: current, observedAt: now, isCurrent: isCurrent, readingIssue: ownIssue, quotaWindowIDs: inventory)
            let incoming = UsageReport(generatedAt: now, snapshots: [], sessions: [], readingIssues: sourceIssue.map { ["Antigravity": $0] } ?? [:],
                                       accounts: ["Antigravity": [account]])
            XCTAssertTrue(incoming.completeQuotaWindowInventories.isEmpty)
            XCTAssertEqual(incoming.retainingReadings(from: previous).snapshots, isCurrent ? previous.snapshots : [])
            let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: previous.discoveredAgents)
            settings.mergeDiscovered(from: incoming)
            XCTAssertEqual(settings.agents.count, isCurrent ? 1 : 0)
        }
        let full = AccountObservation(account: current, observedAt: now, quotaWindowIDs: Set(modernKeys.map(current.windowID)))
        XCTAssertEqual(full.with(isCurrent: false).quotaWindowIDs, full.quotaWindowIDs)
        let original = UsageReport(generatedAt: now, snapshots: [], sessions: [], accounts: ["Antigravity": [full]])
        let restored = try JSONDecoder().decode(UsageReport.self, from: JSONEncoder().encode(original.restartCopy))
        XCTAssertEqual(restored.accounts, original.accounts)
        XCTAssertEqual(restored.startingRowClocks().accounts, original.accounts)
        let old = AccountObservation(account: current, observedAt: now)
        XCTAssertNil(try JSONDecoder().decode(AccountObservation.self, from: JSONEncoder().encode(old)).quotaWindowIDs,
                     "Older cached observations do not guess completeness from account health")
        XCTAssertThrowsError(try AntigravityClient.summary(json(#"{"groups":[{"buckets":[{"remainingFraction":1}]}]}"#)))
    }

    func testFormerSummaryAccountsRetireWhileCurrentLegacyWindowStateRemains() async throws {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let old = [row(modernKeys[0], account: historical, enabled: false), row(modernKeys[2], account: historical, enabled: false),
                   row(legacyKeys[0], account: current, enabled: false)]
        let previous = savedReport(old, at: now.addingTimeInterval(-60))
        let incoming = UsageReport(generatedAt: now, snapshots: [], sessions: [])
        let kept = incoming.retainingReadings(from: previous)
        XCTAssertEqual(kept.discoveredAgents.map(\.shortModel), ["Gemini"])
        XCTAssertEqual(kept.discoveredAgents.map(\.id), [old[2].id])
        XCTAssertEqual(kept.discoveredAgents.map(\.enabled), [false])
        XCTAssertEqual(kept.discoveredAgents.map(\.account), [current])
        XCTAssertEqual(kept.snapshots, previous.snapshots.filter { $0.agentId == old[2].id })
    }

    private func summary(extraBucket: String = "") throws -> ProviderQuota {
        var quota = try AntigravityClient.summary(json(extraBucket.isEmpty ? summaryJSON : summaryJSON.replacingOccurrences(of: #""remainingFraction":0.9}]"#, with: #""remainingFraction":0.9}\#(extraBucket)]"#)))
        quota.account = current
        return quota
    }

    private func legacy(account: ProviderAccount) throws -> ProviderQuota {
        var quota = try AntigravityClient.userStatus(json(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini Pro","quotaInfo":{"remainingFraction":0.4}},{"label":"Claude Sonnet","quotaInfo":{"remainingFraction":0.3}}]}}}"#))
        quota.account = account
        return quota
    }

    private func report(_ quota: ProviderQuota, at date: Date) async throws -> UsageReport {
        let provider = AdditionalUsageProvider(source: .antigravity, readQuota: { quota }, readSessions: { _ in ProviderSessions() },
                                              history: QuotaHistoryStore(), clock: { date })
        await provider.refreshAccountUsage(historyHours: 24)
        return try await provider.fetchUsage(agents: [], historyHours: 24)
    }

    private func row(_ key: String, account: ProviderAccount, enabled: Bool = true) -> AgentDescriptor {
        let word = key.contains("gemini") ? "Gemini" : "3rd-party"
        return AgentDescriptor(id: account.windowID(key), vendor: "Antigravity", model: word, shortModel: word,
                               source: "", enabled: enabled, account: account, allModels: false)
    }

    private func savedReport(_ rows: [AgentDescriptor], at date: Date) -> UsageReport {
        UsageReport(generatedAt: date, snapshots: rows.map {
            .init(agentId: $0.id, remainingPct: 50, windowDuration: $0.windowKey.hasPrefix("antigravity:legacy:") ? nil
                : $0.windowKey.hasSuffix("5h") ? 18000 : 604800, updatedAt: date)
        }, sessions: [], discoveredAgents: rows,
        consumerIdsByQuota: Dictionary(rows.map { ($0.id, Set(["antigravity-model:fixture"])) }, uniquingKeysWith: { first, _ in first }),
        accounts: ["Antigravity": Set(rows.compactMap(\.account)).map {
            AccountObservation(account: $0, observedAt: date, isCurrent: $0 == current)
        }], rowSeenAt: Dictionary(rows.map { ($0.id, date) }, uniquingKeysWith: { first, _ in first }))
    }

    private func json(_ text: String) throws -> ProviderJSON { try ProviderJSON.read(Data(text.utf8)) }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "QuotaWindowInventoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
#endif

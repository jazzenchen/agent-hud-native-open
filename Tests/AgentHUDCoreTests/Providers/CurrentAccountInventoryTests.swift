#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class CurrentAccountInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeSwitchAndSignOutRemoveQuotaButKeepRecordedSessionsAndTokens() throws {
        let old = account("Claude", "old"), current = account("Claude", "current")
        let session = LiveSession(id: "recorded", agentId: "claude-model:sonnet", task: "Recorded session", terminal: nil,
                                  startedAt: now, endedAt: now, pctOfWindow: nil, tokensIn: 100, tokensOut: 20)
        let usage = UsageBucket(start: now, agentId: session.agentId, tokensIn: 100, tokensOut: 20, account: old.id)
        let previous = report([.init(account: old, observedAt: now)], sessions: [session], usage: [usage])
        let incoming = report([.init(account: current, observedAt: now.addingTimeInterval(60))], sessions: [session], usage: [usage])
        let switched = incoming.retainingReadings(from: previous.startingRowClocks())
        XCTAssertEqual(switched.accounts?["Claude"]?.map(\.account), [current])
        XCTAssertEqual(switched.discoveredAgents.map(\.account), [current])
        XCTAssertNil(switched.snapshot(for: row(old).id))
        XCTAssertEqual(switched.sessions, [session])
        XCTAssertEqual(switched.usage, [usage])

        let signedOut = UsageReport(generatedAt: now.addingTimeInterval(120), snapshots: [], sessions: [session],
                                   usage: [usage], accounts: ["Claude": []]).retainingReadings(from: switched)
        XCTAssertEqual(signedOut.accounts?["Claude"], [])
        XCTAssertTrue(signedOut.discoveredAgents.isEmpty)
        XCTAssertTrue(signedOut.snapshots.isEmpty)
        XCTAssertEqual(signedOut.sessions, [session])
        XCTAssertEqual(signedOut.usage, [usage])
    }

    func testFailedClientHomeKeepsItsCurrentAccountWhileAnotherHomeSwitches() {
        let old = account("Codex", "old"), current = account("Codex", "current"), pi = account("Codex", "pi")
        let previous = report([.init(account: old, observedAt: now), .init(account: pi, home: "pi:work", observedAt: now)])
        let incoming = report([.init(account: current, observedAt: now.addingTimeInterval(60))],
                              issues: [ClientHome.sourceKey(provider: "Codex", home: "pi:work"): .readFailed("offline")])
        let partial = incoming.retainingReadings(from: previous.startingRowClocks())
        XCTAssertEqual(Set(partial.accounts?["Codex"]?.map(\.account) ?? []), [current, pi])
        XCTAssertTrue(partial.accounts?["Codex"]?.allSatisfy(\.isCurrent) == true)
        XCTAssertNil(partial.snapshot(for: row(old).id))
        XCTAssertEqual(partial.snapshot(for: row(pi).id)?.updatedAt, now)
        XCTAssertEqual(Set(partial.discoveredAgents.compactMap(\.account)), [current, pi])

        let confirmed = report([.init(account: current, observedAt: now.addingTimeInterval(120))])
            .retainingReadings(from: partial)
        XCTAssertEqual(confirmed.accounts?["Codex"]?.map(\.account), [current])
        XCTAssertNil(confirmed.snapshot(for: row(pi).id), "a confirmed inventory without the Pi account retires it")
    }

    func testOldRestartCopyHidesFormerAccountsBeforeAnySuccessfulRefresh() throws {
        let old = account("Claude", "old"), current = account("Claude", "current")
        let saved = report([.init(account: old, observedAt: now, isCurrent: false), .init(account: current, observedAt: now)])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("account-inventory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(saved.restartCopy).write(to: file)
        let restored = try XCTUnwrap(RetainedUsageProvider(provider: DemoUsageProvider(), cacheURL: file).initialReport)
        let suite = "CurrentAccountInventoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: saved.discoveredAgents)
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: restored)
        XCTAssertEqual(store.rows.map(\.id), [row(current).id])
        XCTAssertEqual(store.visibleAgents.map(\.id), [row(current).id])
        let group = try XCTUnwrap(AgentSettingsGroup.make(sources: [], agents: settings.agents, report: restored).first)
        XCTAssertEqual(group.accounts.map(\.account), [current])
        XCTAssertEqual(group.agents.map(\.id), [row(current).id])
        XCTAssertTrue(group.unobservedAccounts.isEmpty, "former accounts cannot reappear as unnamed settings fallbacks")

        let failed = UsageReport(generatedAt: now.addingTimeInterval(60), snapshots: [], sessions: [],
                                 readingIssues: ["Claude": .readFailed("offline")]).retainingReadings(from: restored)
        store.replace(report: failed)
        XCTAssertEqual(store.rows.map(\.id), [row(current).id])
        XCTAssertEqual(failed.snapshot(for: row(current).id)?.updatedAt, now)
    }

    private func account(_ provider: String, _ user: String) -> ProviderAccount {
        ProviderAccount.identified(provider: provider, user: user, workspace: "workspace")!
    }

    private func row(_ account: ProviderAccount) -> AgentDescriptor {
        AgentDescriptor(id: account.windowID("session"), vendor: account.provider, model: "5h", source: "", enabled: true, account: account)
    }

    private func report(_ observations: [AccountObservation], sessions: [LiveSession] = [], usage: [UsageBucket] = [],
                        issues: [String: ReadingIssue] = [:]) -> UsageReport {
        let rows = observations.map { row($0.account) }
        return UsageReport(generatedAt: now.addingTimeInterval(60), snapshots: rows.map {
            .init(agentId: $0.id, remainingPct: 50, updatedAt: now)
        }, sessions: sessions, discoveredAgents: rows, usage: usage, readingIssues: issues,
        accounts: Dictionary(grouping: observations, by: { $0.account.provider }))
    }
}
#endif

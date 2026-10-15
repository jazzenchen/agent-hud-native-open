#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

/// What the store gives the island beside its rows: the notice above an account's windows, and the vendors among
/// which an alert's pulse is placed.
final class IslandStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// An account's own notice comes first, then its client's, which carries notices about local logs and hooks too.
    /// A billing pool's section shows its own account's notice only, whatever its vendor says.
    @MainActor
    func testASectionShowsItsAccountsNoticeElseItsClientsUnlessItIsAPool() throws {
        let suite = "IslandStoreTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failed = try XCTUnwrap(ProviderAccount.identified(provider: "Codex", user: "failed@example.com", workspace: nil))
        let fine = try XCTUnwrap(ProviderAccount.identified(provider: "Codex", user: "fine@example.com", workspace: nil))
        let pools = ["failing", "working"].map {
            BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: $0, evidence: .credential, entitlement: "kimi-code")
        }
        let agents = [failed, fine].map {
            AgentDescriptor(id: $0.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: $0)
        } + pools.map {
            AgentDescriptor(id: $0.windowID("weekly"), vendor: "Kimi", model: "Weekly", source: "", enabled: true,
                            billingPool: $0, account: ProviderAccount(pool: $0))
        } + [AgentDescriptor(id: "grok", vendor: "Grok", model: "Credits", source: "", enabled: true)]
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: agents))
        store.replace(report: UsageReport(
            generatedAt: now, snapshots: agents.map { .init(agentId: $0.id, remainingPct: 50, updatedAt: now) }, sessions: [],
            discoveredAgents: agents,
            sourceNotices: ["Codex": "Codex hooks could not be read", "Kimi": "Pool: read failed", "Grok": "Grok logs could not be read"],
            quotaNotices: [:],
            accounts: ["Codex": [.init(account: failed, observedAt: now, quotaNotice: "Quota read failed"), .init(account: fine, observedAt: now)],
                       "Kimi": [.init(account: ProviderAccount(pool: pools[0]), observedAt: now, quotaNotice: "read failed"),
                                .init(account: ProviderAccount(pool: pools[1]), observedAt: now)]]))
        store.now = now

        let sections = store.rowGroups.flatMap { store.accountSections($0.rows) }
        XCTAssertEqual(sections.map(\.id), [failed.id, fine.id] + pools.map(\.id) + [""])
        XCTAssertEqual(sections.map { store.accountNotice(for: $0) },
                       ["Quota read failed · Codex hooks could not be read", "Codex hooks could not be read", "read failed", nil, nil],
                       "a notice that holds nothing back still shows above a fine account; a pool never shows its vendor's")
    }

    /// The pulse and the colours share one list of segments: every row whose reading shows a level, a reading half an
    /// hour old included, and every balance, each in its place. A held back, signed-out or reset-passed reading has none.
    @MainActor
    func testTheAlertPulseAndTheColoursShareOneListOfSegments() throws {
        let suite = "IslandStoreTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = try XCTUnwrap(ProviderAccount.identified(provider: "Codex", user: "current@example.com", workspace: nil))
        let old = try XCTUnwrap(ProviderAccount.identified(provider: "Codex", user: "old@example.com", workspace: nil))
        func agent(_ id: String, _ vendor: String, account: ProviderAccount? = nil) -> AgentDescriptor {
            AgentDescriptor(id: account?.windowID(id) ?? id, vendor: vendor, model: id, source: "", enabled: true, account: account)
        }
        // Each row: its descriptor, what is left, and how long ago it was read and until its reset.
        let rows: [(agent: AgentDescriptor, remaining: Double, readAgo: TimeInterval, resetIn: TimeInterval)] = [
            (agent("session", "Claude"), 40, 0, 3600),
            (agent("weekly", "Claude"), 40, QuotaForecast.maximumReadingAge, 3600),
            (agent("current", "Codex", account: current), 5, 0, 3600),
            (agent("old", "Codex", account: old), 50, 0, 3600),
            (agent("credits", "Grok"), 50, 0, -1),
            (agent("included", "Cursor"), 50, 0, 3600),
        ]
        let balance = AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true)
        let agents = rows.prefix(2).map { $0.agent } + [balance] + rows.dropFirst(2).map { $0.agent }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: agents))
        store.replace(report: UsageReport(
            generatedAt: now,
            snapshots: rows.map { .init(agentId: $0.agent.id, remainingPct: $0.remaining, resetAt: now.addingTimeInterval($0.resetIn),
                                        updatedAt: now.addingTimeInterval(-$0.readAgo)) },
            sessions: [], discoveredAgents: agents, quotaNotices: ["Cursor": "Cursor quota could not be read"],
            billing: [APIBilling(vendor: "DeepSeek", balances: [.init(currency: "CNY", total: 5, granted: 0, toppedUp: 5)],
                                 isAvailable: true, updatedAt: now, notice: nil)],
            accounts: ["Codex": [.init(account: current, observedAt: now), .init(account: old, observedAt: now, isCurrent: false)]]))
        store.now = now

        XCTAssertEqual(store.alertPulseVendors, ["Claude", "Claude", "DeepSeek", "Codex"])
        XCTAssertEqual(store.levels, [.ok, .ok, .warning, .critical], "a Codex alert lights the segment that shows Codex's colour")
    }
}
#endif

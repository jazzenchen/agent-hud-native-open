#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

/// Which quota rows, balances, vendor groups and account sections the island and menu show, and which rows Settings
/// lists, for the same agent list under reports that say more or less about its rows.
final class RowPresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = ProviderAccount.identified(provider: "Codex", user: "current@example.com", workspace: nil)!
    private let other = ProviderAccount.identified(provider: "Codex", user: "other@example.com", workspace: nil)!
    private let unlisted = ProviderAccount.identified(provider: "Codex", user: "unlisted@example.com", workspace: nil)!
    private let kimiActive = RowPresenceTests.pool("Kimi", "active")
    private let kimiInactive = RowPresenceTests.pool("Kimi", "inactive")
    private let glm = RowPresenceTests.pool("GLM", "glm")

    /// Every kind of row, in the order the settings keep them: a Claude row the fuller report lists, one it does not
    /// and one switched off; an API row the fuller report does not list either; two Kimi plan pools, one of which the
    /// fuller report calls inactive; a GLM plan pool whose provider that report's inventory leaves out; and Codex rows
    /// of the current account, of another account, and of an account missing from the inventory.
    private var agents: [AgentDescriptor] {
        [AgentDescriptor(id: "claude", vendor: "Claude", model: "5h", source: "", enabled: true),
         AgentDescriptor(id: "claude-unseen", vendor: "Claude", model: "Weekly", source: "", enabled: true),
         AgentDescriptor(id: "claude-off", vendor: "Claude", model: "Opus", source: "", enabled: false),
         AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true)]
        + [("kimi-active", kimiActive), ("kimi-inactive", kimiInactive), ("glm", glm)].map { id, pool in
            AgentDescriptor(id: id, vendor: pool.provider, model: "Weekly", source: "", enabled: true, billingPool: pool,
                            account: ProviderAccount(pool: pool))
        }
        + [("codex-current", current), ("codex-other", other), ("codex-unlisted", unlisted)].map { id, account in
            AgentDescriptor(id: id, vendor: "Codex", model: "5h", source: "", enabled: true, account: account)
        }
    }

    /// What the surfaces show, by row id.
    private struct Presence: Equatable {
        var visible: [String]
        var enabled: [String]
        /// Quota rows, a row of an account the client is not signed in to marked so.
        var rows: [String]
        var billing: [String]
        /// Vendor groups and their rows, then each group's account sections.
        var groups: [String]
        var sections: [String]
        /// Settings' groups, their rows and their accounts.
        var settings: [String]
    }

    @MainActor
    func testWhatEachSurfaceShowsOfTheSameRows() async throws {
        let everyRow = agents.map(\.id)
        let bare = UsageReport(generatedAt: now, snapshots: [], sessions: [], billing: [balance], accounts: inventory)
        let fuller = UsageReport(generatedAt: now, snapshots: [], sessions: [], billing: [balance],
                                 activeQuotaPoolIDs: ["Kimi": [kimiActive.id]], accounts: inventory,
                                 rowSeenAt: Dictionary(uniqueKeysWithValues: everyRow.filter { !["claude-unseen", "deepseek"].contains($0) }
                                     .map { ($0, now) }))
        let codexRows = "Codex: codex-current, codex-other, codex-unlisted"
        let cases: [(String, UsageReport?, Presence)] = [
            // Without a report nothing says a row is gone, so every row is present, plan pools included, on every
            // surface as in Settings, and every row reads as its account's current one.
            ("no report", nil, Presence(
                visible: everyRow,
                enabled: everyRow.filter { $0 != "claude-off" },
                rows: ["claude", "claude-unseen", "kimi-active", "kimi-inactive", "glm", "codex-current", "codex-other", "codex-unlisted"],
                billing: [],
                groups: ["Claude: claude, claude-unseen", "Kimi: kimi-active, kimi-inactive", "GLM: glm", codexRows],
                sections: ["Claude: no account", "Kimi: kimi-active", "Kimi: kimi-inactive", "GLM: glm", "Codex: current", "Codex: other",
                           "Codex: unlisted"],
                settings: ["Claude: claude, claude-unseen, claude-off", "DeepSeek: deepseek", "Kimi: kimi-active, kimi-inactive",
                           "GLM: glm", codexRows])),
            // A report that keeps no sightings and has no pool inventory still excludes former and unlisted accounts.
            ("a report without sightings or pool inventory", bare, Presence(
                visible: everyRow.filter { !["codex-other", "codex-unlisted"].contains($0) },
                enabled: everyRow.filter { !["claude-off", "codex-other", "codex-unlisted"].contains($0) },
                rows: ["claude", "claude-unseen", "kimi-active", "kimi-inactive", "glm", "codex-current"],
                billing: ["DeepSeek"],
                groups: ["Claude: claude, claude-unseen", "Kimi: kimi-active, kimi-inactive", "GLM: glm", "Codex: codex-current"],
                sections: ["Claude: no account", "Kimi: kimi-active", "Kimi: kimi-inactive", "GLM: glm", "Codex: current"],
                settings: ["Claude: claude, claude-unseen, claude-off", "DeepSeek: deepseek", "Kimi: kimi-active, kimi-inactive",
                           "GLM: glm", "Codex: codex-current; accounts current"])),
            // An unlisted row, an inactive pool and a row of an account missing from its inventory go everywhere; the API
            // row's balance goes with its row.
            ("a report with sightings and a pool inventory", fuller, Presence(
                visible: ["claude", "claude-off", "kimi-active", "glm", "codex-current"],
                enabled: ["claude", "kimi-active", "glm", "codex-current"],
                rows: ["claude", "kimi-active", "glm", "codex-current"],
                billing: [],
                groups: ["Claude: claude", "Kimi: kimi-active", "GLM: glm", "Codex: codex-current"],
                sections: ["Claude: no account", "Kimi: kimi-active", "GLM: glm", "Codex: current"],
                settings: ["Claude: claude, claude-off", "Kimi: kimi-active", "GLM: glm", "Codex: codex-current; accounts current"])),
        ]
        for (name, report, expected) in cases {
            let store = UsageStore(provider: DemoUsageProvider(), settings: try makeSettings(agents))
            if let report { store.replace(report: report) }
            XCTAssertEqual(presence(in: store), expected, name)
        }
    }

    /// What a pass makes of a Codex read that leaves one of the current account's windows out. The kept report and the
    /// settings follow one rule: only a read without an issue replaces the account's windows, and a notice about Codex's
    /// logs is no issue. After a read whose Codex read failed, the row keeps its switch and place in the settings; the
    /// window keeps its reading and its place among the rows shown only when an earlier report had them.
    @MainActor
    func testACodexWindowLeftOutOfAReadKeepsItsRowOnlyWhenAnEarlierReportIsKept() async throws {
        let window = AgentDescriptor(id: current.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: current)
        let spark = AgentDescriptor(id: current.windowID("codex:spark:primary"), vendor: "Codex", model: "Spark", source: "",
                                    enabled: true, account: current)
        func read(_ rows: [AgentDescriptor], at date: Date, notice: String? = nil, failed: String? = nil) -> UsageReport {
            UsageReport(generatedAt: date, snapshots: rows.map { UsageSnapshot(agentId: $0.id, remainingPct: 50, updatedAt: date) },
                        sessions: [], discoveredAgents: rows, sourceNotices: (notice ?? failed).map { ["Codex": $0] } ?? [:],
                        quotaNotices: failed.map { ["Codex": $0] } ?? [:],
                        accounts: ["Codex": [AccountObservation(account: current, observedAt: date, quotaWindowIDs: Set(rows.map(\.id)))]])
        }
        let earlier = read([window, spark], at: now.addingTimeInterval(-600))
        // The reads a run makes in turn, whether the left-out window keeps its row in the settings, and whether it keeps its
        // place among the rows shown and its reading after the last of them.
        let cases: [(String, [UsageReport], keepsRow: Bool, keepsReading: Bool)] = [
            ("an earlier read, then one whose Codex read failed", [earlier, read([window], at: now, failed: "Codex could not be read")],
             true, true),
            ("an earlier read, then one with a notice about logs", [earlier, read([window], at: now, notice: "Codex logs could not be read")],
             false, false),
            ("an earlier read, then one without", [earlier, read([window], at: now)], false, false),
            ("a first read whose Codex read failed and no restart copy", [read([window], at: now, failed: "Codex could not be read")],
             true, false),
        ]
        for (name, reads, keepsRow, keepsReading) in cases {
            let store = UsageStore(provider: RetainedUsageProvider(provider: Reads(reads)), settings: try makeSettings([window, spark]))
            for _ in reads { await store.refresh() }
            XCTAssertNil(store.lastError, name)
            XCTAssertEqual(store.settings.agents.map(\.id), [window.id] + (keepsRow ? [spark.id] : []), name)
            XCTAssertEqual(store.rows.map(\.id), [window.id] + (keepsReading ? [spark.id] : []), name)
            XCTAssertEqual(store.report?.snapshot(for: spark.id) != nil, keepsReading, name)
        }
    }

    // MARK: Fixtures

    private static func pool(_ provider: String, _ scope: String) -> BillingPool {
        BillingPool(provider: provider, realm: "CN", product: .plan, scope: scope, evidence: .account, entitlement: "coding-plan")
    }

    private var balance: APIBilling {
        APIBilling(vendor: "DeepSeek", balances: [AccountBalance(currency: "CNY", total: 50, granted: 0, toppedUp: 50)],
                   isAvailable: true, updatedAt: now, notice: nil)
    }

    /// The Codex inventory: the current account and another one; the third account's rows are not in it.
    private var inventory: [String: [AccountObservation]] {
        ["Codex": [AccountObservation(account: current, observedAt: now), AccountObservation(account: other, observedAt: now, isCurrent: false)]]
    }

    @MainActor
    private func presence(in store: UsageStore) -> Presence {
        let names = [current.id: "current", other.id: "other", unlisted.id: "unlisted", kimiActive.id: "kimi-active",
                     kimiInactive.id: "kimi-inactive", glm.id: "glm", "": "no account"]
        let groups = AgentSettingsGroup.make(sources: [], agents: store.settings.agents, report: store.report)
        return Presence(
            visible: store.visibleAgents.map(\.id), enabled: store.enabledAgents.map(\.id),
            rows: store.rows.map { $0.id + ($0.isCurrentAccount ? "" : " (another account)") },
            billing: store.enabledBilling.map(\.id),
            groups: store.rowGroups.map { "\($0.vendor): " + $0.rows.map(\.id).joined(separator: ", ") },
            sections: store.rowGroups.flatMap { group in
                store.accountSections(group.rows).map { "\(group.vendor): \(names[$0.id] ?? $0.id)" + ($0.isCurrent ? "" : ", not current") }
            },
            settings: groups.map { group in
                let accounts = group.accounts.map { names[$0.account.id] ?? $0.account.id }
                return "\(group.id): " + group.agents.map(\.id).joined(separator: ", ")
                    + (accounts.isEmpty ? "" : "; accounts " + accounts.joined(separator: ", "))
            })
    }

    @MainActor
    private func makeSettings(_ agents: [AgentDescriptor]) throws -> SettingsStore {
        let suite = "RowPresenceTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SettingsStore(defaults: defaults, defaultAgents: agents)
    }
}

/// Returns the given reports in turn, then fails.
private actor Reads: UsageProvider {
    private var reports: [UsageReport]
    init(_ reports: [UsageReport]) { self.reports = reports }
    func fetchUsage(agents: [AgentDescriptor], historyHours: Int) throws -> UsageReport {
        guard !reports.isEmpty else { throw UsageProviderError("no more reads") }
        return reports.removeFirst()
    }
}
#endif

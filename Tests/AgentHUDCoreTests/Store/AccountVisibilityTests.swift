#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class AccountVisibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let work = ProviderAccount.identified(provider: "Codex", user: "work@example.com", workspace: "team")!
    private let personal = ProviderAccount.identified(provider: "Codex", user: "me@example.com", workspace: "personal")!

    func testAccountSwitchSynchronizesAndPersistsAllItsWindowsWithoutChangingOrderOrOtherAccounts() async throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.hiddenAccountIDs.isEmpty)
        XCTAssertTrue(old.accountVisible(work.id))
        XCTAssertTrue(old.accountVisible(nil), "Unattributed rows keep their own window selection")

        let defaults = try makeDefaults()
        let settings = SettingsStore(defaults: defaults, defaultAgents: quotaAgents)
        settings.moveAgent(id: personal.windowID("codex"), to: 0)
        let orderedWindows = settings.agents
        let savedWindows = defaults.data(forKey: SettingsStore.Keys.agents)
        var changes: [String] = []
        settings.onChange = { change in
            switch change {
            case .settings: changes.append("settings")
            case .agents: changes.append("agents")
            case .discovery: changes.append("discovery")
            }
            XCTAssertFalse(settings.settings.accountVisible(self.work.id))
            XCTAssertEqual(settings.agents.map(\.enabled), [true, false, false], "Observers see both values updated together")
        }

        settings.setAccount(id: work.id, visible: false)
        XCTAssertEqual(changes, ["settings"], "One account action has one change notification")
        XCTAssertEqual(settings.agents.map(\.id), orderedWindows.map(\.id))
        XCTAssertEqual(settings.agents.map(\.enabled), [true, false, false])
        XCTAssertNotEqual(defaults.data(forKey: SettingsStore.Keys.agents), savedWindows)
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.settings.accountVisible(work.id))
        XCTAssertTrue(reloaded.settings.accountVisible(personal.id))
        XCTAssertEqual(reloaded.agents, settings.agents)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(reloaded.settings)), reloaded.settings)

        reloaded.setAccount(id: work.id, visible: true)
        XCTAssertTrue(reloaded.settings.hiddenAccountIDs.isEmpty)
        XCTAssertEqual(reloaded.agents.map(\.id), orderedWindows.map(\.id))
        XCTAssertEqual(reloaded.agents.map(\.enabled), [true, true, true], "Showing enables every window, including one previously off")
        reloaded.setAgent(id: work.windowID("codex-weekly"), enabled: false)
        XCTAssertTrue(reloaded.settings.accountVisible(work.id), "An individual window never changes its account switch")
        reloaded.setAccount(id: work.id, visible: true)
        XCTAssertTrue(reloaded.agents.allSatisfy(\.enabled), "An already visible account can still enable all its windows")
        XCTAssertEqual(SettingsStore(defaults: defaults).agents, reloaded.agents)
    }

    func testPreviouslyHiddenAccountsNormalizeSavedWindowsAtLaunch() async throws {
        let defaults = try makeDefaults()
        var preferences = Settings()
        preferences.setAccountVisibility(id: work.id, visible: false)
        let stored = [quotaAgents[2].with(enabled: false), quotaAgents[0], quotaAgents[1]]
        defaults.set(try JSONEncoder().encode(preferences), forKey: SettingsStore.Keys.settings)
        defaults.set(try JSONEncoder().encode(stored), forKey: SettingsStore.Keys.agents)
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.agents.map(\.id), stored.map(\.id))
        XCTAssertEqual(settings.agents.map(\.enabled), [false, false, false])
        XCTAssertEqual(settings.settings, preferences)
        XCTAssertEqual(try JSONDecoder().decode([AgentDescriptor].self, from: XCTUnwrap(defaults.data(forKey: SettingsStore.Keys.agents))), settings.agents)
        settings.setAccount(id: work.id, visible: true)
        XCTAssertEqual(settings.agents.map(\.enabled), [false, true, true], "The other account's manual window choice remains off")
    }

    func testDiscoveryKeepsNewAccountAndBillingPoolWindowsOffWhileTheirAccountIsHidden() async throws {
        let shared = pool("shared")
        let plan = BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "plan", evidence: .account, entitlement: "coding-plan")
        let initial = quotaAgents + [
            AgentDescriptor(id: "open-shared", vendor: "OpenCode", model: "Model A", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "pi-existing", vendor: "Pi", model: "Model C", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "kimi-daily", vendor: "Kimi", model: "Daily", source: "", enabled: true, billingPool: plan),
            AgentDescriptor(id: "unattributed", vendor: "Claude", model: "5h", source: "", enabled: true),
        ]
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: initial)
        let orderedIDs = settings.agents.map(\.id)
        for id in [work.id, shared.id, plan.id] { settings.setAccount(id: id, visible: false) }
        let found = initial + [
            AgentDescriptor(id: work.windowID("monthly"), vendor: "Codex", model: "Monthly", source: "", enabled: true, account: work),
            AgentDescriptor(id: "pi-shared", vendor: "Pi", model: "Model B", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "kimi-weekly", vendor: "Kimi", model: "Weekly", source: "", enabled: true, billingPool: plan),
        ]
        settings.mergeDiscovered(found)
        XCTAssertEqual(settings.agents.filter { orderedIDs.contains($0.id) }.map(\.id), orderedIDs,
                       "New windows for known clients preserve existing window order")
        XCTAssertEqual(settings.agents.count, found.count)
        XCTAssertTrue(settings.agents.filter { [work.id, shared.id, plan.id].contains($0.displayAccountID ?? "") }.allSatisfy { !$0.enabled })
        XCTAssertTrue(settings.agents.first { $0.id == personal.windowID("codex") }!.enabled)
        XCTAssertTrue(settings.agents.first { $0.id == "unattributed" }!.enabled, "A row without an account retains its own switch")
        for id in [work.id, shared.id, plan.id] { settings.setAccount(id: id, visible: true) }
        XCTAssertTrue(settings.agents.allSatisfy(\.enabled), "The same account association restores windows across execution clients")
        settings.setAgent(id: work.windowID("codex-weekly"), enabled: false)
        settings.mergeDiscovered(found)
        XCTAssertFalse(settings.agents.first { $0.id == work.windowID("codex-weekly") }!.enabled,
                       "Discovery preserves per-window edits when the account is visible")
    }

    func testHiddenWindowsContinueToReachCollectionWithTokenAndSessionReadings() async throws {
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: quotaAgents)
        settings.setAccount(id: work.id, visible: false)
        settings.setAccount(id: personal.id, visible: false)
        let report = quotaReport()
        let provider = RecordingProvider(report: report)
        let store = UsageStore(provider: provider, settings: settings)
        await store.refresh()
        let received = await provider.receivedAgents
        XCTAssertEqual(received.map(\.id), quotaAgents.map(\.id), "Collection receives every window, including hidden accounts")
        XCTAssertTrue(received.allSatisfy { !$0.enabled })
        XCTAssertEqual(store.report?.usage, report.usage)
        XCTAssertEqual(store.report?.sessions, report.sessions)
        XCTAssertEqual(Set(store.sessions.map(\.id)), Set(report.sessions.map(\.id)))
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(settings.agents.allSatisfy { !$0.enabled }, "A new reading cannot switch hidden windows back on")
        store.now = now
        XCTAssertEqual(store.tokenColumns.map(\.total).reduce(0, +), 1650)
        XCTAssertEqual(store.agentUsage.reduce(0) { $0 + store.tokenDimensions.count($1.tokens) }, 1650)
    }

    func testQuotaVisibilityFiltersPresentationAndKeepsAllTokenAndSessionStatistics() async throws {
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: quotaAgents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        let report = quotaReport()
        store.replace(report: report)
        store.now = now
        let originalRows = store.rows
        let originalColumns = store.tokenColumns
        let originalUsage = store.agentUsage
        let originalCost = store.statsListCost
        let originalCards = store.shownAgents
        let originalSessions = store.sessions
        let originalLiveSessions = store.liveSessions
        let originalWindows = settings.agents
        XCTAssertEqual(originalRows.map(\.id), [work.windowID("codex"), personal.windowID("codex")])
        XCTAssertEqual(store.levels.count, 2)
        XCTAssertEqual(originalColumns.map(\.total).reduce(0, +), 1650)
        XCTAssertEqual(originalSessions.count, 2, "Local use with no account is included")
        XCTAssertNotNil(originalCost)

        settings.setAccount(id: work.id, visible: false)
        XCTAssertEqual(store.rows.map(\.id), [personal.windowID("codex")])
        XCTAssertEqual(store.rows.first?.paletteIndex, 0, "Quota colours follow enabled-window order when the account switch disables its windows")
        XCTAssertEqual(store.levels.count, 1)
        XCTAssertEqual(store.visibleAgents.map(\.id), originalWindows.map(\.id))
        XCTAssertEqual(store.visibleAgents.map(\.enabled), [false, false, true])
        XCTAssertEqual(store.enabledAgents.map(\.id), [personal.windowID("codex")])
        XCTAssertEqual(store.report, report)
        XCTAssertEqual(store.tokenColumns, originalColumns)
        XCTAssertEqual(store.agentUsage, originalUsage)
        XCTAssertEqual(store.statsListCost, originalCost)
        XCTAssertEqual(store.shownAgents, originalCards)
        XCTAssertEqual(store.sessions, originalSessions)
        XCTAssertEqual(store.liveSessions, originalLiveSessions)
        let group = try XCTUnwrap(AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report).first)
        XCTAssertEqual(Set(group.accounts.map(\.account.id)), [work.id, personal.id])
        XCTAssertTrue(group.unobservedAccounts.isEmpty, "Account summaries already own these switches")
        XCTAssertEqual(group.displayedCount(settings: settings.settings), 1)

        settings.setAccount(id: personal.id, visible: false)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.levels.isEmpty)
        XCTAssertTrue(store.alertPulseVendors.isEmpty)
        XCTAssertEqual(group.displayedCount(settings: settings.settings), 0)
        XCTAssertEqual(group.accounts.count, 2, "All hidden accounts remain available to restore in Settings")
        XCTAssertEqual(store.tokenColumns, originalColumns)
        XCTAssertEqual(store.sessions, originalSessions)
        settings.setAccount(id: work.id, visible: true)
        settings.setAccount(id: personal.id, visible: true)
        XCTAssertEqual(settings.agents.map(\.id), originalWindows.map(\.id))
        XCTAssertTrue(settings.agents.allSatisfy(\.enabled))
        XCTAssertEqual(store.rows.map(\.id), originalWindows.map(\.id), "Restoring also enables the account's weekly window")
        XCTAssertEqual(store.tokenColumns, originalColumns)
        XCTAssertEqual(store.sessions, originalSessions)
    }

    func testAPIBalancesUseTheirOwnPoolIdentityAndKeepRestorationEntries() async throws {
        let shared = pool("shared"), other = pool("other")
        let agents = [
            AgentDescriptor(id: "open-shared", vendor: "OpenCode", model: "Model A", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "open-other", vendor: "OpenCode", model: "Model B", source: "", enabled: true, billingPool: other),
            AgentDescriptor(id: "deepseek-model:chat", vendor: "DeepSeek", model: "Chat", source: "", enabled: true),
        ]
        let billing = [balance(pool: shared), balance(pool: other), balance(vendor: "DeepSeek")]
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents, billing: billing)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: agents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        store.replace(report: report)
        store.now = now
        XCTAssertEqual(store.enabledBilling, billing)
        XCTAssertEqual(store.levels.count, 3)

        settings.setAccount(id: shared.id, visible: false)
        XCTAssertEqual(store.enabledBilling.map(\.id), [other.id, "DeepSeek"])
        XCTAssertEqual(store.levels.count, 2)
        XCTAssertEqual(store.report?.billing, billing, "Hiding a balance does not alter its readings or costs")
        XCTAssertEqual(settings.agents.map(\.id), agents.map(\.id))
        XCTAssertEqual(settings.agents.map(\.enabled), [false, true, true])
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(groups.first { $0.id == "Anthropic" }?.billingAccounts.map(\.id), [shared.id, other.id])
        XCTAssertTrue(groups.flatMap(\.unobservedAccounts).isEmpty, "Billing summaries already own these switches")
        settings.setAccount(id: other.id, visible: false)
        settings.setAccount(id: "DeepSeek", visible: false)
        XCTAssertTrue(store.enabledBilling.isEmpty)
        XCTAssertTrue(store.levels.isEmpty)
        XCTAssertEqual(groups.first { $0.id == "DeepSeek" }?.billingAccounts.map(\.id), ["DeepSeek"])
        settings.setAccount(id: shared.id, visible: true)
        settings.setAccount(id: other.id, visible: true)
        settings.setAccount(id: "DeepSeek", visible: true)
        XCTAssertEqual(store.enabledBilling, billing)
        XCTAssertEqual(settings.agents, agents)
    }

    func testQuotaRowsWithoutAccountObservationsKeepOneRestorableControlPerIdentity() async throws {
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: quotaAgents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        let report = quotaReport(includeAccountObservations: false)
        store.replace(report: report)
        store.now = now
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(groups.map(\.id), ["Codex"])
        let group = try XCTUnwrap(groups.first)
        XCTAssertTrue(group.accounts.isEmpty)
        XCTAssertEqual(group.unobservedAccounts.map(\.id), [work.id, personal.id], "Two windows of one account share one switch")
        XCTAssertEqual(Set(group.unobservedAccounts.map(\.displayName)).count, 2, "Distinct accounts retain their six-character identity labels")
        XCTAssertTrue(group.unobservedAccounts.allSatisfy { $0.displayName.hasSuffix(String($0.id.split(separator: ":").last!.prefix(6))) })

        for account in group.unobservedAccounts { settings.setAccount(id: account.id, visible: false) }
        XCTAssertTrue(store.rows.isEmpty)
        let hiddenGroups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(hiddenGroups.map(\.id), groups.map(\.id))
        XCTAssertEqual(hiddenGroups.flatMap(\.unobservedAccounts), groups.flatMap(\.unobservedAccounts), "Hiding keeps every restore control")
        XCTAssertTrue(hiddenGroups.flatMap(\.agents).allSatisfy { !$0.enabled })
        for account in hiddenGroups.flatMap(\.unobservedAccounts) { settings.setAccount(id: account.id, visible: true) }
        XCTAssertEqual(store.rows.map(\.id), quotaAgents.map(\.id))
        XCTAssertEqual(settings.agents.map(\.id), quotaAgents.map(\.id))
        XCTAssertTrue(settings.agents.allSatisfy(\.enabled), "Restoring turns all associated windows on")
        XCTAssertEqual(store.report, report)
    }

    func testAPIRowsWithoutBillingReadingsKeepTheirPoolAndLegacyRestoreControls() async throws {
        let shared = pool("shared"), other = pool("other")
        let agents = [
            AgentDescriptor(id: "shared-a", vendor: "OpenCode", model: "Model A", source: "", enabled: true, billingPool: shared),
            AgentDescriptor(id: "shared-b", vendor: "OpenCode", model: "Model B", source: "", enabled: false, billingPool: shared),
            AgentDescriptor(id: "other", vendor: "OpenCode", model: "Model C", source: "", enabled: true, billingPool: other),
            AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true),
        ]
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: agents)
        let store = UsageStore(provider: NoReadProvider(), settings: settings)
        store.replace(report: report)
        store.now = now
        let groups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        let controls = groups.flatMap(\.unobservedAccounts)
        XCTAssertEqual(controls.map(\.id), [shared.id, other.id, "DeepSeek"])
        XCTAssertEqual(controls.first { $0.id == shared.id }?.detail, shared.label)
        XCTAssertEqual(controls.first { $0.id == other.id }?.detail, other.label)
        XCTAssertEqual(controls.first { $0.id == "DeepSeek" }?.displayName, "DeepSeek · API")
        XCTAssertTrue(groups.flatMap(\.billingAccounts).isEmpty)

        for account in controls { settings.setAccount(id: account.id, visible: false) }
        let hiddenGroups = AgentSettingsGroup.make(sources: [], agents: settings.agents, report: report)
        XCTAssertEqual(hiddenGroups.map(\.id), groups.map(\.id))
        XCTAssertEqual(hiddenGroups.flatMap(\.unobservedAccounts), controls)
        XCTAssertTrue(hiddenGroups.flatMap(\.agents).allSatisfy { !$0.enabled })
        for account in hiddenGroups.flatMap(\.unobservedAccounts) { settings.setAccount(id: account.id, visible: true) }
        XCTAssertTrue(settings.settings.hiddenAccountIDs.isEmpty)
        XCTAssertEqual(settings.agents.map(\.id), agents.map(\.id))
        XCTAssertTrue(settings.agents.allSatisfy(\.enabled), "Each pool and legacy API account restores all associated rows")
        XCTAssertTrue(store.enabledBilling.isEmpty, "A restore switch does not invent a missing balance reading")
        let billing = [balance(pool: shared), balance(pool: other), balance(vendor: "DeepSeek")]
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: agents, billing: billing))
        store.now = now
        XCTAssertEqual(store.enabledBilling, billing, "The next available readings follow the restored preference")
    }

    func testAccountControlsFollowExistingGroupsAndReadingsAloneDoNotCreateGroups() async {
        let plan = BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "plan", evidence: .account, entitlement: "coding-plan")
        let account = AccountObservation(account: ProviderAccount(pool: plan), plan: "Allegretto", observedAt: now)
        let absent = AgentDescriptor(id: "deepseek", vendor: "DeepSeek", model: "API", source: "", enabled: true)
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [],
                                 subscriptions: [plan.id: "Allegretto"], billing: [balance(vendor: "DeepSeek")],
                                 services: [.init(client: "Kimi", provider: "Kimi", product: .plan, accountID: plan.id)],
                                 accounts: ["Kimi": [account], "Codex": [.init(account: work, observedAt: now)]], rowSeenAt: [:])
        let groups = AgentSettingsGroup.make(sources: [], agents: [absent], report: report)
        XCTAssertEqual(groups.map(\.id), ["Kimi"], "A balance or account observation does not replace the source/row presence rule")
        XCTAssertEqual(groups.first { $0.id == "Kimi" }?.accounts, [account])
        XCTAssertEqual(groups.first { $0.id == "Kimi" }?.plans, [], "The plan is already in its account summary")
        XCTAssertNil(groups.first { $0.id == "Codex" })
        XCTAssertNil(groups.first { $0.id == "DeepSeek" })
    }

    func testConfirmedAliasesMoveVisibilityPreferenceOnceAndAllowShowingTheAccount() async throws {
        let unresolved = ProviderAccount.unresolved(provider: "Codex", home: "test-home")
        let unresolvedWindow = AgentDescriptor(id: unresolved.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: unresolved)
        let settings = SettingsStore(defaults: try makeDefaults(), defaultAgents: [unresolvedWindow, quotaAgents[2]])
        settings.setAccount(id: unresolved.id, visible: false)
        let observation = AccountObservation(account: work, observedAt: now, aliases: [unresolved.id])
        let inventory = ["Codex": [observation, AccountObservation(account: personal, observedAt: now)]]
        settings.mergeDiscovered([quotaAgents[0], quotaAgents[1]], accounts: inventory)
        XCTAssertEqual(settings.settings.hiddenAccountIDs, [work.id])
        XCTAssertFalse(settings.agents.contains { $0.account == unresolved })
        XCTAssertTrue(settings.agents.filter { $0.displayAccountID == work.id }.allSatisfy { !$0.enabled })
        XCTAssertTrue(settings.agents.first { $0.displayAccountID == personal.id }!.enabled)
        settings.setAccount(id: work.id, visible: true)
        settings.mergeDiscovered([quotaAgents[0], quotaAgents[1]], accounts: inventory)
        XCTAssertTrue(settings.settings.hiddenAccountIDs.isEmpty, "A later reading cannot undo the user's Show action")
        XCTAssertTrue(settings.agents.allSatisfy(\.enabled), "The canonical account restores every aliased window")
    }

    private var quotaAgents: [AgentDescriptor] {
        [AgentDescriptor(id: work.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: work),
         AgentDescriptor(id: work.windowID("codex-weekly"), vendor: "Codex", model: "Weekly", source: "", enabled: false, account: work),
         AgentDescriptor(id: personal.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: personal)]
    }

    private func quotaReport(includeAccountObservations: Bool = true) -> UsageReport {
        let consumers = [AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: true),
                         AgentDescriptor(id: "unknown-model:custom", vendor: "Local Agent", model: "Custom", source: "", enabled: true)]
        let sessions = consumers.map {
            LiveSession(id: $0.id + ":session", agentId: $0.id, task: "Local work", terminal: nil,
                        startedAt: now.addingTimeInterval(-600), pctOfWindow: nil, tokensIn: 100, tokensOut: 20, observedAt: now)
        }
        return UsageReport(generatedAt: now, snapshots: quotaAgents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 25, resetAt: now.addingTimeInterval(3600), windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: sessions, discoveredAgents: quotaAgents, consumers: consumers,
        usage: [UsageBucket(start: now.addingTimeInterval(-900), agentId: consumers[0].id, tokensIn: 1000, tokensOut: 200, cacheReadTokens: 50),
                UsageBucket(start: now.addingTimeInterval(-900), agentId: consumers[1].id, tokensIn: 400, tokensOut: 50)],
        accounts: includeAccountObservations ? ["Codex": [.init(account: work, observedAt: now), .init(account: personal, observedAt: now)]] : nil)
    }

    private func pool(_ scope: String) -> BillingPool {
        BillingPool(provider: "Anthropic", realm: "Global", product: .api, scope: scope, evidence: .account, entitlement: "api")
    }

    private func balance(vendor: String = "Anthropic", pool: BillingPool? = nil) -> APIBilling {
        APIBilling(vendor: vendor, balances: [.init(currency: "USD", total: 10, granted: 0, toppedUp: 10)],
                   isAvailable: true, updatedAt: now, notice: nil, billingPool: pool)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "AccountVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private struct NoReadProvider: UsageProvider {
        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            throw UsageProviderError("Account visibility tests install their reports directly")
        }
    }

    private actor RecordingProvider: UsageProvider {
        let report: UsageReport
        private(set) var receivedAgents: [AgentDescriptor] = []
        init(report: UsageReport) { self.report = report }
        func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
            receivedAgents = agents
            return report
        }
    }
}
#endif

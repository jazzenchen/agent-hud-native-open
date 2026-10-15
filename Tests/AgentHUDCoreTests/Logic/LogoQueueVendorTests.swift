#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class LogoQueueVendorTests: XCTestCase {
    /// The queue is what is watched plus what has been used, and a vendor leaves it a day after its last turn.
    @MainActor
    func testQueueKeepsWatchedVendorsAndAddsOnesRunWithinTheDay() {
        let suite = "LogoQueueVendorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let watched = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "Sonnet", source: "", enabled: true)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [watched])
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        let recent = AgentDescriptor(id: "codex-model:gpt-5", vendor: "Codex", model: "GPT-5", source: "", enabled: false)
        let stale = AgentDescriptor(id: "grok-model:4", vendor: "Grok", model: "4", source: "", enabled: false)
        let sessions = [
            LiveSession(id: "recent", agentId: recent.id, task: "Task", terminal: nil,
                        startedAt: now.addingTimeInterval(-7200), endedAt: now.addingTimeInterval(-3600),
                        pctOfWindow: nil, tokensIn: 10, tokensOut: 2),
            LiveSession(id: "stale", agentId: stale.id, task: "Task", terminal: nil,
                        startedAt: now.addingTimeInterval(-2 * 86400), endedAt: now.addingTimeInterval(-2 * 86400 + 60),
                        pctOfWindow: nil, tokensIn: 10, tokensOut: 2),
        ]
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: sessions,
                                          consumers: [recent, stale], usage: []))
        store.now = now

        XCTAssertEqual(store.queueVendors.map(\.vendor), ["Claude", "Codex"],
                       "a vendor run within the day joins the watched ones; one last run two days ago does not")
        XCTAssertFalse(store.queueVendors.contains(where: \.isWorking), "every session here has ended")
    }

    /// A vendor's own sessions decide whether its mark bobs; its quota window's id never matches theirs.
    @MainActor
    func testAVendorWithARunningSessionIsWorking() {
        let suite = "LogoQueueVendorTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let watched = AgentDescriptor(id: "claude-session", vendor: "Claude", model: "Sonnet", source: "", enabled: true)
        let settings = SettingsStore(defaults: defaults, defaultAgents: [watched])
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        let consumer = AgentDescriptor(id: "claude-model:opus", vendor: "Claude", model: "Opus", source: "", enabled: false)
        let running = LiveSession(id: "running", agentId: consumer.id, task: "Task", terminal: nil,
                                  startedAt: now.addingTimeInterval(-60), pctOfWindow: nil, tokensIn: 10, tokensOut: 2,
                                  observedAt: now)
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: [running],
                                          consumers: [consumer], usage: []))
        store.now = now

        XCTAssertEqual(store.queueVendors.map(\.vendor), ["Claude"], "one mark for the vendor, not one per model")
        XCTAssertEqual(store.workingVendors, ["Claude"])
        XCTAssertTrue(store.queueVendors.allSatisfy(\.isWorking))
    }

    /// Shared account windows draw the actual recent execution clients, each with only its own work status.
    func testGrokQueueAndLiveStatusKeepClientsSeparateFromTheirAccount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = ProviderAccount.identified(provider: "Grok", user: "user", workspace: "team")!
        let agents = ["grok", "grok:extra"].map {
            AgentDescriptor(id: account.windowID($0), vendor: "Grok", model: $0, source: "", enabled: true, account: account)
        }
        let cli = LiveSession(id: "cli", agentId: "grok-model:test", task: "CLI", terminal: nil,
            startedAt: now.addingTimeInterval(-60), endedAt: now.addingTimeInterval(-10), pctOfWindow: nil,
            tokensIn: 10, tokensOut: 2, client: "Grok CLI", observedAt: now)
        let bot = LiveSession(id: "bot", agentId: "grok-model:test", task: "Bot", terminal: nil,
            startedAt: now.addingTimeInterval(-60), pctOfWindow: nil, tokensIn: 10, tokensOut: 2,
            client: "Grok Bot", observedAt: now)
        let report = UsageReport(generatedAt: now, snapshots: agents.map {
            .init(agentId: $0.id, remainingPct: 80, updatedAt: now)
        }, sessions: [cli, bot], accounts: ["Grok": [.init(account: account, observedAt: now)]])
        var settings = Settings()
        var view = ReportView(report: report, agents: agents, settings: settings, now: now)

        XCTAssertEqual(view.queueVendors.map(\.vendor), ["Grok Bot", "Grok CLI"], "recent clients appear once, newest first")
        XCTAssertEqual(view.queueVendors.map(\.isWorking), [true, false], "Bot work must not animate the CLI mark")
        XCTAssertEqual(view.workingVendors, ["Grok"], "account refresh continues to use the provider identity")
        XCTAssertEqual(view.rows.map(\.id), agents.map(\.id))
        XCTAssertEqual(view.rowGroups.map(\.vendor), ["Grok"])
        XCTAssertEqual(view.accountSections(view.rows).compactMap { $0.account?.account.provider }, ["Grok"])

        settings.setLiveStatus(for: "Grok Bot", enabled: false)
        view = ReportView(report: report, agents: agents, settings: settings, now: now)
        XCTAssertFalse(view.session("bot")!.liveStatus)
        XCTAssertTrue(view.session("cli")!.liveStatus)
        XCTAssertEqual(view.queueVendors.map(\.vendor), ["Grok CLI"])
        XCTAssertEqual(view.queueVendors.map(\.isWorking), [false])
        XCTAssertTrue(view.workingVendors.isEmpty)

        settings.setLiveStatus(for: "Grok CLI", enabled: false)
        settings.setLiveStatus(for: "Grok Bot", enabled: true)
        view = ReportView(report: report, agents: agents, settings: settings, now: now)
        XCTAssertFalse(view.session("cli")!.liveStatus)
        XCTAssertTrue(view.session("bot")!.liveStatus)
        XCTAssertEqual(view.queueVendors.map(\.vendor), ["Grok Bot"])
        XCTAssertEqual(view.queueVendors.map(\.isWorking), [true])

        settings.setLiveStatus(for: "Grok Bot", enabled: false)
        view = ReportView(report: report, agents: agents, settings: settings, now: now)
        XCTAssertEqual(view.queueVendors.map(\.vendor), ["Grok"], "the account has a static mark when no client can be shown")
        XCTAssertEqual(view.queueVendors.map(\.isWorking), [false])
        XCTAssertEqual(view.rows.map(\.id), agents.map(\.id), "client switches do not hide account windows")
    }

    func testAnOldGrokClientDoesNotReplaceTheStaticAccountMark() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let watched = AgentDescriptor(id: "grok", vendor: "Grok", model: "Credits", source: "", enabled: true)
        let old = now.addingTimeInterval(-2 * 86400)
        let session = LiveSession(id: "bot", agentId: "grok-model:test", task: "Bot", terminal: nil,
            startedAt: old, endedAt: old.addingTimeInterval(60), pctOfWindow: nil, tokensIn: 10, tokensOut: 2,
            client: "Grok Bot", observedAt: now)
        let view = ReportView(report: UsageReport(generatedAt: now, snapshots: [], sessions: [session]),
                              agents: [watched], settings: Settings(), now: now)
        XCTAssertEqual(view.queueVendors.map(\.vendor), ["Grok"])
        XCTAssertEqual(view.queueVendors.map(\.isWorking), [false])
    }
}
#endif

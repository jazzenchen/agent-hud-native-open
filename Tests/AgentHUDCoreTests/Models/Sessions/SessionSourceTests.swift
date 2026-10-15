#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

@MainActor
final class SessionSourceTests: XCTestCase {
    /// A session sits under the local day it was last active on, in the order given; one in flight sits under today, even
    /// when the turn it runs was last heard from before midnight.
    @MainActor
    func testSessionsGroupUnderTheDayTheyWereLastActive() {
        let defaults = UserDefaults(suiteName: "AgentHUDSessionDayTests.\(UUID())")!
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // Ten past midnight.
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 0, minute: 10))!
        func at(_ hours: TimeInterval) -> Date { now.addingTimeInterval(hours * 3600) }
        func session(_ id: String, started: TimeInterval, ended: TimeInterval?) -> LiveSession {
            .init(id: id, agentId: "claude-model:test", task: id, terminal: nil, startedAt: at(started), endedAt: ended.map(at),
                  pctOfWindow: nil, tokensIn: 1, tokensOut: 1, observedAt: at(ended ?? -0.05))
        }
        // One whose running turn was last heard from before midnight, one that began last night and ended after midnight,
        // one from yesterday evening, and one that began three days ago and was last active yesterday afternoon.
        let sessions = [session("running", started: -1, ended: nil), session("overnight", started: -2, ended: -0.1),
                        session("yesterday", started: -5, ended: -3), session("resumed", started: -72, ended: -9)]
        let heard = Int64(at(-0.25).timeIntervalSince1970 * 1000)
        store.replace(report: UsageReport(generatedAt: now, snapshots: [], sessions: sessions, turns: [
            SessionTurn(provider: "claude", sessionID: "running", turnID: "1", state: .running, startedAtMs: heard - 60_000,
                        observedAtMs: heard),
        ]))
        store.now = now
        let days = store.sessionsByDay(sessions, calendar: calendar)
        XCTAssertEqual(days.map(\.day), [calendar.startOfDay(for: now), calendar.startOfDay(for: at(-24))])
        XCTAssertEqual(days.map { $0.sessions.map(\.id) }, [["running", "overnight"], ["yesterday", "resumed"]],
                       "a running session and one that ended after midnight sit under today, whenever they began")
    }

    @MainActor
    func testPointingAtAQuotaOrASessionTurnsTheStatisticsPage() {
        let defaults = UserDefaults(suiteName: "AgentHUDStatsTabTests.\(UUID())")!
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults))
        store.focusedSessionID = "s1"
        XCTAssertEqual(store.statsTab, .sessions)
        store.focusedSessionID = nil
        XCTAssertEqual(store.statsTab, .sessions, "going back to the list stays on Sessions")
        store.selectedQuotaId = "claude"
        XCTAssertEqual(store.statsTab, .tokens)
    }

    func testCodexClientGroupsPreserveProviderAndUnknownSurface() {
        let cli = SessionSource(vendor: "Codex", client: "CLI")
        XCTAssertEqual(cli, SessionSource(vendor: "Codex", client: "CLI · exec"))
        XCTAssertEqual(cli.name, "Codex CLI")
        XCTAssertNotEqual(cli, SessionSource(vendor: "Claude", client: "CLI · exec"))
        XCTAssertEqual(SessionSource(vendor: "Codex", client: "Desktop").name, "Codex Desktop")
        XCTAssertEqual(SessionSource(vendor: "Codex", client: "IDE").name, "Codex IDE extension")
        XCTAssertEqual(SessionSource(vendor: "Codex", client: "Codex"), SessionSource(vendor: "Codex", client: nil))
        XCTAssertNotEqual(SessionSource(vendor: "Codex", client: nil), SessionSource(vendor: "Codex", client: "Desktop"))
        XCTAssertEqual(SessionSource(vendor: "DeepSeek", client: "DeepSeek Harness").name, "DeepSeek Harness")
        XCTAssertEqual(SessionSource(vendor: "Claude", client: "Claude Code").name, "Claude Code")
        XCTAssertEqual(SessionSource(vendor: "Codex", client: "Future client").name, "Future client")
    }

    func testClaudeSurfacesComeFromTheTranscriptEntrypoint() {
        XCTAssertEqual(ClaudeEntrypoint.clientLabel("claude-desktop"), "Claude Code Desktop")
        XCTAssertEqual(ClaudeEntrypoint.clientLabel("cli"), "Claude Code CLI")
        XCTAssertEqual(ClaudeEntrypoint.clientLabel("claude-vscode"), "Claude Code IDE extension")
        XCTAssertEqual(ClaudeEntrypoint.clientLabel("sdk-ts"), "Claude Agent SDK")
        XCTAssertEqual(ClaudeEntrypoint.clientLabel(nil), "Claude Code", "older builds never wrote the field")
        XCTAssertEqual(ClaudeEntrypoint.clientLabel("claude-jetbrains"), "claude-jetbrains", "a surface the catalog does not name is shown as written")
        XCTAssertEqual(SessionSource(vendor: "Claude", client: "Claude Code Desktop").name, "Claude Code Desktop")
        XCTAssertNotEqual(SessionSource(vendor: "Claude", client: "Claude Code Desktop"), SessionSource(vendor: "Claude", client: "Claude Code CLI"))
        XCTAssertEqual(SessionSource(vendor: "Claude", client: "Claude Code"), SessionSource(vendor: "Claude", client: nil),
                       "the plain product name from older builds and synced peers is one group")
        XCTAssertEqual(SessionSource(vendor: "Claude", client: nil).name, "Claude Code")
        XCTAssertEqual(SessionSource.vendor(impliedBy: "claude-model:Unknown"), "Claude")
        XCTAssertEqual(SessionSource.vendor(impliedBy: "codex-model:gpt-5"), "Codex")
        XCTAssertEqual(SessionSource.vendor(impliedBy: "antigravity"), "Antigravity")
    }

    func testGrokExecutionClientsKeepTheirSharedProvider() {
        let cli = SessionSource(vendor: "Grok", client: "Grok CLI")
        let bot = SessionSource(vendor: "Grok", client: "Grok Bot")
        XCTAssertEqual(cli, SessionSource(vendor: "Grok", client: nil), "older sessions belong to the CLI")
        XCTAssertNotEqual(cli, bot)
        XCTAssertEqual(cli.vendor, "Grok")
        XCTAssertEqual(bot.vendor, "Grok")
        XCTAssertEqual(cli.agentVendor, "Grok CLI")
        XCTAssertEqual(bot.agentVendor, "Grok Bot")
        XCTAssertEqual(cli.name, "Grok CLI")
        XCTAssertEqual(bot.name, "Grok Bot")
        XCTAssertEqual(SessionSource(vendor: "Grok", client: "Future client").agentVendor, "Future client")
        XCTAssertEqual(SessionSource(vendor: "Codex", client: "Desktop").agentVendor, "Codex")
        XCTAssertNil(SessionSource(vendor: nil, client: "Unknown client").agentVendor)
        XCTAssertTrue(SessionSource.agentVendors.contains("Grok CLI"))
        XCTAssertTrue(SessionSource.agentVendors.contains("Grok Bot"))
        XCTAssertFalse(SessionSource.agentVendors.contains("Grok"), "the account provider is not an execution client")
    }

    func testCursorMeteredBotUsesItsNativeExecutionProviderAndClient() {
        let bot = SessionSource(vendor: "Cursor", client: "Grok Bot")
        XCTAssertEqual(bot.vendor, "Grok")
        XCTAssertEqual(bot.name, "Grok Bot")
        XCTAssertEqual(bot.agentVendor, "Grok Bot")
        XCTAssertEqual(SessionSource(vendor: "Cursor", client: "Cursor").agentVendor, "Cursor")
        XCTAssertEqual(SessionSource(vendor: "Cursor", client: "Future client").agentVendor, "Cursor")
        XCTAssertEqual(SessionSource.vendor(impliedBy: "cursor-model:grok-bot-default"), "Cursor",
                       "the dashboard model identity still belongs to the Cursor billing source")
    }

    func testCursorMeteredBotUsesTheBotLiveStatusSwitch() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = AgentDescriptor(id: "cursor-model:grok-bot-default", vendor: "Cursor", model: "grok-bot-default",
                                    source: "fixture", enabled: false)
        let session = LiveSession(id: "grok-bot:slot:agent", agentId: model.id, task: "Bot task", terminal: nil,
                                  startedAt: now, pctOfWindow: nil, tokensIn: 10, tokensOut: 2, client: "Grok Bot")
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session], consumers: [model])
        var settings = Settings()
        settings.setLiveStatus(for: "Cursor", enabled: false)
        settings.setLiveStatus(for: "Grok Bot", enabled: true)
        let on = try XCTUnwrap(ReportView(report: report, agents: [model], settings: settings, now: now).session(session.id))
        XCTAssertEqual(on.source.vendor, "Grok")
        XCTAssertEqual(on.source.agentVendor, "Grok Bot")
        XCTAssertEqual(model.vendor, "Cursor", "the session's execution provider does not rename its billing consumer")
        XCTAssertTrue(on.liveStatus, "neither the Cursor live-status switch nor a disabled quota row suppresses Bot status")

        settings.setLiveStatus(for: "Cursor", enabled: true)
        settings.setLiveStatus(for: "Grok Bot", enabled: false)
        let off = try XCTUnwrap(ReportView(report: report, agents: [model], settings: settings, now: now).session(session.id))
        XCTAssertFalse(off.liveStatus, "enabling Cursor does not override the Bot's own saved switch")
    }

    @MainActor
    func testStoreResolvesSourcesEvenWhenQuotaAgentIsDisabled() {
        let suite = "AgentHUDSessionSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents.map { $0.with(enabled: false) })
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: DemoData.agents, historyHours: 24, now: Date()))
        let session = LiveSession(id: "example", agentId: "codex", task: "Example", terminal: nil,
            startedAt: Date(), pctOfWindow: nil, tokensIn: 10, tokensOut: 2, client: "CLI · exec")
        XCTAssertEqual(store.sessionSource(session).name, "Codex CLI")
        XCTAssertEqual(session.client, "CLI · exec", "Presentation must not rewrite persisted source metadata")
        let silent = LiveSession(id: "silent", agentId: "claude-model:Unknown", task: "Silent", terminal: nil,
            startedAt: Date(), pctOfWindow: nil, tokensIn: 0, tokensOut: 0, client: "Claude Code Desktop")
        XCTAssertEqual(store.sessionSource(silent), SessionSource(vendor: "Claude", client: "Claude Code Desktop"),
                       "a session whose model never answered has no consumer row but still belongs to Claude")
    }
}
#endif

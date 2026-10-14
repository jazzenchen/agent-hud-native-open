#if !os(Windows)
// Providers/Grok/GrokClientSeparationTests.swift tests macOS-side sockets and home layouts.
import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokClientSeparationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var clients: [SourceStatus] {
        [SourceStatus(id: "grok", name: "Grok CLI", detail: "CLI", state: .installed, provider: "Grok"),
         SourceStatus(id: "grok-bot", name: "Grok Bot", detail: "Bot", state: .installed,
                      provider: "Grok", supportsLiveStatus: false)]
    }

    func testTwoClientsShareOneProviderGroupAccountAndWindowInventory() throws {
        let account = try XCTUnwrap(ProviderAccount.identified(provider: "Grok", user: "shared-user", workspace: nil))
        let windows = ["grok:extra", "grok"].map {
            AgentDescriptor(id: account.windowID($0), vendor: "Grok", model: $0, source: "fixture", enabled: true, account: account)
        }
        let observations = [
            AccountObservation(account: account, home: "cli", client: "Grok CLI", label: "same account", observedAt: now),
            AccountObservation(account: account, home: "bot", client: "Grok Bot", label: "same account", observedAt: now),
        ]
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: windows,
                                 accounts: ["Grok": observations])
        let groups = AgentSettingsGroup.make(sources: clients, agents: windows, report: report)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.map(\.id), ["Grok"])
        XCTAssertEqual(group.clients.map(\.name), ["Grok CLI", "Grok Bot"])
        XCTAssertEqual(group.agents.map(\.id), windows.map(\.id), "execution clients must not duplicate or reorder shared quota windows")
        XCTAssertEqual(group.accounts.map(\.account.id), [account.id])
        XCTAssertEqual(group.windowSections.count, 1)
        XCTAssertEqual(group.windowSections.first?.agents, windows)
        XCTAssertFalse(group.clients[1].supportsLiveStatus)
    }

    func testLegacyGrokSwitchMigratesOnlyToCLIAndDefaultsPreserveSavedChoices() throws {
        var settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"liveStatusPreferences":{"Grok":false,"Grok Bot":true}}"#.utf8))
        XCTAssertFalse(settings.liveStatusEnabled(for: "Grok CLI"))
        XCTAssertEqual(settings.liveStatusPreferences, ["grok cli": false, "grok bot": true], "the stored CLI preference has one canonical key")
        XCTAssertTrue(settings.liveStatusEnabled(for: "Grok Bot"), "the former Grok switch belongs only to CLI")
        settings.applyLiveStatusDefaults(sources: clients)
        XCTAssertFalse(settings.liveStatusEnabled(for: "Grok CLI"))
        XCTAssertTrue(settings.liveStatusEnabled(for: "Grok Bot"), "unsupported live status must not rewrite a saved choice")
        settings.setLiveStatus(for: "Grok CLI", enabled: true)
        settings.applyLiveStatusDefaults(sources: clients.map {
            SourceStatus(id: $0.id, name: $0.name, detail: $0.detail, state: .notDetected,
                         provider: $0.provider, supportsLiveStatus: $0.supportsLiveStatus)
        })
        XCTAssertTrue(settings.liveStatusEnabled(for: "Grok CLI"), "an explicit CLI choice overrides the legacy switch and later detection")
        XCTAssertTrue(settings.liveStatusEnabled(for: "Grok Bot"))

        var fresh = Settings()
        fresh.applyLiveStatusDefaults(sources: clients)
        XCTAssertTrue(fresh.liveStatusEnabled(for: "Grok CLI"))
        XCTAssertFalse(fresh.liveStatusEnabled(for: "Grok Bot"), "installation alone does not enable an unsupported session reader")

        let explicit = try JSONDecoder().decode(Settings.self, from: Data(#"{"liveStatusPreferences":{"Grok":false,"Grok CLI":true}}"#.utf8))
        XCTAssertTrue(explicit.liveStatusEnabled(for: "Grok CLI"), "the explicit client preference wins over a legacy provider preference")
        XCTAssertTrue(explicit.liveStatusEnabled(for: "Grok"), "older callers read the same canonical CLI choice")
        XCTAssertTrue(explicit.liveStatusEnabled(for: "Grok Bot"), "legacy migration creates no Bot choice")
        XCTAssertEqual(explicit.liveStatusPreferences, ["grok cli": true])
    }

    func testCLIAndBotInstallationEvidenceStaySeparate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-clients-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bot = home.appendingPathComponent("Library/Application Support/Grok Bot", isDirectory: true)
        try FileManager.default.createDirectory(at: bot, withIntermediateDirectories: true)
        XCTAssertTrue(GrokBotLocator.isInstalled(home: home, applicationURLs: []))
        XCTAssertFalse(AdditionalSource.grok.isInstalled(home: home), "Bot's data must not trigger a Grok CLI reader")
        let cli = home.appendingPathComponent(".grok", isDirectory: true)
        XCTAssertEqual(GrokSessions.roots(home: home, environment: [:]),
                       [cli.appendingPathComponent("sessions"), cli.appendingPathComponent("logs")])
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        XCTAssertTrue(AdditionalSource.grok.isInstalled(home: home))
        try FileManager.default.removeItem(at: bot)
        XCTAssertFalse(GrokBotLocator.isInstalled(home: home, applicationURLs: []), "CLI data is not Bot installation evidence")

        let app = home.appendingPathComponent("Applications/Grok Bot.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(GrokBotLocator.isInstalled(home: home, applicationURLs: [app]))
        XCTAssertFalse(GrokBotLocator.isInstalled(home: home, applicationURLs: []), "an explicit empty app inventory keeps the test independent of installed apps")
    }

    func testCompletionSwitchesUseTheSessionsExecutionClientAndNeverReplaySuppressedTurns() {
        let sessions = [session("cli", client: "Grok CLI"), session("bot", client: "Grok Bot")]
        let first = [completion("cli", turn: "1", seconds: 1), completion("bot", turn: "1", seconds: 2)]
        var settings = Settings()
        settings.setLiveStatus(for: "Grok CLI", enabled: false)
        settings.setLiveStatus(for: "Grok Bot", enabled: true)
        var tracker = IslandEventTracker(startedAt: now)
        let report = UsageReport(generatedAt: now.addingTimeInterval(3), snapshots: [], sessions: sessions, completions: first)
        let filledBot = completion("bot", turn: "1", seconds: 2, client: "Grok Bot")
        XCTAssertEqual(tracker.update(report: report, agents: [], now: report.generatedAt, settings: settings).completions, [filledBot])

        settings.setLiveStatus(for: "Grok CLI", enabled: true)
        settings.setLiveStatus(for: "Grok Bot", enabled: false)
        let next = [completion("cli", turn: "2", seconds: 4), completion("bot", turn: "2", seconds: 5)]
        let refreshed = UsageReport(generatedAt: now.addingTimeInterval(6), snapshots: [], sessions: sessions, completions: first + next)
        let filledCLI = completion("cli", turn: "2", seconds: 4, client: "Grok CLI")
        XCTAssertEqual(tracker.update(report: refreshed, agents: [], now: refreshed.generatedAt, settings: settings).completions, [filledCLI])
        XCTAssertTrue(tracker.update(report: refreshed, agents: [], now: refreshed.generatedAt).completions.isEmpty)

        var legacyTracker = IslandEventTracker(startedAt: now)
        var legacySettings = Settings()
        legacySettings.setLiveStatus(for: "Grok", enabled: false)
        let legacy = UsageReport(generatedAt: report.generatedAt, snapshots: [], sessions: [], completions: [first[0]])
        XCTAssertTrue(legacyTracker.update(report: legacy, agents: [], now: legacy.generatedAt, settings: legacySettings).completions.isEmpty,
                      "a completion without client metadata keeps the former CLI switch")
    }

    func testCompletionClientRoundTripsWithoutChangingProviderOrEventIdentity() throws {
        let legacy = completion("same-session", turn: "same-turn", seconds: 1)
        for client in ["Grok CLI", "Grok Bot"] {
            let original = completion("same-session", turn: "same-turn", seconds: 1, client: client)
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(SessionCompletion.self, from: data)
            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored.vendor, "Grok")
            XCTAssertEqual(restored.client, client)
            XCTAssertEqual(restored.agentVendor, client)
            XCTAssertEqual(restored.id, legacy.id, "client metadata must not change an existing completion identity")

            var oldRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            oldRecord.removeValue(forKey: "client")
            let old = try JSONDecoder().decode(SessionCompletion.self, from: JSONSerialization.data(withJSONObject: oldRecord))
            XCTAssertNil(old.client)
            XCTAssertEqual(old.vendor, "Grok")
            XCTAssertEqual(old.agentVendor, "Grok CLI")
            XCTAssertEqual(old.id, restored.id)
        }
    }

    private func session(_ id: String, client: String) -> LiveSession {
        LiveSession(id: id, agentId: "grok-model:grok-4", task: "fixture", terminal: nil, startedAt: now,
                    pctOfWindow: nil, tokensIn: 0, tokensOut: 0, client: client)
    }

    private func completion(_ session: String, turn: String, seconds: TimeInterval, client: String? = nil) -> SessionCompletion {
        SessionCompletion(sessionID: session, vendor: "Grok", turnID: turn, task: "fixture", model: "grok-4",
                          startedAt: now, completedAt: now.addingTimeInterval(seconds), client: client)
    }
}
#endif

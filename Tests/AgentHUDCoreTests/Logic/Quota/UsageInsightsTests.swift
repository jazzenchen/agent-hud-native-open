#if !os(Windows)
// This suite follows macOS filesystem, process or hook-command semantics.
import XCTest
@testable import AgentHUDCore

/// The burn rate, time to exhaustion and cap statistics each provider builds from the same stored readings, for a
/// 5-hour window, a weekly one and a 30-day one whose cycle began before the last week.
final class UsageInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A window's shape, what its reading now says, and the readings stored before now.
    private enum Window: String, CaseIterable {
        case session, weekly, monthly

        var duration: TimeInterval {
            switch self {
            case .session: 5 * 3600
            case .weekly: 7 * 86400
            case .monthly: 30 * 86400
            }
        }

        var resetIn: TimeInterval {
            switch self {
            case .session: 2 * 3600
            case .weekly: 3 * 86400
            case .monthly: 10 * 86400
            }
        }

        var remaining: Double { self == .monthly ? 65 : 60 }

        /// Hours before now and the remaining % read then.
        var history: [(hoursAgo: Double, remaining: Double)] {
            switch self {
            case .session: [(2, 80), (1, 70)]
            // Caps 500 and 168¾ hours back, outside the last week, and 120 hours back, inside it but before this cycle.
            case .weekly: [(500, 0), (499, 100), (168.75, 0), (168.25, 100), (120, 0.2), (110, 100), (90, 100), (30, 70)]
            case .monthly: [(470, 100), (240, 80), (144, 70)]
            }
        }
    }

    /// Insights in hours where the report has seconds or dates.
    private struct Insight: Equatable {
        var burn: Double?
        var exhaustHours: Double?
        var capHits = 0
        var waitHours = 0.0
        var longestWaitHours = 0.0
        var longestWaitHoursAgo: Double?

        /// Six decimals: enough to tell the expected values apart, not enough to see floating-point noise.
        var rounded: Insight {
            func round(_ value: Double) -> Double { (value * 1e6).rounded() / 1e6 }
            return Insight(burn: burn.map(round), exhaustHours: exhaustHours.map(round), capHits: capHits, waitHours: round(waitHours),
                           longestWaitHours: round(longestWaitHours), longestWaitHoursAgo: longestWaitHoursAgo.map(round))
        }
    }

    // What every provider builds for a 5-hour window and for a weekly one whose history it reads from a week back.
    private let session = Insight(burn: 10, exhaustHours: 6)
    private let weekly = Insight(burn: 10.0 / 30, exhaustHours: 180, capHits: 1, waitHours: 10, longestWaitHours: 10, longestWaitHoursAgo: 120)
    /// A 30-day window read from the start of its cycle.
    private let monthly = Insight(burn: 15.0 / 240, exhaustHours: 1040)

    /// Claude reads a week of readings for each window, the session window and the weekly ones alike.
    func testClaudeSessionAndWeeklyWindows() async throws {
        let now = now, account = ProviderAccount.unresolved(provider: "Claude", home: "")
        let ids = [(Window.session, account.windowID(ClaudeUsage.sessionRowId)), (.weekly, account.windowID(ClaudeUsage.weeklyRowId))]
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func window(_ window: Window) -> String {
            #"{"utilization":\#(100 - window.remaining),"resets_at":"\#(iso.format(now.addingTimeInterval(window.resetIn)))"}"#
        }
        let provider = ClaudeCodeProvider(engine: try engine(rateLimits: #"{"five_hour":\#(window(.session)),"seven_day":\#(window(.weekly))}"#),
                                          transcripts: .init(roots: []), history: await history(ids), clock: { now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        assertInsights(report, ids, [.session: session, .weekly: weekly])
    }

    /// Codex reads a window from its cycle's start or a week back, whichever is earlier, and counts caps over the week.
    func testCodexWindows() async throws {
        let now = now, account = ProviderAccount.unresolved(provider: "Codex", home: "")
        let ids = [(Window.session, account.windowID("codex")), (.weekly, account.windowID("codex:codex:secondary")),
                   (.monthly, account.windowID("codex:monthly:primary"))]
        func window(_ window: Window) -> String {
            #"{"usedPercent":\#(100 - window.remaining),"windowDurationMins":\#(Int(window.duration / 60)),"resetsAt":\#(now.addingTimeInterval(window.resetIn).timeIntervalSince1970)}"#
        }
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(#"""
            {"rateLimitsByLimitId":{"codex":{"primary":\#(window(.session)),"secondary":\#(window(.weekly))},"monthly":{"primary":\#(window(.monthly))}}}
            """#.utf8))
        let provider = CodexUsageProvider(readLimits: { limits }, transcripts: CodexTranscriptStore(roots: []), history: await history(ids),
                                          clock: { now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        assertInsights(report, ids, [.session: session, .weekly: weekly, .monthly: monthly])
    }

    /// The providers of Cursor, Antigravity, Grok and GitHub Copilot read windows as Codex does.
    func testCursorWindows() async throws {
        let now = now, account = ProviderAccount.unresolved(provider: "Cursor", home: "")
        let ids = Window.allCases.map { ($0, account.windowID($0.rawValue)) }
        let windows = Window.allCases.map {
            ProviderQuota.Window(id: $0.rawValue, label: $0.rawValue, remaining: $0.remaining, reset: now.addingTimeInterval($0.resetIn), duration: $0.duration)
        }
        let provider = AdditionalUsageProvider(source: .cursor, readQuota: { ProviderQuota(windows: windows) }, readSessions: { _ in ProviderSessions() },
                                               history: await history(ids), clock: { now })
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        assertInsights(report, ids, [.session: session, .weekly: weekly, .monthly: monthly])
    }

    /// Kimi and GLM read windows as Codex does, whatever the statistics range: caps count over the last week, and the
    /// 30-day window reads from the start of its cycle.
    func testKimiAndGLMReadWindowsAsCodexDoesWhateverTheStatisticsRange() async throws {
        let now = now
        let credentials = [OpenAgentCredentials.credential(.kimi, token: "kimi-key", client: "Kimi"),
                           OpenAgentCredentials.credential(.glmChina, token: "glm-key", client: "GLM")]
        let ids = credentials.flatMap { credential in Window.allCases.map { ($0, credential.pool.windowID($0.rawValue)) } }
        for (hours, weekly, monthly) in [48, 169, 745].map({ ($0, weekly, monthly) }) {
            let provider = OpenAgentUsageProvider(credentials: { credentials }, sessions: { _ in .init() }, fetchQuota: { credential, _ in
                ProviderQuota(windows: Window.allCases.map {
                    .init(id: credential.pool.windowID($0.rawValue), label: $0.rawValue, remaining: $0.remaining,
                          reset: now.addingTimeInterval($0.resetIn), duration: $0.duration)
                })
            }, history: await history(ids), clock: { now })
            let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: hours)
            assertInsights(report, ids, [.session: session, .weekly: weekly, .monthly: monthly], "\(hours) hours")
        }
    }

    /// A store holding each window's readings under the id its provider files them by.
    private func history(_ ids: [(Window, String)]) async -> QuotaHistoryStore {
        let history = QuotaHistoryStore()
        await history.append(ids.flatMap { window, id in
            window.history.map { QuotaSample(agentId: id, timestamp: now.addingTimeInterval(-$0.hoursAgo * 3600), remainingPct: $0.remaining) }
        }, now: now)
        return history
    }

    private func assertInsights(_ report: UsageReport, _ ids: [(Window, String)], _ expected: [Window: Insight], _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        for (window, id) in ids {
            let actual = report.insightsByAgent[id].map {
                Insight(burn: $0.burnRatePctPerHour, exhaustHours: $0.timeToExhaust.map { $0 / 3600 }, capHits: $0.weeklyCapHits,
                        waitHours: $0.weeklyWaitTotal / 3600, longestWaitHours: $0.weeklyWaitLongest / 3600,
                        longestWaitHoursAgo: $0.weeklyWaitLongestAt.map { now.timeIntervalSince($0) / 3600 })
            }
            XCTAssertEqual(actual?.rounded, expected[window]?.rounded, "\(window) \(message)", file: file, line: line)
        }
    }

    /// A Claude Code engine that answers the usage request with `rateLimits`.
    private func engine(rateLimits: String) throws -> ClaudeEngineUsageClient {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let response = #"{"type":"control_response","response":{"subtype":"success","request_id":"agent-hud-usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":\#(rateLimits)}}}"#
        let script = directory.appendingPathComponent("claude")
        try "#!/bin/bash\nread -r l\necho '\(response)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ClaudeEngineUsageClient(executable: script, workingDirectory: directory, timeout: 10)
    }
}
#endif

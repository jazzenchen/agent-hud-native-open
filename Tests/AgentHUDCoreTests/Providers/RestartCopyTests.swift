#if !os(Windows)
// XCTest on Windows cannot register MainActor-isolated suites; this one runs on the macOS runner.
import XCTest
@testable import AgentHUDCore

/// The copy of the last report that the app reads back after a restart must give the same answers about every reading
/// as the report it was written from.
final class RestartCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let native = ProviderAccount.identified(provider: "Codex", user: "a@example.com", workspace: "workspace-1")!
    private let pi = ProviderAccount.identified(provider: "Codex", user: "b@example.com", workspace: "workspace-1")!
    private let grok = ProviderAccount.identified(provider: "Grok", user: "a@example.com", workspace: nil)!
    private let cursor = ProviderAccount.identified(provider: "Cursor", user: "a@example.com", workspace: nil)!
    private let pools = ["p", "q"].map {
        BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "scope-" + $0, evidence: .account, entitlement: "kimi-code")
    }

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    /// What the surfaces make of every reading in a report.
    private struct Answers: Equatable {
        /// Each quota row's reason not to trust its reading, in row order.
        var notices: [String?]
        /// Each vendor's own notice.
        var vendorNotices: [String?]
        var levels: [StatusLevel?]
        /// Quota levels and the balance's, in glow order.
        var glow: [StatusLevel]
        var menuFigure: Double?
        var statuses: [String?]
        var resets: [String]
        var hints: [String?]
        /// Whether quota alerts take each row's reading as the baseline for the next.
        var alertBaselines: [Bool]
        /// Whether reset credits take each Codex account's reading as the baseline for the next.
        var creditBaselines: [Bool]
    }

    @MainActor
    func testARestartCopyReadsBackToTheSameAnswers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("last-usage-report.json")
        try Data(savedCopy.utf8).write(to: file)
        let restored = try XCTUnwrap(RetainedUsageProvider(provider: DemoUsageProvider(), cacheURL: file).initialReport,
                                     "a copy that does not decode loses every kept reading")
        let source = report()
        // Every scope keeps its notice: the vendors', the accounts' and pools', and the balance's.
        XCTAssertEqual(restored.sourceNotices, source.sourceNotices)
        XCTAssertEqual(restored.quotaNotices, source.quotaNotices)
        XCTAssertEqual(restored.accounts, source.accounts)
        XCTAssertEqual(restored.billing, source.billing)
        let expected = try answers(source)
        XCTAssertEqual(expected.notices, [nil, "Pi offline", "Sign in to Grok CLI, then refresh quota", nil, "rejected", nil],
                       "an account's, a vendor's and a pool's notice hold back their rows; a notice about logs does not")
        XCTAssertEqual(expected.vendorNotices, [nil, "Sign in to Grok CLI, then refresh quota", nil, nil, "Balance could not be read"])
        XCTAssertEqual(try answers(restored), expected)
    }

    /// A copy written with typed issues reads back to the same statuses, keeps them through the report's own copies, and
    /// still carries every notice's text where a version that reads no issues looks for it.
    @MainActor
    func testATypedCopyReadsBackAndStillCarriesTheNoticeText() throws {
        let pool = ProviderAccount(pool: pools[0])
        let source = UsageReport(generatedAt: now, snapshots: [], sessions: [], discoveredAgents: rows,
            sourceNotices: ["Grok": "Sign in to Grok CLI, then refresh quota"], quotaNotices: ["Grok": "Sign in to Grok CLI, then refresh quota"],
            readingIssues: ["Grok": .readFailed("Sign in to Grok CLI, then refresh quota")],
            billing: [APIBilling(vendor: "DeepSeek", balances: [], isAvailable: nil, updatedAt: nil, notice: "Balance could not be read",
                                 readingIssue: .readFailed("Balance could not be read"))],
            accounts: ["Kimi": [AccountObservation(account: pool, observedAt: now, quotaNotice: "identity unconfirmed",
                                                   readingIssue: .unverified("identity unconfirmed"))]])
        let data = try JSONEncoder().encode(source.restartCopy)
        let restored = try JSONDecoder().decode(UsageReport.self, from: data)
        let subjects: [ReadingSubject] = [.window(rows[2]), .window(rows[4]), .account(source.accounts!["Kimi"]![0]), .balance(source.billing[0])]
        XCTAssertEqual(subjects.map { restored.status(of: $0) }, [.readFailed(reason: "Sign in to Grok CLI, then refresh quota"),
                                                                 .unverified(reason: "identity unconfirmed"),
                                                                 .unverified(reason: "identity unconfirmed"),
                                                                 .readFailed(reason: "Balance could not be read")])
        XCTAssertEqual(subjects.map { restored.status(of: $0) }, subjects.map { source.status(of: $0) })
        // The report's own copies keep every issue.
        let kept = source.startingRowClocks().retainingReadings(from: source)
        XCTAssertEqual(kept.readingIssues, source.readingIssues)
        XCTAssertEqual(kept.accounts?["Kimi"]?.map(\.readingIssue), [.unverified("identity unconfirmed")])
        XCTAssertEqual(kept.billing.map(\.readingIssue), [.readFailed("Balance could not be read")])
        XCTAssertEqual(source.accounts!["Kimi"]![0].with(isCurrent: false).readingIssue, .unverified("identity unconfirmed"))
        XCTAssertEqual(CombinedUsageProvider.mergeBilling(source.billing).map(\.readingIssue), [.readFailed("Balance could not be read")])
        // A version that reads no issues finds each notice where it always did.
        let older = try JSONDecoder().decode(NoticeFields.self, from: data)
        XCTAssertEqual(older.quotaNotices, ["Grok": "Sign in to Grok CLI, then refresh quota"])
        XCTAssertEqual(older.accounts["Kimi"]?.map(\.quotaNotice), ["identity unconfirmed"])
        XCTAssertEqual(older.billing.map(\.notice), ["Balance could not be read"])
    }

    /// The notice fields of `last-usage-report.json` as a version that reads no issues decodes them.
    private struct NoticeFields: Decodable {
        struct Account: Decodable { let quotaNotice: String? }
        struct Billing: Decodable { let notice: String? }
        let quotaNotices: [String: String]?
        let accounts: [String: [Account]]
        let billing: [Billing]
    }

    // MARK: Fixtures

    private var later: Date { now.addingTimeInterval(300) }

    /// Quota rows in settings order, then the DeepSeek row whose balance the glow shows.
    private var rows: [AgentDescriptor] {
        [AgentDescriptor(id: native.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: native),
         AgentDescriptor(id: pi.windowID("codex"), vendor: "Codex", model: "5h", source: "", enabled: true, account: pi),
         AgentDescriptor(id: grok.windowID("grok"), vendor: "Grok", model: "Grok", source: "", enabled: true, account: grok),
         AgentDescriptor(id: cursor.windowID("cursor"), vendor: "Cursor", model: "Included", source: "", enabled: true, account: cursor)]
            + pools.map {
                AgentDescriptor(id: $0.windowID("weekly"), vendor: "Kimi", model: "7d", source: "Pi", enabled: true, billingPool: $0,
                                account: ProviderAccount(pool: $0))
            }
            + [AgentDescriptor(id: "deepseek-model:deepseek-chat", vendor: "DeepSeek", model: "deepseek-chat", source: "", enabled: true)]
    }

    /// A merged report with a notice at every scope: one Codex account's failed read in the Pi home, Grok's failed read,
    /// a notice about Cursor's logs alone, one Kimi pool's failed read beside a sibling pool, and a failed DeepSeek balance
    /// read that keeps the last balance.
    private func report() -> UsageReport {
        let fresh = now.addingTimeInterval(-60), kept = now.addingTimeInterval(-600)
        let remaining: [Double] = [25, 30, 45, 60, 20, 50]
        let readAt = [fresh, kept, kept, fresh, kept, fresh]
        let quota = rows.filter { !$0.isAPIBilled }
        let notices = [pi.id: "Pi offline", "Grok": "Sign in to Grok CLI, then refresh quota",
                       "Cursor": "Cursor usage events could not be read", "Kimi": "Kimi pool p: rejected",
                       "DeepSeek": "Balance could not be read"]
        return UsageReport(generatedAt: now,
            snapshots: quota.indices.map {
                UsageSnapshot(agentId: quota[$0].id, remainingPct: remaining[$0], resetAt: now.addingTimeInterval(2 * 3600),
                              windowDuration: 5 * 3600, updatedAt: readAt[$0])
            },
            sessions: [], notice: notices.keys.sorted().map { "\($0): \(notices[$0]!)" }.joined(separator: " · "),
            discoveredAgents: rows, consumers: rows.filter(\.isAPIBilled),
            insightsByAgent: [quota[0].id: insights(hours: 1), quota[5].id: insights(hours: 2)],
            sourceNotices: notices, quotaNotices: notices.filter { ["Grok", "DeepSeek", pi.id].contains($0.key) },
            billing: [APIBilling(vendor: "DeepSeek", balances: [AccountBalance(currency: "CNY", total: 8, granted: 0, toppedUp: 8)],
                                 isAvailable: true, updatedAt: now.addingTimeInterval(-7200), notice: "Balance could not be read")],
            activeQuotaPoolIDs: ["Kimi": Set(pools.map(\.id))],
            accounts: [
                "Codex": [AccountObservation(account: native, label: "a@example.com", plan: "plus", observedAt: fresh,
                                             resetCredits: CodexResetCredits(availableCount: 1, credits: nil)),
                          AccountObservation(account: pi, home: "pi", label: "b@example.com", plan: "pro", observedAt: kept,
                                             quotaNotice: "Pi offline", resetCredits: CodexResetCredits(availableCount: 2, credits: nil))],
                "Grok": [AccountObservation(account: grok, observedAt: kept)],
                "Cursor": [AccountObservation(account: cursor, observedAt: fresh)],
                "Kimi": [AccountObservation(account: ProviderAccount(pool: pools[0]), observedAt: kept, quotaNotice: "rejected"),
                         AccountObservation(account: ProviderAccount(pool: pools[1]), observedAt: fresh)],
            ])
    }

    private func insights(hours: Double) -> UsageInsights {
        UsageInsights(burnRatePctPerHour: 10, timeToExhaust: hours * 3600, weeklyCapHits: 0, weeklyWaitTotal: 0, weeklyWaitLongest: 0,
                      weeklyWaitLongestAt: nil)
    }

    @MainActor
    private func answers(_ report: UsageReport) throws -> Answers {
        let suite = "RestartCopyTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: rows))
        store.replace(report: report)
        store.now = now
        let quota = rows.filter { !$0.isAPIBilled }
        var alerts = QuotaAlertTracker(), resets = ResetCreditTracker()
        _ = alerts.update(report: report, agents: rows, now: now)
        _ = resets.update(report: report, now: now)
        // A clean, critical reading of every row with more reset credits raises an alert or a grant only where the
        // reading before it was taken as a baseline.
        let next = UsageReport(generatedAt: later, snapshots: quota.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 5, resetAt: now.addingTimeInterval(2 * 3600), windowDuration: 5 * 3600, updatedAt: later)
        }, sessions: [], discoveredAgents: rows, accounts: Dictionary(grouping: Set(quota.compactMap(\.account)), by: \.provider).mapValues {
            $0.map { AccountObservation(account: $0, observedAt: later, resetCredits: CodexResetCredits(availableCount: 9, credits: nil)) }
        })
        let crossed = alerts.update(report: next, agents: rows, now: later).criticalAgentIDs
        let granted = Set(resets.update(report: next, now: later).map(\.account.account.id))
        return Answers(notices: quota.map { report.quotaNotice(for: $0) },
                       vendorNotices: ["Codex", "Grok", "Cursor", "Kimi", "DeepSeek"].map { report.quotaNotice(vendor: $0) },
                       levels: store.rows.map(\.level), glow: store.levels, menuFigure: store.maxUsedPct,
                       statuses: store.rows.map { $0.account?.statusLabel(now: now) }, resets: store.rows.map { $0.resetLabel(now: now) },
                       hints: quota.map { store.quotaForecastHint(for: $0.id) }, alertBaselines: quota.map { crossed.contains($0.id) },
                       creditBaselines: [native, pi].map { granted.contains($0.id) })
    }
}

/// `last-usage-report.json` as `RetainedUsageProvider` writes it for `report()`, with members sorted by key and one record
/// per line; no value was changed.
private let savedCopy = #"""
{
    "accounts":{
        "Codex":[
            {"account":{"evidence":"account","id":"account:f4f7373574cffa3d9d10ce9279c4a62108fd14b443f077c2b64c2bb936d9e507","provider":"Codex"},"home":"","isCurrent":true,"label":"a@example.com","observedAt":821692740,"plan":"plus","resetCredits":{"availableCount":1}},
            {"account":{"evidence":"account","id":"account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02","provider":"Codex"},"home":"pi","isCurrent":true,"label":"b@example.com","observedAt":821692200,"plan":"pro","quotaNotice":"Pi offline","resetCredits":{"availableCount":2}}
        ],
        "Cursor":[
            {"account":{"evidence":"account","id":"account:b3edf67830b30a2f695431763701aad9fd8d5a981526635ed6f0d0e3734f169b","provider":"Cursor"},"home":"","isCurrent":true,"observedAt":821692740}
        ],
        "Grok":[
            {"account":{"evidence":"account","id":"account:f98ac22de354bd43d3108fe9537a661198c3b2c556bef16792fc9b5d7113cc0a","provider":"Grok"},"home":"","isCurrent":true,"observedAt":821692200}
        ],
        "Kimi":[
            {"account":{"evidence":"account","id":"pool:15e866067f74809a6a768dbecc28c897334f6d2bdf219933d79cc3967f5a3c49","provider":"Kimi"},"home":"","isCurrent":true,"observedAt":821692200,"quotaNotice":"rejected"},
            {"account":{"evidence":"account","id":"pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590","provider":"Kimi"},"home":"","isCurrent":true,"observedAt":821692740}
        ]
    },
    "activeQuotaPoolIDs":{
        "Kimi":["pool:15e866067f74809a6a768dbecc28c897334f6d2bdf219933d79cc3967f5a3c49","pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590"]
    },
    "billing":[
        {"balances":[{"currency":"CNY","granted":0,"toppedUp":8,"total":8}],"costs":[],"isAvailable":true,"notice":"Balance could not be read","sessionCosts":{},"updatedAt":821685600,"vendor":"DeepSeek"}
    ],
    "completions":[],
    "consumerIdsByQuota":{},
    "consumers":[
        {"connected":true,"enabled":true,"id":"deepseek-model:deepseek-chat","model":"deepseek-chat","source":"","vendor":"DeepSeek"}
    ],
    "discoveredAgents":[
        {"account":{"evidence":"account","id":"account:f4f7373574cffa3d9d10ce9279c4a62108fd14b443f077c2b64c2bb936d9e507","provider":"Codex"},"connected":true,"enabled":true,"id":"account:f4f7373574cffa3d9d10ce9279c4a62108fd14b443f077c2b64c2bb936d9e507\/codex","model":"5h","source":"","vendor":"Codex"},
        {"account":{"evidence":"account","id":"account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02","provider":"Codex"},"connected":true,"enabled":true,"id":"account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02\/codex","model":"5h","source":"","vendor":"Codex"},
        {"account":{"evidence":"account","id":"account:f98ac22de354bd43d3108fe9537a661198c3b2c556bef16792fc9b5d7113cc0a","provider":"Grok"},"connected":true,"enabled":true,"id":"account:f98ac22de354bd43d3108fe9537a661198c3b2c556bef16792fc9b5d7113cc0a\/grok","model":"Grok","source":"","vendor":"Grok"},
        {"account":{"evidence":"account","id":"account:b3edf67830b30a2f695431763701aad9fd8d5a981526635ed6f0d0e3734f169b","provider":"Cursor"},"connected":true,"enabled":true,"id":"account:b3edf67830b30a2f695431763701aad9fd8d5a981526635ed6f0d0e3734f169b\/cursor","model":"Included","source":"","vendor":"Cursor"},
        {"account":{"evidence":"account","id":"pool:15e866067f74809a6a768dbecc28c897334f6d2bdf219933d79cc3967f5a3c49","provider":"Kimi"},"billingPool":{"entitlement":"kimi-code","evidence":"account","product":"plan","provider":"Kimi","realm":"CN","scope":"scope-p"},"connected":true,"enabled":true,"id":"pool:15e866067f74809a6a768dbecc28c897334f6d2bdf219933d79cc3967f5a3c49:weekly","model":"7d","source":"Pi","vendor":"Kimi"},
        {"account":{"evidence":"account","id":"pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590","provider":"Kimi"},"billingPool":{"entitlement":"kimi-code","evidence":"account","product":"plan","provider":"Kimi","realm":"CN","scope":"scope-q"},"connected":true,"enabled":true,"id":"pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590:weekly","model":"7d","source":"Pi","vendor":"Kimi"},
        {"connected":true,"enabled":true,"id":"deepseek-model:deepseek-chat","model":"deepseek-chat","source":"","vendor":"DeepSeek"}
    ],
    "generatedAt":821692800,
    "insightsByAgent":{
        "account:f4f7373574cffa3d9d10ce9279c4a62108fd14b443f077c2b64c2bb936d9e507\/codex":{"burnRatePctPerHour":10,"timeToExhaust":3600,"weeklyCapHits":0,"weeklyWaitLongest":0,"weeklyWaitTotal":0},
        "pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590:weekly":{"burnRatePctPerHour":10,"timeToExhaust":7200,"weeklyCapHits":0,"weeklyWaitLongest":0,"weeklyWaitTotal":0}
    },
    "notice":"Cursor: Cursor usage events could not be read · DeepSeek: Balance could not be read · Grok: Sign in to Grok CLI, then refresh quota · Kimi: Kimi pool p: rejected · account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02: Pi offline",
    "quotaNotices":{
        "DeepSeek":"Balance could not be read",
        "Grok":"Sign in to Grok CLI, then refresh quota",
        "account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02":"Pi offline"
    },
    "rowSeenAt":{
        "account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02\/codex":821692800,
        "account:b3edf67830b30a2f695431763701aad9fd8d5a981526635ed6f0d0e3734f169b\/cursor":821692800,
        "account:f4f7373574cffa3d9d10ce9279c4a62108fd14b443f077c2b64c2bb936d9e507\/codex":821692800,
        "account:f98ac22de354bd43d3108fe9537a661198c3b2c556bef16792fc9b5d7113cc0a\/grok":821692800,
        "deepseek-model:deepseek-chat":821692800,
        "pool:15e866067f74809a6a768dbecc28c897334f6d2bdf219933d79cc3967f5a3c49:weekly":821692800,
        "pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590:weekly":821692800
    },
    "sessions":[],
    "snapshots":[
        {"agentId":"account:f4f7373574cffa3d9d10ce9279c4a62108fd14b443f077c2b64c2bb936d9e507\/codex","remainingPct":25,"resetAt":821700000,"updatedAt":821692740,"windowDuration":18000},
        {"agentId":"account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02\/codex","remainingPct":30,"resetAt":821700000,"updatedAt":821692200,"windowDuration":18000},
        {"agentId":"account:f98ac22de354bd43d3108fe9537a661198c3b2c556bef16792fc9b5d7113cc0a\/grok","remainingPct":45,"resetAt":821700000,"updatedAt":821692200,"windowDuration":18000},
        {"agentId":"account:b3edf67830b30a2f695431763701aad9fd8d5a981526635ed6f0d0e3734f169b\/cursor","remainingPct":60,"resetAt":821700000,"updatedAt":821692740,"windowDuration":18000},
        {"agentId":"pool:15e866067f74809a6a768dbecc28c897334f6d2bdf219933d79cc3967f5a3c49:weekly","remainingPct":20,"resetAt":821700000,"updatedAt":821692200,"windowDuration":18000},
        {"agentId":"pool:38bfbf023f0a2895ba8bb77996f9ee42c902ab2c5951dbab78318b0cfe27e590:weekly","remainingPct":50,"resetAt":821700000,"updatedAt":821692740,"windowDuration":18000}
    ],
    "sourceNotices":{
        "Cursor":"Cursor usage events could not be read",
        "DeepSeek":"Balance could not be read",
        "Grok":"Sign in to Grok CLI, then refresh quota",
        "Kimi":"Kimi pool p: rejected",
        "account:00b192765610242fa8b070022db4f29babc02611a7bb9bdaf9214715f2820e02":"Pi offline"
    },
    "subscriptions":{},
    "turns":[],
    "usage":[]
}
"""#
#endif

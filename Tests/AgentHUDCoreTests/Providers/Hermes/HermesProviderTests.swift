import AgentHUDSupport
import Foundation
import SQLite3
import XCTest
@testable import AgentHUDCore

final class HermesProviderTests: XCTestCase, @unchecked Sendable {
    private let now = Date()
    private var seconds: Double { now.timeIntervalSince1970 }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func database(_ url: URL, _ statements: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK else { throw ProviderFailure.local }
    }
    /// Only the columns the parser reads, spelled as Hermes spells them.
    private func stateDatabase(_ url: URL, profile: String? = nil) throws {
        try database(url, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL, ended_at REAL, input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0, cwd TEXT, billing_provider TEXT,
                billing_base_url TEXT, billing_mode TEXT, title TEXT, last_activity_at REAL, profile_name TEXT);
            CREATE TABLE session_model_usage (session_id TEXT NOT NULL, model TEXT NOT NULL, billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
                billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '', input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_write_tokens INTEGER NOT NULL DEFAULT 0, first_seen REAL, last_seen REAL,
                PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task));
            INSERT INTO sessions VALUES ('s1', 'cli', 'claude-test', \(seconds - 600), NULL, 999, 999, 999, 999, '/work/app', 'anthropic', '', 'api', 'Fix the build', \(seconds), \(profile.map { "'\($0)'" } ?? "NULL"));
            INSERT INTO session_model_usage VALUES ('s1', 'claude-test', 'anthropic', '', 'api', '', 100, 20, 50, 10, \(seconds - 590), \(seconds));
            INSERT INTO session_model_usage VALUES ('s1', 'small-test', 'openrouter', 'https://openrouter.ai/api/v1', 'api', 'title_generation', 30, 5, 0, 0, \(seconds - 300), \(seconds - 300));
            INSERT INTO sessions (id, source, model, started_at, input_tokens, output_tokens) VALUES ('old', 'cli', 'claude-test', \(seconds - 30 * 86400), 1, 1);
            """)
    }

    func testUsageRowsBecomeEventsWhoseIdentityHoldsWhileCountsGrow() async throws {
        let url = try directory().appendingPathComponent("state.db")
        try stateDatabase(url)
        let session = try XCTUnwrap(HermesSessions.read(url, since: now.addingTimeInterval(-86400)).sessions.first)
        XCTAssertEqual(session.id, "hermes:s1")
        XCTAssertEqual(session.title, "Fix the build")
        XCTAssertEqual(session.workspace, "/work/app")
        XCTAssertEqual(session.client, "Hermes Agent")
        let events = session.events.sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(events.map(\.model), ["claude-test", "small-test"], "Session totals are ignored once usage rows exist")
        XCTAssertEqual(events.map(\.input), [110, 30], "In is fresh input plus cache writes")
        XCTAssertEqual(events.map(\.output), [20, 5], "Reasoning is already inside output")
        XCTAssertEqual(events.map(\.cacheRead), [50, 0])
        XCTAssertEqual(events[0].timestamp.timeIntervalSince1970, seconds - 590, accuracy: 0.001)
        try database(url, "UPDATE session_model_usage SET input_tokens = input_tokens + 40, output_tokens = output_tokens + 8, last_seen = \(seconds + 60) WHERE task = ''")
        let updated = try XCTUnwrap(HermesSessions.read(url, since: now.addingTimeInterval(-86400)).sessions.first).events.sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(updated.map(\.id), events.map(\.id))
        XCTAssertEqual(updated[0].input, 150)
        XCTAssertEqual(updated[0].timestamp, events[0].timestamp)
        XCTAssertEqual(try HermesSessions.read(url, since: .distantPast).sessions.map(\.id), ["hermes:old", "hermes:s1"])
    }

    func testOlderDatabaseTotalsKeepTheIdentityAnUpgradeSeeds() async throws {
        let url = try directory().appendingPathComponent("state.db")
        try database(url, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL, input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0);
            INSERT INTO sessions VALUES ('s1', 'telegram', NULL, \(seconds - 60), 70, 9, 40);
            """)
        let before = try XCTUnwrap(HermesSessions.read(url, since: now.addingTimeInterval(-86400)).sessions.first)
        XCTAssertEqual(before.title, "Hermes · telegram")
        XCTAssertEqual(before.events.map(\.model), ["unknown"])
        XCTAssertEqual(before.events.map(\.input), [70])
        XCTAssertEqual(before.events.map(\.cacheRead), [40])
        // Hermes' own migration: add the columns and table, then seed one row per session from its totals.
        try database(url, """
            ALTER TABLE sessions ADD COLUMN cache_write_tokens INTEGER DEFAULT 0; ALTER TABLE sessions ADD COLUMN billing_provider TEXT;
            ALTER TABLE sessions ADD COLUMN billing_base_url TEXT; ALTER TABLE sessions ADD COLUMN billing_mode TEXT;
            CREATE TABLE session_model_usage (session_id TEXT NOT NULL, model TEXT NOT NULL, billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
                billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '', input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_write_tokens INTEGER NOT NULL DEFAULT 0, first_seen REAL, last_seen REAL);
            INSERT INTO session_model_usage SELECT id, COALESCE(model, 'unknown'), COALESCE(billing_provider, ''), COALESCE(billing_base_url, ''), COALESCE(billing_mode, ''), '',
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, started_at, started_at FROM sessions;
            INSERT INTO sessions (id, source, model, started_at, input_tokens, output_tokens) VALUES ('s2', 'cli', 'claude-test', \(seconds), 3, 4);
            """)
        let after = try HermesSessions.read(url, since: now.addingTimeInterval(-86400)).sessions
        XCTAssertEqual(after.first?.events, before.events)
        XCTAssertEqual(after.last?.events.map(\.input), [3], "A session without usage rows still counts its totals")
    }

    func testProfileDatabasesAreScopedAndSourceCheckoutIsNotScanned() async throws {
        let root = try directory()
        try stateDatabase(root.appendingPathComponent("state.db"))
        try stateDatabase(root.appendingPathComponent("profiles/coder/state.db"), profile: "coder")
        let checkout = root.appendingPathComponent("hermes-agent/tests/state.db")
        try stateDatabase(checkout)
        try database(checkout, "INSERT INTO sessions (id, source, started_at, input_tokens, output_tokens) VALUES ('checkout', 'cli', \(seconds), 1, 1)")
        let result = await AdditionalLocalStore(source: .hermes, roots: [root]).index(since: now.addingTimeInterval(-3600))
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.sessions.map(\.id), ["hermes:coder:s1", "hermes:s1"])
        XCTAssertEqual(result.sessions.map(\.client), ["Hermes Agent · coder", "Hermes Agent"])
        XCTAssertTrue(Set(result.sessions[0].events.map(\.id)).isDisjoint(with: result.sessions[1].events.map(\.id)))
        XCTAssertEqual(HermesSessions.roots(home: root, environment: ["HERMES_HOME": "/tmp/hermes"]).map(\.path), ["/tmp/hermes"])
    }
}

import Foundation
import SQLite3
import XCTest
@testable import AgentHUDCore

final class ZCodeProviderTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1788800000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func database(_ url: URL, total: Bool = true, sessions: Bool = true, _ rows: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE model_usage (id TEXT PRIMARY KEY, session_id TEXT, turn_id TEXT, model_id TEXT, started_at INTEGER, completed_at INTEGER,
                duration_ms INTEGER, input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER\(total ? ", computed_total_tokens INTEGER" : ""), agent TEXT, mode TEXT);
            \(sessions ? "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, path TEXT); INSERT INTO session VALUES ('s1', '/Users/alice/work/demo', '/Users/alice/work/demo');" : "")
            """
        let columns = "id, session_id, model_id, started_at, completed_at, input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens, cache_creation_input_tokens"
        let inserts = rows.map { "INSERT INTO model_usage (\(columns)\(total ? ", computed_total_tokens" : "")) VALUES (\($0));" }
        XCTAssertEqual(sqlite3_exec(handle, schema + inserts.joined(), nil, nil, nil), SQLITE_OK)
    }
    private func ms(_ offset: Double) -> Int64 { Int64((now.timeIntervalSince1970 + offset) * 1000) }

    func testTotalDecidesTokenLayoutAndSessionJoinsWorkspace() async throws {
        let url = try directory().appendingPathComponent("db.sqlite")
        try database(url, [
            "'inclusive', 's1', 'GLM-5.2', \(ms(-10)), \(ms(-9)), 100, 50, 10, 80, 5, 150",
            "'additive', 's1', 'GLM-5.2', \(ms(-8)), NULL, 20, 30, 5, 80, 10, 145",
            "'unknown-total', 's2', NULL, \(ms(-7)), \(ms(-6)), 100, 50, 10, 80, 5, NULL",
            "'contradictory', 's2', 'glm', NULL, \(ms(-5)), 10, 50, 0, 80, 0, 60",
            "'untimed', 's2', 'glm', NULL, NULL, 10, 5, 0, 0, 0, 15",
            "'old', 's1', 'glm', NULL, \(ms(-30 * 86400)), 10, 5, 0, 0, 0, 15"
        ])
        let result = try ZCodeSessions.read(url, since: now.addingTimeInterval(-86400))
        XCTAssertNotNil(result.notice)
        let demo = try XCTUnwrap(result.sessions.first { $0.id == "zcode:s1" })
        XCTAssertEqual(demo.title, "demo")
        XCTAssertEqual(demo.workspace, "/Users/alice/work/demo")
        XCTAssertEqual(demo.events.map(\.id), ["inclusive", "additive"])
        XCTAssertEqual(demo.events.map(\.input), [20, 30])
        XCTAssertEqual(demo.events.map(\.output), [50, 35])
        XCTAssertEqual(demo.events.map(\.cacheRead), [80, 80])
        XCTAssertEqual(demo.events[0].timestamp, Date(timeIntervalSince1970: now.timeIntervalSince1970 - 9), "completed_at is the request time")
        XCTAssertEqual(demo.events[1].timestamp, Date(timeIntervalSince1970: now.timeIntervalSince1970 - 8))
        XCTAssertEqual(demo.startedAt, Date(timeIntervalSince1970: now.timeIntervalSince1970 - 10))
        let other = try XCTUnwrap(result.sessions.first { $0.id == "zcode:s2" })
        XCTAssertEqual(other.title, "ZCode · s2")
        XCTAssertEqual(other.events.map(\.id), ["unknown-total"])
        XCTAssertEqual([other.events[0].input, other.events[0].output, other.events[0].cacheRead], [105, 60, 80])
        XCTAssertEqual(other.events[0].model, "Unknown")
    }

    func testZCodesOwnTitleBeatsTheFolderName() async throws {
        let url = try directory().appendingPathComponent("db.sqlite")
        try database(url, sessions: false, ["'r1', 's1', 'glm', \(ms(-10)), \(ms(-9)), 100, 50, 10, 80, 5, 150",
                                           "'r2', 's2', 'glm', \(ms(-8)), \(ms(-7)), 100, 50, 10, 80, 5, 150"])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, title TEXT NOT NULL, title_source TEXT);
            INSERT INTO session VALUES ('s1', '/Users/alice/work/demo', 'Fix the login flow', 'generated'),
                ('s2', '/Users/alice/work/demo', 'Untitled session', 'first_input');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let result = try ZCodeSessions.read(url, since: now.addingTimeInterval(-86400))
        XCTAssertEqual(result.sessions.map(\.title), ["Fix the login flow", "demo"], "ZCode's name for an empty first input is no title")
    }

    func testOlderSchemaWithoutTotalIsInclusive() async throws {
        let url = try directory().appendingPathComponent("db.sqlite")
        try database(url, total: false, sessions: false, ["'legacy', 's1', 'glm-5.2', NULL, \(ms(0)), 100, 50, 10, 80, 5"])
        let result = try ZCodeSessions.read(url, since: now.addingTimeInterval(-60))
        let event = try XCTUnwrap(result.sessions.first?.events.first)
        XCTAssertEqual([event.input, event.output, event.cacheRead], [20, 50, 80])
        XCTAssertNil(result.sessions[0].workspace)
        XCTAssertNil(result.notice)
    }

    func testRowIdentityCountsOneRequestOnceAcrossCopies() async throws {
        let roots = [try directory(), try directory()], stamp = Int64(Date().timeIntervalSince1970 * 1000)
        for root in roots {
            try database(root.appendingPathComponent("db.sqlite"), ["'usage-1', 's1', 'glm', NULL, \(stamp), 10, 5, 0, 0, 0, 15",
                                                                   "'usage-2', 's1', 'glm', NULL, \(stamp), 10, 5, 0, 0, 0, 15"])
        }
        XCTAssertEqual(ZCodeSessions.related(roots[0].appendingPathComponent("db.sqlite")).map(\.lastPathComponent), ["db.sqlite-wal"])
        let result = await AdditionalLocalStore(source: .zcode, roots: roots).index(since: Date().addingTimeInterval(-60))
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.sessions.flatMap(\.events).compactMap { $0.usage(source: .zcode).eventID }.sorted(), ["zcode:usage-1", "zcode:usage-2"])
    }
}

import AgentHUDSupport
import Foundation

/// The ledger's connection and consumer catalog; confined to the ledger actor.
final class LedgerStorage {
    let connection: SQLiteConnection
    let retention: TimeInterval?
    /// The write count at each contribution key's latest change, for readers that keep what they read.
    private(set) var touched: [String: Int] = [:]
    private(set) var writes = 0
    func touch(_ key: String) {
        writes += 1
        touched[key] = writes
    }
    private var agents: [String: Int64] = [:]
    private var names: [Int64: String] = [:]

    init(url: URL?, retention: TimeInterval?) throws {
        self.retention = retention
        connection = try SQLiteConnection(url: url)
        try connection.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;")
        var version: Int64 = 0
        try connection.query("PRAGMA user_version") { version = $0.int(0) }
        if version < 1 {
            try connection.transaction {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS source_file (
                        source TEXT NOT NULL, path TEXT NOT NULL, signature TEXT NOT NULL, state BLOB, file_group TEXT,
                        PRIMARY KEY (source, path)) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS contribution (
                        id INTEGER PRIMARY KEY, source TEXT NOT NULL, key TEXT NOT NULL, account TEXT NOT NULL DEFAULT '',
                        counted INTEGER NOT NULL DEFAULT 1, digest INTEGER, UNIQUE (source, key));
                    CREATE TABLE IF NOT EXISTS agent (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
                    CREATE TABLE IF NOT EXISTS usage_event (
                        contribution_id INTEGER NOT NULL, event INTEGER NOT NULL, timestamp_ms INTEGER NOT NULL, agent INTEGER NOT NULL,
                        tokens_in INTEGER NOT NULL, tokens_out INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                        PRIMARY KEY (contribution_id, event)) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS usage_event_time ON usage_event (timestamp_ms);
                    CREATE TABLE IF NOT EXISTS usage_bucket (
                        start_ms INTEGER NOT NULL, source TEXT NOT NULL, account TEXT NOT NULL, agent INTEGER NOT NULL,
                        tokens_in INTEGER NOT NULL, tokens_out INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                        PRIMARY KEY (start_ms, source, account, agent)) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS cost_amount (
                        contribution_id INTEGER NOT NULL, event INTEGER NOT NULL, currency TEXT NOT NULL, timestamp_ms INTEGER NOT NULL,
                        billing TEXT NOT NULL, amount_pico INTEGER NOT NULL,
                        PRIMARY KEY (contribution_id, event, currency)) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS cost_amount_time ON cost_amount (timestamp_ms);
                    CREATE TABLE IF NOT EXISTS cost_bucket (
                        billing TEXT NOT NULL, start_ms INTEGER NOT NULL, currency TEXT NOT NULL,
                        amount_pico INTEGER NOT NULL, events INTEGER NOT NULL,
                        PRIMARY KEY (billing, start_ms, currency)) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS quota_sample (
                        scope TEXT NOT NULL, window_id TEXT NOT NULL, observed_at REAL NOT NULL, remaining REAL NOT NULL,
                        PRIMARY KEY (scope, window_id, observed_at)) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS quota_sample_time ON quota_sample (observed_at);
                    PRAGMA user_version = 1;
                    """)
            }
        }
        if version < 2 {
            // A session's contributions are found by key alone: its log path or id, and the paths under its directory.
            try connection.execute("CREATE INDEX IF NOT EXISTS contribution_key ON contribution (key); PRAGMA user_version = 2;")
        }
        if version < 3 {
            // Cache writes and reasoning are parts of the input and output already counted; logs read again fill them in.
            try connection.transaction {
                try connection.execute("""
                    ALTER TABLE usage_event ADD COLUMN cache_write INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE usage_event ADD COLUMN reasoning INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE usage_event ADD COLUMN context_window INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE usage_bucket ADD COLUMN cache_write INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE usage_bucket ADD COLUMN reasoning INTEGER NOT NULL DEFAULT 0;
                    CREATE TABLE IF NOT EXISTS session_mark (
                        contribution_id INTEGER NOT NULL, at_ms INTEGER NOT NULL, kind INTEGER NOT NULL,
                        PRIMARY KEY (contribution_id, at_ms, kind)) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS session_mark_time ON session_mark (at_ms);
                    CREATE TABLE IF NOT EXISTS model_context (agent INTEGER PRIMARY KEY, largest INTEGER NOT NULL);
                    INSERT OR REPLACE INTO model_context (agent, largest) SELECT agent, MAX(tokens_in + cache_read) FROM usage_event GROUP BY agent;
                    PRAGMA user_version = 3;
                    """)
            }
        }
        if version < 4 {
            // An API balance's readings, for the pace it falls at.
            try connection.transaction {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS balance_sample (
                        billing TEXT NOT NULL, currency TEXT NOT NULL, observed_ms INTEGER NOT NULL, amount_pico INTEGER NOT NULL,
                        PRIMARY KEY (billing, currency, observed_ms)) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS balance_sample_time ON balance_sample (observed_ms);
                    PRAGMA user_version = 4;
                    """)
            }
        }
        if version < 5 {
            // A call's own time (queue + first token + decode) where the log records it; nil where it does not.
            try connection.transaction {
                try connection.execute("""
                    ALTER TABLE usage_event ADD COLUMN duration_ms INTEGER;
                    ALTER TABLE usage_event ADD COLUMN ttft_ms INTEGER;
                    PRAGMA user_version = 5;
                    """)
            }
        }
        try connection.query("SELECT id, name FROM agent") { row in
            let id = row.int(0), name = row.text(1) ?? ""
            agents[name] = id
            names[id] = name
        }
        try connection.query("SELECT agent, largest FROM model_context") { largestContext[$0.int(0)] = $0.int(1) }
    }

    /// The largest prompt each consumer was seen with, which tells a model's context window where no log states it.
    private(set) var largestContext: [Int64: Int64] = [:]

    func noteContext(agent: Int64, tokens: Int64) throws {
        guard tokens > largestContext[agent] ?? 0 else { return }
        try connection.run("""
            INSERT INTO model_context (agent, largest) VALUES (?, ?)
            ON CONFLICT (agent) DO UPDATE SET largest = MAX(largest, excluded.largest)
            """, [.integer(agent), .integer(tokens)])
        largestContext[agent] = tokens
    }

    func agentID(_ name: String) throws -> Int64 {
        if let id = agents[name] { return id }
        try connection.run("INSERT OR IGNORE INTO agent (name) VALUES (?)", [.text(name)])
        var id: Int64 = 0
        try connection.query("SELECT id FROM agent WHERE name = ?", [.text(name)]) { id = $0.int(0) }
        agents[name] = id
        names[id] = name
        return id
    }

    func agentName(_ id: Int64) -> String { names[id] ?? "" }

    /// A consumer's id in the catalog, without adding one.
    func knownAgentID(_ name: String) -> Int64? { agents[name] }

    /// Follows a consumer that took the name `name`, or whose usage joined `existing`.
    func moved(_ id: Int64, to name: String, joining existing: Int64?) {
        if let old = names[id] { agents[old] = nil }
        guard let existing else {
            agents[name] = id
            names[id] = name
            return
        }
        names[id] = nil
        if let largest = largestContext.removeValue(forKey: id) { largestContext[existing] = max(largestContext[existing] ?? 0, largest) }
    }

    /// A rolled-back transaction can leave catalog entries that no longer exist.
    func reset() {
        agents = [:]
        names = [:]
        largestContext = [:]
        try? connection.query("SELECT id, name FROM agent") { row in
            let id = row.int(0), name = row.text(1) ?? ""
            agents[name] = id
            names[id] = name
        }
        try? connection.query("SELECT agent, largest FROM model_context") { largestContext[$0.int(0)] = $0.int(1) }
    }
}

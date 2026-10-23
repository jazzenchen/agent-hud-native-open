import AgentHUDSupport
import Darwin
import Foundation
import SQLite3

/// Devin CLI's on-disk session layout. Its home is `~/.local/share/devin/cli`: a SQLite `sessions.db` holding
/// `sessions`, `message_nodes` (per-message JSON with token metrics), `prompt_history` and `tool_call_state`;
/// `session_locks/<id>.lock` marks a session's running process; `transcripts/*.json` mirrors completed sessions.
enum DevinSessions: LocalSessionLayout {
    static let installPaths = [".local/share/devin/cli/sessions.db"]
    static func roots(home: URL, environment: [String: String]) -> [URL] { [home.appendingPathComponent(".local/share/devin/cli")] }
    static func accepts(_ url: URL) -> Bool { url.lastPathComponent == "sessions.db" }
    static func related(_ url: URL) -> [URL] { [URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] }

    /// The database keeps every stored message; the report needs the last week.
    static func read(_ url: URL) throws -> ProviderSessions {
        let now = Date()
        return try read(url, since: now.addingTimeInterval(-8 * 86400), now: now)
    }

    /// `message_nodes` is far too large to scan whole (hundreds of thousands of multi-KB JSON rows), so the session
    /// list is bounded by `last_activity_at` and each session, most recent first, contributes only its newest nodes —
    /// the node's `row_id` index supplies the order — while the reader's time budget lasts. Sessions the budget does
    /// not reach keep their `sessions` row and report no events.
    static func read(_ url: URL, since: Date, now: Date = Date()) throws -> ProviderSessions {
        let database = try ReadOnlySQLite(url)
        try database.requireTable("sessions")
        let s = try columns("sessions", in: database)
        guard s.isSuperset(of: ["id", "created_at", "last_activity_at"]) else { throw ProviderFailure.format }
        func field(_ name: String) -> String { s.contains(name) ? "s.\(name)" : "NULL" }
        var sessions: [(raw: String, model: String?, session: ProviderSession)] = [], incomplete = false, truncated = false, count = 0
        let limit = 2000
        try database.rows("""
            SELECT s.id, \(field("title")), \(field("working_directory")), \(field("model")), s.created_at, s.last_activity_at
            FROM sessions s WHERE s.last_activity_at >= CAST(? AS REAL)\(s.contains("hidden") ? " AND s.hidden = 0" : "")
            ORDER BY s.last_activity_at DESC LIMIT \(limit)
            """, strings: [String(since.timeIntervalSince1970)]) { row in
            count += 1
            guard let raw = ReadOnlySQLite.text(row, 0), let started = seconds(row, 4), let last = seconds(row, 5)
            else { incomplete = true; return }
            let folder = ReadOnlySQLite.text(row, 2)
            let title = SessionTitle.named(ReadOnlySQLite.text(row, 1))
                ?? folder.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            sessions.append((raw, ReadOnlySQLite.text(row, 3).flatMap { $0.isEmpty ? nil : $0 }, ProviderSession(id: "devin:\(raw)",
                title: title ?? "Devin · \(raw.prefix(8))", workspace: folder, path: url.path, client: "Devin CLI",
                startedAt: started, lastActivity: last)))
        }
        truncated = count >= limit

        // A lock keeps a quiet session eligible, but only the client's activity dates its turn: observing an open CLI
        // again must not make an earlier Stop look older than new work that never happened.
        let live = liveLocks(in: url.deletingLastPathComponent(), sessionIDs: Set(sessions.map(\.raw)))
        for index in sessions.indices {
            guard let observed = sessions[index].session.lastActivity,
                  live.contains(sessions[index].raw) || now.timeIntervalSince(observed) < SessionPhase.Limits.quiet else { continue }
            sessions[index].session.turns = [SessionTurn(provider: "Devin", sessionID: sessions[index].session.id, turnID: sessions[index].raw,
                state: .running, startedAtMs: nil, observedAtMs: RecordCoding.milliseconds(observed))]
        }

        let n = try columns("message_nodes", in: database)
        let hasNodes = n.isSuperset(of: ["row_id", "session_id", "chat_message", "created_at"])
        if hasNodes {
            // `rows` shares one deadline across every query on the connection; stop issuing sessions rather than fail.
            let budget = Date().addingTimeInterval(2.4), newest = 1000
            for index in sessions.indices {
                guard Date() < budget else { truncated = true; break }
                var seen = Set<String>(), rows = 0
                do {
                    try database.rows("""
                        SELECT n.row_id, n.created_at,
                            CASE WHEN json_valid(n.chat_message) THEN json_extract(n.chat_message, '$.message_id', '$.metadata.request_id',
                                '$.metadata.generation_model', '$.metadata.created_at', '$.metadata.metrics') END
                        FROM message_nodes n WHERE n.session_id = ? ORDER BY n.row_id DESC LIMIT \(newest)
                        """, strings: [sessions[index].raw]) { row in
                        rows += 1
                        do { try node(row, session: &sessions[index].session, model: sessions[index].model, seen: &seen, since: since) }
                        catch { incomplete = true }
                    }
                } catch { truncated = true; break }
                if rows >= newest { truncated = true }
            }
        }
        let notices = [hasNodes ? nil : L10n.text("Devin 消息表缺失或结构已变，会话暂无事件",
                                                  "Devin's message table is missing or its shape changed; sessions carry no events"),
                       incomplete ? L10n.text("部分 Devin 用量记录缺少时间或计数无法核对，未计入统计",
                                              "Some Devin usage records lack a time or have inconsistent counts and were excluded") : nil,
                       truncated ? ProviderFailure.limit.message : nil].compactMap { $0 }
        return ProviderSessions(sessions: sessions.map {
            var item = $0.session; item.events.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }; return item
        }, notice: notices.isEmpty ? nil : notices.joined(separator: " · "),
           usageIsComplete: hasNodes && !incomplete && !truncated)
    }

    /// One usage event from a `message_nodes` row; nothing when the row carries no token metrics. `chat_message` text
    /// itself — prompts and tool bodies — never leaves the database; the query projects only whitelisted fields into a
    /// small array, one document parse instead of one per field, and a malformed document reads as NULL and is skipped.
    private static func node(_ row: OpaquePointer, session: inout ProviderSession, model: String?, seen: inout Set<String>, since: Date) throws {
        guard let fields = ReadOnlySQLite.text(row, 2).flatMap({ try? ProviderJSON.read(Data($0.utf8)) })?.arrayValue,
              fields.count >= 5, let counted = try tokens(fields[4]) else { return }
        guard let date = fields[3].stringValue.flatMap(DateParsing.internet) ?? seconds(row, 1) else { throw ProviderFailure.format }
        guard date >= since else { return }
        // The forest keeps a message's copies on multiple branches; one request counts once.
        let key = fields[1].stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? fields[0].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "row-\(sqlite3_column_int64(row, 0))"
        guard seen.insert(key).inserted else { return }
        var event = ProviderEvent(id: key, model: fields[2].stringValue ?? model ?? "Unknown", timestamp: date,
            input: try TokenCount.sum(counted.input, counted.cacheWrite), output: counted.output,
            cacheRead: counted.cacheRead, cacheWrite: counted.cacheWrite)
        // `metrics.total_time_ms` is the call's own span (ttft + tpot × output), `ttft_ms` its wait for the first token.
        event.durationMs = fields[4]["total_time_ms"].countValue
        event.ttftMs = fields[4]["ttft_ms"].countValue
        session.events.append(event)
    }

    /// `metadata.metrics` names the call's counts: `input_tokens` sits beside both cache kinds, which are read apart,
    /// and `cache_creation` bills as input like the other readers treat cache writes. Other backends instead report
    /// inclusive `total_` counts, where `total_cached_tokens` is inside `total_prompt_tokens`.
    private static func tokens(_ metrics: ProviderJSON) throws -> (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)? {
        if metrics["input_tokens"] == .null, metrics["total_prompt_tokens"] != .null {
            let prompt = try metrics["total_prompt_tokens"].optionalCounter(), cached = try metrics["total_cached_tokens"].optionalCounter()
            guard cached <= prompt else { throw ProviderFailure.format }
            let completion = try metrics["total_completion_tokens"].optionalCounter()
            return try TokenCount.sum(prompt, completion) > 0 ? (prompt - cached, completion, cached, 0) : nil
        }
        let input = try metrics["input_tokens"].optionalCounter(), output = try metrics["output_tokens"].optionalCounter()
        let read = try metrics["cache_read_tokens"].optionalCounter(), write = try metrics["cache_creation_tokens"].optionalCounter()
        return try TokenCount.sum(input, output, read, write) > 0 ? (input, output, read, write) : nil
    }

    /// Sessions whose `session_locks/<id>.lock` names a process that still exists.
    private static func liveLocks(in directory: URL, sessionIDs: Set<String>) -> Set<String> {
        let locks = directory.appendingPathComponent("session_locks", isDirectory: true)
        var live = Set<String>()
        for file in (try? FileManager.default.contentsOfDirectory(atPath: locks.path)) ?? [] where file.hasSuffix(".lock") {
            let raw = String(file.dropLast(".lock".count))
            guard sessionIDs.contains(raw),
                  let pid = (try? String(contentsOf: locks.appendingPathComponent(file), encoding: .utf8))
                    .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), pid > 0,
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            live.insert(raw)
        }
        return live
    }

    private static func columns(_ table: String, in database: ReadOnlySQLite) throws -> Set<String> {
        var names = Set<String>()
        try database.rows("SELECT name FROM pragma_table_info(?)", strings: [table]) { row in
            if let name = ReadOnlySQLite.text(row, 0) { names.insert(name) }
        }
        return names
    }

    /// Sessions and nodes count time in unix seconds.
    private static func seconds(_ row: OpaquePointer, _ column: Int32) -> Date? {
        let type = sqlite3_column_type(row, column)
        guard type == SQLITE_INTEGER || type == SQLITE_FLOAT else { return nil }
        let value = sqlite3_column_double(row, column)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}

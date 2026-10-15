import Foundation
import SQLite3

/// Normal SQLite read transactions include active WAL data; no copying or immutable reads of live databases.
/// A WAL database's writer may remove its `-wal` and `-shm` files on close, and the system SQLite does not let a
/// read-only connection create them again. With no WAL or rollback journal beside it the file alone is the committed
/// database, so it is read as immutable, and the read fails if the file changes before it ends.
final class ReadOnlySQLite {
    private let database: OpaquePointer
    private let deadline: Date
    /// An immutable read's file, with its signature when the read began.
    private let immutable: (path: String, signature: [Int])?

    init(_ url: URL) throws {
        let path = url.path
        var opened = Self.begin(path, flags: SQLITE_OPEN_READONLY), immutable: (path: String, signature: [Int])?
        if opened.result == SQLITE_CANTOPEN, let signature = Self.signature(path),
           !["-wal", "-journal"].contains(where: { FileManager.default.fileExists(atPath: path + $0) }) {
            opened = Self.begin(URL(fileURLWithPath: path).absoluteString + "?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            immutable = (path, signature)
        }
        guard let handle = opened.handle else { throw ProviderFailure.local }
        database = handle
        self.immutable = immutable
        deadline = Date().addingTimeInterval(3)
        sqlite3_progress_handler(handle, 1000, { pointer in
            guard let pointer else { return 1 }
            let reader = Unmanaged<ReadOnlySQLite>.fromOpaque(pointer).takeUnretainedValue()
            return Date() > reader.deadline || Task.isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// A connection inside a read transaction, or nil and the result code that prevented one. The transaction's first
    /// read opens the WAL, which is where a WAL database without its files fails.
    private static func begin(_ name: String, flags: Int32) -> (handle: OpaquePointer?, result: Int32) {
        var handle: OpaquePointer?
        var result = sqlite3_open_v2(name, &handle, flags, nil)
        if result == SQLITE_OK, let handle {
            sqlite3_busy_timeout(handle, 250)
            sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024)
            result = sqlite3_exec(handle, "BEGIN; PRAGMA schema_version", nil, nil, nil)
            if result == SQLITE_OK { return (handle, result) }
        }
        sqlite3_close(handle)
        return (nil, result)
    }

    /// Device, inode, size and modification time, which any write to the file or its replacement changes.
    private static func signature(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if os(Windows)
        return [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino), Int(info.st_size), Int(info.st_mtime)]
        #else
        return [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
        #endif
    }

    deinit {
        sqlite3_progress_handler(database, 0, nil, nil)
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close(database)
    }

    func rows(_ sql: String, strings: [String] = [], consume: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProviderFailure.local }
        defer { sqlite3_finalize(statement) }
        for (index, value) in strings.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var count = 0, bytes = 0
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                // Pages an immutable read took before and after a writer's change do not form one database.
                if let immutable, Self.signature(immutable.path) != immutable.signature { throw ProviderFailure.local }
                return
            }
            guard result == SQLITE_ROW else { throw ProviderFailure.local }
            count += 1
            for index in 0..<sqlite3_column_count(statement) { bytes += Int(sqlite3_column_bytes(statement, index)) }
            guard count <= 10000, bytes <= 64 * 1024 * 1024, Date() <= deadline else { throw ProviderFailure.limit }
            try consume(statement)
        }
    }

    func requireTable(_ name: String) throws {
        var table = false
        try rows("SELECT type, sql FROM sqlite_master WHERE name = ?", strings: [name]) { row in
            let sql = Self.text(row, 1)?.uppercased() ?? ""
            table = Self.text(row, 0) == "table" && !sql.contains("VIRTUAL TABLE")
        }
        guard table else { throw ProviderFailure.format }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(row, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(row, column))
        guard let pointer = sqlite3_column_blob(row, column) else { return nil }
        let data = Data(bytes: pointer, count: count)
        if data.contains(0), let value = String(data: data, encoding: .utf16LittleEndian), !value.contains("\0") { return value }
        return String(data: data, encoding: .utf8)
    }
    static func blob(_ row: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(row, column) == SQLITE_BLOB, let pointer = sqlite3_column_blob(row, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, column)))
    }
}

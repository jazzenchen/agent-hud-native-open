#if !os(Windows)
// Providers/Codex/CodexDaemonOriginTransportTests.swift tests macOS-side sockets and home layouts.
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

final class CodexDaemonOriginTransportTests: XCTestCase {
    func testAcceptsOnlyTheNativeLoopbackOriginWithoutCredentials() {
        func origin(_ value: String, name: String = "codex_tui") -> URL? {
            CodexDaemonOriginTransport.httpOrigin(in: ["data": [["name": name, "httpOrigin": value]]])
        }
        XCTAssertEqual(origin("http://127.0.0.1:61690")?.port, 61690)
        for value in ["https://127.0.0.1:61690", "http://localhost:61690", "http://example.com:61690",
                      "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
                      "http://user:password@127.0.0.1:61690", "http://127.0.0.1:61690/mcp",
                      "http://127.0.0.1:61690?token=value", "http://127.0.0.1:61690#fragment"] {
            XCTAssertNil(origin(value), value)
        }
        XCTAssertNil(origin("http://127.0.0.1:61690", name: "other_server"))
        XCTAssertNil(CodexDaemonOriginTransport.httpOrigin(in: ["data": [
            ["name": "codex_tui", "httpOrigin": "http://127.0.0.1:61690"],
            ["name": "codex_tui", "httpOrigin": "http://127.0.0.1:61691"],
        ]]))
    }

    func testBatchUsesOneConnectionAndQueriesOnlyLoadedRequestedThreads() async throws {
        let first = UUID().uuidString, second = UUID().uuidString, absent = UUID().uuidString
        let daemon = try OriginTestDaemon(loaded: [first, second, UUID().uuidString])
        defer { daemon.stop() }
        let origins = await CodexDaemonOriginTransport.tuiHTTPOrigins(
            threadIDs: [first, second, absent], dataDirectory: daemon.directory)
        XCTAssertEqual(Set(origins.keys), [first, second])
        XCTAssertEqual(origins[first]?.absoluteString, "http://127.0.0.1:61690")
        XCTAssertEqual(daemon.methods, ["initialize", "initialized", "thread/loaded/list",
                                       "mcpServerStatus/list", "mcpServerStatus/list"])
        XCTAssertEqual(daemon.queriedThreads, [first, second].sorted())
        XCTAssertTrue(daemon.requestsAreScoped, "never resume/read a thread, call a tool, or query account/config")
    }

    func testOneDeadlineBoundsAStalledDaemon() async throws {
        let daemon = try OriginTestDaemon(loaded: [], stall: true)
        defer { daemon.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        let origins = await CodexDaemonOriginTransport.tuiHTTPOrigins(
            threadIDs: [UUID().uuidString], dataDirectory: daemon.directory, timeout: 0.08)
        XCTAssertTrue(origins.isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
    }

    func testFollowsLoadedThreadCursorBeforeQueryingTheRequestedThread() async throws {
        let id = UUID().uuidString
        let daemon = try OriginTestDaemon(loaded: [id], paginate: true)
        defer { daemon.stop() }
        let origins = await CodexDaemonOriginTransport.tuiHTTPOrigins(threadIDs: [id], dataDirectory: daemon.directory)
        XCTAssertEqual(Set(origins.keys), [id])
        XCTAssertEqual(daemon.methods, ["initialize", "initialized", "thread/loaded/list",
                                       "thread/loaded/list", "mcpServerStatus/list"])
        XCTAssertEqual(daemon.queriedThreads, [id])
    }

    func testMissingDaemonAndInvalidThreadNeverLaunchAProcess() async {
        let directory = URL(fileURLWithPath: "/private/tmp/agenthud-absent-\(UUID().uuidString)")
        let absent = await CodexDaemonOriginTransport.tuiHTTPOrigins(
            threadIDs: [UUID().uuidString], dataDirectory: directory)
        let invalid = await CodexDaemonOriginTransport.tuiHTTPOrigins(threadIDs: ["cwd-is-not-a-thread"], dataDirectory: directory)
        XCTAssertTrue(absent.isEmpty)
        XCTAssertTrue(invalid.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

/// A local fake daemon verifies the wire contract without touching a user's engine, threads or hooks.
private final class OriginTestDaemon: @unchecked Sendable {
    let directory: URL
    private let listener: Int32
    private let loaded: [String]
    private let stall: Bool
    private let paginate: Bool
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    var methods: [String] { lock.withLock { messages.compactMap { $0["method"] as? String } } }
    var queriedThreads: [String] { lock.withLock {
        messages.filter { $0["method"] as? String == "mcpServerStatus/list" }
            .compactMap { ($0["params"] as? [String: Any])?["threadId"] as? String }
    } }
    var requestsAreScoped: Bool { lock.withLock {
        messages.filter { $0["method"] as? String == "mcpServerStatus/list" }.allSatisfy {
            guard let params = $0["params"] as? [String: Any] else { return false }
            return params["serverName"] as? String == "codex_tui"
                && params["detail"] as? String == "toolsAndAuthOnly" && params["limit"] as? Int == 1
        }
    } }

    init(loaded: [String], stall: Bool = false, paginate: Bool = false) throws {
        self.loaded = loaded; self.stall = stall; self.paginate = paginate
        directory = URL(fileURLWithPath: "/private/tmp/agenthud-ws-\(UUID().uuidString.prefix(8))")
        let folder = directory.appendingPathComponent("app-server-control")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("app-server-control.sock").path
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, UnixSocket.fits(path) else { throw TestFailure.socket }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, path, 104) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, 1) == 0 else { Darwin.close(listener); throw TestFailure.socket }
        DispatchQueue.global().async { self.serve() }
    }

    func stop() { Darwin.close(listener); try? FileManager.default.removeItem(at: directory) }

    private func serve() {
        var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 2000) > 0 else { return }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0), on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if stall { _ = try? read(client, count: 1); _ = try? read(client, count: 1024 * 1024); return }
        do {
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) { header.append(contentsOf: try read(client, count: 1)) }
            guard let request = String(data: header, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }) else {
                throw TestFailure.protocolError
            }
            let key = line.dropFirst("Sec-WebSocket-Key:".count).trimmingCharacters(in: .whitespaces)
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            guard UnixSocket.send(client, Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8)) else { return }
            while true {
                let message = try receive(client)
                lock.withLock { messages.append(message) }
                guard let id = message["id"] as? Int else { continue }
                let result: [String: Any]
                switch message["method"] as? String {
                case "initialize": result = [:]
                case "thread/loaded/list":
                    if paginate, (message["params"] as? [String: Any])?["cursor"] == nil {
                        result = ["data": [UUID().uuidString], "nextCursor": "after-first-page"]
                    } else { result = ["data": loaded, "nextCursor": NSNull()] }
                case "mcpServerStatus/list": result = ["data": [["name": "codex_tui", "httpOrigin": "http://127.0.0.1:61690"]]]
                default: throw TestFailure.protocolError
                }
                let reply = try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
                // Ping and a fragmented reply exercise control frames and continuation messages.
                if id >= 3 { try frame(client, payload: Data([1, 2, 3]), opcode: 9) }
                let middle = reply.count / 2
                try frame(client, payload: reply.prefix(middle), opcode: 1, final: false)
                try frame(client, payload: reply.dropFirst(middle), opcode: 0)
            }
        } catch { }
    }

    private func receive(_ client: Int32) throws -> [String: Any] {
        while true {
            let header = try read(client, count: 2)
            guard header[1] & 0x80 != 0 else { throw TestFailure.protocolError }
            var size = Int(header[1] & 0x7F)
            if size == 126 { size = try read(client, count: 2).reduce(0) { ($0 << 8) | Int($1) } }
            let mask = try read(client, count: 4), bytes = try read(client, count: size)
            if header[0] & 0x0F == 10 { continue }
            let decoded = bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            guard let result = try JSONSerialization.jsonObject(with: Data(decoded)) as? [String: Any] else {
                throw TestFailure.protocolError
            }
            return result
        }
    }

    private func frame(_ client: Int32, payload: Data, opcode: UInt8, final: Bool = true) throws {
        var bytes = [UInt8((final ? 0x80 : 0) | opcode)]
        if payload.count < 126 { bytes.append(UInt8(payload.count)) }
        else { bytes += [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)] }
        bytes += payload
        guard UnixSocket.send(client, Data(bytes)) else { throw TestFailure.socket }
    }

    private func read(_ client: Int32, count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: min(count - result.count, 4096))
            let size = recv(client, &bytes, bytes.count, 0)
            guard size > 0 else { throw TestFailure.socket }
            result += bytes.prefix(size)
        }
        return result
    }

    private enum TestFailure: Error { case socket, protocolError }
}
#endif

import Foundation
#if canImport(Darwin)
import Darwin
#else
import WinSDK
#endif

/// Reads the running daemon's thread-owned TUI MCP endpoint. Codex 0.160 publishes it through
/// mcpServerStatus/list.httpOrigin, which excludes the MCP path and authentication headers.
public enum CodexDaemonOriginTransport {
    public static func tuiHTTPOrigins(threadIDs: Set<String>, dataDirectory: URL = CodexLocator.dataDirectory,
                                      timeout: TimeInterval = 3) async -> [String: URL] {
        let ids = threadIDs.filter { UUID(uuidString: $0) != nil }
        guard !ids.isEmpty, timeout.isFinite, timeout > 0 else { return [:] }
        return await Task.detached(priority: .utility) { () -> [String: URL] in
            let path = dataDirectory.appendingPathComponent("app-server-control/app-server-control.sock").path
            guard let socket = try? DaemonOriginSocket(path: path, timeout: timeout) else { return [:] }
            defer { socket.close() }
            var origins: [String: URL] = [:]
            do {
                try socket.upgrade()
                _ = try socket.request(id: 1, method: "initialize", params: [
                    "clientInfo": ["name": "agent_hud_origin", "title": "Agent HUD", "version": "0.1.0"],
                ])
                try socket.sendJSON(["method": "initialized"])
                var active = Set<String>(), cursor: String?, requestID = 2
                repeat {
                    let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
                    let loaded = try socket.request(id: requestID, method: "thread/loaded/list", params: params)
                    active.formUnion(Set(loaded["data"] as? [String] ?? []).intersection(ids))
                    cursor = loaded["nextCursor"] as? String
                    requestID += 1
                } while cursor != nil
                for id in active.sorted() {
                    let result = try socket.request(id: requestID, method: "mcpServerStatus/list", params: [
                        "threadId": id, "serverName": "codex_tui", "detail": "toolsAndAuthOnly", "limit": 1,
                    ])
                    requestID += 1
                    if let origin = httpOrigin(in: result) { origins[id] = origin }
                }
            } catch { }
            return origins
        }.value
    }

    public static func tuiHTTPOrigin(threadID: String, dataDirectory: URL = CodexLocator.dataDirectory,
                                     timeout: TimeInterval = 3) async -> URL? {
        await tuiHTTPOrigins(threadIDs: [threadID], dataDirectory: dataDirectory, timeout: timeout)[threadID]
    }

    static func httpOrigin(in result: [String: Any]) -> URL? {
        guard let servers = result["data"] as? [[String: Any]], servers.count == 1,
              let server = servers.first, server["name"] as? String == "codex_tui",
              let value = server["httpOrigin"] as? String, let parts = URLComponents(string: value),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        return parts.url
    }
}

/// The daemon control socket carries RFC 6455 frames, rather than the stdio client's JSON lines.
private final class DaemonOriginSocket {
    private let descriptor: Int32
    private let deadline: TimeInterval
    private var remaining: TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }
    private var buffer: [UInt8] = []
    private let maximumMessage = 1024 * 1024

    init(path: String, timeout: TimeInterval) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        #if os(Windows)
        guard WinSock.started, UnixSocket.fits(path) else { throw Failure.unavailable }
        let handle = WinSDK.socket(afUnix, sockStream, 0)
        guard handle != WinSDK.INVALID_SOCKET else { throw Failure.unavailable }
        descriptor = Int32(truncatingIfNeeded: handle)
        do {
            var milliseconds: DWORD = DWORD(max(1, min(timeout, 86_400) * 1000))
            let size = DWORD(MemoryLayout<DWORD>.size)
            guard setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &milliseconds, size) == 0,
                  setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &milliseconds, size) == 0 else { throw Failure.unavailable }
            let connected = UnixSocket.withAddress(path) { address, length in
                WinSDK.connect(handle, address, length)
            }
            guard connected == 0 else { throw Failure.unavailable }
        } catch {
            WinSDK.closesocket(handle)
            throw error
        }
        #else
        var info = stat()
        guard UnixSocket.fits(path), stat(path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK else { throw Failure.unavailable }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        do {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.unavailable }
            var on: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
                field.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, path, 104) }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw Failure.unavailable }
                try wait(for: Int16(POLLOUT))
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw Failure.unavailable
                }
            }
        } catch { Darwin.close(descriptor); throw error }
        #endif
    }

    func close() {
        #if os(Windows)
        UnixSocket.close(descriptor)
        #else
        Darwin.close(descriptor)
        #endif
    }

    func upgrade() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        try write(Array(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8))
        var header: [UInt8] = []
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16 * 1024 else { throw Failure.protocolError }
            header += try read(1)
        }
        guard let text = String(bytes: header, encoding: .utf8) else { throw Failure.protocolError }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "101" else { throw Failure.protocolError }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<separator]).lowercased()] = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let expected = Data(Digest.sha1(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        guard fields["sec-websocket-accept"] == expected, fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().split(separator: ",").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "upgrade"
              }) == true else { throw Failure.protocolError }
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try sendJSON(["id": id, "method": method, "params": params])
        while true {
            guard let message = try JSONSerialization.jsonObject(with: receiveMessage()) as? [String: Any] else {
                throw Failure.protocolError
            }
            guard (message["id"] as? NSNumber)?.intValue == id else { continue }
            if message["error"] != nil { return [:] }
            guard let result = message["result"] as? [String: Any] else { throw Failure.protocolError }
            return result
        }
    }

    func sendJSON(_ message: [String: Any]) throws {
        try sendFrame(Array(JSONSerialization.data(withJSONObject: message)), opcode: 1)
    }

    private func sendFrame(_ payload: [UInt8], opcode: UInt8) throws {
        guard payload.count <= maximumMessage else { throw Failure.protocolError }
        var frame = [UInt8(0x80 | opcode)]
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65535 {
            frame += [0xFE, UInt8((payload.count >> 8) & 255), UInt8(payload.count & 255)]
        } else {
            frame.append(0xFF)
            frame += (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 255) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try write(frame)
    }

    private func receiveMessage() throws -> Data {
        var message: [UInt8] = [], started = false
        while true {
            let header = try read(2)
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw Failure.protocolError }
            let finished = header[0] & 0x80 != 0, opcode = header[0] & 0x0F
            var length = UInt64(header[1] & 0x7F)
            if length == 126 { length = try read(2).reduce(0) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try read(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard length <= maximumMessage else { throw Failure.protocolError }
            let payload = try read(Int(length))
            if opcode >= 8 {
                guard finished, length <= 125 else { throw Failure.protocolError }
                switch opcode {
                case 9: try sendFrame(payload, opcode: 10)
                case 10: break
                default: throw Failure.unavailable
                }
                continue
            }
            guard (opcode == 1 && !started) || (opcode == 0 && started),
                  message.count + payload.count <= maximumMessage else { throw Failure.protocolError }
            started = true
            message += payload
            if finished { return Data(message) }
        }
    }

    private func read(_ count: Int) throws -> [UInt8] {
        while buffer.count < count {
            #if os(Windows)
            var bytes = [UInt8](repeating: 0, count: 4096)
            let received = bytes.withUnsafeMutableBytes { raw in
                WinSDK.recv(UnixSocket.handleOf(descriptor), raw.baseAddress, Int32(raw.count), 0)
            }
            if received == WinSDK.SOCKET_ERROR {
                let error = WSAGetLastError()
                if error == WSAEINTR { continue }
                throw remaining > 0 ? Failure.unavailable : Failure.timeout
            }
            #else
            try wait(for: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: 4096)
            let received = recv(descriptor, &bytes, bytes.count, 0)
            if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            #endif
            guard received > 0 else { throw Failure.unavailable }
            buffer += bytes.prefix(Int(received))
        }
        let result = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            #if os(Windows)
            let sent = bytes.withUnsafeBytes {
                WinSDK.send(UnixSocket.handleOf(descriptor), $0.baseAddress!.advanced(by: offset), Int32(bytes.count - offset), 0)
            }
            if sent == WinSDK.SOCKET_ERROR {
                if WSAGetLastError() == WSAEINTR { continue }
                throw remaining > 0 ? Failure.unavailable : Failure.timeout
            }
            #else
            try wait(for: Int16(POLLOUT))
            let sent = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress! + offset, bytes.count - offset, 0) }
            if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            #endif
            guard sent > 0 else { throw Failure.unavailable }
            offset += sent
        }
    }

    #if !os(Windows)
    private func wait(for events: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timeout }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&entry, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, entry.revents & events != 0 else { throw Failure.unavailable }
            return
        }
    }
    #endif

    private enum Failure: Error { case unavailable, protocolError, timeout }
}

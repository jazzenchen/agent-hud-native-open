import AgentHUDSupport
import Foundation
#if canImport(Darwin)
import Darwin
#else
import WinSDK
#endif

/// Desktop IPC frames are a UInt32 little-endian length followed by UTF-8 JSON, rather than app-server JSON-RPC.
public final class CodexDesktopIPC {
    public enum Failure: Error, Equatable, Sendable {
        case invalidInput, unavailable, timedOut, protocolError
        case rejected(String)
        /// The submission may have been accepted. Do not automatically resend it.
        case acceptanceUncertain
    }

    private let descriptor: Int32
    private let deadline: TimeInterval
    /// A snapshot carries the thread's whole history: tens of megabytes for a long thread.
    private let maximumFrame = 64 * 1024 * 1024

    public init(path: String, timeout: TimeInterval) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        #if os(Windows)
        guard WinSock.started, UnixSocket.fits(path) else { throw Failure.unavailable }
        let handle = WinSDK.socket(afUnix, sockStream, 0)
        guard handle != WinSDK.INVALID_SOCKET else { throw Failure.unavailable }
        descriptor = Int32(truncatingIfNeeded: handle)
        do {
            // Windows has no poll over sockets here; read and send time out on the socket itself, and the deadline
            // below still bounds every call.
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
              (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw Failure.unavailable
        }
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
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { throw Failure.unavailable }
                try wait(for: Int16(POLLOUT))
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw Failure.unavailable
                }
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        #endif
    }

    public func close() {
        #if os(Windows)
        UnixSocket.close(descriptor)
        #else
        Darwin.close(descriptor)
        #endif
    }

    public func request(method: String, version: Int, source: String, target: String? = nil,
                        params: [String: Any], didWrite: (() -> Void)? = nil) throws -> [String: Any] {
        let requestID = UUID().uuidString.lowercased()
        var message: [String: Any] = ["type": "request", "requestId": requestID, "sourceClientId": source,
                                    "version": version, "method": method, "params": params,
                                    "timeoutMs": max(1, Int(min(remaining * 1000, Double(Int32.max))))]
        if let target { message["targetClientId"] = target }
        try send(message, didWrite: didWrite)
        while true {
            let response = try receive()
            if try answerDiscovery(response) { continue }
            guard response["type"] as? String == "response", response["requestId"] as? String == requestID else { continue }
            switch response["resultType"] as? String {
            case "success": return response
            case "error": throw Failure.rejected(response["error"] as? String ?? "unknown-ipc-error")
            default: throw Failure.protocolError
            }
        }
    }

    public func conversationSnapshot(source: String, owner: String, threadID: String) throws -> [String: Any] {
        try follow(true, source: source, owner: owner, threadID: threadID)
        defer { try? follow(false, source: source, owner: owner, threadID: threadID) }
        while true {
            let message = try receive()
            if try answerDiscovery(message) { continue }
            guard message["type"] as? String == "broadcast",
                  message["method"] as? String == "thread-stream-state-changed",
                  message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any],
                  params["hostId"] as? String == "local", params["conversationId"] as? String == threadID else { continue }
            guard message["version"] as? Int == 11,
                  let change = params["change"] as? [String: Any] else { throw Failure.protocolError }
            guard change["type"] as? String == "snapshot" else { continue }
            guard let state = change["conversationState"] as? [String: Any] else { throw Failure.protocolError }
            return state
        }
    }

    /// The same snapshot, its frame parsed once. A reader that asks at every pass uses this one: building a Foundation
    /// tree and converting it costs more than twice as much on a long thread.
    public func conversationState(source: String, owner: String, threadID: String) throws -> JSONValue {
        try follow(true, source: source, owner: owner, threadID: threadID)
        defer { try? follow(false, source: source, owner: owner, threadID: threadID) }
        while true {
            let message = try JSONValue.parse(receiveFrame())
            guard message.objectValue != nil else { throw Failure.protocolError }
            if try answerDiscovery(type: message["type"].stringValue, requestID: message["requestId"].stringValue) { continue }
            let params = message["params"], change = params["change"]
            guard message["type"].stringValue == "broadcast",
                  message["method"].stringValue == "thread-stream-state-changed",
                  message["sourceClientId"].stringValue == owner,
                  params["hostId"].stringValue == "local", params["conversationId"].stringValue == threadID else { continue }
            guard message["version"] == .integer(11), change.objectValue != nil else { throw Failure.protocolError }
            guard change["type"].stringValue == "snapshot" else { continue }
            let state = change["conversationState"]
            guard state.objectValue != nil else { throw Failure.protocolError }
            return state
        }
    }

    private func follow(_ value: Bool, source: String, owner: String, threadID: String) throws {
        try send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                  "sourceClientId": source, "targetClientIds": [owner],
                  "params": ["hostId": "local", "conversationId": threadID, "following": value]])
    }

    private func answerDiscovery(_ message: [String: Any]) throws -> Bool {
        try answerDiscovery(type: message["type"] as? String, requestID: message["requestId"] as? String)
    }

    private func answerDiscovery(type: String?, requestID: String?) throws -> Bool {
        guard type == "client-discovery-request", let requestID else { return false }
        try send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
        return true
    }

    private var remaining: TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }

    private func send(_ message: [String: Any], didWrite: (() -> Void)? = nil) throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        guard payload.count <= maximumFrame else { throw Failure.protocolError }
        var length = UInt32(payload.count).littleEndian
        var bytes = withUnsafeBytes(of: &length) { Data($0) }
        bytes.append(payload)
        var offset = 0
        while offset < bytes.count {
            #if os(Windows)
            let count = bytes.withUnsafeBytes {
                WinSDK.send(UnixSocket.handleOf(descriptor), $0.baseAddress!.advanced(by: offset), Int32(bytes.count - offset), 0)
            }
            if count == WinSDK.SOCKET_ERROR {
                let error = WSAGetLastError()
                if error == WSAEINTR { continue }
                throw remaining > 0 ? Failure.unavailable : Failure.timedOut
            }
            #else
            try wait(for: Int16(POLLOUT))
            let count = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            #endif
            guard count > 0 else { throw Failure.unavailable }
            if offset == 0 { didWrite?() }
            offset += count
        }
    }

    private func receive() throws -> [String: Any] {
        guard let message = try JSONSerialization.jsonObject(with: receiveFrame()) as? [String: Any] else {
            throw Failure.protocolError
        }
        return message
    }

    private func receiveFrame() throws -> Data {
        let header = try read(4)
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= maximumFrame else { throw Failure.protocolError }
        return try read(Int(length))
    }

    private func read(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            #if os(Windows)
            var bytes = [UInt8](repeating: 0, count: min(count - result.count, 64 * 1024))
            let size = bytes.withUnsafeMutableBytes { raw in
                WinSDK.recv(UnixSocket.handleOf(descriptor), raw.baseAddress, Int32(raw.count), 0)
            }
            if size == WinSDK.SOCKET_ERROR {
                let error = WSAGetLastError()
                if error == WSAEINTR { continue }
                throw remaining > 0 ? Failure.unavailable : Failure.timedOut
            }
            guard size > 0 else { throw Failure.unavailable }
            result.append(contentsOf: bytes.prefix(Int(size)))
            #else
            try wait(for: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: min(count - result.count, 64 * 1024))
            let size = recv(descriptor, &bytes, bytes.count, 0)
            if size < 0, errno == EINTR || errno == EAGAIN { continue }
            guard size > 0 else { throw Failure.unavailable }
            result.append(contentsOf: bytes.prefix(size))
            #endif
        }
        return result
    }

    #if !os(Windows)
    private func wait(for events: Int16) throws {
        while true {
            try Task.checkCancellation()
            guard remaining > 0 else { throw Failure.timedOut }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&entry, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0, errno == EINTR { continue }
            if result == 0 { throw Failure.timedOut }
            guard result > 0, entry.revents & events != 0 else { throw Failure.unavailable }
            return
        }
    }
    #endif
}

#if canImport(Darwin)
import Darwin
import Foundation

/// A unix-domain stream socket between the running application and the short-lived processes a client's hooks start. A
/// request is one message, which its sender ends by closing its writing side; only the user can reach the socket.
public enum UnixSocket {
    /// Whether `path` fits a socket address, which holds about a hundred bytes.
    public static func fits(_ path: String) -> Bool { path.utf8.count < 104 }

    /// Connects to the socket at `path`; a write after the other side went away fails instead of raising SIGPIPE. Nil
    /// when there is no socket at `path` or nothing accepts.
    public static func connect(to path: String) -> Int32? {
        var info = stat()
        guard fits(path), stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let size = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: size) { strlcpy($0, path, size) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Closes the socket. The hook's short-lived process calls this before it goes away.
    public static func close(_ descriptor: Int32) {
        Darwin.close(descriptor)
    }

    /// Half-closes the writing side, so the other side sees the request is whole while still being able to answer.
    public static func halfClose(_ descriptor: Int32) {
        shutdown(descriptor, SHUT_WR)
    }

    /// Writes all of `data`; false when the other side went away.
    public static func send(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < buffer.count {
                let written = Darwin.send(descriptor, base + sent, buffer.count - sent, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                sent += written
            }
            return true
        }
    }

    /// Reads until the other side closes the connection, or until more than `limit` bytes arrived.
    public static func readToEnd(_ descriptor: Int32, limit: Int) -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= limit {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            if read < 0 {
                if errno == EINTR { continue }
                break
            }
            if read == 0 { break }
            response.append(contentsOf: buffer[..<read])
        }
        return response
    }
}
#else
import Foundation
import WinSDK

/// The Windows side of the same socket: WinSock speaks AF_UNIX, which does not put a file in the filesystem, so there
/// is no stat check before connecting, and no SIGPIPE to turn off.
public enum UnixSocket {
    public static func fits(_ path: String) -> Bool { path.utf8.count < 104 }

    /// Connects to the socket at `path`; nil when nothing is listening there.
    public static func connect(to path: String) -> Int32? {
        guard WinSock.started, fits(path) else { return nil }
        let handle = WinSDK.socket(afUnix, sockStream, 0)
        guard handle != WinSDK.INVALID_SOCKET else { return nil }
        let connected = withAddress(path) { address, length in
            WinSDK.connect(handle, address, length)
        }
        guard connected == 0 else {
            WinSDK.closesocket(handle)
            return nil
        }
        return Int32(truncatingIfNeeded: handle)
    }

    /// Writes all of `data`; false when the other side went away.
    public static func send(_ descriptor: Int32, _ data: Data) -> Bool {
        let handle = handleOf(descriptor)
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, handle != WinSDK.INVALID_SOCKET else { return false }
            var sent = 0
            while sent < buffer.count {
                let written = WinSDK.send(handle, base + sent, Int32(buffer.count - sent), 0)
                if written < 0 {
                    if WSAGetLastError() == WSAEINTR { continue }
                    return false
                }
                if written == 0 { return false }
                sent += Int(written)
            }
            return true
        }
    }

    /// Bounds both directions of the socket by `seconds`; Windows has no poll here, so the socket times out itself.
    static func timeouts(_ descriptor: Int32, seconds: TimeInterval) -> Bool {
        let handle = handleOf(descriptor)
        guard handle != WinSDK.INVALID_SOCKET else { return false }
        var milliseconds = DWORD(max(1, min(seconds, 86_400) * 1000))
        return withUnsafeMutableBytes(of: &milliseconds) { raw in
            let size = DWORD(raw.count)
            let pointer = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return WinSDK.setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, pointer, Int32(size)) == 0
                && WinSDK.setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, pointer, Int32(size)) == 0
        }
    }

    /// Reads until the other side closes the connection, or until more than `limit` bytes arrived.
    public static func readToEnd(_ descriptor: Int32, limit: Int) -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let handle = handleOf(descriptor)
        while response.count <= limit, handle != WinSDK.INVALID_SOCKET {
            let read = buffer.withUnsafeMutableBytes { raw in
                WinSDK.recv(handle, raw.baseAddress, Int32(raw.count), 0)
            }
            if read < 0 {
                if WSAGetLastError() == WSAEINTR { continue }
                break
            }
            if read == 0 { break }
            response.append(contentsOf: buffer[..<Int(read)])
        }
        return response
    }

    /// Half-closes the writing side, so the other side sees the request is whole while still being able to answer.
    public static func halfClose(_ descriptor: Int32) {
        let handle = handleOf(descriptor)
        if handle != WinSDK.INVALID_SOCKET { WinSDK.shutdown(handle, sdSend) }
    }

    /// Closes a descriptor this type made.
    public static func close(_ descriptor: Int32) {
        let handle = handleOf(descriptor)
        if handle != WinSDK.INVALID_SOCKET {
            WinSDK.shutdown(handle, sdSend)
            WinSDK.closesocket(handle)
        }
    }

    static func handleOf(_ descriptor: Int32) -> SOCKET {
        // The channel's types keep their macOS width, so a descriptor rides in an Int32; sockets this app makes get
        // small handles, and the cast back sign-extends the same bits.
        SOCKET(UInt64(bitPattern: Int64(descriptor)))
    }

    /// A `SOCKADDR_UN` holding `path`, built byte by byte because the address family and layout are all this needs.
    static func withAddress<R>(_ path: String, _ body: (UnsafePointer<WinSDK.sockaddr>, Int32) -> R) -> R {
        var bytes = [UInt8](repeating: 0, count: 2 + 108)
        bytes[0] = UInt8(truncatingIfNeeded: afUnix)
        bytes[1] = UInt8(truncatingIfNeeded: afUnix >> 8)
        let name = Array(path.utf8.prefix(108))
        bytes.replaceSubrange(2..<(2 + name.count), with: name)
        return bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: WinSDK.sockaddr.self, capacity: 1) { address in
                body(address, Int32(buffer.count))
            }
        }
    }
}

/// The few WinSock constants the channel needs, kept under local names: AF_UNIX and SOCK_STREAM share their POSIX
/// values, and SD_SEND is the half-close the hook uses to say its request is whole.
let afUnix: Int32 = 1
let sockStream: Int32 = 1
let sdSend: Int32 = 1
#endif

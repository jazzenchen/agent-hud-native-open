import Foundation

#if canImport(Network)
import Network
import os.log

/// The application's side of a `UnixSocket`: it listens at `path` and hands each request, once its sender stopped
/// writing, to `onRequest` with the connection, which answers it or lets it go. One process serves a path: a lock beside
/// the socket keeps a second copy of the application from replacing it, and a process removes only the socket it made.
@MainActor
public final class UnixSocketListener {
    public let path: String
    /// The largest request read; a longer one closes its connection.
    public let requestLimit: Int
    private let onRequest: @MainActor (Data, UnixConnection) -> Void
    private let log: Logger
    private var listener: NWListener?
    /// The lock that makes this process the one serving the path, and the socket file it made, by device and inode.
    private var lock: Int32 = -1
    private var socket: [Int]?

    /// - category: names the socket in the application's log.
    public init(path: String, requestLimit: Int, category: String, onRequest: @escaping @MainActor (Data, UnixConnection) -> Void) {
        self.path = path
        self.requestLimit = requestLimit
        self.onRequest = onRequest
        log = Logger(subsystem: "app.agenthud", category: category)
    }

    public var isListening: Bool { listener != nil }

    /// Starts listening; false when the path does not fit a socket address, another process serves it or the socket
    /// cannot be made.
    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        let path = path
        guard UnixSocket.fits(path) else {
            log.error("Socket path is too long for a unix socket: \(path, privacy: .public)")
            return false
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Another copy of the app opened beside this one, which shares its data directory, leaves the socket to the one
        // that serves it rather than replacing it; the lock goes with the process that holds it.
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            log.info("Another instance serves \(path, privacy: .public)")
            return false
        }
        unlink(path)
        // The socket must never be readable by anyone else, not even for the moment between bind and chmod.
        let previous = umask(0o077)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else {
            umask(previous)
            close(lock)
            log.error("Could not listen on \(path, privacy: .public)")
            return false
        }
        self.lock = lock
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    umask(previous)
                    chmod(path, 0o700)
                    self?.socket = Self.identity(path)
                case .failed:
                    umask(previous)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.receive(connection, accumulated: Data())
            }
        }
        listener.start(queue: .main)
        return true
    }

    /// Stops listening. Only the socket this process made is removed.
    public func stop() {
        listener?.cancel()
        listener = nil
        if let socket, Self.identity(path) == socket { unlink(path) }
        socket = nil
        if lock >= 0 { close(lock) }
        lock = -1
    }

    private static func identity(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino)]
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                var data = accumulated
                if let content { data.append(content) }
                guard let self, data.count <= self.requestLimit else { return connection.cancel() }
                if isComplete || error != nil {
                    self.onRequest(data, connection)
                } else {
                    self.receive(connection, accumulated: data)
                }
            }
        }
    }
}
#else
import WinSDK

/// The Windows side of the same listener. WinSock speaks AF_UNIX but puts no socket file in the filesystem, so the
/// name dies with the serving process and there is nothing to unlink; the `.lock` file still keeps a second copy of the
/// application from taking the channel over.
@MainActor
public final class UnixSocketListener {
    public let path: String
    public let requestLimit: Int
    private let onRequest: @MainActor (Data, UnixConnection) -> Void
    /// The os_log Logger has no Windows counterpart; the category names the lines this side writes.
    private let log: (String) -> Void
    private var server: ListeningSocket?
    /// The lock that makes this process the one serving the path.
    private var lock: LockedFile?

    public init(path: String, requestLimit: Int, category: String, onRequest: @escaping @MainActor (Data, UnixConnection) -> Void) {
        self.path = path
        self.requestLimit = requestLimit
        self.onRequest = onRequest
        log = { NSLog("[AgentHUD] [%@] %@", category as NSString, $0 as NSString) }
    }

    public var isListening: Bool { server != nil }

    /// Starts listening; false when the path does not fit a socket address, another process serves it or the socket
    /// cannot be made.
    @discardableResult
    public func start() -> Bool {
        guard server == nil else { return true }
        let path = path
        guard WinSock.started, UnixSocket.fits(path) else {
            log("Socket path is too long for a unix socket: \(path)")
            return false
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let lock = LockedFile(path + ".lock") else {
            log("Could not open the channel lock beside \(path)")
            return false
        }
        guard lock.isLocked else {
            log("Another instance serves \(path)")
            return false
        }
        guard let socket = ListeningSocket(path: path) else {
            log("Could not listen on \(path)")
            return false
        }
        self.lock = lock
        self.server = socket
        let limit = requestLimit
        let onRequest = onRequest
        let thread = Thread {
            socket.acceptLoop(limit: limit, onRequest: onRequest)
        }
        thread.stackSize = 256 * 1024
        thread.start()
        return true
    }

    /// Stops listening. The name dies with this process, so only the lock is given up.
    public func stop() {
        server?.close()
        server = nil
        lock = nil
    }
}

/// The listening socket, held apart from the main actor so the accept thread and `stop()` can meet on it.
private final class ListeningSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: SOCKET

    init?(path: String) {
        let handle = WinSDK.socket(afUnix, sockStream, 0)
        guard handle != WinSDK.INVALID_SOCKET else { return nil }
        let bound = UnixSocket.withAddress(path) { address, length in
            WinSDK.bind(handle, address, length)
        }
        guard bound == 0, WinSDK.listen(handle, 8) == 0 else {
            WinSDK.closesocket(handle)
            return nil
        }
        self.handle = handle
    }

    func take() -> SOCKET { lock.withLock { handle } }

    func close() {
        lock.withLock {
            if handle != WinSDK.INVALID_SOCKET {
                WinSDK.shutdown(handle, SD_BOTH)
                WinSDK.closesocket(handle)
                handle = WinSDK.INVALID_SOCKET
            }
        }
    }

    /// Accepts one connection at a time and reads each request whole; the answers are small and a client waits on its
    /// request until the HUD answers, so a queue would change nothing.
    func acceptLoop(limit: Int, onRequest: @escaping @MainActor (Data, UnixConnection) -> Void) {
        while true {
            let accepted = WinSDK.accept(take(), nil, nil)
            guard accepted != WinSDK.INVALID_SOCKET else { break }
            let connection = UnixConnection(handle: accepted)
            connection.makeReady()
            let (data, error) = connection.readToEnd(limit: limit)
            if error == nil, data.count <= limit {
                DispatchQueue.main.async { MainActor.assumeIsolated { onRequest(data, connection) } }
            } else {
                connection.cancel()
            }
        }
    }
}
#endif

/// A file held under an exclusive byte-range lock, in place of flock: the system lets go of the range when the
/// process ends, also when it crashes, so a copy that is gone never keeps another from starting.
final class LockedFile: @unchecked Sendable {
    private let handle: HANDLE?
    /// False when the file exists but another process holds its first byte.
    let isLocked: Bool

    init?(_ path: String) {
        var wide = Array(path.utf16)
        wide.append(0)
        let handle = wide.withUnsafeBufferPointer { buffer in
            CreateFileW(buffer.baseAddress, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        var overlapped = OVERLAPPED()
        let locked = LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK) | DWORD(LOCKFILE_FAIL_IMMEDIATELY), 0, 1, 0, &overlapped)
        self.handle = handle
        self.isLocked = locked
    }

    /// Replaces the file's content with `data`; false when the write did not go whole.
    func write(_ data: Data) -> Bool {
        guard let handle, isLocked else { return false }
        SetFilePointer(handle, 0, nil, DWORD(FILE_BEGIN))
        guard SetEndOfFile(handle) else { return false }
        var written: DWORD = 0
        let ok = data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { WriteFile(handle, $0, DWORD(buffer.count), &written, nil) } ?? true
        }
        return ok && written == DWORD(data.count)
    }

    deinit {
        if let handle { CloseHandle(handle) }
    }
}


import Foundation

#if canImport(Network)
import Network

/// A connection on the request channel. Where Network.framework exists this is NWConnection itself, so every
/// signature that takes one keeps its exact shape; elsewhere it is the stand-in below.
public typealias UnixConnection = NWConnection
#else
import WinSDK

/// The Windows stand-in for the slice of NWConnection the channel uses: a connected unix-domain socket that the
/// application answers and then closes. The listener owns reading; this type carries the handle, the state callback
/// and the answer.
public final class UnixConnection: @unchecked Sendable {
    public enum State: Equatable {
        case setup, preparing, ready, cancelled, failed(Int32)
    }

    /// Mirrors the one completion the channel asks for; the code is a WinSock error, nil on success.
    public enum Completion {
        case contentProcessed(@Sendable (Int32?) -> Void)
    }

    private let lock = NSLock()
    private var handle: SOCKET?
    /// Set by the receiver at any time; fired from then on when the connection ends, like NWConnection's handler,
    /// which a receiver that arrives late also only sees from the next change on.
    public var stateUpdateHandler: (@Sendable (State) -> Void)?

    init(handle: SOCKET) {
        self.handle = handle
    }

    deinit {
        close()
    }

    var isOpen: Bool { lock.withLock { handle != WinSDK.INVALID_SOCKET } }

    func makeReady() { fire(.ready) }

    /// Closes the socket; a handler set before or after sees one `.cancelled`.
    public func cancel() {
        let fired = close()
        if fired { fire(.cancelled) }
    }

    /// Sends all of `content`, then reports; false's code is a WinSock error. The channel's answers are small, so a
    /// blocking send on a side queue cannot hold up anything that matters.
    public func send(content: Data, completion: Completion) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return return0(completion) }
            let error = content.withUnsafeBytes { buffer -> Int32? in
                guard let base = buffer.baseAddress else { return nil }
                var sent = 0
                self.lock.lock()
                let handle = self.handle
                self.lock.unlock()
                guard handle != WinSDK.INVALID_SOCKET else { return WSAENOTSOCK }
                while sent < buffer.count {
                    // UnsafeRawPointer arithmetic in byte units; SOCKET's integer width is fine for a cast back.
                    let written = WinSDK.send(handle, base + sent, Int32(buffer.count - sent), 0)
                    if written == WinSDK.SOCKET_ERROR { return WSAGetLastError() }
                    if written == 0 { return WSAECONNABORTED }
                    sent += written
                }
                return nil
            }
            if case .contentProcessed(let report) = completion { report(error) }
            if error != nil { self.cancel() }
        }
    }

    /// Reads from the socket until the peer stops writing or `limit` is passed; the listener runs this on its own
    /// thread. Nil's code is a WinSock error.
    func readToEnd(limit: Int) -> Result<Data, Int32> {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= limit {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                self.lock.lock()
                let handle = self.handle
                self.lock.unlock()
                guard handle != WinSDK.INVALID_SOCKET else { return -1 }
                return WinSDK.recv(handle, raw.baseAddress, Int32(raw.count), 0)
            }
            if read == WinSDK.SOCKET_ERROR {
                let error = WSAGetLastError()
                if error == WSAEINTR { continue }
                return .failure(error)
            }
            if read == 0 { break }
            response.append(contentsOf: buffer[..<read])
        }
        return .success(response)
    }

    /// Closes the handle once; true when this call was the one that ended the connection.
    @discardableResult
    private func close() -> Bool {
        lock.lock()
        let handle = handle
        handle = WinSDK.INVALID_SOCKET
        lock.unlock()
        guard handle != WinSDK.INVALID_SOCKET else { return false }
        WinSDK.shutdown(handle, SD_SEND)
        WinSDK.closesocket(handle)
        return true
    }

    private func fire(_ state: State) {
        lock.lock()
        let handler = stateUpdateHandler
        lock.unlock()
        handler?(state)
    }
}

private func return0(_ completion: UnixConnection.Completion) {
    if case .contentProcessed(let report) = completion { report(nil) }
}

/// WinSock housekeeping for the channel: the library must be started once per process before any socket call.
enum WinSock {
    static let started: Bool = {
        var data = WinSDK.WSADATA()
        return WinSDK.WSAStartup(0x0202, &data) == 0
    }()
}
#endif

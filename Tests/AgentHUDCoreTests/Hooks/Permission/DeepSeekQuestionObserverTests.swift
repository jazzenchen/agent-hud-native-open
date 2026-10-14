#if !os(Windows)
// Hooks/Permission/DeepSeekQuestionObserverTests.swift tests macOS-side sockets and home layouts.
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AgentHUDCore

@MainActor
final class DeepSeekQuestionObserverTests: XCTestCase {
    private let port = 4599

    func testDiscoveryKeepsWebHostBoundariesQuotedPortsAndDefaultsAmongUnrelatedProcesses() async {
        let unrelated = (100...2_099).map {
            "\($0) /usr/local/bin/node /opt/workers/worker-\($0).js --argument=synthetic"
        }.joined(separator: "\n")
        let fixture = """
        1 /usr/local/bin/dsh --profile web --port 4599
        2 node /opt/测试/bin.js\u{2003}--profile=web --port='5600'
        3 dsh --profile web --port="65535"
        4 /usr/local/bin/dsh --profile web --port 0
        5 /usr/local/bin/dsh --profile=web --port 65536
        6 /usr/local/bin/dsh --profile headless --port 9999
        7 /usr/local/bin/dsh-helper --profile web --port 9998
        8 node /opt/tools/bin.jsx --profile=web --port 9997
        9 /usr/local/bin/dsh/bin/worker --profile web --port 9996
        10 /usr/local/bin/DSH --PROFILE=WEB --port 6000
        11 /Applications/Unrelated.app/worker --profile web --port 9995
        12 /usr/local/bin/dsh --profile=web --x--port=9994 --portExtra=9993
        """
        let output = unrelated + "\n" + fixture
        let ports = await DeepSeekQuestionObserver.discoverPorts(inspect: { _, _ in output })
        XCTAssertEqual(ports, [DeepSeekQuestionObserver.defaultPort, 4599, 5600, 6000, 65535])
        XCTAssertTrue(DeepSeekQuestionObserver.isHarness("/usr/local/bin/dsh --profile=web-preview"),
                      "the existing profile prefix match remains unchanged")
        XCTAssertFalse(DeepSeekQuestionObserver.isHarness("/usr/local/bin/dsh --profile  web"),
                       "discovery keeps the existing literal web-profile syntax")
    }

    private func frame(_ id: String) -> ProviderJSON {
        .object([
            "type": .string("server-request"), "method": .string("question/requested"), "rpcId": .string(id),
            "payload": .object([
                "sessionId": .string("session-1"),
                "questions": .array([.object([
                    "id": .string("choice"), "question": .string("Continue?"), "multiSelect": .bool(false),
                    "options": .array([.object(["label": .string("Yes")]), .object(["label": .string("No")])]),
                ])]),
            ]),
        ])
    }

    private func resolution(_ id: String, method: String = "question/resolved") -> ProviderJSON {
        .object(["method": .string(method), "payload": .object(["questionRpcId": .string(id)])])
    }

    private func observer(queue: PermissionRequests, transport: ObserverTransport, streams: ObserverStreams) -> DeepSeekQuestionObserver {
        var client = DeepSeekQuestions()
        client.http.send = { request in try await transport.send(request) }
        let observer = DeepSeekQuestionObserver(requests: queue, client: client)
        observer.discover = { [4599] }
        observer.connect = { port, onFrame, shouldStop in
            await streams.connect(port: port, onFrame: onFrame, shouldStop: shouldStop)
        }
        return observer
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "observer did not reach the expected state")
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testFailedAnswerReturnsWithoutAnotherQuestionFrameAndCanBeRetried() async throws {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        transport.failures = 1
        let observer = observer(queue: queue, transport: transport, streams: streams)
        defer { observer.stop(); streams.finishAll() }
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 1 }
        streams.connections[0].onFrame(frame("question-1"))
        try await waitUntil { queue.pending.count == 1 }
        let id = try XCTUnwrap(queue.pending.first?.id)
        queue.resolve(id, .answer(["choice": .init(selected: ["Yes"])]))
        try await waitUntil { transport.answers == 1 }
        try await waitUntil { queue.request(id) != nil }
        XCTAssertEqual(streams.connections.count, 1, "retry must not depend on reconnecting or a replayed frame")
        queue.resolve(id, .answer(["choice": .init(selected: ["Yes"])]))
        try await waitUntil { transport.answers == 2 }
        try await waitUntil { queue.pending.isEmpty }
        streams.connections[0].onFrame(frame("another-question"))
        try await waitUntil { queue.pending.count == 1 }
        XCTAssertNil(queue.request(id), "a confirmed receipt removes the original question from the snapshot")
    }

    func testResolutionBelongsToItsPortAndWinsLateQuestionFrames() {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        let observer = observer(queue: queue, transport: transport, streams: streams)
        defer { observer.stop() }
        observer.handle(frame("same-rpc"), port: port)
        observer.handle(frame("same-rpc"), port: port + 1)
        XCTAssertEqual(queue.pending.count, 2)
        observer.handle(resolution("same-rpc", method: "unrelated/event"), port: port)
        XCTAssertEqual(queue.pending.count, 2, "a payload field alone is not a question resolution")
        observer.handle(resolution("same-rpc"), port: port)
        XCTAssertNil(queue.request(DeepSeekQuestions.requestID(port: port, rpcID: "same-rpc")))
        XCTAssertNotNil(queue.request(DeepSeekQuestions.requestID(port: port + 1, rpcID: "same-rpc")))
        observer.handle(frame("same-rpc"), port: port)
        observer.handle(frame("same-rpc"), port: port + 1)
        XCTAssertEqual(queue.pending.count, 1, "resolution memory belongs only to the host that resolved it")
        observer.handle(resolution("already-ended"), port: port)
        observer.handle(frame("already-ended"), port: port)
        XCTAssertEqual(queue.pending.count, 1, "a resolution received before its question also wins")
    }

    func testAcceptedAndNotPendingReceiptsWinLateQuestionFrames() async throws {
        let receipts: [ProviderJSON] = [
            .object(["accepted": .bool(true)]),
            .object(["accepted": .bool(false), "reason": .string("not-pending")]),
        ]
        for receipt in receipts {
            let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
            transport.answerReceipt = receipt
            let observer = observer(queue: queue, transport: transport, streams: streams)
            defer { observer.stop() }
            observer.handle(frame("answered"), port: port)
            let id = try XCTUnwrap(queue.pending.first?.id)
            queue.resolve(id, .answer(["choice": .init(selected: ["Yes"])]))
            try await waitUntil { transport.answers == 1 }
            await settle()
            observer.handle(frame("answered"), port: port)
            XCTAssertTrue(queue.pending.isEmpty, "a terminal receipt suppresses a delayed question frame")
            observer.handle(frame("answered"), port: port + 1)
            XCTAssertEqual(queue.pending.first?.id, DeepSeekQuestions.requestID(port: port + 1, rpcID: "answered"))
        }
    }

    func testUnknownRejectedReceiptCanBeRetried() async throws {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        transport.answerReceipt = .object(["accepted": .bool(false), "reason": .string("invalid-answer")])
        let observer = observer(queue: queue, transport: transport, streams: streams)
        defer { observer.stop(); streams.finishAll() }
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 1 }
        streams.connections[0].onFrame(frame("retry-rejection"))
        try await waitUntil { queue.pending.count == 1 }
        let id = try XCTUnwrap(queue.pending.first?.id)
        queue.resolve(id, .answer(["choice": .init(selected: ["Yes"])]))
        try await waitUntil { transport.answers == 1 }
        try await waitUntil { queue.request(id) != nil }
        transport.answerReceipt = .object(["accepted": .bool(true)])
        queue.resolve(id, .answer(["choice": .init(selected: ["Yes"])]))
        try await waitUntil { transport.answers == 2 }
        await settle()
        streams.connections[0].onFrame(frame("retry-rejection"))
        await settle()
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testLeavingQuestionStaysHiddenAcrossConnectionLossAndReplay() async throws {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        let observer = observer(queue: queue, transport: transport, streams: streams)
        defer { observer.stop(); streams.finishAll() }
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 1 }
        streams.connections[0].onFrame(frame("left-native"))
        try await waitUntil { queue.pending.count == 1 }
        queue.resolve(try XCTUnwrap(queue.pending.first?.id), .leave)
        XCTAssertTrue(queue.pending.isEmpty)
        streams.finish(0)
        try await waitUntil { streams.connections.count == 2 }
        streams.connections[1].onFrame(frame("left-native"))
        await settle()
        XCTAssertTrue(queue.pending.isEmpty, "disconnecting does not prove the host settled a dismissed question")
        XCTAssertEqual(transport.answers, 0)
        streams.connections[1].onFrame(frame("new-question"))
        try await waitUntil { queue.pending.count == 1 }
        XCTAssertEqual(queue.pending.first?.id, DeepSeekQuestions.requestID(port: port, rpcID: "new-question"))
    }

    func testUnansweredQuestionReturnsAfterConnectionLossAndReplay() async throws {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        let observer = observer(queue: queue, transport: transport, streams: streams)
        defer { observer.stop(); streams.finishAll() }
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 1 }
        streams.connections[0].onFrame(frame("still-unanswered"))
        try await waitUntil { queue.pending.count == 1 }
        let id = try XCTUnwrap(queue.pending.first?.id)
        streams.finish(0)
        try await waitUntil { queue.pending.isEmpty }
        try await waitUntil { streams.connections.count == 2 }
        streams.connections[1].onFrame(frame("still-unanswered"))
        try await waitUntil { queue.request(id) != nil }
        XCTAssertEqual(transport.answers, 0, "losing a connection does not answer or dismiss the user's question")
    }

    func testStoppedDiscoveryCannotCreateAConnectionInTheNextObservation() async throws {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        let observer = observer(queue: queue, transport: transport, streams: streams)
        let discovery = ObserverDiscovery()
        observer.discover = { await discovery.read() }
        defer { observer.stop(); discovery.finish([4599]); streams.finishAll() }
        observer.setEnabled(true)
        try await waitUntil { discovery.continuation != nil }
        observer.stop()
        observer.discover = { [4599] }
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 1 }
        discovery.finish([4599])
        await settle()
        XCTAssertEqual(transport.descriptions, 1, "the old discovery must not confirm or open a host after stopping")
        XCTAssertEqual(streams.connections.count, 1)
    }

    func testLateFrameAndOldCleanupCannotReplaceAReopenedPort() async throws {
        let queue = PermissionRequests(), transport = ObserverTransport(), streams = ObserverStreams()
        let observer = observer(queue: queue, transport: transport, streams: streams)
        defer { observer.stop(); streams.finishAll() }
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 1 }
        streams.connections[0].onFrame(frame("old-question"))
        try await waitUntil { queue.pending.count == 1 }
        observer.stop()
        streams.connections[0].onFrame(frame("late-question"))
        await settle()
        XCTAssertTrue(queue.pending.isEmpty, "a callback already queued when stopping cannot publish a card")
        observer.setEnabled(true)
        try await waitUntil { streams.connections.count == 2 }
        streams.connections[1].onFrame(frame("new-question"))
        try await waitUntil { queue.pending.count == 1 }
        streams.finish(0)
        await settle()
        XCTAssertEqual(queue.pending.first?.id, "deepseek:\(port):new-question")
        XCTAssertFalse(streams.connections[1].shouldStop(), "the old connection's cleanup must leave its replacement alive")
        streams.connections[1].onFrame(frame("second-new-question"))
        try await waitUntil { queue.pending.count == 2 }
    }

    func testCancellingIdleWebSocketClosesTheConnectionWithoutAHostFrame() async throws {
        let host = try IdleQuestionHost()
        defer { host.stop() }
        var returned = false
        let stream = Task {
            await DeepSeekQuestionObserver.stream(port: host.port, onFrame: { _ in XCTFail("the idle host sends no frame") }, shouldStop: { false })
            returned = true
        }
        defer { stream.cancel() }
        try await waitUntil { host.connected }
        stream.cancel()
        try await waitUntil({ returned }, timeout: 0.8)
        try await waitUntil({ host.disconnected }, timeout: 0.8)
    }
}

@MainActor
private final class ObserverTransport {
    var failures = 0
    var answers = 0
    var descriptions = 0
    var answerReceipt: ProviderJSON = .object(["accepted": .bool(true)])

    func send(_ request: URLRequest) throws -> Data {
        let value: ProviderJSON
        if request.url?.path == "/api/host.describe" {
            descriptions += 1
            value = .object(["version": .string("1"), "provider": .string("deepseek"), "model": .string("test")])
        } else {
            answers += 1
            if failures > 0 { failures -= 1; throw ProviderHTTPError(status: 503) }
            value = answerReceipt
        }
        return try JSONEncoder().encode(ProviderJSON.object([
            "type": .string("server-response"), "rpcId": .string("reply"),
            "result": .object(["ok": .bool(true), "value": value]),
        ]))
    }
}

@MainActor
private final class ObserverDiscovery {
    var continuation: CheckedContinuation<[Int], Never>?
    func read() async -> [Int] { await withCheckedContinuation { continuation = $0 } }
    func finish(_ ports: [Int]) { continuation?.resume(returning: ports); continuation = nil }
}

@MainActor
private final class ObserverStreams {
    struct Connection {
        let port: Int
        let onFrame: @Sendable (ProviderJSON) -> Void
        let shouldStop: @MainActor @Sendable () -> Bool
        var continuation: CheckedContinuation<Void, Never>?
    }
    var connections: [Connection] = []
    func connect(port: Int, onFrame: @escaping @Sendable (ProviderJSON) -> Void,
                 shouldStop: @escaping @MainActor @Sendable () -> Bool) async {
        await withCheckedContinuation { connections.append(Connection(port: port, onFrame: onFrame, shouldStop: shouldStop, continuation: $0)) }
    }
    func finish(_ index: Int) {
        connections[index].continuation?.resume()
        connections[index].continuation = nil
    }
    func finishAll() { for index in connections.indices { finish(index) } }
}

/// The handshake completes, then the host stays silent until the client closes its socket.
private final class IdleQuestionHost: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32?
    private var stopped = false
    private var opened = false
    private var ended = false
    var connected: Bool { lock.withLock { opened } }
    var disconnected: Bool { lock.withLock { ended } }

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw Failure.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard bound == 0, named == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor); throw Failure.socket
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global().async { self.serve() }
    }

    func stop() {
        let state = lock.withLock { () -> (Bool, Int32?) in
            guard !stopped else { return (false, nil) }
            stopped = true
            return (true, client)
        }
        guard state.0 else { return }
        if let client = state.1 { shutdown(client, SHUT_RDWR) }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func serve() {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 2000) > 0 else { return }
        let socket = Darwin.accept(listener, nil, nil)
        guard socket >= 0 else { return }
        lock.withLock { client = socket }
        defer { lock.withLock { client = nil; ended = true }; Darwin.close(socket) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0), on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            var byte: UInt8 = 0
            guard recv(socket, &byte, 1, 0) == 1 else { return }
            header.append(byte)
        }
        guard let request = String(data: header, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }),
              let key = line.split(separator: ":", maxSplits: 1).last else { return }
        let challenge = key.trimmingCharacters(in: .whitespaces) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data(challenge.utf8))).base64EncodedString()
        let response = Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                             + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8)
        let sent = response.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
        guard sent == response.count else { return }
        lock.withLock { opened = true }
        var bytes = [UInt8](repeating: 0, count: 256)
        while recv(socket, &bytes, bytes.count, 0) > 0 { }
    }

    private enum Failure: Error { case socket }
}
#endif

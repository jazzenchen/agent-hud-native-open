import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Follows the questions DeepSeek Harness's web hosts are already asking, over the event stream each one serves on
/// loopback. It installs no hook and answers nothing on its own; the host stays the authority for every question's
/// lifetime — a question answered in Harness arrives as a `question/resolved` frame, and a host that stops talking
/// takes its questions with it.
@MainActor
public final class DeepSeekQuestionObserver {
    private let requests: PermissionRequests
    private var client: DeepSeekQuestions
    /// How long a process keeps its port after it was last confirmed a Harness web host.
    private let endpointLifetime: TimeInterval = 60
    private var endpoints: [Int: Date] = [:]
    /// A connection's identity lets its delayed teardown leave a replacement on the same port alone.
    private struct Stream {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var streams: [Int: Stream] = [:]
    /// Questions now waiting, by request id, so a resolution from any channel withdraws exactly that card.
    private var pending: [String: DeepSeekQuestions.Pending] = [:]
    /// Terminal receipts and resolutions, keyed by host and RPC, so a late question frame cannot reopen a card
    /// or settle a different host's question.
    private var resolved: [String: Date] = [:]
    /// How long a resolution is remembered, and the frames it can still outrun.
    private let resolutionMemory: TimeInterval = 120
    private var observation: Stream?

    /// A host that started since the last search is found this much later. One that quit ends its own stream.
    nonisolated static let discoveryInterval: TimeInterval = 10
    /// The ports the last search found. Finding them lists every process, so the refreshes that follow each other
    /// share one search.
    nonisolated private static let remembered = Remembered(lifetime: discoveryInterval) { await discoverPorts() }

    /// What discovery runs; the tests replace these instead of starting processes.
    var discover: @Sendable () async -> [Int] = { (try? await DeepSeekQuestionObserver.remembered.value()) ?? [] }
    var clock: @Sendable () -> Date = { Date() }
    /// Opens the event stream for a port. The closure returns only when the connection ends; it hands each frame's
    /// JSON to `onFrame` and gives up when asked to stop.
    var connect: @MainActor @Sendable (Int, @escaping @Sendable (ProviderJSON) -> Void, @escaping @MainActor @Sendable () -> Bool) async -> Void
        = { port, onFrame, shouldStop in await DeepSeekQuestionObserver.stream(port: port, onFrame: onFrame, shouldStop: shouldStop) }

    public init() {
        requests = .shared
        client = DeepSeekQuestions()
    }

    init(requests: PermissionRequests, client: DeepSeekQuestions) {
        self.requests = requests
        self.client = client
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        guard observation == nil else { return }
        let id = UUID()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(observation: id)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        observation = Stream(id: id, task: task)
    }

    public func stop() {
        observation?.task.cancel()
        observation = nil
        for stream in streams.values { stream.task.cancel() }
        streams.removeAll()
        endpoints.removeAll()
        pending.removeAll()
        resolved.removeAll()
        requests.stopNativeRequests(source: .deepseek)
    }

    /// Rediscovers hosts, forgets the ones gone quiet, and opens streams for the ones newly confirmed. Every
    /// confirmation asks the port itself, so another process that takes a remembered port is not answered.
    private func refresh(observation id: UUID) async {
        let found = await discover()
        guard observation?.id == id, !Task.isCancelled else { return }
        let now = clock()
        var confirmed: Set<Int> = []
        for port in found where endpoints[port] == nil || now.timeIntervalSince(endpoints[port]!) > endpointLifetime {
            let described = (try? await client.describe(port: port)) == true
            guard observation?.id == id, !Task.isCancelled else { return }
            guard described else { endpoints[port] = nil; continue }
            endpoints[port] = now
        }
        for port in found {
            guard endpoints[port] != nil else { continue }
            confirmed.insert(port)
            if streams[port] == nil {
                let streamID = UUID()
                let onFrame: @Sendable (ProviderJSON) -> Void = { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.observation?.id == id,
                              self.streams[port]?.id == streamID else { return }
                        self.handle(frame, port: port)
                    }
                }
                let shouldStop: @MainActor @Sendable () -> Bool = { [weak self] in
                    guard let self, !Task.isCancelled else { return true }
                    return self.observation?.id != id || self.streams[port]?.id != streamID
                }
                let stream = Task { [weak self, connect] in
                    await connect(port, onFrame, shouldStop)
                    self?.closed(port, stream: streamID)
                }
                streams[port] = Stream(id: streamID, task: stream)
            }
        }
        for (port, stream) in streams where !confirmed.contains(port) {
            streams[port] = nil
            endpoints[port] = nil
            stream.task.cancel()
            removePending(port: port)
        }
        // A failed answer remains pending at the host. The queue clears its dismissal on failure, and this
        // reconciliation makes that question answerable again even when the event stream sends no new frame.
        publish()
    }

    /// One frame off a host's stream: a question opens its card, a resolution takes it down.
    func handle(_ frame: ProviderJSON, port: Int) {
        let now = clock()
        resolved = resolved.filter { now.timeIntervalSince($0.value) < resolutionMemory }
        if frame["method"].stringValue == "question/resolved",
           let rpcID = frame["payload"]["questionRpcId"].stringValue, !rpcID.isEmpty {
            withdraw(DeepSeekQuestions.requestID(port: port, rpcID: rpcID))
            return
        }
        guard let read = DeepSeekQuestions.Frame.read(frame) else { return }
        // A resolution already seen for this question wins: the frame is late, not new.
        let id = DeepSeekQuestions.requestID(port: port, rpcID: read.rpcID)
        if let seen = resolved[id], now.timeIntervalSince(seen) < resolutionMemory { return }
        let waiting = DeepSeekQuestions.pending(read, port: port, now: now)
        pending[waiting.id] = waiting
        publish()
    }

    private func closed(_ port: Int, stream id: UUID) {
        guard streams[port]?.id == id else { return }
        streams[port] = nil
        endpoints[port] = nil
        removePending(port: port)
        publish()
    }

    private func removePending(port: Int) {
        for waiting in pending.values where waiting.port == port { pending.removeValue(forKey: waiting.id) }
    }

    private func withdraw(_ id: String) {
        resolved[id] = clock()
        pending.removeValue(forKey: id)
        requests.settleNativeRequest(id, source: .deepseek)
        publish()
    }

    /// Republishes what is waiting. An answer comes from one place at a time: the queue holds the answer closure,
    /// which tells this host the decision and leaves a question answered elsewhere to its own frame.
    private func publish() {
        let waiting = pending.values.sorted { ($0.request.at, $0.id) < ($1.request.at, $1.id) }
        requests.updateNativeRequests(waiting.map(\.request), source: .deepseek, preservesDismissals: true) { [weak self] request, decision in
            guard let self, let waiting = self.pending[request.id] else { return }
            guard decision != .leave else { return }
            let body = try DeepSeekQuestions.answer(decision, for: waiting)
            let reply = try await self.client.send(body, port: waiting.port)
            try Task.checkCancellation()
            // Only the host can establish that the question was answered or has already stopped waiting.
            _ = try DeepSeekQuestions.receipt(reply)
            self.withdraw(request.id)
        }
    }

    nonisolated static let defaultPort = 3080

    /// The Harness web hosts running right now: processes whose command names the Harness entry and a web profile.
    /// A port named on the command line is what the host serves; without one, the default.
    nonisolated static func discoverPorts(
        inspect: @Sendable (String, [String]) async throws -> String = ProviderCommand.run
    ) async -> [Int] {
        guard let output = try? await inspect("/bin/ps", ["-U", String(getuid()), "-o", "pid=,command="]) else { return [] }
        var ports: Set<Int> = []
        // Only a web profile's host asks questions; the lines of every other process are never taken apart.
        for line in ProcessLines.mentioning(["--profile web", "--profile=web"], in: output) {
            let command = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            guard isHarness(command) else { continue }
            if let port = portFlag(command: command).flatMap(Int.init), (1...65535).contains(port) {
                ports.insert(port)
            } else {
                ports.insert(defaultPort)
            }
        }
        return ports.sorted()
    }

    /// The Harness entry — `dsh` or the package's `bin.js` — running its web profile, the only profile whose
    /// host asks questions. Which home a process serves its files under its environment keeps to itself; the
    /// describe call is what confirms the port.
    nonisolated private static let harnessPattern = try! NSRegularExpression(pattern: #"(?:^|/)(?:dsh|bin\.js)(?:\s|$)"#)
    nonisolated private static let portPattern = try! NSRegularExpression(pattern: #"(?:^|\s)--port(?:=|\s+)(?:"([^"]+)"|'([^']+)'|([^\s]+))"#)

    nonisolated static func isHarness(_ command: String) -> Bool {
        let lower = command.lowercased()
        guard lower.contains("--profile web") || lower.contains("--profile=web") else { return false }
        return harnessPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }

    nonisolated private static func portFlag(command: String) -> String? {
        guard command.contains("--port"),
              let match = portPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: command) { return String(command[range]) }
        }
        return nil
    }

    /// The event stream: one downlink WebSocket per host, whose server pushes questions and resolutions without
    /// being polled. The connection ends when the socket does; the caller reconnects through `connect` again.
    static func stream(port: Int, onFrame: @escaping @Sendable (ProviderJSON) -> Void, shouldStop: @escaping @MainActor @Sendable () -> Bool) async {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api/events.mux") else { return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 5))
        socket.resume()
        await withTaskCancellationHandler {
            while !Task.isCancelled, !shouldStop() {
                do {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, !shouldStop() else { return }
                    if case .data(let data) = message, let frame = try? ProviderJSON.read(data) { onFrame(frame) }
                    if case .string(let text) = message, let frame = try? ProviderJSON.read(Data(text.utf8)) { onFrame(frame) }
                } catch {
                    return
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
    }
}

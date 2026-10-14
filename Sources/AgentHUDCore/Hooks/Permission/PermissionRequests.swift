import AgentHUDSupport
import Foundation

/// The requests a user is being asked about right now, and the channel their clients are waiting on.
///
/// A hook request lives as long as its connection; a native request lives as long as the client's waiting step.
/// Answering resumes that client, and answering in the client removes the card. Nothing is stored on disk.
@MainActor
@Observable
public final class PermissionRequests {
    public static let shared = PermissionRequests()

    /// In arrival order. Two sessions can be waiting at once, and parallel tool calls in one session can be too.
    public private(set) var pending: [PermissionRequest] = []

    private enum Waiting {
        case hook(UnixConnection)
        case native(@MainActor (PermissionDecision) async throws -> Void)
    }
    @ObservationIgnored private var waiting: [String: Waiting] = [:]
    /// A request left to the client's own dialog stays hidden until the client settles it.
    @ObservationIgnored private var dismissedNative: [String: PermissionHooks.Source] = [:]
    @ObservationIgnored private var nativeAnswers: [String: (source: PermissionHooks.Source, task: Task<Void, Never>)] = [:]
    /// The demo requests a script has brought in and not yet taken back, answered on the HUD or not.
    @ObservationIgnored private var demoShown: Set<String> = []
    /// How long a request waits for an answer before it goes back to the client's own prompt. The client's hook
    /// timeout stays far longer, as the ceiling for a HUD that stopped answering altogether; letting go here instead
    /// means a new value applies at once, to requests already waiting too, without rewriting any client's settings.
    @ObservationIgnored public var holdTime: TimeInterval = 600 {
        didSet { for request in pending { scheduleExpiry(request) } }
    }
    @ObservationIgnored private var channel: UnixSocketListener?
    @ObservationIgnored private var counter: UInt64 = 0

    init() {}

    // MARK: Channel

    /// Where the hook and the app meet. The name is short on purpose: a unix socket path has about a hundred bytes.
    public nonisolated static var socketPath: String { AppSupport.directory.appendingPathComponent("permission.sock").path }

    /// Opens the channel, unless another copy of the app opened beside this one already serves it.
    public func start(path: String = PermissionRequests.socketPath) {
        guard channel == nil else { return }
        let channel = UnixSocketListener(path: path, requestLimit: 1024 * 1024, category: "permission") { [weak self] data, connection in
            self?.register(data, connection: connection)
        }
        if channel.start() { self.channel = channel }
    }

    /// Lets every waiting client go back to asking in its own terminal, then closes the channel. Only the socket this
    /// process made is removed.
    public func stop() {
        for answer in nativeAnswers.values { answer.task.cancel() }
        nativeAnswers.removeAll()
        for id in pending.map(\.id) { withdraw(id) }
        dismissedNative.removeAll()
        channel?.stop()
        channel = nil
    }

    // MARK: Receiving

    private func register(_ data: Data, connection: UnixConnection) {
        // The hook names its own client; a payload that arrives on this socket without one cannot be placed.
        guard let source = source(of: data), source.usesHook else { return connection.cancel() }
        counter &+= 1
        let id = "\(source.rawValue)-\(counter)"
        guard let request = try? PermissionRequest.parse(data, source: source, id: id, now: Date()) else {
            return connection.cancel()
        }
        waiting[id] = .hook(connection)
        pending.append(request)
        scheduleExpiry(request)
        // A client that gives up closes the socket. That is the only signal that a request stopped being a question,
        // and it arrives whether the user answered in the terminal, the hook timed out or the client was killed.
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed:
                    // An answered request is already gone from the table, so its own teardown withdraws nothing.
                    self?.withdraw(id)
                default:
                    break
                }
            }
        }
    }

    /// The hook adds its own name to the payload it forwards; the client's own fields are left untouched.
    private func source(of data: Data) -> PermissionHooks.Source? {
        guard let payload = try? ProviderJSON.read(data),
              let name = payload[PermissionHookClient.sourceKey].stringValue else { return nil }
        return PermissionHooks.Source(rawValue: name)
    }

    /// Reconciles a native client's actual waiting requests. Executing tools never enter this queue, and a request
    /// answered in that client disappears at the next reading without sending it another answer.
    func updateNativeRequests(_ requests: [PermissionRequest], source: PermissionHooks.Source,
                              preservesDismissals: Bool = false,
                              answer: @escaping @MainActor (PermissionRequest, PermissionDecision) async throws -> Void) {
        let requests = requests.filter { $0.source == source }
        let ids = Set(requests.map(\.id))
        for request in pending.filter({ $0.source == source }) where !ids.contains(request.id) {
            if preservesDismissals { hideNativeRequest(request.id) }
            else if case .native = waiting[request.id] { withdraw(request.id) }
        }
        if !preservesDismissals {
            dismissedNative = dismissedNative.filter { $0.value != source || ids.contains($0.key) }
        }
        for request in requests where dismissedNative[request.id] == nil {
            waiting[request.id] = .native { decision in try await answer(request, decision) }
            guard !pending.contains(where: { $0.id == request.id }) else { continue }
            pending.append(request)
            scheduleExpiry(request)
        }
    }

    /// An event stream settles prompts explicitly; a disconnect alone cannot clear a user's dismissal.
    func settleNativeRequest(_ id: String, source: PermissionHooks.Source) {
        if request(id)?.source == source, case .native = waiting[id] { withdraw(id) }
        if dismissedNative[id] == source { dismissedNative.removeValue(forKey: id) }
    }

    /// A failed reading hides cards but cannot prove that a prompt the user left has ended.
    func removeNativeRequests(source: PermissionHooks.Source) {
        for request in pending.filter({ $0.source == source }) {
            hideNativeRequest(request.id)
        }
    }

    private func hideNativeRequest(_ id: String) {
        guard case .native = waiting[id] else { return }
        waiting.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
    }

    func stopNativeRequests(source: PermissionHooks.Source) {
        removeNativeRequests(source: source)
        for (id, answer) in nativeAnswers where answer.source == source {
            answer.task.cancel()
            nativeAnswers.removeValue(forKey: id)
        }
        dismissedNative = dismissedNative.filter { $0.value != source }
    }

    // MARK: Answering

    /// Hands the client the user's decision and lets it go.
    public func resolve(_ id: String, _ decision: PermissionDecision) {
        guard decision != .leave else { return withdraw(id) }
        guard let request = request(id) else { return }
        pending.removeAll { $0.id == id }
        // The demo's requests have no client waiting behind them: taking the card away is the whole answer.
        guard let client = waiting.removeValue(forKey: id) else { return }
        switch client {
        case .hook(let connection):
            connection.send(content: decision.response(for: request), completion: .contentProcessed { _ in
                connection.cancel()
            })
        case .native(let answer):
            dismissedNative[id] = request.source
            let task = Task { [weak self] in
                defer {
                    if !Task.isCancelled { self?.nativeAnswers.removeValue(forKey: id) }
                }
                do {
                    try Task.checkCancellation()
                    try await answer(decision)
                }
                catch {
                    guard !Task.isCancelled else { return }
                    self?.dismissedNative.removeValue(forKey: id)
                    NSLog("[AgentHUD] Native approval answer failed for %@", request.vendor)
                }
            }
            nativeAnswers[id] = (request.source, task)
        }
    }

    private func scheduleExpiry(_ request: PermissionRequest) {
        let delay = max(0, request.at.addingTimeInterval(holdTime).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, id = request.id] in
            MainActor.assumeIsolated { self?.expire(id) }
        }
    }

    /// A request nobody answered in time goes back unanswered, so the client asks in its own prompt. A timer set
    /// under an earlier, longer wait finds the request still inside the current one and leaves it.
    private func expire(_ id: String) {
        guard let request = request(id), waiting[id] != nil, Date() >= request.at.addingTimeInterval(holdTime) else { return }
        withdraw(id)
    }

    /// Takes a request off the HUD without answering it: the client goes on as if the HUD had never been there.
    public func withdraw(_ id: String) {
        let source = request(id)?.source
        pending.removeAll { $0.id == id }
        switch waiting.removeValue(forKey: id) {
        case .hook(let connection): connection.cancel()
        case .native:
            if let source { dismissedNative[id] = source }
        case nil: break
        }
    }

    public func request(_ id: String) -> PermissionRequest? { pending.first { $0.id == id } }

    /// Fills the queue for the demo. Nothing is listening on the channel in that mode, and nothing is answered
    /// on any client's behalf.
    public func seedDemo(now: Date = Date()) {
        pending = DemoData.permissionRequests(now: now)
    }

    /// Shows exactly these of the demo's requests, for a script that decides when each arrives and leaves. One the
    /// user answered on the HUD stays answered: it is not brought back while the script still lists it.
    public func showDemo(_ waiting: [(id: String, at: Date)]) {
        let listed = Set(waiting.map(\.id))
        pending.removeAll { !listed.contains($0.id) }
        demoShown.formIntersection(listed)
        for request in waiting where demoShown.insert(request.id).inserted {
            if let made = DemoData.permissionRequest(request.id, at: request.at) { pending.append(made) }
        }
    }
}

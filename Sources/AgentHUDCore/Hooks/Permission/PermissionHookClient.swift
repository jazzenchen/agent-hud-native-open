import AgentHUDSupport
import Foundation

#if canImport(Darwin)
import Darwin
#else
import ucrt
#endif

/// The `--permission-hook` side: a short-lived process the client starts and then waits on.
///
/// It hands the client's request to the running HUD and prints back whatever the user decided. Every failure — no HUD,
/// a wedged HUD, a payload it cannot read — prints nothing, which leaves the client's own permission flow exactly as
/// it would be with no hook installed. The wait itself is not bounded here: the client already set the limit it is
/// willing to wait, and the HUD learns the request is over when this process goes away — which it also does on its
/// own once the session record shows the user answered in the client instead.
public enum PermissionHookClient {
    /// The field the hook adds so the HUD knows which client is asking; the client's own fields are left untouched.
    public static let sourceKey = "_agentHUDSource"

    public static func run(source: PermissionHooks.Source) {
        // A HUD that stops reading must never raise a signal in the client's hook process; Windows has no SIGPIPE.
        #if canImport(Darwin)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGALRM) { _ in _exit(0) }
        #endif

        // Everything up to the wait is bounded: a client that forgot to close its pipe, or a socket that will not
        // accept, must not hold the client here.
        let alarm = Alarm()
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = tagged(input, source: source) else { return }
        guard let socket = UnixSocket.connect(to: PermissionRequests.socketPath) else { return }
        defer { UnixSocket.close(socket) }
        guard UnixSocket.send(socket, payload) else { return }
        // Half-close so the HUD sees the whole request and knows no more is coming.
        UnixSocket.halfClose(socket)
        alarm.cancel()

        // Answered in the client's own dialog, the call shows up settled in the session record while this hook is
        // still waiting; leaving without an answer then takes the request off the HUD.
        let watch = source.recordsCalls
            ? (try? ProviderJSON.read(input)).flatMap { PermissionTranscriptWatch(payload: $0) { Self.goNow() } }
            : nil
        let response = UnixSocket.readToEnd(socket, limit: 1024 * 1024)
        // The HUD answered first; the answer is written whole.
        watch?.stop()
        guard !response.isEmpty else { return }
        FileHandle.standardOutput.write(response)
    }

    /// Adds the client's name to a request the HUD can answer. Codex runs this hook before choosing its reviewer;
    /// automatic review and an unknown reviewer go back unanswered, before opening a connection to the HUD.
    static func tagged(_ data: Data, source: PermissionHooks.Source) -> Data? {
        guard !data.isEmpty, data.count <= 1024 * 1024,
              let json = try? ProviderJSON.read(data), var object = json.objectValue else { return nil }
        guard source != .codex || CodexPermissionReviewer.isUser(payload: json) else { return nil }
        object[sourceKey] = .string(source.rawValue)
        return try? RecordCoding.encoder().encode(ProviderJSON.object(object))
    }

    /// Leaves at once, from wherever the transcript watch is running.
    static func goNow() {
        #if canImport(Darwin)
        _exit(0)
        #else
        ucrt._exit(0)
        #endif
    }

    /// The five seconds the connect-and-send phase may take; Darwin has `alarm`, elsewhere a one-shot on a side queue.
    private final class Alarm {
        #if canImport(Darwin)
        init() { alarm(5) }
        func cancel() { alarm(0) }
        #else
        private let item: DispatchWorkItem
        init() {
            item = DispatchWorkItem { Self.goNow() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: item)
        }
        func cancel() { item.cancel() }
        #endif
    }
}

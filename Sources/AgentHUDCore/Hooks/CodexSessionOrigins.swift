import AgentHUDSupport
import Foundation

/// The most recently observed host of a Codex session. This local inbox supplies navigation only; rollouts own turns.
public enum CodexSessionOrigins {
    public enum Host: String, Codable, Sendable { case cli, desktop, daemon, unknown }

    public struct Event: Codable, Equatable, Sendable {
        public let sessionID: String
        public let at: Date
        public let host: Host
        /// A present record with no target clears an earlier host's destination.
        public let target: SessionNavigationTarget?

        public init(sessionID: String, at: Date, host: Host, target: SessionNavigationTarget?) {
            self.sessionID = sessionID; self.at = at; self.host = host; self.target = target
        }
    }

    public static var directory: URL { AppSupport.directory.appendingPathComponent("session-origins/codex") }
    static let arguments = "--session-origin-hook codex"
    static let events = ["SessionStart", "UserPromptSubmit"]

    /// Create the watched folder before the first callback, without creating any session records.
    public static func prepare(directory: URL = directory) throws {
        try HookInbox(folder: directory).create()
    }

    /// Read the last host observation of each session, including observations that explicitly have no destination.
    public static func read(directory: URL = directory) -> [String: Event] {
        guard let files = try? HookInbox(folder: directory).files() else { return [:] }
        var result: [String: Event] = [:]
        for file in files {
            guard let data = try? HookInbox.data(of: file), let event = try? JSONDecoder().decode(Event.self, from: data),
                  !event.sessionID.isEmpty else { continue }
            if let earlier = result[event.sessionID], earlier.at >= event.at { continue }
            result[event.sessionID] = event
        }
        return result
    }

    /// The callback process inherits terminal variables from its host. They are used only for a verified CLI host.
    public static func record(data: Data, now: Date = Date(), directory: URL = directory,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try record(data: data, host: host(ancestors: ancestors()), environment: environment, now: now, directory: directory)
    }

    static func record(data: Data, host: Host, environment: [String: String], now: Date, directory: URL) throws {
        guard data.count <= HookInbox.payloadLimit else { throw ProviderFailure.limit }
        let payload = try ProviderJSON.read(data)
        guard events.contains(payload["hook_event_name"].stringValue ?? ""),
              let session = payload["session_id"].stringValue, !session.isEmpty, host != .unknown else { return }
        let target: SessionNavigationTarget?
        switch host {
        case .cli:
            if environment["TERM_PROGRAM"] == "iTerm.app", (environment["TMUX"] ?? "").isEmpty,
               let id = environment["ITERM_SESSION_ID"], !id.isEmpty {
                target = .iTermSession(id: id)
            } else { target = nil }
        case .desktop: target = .codexThread(id: session)
        case .daemon, .unknown: target = nil
        }
        let inbox = HookInbox(folder: directory), name = RecordCoding.hash([session])
        let file = directory.appendingPathComponent(name + ".json")
        if let data = try? HookInbox.data(of: file), let earlier = try? JSONDecoder().decode(Event.self, from: data),
           earlier.sessionID == session, earlier.at > now { return }
        try inbox.write(Event(sessionID: session, at: now, host: host, target: target), name: name, replacing: true)
    }

    /// Add both origin callbacks beside existing Codex hooks. Only this handler's commands are updated or removed.
    public static func configure(enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 directory: URL = directory) throws {
        let configuration = CodexLocator.dataDirectory(home: home, environment: environment).appendingPathComponent("hooks.json")
        let installer = HookInstaller(configuration: configuration, arguments: arguments)
        try installer.configure(enabled: enabled, executable: executable) { configuration, command in
            try events.reduce(configuration) { current, event in
                try ClaudeStyleHooks.updating(current, event: event, owns: installer.owns, command: command,
                                               group: ClaudeStyleHooks.group(timeout: 5))
            }
        }
        if enabled { try prepare(directory: directory) }
    }

    typealias Ancestor = HookProcessOrigins.Ancestor

    /// The nearest non-shell process owns the callback. An outer CLI cannot turn its app-server child into a CLI.
    static func host(ancestors: [Ancestor]) -> Host {
        #if os(Windows)
        // Ancestry is unknown on Windows, so no shell is ever skipped there.
        let shells: Set<String> = []
        #else
        let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh"]
        #endif
        guard let index = ancestors.firstIndex(where: { !shells.contains($0.executable) }) else { return .unknown }
        let process = ancestors[index]
        guard URL(fileURLWithPath: process.executable).lastPathComponent == "codex" else { return .unknown }
        switch invocation(process.arguments) {
        case .cli: return .cli
        case .daemon: return .daemon
        case .unknown: return .unknown
        case .desktop:
            // app-server has no terminal identity of its own. Only a directly established Desktop parent restores it.
            for parent in ancestors.dropFirst(index + 1) {
                if shells.contains(parent.executable) { continue }
                if parent.bundleIdentifier == "com.openai.codex" { return .desktop }
                return .daemon
            }
            return .daemon
        }
    }

    /// Parse global options before the subcommand; option values and prompt contents never name the host.
    static func invocation(_ arguments: [String]) -> Host {
        guard !arguments.isEmpty else { return .unknown }
        let values: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
                                   "-a", "--ask-for-approval", "--enable", "--disable", "-C", "--cd", "--add-dir", "-i", "--image"]
        let flags: Set<String> = ["--search", "--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--no-alt-screen", "--no-daemon"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return .cli }
            if values.contains(argument) {
                guard index + 1 < arguments.count else { return .unknown }
                index += 2; continue
            }
            if let equal = argument.firstIndex(of: "="), values.contains(String(argument[..<equal])) {
                index += 1; continue
            }
            if flags.contains(argument) { index += 1; continue }
            if argument.hasPrefix("-") { return .unknown }
            switch argument {
            case "app-server": return arguments.dropFirst(index + 1).contains("--managed-daemon") ? .daemon : .desktop
            case "daemon", "desktop-daemon": return .daemon
            case "mcp-server", "mcp", "login", "logout", "completion", "sandbox", "debug", "apply", "a", "cloud", "features": return .unknown
            default: return .cli
            }
        }
        return .cli
    }

    static func ancestors() -> [Ancestor] { HookProcessOrigins.ancestors() }
    static func processArguments(_ data: Data) -> [String]? { HookProcessOrigins.processArguments(data) }
}

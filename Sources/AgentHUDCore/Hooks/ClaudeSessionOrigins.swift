import AgentHUDSupport
import Foundation

/// The latest local host of a Claude Code session. Transcripts remain the sole owner of turns and completions.
public enum ClaudeSessionOrigins {
    public enum Host: String, Codable, Sendable { case cli, desktop, cowork, unsupported }

    public struct Event: Codable, Equatable, Sendable {
        public let sessionID: String
        public let at: Date
        public let host: Host
        /// A record without a destination clears the terminal of an earlier interactive invocation.
        public let target: SessionNavigationTarget?

        public init(sessionID: String, at: Date, target: SessionNavigationTarget?, host: Host = .cli) {
            self.sessionID = sessionID; self.at = at; self.target = target; self.host = host
        }

        private enum CodingKeys: String, CodingKey { case sessionID, at, target, host }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try values.decode(String.self, forKey: .sessionID)
            at = try values.decode(Date.self, forKey: .at)
            target = try values.decodeIfPresent(SessionNavigationTarget.self, forKey: .target)
            // Earlier records with no destination were explicit clears. A newly available Desktop index must not revive them.
            host = try values.decodeIfPresent(Host.self, forKey: .host) ?? (target == nil ? .unsupported : .cli)
        }
    }

    public static var directory: URL { AppSupport.directory.appendingPathComponent("session-origins/claude") }
    static let arguments = "--session-origin-hook claude"
    static let events = ["SessionStart", "UserPromptSubmit"]

    public static func prepare(directory: URL = directory) throws { try HookInbox(folder: directory).create() }

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

    /// Hooks have no controlling TTY of their own. Verify their nearest host and use only its inherited iTerm identity.
    public static func record(data: Data, now: Date = Date(), directory: URL = directory,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let executables = Set(ClaudeEngineLocator.candidates(home: home, path: environment["PATH"] ?? "")
            .map { $0.resolvingSymlinksInPath().path })
        let ancestors = HookProcessOrigins.ancestors()
        let host = host(ancestors: ancestors, environment: environment, executablePaths: executables)
        let target = navigationTarget(ancestors: ancestors, environment: environment,
                                      executablePaths: executables)
        try record(data: data, target: target, now: now, directory: directory, host: host)
    }

    static func record(data: Data, target: SessionNavigationTarget?, now: Date, directory: URL, host: Host = .cli) throws {
        guard data.count <= HookInbox.payloadLimit else { throw ProviderFailure.limit }
        let payload = try ProviderJSON.read(data)
        guard events.contains(payload["hook_event_name"].stringValue ?? ""),
              let session = payload["session_id"].stringValue, !session.isEmpty else { return }
        let name = RecordCoding.hash([session]), file = directory.appendingPathComponent(name + ".json")
        if let data = try? HookInbox.data(of: file), let earlier = try? JSONDecoder().decode(Event.self, from: data),
           earlier.sessionID == session, earlier.at > now { return }
        try HookInbox(folder: directory).write(Event(sessionID: session, at: now, target: target, host: host), name: name, replacing: true)
    }

    static func isDesktopEntrypoint(_ entrypoint: String?) -> Bool {
        desktopHost(entrypoint) != nil
    }

    static func desktopHost(_ entrypoint: String?) -> Host? {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return .desktop
        case "local-agent": return .cowork
        default: return nil
        }
    }

    /// The engine stamps its own surface. Desktop uses a separate exact metadata mapping, never inherited terminal variables.
    static func host(ancestors: [HookProcessOrigins.Ancestor], environment: [String: String],
                     executablePaths: Set<String>) -> Host {
        guard engineArguments(ancestors: ancestors, executablePaths: executablePaths) != nil else { return .unsupported }
        let entrypoint = environment["CLAUDE_CODE_ENTRYPOINT"]
        if let surface = desktopHost(entrypoint) {
            return ancestors.contains { $0.bundleIdentifier == "com.anthropic.claudefordesktop" } ? surface : .unsupported
        }
        if entrypoint == "cli" || entrypoint == "sdk-cli" { return .cli }
        return .unsupported
    }

    /// Only a direct interactive engine can supply a pane. Desktop callbacks retain their host without borrowing a terminal.
    static func navigationTarget(ancestors: [HookProcessOrigins.Ancestor], environment: [String: String],
                                 executablePaths: Set<String>) -> SessionNavigationTarget? {
        guard environment["CLAUDE_CODE_ENTRYPOINT"] == "cli", environment["TERM_PROGRAM"] == "iTerm.app",
              (environment["TMUX"] ?? "").isEmpty,
              let id = environment["ITERM_SESSION_ID"], !id.isEmpty else { return nil }
        guard let arguments = engineArguments(ancestors: ancestors, executablePaths: executablePaths), interactive(arguments) else { return nil }
        return .iTermSession(id: id)
    }

    private static func engineArguments(ancestors: [HookProcessOrigins.Ancestor], executablePaths: Set<String>) -> [String]? {
        #if os(Windows)
        // Ancestry is unknown on Windows, so no shell is ever skipped there.
        let shells: Set<String> = []
        #else
        let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh"]
        #endif
        guard let process = ancestors.first(where: { !shells.contains($0.executable) }) else { return nil }
        let executable = URL(fileURLWithPath: process.executable).resolvingSymlinksInPath().path
        let arguments: [String]
        if executablePaths.contains(executable) || process.bundleIdentifier == "com.anthropic.claude-code" {
            arguments = process.arguments
        } else if URL(fileURLWithPath: executable).lastPathComponent == "node", process.arguments.count > 1,
                  executablePaths.contains(URL(fileURLWithPath: process.arguments[1]).resolvingSymlinksInPath().path) {
            // The npm installer launches its exact CLI script through Node, rather than a native versioned executable.
            arguments = Array(process.arguments.dropFirst())
        } else { return nil }
        return arguments
    }

    /// Command mode supplements the engine's entrypoint marker. Never interpret an option value or prompt as a flag.
    static func interactive(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        let noninteractive: Set<String> = ["-p", "--print", "--background", "--bg", "--init-only", "--cloud", "--remote",
                                           "--sdk-url", "--input-format", "--output-format"]
        let values: Set<String> = ["--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--effort",
                                   "--fallback-model", "--json-schema", "--mcp-config", "--model", "--permission-mode",
                                   "--plugin-dir", "--plugin-url", "--session-id", "--settings", "--setting-sources",
                                   "--system-prompt", "--system-prompt-file", "--max-turns", "--max-budget-usd", "--name", "-n"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if noninteractive.contains(option) { return false }
            if values.contains(option), !argument.contains("=") { index += 2 } else { index += 1 }
        }
        return true
    }

    /// Installs origin callbacks beside the user's hooks without changing other settings or completion handlers.
    public static func configure(enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 directory: URL = directory) throws {
        let configuration = ClaudeSubscription.directory(home: home, environment: environment).appendingPathComponent("settings.json")
        let installer = HookInstaller(configuration: configuration, arguments: arguments)
        try installer.configure(enabled: enabled, executable: executable) { configuration, command in
            try events.reduce(configuration) { current, event in
                try ClaudeStyleHooks.updating(current, event: event, owns: installer.owns, command: command,
                                               group: ClaudeStyleHooks.group(timeout: 5))
            }
        }
        if enabled { try prepare(directory: directory) }
    }
}

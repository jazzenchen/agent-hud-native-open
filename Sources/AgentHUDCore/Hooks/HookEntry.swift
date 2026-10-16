import Foundation

/// The commands a client's hooks run, and the adapter commands that install them without starting the application:
/// short-lived processes that leave what a client sent for the running application, or hand it over and wait for the
/// answer, and quit. `--mcp` is the one a client keeps: the server its agent calls Agent HUD's tools through, for as
/// long as the client holds its input open. None of them starts the interface, queries an account or holds up the
/// client. A host runs them first thing at launch.
public enum HookEntry {
    /// Runs the command `arguments` name — the process's arguments, its executable first — and returns its exit status;
    /// nil when they name none, and the application starts. A hook's flag this build does not know, or a client it does
    /// not know after one it does, ends with 0 and prints nothing.
    public static func handle(arguments: [String]) -> Int32? {
        if arguments.contains("--install-pi-observer") {
            do {
                try PiSessionObserver.configure(enabled: true)
                print("Pi session observer installed. Run /reload in existing Pi sessions.")
                return 0
            } catch {
                FileHandle.standardError.write(Data("Could not install Pi session observer: \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        if MCPStdio.isRequested(by: arguments) { return MCPStdio.run() }
        guard arguments.count > 1, isHookFlag(arguments[1]) else { return nil }
        // A client's hook names one executable path, and a copy of another build may sit at it. One that does not know
        // the command must not start whole: a second application would rewrite every client's hooks to its own path.
        guard arguments.count == 3 else { return 0 }
        let name = arguments[2]
        switch arguments[1] {
        case "--session-origin-hook":
            switch name {
            case "codex": try? CodexSessionOrigins.record(data: input())
            case "claude":
                // Claude Code's PreCompact hook runs this command too (`CompactionHooks.arguments`); each record keeps
                // only the events it is for.
                let data = try? input()
                try? data.map { try ClaudeSessionOrigins.record(data: $0) }
                try? data.map { try CompactionHooks.record(source: .claude, data: $0) }
            default: return 0
            }
            print("{}")
            return 0
        case "--completion-hook":
            guard let source = CompletionHooks.Source(rawValue: name) else { return 0 }
            // Local status tracking must not affect the agent's execution.
            try? CompletionHooks.record(source: source, data: input())
            print(source == .antigravity ? #"{"decision":"stop"}"# : "{}")
            return 0
        case "--attention-hook":
            guard let source = AttentionHooks.Source(rawValue: name) else { return 0 }
            try? AttentionHooks.record(source: source, data: input())
            print("{}")
            return 0
        case "--permission-hook":
            // The client waits on this one: it holds the request open until the user answers on the HUD, and prints
            // nothing when it cannot be answered, which leaves the client's own permission prompt exactly as it was.
            guard let source = PermissionHooks.Source(rawValue: name) else { return 0 }
            guard source.usesHook else { return 0 }
            PermissionHookClient.run(source: source)
            return 0
        case "--install-completion-hook":
            // A person types this one, not a client: a name it does not know is a mistake to say.
            guard let source = CompletionHooks.Source(rawValue: name) else {
                FileHandle.standardError.write(Data("Unknown client for a completion hook: \(name)\n".utf8))
                return 1
            }
            do {
                try CompletionHooks.configure(source, enabled: true, executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL)
                print("Completion hook installed: \(source.rawValue)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("Could not install completion hook: \(error.localizedDescription)\n".utf8))
                return 1
            }
        default:
            return 0
        }
    }

    /// Whether `argument` is a hook's flag, `--…-hook`, a later build's included.
    static func isHookFlag(_ argument: String) -> Bool {
        argument.hasPrefix("--") && argument.hasSuffix("-hook")
    }

    /// Standard input, read until it ends or grows past the largest payload a record is made from.
    static func input() throws -> Data {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > HookInbox.payloadLimit { break }
        }
        return data
    }
}

#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Grok's live registry owns the exact session-to-PID link. Resolve only an interactive native process with one
/// registered session, so revealing its existing iTerm pane cannot land on another conversation in the pager.
public enum GrokSessionOrigins {
    public static var dataDirectory: URL {
        GrokSessions.directory(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
    }

    public static func read(sessionIDs: Set<String>, dataDirectory: URL = GrokSessionOrigins.dataDirectory)
        -> [String: SessionNavigationTarget] {
        #if os(Windows)
        // The registry's PID link is resolved through the kernel, which this port does not read.
        return [:]
        #else
        guard !sessionIDs.isEmpty,
              let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("active_sessions.json")) else { return [:] }
        return targets(in: data, sessionIDs: sessionIDs, uid: getuid(),
                       process: CodexTerminalOrigins.processIdentity, arguments: CodexTerminalOrigins.argumentsData)
        #endif
    }

    #if !os(Windows)
    private struct ActiveSession: Decodable {
        let session_id: String
        let pid: pid_t
        let opened_at: String
    }

    static func targets(in data: Data, sessionIDs: Set<String>, uid: uid_t,
                        process: (pid_t) -> CodexTerminalOrigins.ProcessIdentity?, arguments: (pid_t) -> Data?)
        -> [String: SessionNavigationTarget] {
        guard let records = try? JSONDecoder().decode([ActiveSession].self, from: data) else { return [:] }
        let byPID = Dictionary(grouping: records, by: \.pid)
        let byID = Dictionary(grouping: records, by: \.session_id)
        var result: [String: SessionNavigationTarget] = [:]
        for record in records {
            let id = "grok:" + record.session_id
            guard sessionIDs.contains(id), record.pid > 0, !record.session_id.isEmpty,
                  Set(byPID[record.pid, default: []].map(\.session_id)).count == 1,
                  Set(byID[record.session_id, default: []].map(\.pid)).count == 1,
                  let opened = DateParsing.internet(record.opened_at), let identity = process(record.pid),
                  let data = arguments(record.pid), let argv = CodexSessionOrigins.processArguments(data),
                  let environment = CodexTerminalOrigins.terminalEnvironment(data),
                  let target = target(process: identity, rechecked: process(record.pid), openedAt: opened,
                                      arguments: argv, environment: environment, uid: uid) else { continue }
            result[id] = target
        }
        return result
    }

    static func target(process: CodexTerminalOrigins.ProcessIdentity, rechecked: CodexTerminalOrigins.ProcessIdentity?,
                       openedAt: Date, arguments: [String], environment: [String: String], uid: uid_t) -> SessionNavigationTarget? {
        let name = URL(fileURLWithPath: process.executable).lastPathComponent
        let native = name == "grok" || name.range(of: #"^grok-[0-9]+\.[0-9]+\.[0-9]+-macos-(aarch64|x86_64)$"#,
                                                  options: .regularExpression) != nil
        let headless = arguments.dropFirst().contains { argument in
            argument == "-p" || argument.hasPrefix("-p") && !argument.hasPrefix("--")
                || ["--single", "--prompt-json", "--prompt-file", "--output-format", "--json-schema", "--memory-flush"].contains {
                    argument == $0 || argument.hasPrefix($0 + "=")
                }
        }
        let started = Double(process.startSeconds) + Double(process.startMicroseconds) / 1_000_000
        guard native, !headless, process == rechecked, process.uid == uid, process.startSeconds > 0,
              started < openedAt.timeIntervalSince1970 + 0.001,
              environment["TERM_PROGRAM"] == "iTerm.app", (environment["TMUX"] ?? "").isEmpty,
              let pane = environment["ITERM_SESSION_ID"], !pane.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .iTermSession(id: pane)
    }
    #endif
}

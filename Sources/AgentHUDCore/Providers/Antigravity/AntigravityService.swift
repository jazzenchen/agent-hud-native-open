import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Antigravity's already-running local services. Credentials stay in memory and are sent only to loopback.
enum AntigravityService {
    struct Candidate: Sendable {
        let pid: Int
        let token: String
        let extensionPort: Int?
        let extensionToken: String?
        let priority: Int
    }

    struct Endpoint: Sendable, Equatable {
        let pid: Int
        let base: URL
        let token: String

        func json(_ method: String, body: ProviderJSON = .object([:]), http: ProviderHTTP,
                  timeout: TimeInterval = 2) async throws -> ProviderJSON {
            var headers = ["Connect-Protocol-Version": "1"]
            if !token.isEmpty { headers["X-Codeium-Csrf-Token"] = token }
            return try await http.json(base.appendingPathComponent(method), headers: headers, body: body, timeout: timeout)
        }
    }

    /// A service that started since the last search is found this much later; one that quit is looked for at once.
    static let discoveryInterval: TimeInterval = 10
    /// What `permissionEndpoints` last found, shared by the polls that follow each other.
    static let remembered = Remembered(lifetime: discoveryInterval) { try await permissionEndpoints() }

    static func running() async throws -> [Candidate] {
        #if os(Windows)
        // Service discovery reads `ps`; on Windows a running service is not searched for.
        return []
        #else
        return candidates(try await ProviderCommand.run("/bin/ps", ["-U", String(getuid()), "-o", "pid=,command="]))
        #endif
    }

    /// Only services advertising their local credentials can supply an authenticated native approval snapshot.
    /// A failed inspection is unknown, rather than proof that one of their prompts has disappeared.
    static func permissionEndpoints(
        inspect: @Sendable (String, [String]) async throws -> String = ProviderCommand.run
    ) async throws -> [Endpoint] {
        #if os(Windows)
        return []
        #else
        let running = candidates(try await inspect("/bin/ps", ["-U", String(getuid()), "-o", "pid=,command="]))
        var found: [Endpoint] = []
        for candidate in running where !candidate.token.isEmpty || !(candidate.extensionToken ?? "").isEmpty {
            try Task.checkCancellation()
            let endpoints = try await endpoints(for: candidate, inspect: inspect)
            guard !endpoints.isEmpty else { throw ProviderFailure.format }
            found += endpoints
        }
        return found
        #endif
    }

    static func endpoints(for candidate: Candidate,
                          inspect: @Sendable (String, [String]) async throws -> String = ProviderCommand.run) async throws -> [Endpoint] {
        #if os(Windows)
        // lsof is macOS: only the extension port, which the command line itself declares, is known here.
        let ports: [Int] = []
        #else
        let ports = Self.ports(try await inspect("/usr/sbin/lsof", ["-nP", "-a", "-p", String(candidate.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]))
        #endif
        var locations = ports.map { ("https", $0, candidate.token) }
        if let port = candidate.extensionPort { locations.append(("http", port, candidate.extensionToken ?? candidate.token)) }
        return locations.compactMap { scheme, port, token in
            guard let base = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/") else { return nil }
            return Endpoint(pid: candidate.pid, base: base, token: token)
        }
    }

    private static let agyPattern = try! NSRegularExpression(pattern: #"(?:^|/)agy(?:\s|$)"#)
    private static let flagPatterns: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues:
        ["app_data_dir", "csrf_token", "extension_server_port", "extension_server_csrf_token"].map { name in
            let pattern = #"(?:^|\s)--"# + name + #"(?:=|\s+)(?:"([^"]+)"|'([^']+)'|([^\s]+))"#
            return (name, try! NSRegularExpression(pattern: pattern))
        })

    static func candidates(_ output: String) -> [Candidate] {
        // Every accepted CLI or server names one of these; the hundreds of unrelated processes are never taken apart.
        ProcessLines.mentioning(["antigravity", "agy"], in: output).compactMap { line in
            let pieces = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pieces.count == 2, let pid = Int(pieces[0]) else { return nil }
            let command = String(pieces[1]), lower = command.lowercased()
            guard lower.contains("antigravity") || lower.contains("agy") else { return nil }
            let cli = lower.contains("/antigravity-cli/") || lower.contains("/antigravity_cli/")
                || (lower.contains("agy") && agyPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil)
            let server = (lower.contains("language_server") || lower.contains("language-server"))
                && (lower.contains("antigravity.app/") || lower.contains("antigravity ide.app/")
                    || lower.contains("/antigravity/") || flag("app_data_dir", command: command)?.hasPrefix("antigravity") == true)
            guard cli || server else { return nil }
            let token = flag("csrf_token", command: command)
            guard cli || token?.isEmpty == false else { return nil }
            let extensionPort = flag("extension_server_port", command: command).flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
            return Candidate(pid: pid, token: token ?? "", extensionPort: extensionPort,
                extensionToken: flag("extension_server_csrf_token", command: command),
                priority: cli ? 1 : lower.contains("antigravity-ide") || lower.contains("antigravity ide.app") ? 2 : 0)
        }.sorted { ($0.priority, $0.pid) < ($1.priority, $1.pid) }
    }

    private static func flag(_ name: String, command: String) -> String? {
        guard command.contains("--" + name), let regex = flagPatterns[name],
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: command) { return String(command[range]) }
        }
        return nil
    }

    static func ports(_ output: String) -> [Int] {
        Set(output.split(separator: "\n").filter { $0.hasPrefix("n") }.compactMap { line -> Int? in
            guard let raw = line.split(separator: ":").last, let port = Int(raw), (1...65535).contains(port) else { return nil }
            return port
        }).sorted()
    }
}

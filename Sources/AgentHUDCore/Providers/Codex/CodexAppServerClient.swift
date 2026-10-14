import Foundation

/// One short-lived stdio connection. Only initialize, account/rateLimits/read and account/read; never starts a turn.
public struct CodexAppServerClient: Sendable {
    public let executable: URL
    public let dataDirectory: URL
    public let timeout: TimeInterval

    public init(executable: URL, dataDirectory: URL = CodexLocator.dataDirectory, timeout: TimeInterval = 30) {
        self.executable = executable
        self.dataDirectory = dataDirectory
        self.timeout = timeout
    }

    public func fetch() async throws -> CodexRateLimits {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = dataDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(Windows)
        environment["PATH"] = "\(home)\.bun\bin;\(home)\.local\bin;" + (environment["PATH"] ?? "")
        #else
        environment["PATH"] = "\(home)/.bun/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        #endif
        let server = try ChildProcess(executable, ["app-server", "--listen", "stdio://"], environment: environment,
                                      directory: FileManager.default.temporaryDirectory, input: true, stdoutLimit: 8 * 1024 * 1024)
        defer { server.stop() }
        func send(_ message: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: message)
            bytes.append(0x0A)
            try server.write(bytes)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agent_hud", "title": "Agent HUD", "version": "0.1.0"]]])
        let deadline = Date().addingTimeInterval(timeout)
        var limits: CodexRateLimits?
        var account: CodexRateLimits.SignedInAccount?
        var accountAnswered = false
        var graceUntil = Date.distantFuture
        // Lines stop at the deadline, when the grace for account/read runs out, or after an exited server's last line.
        while limits == nil || !accountAnswered, let line = try await server.line(before: min(deadline, graceUntil)) {
            guard let bytes = line.data(using: .utf8),
                  let message = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let id = message["id"] as? Int, (1...3).contains(id) else { continue }
            if let error = message["error"] as? [String: Any] {
                // An engine without account/read still reports limits, only without the signed-in email.
                guard id == 3 else { throw UsageProviderError("Codex: " + (error["message"] as? String ?? "app-server error")) }
                accountAnswered = true
                continue
            }
            guard let result = message["result"] else { continue }
            let data = try JSONSerialization.data(withJSONObject: result)
            switch id {
            case 1:
                try send(["method": "initialized"])
                try send(["id": 2, "method": "account/rateLimits/read"])
                try send(["id": 3, "method": "account/read", "params": [String: Any]()])
            case 2:
                limits = try JSONDecoder().decode(CodexRateLimits.self, from: data)
                graceUntil = Date().addingTimeInterval(2)
            default:
                account = try? JSONDecoder().decode(AccountResponse.self, from: data).account
                accountAnswered = true
            }
        }
        if var reading = limits {
            reading.account = account
            return reading
        }
        if server.output.status != nil {
            throw UsageProviderError(L10n.text("Codex 引擎提前退出，请检查本机登录状态", "Codex exited before reporting limits; check local sign-in"))
        }
        throw UsageProviderError(L10n.text("Codex 额度查询超时", "Codex quota query timed out"))
    }
}

private struct AccountResponse: Decodable {
    let account: CodexRateLimits.SignedInAccount?
}

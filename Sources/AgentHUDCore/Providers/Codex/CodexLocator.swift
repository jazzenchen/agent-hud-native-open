import Foundation

public enum CodexLocator {
    public static var dataDirectory: URL {
        dataDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func dataDirectory(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = ClientHome.variable("CODEX_HOME", in: environment) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Prefer the self-contained Desktop engine; GUI PATH often cannot run npm's node shim. The app is looked for under
    /// its known names, then wherever Launch Services has it under its bundle ID, whatever it is called now.
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  applications: URL = URL(fileURLWithPath: "/Applications"),
                                  path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                                  registered: [URL] = VendorCatalog.applications("Codex")) -> [URL] {
        desktop(home: home, applications: applications) + registered.flatMap(engines(in:)) + cli(home: home, path: path)
    }

    /// The same order as `candidates`, asking Launch Services only when no app sits under a known name.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            applications: URL = URL(fileURLWithPath: "/Applications"),
                            path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                            registered: @autoclosure () -> [URL] = VendorCatalog.applications("Codex")) -> URL? {
        Executables.first(desktop(home: home, applications: applications))
            ?? Executables.first(registered().flatMap(engines(in:)))
            ?? Executables.first(cli(home: home, path: path))
    }

    /// Current builds keep the engine in `codex-cli`, older ones beside the app's other resources.
    private static func engines(in app: URL) -> [URL] {
        ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"].map { app.appendingPathComponent($0) }
    }

    private static func desktop(home: URL, applications: URL) -> [URL] {
        [applications, home.appendingPathComponent("Applications")].flatMap { root in
            ["Codex.app", "ChatGPT.app"].flatMap { engines(in: root.appendingPathComponent($0)) }
        }
    }

    private static func cli(home: URL, path: String) -> [URL] {
        #if os(Windows)
        return [home.appendingPathComponent(".bun/bin/codex.exe"), home.appendingPathComponent(".local/bin/codex.exe")]
            + Executables.onPath("codex", path: path)
        #else
        return [home.appendingPathComponent(".bun/bin/codex"), home.appendingPathComponent(".local/bin/codex"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
            + Executables.onPath("codex", path: path)
        #endif
    }
}

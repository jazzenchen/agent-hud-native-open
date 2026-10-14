import Foundation

public enum DeepSeekLocator {
    public static var dataDirectory: URL { dataDirectory(environment: ProcessInfo.processInfo.environment) }

    public static func dataDirectory(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let path = ClientHome.variable("DSH_HOME", in: environment) else {
            return home.appendingPathComponent(".dsh", isDirectory: true)
        }
        let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    public static func isInstalled(directory: URL = dataDirectory) -> Bool {
        ["profiles", "sessions"].contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Harness itself requires Node with Zstandard support. GUI launches may have a minimal PATH.
    public static func nodeExecutable(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        #if os(Windows)
        return Executables.first(Executables.onPath("node", path: path))
            ?? Executables.first([URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROGRAMFILES"] ?? "",
                                       isDirectory: true).appendingPathComponent("nodejs/node.exe")])
        #else
        return Executables.first(Executables.onPath("node", path: path) + ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map { URL(fileURLWithPath: $0) })
        #endif
    }
}

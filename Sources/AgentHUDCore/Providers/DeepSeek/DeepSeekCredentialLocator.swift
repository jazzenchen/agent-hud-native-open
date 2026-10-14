import Foundation

enum DeepSeekCredentialLocator {
    static func module(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let suffix = "@deepseek-ai/dsh-credentials-local/lib/index.js"
        var roots: [URL]
        #if os(Windows)
        roots = [URL(fileURLWithPath: ProcessInfo.processInfo.environment["APPDATA"] ?? "",
                     isDirectory: true).appendingPathComponent("npm/node_modules"),
                 URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROGRAMFILES"] ?? "",
                     isDirectory: true).appendingPathComponent("nodejs/node_modules")]
        #else
        roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules"].map { URL(fileURLWithPath: $0) }
        #endif
        roots.append(home.appendingPathComponent(".bun/install/global/node_modules"))
        let cache = home.appendingPathComponent(".npm/_npx")
        if let installs = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) {
            roots += installs.sorted { a, b in
                ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.map { $0.appendingPathComponent("node_modules") }
        }
        return roots.map { $0.appendingPathComponent(suffix) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

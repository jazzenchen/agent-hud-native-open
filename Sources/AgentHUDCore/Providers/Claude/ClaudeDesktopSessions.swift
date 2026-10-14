import Foundation

/// Exact CLI-to-tab identifiers from the Claude Desktop metadata files. This index reads no transcript or account files.
public actor ClaudeDesktopSessions {
    private struct Location: Sendable { let url: URL; let cowork: Bool }
    private nonisolated let locations: [Location]
    public nonisolated var roots: [URL] { locations.map(\.url) }
    private static let metadataLimit = 1024 * 1024
    private struct Metadata: Decodable, Sendable {
        let sessionId: String
        let cliSessionId: String
        let isArchived: Bool?
    }
    private struct Stamp: Equatable, Sendable { let modified: Date?; let size: Int }
    private struct Cached: Sendable { let stamp: Stamp; let metadata: Metadata? }
    private var cache: [String: Cached] = [:]

    public init(codeRoot: URL = defaultRoots()[0], coworkRoot: URL? = defaultRoots()[1]) {
        locations = [Location(url: codeRoot, cowork: false)] + (coworkRoot.map { [Location(url: $0, cowork: true)] } ?? [])
    }

    public nonisolated static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let base = ClientHome.applicationData("Claude", home: home)
        return ["claude-code-sessions", "local-agent-mode-sessions"].map { base.appendingPathComponent($0, isDirectory: true) }
    }

    /// Only the requested native session IDs can become destinations. Conflicting active tab mappings are left unresolved.
    public func targets(sessionIDs: Set<String>) -> [String: SessionNavigationTarget] {
        guard !sessionIDs.isEmpty else { return [:] }
        var files: [String: Cached] = [:], matches: [String: Set<SessionNavigationTarget>] = [:]
        for location in locations {
            for file in Self.metadataFiles(roots: [location.url]) {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
                      size <= Self.metadataLimit else { continue }
                let stamp = Stamp(modified: values.contentModificationDate, size: size)
                let cached: Cached
                if let previous = cache[file.path], previous.stamp == stamp { cached = previous }
                else { cached = Cached(stamp: stamp, metadata: Self.read(file)) }
                files[file.path] = cached
                guard let metadata = cached.metadata, metadata.isArchived != true, sessionIDs.contains(metadata.cliSessionId),
                      Self.isLocalID(metadata.sessionId), file.deletingPathExtension().lastPathComponent == metadata.sessionId else { continue }
                let target: SessionNavigationTarget = location.cowork ? .claudeCoworkSession(id: metadata.sessionId) : .claudeDesktopSession(id: metadata.sessionId)
                matches[metadata.cliSessionId, default: []].insert(target)
            }
        }
        cache = files
        return matches.reduce(into: [:]) { result, match in
            if match.value.count == 1, let target = match.value.first { result[match.key] = target }
        }
    }

    private static func read(_ file: URL) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: metadataLimit + 1), data.count <= metadataLimit else { return nil }
        // Decode only the identifier and archive fields; titles, prompts, MCP configuration and account details are ignored.
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    static func isLocalID(_ id: String) -> Bool { id.hasPrefix("local_") && UUID(uuidString: String(id.dropFirst(6))) != nil }

    /// Walk exactly <root>/<organization>/<account>/local_*.json. Sibling transcript directories are never entered.
    static func metadataFiles(roots: [URL]) -> [URL] {
        func directories(_ root: URL) -> [URL] {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
            return files.filter {
                guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
        }
        return roots.flatMap { root in
            directories(root).flatMap { organization in
                directories(organization).flatMap { account in
                    ((try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                        .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("local_") }
                }
            }
        }
    }
}

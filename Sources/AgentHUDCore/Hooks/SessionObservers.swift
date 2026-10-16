import Foundation

/// The host opts into local adapter installation and supplies the executable that handles callbacks.
public enum SessionObservers {
    /// Points every Agent HUD handler in the clients installed here at `executable`, adding the ones that are missing,
    /// or, with `enabled` false, takes them all out, whichever copy of Agent HUD wrote them. Every other entry in the
    /// clients' files is left alone.
    public static func configure(executable: URL, enabled: Bool,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if enabled { installObservers(home: home) } else {
            do { try PiSessionObserver.configure(enabled: false, home: home) }
            catch { NSLog("[AgentHUD] Pi observer setup failed: %@", error.localizedDescription) }
            do { try OpenCodeSessionObserver.configure(enabled: false, home: home) }
            catch { NSLog("[AgentHUD] OpenCode observer setup failed: %@", error.localizedDescription) }
        }
        for source in AttentionHooks.Source.allCases where source.isInstalled(home: home) {
            do { try AttentionHooks.configure(source, enabled: enabled, executable: executable, home: home) }
            catch { NSLog("[AgentHUD] Notification hook setup failed for %@: %@", source.rawValue, error.localizedDescription) }
        }
        for source in CompactionHooks.Source.allCases where source.isInstalled(home: home) {
            do { try CompactionHooks.configure(source, enabled: enabled, executable: executable, home: home) }
            catch { NSLog("[AgentHUD] Compaction hook setup failed for %@: %@", source.rawValue, error.localizedDescription) }
        }
        for source in PermissionHooks.Source.allCases where source.usesHook && source.isInstalled(home: home) {
            do { try PermissionHooks.configure(source, enabled: enabled, executable: executable, home: home) }
            catch { NSLog("[AgentHUD] Permission hook setup failed for %@: %@", source.rawValue, error.localizedDescription) }
        }
        if PermissionHooks.Source.codex.isInstalled(home: home) {
            do { try CodexSessionOrigins.configure(enabled: enabled, executable: executable, home: home) }
            catch { NSLog("[AgentHUD] Codex origin hook setup failed: %@", error.localizedDescription) }
        }
        if PermissionHooks.Source.claude.isInstalled(home: home) {
            do { try ClaudeSessionOrigins.configure(enabled: enabled, executable: executable, home: home) }
            catch { NSLog("[AgentHUD] Claude origin hook setup failed: %@", error.localizedDescription) }
        }
        for source in CompletionHooks.Source.allCases {
            guard AdditionalSource(rawValue: source.rawValue)?.isInstalled(home: home) == true else { continue }
            do { try CompletionHooks.configure(source, enabled: enabled, executable: executable, home: home) }
            catch { NSLog("[AgentHUD] Completion hook setup failed for %@: %@", source.rawValue, error.localizedDescription) }
        }
    }

    /// The vendors whose observer lives in the client's own directory — Pi's extension, OpenCode's plugin — where that
    /// directory exists. It appears the first time the client runs, so a directory new since the last look is a client
    /// run for the first time while the host was open.
    public static func observedClients(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        var vendors: Set<String> = []
        if PiSessionObserver.isAvailable(home: home) { vendors.insert("Pi") }
        if OpenCodeSessionObserver.isAvailable(home: home) { vendors.insert("OpenCode") }
        return vendors
    }

    /// Adds the observer of every client whose directory exists, as start-up does with client hooks on.
    public static func installObservers(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        do { try PiSessionObserver.configureIfAvailable(home: home) }
        catch { NSLog("[AgentHUD] Pi observer setup failed: %@", error.localizedDescription) }
        do { try OpenCodeSessionObserver.configureIfAvailable(home: home) }
        catch { NSLog("[AgentHUD] OpenCode observer setup failed: %@", error.localizedDescription) }
    }
}

/// Whether an observer's file is in place in its client's directory, as the client's settings show it.
public enum ClientObserverFile: Sendable, Equatable {
    /// Agent HUD's file is there. One an earlier version wrote still reports, and the next setup updates it.
    case installed
    case missing
    /// A file of the same name belongs to something else and is left alone, so nothing reports.
    case foreign
}

/// An observer is one file Agent HUD keeps in a client's own directory, known by its first line: a file of the same name
/// that does not start with it belongs to something else and is never replaced or removed.
struct ObserverFile {
    let url: URL
    let marker: String
    let script: String
    /// Why setup refused a file of the same name that is not Agent HUD's.
    let conflict: String

    var state: ClientObserverFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix(marker) == true ? .installed : .foreign
    }

    var isCurrent: Bool { (try? String(contentsOf: url, encoding: .utf8)) == script }

    func configure(enabled: Bool) throws {
        switch state {
        case .foreign: throw UsageProviderError(conflict)
        case .missing:
            guard enabled else { return }
        case .installed:
            if !enabled { return try FileManager.default.removeItem(at: url) }
            if isCurrent { return }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url, options: .atomic)
    }
}

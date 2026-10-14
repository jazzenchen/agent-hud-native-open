#if canImport(CoreServices)
import CoreServices
#endif
import Foundation

/// What the app shows for a vendor, kept apart from the vendor's id. The id ("Codex") keys settings, the ledger, account
/// observations and sync records and never changes; a renamed product, a new entry point or a new window name changes
/// only an entry here. A value no entry names is shown as the vendor wrote it, never filed under another name.
public enum VendorCatalog {
    public struct Entry: Sendable {
        /// Shown wherever the vendor is named; nil shows the id.
        public var name: String?
        /// A vendor's first rows arrive switched off.
        public var startsHidden: Bool
        /// Apps that carry the vendor's client, found by bundle ID whatever the app is called.
        public var bundleIDs: [String]
        /// Client names as the vendor's logs write them, mapped to the client the app shows.
        public var clients: [String: String]
        /// Quota window names as the vendor's service reports them, mapped to the names shown.
        public var windows: [String: String]
        /// The same window names mapped to the word a short name keeps of them.
        public var windowWords: [String: String]

        public init(name: String? = nil, startsHidden: Bool = false, bundleIDs: [String] = [],
                    clients: [String: String] = [:], windows: [String: String] = [:], windowWords: [String: String] = [:]) {
            self.name = name
            self.startsHidden = startsHidden
            self.bundleIDs = bundleIDs
            self.clients = clients
            self.windows = windows
            self.windowWords = windowWords
        }
    }

    static let entries: [String: Entry] = [
        "Claude": Entry(clients: [
            "cli": "Claude Code CLI", "claude-desktop": "Claude Code Desktop", "claude-vscode": "Claude Code IDE extension",
        ]),
        // The ChatGPT app carries Codex under Codex's bundle ID. Rollouts name their client in `originator`: the desktop
        // app writes Codex Desktop, or codex_work_desktop signed in to a work workspace, and Codex's own code knows it as
        // codex_desktop too; the CLI's default is codex_cli_rs.
        "Codex": Entry(
            bundleIDs: ["com.openai.codex"],
            clients: ["Codex Desktop": "Desktop", "codex_work_desktop": "Desktop", "codex_desktop": "Desktop", "codex_vscode": "IDE",
                      "codex-tui": "CLI", "codex_cli_rs": "CLI", "codex-cli": "CLI", "codex_exec": "CLI · exec"],
            windows: ["gpt-reserve": "Luna Reserve"], windowWords: ["gpt-reserve": "Reserve"]),
        "Cursor": Entry(bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        "Grok Bot": Entry(bundleIDs: ["com.anysphere.sand"]),
        // An API balance, not a subscription: its rows stay out of the HUD until switched on.
        "DeepSeek": Entry(startsHidden: true),
    ]

    public static func name(_ vendor: String) -> String { entries[vendor]?.name ?? vendor }

    public static func startsHidden(_ vendor: String) -> Bool { entries[vendor]?.startsHidden ?? false }

    /// The client the app shows for a name the vendor's logs wrote, or nil when no entry names it.
    public static func client(_ value: String, vendor: String) -> String? { entries[vendor]?.clients[value] }

    /// The name shown for a quota window the vendor's service reported; unnamed windows keep the service's name.
    public static func window(_ value: String, vendor: String) -> String { entries[vendor]?.windows[value] ?? value }

    /// The word a short name keeps of a quota window the vendor's service reported: the catalog's, else the distinctive
    /// word of the name shown (`WindowNames.word(_:)`).
    public static func windowWord(_ value: String, vendor: String) -> String {
        entries[vendor]?.windowWords[value] ?? WindowNames.word(window(value, vendor: vendor))
    }

    /// The vendor's apps wherever Launch Services has seen them, so a renamed or moved app is still found.
    public static func applications(_ vendor: String) -> [URL] {
        #if canImport(CoreServices)
        return (entries[vendor]?.bundleIDs ?? []).flatMap { id -> [URL] in
            (LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        }
        #else
        return []
        #endif
    }

    /// Values met that no entry names yet, by kind ("Codex client"), for diagnostics.
    public static var unnamed: [String: Set<String>] { Unnamed.shared.values }

    /// Records a value shown as written because no entry names it; the first sighting of each is logged.
    static func noteUnnamed(_ value: String, kind: String) { Unnamed.shared.note(value, kind: kind) }

    private final class Unnamed: @unchecked Sendable {
        static let shared = Unnamed()
        private let lock = NSLock()
        private var seen: [String: Set<String>] = [:]

        var values: [String: Set<String>] { lock.withLock { seen } }

        func note(_ value: String, kind: String) {
            let first = lock.withLock { seen[kind, default: []].insert(value).inserted }
            if first { NSLog("[AgentHUD] Unnamed %@: %@", kind, value) }
        }
    }
}

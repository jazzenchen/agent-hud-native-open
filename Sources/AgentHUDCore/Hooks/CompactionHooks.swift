import AgentHUDSupport
import Foundation

/// A client saying it starts compacting a session's conversation, which its log cannot say until compaction is over: Claude
/// Code writes the boundary only once the summary is in. Like a request for the user, the record is evidence beside the
/// log, and the log decides: a session compacts while its record is newer than the log's last line and at most `limit`
/// old, and any newer line, the boundary first among them, ends it.
public enum CompactionHooks {
    public enum Source: String, CaseIterable, Sendable {
        case claude
        var event: String { "PreCompact" }
        /// Only the compaction the client starts on its own, in the middle of a turn. A `/compact` the user types runs
        /// while the session waits for them, and is not work the session is doing.
        var matcher: String { "auto" }
        /// Claude Code's settings, in the directory `CLAUDE_CONFIG_DIR` moves.
        func configuration(home: URL) -> URL { ClaudeSubscription.directory(home: home).appendingPathComponent("settings.json") }

        /// Whether the client is here at all. A machine without it keeps its home untouched.
        func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> Bool {
            switch self {
            case .claude: AttentionHooks.Source.claude.isInstalled(home: home, fileManager: fileManager)
            }
        }
    }

    /// The last compaction a client began in one session.
    public struct Event: Codable, Equatable, Sendable {
        public let sessionID: String
        public let at: Date
        /// What started it, as the client names it: "auto" or "manual".
        public let trigger: String?

        public init(sessionID: String, at: Date, trigger: String?) {
            self.sessionID = sessionID; self.at = at; self.trigger = trigger
        }

        /// Whether the client started it on its own.
        public var isAutomatic: Bool { trigger == "auto" }
    }

    public static var directory: URL { AppSupport.directory.appendingPathComponent("compaction") }
    /// A compaction begun this long ago is over, whether or not its boundary reached the log. Its record is forgotten the
    /// next time a compaction is recorded: every collection pass reads every record kept, and an older one never counts.
    public static let limit: TimeInterval = 300

    /// The compaction the payload says began, of the session's own conversation. Claude Code runs the hook inside a
    /// sub-agent too, with the session's id and the sub-agent's `agent_id`; that compaction ends in the sub-agent's log,
    /// which the session's record is never compared with, so it is not the session's.
    static func event(_ payload: ProviderJSON, now: Date) -> Event? {
        guard payload["hook_event_name"].stringValue == "PreCompact",
              let session = payload["session_id"].stringValue, !session.isEmpty, payload["agent_id"].stringValue == nil
        else { return nil }
        return Event(sessionID: session, at: now, trigger: payload["trigger"].stringValue)
    }

    /// One file per session: only the latest compaction matters, and its end is seen in the transcript, not here.
    public static func record(source: Source, data: Data, now: Date = Date(), directory: URL = directory) throws {
        guard data.count <= HookInbox.payloadLimit else { throw ProviderFailure.limit }
        guard let event = event(try ProviderJSON.read(data), now: now) else { return }
        let inbox = HookInbox(directory: directory, source: source.rawValue)
        let name = RecordCoding.hash([event.sessionID])
        try inbox.write(event, name: name, replacing: true)
        // Records age by when compaction began, which is inside them; a file's own timestamps say nothing about that.
        for file in try inbox.files() where file.lastPathComponent != name + ".json" {
            let stored = (try? HookInbox.data(of: file)).flatMap { try? JSONDecoder().decode(Event.self, from: $0) }
            if stored.map({ $0.at <= now.addingTimeInterval(-limit) }) ?? true { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The compactions begun at most `limit` before `now`, by session.
    public static func read(source: Source, now: Date = Date(), directory: URL = directory) -> [String: Event] {
        guard let files = try? HookInbox(directory: directory, source: source.rawValue).files() else { return [:] }
        var result: [String: Event] = [:]
        for file in files {
            guard let data = try? HookInbox.data(of: file), let event = try? JSONDecoder().decode(Event.self, from: data),
                  event.at > now.addingTimeInterval(-limit), event.at <= now.addingTimeInterval(60) else { continue }
            if let existing = result[event.sessionID], existing.at >= event.at { continue }
            result[event.sessionID] = event
        }
        return result
    }

    /// When the session began compacting, given when its log last wrote anything: the client's own compaction still
    /// newer than that line. Nil when it is not compacting by its record.
    static func since(_ event: Event?, lastLineAt: Date?) -> Date? {
        guard let event, event.isAutomatic, event.at > lastLineAt ?? .distantPast else { return nil }
        return event.at
    }

    // MARK: Installation

    /// What follows the executable in Agent HUD's handler of the compaction hook: the session origin hook's own command,
    /// which tells the events apart by name. Every build since that hook came hears a compaction there and does nothing
    /// with it, so a hook this build installs never reaches an older copy at the same path as a flag it does not know,
    /// which would start that copy whole.
    static func arguments(_ source: Source) -> String {
        switch source {
        case .claude: ClaudeSessionOrigins.arguments
        }
    }

    static func installer(_ source: Source, home: URL) -> HookInstaller {
        HookInstaller(configuration: source.configuration(home: home), arguments: arguments(source))
    }

    static func configuration(_ source: Source, home: URL) throws -> [String: ProviderJSON] {
        try installer(source, home: home).read()
    }

    static func ownsCommand(_ command: String?, source: Source) -> Bool { HookCommand.runs(command, arguments: arguments(source)) }

    public static func isActive(_ source: Source, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let object = try? configuration(source, home: home) else { return false }
        return !commands(in: object, source: source).isEmpty
    }

    static func commands(in configuration: [String: ProviderJSON], source: Source) -> [String] {
        ClaudeStyleHooks.commands(in: configuration, event: source.event) { ownsCommand($0, source: source) }
    }

    /// Points every Agent HUD handler of the compaction hook at `executable`, whichever copy wrote it (`HookCommand`), or
    /// with `enabled` false takes them all out, leaving every other hook in the file alone. An unrecognized layout throws
    /// rather than being rewritten.
    public static func configure(_ source: Source, enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try installer(source, home: home).configure(enabled: enabled, executable: executable, updating: {
            try updating($0, source: source, command: $1)
        }, willWrite: {
            // The inbox exists from the moment the hook does, so its changes can be watched before the first record.
            try? HookInbox(directory: directory, source: source.rawValue).create()
        })
    }

    /// The configuration with Agent HUD's handlers taken out, or with `command` when it is given: in the first handler
    /// already there, or in a group of its own.
    static func updating(_ configuration: [String: ProviderJSON], source: Source, command: String?) throws -> [String: ProviderJSON] {
        // That compaction began is a report: the client compacts without waiting for it.
        try ClaudeStyleHooks.updating(configuration, event: source.event, owns: { ownsCommand($0, source: source) }, command: command,
                                      fixed: ClaudeStyleHooks.reporting) { command in
            .object(["matcher": .string(source.matcher),
                     "hooks": .array([.object(ClaudeStyleHooks.reporting.merging(["type": .string("command"), "command": .string(command),
                                                                                  "timeout": .integer(5)]) { $1 })])])
        }
    }
}

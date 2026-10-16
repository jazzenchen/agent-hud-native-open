import Foundation

/// What a session's own log says its turn is busy with: the calls still waiting for their result, the kind of work its
/// newest calls do, and what its newest line is. Only the clients whose logs record each tool call have one (Claude Code,
/// Codex, Grok CLI, DeepSeek Harness). It says nothing about whether the turn is in flight, which `SessionTurn` and the
/// session's phase do, and holds only times its log wrote, never one it was read at.
public struct SessionActivity: Hashable, Codable, Sendable {
    /// What a call does, by the groups a permission request names its tool with (`PermissionRequest.group(ofTool:)`).
    public enum Work: String, Hashable, Codable, Sendable {
        /// A shell command: Claude Code's Bash, Codex's exec. The only work that can show as a long command.
        case shell
        /// Any other command: an MCP tool, Codex's js.
        case command
        case edit
        /// Reading, searching or fetching.
        case read
        /// Starting, messaging or waiting on sub-agents: Claude Code's Task and Agent, Codex's collaboration tools.
        case agents
        /// Asking the user something: Codex's request_user_input_async.
        case question

        /// Whether a session shows this work as what it is doing: a command, an edit or a read. Sub-agents and questions
        /// show as themselves, beside or instead of it.
        public var isShown: Bool { self != .agents && self != .question }
    }

    /// A call still waiting for its result.
    public struct Call: Hashable, Codable, Sendable {
        public let id: String
        /// Nil for a tool no group names, such as a to-do list or a tool search: such a call never changes what the
        /// session shows, though it still waits for its result.
        public let work: Work?
        public let at: Date

        public init(id: String, work: Work?, at: Date) {
            self.id = id; self.work = work; self.at = at
        }
    }

    /// What the newest line of the conversation holds.
    public enum Line: String, Hashable, Codable, Sendable {
        /// The prompt that started the turn.
        case prompt
        /// Anything else the user's side added: context a hook or a skill injected, a compaction's summary.
        case context
        case call
        case result
        /// A thinking block, which the client writes once it is finished.
        case thinking
        /// Text the agent wrote without ending the turn.
        case text
        /// The answer that ended the turn.
        case answer
        /// The message the client writes in the model's place when the API failed the turn.
        case error
    }

    /// The calls of the turn still waiting for their result, oldest first.
    public private(set) var calls: [Call] = []
    /// The kind of work the turn's calls do as the log was last read, a command, an edit or a read: the newest call still
    /// open, else the newest one that read brought in, else what the read before said. Nil before the turn's first call.
    public private(set) var work: Work?
    /// When the newest call was last seen: when it was made, or when its result came back if that is later.
    public private(set) var toolAt: Date?
    /// The newest line of the conversation; nil for a client whose log does not tell.
    public var line: Line?
    /// Whether the newest line of any kind says the client is trying a failed API request again.
    public var retrying = false
    /// The newest line of the session's sub-agents that are themselves at work; nil when none is.
    public var subagentsAt: Date?
    /// When the client said it began compacting the conversation, while that is newer than the log's last line
    /// (`CompactionHooks`).
    public var compactingSince: Date?
    /// The newest work the read under way brought in, which `settle()` takes into `work`.
    private var latest: Work?

    public init() {}

    /// The newest call still open whose work the session shows.
    public var openCall: Call? { calls.last { $0.work?.isShown == true } }

    /// Whether any call of the turn still waits for its result, one no group names included.
    public var hasOpenCall: Bool { !calls.isEmpty }

    /// Whether the session's sub-agents are at work: a call that starts or waits on them is open, or their own logs move.
    public var delegating: Bool { subagentsAt != nil || calls.contains { $0.work == .agents } }

    /// When the open call asking the user something was made; nil when none is open.
    public var askedAt: Date? { calls.last { $0.work == .question }?.at }

    /// Whether the conversation's newest line leaves the model to go on: a prompt, context, a call's result, a thinking
    /// block or text that did not end the turn. A client whose log does not say leaves it open too.
    public var awaitsModel: Bool {
        switch line {
        case nil, .prompt, .context, .result, .thinking, .text: true
        case .call, .answer, .error: false
        }
    }

    // MARK: Reading

    /// A new turn starts: nothing of the last one is open, and nothing it did says what this one does.
    public mutating func startTurn() {
        calls = []
        work = nil
        toolAt = nil
        latest = nil
    }

    /// The turn is over: none of its calls waits for a result any more.
    public mutating func endTurn() {
        calls = []
        latest = nil
    }

    /// A call made at `at`.
    public mutating func open(_ id: String, work: Work?, at: Date) {
        calls.removeAll { $0.id == id }
        calls.append(Call(id: id, work: work, at: at))
        if let work, work.isShown { latest = work }
        toolAt = max(toolAt ?? at, at)
    }

    /// A call's result came back at `at`.
    public mutating func close(_ id: String, at: Date) {
        calls.removeAll { $0.id == id }
        toolAt = max(toolAt ?? at, at)
    }

    /// Work the log records only once it is done, such as a file Codex changed, as if a call of it had been made and
    /// answered at `at`.
    public mutating func did(_ work: Work, at: Date) {
        if work.isShown { latest = work }
        toolAt = max(toolAt ?? at, at)
    }

    /// Ends one read of the log: the newest open call says what the turn does, else the newest work the read brought in,
    /// else the turn keeps what the read before said.
    public mutating func settle() {
        if let open = openCall?.work { work = open } else if let latest { work = latest }
        latest = nil
    }

    // MARK: Tools

    /// What a call of `tool` does, by the group a permission request shows it with; nil for a tool no group names, and
    /// for the questions and plans the user answers, which are requests rather than work.
    public static func work(ofTool tool: String) -> Work? {
        switch PermissionRequest.group(ofTool: tool) {
        case "BASH": .shell
        case "MCP": .command
        case "EDIT": .edit
        case "READ", "FIND", "WEB": .read
        case "AGENT": .agents
        default: nil
        }
    }
}

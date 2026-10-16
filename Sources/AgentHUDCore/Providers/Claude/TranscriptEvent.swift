import AgentHUDSupport
import Foundation

/// One line of a Claude Code transcript (`~/.claude/projects/**/*.jsonl`).
public struct TranscriptEvent: Hashable, Sendable {
    public enum Role: String, Sendable {
        case user, assistant, other
    }

    public let timestamp: Date
    public let role: Role
    public let model: String?
    public let inputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    /// The part of `outputTokens` spent thinking, which current builds record per message.
    public let thinkingTokens: Int
    /// First text of a user message (used for the session title); nil for other lines.
    public let text: String?
    public let sessionId: String?
    public let cwd: String?
    /// API message id; Claude Code writes one line per content block, so usage repeats under the same id.
    public let messageId: String?
    public let requestId: String?
    /// `message.stop_reason` of an assistant line ("end_turn", "tool_use", …); nil for other lines and for a null reason.
    public let stopReason: String?
    /// Sub-agent traffic that older Claude Code builds wrote into the parent transcript.
    public let isSidechain: Bool
    /// A user line that starts a turn: typed or queued input, not a tool result, command output, injected context or the
    /// summary a compaction leaves.
    public let isPrompt: Bool
    /// The boundary Claude Code writes where it compacted the conversation.
    public let isCompaction: Bool
    /// A `system` line Claude Code writes once the agent has stopped: the summary of the Stop hooks it ran
    /// (`stop_hook_summary`) or the turn's duration (`turn_duration`).
    public let isStop: Bool
    /// Surface that wrote the line, from the `entrypoint` current builds stamp on every message ("cli",
    /// "claude-desktop", "claude-vscode", "sdk-ts"); nil for older builds.
    public let entrypoint: String?
    /// An assistant line calling `StructuredOutput`: the result a workflow agent hands back, after which its log ends
    /// without an `end_turn`.
    public let returnsStructuredOutput: Bool
    /// The tool an assistant line calls and the call's id, from its `tool_use` block; nil for any other line.
    public let toolName: String?
    public let toolUseID: String?
    /// The call a user line carries the result of, from its `tool_result` block's `tool_use_id`.
    public let toolResultID: String?
    /// An assistant line holding a thinking block. Claude Code writes the block once it is finished.
    public let isThinking: Bool
    /// The `error` of the message Claude Code writes in the model's place when the API failed the turn (`isApiErrorMessage`),
    /// such as "rate_limit", "billing_error" or "server_error"; nil for every other line.
    public let apiError: String?
    /// When the usage limit behind such a message lifts, from its `quotaLimits.resetsAt`.
    public let limitResetsAt: Date?
    /// The attempt of a `system` line saying Claude Code retries a failed API request (`api_error` with `retryAttempt`).
    public let retryAttempt: Int?
    /// Where the line begins in its log, when it was read from a known place in one.
    public var offset: Int?

    public init(
        timestamp: Date, role: Role, model: String?, inputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int,
        outputTokens: Int, thinkingTokens: Int = 0, text: String?, sessionId: String?, cwd: String?, messageId: String? = nil,
        requestId: String? = nil, stopReason: String? = nil, isSidechain: Bool = false, isPrompt: Bool = false,
        isCompaction: Bool = false, isStop: Bool = false, entrypoint: String? = nil, returnsStructuredOutput: Bool = false,
        toolName: String? = nil, toolUseID: String? = nil, toolResultID: String? = nil, isThinking: Bool = false,
        apiError: String? = nil, limitResetsAt: Date? = nil, retryAttempt: Int? = nil
    ) {
        self.timestamp = timestamp
        self.role = role
        self.model = model
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
        self.text = text
        self.sessionId = sessionId
        self.cwd = cwd
        self.messageId = messageId
        self.requestId = requestId
        self.stopReason = stopReason
        self.isSidechain = isSidechain
        self.isPrompt = isPrompt
        self.isCompaction = isCompaction
        self.isStop = isStop
        self.entrypoint = entrypoint
        self.returnsStructuredOutput = returnsStructuredOutput
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.toolResultID = toolResultID
        self.isThinking = isThinking
        self.apiError = apiError
        self.limitResetsAt = limitResetsAt
        self.retryAttempt = retryAttempt
    }

    /// Key used to count each API response once.
    public var usageKey: String? {
        if let messageId { return "m:" + messageId }
        if let requestId { return "r:" + requestId }
        return nil
    }

    /// Fresh input (prompt + cache writes); cache reads are excluded because they are billed differently.
    public var tokensIn: Int { inputTokens + cacheCreationTokens }
    public var hasUsage: Bool { role == .assistant && (tokensIn + cacheReadTokens + outputTokens) > 0 }
}

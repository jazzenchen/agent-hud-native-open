import AgentHUDSupport
import Foundation

public enum ClaudeTranscriptParser {
    public static func parseLine(_ line: String) -> TranscriptEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = (object["timestamp"] as? String).flatMap(DateParsing.iso8601)
        else { return nil }
        let message = object["message"] as? [String: Any]
        let roleName = (message?["role"] as? String) ?? (object["type"] as? String)
        let role: TranscriptEvent.Role
        switch roleName {
        case "user": role = .user
        case "assistant": role = .assistant
        default: role = .other
        }
        let usage = message?["usage"] as? [String: Any]
        func count(_ key: String) -> Int {
            if let value = usage?[key] as? Int { return value }
            if let value = usage?[key] as? Double { return Int(value) }
            return 0
        }
        var text: String?
        var isToolResult = false
        var resultID: String?
        if role == .user, let content = message?["content"] {
            if let string = content as? String {
                text = string
            } else if let blocks = content as? [[String: Any]] {
                text = blocks.first { ($0["type"] as? String) == "text" }?["text"] as? String
                isToolResult = blocks.contains { ($0["type"] as? String) == "tool_result" }
                resultID = blocks.first { ($0["type"] as? String) == "tool_result" }?["tool_use_id"] as? String
            }
        }
        let block = role == .assistant ? (message?["content"] as? [[String: Any]])?.first : nil
        let call = block?["type"] as? String == "tool_use" ? block : nil
        let apiError = role == .assistant && object["isApiErrorMessage"] as? Bool == true ? object["error"] as? String : nil
        let resetsAt = apiError == nil ? nil : ((object["quotaLimits"] as? [String: Any])?["resetsAt"] as? Double)
        let isRetry = object["type"] as? String == "system" && object["subtype"] as? String == "api_error"
        let isMeta = object["isMeta"] as? Bool ?? false
        let isSummary = object["isCompactSummary"] as? Bool ?? false
        let details = usage?["output_tokens_details"] as? [String: Any]
        let calls = role == .assistant ? message?["content"] as? [[String: Any]] ?? [] : []
        return TranscriptEvent(
            timestamp: timestamp,
            role: role,
            model: message?["model"] as? String,
            inputTokens: count("input_tokens"),
            cacheCreationTokens: count("cache_creation_input_tokens"),
            cacheReadTokens: count("cache_read_input_tokens"),
            outputTokens: count("output_tokens"),
            thinkingTokens: (details?["thinking_tokens"] as? Int) ?? 0,
            text: text,
            sessionId: object["sessionId"] as? String,
            cwd: object["cwd"] as? String,
            messageId: message?["id"] as? String,
            requestId: object["requestId"] as? String,
            stopReason: role == .assistant ? message?["stop_reason"] as? String : nil,
            isSidechain: object["isSidechain"] as? Bool ?? false,
            isPrompt: role == .user && !isMeta && !isToolResult && !isSummary && !isLocalCommand(text),
            isCompaction: object["type"] as? String == "system" && object["subtype"] as? String == "compact_boundary",
            isStop: object["type"] as? String == "system" && ["stop_hook_summary", "turn_duration"].contains(object["subtype"] as? String),
            entrypoint: object["entrypoint"] as? String,
            returnsStructuredOutput: calls.contains { $0["type"] as? String == "tool_use" && $0["name"] as? String == "StructuredOutput" },
            toolName: call?["name"] as? String, toolUseID: call?["id"] as? String, toolResultID: resultID,
            isThinking: ["thinking", "redacted_thinking"].contains(block?["type"] as? String),
            apiError: apiError, limitResetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) },
            retryAttempt: isRetry ? object["retryAttempt"] as? Int : nil
        )
    }

    public static func parse(_ text: String) -> [TranscriptEvent] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseLine(String($0)) }
    }

    /// A slash command Claude Code runs itself, such as `/exit`, `/clear` or `/model`, is written as a `<command-name>`
    /// line and its output as `<local-command-…>` lines, without the meta flag; neither reaches the model. A command that
    /// expands into a prompt writes `<command-message>` first.
    static func isLocalCommand(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.hasPrefix("<command-name>") || text.hasPrefix("<local-command-")
    }
}

public enum ClaudeModelMapper {
    /// Maps an API model id to a family row id ("claude-opus" / "claude-sonnet" / "claude-fable" / "claude-haiku").
    public static func agentId(for model: String?) -> String? {
        guard let model, !model.isEmpty, model != "<synthetic>" else { return nil }
        return "claude-model:\(model)"
    }
}

/// Which Claude Code surface drives a session, from the transcript's `entrypoint` (`CLAUDE_CODE_ENTRYPOINT`).
/// The label is stored as the session's client, so synced peers and the iOS app show it without knowing the ids.
public enum ClaudeEntrypoint {
    /// Builds before the field existed.
    public static let defaultLabel = "Claude Code"

    /// Named surfaces come from the vendor catalog; an id it does not name is shown as written.
    public static func clientLabel(_ entrypoint: String?) -> String {
        guard let entrypoint, !entrypoint.isEmpty else { return defaultLabel }
        if let named = VendorCatalog.client(entrypoint, vendor: "Claude") { return named }
        if entrypoint.hasPrefix("sdk-") { return "Claude Agent SDK" }
        VendorCatalog.noteUnnamed(entrypoint, kind: "Claude client")
        return entrypoint
    }
}

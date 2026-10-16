import AgentHUDSupport
import Foundation

/// One request a client is asking its user about, through a tool hook or its native channel.
///
/// Answering resumes the client, and the client withdrawing the request takes it off the HUD. Nothing here is stored.
public struct PermissionRequest: Identifiable, Equatable, Sendable {
    /// Native requests carry their own scopes or active turn rather than a tool-hook permission rule.
    public enum NativeApproval: Equatable, Sendable {
        case computerUseApp(persist: [String])
        /// The browser asking for a website, with the scopes its answer can be kept for: none for an answer that is
        /// not kept beyond what the browser itself keeps.
        case browserAccess(origin: String?, persist: [String])
        case asynchronousQuestion(turnID: String)
    }

    public let id: String
    public let source: PermissionHooks.Source
    /// Whose request this is, as the HUD names clients elsewhere. It comes from the hook's own source today and
    /// from the channel itself once a client answers without one.
    public let vendor: String
    public let sessionID: String
    public let toolName: String?
    /// The one line worth reading first: what this call does to what.
    public let summary: String
    /// The full subject of the call — a command, a path, a URL, the tool's own input — which is what an allow lets run,
    /// so it is there to read even when the summary already says it.
    public let detail: String?
    public let cwd: String?
    /// The file this call is about, when it is about one; the summary names it, this locates it.
    public let path: String?
    /// The two sides of an edit, already trimmed to what is worth reading before approving it.
    public let removed: String?
    public let added: String?
    /// What the client itself offers to change if this is allowed — the same entries its own dialog builds its
    /// options from. They are echoed back untouched rather than assembled here: the client knows what rule fits its
    /// own request, and a rule invented from the outside is the kind that silently never matches.
    public let suggestions: [JSONValue]
    /// What the call asks, when it is a question put to the user rather than a tool waiting to run. A question is
    /// answered, not allowed: the answers travel back inside the call's own input, which is kept for that.
    public let questions: [PermissionQuestion]
    /// The call's own input, kept for a question or a plan: a question's answers travel back inside it, and Claude Code
    /// approves a plan only when its input comes back with the allow.
    let answerInput: JSONValue?
    public let nativeApproval: NativeApproval?
    public let at: Date

    public var isQuestion: Bool { !questions.isEmpty }
    /// A plan Claude Code wants approved before it starts changing anything.
    public var isPlan: Bool { toolName.map(Self.kind) == Self.planTool }
    static let planTool = "ExitPlanMode"
    /// The whole plan as the agent wrote it, Markdown, for reading before it is approved.
    public var plan: String? {
        guard isPlan, let text = answerInput?["plan"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
    /// Whether this plan can be answered here: approved, approved with edits accepted, or sent back with a note. Only a
    /// client that takes those answers from its hook qualifies; elsewhere the HUD points to the client's own dialog.
    public var answersPlan: Bool { plan != nil && source.answersPlans && nativeApproval == nil }

    /// The folder the session runs in, which is how a user tells two sessions apart.
    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    public init(id: String, source: PermissionHooks.Source, vendor: String? = nil, sessionID: String, toolName: String?,
                summary: String, detail: String?, cwd: String?, path: String? = nil,
                removed: String? = nil, added: String? = nil, suggestions: [JSONValue] = [],
                questions: [PermissionQuestion] = [], answerInput: JSONValue? = nil,
                nativeApproval: NativeApproval? = nil, at: Date) {
        self.id = id
        self.source = source
        self.vendor = vendor ?? source.vendor
        self.sessionID = sessionID
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.cwd = cwd
        self.path = path
        self.removed = removed
        self.added = added
        self.suggestions = suggestions
        self.questions = questions
        self.answerInput = answerInput
        self.nativeApproval = nativeApproval
        self.at = at
    }

    /// What kind of call this is, in one word, so a list of them can be read down the left edge.
    public var badge: String {
        if isQuestion { return "ASK" }
        if case .computerUseApp = nativeApproval { return "APP" }
        if case .browserAccess = nativeApproval { return "WEB" }
        guard let toolName, !toolName.isEmpty else { return "TOOL" }
        return Self.group(ofTool: toolName) ?? String(toolName.prefix(6)).uppercased()
    }

    /// The group a client's tool belongs to, as a request's badge names it: BASH, EDIT, READ, FIND, WEB, AGENT, MCP, ASK
    /// or PLAN. Nil for a tool no group names, whose badge is its own name.
    public static func group(ofTool toolName: String) -> String? {
        if toolName.hasPrefix("mcp__") { return "MCP" }
        switch kind(toolName) {
        case "Bash", "BashOutput", "KillShell": return "BASH"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return "EDIT"
        case "Read": return "READ"
        case "Glob", "Grep": return "FIND"
        case "WebFetch", "WebSearch": return "WEB"
        case "Task", "Agent": return "AGENT"
        case "AskUserQuestion": return "ASK"
        case "ExitPlanMode": return "PLAN"
        default: return nil
        }
    }

    /// The mark a call is recognized by before its name is read. Only what the client's own tools are; an unknown
    /// tool gets the neutral one rather than a guess.
    public var symbol: String {
        if isQuestion { return "questionmark.bubble.fill" }
        if case .computerUseApp = nativeApproval { return "desktopcomputer" }
        if case .browserAccess = nativeApproval { return "globe" }
        guard let toolName, !toolName.isEmpty else { return "questionmark.circle" }
        if toolName.hasPrefix("mcp__") { return "puzzlepiece.extension.fill" }
        switch Self.kind(toolName) {
        case "Bash", "BashOutput", "KillShell": return "terminal.fill"
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "pencil"
        case "Write": return "square.and.pencil"
        case "Read": return "doc.text.fill"
        case "Glob", "Grep": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "sparkles"
        case "AskUserQuestion": return "questionmark.bubble.fill"
        case "ExitPlanMode": return "list.bullet.clipboard.fill"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    /// Where the call lands: the file it touches, else the folder the session runs in. Written the way a shell
    /// prompt would, so it is recognized rather than read.
    public var context: String? {
        guard let raw = path ?? cwd, !raw.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
    }

    /// The client's offer to stop asking. Native app approvals use the advertised persistent scope. Hooks take only a rule — an entry
    /// that changes the whole permission mode is a different decision than the one being made here, and one that
    /// quietly does nothing unless the session was started to allow it.
    /// A rule that cannot be read back is not offered: what it would allow is not something to agree to unseen.
    public var alwaysAllow: JSONValue? {
        switch nativeApproval {
        case .computerUseApp(let persist), .browserAccess(_, let persist):
            return persist.contains("always") ? .object(["persist": .string("always")]) : nil
        case .asynchronousQuestion, nil: break
        }
        guard source.supportsPermissionUpdates else { return nil }
        return suggestions.first {
            $0["type"].stringValue == "addRules" && $0["behavior"].stringValue == "allow" && Self.rules($0) != nil
        }
    }

    /// What always allowing adds, written the way the client's settings hold a rule, such as `Bash(npm test:*)`.
    public var alwaysAllowRule: String? {
        // For a website, always allowing adds the site itself to the browser's allowed ones.
        if case .browserAccess(let origin, _) = nativeApproval { return alwaysAllow == nil ? nil : origin }
        return alwaysAllow.flatMap(Self.rules)
    }

    public var allowLabel: String {
        switch nativeApproval {
        case nil: return L10n.text("批准一次", "Allow once")
        // A website's answer is kept for the conversation only when the request offers that.
        case .browserAccess(_, let persist) where !persist.contains("session"): return L10n.text("批准一次", "Allow once")
        default: return L10n.text("允许此对话", "Allow this conversation")
        }
    }

    /// The rules a suggestion adds, in the client's own notation and order; nil unless every one names its tool.
    static func rules(_ suggestion: JSONValue) -> String? {
        guard let rules = suggestion["rules"].arrayValue, !rules.isEmpty else { return nil }
        let written = rules.compactMap { rule -> String? in
            guard let tool = rule["toolName"].stringValue, !tool.isEmpty else { return nil }
            guard let content = rule["ruleContent"].stringValue, !content.isEmpty else { return tool }
            return "\(tool)(\(content))"
        }
        return written.count == rules.count ? written.joined(separator: ", ") : nil
    }

    static let detailLength = 2048
    static let fileTools: Set<String> = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Qwen Code's names for the tools Claude Code has, whose inputs use the same keys; a call reads the same
    /// whichever client makes it.
    static let aliases = ["run_command": "Bash", "run_shell_command": "Bash", "edit": "Edit", "replace": "Edit", "write_file": "Write",
                          "read_file": "Read", "glob": "Glob", "grep_search": "Grep", "search_file_content": "Grep",
                          "web_fetch": "WebFetch", "web_search": "WebSearch", "agent": "Agent", "task": "Task"]
    static func kind(_ tool: String) -> String { aliases[tool] ?? tool }

    /// Reads a client's hook payload. A payload without a session cannot be shown next to the session it belongs to,
    /// and is refused rather than guessed at; so is a call that asks the user something the HUD cannot answer, and a
    /// question it cannot read in full.
    static func parse(_ data: Data, source: PermissionHooks.Source, id: String, now: Date) throws -> PermissionRequest? {
        guard data.count <= 1024 * 1024 else { throw ProviderFailure.limit }
        let payload = try ProviderJSON.read(data)
        guard let session = payload["session_id"].stringValue, !session.isEmpty else { return nil }
        let tool = payload["tool_name"].stringValue
        guard !source.unanswerableTools.contains(tool ?? "") else { return nil }
        let input = payload["tool_input"]
        let kind = tool.map(kind)
        let questions = kind == PermissionQuestion.tool ? PermissionQuestion.read(input["questions"]) : []
        guard kind != PermissionQuestion.tool || !questions.isEmpty else { return nil }
        let file = fileTools.contains(kind ?? "") ? filePath(input) : nil
        // A multi-edit is recognized by its first change, the same way a single edit is. Only a file tool's input is an
        // edit: another tool's `content` is an argument like any other.
        let change = kind == "MultiEdit" ? input["edits"].arrayValue?.first ?? .null : file == nil ? .null : input
        return PermissionRequest(
            id: id, source: source, sessionID: source.sessionID(session), toolName: tool,
            summary: questions.first?.question ?? summary(tool: kind, input: input), detail: detail(tool: kind, input: input),
            cwd: payload["cwd"].stringValue, path: file,
            // A new file has no old side; its content is the new one, as a notebook cell's source is.
            removed: lines(change["old_string"]),
            added: lines(change["new_string"]) ?? lines(change["content"]) ?? lines(change["new_source"]),
            suggestions: payload["permission_suggestions"].arrayValue ?? [],
            questions: questions, answerInput: questions.isEmpty && kind != planTool ? nil : input, at: now
        )
    }

    /// What the call is about, in the words the tool itself uses. Known hook tool names are matched; anything
    /// else falls back to the tool's name, which is all a request for an unknown tool can honestly say.
    static func summary(tool: String?, input: ProviderJSON) -> String {
        guard let tool, !tool.isEmpty else { return L10n.text("工具调用", "Tool call") }
        switch tool {
        case "Bash", "BashOutput", "KillShell":
            return trimmed(input["description"]) ?? trimmed(input["command"]) ?? tool
        case "apply_patch":
            return trimmed(input["description"]) ?? L10n.text("应用文件修改", "Apply file changes")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return filePath(input).map { ($0 as NSString).lastPathComponent } ?? tool
        case "Glob", "Grep":
            return trimmed(input["pattern"]) ?? tool
        case "WebFetch":
            return trimmed(input["url"]) ?? tool
        case "WebSearch":
            return trimmed(input["query"]) ?? tool
        case "Task", "Agent":
            return trimmed(input["description"]) ?? tool
        case planTool:
            // A plan opens with its title; the heading marks are not part of it.
            let title = input["plan"].stringValue?.split(separator: "\n").lazy
                .map { $0.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            return title.map { String($0.prefix(detailLength)) } ?? L10n.text("计划", "Plan")
        default:
            // An MCP tool is named mcp__<server>__<tool>; the last two parts are what the user recognizes.
            guard tool.hasPrefix("mcp__") else { return tool }
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            return parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : tool
        }
    }

    /// The exact subject of the call: the command, the file, the URL or the plan, and for any other call its input — an
    /// MCP tool's arguments, a search's pattern and folder. It is kept when the summary says the same, since the summary
    /// is one line and may be cut short.
    static func detail(tool: String?, input: ProviderJSON) -> String? {
        let value: String?
        switch tool {
        case "Bash", "apply_patch": value = trimmed(input["command"])
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": value = filePath(input)
        case "WebFetch": value = trimmed(input["url"])
        case planTool: value = trimmed(input["plan"])
        // A question shows itself, one question at a time.
        case PermissionQuestion.tool: return nil
        default: value = nil
        }
        return (value ?? arguments(input)).map { String($0.prefix(detailLength)) }
    }

    /// A call's input one argument to a line, sorted by name: text as written, anything else as JSON.
    static func arguments(_ input: ProviderJSON) -> String? {
        guard let fields = input.objectValue, !fields.isEmpty else { return nil }
        return fields.sorted { $0.key < $1.key }.map { name, value in
            let text = value.stringValue ?? (try? RecordCoding.encoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
            return "\(name): \(text ?? "")"
        }.joined(separator: "\n")
    }

    /// The file a file tool works on. A notebook edit names its notebook under a key of its own.
    private static func filePath(_ input: ProviderJSON) -> String? {
        trimmed(input["file_path"]) ?? trimmed(input["notebook_path"])
    }

    /// One side of an edit, capped at what fits on a card: the point is to recognize the change, not to review it.
    static let diffLines = 6
    static func lines(_ value: ProviderJSON) -> String? {
        guard let text = value.stringValue, !text.isEmpty else { return nil }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(diffLines)
        return kept.joined(separator: "\n")
    }

    private static func trimmed(_ value: ProviderJSON) -> String? {
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(detailLength))
    }
}

/// One question a client asks its user, with the answers it offers. The user can always answer in their own words
/// instead, the way the client's own dialog lets them.
public struct PermissionQuestion: Equatable, Sendable {
    /// Choices and the user's own words stay separate until the client's wire format is written.
    public struct Answer: Equatable, Sendable {
        public let selected: [String]
        public let custom: String?

        public init(selected: [String] = [], custom: String? = nil) {
            self.selected = selected
            self.custom = custom
        }

        /// Hook clients file one string under each question's text.
        public var text: String { (selected + (custom.map { [$0] } ?? [])).joined(separator: ", ") }
    }

    public struct Option: Equatable, Sendable {
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    /// A native client's stable question identity; hook clients name answers by the question text.
    public let id: String?
    public var answerKey: String { id ?? question }
    /// The question in full, kept exactly as the client wrote it.
    public let question: String
    /// A word or two naming the question.
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    public init(id: String? = nil, question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The tool Claude Code asks its questions with.
    static let tool = "AskUserQuestion"

    /// Reads the questions a call asks. Answers go back as a set, so a list with one question the HUD cannot read is
    /// left whole to the client's own dialog rather than answered in part.
    static func read(_ value: JSONValue) -> [PermissionQuestion] {
        guard let list = value.arrayValue, !list.isEmpty else { return [] }
        let questions = list.compactMap { item -> PermissionQuestion? in
            guard let text = item["question"].stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let options = (item["options"].arrayValue ?? []).compactMap { option -> Option? in
                guard let label = option["label"].stringValue, !label.isEmpty else { return nil }
                return Option(label: label, description: option["description"].stringValue.flatMap { $0.isEmpty ? nil : $0 })
            }
            guard !options.isEmpty else { return nil }
            return PermissionQuestion(id: item["id"].stringValue, question: text, header: item["header"].stringValue.flatMap { $0.isEmpty ? nil : $0 },
                                      options: options, multiSelect: item["multiSelect"].boolValue ?? false)
        }
        return questions.count == list.count ? questions : []
    }
}

/// What the user decided, in the shape the client reads it in.
///
/// The allow/deny answer is shared; permission-rule updates are available only on supporting clients.
/// Saying nothing is its own answer:
/// the client then does what it would have done without the hook, which is to ask in its own terminal.
public enum PermissionDecision: Sendable, Equatable {
    case allow
    case deny
    /// Allow, and apply what the client offered so it stops asking about calls like this one.
    case allowAlways(JSONValue)
    /// Each answer is filed under its question's answerKey. A question skipped has no entry.
    case answer([String: PermissionQuestion.Answer])
    /// Approve a plan. With `acceptEdits` the session then accepts file edits without asking, as Claude Code's own
    /// choice does; without it every edit is still asked about.
    case approvePlan(acceptEdits: Bool)
    /// Send a plan back to be worked on, with what the user wants changed, if they said.
    case keepPlanning(String?)
    /// Say nothing: the request leaves the HUD and the client carries on with its own dialog, as though the HUD had
    /// never been asked.
    case leave

    var behavior: String {
        switch self {
        case .deny, .keepPlanning: return "deny"
        default: return "allow"
        }
    }

    public func response(for source: PermissionHooks.Source) -> Data {
        guard source.usesHook else { return Self.noDecision }
        var decision: [String: JSONValue] = ["behavior": .string(behavior)]
        switch self {
        case .allowAlways(let update):
            // Codex rejects updatedPermissions. Leave unsupported decisions to the client's own approval flow.
            guard source.supportsPermissionUpdates else { return Self.noDecision }
            decision["updatedPermissions"] = .array([update])
        case .answer, .approvePlan, .keepPlanning, .leave:
            // Answers travel inside the question or plan they answer; without it there is nothing to send.
            return Self.noDecision
        case .allow, .deny:
            break
        }
        return Self.encode(decision)
    }

    /// The answer for this request. A question's answers go back as the call's own input with the answers filled
    /// in, which is how Claude Code hears what its user chose; a question left out is one the user skipped, and with
    /// none answered Claude Code hears that its questions went unanswered.
    public func response(for request: PermissionRequest) -> Data {
        guard request.nativeApproval == nil else { return Self.noDecision }
        switch self {
        case .approvePlan(let acceptEdits):
            // Claude Code ignores a bare allow on a plan: the plan comes back as the call's input, and accepting edits
            // is the mode the session moves to (verified on Claude Code 2.1.300).
            guard request.answersPlan, let input = request.answerInput else { return Self.noDecision }
            var decision: [String: JSONValue] = ["behavior": .string("allow"), "updatedInput": input]
            if acceptEdits {
                decision["updatedPermissions"] = .array([.object(["type": .string("setMode"), "mode": .string("acceptEdits"),
                                                                  "destination": .string("session")])])
            }
            return Self.encode(decision)
        case .keepPlanning(let note):
            guard request.answersPlan else { return Self.noDecision }
            return Self.encode(["behavior": .string("deny"), "message": .string(Self.planFeedback(note))])
        case .answer:
            break
        default:
            return response(for: request.source)
        }
        guard case .answer(let answers) = self, var input = request.answerInput?.objectValue else { return Self.noDecision }
        var written: [String: JSONValue] = [:]
        for question in request.questions {
            if let answer = answers[question.answerKey] { written[question.question] = .string(answer.text) }
        }
        input["answers"] = .object(written)
        return Self.encode(["behavior": .string("allow"), "updatedInput": .object(input)])
    }

    /// What Claude reads when its plan is sent back. It is told the words are the user's: a refusal's message on its own
    /// reads as the hook's, and Claude then keeps the plan as it was.
    static func planFeedback(_ note: String?) -> String {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reviewed = "The user reviewed this plan in Agent HUD and did not approve it."
        return note.isEmpty ? reviewed + " They want to keep planning." : reviewed + " Their feedback: " + note
    }

    private static func encode(_ decision: [String: JSONValue]) -> Data {
        let payload: [String: JSONValue] = [
            "hookSpecificOutput": .object([
                "hookEventName": .string("PermissionRequest"),
                "decision": .object(decision),
            ])
        ]
        return (try? RecordCoding.encoder().encode(JSONValue.object(payload))) ?? Data()
    }

    /// No opinion. An empty answer leaves the permission flow exactly as it was, which is what a HUD that is closed,
    /// busy or switched off must look like.
    public static let noDecision = Data()
}

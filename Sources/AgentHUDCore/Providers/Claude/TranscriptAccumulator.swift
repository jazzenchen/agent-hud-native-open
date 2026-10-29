import AgentHUDSupport
import Foundation

/// Mutable builder that ingests events (possibly in several batches) and produces a `TranscriptSession`.
/// Codable so the transcript store can persist it between runs; token events themselves go to the usage ledger.
public struct TranscriptAccumulator: Hashable, Sendable, Codable {
    public let path: String
    public let isSubagent: Bool
    private var sessionId: String?
    private var cwd: String?
    private var startedAt: Date?
    private var lastActivityAt: Date?
    /// The first prompt's title, the latest name the user or the desktop app gave the session, and the latest title
    /// Claude Code generated for it.
    private var task: String?
    private var customTitle: String?
    private var generatedTitle: String?
    private var tokensIn = 0
    private var tokensOut = 0
    private var cacheReadTokens = 0
    private var outputByAgent: [String: Int] = [:]
    /// Keys of recently counted responses. Claude Code writes the lines of one response back to back.
    private var recentUsageKeys: [String] = []
    /// Usage lines without a response id, numbered so each keeps its own ledger key.
    private var unkeyedUsage = 0
    private var modelsSeen: [String: Date] = [:]
    private var entrypoint: String?
    private struct Turn: Hashable, Sendable, Codable {
        let startedAt: Date?
        var state: SessionTurn.State
        var observedAt: Date
        /// What the agent said, kept only while the app runs: the ledger stores no conversation text.
        var message: String?
        /// Why the turn ended, when the log said.
        var outcome: TurnOutcome?
        enum CodingKeys: String, CodingKey { case startedAt, state, observedAt, outcome }
    }
    private var currentTurn: Turn?
    /// What the main log says its turn is busy with: open calls, the kind of work they do, its newest line.
    private var activity: SessionActivity?
    private var completions: [SessionCompletion]?
    /// Prompts and compactions read since the store last took them.
    private var marks: [UsageLedger.Mark] = []
    /// The request side's latest line in this log — a prompt or a tool result — which times the reply that follows.
    private var requestAt: Date?

    /// A response that neither requests a tool nor was cut off ends the turn and returns control to the user.
    /// Interruptions leave no such line; API errors are synthetic messages without one.
    static let completedStopReasons: Set<String> = ["end_turn", "stop_sequence"]
    /// The errors of an API error message that mean a usage limit stopped the turn rather than a failure.
    static let limitErrors: Set<String> = ["rate_limit", "billing_error"]
    /// Enough for every turn a poll can observe; the notification tracker ignores older ones anyway.
    static let retainedCompletions = 32
    static let retainedUsageKeys = 512

    public init(path: String, isSubagent: Bool) {
        self.path = path
        self.isSubagent = isSubagent
    }

    /// Takes the titles `FastTranscriptParser.titles(in:)` read from the same lines as the next events.
    public mutating func noteTitles(custom: String?, generated: String?) {
        if let custom = SessionTitle.named(custom) { customTitle = custom }
        if let generated = SessionTitle.named(generated) { generatedTitle = generated }
    }

    /// Claude Code's own order: the name given to the session, then the generated title, then the first prompt.
    private var title: String? { customTitle ?? generatedTitle ?? task }

    /// The session a main log is named after; a sub-agent's log carries the session that started it. A forked session's
    /// log begins with a copy of its parent's lines, which keep the parent's session and times: they belong to the
    /// parent's own log, so this one skips them.
    var ownSession: String? {
        isSubagent ? nil : URL(fileURLWithPath: path, isDirectory: false).deletingPathExtension().lastPathComponent
    }

    /// Returns the usage these lines added, keyed by response so a repeated line never counts twice.
    @discardableResult
    public mutating func ingest(_ events: [TranscriptEvent]) -> [UsageLedger.Event] {
        var added: [UsageLedger.Event] = []
        let own = ownSession
        for event in events {
            if let own, let session = event.sessionId, session != own { continue }
            if sessionId == nil { sessionId = event.sessionId }
            if cwd == nil { cwd = event.cwd }
            if let entrypoint = event.entrypoint { self.entrypoint = entrypoint }
            startedAt = min(startedAt ?? event.timestamp, event.timestamp)
            lastActivityAt = max(lastActivityAt ?? event.timestamp, event.timestamp)
            if task == nil, event.role == .user, let text = event.text {
                task = SessionTitle.from(text)
            }
            // A reply's own span pairs it with the request side's latest line: a prompt or a tool result.
            if event.role == .user { requestAt = event.timestamp }
            // A sub-agent's own log follows its turn too, so its session can tell that the agent is still at work; only
            // a main log records prompts, compactions, completions and the answer.
            if isSubagent || !event.isSidechain {
                if !isSubagent, event.isCompaction { marks.append(.init(.compaction, at: event.timestamp)) }
                if !isSubagent { note(event) }
                if event.isPrompt {
                    // Claude Code records an interruption as a user line; that turn is over without a completion.
                    let interrupted = Self.isInterruption(event)
                    if !interrupted, !isSubagent { marks.append(.init(.prompt, at: event.timestamp)) }
                    if event.timestamp >= (currentTurn?.observedAt ?? .distantPast) {
                        currentTurn = Turn(startedAt: interrupted ? currentTurn?.startedAt : event.timestamp,
                            state: interrupted ? .ended : .running, observedAt: event.timestamp, outcome: interrupted ? .interrupted : nil)
                    }
                } else if let error = event.apiError {
                    // Claude Code writes a message in the model's place when the API failed, and the turn is over: held up
                    // by a usage limit until it lifts or the next prompt, or failed. No Stop hook summary follows it.
                    if (currentTurn?.state ?? .running) == .running, event.timestamp >= (currentTurn?.observedAt ?? .distantPast) {
                        currentTurn = Turn(startedAt: currentTurn?.startedAt, state: .ended, observedAt: event.timestamp,
                                           message: currentTurn?.message,
                                           outcome: Self.limitErrors.contains(error) ? .limited(resetsAt: event.limitResetsAt) : .failed)
                    }
                } else if event.role == .assistant, event.model != "<synthetic>" {
                    if let reason = event.stopReason, Self.completedStopReasons.contains(reason) {
                        var duplicate = false
                        if !isSubagent {
                            let completionID = RecordCoding.hash(["Claude", sessionId ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                event.messageId ?? String(RecordCoding.milliseconds(event.timestamp))])
                            duplicate = completions?.contains { $0.id == completionID } == true
                            recordCompletion(event)
                        }
                        if !duplicate, event.timestamp >= (currentTurn?.observedAt ?? .distantPast) {
                            currentTurn = Turn(startedAt: currentTurn?.startedAt, state: .completed, observedAt: event.timestamp,
                                               message: currentTurn?.message, outcome: .completed)
                        }
                    } else if isSubagent, event.returnsStructuredOutput, event.timestamp >= (currentTurn?.observedAt ?? .distantPast) {
                        // A workflow agent hands back its result and stops without an end_turn.
                        currentTurn = Turn(startedAt: currentTurn?.startedAt, state: .completed, observedAt: event.timestamp,
                                           outcome: .completed)
                    } else if currentTurn == nil {
                        // A partial legacy transcript can show work, but cannot invent a prompt start time.
                        currentTurn = Turn(startedAt: nil, state: .running, observedAt: event.timestamp)
                    } else if currentTurn?.state != .running, event.timestamp > currentTurn!.observedAt {
                        // Claude Code woke the agent without a prompt: a sub-agent's report, a queued notification or a
                        // Stop hook's feedback. The turn that stopped is being worked on again, and has not ended yet.
                        currentTurn?.state = .running
                        currentTurn?.outcome = nil
                    }
                } else if event.endsTurn, currentTurn?.state == .running, event.timestamp >= currentTurn!.observedAt {
                    // A tool that ends the turn, as the desktop app's next-step box does, leaves no answer and no Stop hook
                    // summary after its result: the result is the turn's last line.
                    currentTurn = Turn(startedAt: currentTurn?.startedAt, state: .completed, observedAt: event.timestamp,
                                       message: currentTurn?.message, outcome: .completed)
                } else if event.isStop, currentTurn?.state == .running, event.timestamp >= currentTurn!.observedAt {
                    // Claude Code ran the Stop hooks or timed the turn once the agent stopped: a turn no end_turn
                    // completed, such as one whose answer was cut off or failed, is over as well.
                    currentTurn = Turn(startedAt: currentTurn?.startedAt, state: .completed, observedAt: event.timestamp,
                                       message: currentTurn?.message)
                }
                // Only the conversation dates a running turn. An attachment or queue record can carry a later time than
                // the answer written after it, which would then look older than the turn and leave it running.
                if currentTurn?.state == .running, event.role != .other, event.timestamp > currentTurn!.observedAt {
                    currentTurn?.observedAt = event.timestamp
                }
                // The visible answer, taken from whichever block carried it last.
                if !isSubagent, event.role == .assistant, event.model != "<synthetic>",
                   let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    currentTurn?.message = text
                }
            }
            guard event.hasUsage else { continue }
            let key: String
            if let usageKey = event.usageKey {
                // Same API response written as several lines: count its usage once.
                guard !recentUsageKeys.contains(usageKey) else { continue }
                recentUsageKeys.append(usageKey)
                if recentUsageKeys.count > Self.retainedUsageKeys { recentUsageKeys.removeFirst(recentUsageKeys.count - Self.retainedUsageKeys) }
                key = usageKey
            } else if let offset = event.offset {
                // Without a response id, the line's place in its log keys it, whichever page is read first.
                key = "o:\(offset)"
            } else {
                unkeyedUsage += 1
                key = "n:\(unkeyedUsage)"
            }
            let mapped = ClaudeModelMapper.agentId(for: event.model) ?? "claude-model:Unknown"
            tokensIn += event.tokensIn
            tokensOut += event.outputTokens
            cacheReadTokens += event.cacheReadTokens
            outputByAgent[mapped, default: 0] += event.outputTokens
            let model = String(mapped.dropFirst("claude-model:".count))
            if (modelsSeen[model] ?? .distantPast) < event.timestamp {
                modelsSeen[model] = event.timestamp
            }
            added.append(UsageLedger.Event(key: key, timestamp: event.timestamp, agentId: mapped, tokensIn: event.tokensIn,
                                           tokensOut: event.outputTokens, cacheReadTokens: event.cacheReadTokens,
                                           cacheWriteTokens: event.cacheCreationTokens, reasoningTokens: event.thinkingTokens,
                                           durationMs: requestAt.map { Int64(((event.timestamp.timeIntervalSince($0)) * 1000).rounded()) }
                                               .flatMap { $0 > 0 ? $0 : nil }))
        }
        activity?.settle()
        return added
    }

    /// An interruption, which Claude Code records as a user line of its own.
    static func isInterruption(_ event: TranscriptEvent) -> Bool { event.text?.hasPrefix("[Request interrupted") == true }

    /// Takes a main-log line into what the turn is busy with: a prompt that starts a turn starts it afresh, a call opens
    /// until its result comes back, along with what it asks the user in the client's own window, and the line says what the
    /// conversation's newest line is. Only a retry's own line says the client is retrying the API.
    private mutating func note(_ event: TranscriptEvent) {
        var activity = self.activity ?? SessionActivity()
        if event.isPrompt {
            guard event.timestamp >= (currentTurn?.observedAt ?? .distantPast) else { return }
            activity.startTurn()
            activity.line = Self.isInterruption(event) ? .context : .prompt
        } else if let id = event.toolUseID {
            var ask = event.ask
            ask?.offset = event.offset
            activity.open(id, work: event.toolName.flatMap(SessionActivity.work(ofTool:)), at: event.timestamp,
                          response: event.messageId, asking: ask)
            activity.line = .call
        } else if let id = event.toolResultID {
            activity.close(id, at: event.timestamp, failed: event.failed)
            // A result that ends the turn leaves the model nothing to go on with, as an answer does.
            activity.line = event.endsTurn ? .answer : .result
        } else if event.apiError != nil {
            activity.line = .error
        } else if event.role == .assistant, event.model != "<synthetic>" {
            activity.line = event.isThinking ? .thinking
                : event.stopReason.map(Self.completedStopReasons.contains) == true ? .answer : .text
        } else if event.role == .user {
            activity.line = .context
        }
        activity.retrying = event.retryAttempt != nil
        self.activity = activity
    }

    public var isEmpty: Bool { startedAt == nil }

    /// Takes what a log's first lines say about its session: its id, folder, surface and start, and its first prompt as
    /// the title, counting none of their usage. A page of history read later carries these before its own lines.
    public mutating func readHead(_ events: [TranscriptEvent]) {
        let own = ownSession
        for event in events where own == nil || event.sessionId == nil || event.sessionId == own {
            if sessionId == nil { sessionId = event.sessionId }
            if cwd == nil { cwd = event.cwd }
            if entrypoint == nil { entrypoint = event.entrypoint }
            startedAt = min(startedAt ?? event.timestamp, event.timestamp)
            if task == nil, event.role == .user, let text = event.text { task = SessionTitle.from(text) }
        }
    }

    /// Takes in what an older page of the same log read: its counts add up, its first prompt names the session, and the
    /// newest turn, titles and recent completions stay this summary's own where it has them.
    public mutating func merge(older: TranscriptAccumulator) {
        sessionId = sessionId ?? older.sessionId
        cwd = cwd ?? older.cwd
        entrypoint = entrypoint ?? older.entrypoint
        startedAt = [startedAt, older.startedAt].compactMap { $0 }.min()
        lastActivityAt = [lastActivityAt, older.lastActivityAt].compactMap { $0 }.max()
        task = older.task ?? task
        customTitle = customTitle ?? older.customTitle
        generatedTitle = generatedTitle ?? older.generatedTitle
        tokensIn += older.tokensIn
        tokensOut += older.tokensOut
        cacheReadTokens += older.cacheReadTokens
        outputByAgent.merge(older.outputByAgent, uniquingKeysWith: +)
        modelsSeen.merge(older.modelsSeen) { max($0, $1) }
        currentTurn = currentTurn ?? older.currentTurn
        activity = activity ?? older.activity
        if let earlier = older.completions {
            let ids = Set((completions ?? []).map(\.id))
            completions = Array((earlier.filter { !ids.contains($0.id) } + (completions ?? [])).suffix(Self.retainedCompletions))
        }
    }

    /// Hands over the prompts and compactions read since the last call.
    public mutating func drainMarks() -> [UsageLedger.Mark] {
        defer { marks = [] }
        return marks
    }

    private mutating func recordCompletion(_ event: TranscriptEvent) {
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let completion = SessionCompletion(
            sessionID: sessionId ?? fileName, vendor: "Claude",
            turnID: event.messageId ?? String(RecordCoding.milliseconds(event.timestamp)),
            task: title ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code",
            model: event.model.map { ClaudeModelInfo.parse($0)?.displayName ?? $0 } ?? "Claude",
            startedAt: currentTurn?.state == .running ? currentTurn?.startedAt : nil, completedAt: event.timestamp
        )
        // Claude Code writes one line per content block, and every line carries the message's stop reason.
        if let index = completions?.firstIndex(where: { $0.id == completion.id }), let previous = completions?[index] {
            // Thinking and text blocks share an ID but can have timestamps tens of seconds apart.
            // Preserve the original prompt even when later blocks arrive in a subsequent indexing batch.
            if completion.completedAt > previous.completedAt {
                completions?[index] = SessionCompletion(
                    sessionID: completion.sessionID, vendor: completion.vendor,
                    turnID: event.messageId ?? String(RecordCoding.milliseconds(event.timestamp)),
                    task: previous.task, model: completion.model,
                    startedAt: previous.startedAt, completedAt: completion.completedAt
                )
            }
            return
        }
        completions = Array(((completions ?? []) + [completion]).suffix(Self.retainedCompletions))
    }

    /// Drops the recent response keys and old completions once a file can no longer receive appended lines, keeping
    /// the persisted state of thousands of finished sessions small.
    public mutating func compactIfFinished(now: Date, idleFor interval: TimeInterval = 86400) {
        guard let lastActivityAt, now.timeIntervalSince(lastActivityAt) > interval,
              !recentUsageKeys.isEmpty || completions != nil else { return }
        recentUsageKeys.removeAll()
        completions = nil
    }

    public func build() -> TranscriptSession? {
        guard let startedAt, let lastActivityAt else { return nil }
        let dominant = outputByAgent.max { $0.value < $1.value }?.key ?? "claude-model:Unknown"
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return TranscriptSession(
            id: sessionId ?? fileName,
            path: path,
            cwd: cwd,
            isSubagent: isSubagent,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            task: title,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            cacheReadTokens: cacheReadTokens,
            dominantAgentId: dominant,
            modelsSeen: modelsSeen,
            entrypoint: entrypoint,
            completions: completions ?? [],
            turn: currentTurn.map { turn in
                SessionTurn(provider: "claude", sessionID: sessionId ?? fileName,
                    turnID: String(RecordCoding.milliseconds(turn.startedAt ?? turn.observedAt)), state: turn.state,
                    startedAtMs: turn.startedAt.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(turn.observedAt),
                    message: turn.message, outcome: turn.outcome)
            },
            activity: isSubagent ? nil : activity
        )
    }
}

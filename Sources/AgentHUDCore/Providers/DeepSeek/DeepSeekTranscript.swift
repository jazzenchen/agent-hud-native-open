import AgentHUDSupport
import Foundation

/// Summary of Harness session logs in formats 0 and 2–4. Only metadata and token counters survive indexing.
public struct DeepSeekTranscript: Codable, Sendable {
    public struct Usage: Codable, Sendable {
        public let timestamp: Date
        public let requestedAt: Date
        public let provider: String
        public let model: String
        public let input: Int
        public let cachedInput: Int
        public let output: Int
        /// The part of `input` written to the cache and the part of `output` spent reasoning.
        public var cacheWrite = 0
        public var reasoning = 0

        public var event: UsageEvent {
            .init(timestamp: timestamp, agentId: "deepseek-model:\(model)", tokensIn: input, tokensOut: output, cacheReadTokens: cachedInput,
                  cacheWriteTokens: cacheWrite, reasoningTokens: reasoning)
        }
    }

    public private(set) var id: String?
    public private(set) var cwd: String?
    public private(set) var startedAt: Date?
    public private(set) var lastActivityAt: Date?
    public private(set) var title: String?
    public private(set) var model = "Unknown"
    private var provider = "Unknown"
    private var requestedAt: Date?
    public private(set) var isSubagent = false
    /// Usage read since the store last recorded it in the ledger; the totals below cover the whole log.
    public private(set) var usage: [Usage] = []
    /// The ledger key of each pending usage entry: one per attempt, so a later chunk of the attempt corrects it.
    private var usageKeys: [String] = []
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var cachedInputTokens = 0
    /// Models that reported usage in this log.
    public private(set) var models: Set<String> = []
    private var attempts = 0
    /// The header's format version, absent from summaries stored before format 4 was read.
    private var format: Int?
    private var seedLength = 0
    /// The last tagged seed marker read before the cut.
    private var seedMarker: Int?
    /// Turn starts read since the store last took them.
    private var marks: [UsageLedger.Mark] = []
    private struct Turn: Codable, Sendable {
        let id: Int
        let startedAt: Date?
        var state: SessionTurn.State
        var observedAt: Date
        /// Why the turn ended, from its end's reason.
        var outcome: TurnOutcome?
    }
    private var turns: [Turn]?
    /// What the running turn is busy with: the tool calls still waiting for their result and the kind of work they do.
    public private(set) var activity: SessionActivity?
    public private(set) var completions: [SessionCompletion]?
    private var lastAttempt: Attempt?

    private struct Attempt: Codable {
        let turn: Int
        let step: Int
        let key: String
        var sample: Usage
    }

    public init() {}

    public mutating func ingest(_ line: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "session" {
            // Format 1 was never released; 2 embeds streams in settled events and 3 changes nothing read here. 4 renames
            // producer message sources but not a person's `user` prompts, and dates a fork's marker at its cut.
            guard let version = object["version"] as? Int, [0, 2, 3, 4].contains(version) else {
                throw UsageProviderError(L10n.text("不支持此 Harness 会话格式", "Unsupported Harness session format"))
            }
            guard let sessionId = object["id"] as? String, let created = object["createdAt"] as? Double else {
                throw UsageProviderError(L10n.text("Harness 会话头无效", "Invalid Harness session header"))
            }
            id = sessionId; cwd = object["cwd"] as? String; format = version
            startedAt = Date(timeIntervalSince1970: created / 1000)
            isSubagent = object["origin"] as? String == "subagent" || (object["delegationDepth"] as? Int ?? 0) > 0
            // A seeded format-2+ log stores no seed length; its cut is found at the fork's own marker below.
            seedLength = object["seedLength"] as? Int ?? (version >= 2 && object["isSeeded"] as? Bool == true ? .max : 0)
            return
        }
        // Packed streaming rows carry source timestamps, without requiring their text to be retained.
        if ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(type) {
            guard id != nil, let seq = object["seq0"] as? Int, let time = object["time0"] as? Double,
                  let data = object["data"] as? [String: Any], let gaps = data["dt"] as? [Double],
                  let turn = data["turn"] as? Int, seq + gaps.count >= seedLength else { return }
            observeTurn(at: Date(timeIntervalSince1970: (time + gaps.reduce(0, +)) / 1000), id: turn)
            return
        }
        guard id != nil, let seq = object["seq"] as? Int,
              let milliseconds = object["time"] as? Double, let data = object["data"] as? [String: Any] else { return }
        // Inherited requests establish the model but never contribute the parent's tokens or liveness.
        if type == "request/header", let config = (data["header"] as? [String: Any])?["config"] as? [String: Any],
           let value = config["model"] as? String {
            model = value
            provider = config["provider"] as? String ?? "Unknown"
        }
        if type == "request/context", let value = data["model"] as? String {
            model = value
            provider = data["provider"] as? String ?? "Unknown"
        }
        let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
        // The cut is the fork's own tagged end-seed, the last one; markers copied from ancestors are followed by more
        // inherited events, all older than the header. Before format 4 the fork dates its marker at its creation. Format 4
        // dates it, and the closers of a turn the fork cut open, at the last inherited event, so the fork's first event
        // from the header's time on settles the cut at the last marker read.
        if type == "session/end-seed", seq < seedLength, data["inherited"] as? Bool == true {
            seedMarker = seq
            if timestamp >= startedAt ?? .distantFuture { seedLength = seq }
        } else if seedLength == .max, (format ?? 0) >= 4, let seedMarker, timestamp >= startedAt ?? .distantFuture {
            seedLength = seedMarker
        }
        guard seq >= seedLength else { return }
        // A rename or seed marker must not make a finished task look active again.
        if type != "session/title" && type != "session/end-seed" {
            lastActivityAt = timestamp
            observeTurn(at: timestamp, id: data["turn"] as? Int)
        }
        switch type {
        case "turn/start":
            if !isSubagent { marks.append(.init(.prompt, at: timestamp)) }
            if let turn = data["turn"] as? Int, !(turns ?? []).contains(where: { $0.id == turn }),
               timestamp >= (turns?.last?.observedAt ?? .distantPast) {
                turns = Array(((turns ?? []) + [Turn(id: turn, startedAt: timestamp, state: .running, observedAt: timestamp)]).suffix(32))
                var started = activity ?? SessionActivity()
                started.startTurn()
                started.line = .prompt
                activity = started
            }
        case "step/start": requestedAt = timestamp
        case "tool/call":
            // A result names the calls it answers by their lines' places in the log.
            guard turns?.last?.state == .running else { break }
            var calling = activity ?? SessionActivity()
            calling.open(String(seq), work: (data["name"] as? String).flatMap(Self.work(ofTool:)), at: timestamp)
            calling.line = .call
            activity = calling
        case "tool/result":
            guard var answered = activity else { break }
            for call in object["sourceEventSeqs"] as? [Int] ?? [] { answered.close(String(call), at: timestamp) }
            answered.line = .result
            activity = answered
        case "turn/end":
            guard let turn = data["turn"] as? Int else { break }
            let reason = data["reason"] as? [String: Any]
            let completed = reason?["kind"] as? String == "completed"
            let finished = finishTurn(turn, state: completed ? .completed : .ended, outcome: Self.outcome(of: reason), at: timestamp)
            if !isSubagent, completed, let id {
                let completion = SessionCompletion(sessionID: "deepseek:\(id)", vendor: "DeepSeek", turnID: String(seq),
                    task: title ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "DeepSeek Harness",
                    model: model, startedAt: finished?.startedAt, completedAt: timestamp)
                if completions?.contains(where: { $0.id == completion.id }) != true {
                    completions = (completions ?? []) + [completion]
                }
            }
        case "session/end-seed": turns = nil
        case "session/title":
            if let text = data["title"] as? String { title = SessionTitle.from(text) }
        case "user/message":
            if title == nil, (data["source"] as? [String: Any])?["kind"] as? String == "user",
               let content = data["content"] as? [[String: Any]],
               let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                title = SessionTitle.from(text)
            }
        case "llm/retry-started":
            if lastAttempt?.turn == data["turn"] as? Int && lastAttempt?.step == data["step"] as? Int { lastAttempt = nil }
            requestedAt = timestamp
        case "assistant/chunk", "assistant/message", "assistant/attempt":
            // Format 0 logs usage chunks as events; later formats embed the stream in the settled message or failed attempt.
            let chunks = ((data["stream"] as? [[String: Any]])?.map { $0["chunk"] } ?? [data["chunk"]]).compactMap { $0 as? [String: Any] }
            let counters = data["usage"] as? [String: Any] ?? chunks.last { $0["type"] as? String == "usage" }?["usage"] as? [String: Any]
            guard let counters, let input = counters["inputTokens"] as? Int, input >= 0,
                  let output = counters["outputTokens"] as? Int, output >= 0,
                  let turn = data["turn"] as? Int, let step = data["step"] as? Int else { return }
            // Harness already excludes cache hits from inputTokens. Match HUD's fresh-input convention.
            // Reasoning is included in outputTokens; chunks and their final message report one attempt.
            let written = max(0, counters["cacheWriteTokens"] as? Int ?? 0)
            var sample = Usage(timestamp: timestamp, requestedAt: requestedAt ?? timestamp, provider: provider, model: model,
                               input: input + written, cachedInput: max(0, counters["cacheReadTokens"] as? Int ?? 0), output: output)
            sample.cacheWrite = written
            sample.reasoning = max(0, counters["reasoningTokens"] as? Int ?? 0)
            if type != "assistant/attempt", var previous = lastAttempt, previous.turn == turn, previous.step == step {
                count(previous.sample, sign: -1)
                previous.sample = sample
                lastAttempt = previous
                if let index = usageKeys.lastIndex(of: previous.key) { usage[index] = sample }
                else { usage.append(sample); usageKeys.append(previous.key) }
            } else {
                attempts += 1
                // A failed attempt is settled; the next attempt of its step counts separately.
                lastAttempt = type == "assistant/attempt" ? nil : Attempt(turn: turn, step: step, key: "a\(attempts)", sample: sample)
                usage.append(sample)
                usageKeys.append("a\(attempts)")
            }
            count(sample, sign: 1)
        default: break
        }
    }

    private mutating func count(_ sample: Usage, sign: Int) {
        inputTokens += sign * sample.input
        outputTokens += sign * sample.output
        cachedInputTokens += sign * sample.cachedInput
        if sign > 0 { models.insert(sample.model) }
    }

    /// Hands the usage read since the last call to the ledger with its estimated price.
    mutating func drainUsage() -> [UsageLedger.Event] {
        defer {
            usage = []
            usageKeys = []
        }
        return zip(usageKeys, usage).map { key, sample in
            let costs = Dictionary(uniqueKeysWithValues: ["CNY", "USD"].compactMap { currency in
                DeepSeekPricing.estimate(sample, currency: currency).map { (currency, $0) }
            })
            return UsageLedger.Event(key: key, timestamp: sample.timestamp, agentId: "deepseek-model:\(sample.model)",
                                     tokensIn: sample.input, tokensOut: sample.output, cacheReadTokens: sample.cachedInput,
                                     cacheWriteTokens: sample.cacheWrite, reasoningTokens: sample.reasoning,
                                     billingID: "DeepSeek", costs: costs)
        }
    }

    /// Hands over the turn starts read since the last call.
    mutating func drainMarks() -> [UsageLedger.Mark] {
        defer { marks = [] }
        return marks
    }

    public var sessionTurns: [SessionTurn] {
        guard let id, !isSubagent else { return [] }
        return (turns ?? []).map { turn in
            SessionTurn(provider: "deepseek", sessionID: "deepseek:\(id)", turnID: String(turn.id), state: turn.state,
                        startedAtMs: turn.startedAt.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(turn.observedAt),
                        outcome: turn.outcome)
        }
    }

    private mutating func observeTurn(at date: Date, id: Int?) {
        guard let index = turns?.indices.last, turns?[index].state == .running,
              id == nil || turns?[index].id == id, date > turns![index].observedAt else { return }
        turns?[index].observedAt = date
        lastActivityAt = max(lastActivityAt ?? date, date)
    }

    private mutating func finishTurn(_ id: Int, state: SessionTurn.State, outcome: TurnOutcome?, at date: Date) -> Turn? {
        if let index = turns?.lastIndex(where: { $0.id == id }) {
            guard date >= turns![index].observedAt, turns?[index].state == .running else { return turns?[index] }
            turns?[index].state = state; turns?[index].observedAt = date; turns?[index].outcome = outcome
            if index == turns!.indices.last { activity?.endTurn() }
            return turns?[index]
        }
        guard turns?.last?.state != .running else { return nil }
        let value = Turn(id: id, startedAt: nil, state: state, observedAt: date, outcome: outcome)
        turns = Array(((turns ?? []) + [value]).suffix(32))
        return value
    }

    /// How a turn's end reason ended it: completed, or an error, which a rate limit makes a limit. Harness names no other
    /// reason this Mac has seen, so any other ends the turn without one.
    static func outcome(of reason: [String: Any]?) -> TurnOutcome? {
        switch reason?["kind"] as? String {
        case "completed": return .completed
        case "error": return (reason?["error"] as? [String: Any])?["code"] as? String == "RATE_LIMIT" ? .limited(resetsAt: nil) : .failed
        default: return nil
        }
    }

    /// What a Harness tool call does, by its tool's name; nil for a tool no group names, such as its to-do list.
    static func work(ofTool name: String) -> SessionActivity.Work? {
        switch name {
        case "bash", "job_output": return .shell
        case "edit", "write": return .edit
        case "read", "read_image", "grep", "glob", "web_fetch", "web_search": return .read
        case "subagent", "send_message", "list_agents": return .agents
        case "ask_user_question": return .question
        default: return name.hasPrefix("mcp__") ? .command : nil
        }
    }

    /// Ends one read of the log (`SessionActivity.settle()`).
    mutating func settleActivity() { activity?.settle() }

    /// Whether this log has its session in flight, by the process rule of `SessionPhase.read(_:rule:at:)`.
    /// `processStarts` is the process table, nil when it was not read.
    public func isLive(processStarts: [Date]?) -> Bool {
        // The process rule reads no clock.
        SessionPhase.read(evidence(processStarts: processStarts), rule: .process, at: Date()).inFlight
    }

    /// What this log says about its session: its newest turn, when it last recorded an event, and, when the process table
    /// was read at `checkedAt`, whether a process there predates the turn. A newer process cannot own an older turn, so a
    /// turn none of them predates has lost its harness.
    func evidence(processStarts: [Date]?, checkedAt: Date? = nil) -> SessionPhase.SourceEvidence {
        let newest = turns?.last
        return SessionPhase.SourceEvidence(turn: newest.map { turn in
            SessionTurn(provider: "deepseek", sessionID: "deepseek:\(id ?? "")", turnID: String(turn.id), state: turn.state,
                        startedAtMs: turn.startedAt.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(turn.observedAt),
                        outcome: turn.outcome)
        }, lastWriteAt: lastActivityAt, processOutlivesTurn: processStarts.map { starts in
            // `turn/start` opens every turn, so a running one always has a start.
            starts.contains { $0 <= newest?.startedAt ?? .distantPast }
        }, processCheckedAt: processStarts == nil ? nil : checkedAt)
    }
}

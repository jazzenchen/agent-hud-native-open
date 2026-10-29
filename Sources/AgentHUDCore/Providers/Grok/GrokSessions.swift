import AgentHUDSupport
import Foundation

// Recorded Grok schemas and source precedence follow Tokscale grok.rs (MIT).
enum GrokSessions: LocalSessionLayout {
    static let installPaths = [".grok"]

    static func directory(home: URL, environment: [String: String]) -> URL {
        ClientHome.variable("GROK_HOME", in: environment).map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".grok")
    }

    static func roots(home: URL, environment: [String: String]) -> [URL] {
        let base = directory(home: home, environment: environment)
        return [base.appendingPathComponent("sessions"), base.appendingPathComponent("logs")]
    }

    static func accepts(_ url: URL) -> Bool { url.lastPathComponent == "updates.jsonl" || url.lastPathComponent == "unified.jsonl" }

    static func related(_ url: URL) -> [URL] {
        url.lastPathComponent == "updates.jsonl" ? ["summary.json", "signals.json"].map { url.deletingLastPathComponent().appendingPathComponent($0) } : []
    }

    static func read(_ url: URL) throws -> ProviderSessions {
        url.lastPathComponent == "unified.jsonl" ? try unified(url) : try updates(url)
    }

    /// The inference log owns usage for the sessions it covers; their title, workspace, turns and completions still come
    /// from the session's updates log.
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] {
        let covered = Set(sessions.filter(isInference).map(\.id)), updates = updateLogs(sessions)
        return sessions.filter { isInference($0) || !covered.contains($0.id) }.map { item in
            guard isInference(item), let previous = updates[item.id] else { return item }
            var item = item
            item.title = previous.title; item.workspace = previous.workspace
            item.path = previous.path
            item.turns = previous.turns; item.completions = previous.completions
            item.startedAt = previous.startedAt
            item.lastActivity = [item.lastActivity, previous.lastActivity].compactMap { $0 }.max()
            return item
        }
    }

    static func notice(merging sessions: [ProviderSession]) -> String? {
        let inferenceStarts = Dictionary(sessions.filter(isInference).compactMap { session in
            session.events.map(\.timestamp).min().map { (session.id, $0) }
        }, uniquingKeysWith: min)
        guard sessions.contains(where: { session in
            guard session.path?.hasSuffix("/updates.jsonl") == true, let start = inferenceStarts[session.id] else { return false }
            return session.events.contains { $0.timestamp < start }
        }) else { return nil }
        return L10n.text("Grok 新旧日志并存：采用新版请求记录，旧历史可能不完整", "Grok log formats overlap: using inference records; older history may be incomplete")
    }

    private static func isInference(_ session: ProviderSession) -> Bool { session.path?.hasSuffix("/unified.jsonl") == true }

    /// The first session of each id read from an updates log.
    private static func updateLogs(_ sessions: [ProviderSession]) -> [String: ProviderSession] {
        Dictionary(sessions.filter { $0.path?.hasSuffix("/updates.jsonl") == true }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func updates(_ url: URL) throws -> ProviderSessions {
        let directory = url.deletingLastPathComponent()
        let rawID = directory.lastPathComponent, id = "grok:\(rawID)"
        let workspace = directory.deletingLastPathComponent().lastPathComponent.removingPercentEncoding
        let summary = (try? ProviderFiles.json(directory.appendingPathComponent("summary.json"))) ?? .null
        var model = "Unknown"
        // Grok keeps a generated title current as the conversation goes on, and a `/rename` pins it.
        let title = SessionTitle.named(summary["generated_title"].stringValue) ?? SessionTitle.named(summary["title"].stringValue)
            ?? SessionTitle.named(summary["session_summary"].stringValue)
            ?? workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Grok CLI"
        var session = ProviderSession(id: id, title: title, workspace: workspace, path: url.path, client: "Grok CLI")
        var seen = Set<String>(), turnID: String?, turnStart: Date?, incomplete = false, hasContextOnly = false
        // The whole log is read each time, so the turn's newest call is the newest one this read brought in.
        var activity = SessionActivity()
        try ProviderFiles.lines(url) { json, line in
            guard let method = json["method"].stringValue,
                  method == "session/update" || method == "_x.ai/session/update" else { return }
            let params = json["params"], update = params["update"], meta = params["_meta"]
            guard params["sessionId"].stringValue == rawID else { throw ProviderFailure.format }
            guard let date = ProviderDate.milliseconds(meta["agentTimestampMs"]) else { return }
            let eventID = meta["eventId"].stringValue ?? "line-\(line)"
            guard seen.insert(eventID).inserted else { return }
            session.startedAt = min(session.startedAt ?? date, date)
            session.lastActivity = max(session.lastActivity ?? date, date)
            if let value = update["_meta"]["modelId"].stringValue ?? meta["modelId"].stringValue { model = value }
            let kind = update["sessionUpdate"].stringValue
            if kind == "user_message_chunk", turnID == nil {
                turnID = meta["promptId"].stringValue ?? eventID
                turnStart = ProviderDate.milliseconds(meta["turnStartMs"]) ?? date
                activity.startTurn()
                activity.line = .prompt
            }
            if turnID != nil, kind == "tool_call" || kind == "tool_call_update", let call = update["toolCallId"].stringValue {
                Self.note(call, update: update, isUpdate: kind == "tool_call_update", at: date, into: &activity)
            }
            // Older user updates lack a prompt id; the following agent/tool update supplies the client's real turn id.
            if let previous = turnID, let observed = meta["promptId"].stringValue, observed != previous {
                session.turns.removeAll { $0.turnID == previous }
                turnID = observed
            }
            if let turnID, kind == "user_message_chunk" || kind == "agent_message_chunk" || kind == "agent_thought_chunk" || kind == "tool_call" || kind == "tool_call_update" {
                session.turns.removeAll { $0.turnID == turnID }
                session.turns.append(.init(provider: "Grok", sessionID: id, turnID: turnID, state: .running,
                    startedAtMs: turnStart.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(date)))
            }
            guard kind == "turn_completed" else {
                if meta["totalTokens"].countValue ?? 0 > 0 { hasContextOnly = true }
                return
            }
            let usage = update["usage"]
            let usedModels = usage["modelUsage"].objectValue?.keys.sorted() ?? []
            if usedModels.count == 1 { model = usedModels[0] }
            if let input = usage["inputTokens"].countValue, let output = usage["outputTokens"].countValue {
                let cache = try (usage["cachedReadTokens"] == .null ? usage["cacheReadTokens"] : usage["cachedReadTokens"]).optionalCounter()
                guard cache <= input else { throw ProviderFailure.format }
                // The usage covers a whole turn, so the turn's own start to its completion is the honest span.
                session.events.append(.init(id: "\(id):\(eventID)", model: model, timestamp: date, input: input - cache, output: output, cacheRead: cache,
                    origin: .init(group: id, priority: 1),
                    durationMs: turnStart.map { Int((date.timeIntervalSince($0) * 1000).rounded()) }.flatMap { $0 > 0 ? $0 : nil }))
            } else { incomplete = true }
            let completedID = update["prompt_id"].stringValue ?? turnID ?? eventID
            if let turnID { session.turns.removeAll { $0.turnID == turnID } }
            session.turns.removeAll { $0.turnID == completedID }
            let succeeded = update["stop_reason"].stringValue == "end_turn"
            // A cancelled turn is the user's stop; one that stopped for any other reason ends without one.
            session.turns.append(.init(provider: "Grok", sessionID: id, turnID: completedID, state: succeeded ? .completed : .ended,
                startedAtMs: turnStart.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(date),
                outcome: succeeded ? .completed : update["stop_reason"].stringValue == "cancelled" ? .interrupted : nil))
            activity.endTurn()
            if succeeded {
                session.completions.append(.init(sessionID: id, vendor: "Grok", turnID: completedID, task: title,
                    model: model, startedAt: turnStart, completedAt: date, client: "Grok CLI"))
            }
            turnID = nil; turnStart = nil
        }
        activity.settle()
        session.activity = activity
        return ProviderSessions(sessions: [session], notice: incomplete || (hasContextOnly && session.events.isEmpty)
            ? L10n.text("部分 Grok 旧会话只有上下文计数，无法还原实际 Token 消耗", "Some older Grok sessions only report context size, not token consumption") : nil)
    }

    /// A tool call of a running turn, or an update of one: the call opens with what its kind or its tool says it does, an
    /// update that names a kind says it better, and one that says it finished closes it.
    private static func note(_ call: String, update: ProviderJSON, isUpdate: Bool, at date: Date, into activity: inout SessionActivity) {
        let status = update["status"].stringValue
        if status == "completed" || status == "failed" {
            activity.close(call, at: date)
            activity.line = .result
            return
        }
        let open = activity.calls.first { $0.id == call }
        guard !isUpdate || (open != nil && update["kind"].stringValue != nil) else { return }
        let tool = update["_meta"]["x.ai/tool"]
        activity.open(call, work: work(kind: update["kind"].stringValue ?? tool["kind"].stringValue,
                                       name: tool["name"].stringValue ?? update["title"].stringValue), at: open?.at ?? date)
        activity.line = .call
    }

    /// What a Grok tool call does, by the kind the agent protocol gives it, else by its tool's name; nil for any other.
    static func work(kind: String?, name: String?) -> SessionActivity.Work? {
        switch kind {
        case "execute": return .shell
        case "edit", "delete", "move": return .edit
        case "read", "search", "fetch", "list": return .read
        default: break
        }
        switch name {
        case "run_terminal_command": return .shell
        case "read_file", "list_dir", "grep", "glob", "web_fetch", "web_search": return .read
        case "edit_file", "write_file", "create_file", "search_replace": return .edit
        default: return nil
        }
    }

    /// The messages the inference log is read for, as quoted strings; the rest of the log is not decoded.
    private static let unifiedMessages = ["AuthManager::new", "model changed", "model catalog: notifying clients", "backend_search: model switch",
                                          "shell.turn.inference_done"].map { Data("\"\($0)\"".utf8) }

    static func unified(_ url: URL) throws -> ProviderSessions {
        var sessions: [String: ProviderSession] = [:], models: [String: String] = [:], seen = Set<String>()
        var generations: [Int: Int] = [:], processModels: [String: String] = [:], processSessions: [String: Set<String>] = [:]
        var pendingModels: [String: (process: String, model: String)] = [:]
        try ProviderFiles.lines(url, markers: unifiedMessages) { json, _ in
            let pid = json["pid"].countValue
            if json["msg"].stringValue == "AuthManager::new", let pid { generations[pid, default: 0] += 1; return }
            let process = pid.map { "\($0):\(generations[$0, default: 0])" }
            let context = json["ctx"]
            let changedModel: String?
            switch json["msg"].stringValue {
            case "model changed": changedModel = context["model"].stringValue
            case "model catalog: notifying clients": changedModel = context["current_model_id"].stringValue
            case "backend_search: model switch": changedModel = context["new_model"].stringValue
            default: changedModel = nil
            }
            if json["sid"].stringValue == nil, let process, let changedModel { processModels[process] = changedModel; return }
            guard let rawID = json["sid"].stringValue, !rawID.isEmpty else { return }
            let id = "grok:\(rawID)"
            // A model is scoped to the exact session and process that reported it; no parent-model guessing.
            let scope = id + ":" + (process ?? "")
            switch json["msg"].stringValue {
            case "model changed": models[scope] = context["model"].stringValue; return
            case "model catalog: notifying clients": models[scope] = context["current_model_id"].stringValue; return
            case "backend_search: model switch": models[scope] = context["new_model"].stringValue; return
            case "shell.turn.inference_done": break
            default: return
            }
            guard let date = DateParsing.internet(json["ts"].stringValue) ?? ProviderDate.milliseconds(json["ts"]),
                  let input = context["prompt_tokens"].countValue, let output = context["completion_tokens"].countValue else { throw ProviderFailure.format }
            let cache = try context["cached_prompt_tokens"].optionalCounter()
            guard cache <= input else { throw ProviderFailure.format }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let raw = String(decoding: try encoder.encode(json), as: UTF8.self)
            let eventID = json["event_id"].stringValue ?? json["eventId"].stringValue ?? context["event_id"].stringValue ?? RecordCoding.hash([raw])
            let identity = "\(id):unified:\(eventID)"
            guard seen.insert(identity).inserted else { return }
            let model = models[scope] ?? "Unknown"
            if let process {
                processSessions[process, default: []].insert(id)
                if model == "Unknown", let fallback = processModels[process] { pendingModels[identity] = (process, fallback) }
            }
            if sessions[id] == nil { sessions[id] = ProviderSession(id: id, title: "Grok · \(rawID.prefix(8))", path: url.path, client: "Grok CLI") }
            sessions[id]?.events.append(.init(id: identity, model: model, timestamp: date, input: input - cache, output: output, cacheRead: cache,
                origin: .init(group: id, priority: 2)))
        }
        return ProviderSessions(sessions: sessions.keys.sorted().compactMap { sessions[$0] }.map { session in
            var session = session
            session.events = session.events.map { event in
                guard let candidate = pendingModels[event.id], processSessions[candidate.process]?.count == 1 else { return event }
                return ProviderEvent(id: event.id, model: candidate.model, timestamp: event.timestamp,
                    input: event.input, output: event.output, cacheRead: event.cacheRead, origin: event.origin)
            }
            return session
        })
    }
}

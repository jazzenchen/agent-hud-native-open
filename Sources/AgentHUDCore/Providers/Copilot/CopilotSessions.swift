import AgentHUDSupport
import Foundation

// Shutdown snapshot differencing and OpenTelemetry chat-span fields follow Tokscale copilot_desktop.rs and copilot.rs (MIT).
enum CopilotSessions: LocalSessionLayout {
    // `~/.copilot` alone can hold only editor integration state.
    static let installPaths = [".copilot/session-state", ".copilot/config.json"]
    static let exporterVariable = "COPILOT_OTEL_FILE_EXPORTER_PATH"
    static let client = "Copilot CLI"
    private static let logTypes: Set<String> = ["session.start", "session.model_change", "user.message", "assistant.turn_start",
                                                "assistant.turn_end", "abort", "hook.start", "session.shutdown"]

    static func roots(home: URL, environment: [String: String]) -> [URL] {
        let base = ClientHome.variable("COPILOT_HOME", in: environment).map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".copilot")
        let otel = base.appendingPathComponent("otel")
        var roots = [base.appendingPathComponent("session-state"), otel]
        // An exporter file outside the otel directory is found by scanning only its own folder.
        if let path = ClientHome.variable(exporterVariable, in: environment) {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
            if !(folder.path + "/").hasPrefix(otel.standardizedFileURL.path + "/") { roots.append(folder) }
        }
        return roots
    }

    static func isLog(_ url: URL) -> Bool {
        url.lastPathComponent == "events.jsonl" && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "session-state"
    }

    static func accepts(_ url: URL) -> Bool {
        if isLog(url) { return true }
        guard url.pathExtension == "jsonl", !url.pathComponents.contains("session-state") else { return false }
        return url.pathComponents.contains("otel") || ClientHome.variable(exporterVariable, in: ProcessInfo.processInfo.environment)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path == url.standardizedFileURL.path } == true
    }

    /// Session folders keep checkpoints and file snapshots below them; only their top level matters.
    static func skips(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == false else { return false }
        let components = url.pathComponents
        if let index = components.lastIndex(of: "session-state") { return components.count - index > 2 }
        return !components.contains("otel")
    }

    static func related(_ url: URL) -> [URL] {
        isLog(url) ? [url.deletingLastPathComponent().appendingPathComponent("workspace.yaml")] : []
    }

    static func read(_ url: URL) throws -> ProviderSessions {
        isLog(url) ? try log(url) : try traces(url)
    }

    /// OpenTelemetry chat spans are per request, so they own a session's usage over its cumulative shutdown totals.
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] {
        var result: [String: ProviderSession] = [:], traced: [String: [String: ProviderEvent]] = [:]
        for item in sessions where item.path.map({ isLog(URL(fileURLWithPath: $0)) }) == true { result[item.id] = result[item.id] ?? item }
        for item in sessions where item.path.map({ isLog(URL(fileURLWithPath: $0)) }) != true {
            for event in item.events {
                if let old = traced[item.id]?[event.id], old.input + old.output + old.cacheRead >= event.input + event.output + event.cacheRead { continue }
                traced[item.id, default: [:]][event.id] = event
            }
            if result[item.id] == nil { result[item.id] = item }
        }
        for (id, events) in traced {
            guard var item = result[id] else { continue }
            item.events = events.values.sorted { $0.timestamp < $1.timestamp }
            let times = item.events.map(\.timestamp)
            item.startedAt = ([item.startedAt] + [times.min()]).compactMap { $0 }.min()
            item.lastActivity = ([item.lastActivity] + [times.max()]).compactMap { $0 }.max()
            result[id] = item
        }
        return result.keys.sorted().compactMap { result[$0] }
    }

    static func log(_ url: URL) throws -> ProviderSessions {
        let directory = url.deletingLastPathComponent(), id = "copilot:\(directory.lastPathComponent)"
        let metadata = workspace(directory.appendingPathComponent("workspace.yaml"))
        var session = ProviderSession(id: id, title: client, workspace: metadata["cwd"], path: url.path, client: client)
        var started = false, model: String?, snapshots: [(event: String, date: Date, key: String, model: String?, counts: [Int])] = []
        var active: (id: String, started: Int64, observed: Int64)?
        func concrete(_ value: ProviderJSON) -> String? { value.stringValue.flatMap { $0 == "auto" || $0.isEmpty ? nil : $0 } }
        func observe(_ state: SessionTurn.State, _ turn: (id: String, started: Int64, observed: Int64), outcome: TurnOutcome? = nil) {
            session.turns.removeAll { $0.turnID == turn.id }
            session.turns.append(.init(provider: AdditionalSource.copilot.vendor, sessionID: id, turnID: turn.id, state: state,
                                       startedAtMs: turn.started, observedAtMs: turn.observed, outcome: outcome))
        }
        try events(url, types: logTypes) { json in
            guard let type = json["type"].stringValue, let date = DateParsing.internet(json["timestamp"].stringValue) else { return }
            let ms = RecordCoding.milliseconds(date), data = json["data"], main = json["agentId"] == .null
            session.startedAt = min(session.startedAt ?? date, date)
            session.lastActivity = max(session.lastActivity ?? date, date)
            switch type {
            case "session.start":
                started = true
                session.workspace = data["context"]["cwd"].stringValue ?? session.workspace
                model = concrete(data["selectedModel"]) ?? model
            case "session.model_change":
                model = concrete(data["newModel"]) ?? model
            case "user.message", "assistant.turn_start", "assistant.turn_end":
                // Sub-agent loops and later iterations keep the prompt's turn alive; only a main-agent prompt or loop opens one.
                if var turn = active, type != "user.message" || ms - turn.observed < 120_000 {
                    turn.observed = ms; active = turn; observe(.running, turn)
                } else if main && type != "assistant.turn_end" {
                    let turn = (id: json["id"].stringValue ?? "at-\(ms)", started: ms, observed: ms)
                    active = turn; observe(.running, turn)
                }
            case "abort" where main:
                if var turn = active { turn.observed = ms; observe(.ended, turn, outcome: .interrupted); active = nil }
            case "hook.start" where main && data["hookType"].stringValue == "agentStop":
                // The stop's reason says how the agent ended; one that is neither an answer nor an error ends it without one.
                if var turn = active {
                    let reason = data["input"]["stopReason"].stringValue
                    turn.observed = ms
                    observe(reason == "end_turn" ? .completed : .ended, turn,
                            outcome: reason == "end_turn" ? .completed : reason == "error" ? .failed : nil)
                    active = nil
                }
            case "session.shutdown":
                if var turn = active { turn.observed = ms; observe(.ended, turn); active = nil }
                let current = concrete(data["currentModel"])
                for (raw, metric) in (data["modelMetrics"].objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let usage = metric["usage"], key = raw.trimmingCharacters(in: .whitespaces)
                    let counts = try ["inputTokens", "outputTokens", "cacheReadTokens"].map { try usage[$0].optionalCounter() }
                    snapshots.append((json["id"].stringValue ?? "at-\(ms)", date, key, key == "auto" || key.isEmpty ? current : key, counts))
                }
            default: break
            }
        }
        session.title = SessionTitle.named(metadata["name"]) ?? SessionTitle.named(metadata["summary"])
            ?? session.workspace.map { URL(fileURLWithPath: $0).lastPathComponent } ?? client
        // Each snapshot is the process's running total per model; a resumed session writes another one.
        var peaks: [String: [Int]] = [:], seen = Set<String>()
        for snapshot in snapshots.enumerated().sorted(by: { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }).map(\.element)
        where seen.insert(snapshot.event + "\u{0}" + snapshot.key).inserted {
            // Without the session start an earlier snapshot may be gone, so the first survivor is only a baseline.
            let baseline = peaks[snapshot.key] ?? (started ? [0, 0, 0] : nil)
            peaks[snapshot.key] = zip(peaks[snapshot.key] ?? snapshot.counts, snapshot.counts).map { max($0, $1) }
            guard let baseline else { continue }
            let input = max(0, snapshot.counts[0] - baseline[0]), output = max(0, snapshot.counts[1] - baseline[1])
            let cache = min(max(0, snapshot.counts[2] - baseline[2]), input)
            guard input > 0 || output > 0 else { continue }
            session.events.append(.init(id: "\(id):shutdown:\(snapshot.event):\(snapshot.key)", model: snapshot.model ?? model ?? snapshot.key,
                timestamp: snapshot.date, input: input - cache, output: output, cacheRead: cache, origin: .init(group: id, priority: 1)))
        }
        return ProviderSessions(sessions: [session])
    }

    static func traces(_ url: URL) throws -> ProviderSessions {
        struct Span { let identity: String; let trace: String?; let session: String?; let model: String?; let date: Date; let input, output, cache: Int }
        func text(_ value: ProviderJSON) -> String? { value.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        func identifier(_ value: ProviderJSON) -> String? { text(value).flatMap { $0.allSatisfy { $0 == "0" } ? nil : $0 } }
        func count(_ value: ProviderJSON) -> Int? { value.countValue ?? value.stringValue.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } }
        func time(_ value: ProviderJSON) -> Date? {
            guard let parts = value.arrayValue, parts.count == 2, let seconds = parts[0].numberValue, let nanos = parts[1].numberValue, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
        }
        var contexts: [String: (session: String?, model: String?)] = [:], spans: [Span] = []
        try ProviderFiles.lines(url) { json, _ in
            let attributes = json["attributes"]
            guard attributes.objectValue != nil else { return }
            let trace = identifier(json["traceId"]) ?? identifier(json["spanContext"]["traceId"])
            let session = text(attributes["gen_ai.conversation.id"])
            let model = text(attributes["gen_ai.response.model"]) ?? text(attributes["gen_ai.request.model"])
            if let trace {
                let known = contexts[trace]
                contexts[trace] = (known?.session ?? session, known?.model ?? model)
            }
            let name = json["name"].stringValue
            guard json["type"].stringValue.map({ $0 == "span" }) ?? (name != nil),
                  attributes["gen_ai.operation.name"].stringValue == "chat" || name?.hasPrefix("chat ") == true else { return }
            let input = count(attributes["gen_ai.usage.input_tokens"]), output = count(attributes["gen_ai.usage.output_tokens"])
            guard input != nil || output != nil, let date = time(json["startTime"]) ?? time(json["endTime"]) else { return }
            let cache = count(attributes["gen_ai.usage.cache_read.input_tokens"]) ?? count(attributes["gen_ai.usage.cache_read_input_tokens"]) ?? 0
            let span = identifier(json["spanId"]) ?? identifier(json["spanContext"]["spanId"])
            let identity: String
            if let trace, let span { identity = "\(trace):\(span)" }
            else if let response = text(attributes["gen_ai.response.id"]) { identity = "response:\(response)" }
            else { identity = RecordCoding.hash([String(decoding: try RecordCoding.encoder().encode(json), as: UTF8.self)]) }
            spans.append(Span(identity: identity, trace: trace, session: session, model: model, date: date, input: input ?? 0, output: output ?? 0, cache: cache))
        }
        var sessions: [String: ProviderSession] = [:]
        for span in spans {
            let context = span.trace.flatMap { contexts[$0] }
            guard let raw = span.session ?? context?.session else { continue }
            let id = "copilot:\(raw)"
            // Input tokens include cache reads; reasoning is already part of the output count.
            let event = ProviderEvent(id: "\(id):otel:\(span.identity)", model: span.model ?? context?.model ?? "Unknown", timestamp: span.date,
                input: max(0, span.input - span.cache), output: span.output, cacheRead: span.cache, origin: .init(group: id, priority: 2))
            var session = sessions[id] ?? ProviderSession(id: id, title: client, path: url.path, client: client)
            if let index = session.events.firstIndex(where: { $0.id == event.id }) {
                let old = session.events[index]
                if event.input + event.output + event.cacheRead > old.input + old.output + old.cacheRead { session.events[index] = event }
            } else { session.events.append(event) }
            session.startedAt = min(session.startedAt ?? span.date, span.date)
            session.lastActivity = max(session.lastActivity ?? span.date, span.date)
            sessions[id] = session
        }
        return ProviderSessions(sessions: sessions.keys.sorted().compactMap { sessions[$0] })
    }

    /// Top-level scalars of `workspace.yaml`, including the block scalar Copilot writes for a long name; nested values
    /// are not needed.
    static func workspace(_ url: URL) -> [String: String] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() where !(line.first?.isWhitespace ?? true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ["name", "summary", "cwd"].contains(key), !value.isEmpty else { continue }
            if let style = value.first, style == "|" || style == ">" {
                // The indented lines that follow, kept as lines (`|`) or folded into one (`>`).
                value = lines[(index + 1)...].prefix { $0.first?.isWhitespace ?? false }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: style == "|" ? "\n" : " ")
            } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
                value = quote == "'" ? value.replacingOccurrences(of: "''", with: "'")
                    : value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if !value.isEmpty { values[key] = value }
        }
        return values
    }

    /// Decodes only lines whose leading `type` is wanted, so tool output and message bodies stay unparsed.
    static func events(_ url: URL, types: Set<String>, consume: (ProviderJSON) throws -> Void) throws {
        let marker = Data(#""type":""#.utf8)
        func wanted(_ line: Data) -> Bool {
            guard let range = line.prefix(96).range(of: marker) else { return true }
            let rest = line[range.upperBound...].prefix(64)
            guard let end = rest.firstIndex(of: 34) else { return true }
            return types.contains(String(decoding: rest[rest.startIndex..<end], as: UTF8.self))
        }
        try ProviderFiles.lines(url, wanted: wanted) { json, _ in try consume(json) }
    }
}

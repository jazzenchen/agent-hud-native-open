import AgentHUDSupport
import Foundation

/// Pi's native lifecycle events are independent of its persisted message usage.
public enum PiSessionObserver {
    /// The first Pi release whose extensions hear `agent_settled`. Its changelog names 0.80.4, which was never published.
    public static let firstSettlingRelease = "0.80.5"

    private static func file(_ paths: OpenAgentPaths) -> ObserverFile {
        .init(url: paths.pi.appendingPathComponent("extensions/agent-hud.ts"), marker: "// Agent HUD Pi session observer\n",
              script: script, conflict: L10n.text("agent-hud.ts 已被其他扩展使用", "agent-hud.ts belongs to another extension"))
    }

    /// Pi's directory exists once Pi has run.
    static func isAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        FileManager.default.fileExists(atPath: OpenAgentPaths(home: home, environment: environment).pi.path)
    }

    /// Adapter setup is independent of the user's live-status presentation preference.
    public static func configureIfAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard isAvailable(home: home, environment: environment) else { return }
        try configure(enabled: true, home: home, environment: environment)
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        file(OpenAgentPaths(home: home, environment: environment)).isCurrent
    }

    public static func configure(enabled: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try file(OpenAgentPaths(home: home, environment: environment)).configure(enabled: enabled)
    }

    /// Whether the extension is in place, for Pi's settings.
    public static func fileState(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> ClientObserverFile {
        file(OpenAgentPaths(home: home, environment: environment)).state
    }

    /// The Pi version Pi last recorded, when it predates `agent_settled`: that Pi reports a run but never its completion.
    /// Pi records its version when an interactive session opens on a fresh install or after an update.
    public static func unsupportedVersion(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let url = OpenAgentPaths(home: home, environment: environment).pi.appendingPathComponent("settings.json")
        guard let version = (try? ProviderFiles.json(url))?["lastChangelogVersion"].stringValue, version.first?.isNumber == true,
              version.compare(firstSettlingRelease, options: .numeric) == .orderedAscending else { return nil }
        return version
    }

    struct Observation: Codable, Sendable {
        let version: Int
        let sessionID: String
        let sessionFile: String?
        let workspace: String
        let title: String
        let model: String?
        let providerID: String?
        let turnID: String
        let state: SessionTurn.State
        let startedAtMs: Int64
        let observedAtMs: Int64
        var navigationTarget: SessionNavigationTarget? = nil
        /// The stop reason of the run's last assistant message, written once the run settles; absent from extensions that
        /// predate it.
        var stopReason: String? = nil

        var turn: SessionTurn {
            .init(provider: "Pi", sessionID: sessionID, turnID: turnID, state: state,
                  startedAtMs: startedAtMs, observedAtMs: observedAtMs, outcome: outcome)
        }

        /// How the run ended, by Pi's stop reason: an abort is the user's stop and an error a failure. Pi says a usage
        /// limit only in an error's wording, so a limit is never told apart; a run that ended for any other reason, or
        /// whose session shut down, ends without one.
        var outcome: TurnOutcome? {
            switch state {
            case .completed: .completed
            case .ended: stopReason == "aborted" ? .interrupted : stopReason == "error" ? .failed : nil
            case .running, .waitingForApproval: nil
            }
        }

        var session: OpenAgentSession {
            var value = OpenAgentSession(id: sessionID, client: .pi, title: title, workspace: workspace,
                path: sessionFile ?? "", start: RecordCoding.date(startedAtMs), end: RecordCoding.date(observedAtMs), turns: [turn])
            value.titleSource = .observer
            value.navigation = .init(observedAt: RecordCoding.date(observedAtMs), target: navigationTarget)
            if let model, let providerID { value.setModel(model, provider: providerID) }
            if state == .completed {
                value.completions = [.init(sessionID: sessionID, vendor: "Pi", turnID: turnID,
                    task: title, model: model ?? "Unknown", startedAt: RecordCoding.date(startedAtMs), completedAt: RecordCoding.date(observedAtMs),
                    navigationTarget: navigationTarget)]
            }
            return value
        }
    }

    static func read(_ data: Data) throws -> Observation {
        guard data.count <= 64 * 1024 else { throw ProviderFailure.limit }
        let value = try JSONDecoder().decode(Observation.self, from: data)
        guard value.version == 1, value.sessionID.hasPrefix("pi:"), value.sessionID.count > 3,
              !value.turnID.isEmpty, value.startedAtMs > 0, value.observedAtMs >= value.startedAtMs else {
            throw ProviderFailure.format
        }
        return value
    }

    // No Pi imports are required: this works with Pi's built-in extension loader.
    // Only lifecycle metadata leaves the process. Tokens remain owned by Pi's transcript.
    static let script = #"""
    // Agent HUD Pi session observer
    import { mkdirSync, writeFileSync, renameSync, readdirSync, statSync, unlinkSync } from "node:fs";
    import { homedir } from "node:os";
    import { join } from "node:path";
    import { createHash, randomUUID } from "node:crypto";

    export default function (pi) {
      const directory = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "agent-hud", "turns");
      let active;
      let heartbeat;
      let lastStopReason;

      function navigationTarget() {
        const id = process.env.ITERM_SESSION_ID;
        return process.env.TERM_PROGRAM === "iTerm.app" && !process.env.TMUX && id
          ? { kind: "iTermSession", id } : undefined;
      }

      function publish(ctx, state = "running", stopReason) {
        if (!active) return;
        const sessionID = "pi:" + ctx.sessionManager.getSessionId();
        const record = {
          version: 1, sessionID, sessionFile: ctx.sessionManager.getSessionFile(),
          workspace: ctx.cwd, title: ctx.sessionManager.getSessionName() || "Pi",
          model: ctx.model?.id, providerID: ctx.model?.provider,
          turnID: active.id, state, startedAtMs: active.startedAtMs, observedAtMs: Date.now(),
          navigationTarget: navigationTarget(), stopReason,
        };
        try {
          mkdirSync(directory, { recursive: true, mode: 0o700 });
          const name = createHash("sha256").update(sessionID + "\0" + active.id).digest("hex");
          const file = join(directory, name + ".json");
          const temporary = file + "." + process.pid + ".tmp";
          writeFileSync(temporary, JSON.stringify(record), { mode: 0o600 });
          renameSync(temporary, file);
        } catch { /* Observability must never interrupt Pi's agent loop. */ }
      }

      function finish(ctx, state, stopReason) {
        publish(ctx, state, stopReason);
        clearInterval(heartbeat);
        heartbeat = undefined;
        active = undefined;
      }

      pi.on("session_start", () => {
        try {
          for (const name of readdirSync(directory)) {
            if (/^[a-f0-9]{64}\.json$/.test(name) && statSync(join(directory, name)).mtimeMs < Date.now() - 7 * 86400000) {
              unlinkSync(join(directory, name));
            }
          }
        } catch { /* The inbox is created on the first agent run. */ }
      });
      pi.on("agent_start", (_event, ctx) => {
        // Retries, auto-compaction and queued follow-ups belong to one unsettled run.
        if (!active) active = { id: randomUUID(), startedAtMs: Date.now() };
        if (!heartbeat) {
          heartbeat = setInterval(() => publish(ctx), 15000);
          heartbeat.unref();
        }
        lastStopReason = undefined;
        publish(ctx);
      });
      // A build without agent_settled never settles the run: its heartbeat stops here, and the run goes quiet.
      pi.on("agent_end", () => {
        clearInterval(heartbeat);
        heartbeat = undefined;
      });
      pi.on("message_end", (event, ctx) => {
        if (event.message.role === "assistant") lastStopReason = event.message.stopReason;
        publish(ctx);
      });
      pi.on("tool_execution_start", (_event, ctx) => publish(ctx));
      pi.on("tool_execution_end", (_event, ctx) => publish(ctx));
      // The last message's stop reason says how the run ended: an answer, the user's abort or an error.
      pi.on("agent_settled", (_event, ctx) => finish(ctx, lastStopReason === "stop" ? "completed" : "ended", lastStopReason));
      pi.on("session_shutdown", (_event, ctx) => finish(ctx, "ended"));
    }
    """#
}

import Foundation

/// What a scripted demo shows right now: which sessions run, what each window reads, the turns that have ended and
/// the requests waiting. The demo's provider builds its report from this instead of from its fixed figures.
public struct DemoStage: Equatable, Sendable {
    /// Running sessions and when each started.
    public var running: [String: Date]
    /// Sessions the script has ended and when.
    public var ended: [String: Date] = [:]
    /// Percentages used by window key, where the script has changed a reading.
    public var used: [String: Double]
    public var completions: [SessionCompletion] = []
    /// Permission requests waiting and when each arrived, oldest first.
    public var requests: [(id: String, at: Date)] = []
    private var turns = 0

    public init(script: DemoScript, now: Date) {
        running = Dictionary(uniqueKeysWithValues: script.running.map { ($0, now) })
        used = script.used
    }

    public static func == (lhs: DemoStage, rhs: DemoStage) -> Bool {
        lhs.running == rhs.running && lhs.ended == rhs.ended && lhs.used == rhs.used && lhs.completions == rhs.completions
            && lhs.requests.map(\.id) == rhs.requests.map(\.id) && lhs.requests.map(\.at) == rhs.requests.map(\.at)
    }

    /// The same stage as the script begins with, keeping the turns already completed so none is announced twice.
    public mutating func restart(script: DemoScript, now: Date) {
        let kept = (completions, turns)
        self = DemoStage(script: script, now: now)
        (completions, turns) = kept
    }

    /// Whether the step changed anything a report carries. The panel is not part of a report, and a request is not either.
    @discardableResult
    public mutating func apply(_ action: DemoScript.Action, at now: Date) -> Bool {
        switch action {
        case .work(let session):
            running[session] = now
            ended[session] = nil
        case .rest(let session):
            running[session] = nil
            ended[session] = now
        case .reply(let session, let message):
            let started = running.removeValue(forKey: session)
            ended[session] = now
            turns += 1
            guard let live = DemoData.sessions(now: now).first(where: { $0.id == session }),
                  let agent = DemoData.consumers.first(where: { $0.id == live.agentId }) else { return true }
            completions.append(SessionCompletion(sessionID: session, vendor: agent.vendor, turnID: "demo-turn-\(turns)",
                                                 task: live.task, model: agent.model, startedAt: started ?? live.startedAt,
                                                 completedAt: now, message: message))
        case .ask(let request):
            guard !requests.contains(where: { $0.id == request }) else { return false }
            requests.append((request, now))
            return false
        case .answer(let request):
            requests.removeAll { $0.id == request }
            return false
        case .quota(let agent, let percent):
            used[agent] = min(100, max(0, percent))
        case .panel:
            return false
        }
        return true
    }
}

/// The stage a playing script has set, for the demo's provider to read from whichever thread it reports on.
public enum DemoStageBox {
    private static let stage = OSAllocatedUnfairLock<DemoStage?>(initialState: nil)

    /// Nil while no script plays: the demo then shows its fixed figures.
    public static var current: DemoStage? {
        get { stage.withLock { $0 } }
        set { stage.withLock { $0 = newValue } }
    }
}

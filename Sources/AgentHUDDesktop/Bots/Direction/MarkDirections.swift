import AgentHUDCore
import Foundation

/// The director at work for the running app: it reads every report the island is given, wakes itself when a rule says
/// a mark shows something else with time alone, and says when that happened. One serves every screen, so a mark tells
/// the same story on all of them.
@MainActor
final class MarkDirections {
    private var director: MarkDirector
    private let clock: () -> Date
    private var timer: Timer?
    /// What a mark shows changed with no report: a rule's time came, or a card was looked at. Not called for a read.
    var onChange: (@MainActor () -> Void)?

    /// - startedAt: the app's start; what happened before it is history.
    /// - clock: the time the store runs on.
    init(startedAt: Date, clock: @escaping () -> Date) {
        director = MarkDirector(startedAt: startedAt)
        self.clock = clock
    }

    /// What each mark shows now, by mark key.
    var current: [String: MarkDirector.Direction] { director.directions }

    /// Takes in a report's marks. Whoever read them applies what they say.
    func read(_ queue: [ReportView.QueueMark]) {
        director.read(queue, at: clock())
        schedule()
    }

    /// Someone looked at these marks' cards, or at every mark's for nil. What changes is told once the caller, which
    /// is in the middle of drawing a screen, is done.
    func looked(at keys: Set<String>?) {
        let before = director.directions
        director.looked(at: keys, at: clock())
        schedule()
        guard director.directions != before else { return }
        Task { @MainActor [weak self] in self?.onChange?() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        let now = clock()
        guard let next = director.nextChange(after: now) else { return }
        let timer = Timer(timeInterval: max(0, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        // A rule's time is a few seconds out at the least, and nothing is drawn from it directly.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        let before = director.directions
        director.advance(to: clock())
        schedule()
        if director.directions != before { onChange?() }
    }
}

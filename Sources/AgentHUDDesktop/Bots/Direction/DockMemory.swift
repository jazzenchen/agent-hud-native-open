import Foundation

/// What one screen's dock, a Dynamic dock or a Simple panel, remembers across the cards that hide it: the events its
/// marks have been handed, and that a card has hidden it. A dock comes back as a new view, which knows nothing, so the
/// screen tells it how to take up where its marks left off.
struct DockMemory: Sendable {
    /// A card has hidden the dock: bots built for it from now on were out before, and take up their looks at once
    /// (`BotActor`'s `awake`).
    private(set) var returns = false
    /// The newest event handed to each mark while the dock showed, by mark key, and the copy of it dated afresh that
    /// replays it.
    private var handed: [String: BotCue] = [:]
    private var replays: [String: BotCue] = [:]

    /// A card is up where the dock was.
    mutating func hide() { returns = true }

    /// The event to hand the mark `key` while the dock shows, from the director's newest for it. One that is still fresh
    /// plays as it is. One that fired while a card hid the dock is over, unless it was a failure or a limit whose badge
    /// the mark still wears: that plays once now, dated afresh. Asked again, the answer stays the same.
    mutating func cue(for key: String, _ cue: BotCue?, badge: BotBadge?, at now: Date) -> BotCue? {
        guard let cue else { return nil }
        if handed[key] == cue { return replays[key] ?? cue }
        handed[key] = cue
        replays[key] = nil
        guard now.timeIntervalSince(cue.at) > BotEvent.freshness else { return cue }
        let stands = switch cue.event {
        case .failed: badge == .failed
        case .limitHit: badge == .limited
        case .start: false
        }
        guard stands else { return cue }
        let replay = BotCue(event: cue.event, at: now)
        replays[key] = replay
        return replay
    }
}

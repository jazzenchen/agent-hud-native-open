import CoreGraphics
import Foundation

/// What a Clawd draws at one moment: one frame of one sprite, where it sits, and what it carries.
struct ClawdPicture: Hashable, Sendable {
    var frame: ClawdFrame
    /// In sprite pixels from where every frame stands.
    var offset = ClawdOffset.zero
    var sign: ClawdSign?
    /// The still mini Clawd beside a look whose agent has sub-agents at work: its middle this many sprite pixels right of
    /// the body's (`ClawdClip.miniShift`); nil for none.
    var mini: Int?
    /// Facing left.
    var mirrored = false
}

/// Plays Clawd's clips for one mark: told what to show and when, it says what to draw and exactly when that next
/// changes, on the absolute 1/12 s grid.
///
/// It plays what it is asked to and decides nothing about the agent. Waiting for a look to be wanted twice, holding
/// a look, the delay before thinking and choosing between sessions are the director's; the player only plays the
/// clips the way they are written: a look's intro, loop and outro, one working look handing over to the next, a
/// wait cutting in from standing, events over a look, visits, greeting, the gaze, and loops that slow down when
/// they run long. A change waits for the point the clip allows it, which `switchPoint` tells.
///
/// It is stepped with a clock and nothing else: the same requests at the same times give the same frames.
struct ClawdPlayer: Sendable {
    /// What the mark shows when no clip plays.
    enum Rest: Sendable {
        /// Its logo, drawn by whoever hosts the mark.
        case logo
        /// Clawd standing, on a card that keeps its bot.
        case standing
    }

    /// What to draw at the time last stepped to; nil for the logo.
    private(set) var picture: ClawdPicture?
    /// When the picture next changes by itself; nil while it holds until something is asked for.
    private(set) var due: TimeInterval?

    let clips: ClawdClips
    /// The sprites, to tell which frames look the same: those are drawn once and held. Without them every frame
    /// counts as a picture of its own.
    let sheet: ClawdSheet?
    let rest: Rest

    /// The look asked for, and whether its agent has sub-agents at work.
    private(set) var target: ClawdLook?
    private(set) var subagents = false
    /// The event waiting for its turn. Only the newest waits.
    private(set) var pendingEvent: ClawdEvent?
    private(set) var badge: ClawdSign?
    private var hovered = false
    private var sector: Int?

    private var activity = Activity.resting
    /// What is left to show of what plays now; the first step started at `start`.
    private var script: [Step]
    private var start = Int64.min
    /// The tick last stepped to.
    private var now = Int64.min
    /// The tick a look came in from rest, so an event asked for with it still plays first.
    private var cameInAt: Int64?

    /// A timer rarely fires on the dot: a step this close to its time is on time.
    private static let slack: TimeInterval = 0.004
    /// Looking further ahead than this for the next change means there is none.
    private static let lookahead = 10_000

    init(clips: ClawdClips = .standard, sheet: ClawdSheet? = nil, rest: Rest = .logo) {
        self.clips = clips
        self.sheet = sheet
        self.rest = rest
        script = [Self.restStep(rest)]
        picture = rest == .standing ? ClawdPicture(frame: sheet?.canonical(.standing) ?? .standing) : nil
    }

    // MARK: Requests

    /// Shows `look`, or the logo for nil: at once from rest, at the next point its clip allows from another look,
    /// and at once for a wait, which cuts in from standing.
    mutating func show(_ look: ClawdLook?, subagents: Bool = false, at time: TimeInterval) {
        let now = step(to: time)
        self.subagents = subagents
        let atCard = if case .atCard = activity { true } else { false }
        guard look != target || atCard else { return settle() }
        target = look
        switch activity {
        case .resting, .visit, .greeting, .gazing, .card, .atCard:
            guard let look else { if atCard { rest(at: now) }; break }
            cameInAt = now
            enter(look, from: nil, at: now)
        case .entering(let shown), .looping(let shown):
            if let look, look.isAttention, look != shown.look {
                enter(look, from: nil, at: now)
            } else if let look, sameClip(look, shown) {
                // The same clip is never restarted. A still one starts moving again at once.
                if case .looping = activity, shown.still != (look == .retrying) { endHold(at: now) }
            } else if case .looping = activity {
                leave(shown, at: now)
            }
            // A look still coming in leaves once its intro is over.
        case .leaving(let shown):
            if let look, look.isAttention {
                enter(look, from: nil, at: now)
            } else if let look, sameClip(look, shown), !script[0].outro {
                // Asked back before its outro began: it simply loops on.
                activity = .looping(shown)
                script.removeAll(where: \.outro)
                for at in script.indices { script[at].sign = shown.clip.sign }
            }
        case .event:
            if let look, look.isAttention { enter(look, from: nil, at: now) }
        }
        settle()
    }

    /// Shows `look` from its loop's start, with no intro: a mark built again after an alert, picking up its look.
    mutating func resume(_ look: ClawdLook, subagents: Bool = false, at time: TimeInterval) {
        let now = step(to: time)
        target = look
        self.subagents = subagents
        loop(Shown(look: look, clip: clips.clip(for: look), still: look == .retrying, epoch: now), at: now)
        settle()
    }

    /// Plays `event` once: at once from rest, at the next point the look allows otherwise, after the look's outro
    /// if it is leaving, and after a wait is over. An event asked for while another waits takes its place.
    mutating func play(_ event: ClawdEvent, at time: TimeInterval) {
        let now = step(to: time)
        switch activity {
        case .resting, .visit, .greeting, .gazing, .card, .atCard:
            playShot(event, resume: nil, at: now)
        case .entering(let shown) where cameInAt == now && !shown.look.isAttention:
            // Asked for together with the look it starts: the event plays, then the look comes in.
            playShot(event, resume: nil, at: now)
        case .looping(let shown) where !shown.look.isAttention:
            pendingEvent = event
            endHold(at: now)
        default:
            pendingEvent = event
        }
        settle()
    }

    /// Forgets the event waiting for its turn.
    mutating func cancelEvent() {
        pendingEvent = nil
    }

    /// Plays a visit on a mark resting as its logo. Anywhere else there is something better to show, and it does not play.
    mutating func visit(_ visit: ClawdVisit, at time: TimeInterval) {
        let now = step(to: time)
        guard case .resting = activity, target == nil, pendingEvent == nil, let shot = clips.visits[visit] else { return settle() }
        activity = .visit
        begin(steps(of: shot), at: now)
        settle()
    }

    /// The pointer has come to rest on the mark: a resting Clawd waves, then follows the pointer with its eyes.
    mutating func greet(at time: TimeInterval) {
        let now = step(to: time)
        hovered = true
        switch activity {
        case .resting, .visit:
            guard target == nil else { break }
            activity = .greeting
            begin(steps(of: clips.greet), at: now)
        default: break
        }
        settle()
    }

    /// The pointer has left the mark: a wave plays out, and eyes on the pointer go back to the logo.
    mutating func endHover(at time: TimeInterval) {
        let now = step(to: time)
        hovered = false
        if case .gazing = activity { rest(at: now) }
        settle()
    }

    /// Where the pointer is, as `BotMotion.aim(from:to:)` gives it. Eyes that follow it change only when it moves into
    /// another 45° sector.
    mutating func look(toward aim: CGPoint, at time: TimeInterval) {
        let now = step(to: time)
        guard let sector = Self.sector(of: aim), sector != self.sector else { return settle() }
        self.sector = sector
        if case .gazing = activity { gaze(at: now) }
        settle()
    }

    /// Plays a card's clip once, after which the card's Clawd stands.
    mutating func card(_ card: ClawdCard, at time: TimeInterval) {
        let now = step(to: time)
        target = nil
        pendingEvent = nil
        if let shot = clips.cards[card] {
            activity = .card
            begin(steps(of: shot), at: now)
        }
        settle()
    }

    /// Holds Clawd still pointing at its agent's card beside it, facing left when the card is to its left. The next look
    /// asked for ends it.
    mutating func pointAtCard(mirrored: Bool, at time: TimeInterval) {
        holdAtCard(Step(frame: clips.pointsAtCard, ticks: .max, holds: true, mirrored: mirrored), at: time)
    }

    /// Holds Clawd still by its agent's card above or below it, which pointing would aim past: standing with the sign of
    /// `look`'s clip for a request, and for a plan, whose bulb is its sign, the bulb lit, its loop's first frame. The next
    /// look asked for ends it.
    mutating func standAtCard(for look: ClawdLook, at time: TimeInterval) {
        let clip = clips.clip(for: look)
        let held: Step
        if clip.sign == nil, let first = clip.loopFrames.first {
            held = Step(frame: first, ticks: .max, offset: clip.offset, holds: true)
        } else {
            held = Step(frame: .standing, ticks: .max, sign: clip.sign, holds: true)
        }
        holdAtCard(held, at: time)
    }

    /// The badge every picture carries, unless it carries a sign that comes before it.
    mutating func set(badge: ClawdSign?, at time: TimeInterval) {
        step(to: time)
        self.badge = badge
        settle()
    }

    /// Steps to `time` and says what to draw.
    @discardableResult
    mutating func advance(to time: TimeInterval) -> ClawdPicture? {
        step(to: time)
        settle()
        return picture
    }

    // MARK: Where a change can happen

    /// The look whose clip is on screen, coming in, looping or going; nil for anything else.
    var shown: ClawdLook? {
        switch activity {
        case .entering(let shown), .looping(let shown), .leaving(let shown): shown.look
        default: nil
        }
    }

    /// The event playing now.
    var playing: ClawdEvent? { if case .event(let event, _) = activity { event } else { nil } }

    /// When a change of look asked for now would begin: now on a mark that rests, with the next tick on a frame held
    /// or standing and in a wait that may be left from any frame, at the end of the cycle or intro that plays, or once
    /// the outro or one-off that plays is over. A wait asked for cuts in at once whatever this says.
    var switchPoint: TimeInterval {
        Self.time(of: switchTick)
    }

    /// Whether a change asked for now begins with the next tick.
    var atSwitchPoint: Bool { switchTick <= now + 1 }

    private var switchTick: Int64 {
        switch activity {
        case .resting, .visit, .greeting, .gazing, .card, .atCard: return now
        case .looping(let shown):
            if script[0].holds || shown.clip.exit == .anyFrame || picture?.frame == (sheet?.canonical(.standing) ?? .standing) {
                return now + 1
            }
            var end = start
            for step in script {
                end += Int64(step.ticks)
                if step.endsCycle { break }
            }
            return end
        case .entering, .leaving, .event:
            return script.reduce(start) { $1.ticks == .max ? $0 : $0 + Int64($1.ticks) }
        }
    }

    // MARK: Playing

    private enum Activity: Sendable {
        case resting
        case entering(Shown)
        case looping(Shown)
        case leaving(Shown)
        case event(ClawdEvent, resume: Shown?)
        case visit, greeting, gazing, card
        /// Held still at its agent's card, pointing or standing.
        case atCard
    }

    /// A look on screen, and the clip it plays.
    private struct Shown: Sendable {
        var look: ClawdLook
        var clip: ClawdClip
        var still: Bool
        /// The tick its loop first started, which its slowing down counts from.
        var epoch: Int64?
    }

    private struct Step: Sendable {
        /// Nil for the logo.
        var frame: ClawdFrame?
        /// Ticks it shows for; `Int.max` until something is asked for.
        var ticks = 1
        var offset = ClawdOffset.zero
        var sign: ClawdSign?
        /// Where the mini Clawd of sub-agents stands on a working look's frame; nil where it has none.
        var mini: Int?
        /// A frame held on purpose, which a change asked for may end with the next tick.
        var holds = false
        /// The last frame of a cycle, or of an intro: where a working look may change.
        var endsCycle = false
        /// Part of an outro, past the point a look can be asked back.
        var outro = false
        var mirrored = false
    }

    private static func restStep(_ rest: Rest) -> Step {
        Step(frame: rest == .standing ? .standing : nil, ticks: .max, holds: true)
    }

    private static func tick(of time: TimeInterval) -> Int64 {
        Int64(((time + slack) * Double(ClawdTicks.perSecond)).rounded(.down))
    }

    private static func time(of tick: Int64) -> TimeInterval { Double(tick) / Double(ClawdTicks.perSecond) }

    /// Moves to the tick of `time`, playing on through everything that ends before it. Time never runs back.
    @discardableResult
    private mutating func step(to time: TimeInterval) -> Int64 {
        let tick = max(now, Self.tick(of: time))
        play(to: tick)
        now = tick
        return tick
    }

    private mutating func play(to tick: Int64) {
        while script[0].ticks != .max, start + Int64(script[0].ticks) <= tick {
            start += Int64(script[0].ticks)
            script.removeFirst()
            if script.isEmpty { proceed(at: start) }
        }
    }

    /// Works out the picture, and when it next changes.
    private mutating func settle() {
        picture = picture(of: script[0])
        due = nextChange().map(Self.time(of:))
    }

    private func nextChange() -> Int64? {
        var probe = self
        for _ in 0..<Self.lookahead {
            guard probe.script[0].ticks != .max else { return nil }
            let end = probe.start + Int64(probe.script[0].ticks)
            probe.play(to: end)
            if probe.picture(of: probe.script[0]) != picture { return end }
        }
        return nil
    }

    private func picture(of step: Step) -> ClawdPicture? {
        guard let frame = step.frame else { return nil }
        var sign = step.sign
        if let badge, sign.map({ badge < $0 }) ?? true { sign = badge }
        return ClawdPicture(frame: sheet?.canonical(frame) ?? frame, offset: step.offset, sign: sign,
                            mini: subagents ? step.mini : nil, mirrored: step.mirrored)
    }

    private func sameClip(_ look: ClawdLook, _ shown: Shown) -> Bool { clips.clip(for: look).name == shown.clip.name }

    private mutating func begin(_ steps: [Step], at tick: Int64) {
        start = tick
        script = steps
        if script.isEmpty { proceed(at: tick) }
    }

    /// What follows once what was playing has played out.
    private mutating func proceed(at tick: Int64) {
        switch activity {
        case .entering(let shown), .looping(let shown):
            reachSwitch(shown, at: tick)
        case .leaving(let shown):
            if let event = pendingEvent, target?.isAttention != true {
                playShot(event, resume: nil, at: tick)
            } else if let target {
                enter(target, from: shown, at: tick)
            } else {
                rest(at: tick)
            }
        case .event(_, let resume):
            if let event = pendingEvent, target?.isAttention != true {
                playShot(event, resume: resume, at: tick)
            } else if let target, let resume, sameClip(target, resume) {
                // A look an event played over resumes where its loop starts, with no intro.
                loop(Shown(look: target, clip: resume.clip, still: target == .retrying, epoch: resume.epoch), at: tick)
            } else if let target {
                enter(target, from: nil, at: tick)
            } else {
                rest(at: tick)
            }
        case .greeting:
            if hovered { gaze(at: tick) } else { rest(at: tick) }
        case .visit, .card:
            if let target { enter(target, from: nil, at: tick) } else { rest(at: tick) }
        case .resting, .gazing, .atCard:
            rest(at: tick)
        }
    }

    /// A look at the end of its intro or of a cycle: an event waiting plays, a look asked for takes over, or it loops on.
    private mutating func reachSwitch(_ shown: Shown, at tick: Int64) {
        var shown = shown
        if let event = pendingEvent, !shown.look.isAttention { return playShot(event, resume: shown, at: tick) }
        guard let target, sameClip(target, shown) else { return leave(shown, at: tick) }
        shown.look = target
        shown.still = target == .retrying
        loop(shown, at: tick)
    }

    private mutating func rest(at tick: Int64) {
        activity = .resting
        begin([Self.restStep(rest)], at: tick)
    }

    private mutating func holdAtCard(_ held: Step, at time: TimeInterval) {
        let now = step(to: time)
        activity = .atCard
        begin([held], at: now)
        settle()
    }

    private mutating func gaze(at tick: Int64) {
        activity = .gazing
        let frame = sector.map { ClawdFrame(.lookingAroundEyesOnly, clips.gaze[$0 % clips.gaze.count]) } ?? .standing
        begin([Step(frame: frame, ticks: .max, holds: true)], at: tick)
    }

    private mutating func playShot(_ event: ClawdEvent, resume: Shown?, at tick: Int64) {
        pendingEvent = nil
        activity = .event(event, resume: resume)
        begin(steps(of: clips.shot(for: event)), at: tick)
    }

    private func steps(of shot: ClawdShot) -> [Step] {
        shot.steps.map { Step(frame: $0.frame, ticks: $0.ticks, offset: $0.offset, sign: $0.sign) }
    }

    /// Brings `look` in: after another working look, through its entry; from anything else, through its whole intro.
    private mutating func enter(_ look: ClawdLook, from source: Shown?, at tick: Int64) {
        let clip = clips.clip(for: look)
        let handover = source.map { $0.clip.working && clip.working } ?? false
        let frames = handover ? clip.entry ?? clip.intro : clip.intro
        let shown = Shown(look: look, clip: clip, still: look == .retrying, epoch: nil)
        activity = .entering(shown)
        var steps = frames.enumerated().map { at, frame in
            Step(frame: frame, ticks: clip.ticks, offset: clip.offset.eased(frames.count > 1 ? CGFloat(at) / CGFloat(frames.count - 1) : 1),
                 sign: clip.sign, mini: clip.miniShift)
        }
        if !steps.isEmpty { steps[steps.count - 1].endsCycle = true }
        begin(steps, at: tick)
    }

    private mutating func loop(_ shown: Shown, at tick: Int64) {
        var shown = shown
        if shown.epoch == nil { shown.epoch = tick }
        activity = .looping(shown)
        begin(cycle(shown, at: tick), at: tick)
    }

    /// One cycle of a look's loop starting at `tick`: in full, or slowed down once the loop has run long.
    private func cycle(_ shown: Shown, at tick: Int64) -> [Step] {
        let clip = shown.clip, each = clip.ticks
        func step(_ index: Int, _ ticks: Int) -> Step {
            Step(frame: ClawdFrame(clip.sprite, index), ticks: ticks, offset: clip.offset, sign: clip.sign, mini: clip.miniShift)
        }
        guard !shown.still, !clip.loop.isEmpty else {
            var still = clip.loop.first.map { step($0, .max) } ?? Step(ticks: .max)
            still.holds = true
            return [still]
        }
        var steps = clip.loop.map { step($0, each) }
        let looped = tick - (shown.epoch ?? tick)
        func past(_ seconds: TimeInterval) -> Bool { looped >= Int64(ClawdTicks.of(seconds)) }
        switch clip.pace {
        case .steady: break
        case .resting(let after, let hold) where past(after):
            steps[0].ticks += ClawdTicks.of(hold)
            steps[0].holds = true
        case .waiting(let after, let every, let slowAfter, let slowEvery) where past(after):
            let period = ClawdTicks.of(past(slowAfter) ? slowEvery : every)
            steps[0].ticks = max(each, period - (steps.count - 1) * each)
            steps[0].holds = true
        case .replaying(let after, let hold, let replay, let every) where past(after):
            var held = step(hold, max(each, ClawdTicks.of(every) - replay.count * each))
            held.holds = true
            steps = [held] + replay.map { step($0, each) }
        default: break
        }
        steps[steps.count - 1].endsCycle = true
        return steps
    }

    /// Leaves a look by the way its clip allows, then plays its outro. Where a cycle ends, a wait whose exit needs a
    /// frame first plays on to it. From inside a cycle, a working look finishes the cycle, a wait leaves after the
    /// frame on screen or plays on through the frame its exit needs, and a frame held is let go with the next tick.
    private mutating func leave(_ shown: Shown, at tick: Int64) {
        let clip = shown.clip
        var lead: [Step]
        if script.isEmpty {
            lead = exitLead(clip)
        } else {
            lead = script
            if lead[0].holds { lead[0].ticks = Int(tick + 1 - start) }
            switch clip.exit {
            case .cycleEnd:
                if script[0].holds { lead = [lead[0]] }
            case .anyFrame:
                lead = [lead[0]]
            case .through(let frame):
                if let at = lead.firstIndex(where: { $0.frame == ClawdFrame(clip.sprite, frame) }) {
                    lead = Array(lead[...at])
                } else {
                    lead += exitLead(clip)
                }
            }
            for at in lead.indices.dropFirst() where lead[at].holds { lead[at].ticks = clip.ticks }
        }
        // A wait that is over no longer carries its sign, from the frame after the one on screen.
        lead = lead.enumerated().map { at, step in
            var step = step
            if at > 0 || script.isEmpty { step.sign = nil }
            step.holds = false
            step.endsCycle = false
            return step
        }
        let outro = clip.outro.enumerated().map { at, frame in
            Step(frame: frame, ticks: clip.ticks,
                 offset: clip.offset.eased(clip.outro.count > 1 ? 1 - CGFloat(at) / CGFloat(clip.outro.count - 1) : 0),
                 mini: clip.miniShift, outro: true)
        }
        let leaving = script.isEmpty
        activity = .leaving(shown)
        if leaving { begin(lead + outro, at: tick) } else { script = lead + outro }
    }

    /// The loop's frames from its start through the one its exit needs, for a look leaving where a cycle begins.
    private func exitLead(_ clip: ClawdClip) -> [Step] {
        guard case .through(let frame) = clip.exit, let end = clip.loop.firstIndex(of: frame) else { return [] }
        return clip.loop[...end].map {
            Step(frame: ClawdFrame(clip.sprite, $0), ticks: clip.ticks, offset: clip.offset, mini: clip.miniShift)
        }
    }

    /// Ends the frame held now with the next tick, and what was to follow it in this cycle, so the look reaches the
    /// point where it can change.
    private mutating func endHold(at tick: Int64) {
        guard case .looping = activity, script[0].holds else { return }
        script = [script[0]]
        script[0].ticks = Int(tick + 1 - start)
        script[0].endsCycle = true
    }

    /// The 45° sector `aim` points into, counter-clockwise from the right; nil when the pointer is too close to tell.
    static func sector(of aim: CGPoint) -> Int? {
        guard hypot(aim.x, aim.y) >= 0.02 else { return nil }
        // An aim is measured with y running down.
        let turns = Int((atan2(-aim.y, aim.x) / (.pi / 4)).rounded())
        return (turns % 8 + 8) % 8
    }
}

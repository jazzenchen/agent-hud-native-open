import AgentHUDCore
import AppKit
import QuartzCore
import XCTest
@testable import AgentHUDDesktop

/// A bot's frames are drawn from kept parts wherever they can be. These hold every such frame to the one drawn
/// whole, the outline and the hairline to the ones drawn before they were made cheaper, byte for byte, and measure
/// what a frame costs.
@MainActor
final class BotFrameTests: XCTestCase {
    /// A pointer that keeps moving, so the eyes keep following it.
    private static func aim(at now: TimeInterval) -> CGPoint {
        CGPoint(x: 0.6 * cos(now * 0.7), y: 0.4 * sin(now * 1.1))
    }

    /// The motions a bot would draw a frame for, at 30 frames a second, through `phases` from the given times.
    private static func motions(of form: BotForm, seed: UInt64, until end: TimeInterval,
                                phases: [(TimeInterval, BotPhase)]) -> [BotMotion] {
        motions(of: form, seed: seed, until: end, states: phases.map { ($0.0, $0.1.state, nil) })
    }

    /// The same through states, each with an event played as it is given.
    private static func motions(of form: BotForm, seed: UInt64, until end: TimeInterval,
                                states: [(TimeInterval, BotState, BotEvent?)]) -> [BotMotion] {
        var motion = BotMotion(seed: seed)
        motion.fit(form.spec)
        var drawn: [BotMotion] = [], shown: BotRenderer.Look?, next = 0, frame = 0
        while Double(frame) / 30 < end {
            let now = Double(frame) / 30
            while next < states.count, states[next].0 <= now {
                motion.set(states[next].1, at: now)
                if let event = states[next].2 { motion.play(event, at: now) }
                next += 1
            }
            motion.step(to: now, aim: aim(at: now))
            let look = BotRenderer.look(of: motion)
            if look != shown {
                shown = look
                drawn.append(motion)
            }
            frame += 1
        }
        return drawn
    }

    private static let phases: [(TimeInterval, BotPhase)] = [(0, .working), (4, .opened), (5, .asking), (6, .done), (7.5, .idle)]

    /// The new looks, with their signs, the copy for sub-agents coming and going, a badge, and the events over them.
    private static let states: [(TimeInterval, BotState, BotEvent?)] = [
        (0, BotState(look: .thinking), nil), (2.5, BotState(look: .tool(.edit), subagents: true), .start),
        (4, BotState(look: .plain, subagents: true), .failed), (6, BotState(look: .question), nil),
        (7.5, BotState(look: .idle, badge: .limited, hovered: true), nil), (9, BotState(look: .plain), .limitHit),
    ]

    private static func bytes(_ image: CGImage?) -> Data {
        (image?.dataProvider?.data as Data?) ?? Data()
    }

    /// The ways a queue draws a bot: its size, its hairline and its display's colours.
    private struct Setting {
        var side: CGFloat
        var outline: Int
        var space: CGColorSpace?
    }

    /// The settings the app draws in, side by side: a 20 pt mark at 2x with its hairline on a P3 display, the
    /// stand-alone mark without one, a mark at 1x, sizes that are not even, colours that are not the usual ones,
    /// and the main display's own.
    private static let settings: [Setting] = {
        var settings = [Setting(side: 40, outline: 1, space: CGColorSpace(name: CGColorSpace.displayP3)),
                        Setting(side: 40, outline: 0, space: nil),
                        Setting(side: 20, outline: 1, space: CGColorSpace(name: CGColorSpace.sRGB)),
                        Setting(side: 37, outline: 0, space: CGColorSpace(name: CGColorSpace.adobeRGB1998))]
        let display = CGDisplayCopyColorSpace(CGMainDisplayID())
        if display.model == .rgb { settings.append(Setting(side: 44, outline: 1, space: display)) }
        return settings
    }()

    private static func draw(_ form: BotForm, _ motion: BotMotion, _ setting: Setting) -> CGImage? {
        BotRenderer.image(form, motion: motion, side: setting.side, outline: setting.outline, space: setting.space)
    }

    /// The same frame with nothing kept from any earlier one.
    private static func drawnWhole(_ form: BotForm, _ motion: BotMotion, _ setting: Setting) -> Data {
        BotCanvas.forget()
        BotStill.forget()
        return bytes(draw(form, motion, setting))
    }

    /// Every bot through a morph, its acts, an alert and back, drawn as two queues would draw it in every setting
    /// in turn, and each frame drawn again whole in a new bitmap.
    func testAFrameFromKeptPartsIsTheFrameDrawnWhole() throws {
        var frames = 0, differing: [String] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            let screens = (0..<2).map { Self.motions(of: form, seed: UInt64($0 + 1), until: 9, phases: Self.phases) }
            // Both screens' frames, in every setting, in turn the way the clock draws them, from whatever is kept.
            var kept: [[[Data]]] = Array(repeating: Array(repeating: [], count: Self.settings.count), count: 2)
            for index in 0..<screens.map(\.count).max()! {
                for (screen, motions) in screens.enumerated() where index < motions.count {
                    for (place, setting) in Self.settings.enumerated() {
                        kept[screen][place].append(Self.bytes(Self.draw(form, motions[index], setting)))
                    }
                }
            }
            // Then each frame again with nothing kept.
            for (screen, motions) in screens.enumerated() {
                for (index, motion) in motions.enumerated() {
                    for (place, setting) in Self.settings.enumerated() {
                        frames += 1
                        if kept[screen][place][index] != Self.drawnWhole(form, motion, setting) {
                            differing.append("\(vendor) screen \(screen) setting \(place) frame \(index)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 25000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// Every bot at once, frame by frame, in more settings than there is room to keep, so kept parts are shared,
    /// passed between bots and let go.
    func testFramesOfManyBotsInTurnAreTheFramesDrawnWhole() throws {
        let bots = try AgentArtwork.allVendors.map { vendor in
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            return (vendor, form, Self.motions(of: form, seed: 5, until: 9, phases: Self.phases))
        }
        let settings = Array(Self.settings.prefix(3))
        var kept: [[[Data]]] = bots.map { _ in settings.map { _ in [] } }
        for index in 0..<bots.map(\.2.count).max()! {
            for (bot, (_, form, motions)) in bots.enumerated() where index < motions.count {
                for (place, setting) in settings.enumerated() {
                    kept[bot][place].append(Self.bytes(Self.draw(form, motions[index], setting)))
                }
            }
        }
        var frames = 0, differing: [String] = []
        for (bot, (vendor, form, motions)) in bots.enumerated() {
            for (index, motion) in motions.enumerated() {
                for (place, setting) in settings.enumerated() {
                    frames += 1
                    if kept[bot][place][index] != Self.drawnWhole(form, motion, setting) {
                        differing.append("\(vendor) setting \(place) frame \(index)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 10000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// The same for the new looks: a sign, a copy for sub-agents kept with the still part and let go again, crossed
    /// eyes, a faded logo's badge.
    func testFramesOfTheNewLooksFromKeptPartsAreTheFramesDrawnWhole() throws {
        var frames = 0, differing: [String] = []
        let settings = Array(Self.settings.prefix(3))
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            let motions = Self.motions(of: form, seed: 4, until: 11, states: Self.states)
            var kept: [[Data]] = settings.map { _ in [] }
            for motion in motions {
                for (place, setting) in settings.enumerated() { kept[place].append(Self.bytes(Self.draw(form, motion, setting))) }
            }
            for (index, motion) in motions.enumerated() {
                for (place, setting) in settings.enumerated() {
                    frames += 1
                    if kept[place][index] != Self.drawnWhole(form, motion, setting) {
                        differing.append("\(vendor) setting \(place) frame \(index)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 5000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// Sub-agents stand as a copy of the body at 0.4 of its size, its centre 0.42 of the side right of the body's and
    /// 0.18 below, drawn into the frame and still while the bot beside it moves.
    func testSubAgentsStandAsASmallStillCopyAtTheLowerRight() throws {
        for vendor in ["Grok Bot", "GLM", "CodeBuddy", "Claude", "GitHub Copilot", "Kimi"] {
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            func picture(subagents: Bool, aim: CGPoint) throws -> [UInt8] {
                var motion = BotMotion(seed: 3)
                motion.fit(form.spec)
                motion.set(BotState(look: .plain, subagents: subagents), at: 0)
                var now: TimeInterval = 0
                while now < 0.8 { motion.step(to: now, aim: aim); now += BotPace.lively }
                let image = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: 100))
                return [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
            }
            let alone = try picture(subagents: false, aim: .zero), helped = try picture(subagents: true, aim: .zero)
            // The pixels the copy and the gap round it changed, in a 160-pixel frame where the mark is 100.
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<160 {
                for x in 0..<160 {
                    // Each step on its own line: as one condition, Xcode 16.4's type checker gives up on it.
                    let index: Int = (y * 160 + x) * 4 + 3
                    let change: Int = abs(Int(alone[index]) - Int(helped[index]))
                    guard change > 60 else { continue }
                    xs.append(x)
                    ys.append(y)
                }
            }
            XCTAssertGreaterThan(xs.count, 100, vendor)
            let middle = CGPoint(x: CGFloat(xs.min()! + xs.max()!) / 2, y: CGFloat(ys.min()! + ys.max()!) / 2)
            let spec = form.spec
            let wanted = CGPoint(x: (spec.center.x + 0.42 + 0.3) * 100, y: (spec.center.y + 0.18 + 0.3) * 100)
            XCTAssertEqual(middle.x, wanted.x, accuracy: 8, "\(vendor) across")
            XCTAssertEqual(middle.y, wanted.y + spec.settle * 100, accuracy: 8, "\(vendor) down")
            XCTAssertLessThan(CGFloat(xs.max()! - xs.min()!), 0.5 * 100, "\(vendor): a small one")

            // Looking elsewhere moves the bot's eyes, never the copy's.
            let looking = try picture(subagents: true, aim: CGPoint(x: -0.8, y: 0.5))
            let box = (xs.min()!...xs.max()!, ys.min()!...ys.max()!)
            let main = CGRect(x: (spec.center.x - spec.radius + 0.3) * 100, y: (spec.center.y - spec.radius + 0.3) * 100,
                              width: 2 * spec.radius * 100, height: 2 * spec.radius * 100)
            var moved = 0
            for y in box.1 {
                for x in box.0 where !main.contains(CGPoint(x: x, y: y)) {
                    let index: Int = (y * 160 + x) * 4 + 3
                    if looking[index] != helped[index] { moved += 1 }
                }
            }
            XCTAssertEqual(moved, 0, "\(vendor): the copy stays still")
        }
    }

    /// The outline built from kept directions, and handed back when it is asked for again, is the one built a
    /// point at a time, at every moment of every bot's morph and turn.
    func testTheOutlineIsTheOneBuiltBefore() throws {
        var outlines = 0, differing: [String] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            var moments = Self.motions(of: form, seed: 3, until: 9, phases: Self.phases)
                .map { (BotMotion.easeInOut($0.morph), $0.turn) }
            moments += [(0, 0), (1, 0), (0.5, 359.75), (1, -12.5), (0.25, 721.5), (1, 0)]
            for (eased, turn) in moments {
                outlines += 1
                if BotFramesAsBefore.elements(of: form.outline(eased: eased, turn: turn))
                    != BotFramesAsBefore.elements(of: BotFramesAsBefore.outline(form, eased: eased, turn: turn)) {
                    differing.append("\(vendor) at \(eased), turned \(turn)")
                }
            }
        }
        XCTAssertGreaterThan(outlines, 3000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(outlines) outlines differ")
    }

    /// Whole frames with their hairline, from every bot in every setting that has one, are the same frames drawn
    /// without it with the hairline then laid as it was before.
    func testTheHairlineIsTheOneLaidBefore() throws {
        for space in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!] {
            let probe = try XCTUnwrap(BotCanvas.clear(66, space: space))
            XCTAssertNotNil(BotHairline.strengths(for: probe), "\(space): Accelerate lays the hairline as Core Graphics does")
        }
        var frames = 0, differing: [String] = []
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            let motions = Self.motions(of: form, seed: 3, until: 9, phases: Self.phases)
            for (index, motion) in motions.enumerated() where index % 3 == 0 {
                for setting in Self.settings where setting.outline > 0 {
                    let laid = Self.bytes(Self.draw(form, motion, setting))
                    let bare = try XCTUnwrap(BotRenderer.bare(form, motion: motion, side: setting.side,
                                                              outline: setting.outline, space: setting.space))
                    frames += 1
                    if laid != Self.bytes(BotFramesAsBefore.hairlined(bare, reach: setting.outline)) {
                        differing.append("\(vendor) frame \(index) at \(setting.side)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(frames, 2000)
        XCTAssertEqual(differing.prefix(20), [], "\(differing.count) of \(frames) frames differ")
    }

    /// Not a benchmark unless asked for: `AGENT_HUD_BENCH_BOTS=1 swift test --filter BotFrameTests`, in a debug or
    /// a release build. A typical Dynamic-mode queue on two displays, timed in thread CPU time: a minute of its
    /// drawing alone, then two minutes of the clock ticking every lively frame, as `BotClock` would at its busiest.
    func testFrameCost() throws {
        guard ProcessInfo.processInfo.environment["AGENT_HUD_BENCH_BOTS"] == "1" else {
            throw XCTSkip("Set AGENT_HUD_BENCH_BOTS=1 to time a bot's frames")
        }
        func cpu() -> TimeInterval {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
        }
        let rows: [(String, BotPhase)] = [("Claude", .working), ("Codex", .working), ("Cursor", .idle),
                                          ("Grok", .working), ("OpenCode", .idle), ("DeepSeek", .idle)]
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let minute: [(TimeInterval, BotPhase)] = [(0, .working), (20, .asking), (26, .done), (30, .opened), (40, .idle), (45, .working)]

        // The drawing alone: every frame a working bot draws in that minute, best of five rounds.
        var drawn: [(BotForm, BotMotion)] = []
        for (index, row) in rows.enumerated() {
            let form = try XCTUnwrap(BotForm.form(for: row.0, ground: .dark))
            drawn += Self.motions(of: form, seed: UInt64(index + 1), until: 60, phases: minute).map { (form, $0) }
        }
        var best = TimeInterval.infinity
        for _ in 0..<5 {
            let began = cpu()
            for (form, motion) in drawn { autoreleasepool { _ = BotRenderer.image(form, motion: motion, side: 40, outline: 1, space: space) } }
            best = min(best, cpu() - began)
        }
        print(String(format: "bot frame: %.1f µs each, %d frames over %d bot-minutes",
                     best / Double(drawn.count) * 1e6, drawn.count, rows.count))

        // The clock: two queues of those six marks, stepped as their actors ask, frames committed every tick.
        let root = CALayer()
        var actors: [BotActor] = []
        for screen in 0..<2 {
            for (index, row) in rows.enumerated() {
                let actor = BotActor(form: try XCTUnwrap(BotForm.form(for: row.0, ground: .dark)), staysBot: false, period: 3,
                                     seed: UInt64(screen * 100 + index + 1))
                actor.resize(side: 20, scale: 2, outline: 1)
                actor.show(in: space)
                actor.set(row.1, at: 0)
                root.addSublayer(actor.layer)
                actors.append(actor)
            }
        }
        var now: TimeInterval = 0, busy: TimeInterval = 0, ticks = 0
        while now < 120 {
            let began = cpu()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for actor in actors { _ = actor.step(to: now, yRunsDown: true) { Self.aim(at: now) } }
            CATransaction.commit()
            busy += cpu() - began
            ticks += 1
            now += BotPace.lively
        }
        print(String(format: "bot clock: %.1f µs a tick, %.2f ms a second at %.0f ticks a second",
                     busy / Double(ticks) * 1e6, busy / now * 1000, 1 / BotPace.lively))
    }
}

import AppKit
import AgentHUDCore
import QuartzCore
import SwiftUI
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class BotQueueTests: XCTestCase {
    private func queue(_ rows: [(String, Bool)], bots: Bool = true) -> LogoQueueConfig {
        var settings = Settings()
        settings.botLogos = bots
        return LogoQueueConfig(items: rows.map { LogoQueueItem(vendor: $0.0, isWorking: $0.1) },
                               placement: ScreenPlacement(mode: .logos), settings: settings)
    }

    /// A queue in a window that is never shown, so its bots have a screen position to look from.
    private func hosted() -> (LogoQueueLayerView, NSWindow) {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 48)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        // A window made in code releases itself when closed unless told otherwise, and ARC then releases it again.
        window.isReleasedWhenClosed = false
        let view = LogoQueueLayerView(frame: frame)
        window.contentView?.addSubview(view)
        return (view, window)
    }

    private func run(_ view: LogoQueueLayerView, from start: TimeInterval, frames: Int) -> (now: TimeInterval, moving: Bool) {
        var now = start, moving = false
        for _ in 0..<frames {
            now += 1.0 / 30
            moving = view.stepBots(to: now) != nil
        }
        return (now, moving)
    }

    func testAWorkingMarkGivesWayToItsBotAndComesBackWhenWorkEnds() throws {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Claude", true), ("Cursor", false)]), light: false, scale: 2, animates: true)
        var clock = run(view, from: CACurrentMediaTime(), frames: 30)
        XCTAssertTrue(clock.moving)
        let claude = try XCTUnwrap(view.actors[0]), cursor = try XCTUnwrap(view.actors[1])
        XCTAssertEqual(view.marks[0].opacity, 0)
        XCTAssertFalse(claude.layer.isHidden)
        XCTAssertNotNil(claude.layer.contents)
        XCTAssertEqual(view.marks[1].opacity, 1)
        XCTAssertTrue(cursor.layer.isHidden)
        // The bot sits on its mark, with room round it for what overflows.
        XCTAssertEqual(claude.layer.position.x, view.marks[0].frame.midX, accuracy: 0.01)
        XCTAssertEqual(claude.layer.position.y, view.marks[0].frame.midY, accuracy: 0.01)
        XCTAssertGreaterThan(claude.layer.bounds.width, view.marks[0].bounds.width * 1.5)

        view.apply(config: queue([("Claude", false), ("Cursor", false)]), light: false, scale: 2, animates: true)
        clock = run(view, from: clock.now, frames: 45)
        XCTAssertTrue(clock.moving, "Idle logos keep the clock for their occasional bot appearance")
        XCTAssertEqual(view.marks[0].opacity, 1)
        XCTAssertTrue(claude.layer.isHidden)
    }

    func testWithBotsOffAWorkingMarkStaysStill() {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Claude", true)], bots: false), light: false, scale: 2, animates: true)
        XCTAssertNil(view.actors[0])
        XCTAssertNil(view.marks[0].animationKeys())
        XCTAssertNil(view.stepBots(to: CACurrentMediaTime()))
    }

    func testAWorkingQueueKeepsItsBotThroughoutTheTurn() throws {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Codex", true)]), light: false, scale: 2, animates: true)
        let actor = try XCTUnwrap(view.actors[0])
        let start = CACurrentMediaTime()
        for frame in 1...1500 {
            XCTAssertNotNil(view.stepBots(to: start + Double(frame) / 30))
            XCTAssertEqual(actor.phase, .working)
            XCTAssertFalse(actor.layer.isHidden)
            XCTAssertEqual(view.marks[0].opacity, 0)
            XCTAssertEqual(actor.layer.affineTransform().tx, 0, accuracy: 0.0001)
            XCTAssertEqual(actor.layer.affineTransform().ty, 0, accuracy: 0.0001)
        }
        XCTAssertNil(view.marks[0].animationKeys())
    }

    func testAnIdleQueueOccasionallyShowsItsBotThenReturnsToTheLogo() throws {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Codex", false)]), light: false, scale: 2, animates: true)
        let actor = try XCTUnwrap(view.actors[0])
        let start = CACurrentMediaTime()
        var sawBot = false, returnedToLogo = false, returnedToBot = false
        for frame in 1...2700 {
            XCTAssertNotNil(view.stepBots(to: start + Double(frame) / 30),
                            "The idle interval keeps the clock for the next bot appearance")
            XCTAssertEqual(actor.phase, .idle)
            if actor.layer.isHidden {
                XCTAssertEqual(view.marks[0].opacity, 1)
                if sawBot { returnedToLogo = true }
            } else {
                XCTAssertEqual(view.marks[0].opacity, 0)
                sawBot = true
                if returnedToLogo { returnedToBot = true }
            }
            if frame < 600 { XCTAssertTrue(actor.layer.isHidden, "Idle starts with a longer logo interval") }
            XCTAssertEqual(actor.layer.affineTransform().tx, 0, accuracy: 0.0001)
            XCTAssertEqual(actor.layer.affineTransform().ty, 0, accuracy: 0.0001)
        }
        XCTAssertTrue(sawBot)
        XCTAssertTrue(returnedToLogo)
        XCTAssertTrue(returnedToBot)
    }

    /// Clawd is the one bot that leaves its logo's place: it steps aside and jumps, in whole steps of its art, never
    /// more than two aside or three up, and comes back.
    func testClawdMovesInWholeStepsAndComesBack() throws {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        // A seed whose minute of random acts holds a scuttle and a jump: with any seed, about one minute in fifty has
        // neither, and the test would fail for that alone.
        view.seed = 7
        view.apply(config: queue([("Claude", true)]), light: false, scale: 2, animates: true)
        let actor = try XCTUnwrap(view.actors[0])
        // One step of the art at the queue's logo size: a quarter of the body's radius.
        let step = 0.25 * 0.22 * queue([("Claude", true)]).logo
        let start = CACurrentMediaTime()
        var aside = Set<Int>(), up = Set<Int>()
        for frame in 1...1800 {
            XCTAssertNotNil(view.stepBots(to: start + Double(frame) / 30))
            guard frame > 20 else { continue }
            let moved = actor.layer.affineTransform()
            let x = moved.tx / step, y = moved.ty / step
            XCTAssertEqual(x, x.rounded(), accuracy: 0.0001, "frame \(frame)")
            XCTAssertEqual(y, y.rounded(), accuracy: 0.0001, "frame \(frame)")
            aside.insert(Int(x.rounded()))
            up.insert(Int(y.rounded()))
        }
        XCTAssertTrue(aside.isSubset(of: -2...2) && aside.count > 1, "\(aside)")
        // The queue lays its layers out with y running down: a jump is a move up the screen.
        XCTAssertTrue(up.isSubset(of: -3...1) && up.contains(-3), "\(up)")
        XCTAssertTrue(aside.contains(0) && up.contains(0))
    }

    func testAnIdleQueueAsksForNoFrameBeforeItsNextVisit() throws {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Claude", false), ("Cursor", false)]), light: false, scale: 2, animates: true)
        let start = CACurrentMediaTime()
        let wait = try XCTUnwrap(view.stepBots(to: start))
        // Every mark is its logo and the soonest visit is at least twenty seconds away.
        XCTAssertGreaterThan(wait, 15)
        XCTAssertLessThan(wait, 36)
        let claude = try XCTUnwrap(view.actors[0])
        XCTAssertTrue(claude.layer.isHidden)
        // A step before then is turned away without moving anything.
        let later = try XCTUnwrap(view.stepBots(to: start + 5))
        XCTAssertEqual(later, wait - 5, accuracy: 0.001)

        // Work starting meanwhile is shown from the next frame, however long the mark meant to wait.
        view.apply(config: queue([("Claude", true), ("Cursor", false)]), light: false, scale: 2, animates: true)
        let working = try XCTUnwrap(view.stepBots(to: start + 6))
        // A step within a slack of a frame's time counts as that frame's, so the next one can be a slack further away.
        XCTAssertLessThanOrEqual(working, BotPace.lively + BotPace.slack + 0.0001, "no later than the next frame")
    }

    func testAWorkingBotThatOnlyBreathesIsSteppedAFewTimesASecond() throws {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Cursor", true)]), light: false, scale: 2, animates: true)
        let start = CACurrentMediaTime()
        var waits: [TimeInterval] = [], now = start
        // Thirty seconds of a turn, stepped exactly when the queue asks, from the first frame on the shared clock.
        now += try XCTUnwrap(view.stepBots(to: now))
        while now < start + 30 {
            let wait = try XCTUnwrap(view.stepBots(to: now))
            XCTAssertEqual((now + wait) / BotPace.lively, ((now + wait) / BotPace.lively).rounded(), accuracy: 0.001,
                           "every frame falls on the shared clock's")
            waits.append(wait)
            now += wait
        }
        XCTAssertTrue(waits.allSatisfy { $0 >= BotPace.lively - 0.0001 && $0 <= BotPace.calm + 0.0001 })
        XCTAssertTrue(waits.contains { abs($0 - BotPace.calm) < 0.0001 }, "between acts a breath needs few frames")
        XCTAssertTrue(waits.contains { abs($0 - BotPace.lively) < 0.0001 }, "an act or a blink is drawn every frame")
        XCTAssertLessThan(waits.count, 30 * 30 * 3 / 4, "a working bot needs well under thirty frames a second")
    }

    func testReduceMotionLeavesEveryMarkItsLogo() {
        let (view, window) = hosted()
        defer { BotClock.shared.drop(view); window.close() }
        view.apply(config: queue([("Claude", true)]), light: false, scale: 2, animates: false)
        let clock = run(view, from: CACurrentMediaTime(), frames: 2700)
        XCTAssertFalse(clock.moving)
        XCTAssertEqual(view.marks[0].opacity, 1)
        XCTAssertNil(view.marks[0].animation(forKey: "bob"))
    }

    func testNoNewsFadesTheStillLogoToo() {
        for (bots, animates) in [(true, false), (false, true)] {
            let (view, window) = hosted()
            defer { BotClock.shared.drop(view); window.close() }
            var config = queue([("Claude", false), ("Cursor", false)], bots: bots)
            config.items[0].state = BotState(look: .noNews)
            view.apply(config: config, light: false, scale: 2, animates: animates)
            _ = run(view, from: CACurrentMediaTime(), frames: 2)
            XCTAssertEqual(view.marks[0].opacity, 0.5, "bots \(bots), motion \(animates): no news needs no motion to say")
            XCTAssertEqual(view.marks[1].opacity, 1)
        }
    }

    /// Not a benchmark: a guard against a frame becoming expensive enough to show up in the HUD's own cost.
    func testDrawingAQueueBotIsCheap() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Claude", ground: .dark))
        var motion = BotMotion(seed: 2)
        motion.fit(form.spec)
        motion.set(.working, at: 0)
        var now: TimeInterval = 0
        while now < 1 { motion.step(to: now); now += 1.0 / 30 }
        let frames = 200, start = CACurrentMediaTime()
        var drawing: TimeInterval = 0
        for _ in 0..<frames {
            let began = CACurrentMediaTime()
            XCTAssertNotNil(BotRenderer.image(form, motion: motion, side: 40))
            drawing += CACurrentMediaTime() - began
            XCTAssertNotNil(BotRenderer.image(form, motion: motion, side: 40, outline: 1))
        }
        let each = (CACurrentMediaTime() - start) / Double(frames)
        let plain = drawing / Double(frames), outlined = each - plain
        print(String(format: "bot frame at 20 pt @2x: %.3f ms plain, %.3f ms with its hairline", plain * 1000, outlined * 1000))
        XCTAssertLessThan(outlined, 0.004)
    }
}

@MainActor
final class BotFormTimingTests: XCTestCase {
    /// Reading a mark is paid once per vendor, on the main thread, the first time its bot is needed.
    func testReadingAMarkIsQuick() throws {
        var slowest: (String, TimeInterval) = ("", 0), total: TimeInterval = 0
        for vendor in AgentArtwork.allVendors {
            let began = CACurrentMediaTime()
            XCTAssertNotNil(BotForm.read(vendor, ground: .dark))
            let took = CACurrentMediaTime() - began
            total += took
            if took > slowest.1 { slowest = (vendor, took) }
        }
        print(String(format: "reading a mark: %.1f ms on average, %.1f ms at worst (%@)",
                     total / Double(AgentArtwork.allVendors.count) * 1000, slowest.1 * 1000, slowest.0))
        XCTAssertLessThan(slowest.1, 0.25)
    }
}

@MainActor
final class BotMarkTests: XCTestCase {
    private func stage(in view: NSView) -> BotStageView? {
        if let found = view as? BotStageView { return found }
        for child in view.subviews { if let found = stage(in: child) { return found } }
        return nil
    }

    private func hosted<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
        let frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        let window = SeenWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.frame = frame
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// The reminder cards' mark, through SwiftUI and the shared clock, the way the island shows it.
    func testAReminderMarkOpensAsItsLogoAndTurnsIntoItsBotOnceItsCardHasOpened() throws {
        // With Reduce Motion on, as on the build machines, the mark is rightly left a logo.
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion keeps the logo")
        let (host, window) = hosted(BotMark(vendor: "Claude", size: 17, phase: .asking).frame(width: 60, height: 60))
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(BotMark.arrival - 0.3))
        let stage = try XCTUnwrap(stage(in: host), "the bot's layer view was never made")
        let bot = try XCTUnwrap(stage.layer?.sublayers?.first)
        XCTAssertFalse(bot.isHidden)
        XCTAssertNotNil(bot.contents, "the logo is drawn while the card opens")
        XCTAssertEqual(bot.affineTransform().a, 1, accuracy: 0.001, "the logo waits at rest; it does not hop")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3 + 0.7))
        // Asking stays raised: the layer is scaled up from its resting size.
        XCTAssertGreaterThan(bot.affineTransform().a, 1.05)
        BotClock.shared.drop(stage)
    }

    func testWithBotsOffAReminderShowsThePlainLogo() {
        let (host, window) = hosted(BotMark(vendor: "Claude", size: 17, phase: .asking).environment(\.botLogos, false))
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(stage(in: host))
    }
}

/// A window the clock takes for one on screen and uncovered, without putting one on the desktop: the display server may
/// call any test's window covered.
@MainActor
final class SeenWindow: NSWindow {
    var seen = true
    override var isVisible: Bool { seen }
    override var occlusionState: NSWindow.OcclusionState { seen ? [.visible] : [] }
}

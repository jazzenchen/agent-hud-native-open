import AppKit
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class BotClockTests: XCTestCase {
    func testEveryFrameFallsOnAWholeMultipleOfItsPace() {
        XCTAssertEqual(BotPace.lively, 1.0 / 24)
        XCTAssertEqual(BotPace.following / BotPace.lively, 2, accuracy: 1e-9)
        XCTAssertEqual(BotPace.calm / BotPace.lively, 4, accuracy: 1e-9)
        XCTAssertEqual(BotMoves.beat / BotPace.lively, 3, accuracy: 1e-9, "Clawd's beats, an eighth of a second, are frames")

        XCTAssertEqual(BotPace.next(after: 10, every: BotPace.lively), 241.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(BotPace.next(after: 10.01, every: BotPace.calm), 61.0 / 6, accuracy: 1e-9)
        // A step a little early for its frame is on time, so the next frame is the one after it, not the same one.
        XCTAssertEqual(BotPace.next(after: 10 - 0.003, every: BotPace.lively), 241.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(BotPace.next(after: 10.005, every: BotPace.following), 121.0 / 12, accuracy: 1e-9)
        // A wait for a moment ends on the first frame at or after it, and never before the next frame.
        XCTAssertEqual(BotPace.frame(at: 10.02, after: 10), 241.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(BotPace.frame(at: 25.5, after: 10), 25.5, accuracy: 1e-9)
        XCTAssertEqual(BotPace.frame(at: 25.51, after: 10), 613.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(BotPace.frame(at: 3, after: 10), 241.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(BotPace.onFrame(10.003), 10, accuracy: 1e-9)
        XCTAssertEqual(BotPace.onFrame(10.006), 10.006, accuracy: 1e-9)
    }

    /// The timer fires at the soonest frame any follower asks for, however near: there is no longer a frame and a half
    /// below which it keeps its own beat.
    func testTheTimerIsSetForTheSoonestFrameAnyFollowerAsksFor() {
        let clock = BotClock()
        let slow = NSObject(), quick = NSObject(), done = NSObject()
        var waits: [ObjectIdentifier: TimeInterval?] = [ObjectIdentifier(slow): 0.5, ObjectIdentifier(quick): 0.2,
                                                       ObjectIdentifier(done): nil]
        var steps = 0
        for owner in [slow, quick, done] {
            clock.follow(owner) { _ in
                steps += 1
                return waits[ObjectIdentifier(owner)] ?? nil
            }
        }
        defer { for owner in [slow, quick, done] { clock.drop(owner) } }
        XCTAssertTrue(clock.isRunning)
        clock.tick(at: 100)
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(clock.due ?? 0, 100.2, accuracy: 1e-9)
        // The follower that asked for nothing more is let go.
        clock.tick(at: 100.2)
        XCTAssertEqual(steps, 5)
        waits[ObjectIdentifier(quick)] = BotPace.lively * 1.2
        clock.tick(at: 100.25)
        XCTAssertEqual(clock.due ?? 0, 100.25 + BotPace.lively * 1.2, accuracy: 1e-9)
        // With nothing left to ask for, the timer stops.
        waits[ObjectIdentifier(slow)] = .some(nil)
        waits[ObjectIdentifier(quick)] = .some(nil)
        clock.tick(at: 101)
        XCTAssertFalse(clock.isRunning)
        XCTAssertNil(clock.due)
    }

    /// A bot whose window is covered or off screen is left out of the clock, which stops when nothing it steps can be
    /// seen, and comes back the moment it can be seen again.
    func testABotNobodySeesIsLeftOutUntilItCanBeSeenAgain() {
        let clock = BotClock()
        let window = SeenWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless,
                                backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        let other = NSObject()
        var stepped: [String] = []
        clock.follow(view) { _ in stepped.append("seen"); return 0.1 }
        defer { clock.drop(view); clock.drop(other); window.close() }

        window.seen = false
        clock.tick(at: 10)
        XCTAssertEqual(stepped, [], "a covered window's bot is not stepped")
        XCTAssertFalse(clock.isRunning, "and with nothing else to step, nothing wakes the app")
        window.seen = true
        clock.wake()
        XCTAssertTrue(clock.isRunning, "seen again, it is stepped at once")
        clock.tick(at: 40)
        XCTAssertEqual(stepped, ["seen"])

        // A bot on another screen keeps the clock going while this one is covered.
        clock.follow(other) { _ in stepped.append("other"); return 0.3 }
        window.seen = false
        clock.tick(at: 41)
        XCTAssertEqual(stepped, ["seen", "other"])
        XCTAssertEqual(clock.due ?? 0, 41.3, accuracy: 1e-9)
        window.seen = true
        clock.wake()
        clock.tick(at: 41.05)
        XCTAssertEqual(stepped.suffix(2).sorted(), ["other", "seen"])
    }

    func testSleepingDisplaysAndAnAwaySessionStopTheClock() {
        let clock = BotClock()
        let owner = NSObject()
        var steps = 0
        clock.follow(owner) { _ in steps += 1; return 0.1 }
        defer { clock.drop(owner) }
        for leave in [{ clock.screens(asleep: true) }, { clock.session(away: true) }] {
            leave()
            XCTAssertFalse(clock.isRunning)
            clock.tick(at: 1)
            XCTAssertEqual(steps, 0)
            clock.wake()
            XCTAssertFalse(clock.isRunning, "nothing wakes it before the displays or the session are back")
            clock.screens(asleep: false)
            clock.session(away: false)
            XCTAssertTrue(clock.isRunning)
            clock.tick(at: 2)
            XCTAssertEqual(steps, 1)
            steps = 0
        }
    }

    /// A bot stepped again after a long time off the clock is where the clock says it is: its beats at the frame the
    /// shared clock is on, and its morph not played through.
    func testABotComingBackResumesAtTheClocksFrameWithoutReplaying() {
        var clawd = BotMotion(seed: 2)
        clawd.limbed = true
        clawd.set(BotState(look: .thinking), at: 1000)
        var now: TimeInterval = 1000
        while now < 1000.25 { clawd.step(to: now); now += BotPace.lively }
        let morph = clawd.morph
        XCTAssertGreaterThan(morph, 0)
        XCTAssertLessThan(morph, 1)
        clawd.step(to: 1061.375)
        XCTAssertEqual(clawd.morph, morph, "the morph goes on from where it was")
        // The spinner's frame on the shared clock: its six shapes out and back, an eighth of a second each.
        let beat = Int((1061.375 / BotMoves.beat).rounded()) % 10
        XCTAssertEqual(clawd.limbs.spinner, beat < 6 ? beat + 1 : 11 - beat)

        var bot = BotMotion(seed: 2)
        bot.set(BotState(look: .tool(.read)), at: 1000)
        now = 1000
        while now < 1001 { bot.step(to: now); now += BotPace.lively }
        for later in [1031.125, 1031.25, 1033.5] {
            bot.step(to: later)
            XCTAssertEqual(bot.pose.y, BotMoves.bob(at: later - 1000) * bot.morph, accuracy: 1e-9, "at \(later)")
        }
    }
}

import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

final class BotMotionTests: XCTestCase {
    /// Steps a motion at 30 frames a second from `start` for `seconds`.
    private func run(_ motion: inout BotMotion, from start: TimeInterval, for seconds: TimeInterval, aim: CGPoint = .zero) {
        var now = start
        while now <= start + seconds {
            motion.step(to: now, aim: aim)
            now += 1.0 / 30
        }
    }

    func testAnOpenedMarkIsItsBotWatchingThePointerUntilItsCardCloses() {
        var motion = BotMotion(seed: 3)
        motion.set(.idle, at: 10)
        run(&motion, from: 10, for: 0.5)
        XCTAssertEqual(motion.morph, 0)
        motion.set(.opened, at: 10.5)
        run(&motion, from: 10.5, for: 1, aim: CGPoint(x: 0.6, y: 0.2))
        XCTAssertEqual(motion.morph, 1, "half a second after its card opens it is the bot")
        XCTAssertEqual(motion.pose.y, 0, "and it stays where its logo was")
        XCTAssertGreaterThan(motion.face.look, 0.3, "its eyes go to the pointer")
        // However long the panel stays open, the bot stays up.
        run(&motion, from: 11.5, for: 120, aim: CGPoint(x: 0.6, y: 0.2))
        XCTAssertEqual(motion.morph, 1)
        XCTAssertFalse(motion.isAtRest)
        XCTAssertNotNil(motion.wait)
        // The panel closes over an idle agent: back to the logo.
        motion.set(.idle, at: 131.5)
        run(&motion, from: 131.5, for: 1)
        XCTAssertEqual(motion.morph, 0)
        // And over a working one, the bot simply stays.
        var busy = BotMotion(seed: 3)
        busy.set(.opened, at: 10)
        run(&busy, from: 10, for: 2)
        busy.set(.working, at: 12)
        run(&busy, from: 12, for: 1)
        XCTAssertEqual(busy.morph, 1)
    }

    /// Clawd's arms and legs over a few seconds of one phase, after another, with a pointer to the right.
    private func limbs(_ phases: [(BotPhase, TimeInterval)], for seconds: TimeInterval, seed: UInt64 = 3) -> [(TimeInterval, BotLimbs)] {
        signed(phases, for: seconds, seed: seed).map { ($0.0, $0.1) }
    }

    /// The same, with the sign over its head at each moment.
    private func signed(_ phases: [(BotPhase, TimeInterval)], for seconds: TimeInterval,
                        seed: UInt64 = 3) -> [(TimeInterval, BotLimbs, BotSign?)] {
        var motion = BotMotion(seed: seed)
        motion.limbed = true
        var seen: [(TimeInterval, BotLimbs, BotSign?)] = [], now: TimeInterval = 0, next = 0
        while now <= seconds {
            while next < phases.count, phases[next].1 <= now { motion.set(phases[next].0, at: now); next += 1 }
            motion.step(to: now, aim: CGPoint(x: 0.6, y: 0.2))
            seen.append((now, motion.limbs, motion.sign))
            now += 1.0 / 30
        }
        return seen
    }

    func testABotWithArmsWavesAtWhoeverOpensItsCard() throws {
        let seen = limbs([(.idle, 0), (.opened, 2)], for: 4)
        XCTAssertTrue(seen.filter { $0.0 < 2 }.allSatisfy { $0.1 == BotLimbs() }, "a resting logo keeps still")
        // Once it has turned into its bot, the arm on the pointer's side goes up and out, and waves.
        let up = try XCTUnwrap(seen.first { $0.1.right == 2 })
        XCTAssertLessThan(up.0, 2.8)
        XCTAssertEqual(up.1.left, 0)
        let wave = seen.filter { $0.0 > up.0 && $0.0 < up.0 + 1 }.map(\.1.right)
        XCTAssertTrue(wave.contains(1) && wave.contains(2))
        // A bot without arms keeps them at rest whatever it does.
        var plain = BotMotion(seed: 3)
        plain.set(.opened, at: 0)
        for frame in 0...90 { plain.step(to: Double(frame) / 30, aim: CGPoint(x: 0.6, y: 0.2)) }
        XCTAssertEqual(plain.limbs, BotLimbs())
    }

    func testABotWithArmsTypesUnderTheSpinnerAndStepsAndJumpsWhileItsAgentWorks() {
        let signed = signed([(.working, 0)], for: 60), seen = signed.map(\.1)
        XCTAssertTrue(seen.allSatisfy { (1...6).contains($0.spinner) }, "Claude Code's spinner over its head throughout")
        XCTAssertTrue(signed.allSatisfy { $0.2 == nil }, "and no sign")
        XCTAssertEqual(Set(seen.map(\.spinner)).count, 6, "through all six of its shapes")
        XCTAssertTrue(seen.contains { $0.left == 1 && $0.right == 0 } && seen.contains { $0.left == 0 && $0.right == 1 },
                      "typing, a hand at a time")
        XCTAssertTrue(seen.contains { abs($0.x) == 2 && $0.lifted > 0 }, "stepping aside, legs going")
        XCTAssertTrue(seen.contains { $0.y == -3 && $0.left == 2 && $0.right == 2 }, "jumping, arms flung up")
        XCTAssertTrue(seen.allSatisfy { abs($0.x) <= 2 && (-3...1).contains($0.y) }, "never far from its place")
    }

    func testABotWithArmsCallsForAnAnswerAndDancesForAReply() {
        let signed = signed([(.asking, 0)], for: 6), asking = signed.map(\.1)
        XCTAssertTrue(signed.allSatisfy { $0.2 == .exclamation && $0.1.spinner == 0 }, "an exclamation mark over its head")
        XCTAssertTrue(asking.contains { $0.left == 2 && $0.right == 1 } && asking.contains { $0.left == 1 && $0.right == 2 },
                      "both arms waving in turn")
        XCTAssertTrue(asking.contains { $0.y == -2 && $0.lifted == 3 }, "jumping at a knock")
        let between = limbs([(.asking, 0)], for: 3.5).filter { $0.0 > 2 }.map(\.1)
        XCTAssertTrue(between.allSatisfy { $0.left == 0 && $0.right == 2 && $0.y == 0 }, "a hand up, still, between knocks")

        let reply = limbs([(.working, 0), (.done, 1)], for: 4).filter { $0.0 > 1 }
        XCTAssertTrue(reply.contains { $0.1.left == 2 && $0.1.right == 0 } && reply.contains { $0.1.left == 0 && $0.1.right == 2 },
                      "arms up in turn")
        XCTAssertTrue(reply.contains { $0.1.y == -2 }, "a jump on every other beat")
        XCTAssertTrue(reply.filter { $0.0 > 2.7 }.allSatisfy { $0.1 == BotLimbs() }, "and still again")
    }

    func testAShortVisitOfABotWithArmsIsOneOfItsOwnMoves() {
        let visits = limbs([(.idle, 0)], for: 120).filter { $0.1 != BotLimbs() }
        XCTAssertFalse(visits.isEmpty)
        XCTAssertTrue(visits.contains { $0.1.x != 0 || $0.1.y != 0 || $0.1.left > 0 || $0.1.right > 0 })
    }

    func testAMarkFollowsItsAgentAndALookAtItsCardPutsThePointerOnTop() {
        XCTAssertEqual(MarkAttention.none.state(of: BotState(look: .plain)).phase, .working)
        XCTAssertEqual(MarkAttention.none.state(of: BotState()).phase, .idle)
        XCTAssertEqual(MarkAttention.opened.state(of: BotState(look: .plain)), BotState(look: .plain, hovered: true))
        XCTAssertEqual(MarkAttention.opened.state(of: BotState()).phase, .opened)
    }

    func testANewIdleMarkWaitsAsItsLogoWithoutStoppingItsClock() {
        var motion = BotMotion(seed: 1)
        motion.set(.idle, at: 100)
        run(&motion, from: 100, for: 2)
        XCTAssertEqual(motion.morph, 0)
        XCTAssertEqual(motion.pose, BotPose())
        XCTAssertFalse(motion.isAtRest, "an initial idle phase still needs the clock for its first visit")
    }

    func testAnIdleMarkAsksForNoFrameUntilItsVisitAndStartsItFromTheLogo() throws {
        var motion = BotMotion(seed: 1)
        motion.set(.idle, at: 100)
        motion.step(to: 100)
        let wait = try XCTUnwrap(motion.wait)
        XCTAssertGreaterThanOrEqual(wait, 20)
        XCTAssertLessThanOrEqual(wait, 35)
        // Woken exactly then, after a sleep far longer than a frame: the morph begins, it does not jump ahead.
        motion.step(to: 100 + wait)
        XCTAssertEqual(motion.morph, 0)
        XCTAssertEqual(try XCTUnwrap(motion.wait), BotPace.lively, accuracy: 0.0001)
        motion.step(to: 100 + wait + BotPace.lively)
        XCTAssertEqual(motion.morph, CGFloat(BotPace.lively / 0.5), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(motion.wait), BotPace.lively, accuracy: 0.0001)
    }

    func testAStillBotWaitsForItsBlinkAndItsEyesFollowAMovedPointerAtTheirOwnPace() throws {
        // An alert's bot after its smile: no acts and no breath, only eyes that look where the pointer is.
        var motion = BotMotion(seed: 1)
        motion.staysBot = true
        motion.set(.done, at: 0)
        // Up to just before its first blink, two seconds in: nothing moves until then.
        run(&motion, from: 0, for: 1.7)
        motion.step(to: 1.8)
        XCTAssertEqual(try XCTUnwrap(motion.wait), 2 - 1.8, accuracy: 0.0001)
        motion.step(to: 1.9, aim: CGPoint(x: 0.8, y: 0.3))
        XCTAssertEqual(try XCTUnwrap(motion.wait), BotPace.following - 1.9.truncatingRemainder(dividingBy: BotPace.following),
                       accuracy: 0.0001, "the next frame of the pointer's pace")
    }

    func testAMarkAtRestAsksForNothing() {
        var motion = BotMotion(seed: 1)
        motion.set(.working, at: 0)
        run(&motion, from: 0, for: 1)
        motion.set(.done, at: 1)
        run(&motion, from: 1, for: 3)
        XCTAssertTrue(motion.isAtRest)
        XCTAssertNil(motion.wait)
    }

    func testWorkTurnsTheLogoIntoItsBotInHalfASecond() {
        var motion = BotMotion(seed: 1)
        motion.set(.working, at: 0)
        run(&motion, from: 0, for: 0.3)
        XCTAssertGreaterThan(motion.morph, 0)
        XCTAssertLessThan(motion.morph, 1)
        run(&motion, from: 0.3, for: 0.4)
        XCTAssertEqual(motion.morph, 1)
        XCTAssertFalse(motion.isAtRest)
    }

    func testWorkStaysItsBotThroughoutLongRunningWork() {
        var motion = BotMotion(seed: 1)
        motion.set(.working, at: 0)
        for frame in 0...3600 {
            motion.step(to: Double(frame) / 30)
            XCTAssertEqual(motion.phase, .working)
            if frame >= 16 { XCTAssertEqual(motion.morph, 1) }
            XCTAssertFalse(motion.isAtRest)
        }
    }

    func testIdleVisitsItsBotBrieflyWithoutStoppingItsClockOrResettingItsSchedule() {
        var motion = BotMotion(seed: 1)
        motion.set(.idle, at: 0)
        var bots: [TimeInterval] = [], logos: [TimeInterval] = []
        var sawBodyAction = false, sawExpression = false
        for frame in 0...7200 {
            let now = Double(frame) / 30, before = motion.morph, face = motion.face
            // Repeated view updates must not postpone the visit by scheduling another twenty seconds.
            motion.set(.idle, at: now)
            motion.step(to: now, aim: CGPoint(x: 0.8, y: -0.6))
            XCTAssertEqual(motion.phase, .idle)
            XCTAssertFalse(motion.isAtRest, "the clock must survive the logo wait and the bot visit")
            XCTAssertLessThanOrEqual(abs(motion.morph - before), 1.0 / 15 + 0.0001)
            if before == 0, motion.morph > 0 { bots.append(now) }
            if before > 0, motion.morph == 0 { logos.append(now) }
            if motion.morph == 0 {
                XCTAssertEqual(motion.pose, BotPose(), "the original logo stays still")
                if before == 0 { XCTAssertEqual(motion.face, face, "hidden eyes need no animation frames") }
            } else {
                if motion.pose != BotPose() { sawBodyAction = true }
                if motion.face != BotFace() { sawExpression = true }
            }
        }
        XCTAssertGreaterThanOrEqual(logos.count, 5)
        XCTAssertGreaterThanOrEqual(bots.count, logos.count)
        XCTAssertGreaterThanOrEqual(bots.first ?? 0, 20)
        XCTAssertLessThanOrEqual(bots.first ?? 100, 35.1)
        for (bot, logo) in zip(bots, logos) {
            XCTAssertGreaterThanOrEqual(logo - bot, 2.9)
            XCTAssertLessThanOrEqual(logo - bot, 5.1)
        }
        for (logo, bot) in zip(logos, bots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(bot - logo, 20)
            XCTAssertLessThanOrEqual(bot - logo, 35.1)
        }
        XCTAssertTrue(sawBodyAction)
        XCTAssertTrue(sawExpression)
    }

    func testIdleAndWorkKeepTheWholeBotAndItsRetainedArtworkInPlace() {
        for phase in [BotPhase.idle, .working] {
            for seed in 1...8 {
                var motion = BotMotion(seed: UInt64(seed))
                motion.spin = 9
                motion.set(phase, at: 0)
                for frame in 0...1800 {
                    motion.step(to: Double(frame) / 30, aim: CGPoint(x: 0.8, y: -0.6))
                    XCTAssertEqual(motion.pose.x, 0)
                    XCTAssertEqual(motion.pose.y, 0)
                    XCTAssertEqual(motion.kept.lift, 0)
                    XCTAssertEqual(motion.kept.scale, 1)
                    for runsDown in [true, false] {
                        let transform = BotActor.transform(motion.pose, side: 36, yRunsDown: runsDown)
                        XCTAssertEqual(transform.tx, 0)
                        XCTAssertEqual(transform.ty, 0)
                    }
                }
            }
        }
    }

    func testDifferentSeedsTakeTheirIdleBotVisitsIndependently() {
        var first = BotMotion(seed: 1), other = BotMotion(seed: 7)
        first.set(.idle, at: 0); other.set(.idle, at: 0)
        var differed = false
        for frame in 0...1800 {
            let now = Double(frame) / 30
            first.step(to: now); other.step(to: now)
            if (first.morph == 0) != (other.morph == 0) { differed = true }
        }
        XCTAssertTrue(differed)
    }

    func testAnAlertStaysItsBotThroughoutLongRunningIdle() {
        var motion = BotMotion(seed: 1)
        motion.staysBot = true
        motion.set(.idle, at: 0)
        for frame in 0...1800 {
            motion.step(to: Double(frame) / 30)
            if frame >= 16 { XCTAssertEqual(motion.morph, 1) }
            XCTAssertFalse(motion.isAtRest)
        }
    }

    func testWorkAskingAndDoneTakePriorityOverAnIdleWaitOrVisit() {
        for visiting in [false, true] {
            for phase in [BotPhase.working, .asking, .done] {
                var motion = BotMotion(seed: 1)
                motion.set(.idle, at: 0)
                var now: TimeInterval = 0
                if visiting {
                    for frame in 0...1100 {
                        now = Double(frame) / 30
                        motion.step(to: now)
                        if motion.morph == 1 { break }
                    }
                    XCTAssertEqual(motion.morph, 1, "idle must visit its bot before thirty-six seconds")
                } else {
                    now = 10
                    run(&motion, from: 0, for: now)
                    XCTAssertEqual(motion.morph, 0)
                }
                motion.set(phase, at: now)
                run(&motion, from: now, for: 0.8)
                XCTAssertEqual(motion.morph, 1)
                XCTAssertFalse(motion.isAtRest)
                if phase == .asking { XCTAssertGreaterThan(motion.pose.scaleX, 1.05) }
                else if phase == .done { XCTAssertGreaterThan(motion.face.happy, 0.9) }
                if phase == .working {
                    run(&motion, from: now + 0.8, for: 60)
                    XCTAssertEqual(motion.morph, 1, "the old idle visit must not fade out a running bot")
                }
            }
        }
    }

    func testReturningFromAskingToIdleOrWorkImmediatelyFixesTheCentre() {
        for phase in [BotPhase.idle, .working] {
            var motion = BotMotion(seed: 1)
            motion.set(.asking, at: 0)
            run(&motion, from: 0, for: 0.2)
            XCTAssertLessThan(motion.pose.y, 0)
            XCTAssertGreaterThan(motion.kept.lift, 0)
            motion.set(phase, at: 0.2)
            motion.step(to: 0.2, aim: CGPoint(x: 0.8, y: 0.3))
            XCTAssertEqual(motion.pose.x, 0)
            XCTAssertEqual(motion.pose.y, 0)
            XCTAssertEqual(motion.pose.footing, 0)
            XCTAssertEqual(motion.kept.lift, 0)
        }
    }

    func testAFinishedTurnSmilesThenSettlesBackIntoTheLogo() {
        var motion = BotMotion(seed: 1)
        motion.set(.working, at: 0)
        run(&motion, from: 0, for: 1)
        motion.set(.done, at: 1)
        run(&motion, from: 1, for: 0.8)
        XCTAssertGreaterThan(motion.face.happy, 0.9)
        XCTAssertEqual(motion.morph, 1)
        run(&motion, from: 1.8, for: 2)
        XCTAssertEqual(motion.morph, 0)
        XCTAssertTrue(motion.isAtRest)
    }

    func testAnAlertKeepsItsBotAfterTheSmile() {
        var motion = BotMotion(seed: 1)
        motion.staysBot = true
        motion.set(.done, at: 0)
        run(&motion, from: 0, for: 4)
        XCTAssertEqual(motion.morph, 1)
        XCTAssertLessThan(motion.face.happy, 0.05)
        XCTAssertFalse(motion.isAtRest)
    }

    func testAskingFacesTheUserWithWideEyesWhateverItWasLookingAt() {
        var motion = BotMotion(seed: 1)
        motion.set(.working, at: 0)
        // The first random act starts no earlier than 0.9 seconds; establish the aimed gaze before it.
        run(&motion, from: 0, for: 0.8, aim: CGPoint(x: 0.8, y: 0.3))
        XCTAssertGreaterThan(motion.face.look, 0.3)
        motion.set(.asking, at: 0.8)
        run(&motion, from: 0.8, for: 1, aim: CGPoint(x: 0.8, y: 0.3))
        XCTAssertEqual(motion.face.look, 0, accuracy: 0.02)
        XCTAssertEqual(motion.face.lookY, 0, accuracy: 0.02)
        XCTAssertGreaterThan(motion.face.wide, 1.15)
        XCTAssertGreaterThan(motion.pose.scaleX, 1.05)
    }

    func testTheSameSeedReplaysTheSameActs() {
        for phase in [BotPhase.idle, .working] {
            var first = BotMotion(seed: 42), second = BotMotion(seed: 42), other = BotMotion(seed: 7)
            first.set(phase, at: 0); second.set(phase, at: 0); other.set(phase, at: 0)
            var differed = false
            for frame in 0...2700 {
                let now = Double(frame) / 30
                first.step(to: now); second.step(to: now); other.step(to: now)
                XCTAssertEqual(first.face, second.face)
                XCTAssertEqual(first.pose, second.pose)
                XCTAssertEqual(first.morph, second.morph)
                if first.face != other.face || first.pose != other.pose || first.morph != other.morph {
                    differed = true
                }
            }
            XCTAssertTrue(differed)
        }
    }

    func testAimTurnsLessTowardsSomethingClose() {
        let near = BotMotion.aim(from: .zero, to: CGPoint(x: 30, y: 0))
        let far = BotMotion.aim(from: .zero, to: CGPoint(x: 900, y: 0))
        XCTAssertGreaterThan(far.x, near.x)
        XCTAssertLessThan(far.x, 1)
        XCTAssertEqual(BotMotion.aim(from: .zero, to: .zero), .zero)
        // Down on screen is down for the eyes.
        XCTAssertGreaterThan(BotMotion.aim(from: .zero, to: CGPoint(x: 0, y: 200)).y, 0)
    }

    func testAPoseLiftsAndTurnsTheSameWayWhicheverWayUpTheLayerIs() {
        var pose = BotPose()
        pose.y = -0.2
        pose.rotation = 10
        let down = BotActor.transform(pose, side: 20, yRunsDown: true)
        let up = BotActor.transform(pose, side: 20, yRunsDown: false)
        // A hop moves up the screen: less y where y runs down, more where it runs up.
        XCTAssertEqual(down.ty, -4, accuracy: 0.001)
        XCTAssertEqual(up.ty, 4, accuracy: 0.001)
        XCTAssertEqual(down.b, -up.b, accuracy: 0.001)
    }

    func testAReminderOpensAsItsLogoAndTurnsIntoItsBotOnceItArrives() throws {
        var motion = BotMotion(seed: 1)
        motion.staysBot = true
        motion.arrivesAfter = 0.7
        motion.set(.asking, at: 100)
        motion.step(to: 100)
        XCTAssertEqual(motion.morph, 0)
        XCTAssertEqual(motion.pose, BotPose(), "the logo does not hop")
        XCTAssertEqual(try XCTUnwrap(motion.wait), 0.7, accuracy: BotPace.lively, "nothing changes until it arrives")
        run(&motion, from: 100, for: 0.66)
        XCTAssertEqual(motion.morph, 0, "still the logo while its card opens")
        XCTAssertEqual(motion.pose, BotPose())
        XCTAssertFalse(motion.isAtRest)

        run(&motion, from: 100.7, for: 0.2)
        XCTAssertGreaterThan(motion.morph, 0)
        XCTAssertLessThan(motion.morph, 1)
        XCTAssertLessThan(motion.pose.y, 0, "the hop begins with the bot, not before it")
        run(&motion, from: 100.9 + 1.0 / 30, for: 0.5)
        XCTAssertEqual(motion.morph, 1)
    }

    func testOnlyAStayingBotWithAHoldWaitsAsItsLogo() {
        var staying = BotMotion(seed: 1)
        staying.staysBot = true
        staying.set(.done, at: 50)
        run(&staying, from: 50, for: 0.2)
        XCTAssertGreaterThan(staying.morph, 0, "with no hold a staying bot starts at once")

        var queued = BotMotion(seed: 1)
        queued.arrivesAfter = 0.7
        queued.set(.working, at: 50)
        run(&queued, from: 50, for: 0.2)
        XCTAssertGreaterThan(queued.morph, 0, "a mark that follows its agent is never held")
    }
}

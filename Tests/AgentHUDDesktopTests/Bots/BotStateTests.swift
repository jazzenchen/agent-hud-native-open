import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

/// The looks, events, badges and greetings a bot acts out, stepped the way the clock steps it: at the frames it asks for.
final class BotStateTests: XCTestCase {
    /// One frame of a motion: when it was stepped, and the motion then.
    private typealias Frame = (now: TimeInterval, motion: BotMotion)

    /// Steps `motion` from `start` for `seconds` at the frames it asks for, until it asks for none. Every frame it asks
    /// for falls on the shared clock.
    @discardableResult
    private func drive(_ motion: inout BotMotion, from start: TimeInterval, for seconds: TimeInterval,
                       aim: CGPoint = .zero, file: StaticString = #filePath, line: UInt = #line) -> [Frame] {
        var now = start, frames: [Frame] = []
        while now < start + seconds {
            motion.step(to: now, aim: aim)
            frames.append((now, motion))
            guard let wait = motion.wait else { break }
            XCTAssertGreaterThan(wait, 0, file: file, line: line)
            let due = (now + wait) / BotPace.lively
            XCTAssertEqual(due, due.rounded(), accuracy: 0.001, "a frame off the shared clock", file: file, line: line)
            now += wait
        }
        return frames
    }

    private func bot(_ vendor: String? = nil, seed: UInt64 = 5) -> BotMotion {
        var motion = BotMotion(seed: seed)
        if let vendor, let spec = BotSpec.table[vendor] { motion.fit(spec) }
        // A breath this slow leaves the body's shape alone, so what a look or an event does to it shows.
        motion.period = 10_000
        return motion
    }

    // MARK: The vocabulary

    func testTheOldPhasesAreStatesAndBack() {
        XCTAssertEqual(BotPhase.idle.state, BotState())
        XCTAssertEqual(BotPhase.working.state, BotState(look: .plain))
        XCTAssertEqual(BotPhase.asking.state, BotState(look: .permission))
        XCTAssertEqual(BotPhase.done.state, BotState(look: .done))
        XCTAssertEqual(BotPhase.opened.state, BotState(look: .idle, hovered: true))
        for phase in [BotPhase.idle, .working, .asking, .done, .opened] { XCTAssertEqual(phase.state.phase, phase) }
        XCTAssertEqual(BotState(look: .thinking).phase, .working)
        XCTAssertEqual(BotState(look: .tool(.longCommand), hovered: true).phase, .working)
        XCTAssertEqual(BotState(look: .plan).phase, .asking)
        XCTAssertEqual(BotState(look: .asleep).phase, .idle)

        XCTAssertEqual(BotLook.allCases.count, 14)
        XCTAssertEqual(BotLook.allCases.filter(\.isAttention), [.permission, .question, .plan])
        XCTAssertEqual(BotLook.allCases.filter(\.isCalm), [.noNews, .idle, .asleep])
        XCTAssertEqual(BotLook.allCases.filter(\.isWorking).count, 7)
        XCTAssertFalse(BotLook.done.staysInPlace)
        XCTAssertGreaterThan(BotEvent.failed.rank, BotEvent.limitHit.rank)
        XCTAssertGreaterThan(BotEvent.limitHit.rank, BotEvent.start.rank)
    }

    func testACardSaysWhichGoodNewsItGreets() {
        XCTAssertEqual(BotState(card: .reset), BotState(look: .done, card: .reset))
        XCTAssertEqual(BotState(card: .longDone).phase, .done)
        XCTAssertEqual(BotState(look: .done).card, .done, "a reply, unless told otherwise")
        let end = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(BotCard.reply(from: end.addingTimeInterval(-600), to: end), .longDone, "ten minutes or more")
        XCTAssertEqual(BotCard.reply(from: end.addingTimeInterval(-599), to: end), .done)
        XCTAssertEqual(BotCard.reply(from: nil, to: end), .done, "a turn whose start is not known")
    }

    /// Every look, under the pointer or not, on a bot with limbs or without, staying or following its agent: each frame
    /// on the shared clock, and each look either at rest or still asking for frames when it should.
    func testEveryLookSettlesRestsOrKeepsTheClockAsItShould() {
        for look in BotLook.allCases {
            for hovered in [false, true] {
                for limbed in [false, true] {
                    for staysBot in [false, true] {
                        var motion = bot()
                        motion.limbed = limbed
                        motion.staysBot = staysBot
                        motion.set(BotState(look: look, hovered: hovered), at: 1000.01)
                        let frames = drive(&motion, from: 1000.01, for: 300)
                        let place = "\(look) hovered \(hovered) limbed \(limbed) staying \(staysBot)"
                        XCTAssertTrue(frames.allSatisfy { (0...1).contains($0.motion.morph) }, place)
                        // A logo with nothing to visit rests; so does a bot with nothing left that moves: a doze that
                        // stays, and Clawd sitting with its eyes shut.
                        let restsAsLogo = !staysBot && !hovered && (look == .noNews || look == .done)
                        let restsAsBot = !hovered && (look == .asleep && staysBot || look == .compacting && limbed)
                        if restsAsLogo || restsAsBot {
                            XCTAssertNil(motion.wait, "\(place): rests with no clock")
                            XCTAssertEqual(motion.morph, restsAsLogo ? 0 : 1, place)
                        } else {
                            XCTAssertNotNil(motion.wait, "\(place): keeps its clock")
                        }
                        // However long it goes on, no look asks for more than the lively pace.
                        let last = frames.filter { $0.now > 1240 }
                        XCTAssertLessThanOrEqual(Double(last.count), 60 / BotPace.lively + 1, place)
                    }
                }
            }
        }
    }

    // MARK: Waiting requests

    /// A request is acted out in full for its first seconds, then with one move every 2.6 s and nothing between, and
    /// after two minutes with one every 8 s.
    func testALongWaitIsActedOutLessAndLessOften() {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .permission), at: 0)
        let frames = drive(&motion, from: 0, for: 200)
        func rate(_ range: Range<TimeInterval>) -> Double {
            Double(frames.filter { range.contains($0.now) }.count) / (range.upperBound - range.lowerBound)
        }
        XCTAssertGreaterThan(rate(0..<8), rate(30..<90))
        XCTAssertLessThan(rate(30..<90), 8)
        XCTAssertLessThan(rate(130..<190), rate(30..<90) / 2)
        XCTAssertLessThan(rate(130..<190), 3)
        for frame in frames where frame.now >= BotMoves.fullWait {
            let move = BotMoves.move(at: frame.now)
            let into = frame.now - (move.start ?? 0)
            // A frame comes only for a move: as it starts, through it, and the frame that leaves it still.
            XCTAssertLessThan(into, BotMoves.moveLength(.permission) + 2 * BotPace.lively, "a frame at \(frame.now)")
            if into > BotMoves.moveLength(.permission) { XCTAssertEqual(frame.motion.pose.rotation, 0) }
        }
        let late = frames.filter { $0.now > 125 }.map(\.now)
        XCTAssertTrue(late.contains { abs($0 - 120.8) < 0.05 } || late.contains { abs($0 - 128.8) < 0.05 }, "moves 8 s apart")
        XCTAssertEqual(motion.sign, .exclamation)
    }

    func testAQuestionHoldsATiltAndSwitchesSidesAndAPlanNods() throws {
        var question = bot("Grok Bot")
        question.set(BotState(look: .question), at: 0)
        let asked = drive(&question, from: 0, for: 12)
        func rotation(at time: TimeInterval) throws -> CGFloat {
            try XCTUnwrap(asked.last { $0.now <= time }).motion.pose.rotation
        }
        XCTAssertEqual(try rotation(at: 1.1), 0, accuracy: 0.001, "upright through the hop")
        XCTAssertEqual(try rotation(at: 3.5), 12, accuracy: 0.01, "over to one side, held")
        XCTAssertEqual(try rotation(at: 6.0), -12, accuracy: 0.01, "and to the other at the next move")
        XCTAssertEqual(try rotation(at: 8.5), 12, accuracy: 0.01)
        XCTAssertEqual(question.sign, .question)

        var plan = bot("Grok Bot")
        plan.set(BotState(look: .plan), at: 0)
        let planned = drive(&plan, from: 0, for: 12)
        let nods = planned.filter { $0.now > 3.8 && $0.now < 3.8 + 0.6 }.map(\.motion.pose.y)
        XCTAssertGreaterThan(nods.max() ?? 0, 0.02, "a nod down over the plan")
        XCTAssertTrue(planned.filter { $0.now > 2 && $0.now < 3.7 }.allSatisfy { $0.motion.pose.y == 0 }, "still between")
        XCTAssertGreaterThan(planned.filter { $0.now > 3.9 && $0.now < 4.3 }.map(\.motion.face.lookY).max() ?? 0, 0.2,
                             "eyes down at the plan")
        XCTAssertEqual(plan.sign, .lines)

        var permission = bot("Grok Bot")
        permission.set(BotState(look: .permission), at: 0)
        let knocks = drive(&permission, from: 0, for: 4).filter { $0.now > 1.2 && $0.now < 1.75 }
        XCTAssertGreaterThan(knocks.map { abs($0.motion.pose.rotation) }.max() ?? 0, 3, "a knock, as before")
    }

    /// Under the pointer a waiting bot keeps its moves and only turns its eyes; otherwise it stares at the user.
    func testAWaitingBotWatchesThePointerOnlyUnderIt() {
        for hovered in [false, true] {
            var motion = bot("Grok Bot")
            motion.set(BotState(look: .permission, hovered: hovered), at: 0)
            drive(&motion, from: 0, for: 3, aim: CGPoint(x: 0.7, y: 0.2))
            if hovered { XCTAssertGreaterThan(motion.face.look, 0.5) } else { XCTAssertEqual(motion.face.look, 0, accuracy: 0.02) }
            XCTAssertGreaterThan(motion.face.wide, 1.15)
            XCTAssertGreaterThan(motion.pose.scaleX, 1.05, "raised either way")
        }
    }

    /// On a dock that keeps its marks beside the card, a waiting bot whose card is up hops and rises as ever, then keeps
    /// still with its eyes on the card, and its clock stops.
    func testAWaitingBotTurnedToItsCardStaysRaisedAndStillWithEyesOnIt() {
        for (facing, look) in [(BotFacing.left, BotLook.permission), (.down, .question), (.right, .plan)] {
            var motion = bot("Grok Bot")
            motion.set(BotState(look: look, facing: facing), at: 0)
            let frames = drive(&motion, from: 0, for: 30)
            XCTAssertNil(motion.wait, "\(look): at rest once raised")
            XCTAssertLessThan(frames.last?.now ?? 30, 2)
            XCTAssertTrue(frames.filter { $0.now > 0.5 }.allSatisfy { $0.motion.pose.rotation == 0 }, "\(look): no knock or tilt")
            XCTAssertGreaterThan(motion.pose.scaleX, 1.05, "\(look): raised")
            XCTAssertEqual(motion.face.look, facing.aim.x, accuracy: 0.02)
            XCTAssertEqual(motion.face.lookY, facing.aim.y, accuracy: 0.02)
            // The card goes and the moves come back.
            motion.set(BotState(look: look), at: 40)
            XCTAssertNotNil(drive(&motion, from: 40, for: 5).last?.motion.wait)
        }
        var clawd = bot()
        clawd.limbed = true
        clawd.set(BotState(look: .permission, facing: .left), at: 0)
        drive(&clawd, from: 0, for: 5)
        XCTAssertEqual(clawd.limbs, BotLimbs(left: 2), "the drawn Clawd holds up the hand on the card's side")
        XCTAssertNil(clawd.wait)
        var below = bot()
        below.limbed = true
        below.set(BotState(look: .permission, facing: .down), at: 0)
        drive(&below, from: 0, for: 5)
        XCTAssertEqual(below.limbs, BotLimbs(), "and none for a card below it, which a hand would point past")
        XCTAssertEqual(below.sign, .exclamation)
        XCTAssertEqual(BotFacing(cardFrom: .top), .down)
        XCTAssertEqual(BotFacing(cardFrom: .right), .left)
    }

    /// A bot built again where it was showing takes up its look at once: no morph from the logo, no hop, no blend.
    func testAResumedBotTakesUpItsLookWithNoMorphOrIntro() {
        for look in [BotLook.tool(.command), .thinking, .permission] {
            var motion = bot("Grok Bot")
            motion.set(BotState(look: look), at: 100)
            motion.resume(at: 100)
            motion.step(to: 100)
            XCTAssertEqual(motion.morph, 1, "\(look)")
            XCTAssertEqual(motion.pose.y, 0, accuracy: 0.0001, "\(look): no hop")
            if look.isAttention { XCTAssertEqual(motion.pose.scaleX, 1.12, accuracy: 0.01, "raised already") }
        }
        var idle = bot()
        idle.set(BotState(look: .idle), at: 100)
        idle.resume(at: 100)
        idle.step(to: 100)
        XCTAssertEqual(idle.morph, 0, "a resting mark is its logo")
    }

    // MARK: Working

    func testThinkingLooksUpAndAsideTiltsAndLightsItsDots() {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .thinking), at: 1000)
        let frames = drive(&motion, from: 1000, for: 8)
        for frame in frames where frame.now > 1001 {
            let side = BotMoves.ponderSide(at: frame.now), face = frame.motion.face
            // Settled eyes, half a second after each change of side.
            let sinceSwitch = frame.now - (frame.now / BotMoves.ponder).rounded(.down) * BotMoves.ponder
            if sinceSwitch > 0.6, sinceSwitch < BotMoves.ponder - 0.05 {
                XCTAssertEqual(face.look, 0.4 * side, accuracy: 0.02, "at \(frame.now)")
                XCTAssertEqual(face.lookY, -0.7, accuracy: 0.02)
                XCTAssertEqual(frame.motion.pose.rotation, 5 * side, accuracy: 0.3, "leaning toward the gaze")
            }
            XCTAssertLessThanOrEqual(abs(frame.motion.pose.rotation), 5.001)
            XCTAssertEqual(frame.motion.sign, .ellipsis)
            XCTAssertEqual(frame.motion.lit, Int((frame.now * 3 + 1e-6).rounded(.down)) % 3)
        }
        XCTAssertEqual(Set(frames.map(\.motion.lit)), [0, 1, 2], "each dot lit in turn")
        XCTAssertTrue(frames.allSatisfy { $0.motion.pose.x == 0 && $0.motion.pose.y == 0 }, "in its place")
    }

    /// A tool bobs the whole body down on every other beat for three seconds, then rests a second and a half; a body
    /// that spins spins faster through the bursts and not at all through the rests.
    func testAToolBobsOnTheBeatInBurstsAndRests() {
        var motion = bot("ChatGPT")
        let start: TimeInterval = 1000
        motion.set(BotState(look: .tool(.command)), at: start)
        let frames = drive(&motion, from: start, for: 13.5)
        for frame in frames where frame.now > start + 0.6 {
            let time = frame.now - start, beat = Int(time / BotMoves.beat + 1e-6)
            let bursting = time.truncatingRemainder(dividingBy: 4.5) < 3 - 1e-6
            XCTAssertEqual(frame.motion.pose.y, bursting && beat % 2 == 1 ? 0.04 : 0, accuracy: 0.0001, "at \(time)")
        }
        // Through a burst nothing but the beat asks for a frame, unless the eyes or an act do.
        let burst = frames.filter { $0.now > start + 4.6 && $0.now < start + 7.4 }
        XCTAssertLessThanOrEqual(burst.count, Int(2.8 / BotPace.lively))
        XCTAssertGreaterThanOrEqual(burst.count, Int(2.8 / BotMoves.beat))
        // 14° a second through a burst, nothing through a rest, apart from a turn act.
        func turned(_ range: ClosedRange<TimeInterval>) -> CGFloat {
            let inside = frames.filter { range.contains($0.now - start) }
            return (inside.last?.motion.turn ?? 0) - (inside.first?.motion.turn ?? 0)
        }
        let rest = turned(7.6...8.9), busy = turned(9.1...11.9)
        XCTAssertTrue(rest == 0 || abs(rest) >= 50, "a rest turns only by an act: \(rest)")
        XCTAssertTrue(abs(busy - 14 * 2.8) < 2 || abs(busy) > 70, "a burst turns at 14° a second: \(busy)")
    }

    /// Clients whose logs say nothing about tools work as bots always have: in place, breathing, no sign.
    func testPlainWorkIsTodaysWorkingMotion() {
        var plain = BotMotion(seed: 9), working = BotMotion(seed: 9)
        plain.set(BotState(look: .plain), at: 0)
        working.set(.working, at: 0)
        for frame in 0...900 {
            let now = Double(frame) / 30
            plain.step(to: now); working.step(to: now)
            XCTAssertEqual(plain.pose, working.pose)
            XCTAssertEqual(plain.face, working.face)
            XCTAssertNil(plain.sign)
        }
    }

    // MARK: Sub-agents

    /// The copy for sub-agents is part of the frame only while a turn runs.
    func testSubAgentsComeWithWorkOnly() {
        var motion = bot()
        motion.set(BotState(look: .plain, subagents: true), at: 0)
        drive(&motion, from: 0, for: 1)
        XCTAssertTrue(motion.helper)
        motion.set(BotState(look: .idle, subagents: true), at: 1)
        drive(&motion, from: 1, for: 1)
        XCTAssertFalse(motion.helper)
    }

    // MARK: Events

    func testAStartHopsWhileItsEyesOpen() throws {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .idle), at: 0)
        drive(&motion, from: 0, for: 1)
        motion.set(BotState(look: .plain), at: 1)
        motion.play(.start, at: 1)
        let frames = drive(&motion, from: 1, for: 2)
        let rising = frames.filter { $0.motion.morph > 0.3 && $0.motion.playing == nil && $0.now < 1.5 }
        XCTAssertTrue(rising.allSatisfy { $0.motion.face.open < 0.2 }, "it comes up with its eyes shut")
        let hop = frames.filter { $0.motion.playing == .start }
        XCTAssertFalse(hop.isEmpty)
        XCTAssertEqual(hop.map(\.motion.pose.y).min() ?? 0, -0.06, accuracy: 0.006, "a hop of 0.06 of the side")
        let (first, last) = (try XCTUnwrap(hop.first), try XCTUnwrap(hop.last))
        XCTAssertLessThanOrEqual(last.now - first.now, BotMoves.hopSeconds)
        XCTAssertGreaterThan(last.motion.face.open, 0.6, "the eyes open as it hops")
        XCTAssertNil(motion.playing)
        XCTAssertEqual(motion.pose.y, 0, "and the look carries on in its place")
        XCTAssertGreaterThan(motion.face.open, 0.9)
    }

    func testAFailureShakesAndSagsWithCrossedEyesWhereTheyAreBigEnough() {
        for (vendor, crosses) in [("ChatGPT", true), ("Grok Bot", true), ("Pi", false), ("OpenCode", false)] {
            var motion = bot(vendor)
            motion.set(BotState(look: .plain), at: 0)
            drive(&motion, from: 0, for: 1)
            motion.play(.failed, at: 1)
            let frames = drive(&motion, from: 1, for: 2.5).filter { $0.motion.playing == .failed }
            let shake = frames.filter { $0.now < 1.5 }.map { abs($0.motion.pose.x) }
            XCTAssertGreaterThan(shake.max() ?? 0, 0.02, vendor)
            XCTAssertLessThanOrEqual(shake.max() ?? 1, 0.05, vendor)
            let sagged = frames.filter { $0.now > 1.8 && $0.now < 2.2 }
            XCTAssertFalse(sagged.isEmpty)
            XCTAssertTrue(sagged.allSatisfy { abs($0.motion.pose.rotation - 6) < 0.5 && $0.motion.pose.x == 0 }, vendor)
            XCTAssertTrue(frames.allSatisfy { $0.motion.sign == .cross }, "\(vendor): a cross while it plays")
            if crosses {
                XCTAssertGreaterThan(sagged.map(\.motion.face.crossed).min() ?? 0, 0.9, vendor)
            } else {
                XCTAssertEqual(sagged.map(\.motion.face.crossed).max() ?? 1, 0, vendor)
                XCTAssertLessThan(sagged.map(\.motion.face.open).max() ?? 1, 0.6, "\(vendor) squints")
            }
            XCTAssertNil(motion.playing)
            XCTAssertNil(motion.sign, "no badge was given")
            XCTAssertLessThan(motion.face.crossed, 0.05)
            motion.set(BotState(look: .idle, badge: .failed), at: 3.5)
            drive(&motion, from: 3.5, for: 2)
            XCTAssertEqual(motion.sign, .cross, "the badge stays on the logo")
            XCTAssertEqual(motion.morph, 0)
            XCTAssertFalse(motion.restsAsLogo, "a queue shows the bot's own logo with its badge")
        }
    }

    func testALimitHitSighsOnce() {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .plain), at: 0)
        drive(&motion, from: 0, for: 1)
        motion.play(.limitHit, at: 1)
        let frames = drive(&motion, from: 1, for: 2).filter { $0.motion.playing == .limitHit }
        XCTAssertGreaterThan(frames.map(\.motion.pose.scaleY).max() ?? 0, 1.05, "a breath in, stretching up")
        XCTAssertLessThan(frames.map(\.motion.pose.scaleY).min() ?? 1, 0.95, "and out, sinking")
        XCTAssertTrue(frames.allSatisfy { $0.motion.pose.footing == 0.5 }, "from its feet")
        XCTAssertEqual(motion.pose.scaleY, 1, accuracy: 0.001)
        motion.set(BotState(look: .plain, badge: .limited), at: 3)
        drive(&motion, from: 3, for: 0.5)
        XCTAssertEqual(motion.sign, .hourglass)
    }

    func testAnEventWakesTheBotWaitsForItAndLetsGoWhenStaleOrOutranked() {
        // On a resting logo, an event brings the bot up to play it, and the logo comes back after.
        var resting = bot("Grok Bot")
        resting.set(BotState(look: .idle), at: 0)
        drive(&resting, from: 0, for: 1)
        resting.play(.failed, at: 1)
        let played = drive(&resting, from: 1, for: 4)
        XCTAssertTrue(played.contains { $0.motion.playing == .failed && $0.motion.morph == 1 })
        XCTAssertEqual(resting.morph, 0)

        // A waiting request is never interrupted; the event is let go after three seconds.
        var waiting = bot("Grok Bot")
        waiting.set(BotState(look: .permission), at: 0)
        waiting.play(.start, at: 0)
        XCTAssertTrue(drive(&waiting, from: 0, for: 3.5).allSatisfy { $0.motion.playing == nil })
        waiting.set(BotState(look: .plain), at: 3.5)
        XCTAssertTrue(drive(&waiting, from: 3.5, for: 2).allSatisfy { $0.motion.playing == nil }, "and not played later")

        // The newest event wins, unless one waiting outranks it.
        for (first, second, plays) in [(BotEvent.start, BotEvent.failed, BotEvent.failed), (.failed, .start, .failed),
                                       (.limitHit, .start, .limitHit), (.start, .limitHit, .limitHit)] {
            var motion = bot("Grok Bot")
            motion.set(BotState(look: .idle), at: 0)
            motion.play(first, at: 0)
            motion.play(second, at: 0)
            XCTAssertEqual(drive(&motion, from: 0, for: 2).compactMap(\.motion.playing).first, plays)
        }
    }

    // MARK: Resting

    func testAsleepDozesEveryFewMinutesWithShutEyesAndAZ() {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .asleep), at: 0)
        let frames = drive(&motion, from: 0, for: 1200)
        var visits: [TimeInterval] = [], last: CGFloat = 0
        for frame in frames {
            if last == 0, frame.motion.morph > 0 { visits.append(frame.now) }
            last = frame.motion.morph
            if frame.motion.morph == 1 {
                XCTAssertLessThan(frame.motion.face.open, 0.1, "eyes shut to lines")
                XCTAssertEqual(frame.motion.sign, .z)
                XCTAssertEqual(frame.motion.pose, BotPose(), "no breath")
            }
        }
        XCTAssertGreaterThanOrEqual(visits.count, 3)
        XCTAssertGreaterThanOrEqual(visits.first ?? 0, 180)
        for (one, next) in zip(visits, visits.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - one, 180)
            XCTAssertLessThanOrEqual(next - one, 306)
        }
        XCTAssertLessThan(frames.count, visits.count * 120 + 20, "nothing between visits")
    }

    func testNoNewsRestsAsAFadedLogoWithNoClock() {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .plain), at: 0)
        drive(&motion, from: 0, for: 1)
        motion.set(BotState(look: .noNews), at: 1)
        let frames = drive(&motion, from: 1, for: 60)
        XCTAssertNil(motion.wait, "no visits and no timer")
        XCTAssertLessThan(frames.count, 30)
        XCTAssertEqual(motion.morph, 0)
        XCTAssertEqual(motion.opacity, 0.5)
        XCTAssertFalse(motion.restsAsLogo, "the faded logo is the bot's to show")
        // Under the pointer it comes up whole, and greets.
        motion.set(BotState(look: .noNews, hovered: true), at: 61)
        let greeted = drive(&motion, from: 61, for: 1.5)
        XCTAssertEqual(motion.morph, 1)
        XCTAssertEqual(motion.opacity, 1)
        XCTAssertLessThan(greeted.map(\.motion.pose.y).min() ?? 0, -0.05)
    }

    /// Under the pointer a resting mark, or one with a badge, comes up and hops to greet once the pointer has stayed;
    /// a working one only turns its eyes.
    func testHoverGreetsARestingOrBadgedMarkAndOnlyTurnsABusyOnesEyes() throws {
        for (state, greets) in [(BotState(look: .idle), true), (BotState(look: .asleep), true),
                                (BotState(look: .plain, badge: .limited), true), (BotState(look: .plain), false),
                                (BotState(look: .thinking), false)] {
            var motion = bot("Grok Bot")
            motion.set(state, at: 0)
            drive(&motion, from: 0, for: 1)
            var hovered = state
            hovered.hovered = true
            motion.set(hovered, at: 1)
            let frames = drive(&motion, from: 1, for: 2, aim: CGPoint(x: 0.7, y: 0.3))
            let hop = frames.filter { $0.motion.pose.y < -0.01 }
            if greets {
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(hop.first, "\(state)").now, 1.3, "after the pointer stays")
                XCTAssertEqual(hop.map(\.motion.pose.y).min() ?? 0, -0.06, accuracy: 0.006)
            } else {
                XCTAssertTrue(hop.isEmpty, "\(state)")
            }
            XCTAssertEqual(motion.morph, 1)
            XCTAssertGreaterThan(frames.map(\.motion.face.look).max() ?? 0, 0.6, "\(state): eyes on the pointer")
        }
    }

    func testAHeldLookComesToRestAndResumes() {
        var motion = bot("Grok Bot")
        motion.set(BotState(look: .thinking), at: 1000)
        drive(&motion, from: 1000, for: 2)
        motion.set(BotState(look: .thinking, holds: true), at: 1002)
        let frames = drive(&motion, from: 1002, for: 30)
        XCTAssertNil(motion.wait, "held still with no clock")
        XCTAssertLessThan(frames.count, 40)
        XCTAssertEqual(motion.morph, 1)
        XCTAssertEqual(motion.sign, .ellipsis)
        XCTAssertEqual(motion.lit, 0, "one dot")
        motion.set(BotState(look: .thinking), at: 1040)
        motion.step(to: 1040)
        XCTAssertNotNil(motion.wait)
    }

    // MARK: Clawd drawn

    /// The drawn Clawd plays the new looks with the moves it has, in whole steps.
    func testTheDrawnClawdActsOutTheNewLooks() {
        func seen(_ state: BotState, for seconds: TimeInterval = 6) -> [BotMotion] {
            var motion = bot()
            motion.limbed = true
            motion.set(state, at: 1000)
            return drive(&motion, from: 1000, for: seconds).map(\.motion)
        }
        let thinking = seen(BotState(look: .thinking))
        XCTAssertTrue(thinking.allSatisfy { (1...6).contains($0.limbs.spinner) && $0.limbs.left == 0 && $0.sign == nil },
                      "the spinner, hands still, and no dots")
        XCTAssertTrue(seen(BotState(look: .tool(.edit))).contains { $0.limbs.left == 1 }, "typing")
        for (look, sign) in [(BotLook.permission, BotSign.exclamation), (.question, .question), (.plan, .lines)] {
            let waiting = seen(BotState(look: look))
            XCTAssertTrue(waiting.allSatisfy { $0.sign == sign && $0.limbs.spinner == 0 }, "\(look)")
            XCTAssertTrue(waiting.contains { $0.limbs.left == 2 }, "\(look): arms waving")
        }
        let compacting = seen(BotState(look: .compacting)).last
        XCTAssertEqual(compacting?.limbs, BotLimbs(left: 1, right: 1, lifted: 3))
        XCTAssertLessThan(compacting?.face.open ?? 1, 0.1, "eyes shut, sitting")
        let thinkingWithBadge = seen(BotState(look: .thinking, badge: .failed))
        XCTAssertTrue(thinkingWithBadge.allSatisfy { $0.limbs.spinner == 0 && $0.sign == .cross }, "a badge stands where the spinner was")

        var dozing = bot()
        dozing.limbed = true
        dozing.staysBot = true
        dozing.set(BotState(look: .asleep), at: 0)
        drive(&dozing, from: 0, for: 2)
        XCTAssertEqual(dozing.limbs, BotLimbs(lifted: 3, x: 0, y: 1))
        XCTAssertEqual(dozing.sign, .z)

        for (event, check) in [(BotEvent.start, { (limbs: [BotLimbs]) in limbs.contains { $0.y == -3 } }),
                               (.failed, { $0.contains { $0.x == 1 } && $0.contains { $0.x == -1 } && $0.contains { $0.y == 1 } }),
                               (.limitHit, { $0.contains { $0.left == 2 && $0.y == -1 } && $0.contains { $0.y == 1 } })] {
            var motion = bot()
            motion.limbed = true
            motion.set(BotState(look: .plain), at: 1000)
            drive(&motion, from: 1000, for: 1)
            motion.play(event, at: 1001)
            let limbs = drive(&motion, from: 1001, for: 2).filter { $0.motion.playing == event }.map(\.motion.limbs)
            XCTAssertTrue(check(limbs), "\(event)")
        }
    }

    /// Clawd's spinner and typing change on eighths of a second of the shared clock, so each is drawn for the same
    /// number of frames.
    func testClawdsBeatsAreEighthsOfASecondOnTheClock() {
        var motion = bot()
        motion.limbed = true
        motion.set(BotState(look: .thinking), at: 1000.02)
        var changes: [TimeInterval] = [], last: BotLimbs?
        for frame in drive(&motion, from: 1000.02, for: 10) {
            if let last, frame.motion.limbs != last { changes.append(frame.now) }
            last = frame.motion.limbs
        }
        XCTAssertGreaterThan(changes.count, 60)
        for change in changes {
            XCTAssertEqual(change / BotMoves.beat, (change / BotMoves.beat).rounded(), accuracy: 0.001, "at \(change)")
        }
    }
}

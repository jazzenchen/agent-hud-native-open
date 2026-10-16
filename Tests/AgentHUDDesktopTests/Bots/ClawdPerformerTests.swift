import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

final class ClawdPerformerTests: XCTestCase {
    private let sheet = ClawdFixture.everySprite()
    private let clips = ClawdClips.standard

    private func performer(staysBot: Bool = false, arrivesAfter: TimeInterval = 0, seed: UInt64 = 1) -> ClawdPerformer {
        ClawdPerformer(sheet: sheet, staysBot: staysBot, arrivesAfter: arrivesAfter, seed: seed)
    }

    /// A picture and when it began to show.
    private typealias Shot = (time: TimeInterval, picture: ClawdPicture?)

    /// Steps `performer` from `start` to `end`, waking only when it says it is due, and keeps every picture it shows.
    /// Every wake must fall on Clawd's 1/12 s grid.
    private func film(_ performer: inout ClawdPerformer, from start: TimeInterval, until end: TimeInterval,
                      aim: CGPoint = .zero, file: StaticString = #filePath, line: UInt = #line) -> [Shot] {
        var shots: [Shot] = [], now = start
        while true {
            performer.step(to: now) { aim }
            if shots.last.map({ $0.picture != performer.picture }) ?? true { shots.append((now, performer.picture)) }
            guard let due = performer.due, due <= end else { break }
            XCTAssertGreaterThan(due, now, "no progress at \(now)", file: file, line: line)
            XCTAssertEqual(due * 12, (due * 12).rounded(), accuracy: 1e-6, "off the grid", file: file, line: line)
            guard due > now else { break }
            now = due
        }
        return shots
    }

    /// Where a visit of Clawd's begins and ends, among `shots` that start on the logo.
    private func visits(_ shots: [Shot]) -> [(start: TimeInterval, end: TimeInterval?)] {
        var visits: [(start: TimeInterval, end: TimeInterval?)] = []
        for (at, shot) in shots.enumerated() where at > 0 {
            let before = shots[at - 1].picture
            if shot.picture != nil, before == nil { visits.append((shot.time, nil)) }
            if shot.picture == nil, before != nil, !visits.isEmpty { visits[visits.count - 1].end = shot.time }
        }
        return visits
    }

    private static func onGrid(_ time: TimeInterval) -> TimeInterval { ((time - 0.004) * 12).rounded(.up) / 12 }

    // MARK: Looks

    func testEachLookPlaysItsClip() {
        let cases: [(BotState, ClawdLook?)] = [
            (BotState(look: .permission), .permission), (BotState(look: .question), .question), (BotState(look: .plan), .plan),
            (BotState(look: .compacting), .compacting), (BotState(look: .thinking), .thinking),
            (BotState(look: .thinking, holds: true), .retrying), (BotState(look: .tool(.edit)), .edit),
            (BotState(look: .tool(.command)), .command), (BotState(look: .tool(.read)), .read),
            (BotState(look: .tool(.longCommand)), .longCommand), (BotState(look: .plain), .command),
            (BotState(look: .noNews), nil), (BotState(look: .idle), nil), (BotState(look: .asleep), nil),
        ]
        XCTAssertEqual(Set(cases.map(\.0.look)), Set(BotLook.allCases.filter { $0 != .done }), "every look but a card's")
        for (state, look) in cases {
            XCTAssertEqual(ClawdPerformer.look(for: state), look, "\(state.look)")
            var performer = performer()
            performer.set(state, at: 10)
            performer.step(to: 10) { .zero }
            XCTAssertEqual(performer.player.shown, look, "\(state.look)")
            if let look {
                let clip = clips.clip(for: look)
                XCTAssertEqual(performer.picture?.frame, clip.intro.first ?? clip.loopFrames.first, "\(look) comes in from its intro")
            } else {
                XCTAssertNil(performer.picture, "\(state.look) rests as the logo")
            }
        }
    }

    func testAResumedLookStartsAtItsLoopWithNoIntro() {
        for state in [BotState(look: .tool(.edit)), BotState(look: .thinking), BotState(look: .question)] {
            var performer = performer()
            performer.resume(state, at: 10)
            performer.step(to: 10) { .zero }
            let look = ClawdPerformer.look(for: state)!
            XCTAssertEqual(performer.picture?.frame, clips.clip(for: look).loopFrames.first, "\(state.look)")
        }
        var resting = performer()
        resting.resume(BotState(look: .idle), at: 10)
        resting.step(to: 10) { .zero }
        XCTAssertNil(resting.picture)
    }

    func testAWaitWhoseCardIsUpPointsAtItHeldStill() {
        var performer = performer()
        performer.set(BotState(look: .permission, facing: .left), at: 10)
        performer.step(to: 10) { .zero }
        XCTAssertEqual(performer.picture?.frame, sheet.canonical(clips.pointsAtCard))
        XCTAssertEqual(performer.picture?.mirrored, true, "toward a card on its left")
        XCTAssertNil(performer.due, "held, with no clock")
        performer.set(BotState(look: .permission, badge: .failed, facing: .left), at: 11)
        performer.step(to: 11) { .zero }
        XCTAssertEqual(performer.picture?.frame, sheet.canonical(clips.pointsAtCard), "still pointing")
        // The card goes: the wait plays its own clip.
        performer.set(BotState(look: .permission), at: 12)
        performer.step(to: 12) { .zero }
        XCTAssertEqual(performer.picture?.frame, clips.clip(for: .permission).intro.first)
        var right = self.performer()
        right.set(BotState(look: .question, facing: .right), at: 10)
        right.step(to: 10) { .zero }
        XCTAssertEqual(right.picture, ClawdPicture(frame: sheet.canonical(clips.pointsAtCard)), "toward a card on its right")
    }

    /// Pointing would aim past a card above or below the mark, on a top or bottom dock: there Clawd stands still with
    /// the sign its wait wears.
    func testAWaitByACardAboveOrBelowItStandsStillWithItsSign() throws {
        let bulb = ClawdPicture(frame: sheet.canonical(ClawdFrame(.lightbulb, 11)), offset: ClawdOffset(y: 1))
        let waits: [(BotFacing, BotLook, ClawdPicture)] = [
            (.down, .question, ClawdPicture(frame: sheet.canonical(.standing), sign: .question)),
            (.up, .permission, ClawdPicture(frame: sheet.canonical(.standing), sign: .permission)),
            (.up, .plan, bulb),
        ]
        for (facing, look, held) in waits {
            var standing = performer()
            standing.set(BotState(look: look, facing: facing), at: 10)
            standing.step(to: 10) { .zero }
            XCTAssertEqual(standing.picture, held, "\(look) \(facing)")
            XCTAssertNil(standing.due, "\(look): held, with no clock")
            // The card goes: the wait plays its own clip.
            standing.set(BotState(look: look), at: 12)
            standing.step(to: 12) { .zero }
            let clip = try XCTUnwrap(ClawdPerformer.look(for: BotState(look: look)).map(clips.clip(for:)))
            XCTAssertEqual(standing.picture?.frame, clip.intro.first, "\(look)")
        }
        // Another wait by the same card wears its own sign.
        var asking = performer()
        asking.set(BotState(look: .permission, facing: .down), at: 10)
        asking.set(BotState(look: .question, facing: .down), at: 11)
        asking.step(to: 11) { .zero }
        XCTAssertEqual(asking.picture?.sign, .question)
    }

    func testSubAgentsAndABadgeComeWithTheLook() {
        var performer = performer()
        performer.set(BotState(look: .thinking, subagents: true, badge: .failed), at: 10)
        performer.step(to: 10) { .zero }
        XCTAssertEqual(performer.picture?.mini, 13)
        XCTAssertEqual(performer.picture?.sign, .failed, "the bot wears the badge")
        // So does the logo, while it shows.
        var resting = self.performer()
        resting.set(BotState(look: .idle, badge: .limited), at: 10)
        resting.step(to: 10) { .zero }
        XCTAssertNil(resting.picture)
        XCTAssertEqual(resting.logoSign, .hourglass)
    }

    func testTheNextChangeIsThePlayersOwn() throws {
        var performer = performer()
        performer.set(BotState(look: .tool(.edit)), at: 10.02)
        var now = 10.02
        for _ in 0..<60 {
            performer.step(to: now) { .zero }
            XCTAssertEqual(performer.due, performer.player.due)
            now = try XCTUnwrap(performer.due)
        }
    }

    // MARK: Cards

    func testEachCardPlaysItsOwnClipAndItsClawdStands() {
        for (card, sprite) in [(BotCard.done, ClawdSpriteName.excited), (.longDone, .dancingHappy), (.reset, .spark)] {
            var performer = performer(staysBot: true)
            performer.set(BotState(card: card), at: 10)
            let shots = film(&performer, from: 10, until: 20)
            XCTAssertEqual(shots.first?.picture?.frame.sprite, sprite, "\(card)")
            XCTAssertEqual(shots.last?.picture?.frame, .standing, "\(card): standing once its clip is over")
            XCTAssertNil(performer.due, "\(card): and holding there")
            // Told the same card again, as a view is on every update, it does not play it again.
            performer.set(BotState(card: card), at: 21)
            performer.step(to: 21) { .zero }
            XCTAssertEqual(performer.picture?.frame, .standing)
        }
        // A mark that follows its agent goes back to its logo.
        var dock = performer()
        dock.set(BotState(card: .done), at: 10)
        XCTAssertNil(film(&dock, from: 10, until: 20).last?.picture)
    }

    func testAStayingClawdKeepsItsLogoWhileItsCardOpens() throws {
        var performer = performer(staysBot: true, arrivesAfter: 0.7)
        performer.set(BotState(look: .permission, badge: .failed), at: 10.01)
        performer.step(to: 10.01) { .zero }
        XCTAssertNil(performer.picture)
        XCTAssertEqual(performer.logoSign, .cross, "a badge stands on the logo")
        let arrival = try XCTUnwrap(performer.due)
        XCTAssertEqual(arrival, Self.onGrid(10.71), accuracy: 1e-9)
        performer.step(to: arrival) { .zero }
        XCTAssertEqual(performer.picture?.frame, ClawdFrame(.pointing, 6), "the wait's whole intro from standing")
        XCTAssertEqual(performer.picture?.sign, .permission)

        // An event asked for while the card opens plays first once it has.
        var started = self.performer(staysBot: true, arrivesAfter: 0.7)
        started.set(BotState(look: .thinking), at: 10)
        started.play(.start, at: 10.2)
        let shots = film(&started, from: 10, until: 14)
        XCTAssertNil(shots[0].picture)
        XCTAssertEqual(shots[1].picture?.frame, ClawdFrame(.jumpingHappy, 3))
        XCTAssertTrue(shots.contains { $0.picture?.frame == ClawdFrame(.thinking, 4) }, "then the look's intro")
    }

    // MARK: Visits

    func testAnIdleMarkVisitsEveryTwentyToThirtyFiveSeconds() throws {
        var performer = performer(seed: 7)
        performer.set(BotState(look: .idle), at: 0)
        let shots = film(&performer, from: 0, until: 600)
        let visits = visits(shots)
        XCTAssertGreaterThan(visits.count, 12)
        XCTAssertTrue((20...35).contains(visits[0].start), "\(visits[0].start)")
        for (one, next) in zip(visits, visits.dropFirst()) {
            let gap = next.start - (one.end ?? .infinity)
            XCTAssertTrue((20 - 0.1...35 + 0.1).contains(gap), "\(gap)")
        }
        // Every visit is one of the idle ones, and none waves: a raised claw is a question.
        let sprites = Set(shots.compactMap { $0.picture?.frame.sprite })
        XCTAssertEqual(sprites, [.swaying, .turning, .lookingAroundEyesOnly, .walking])
    }

    func testASleepingMarkDozesEveryFewMinutes() {
        var performer = performer(seed: 3)
        performer.set(BotState(look: .asleep), at: 0)
        let shots = film(&performer, from: 0, until: 1800)
        let visits = visits(shots)
        XCTAssertGreaterThan(visits.count, 4)
        XCTAssertTrue((180...300).contains(visits[0].start), "\(visits[0].start)")
        for (one, next) in zip(visits, visits.dropFirst()) {
            XCTAssertTrue((180 - 0.1...300 + 0.1).contains(next.start - (one.end ?? .infinity)))
        }
        let dozing = shots.compactMap(\.picture)
        XCTAssertTrue(dozing.allSatisfy { $0.sign == .asleep }, "z all through")
        XCTAssertTrue(dozing.contains { $0.frame == ClawdFrame(.meditating, 23) })
    }

    func testAMarkWithNoNewsHasNoVisits() {
        var performer = performer()
        performer.set(BotState(look: .noNews), at: 0)
        let shots = film(&performer, from: 0, until: 600)
        XCTAssertEqual(shots.count, 1)
        XCTAssertNil(performer.due, "nothing to wake for")
    }

    // MARK: The pointer

    func testThePointerOnARestingMarkIsGreetedThenWatched() throws {
        var performer = performer()
        performer.set(BotState(look: .idle), at: 10)
        performer.step(to: 10) { .zero }
        performer.set(BotState(look: .idle, hovered: true), at: 11)
        performer.step(to: 11) { .zero }
        XCTAssertNil(performer.picture, "not before the pointer has rested a moment")
        let greet = try XCTUnwrap(performer.due)
        XCTAssertEqual(greet, Self.onGrid(11.3), accuracy: 1e-9)
        // To the right of the mark.
        let shots = film(&performer, from: greet, until: 14, aim: CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(shots.first?.picture?.frame, ClawdFrame(.waving, 3))
        XCTAssertEqual(shots.last?.picture?.frame, ClawdFrame(.lookingAroundEyesOnly, 6), "eyes on the pointer")
        // The pointer is looked at every sprite frame, and the eyes turn when it moves into another eighth.
        XCTAssertLessThanOrEqual(try XCTUnwrap(performer.due), 14 + BotPace.following + 1e-9)
        performer.step(to: 14.5) { CGPoint(x: 0, y: -0.5) }
        XCTAssertEqual(performer.picture?.frame, ClawdFrame(.lookingAroundEyesOnly, 12), "up")
        // The pointer leaves: the logo again, and a visit in a while.
        performer.set(BotState(look: .idle), at: 15)
        performer.step(to: 15) { .zero }
        XCTAssertNil(performer.picture)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(performer.due), 35)
    }

    func testABusyMarkKeepsToItsClipUnderThePointer() {
        var performer = performer()
        performer.set(BotState(look: .thinking, hovered: true), at: 10)
        let shots = film(&performer, from: 10, until: 14)
        XCTAssertFalse(shots.contains { $0.picture?.frame.sprite == .waving })
        XCTAssertTrue(shots.allSatisfy { $0.picture?.frame.sprite == .thinking })

        // Work that begins under the pointer ends the eyes on it, and the pointer is no longer looked at.
        var watched = self.performer()
        watched.set(BotState(look: .idle, hovered: true), at: 10)
        _ = film(&watched, from: 10, until: 12)
        watched.set(BotState(look: .tool(.edit), hovered: true), at: 12)
        let working = film(&watched, from: 12, until: 16)
        XCTAssertTrue(working.dropFirst().allSatisfy { $0.picture?.frame.sprite == .laptop })
        XCTAssertEqual(watched.due, watched.player.due)
    }

    // MARK: Events

    func testAnEventThatCannotBeginWithinThreeSecondsIsLetGo() {
        // A wait holds an event back; answered four seconds later, the turn carries on without it.
        var late = performer()
        late.set(BotState(look: .permission), at: 10)
        late.play(.failed, at: 10.5)
        late.set(BotState(look: .thinking), at: 14.5)
        XCTAssertFalse(film(&late, from: 14.5, until: 20).contains { $0.picture?.frame.sprite == .facepalm })
        // Answered in time, it plays.
        var quick = performer()
        quick.set(BotState(look: .permission), at: 10)
        quick.play(.failed, at: 10.5)
        quick.set(BotState(look: .thinking), at: 11.5)
        XCTAssertTrue(film(&quick, from: 11.5, until: 20).contains { $0.picture?.frame.sprite == .facepalm })
    }

    func testANewerEventNeverTakesTheTurnOfOneThatOutranksIt() {
        var performer = performer()
        performer.set(BotState(look: .thinking), at: 10)
        performer.step(to: 10.5) { .zero }
        performer.play(.failed, at: 10.6)
        performer.play(.start, at: 10.7)
        let sprites = Set(film(&performer, from: 10.7, until: 14).compactMap { $0.picture?.frame.sprite })
        XCTAssertTrue(sprites.contains(.facepalm))
        XCTAssertFalse(sprites.contains(.jumpingHappy))
    }
}

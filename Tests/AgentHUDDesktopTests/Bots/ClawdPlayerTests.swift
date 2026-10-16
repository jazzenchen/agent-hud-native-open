import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

final class ClawdPlayerTests: XCTestCase {
    /// Something asked of a player at a time.
    private typealias Request = (time: TimeInterval, ask: (inout ClawdPlayer, TimeInterval) -> Void)

    /// A picture and the tick it started showing on.
    private struct Shot: Equatable, CustomStringConvertible {
        var tick: Int
        var picture: ClawdPicture?
        var description: String {
            guard let picture else { return "\(tick) logo" }
            var text = "\(tick) \(picture.frame)"
            if picture.offset != .zero { text += " (\(picture.offset.x),\(picture.offset.y))" }
            if let sign = picture.sign { text += " \(sign.rawValue)" }
            if let mini = picture.mini { text += " +mini \(mini)" }
            return text
        }
    }

    private static func tick(of time: TimeInterval) -> Int { Int(((time + 0.004) * 12).rounded(.down)) }
    /// A time a little into tick `tick`, the way a request rarely lands on the grid.
    private static func into(_ tick: Int) -> TimeInterval { Double(tick) / 12 + 0.02 }

    private func show(_ look: ClawdLook?, at time: TimeInterval, subagents: Bool = false) -> Request {
        (time, { $0.show(look, subagents: subagents, at: $1) })
    }

    private func play(_ event: ClawdEvent, at time: TimeInterval) -> Request { (time, { $0.play(event, at: $1) }) }

    /// Plays `requests` waking only when the player says it is due, and records every picture it shows. Every due
    /// time must be on the 1/12 s grid and bring a new picture.
    private func film(_ requests: [Request], player: ClawdPlayer = ClawdPlayer(), until end: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) -> [Shot] {
        var player = player, shots: [Shot] = [], pending = requests
        func record(_ time: TimeInterval) { Self.record(player.advance(to: time), at: time, in: &shots) }
        var time = pending.first?.time ?? 0
        record(time)
        while true {
            while let next = pending.first, next.time <= time {
                pending.removeFirst()
                next.ask(&player, next.time)
                record(next.time)
            }
            let wake = [player.due, pending.first?.time].compactMap { $0 }.min()
            guard let wake, wake <= end else { break }
            if let due = player.due, due == wake, pending.first?.time != wake {
                XCTAssertEqual(due * 12, (due * 12).rounded(), accuracy: 1e-6, "due off the grid", file: file, line: line)
                let before = player.picture
                XCTAssertNotEqual(player.advance(to: due), before, "woke at \(Self.tick(of: due)) for nothing", file: file, line: line)
            }
            time = wake
            record(time)
        }
        return shots
    }

    /// The same requests with the player stepped on every tick, whatever it says it needs.
    private func everyTick(_ requests: [Request], player: ClawdPlayer = ClawdPlayer(), until end: TimeInterval) -> [Shot] {
        var player = player, shots: [Shot] = [], pending = requests
        func record(_ time: TimeInterval) { Self.record(player.advance(to: time), at: time, in: &shots) }
        var tick = Self.tick(of: pending.first?.time ?? 0)
        record(Double(tick) / 12)
        while Double(tick) / 12 <= end {
            while let next = pending.first, next.time < Double(tick + 1) / 12 {
                pending.removeFirst()
                next.ask(&player, next.time)
                record(next.time)
            }
            tick += 1
            record(Double(tick) / 12)
        }
        return shots
    }

    /// Keeps what a tick ends up showing: a picture asked for later in the same tick replaces the one before.
    private static func record(_ picture: ClawdPicture?, at time: TimeInterval, in shots: inout [Shot]) {
        let tick = tick(of: time)
        if shots.last?.tick == tick { shots.removeLast() }
        if shots.isEmpty || shots.last?.picture != picture { shots.append(Shot(tick: tick, picture: picture)) }
    }

    private func frames(_ shots: [Shot]) -> [String] { shots.map(\.description) }

    /// The frames of one sprite as "tick Sprite index" lines, one tick apart from `tick`.
    private func run(from tick: Int, _ sprite: ClawdSpriteName, _ frames: [Int], ticks: Int = 1) -> [String] {
        frames.enumerated().map { (offset: Int, frame: Int) -> String in
            let at: Int = tick + offset * ticks
            return "\(at) \(sprite.rawValue) \(frame)"
        }
    }

    private func frame(_ shots: [Shot], at tick: Int) -> Shot? { shots.last { $0.tick <= tick } }

    // MARK: Looks

    func testAWorkingLookComesInLoopsAndGoesAtTheEndOfACycle() {
        let shots = film([show(.thinking, at: 10), show(nil, at: Self.into(132))], until: 20)
        XCTAssertEqual(Array(frames(shots).prefix(30)),
                       run(from: 120, .thinking, [4, 5] + Array(6...19)) + run(from: 136, .thinking, [5, 4])
                       + ["138 Walking 0", "139 logo"],
                       "the cycle under way plays to its end, then the outro and standing")
        XCTAssertEqual(shots.count, 20)
    }

    func testWorkingLooksHandOverPropToProp() throws {
        let shots = film([show(.thinking, at: 10), show(.command, at: Self.into(125)), show(.longCommand, at: Self.into(145))],
                         until: 16)
        let lines = frames(shots)
        // Thinking's cycle ends, its outro to standing, then straight to the laptop on the ground.
        let laptop = try XCTUnwrap(lines.firstIndex(of: "139 Laptop 14"))
        XCTAssertEqual(Array(lines[(laptop - 3)...(laptop + 3)]),
                       ["136 Thinking 5", "137 Thinking 4", "138 Walking 0", "139 Laptop 14", "140 Laptop 15 (-1,0)",
                        "141 Laptop 16 (-1,0)", "142 Laptop 17 (-1,0)"])
        // The laptop's cycle ends, it folds the laptop, and the computer slides in without a turn and a reach.
        XCTAssertEqual(frame(shots, at: 158)?.description, "158 Laptop 33 (-1,0)")
        XCTAssertEqual(frame(shots, at: 159)?.description, "159 Laptop 34 (-1,0)")
        XCTAssertEqual(frame(shots, at: 167)?.description, "167 Laptop 42")
        XCTAssertEqual(frame(shots, at: 168)?.description, "168 Desktop 7")
        XCTAssertEqual(frame(shots, at: 176)?.description, "176 Desktop 15 (-3,0)")
        XCTAssertEqual(frame(shots, at: 177)?.description, "177 Desktop 16 (-3,0)")
        // Offsets ease in and out a pixel at a time.
        let offsets = shots.compactMap { $0.picture?.offset.x }
        XCTAssertTrue(zip(offsets, offsets.dropFirst()).allSatisfy { abs($0 - $1) <= 1 }, "\(offsets)")
    }

    func testLooksThatShareAClipNeverRestartIt() {
        let alone = film([show(.edit, at: 10)], until: 15)
        let switched = film([show(.edit, at: 10), show(.command, at: Self.into(130)), show(.edit, at: Self.into(140))], until: 15)
        XCTAssertEqual(frames(alone), frames(switched))
    }

    func testAWaitCutsInAtOnceAndLeavesFromAnyFrame() {
        let shots = film([show(.command, at: 10), show(.permission, at: Self.into(130)), show(nil, at: Self.into(150))], until: 14)
        let lines = frames(shots)
        XCTAssertEqual(frame(shots, at: 129)?.picture?.frame.sprite, .laptop)
        XCTAssertEqual(frame(shots, at: 130)?.description, "130 Pointing 6 !", "no outro, no wait")
        XCTAssertEqual(frame(shots, at: 142)?.description, "142 Pointing 18 !")
        XCTAssertEqual(frame(shots, at: 143)?.description, "143 Pointing 19 !")
        XCTAssertEqual(lines.suffix(4), ["150 Pointing 21 !", "151 Pointing 18", "152 Walking 0", "153 logo"],
                       "answered, it lowers its arm from the frame it is on")
    }

    func testAQuestionLeavesThroughItsLastLoopFrame() {
        let onSeven = film([show(.question, at: 10), show(nil, at: Self.into(126))], until: 12)
        XCTAssertEqual(Array(frames(onSeven).prefix(4)), ["120 Waving 3 ?", "121 Waving 4 ?", "122 Waving 5 ?", "123 Waving 6 ?"])
        XCTAssertEqual(frames(onSeven).suffix(5), ["126 Waving 7 ?", "127 Waving 8", "128 Waving 6", "129 Walking 0", "130 logo"])
        let onEight = film([show(.question, at: 10), show(nil, at: Self.into(127))], until: 12)
        XCTAssertEqual(frames(onEight).suffix(4), ["127 Waving 8 ?", "128 Waving 6", "129 Walking 0", "130 logo"])
    }

    func testCompactingLeavesOnlyFromItsStillFrame() {
        let shots = film([show(.compacting, at: 10), show(nil, at: Self.into(133))], until: 14)
        XCTAssertEqual(Array(frames(shots).prefix(9)), run(from: 120, .meditating, Array(6...13)) + ["128 Meditating 23"])
        XCTAssertEqual(frames(shots).suffix(19),
                       run(from: 133, .meditating, Array(28...34) + [23] + Array(45...54)) + ["151 logo"])
    }

    func testAPlanLeavesByItsOwnOutro() {
        let shots = film([show(.plan, at: 10), show(nil, at: Self.into(140))], until: 14)
        XCTAssertEqual(frames(shots).first, "120 Lightbulb 4")
        XCTAssertEqual(frame(shots, at: 127)?.description, "127 Lightbulb 11 (0,1)", "no sign: the bulb says it")
        XCTAssertEqual(frames(shots).suffix(6),
                       ["140 Lightbulb 24 (0,1)", "141 Lightbulb 41 (0,1)", "142 Lightbulb 42 (0,1)", "143 Lightbulb 43", "144 Lightbulb 44",
                        "145 logo"])
    }

    func testReadingPlaysAtHalfRate() {
        let shots = film([show(.read, at: 10), show(nil, at: Self.into(125))], until: 12)
        XCTAssertEqual(frames(shots), run(from: 120, .lookingAround, Array(6...15), ticks: 2) + ["140 logo"],
                       "no intro, no outro, each frame two ticks")
    }

    func testRetryingHoldsThinkingStillUntilAskedToMove() {
        var player = ClawdPlayer()
        player.show(.retrying, at: 0)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 4))
        player.advance(to: 2.0 / 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 6))
        XCTAssertNil(player.due, "a still frame needs no clock")
        player.advance(to: 1.5)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 6))
        player.show(.thinking, at: Self.into(20))
        XCTAssertEqual(player.due.map(Self.tick(of:)), 22, "it moves on with the next tick: 6 again, then 7")
        player.advance(to: 22.0 / 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 7))
        player.show(.retrying, at: Self.into(25))
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 10))
        XCTAssertEqual(player.due.map(Self.tick(of:)), 26, "it plays its cycle out")
        player.advance(to: Self.into(34))
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 19))
        player.advance(to: Self.into(35))
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 6))
        XCTAssertNil(player.due)
    }

    // MARK: Events

    func testAnEventPlaysAtTheEndOfACycleAndTheLookResumesAtItsLoop() {
        let shots = film([show(.thinking, at: 10), play(.failed, at: Self.into(126))], until: 14.5)
        let lines = frames(shots)
        XCTAssertEqual(frame(shots, at: 135)?.description, "135 Thinking 19")
        XCTAssertEqual(frame(shots, at: 136)?.description, "136 Facepalm 2")
        XCTAssertEqual(frame(shots, at: 139)?.description, "139 Facepalm 5 ×")
        XCTAssertEqual(frame(shots, at: 165)?.description, "165 Facepalm 31 ×")
        XCTAssertEqual(frame(shots, at: 166)?.description, "166 Facepalm 32")
        XCTAssertEqual(frame(shots, at: 167)?.description, "167 Facepalm 33")
        XCTAssertEqual(frame(shots, at: 168)?.description, "168 Thinking 6", "from the loop's start, with no intro")
        XCTAssertFalse(lines.contains("168 Thinking 4"))
    }

    func testAStartPlaysBeforeTheIntroOfTheLookItStarts() {
        for requests in [[play(.start, at: 10), show(.thinking, at: 10)], [show(.thinking, at: 10), play(.start, at: 10)]] {
            let shots = film(requests, until: 12)
            XCTAssertEqual(Array(frames(shots).prefix(21)),
                           run(from: 120, .jumpingHappy, Array(3...20)) + run(from: 138, .thinking, [4, 5, 6]))
        }
    }

    func testAnEventWaitsForAWaitAndTheNewestWins() {
        var player = ClawdPlayer()
        player.show(.permission, at: 10)
        player.play(.start, at: 10.5)
        player.play(.failed, at: 11)
        XCTAssertEqual(player.pendingEvent, .failed)
        player.advance(to: 20)
        XCTAssertEqual(player.picture?.frame.sprite, .pointing, "a wait is never played over")
        player.show(nil, at: Self.into(240))
        player.advance(to: 21)
        XCTAssertEqual(player.playing, .failed, "once the wait is over")
        player.advance(to: 30)
        XCTAssertNil(player.picture, "then back to the logo")
        XCTAssertNil(player.pendingEvent)
    }

    func testALimitHitStaggersTwiceAndStandsUp() {
        let shots = film([play(.limitHit, at: 10)], until: 15)
        let dizzy = Array(6...21) + Array(6...17) + Array(30...37)
        XCTAssertEqual(frames(shots), run(from: 120, .dizzy, dizzy) + ["\(120 + dizzy.count) Walking 0", "\(121 + dizzy.count) logo"])
    }

    // MARK: Slowing down

    /// The ticks on which `frame` starts showing after another picture.
    private func starts(of frame: ClawdFrame, in shots: [Shot]) -> [Int] {
        shots.filter { $0.picture?.frame == frame }.map(\.tick)
    }

    func testALongRunPlaysACycleThenRestsOnItsFirstFrame() {
        let shots = film([show(.thinking, at: 0)], until: 40)
        let cycles = starts(of: ClawdFrame(.thinking, 6), in: shots)
        // The loop starts on tick 2 and runs in full for 20 seconds.
        let wanted: [Int] = (0..<19).map { (cycle: Int) -> Int in 2 + 14 * cycle }
        XCTAssertEqual(Array(cycles.prefix(19)), wanted)
        XCTAssertEqual(cycles[18], 254)
        // From then on its first frame stays three seconds more, and the rest of the cycle plays.
        XCTAssertEqual(frame(shots, at: 290)?.picture?.frame, ClawdFrame(.thinking, 6))
        XCTAssertEqual(frame(shots, at: 291)?.description, "291 Thinking 7")
        XCTAssertEqual(Array(zip(cycles.dropFirst(18), cycles.dropFirst(19)).map { $1 - $0 }.prefix(3)), [50, 50, 50])
    }

    func testAWaitSlowsDownAfterEightSecondsAndAgainAfterTwoMinutes() {
        let shots = film([show(.permission, at: 0)], until: 200)
        let cycles = starts(of: ClawdFrame(.pointing, 19), in: shots)
        let gaps = zip(cycles, cycles.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(cycles.first, 13, "after its intro")
        XCTAssertEqual(Array(gaps.prefix(20)), Array(repeating: 5, count: 20), "eight seconds of loop")
        XCTAssertEqual(cycles[20], 113)
        XCTAssertEqual(Array(gaps[20..<64]), Array(repeating: 31, count: 44), "a cycle every 2.6 s")
        XCTAssertEqual(Array(gaps[64...].prefix(5)), Array(repeating: 96, count: 5), "after two minutes, every 8 s")
        XCTAssertEqual(frame(shots, at: 139)?.picture?.frame, ClawdFrame(.pointing, 19), "its first frame held in between")
        XCTAssertEqual(frame(shots, at: 140)?.description, "140 Pointing 20 !")
    }

    func testAPlanHoldsItsBulbAndPumpsEveryEightSeconds() {
        let shots = film([show(.plan, at: 0)], until: 160)
        let held = starts(of: ClawdFrame(.lightbulb, 11), in: shots)
        XCTAssertEqual(held.first, 7)
        XCTAssertEqual(held[52], 1463, "two minutes of loop")
        XCTAssertEqual(frame(shots, at: 1554)?.picture?.frame, ClawdFrame(.lightbulb, 11))
        XCTAssertEqual(frames(shots.filter { (1555...1559).contains($0.tick) }),
                       ["1555 Lightbulb 26 (0,1)", "1556 Lightbulb 27 (0,1)", "1557 Lightbulb 28 (0,1)", "1558 Lightbulb 29 (0,1)",
                        "1559 Lightbulb 11 (0,1)"])
        XCTAssertEqual(held[53] - held[52], 96)
        XCTAssertEqual(held[54] - held[53], 96)
    }

    func testALookIsLeftAtOnceWhileItsFirstFrameIsHeld() {
        // Twenty seconds in, the thinking loop rests on frame 6 between cycles: a change cuts the rest short.
        let shots = film([show(.thinking, at: 0), show(.command, at: Self.into(260))], until: 24)
        XCTAssertEqual(frame(shots, at: 260)?.description, "254 Thinking 6")
        XCTAssertEqual(frame(shots, at: 261)?.description, "261 Thinking 5")
    }

    // MARK: Visits, greeting, cards

    func testAVisitPlaysOnceAndEndsOnStanding() {
        var player = ClawdPlayer()
        player.visit(.turning, at: 10)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.turning, 2))
        let shots = film([], player: player, until: 20)
        XCTAssertEqual(frames(shots).suffix(3), ["146 Turning 28", "147 Walking 0", "148 logo"])
        let doze = film([(10, { $0.visit(.dozing, at: $1) })], until: 20)
        XCTAssertTrue(doze.dropLast().allSatisfy { $0.picture?.sign == .asleep })
        XCTAssertEqual(frame(doze, at: 137 + 23)?.description, "137 Meditating 23 z", "held two seconds")
        XCTAssertEqual(frame(doze, at: 161)?.description, "161 Meditating 45 z")
        XCTAssertNil(doze.last?.picture)

        // A visit only ever plays over the logo.
        var busy = ClawdPlayer()
        busy.show(.thinking, at: 0)
        busy.visit(.swaying, at: 1)
        XCTAssertEqual(busy.picture?.frame.sprite, .thinking)
    }

    func testAGreetingWavesThenFollowsThePointerBySectors() {
        var player = ClawdPlayer()
        player.greet(at: 10)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.waving, 3))
        player.advance(to: 10 + 13.0 / 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.waving, 6))
        player.advance(to: 10 + 14.0 / 12)
        XCTAssertEqual(player.picture?.frame, .standing)
        XCTAssertNil(player.due, "standing, with no pointer to look at yet")
        player.look(toward: CGPoint(x: 0.4, y: 0), at: 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.lookingAroundEyesOnly, 6), "to the right")
        player.look(toward: CGPoint(x: 0.4, y: 0.1), at: 12.1)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.lookingAroundEyesOnly, 6), "the same sector")
        XCTAssertNil(player.due)
        let sectors: [(CGPoint, Int)] = [(CGPoint(x: 0.3, y: -0.3), 9), (CGPoint(x: 0, y: -0.4), 12), (CGPoint(x: -0.3, y: -0.3), 15),
                                         (CGPoint(x: -0.4, y: 0), 18), (CGPoint(x: -0.3, y: 0.3), 21), (CGPoint(x: 0, y: 0.4), 27),
                                         (CGPoint(x: 0.3, y: 0.3), 30)]
        for (aim, frame) in sectors {
            player.look(toward: aim, at: 13)
            XCTAssertEqual(player.picture?.frame, ClawdFrame(.lookingAroundEyesOnly, frame), "\(aim)")
        }
        player.look(toward: CGPoint(x: 0.001, y: 0), at: 13.5)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.lookingAroundEyesOnly, 30), "too close to tell: the eyes stay")
        player.endHover(at: 14)
        XCTAssertNil(player.picture)

        // A working mark keeps its clip under the pointer.
        var busy = ClawdPlayer()
        busy.show(.edit, at: 0)
        busy.greet(at: 1)
        XCTAssertEqual(busy.picture?.frame.sprite, .laptop)
    }

    func testACardPlaysOnceAndStands() {
        var player = ClawdPlayer(rest: .standing)
        XCTAssertEqual(player.picture?.frame, .standing)
        player.card(.done, at: 0)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.excited, 2))
        player.advance(to: 10)
        XCTAssertEqual(player.picture?.frame, .standing)
        XCTAssertNil(player.due)
        let reset = film([(0, { $0.card(.reset, at: $1) })], player: ClawdPlayer(rest: .standing), until: 5)
        XCTAssertEqual(reset.first?.description, "0 Spark 4")
        XCTAssertEqual(reset.last?.description, "30 Walking 0", "2.5 s, then standing")
    }

    func testAMarkBesideItsCardPointsAtIt() {
        var player = ClawdPlayer()
        player.pointAtCard(mirrored: true, at: 0)
        XCTAssertEqual(player.picture, ClawdPicture(frame: ClawdFrame(.pointing, 19), mirrored: true))
        XCTAssertNil(player.due)
        player.show(nil, at: 1)
        XCTAssertNil(player.picture)
        player.pointAtCard(mirrored: false, at: 2)
        player.show(.permission, at: 3)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.pointing, 6))
    }

    func testAMarkByACardAboveOrBelowItStandsStillWithItsWaitsSign() {
        // A plan's bulb is its sign: it holds the bulb lit, its loop's first frame, where a request stands with its sign.
        let bulb = ClawdPicture(frame: ClawdFrame(.lightbulb, 11), offset: ClawdOffset(y: 1))
        let waits: [(ClawdLook, ClawdPicture)] = [(.permission, ClawdPicture(frame: .standing, sign: .permission)),
                                                  (.question, ClawdPicture(frame: .standing, sign: .question)), (.plan, bulb)]
        for (look, held) in waits {
            var player = ClawdPlayer()
            player.show(look, at: 0)
            player.standAtCard(for: look, at: 1)
            XCTAssertEqual(player.picture, held, "\(look)")
            XCTAssertNil(player.due, "\(look): held, with no clock")
            // The card goes: the wait asked for again plays its clip from the start.
            player.show(look, at: 2)
            XCTAssertEqual(player.picture?.frame, ClawdClips.standard.clip(for: look).intro.first, "\(look)")
        }
        var badged = ClawdPlayer()
        badged.standAtCard(for: .permission, at: 0)
        badged.set(badge: .failed, at: 1)
        XCTAssertEqual(badged.picture?.sign, .permission, "the request's sign comes before a badge")
        badged.show(nil, at: 2)
        XCTAssertNil(badged.picture)
    }

    // MARK: What a picture carries

    func testSubAgentsAddTheMiniToWorkingLooksOnly() {
        let shots = film([show(.command, at: 10, subagents: true), play(.failed, at: 11), show(.permission, at: 16)], until: 18)
        XCTAssertTrue(shots.filter { $0.picture?.frame.sprite == .laptop }.allSatisfy { $0.picture?.mini != nil })
        XCTAssertTrue(shots.filter { $0.picture?.frame.sprite != .laptop }.allSatisfy { $0.picture?.mini == nil })
    }

    func testTheMiniStandsWhereEachClipLeavesRoom() {
        let shots = film([show(.thinking, at: 10, subagents: true), show(.command, at: 12, subagents: true),
                          show(.longCommand, at: 16, subagents: true)], until: 24)
        // Right of the body while thinking, left of it beside the laptop, and nowhere beside the desk.
        XCTAssertTrue(shots.filter { $0.picture?.frame.sprite == .thinking }.allSatisfy { $0.picture?.mini == 13 })
        XCTAssertTrue(shots.filter { $0.picture?.frame.sprite == .laptop }.allSatisfy { $0.picture?.mini == -14 })
        let desk = shots.filter { $0.picture?.frame.sprite == .desktop }
        XCTAssertFalse(desk.isEmpty)
        XCTAssertTrue(desk.allSatisfy { $0.picture?.mini == nil })
    }

    func testTheDeskIsLeftFromAnyFrame() {
        // Well into the desk's five-second cycle, the turn ends: it packs up after the frame on screen.
        let shots = film([show(.longCommand, at: 10), show(nil, at: Self.into(150))], until: 20)
        XCTAssertEqual(frame(shots, at: 150)?.description, "150 Desktop 33 (-3,0)")
        XCTAssertEqual(frame(shots, at: 151)?.description, "151 Desktop 76 (-3,0)")
        XCTAssertEqual(frame(shots, at: 162)?.description, "162 Desktop 87")
        XCTAssertEqual(frame(shots, at: 163)?.description, "163 logo")
    }

    func testABadgeShowsUnlessASignComesFirst() {
        var player = ClawdPlayer()
        player.set(badge: .failed, at: 0)
        XCTAssertNil(player.picture, "the logo carries it in its own layer")
        player.visit(.dozing, at: 1)
        XCTAssertEqual(player.picture?.sign, .failed, "× before z")
        player.show(.permission, at: 2)
        XCTAssertEqual(player.picture?.sign, .permission, "! before ×")
        player.set(badge: nil, at: 3)
        player.show(.thinking, at: 4)
        XCTAssertEqual(player.picture?.sign, .permission, "the frame on screen keeps it for its tick")
        player.advance(to: 5)
        XCTAssertEqual(player.picture?.frame.sprite, .thinking)
        XCTAssertNil(player.picture?.sign)
        player.set(badge: .limited, at: 5)
        XCTAssertEqual(player.picture?.sign, .limited)
    }

    // MARK: The clock

    private func sheet(sameAs: [(ClawdFrame, ClawdFrame)]) -> ClawdSheet { ClawdFixture.everySprite(sameAs: sameAs) }

    func testFramesThatLookTheSameAreHeldAsOne() {
        let sheet = sheet(sameAs: [(ClawdFrame(.thinking, 7), ClawdFrame(.thinking, 6)), (ClawdFrame(.thinking, 9), ClawdFrame(.thinking, 6))])
        var player = ClawdPlayer(sheet: sheet)
        player.show(.thinking, at: 0)
        player.advance(to: 2.0 / 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 6))
        XCTAssertEqual(player.due.map(Self.tick(of:)), 4, "6 and 7 are one picture")
        player.advance(to: 4.0 / 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 8))
        player.advance(to: 5.0 / 12)
        XCTAssertEqual(player.picture?.frame, ClawdFrame(.thinking, 6), "9 is drawn as 6")
    }

    func testDueTimesAreExactlyWhenThePictureChanges() {
        let requests: [Request] = [
            show(.thinking, at: 10.01), show(.command, at: 12.3), show(.permission, at: 14.07), show(.command, at: 17.5),
            play(.failed, at: 19.02), show(.longCommand, at: 22, subagents: true), (24.5, { $0.set(badge: .limited, at: $1) }),
            show(nil, at: 30.04), (45.01, { $0.visit(.dozing, at: $1) }), (50, { $0.greet(at: $1) }),
            (51.3, { $0.look(toward: CGPoint(x: 0.2, y: -0.3), at: $1) }), (52.06, { $0.endHover(at: $1) }),
            show(.question, at: 55), show(.plan, at: 57.71), show(.compacting, at: 61), show(.read, at: 63.3), show(.retrying, at: 66),
            play(.limitHit, at: 67), show(nil, at: 70),
        ]
        for player in [ClawdPlayer(), ClawdPlayer(sheet: sheet(sameAs: [(ClawdFrame(.laptop, 18), ClawdFrame(.laptop, 17)),
                                                                        (ClawdFrame(.pointing, 21), ClawdFrame(.pointing, 20))]))] {
            let byDue = film(requests, player: player, until: 80)
            XCTAssertEqual(frames(byDue), frames(everyTick(requests, player: player, until: 80)))
            XCTAssertGreaterThan(byDue.count, 200)
        }
    }

    func testAClockThatSleptPicksUpWhereTheTimeSays() {
        var player = ClawdPlayer()
        player.show(.command, at: 0)
        // An hour asleep: it plays on to where the clock is, without drawing what it missed.
        player.advance(to: 3600 + 0.5)
        XCTAssertEqual(player.picture?.frame.sprite, .laptop)
        let due = try? XCTUnwrap(player.due)
        XCTAssertGreaterThan(due ?? 0, 3600.5)
        XCTAssertLessThan(due ?? .infinity, 3600.5 + 4)
    }

    func testItSaysWhereALookCanChange() {
        var player = ClawdPlayer()
        XCTAssertTrue(player.atSwitchPoint)
        player.show(.edit, at: 10)
        XCTAssertEqual(Self.tick(of: player.switchPoint), 123, "after its intro")
        player.advance(to: Self.into(125))
        XCTAssertEqual(Self.tick(of: player.switchPoint), 140, "at the end of the cycle")
        XCTAssertFalse(player.atSwitchPoint)
        player.advance(to: Self.into(139))
        XCTAssertTrue(player.atSwitchPoint)
        XCTAssertEqual(player.shown, .edit)
        player.show(.thinking, at: Self.into(139))
        XCTAssertEqual(player.shown, .edit, "until it has gone")
        player.advance(to: Self.into(150))
        XCTAssertEqual(player.shown, .thinking)
    }
}

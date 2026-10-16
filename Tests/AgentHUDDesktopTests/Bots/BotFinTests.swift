import AgentHUDCore
import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

/// DeepSeek's bot is a fat fish: a fin on its back and a small triangular fin low on each side for hands, all standing
/// behind the body. The hands flap on a tool's beats, at a start and over a reply's card, and one waves at a greeting; nothing else moves them,
/// so the clock still rests where it did.
@MainActor
final class BotFinTests: XCTestCase {
    private typealias Frame = (now: TimeInterval, motion: BotMotion)

    private static var spec: BotSpec { BotSpec.table["DeepSeek"]! }

    private static func fins(of spec: BotSpec) -> [BotSpec.Fin] {
        spec.decor.flatMap { item -> [BotSpec.Fin] in
            if case .fins(let fins, _) = item { fins } else { [] }
        }
    }

    /// `spec` with only the fins `keep` keeps.
    private static func spec(_ spec: BotSpec, keeping keep: (BotSpec.Fin) -> Bool) -> BotSpec {
        var trimmed = spec
        trimmed.decor = spec.decor.map { item in
            if case .fins(let fins, let paint) = item { .fins(fins.filter(keep), paint) } else { item }
        }
        return trimmed
    }

    /// DeepSeek with its fins and without them, on `ground`.
    private static func forms(_ ground: HUDLook.Appearance) throws -> (fins: BotForm, bare: BotForm) {
        let fins = try XCTUnwrap(BotForm.read("DeepSeek", ground: ground))
        let bare = try XCTUnwrap(BotForm.read("DeepSeek", ground: ground, spec: spec(fins.spec) { _ in false }))
        return (fins, bare)
    }

    /// Steps a motion at the frames it asks for, each on the shared clock.
    @discardableResult
    private func drive(_ motion: inout BotMotion, from start: TimeInterval, for seconds: TimeInterval,
                       aim: CGPoint = CGPoint(x: 0.4, y: 0.3)) -> [Frame] {
        var now = start, frames: [Frame] = []
        while now < start + seconds {
            motion.step(to: now, aim: aim)
            frames.append((now, motion))
            guard let wait = motion.wait else { break }
            let due = (now + wait) / BotPace.lively
            XCTAssertEqual(due, due.rounded(), accuracy: 0.001, "a frame off the shared clock")
            now += wait
        }
        return frames
    }

    private func fish(staysBot: Bool = false, seed: UInt64 = 5) -> BotMotion {
        var motion = BotMotion(seed: seed)
        motion.fit(Self.spec)
        motion.staysBot = staysBot
        return motion
    }

    /// The motion `state` gives after `seconds`, stepped every lively frame, `event` played once the bot is up.
    private func moment(_ state: BotState, event: BotEvent? = nil, at seconds: TimeInterval, staysBot: Bool = false,
                        aim: CGPoint = CGPoint(x: 0.35, y: 0.45)) -> BotMotion {
        var motion = fish(staysBot: staysBot, seed: 11)
        motion.set(state, at: 0)
        var now: TimeInterval = 0
        func run(until end: TimeInterval) {
            while now <= end + 1e-9 { motion.step(to: now, aim: aim); now += BotPace.lively }
        }
        if let event {
            run(until: 1)
            motion.play(event, at: now)
            run(until: now + seconds)
        } else {
            run(until: seconds)
        }
        return motion
    }

    private static func pixels(_ form: BotForm, _ motion: BotMotion, side: CGFloat) throws -> [UInt8] {
        let image = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: side))
        return [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
    }

    /// Where a point given in body radii from the body's centre falls in a frame `side` pixels to the mark, in pixels
    /// from its top left.
    private static func pixel(_ point: CGPoint, spec: BotSpec, side: CGFloat) -> CGPoint {
        let x: CGFloat = spec.center.x + point.x * spec.radius
        let y: CGFloat = spec.center.y + point.y * spec.radius
        return CGPoint(x: (x + BotRenderer.margin) * side, y: (y + BotRenderer.margin) * side)
    }

    /// Points round a fin's outline, in body radii.
    private static func outline(_ fin: BotSpec.Fin, raised: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        BotFins.path(fin, grown: 1, raised: raised).applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                points.append(element.pointee.points[0])
            }
        }
        return points
    }

    // MARK: The fish

    func testDeepSeekIsAFishWithAHandOnEachSideAndAFinOnItsBack() throws {
        let fins = Self.fins(of: Self.spec)
        XCTAssertEqual(fins.count, 3)
        let left = try XCTUnwrap(fins.first { $0.hand < 0 }), right = try XCTUnwrap(fins.first { $0.hand > 0 })
        let back = try XCTUnwrap(fins.first { $0.hand == 0 })
        // The hands mirror each other, low on the sides, pointing down and out.
        XCTAssertEqual(left.root.x, -right.root.x)
        XCTAssertEqual(left.root.y, right.root.y)
        XCTAssertEqual(left.angle, 180 - right.angle)
        XCTAssertEqual(left.length, right.length)
        XCTAssertGreaterThan(right.root.x, 0)
        XCTAssertGreaterThan(right.root.y, 0, "low on the side")
        XCTAssertTrue((10...60).contains(right.angle), "down and out: \(right.angle)")
        XCTAssertLessThan(right.tip * 3, right.base, "a small triangle: broad where it leaves the body, a point at its end")
        XCTAssertGreaterThan(right.tip, 0.03, "its point rounded a little")
        XCTAssertEqual(right.sweep, 0)
        // The fin on the back stands on top, a little back of the middle, and sweeps further back.
        XCTAssertLessThan(back.root.y, -0.5)
        XCTAssertLessThan(back.root.x, 0)
        XCTAssertLessThan(sin(back.angle * .pi / 180), -0.9, "it points up")
        XCTAssertGreaterThan(back.sweep, 0)
        XCTAssertLessThan(back.tip, back.base)
        // Every fin grows from inside the body and clears its outline.
        for fin in fins {
            XCTAssertLessThan(hypot(fin.root.x, fin.root.y), 0.9)
            let reach = Self.outline(fin, raised: 0).map { hypot($0.x, $0.y) }.max() ?? 0
            XCTAssertTrue((1.25...1.5).contains(reach), "reaches \(reach) radii")
        }

        var motion = BotMotion()
        motion.fit(Self.spec)
        XCTAssertTrue(motion.finned)
        for (vendor, spec) in BotSpec.table where vendor != "DeepSeek" {
            XCTAssertTrue(Self.fins(of: spec).isEmpty, vendor)
            var other = BotMotion()
            other.fit(spec)
            XCTAssertFalse(other.finned, vendor)
        }
    }

    /// The fins stand behind the body: inside its outline the bot is the bot it was. They grow out of it with the morph,
    /// in the whale's blue a touch darker than the body.
    func testFinsStandBehindTheBodyAndGrowInWithTheMorph() throws {
        for ground in [HUDLook.Appearance.dark, .light] {
            let (fins, bare) = try Self.forms(ground)
            let spec = fins.spec
            for side: CGFloat in [40, 72, 160] {
                let extent = Int((side * (1 + 2 * BotRenderer.margin)).rounded(.up))
                let center = Self.pixel(.zero, spec: spec, side: side), inside = spec.radius * side - 1.5
                func added(_ motion: BotMotion) throws -> (inside: Int, outside: Int) {
                    let with = try Self.pixels(fins, motion, side: side), without = try Self.pixels(bare, motion, side: side)
                    var counts = (inside: 0, outside: 0)
                    for y in 0..<extent {
                        for x in 0..<extent {
                            let index = (y * extent + x) * 4
                            guard with[index ..< index + 4] != without[index ..< index + 4] else { continue }
                            let distance = hypot(CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y)
                            if distance < inside { counts.inside += 1 } else { counts.outside += 1 }
                        }
                    }
                    return counts
                }
                let place = "\(ground) at \(side)"
                let logo = try added(moment(BotState(look: .idle), at: 0, staysBot: true))
                XCTAssertEqual(logo.inside + logo.outside, 0, "\(place): the logo has no fins")
                let growing = try added(moment(BotState(look: .idle), at: 0.3, staysBot: true))
                let grown = try added(moment(BotState(look: .idle), at: 1.6, staysBot: true))
                XCTAssertEqual(grown.inside, 0, "\(place): nothing changes inside the body")
                XCTAssertGreaterThan(grown.outside, Int(side * side * 0.02), place)
                XCTAssertLessThan(growing.outside, grown.outside, "\(place): the fins grow in with the morph")

                // A side fin's colour, on its middle line past the body's outline, is the body's blue, a little darker.
                // The most opaque pixel round that point is taken, as the triangle is only a few pixels wide at 20 pt.
                let motion = moment(BotState(look: .idle), at: 1.6, staysBot: true)
                let bytes = try Self.pixels(fins, motion, side: side)
                func color(_ point: CGPoint) -> (blue: Int, green: Int, red: Int, alpha: Int) {
                    let at = Self.pixel(point, spec: spec, side: side)
                    var best: Int = (Int(at.y) * extent + Int(at.x)) * 4
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let row: Int = Int(at.y) + dy, column: Int = Int(at.x) + dx
                            let index: Int = (row * extent + column) * 4
                            if bytes[index + 3] > bytes[best + 3] { best = index }
                        }
                    }
                    return (Int(bytes[best]), Int(bytes[best + 1]), Int(bytes[best + 2]), Int(bytes[best + 3]))
                }
                func brightness(_ value: (blue: Int, green: Int, red: Int, alpha: Int)) -> Int {
                    let sum: Int = value.red + value.green
                    return sum + value.blue
                }
                let hand = try XCTUnwrap(Self.fins(of: spec).first { $0.hand > 0 })
                let angle: CGFloat = hand.angle * .pi / 180, out: CGFloat = hand.length * 0.72
                let middle = CGPoint(x: hand.root.x + cos(angle) * out, y: hand.root.y + sin(angle) * out)
                let fin = color(middle)
                let body = color(CGPoint(x: 0, y: -0.7))
                XCTAssertGreaterThan(hypot(middle.x, middle.y), 1.05, "\(place): past the body's outline")
                XCTAssertEqual(fin.alpha, 255, place)
                XCTAssertGreaterThan(fin.blue, fin.red + 100, "\(place): blue")
                let finSum: Int = brightness(fin), bodySum: Int = brightness(body)
                XCTAssertLessThan(finSum, bodySum, "\(place): darker")
                XCTAssertGreaterThan(finSum * 4, bodySum * 3, "\(place): a touch")
            }
        }
    }

    /// No fin reaches the sign over the head, raised or not; and beside the copy that stands for sub-agents at its lower
    /// right, the hand on that side is put away and the rest keep the copy's gap clear.
    func testFinsKeepClearOfTheSignAndOfTheCopyForSubAgents() throws {
        let (fins, bare) = try Self.forms(.dark)
        let spec = fins.spec
        // Every sign a fish can wear while a hand is up or its fins stand at rest.
        let moments: [BotMotion] = [
            moment(BotState(look: .permission), at: 1.4), moment(BotState(look: .thinking), at: 1.6),
            moment(BotState(look: .asleep), at: 1.6, staysBot: true),
            moment(BotState(look: .idle, badge: .failed, hovered: true), at: 0.95),
            moment(BotState(look: .tool(.edit), badge: .limited), at: 1.375),
            moment(BotState(look: .plain, badge: .limited), event: .start, at: 0.15),
        ]
        for motion in moments {
            XCTAssertNotNil(motion.sign)
            for side: CGFloat in [40, 72] {
                let extent = Int((side * (1 + 2 * BotRenderer.margin)).rounded(.up))
                let box = BotSigns.box(for: fins, side: side, outline: 0).insetBy(dx: -2, dy: -2)
                let with = try Self.pixels(fins, motion, side: side), without = try Self.pixels(bare, motion, side: side)
                var touched = 0
                for y in max(0, Int(box.minY))..<min(extent, Int(box.maxY.rounded(.up))) {
                    for x in max(0, Int(box.minX))..<min(extent, Int(box.maxX.rounded(.up))) {
                        let index = (y * extent + x) * 4
                        if with[index ..< index + 4] != without[index ..< index + 4] { touched += 1 }
                    }
                }
                XCTAssertEqual(touched, 0, "\(String(describing: motion.sign)) at \(side): a fin by the sign")
            }
        }

        // The copy: 0.4 of the body, its centre 0.42 of the side right of the body's and 0.18 below, with a gap of 0.035
        // round it and its own fins, all in body radii here. At every height the hands reach while it stands there, a
        // beat's or a start's, what clears the body of the hand on its side lies under the copy, its fins or their gap,
        // and the other fins keep clear of all of them.
        let copy = CGPoint(x: 0.42 / spec.radius, y: 0.18 / spec.radius)
        let gap: CGFloat = 0.035 / spec.radius, covered: CGFloat = 0.4 + gap
        let small = CGAffineTransform(translationX: copy.x, y: copy.y).scaledBy(x: 0.4, y: 0.4)
        let copyFins = CGMutablePath()
        for fin in Self.fins(of: spec) { copyFins.addPath(BotFins.path(fin, grown: 1, raised: 0), transform: small) }
        let copyGap = copyFins.copy(strokingWithWidth: 2 * gap, lineCap: .round, lineJoin: .round, miterLimit: 1)
        func underCopy(_ point: CGPoint) -> Bool {
            let fromCopy: CGFloat = hypot(point.x - copy.x, point.y - copy.y)
            return fromCopy <= covered || copyFins.contains(point) || copyGap.contains(point)
        }
        for fin in Self.fins(of: spec) {
            for raised in [0, BotMoves.paddle, 32] as [CGFloat] {
                let path = BotFins.path(fin, grown: 1, raised: raised)
                var shows = 0, beside = 0
                for i in -160...160 {
                    for j in -160...160 {
                        let point = CGPoint(x: CGFloat(i) / 100, y: CGFloat(j) / 100)
                        guard hypot(point.x, point.y) > 1, path.contains(point) else { continue }
                        if !underCopy(point) { shows += 1 }
                        let fromCopy: CGFloat = hypot(point.x - copy.x, point.y - copy.y)
                        if fromCopy < covered + 0.1 || copyGap.contains(point) { beside += 1 }
                    }
                }
                if fin.hand > 0 {
                    XCTAssertEqual(shows, 0, "the right hand raised \(raised)° shows beside the copy")
                } else {
                    XCTAssertEqual(beside, 0, "a fin at \(fin.angle)° raised \(raised)° by the copy")
                }
            }
        }
    }

    // MARK: Flapping

    /// The hands go up together on every beat of a tool's bob, and in a flap at a start and in three over a reply's
    /// card; one waves at a greeting, the one on the pointer's side. Every other look and event leaves them still, and a
    /// bot without hands never flaps.
    func testHandsFlapOnlyOnAToolsBeatsAStartAReplyAndAGreeting() {
        func flaps(_ frames: [Frame]) -> [BotFlap] { frames.map(\.motion.flap) }
        let still = BotFlap()

        // A tool: both hands, the paddle's height on every beat the body dips, and only then.
        var tool = fish()
        tool.set(BotState(look: .tool(.edit)), at: 0)
        let working = drive(&tool, from: 0, for: 9.1)
        for frame in working where frame.motion.morph == 1 {
            let dips = frame.motion.pose.y > 0.001
            XCTAssertEqual(frame.motion.flap, dips ? BotFlap(both: BotMoves.paddle) : still, "at \(frame.now)")
        }
        XCTAssertTrue(flaps(working).contains(BotFlap(both: BotMoves.paddle)))
        XCTAssertTrue(working.filter { (3.1...4.4).contains($0.now) }.allSatisfy { $0.motion.flap == still }, "still in a rest")

        // Still through every other look, staying or not, and through a held tool.
        let looks: [BotState] = [BotState(look: .thinking), BotState(look: .plain), BotState(look: .compacting),
                                 BotState(look: .permission), BotState(look: .question), BotState(look: .plan),
                                 BotState(look: .permission, facing: .left), BotState(look: .noNews), BotState(look: .idle),
                                 BotState(look: .asleep), BotState(look: .tool(.read), holds: true),
                                 BotState(look: .thinking, hovered: true), BotState(look: .plain, subagents: true)]
        for state in looks {
            for staysBot in [false, true] {
                var motion = fish(staysBot: staysBot)
                motion.set(state, at: 0)
                XCTAssertTrue(flaps(drive(&motion, from: 0, for: 12)).allSatisfy { $0 == still }, "\(state) staying \(staysBot)")
            }
        }

        // Events: a start flaps both hands once, a failure and a limit leave them be.
        for event in BotEvent.allCases {
            var motion = fish()
            motion.set(BotState(look: .plain), at: 0)
            drive(&motion, from: 0, for: 1)
            motion.play(event, at: 1)
            let frames = drive(&motion, from: 1, for: 2)
            let raised = frames.filter { $0.motion.flap != still }
            if event == .start {
                XCTAssertFalse(raised.isEmpty)
                XCTAssertTrue(raised.allSatisfy { $0.motion.flap.left == $0.motion.flap.right })
                XCTAssertGreaterThan(raised.map(\.motion.flap.left).max() ?? 0, 25)
                XCTAssertLessThanOrEqual((raised.last?.now ?? 0) - (raised.first?.now ?? 0), BotMoves.hopSeconds)
                XCTAssertEqual(frames.last?.motion.flap, still)
            } else {
                XCTAssertTrue(raised.isEmpty, "\(event)")
            }
        }

        // A reply's card: both hands, three times, then still.
        var reply = fish(staysBot: true)
        reply.set(BotState(card: .done), at: 0)
        let cheering = drive(&reply, from: 0, for: 3)
        let up = cheering.filter { $0.motion.flap != still }
        XCTAssertGreaterThan(up.count, 10)
        XCTAssertTrue(up.allSatisfy { $0.motion.flap.left == $0.motion.flap.right && $0.now < 1.5 })
        XCTAssertEqual(reply.flap, still)

        // A greeting: the hand on the pointer's side waves, the other stays down; the left one beside a copy for sub-agents.
        for (state, aim, side) in [(BotState(look: .idle), CGPoint(x: 0.6, y: 0.2), 1.0),
                                   (BotState(look: .asleep), CGPoint(x: -0.6, y: 0.2), -1.0),
                                   (BotState(look: .plain, subagents: true, badge: .failed), CGPoint(x: 0.6, y: 0.2), -1.0)]
                as [(BotState, CGPoint, CGFloat)] {
            var motion = fish()
            motion.set(state, at: 0)
            drive(&motion, from: 0, for: 1, aim: aim)
            var hovered = state
            hovered.hovered = true
            motion.set(hovered, at: 1)
            let frames = drive(&motion, from: 1, for: 3, aim: aim)
            let waving = frames.map { side < 0 ? $0.motion.flap.left : $0.motion.flap.right }
            let other = frames.map { side < 0 ? $0.motion.flap.right : $0.motion.flap.left }
            XCTAssertGreaterThan(waving.max() ?? 0, 30, "\(state): waves")
            XCTAssertTrue(other.allSatisfy { $0 == 0 }, "\(state): one hand")
            XCTAssertEqual(motion.flap, still, "\(state): and puts it down")
        }

        // A bot without hands keeps its flap at rest through all of it.
        var other = BotMotion(seed: 5)
        other.fit(BotSpec.table["Grok Bot"]!)
        other.set(BotState(look: .tool(.edit)), at: 0)
        var frames = drive(&other, from: 0, for: 5)
        other.play(.start, at: 5)
        frames += drive(&other, from: 5, for: 1)
        other.set(BotState(look: .idle, hovered: true), at: 6)
        frames += drive(&other, from: 6, for: 2)
        XCTAssertTrue(flaps(frames).allSatisfy { $0 == still })
    }

    /// The hands ask the clock for no frame of their own: a fish is stepped at the frames a bot without hands would be,
    /// apart from a greeting's wave, which outlasts the hop. Between two beats the hands, and so the picture, hold still.
    func testHandsAskForNoFramesOfTheirOwnAndHoldStillBetweenBeats() throws {
        for state in [BotState(look: .tool(.edit)), BotState(look: .thinking), BotState(look: .permission),
                      BotState(look: .tool(.command), subagents: true), BotState(look: .plain)] {
            for staysBot in [false, true] {
                var fish = self.fish(staysBot: staysBot), plain = fish
                plain.finned = false
                fish.set(state, at: 0)
                plain.set(state, at: 0)
                fish.play(.start, at: 2)
                plain.play(.start, at: 2)
                let finned = drive(&fish, from: 0, for: 20).map(\.now), unfinned = drive(&plain, from: 0, for: 20).map(\.now)
                XCTAssertEqual(finned, unfinned, "\(state) staying \(staysBot)")
            }
        }
        // A staying fish asleep, and one holding a look, still rest with no clock.
        var asleep = fish(staysBot: true)
        asleep.set(BotState(look: .asleep), at: 0)
        drive(&asleep, from: 0, for: 30)
        XCTAssertNil(asleep.wait)
        var held = fish()
        held.set(BotState(look: .tool(.edit), holds: true), at: 0)
        drive(&held, from: 0, for: 30)
        XCTAssertNil(held.wait)

        // Every lively frame within one beat of a burst has the same hands, and a frame whose eyes have not moved since
        // the one before is that frame again, with the hands up or down.
        let form = try XCTUnwrap(BotForm.form(for: "DeepSeek", ground: .dark))
        var motion = fish(seed: 3)
        motion.set(BotState(look: .tool(.edit)), at: 0)
        var byBeat: [Int: Set<BotFlap>] = [:], now: TimeInterval = 0, same = 0
        var last: (face: BotFace, flap: BotFlap, data: Data)?
        while now < 3 {
            motion.step(to: now)
            if motion.morph == 1, let data = BotRenderer.image(form, motion: motion, side: 40)?.dataProvider?.data as Data? {
                byBeat[Int(now / BotMoves.beat + 1e-6), default: []].insert(motion.flap)
                if let last, last.face == motion.face, last.flap == motion.flap {
                    XCTAssertEqual(last.data, data, "at \(now)")
                    same += 1
                }
                last = (motion.face, motion.flap, data)
            }
            now += BotPace.lively
        }
        XCTAssertTrue(byBeat.values.allSatisfy { $0.count == 1 }, "the hands move on the beat only")
        XCTAssertGreaterThan(Set(byBeat.values.flatMap { $0 }).count, 1)
        XCTAssertGreaterThan(same, 5)
    }

    /// Frames with the hands up, coming down and at rest, drawn from what is kept of earlier frames, are the frames drawn
    /// whole; the still part with the hands at rest is kept again once they stop.
    func testFramesWithFlappingHandsFromKeptPartsAreTheFramesDrawnWhole() throws {
        let form = try XCTUnwrap(BotForm.form(for: "DeepSeek", ground: .dark))
        let timeline: [(TimeInterval, BotState, BotEvent?)] = [
            (0, BotState(look: .tool(.edit)), nil), (2.4, BotState(look: .tool(.edit), subagents: true), .start),
            (4, BotState(look: .idle, hovered: true), nil),
            (6, BotState(look: .tool(.edit), subagents: true, badge: .failed, hovered: true), nil),
            (8, BotState(card: .done), nil),
        ]
        var motion = fish(staysBot: true, seed: 7)
        var drawn: [BotMotion] = [], shown: BotRenderer.Look?, next = 0, frame = 0
        while Double(frame) / 30 < 10 {
            let now = Double(frame) / 30
            while next < timeline.count, timeline[next].0 <= now {
                motion.set(timeline[next].1, at: now)
                if let event = timeline[next].2 { motion.play(event, at: now) }
                next += 1
            }
            motion.step(to: now, aim: CGPoint(x: 0.5 * cos(now), y: 0.3))
            let look = BotRenderer.look(of: motion)
            if look != shown { shown = look; drawn.append(motion) }
            frame += 1
        }
        XCTAssertGreaterThan(Set(drawn.map(\.flap)).count, 8)
        for (side, outline, space) in [(CGFloat(40), 1, CGColorSpace(name: CGColorSpace.displayP3)), (72, 0, nil)] {
            func bytes(_ motion: BotMotion) -> Data? {
                BotRenderer.image(form, motion: motion, side: side, outline: outline, space: space)?.dataProvider?.data as Data?
            }
            let kept = drawn.map(bytes)
            var differing: [Int] = []
            for (index, motion) in drawn.enumerated() {
                BotCanvas.forget()
                BotStill.forget()
                if kept[index] != bytes(motion) { differing.append(index) }
            }
            XCTAssertEqual(differing.prefix(10), [], "\(differing.count) of \(drawn.count) frames at \(side) differ")
        }
    }
}

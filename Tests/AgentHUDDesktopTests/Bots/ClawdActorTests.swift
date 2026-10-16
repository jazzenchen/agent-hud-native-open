import AppKit
import QuartzCore
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class ClawdActorTests: XCTestCase {
    private let sheet = ClawdFixture.everySprite()
    private var hosts: [CALayer] = []

    override func tearDown() {
        MainActor.assumeIsolated { ClawdSprites.shared.use(nil) }
        super.tearDown()
    }

    /// A bot for `vendor`'s mark, in a layer of its own the way a queue holds it: 20 pt on a Retina display with a
    /// hairline, unless told otherwise.
    private func actor(_ sprites: ClawdSprites? = nil, vendor: String = "Claude", staysBot: Bool = false, side: CGFloat = 20,
                       outline: Int = 1, at position: CGPoint = CGPoint(x: 50, y: 40)) throws -> BotActor {
        let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
        let actor = BotActor(form: form, staysBot: staysBot, period: 3, arrivesAfter: staysBot ? BotMark.arrival : 0, seed: 5,
                             sprites: sprites ?? ClawdSprites(sheet: sheet))
        actor.resize(side: side, scale: 2, outline: outline)
        if staysBot { actor.restsHidden = false }
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
        host.addSublayer(actor.layer)
        actor.layer.position = position
        hosts.append(host)
        return actor
    }

    private func step(_ actor: BotActor, _ now: TimeInterval) -> TimeInterval? {
        actor.step(to: now, yRunsDown: false) { .zero }
    }

    /// Steps `actor` from `start` until `end`, only when it says it is due, calling `each` after every step with the time
    /// and the wait it asked for. Returns the time of the last step.
    @discardableResult
    private func run(_ actor: BotActor, from start: TimeInterval, until end: TimeInterval,
                     each: (TimeInterval, TimeInterval?) -> Void = { _, _ in }) -> TimeInterval {
        var now = start
        while true {
            let wait = step(actor, now)
            each(now, wait)
            guard let wait, now + wait <= end else { return now }
            now += max(wait, 1e-3)
        }
    }

    /// The frame the baker keeps for what Clawd shows now, as the actor's layer is sized.
    private func baked(_ clawd: ClawdActor) -> CGImage? {
        clawd.performer.picture.flatMap { clawd.baker.image($0, side: 20, scale: 2, outline: 1, ground: .dark) }
    }

    private func bytes(_ image: CGImage?) -> Data? { (image?.dataProvider?.data).map { $0 as Data } }

    private func logo(sign: BotSign? = nil, outline: Int = 1) throws -> Data? {
        bytes(BotRenderer.logo(try XCTUnwrap(BotForm.form(for: "Claude", ground: .dark)), sign: sign, side: 40, outline: outline))
    }

    // MARK: Sprites or the drawn Clawd

    func testClaudesMarkPlaysTheSpritesForEveryLook() throws {
        let tools: [BotLook] = BotTool.allCases.map { BotLook.tool($0) }
        let looks: [BotLook] = [.permission, .question, .plan, .compacting, .thinking, .plain] + tools
        for look in looks {
            let actor = try actor()
            actor.set(BotState(look: look), at: 10)
            var frames = 0
            run(actor, from: 10, until: 13) { _, _ in
                guard let clawd = actor.clawd else { return XCTFail("\(look): drawn") }
                XCTAssertTrue((clawd.front.contents as! CGImage?) === baked(clawd), "\(look): the baked frame, as it is")
                frames += 1
            }
            XCTAssertGreaterThan(frames, 10, "\(look)")
            XCTAssertFalse(actor.layer.isHidden)
            XCTAssertNil(actor.layer.contents, "\(look): nothing drawn in the bot's own way")
            XCTAssertEqual(actor.layer.affineTransform(), .identity, "\(look): a sprite is never moved, scaled or turned")
        }
    }

    /// By a card above or below it, on a top or bottom dock, Clawd stands still with its wait's sign, baked from the
    /// sprites as any frame is.
    func testClawdByACardAboveOrBelowItStandsWithItsWaitsSign() throws {
        let actor = try actor()
        actor.set(BotState(look: .question, facing: .down), at: 10)
        run(actor, from: 10, until: 12)
        let clawd = try XCTUnwrap(actor.clawd)
        XCTAssertEqual(clawd.performer.picture, ClawdPicture(frame: sheet.canonical(.standing), sign: .question))
        let front = try XCTUnwrap(clawd.front.contents as! CGImage?)
        XCTAssertTrue(front === baked(clawd), "the baked frame, as it is")
        let bare = clawd.baker.image(ClawdPicture(frame: sheet.canonical(.standing)), side: 20, scale: 2, outline: 1, ground: .dark)
        XCTAssertNotEqual(bytes(front), bytes(bare), "the sign is drawn over it")
    }

    /// A dock built again after a card hid it: Clawd is out from the first frame, at its look's loop, with no fade.
    func testAnAwakeActorShowsClawdsLoopAtOnce() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Claude", ground: .dark))
        let actor = BotActor(form: form, staysBot: false, period: 3, seed: 5, sprites: ClawdSprites(sheet: sheet), awake: true)
        actor.resize(side: 20, scale: 2, outline: 1)
        let host = CALayer()
        host.addSublayer(actor.layer)
        hosts.append(host)
        actor.set(BotState(look: .tool(.edit)), at: 10)
        _ = step(actor, 10)
        let clawd = try XCTUnwrap(actor.clawd)
        XCTAssertEqual(clawd.performer.picture?.frame, ClawdClips.standard.clip(for: .edit).loopFrames.first)
        XCTAssertFalse(actor.layer.isHidden)
        XCTAssertTrue(clawd.back.isHidden, "nothing to fade from")
        XCTAssertNil(clawd.front.animationKeys())
        XCTAssertNil(actor.layer.animationKeys())
    }

    /// A dock built again after a card, or a stage built anew, sets its bot and tells it an event before the first step,
    /// which is when the sprites take over: the event still plays.
    func testAnEventToldBeforeTheFirstStepPlays() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Claude", ground: .dark))
        for awake in [false, true] {
            let actor = BotActor(form: form, staysBot: false, period: 3, seed: 5, sprites: ClawdSprites(sheet: sheet), awake: awake)
            actor.resize(side: 20, scale: 2, outline: 1)
            let host = CALayer()
            host.addSublayer(actor.layer)
            hosts.append(host)
            actor.set(BotState(look: .idle, badge: .failed), at: 10)
            actor.play(.failed, at: 10)
            var played = false
            run(actor, from: 10, until: 13) { _, _ in played = played || actor.clawd?.performer.player.playing == .failed }
            XCTAssertTrue(played, "awake \(awake)")
        }
    }

    /// A dock built again after a card takes up a mark with no news as it was, at half strength, with nothing to fade.
    func testAnAwakeMarkWithNoNewsDoesNotFadeFromFullStrength() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Claude", ground: .dark))
        let actor = BotActor(form: form, staysBot: false, period: 3, seed: 5, sprites: ClawdSprites(sheet: sheet), awake: true)
        actor.resize(side: 20, scale: 2, outline: 1)
        let host = CALayer()
        host.addSublayer(actor.layer)
        hosts.append(host)
        actor.set(BotState(look: .noNews), at: 10)
        _ = step(actor, 10)
        XCTAssertNotNil(actor.clawd)
        XCTAssertFalse(actor.layer.isHidden)
        XCTAssertEqual(actor.layer.opacity, 0.5)
        XCTAssertNil(actor.layer.animation(forKey: "opacity"))
    }

    func testWithoutSpritesOrBelowTheirSizeClawdIsDrawn() throws {
        for actor in [try actor(ClawdSprites()), try actor(side: 12)] {
            actor.set(BotState(look: .tool(.edit)), at: 10)
            run(actor, from: 10, until: 11)
            XCTAssertNil(actor.clawd)
            XCTAssertNotNil(actor.layer.contents, "the drawn Clawd")
            XCTAssertNil(actor.layer.sublayers)
        }
        // Another mark never plays Clawd's sprites.
        let codex = try actor(vendor: "Codex")
        codex.set(BotState(look: .thinking), at: 10)
        run(codex, from: 10, until: 11)
        XCTAssertNil(codex.clawd)

        // A mark that grows past the size the sprites need changes over to them, and back when it shrinks again.
        let growing = try actor(side: 12)
        growing.set(BotState(look: .thinking), at: 10)
        run(growing, from: 10, until: 11)
        growing.resize(side: 20, scale: 2, outline: 1)
        _ = step(growing, 11.1)
        XCTAssertNotNil(growing.clawd)
        XCTAssertNotNil(growing.layer.animation(forKey: kCATransition), "the drawn Clawd fades into the sprites")
        growing.resize(side: 12, scale: 2, outline: 1)
        _ = step(growing, 11.2)
        XCTAssertNil(growing.clawd)
        XCTAssertNil(growing.layer.sublayers)
    }

    func testSpritesReadLaterTakeOverWithAFade() throws {
        let sprites = ClawdSprites()
        let actor = try actor(sprites)
        actor.set(BotState(look: .thinking), at: 10)
        run(actor, from: 10, until: 12)
        XCTAssertNil(actor.clawd)
        XCTAssertNotNil(actor.layer.contents)
        actor.layer.removeAllAnimations()
        sprites.use(sheet)
        // Even a bot that meant to wait steps over at once.
        _ = step(actor, 12.01)
        let clawd = try XCTUnwrap(actor.clawd)
        let fade = try XCTUnwrap(actor.layer.animation(forKey: kCATransition) as? CATransition)
        XCTAssertEqual(fade.type, .fade)
        XCTAssertEqual(fade.duration, ClawdActor.fade)
        XCTAssertNil(actor.layer.contents)
        XCTAssertNotNil(clawd.front.contents)
        XCTAssertNil(clawd.back.animation(forKey: "fade"), "one fade, from the drawn Clawd, and none from the logo")
        XCTAssertEqual(clawd.performer.player.shown, .thinking, "the look picked up")
    }

    // MARK: Frames and the clock

    func testTheWaitIsWhenThePictureNextChanges() throws {
        let actor = try actor()
        actor.set(BotState(look: .tool(.read)), at: 10.02)
        var waits = 0
        run(actor, from: 10.02, until: 20) { now, wait in
            guard let wait, let clawd = actor.clawd else { return XCTFail("no wait") }
            // The fade in from the logo ends on a sprite frame of its own; after it, every wake is the player's.
            if now > 10.5 { XCTAssertEqual(now + wait, try! XCTUnwrap(clawd.performer.due), accuracy: 1e-9) }
            XCTAssertEqual((now + wait) * 12, ((now + wait) * 12).rounded(), accuracy: 1e-6, "on the 1/12 s grid")
            waits += 1
        }
        // LookingAround at 6 fps: about six frames a second, and no more wakes than that.
        XCTAssertLessThan(waits, 10 * 6 + 5)
        XCTAssertGreaterThan(waits, 10 * 5)
    }

    func testAFrameIsHandedOverOnlyWhenThePictureChanges() throws {
        let actor = try actor()
        let state = BotState(look: .thinking)
        actor.set(state, at: 10)
        _ = step(actor, 10)
        let clawd = try XCTUnwrap(actor.clawd)
        let handed = Tally()
        let watch = clawd.front.observe(\.contents) { _, _ in handed.count += 1 }
        defer { watch.invalidate() }
        var pictures = 0, last = clawd.performer.picture
        // Told the same state sixty times a second, as an eager view might, so it steps far more often than it is due.
        var now = 10.0
        while now < 15 {
            now += 1.0 / 60
            actor.set(state, at: now)
            _ = step(actor, now)
            if clawd.performer.picture != last { pictures += 1; last = clawd.performer.picture }
        }
        XCTAssertGreaterThan(pictures, 40)
        XCTAssertEqual(handed.count, pictures, "a new frame for every new picture, and for nothing else")
    }

    func testSpritePixelsLandOnWholeDevicePixels() throws {
        let actor = try actor(at: CGPoint(x: 50.3, y: 40.7))
        actor.set(BotState(look: .thinking), at: 10)
        _ = step(actor, 10)
        let clawd = try XCTUnwrap(actor.clawd)
        for part in [clawd.front, clawd.back] {
            let corner = part.convert(CGPoint.zero, to: nil)
            XCTAssertEqual(corner.x * 2, (corner.x * 2).rounded(), accuracy: 1e-9)
            XCTAssertEqual(corner.y * 2, (corner.y * 2).rounded(), accuracy: 1e-9)
            XCTAssertEqual(part.contentsScale, 2)
            XCTAssertEqual(part.magnificationFilter, .nearest)
            XCTAssertEqual(part.minificationFilter, .nearest)
            XCTAssertEqual(part.bounds.size, actor.layer.bounds.size, "the frame's own size: never scaled")
        }
        let image = try XCTUnwrap(clawd.front.contents as! CGImage?)
        XCTAssertEqual(CGFloat(image.width), actor.layer.bounds.width * 2, accuracy: 1e-9)
    }

    // MARK: The logo

    func testTheLogoIsTheFrameTheDrawnBotRestsOn() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Claude", ground: .dark))
        for (badge, sign) in [(nil, nil), (BotBadge.failed, BotSign.cross), (.limited, .hourglass)] as [(BotBadge?, BotSign?)] {
            var motion = BotMotion(seed: 1)
            motion.fit(form.spec)
            motion.set(BotState(look: .idle, badge: badge), at: 0)
            motion.step(to: 0)
            XCTAssertEqual(motion.morph, 0)
            XCTAssertEqual(bytes(BotRenderer.logo(form, sign: sign, side: 40, outline: 1)),
                           bytes(BotRenderer.image(form, motion: motion, side: 40, outline: 1)), "\(String(describing: sign))")
        }
    }

    func testTheLogoAndClawdFadeIntoEachOther() throws {
        let actor = try actor()
        actor.set(BotState(look: .idle), at: 10)
        _ = step(actor, 10)
        XCTAssertTrue(actor.layer.isHidden, "the queue's own mark shows the logo")

        actor.set(BotState(look: .thinking), at: 10.5)
        _ = step(actor, 10.5)
        let clawd = try XCTUnwrap(actor.clawd)
        XCTAssertFalse(actor.layer.isHidden)
        XCTAssertEqual(bytes(clawd.back.contents as! CGImage?), try logo(), "from the logo")
        XCTAssertTrue((clawd.front.contents as! CGImage?) === baked(clawd), "into Clawd")
        for (part, from, to) in [(clawd.back, 1, 0), (clawd.front, 0, 1)] as [(CALayer, Float, Float)] {
            let fade = try XCTUnwrap(part.animation(forKey: "fade") as? CABasicAnimation)
            XCTAssertEqual(fade.fromValue as? Float, from)
            XCTAssertEqual(fade.toValue as? Float, to)
            XCTAssertEqual(fade.duration, ClawdActor.fade)
            XCTAssertEqual(part.opacity, to)
        }
        XCTAssertFalse(clawd.back.isHidden)
        // Once the fade is over, the picture it faded out of is let go.
        run(actor, from: 10.5 + 1.0 / 24, until: 10.9)
        XCTAssertTrue(clawd.back.isHidden)
        XCTAssertNil(clawd.back.contents)

        // The turn ends: Clawd finishes its cycle and its outro, then fades into the logo, and only then leaves it to
        // the queue's mark.
        actor.set(BotState(look: .idle), at: 11)
        var faded: TimeInterval?
        run(actor, from: 11, until: 15) { now, _ in
            if faded == nil, clawd.performer.picture == nil {
                faded = now
                XCTAssertFalse(actor.layer.isHidden, "still fading")
                XCTAssertEqual(self.bytes(clawd.front.contents as! CGImage?), try? self.logo())
                XCTAssertNotNil(clawd.back.contents, "out of Clawd's last frame")
                XCTAssertNotNil(clawd.back.animation(forKey: "fade"))
            }
        }
        let start = try XCTUnwrap(faded)
        XCTAssertTrue(actor.layer.isHidden)
        XCTAssertLessThanOrEqual(run(actor, from: start, until: start + ClawdActor.fade + 0.1) - start, ClawdActor.fade + 0.1)
    }

    func testALogoWithABadgeOrNoNewsIsTheBotsToDraw() throws {
        let badged = try actor()
        badged.set(BotState(look: .idle, badge: .failed), at: 10)
        _ = step(badged, 10)
        let clawd = try XCTUnwrap(badged.clawd)
        XCTAssertFalse(badged.layer.isHidden, "the queue's mark has no sign")
        XCTAssertEqual(bytes(clawd.front.contents as! CGImage?), try logo(sign: .cross))

        let quiet = try actor()
        quiet.set(BotState(look: .noNews), at: 10)
        _ = step(quiet, 10)
        XCTAssertFalse(quiet.layer.isHidden)
        XCTAssertEqual(quiet.layer.opacity, 0.5)
        let dimming = try XCTUnwrap(quiet.layer.animation(forKey: "opacity") as? CABasicAnimation)
        XCTAssertEqual(dimming.fromValue as? Float, 1, "from the queue's mark at full strength")
        // Greeted, Clawd comes up at full strength.
        quiet.set(BotState(look: .noNews, hovered: true), at: 11)
        run(quiet, from: 11, until: 11.5)
        XCTAssertNotNil(try XCTUnwrap(quiet.clawd).performer.picture)
        XCTAssertEqual(quiet.layer.opacity, 1)
    }

    func testKeptFramesGoAfterAMinuteAsTheLogo() throws {
        let actor = try actor()
        actor.set(BotState(look: .thinking), at: 10)
        run(actor, from: 10, until: 13)
        let clawd = try XCTUnwrap(actor.clawd)
        actor.set(BotState(look: .noNews), at: 13)
        var rested: TimeInterval?
        let last = run(actor, from: 13, until: 200) { now, wait in
            if rested == nil, clawd.performer.picture == nil {
                rested = now
                XCTAssertGreaterThan(clawd.baker.count, 0)
            }
            if let rested, now < rested + ClawdActor.keepsFrames - 0.01 {
                XCTAssertGreaterThan(clawd.baker.count, 0, "kept for a minute")
                XCTAssertNotNil(wait, "woken to let them go")
            }
        }
        let since = try XCTUnwrap(rested)
        XCTAssertEqual(clawd.baker.count, 0)
        XCTAssertEqual(last, since + ClawdActor.keepsFrames, accuracy: 1.0 / 12 + 1e-9, "let go after a minute, then at rest")
        XCTAssertNil(step(actor, last + 1), "a mark with no news rests with no clock")
    }

    /// An idle mark visits as its bot every 20 to 35 s, so it never rests a whole minute as its logo; the time it spends
    /// at rest is counted across its visits, and its frames go between two of them.
    func testAnIdleMarkLetsItsFramesGoBetweenVisits() throws {
        let actor = try actor()
        actor.set(BotState(look: .tool(.edit)), at: 10)
        run(actor, from: 10, until: 70)
        let clawd = try XCTUnwrap(actor.clawd)
        actor.set(BotState(), at: 70)
        var visits = 0, showing = false, purged = false, steps = 0
        run(actor, from: 70, until: 70 + 1800) { _, _ in
            steps += 1
            if clawd.performer.picture != nil, !showing { visits += 1 }
            showing = clawd.performer.picture != nil
            if !showing, clawd.baker.count == 0 { purged = true }
        }
        XCTAssertGreaterThan(visits, 10, "an idle mark visits")
        XCTAssertTrue(purged, "its frames go between visits")
        XCTAssertLessThan(steps, 1800 * 12, "it is not woken more than its frames ask")
    }

    // MARK: Reminder cards

    func testAReminderCardOpensAsItsLogoThenPlaysItsClipAndStands() throws {
        for (card, sprite) in [(BotCard.done, ClawdSpriteName.excited), (.longDone, .dancingHappy), (.reset, .spark)] {
            let actor = try actor(staysBot: true, side: 17, outline: 0)
            actor.set(BotState(card: card), at: 10)
            let wait = try XCTUnwrap(step(actor, 10))
            let clawd = try XCTUnwrap(actor.clawd)
            XCTAssertNil(clawd.performer.picture)
            XCTAssertFalse(actor.layer.isHidden, "a card's mark is drawn by its bot alone")
            XCTAssertEqual(wait, BotMark.arrival, accuracy: 1.0 / 12, "the logo while the card opens")
            _ = step(actor, 10 + wait)
            XCTAssertEqual(clawd.performer.picture?.frame.sprite, sprite, "\(card)")
            XCTAssertNotNil(clawd.back.animation(forKey: "fade"), "the logo fades into Clawd")
            let end = run(actor, from: 10 + wait, until: 30)
            XCTAssertEqual(clawd.performer.picture?.frame, .standing, "\(card): standing once its clip is over")
            XCTAssertLessThan(end, 16, "\(card)")
            XCTAssertNil(step(actor, end + 1), "\(card): and still, with no clock")
        }
    }

    /// A reminder card's mark, through its stage and the shared clock, the way the island shows it.
    func testAStageShowsAReminderCardsClawdFromTheSprites() throws {
        ClawdSprites.shared.use(sheet)
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let window = SeenWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let stage = BotStageView(frame: frame)
        window.contentView = stage
        defer { BotClock.shared.drop(stage); window.close() }
        stage.show(vendor: "Claude", size: 17, scale: 2, state: BotState(look: .question), staysBot: true, ground: .dark)
        RunLoop.main.run(until: Date().addingTimeInterval(BotMark.arrival + 0.3))
        let bot = try XCTUnwrap(stage.layer?.sublayers?.first)
        XCTAssertNil(bot.contents, "not the drawn Clawd")
        let parts = try XCTUnwrap(bot.sublayers)
        XCTAssertEqual(parts.count, 2, "the picture, and the one it fades out of")
        XCTAssertNotNil(parts[1].contents)
        XCTAssertFalse(bot.isHidden)
    }
}

/// A count kept by an observer the layer calls back.
private final class Tally: @unchecked Sendable {
    var count = 0
}

import XCTest
@testable import AgentHUDDesktop

final class ClawdClipsTests: XCTestCase {
    /// How many frames each of the game's sprites has in the Claude app the clips were written against.
    static let realFrameCounts: [ClawdSpriteName: Int] = [
        .breakDancing: 149, .confetti: 34, .crabWalking: 20, .dancingHappy: 40, .desktop: 88, .disappointed: 44,
        .dizzy: 41, .excited: 23, .facepalm: 35, .hula: 54, .jumping: 21, .jumpingHappy: 21, .laptop: 43,
        .lightbulb: 50, .lookingAround: 31, .lookingAroundEyesOnly: 42, .meditating: 60, .pointing: 43, .running: 20,
        .spark: 73, .swaying: 49, .thinking: 38, .turning: 29, .walking: 28, .waving: 17,
    ]

    private let clips = ClawdClips.standard

    func testEveryFrameAClipPlaysIsInTheGame() {
        XCTAssertEqual(Self.realFrameCounts.count, ClawdSpriteName.allCases.count)
        for frame in clips.frames {
            let count = Self.realFrameCounts[frame.sprite] ?? 0
            XCTAssertTrue((0..<count).contains(frame.index), "\(frame) is not one of \(count) frames")
        }
        for (sprite, count) in clips.frameCounts {
            XCTAssertEqual(count, Self.realFrameCounts[sprite], sprite.rawValue)
        }
        XCTAssertEqual(Set(clips.frameCounts.keys), Set(clips.frames.map(\.sprite)), "every sprite used, and no other")
    }

    /// Frames as the game numbers them, written the way the spec writes them.
    private func indexes(_ frames: [ClawdFrame], of sprite: ClawdSpriteName) -> [Int] {
        frames.map { $0.sprite == sprite ? $0.index : -1 }
    }

    func testTheLooksPlayTheirClips() {
        let thinking = clips.clip(for: .thinking)
        XCTAssertEqual(indexes(thinking.intro, of: .thinking), [4, 5])
        XCTAssertEqual(thinking.loop, Array(6...19))
        XCTAssertEqual(thinking.outro, ClawdSpriteName.thinking[5, 4] + [.standing])
        XCTAssertEqual(clips.clip(for: .retrying).name, thinking.name, "retrying holds thinking still")

        let laptop = clips.clip(for: .edit)
        XCTAssertEqual(clips.clip(for: .command).name, laptop.name)
        XCTAssertEqual(laptop.intro, ClawdSpriteName.laptop[14...16], "cut from standing to the laptop on the ground")
        XCTAssertEqual(laptop.loop, Array(17...33))
        XCTAssertEqual(laptop.outro, ClawdSpriteName.laptop[34...42])
        XCTAssertEqual(laptop.offset, ClawdOffset(x: -1))
        XCTAssertEqual(laptop.miniShift, -14, "the mini stands left of the laptop")
        XCTAssertEqual(thinking.miniShift, 13)

        let desktop = clips.clip(for: .longCommand)
        XCTAssertEqual(desktop.intro, ClawdSpriteName.desktop[3...15])
        XCTAssertEqual(desktop.entry, ClawdSpriteName.desktop[7...15])
        XCTAssertEqual(desktop.loop, Array(16...75))
        XCTAssertEqual(desktop.outro, ClawdSpriteName.desktop[76...87])
        XCTAssertEqual(desktop.offset, ClawdOffset(x: -3))
        XCTAssertEqual(desktop.exit, .anyFrame, "a finished turn does not wait out the five-second cycle")
        XCTAssertNil(desktop.miniShift, "no room for the mini beside the desk")

        let reading = clips.clip(for: .read)
        XCTAssertEqual(reading.sprite, .lookingAround)
        XCTAssertEqual(reading.loop, Array(6...15))
        XCTAssertEqual(reading.ticks, 2, "6 fps")
        XCTAssertTrue(reading.intro.isEmpty && reading.outro.isEmpty && reading.entry == nil)
        XCTAssertEqual(reading.miniShift, 13)
        for look in ClawdLook.allCases where !look.isWorking { XCTAssertNil(clips.clip(for: look).miniShift, "\(look)") }

        let meditating = clips.clip(for: .compacting)
        XCTAssertEqual(meditating.intro, ClawdSpriteName.meditating[6...13])
        XCTAssertEqual(meditating.loop, Array(23...34))
        XCTAssertEqual(meditating.exit, .through(23))
        XCTAssertEqual(meditating.outro, ClawdSpriteName.meditating[45...54])

        let pointing = clips.clip(for: .permission)
        XCTAssertEqual(pointing.intro, ClawdSpriteName.pointing[6...18])
        XCTAssertEqual(pointing.loop, Array(19...23))
        XCTAssertEqual(pointing.sign, .permission)
        XCTAssertEqual(pointing.exit, .anyFrame)
        XCTAssertEqual(pointing.outro, ClawdSpriteName.pointing[18] + [.standing])

        let waving = clips.clip(for: .question)
        XCTAssertEqual(waving.intro, ClawdSpriteName.waving[3...6])
        XCTAssertEqual(waving.loop, [7, 8])
        XCTAssertEqual(waving.sign, .question)
        XCTAssertEqual(waving.exit, .through(8))
        XCTAssertEqual(waving.outro, ClawdSpriteName.waving[6] + [.standing])

        let lightbulb = clips.clip(for: .plan)
        XCTAssertEqual(lightbulb.intro, ClawdSpriteName.lightbulb[4...10])
        XCTAssertEqual(lightbulb.loop, Array(11...38))
        XCTAssertEqual(lightbulb.outro, ClawdSpriteName.lightbulb[41...44])
        XCTAssertEqual(lightbulb.offset, ClawdOffset(y: 1))
        XCTAssertNil(lightbulb.sign, "the bulb says plan")
        XCTAssertEqual(lightbulb.pace, .replaying(after: 120, hold: 11, replay: 26...29, every: 8))

        for look in ClawdLook.allCases {
            let clip = clips.clip(for: look)
            XCTAssertEqual(clip.working, look.isWorking, "\(look)")
            XCTAssertEqual(clip.sign != nil, look == .permission || look == .question, "\(look)")
            XCTAssertFalse(clip.loop.isEmpty)
            if look.isWorking { XCTAssertEqual(clip.pace, .resting(after: 20, hold: 3), "\(look)") }
        }
        XCTAssertEqual(pointing.pace, .waiting(after: 8, every: 2.6, slowAfter: 120, slowEvery: 8))
        XCTAssertEqual(waving.pace, pointing.pace)
    }

    func testTheOneOffsPlayTheirFrames() {
        func frames(_ shot: ClawdShot) -> [ClawdFrame] { shot.steps.map(\.frame) }
        func seconds(_ shot: ClawdShot) -> TimeInterval { Double(shot.steps.map(\.ticks).reduce(0, +)) / 12 }

        XCTAssertEqual(frames(clips.start), ClawdSpriteName.jumpingHappy[3...20])
        XCTAssertEqual(seconds(clips.start), 1.5)
        XCTAssertEqual(frames(clips.failed), ClawdSpriteName.facepalm[2...33])
        XCTAssertEqual(clips.failed.steps.filter { $0.sign == .failed }.map(\.frame.index), Array(5...31))
        let dizzy = ClawdSpriteName.dizzy
        XCTAssertEqual(frames(clips.limitHit), dizzy[6...21] + dizzy[6...17] + dizzy[30...37] + [.standing])

        XCTAssertEqual(frames(clips.visits[.swaying]!), ClawdSpriteName.swaying[4...48])
        XCTAssertEqual(frames(clips.visits[.turning]!), ClawdSpriteName.turning[2...28] + [.standing])
        XCTAssertEqual(frames(clips.visits[.glancing]!), ClawdSpriteName.lookingAroundEyesOnly[0...41])
        let doze = clips.visits[.dozing]!
        XCTAssertEqual(frames(doze), ClawdSpriteName.meditating[6...23] + ClawdSpriteName.meditating[45...54] + [.standing])
        XCTAssertEqual(doze.steps.first { $0.frame.index == 23 }?.ticks, 24, "23 held two seconds")
        XCTAssertTrue(doze.steps.allSatisfy { $0.sign == .asleep })
        XCTAssertFalse(ClawdVisit.idle.contains(.dozing))
        XCTAssertTrue(ClawdVisit.idle.allSatisfy { visit in clips.visits[visit]!.steps.allSatisfy { $0.frame.sprite != .waving } },
                      "a raised claw means a question")

        XCTAssertEqual(frames(clips.greet), ClawdSpriteName.waving[3...15] + ClawdSpriteName.waving[6] + [.standing])
        XCTAssertEqual(clips.gaze, [6, 9, 12, 15, 18, 21, 27, 30])

        XCTAssertEqual(frames(clips.cards[.done]!), ClawdSpriteName.excited[2...21] + [.standing])
        XCTAssertEqual(frames(clips.cards[.longDone]!),
                       ClawdSpriteName.dancingHappy[4...38] + ClawdSpriteName.dancingHappy[7] + [.standing])
        let reset = clips.cards[.reset]!
        XCTAssertEqual(frames(reset), ClawdSpriteName.spark[4...21] + ClawdSpriteName.spark[57...68])
        XCTAssertEqual(seconds(reset), 2.5)
        // The spark's offset eases in and out, so it starts and ends where standing stands.
        XCTAssertEqual(reset.steps.first?.offset, .zero)
        XCTAssertEqual(reset.steps.last?.offset, .zero)
        XCTAssertEqual(reset.steps[10].offset, ClawdOffset(x: -2))
        XCTAssertEqual(clips.pointsAtCard, ClawdFrame(.pointing, 19))
    }

    func testOnlySpritesTheClipsWereWrittenForFitThem() throws {
        // A sheet with every frame, of the counts the clips were written against.
        func sheet(_ counts: [ClawdSpriteName: Int]) -> ClawdSheet {
            let color = ClawdSprite.Color(red: 0, green: 0, blue: 0, alpha: 255)
            let sprites = counts.map { name, count in
                (name.rawValue, ClawdSprite(name: name.rawValue, category: "", width: 1, height: 1, fps: 12, palette: [color],
                                            frames: (0..<count).map { [$0 % 2 == 0 ? 0 : ClawdSprite.clear] },
                                            anchor: (0, 1), standMatch: true))
            }
            return ClawdSheet(version: "", sprites: Dictionary(uniqueKeysWithValues: sprites))
        }
        XCTAssertTrue(clips.fit(sheet(Self.realFrameCounts)))
        var redrawn = Self.realFrameCounts
        redrawn[.laptop] = 44
        XCTAssertFalse(clips.fit(sheet(redrawn)), "a sprite redrawn with a frame more")
        var missing = Self.realFrameCounts
        missing[.thinking] = nil
        XCTAssertFalse(clips.fit(sheet(missing)))
        XCTAssertFalse(clips.fit(ClawdFixture.sheet()))
    }

    func testSignsComeOneAtATimeInTheirOrder() {
        XCTAssertEqual(ClawdSign.allCases.sorted(), [.permission, .question, .failed, .limited, .asleep])
        XCTAssertEqual(ClawdSign.allCases.map(\.rawValue).joined(), "!?×⧗z")
        XCTAssertLessThan(ClawdSign.failed, ClawdSign.asleep)
    }
}

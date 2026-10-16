import XCTest
@testable import AgentHUDDesktop

final class ClawdSheetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try ClawdFixture.folder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The table

    func testEveryWayTheGameWritesASpriteReads() throws {
        let sheet = try XCTUnwrap(ClawdSpriteTable.sheet(in: Array(ClawdFixture.file.utf8)))
        XCTAssertEqual(sheet.version, "9.9.9")
        let sprites = sheet.sprites
        XCTAssertEqual(Set(sprites.keys), ["Walking", "Thinking", "Waving"], "a sprite with a bad pixel is left out")

        let walking = try XCTUnwrap(sprites["Walking"])
        XCTAssertEqual(walking.category, "Core")
        XCTAssertEqual(walking.width, 4)
        XCTAssertEqual(walking.height, 3)
        XCTAssertEqual(walking.fps, 12)
        XCTAssertEqual(walking.palette, [ClawdSprite.Color(red: 0xd9, green: 0x77, blue: 0x57, alpha: 255),
                                         ClawdSprite.Color(red: 0x14, green: 0x14, blue: 0x13, alpha: 255)])
        XCTAssertEqual(walking.frames, ClawdFixture.walking)
        XCTAssertEqual(walking.anchor.x, 2, "the middle of its box")
        XCTAssertEqual(walking.anchor.y, 3, "under its box")
        XCTAssertTrue(walking.standMatch)

        // Split by "(": an empty piece is a frame like the one before.
        let thinking = try XCTUnwrap(sprites["Thinking"])
        let clear = ClawdSprite.clear
        XCTAssertEqual(thinking.frames, [[0, 1, 2, 2, clear, 1], [0, 1, 2, 2, clear, 1],
                                         [0, 2, clear, 2, clear, 1], [0, 2, clear, 2, clear, 1]])
        XCTAssertTrue(thinking.standMatch, "!0 is true")

        // A quoted name, keys in any order, an unknown value passed over, an empty box for the whole sprite.
        let waving = try XCTUnwrap(sprites["Waving"])
        XCTAssertEqual(waving.palette, [ClawdSprite.Color(red: 255, green: 255, blue: 255, alpha: 255)])
        XCTAssertEqual(waving.frames, [[0, clear], [0, 0], [0, 0], [0, 0]])
        XCTAssertEqual(waving.anchor.x, 1)
        XCTAssertEqual(waving.anchor.y, 1)
        XCTAssertEqual(waving.fps, 6)
        XCTAssertFalse(waving.standMatch)
    }

    func testAFrameMovesOnlyThePixelsItsDeltaNames() throws {
        // Pixel numbers run past one base-36 digit; a value of "." clears a pixel.
        let frames = try XCTUnwrap(ClawdSpriteTable.frames(base: String(repeating: "0", count: 40), deltas: ["10.,z1", "", "131"],
                                                           pixels: 40, colors: 2))
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[1][36], ClawdSprite.clear, "10 is pixel 36")
        XCTAssertEqual(frames[1][35], 1)
        XCTAssertEqual(frames[2], frames[1])
        XCTAssertEqual(frames[3][39], 1, "13 is pixel 39")
        XCTAssertEqual(frames[3].filter { $0 == 0 }.count, 37)

        XCTAssertNil(ClawdSpriteTable.frames(base: "00", deltas: ["21"], pixels: 2, colors: 2), "no pixel 2")
        XCTAssertNil(ClawdSpriteTable.frames(base: "00", deltas: ["12"], pixels: 2, colors: 2), "no colour 2")
        XCTAssertNil(ClawdSpriteTable.frames(base: "0", deltas: [], pixels: 2, colors: 2), "too few pixels")
        XCTAssertNil(ClawdSpriteTable.frames(base: "0!", deltas: [], pixels: 2, colors: 2))
        XCTAssertEqual(ClawdSpriteTable.frames(base: "00", deltas: ["1"], pixels: 2, colors: 2)?.count, 2,
                       "a change too short to name a pixel changes nothing, as in the game")
    }

    func testColoursReadInEveryLength() {
        XCTAssertEqual(ClawdSpriteTable.color(from: "#d97757"), ClawdSprite.Color(red: 217, green: 119, blue: 87, alpha: 255))
        XCTAssertEqual(ClawdSpriteTable.color(from: "#FA0"), ClawdSprite.Color(red: 255, green: 170, blue: 0, alpha: 255))
        XCTAssertEqual(ClawdSpriteTable.color(from: "#11223380"), ClawdSprite.Color(red: 17, green: 34, blue: 51, alpha: 128))
        XCTAssertNil(ClawdSpriteTable.color(from: "d97757"))
        XCTAssertNil(ClawdSpriteTable.color(from: "#d9775"))
        XCTAssertNil(ClawdSpriteTable.color(from: "#gg0000"))
    }

    func testWhatIsNotASheetHasNoSprites() {
        let files = ["", "[]", "{}", "::{{", #"{"sprites":{}}"#, #"{"claude":"1","sprites":[]}"#,
                     ##"{"claude":"1","sprites":{"Walking":{"cat":"Core","w":4,"h":3,"palette":["#000"],"base":"0"##]
        for file in files {
            XCTAssertNil(ClawdSpriteTable.sheet(in: Array(file.utf8)), file)
        }
        let empty = ClawdSpriteTable.sheet(in: Array(#"{"claude":"1","sprites":{"Walking":{"w":4},"x":1}}"#.utf8))
        XCTAssertEqual(empty?.sprites.isEmpty, true, "sprites that do not read are passed over")
    }

    // MARK: The sheet

    func testFramesThatLookTheSameAreOneFrame() throws {
        let sheet = ClawdFixture.sheet()
        XCTAssertEqual(sheet.canonical(ClawdFrame(.walking, 1)), ClawdFrame(.walking, 0), "an empty delta repeats a frame")
        XCTAssertEqual(sheet.canonical(ClawdFrame(.walking, 2)), ClawdFrame(.walking, 2))
        XCTAssertEqual(sheet.canonical(ClawdFrame(.thinking, 3)), ClawdFrame(.thinking, 2))
        XCTAssertEqual(sheet.canonical(ClawdFrame(.waving, 3)), ClawdFrame(.waving, 1))
        XCTAssertTrue(sheet.has(ClawdFrame(.walking, 3)))
        XCTAssertFalse(sheet.has(ClawdFrame(.walking, 4)))
        XCTAssertFalse(sheet.has(ClawdFrame(.laptop, 0)))

        // Frames of two sprites match where their pixels land from the anchor, whatever their sizes.
        let small = ClawdSprite(name: "Walking", category: "", width: 2, height: 1, fps: 12,
                                palette: [ClawdSprite.Color(red: 1, green: 2, blue: 3, alpha: 255)], frames: [[0, 0]],
                                anchor: (1, 1), standMatch: true)
        let big = ClawdSprite(name: "Excited", category: "", width: 4, height: 3, fps: 12,
                              palette: [ClawdSprite.Color(red: 9, green: 9, blue: 9, alpha: 255), ClawdSprite.Color(red: 1, green: 2, blue: 3, alpha: 255)],
                              frames: [[255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 1, 255], [255, 255, 255, 255, 255, 255, 255, 255, 1, 1, 255, 255]],
                              anchor: (2, 3), standMatch: true)
        let both = ClawdSheet(version: "", sprites: ["Walking": small, "Excited": big])
        XCTAssertEqual(both.canonical(ClawdFrame(.excited, 0)), .standing)
        XCTAssertEqual(both.canonical(ClawdFrame(.excited, 1)), ClawdFrame(.excited, 1), "a pixel to the left")
    }

    // MARK: The source

    func testTheSheetIsDecodedFromItsFile() async throws {
        let file = folder.appendingPathComponent("clawd-sprites.json")
        try Data(ClawdFixture.file.utf8).write(to: file)
        let sheet = try XCTUnwrap(ClawdSheetSource.sheet(at: file))
        XCTAssertEqual(Set(sheet.sprites.keys), ["Walking", "Thinking", "Waving"])
        XCTAssertEqual(sheet[.walking]?.frames, ClawdFixture.walking)

        // A made-up sheet has none of the frames the clips play, so it is not used and nothing fails.
        let fitting = await ClawdSheetSource(file: file).sheet()
        XCTAssertNil(fitting)
        let missing = await ClawdSheetSource(file: folder.appendingPathComponent("missing.json")).sheet()
        XCTAssertNil(missing)
        let none = await ClawdSheetSource(file: nil).sheet()
        XCTAssertNil(none)
    }
}

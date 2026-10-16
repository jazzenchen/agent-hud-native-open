import XCTest
@testable import AgentHUDDesktop

/// The sheet Agent HUD bundles, `clawd-sprites.json`: the Claude app's own sprites, which `scripts/clawd-sprites.py`
/// writes. A new copy of them has to pass this before it ships.
@MainActor
final class ClawdBundledSheetTests: XCTestCase {
    func testTheBundledSheetHasEveryClipsFrame() async throws {
        let file = try XCTUnwrap(ClawdSheetSource.bundled, "clawd-sprites.json is not among the resources")
        let started = Date()
        let sheet = try XCTUnwrap(ClawdSheetSource.sheet(at: file))
        let seconds = Date().timeIntervalSince(started)
        XCTAssertFalse(sheet.version.isEmpty)
        // Only the sprites the clips play, each as many frames long as when the clips were written.
        let counts = ClawdClips.standard.frameCounts
        XCTAssertEqual(sheet.sprites.count, 18)
        XCTAssertEqual(Set(sheet.sprites.keys), Set(counts.keys.map(\.rawValue)))
        for (name, count) in counts {
            let sprite = try XCTUnwrap(sheet[name], name.rawValue)
            XCTAssertEqual(sprite.frameCount, count, name.rawValue)
            XCTAssertEqual(sprite.frameCount, ClawdClipsTests.realFrameCounts[name], name.rawValue)
            XCTAssertEqual(sprite.frames.allSatisfy { $0.count == sprite.width * sprite.height }, true, name.rawValue)
        }
        XCTAssertTrue(ClawdClips.standard.fit(sheet))
        print("Decoded \(sheet.sprites.count) sprites of Claude \(sheet.version) in \(Int(seconds * 1000)) ms")

        // The app decodes it once, for every mark that asks.
        let first = await ClawdSheetSource.shared.sheet()
        let again = await ClawdSheetSource.shared.sheet()
        XCTAssertNotNil(first)
        XCTAssertTrue(first === again)

        // Standing is the game's standing pose: the body on its feet, centred on its anchor.
        let standing = try XCTUnwrap(sheet[.walking])
        XCTAssertEqual(standing.anchor.x, 12)
        let baker = ClawdBaker(sheet: sheet)
        let image = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2))
        XCTAssertEqual(image.width, 64)
    }
}

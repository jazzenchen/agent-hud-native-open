import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class ClawdBakerTests: XCTestCase {
    private let sheet = ClawdFixture.sheet()
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An image's pixels as the bitmap keeps them, one 32-bit word each, rows from the top.
    private func pixels(_ image: CGImage) throws -> [UInt32] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let row = image.bytesPerRow / 4
        return data.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            var all: [UInt32] = []
            for y in 0..<image.height {
                for x in 0..<image.width { all.append(words[y * row + x]) }
            }
            return all
        }
    }

    /// An sRGB colour as a premultiplied, opaque pixel in the bitmap's byte order.
    private func word(_ color: ClawdSprite.Color) -> UInt32 {
        UInt32(color.alpha) << 24 | UInt32(color.red) << 16 | UInt32(color.green) << 8 | UInt32(color.blue)
    }

    func testTheScaleFollowsTheMarksSizeInDevicePixels() {
        // Device pixels to two sprite pixels, for marks of 12 to 36 points.
        let atOne = [Int](repeating: 1, count: 14) + [Int](repeating: 2, count: 11)
        let atTwo = [1] + [Int](repeating: 2, count: 7) + [Int](repeating: 3, count: 7) + [Int](repeating: 4, count: 6)
            + [Int](repeating: 5, count: 4)
        for (at, side) in (12...36).enumerated() {
            XCTAssertEqual(ClawdBaker.grain(side: CGFloat(side), scale: 1), atOne[at], "\(side) pt at 1x")
            XCTAssertEqual(ClawdBaker.grain(side: CGFloat(side), scale: 2), atTwo[at], "\(side) pt at 2x")
            XCTAssertEqual(ClawdBaker.drawsSprites(side: CGFloat(side), scale: 1), atOne[at] >= 2)
            XCTAssertEqual(ClawdBaker.drawsSprites(side: CGFloat(side), scale: 2), atTwo[at] >= 2)
        }
        // 20 pt on Retina: a body of 24 sprite pixels is 36 device pixels, nine tenths of the mark.
        XCTAssertEqual(ClawdBaker.grain(side: 20, scale: 2), 3)
        XCTAssertFalse(ClawdBaker.drawsSprites(side: 25, scale: 1))
        XCTAssertFalse(ClawdBaker.drawsSprites(side: 12, scale: 2))
        let baker = ClawdBaker(sheet: sheet)
        XCTAssertNil(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 1), "too small: the drawn Clawd")
        XCTAssertNotNil(baker.image(ClawdPicture(frame: .standing), side: 26, scale: 1))
    }

    func testEverySpritePixelIsABlockOfWholeDevicePixels() throws {
        let baker = ClawdBaker(sheet: sheet)
        let walking = try XCTUnwrap(sheet[.walking])
        for (side, scale) in [(13, 2), (17, 2), (20, 2), (24, 2), (28, 2), (33, 2), (36, 2), (26, 1), (36, 1)] as [(CGFloat, CGFloat)] {
            let place = ClawdBaker.placement(side: side, scale: scale)
            let n = place.grain
            for index in 0..<walking.frameCount {
                let image = try XCTUnwrap(baker.image(ClawdPicture(frame: ClawdFrame(.walking, index)), side: side, scale: scale, space: srgb))
                XCTAssertEqual(image.width, place.extent)
                XCTAssertEqual(CGFloat(image.width), BotActor.extent(side: side, scale: scale, outline: 0) * scale, accuracy: 1e-9,
                               "the layer's own size")
                // Each device pixel shows the sprite pixel it lies in, counted from the feet: n/2 device pixels to one.
                let frame = walking.frames[index]
                var expected = [UInt32](repeating: 0, count: place.extent * place.extent)
                for y in 0..<place.extent {
                    for x in 0..<place.extent {
                        let u = Int((2 * CGFloat(x - place.foot.x + 1) / CGFloat(n)).rounded(.up)) - 1 + walking.anchor.x
                        let v = Int((2 * CGFloat(y - place.foot.y + 1) / CGFloat(n)).rounded(.up)) - 1 + walking.anchor.y
                        guard (0..<walking.width).contains(u), (0..<walking.height).contains(v) else { continue }
                        let pixel = frame[v * walking.width + u]
                        if pixel != ClawdSprite.clear { expected[y * place.extent + x] = word(walking.palette[Int(pixel)]) }
                    }
                }
                XCTAssertEqual(try pixels(image), expected, "\(side) pt at \(scale)x, frame \(index)")
            }
        }
    }

    func testTheBodyIsCentredWithItsFeetAnEighthAboveTheMarksBottom() throws {
        let baker = ClawdBaker(sheet: sheet)
        for (side, scale) in [(20, 2), (30, 2), (36, 1)] as [(CGFloat, CGFloat)] {
            let place = ClawdBaker.placement(side: side, scale: scale)
            let image = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: side, scale: scale, space: srgb))
            let words = try pixels(image), extent = place.extent
            let drawn = words.indices.filter { words[$0] != 0 }
            let rows = drawn.map { $0 / extent }, columns = drawn.map { $0 % extent }
            let mark = CGFloat(extent) / 2 + side * scale / 2
            // The feet's last row ends an eighth of the mark above its bottom edge.
            XCTAssertEqual(CGFloat(try XCTUnwrap(rows.max()) + 1), (mark - side * scale / 8).rounded(), accuracy: 0.5)
            // The standing frame is four sprite pixels wide about its anchor: as much to the left of the middle as to its right.
            let left = try XCTUnwrap(columns.min()), right = try XCTUnwrap(columns.max()) + 1
            XCTAssertEqual(place.foot.x - left, right - place.foot.x, "\(side) pt at \(scale)x")
            XCTAssertEqual(right - left, 2 * place.grain)
        }
        let twenty = ClawdBaker.placement(side: 20, scale: 2)
        XCTAssertEqual(twenty.extent, 64)
        XCTAssertEqual(twenty.foot.x, 32)
        XCTAssertEqual(twenty.foot.y, 47, "32 + 20 - 5")
    }

    func testAnOffsetMovesTheWholePictureByWholePixels() throws {
        let baker = ClawdBaker(sheet: sheet)
        let still = try pixels(try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2, space: srgb)))
        let moved = try pixels(try XCTUnwrap(baker.image(ClawdPicture(frame: .standing, offset: ClawdOffset(x: -1, y: 1)),
                                                         side: 20, scale: 2, space: srgb)))
        // At 1.5 device pixels to a sprite pixel, one sprite pixel is two device pixels, rounded away from nothing.
        let extent = 64, shift = (x: -2, y: 2)
        for y in 0..<extent {
            for x in 0..<extent {
                let from = (x - shift.x, y - shift.y)
                let expected = (0..<extent).contains(from.0) && (0..<extent).contains(from.1) ? still[from.1 * extent + from.0] : 0
                XCTAssertEqual(moved[y * extent + x], expected, "\(x), \(y)")
            }
        }
    }

    func testAMirroredFrameTurnsAboutItsFeet() throws {
        let baker = ClawdBaker(sheet: sheet)
        let picture = ClawdPicture(frame: ClawdFrame(.walking, 2))
        var mirrored = picture
        mirrored.mirrored = true
        let place = ClawdBaker.placement(side: 30, scale: 2)
        let plain = try pixels(try XCTUnwrap(baker.image(picture, side: 30, scale: 2, space: srgb)))
        let turned = try pixels(try XCTUnwrap(baker.image(mirrored, side: 30, scale: 2, space: srgb)))
        XCTAssertNotEqual(plain, turned)
        for y in 0..<place.extent {
            for x in 0..<place.extent where (0..<place.extent).contains(2 * place.foot.x - 1 - x) {
                XCTAssertEqual(turned[y * place.extent + x], plain[y * place.extent + 2 * place.foot.x - 1 - x])
            }
        }
    }

    func testTheMiniStandsBesideTheBodyAtHalfItsSize() throws {
        let baker = ClawdBaker(sheet: sheet)
        let place = ClawdBaker.placement(side: 30, scale: 2)
        XCTAssertEqual(place.grain, 4)
        let alone = try pixels(try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 30, scale: 2, space: srgb)))
        let both = try pixels(try XCTUnwrap(baker.image(ClawdPicture(frame: .standing, mini: 13), side: 30, scale: 2, space: srgb)))
        let walking = try XCTUnwrap(sheet[.walking])
        // One device pixel to a sprite pixel, its middle 13 sprite pixels of the body to the right, on the same feet line.
        let middle = place.foot.x + 26
        for y in 0..<place.extent {
            for x in 0..<place.extent {
                let u = x - middle + walking.anchor.x, v = y - place.foot.y + walking.anchor.y
                var expected = alone[y * place.extent + x]
                if (0..<walking.width).contains(u), (0..<walking.height).contains(v) {
                    let pixel = walking.frames[0][v * walking.width + u]
                    if pixel != ClawdSprite.clear { expected = word(walking.palette[Int(pixel)]) }
                }
                XCTAssertEqual(both[y * place.extent + x], expected, "\(x), \(y)")
            }
        }
    }

    func testASignIsPaintedIntoItsBoxOverTheHead() throws {
        var boxes: [(ClawdSign, ClawdBaker.SignBox)] = []
        let baker = ClawdBaker(sheet: sheet) { sign, box, context in
            boxes.append((sign, box))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box.rect)
        }
        let image = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing, sign: .question), side: 20, scale: 2,
                                              ground: .light, space: srgb))
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes.first?.0, .question)
        // At 20 pt on Retina a cell is 2 pixels, so the box is 10 by 14: its left edge 0.14 of the mark right of the body's
        // middle, its bottom 0.04 of the mark over the body's top, 16 sprite pixels above the feet.
        let box = try XCTUnwrap(boxes.first?.1)
        XCTAssertEqual(box.cell, 2)
        XCTAssertEqual(box.ground, .light)
        XCTAssertEqual(box.rect, CGRect(x: 32 + 6, y: 64 - (47 - 24 - 2), width: 10, height: 14))
        let words = try pixels(image)
        XCTAssertEqual(words[(64 - Int(box.rect.maxY)) * 64 + Int(box.rect.minX)], 0xFFFF_FFFF, "painted into the frame itself")

        // At 36 pt a cell is 3 pixels, and a box pushed too high stays inside the room over the mark.
        XCTAssertEqual(baker.signBox(for: ClawdPicture(frame: .standing), place: ClawdBaker.placement(side: 36, scale: 2),
                                     foot: (58, 85), ground: .dark).rect.size, CGSize(width: 15, height: 21))
        var high = ClawdClips.standard
        high.signShifts[.walking] = ClawdOffset(y: -60)
        let lifted = ClawdBaker(sheet: sheet, clips: high).signBox(for: ClawdPicture(frame: .standing), place: ClawdBaker.placement(side: 20, scale: 2),
                                                                  foot: (32, 47), ground: .dark)
        XCTAssertEqual(64 - lifted.rect.maxY, (32 - 20 - 0.28 * 40).rounded(.up), "no higher than 0.28 of the mark above it")
        // With nothing to paint signs, the frame is drawn without one.
        XCTAssertNotNil(ClawdBaker(sheet: sheet).image(ClawdPicture(frame: .standing, sign: .question), side: 20, scale: 2))
        XCTAssertEqual(boxes.count, 1)
    }

    func testFramesAreDrawnInTheDisplaysColours() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let baker = ClawdBaker(sheet: sheet)
        let image = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2, space: p3))
        XCTAssertTrue(image.colorSpace.map { CFEqual($0, p3) } ?? false)
        // The body's orange, as Core Graphics itself puts it into a Display P3 bitmap.
        let probe = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: p3,
                                            bitmapInfo: BotCanvas.layout.rawValue))
        probe.setFillColor(CGColor(srgbRed: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1))
        probe.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let orange = try XCTUnwrap(probe.data).load(as: UInt32.self)
        XCTAssertNotEqual(orange, word(ClawdSprite.Color(red: 0xd9, green: 0x77, blue: 0x57, alpha: 255)))
        let words = try pixels(image)
        XCTAssertTrue(words.contains(orange))
        XCTAssertFalse(words.contains(word(ClawdSprite.Color(red: 0xd9, green: 0x77, blue: 0x57, alpha: 255))))
    }

    func testAnOutlinedFrameGrowsAndCarriesAHairline() throws {
        let baker = ClawdBaker(sheet: sheet)
        let plain = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2, space: srgb))
        let outlined = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2, outline: 1, space: srgb))
        XCTAssertEqual(outlined.width, plain.width + 2)
        XCTAssertEqual(CGFloat(outlined.width), BotActor.extent(side: 20, scale: 2, outline: 1) * 2, accuracy: 1e-9)
        let place = ClawdBaker.placement(side: 20, scale: 2, outline: 1)
        let words = try pixels(outlined)
        // Just under the feet, where nothing is drawn, the hairline darkens the wallpaper.
        let under = words[place.foot.y * place.extent + place.foot.x - 2]
        XCTAssertGreaterThan(under >> 24, 0)
        XCTAssertLessThan(under >> 24, 255)
    }

    func testFramesAreKeptUntilSixtyFourAreAndTheOldestGoes() throws {
        let baker = ClawdBaker(sheet: sheet)
        let first = try XCTUnwrap(baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2))
        XCTAssertTrue(first === baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2), "drawn once")
        XCTAssertEqual(baker.count, 1)
        let second = try XCTUnwrap(baker.image(ClawdPicture(frame: ClawdFrame(.walking, 2)), side: 20, scale: 2))
        for x in 0..<70 {
            _ = baker.image(ClawdPicture(frame: .standing, offset: ClawdOffset(x: x + 1)), side: 20, scale: 2)
            // The standing frame is shown all along; the other is not.
            _ = baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2)
            XCTAssertLessThanOrEqual(baker.count, ClawdBaker.most)
        }
        XCTAssertEqual(baker.count, ClawdBaker.most)
        XCTAssertTrue(first === baker.image(ClawdPicture(frame: .standing), side: 20, scale: 2), "kept while it shows")
        XCTAssertFalse(second === baker.image(ClawdPicture(frame: ClawdFrame(.walking, 2)), side: 20, scale: 2), "let go")
        baker.purge()
        XCTAssertEqual(baker.count, 0)
        XCTAssertNil(baker.image(ClawdPicture(frame: ClawdFrame(.laptop, 0)), side: 20, scale: 2), "a sprite the sheet does not have")
    }
}

import AppKit
import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class BotSignTests: XCTestCase {
    /// One pixel's bytes, blue, green, red and alpha, counted from the bitmap's top left.
    private typealias Pixel = (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)

    /// A clear sRGB bitmap laid out as a bot's frames are, `side` pixels square.
    private func canvas(_ side: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: BotCanvas.layout.rawValue))
    }

    private func pixel(_ context: CGContext, _ x: Int, _ y: Int) -> Pixel {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self), at = y * context.bytesPerRow + x * 4
        return (bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3])
    }

    /// The cells of `sign`'s grid that carry ink, as (column, row) from its top left.
    private func inked(_ sign: BotSign) -> Set<[Int]> {
        var cells = Set<[Int]>()
        for (row, line) in sign.rows.enumerated() {
            for (column, mark) in line.enumerated() where mark == "#" { cells.insert([column, row]) }
        }
        return cells
    }

    func testEveryGlyphIsFiveByWithSevenRowsOfInk() {
        for sign in BotSign.allCases {
            XCTAssertEqual(sign.rows.count, 7, "\(sign)")
            XCTAssertTrue(sign.rows.allSatisfy { $0.count == 5 && $0.allSatisfy { $0 == "#" || $0 == "." } }, "\(sign)")
            XCTAssertFalse(inked(sign).isEmpty)
        }
        XCTAssertEqual(BotSign.ellipsis.rows.last, "#.#.#")
        XCTAssertEqual(BotSign.z.rows, [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"])
    }

    /// Every cell of every sign, at the cell sizes of a small, a usual and a large mark, is whole pixels of white
    /// inside one pixel of the island's dark at 60% on a dark ground, and of that dark alone on a light one.
    func testEveryGlyphIsDrawnCellForCellInWholePixels() throws {
        let dark: Pixel = (0x0f, 0x0d, 0x0d, 0xff)
        for cell in [1, 2, 3] {
            for sign in BotSign.allCases where sign != .ellipsis {
                let ink = inked(sign), origin = (x: 4, y: 3)
                for ground in [HUDLook.Appearance.dark, .light] {
                    let context = try canvas(40)
                    // Given with y running up, as the bitmap's own space is: the box's top is its maxY.
                    let box = CGRect(x: origin.x, y: 40 - origin.y - 7 * cell, width: 5 * cell, height: 7 * cell)
                    BotSigns.paint(sign, in: box, on: context, ground: ground)
                    for y in 0..<40 {
                        for x in 0..<40 {
                            let column = x - origin.x, row = y - origin.y
                            let cellAt = [column >= 0 ? column / cell : -1, row >= 0 ? row / cell : -1]
                            let isInk = column >= 0 && row >= 0 && column < 5 * cell && row < 7 * cell && ink.contains(cellAt)
                            // An edge pixel is one outside the ink with ink among its eight neighbours.
                            let isEdge = !isInk && (-1...1).contains { dy in (-1...1).contains { dx in
                                let c = x + dx - origin.x, r = y + dy - origin.y
                                return c >= 0 && r >= 0 && c < 5 * cell && r < 7 * cell && ink.contains([c / cell, r / cell])
                            } }
                            let found = pixel(context, x, y)
                            let place = "\(sign) cell \(cell) \(ground) at \(x),\(y)"
                            switch (ground, isInk, isEdge) {
                            case (.dark, true, _):
                                XCTAssertTrue(found == (255, 255, 255, 255), place)
                            case (.dark, false, true):
                                XCTAssertEqual(found.alpha, 153, place)
                                XCTAssertLessThan(found.red, 12, place)
                            case (.light, true, _):
                                XCTAssertTrue(found == dark, place)
                            default:
                                XCTAssertEqual(found.alpha, 0, place)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The dots of `…` light one at a time: the lit one at full ink, the others faint all through, edge and all.
    func testTheThinkingDotsLightOneAtATime() throws {
        let cell = 2
        for lit in 0...2 {
            let context = try canvas(30)
            BotSigns.paint(.ellipsis, lit: lit, in: CGRect(x: 4, y: 30 - 3 - 14, width: 10, height: 14), on: context,
                           ground: .dark)
            // The bottom row, two pixels tall, three rows of cells down from the top at y = 3.
            let y = 3 + 6 * cell
            for dot in 0...2 {
                let middle = pixel(context, 4 + 2 * dot * cell, y)
                if dot == lit {
                    XCTAssertTrue(middle == (255, 255, 255, 255), "dot \(dot) lit \(lit)")
                } else {
                    XCTAssertEqual(Double(middle.alpha), 0.35 * 255, accuracy: 1.5, "dot \(dot) faint")
                    XCTAssertEqual(Double(middle.red), 0.35 * 255, accuracy: 1.5)
                }
            }
            XCTAssertEqual(pixel(context, 4, y - 6 * cell).alpha, 0, "nothing above the dots")
        }
    }

    func testACellIsATwentiethOfTheMarkUpToWhatFitsInThreeTenths() {
        // Device pixels to the mark's side: 12, 20 and 36 points on Retina, and 20 points at 1x.
        XCTAssertEqual(BotSigns.cell(side: 24), 1)
        XCTAssertEqual(BotSigns.cell(side: 40), 2, "10 by 14 pixels at 20 points on Retina")
        XCTAssertEqual(BotSigns.cell(side: 72), 3, "15 by 21 at 36 points")
        XCTAssertEqual(BotSigns.cell(side: 20), 1)
        XCTAssertEqual(BotSigns.cell(side: 8), 1, "never less than a pixel")
        for side in stride(from: 12, through: 120, by: 1) {
            XCTAssertLessThanOrEqual(CGFloat(7 * BotSigns.cell(side: CGFloat(side))), 0.3 * CGFloat(side) + 3.5, "\(side)")
        }
    }

    func testOneSignAtATimeInItsOrder() {
        let order: [BotSign] = [.exclamation, .question, .lines, .cross, .hourglass, .ellipsis, .z]
        XCTAssertEqual(BotSign.allCases, order)
        for (index, high) in order.enumerated() {
            for low in order[index...] {
                XCTAssertEqual(BotSign.shown(high, low), high)
                XCTAssertEqual(BotSign.shown(low, high), high)
            }
            XCTAssertEqual(BotSign.shown(high, nil), high)
            XCTAssertEqual(BotSign.shown(nil, high), high)
        }
        XCTAssertNil(BotSign.shown(nil, nil))
        XCTAssertEqual(BotSign(.failed), .cross)
        XCTAssertEqual(BotSign(.limited), .hourglass)
        // A still logo carries only what a request or a badge says, never a moving bot's dots.
        XCTAssertEqual(BotState(look: .question, badge: .failed).stillSign, .question)
        XCTAssertEqual(BotState(look: .idle, badge: .limited).stillSign, .hourglass)
        XCTAssertNil(BotState(look: .thinking).stillSign)
    }

    /// The sign stands on whole pixels, 0.14 of the side right of the body's centre and 0.04 clear of its top, and
    /// never higher than 0.28 of the side above the mark, which is inside the frame's room for overflow.
    func testASignStandsOverTheHeadOnWholePixels() throws {
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor, ground: .dark))
            for (side, outline) in [(CGFloat(40), 1), (24, 1), (72, 0), (37, 0), (20, 1)] {
                let box = BotSigns.box(for: form, side: side, outline: outline)
                let inner = (side * 1.6).rounded(.up), unit = inner / 1.6, extent = inner + CGFloat(2 * outline)
                func share(_ pixels: CGFloat) -> CGFloat { (pixels - CGFloat(outline)) / unit - BotRenderer.margin }
                // Half a pixel either way, as a place is rounded to the nearest.
                let place = "\(vendor) at \(side)", half = (0.5 + 1e-6) / unit
                for edge in [box.minX, box.minY, box.width, box.height] { XCTAssertEqual(edge, edge.rounded(), place) }
                XCTAssertEqual(box.width, CGFloat(5 * BotSigns.cell(side: side)), place)
                XCTAssertEqual(box.height, CGFloat(7 * BotSigns.cell(side: side)), place)
                // With room for its one-pixel edge inside the frame.
                XCTAssertGreaterThanOrEqual(box.minX, 1, place)
                XCTAssertGreaterThanOrEqual(box.minY, 1, place)
                XCTAssertLessThanOrEqual(box.maxX + 1, extent, place)
                XCTAssertGreaterThanOrEqual(share(box.minY), -0.28 - half, place)
                let wanted = form.spec.signAt ?? CGPoint(x: form.spec.center.x + 0.14, y: form.top - 0.04)
                XCTAssertEqual(share(box.minX), wanted.x, accuracy: half, place)
                if share(box.minY) > -0.28 + 1 / unit {
                    XCTAssertEqual(share(box.maxY), wanted.y, accuracy: half, place)
                } else {
                    XCTAssertGreaterThanOrEqual(share(box.maxY), wanted.y - half, "\(place): moved down, never up")
                }
            }
        }
    }

    /// A bot's sign is drawn into its own frame, in white over a dark body too, where a body-coloured sign would vanish.
    func testASignIsPartOfTheBotsOwnFrameAndNeverInItsColour() throws {
        let form = try XCTUnwrap(BotForm.form(for: "GLM", ground: .dark))
        var motion = BotMotion(seed: 3)
        motion.fit(form.spec)
        motion.set(BotState(look: .permission), at: 0)
        var now: TimeInterval = 0
        while now < 1 { motion.step(to: now); now += BotPace.lively }
        XCTAssertEqual(motion.sign, .exclamation)
        let context = try XCTUnwrap(BotRenderer.bare(form, motion: motion, side: 40, outline: 0, space: nil))
        let box = BotSigns.box(for: form, side: 40, outline: 0), cell = BotSigns.cell(side: 40)
        // The bar of `!` runs down its middle column; the dot is its last row.
        for row in [0, 4, 6] {
            let found = pixel(context, Int(box.minX) + 2 * cell, Int(box.minY) + row * cell)
            XCTAssertTrue(found == (255, 255, 255, 255), "row \(row)")
        }
        XCTAssertLessThan(pixel(context, Int(box.minX) + 2 * cell, Int(box.minY) + 5 * cell).red, 20, "the gap above the dot")

        // Once the request is answered and the bot is idle again, the frame has no sign left in it.
        motion.set(BotState(look: .idle), at: now)
        while now < 3 { motion.step(to: now); now += BotPace.lively }
        XCTAssertNil(motion.sign)
        let plain = try XCTUnwrap(BotRenderer.bare(form, motion: motion, side: 40, outline: 0, space: nil))
        XCTAssertEqual(pixel(plain, Int(box.minX) + 2 * cell, Int(box.minY)).alpha, 0)
    }

    /// With bots off or motion reduced, the plain logo wears the same sign as a picture of its own, the size its cells
    /// would be, just past the logo's top right.
    func testAStillLogoWearsItsSignAsAPictureOfItsOwn() throws {
        let form = try XCTUnwrap(BotForm.form(for: "Cursor", ground: .dark))
        let still = try XCTUnwrap(BotSigns.still(.cross, form: form, side: 20, scale: 2, ground: .dark))
        XCTAssertEqual(still.image.width, 5 * 2 + 2)
        XCTAssertEqual(still.image.height, 7 * 2 + 2)
        XCTAssertEqual(still.frame.width, 6, accuracy: 0.001)
        XCTAssertEqual(still.frame.height, 8, accuracy: 0.001)
        XCTAssertEqual(still.frame.minX, ((0.64 * 40).rounded() - 1) / 2, accuracy: 0.001, "right of the middle")
        // Cursor's logo reaches its top edge, so the sign stands as high as it may, over the logo's corner.
        XCTAssertEqual(still.frame.minY, ((-0.28 * 40).rounded(.up) - 1) / 2, accuracy: 0.001)
        XCTAssertNotNil(BotSigns.still(.question, form: nil, side: 17, scale: 1, ground: .light), "a mark with no bot")
    }
}

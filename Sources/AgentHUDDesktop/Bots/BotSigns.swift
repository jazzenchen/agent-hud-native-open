import CoreGraphics
import Foundation

/// A sign over a bot's head: what its mark waits for or has just been through. Each is a 5×7 grid drawn in whole device
/// pixels, so it reads the same at every size and on every bot. Cases run from the sign that wins to the one that
/// gives way: a mark shows one sign at a time.
enum BotSign: Int, Hashable, Sendable, CaseIterable {
    /// `!`: a tool waits for approval.
    case exclamation
    /// `?`: a question waits for an answer.
    case question
    /// `≡`: a plan waits for approval.
    case lines
    /// `×`: the last turn failed.
    case cross
    /// `⧗`: a usage limit holds the agent up.
    case hourglass
    /// `…`: the model is thinking. One dot is lit at a time.
    case ellipsis
    /// `z`: the agents have been idle for an hour.
    case z

    init(_ badge: BotBadge) {
        switch badge {
        case .failed: self = .cross
        case .limited: self = .hourglass
        }
    }

    /// Whichever of two signs wins.
    static func shown(_ one: BotSign?, _ other: BotSign?) -> BotSign? {
        guard let one, let other else { return one ?? other }
        return one.rawValue <= other.rawValue ? one : other
    }

    /// The grid, top row first, with `#` for ink.
    var rows: [String] {
        switch self {
        case .exclamation: ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."]
        case .question: [".###.", "#...#", "....#", "..##.", "..#..", ".....", "..#.."]
        case .lines: [".....", "#####", ".....", "#####", ".....", "#####", "....."]
        case .cross: [".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."]
        case .hourglass: [".....", "#####", ".#.#.", "..#..", ".###.", "#####", "....."]
        case .ellipsis: [".....", ".....", ".....", ".....", ".....", ".....", "#.#.#"]
        case .z: [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"]
        }
    }

    /// The grid's rows as bits, the leftmost cell highest, read once.
    fileprivate static let bits: [[UInt8]] = allCases.map { sign in
        sign.rows.map { row in row.reduce(UInt8(0)) { $0 << 1 | ($1 == "#" ? 1 : 0) } }
    }
}

/// Draws the signs, for the procedural bots and for anything else that bakes a frame, such as a sprite.
enum BotSigns {
    /// Columns and rows of a sign's grid.
    static let columns = 5, rows = 7
    /// How strongly the dots of `…` that are not lit are drawn.
    static let faint: CGFloat = 0.35

    /// The island's own dark: the edge round a sign on a dark ground, and its ink on a light one.
    private static let dark = CGColor(srgbRed: 0x0d / 255, green: 0x0d / 255, blue: 0x0f / 255, alpha: 1)

    /// Side of one cell of a sign, in device pixels, for a mark `side` device pixels wide: a twentieth of the side, and
    /// no more than fits the seven rows in 0.3 of it. That is 2 pixels at 20 points on a Retina display.
    static func cell(side: CGFloat) -> Int {
        max(1, min(Int((side / 20).rounded()), Int((0.3 * side / CGFloat(rows)).rounded())))
    }

    /// Draws `sign` with its ink in `rect`, given in the context's current space and snapped to whole pixels of the
    /// bitmap it lands in; a cell is a fifth of the rect's width. On a dark `ground` the ink is white inside a pixel of
    /// the island's dark at 60%, which keeps it apart from a body of any colour; on a light ground it is that dark
    /// alone. `lit` picks the dot of `…` drawn at full ink, 0 to 2 from the left.
    static func paint(_ sign: BotSign, lit: Int = 0, in rect: CGRect, on context: CGContext, ground: HUDLook.Appearance) {
        // The bitmap's own space, a unit to a pixel and running up from its bottom left; its device space, which
        // `convertToDeviceSpace` gives, runs down instead, so the transform is taken from the context's own.
        let pixels = rect.applying(context.ctm).standardized
        let cell = max(1, (pixels.width / CGFloat(columns)).rounded())
        let left = pixels.minX.rounded(), top = pixels.maxY.rounded()
        let lit = max(0, min(2, lit)), bits = BotSign.bits[sign.rawValue]
        var ink: [CGRect] = [], dim: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns where bits[row] >> (columns - 1 - column) & 1 == 1 {
                let box = CGRect(x: left + CGFloat(column) * cell, y: top - CGFloat(row + 1) * cell, width: cell, height: cell)
                if sign == .ellipsis, column != 2 * lit { dim.append(box) } else { ink.append(box) }
            }
        }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.setShouldAntialias(false)
        context.setBlendMode(.normal)
        switch ground {
        case .dark:
            // The edge first, as one path so that cells side by side share theirs; a faint dot's is a ring, so its ink
            // is faint all through.
            for box in dim { context.addRect(box.insetBy(dx: -1, dy: -1)); context.addRect(box) }
            context.setFillColor(dark.copy(alpha: 0.6 * faint) ?? dark)
            context.fillPath(using: .evenOdd)
            for box in ink { context.addRect(box.insetBy(dx: -1, dy: -1)) }
            context.setFillColor(dark.copy(alpha: 0.6) ?? dark)
            context.fillPath()
            fill(ink, CGColor(gray: 1, alpha: 1), on: context)
            fill(dim, CGColor(gray: 1, alpha: faint), on: context)
        case .light:
            fill(ink, dark, on: context)
            fill(dim, dark.copy(alpha: faint) ?? dark, on: context)
        }
        context.restoreGState()
    }

    private static func fill(_ boxes: [CGRect], _ color: CGColor, on context: CGContext) {
        guard !boxes.isEmpty else { return }
        context.addRects(boxes)
        context.setFillColor(color)
        context.fillPath()
    }

    // MARK: Placement

    /// Where a bot's sign stands in its frame, in device pixels from the frame's top left with y running down, for a mark
    /// `side` device pixels wide and `outline` pixels of hairline: its left edge 0.14 of the side right of the body's
    /// centre, its foot 0.04 of the side clear of the top of the body, and its top no higher than 0.28 of the side above
    /// the mark, low enough to overlap the head when the room above it is short. A bot may name its own place
    /// (`BotSpec.signAt`).
    @MainActor
    static func box(for form: BotForm, side: CGFloat, outline: Int) -> CGRect {
        let margin = BotRenderer.margin
        let inner = (side * (1 + 2 * margin)).rounded(.up), unit = inner / (1 + 2 * margin)
        let extent = inner + CGFloat(outline * 2)
        func pixels(_ share: CGFloat) -> CGFloat { CGFloat(outline) + (share + margin) * unit }
        let foot = form.spec.signAt ?? CGPoint(x: form.spec.center.x + 0.14, y: form.top - 0.04)
        return placed(left: pixels(foot.x), bottom: pixels(foot.y), ceiling: pixels(-0.28), cell: cell(side: side),
                      right: extent)
    }

    /// The ink box at `left` and `bottom`, on whole pixels, moved down to `ceiling` if it would rise above it and in from
    /// `right` with room for its edge.
    private static func placed(left: CGFloat, bottom: CGFloat, ceiling: CGFloat, cell: Int, right: CGFloat) -> CGRect {
        let width = CGFloat(columns * cell), height = CGFloat(rows * cell)
        let bottom = max(bottom.rounded(), ceiling.rounded(.up) + height)
        let left = max(1, min(left.rounded(), right - 1 - width))
        return CGRect(x: left, y: bottom - height, width: width, height: height)
    }

    /// A sign alone, for a mark shown as its plain logo with bots off or motion reduced, to lay over the logo as a layer
    /// that never moves. It stands as it would over the bot, measured from the logo's own top. `frame` is where, in
    /// points from the mark's top left with y running down; it reaches beyond the mark.
    @MainActor
    static func still(_ sign: BotSign, form: BotForm?, side: CGFloat, scale: CGFloat,
                      ground: HUDLook.Appearance) -> (image: CGImage, frame: CGRect)? {
        let scale = max(1, scale), pixels = side * scale, cell = cell(side: pixels)
        let foot = form.map { $0.spec.signAt ?? CGPoint(x: $0.spec.center.x + 0.14, y: $0.logoTop - 0.04) }
            ?? CGPoint(x: 0.64, y: 0.06)
        let box = placed(left: foot.x * pixels, bottom: foot.y * pixels, ceiling: -0.28 * pixels, cell: cell,
                         right: 1.3 * pixels)
        let width = Int(box.width) + 2, height = Int(box.height) + 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: BotCanvas.layout.rawValue)
        else { return nil }
        paint(sign, in: CGRect(x: 1, y: 1, width: box.width, height: box.height), on: context, ground: ground)
        guard let image = context.makeImage() else { return nil }
        let points = CGRect(x: box.minX - 1, y: box.minY - 1, width: CGFloat(width), height: CGFloat(height))
        return (image, CGRect(x: points.minX / scale, y: points.minY / scale, width: points.width / scale,
                              height: points.height / scale))
    }
}

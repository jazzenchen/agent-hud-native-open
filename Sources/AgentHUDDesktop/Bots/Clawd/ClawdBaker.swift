import CoreGraphics
import Foundation

/// Draws Clawd's frames into a display's own pixels, each the first time it shows, and keeps them while they may
/// show again.
///
/// A sprite pixel becomes a block of whole device pixels, n/2 on a side, picked nearest-neighbour: at an even n every
/// block is the same size, and at an odd one each column and row of the sprite is always 1 or always 2 pixels, by
/// where it is from the feet. The layer that shows a frame must never scale it again.
///
/// Each frame fills the same square as one of `BotRenderer`'s, the mark with `BotRenderer.margin` of room on every
/// edge, so it can take that frame's place in a `BotActor`'s layer.
@MainActor
final class ClawdBaker {
    /// Where a sign goes in a frame: a box five cells wide and seven tall, in the frame's own pixels with y running up.
    struct SignBox: Equatable {
        var rect: CGRect
        /// Device pixels to a cell of the sign's 5×7 grid.
        var cell: Int
        var ground: HUDLook.Appearance
    }

    /// Draws `sign` into `box` of a frame. The signs are drawn by whoever draws every bot's signs.
    typealias SignPainter = @MainActor (_ sign: ClawdSign, _ box: SignBox, _ context: CGContext) -> Void

    /// Where everything sits in a frame for a mark of one size on one display.
    struct Placement: Equatable {
        /// The frame's side in device pixels.
        var extent: Int
        /// Device pixels to two sprite pixels.
        var grain: Int
        /// The mark's side in device pixels.
        var side: CGFloat
        /// Pixels of hairline round Clawd, inside the frame's edge.
        var outline: Int
        /// Where the feet stand, in device pixels from the frame's top left: the middle of the body, and the line
        /// the feet stand on.
        var foot: (x: Int, y: Int)

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.extent == rhs.extent && lhs.grain == rhs.grain && lhs.side == rhs.side && lhs.outline == rhs.outline
                && lhs.foot == rhs.foot
        }
    }

    /// More frames than this for one Clawd and the one shown longest ago is let go.
    static let most = 64

    let sheet: ClawdSheet
    let clips: ClawdClips
    private let paintSign: SignPainter?

    private struct Key: Hashable {
        var picture: ClawdPicture
        var side: CGFloat
        var outline: Int
        var space: CGColorSpace
        var ground: HUDLook.Appearance
    }

    private var kept: [Key: (image: CGImage, used: Int)] = [:]
    private var uses = 0
    /// Each palette in each display's colours, as the bitmap keeps a pixel.
    private var inks: [[ClawdSprite.Color]: (space: CGColorSpace, pixels: [UInt32])] = [:]

    init(sheet: ClawdSheet, clips: ClawdClips = .standard, paintSign: SignPainter? = nil) {
        self.sheet = sheet
        self.clips = clips
        self.paintSign = paintSign
    }

    /// Device pixels to two sprite pixels, for a mark `side` points wide on a display of `scale` pixels a point. Clawd's
    /// body, 24 sprite pixels wide, comes to about nine tenths of the mark at most.
    static func grain(side: CGFloat, scale: CGFloat) -> Int {
        // The tiny nudge keeps a size that lands on a whole number on it, whatever the rounding on the way.
        max(1, Int((1.8 * side * scale / 24 + 0.05 + 1e-9).rounded(.down)))
    }

    /// Whether a mark this size can show the sprites: at least one device pixel to a sprite pixel. Smaller, Clawd is
    /// drawn the way `BotRenderer` draws it.
    static func drawsSprites(side: CGFloat, scale: CGFloat) -> Bool { grain(side: side, scale: scale) >= 2 }

    static func placement(side: CGFloat, scale: CGFloat, outline: Int = 0) -> Placement {
        let grain = grain(side: side, scale: scale), side = side * scale
        let extent = Int((side * (1 + 2 * BotRenderer.margin)).rounded(.up)) + outline * 2
        // The body is centred on the mark, and the feet stand an eighth of the mark above its bottom edge.
        let middle = CGFloat(extent) / 2
        return Placement(extent: extent, grain: grain, side: side, outline: outline,
                         foot: (extent / 2, Int((middle + side / 2 - 0.125 * side).rounded())))
    }

    var count: Int { kept.count }

    /// Lets every kept frame go: the mark has rested as its logo long enough not to need them soon.
    func purge() {
        kept = [:]
        inks = [:]
    }

    /// The frame `picture` for a mark `side` points wide on a display of `scale` pixels a point.
    ///
    /// - outline: pixels of hairline round Clawd, as `BotRenderer.image` lays it.
    /// - ground: the HUD's ground, which the sign and the hairline are drawn for.
    /// - space: the colours of the display the frame is shown on; sRGB when it is not known.
    func image(_ picture: ClawdPicture, side: CGFloat, scale: CGFloat, outline: Int = 0,
               ground: HUDLook.Appearance = .dark, space: CGColorSpace? = nil) -> CGImage? {
        let place = Self.placement(side: side, scale: scale, outline: outline)
        guard place.grain >= 2, sheet.has(picture.frame) else { return nil }
        // The colours a frame is drawn in, as `BotCanvas` picks them.
        let shownIn = space.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let key = Key(picture: picture, side: place.side, outline: outline, space: shownIn, ground: ground)
        uses += 1
        if let hit = kept[key] {
            kept[key]?.used = uses
            return hit.image
        }
        guard let context = BotCanvas.clear(place.extent, space: shownIn),
              draw(picture, place: place, ground: ground, on: context), let image = context.makeImage()
        else { return nil }
        if kept.count >= Self.most, let oldest = kept.min(by: { $0.value.used < $1.value.used })?.key { kept[oldest] = nil }
        kept[key] = (image, uses)
        return image
    }

    private func draw(_ picture: ClawdPicture, place: Placement, ground: HUDLook.Appearance, on context: CGContext) -> Bool {
        guard let sprite = sheet[picture.frame.sprite] else { return false }
        let n = place.grain, flip = picture.mirrored ? -1 : 1
        let shift = (x: Self.pixels(picture.offset.x * flip, n), y: Self.pixels(picture.offset.y, n))
        let foot = (x: place.foot.x + shift.x, y: place.foot.y + shift.y)
        fill(sprite, frame: picture.frame.index, at: foot, scale: (n, 2), mirrored: picture.mirrored, on: context)
        if let shift = picture.mini, let standing = sheet[ClawdFrame.standing.sprite] {
            // Half the size, standing on the same line beside the body.
            let middle = place.foot.x + Self.pixels(shift, n)
            fill(standing, frame: ClawdFrame.standing.index, at: (middle, place.foot.y), scale: (n, 4), mirrored: false, on: context)
        }
        if let sign = picture.sign, let paintSign {
            context.saveGState()
            paintSign(sign, signBox(for: picture, place: place, foot: foot, ground: ground), context)
            context.restoreGState()
        }
        if place.outline > 0 { BotHairline.lay(on: context, reach: place.outline, ground: ground) }
        return true
    }

    /// Where the sign goes: its left edge a little right of the body's middle, its bottom just over the body's top,
    /// and never higher than the room above the mark allows.
    func signBox(for picture: ClawdPicture, place: Placement, foot: (x: Int, y: Int), ground: HUDLook.Appearance) -> SignBox {
        let side = place.side, n = place.grain
        let cell = max(1, min(Int((side / 20).rounded()), Int((0.3 * side / 7).rounded())))
        let shift = clips.signShifts[picture.frame.sprite] ?? .zero
        let left = foot.x + Self.pixels(shift.x, n) + Int((0.14 * side).rounded())
        // The body is 16 sprite pixels from its feet to its top.
        let bodyTop = foot.y + Self.pixels(shift.y, n) - 8 * n
        var top = bodyTop - Int((0.04 * side).rounded()) - 7 * cell
        top = max(top, Int((CGFloat(place.extent) / 2 - side / 2 - 0.28 * side).rounded(.up)))
        // The frame's pixels are counted from its top; a context counts from its bottom.
        let rect = CGRect(x: left, y: place.extent - top - 7 * cell, width: 5 * cell, height: 7 * cell)
        return SignBox(rect: rect, cell: cell, ground: ground)
    }

    /// Device pixels for `sprite` sprite pixels at `grain`: whole pixels, rounded half away from nothing.
    static func pixels(_ sprite: Int, _ grain: Int) -> Int { Int((Double(sprite * grain) / 2).rounded()) }

    /// Fills each drawn pixel of one frame as a block of device pixels, `scale` device pixels to `scale.per` sprite
    /// pixels. Blocks are measured from the anchor, so a sprite pixel's block is the same whatever frame it is in.
    private func fill(_ sprite: ClawdSprite, frame: Int, at foot: (x: Int, y: Int), scale: (pixels: Int, per: Int),
                      mirrored: Bool, on context: CGContext) {
        guard let data = context.data, let pixels = ink(sprite.palette, in: context.colorSpace) else { return }
        let width = context.width, height = context.height, row = context.bytesPerRow / 4
        let bitmap = data.bindMemory(to: UInt32.self, capacity: row * height)
        func span(_ at: Int) -> (Int, Int) { (Self.floor(at * scale.pixels, scale.per), Self.floor((at + 1) * scale.pixels, scale.per)) }
        let indexes = sprite.frames[frame]
        for y in 0..<sprite.height {
            let (top, bottom) = span(y - sprite.anchor.y)
            let firstRow = max(0, foot.y + top), endRow = min(height, foot.y + bottom)
            // A row off the frame, or one a smaller scale draws no pixel of.
            guard firstRow < endRow else { continue }
            for x in 0..<sprite.width {
                let index = indexes[y * sprite.width + x]
                guard index != ClawdSprite.clear else { continue }
                let (left, right) = span(mirrored ? sprite.anchor.x - x - 1 : x - sprite.anchor.x)
                let firstColumn = max(0, foot.x + left), endColumn = min(width, foot.x + right)
                guard firstColumn < endColumn else { continue }
                let pixel = pixels[Int(index)]
                for line in firstRow..<endRow {
                    let start = line * row
                    for column in firstColumn..<endColumn { bitmap[start + column] = pixel }
                }
            }
        }
    }

    private static func floor(_ value: Int, _ by: Int) -> Int { value >= 0 ? value / by : -((-value + by - 1) / by) }

    /// A palette's colours as `space` keeps them, worked out by Core Graphics itself: each colour filled into a
    /// pixel of a bitmap laid out as the frames are.
    private func ink(_ palette: [ClawdSprite.Color], in space: CGColorSpace?) -> [UInt32]? {
        guard let space else { return nil }
        if let known = inks[palette], CFEqual(known.space, space) { return known.pixels }
        guard let probe = CGContext(data: nil, width: palette.count, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: palette.count * 4, space: space, bitmapInfo: BotCanvas.layout.rawValue),
              let data = probe.data
        else { return nil }
        for (at, color) in palette.enumerated() {
            probe.setFillColor(CGColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                                       blue: CGFloat(color.blue) / 255, alpha: CGFloat(color.alpha) / 255))
            probe.fill(CGRect(x: at, y: 0, width: 1, height: 1))
        }
        let pixels = Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt32.self, capacity: palette.count), count: palette.count))
        inks[palette] = (space, pixels)
        return pixels
    }
}

import AgentHUDCore
import CoreGraphics
import Foundation

/// What an agent's mark turns into while its agent is in flight: a small body in the mark's own outline and
/// colour, with two eyes and nothing else.
///
/// Positions on the mark are shares of its side, measured from the top left with y running down, the way
/// artwork is read. Sizes on the body — eyes, a hat, a moustache — are in body radii from the body's centre,
/// so a bot can be resized by its radius alone.
struct BotSpec: Sendable {
    enum Shape: Sendable {
        /// The mark's own outline, averaged over `smooth` degrees and pulled in to `keep` of its relief.
        case outline(keep: CGFloat, smooth: Int)
        case circle
        case polygon(sides: Int, rotation: CGFloat, round: CGFloat)
        case rect(width: CGFloat, height: CGFloat, round: CGFloat)
        case slant(width: CGFloat, height: CGFloat, skew: CGFloat, round: CGFloat)
        /// A wide head with two ears.
        case cat
        /// A dome of hair that falls straight and flicks out at the ends.
        case bob
    }

    enum Paint: Sendable {
        /// The mark's own colours, spread into a soft field so the body carries each where the mark had it.
        case artwork
        case solid(RGBA)
        /// Gradient ends and centres are shares of the body's own box, so the paint travels with the body.
        case linear(from: CGPoint, to: CGPoint, stops: [RGBA])
        case radial(center: CGPoint, inner: CGFloat, outer: CGFloat, stops: [RGBA])
    }

    struct Eye: Sendable {
        var height: CGFloat = 0.62
        var width: CGFloat = 0.25
        /// 1 is a capsule, 0 a block.
        var round: CGFloat = 1
        /// How far each eye sits from the middle of the face, as an angle round the body in radians.
        var spread: CGFloat = 0.34
        /// Set for a flat face, in place of `spread`: how far each eye sits from the middle, in body radii. The eyes
        /// keep their shape and slide across together when the bot looks around, as on a box rather than a ball.
        var across: CGFloat? = nil
    }

    /// Arms and legs the motion moves, in the body's own paint: boxes in body radii from the body's centre, as the
    /// limbs of pixel art are, and moved in whole steps of `pixel`. A raised arm climbs a step; raised further it
    /// takes another step up and out, one arm's width. A lifted leg rises half a step into the body. A body with limbs
    /// is moved as pixel art throughout: the whole of it in steps of half a `pixel`, its eyes too.
    struct Limbs: Sendable {
        /// The arm on the left, then the one on the right.
        var arms: [CGRect]
        /// Left to right; the first and third step together, then the second and fourth.
        var legs: [CGRect]
        var pixel: CGFloat
    }

    /// A second colour laid inside the body: the face panel of a head.
    struct Patch: Sendable {
        var box: CGRect
        var round: CGFloat
        var paint: Paint
    }

    /// A ring round the body: its far side hidden by the body, its near side drawn across it.
    struct Ring: Sendable {
        var radiusX: CGFloat
        var radiusY: CGFloat
        var drop: CGFloat
        var tilt: CGFloat
        var width: CGFloat
    }

    /// A fin that stands behind the body, in body radii from the body's centre: a rounded paddle from a root inside the
    /// body out past its outline (`BotFins.path`).
    struct Fin: Sendable {
        /// Where it grows from, inside the body.
        var root: CGPoint
        /// Which way it points, in degrees clockwise from the right, with y running down.
        var angle: CGFloat
        /// From the root to the far edge of its tip.
        var length: CGFloat
        /// The radius of its round root, and of its round tip.
        var base: CGFloat
        var tip: CGFloat
        /// How far its tip leans to the left of where it points, as a fin on a fish's back sweeps toward its tail.
        var sweep: CGFloat = 0
        /// A hand, which the motion raises about its root (`BotFlap`): −1 on the left, 1 on the right. 0 keeps still.
        var hand: CGFloat = 0
    }

    enum Decor: Sendable {
        /// Rounded pieces in one colour laid on the body and kept to its outline, later ones over earlier:
        /// a fringe, a scarf. `round` 1 is a full capsule or ball, 0 a block.
        case soft([CGRect], RGBA, round: CGFloat)
        /// Thin lines with round ends that stand behind the body, so only what clears its outline shows:
        /// a pair of antennae.
        case feelers([[CGPoint]], RGBA, width: CGFloat)
        /// Filled fins that stand behind the body, so only what clears its outline shows: a fish's hands and the fin on
        /// its back.
        case fins([Fin], RGBA)
        /// Filled blocks, such as hair or a hat. `followsFace` rides with the eyes when the bot looks around.
        case blocks([CGRect], RGBA, followsFace: Bool)
        /// Pieces taken out of the silhouette.
        case cut([CGRect])
        case notch([CGPoint])
        /// A dark line drawn on the body.
        case line([CGPoint], width: CGFloat)

        /// The piece rides with the eyes when the bot looks around.
        var followsFace: Bool {
            if case .blocks(_, _, let follows) = self { follows } else { false }
        }
    }

    var radius: CGFloat = 0.36
    var center = CGPoint(x: 0.5, y: 0.5)
    /// How far the face may travel across the body, as a share of a full turn of the head.
    var reach: CGFloat = 1
    var shape: Shape = .circle
    var paint: Paint = .artwork
    /// Where the face rests, in body radii from the centre.
    var face = CGPoint.zero
    var eye = Eye()
    /// Nil draws the eyes in the island's own dark, which reads as cut out on any body.
    var eyeColor: RGBA? = nil
    var pupil: RGBA? = nil
    var patch: Patch? = nil
    var ring: Ring? = nil
    var stroke: RGBA? = nil
    var decor: [Decor] = []
    var limbs: Limbs? = nil
    /// Degrees per second the body turns under a still face while its agent works.
    var spin: CGFloat = 0
    /// A piece of the artwork that stays as drawn and hops above the body.
    var keeps: CGRect? = nil
    /// The mark already is a character and keeps its artwork; only the eyes inside these boxes come alive.
    var ownEyes: [CGRect]? = nil
    /// Parts of the artwork left out of the body's colours: the mark's own eyes, which would smudge the body.
    var unpainted: [CGRect] = []
    /// How far below its logo the finished bot sits, as a share of the mark's side. The move happens with
    /// the morph, for a body that would otherwise stand higher or lower than its neighbours.
    var settle: CGFloat = 0
    /// Its eyes are big enough to cross out after a failed turn, at least 1.4 by 3.4 points at 20; smaller ones squint.
    var crossesEyes = false
    /// Where its sign stands, the bottom left of the sign's ink as shares of the side, for a body the usual place over
    /// its head does not suit (`BotSigns.box`).
    var signAt: CGPoint? = nil

    /// A mark with no entry stays a logo: it moves as a whole and has no face.
    ///
    /// The table draws every bot for a dark ground, the island's black or a wallpaper, in light ink. On a light ground,
    /// a light HUD's surface, a bot in light ink would vanish, so it wears dark ink there instead (`lightGroundInk`), and
    /// a body that is now dark has its eyes cut in the ground's own colour (`lightCut`): a single-colour mark's, whose
    /// body is its own stencil, and every bot whose paint turned dark.
    static func spec(for vendor: String, ground: HUDLook.Appearance) -> BotSpec? {
        let key = AgentArtwork.markKey(vendor).replacingOccurrences(of: "-dark", with: "")
        guard let spec = table[key] else { return nil }
        guard ground == .light else { return spec }
        let swaps = lightGroundInk[key] ?? []
        var light = swaps.reduce(spec) { $0.repainted($1.dark, $1.light) }
        if light.eyeColor == nil, AgentArtwork.isTemplate(vendor) || !swaps.isEmpty { light.eyeColor = lightCut }
        return light
    }

    /// The light ground's own colour, the light HUD's surface: eyes drawn in it read as cut out of a dark body.
    static let lightCut = RGBA(hex: 0xf5f5f7)

    /// The light ink each bot in it is painted with, and the dark ink it wears on a light ground instead: as its mark's
    /// own artwork for a light background draws it where there is one, the light HUD's ink where there is none.
    private static let lightGroundInk: [String: [(dark: RGBA, light: RGBA)]] = [
        // Black with white eyes, as its wordmark is on a light ground.
        "Grok Bot": [(RGBA(hex: 0xffffff), RGBA(hex: 0x000000))],
        "Pi": [(RGBA(hex: 0xffffff), ink)],
        "Hermes": [(RGBA(hex: 0xf8f8f9), ink)],
        // The light variant's dark frame, with its cap and moustache in the variant's pale grey.
        "OpenCode": [(RGBA(hex: 0xf1ecec), RGBA(hex: 0x211e1e)), (grey, RGBA(hex: 0xcfcecd))],
        // A black ball, its own artwork's for a light background, in the same green neck warmer.
        "Qoder": [(RGBA(hex: 0xf8f8f8), RGBA(hex: 0x161616))],
        "CodeBuddy": [(RGBA(hex: 0xffffff), ink)],
        "WorkBuddy": [(RGBA(hex: 0xeafaf6), RGBA(hex: 0x1b2622))],
    ]

    /// The light HUD's ink.
    private static let ink = RGBA(hex: 0x1d1d1f)

    /// The same bot with every paint and piece in `old` painted `new` instead. Its eyes keep their colour.
    private func repainted(_ old: RGBA, _ new: RGBA) -> BotSpec {
        func swap(_ value: RGBA) -> RGBA { value == old ? new : value }
        func swap(_ paint: Paint) -> Paint {
            switch paint {
            case .artwork: .artwork
            case .solid(let value): .solid(swap(value))
            case .linear(let from, let to, let stops): .linear(from: from, to: to, stops: stops.map(swap))
            case .radial(let center, let inner, let outer, let stops):
                .radial(center: center, inner: inner, outer: outer, stops: stops.map(swap))
            }
        }
        var spec = self
        spec.paint = swap(paint)
        spec.patch = patch.map { Patch(box: $0.box, round: $0.round, paint: swap($0.paint)) }
        spec.stroke = stroke.map(swap)
        spec.decor = decor.map { item in
            switch item {
            case .soft(let rects, let value, let round): .soft(rects, swap(value), round: round)
            case .feelers(let lines, let value, let width): .feelers(lines, swap(value), width: width)
            case .fins(let fins, let value): .fins(fins, swap(value))
            case .blocks(let rects, let value, let follows): .blocks(rects, swap(value), followsFace: follows)
            case .cut, .notch, .line: item
            }
        }
        return spec
    }

    private static let grey = RGBA(hex: 0x4b4646)
    private static let hair = RGBA(hex: 0xb7b6c2)

    static let table: [String: BotSpec] = [
        // Clawd, Claude Code's own creature, as its pixel art draws it: a wide block of the logo's orange, an arm out of
        // each side, four short legs and two upright bars for eyes. A pixel of the art is half a body radius; the
        // body is six pixels by four.
        "Claude": BotSpec(radius: 0.22, center: CGPoint(x: 0.5, y: 0.445), reach: 0.7,
                          shape: .rect(width: 0.66, height: 0.44, round: 0.008), face: CGPoint(x: 0, y: -0.25),
                          eye: Eye(height: 0.64, width: 0.32, round: 0, across: 0.875),
                          limbs: Limbs(arms: [rect(-2, 0, -1.5, 0.5), rect(1.5, 0, 2, 0.5)],
                                       legs: [rect(-1.25, 1, -1, 1.5), rect(-0.75, 1, -0.5, 1.5),
                                              rect(0.5, 1, 0.75, 1.5), rect(1, 1, 1.25, 1.5)],
                                       pixel: 0.5)),
        // The knot's own six lobes, deepened: a body that is nearly round turns without anyone seeing it turn.
        "ChatGPT": BotSpec(radius: 0.37, shape: .outline(keep: 1.1, smooth: 5), spin: 7, crossesEyes: true),
        // The arch gives a dome that runs from 0.05 to 0.77 down the mark, where a ball beside it runs from
        // 0.14 to 0.86. The finished bot settles by that difference, so its top and bottom line up with theirs.
        "Antigravity": BotSpec(reach: 0.75, shape: .outline(keep: 0.5, smooth: 16), face: CGPoint(x: 0, y: -0.2),
                               settle: 0.093),
        // A big fat fish: the whale's blue ball with its pale belly, a small triangular fin low on each side for hands and
        // a fin on its back, swept back a little left of the top, clear of the sign over its head. The copy for sub-agents
        // stands in front of the hand on its side.
        "DeepSeek": BotSpec(face: CGPoint(x: 0, y: -0.14),
                            decor: [.fins([Fin(root: CGPoint(x: -0.5, y: 0.38), angle: 142, length: 0.7, base: 0.27,
                                               tip: 0.06, hand: -1),
                                           Fin(root: CGPoint(x: 0.5, y: 0.38), angle: 38, length: 0.7, base: 0.27,
                                               tip: 0.06, hand: 1),
                                           Fin(root: CGPoint(x: -0.12, y: -0.7), angle: -100, length: 0.64, base: 0.34, tip: 0.15,
                                               sweep: 0.22)],
                                          RGBA(hex: 0x3f5ae6)),
                                    .soft([rect(-0.86, 0.34, 0.86, 1.9)], RGBA(hex: 0xc9d4ff), round: 1)],
                            crossesEyes: true),
        "Grok": BotSpec(radius: 0.33, reach: 0.55, face: CGPoint(x: 0, y: -0.3),
                        ring: Ring(radiusX: 1.5, radiusY: 0.32, drop: 0.3, tilt: -20, width: 0.14)),
        // Grok's bot is one flat colour with eyes in the other: black on a light ground, white on a dark one.
        // Bots are drawn on the island's black and over wallpapers in light ink, so this one is the white ball
        // with dark eyes its own wordmark shows on black.
        "Grok Bot": BotSpec(radius: 0.37, paint: .solid(RGBA(hex: 0xffffff)), eye: Eye(height: 0.78, width: 0.3),
                            crossesEyes: true),
        // The logo's cut, as a notch in the edge it was taken from.
        "Cursor": BotSpec(radius: 0.41, reach: 0.7, shape: .polygon(sides: 6, rotation: -90, round: 0.07),
                          face: CGPoint(x: -0.12, y: 0.16),
                          decor: [.notch([CGPoint(x: 0.32, y: -0.954), CGPoint(x: 0.75, y: -0.704),
                                          CGPoint(x: 0.266, y: -0.361)])]),
        // A cap of hair with uneven locks and a moustache, both in the logo's grey.
        "OpenCode": BotSpec(reach: 0.5, shape: .rect(width: 0.66, height: 0.66, round: 0.04),
                            paint: .solid(RGBA(hex: 0xf1ecec)), face: CGPoint(x: 0, y: -0.02),
                            eye: Eye(height: 0.4, width: 0.24, round: 0.12),
                            decor: [.blocks([rect(-1.0, -1.06, 1.0, -0.56), rect(-1.0, -0.56, -0.62, -0.36),
                                             rect(-0.24, -0.56, 0.16, -0.42), rect(0.58, -0.56, 1.0, -0.3)],
                                            grey, followsFace: false),
                                    .blocks([rect(-0.6, 0.36, 0.6, 0.6)], grey, followsFace: true)]),
        // Its sign stands a little left of the usual place, clear of the dot it keeps, which grows while a request waits.
        "Kimi": BotSpec(radius: 0.32, center: CGPoint(x: 0.41, y: 0.59), shape: .outline(keep: 0.3, smooth: 22),
                        keeps: CGRect(x: 0.78, y: 0.02, width: 0.215, height: 0.215), signAt: CGPoint(x: 0.44, y: 0.22)),
        "GLM": BotSpec(shape: .rect(width: 0.74, height: 0.74, round: 0.16), paint: .solid(RGBA(hex: 0x28282b)),
                       eyeColor: RGBA(hex: 0xffffff), stroke: RGBA(hex: 0xffffff)),
        // The letter itself, in one piece: a wide bar that holds the face, standing on two legs.
        "Pi": BotSpec(center: CGPoint(x: 0.5, y: 0.31), reach: 0.3, shape: .rect(width: 0.9, height: 0.29, round: 0.02),
                      eye: Eye(height: 0.3, width: 0.3, round: 0),
                      decor: [.blocks([rect(-0.8, 0.36, -0.3, 1.5), rect(0.3, 0.36, 0.8, 1.5)], RGBA(hex: 0xffffff), followsFace: false)]),
        // A plain white ball with a fringe: three locks over the forehead, kept to the ball's outline.
        "Hermes": BotSpec(radius: 0.35, reach: 0.5, paint: .solid(RGBA(hex: 0xf8f8f9)), face: CGPoint(x: 0, y: 0.24),
                          eye: Eye(height: 0.72, width: 0.3, spread: 0.44),
                          decor: [.soft([rect(-1.1, -1.25, -0.2, -0.22), rect(-0.44, -1.3, 0.44, -0.3), rect(0.2, -1.25, 1.1, -0.22)],
                                        hair, round: 1)],
                          crossesEyes: true),
        "ZCode": BotSpec(reach: 0.8, shape: .slant(width: 0.66, height: 0.64, skew: 0.2, round: 0.05)),
        "Qwen": BotSpec(radius: 0.37, shape: .outline(keep: 0.55, smooth: 7), spin: 7, crossesEyes: true),
        // A plain red ball with two round black eyes and the logo's pair of small antennae. The logo's cyan
        // pupils are left out: on a face this small they stare.
        "OpenClaw": BotSpec(center: CGPoint(x: 0.5, y: 0.54), reach: 0.7,
                            paint: .linear(from: CGPoint(x: 0.2, y: 0.1), to: CGPoint(x: 0.85, y: 0.95),
                                           stops: [RGBA(hex: 0xee4747), RGBA(hex: 0xc22e2e)]),
                            face: CGPoint(x: 0, y: 0.06), eye: Eye(height: 0.46, width: 0.46, spread: 0.46),
                            eyeColor: RGBA(hex: 0x050810),
                            decor: [.feelers([[CGPoint(x: -0.24, y: -0.9), CGPoint(x: -0.34, y: -1.14), CGPoint(x: -0.54, y: -1.22)],
                                              [CGPoint(x: 0.24, y: -0.9), CGPoint(x: 0.34, y: -1.14), CGPoint(x: 0.54, y: -1.22)]],
                                             RGBA(hex: 0xea4a4a), width: 0.1)],
                            crossesEyes: true),
        // The cat in each logo, sitting up straight and out of its tile: white head, the logo's coloured face.
        "CodeBuddy": cat(head: RGBA(hex: 0xffffff),
                         face: .linear(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.85, y: 1),
                                       stops: [RGBA(hex: 0x5570da), RGBA(hex: 0x4587c1), RGBA(hex: 0x369dab)])),
        "WorkBuddy": cat(head: RGBA(hex: 0xeafaf6),
                         face: .linear(from: CGPoint(x: 0.5, y: 0.55), to: CGPoint(x: 0.5, y: 1),
                                       stops: [RGBA(hex: 0x00cd8c), RGBA(hex: 0x7dd76d)])),
        // A white ball wearing the logo's green as a neck warmer: the lower part of the ball, pulled up higher
        // at the sides than under the eyes, with a paler cuff along its edge. Nothing stands out from the ball.
        "Qoder": BotSpec(reach: 0.55, paint: .solid(RGBA(hex: 0xf8f8f8)), face: CGPoint(x: 0, y: -0.24),
                         eye: Eye(height: 0.7, width: 0.3, spread: 0.42),
                         decor: [.soft([rect(-1.2, -0.3, 1.2, 1.2)], RGBA(hex: 0x28d858), round: 0),
                                 .soft([rect(-1.4, -1.7, 1.4, 0.45)], RGBA(hex: 0x5be584), round: 1),
                                 .soft([rect(-1.4, -1.7, 1.4, 0.34)], RGBA(hex: 0xf8f8f8), round: 1)],
                         crossesEyes: true),
        // Already a bot: it keeps its helmet and goggles, and its two eyes come alive where they are drawn.
        "GitHub Copilot": BotSpec(ownEyes: [rect(0.355, 0.570, 0.434, 0.723), rect(0.562, 0.570, 0.645, 0.723)]),
    ]

    private static func cat(head: RGBA, face: Paint) -> BotSpec {
        BotSpec(center: CGPoint(x: 0.5, y: 0.55), reach: 0.5, shape: .cat, paint: .solid(head),
                face: CGPoint(x: 0, y: 0.2), eye: Eye(height: 0.84, width: 0.36), eyeColor: RGBA(hex: 0xffffff),
                patch: Patch(box: rect(-0.9, -0.52, 0.9, 1.3), round: 0.5, paint: face), crossesEyes: true)
    }

    private static func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

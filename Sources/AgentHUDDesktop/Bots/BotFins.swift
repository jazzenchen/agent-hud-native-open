import CoreGraphics
import Foundation

/// How far a fish's two hands, its pectoral fins (`BotSpec.Fin.hand`), are raised about their roots, in whole degrees so
/// two looks can tell them apart: the left one, then the right. Every other fin, and every bot without hands, keeps still.
struct BotFlap: Hashable, Sendable {
    var left = 0, right = 0

    init(left: CGFloat = 0, right: CGFloat = 0) {
        self.left = Int(left.rounded())
        self.right = Int(right.rounded())
    }

    init(both: CGFloat) { self.init(left: both, right: both) }

    /// How far the hand on `side` is raised: −1 for the left, 1 for the right, 0 for a fin that keeps still.
    func raised(_ side: CGFloat) -> CGFloat {
        side < 0 ? CGFloat(left) : side > 0 ? CGFloat(right) : 0
    }
}

/// The outline of a fin, in body radii from the body's centre.
enum BotFins {
    /// A rounded paddle: a disc at the root and a disc at the tip, wrapped by the two lines that touch both, so a broad
    /// root and a small tip make a triangle with its corners rounded: a fish's side fin or the fin on its back. `grown` is how far it
    /// has grown out of its root, from 0 to 1; `raised` is how many degrees it has turned up about its root.
    static func path(_ fin: BotSpec.Fin, grown: CGFloat, raised: CGFloat) -> CGPath {
        // A hand on the right turns up against the clock, one on the left with it, with y running down.
        let angle = (fin.angle - fin.hand * raised) * .pi / 180
        let along = CGPoint(x: cos(angle), y: sin(angle)), across = CGPoint(x: sin(angle), y: -cos(angle))
        let length = fin.length * grown
        let a = fin.root, ra = fin.base * grown, rb = fin.tip * grown
        let b = CGPoint(x: a.x + along.x * (length - rb) + across.x * fin.sweep * grown,
                        y: a.y + along.y * (length - rb) + across.y * fin.sweep * grown)
        let dx = b.x - a.x, dy = b.y - a.y, d = max(1e-6, hypot(dx, dy))
        // The lines touching both discs leave each at the same angle to the line between their centres.
        let s = max(-1, min(1, (ra - rb) / d)), c = sqrt(1 - s * s)
        let toward = atan2(dy, dx), spread = atan2(c, s)
        let path = CGMutablePath()
        // Round the tip from one touching line to the other, then back round the root.
        arc(path, b, rb, from: toward - spread, to: toward + spread)
        arc(path, a, ra, from: toward + spread, to: toward + 2 * .pi - spread)
        path.closeSubpath()
        return path
    }

    /// Every fin a body wears, at rest and grown, in the mark's own coordinates; nil for a body without fins.
    static func silhouette(of spec: BotSpec) -> CGPath? {
        let place = CGAffineTransform(translationX: spec.center.x, y: spec.center.y)
            .scaledBy(x: spec.radius, y: spec.radius)
        let path = CGMutablePath()
        for case .fins(let fins, _) in spec.decor {
            for fin in fins { path.addPath(Self.path(fin, grown: 1, raised: 0), transform: place) }
        }
        return path.isEmpty ? nil : path
    }

    /// An arc round `center` from one angle to a larger one, as points close enough to read as a curve at any size a
    /// bot is drawn.
    private static func arc(_ path: CGMutablePath, _ center: CGPoint, _ radius: CGFloat, from start: CGFloat, to end: CGFloat) {
        let steps = max(2, Int(((end - start) / (.pi / 16)).rounded(.up)))
        for step in 0...steps {
            let angle = start + (end - start) * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
        }
    }
}

extension BotMoves {
    // MARK: Fins

    /// Degrees a fish's hands go up on each beat of a tool's bob, as the body dips.
    static let paddle: CGFloat = 14

    /// How far a fish's hands are raised at a start, `time` seconds into it: one flap, up and down with the hop.
    static func finFlap(_ time: TimeInterval) -> CGFloat {
        guard time >= 0, time < hopSeconds else { return 0 }
        return 32 * sin(.pi * CGFloat(time / hopSeconds))
    }

    /// Seconds a fish waves one hand at whoever it greets.
    static let finWaveSeconds: TimeInterval = 0.9

    /// How far the waving hand is raised, `time` seconds into the greeting: up, waggled twice, and down again.
    static func finWave(_ time: TimeInterval) -> CGFloat {
        guard time >= 0, time < finWaveSeconds else { return 0 }
        let rise: TimeInterval = 0.18
        let up = BotMotion.easeInOut(CGFloat(min(1, time / rise)))
            * BotMotion.easeInOut(CGFloat(min(1, (finWaveSeconds - time) / rise)))
        return up * (34 + 12 * sin(2 * .pi * CGFloat((time - rise) / 0.27)))
    }

    /// When a fish starts flapping both hands over a reply's card, once it has turned into its bot, and for how long.
    static let cheerStart: TimeInterval = 0.3, cheerSeconds: TimeInterval = 1.2

    /// How far both hands are raised over a reply's card, `age` seconds into it: three flaps while it smiles.
    static func cheer(_ age: TimeInterval) -> CGFloat {
        let time = age - cheerStart
        guard time >= 0, time < cheerSeconds else { return 0 }
        return 30 * abs(sin(.pi * CGFloat(time / (cheerSeconds / 3))))
    }
}

import AppKit
import AgentHUDCore
import CoreGraphics

/// Draws one frame of a bot: wherever its motion says it is between the logo and the bot, with the eyes it
/// has at that moment. The frame is the bot standing still and upright; how it sits — hopping, leaning,
/// breathing — is a transform the caller applies to the layer, so a breath never costs a redraw.
@MainActor
enum BotRenderer {
    /// Room round the mark for what overflows it — ears, a hat, a ring, rays on their way in — as a share of
    /// the mark's side on every edge.
    static let margin: CGFloat = 0.3

    /// What a frame depends on, in steps finer than the eye can tell apart. Two motions with the same look
    /// draw the same picture, so a bot that has not visibly changed is not drawn again.
    struct Look: Hashable {
        var morph, turn, open, look, lookY, wide, happy, lean, crossed, lift, scale: Int
        var limbs: BotLimbs
        var flap: BotFlap
        var sign: BotSign?
        var lit: Int
        var helper: Bool
    }

    static func look(of motion: BotMotion) -> Look {
        let face = motion.face
        func step(_ value: CGFloat, _ steps: CGFloat) -> Int { Int((value * steps).rounded()) }
        return Look(morph: step(motion.morph, 60), turn: step(motion.turn, 0.5), open: step(face.open, 40),
                    look: step(face.look, 50), lookY: step(face.lookY, 50), wide: step(face.wide, 50),
                    happy: step(face.happy, 30), lean: step(face.lean, 30), crossed: step(face.crossed, 30),
                    lift: step(motion.kept.lift, 300), scale: step(motion.kept.scale, 60), limbs: motion.limbs,
                    flap: motion.flap, sign: motion.sign, lit: motion.lit, helper: motion.helper)
    }

    /// The island's own dark: eyes drawn in it read as cut out of any body, on the island or over a wallpaper.
    private static let ink = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)

    /// What reads as cut out of a body drawn in `form`'s ink: the island's dark out of a light body, the light ground's
    /// own colour out of a dark one.
    private static func cut(_ form: BotForm) -> CGColor {
        switch form.ground {
        case .dark: ink
        case .light: color(BotSpec.lightCut)
        }
    }
    private static let box = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// One frame, `side` pixels to the mark's side, with `margin` of room on every edge.
    ///
    /// - outline: pixels of hairline round the bot, for a bot that sits on a wallpaper beside the logo queue's outlined
    ///   marks: dark round a bot in light ink, light round one in dark ink. The picture grows by that much on every edge.
    /// - space: the colours of the display the frame is shown on; sRGB when it is not known.
    static func image(_ form: BotForm, motion: BotMotion, side: CGFloat, outline: Int = 0, space: CGColorSpace? = nil) -> CGImage? {
        guard let context = bare(form, motion: motion, side: side, outline: outline, space: space) else { return nil }
        if outline > 0 { BotHairline.lay(on: context, reach: outline, ground: form.ground) }
        return context.makeImage()
    }

    /// The plain logo, in a frame like `image`'s, wearing `sign` if it has one: the frame `image` draws for a motion that
    /// rests as its logo, for a bot drawn some other way while it does, such as Clawd from its sprites.
    static func logo(_ form: BotForm, sign: BotSign?, side: CGFloat, outline: Int = 0, space: CGColorSpace? = nil) -> CGImage? {
        let inner = Int((side * (1 + 2 * margin)).rounded(.up))
        guard inner > 0, let context = BotCanvas.clear(inner + outline * 2, space: space) else { return nil }
        context.saveGState()
        enterMark(on: context, inner: inner, outline: outline)
        context.interpolationQuality = .high
        draw(form.artwork, in: box, on: context)
        context.restoreGState()
        if let sign { paint(sign, lit: 0, alpha: 1, form: form, side: side, outline: outline, on: context) }
        if outline > 0 { BotHairline.lay(on: context, reach: outline, ground: form.ground) }
        return context.makeImage()
    }

    /// The frame without its hairline, with `outline` pixels of room left for one on every edge, in the kept
    /// bitmap the next frame is drawn in.
    static func bare(_ form: BotForm, motion: BotMotion, side: CGFloat, outline: Int, space: CGColorSpace?) -> CGContext? {
        let inner = Int((side * (1 + 2 * margin)).rounded(.up)), extent = inner + outline * 2
        guard inner > 0, let context = BotCanvas.clear(extent, space: space) else { return nil }
        context.saveGState()
        enterMark(on: context, inner: inner, outline: outline)
        context.interpolationQuality = .high

        if let eyes = form.spec.ownEyes {
            context.setAlpha(1 - motion.morph)
            draw(form.artwork, in: box, on: context)
            if motion.morph > 0 {
                // Blend the complete eye animation as one picture: its drawing sets its own alpha.
                context.setAlpha(motion.morph)
                context.setBlendMode(.plusLighter)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(form.stripped ?? form.artwork, in: box, on: context)
                ownEyes(eyes, face: motion.face, ink: form.ink, on: context)
                context.endTransparencyLayer()
                context.setBlendMode(.normal)
                if motion.helper { helper(form, strength: motion.morph, on: context) }
            }
        } else {
            body(form, motion: motion, on: context)
        }
        context.restoreGState()
        if let sign = motion.sign {
            // A sign of the bot's own comes with it; a request's or a badge's stands on the logo too.
            let alpha = sign == .ellipsis || sign == .z ? Morph(motion.morph).dressed : 1
            paint(sign, lit: motion.lit, alpha: alpha, form: form, side: side, outline: outline, on: context)
        }
        return context
    }

    /// From here one unit is the mark's side, measured from its top left with y running down, in a frame `inner` pixels
    /// wide with `outline` pixels round it.
    private static func enterMark(on context: CGContext, inner: Int, outline: Int) {
        let unit = CGFloat(inner) / (1 + 2 * margin)
        context.translateBy(x: CGFloat(outline), y: CGFloat(inner + outline))
        context.scaleBy(x: unit, y: -unit)
        context.translateBy(x: margin, y: margin)
    }

    /// Paints `sign` over the bot in the frame's own pixels, which run up from its bottom left, so every cell is whole.
    private static func paint(_ sign: BotSign, lit: Int, alpha: CGFloat, form: BotForm, side: CGFloat, outline: Int,
                              on context: CGContext) {
        let place = BotSigns.box(for: form, side: side, outline: outline)
        let rect = CGRect(x: place.minX, y: CGFloat(context.height) - place.maxY, width: place.width, height: place.height)
        context.saveGState()
        context.setAlpha(alpha)
        BotSigns.paint(sign, lit: lit, in: rect, on: context, ground: form.ground)
        context.restoreGState()
    }

    // MARK: The morph

    /// How far each part of a body has come through the morph. Worked out once a frame, so the still part kept
    /// from an earlier frame and the part drawn over it follow the same curves.
    private struct Morph {
        /// How far the logo has turned into the bot, from 0 to 1.
        let share: CGFloat
        /// The share eased in and out: how far the outline has come and how far the body has settled.
        let eased: CGFloat
        /// The body's colour field, solid well before the outline has arrived.
        let solid: CGFloat
        /// What the body wears, which arrives with the eyes.
        let dressed: CGFloat

        init(_ share: CGFloat) {
            self.share = share
            eased = BotMotion.easeInOut(share)
            solid = min(1, share / 0.22)
            dressed = max(0, min(1, (share - 0.45) / 0.45))
        }

        /// The logo stays where it is; the bot it turns into may settle a little above or below it.
        func settle(_ spec: BotSpec, on context: CGContext) {
            context.translateBy(x: 0, y: spec.settle * eased)
        }
    }

    /// A body's frame: its still part, kept from an earlier frame when nothing has moved it, then what moves
    /// with the face.
    private static func body(_ form: BotForm, motion: BotMotion, on context: CGContext) {
        let spec = form.spec, morph = Morph(motion.morph), radius = spec.radius
        // Everything drawn before a kept piece, or before a piece that rides with the face, moves with the morph
        // and the turn alone. A bot that does not spin draws that part once and then only what its face changes.
        let settled = spec.keeps == nil ? spec.decor.firstIndex { $0.followsFace } ?? spec.decor.count : 0
        let still = BotStill(form: form, morph: morph.share, turn: motion.turn, helper: motion.helper, flap: motion.flap,
                             on: context)
        if !still.restore() {
            context.saveGState()
            stillPart(form, morph: morph, turn: motion.turn, decor: settled, helper: motion.helper, flap: motion.flap,
                      on: context)
            context.restoreGState()
            still.keep()
        }

        morph.settle(spec, on: context)
        if let kept = spec.keeps {
            context.saveGState()
            context.setAlpha(morph.solid)
            context.translateBy(x: kept.midX, y: kept.midY - motion.kept.lift)
            context.scaleBy(x: motion.kept.scale, y: motion.kept.scale)
            context.translateBy(x: -kept.midX, y: -kept.midY)
            context.clip(to: kept.insetBy(dx: -0.01, dy: -0.01))
            draw(form.artwork, in: box, on: context)
            context.restoreGState()
        }

        guard morph.dressed > 0 else { return }
        limbs(form, stance: motion.limbs, strength: morph.dressed, on: context)
        let face = motion.face, turn = spec.reach * 0.72
        let yaw = max(-1.15, min(1.15, face.look)) * turn, pitch = max(-1.15, min(1.15, face.lookY)) * turn
        let glance = CGPoint(x: sin(yaw) * radius * 0.72, y: sin(pitch) * radius * 0.62)
        if spec.keeps != nil {
            wear(spec, outline: form.outline(eased: morph.eased, turn: motion.turn), strength: morph.dressed, on: context)
        }
        for item in spec.decor[settled...] {
            decorate(item, spec: spec, offset: item.followsFace ? glance : .zero, strength: morph.dressed, on: context)
        }
        eyes(spec, face: face, yaw: yaw, pitch: pitch, awake: morph.dressed, on: context)
    }

    /// The part of a body that only the morph and the turn change: the logo fading out, the body and its
    /// paint, a ring, and what it wears up to the first piece that moves with its face; then the small copy of the body
    /// that stands for its sub-agents, when they run. `decor` counts the pieces of `spec.decor` drawn here; a body with
    /// a kept piece draws none here, as that piece comes first. A fish's hands are part of it too, raised by `flap`.
    private static func stillPart(_ form: BotForm, morph: Morph, turn: CGFloat, decor: Int, helper: Bool = false,
                                  flap: BotFlap = BotFlap(), on context: CGContext) {
        let spec = form.spec, share = morph.share, eased = morph.eased, solid = morph.solid, dressed = morph.dressed
        let center = spec.center, radius = spec.radius
        // The artwork fades into the colour field while the outline is still close to the logo's.
        let artwork = 1 - min(1, share / 0.4)
        if artwork > 0 {
            context.setAlpha(artwork)
            draw(form.artwork, in: box, on: context)
        }
        morph.settle(spec, on: context)
        let outline = form.outline(eased: eased, turn: turn)

        // A ring goes on in two passes: all of it first, so the body covers the far side; then the near side
        // drawn across the body.
        let ringShare = spec.ring == nil ? 0 : max(0, min(1, (share - 0.5) / 0.5))
        if let ring = spec.ring, ringShare > 0 {
            context.setAlpha(ringShare)
            context.setStrokeColor(form.ink)
            context.setLineWidth(ring.width * radius)
            context.setLineCap(.round)
            context.addPath(ringPath(ring, spec: spec, grown: ringShare, nearSideOnly: false))
            context.strokePath()
        }

        // Feelers go on before the body, which then covers where they start.
        for item in spec.decor where dressed > 0 {
            guard case .feelers(let lines, let paint, let width) = item else { continue }
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: radius, y: radius)
            context.setAlpha(dressed)
            context.setStrokeColor(color(paint))
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            for line in lines { context.addLines(between: line) }
            context.strokePath()
            context.restoreGState()
        }
        // So do fins, which grow out of their roots as the bot arrives.
        for item in spec.decor where dressed > 0 {
            guard case .fins(let fins, let paint) = item else { continue }
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: radius, y: radius)
            context.setAlpha(dressed)
            context.setFillColor(color(paint))
            let grown = 0.3 + 0.7 * dressed
            for fin in fins { context.addPath(BotFins.path(fin, grown: grown, raised: flap.raised(fin.hand))) }
            context.fillPath()
            context.restoreGState()
        }

        context.setAlpha(solid)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        fill(spec.paint, form: form, on: context)
        if let patch = spec.patch {
            // The face panel grows in with the morph.
            let width = patch.box.width * radius, height = patch.box.height * radius
            let corner = min(patch.round * radius, min(width, height) / 2)
            context.saveGState()
            context.translateBy(x: center.x + patch.box.midX * radius, y: center.y + patch.box.midY * radius)
            context.scaleBy(x: 0.4 + 0.6 * eased, y: 0.4 + 0.6 * eased)
            context.setAlpha(solid * max(0, min(1, (share - 0.2) / 0.4)))
            context.addPath(CGPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                   cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.clip()
            fill(patch.paint, form: form, on: context, origin: CGPoint(x: -center.x - patch.box.midX * radius,
                                                                       y: -center.y - patch.box.midY * radius))
            context.restoreGState()
        }
        if let stroke = spec.stroke {
            context.setStrokeColor(color(stroke))
            context.setLineWidth(0.07)
            context.setLineJoin(.round)
            context.addPath(outline)
            context.strokePath()
        }
        context.restoreGState()

        if let ring = spec.ring, ringShare > 0 {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.setAlpha(ringShare)
            context.setStrokeColor(cut(form))
            context.setLineWidth(ring.width * radius)
            context.setLineCap(.butt)
            context.addPath(ringPath(ring, spec: spec, grown: ringShare, nearSideOnly: true))
            context.strokePath()
            context.restoreGState()
        }

        if spec.keeps == nil, dressed > 0 {
            wear(spec, outline: outline, strength: dressed, on: context)
            for item in spec.decor.prefix(decor) { decorate(item, spec: spec, offset: .zero, strength: dressed, on: context) }
        }
        if helper, dressed > 0 { self.helper(form, strength: dressed, on: context) }
    }

    // MARK: Sub-agents

    /// The copy's size, and where its centre stands from the body's, as shares of the side.
    private static let helperScale: CGFloat = 0.4
    private static let helperOffset = CGPoint(x: 0.42, y: 0.18)
    /// The gap kept clear round the copy, as a share of the side, so the two bodies never run into one blob.
    private static let helperGap: CGFloat = 0.035

    /// A still copy of the finished bot at 0.4 of its size, to the lower right of the body, for sub-agents at work: its
    /// body, paint and what it wears, its arms and legs at rest, and its eyes open and ahead. It never moves, so it is
    /// drawn with the still part and kept with it.
    private static func helper(_ form: BotForm, strength: CGFloat, on context: CGContext) {
        let spec = form.spec, scale = helperScale
        let center = CGPoint(x: spec.center.x + helperOffset.x, y: spec.center.y + helperOffset.y)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -spec.center.x, y: -spec.center.y)
        context.setAlpha(strength)
        if spec.ownEyes != nil {
            // A mark that keeps its artwork is copied whole, with the gap cut by a larger copy of it.
            context.saveGState()
            context.translateBy(x: 0.5, y: 0.5)
            context.scaleBy(x: 1 + helperGap * 2 / scale, y: 1 + helperGap * 2 / scale)
            context.translateBy(x: -0.5, y: -0.5)
            context.setBlendMode(.destinationOut)
            draw(form.artwork, in: box, on: context)
            context.restoreGState()
            draw(form.artwork, in: box, on: context)
        } else {
            let outline = form.outline(eased: 1, turn: 0)
            context.saveGState()
            context.setBlendMode(.destinationOut)
            context.setStrokeColor(.black)
            context.setLineWidth(helperGap * 2 / scale)
            context.setLineJoin(.round)
            context.addPath(outline)
            // A fish's copy keeps the gap round its fins too.
            if let fins = BotFins.silhouette(of: spec) { context.addPath(fins) }
            context.strokePath()
            context.restoreGState()
            // As one picture, so the copy's own parts do not show through each other at its strength. The still part
            // settles the copy as the finished bot settles, and its limbs and eyes sit where that leaves them.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            stillPart(form, morph: Morph(1), turn: 0, decor: spec.decor.count, on: context)
            limbs(form, stance: BotLimbs(), strength: 1, on: context)
            eyes(spec, face: BotFace(), yaw: 0, pitch: 0, awake: 1, on: context)
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    /// Arms and legs where the motion has put them, filled with the body's own paint. They come with the eyes.
    private static func limbs(_ form: BotForm, stance: BotLimbs, strength: CGFloat, on context: CGContext) {
        guard let limbs = form.spec.limbs else { return }
        let spec = form.spec, step = limbs.pixel
        var pieces: [CGRect] = []
        for arm in limbs.arms {
            let out: CGFloat = arm.midX < 0 ? -1 : 1, raised = out < 0 ? stance.left : stance.right
            pieces.append(arm.offsetBy(dx: 0, dy: raised > 0 ? -step : 0))
            if raised > 1 { pieces.append(arm.offsetBy(dx: out * arm.width, dy: -2 * step)) }
        }
        for (index, leg) in limbs.legs.enumerated() {
            let lifted = stance.lifted == 3 || stance.lifted > 0 && index % 2 == stance.lifted - 1
            pieces.append(leg.offsetBy(dx: 0, dy: lifted ? -step / 2 : 0))
        }
        // A path is kept in the space it was added in, so the pieces stay in body radii once the space is restored.
        context.saveGState()
        context.translateBy(x: spec.center.x, y: spec.center.y)
        context.scaleBy(x: spec.radius, y: spec.radius)
        context.addRects(pieces)
        if stance.spinner > 0 { spinner(stance.spinner, at: CGPoint(x: 2.2 * step, y: -1 - 1.5 * step), size: 0.75 * step, on: context) }
        context.restoreGState()
        context.saveGState()
        context.clip()
        context.setAlpha(strength)
        fill(spec.paint, form: form, on: context)
        context.restoreGState()
    }

    /// Claude Code's spinner, one of its six frames from a dot to the fullest star, added to the current path as the
    /// outlines of its spokes. `size` is the longest spoke.
    private static func spinner(_ frame: Int, at center: CGPoint, size: CGFloat, on context: CGContext) {
        let shapes: [(spokes: Int, length: CGFloat, width: CGFloat)] = [(0, 0.24, 0.24), (4, 0.55, 0.2), (4, 0.85, 0.22),
                                                                       (6, 0.9, 0.2), (8, 1, 0.2), (8, 1, 0.28)]
        let shape = shapes[max(0, min(shapes.count - 1, frame - 1))]
        guard shape.spokes > 0 else {
            let side = shape.length * size
            context.addRect(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
            return
        }
        let spokes = CGMutablePath()
        for index in 0..<shape.spokes {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(shape.spokes)
            spokes.move(to: center)
            spokes.addLine(to: CGPoint(x: center.x + cos(angle) * shape.length * size, y: center.y + sin(angle) * shape.length * size))
        }
        context.addPath(spokes.copy(strokingWithWidth: shape.width * size, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }

    /// One piece a body wears over its outline, `offset` from where it sits on the body.
    private static func decorate(_ item: BotSpec.Decor, spec: BotSpec, offset: CGPoint, strength: CGFloat,
                                 on context: CGContext) {
        context.saveGState()
        context.translateBy(x: spec.center.x + offset.x, y: spec.center.y + offset.y)
        context.scaleBy(x: spec.radius, y: spec.radius)
        context.setAlpha(strength)
        switch item {
        case .blocks(let rects, let paint, _):
            context.setFillColor(color(paint))
            context.fill(rects)
        case .cut(let rects):
            context.setBlendMode(.destinationOut)
            context.setFillColor(.black)
            context.fill(rects)
        case .notch(let points):
            context.setBlendMode(.destinationOut)
            context.setFillColor(.black)
            context.addLines(between: points)
            context.closePath()
            context.fillPath()
        case .line(let points, let width):
            context.setStrokeColor(ink)
            context.setLineWidth(width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.addLines(between: points)
            context.strokePath()
        case .soft, .feelers, .fins:
            break
        }
        context.restoreGState()
    }

    /// The soft pieces a body wears, kept to its outline: a fringe, a scarf. Sizes are in body radii from
    /// the body's centre.
    private static func wear(_ spec: BotSpec, outline: CGPath, strength: CGFloat, on context: CGContext) {
        for item in spec.decor {
            guard case .soft(let rects, let paint, let round) = item else { continue }
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.translateBy(x: spec.center.x, y: spec.center.y)
            context.scaleBy(x: spec.radius, y: spec.radius)
            context.setAlpha(strength)
            context.setFillColor(color(paint))
            for rect in rects {
                let corner = min(rect.width, rect.height) / 2 * round
                context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            }
            context.fillPath()
            context.restoreGState()
        }
    }

    private static func ringPath(_ ring: BotSpec.Ring, spec: BotSpec, grown: CGFloat, nearSideOnly: Bool) -> CGPath {
        let path = CGMutablePath(), radius = spec.radius, size = 0.5 + 0.5 * grown
        let tilt = ring.tilt * .pi / 180, steps = 48
        let sweep = nearSideOnly ? CGFloat.pi : 2 * CGFloat.pi
        for step in 0...steps {
            let angle = sweep * CGFloat(step) / CGFloat(steps)
            let x = ring.radiusX * radius * size * cos(angle), y = ring.radiusY * radius * size * sin(angle)
            let point = CGPoint(x: spec.center.x + x * cos(tilt) - y * sin(tilt),
                                y: spec.center.y + ring.drop * radius + x * sin(tilt) + y * cos(tilt))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if !nearSideOnly { path.closeSubpath() }
        return path
    }

    /// Paints the current clip. `origin` moves the mark's coordinates when the context has been re-centred.
    private static func fill(_ paint: BotSpec.Paint, form: BotForm, on context: CGContext, origin: CGPoint = .zero) {
        let spec = form.spec
        func at(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + spec.center.x + (point.x - 0.5) * 2 * spec.radius,
                    y: origin.y + spec.center.y + (point.y - 0.5) * 2 * spec.radius)
        }
        let everything = CGRect(x: origin.x - 0.3, y: origin.y - 0.3, width: 1.6, height: 1.6)
        let both: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch paint {
        case .artwork:
            if let field = form.field {
                draw(field, in: CGRect(x: origin.x - 0.25, y: origin.y - 0.25, width: 1.5, height: 1.5), on: context)
            } else {
                context.setFillColor(form.ink)
                context.fill(everything)
            }
        case .solid(let value):
            context.setFillColor(color(value))
            context.fill(everything)
        case .linear(let from, let to, let stops):
            guard let gradient = gradient(stops) else { return }
            context.drawLinearGradient(gradient, start: at(from), end: at(to), options: both)
        case .radial(let center, let inner, let outer, let stops):
            guard let gradient = gradient(stops) else { return }
            context.drawRadialGradient(gradient, startCenter: at(center), startRadius: inner * 2 * spec.radius,
                                       endCenter: at(center), endRadius: outer * 2 * spec.radius, options: both)
        }
    }

    // MARK: Eyes

    /// Two small eyes that sit on the body as on a ball: turning the gaze slides them across it and narrows
    /// the far one, so the body reads as a head looking somewhere. They stay upright.
    private static func eyes(_ spec: BotSpec, face: BotFace, yaw: CGFloat, pitch: CGFloat, awake: CGFloat,
                             on context: CGContext) {
        let radius = spec.radius, size: CGFloat = 0.78, spread = spec.eye.spread, flat = spec.eye.across
        // The smallest step of a pixel-art body's art, in body radii: half a limb's step.
        let grain = spec.limbs.map { $0.pixel / 2 }
        func snapped(_ value: CGFloat) -> CGFloat { grain.map { ($0 > 0 ? (value / $0).rounded() * $0 : value) } ?? value }
        let paint = spec.eyeColor.map(color) ?? ink
        // A smile is sized from how far apart the eyes are right now, so two never join into one line.
        let apart = flat.map { 2 * $0 * radius } ?? (sin(yaw + spread) - sin(yaw - spread)) * radius * 0.76
        for side in [-1.0, 1.0] as [CGFloat] {
            let angle = flat == nil ? yaw + side * spread : 0
            // On a flat face the two slide across together, in whole steps where the body is pixel art; on a ball each
            // goes round it.
            let x = spec.center.x + spec.face.x * radius
                + (flat.map { side * $0 * radius + snapped(sin(yaw) * 0.76) * radius } ?? sin(angle) * radius * 0.76)
            let y = spec.center.y + spec.face.y * radius + (flat == nil ? sin(pitch) * 0.62 : snapped(sin(pitch) * 0.62)) * radius
            let narrow = pow(max(0.25, cos(angle)), 1.4), tall = (0.72 + 0.28 * cos(angle)) * pow(cos(pitch), 0.5)
            let big = (1 + 0.26 * side * face.lean) * face.wide * (0.6 + 0.4 * awake) * size
            let width = spec.eye.width * radius * big * narrow
            let height = spec.eye.height * radius * big * tall * max(0.08, face.open) * awake
            context.saveGState()
            context.translateBy(x: x, y: y)
            if face.happy < 0.98, face.crossed < 0.98 {
                context.setAlpha((1 - face.happy) * (1 - face.crossed))
                context.setFillColor(paint)
                context.addPath(pill(width, max(height, width * 0.16), round: spec.eye.round))
                context.fillPath()
                if let pupil = spec.pupil, height > width * 0.45 {
                    context.setFillColor(color(pupil))
                    let across = width * 0.21, down = min(height, width) * 0.21
                    context.fillEllipse(in: CGRect(x: face.look * width * 0.2 - across,
                                                   y: face.lookY * height * 0.2 - height * 0.06 - down,
                                                   width: across * 2, height: down * 2))
                }
            }
            if face.crossed > 0.02 {
                // Crossed out after a failed turn, across a square as wide as two thirds of the eye is tall, so a narrow
                // eye still reads as a cross.
                let reach = spec.eye.height * radius * size * 0.32 * (0.6 + 0.4 * awake)
                context.setAlpha(face.crossed)
                context.setStrokeColor(paint)
                context.setLineWidth(spec.eye.width * radius * size * 0.55)
                context.setLineCap(.round)
                context.move(to: CGPoint(x: -reach, y: -reach))
                context.addLine(to: CGPoint(x: reach, y: reach))
                context.move(to: CGPoint(x: -reach, y: reach))
                context.addLine(to: CGPoint(x: reach, y: -reach))
                context.strokePath()
            }
            if face.happy > 0.02 {
                let stroke = min(spec.eye.width * radius * 0.58 * size, apart * 0.2)
                let half = max(stroke * 0.7, min(spec.eye.width * radius * 0.8 * size, apart / 2 - stroke * 1.05)) * max(0.6, narrow)
                smile(half: half, stroke: stroke, paint: paint, strength: face.happy, on: context)
            }
            context.restoreGState()
        }
    }

    /// Eyes that belong to the artwork: drawn where the mark draws them, in the mark's own `ink`.
    private static func ownEyes(_ eyes: [CGRect], face: BotFace, ink: CGColor, on context: CGContext) {
        guard let first = eyes.first, let last = eyes.last else { return }
        let middle = (first.midX + last.midX) / 2, apart = abs(last.midX - first.midX)
        for eye in eyes {
            let side: CGFloat = eye.midX > middle ? 1 : -1
            let big = (1 + 0.26 * side * face.lean) * face.wide
            let width = eye.width * big, height = eye.height * big * max(0.06, face.open)
            context.saveGState()
            context.translateBy(x: eye.midX + min(0.04, eye.width * 0.45) * face.look,
                                y: eye.midY + min(0.03, eye.height * 0.14) * face.lookY)
            if face.happy < 0.98 {
                context.setAlpha(1 - face.happy)
                context.setFillColor(ink)
                context.addPath(pill(width, max(height, width * 0.16), round: 1))
                context.fillPath()
            }
            if face.happy > 0.02 {
                smile(half: min(eye.width * 0.95, apart * 0.3), stroke: min(eye.width * 0.6, apart * 0.2),
                      paint: ink, strength: face.happy, on: context)
            }
            context.restoreGState()
        }
    }

    /// An arch whose top points up the face, about the current origin.
    private static func smile(half: CGFloat, stroke: CGFloat, paint: CGColor, strength: CGFloat, on context: CGContext) {
        let rise = half * 0.95
        context.setAlpha(strength)
        context.setStrokeColor(paint)
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: -half, y: rise * 0.45))
        context.addQuadCurve(to: CGPoint(x: half, y: rise * 0.45), control: CGPoint(x: 0, y: -rise * 1.1))
        context.strokePath()
    }

    private static func pill(_ width: CGFloat, _ height: CGFloat, round: CGFloat) -> CGPath {
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let corner = min(width, height) / 2 * round
        return corner > 0.0005 ? CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            : CGPath(rect: rect, transform: nil)
    }

    // MARK: Pieces

    /// An image the right way up in coordinates whose y runs down.
    private static func draw(_ image: CGImage, in rect: CGRect, on context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func color(_ value: RGBA) -> CGColor {
        CGColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    private static func gradient(_ stops: [RGBA]) -> CGGradient? {
        guard stops.count > 1 else { return nil }
        let places = stops.indices.map { CGFloat($0) / CGFloat(stops.count - 1) }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(color) as CFArray,
                          locations: places)
    }
}

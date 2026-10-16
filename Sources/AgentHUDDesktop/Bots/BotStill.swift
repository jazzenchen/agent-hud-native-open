import CoreGraphics
import Foundation

/// The still part of a bot's frame, kept as the bitmap's own bytes: the body, its paint and what it wears, and the
/// small copy of it for sub-agents, which only the morph, the turn, the copy coming or going and a fish's flapping
/// hands change. A bot that does not spin draws them once it has turned into its bot and, for every blink and glance
/// after that, starts its frame from a copy. Copied bytes are the bytes drawing them would have made, so the frame
/// comes out the same.
@MainActor
struct BotStill {
    let form: BotForm
    let morph: CGFloat
    let turn: CGFloat
    let helper: Bool
    /// How far a fish's hands are raised: they stand behind the body, so they are drawn with it.
    let flap: BotFlap
    /// The cleared bitmap the frame is drawn in. Its size, colours and transform are part of what is kept.
    let context: CGContext

    init(form: BotForm, morph: CGFloat, turn: CGFloat, helper: Bool = false, flap: BotFlap = BotFlap(),
         on context: CGContext) {
        self.form = form
        self.morph = morph
        self.turn = turn
        self.helper = helper
        self.flap = flap
        self.context = context
    }

    /// One bot's still part on one kind of bitmap. Two queues showing the same bot at the same size share it.
    @MainActor
    private final class Slot {
        let form: BotForm
        let width: Int
        let space: CGColorSpace?
        let transform: CGAffineTransform
        /// The moment of the morph and the turn last drawn on this kind of bitmap, and whether the copy was on it.
        var morph: CGFloat
        var turn: CGFloat
        var helper: Bool
        var flap: BotFlap
        /// The still part at that moment, once it has been drawn there twice; until then nothing is copied, so a
        /// bot that is morphing or spinning, whose every frame is a new moment, pays for no copy it never uses.
        var bytes: [UInt8] = []
        var held = false

        init(_ still: BotStill) {
            form = still.form
            width = still.context.width
            space = still.context.colorSpace
            transform = still.context.ctm
            morph = still.morph
            turn = still.turn
            helper = still.helper
            flap = still.flap
        }
    }

    /// Kept parts, the one used longest ago first.
    private static var slots: [Slot] = []
    /// Two queues of every bot that draws a body (18 of the 19 today), on displays whose sizes or colours differ.
    /// Past that, the part used longest ago goes.
    private static let most = 36

    /// Where this bitmap's kept part is, moved to the end as the one used last.
    private func slot() -> Slot? {
        guard let index = Self.slots.firstIndex(where: {
            $0.form === form && $0.width == context.width && $0.space == context.colorSpace && $0.transform == context.ctm
        }) else { return nil }
        let slot = Self.slots.remove(at: index)
        Self.slots.append(slot)
        return slot
    }

    private var size: Int { context.bytesPerRow * context.height }

    /// Copies the kept part into the bitmap, when one was kept for this moment of the morph and the turn.
    func restore() -> Bool {
        guard let slot = slot(), slot.held, slot.morph == morph, slot.turn == turn, slot.helper == helper,
              slot.flap == flap, slot.bytes.count == size,
              let data = context.data
        else { return false }
        slot.bytes.withUnsafeBytes { _ = memcpy(data, $0.baseAddress!, $0.count) }
        return true
    }

    /// Notes what the bitmap holds now as the still part for this moment, and keeps a copy of it when this moment
    /// was also the last one drawn: a bot that has stopped moving is kept from its second still frame on.
    func keep() {
        guard let data = context.data else { return }
        guard let slot = slot() else {
            if Self.slots.count >= Self.most { Self.slots.removeFirst() }
            Self.slots.append(Slot(self))
            return
        }
        guard slot.morph == morph, slot.turn == turn, slot.helper == helper, slot.flap == flap else {
            slot.morph = morph
            slot.turn = turn
            slot.helper = helper
            slot.flap = flap
            slot.held = false
            return
        }
        if slot.bytes.count != size { slot.bytes = [UInt8](repeating: 0, count: size) }
        slot.bytes.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, data, $0.count) }
        slot.held = true
    }

    /// Lets every kept part go, so the next frame of every bot is drawn whole.
    static func forget() { slots = [] }
}

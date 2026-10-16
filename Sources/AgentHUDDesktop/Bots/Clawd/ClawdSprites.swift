import CoreGraphics
import Foundation

/// Clawd's sprites, for every Claude mark: decoded from the sheet Agent HUD bundles the first time a Claude mark is
/// built, and kept for as long as Agent HUD runs.
///
/// Nothing is decoded until the app says where from (`source`). Tests, snapshots and the demo, whose pictures may be
/// shown anywhere, never say, and keep the Clawd Agent HUD draws itself.
@MainActor
final class ClawdSprites {
    static let shared = ClawdSprites()

    /// Where the sprites are read from; nil reads nothing.
    var source: ClawdSheetSource?
    /// Nil until they are decoded, and for good if the bundled sheet does not fit the clips.
    private(set) var sheet: ClawdSheet?
    private var asked = false

    init(sheet: ClawdSheet? = nil) {
        self.sheet = sheet
    }

    /// A Claude mark is being built: the sprites are decoded, once, away from the main thread.
    func want() {
        guard let source, sheet == nil, !asked else { return }
        asked = true
        Task {
            if let sheet = await source.sheet(fitting: .standard) { use(sheet) }
        }
    }

    /// Hands every Claude mark `sheet`, or for nil takes the sprites away again. Each changes over within a frame.
    func use(_ sheet: ClawdSheet?) {
        guard sheet !== self.sheet else { return }
        self.sheet = sheet
        BotClock.shared.hurry()
    }
}

extension BotForm {
    /// Claude's mark, whose bot is Clawd, played from the Claude app's own sprites once they are decoded.
    var isClawd: Bool { AgentArtwork.markKey(vendor) == "Claude" }
}

extension ClawdSign {
    /// The sign of every bot's set it is drawn as.
    var botSign: BotSign {
        switch self {
        case .permission: .exclamation
        case .question: .question
        case .failed: .cross
        case .limited: .hourglass
        case .asleep: .z
        }
    }
}

extension ClawdBaker {
    /// Paints a Clawd's sign the way every bot's is painted, whole cells over its head.
    static let signs: SignPainter = { sign, box, context in
        BotSigns.paint(sign.botSign, in: box.rect, on: context, ground: box.ground)
    }
}

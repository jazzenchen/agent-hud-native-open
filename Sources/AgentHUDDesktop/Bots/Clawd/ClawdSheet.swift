import Foundation

/// The sprites of Clawd Quest, the game the Claude app ships, by the names the game gives them.
enum ClawdSpriteName: String, CaseIterable, Sendable {
    case breakDancing = "BreakDancing", confetti = "Confetti", crabWalking = "CrabWalking"
    case dancingHappy = "DancingHappy", desktop = "Desktop", disappointed = "Disappointed", dizzy = "Dizzy"
    case excited = "Excited", facepalm = "Facepalm", hula = "Hula", jumping = "Jumping"
    case jumpingHappy = "JumpingHappy", laptop = "Laptop", lightbulb = "Lightbulb"
    case lookingAround = "LookingAround", lookingAroundEyesOnly = "LookingAroundEyesOnly"
    case meditating = "Meditating", pointing = "Pointing", running = "Running", spark = "Spark"
    case swaying = "Swaying", thinking = "Thinking", turning = "Turning", walking = "Walking", waving = "Waving"

    /// Frames of this sprite by the game's own numbers: `Thinking[6...19]`.
    subscript(_ frames: ClosedRange<Int>) -> [ClawdFrame] { frames.map { ClawdFrame(self, $0) } }
    subscript(_ frames: Int...) -> [ClawdFrame] { frames.map { ClawdFrame(self, $0) } }
}

/// One frame of one sprite, numbered the way the game numbers it.
struct ClawdFrame: Hashable, Sendable, CustomStringConvertible {
    var sprite: ClawdSpriteName
    var index: Int

    init(_ sprite: ClawdSpriteName, _ index: Int) {
        self.sprite = sprite
        self.index = index
    }

    /// Clawd standing still: the pose the game draws whenever no animation plays.
    static let standing = ClawdFrame(.walking, 0)

    var description: String { "\(sprite.rawValue) \(index)" }
}

/// One sprite as the game keeps it: a small grid of palette indexes per frame, all frames the same size.
struct ClawdSprite: Sendable {
    /// An sRGB colour with 8 bits a channel.
    struct Color: Hashable, Sendable {
        var red, green, blue, alpha: UInt8
    }

    /// The index of a pixel nothing is drawn in.
    static let clear: UInt8 = 255

    let name: String
    /// The game's own grouping: Core, Reactive or Persona.
    let category: String
    let width, height: Int
    /// The rate the game plays the sprite at. Agent HUD plays every clip on its own 12 fps grid instead.
    let fps: Int
    let palette: [Color]
    /// One palette index per pixel, row by row from the top, `clear` where nothing is drawn.
    let frames: [[UInt8]]
    /// The point every frame is placed by, in sprite pixels from the top left: the bottom centre of the box the
    /// game stands Clawd's body in, which is under its feet. Props spill out of that box; the feet stay put.
    let anchor: (x: Int, y: Int)
    /// Whether the game counts the sprite's first frame as the standing pose.
    let standMatch: Bool

    var frameCount: Int { frames.count }
}

/// The sprites of the game Clawd plays, decoded once from the sheet Agent HUD bundles (`ClawdSheetSource`).
///
/// The art is Anthropic's, the Claude app's own, copied unchanged (THIRD_PARTY_NOTICES.txt); Agent HUD only picks
/// frames from it and places them.
final class ClawdSheet: Sendable {
    /// The version of the Claude app the sprites were copied from.
    let version: String
    let sprites: [String: ClawdSprite]
    /// For each frame that shows exactly what an earlier one shows, once both are placed by their anchors, that
    /// earlier frame. A clip holding a pose for two frames, or ending on the standing pose, then draws nothing new.
    private let earlier: [ClawdFrame: ClawdFrame]

    init(version: String, sprites: [String: ClawdSprite]) {
        self.version = version
        self.sprites = sprites
        earlier = Self.repeats(in: sprites)
    }

    subscript(_ name: ClawdSpriteName) -> ClawdSprite? { sprites[name.rawValue] }

    func has(_ frame: ClawdFrame) -> Bool {
        guard let sprite = self[frame.sprite] else { return false }
        return frame.index >= 0 && frame.index < sprite.frameCount
    }

    /// The first frame that looks exactly like `frame`: standing first, then the sprites by name in frame order.
    func canonical(_ frame: ClawdFrame) -> ClawdFrame { earlier[frame] ?? frame }

    /// Frames that repeat an earlier picture. Pixels are compared where they land, measured from the anchor, so a
    /// frame of one sprite can repeat a frame of another of a different size.
    private static func repeats(in sprites: [String: ClawdSprite]) -> [ClawdFrame: ClawdFrame] {
        var first: [[UInt8]: ClawdFrame] = [:], earlier: [ClawdFrame: ClawdFrame] = [:]
        let order = [ClawdSpriteName.walking] + ClawdSpriteName.allCases.filter { $0 != .walking }
        for name in order {
            guard let sprite = sprites[name.rawValue] else { continue }
            for (index, frame) in sprite.frames.enumerated() {
                let key = signature(of: frame, in: sprite), here = ClawdFrame(name, index)
                if let seen = first[key] { earlier[here] = seen } else { first[key] = here }
            }
        }
        return earlier
    }

    /// Each drawn pixel as its place from the anchor and its colour, in reading order.
    private static func signature(of frame: [UInt8], in sprite: ClawdSprite) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(frame.count * 2)
        for (offset, index) in frame.enumerated() where index != ClawdSprite.clear {
            let x = offset % sprite.width - sprite.anchor.x, y = offset / sprite.width - sprite.anchor.y
            let color = sprite.palette[Int(index)]
            bytes += [UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8),
                      UInt8(truncatingIfNeeded: y), UInt8(truncatingIfNeeded: y >> 8),
                      color.red, color.green, color.blue, color.alpha]
        }
        return bytes
    }
}

import Foundation
@testable import AgentHUDDesktop

/// A made-up sheet, in the shape of the one Agent HUD bundles. No art of the real game is ever in the tests.
enum ClawdFixture {
    /// Three sprites, written the three ways the game writes them, the first as JSON as the bundled sheet is.
    ///
    /// - Walking, 4×3: deltas as an array of strings; its box stands it on its bottom row.
    /// - Thinking, 3×2: deltas as one string split by `(`.
    /// - Waving, 2×1: a quoted name, keys out of order, deltas split by `.`, an empty box and a value that is code.
    static let file = """
    {"claude":"9.9.9","sprites":{"Walking":{"cat":"Core","w":4,"h":3,"fps":12,\
    "palette":["#d97757","#141413"],"base":"0110100100..","deltas":["","0.,51","b0"],"a0":[0,1,4,2],"standMatch":1},\
    Thinking:{cat:"Reactive",w:3,h:2,fps:12,palette:["#d97757","#141413","#699acb"],base:"0122.1",\
    deltas:"(12,2.(".split("("),a0:[0,0,3,2],standMatch:!0},\
    "Waving":{h:1,w:2,base:"0.",palette:["#fff"],deltas:"10..00".split("."),cat:"Core",a0:[0,0,0,0],fps:6,extra:f(1,[2]),standMatch:!1},\
    Broken:{cat:"Core",w:2,h:1,fps:12,palette:["#000"],base:"05",deltas:[],a0:[0,0,2,1],standMatch:1}}}
    """

    /// Walking's four frames, row by row, `clear` where nothing is drawn: an empty delta repeats a frame.
    static let walking: [[UInt8]] = {
        let clear = ClawdSprite.clear
        let first: [UInt8] = [0, 1, 1, 0, 1, 0, 0, 1, 0, 0, clear, clear]
        var second = first
        second[0] = clear
        second[5] = 1
        var third = second
        third[11] = 0
        return [first, first, second, third]
    }()

    /// The sprites of `file`, decoded.
    static func sheet() -> ClawdSheet {
        ClawdSpriteTable.sheet(in: Array(file.utf8)) ?? ClawdSheet(version: "", sprites: [:])
    }

    /// Every sprite of the game, as many frames long as the real ones, so the clips fit it, and every frame a picture of
    /// its own: one pixel, a row lower each frame, in a colour of the sprite's own. A frame in `sameAs` repeats another.
    static func everySprite(sameAs: [(ClawdFrame, ClawdFrame)] = []) -> ClawdSheet {
        var sprites: [String: ClawdSprite] = [:]
        for (name, count) in ClawdClipsTests.realFrameCounts {
            let color = ClawdSprite.Color(red: UInt8(ClawdSpriteName.allCases.firstIndex(of: name)!), green: 0, blue: 0, alpha: 255)
            var frames = (0..<count).map { index in (0..<count).map { $0 == index ? UInt8(0) : ClawdSprite.clear } }
            for (frame, original) in sameAs where frame.sprite == name { frames[frame.index] = frames[original.index] }
            sprites[name.rawValue] = ClawdSprite(name: name.rawValue, category: "", width: 1, height: count, fps: 12,
                                                 palette: [color], frames: frames, anchor: (0, count), standMatch: true)
        }
        return ClawdSheet(version: "", sprites: sprites)
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClawdFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

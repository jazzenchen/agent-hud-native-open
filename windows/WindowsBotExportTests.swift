import AppKit
import CryptoKit
import XCTest
@testable import AgentHUDDesktop

/// Windows asset build: use the original renderer and motion unchanged.
@MainActor
final class WindowsBotExportTests: XCTestCase {
    func testExport() throws {
        guard let folder = ProcessInfo.processInfo.environment["WINDOWS_BOT_EXPORT"] else { throw XCTSkip("Asset build only") }
        let root = URL(fileURLWithPath: folder), images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var clips: [[String: Any]] = [], seen: Set<String> = []
        var states: [(String, BotState)] = [
            ("working", BotState(look: .plain)), ("thinking", BotState(look: .thinking)),
            ("edit", BotState(look: .tool(.edit))), ("command", BotState(look: .tool(.command))),
            ("read", BotState(look: .tool(.read))), ("asking", BotState(look: .permission)),
            ("question", BotState(look: .question)), ("plan", BotState(look: .plan)),
            ("compacting", BotState(look: .compacting)), ("opened", BotState(look: .idle, hovered: true)),
            ("done", BotState(look: .done)), ("idle", BotState()), ("asleep", BotState(look: .asleep)),
            ("failed", BotState(look: .idle, badge: .failed, hovered: true)),
            ("limited", BotState(look: .idle, badge: .limited, hovered: true))
        ]
        let reminders = ProcessInfo.processInfo.environment["WINDOWS_BOT_VARIANTS"] == "reminders"
        if reminders {
            states = [
                ("card-done", BotState(card: .done)), ("card-long-done", BotState(card: .longDone)),
                ("card-reset", BotState(card: .reset)),
                ("card-asking", BotState(look: .permission)),
                ("card-question", BotState(look: .question)), ("card-plan", BotState(look: .plan))
            ]
        }
        for vendor in AgentArtwork.allVendors {
            for light in [false, true] {
                guard let form = BotForm.form(for: vendor, ground: light ? .light : .dark) else { continue }
                for (name, state) in states {
                    var motion = BotMotion(seed: 7); motion.fit(form.spec); motion.period = 3
                    if reminders { motion.staysBot = true; motion.arrivesAfter = BotMark.arrival }
                    motion.set(state, at: 0)
                    if name == "failed" { motion.play(.failed, at: 0) }
                    if name == "limited" { motion.play(.limitHit, at: 0) }
                    var frames: [[String: Any]] = []
                    let duration = name == "idle" ? 40.0 : name == "asleep" ? 6.0 : 8.0
                    for index in 0..<Int(duration * 24) {
                        let time = Double(index) / 24
                        motion.step(to: time, aim: .zero)
                        guard let image = BotRenderer.image(form, motion: motion, side: 64, outline: 0,
                                                           space: CGColorSpace(name: CGColorSpace.sRGB)),
                              let bytes = image.dataProvider?.data as Data? else { throw NSError(domain: "BotExport", code: 1) }
                        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        if seen.insert(hash).inserted {
                            let bitmap = NSBitmapImageRep(cgImage: image)
                            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "BotExport", code: 2) }
                            try png.write(to: images.appendingPathComponent(hash + ".png"))
                        }
                        let pose = motion.pose
                        frames.append(["image": hash, "pose": [pose.x, pose.y, pose.rotation, pose.scaleX, pose.scaleY, pose.footing],
                                       "opacity": motion.opacity, "rest": motion.restsAsLogo])
                    }
                    clips.append(["vendor": vendor, "light": light, "state": name, "fps": 24, "frames": frames])
                }
                print("Exported original bots: \(vendor) light=\(light)")
            }
        }
        let manifest: [String: Any] = ["version": 1, "markSide": 64, "margin": 0.3,
            "upstreamRevision": "bf19ac98da11fe0f5967f5a124d42f0da4bf2cf9", "clips": clips]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        print("Original bot frames: \(seen.count) unique images, \(clips.count) clips")
    }
}

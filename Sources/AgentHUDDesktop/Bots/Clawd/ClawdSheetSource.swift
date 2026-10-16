import Foundation

/// Where Clawd's sprites come from: `clawd-sprites.json` in Agent HUD's resources, the Claude app's own sprites of
/// the ones the clips play, which `scripts/clawd-sprites.py` copies out of the app's game by hand.
///
/// The file is decoded once a launch, away from the main thread. If it does not read the way it should, or its
/// sprites do not fit the clips, there is no sheet at all, and Clawd is drawn the way Agent HUD draws it.
final class ClawdSheetSource: Sendable {
    static let shared = ClawdSheetSource()

    /// The sheet Agent HUD bundles.
    static let bundled = AppResources.bundle.url(forResource: "clawd-sprites", withExtension: "json")

    private let file: URL?
    private let store = Store()

    init(file: URL? = ClawdSheetSource.bundled) {
        self.file = file
    }

    /// The sprites, decoded the first time anyone asks; nil when the file does not read or does not fit `clips`.
    func sheet(fitting clips: ClawdClips = .standard) async -> ClawdSheet? {
        guard let file else { return nil }
        let sheet = await store.sheet { Self.sheet(at: file) }
        return sheet.flatMap { clips.fit($0) ? $0 : nil }
    }

    /// The sprites of the sheet at `file`, read here and now.
    static func sheet(at file: URL) -> ClawdSheet? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ClawdSpriteTable.sheet(in: [UInt8](data))
    }

    /// One decoding, shared by everyone who asks while it runs and after.
    private actor Store {
        private var decoding: Task<ClawdSheet?, Never>?

        func sheet(decode: @escaping @Sendable () -> ClawdSheet?) async -> ClawdSheet? {
            if let decoding { return await decoding.value }
            let task = Task.detached(priority: .utility) { decode() }
            decoding = task
            return await task.value
        }
    }
}

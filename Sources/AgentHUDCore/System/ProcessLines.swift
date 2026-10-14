import Foundation

/// A listing of this user's processes, one to a line, as `ps` prints it.
///
/// On a busy Mac it runs to half a megabyte, and whoever reads it is looking for the two or three lines of one client's
/// own service. Those lines are found by searching the listing's bytes; only they become strings for the reader to
/// take apart.
enum ProcessLines {
    /// The lines that contain one of `words`, in the listing's order. Letters match whatever their case; the words are
    /// plain ASCII without a line break.
    static func mentioning(_ words: [String], in listing: String) -> [String] {
        let words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        // ASCII case folding only: the words are plain ASCII, and no locale folds another byte into an ASCII letter.
        func fold(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte &+ 32 : byte }
        let needles = words.map { Array($0.utf8).map(fold) }
        var lines: [String] = []
        var line = [UInt8]()
        func keep() {
            if needles.contains(where: { matches(line, $0) }) {
                lines.append(String(decoding: line, as: UTF8.self))
            }
        }
        for byte in listing.utf8 {
            if byte == 0x0A {
                keep()
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        keep()
        return lines
    }

    /// Whether the folded bytes of `needle` appear anywhere in the folded `line`.
    private static func matches(_ line: [UInt8], _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, line.count >= needle.count else { return false }
        var start = 0
        while start + needle.count <= line.count {
            if fold(line[start]) == first {
                var offset = 1
                while offset < needle.count, fold(line[start + offset]) == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            start += 1
        }
        return false
    }
}

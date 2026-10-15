import Foundation

/// A listing of this user's processes, one to a line, as `ps` prints it.
///
/// On a busy Mac it runs to half a megabyte, and whoever reads it is looking for the two or three lines of one client's
/// own service. Those lines are found by searching the listing's bytes; only they become strings for the reader to
/// take apart.
enum ProcessLines {
    /// Folded ASCII, by byte: uppercase becomes lowercase, every other byte stays. The words are plain ASCII, and no
    /// locale folds another byte into an ASCII letter.
    private static let folded: [UInt8] = (0...255).map { byte in (65...90).contains(byte) ? byte + 32 : byte }

    /// The lines that contain one of `words`, in the listing's order. Letters match whatever their case; the words are
    /// plain ASCII without a line break.
    static func mentioning(_ words: [String], in listing: String) -> [String] {
        let words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let bytes = Array(listing.utf8)
        var found: [(start: Int, end: Int)] = []
        for word in words {
            let needle = word.utf8.map { Self.folded[Int($0)] }
            var cursor = 0
            while let hit = Self.hit(of: needle, in: bytes, from: cursor) {
                // The line around the hit, whole; the scan resumes after it, so a line matches a word at most once.
                var lineStart = hit
                while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
                var lineEnd = hit
                while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                found.append((lineStart, lineEnd))
                cursor = lineEnd + 1
            }
        }
        return found.sorted { $0.start < $1.start }.map { String(decoding: bytes[$0.start..<$0.end], as: UTF8.self) }
    }

    /// The offset of the folded `needle` in `bytes` at or after `from`: a scan that steps by its first folded byte,
    /// confirmed by its second, so the whole comparison runs only where both already agree.
    private static func hit(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard needle.first != nil, start + needle.count <= bytes.count else { return nil }
        let table = folded
        let first = needle[0], second = needle.count > 1 ? needle[1] : nil
        var index = start
        let last = bytes.count - needle.count
        while index <= last {
            if table[Int(bytes[index])] == first, second == nil || table[Int(bytes[index + 1])] == second {
                if needle.count == 1 { return index }
                var offset = 2
                while offset < needle.count, table[Int(bytes[index + offset])] == needle[offset] { offset += 1 }
                if offset == needle.count { return index }
            }
            index += 1
        }
        return nil
    }
}

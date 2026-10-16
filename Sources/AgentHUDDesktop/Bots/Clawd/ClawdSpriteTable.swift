import Foundation

/// Reads Clawd's sprites the way Clawd Quest, the Claude app's game, writes its sprite table, one literal a sprite:
///
///     Walking:{cat:"Core",w:24,h:18,fps:12,palette:["#141413",…],base:"…",deltas:"…".split("("),a0:[0,2,24,16],standMatch:1}
///
/// Agent HUD bundles the sprites its clips play as JSON, which `scripts/clawd-sprites.py` copies out of the game's
/// script: the nine fields it reads, each value unchanged, and the deltas always a list. JSON is a literal of the same kind, and the
/// reader takes the game's own literals too, in any key order; a sprite that does not read is passed over.
///
/// A sprite's frames are kept as the game keeps them: `base` is the first frame, one base-36 palette index per pixel
/// row by row, `.` where nothing is drawn; each of `deltas` makes the next frame from the one before, as
/// comma-separated changes `PPPV`, a base-36 pixel number and its new value.
enum ClawdSpriteTable {
    /// The sheet in `file`, as Agent HUD bundles it: `{"claude": version, "sprites": {name: sprite, …}}`, the version
    /// of the Claude app the sprites come from and the sprites by name. Nil when the file is not one.
    static func sheet(in file: [UInt8]) -> ClawdSheet? {
        var reader = Reader(bytes: file, at: 0)
        guard case .object(let fields)? = reader.value(), let version = fields["claude"]?.text,
              case .object(let table)? = fields["sprites"]
        else { return nil }
        var sprites: [String: ClawdSprite] = [:]
        for (name, value) in table {
            guard case .object(let fields) = value, let sprite = sprite(named: name, fields) else { continue }
            sprites[name] = sprite
        }
        return ClawdSheet(version: version, sprites: sprites)
    }

    /// A sprite out of its object's fields, decoded into frames; nil when anything it needs is missing or wrong.
    static func sprite(named name: String, _ fields: [String: Value]) -> ClawdSprite? {
        guard let width = fields["w"]?.integer, let height = fields["h"]?.integer, width > 0, height > 0,
              width * height <= 1 << 16,
              case .array(let colors)? = fields["palette"], !colors.isEmpty, colors.count <= 36,
              case .string(let base)? = fields["base"],
              case .array(let deltaValues)? = fields["deltas"]
        else { return nil }
        let palette = colors.compactMap { $0.text.flatMap(color(from:)) }
        let deltas = deltaValues.compactMap(\.text)
        guard palette.count == colors.count, deltas.count == deltaValues.count,
              let frames = frames(base: base, deltas: deltas, pixels: width * height, colors: palette.count)
        else { return nil }
        // The game stands every frame on the bottom centre of `a0`, or of the whole sprite when the box is empty.
        var box = [0, 0, width, height]
        if case .array(let values)? = fields["a0"] {
            let numbers = values.compactMap(\.integer)
            if numbers.count == 4, numbers[2] > 0 { box = numbers }
        }
        let fps = fields["fps"]?.integer ?? 12
        return ClawdSprite(name: name, category: fields["cat"]?.text ?? "", width: width, height: height,
                           fps: fps > 0 ? fps : 12, palette: palette, frames: frames,
                           anchor: (box[0] + box[2] / 2, box[1] + box[3]), standMatch: fields["standMatch"]?.truthy ?? false)
    }

    /// The frames `base` and `deltas` make, or nil if any pixel or index is out of range.
    static func frames(base: String, deltas: [String], pixels: Int, colors: Int) -> [[UInt8]]? {
        var frame: [UInt8] = []
        frame.reserveCapacity(pixels)
        for character in base.utf8 {
            guard let index = index(character, colors: colors) else { return nil }
            frame.append(index)
        }
        guard frame.count == pixels else { return nil }
        var frames = [frame]
        for delta in deltas {
            for change in delta.utf8.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: true) {
                // The game reads a change too short to name a pixel as no change at all.
                guard change.count >= 2 else { continue }
                var pixel = 0
                for digit in change.dropLast() {
                    guard let value = digit36(digit) else { return nil }
                    pixel = pixel * 36 + value
                    guard pixel < pixels else { return nil }
                }
                guard let last = change.last, let index = index(last, colors: colors) else { return nil }
                frame[pixel] = index
            }
            frames.append(frame)
        }
        return frames
    }

    /// The palette index a character stands for: `.` for nothing drawn, otherwise a base-36 digit.
    private static func index(_ character: UInt8, colors: Int) -> UInt8? {
        if character == UInt8(ascii: ".") { return ClawdSprite.clear }
        guard let value = digit36(character), value < colors else { return nil }
        return UInt8(value)
    }

    private static func digit36(_ character: UInt8) -> Int? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(character - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(character - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(character - UInt8(ascii: "A")) + 10
        default: nil
        }
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`.
    static func color(from text: String) -> ClawdSprite.Color? {
        guard text.hasPrefix("#") else { return nil }
        var digits = Array(text.utf8.dropFirst()).compactMap { digit36($0).flatMap { $0 < 16 ? UInt8($0) : nil } }
        guard digits.count == text.utf8.count - 1 else { return nil }
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        if digits.count == 6 { digits += [15, 15] }
        guard digits.count == 8 else { return nil }
        let channel = { (at: Int) in digits[at] << 4 | digits[at + 1] }
        return ClawdSprite.Color(red: channel(0), green: channel(2), blue: channel(4), alpha: channel(6))
    }

    // MARK: Literals

    /// A JavaScript literal, as far as a sprite table writes them.
    indirect enum Value {
        case string(String), number(Double), bool(Bool), array([Value]), object([String: Value])
        /// Any other expression, read past without being understood.
        case other

        var text: String? { if case .string(let text) = self { text } else { nil } }
        var integer: Int? {
            guard case .number(let number) = self, number.rounded() == number, abs(number) < 1e9 else { return nil }
            return Int(number)
        }
        var truthy: Bool? {
            switch self {
            case .bool(let value): value
            case .number(let number): number != 0
            default: nil
            }
        }
    }

    /// Reads one literal from `at`, leaving `at` just past it.
    struct Reader {
        let bytes: [UInt8]
        var at: Int

        static func isName(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "$"): true
            default: false
            }
        }

        private var next: UInt8? { at < bytes.count ? bytes[at] : nil }

        private mutating func skipSpace() {
            while let byte = next, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { at += 1 }
        }

        private mutating func take(_ byte: UInt8) -> Bool {
            skipSpace()
            guard next == byte else { return false }
            at += 1
            return true
        }

        /// The literal at `at`, or nil where the script stops being one a table could hold.
        mutating func value() -> Value? {
            skipSpace()
            guard let byte = next else { return nil }
            switch byte {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"):
                guard let text = string() else { return nil }
                return split(text)
            case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
            case UInt8(ascii: "!"):
                // Minified true and false.
                at += 1
                guard case .number(let number)? = number() else { return nil }
                return .bool(number == 0)
            default:
                let start = at
                while let byte = next, Self.isName(byte) { at += 1 }
                switch String(decoding: bytes[start..<at], as: UTF8.self) {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "": return nil
                default: return skipRest()
                }
            }
        }

        private mutating func object() -> Value? {
            at += 1
            var fields: [String: Value] = [:]
            while true {
                if take(UInt8(ascii: "}")) { return .object(fields) }
                skipSpace()
                guard let key = key(), take(UInt8(ascii: ":")), let value = value() else { return nil }
                fields[key] = value
                if take(UInt8(ascii: ",")) { continue }
                return take(UInt8(ascii: "}")) ? .object(fields) : nil
            }
        }

        private mutating func key() -> String? {
            guard let byte = next else { return nil }
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") { return string() }
            let start = at
            while let byte = next, Self.isName(byte) { at += 1 }
            return at > start ? String(decoding: bytes[start..<at], as: UTF8.self) : nil
        }

        private mutating func array() -> Value? {
            at += 1
            var values: [Value] = []
            while true {
                if take(UInt8(ascii: "]")) { return .array(values) }
                guard let value = value() else { return nil }
                values.append(value)
                if take(UInt8(ascii: ",")) { continue }
                return take(UInt8(ascii: "]")) ? .array(values) : nil
            }
        }

        private mutating func string() -> String? {
            guard let quote = next else { return nil }
            at += 1
            var text: [UInt8] = []
            while let byte = next {
                at += 1
                if byte == quote { return String(decoding: text, as: UTF8.self) }
                // A template with a placeholder in it is code, not text.
                if quote == UInt8(ascii: "`"), byte == UInt8(ascii: "$"), next == UInt8(ascii: "{") { return nil }
                guard byte == UInt8(ascii: "\\") else { text.append(byte); continue }
                guard let escaped = next else { return nil }
                at += 1
                switch escaped {
                case UInt8(ascii: "n"): text.append(0x0A)
                case UInt8(ascii: "t"): text.append(0x09)
                case UInt8(ascii: "r"): text.append(0x0D)
                case UInt8(ascii: "0"): text.append(0)
                case UInt8(ascii: "x"):
                    guard let code = hex(count: 2) else { return nil }
                    text += Array(String(UnicodeScalar(UInt8(code))).utf8)
                case UInt8(ascii: "u"):
                    guard let code = hex(count: 4), let scalar = UnicodeScalar(code) else { return nil }
                    text += Array(String(scalar).utf8)
                case 0x0A: break
                default: text.append(escaped)
                }
            }
            return nil
        }

        private mutating func hex(count: Int) -> UInt32? {
            guard at + count <= bytes.count else { return nil }
            var code: UInt32 = 0
            for _ in 0..<count {
                guard let digit = digit36(bytes[at]), digit < 16 else { return nil }
                code = code * 16 + UInt32(digit)
                at += 1
            }
            return code
        }

        /// A string, or the pieces of one split by a separator: `"a(b".split("(")`.
        private mutating func split(_ text: String) -> Value? {
            let start = at
            let call = Array(".split(".utf8)
            skipSpace()
            guard at + call.count <= bytes.count, Array(bytes[at..<(at + call.count)]) == call else {
                at = start
                skipSpace()
                // Any other method called on the string makes it something this cannot tell.
                return next == UInt8(ascii: ".") ? skipRest() : .string(text)
            }
            at += call.count
            skipSpace()
            guard let separator = string(), !separator.isEmpty, take(UInt8(ascii: ")")) else { return nil }
            return .array(text.components(separatedBy: separator).map(Value.string))
        }

        private mutating func number() -> Value? {
            let start = at
            if next == UInt8(ascii: "-") { at += 1 }
            while let byte = next, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
                || ((byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")) && at > start
                    && (bytes[at - 1] == UInt8(ascii: "e") || bytes[at - 1] == UInt8(ascii: "E"))) {
                at += 1
            }
            guard let number = Double(String(decoding: bytes[start..<at], as: UTF8.self)) else { return nil }
            return .number(number)
        }

        /// Passes over an expression this does not read, up to the comma or bracket that ends it.
        private mutating func skipRest() -> Value? {
            var depth = 0
            while let byte = next {
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"):
                    guard string() != nil else { return nil }
                    continue
                case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                    if depth == 0 { return .other }
                    depth -= 1
                case UInt8(ascii: ","): if depth == 0 { return .other }
                default: break
                }
                at += 1
            }
            return nil
        }
    }
}

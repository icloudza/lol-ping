import Foundation

/// A parsed JSON value, with JavaScript's idea of one: every number is a double, and a repeated key keeps its last value.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// `Number.isSafeInteger`: a whole number that a double holds exactly.
    var safeInteger: Int? {
        guard case .number(let n) = self, n.rounded(.towardZero) == n, abs(n) <= 9_007_199_254_740_991 else { return nil }
        return Int(n)
    }

    /// `Number.isInteger`, as an Int when it fits one.
    var integer: Int? {
        guard case .number(let n) = self, n.isFinite, n.rounded(.towardZero) == n, abs(n) < 9.0e18 else { return nil }
        return Int(n)
    }
}

/// A strict JSON reader and writer that agree with JavaScript's `JSON.parse` and `JSON.stringify` on everything room
/// messages and Nostr events contain. Foundation's JSONSerialization differs in the details that validation depends
/// on (booleans are numbers, long decimals lose precision, repeated keys), so the wire format doesn't go through it.
enum JSON {
    /// Deeper than anything we read, and shallow enough that a hostile message can't overflow the stack.
    private static let maxDepth = 512

    /// The value, or nil for anything `JSON.parse` would throw on.
    static func parse(_ text: String) -> JSONValue? {
        var p = Parser(bytes: Array(text.utf8))
        return p.parseDocument()
    }

    /// What `new TextDecoder('utf-8', { fatal: true }).decode(bytes)` followed by `JSON.parse` gives: nil for bytes
    /// that aren't UTF-8, with a leading byte order mark dropped.
    static func parse(utf8 bytes: [UInt8]) -> JSONValue? {
        guard isUTF8(bytes) else { return nil }
        let hasBOM = bytes.count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf
        var p = Parser(bytes: hasBOM ? Array(bytes[3...]) : bytes)
        return p.parseDocument()
    }

    static func isUTF8(_ bytes: [UInt8]) -> Bool {
        var decoder = UTF8()
        var it = bytes.makeIterator()
        while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    /// A string as `JSON.stringify` writes it: quotes, backslashes and control characters escaped, the rest as is.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0c: out += "\\f"
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    /// A number as `JSON.stringify` writes it, for the values we send: whole numbers without a fraction, the others
    /// in their shortest form, and `null` for what JSON can't hold.
    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "null" }
        if v == v.rounded(.towardZero), abs(v) < 1e15 { return String(Int(v)) }
        return "\(v)"
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseDocument() -> JSONValue? {
            skipSpace()
            guard let v = value(depth: 0) else { return nil }
            skipSpace()
            return i == bytes.count ? v : nil
        }

        private mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0a || bytes[i] == 0x0d { i += 1 }
        }

        private mutating func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { return false }
            i += w.count
            return true
        }

        private mutating func value(depth: Int) -> JSONValue? {
            guard i < bytes.count, depth < JSON.maxDepth else { return nil }
            switch bytes[i] {
            case 0x7b: // {
                i += 1
                var out: [String: JSONValue] = [:]
                skipSpace()
                if i < bytes.count, bytes[i] == 0x7d {
                    i += 1
                    return .object(out)
                }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == 0x22, let key = string() else { return nil }
                    skipSpace()
                    guard i < bytes.count, bytes[i] == 0x3a else { return nil }
                    i += 1
                    skipSpace()
                    guard let v = value(depth: depth + 1) else { return nil }
                    out[key] = v
                    skipSpace()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == 0x2c {
                        i += 1
                        continue
                    }
                    guard bytes[i] == 0x7d else { return nil }
                    i += 1
                    return .object(out)
                }
            case 0x5b: // [
                i += 1
                var out: [JSONValue] = []
                skipSpace()
                if i < bytes.count, bytes[i] == 0x5d {
                    i += 1
                    return .array(out)
                }
                while true {
                    skipSpace()
                    guard let v = value(depth: depth + 1) else { return nil }
                    out.append(v)
                    skipSpace()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == 0x2c {
                        i += 1
                        continue
                    }
                    guard bytes[i] == 0x5d else { return nil }
                    i += 1
                    return .array(out)
                }
            case 0x22:
                return string().map { .string($0) }
            case 0x74:
                return literal("true") ? .bool(true) : nil
            case 0x66:
                return literal("false") ? .bool(false) : nil
            case 0x6e:
                return literal("null") ? .null : nil
            default:
                return number()
            }
        }

        private mutating func number() -> JSONValue? {
            let start = i
            func digit(_ k: Int) -> Bool { k < bytes.count && bytes[k] >= 0x30 && bytes[k] <= 0x39 }
            if i < bytes.count, bytes[i] == 0x2d { i += 1 }
            guard digit(i) else { return nil }
            if bytes[i] == 0x30 {
                i += 1
            } else {
                while digit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == 0x2e {
                i += 1
                guard digit(i) else { return nil }
                while digit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                i += 1
                if i < bytes.count, bytes[i] == 0x2b || bytes[i] == 0x2d { i += 1 }
                guard digit(i) else { return nil }
                while digit(i) { i += 1 }
            }
            // Correctly rounded, like JavaScript; out of range gives infinity, which every check that follows rejects.
            guard let v = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { return nil }
            return .number(v)
        }

        private func hex4(at k: Int) -> UInt32? {
            guard k + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for b in bytes[k..<k + 4] {
                switch b {
                case 0x30...0x39: v = v << 4 | UInt32(b - 0x30)
                case 0x41...0x46: v = v << 4 | UInt32(b - 0x41 + 10)
                case 0x61...0x66: v = v << 4 | UInt32(b - 0x61 + 10)
                default: return nil
                }
            }
            return v
        }

        private mutating func string() -> String? {
            i += 1 // the opening quote
            var out: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x22 {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b < 0x20 { return nil }
                if b != 0x5c {
                    out.append(b)
                    i += 1
                    continue
                }
                guard i + 1 < bytes.count else { return nil }
                i += 2
                switch bytes[i - 1] {
                case 0x22: out.append(0x22)
                case 0x5c: out.append(0x5c)
                case 0x2f: out.append(0x2f)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0c)
                case 0x6e: out.append(0x0a)
                case 0x72: out.append(0x0d)
                case 0x74: out.append(0x09)
                case 0x75:
                    guard var code = hex4(at: i) else { return nil }
                    i += 4
                    if (0xd800...0xdbff).contains(code), i + 6 <= bytes.count, bytes[i] == 0x5c, bytes[i + 1] == 0x75,
                       let low = hex4(at: i + 2), (0xdc00...0xdfff).contains(low) {
                        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
                        i += 6
                    }
                    // A lone surrogate is a legal JavaScript string but not a Swift one: it becomes U+FFFD.
                    let scalar = Unicode.Scalar(code) ?? "\u{fffd}"
                    out.append(contentsOf: Array(String(scalar).utf8))
                default:
                    return nil
                }
            }
            return nil
        }
    }
}

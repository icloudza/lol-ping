import Foundation

public enum Names {
    public static let maxName = 16

    // C0/C1 controls, zero-width characters, bidi marks, embeddings and isolates, BOM, line/paragraph separators,
    // soft hyphen, combining grapheme joiner, Arabic letter mark, Mongolian vowel separator and the Hangul fillers
    // (blank characters that would make a name invisible).
    private static func isUnsafe(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0000...0x001f, 0x007f...0x009f, 0x00ad, 0x034f, 0x061c, 0x115f, 0x1160, 0x180e,
             0x200b...0x200f, 0x2028...0x202e, 0x2060...0x2069, 0x3164, 0xfeff, 0xffa0:
            return true
        default:
            return false
        }
    }

    // What JavaScript's String.prototype.trim removes.
    private static func isJSWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
            return true
        default:
            return false
        }
    }

    private static func trim(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var slice = scalars[...]
        while let f = slice.first, isJSWhitespace(f) { slice = slice.dropFirst() }
        while let l = slice.last, isJSWhitespace(l) { slice = slice.dropLast() }
        return Array(slice)
    }

    /// While typing: at most `maxName` code points (an emoji counts once).
    public static func clampInput(_ v: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: v.unicodeScalars.prefix(maxName))
        return String(out)
    }

    /// A display name that can't hide, reorder or break the text around it. `max` is in code points.
    public static func sanitize(_ raw: String, fallback: String = "Player", max: Int = maxName) -> String {
        let cleaned = trim(raw.unicodeScalars.filter { !isUnsafe($0) })
        let cut = trim(Array(cleaned.prefix(max)))
        if cut.isEmpty { return fallback }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: cut)
        return String(view)
    }
}

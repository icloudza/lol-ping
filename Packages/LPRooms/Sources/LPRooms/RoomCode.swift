import Foundation

public enum RoomCodeError: Equatable, Sendable {
    case invalid
    case mistyped
}

public enum RoomCode {
    /// Crockford base32: no I, L, O or U, so a code read out loud can't be misheard as another.
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let index = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    private static let codeLength = 10
    private static let prefix = "P1NG" // "PING" after I→1
    /// Pasted chat messages are scanned for a code; anything longer is cut first.
    private static let maxInput = 2000

    /// Luhn mod 32 over the 9 random characters: catches every single-character error and most swaps.
    public static func checkChar(_ nine: String) -> Character {
        var factor = 2
        var sum = 0
        for ch in nine.reversed() {
            var addend = factor * (index[ch] ?? -1)
            factor = factor == 2 ? 1 : 2
            addend = Int((Double(addend) / 32).rounded(.down)) + addend % 32
            sum += addend
        }
        return alphabet[(32 - (sum % 32)) % 32]
    }

    /// The canonical code (10 characters, no prefix) from 9 random bytes.
    public static func make(random9: [UInt8]) -> String {
        let nine = String(random9.prefix(9).map { alphabet[Int($0 & 31)] })
        return nine + String(checkChar(nine))
    }

    /// PING-XXXXX-XXXXX.
    public static func format(_ canonical: String) -> String {
        "PING-\(canonical.prefix(5))-\(canonical.dropFirst(5))"
    }

    private static func valid(_ code: String) -> Bool { checkChar(String(code.prefix(9))) == code.last }
    private static func isCodeShaped(_ c: String) -> Bool { c.count == codeLength && c.allSatisfy { index[$0] != nil } }

    /// Look-alike letters read as the digits they resemble: O→0, I/L→1.
    private static func mapLookalikes(_ t: String) -> String {
        String(t.uppercased().map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 })
    }

    private struct Token {
        /// After look-alike mapping, dashes removed.
        let text: String
        /// Typed with at least one real digit: ordinary words never are, real codes almost always are.
        let digit: Bool
    }

    private static func isTokenChar(_ c: Character) -> Bool {
        guard let a = c.asciiValue, c.unicodeScalars.count == 1 else { return false }
        return (a >= 0x30 && a <= 0x39) || (a >= 0x41 && a <= 0x5a) || (a >= 0x61 && a <= 0x7a) || a == 0x2d
    }

    /// Finds a room code in what the user typed or pasted. Most trusted first:
    /// 1. A PING code anywhere, split only where the display form splits it (PING-XXXXX-XXXXX, PING XXXXX XXXXX, …).
    /// 2. A lone 10-character token. Inside longer text it must contain a real digit, so words like STRAWBERRY don't count.
    /// 3. The whole input being one code, however it is spaced. With spaces it needs a real digit too ("hello there").
    /// `strict` (the clipboard, read without the user typing anything) accepts only 1, or a clipboard that is just a code.
    /// Neighbouring words are never glued onto a code: that made ordinary chat read as codes.
    public static func parse(_ text: String, strict: Bool = false) -> Result<String, RoomCodeError> {
        // JavaScript's slice counts UTF-16 units.
        let cut = String(decoding: Array(text.utf16.prefix(maxInput)), as: UTF16.self)
        let tokens: [Token] = cut.split(whereSeparator: { !isTokenChar($0) })
            .map { $0.filter { $0 != "-" } }
            .filter { !$0.isEmpty }
            .map { Token(text: mapLookalikes(String($0)), digit: $0.contains { $0.isASCII && $0.isNumber }) }
        var mistyped = false
        func tryCode(_ c: String, countsAsTypo: Bool) -> String? {
            guard isCodeShaped(c) else { return nil }
            if valid(c) { return c }
            if countsAsTypo { mistyped = true }
            return nil
        }

        // 1. PING codes: the token boundaries must fall where the display form's do (after PING, and after 5 more).
        let stops = [prefix.count, prefix.count + 5, prefix.count + codeLength]
        for i in tokens.indices where tokens[i].text.hasPrefix(prefix) {
            var joined = ""
            for j in i..<tokens.count {
                joined += tokens[j].text
                if !stops.contains(joined.count) { break }
                if joined.count == prefix.count + codeLength {
                    if let code = tryCode(String(joined.dropFirst(prefix.count)), countsAsTypo: true) { return .success(code) }
                    break
                }
            }
        }

        // The whole input as one code (also the strict mode's "clipboard is just a code"). Spaced, or read from the
        // clipboard, it needs a real digit: typing it is deliberate, a clipboard word that happens to pass isn't.
        let whole = tokens.map(\.text).joined()
        let wholeDigit = tokens.contains { $0.digit }
        if strict ? (tokens.count == 1 && wholeDigit) : (tokens.count == 1 || wholeDigit) {
            let candidate = whole.hasPrefix(prefix) && whole.count == prefix.count + codeLength ? String(whole.dropFirst(prefix.count)) : whole
            if let code = tryCode(candidate, countsAsTypo: true) { return .success(code) }
        }
        if !strict {
            // 2. A lone token inside longer text.
            for t in tokens where t.digit {
                if let code = tryCode(t.text, countsAsTypo: false) { return .success(code) }
            }
        }
        return .failure(mistyped ? .mistyped : .invalid)
    }
}

extension RoomCodeError: Error {}

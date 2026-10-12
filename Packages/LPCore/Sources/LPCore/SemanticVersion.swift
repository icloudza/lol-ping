import Foundation

/// A release number such as 1.4.0, read from "1.4.0" or a tag like "v1.4.0". Pre-release suffixes are not understood:
/// a string with one is not a version, so it is never offered as an update.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ text: String) {
        var body = Substring(text)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

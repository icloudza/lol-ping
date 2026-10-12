import Foundation

/// A bundled emote's slug, or "c:" + 32 lower-case hex characters (the hash of an imported emote).
public typealias EmoteRef = String

/// The ids that travel in room messages. They are the protocol's vocabulary, shared with every other client,
/// so they live here rather than with the app's own catalogue.
public enum RoomWire {
    /// Every ping a `ping` message may name.
    public static let pingIds = [
        "danger", "push", "omw", "allin", "assist", "needvision", "missing", "enemyvision", "generic", "bait", "visioncleared",
    ]
    private static let pingIdSet = Set(pingIds)

    public static func isPingId(_ id: String) -> Bool { pingIdSet.contains(id) }

    private static func isSlug(_ s: String) -> Bool {
        let u = s.utf8
        return (1...40).contains(u.count) && u.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5f }
    }

    public static func isCustomEmoteRef(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return u.count == 34 && u[0] == 0x63 && u[1] == 0x3a
            && u[2...].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Well-formed, whether or not it exists here. Messages are checked against this before anything looks the emote up.
    public static func isEmoteRef(_ s: String) -> Bool { isSlug(s) || isCustomEmoteRef(s) }

    private static func plainVersion(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard (1...9).contains(p.utf8.count), p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// True only when `app` is a plain x.y.z version lower than `version`: anything else (a dev tool, a prerelease) isn't called old.
    public static func isOlder(_ app: String, than version: String) -> Bool {
        guard let a = plainVersion(app), let v = plainVersion(version) else { return false }
        for i in 0..<3 where a[i] != v[i] { return a[i] < v[i] }
        return false
    }
}

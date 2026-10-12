import Foundation

/// One kind of ping: which pictures and sound it uses, and the colour of its glow.
public struct Ping: Identifiable, Hashable, Sendable {
    /// Also the name the ping goes by in a room message.
    public let id: String
    /// The picture on its wheel slot (a file in Resources/textures, without the extension).
    public let badge: String
    /// What appears on screen when it is sent. Two pictures means two halves that slam together.
    public let art: [String]
    /// A file in Resources/sounds, without the extension.
    public let sound: String
    /// 0xRRGGBB.
    public let tint: UInt32

    public var isTwoPart: Bool { art.count > 1 }
}

public enum PingCatalog {
    public static let all: [Ping] = [
        Ping(id: "danger", badge: "pingwheel_retreatrender", art: ["pingwheel_retreatrender"], sound: "SRP_12", tint: 0xff3b55),
        Ping(id: "push", badge: "push", art: ["pingwheel_pushrender"], sound: "SRP_9", tint: 0x35d27a),
        Ping(id: "omw", badge: "omw", art: ["omw"], sound: "OnMyWay", tint: 0x2e8bff),
        Ping(id: "allin", badge: "all_in", art: ["pingwheel_allin_render_01", "pingwheel_allin_render_02"], sound: "SRP_4", tint: 0xf2b320),
        Ping(id: "assist", badge: "assist_me", art: ["assist_me"], sound: "ComeHere", tint: 0x56d43c),
        Ping(id: "needvision", badge: "need_vision", art: ["need_vision"], sound: "SRP_7", tint: 0x56d43c),
        Ping(id: "missing", badge: "enemy_missing", art: ["enemy_missing"], sound: "MIA", tint: 0xf2c518),
        Ping(id: "enemyvision", badge: "pingwheel_enemyvisionrender", art: ["pingwheel_enemyvisionrender"], sound: "AreaIsWarded", tint: 0xff3b55),
        Ping(id: "generic", badge: "generic_ping", art: ["pingwheel_basicpingrender"], sound: "Base", tint: 0x2e8bff),
        Ping(id: "bait", badge: "pingwheel_baitrender", art: ["pingwheel_baitrender"], sound: "SRP_11", tint: 0xefbc12),
        Ping(id: "visioncleared", badge: "vision_cleared", art: ["pingwheel_visionclearedrender"], sound: "SRP_6", tint: 0x2b80ff),
    ]

    /// The ping wheel a fresh install starts with, from the top going clockwise.
    public static let standardWheel = ["danger", "push", "omw", "allin", "assist", "needvision", "missing", "enemyvision"]
    /// What trigger + click sends until the user picks something else.
    public static let standardQuick = "generic"
    /// Pings that are not on the standard wheel: the editor marks them as extras.
    public static let extras: Set<String> = ["bait", "visioncleared"]

    /// The soft click when the pointer crosses onto another slice.
    public static let tickSound = "button"
    /// Drawn in place of a picture that fails to load.
    public static let standInTexture = "generic_ping"

    private static let index = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static subscript(id: String) -> Ping? { index[id] }
    public static func contains(_ id: String) -> Bool { index[id] != nil }
    /// The ping for `id`, or the generic one when the id is unknown (a newer client may send pings this build lacks).
    public static func resolve(_ id: String) -> Ping { index[id] ?? index[standardQuick]! }

    public static var soundNames: [String] { unique(all.map(\.sound) + [tickSound]) }
    public static var textureNames: [String] { unique(all.flatMap { [$0.badge] + $0.art } + [standInTexture]) }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

import Foundation

/// One room message. Every message carries who sent it, its number and the sender's clock.
public struct RoomMessage: Equatable, Sendable {
    /// Random per join, 16 lower-case hex characters.
    public var peer: String
    /// +1 for every message the peer sends.
    public var seq: Int
    /// Sender's clock, ms since epoch.
    public var ts: Int
    public var body: Body

    public enum Body: Equatable, Sendable {
        case presence(proto: Int, app: String, name: String, color: Int, status: MemberStatus)
        /// `d` is a display number (1 = primary); `x` and `y` are fractions of that display, 0–1.
        case ping(id: String, d: Int, x: Double, y: Double)
        /// Added in 0.5.0: older apps drop it as an unknown type. `ref` is a bundled slug (possibly one only a newer
        /// app has) or "c:" + the hash of an imported emote. Position as in a ping.
        case emote(ref: String, d: Int, x: Double, y: Double)
        case bye
    }

    public init(peer: String, seq: Int, ts: Int, body: Body) {
        self.peer = peer
        self.seq = seq
        self.ts = ts
        self.body = body
    }
}

public enum RoomProtocol {
    /// Bumped when room messages change incompatibly. Peers on another version are shown as "needs update".
    public static let version = 1
    private static let maxDisplay = 16
    private static let maxAppVersion = 64

    private static func round4(_ v: Double) -> Double {
        // Math.round(v * 10_000) / 10_000: halves go up. (Adding 0.5 and flooring is wrong just below a half.)
        let scaled = v * 10_000
        let floor = scaled.rounded(.down)
        return (scaled - floor >= 0.5 ? floor + 1 : floor) / 10_000
    }

    /// The JSON upstream's `encodeMessage` writes, key for key: peer, seq, ts, then the type and its fields.
    public static func encode(_ m: RoomMessage) -> Data {
        var out = "{\"peer\":\(JSON.quote(m.peer)),\"seq\":\(m.seq),\"ts\":\(m.ts)"
        switch m.body {
        case .presence(let proto, let app, let name, let color, let status):
            out += ",\"t\":\"presence\",\"proto\":\(proto),\"app\":\(JSON.quote(app)),\"name\":\(JSON.quote(name)),\"color\":\(color),\"status\":\"\(status.rawValue)\""
        case .ping(let id, let d, let x, let y):
            out += ",\"t\":\"ping\",\"ping\":\(JSON.quote(id)),\"d\":\(d),\"x\":\(JSON.number(round4(x))),\"y\":\(JSON.number(round4(y)))"
        case .emote(let ref, let d, let x, let y):
            out += ",\"t\":\"emote\",\"e\":\(JSON.quote(ref)),\"d\":\(d),\"x\":\(JSON.number(round4(x))),\"y\":\(JSON.number(round4(y)))"
        case .bye:
            out += ",\"t\":\"bye\""
        }
        return Data((out + "}").utf8)
    }

    public static func decode(_ bytes: Data) -> RoomMessage? {
        JSON.parse(utf8: [UInt8](bytes)).flatMap(validate)
    }

    private static func isUnit(_ v: JSONValue?) -> Double? {
        guard let n = v?.number, n >= 0, n <= 1 else { return nil }
        return n == 0 ? 0 : n // -0 reads as 0
    }

    private static func display(_ v: JSONValue?) -> Int? {
        guard let d = v?.integer, d >= 1, d <= maxDisplay else { return nil }
        return d
    }

    /// Builds a fresh message from known fields only, or nil when anything is missing or out of range.
    static func validate(_ raw: JSONValue) -> RoomMessage? {
        guard let o = raw.object else { return nil }
        guard let peer = o["peer"]?.string, Hex.isLower(peer, count: 16),
              let seq = o["seq"]?.safeInteger, seq >= 0, let ts = o["ts"]?.safeInteger, ts >= 0 else { return nil }
        let body: RoomMessage.Body
        switch o["t"]?.string {
        case "presence":
            guard let proto = o["proto"]?.safeInteger, proto >= 0,
                  let app = o["app"]?.string, app.utf16.count <= maxAppVersion, let name = o["name"]?.string else { return nil }
            guard let color = o["color"]?.integer, TagColors.isTagColor(color),
                  let status = o["status"]?.string.flatMap(MemberStatus.init(rawValue:)) else { return nil }
            // JavaScript's slice(0, 256) counts UTF-16 units.
            let cut = String(decoding: Array(name.utf16.prefix(256)), as: UTF16.self)
            body = .presence(proto: proto, app: app, name: Names.sanitize(cut), color: color, status: status)
        case "ping":
            guard let ping = o["ping"]?.string, RoomWire.isPingId(ping), let d = display(o["d"]) else { return nil }
            guard let x = isUnit(o["x"]), let y = isUnit(o["y"]) else { return nil }
            body = .ping(id: ping, d: d, x: x, y: y)
        case "emote":
            guard let e = o["e"]?.string, RoomWire.isEmoteRef(e), let d = display(o["d"]) else { return nil }
            guard let x = isUnit(o["x"]), let y = isUnit(o["y"]) else { return nil }
            body = .emote(ref: e, d: d, x: x, y: y)
        case "bye":
            body = .bye
        default:
            return nil
        }
        return RoomMessage(peer: peer, seq: seq, ts: ts, body: body)
    }
}

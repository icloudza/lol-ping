import CLPRoomsCrypto
import CryptoKit
import Foundation

public struct NostrEvent: Equatable, Sendable {
    public var id: String
    public var pubkey: String
    public var createdAt: Int
    public var kind: Int
    public var tags: [[String]]
    public var content: String
    public var sig: String
}

/// A throwaway signing key: relays require a signature, the room's own crypto does the real work.
public struct NostrKeyPair: Equatable, Sendable {
    public let secretKey: [UInt8]
    /// 64 hex characters, x-only, as NIP-01 wants it.
    public let pubkey: String
}

public enum RelayMessage: Equatable, Sendable {
    case event(subId: String, event: NostrEvent)
    case ok(eventId: String, ok: Bool, message: String)
    case eose(subId: String)
    case closed(subId: String, message: String)
    case notice(message: String)
}

public enum Nostr {
    /// Ephemeral (20000–29999): relays forward these to subscribers and don't store them.
    public static let roomEventKind = 24747

    /// BIP-340 Schnorr over secp256k1, as upstream gets from @noble/secp256k1.
    public enum Schnorr {
        /// The x-only public key, or nil when `secretKey` isn't a valid key (zero, or not below the curve order).
        public static func publicKey(_ secretKey: [UInt8]) -> [UInt8]? {
            guard secretKey.count == 32 else { return nil }
            var out = [UInt8](repeating: 0, count: 32)
            return lp_schnorr_pubkey(secretKey, &out) == 1 ? out : nil
        }

        /// `aux` is 32 bytes of fresh randomness (BIP-340's auxiliary data); nil draws them here.
        public static func sign(_ message: [UInt8], secretKey: [UInt8], aux: [UInt8]? = nil) -> [UInt8]? {
            let aux = aux ?? randomBytes(32)
            guard secretKey.count == 32, aux.count == 32 else { return nil }
            var out = [UInt8](repeating: 0, count: 64)
            return lp_schnorr_sign(secretKey, message, message.count, aux, &out) == 1 ? out : nil
        }

        public static func verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
            guard signature.count == 64, publicKey.count == 32 else { return false }
            return lp_schnorr_verify(publicKey, message, message.count, signature) == 1
        }
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }

    public static func makeKeyPair() -> NostrKeyPair {
        // All but about 1 in 2^128 random 32-byte strings are valid keys; the loop is for the rest.
        while true {
            let secret = randomBytes(32)
            if let pub = Schnorr.publicKey(secret) { return NostrKeyPair(secretKey: secret, pubkey: Hex.encode(pub)) }
        }
    }

    private static func tagsJSON(_ tags: [[String]]) -> String {
        "[" + tags.map { "[" + $0.map(JSON.quote).joined(separator: ",") + "]" }.joined(separator: ",") + "]"
    }

    /// NIP-01's canonical form, whose SHA-256 is the event id: [0,pubkey,created_at,kind,tags,content], no spaces.
    public static func serializeEvent(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> String {
        "[0,\(JSON.quote(pubkey)),\(createdAt),\(kind),\(tagsJSON(tags)),\(JSON.quote(content))]"
    }

    /// Nil only if the key pair is broken, which `makeKeyPair` never gives.
    public static func signEvent(_ keys: NostrKeyPair, kind: Int, tags: [[String]], content: String, createdAt: Int) -> NostrEvent? {
        let serialized = serializeEvent(pubkey: keys.pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        let id = Array(SHA256.hash(data: Data(serialized.utf8)))
        guard let sig = Schnorr.sign(id, secretKey: keys.secretKey) else { return nil }
        return NostrEvent(id: Hex.encode(id), pubkey: keys.pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content, sig: Hex.encode(sig))
    }

    public static func reqMessage(subId: String, topic: String, since: Int) -> String {
        "[\"REQ\",\(JSON.quote(subId)),{\"kinds\":[\(roomEventKind)],\"#x\":[\(JSON.quote(topic))],\"since\":\(since),\"limit\":0}]"
    }

    public static func eventMessage(_ e: NostrEvent) -> String {
        "[\"EVENT\",{\"id\":\(JSON.quote(e.id)),\"pubkey\":\(JSON.quote(e.pubkey)),\"created_at\":\(e.createdAt),\"kind\":\(e.kind),"
            + "\"tags\":\(tagsJSON(e.tags)),\"content\":\(JSON.quote(e.content)),\"sig\":\(JSON.quote(e.sig))}]"
    }

    public static func closeMessage(subId: String) -> String {
        "[\"CLOSE\",\(JSON.quote(subId))]"
    }

    /// A fresh event with exactly the NIP-01 fields, or nil. Signatures are left to the relays.
    private static func toEvent(_ raw: JSONValue?) -> NostrEvent? {
        guard let e = raw?.object else { return nil }
        guard let id = e["id"]?.string, Hex.isLower(id, count: 64) else { return nil }
        guard let pubkey = e["pubkey"]?.string, Hex.isLower(pubkey, count: 64) else { return nil }
        guard let sig = e["sig"]?.string, Hex.isLower(sig, count: 128) else { return nil }
        guard let createdAt = e["created_at"]?.safeInteger, createdAt >= 0 else { return nil }
        guard let kind = e["kind"]?.safeInteger else { return nil }
        guard let rawTags = e["tags"]?.array, let content = e["content"]?.string else { return nil }
        var tags: [[String]] = []
        for t in rawTags {
            guard let items = t.array else { return nil }
            var tag: [String] = []
            for v in items {
                guard let s = v.string else { return nil }
                tag.append(s)
            }
            tags.append(tag)
        }
        return NostrEvent(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content, sig: sig)
    }

    /// One message from a relay, or nil for anything malformed or that we don't use (AUTH, COUNT, …).
    public static func parseRelayMessage(_ text: String) -> RelayMessage? {
        guard let m = JSON.parse(text)?.array, let type = m.first?.string else { return nil }
        func at(_ i: Int) -> JSONValue? { i < m.count ? m[i] : nil }
        /// A missing trailing string reads as empty; anything else there is malformed.
        func optional(_ v: JSONValue?) -> String? { v == nil ? "" : v?.string }
        switch type {
        case "EVENT":
            guard let subId = at(1)?.string, let event = toEvent(at(2)) else { return nil }
            return .event(subId: subId, event: event)
        case "OK":
            guard let id = at(1)?.string, Hex.isLower(id, count: 64), let ok = at(2)?.bool, let message = optional(at(3)) else { return nil }
            return .ok(eventId: id, ok: ok, message: message)
        case "EOSE":
            return at(1)?.string.map { .eose(subId: $0) }
        case "CLOSED":
            guard let subId = at(1)?.string, let message = optional(at(2)) else { return nil }
            return .closed(subId: subId, message: message)
        case "NOTICE":
            return at(1)?.string.map { .notice(message: $0) }
        default:
            return nil
        }
    }
}

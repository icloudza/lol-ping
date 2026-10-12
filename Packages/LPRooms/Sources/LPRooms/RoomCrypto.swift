import CLPRoomsCrypto
import CryptoKit
import Foundation

public struct RoomKeys: Equatable, Sendable {
    /// Encrypts every room message. 32 bytes; never leaves the process.
    public let msgKey: Data
    /// The relay topic: 64 hex characters that say nothing without the code.
    public let relayTopic: String

    public init(msgKey: Data, relayTopic: String) {
        self.msgKey = msgKey
        self.relayTopic = relayTopic
    }
}

public enum RoomCryptoError: Error, Equatable {
    case derivationFailed
}

public enum RoomCrypto {
    /// Every room packet: format byte, nonce, AES-256-GCM ciphertext and tag. Larger packets are never sent or read.
    public static let maxPacket = 1200
    private static let format: UInt8 = 0x01
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let overhead = 1 + nonceLength + tagLength

    /// scrypt (RFC 7914). Nil for parameters it can't run with, or when the memory (128 · r · N bytes) isn't there.
    public static func scrypt(password: Data, salt: Data, n: Int, r: Int, p: Int, length: Int) -> Data? {
        guard n > 1, r > 0, p > 0, length > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        let pw = [UInt8](password)
        let s = [UInt8](salt)
        let ok = lp_scrypt(pw, pw.count, s, s.count, UInt64(n), UInt32(r), UInt32(p), &out, length)
        return ok == 1 ? Data(out) : nil
    }

    /// Room code → keys. scrypt makes guessing a code from a relay topic impractical; HKDF gives each key one job.
    /// Takes about a tenth of a second and 32 MB: never call it on the main thread (`deriveRoomKeys` doesn't).
    public static func deriveRoomKeysSync(_ canonical: String) throws -> RoomKeys {
        guard let master = scrypt(password: Data(canonical.utf8), salt: Data("lolping/room/v1".utf8), n: 1 << 15, r: 8, p: 1, length: 32) else {
            throw RoomCryptoError.derivationFailed
        }
        func sub(_ info: String) -> Data {
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: Data(), info: Data(info.utf8), outputByteCount: 32)
            return key.withUnsafeBytes { Data($0) }
        }
        // "sig-room" dates from a WebRTC design; kept so the keys, and the test vectors, stay the same.
        return RoomKeys(msgKey: sub("msg"), relayTopic: Hex.encode(sub("sig-room")))
    }

    /// `deriveRoomKeysSync` on a background queue; `completion` runs on `queue`.
    public static func deriveRoomKeys(_ canonical: String, queue: DispatchQueue = .main, completion: @escaping (Result<RoomKeys, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try deriveRoomKeysSync(canonical) }
            queue.async { completion(result) }
        }
    }

    /// The packet, or nil when `plain` doesn't fit in one (upstream throws).
    public static func seal(key: Data, plain: Data) -> Data? {
        guard plain.count + overhead <= maxPacket else { return nil }
        var nonce = [UInt8](repeating: 0, count: nonceLength)
        var rng = SystemRandomNumberGenerator()
        for i in nonce.indices { nonce[i] = UInt8.random(in: .min ... .max, using: &rng) }
        guard let n = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: n, authenticating: [format]) else { return nil }
        var out = Data(capacity: plain.count + overhead)
        out.append(format)
        out.append(contentsOf: nonce)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// The plaintext, or nil for anything that isn't a packet sealed with this key.
    public static func open(key: Data, packet: Data) -> Data? {
        guard packet.count >= overhead, packet.count <= maxPacket, packet.first == format else { return nil }
        let bytes = [UInt8](packet)
        guard let nonce = try? AES.GCM.Nonce(data: bytes[1..<1 + nonceLength]),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: bytes[(1 + nonceLength)..<(bytes.count - tagLength)], tag: bytes[(bytes.count - tagLength)...])
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: [format])
    }
}

enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out: [UInt8] = []
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Nil unless `s` is an even number of hex digits.
    static func decode(_ s: String) -> [UInt8]? {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        func value(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(u.count / 2)
        for i in stride(from: 0, to: u.count, by: 2) {
            guard let hi = value(u[i]), let lo = value(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    /// Lower-case hex of exactly `count` characters: what peer IDs, event ids, keys and signatures must be.
    static func isLower(_ s: String, count: Int) -> Bool {
        let u = s.utf8
        return u.count == count && u.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

import CLPRoomsCrypto
import XCTest
@testable import LPRooms

final class ScryptTests: XCTestCase {
    // RFC 7914 §12, copied from the RFC text.
    func testRFC7914Vectors() {
        let cases: [(String, String, Int, Int, Int, String)] = [
            ("", "", 16, 1, 1,
             "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"),
            ("password", "NaCl", 1024, 8, 16,
             "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"),
            ("pleaseletmein", "SodiumChloride", 16384, 8, 1,
             "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"),
            ("pleaseletmein", "SodiumChloride", 1_048_576, 8, 1,
             "2101cb9b6a511aaeaddbbe09cf70f881ec568d574a2ffd4dabe5ee9820adaa478e56fd8f4ba5d09ffa1c6d927c40f4c337304049e8a952fbcbf45c6fa77a41a4"),
        ]
        for (pw, salt, n, r, p, expected) in cases {
            let out = RoomCrypto.scrypt(password: Data(pw.utf8), salt: Data(salt.utf8), n: n, r: r, p: p, length: 64)
            XCTAssertEqual(out?.hex, expected, "N=\(n) r=\(r) p=\(p)")
        }
    }

    /// The same function as Node's crypto.scryptSync (OpenSSL), on RFC inputs and odd shapes.
    func testMatchesNode() {
        for c in Fixture.list("scrypt.json") {
            let out = RoomCrypto.scrypt(password: Data(hex: c["pw"] as! String), salt: Data(hex: c["salt"] as! String),
                                        n: c["n"] as! Int, r: c["r"] as! Int, p: c["p"] as! Int, length: c["len"] as! Int)
            XCTAssertEqual(out?.hex, c["out"] as? String, "\(c)")
        }
    }

    func testRejectsBadParameters() {
        let d = Data("x".utf8)
        XCTAssertNil(RoomCrypto.scrypt(password: d, salt: d, n: 0, r: 8, p: 1, length: 32))
        XCTAssertNil(RoomCrypto.scrypt(password: d, salt: d, n: 1, r: 8, p: 1, length: 32))
        XCTAssertNil(RoomCrypto.scrypt(password: d, salt: d, n: 1000, r: 8, p: 1, length: 32)) // not a power of two
        XCTAssertNil(RoomCrypto.scrypt(password: d, salt: d, n: 16, r: 0, p: 1, length: 32))
        XCTAssertNil(RoomCrypto.scrypt(password: d, salt: d, n: 16, r: 1, p: 0, length: 32))
        XCTAssertNil(RoomCrypto.scrypt(password: d, salt: d, n: 16, r: 1, p: 1, length: 0))
    }
}

final class RoomCryptoTests: XCTestCase {
    // Upstream's own known-answer test (tests/main/roomCrypto.test.ts): every OS must derive the same keys.
    func testDeriveRoomKeysKnownAnswer() throws {
        let k = try RoomCrypto.deriveRoomKeysSync("0000000000")
        XCTAssertEqual(k.msgKey.hex, "2b8ef59047332409e1662fe75774f9383fcd16b655fcb3db975f0e80ad2043da")
        XCTAssertEqual(k.relayTopic, "0381782f350540d4639958bed594ae3b2b1a3d11683146e542edb34db89b6910")
    }

    /// Keys upstream's deriveRoomKeys gave for these codes.
    func testDeriveRoomKeysMatchesUpstream() throws {
        let cases = Fixture.list("roomKeys.json")
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        for c in cases {
            let k = try RoomCrypto.deriveRoomKeysSync(c["code"] as! String)
            XCTAssertEqual(k.msgKey.hex, c["msgKey"] as? String)
            XCTAssertEqual(k.relayTopic, c["relayTopic"] as? String)
        }
    }

    func testDifferentCodesGiveDifferentKeys() throws {
        XCTAssertNotEqual(try RoomCrypto.deriveRoomKeysSync("0000000000").msgKey, try RoomCrypto.deriveRoomKeysSync("0000000011").msgKey)
    }

    /// Joining must not hang: the derivation has to stay well under a second, in a debug build too.
    func testDerivationIsFastEnough() throws {
        let start = Date()
        _ = try RoomCrypto.deriveRoomKeysSync("0000000000")
        let took = Date().timeIntervalSince(start)
        print("deriveRoomKeysSync took \(Int(took * 1000)) ms")
        XCTAssertLessThan(took, 1.0)
    }

    func testDeriveRoomKeysRunsOffTheCallingThreadAndAnswersOnTheQueue() {
        let done = expectation(description: "derived")
        RoomCrypto.deriveRoomKeys("0000000000") { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual((try? result.get())?.relayTopic, "0381782f350540d4639958bed594ae3b2b1a3d11683146e542edb34db89b6910")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    private let key = Data(repeating: 7, count: 32)
    private let msg = Data("{\"t\":\"bye\"}".utf8)

    func testRoundTrips() {
        let packet = RoomCrypto.seal(key: key, plain: msg)!
        XCTAssertEqual(packet.count, msg.count + 29)
        XCTAssertEqual(packet.first, 1)
        XCTAssertEqual(RoomCrypto.open(key: key, packet: packet), msg)
    }

    func testFreshNonceEveryTime() {
        XCTAssertNotEqual(RoomCrypto.seal(key: key, plain: msg), RoomCrypto.seal(key: key, plain: msg))
    }

    func testRejectsAnyFlippedByte() {
        let packet = RoomCrypto.seal(key: key, plain: msg)!
        for i in 0..<packet.count {
            var bad = packet
            bad[i] ^= 1
            XCTAssertNil(RoomCrypto.open(key: key, packet: bad), "byte \(i)")
        }
    }

    func testRejectsWrongKeyTruncatedAndOversize() {
        let packet = RoomCrypto.seal(key: key, plain: msg)!
        XCTAssertNil(RoomCrypto.open(key: Data(repeating: 8, count: 32), packet: packet))
        XCTAssertNil(RoomCrypto.open(key: key, packet: packet.prefix(20)))
        XCTAssertNil(RoomCrypto.open(key: key, packet: Data()))
        XCTAssertNil(RoomCrypto.open(key: key, packet: packet + Data(count: RoomCrypto.maxPacket)))
    }

    func testOpensASliceThatDoesNotStartAtZero() {
        let packet = RoomCrypto.seal(key: key, plain: msg)!
        let padded = Data([9, 9, 9]) + packet
        XCTAssertEqual(RoomCrypto.open(key: key, packet: padded.dropFirst(3)), msg)
    }

    func testRefusesToSealMoreThanFits() {
        XCTAssertNil(RoomCrypto.seal(key: key, plain: Data(count: RoomCrypto.maxPacket)))
        XCTAssertNil(RoomCrypto.seal(key: key, plain: Data(count: RoomCrypto.maxPacket - 28)))
        XCTAssertEqual(RoomCrypto.seal(key: key, plain: Data(count: RoomCrypto.maxPacket - 29))?.count, RoomCrypto.maxPacket)
    }

    /// Packets sealed by upstream's `seal`: we open them and read the same message.
    func testOpensPacketsSealedByUpstream() {
        let cases = Fixture.list("sealed.json")
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let plain = RoomCrypto.open(key: Data(hex: c["key"] as! String), packet: Data(hex: c["packet"] as! String))
            XCTAssertEqual(plain.map { String(decoding: $0, as: UTF8.self) }, c["json"] as? String)
            XCTAssertNotNil(plain.flatMap(RoomProtocol.decode))
        }
    }
}

final class SchnorrTests: XCTestCase {
    /// bitcoin/bips bip-0340/test-vectors.csv, all 19 rows: public keys, signatures and verification results.
    func testBIP340Vectors() throws {
        let rows = String(decoding: Fixture.data("bip340-test-vectors.csv"), as: UTF8.self).split(whereSeparator: \.isNewline).dropFirst()
        XCTAssertEqual(rows.count, 19)
        var signed = 0
        for row in rows {
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let (index, sk, pk, aux, msg, sig, result) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6])
            if !sk.isEmpty {
                XCTAssertEqual(Nostr.Schnorr.publicKey(unhex(sk)).map(Hex.encode), pk.lowercased(), "vector \(index) public key")
                XCTAssertEqual(Nostr.Schnorr.sign(unhex(msg), secretKey: unhex(sk), aux: unhex(aux)).map(Hex.encode), sig.lowercased(), "vector \(index) signature")
                signed += 1
            }
            XCTAssertEqual(Nostr.Schnorr.verify(signature: unhex(sig), message: unhex(msg), publicKey: unhex(pk)), result == "TRUE", "vector \(index) verification")
        }
        XCTAssertGreaterThanOrEqual(signed, 8)
    }

    /// Public keys @noble/secp256k1 derives, including the smallest and the largest secret key.
    func testPublicKeysMatchNoble() {
        let cases = Fixture.list("nostrKeys.json")
        XCTAssertGreaterThanOrEqual(cases.count, 16)
        for c in cases {
            XCTAssertEqual(Nostr.Schnorr.publicKey(unhex(c["sk"] as! String)).map(Hex.encode), c["pubkey"] as? String)
        }
    }

    /// Signatures @noble/secp256k1 makes when given the same auxiliary randomness: ours are byte for byte the same.
    func testSignaturesMatchNoble() {
        let cases = Fixture.list("nostrSign.json")
        XCTAssertGreaterThanOrEqual(cases.count, 24)
        for c in cases {
            let (sk, msg, aux) = (unhex(c["sk"] as! String), unhex(c["msg"] as! String), unhex(c["aux"] as! String))
            let sig = Nostr.Schnorr.sign(msg, secretKey: sk, aux: aux)
            XCTAssertEqual(sig.map(Hex.encode), c["sig"] as? String)
            XCTAssertTrue(Nostr.Schnorr.verify(signature: unhex(c["sig"] as! String), message: msg, publicKey: Nostr.Schnorr.publicKey(sk)!))
        }
    }

    func testFieldArithmeticOnCarryHeavyInputs() {
        XCTAssertEqual(lp_selftest_field(), 1)
    }

    func testRejectsInvalidSecretKeys() {
        XCTAssertNil(Nostr.Schnorr.publicKey([UInt8](repeating: 0, count: 32)))
        XCTAssertNil(Nostr.Schnorr.publicKey(unhex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"))) // the curve order
        XCTAssertNil(Nostr.Schnorr.publicKey([UInt8](repeating: 0xff, count: 32)))
        XCTAssertNil(Nostr.Schnorr.publicKey([1, 2, 3]))
        XCTAssertNil(Nostr.Schnorr.sign([UInt8](repeating: 1, count: 32), secretKey: [UInt8](repeating: 0, count: 32)))
    }

    func testSignsWithFreshRandomnessAndVerifies() {
        let keys = Nostr.makeKeyPair()
        let msg = [UInt8](repeating: 0x42, count: 32)
        let a = Nostr.Schnorr.sign(msg, secretKey: keys.secretKey)!
        let b = Nostr.Schnorr.sign(msg, secretKey: keys.secretKey)!
        XCTAssertNotEqual(a, b)
        let pub = unhex(keys.pubkey)
        XCTAssertTrue(Nostr.Schnorr.verify(signature: a, message: msg, publicKey: pub))
        XCTAssertTrue(Nostr.Schnorr.verify(signature: b, message: msg, publicKey: pub))
        var bad = a
        bad[40] ^= 1
        XCTAssertFalse(Nostr.Schnorr.verify(signature: bad, message: msg, publicKey: pub))
        XCTAssertFalse(Nostr.Schnorr.verify(signature: a, message: [UInt8](repeating: 0x43, count: 32), publicKey: pub))
    }

    func testSigningIsFastEnoughForTheMainThread() {
        let keys = Nostr.makeKeyPair()
        let start = Date()
        for i in 0..<20 { _ = Nostr.Schnorr.sign([UInt8](repeating: UInt8(i), count: 32), secretKey: keys.secretKey) }
        let each = Date().timeIntervalSince(start) / 20
        print("schnorr sign took \(String(format: "%.2f", each * 1000)) ms each")
        XCTAssertLessThan(each, 0.05)
    }
}

import CryptoKit
import XCTest
@testable import LPRooms

// Ported from upstream's tests/main/nostrEvent.test.ts, plus vectors made by upstream's nostrEvent.ts and
// @noble/secp256k1 (Fixtures/nostr*.json, relayMessages.json).

private let PK = String(repeating: "a", count: 64)

private func event(_ o: [String: Any]) -> NostrEvent {
    NostrEvent(id: o["id"] as! String, pubkey: o["pubkey"] as! String, createdAt: o["created_at"] as! Int, kind: o["kind"] as! Int,
               tags: o["tags"] as! [[String]], content: o["content"] as! String, sig: o["sig"] as! String)
}

final class NostrEventTests: XCTestCase {
    func testSerializesPerNIP01() {
        XCTAssertEqual(Nostr.serializeEvent(pubkey: PK, createdAt: 1_700_000_000, kind: 24747, tags: [["x", "ab"]], content: "hi"),
                       "[0,\"\(PK)\",1700000000,24747,[[\"x\",\"ab\"]],\"hi\"]")
    }

    func testIdsAnEventByTheSHA256OfItsSerialization() {
        let keys = Nostr.makeKeyPair()
        let e = Nostr.signEvent(keys, kind: 24747, tags: [["x", "ab"]], content: "hi", createdAt: 1_700_000_000)!
        let serialized = Nostr.serializeEvent(pubkey: keys.pubkey, createdAt: 1_700_000_000, kind: 24747, tags: [["x", "ab"]], content: "hi")
        XCTAssertEqual(e.id, Hex.encode(SHA256.hash(data: Data(serialized.utf8))))
        XCTAssertEqual(e.pubkey, keys.pubkey)
        XCTAssertEqual(e.createdAt, 1_700_000_000)
        XCTAssertEqual(e.kind, 24747)
        XCTAssertEqual(e.tags, [["x", "ab"]])
        XCTAssertEqual(e.content, "hi")
    }

    func testMatchesBIP340TestVector0() {
        var sk = [UInt8](repeating: 0, count: 32)
        sk[31] = 3
        let zero = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(Nostr.Schnorr.publicKey(sk).map(Hex.encode), "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
        XCTAssertEqual(Nostr.Schnorr.sign(zero, secretKey: sk, aux: zero).map(Hex.encode),
                       "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0")
    }

    func testSignsEventsThatVerifyWithAFreshKeyEachTime() {
        let keys = Nostr.makeKeyPair()
        let e = Nostr.signEvent(keys, kind: 24747, tags: [], content: "", createdAt: 1_700_000_000)!
        XCTAssertTrue(Hex.isLower(keys.pubkey, count: 64))
        XCTAssertTrue(Hex.isLower(e.sig, count: 128))
        XCTAssertTrue(Nostr.Schnorr.verify(signature: unhex(e.sig), message: unhex(e.id), publicKey: unhex(e.pubkey)))
        XCTAssertNotEqual(Nostr.makeKeyPair().pubkey, keys.pubkey)
    }

    func testBuildsTheMessagesSentToRelays() {
        XCTAssertEqual(Nostr.reqMessage(subId: "lolping", topic: "ab", since: 1_700_000_000),
                       "[\"REQ\",\"lolping\",{\"kinds\":[24747],\"#x\":[\"ab\"],\"since\":1700000000,\"limit\":0}]")
        let e = Nostr.signEvent(Nostr.makeKeyPair(), kind: 24747, tags: [], content: "c", createdAt: 1)!
        XCTAssertEqual(Nostr.parseRelayMessage("[\"EVENT\",\"s\",\(Nostr.eventMessage(e).dropFirst(9))"), .event(subId: "s", event: e))
        XCTAssertEqual(Nostr.closeMessage(subId: "lolping"), "[\"CLOSE\",\"lolping\"]")
    }

    /// The REQ and CLOSE upstream writes, character for character.
    func testRelayRequestsMatchUpstream() {
        let f = Fixture.json("nostrMessages.json") as! [String: Any]
        XCTAssertEqual(Nostr.reqMessage(subId: "lolping", topic: f["reqTopic"] as! String, since: f["reqSince"] as! Int), f["req"] as? String)
        XCTAssertEqual(Nostr.closeMessage(subId: "lolping"), f["close"] as? String)
    }

    /// 40 events signed by upstream (noble): our serialization, id, public key and EVENT message are identical, and
    /// our verifier accepts its signatures. Contents include quotes, control characters and non-ASCII text.
    func testEventsSignedByUpstream() {
        let cases = Fixture.list("nostrEvents.json")
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        for c in cases {
            let e = event(c["event"] as! [String: Any])
            let serialized = Nostr.serializeEvent(pubkey: e.pubkey, createdAt: e.createdAt, kind: e.kind, tags: e.tags, content: e.content)
            XCTAssertEqual(serialized, c["serialized"] as? String)
            XCTAssertEqual(Hex.encode(SHA256.hash(data: Data(serialized.utf8))), e.id)
            XCTAssertEqual(Nostr.Schnorr.publicKey(unhex(c["sk"] as! String)).map(Hex.encode), e.pubkey)
            XCTAssertTrue(Nostr.Schnorr.verify(signature: unhex(e.sig), message: unhex(e.id), publicKey: unhex(e.pubkey)))
            XCTAssertEqual(Nostr.eventMessage(e), c["eventMessage"] as? String)
            // And an event of ours with the same fields gets the same id.
            let ours = Nostr.signEvent(NostrKeyPair(secretKey: unhex(c["sk"] as! String), pubkey: e.pubkey), kind: e.kind, tags: e.tags, content: e.content, createdAt: e.createdAt)
            XCTAssertEqual(ours?.id, e.id)
        }
    }
}

final class ParseRelayMessageTests: XCTestCase {
    private let event = Nostr.signEvent(Nostr.makeKeyPair(), kind: 24747, tags: [["x", "ab"]], content: "hi", createdAt: 1_700_000_000)!
    private var eventJSON: String { String(Nostr.eventMessage(event).dropFirst(9).dropLast()) }

    func testParsesEachRelayMessageType() {
        XCTAssertEqual(Nostr.parseRelayMessage("[\"EVENT\",\"s\",\(eventJSON)]"), .event(subId: "s", event: event))
        XCTAssertEqual(Nostr.parseRelayMessage("[\"OK\",\"\(event.id)\",false,\"rate-limited: slow down\"]"), .ok(eventId: event.id, ok: false, message: "rate-limited: slow down"))
        XCTAssertEqual(Nostr.parseRelayMessage("[\"OK\",\"\(event.id)\",true]"), .ok(eventId: event.id, ok: true, message: ""))
        XCTAssertEqual(Nostr.parseRelayMessage("[\"EOSE\",\"s\"]"), .eose(subId: "s"))
        XCTAssertEqual(Nostr.parseRelayMessage("[\"CLOSED\",\"s\",\"error: shutting down\"]"), .closed(subId: "s", message: "error: shutting down"))
        XCTAssertEqual(Nostr.parseRelayMessage("[\"NOTICE\",\"hello\"]"), .notice(message: "hello"))
    }

    func testRejectsJunk() {
        func bad(_ field: String, _ value: String) -> String {
            var o = try! JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as! [String: Any]
            o[field] = try! JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
            return "[\"EVENT\",\"s\",\(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))]"
        }
        XCTAssertNotNil(Nostr.parseRelayMessage(bad("content", "\"fine\"")))
        for text in [
            "not json", "{\"a\":1}", "[]", "[\"AUTH\",\"challenge\"]", "[\"EVENT\",\"s\"]", "[\"EOSE\"]",
            bad("id", "\"xyz\""), bad("sig", "\"ab\""), bad("pubkey", "\"\(String(repeating: "A", count: 64))\""), bad("created_at", "1.5"),
            bad("kind", "\"24747\""), bad("tags", "[[\"x\",1]]"), bad("tags", "\"x\""), bad("content", "5"),
            "[\"OK\",\"\(event.id)\",\"yes\",\"\"]", "[\"OK\",\"short\",true,\"\"]",
        ] {
            XCTAssertNil(Nostr.parseRelayMessage(text), text)
        }
    }

    /// What upstream's parseRelayMessage makes of 66 messages.
    func testParsesExactlyAsUpstream() {
        let cases = Fixture.list("relayMessages.json")
        XCTAssertGreaterThanOrEqual(cases.count, 66)
        var parsed = 0
        for c in cases {
            let text = c["text"] as! String
            let expected: RelayMessage?
            if let r = c["result"] as? [String: Any] {
                switch r["type"] as! String {
                case "EVENT": expected = .event(subId: r["subId"] as! String, event: LPRoomsTests.event(r["event"] as! [String: Any]))
                case "OK": expected = .ok(eventId: r["eventId"] as! String, ok: r["ok"] as! Bool, message: r["message"] as! String)
                case "EOSE": expected = .eose(subId: r["subId"] as! String)
                case "CLOSED": expected = .closed(subId: r["subId"] as! String, message: r["message"] as! String)
                default: expected = .notice(message: r["message"] as! String)
                }
                parsed += 1
            } else {
                expected = nil
            }
            XCTAssertEqual(Nostr.parseRelayMessage(text), expected, text)
        }
        XCTAssertGreaterThan(parsed, 15)
    }
}

final class RelayContentTests: XCTestCase {
    /// Event contents upstream's RelayTransport accepted or dropped, and the packet it made of each: 31 cases around
    /// its base64 pattern and its 1600-character limit.
    func testAcceptsAndDecodesContentExactlyAsUpstream() {
        let cases = Fixture.list("relayContent.json")
        XCTAssertGreaterThanOrEqual(cases.count, 31)
        let clock = FakeScheduler()
        let sockets = FakeSockets()
        let relay = RelayTransport(RelayTransportOptions(urls: ["wss://x.test"], socket: sockets.factory, random: { 0.5 }), scheduler: clock)
        var got: Data?
        relay.onPacket = { _, packet in got = packet }
        relay.start(keys: RoomKeys(msgKey: Data(repeating: 1, count: 32), relayTopic: "topic"))
        sockets.last.open()
        let other = Nostr.makeKeyPair()
        var at = 1_780_000_000
        var accepted = 0
        for c in cases {
            let content = c["content"] as! String
            got = nil
            at += 1
            sockets.last.receive(event: Nostr.signEvent(other, kind: 24747, tags: [["x", "topic"]], content: content, createdAt: at)!)
            XCTAssertTrue(got?.hex == c["packet"] as? String, content.count > 40 ? "\(content.count) characters" : content)
            if got != nil { accepted += 1 }
        }
        XCTAssertGreaterThan(accepted, 8)
        XCTAssertLessThan(accepted, cases.count - 8)
        relay.stop()
    }
}

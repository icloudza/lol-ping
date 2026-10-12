import XCTest
@testable import LPRooms

// Ported from upstream's tests/shared/roomProtocol.test.ts, plus vectors made by upstream's own encodeMessage and
// decodeMessage (Fixtures/messages.json, decode.json).

/// A message from a fixture's JSON object.
private func message(_ o: [String: Any]) -> RoomMessage? {
    guard let peer = o["peer"] as? String, let seq = o["seq"] as? Int, let ts = o["ts"] as? Int, let t = o["t"] as? String else { return nil }
    func num(_ k: String) -> Double { (o[k] as! NSNumber).doubleValue }
    let body: RoomMessage.Body
    switch t {
    case "presence":
        body = .presence(proto: o["proto"] as! Int, app: o["app"] as! String, name: o["name"] as! String, color: o["color"] as! Int,
                         status: MemberStatus(rawValue: o["status"] as! String)!)
    case "ping": body = .ping(id: o["ping"] as! String, d: o["d"] as! Int, x: num("x"), y: num("y"))
    case "emote": body = .emote(ref: o["e"] as! String, d: o["d"] as! Int, x: num("x"), y: num("y"))
    case "bye": body = .bye
    default: return nil
    }
    return RoomMessage(peer: peer, seq: seq, ts: ts, body: body)
}

private let base = (peer: "0123456789abcdef", seq: 4, ts: 1_780_000_000_000)
private func msg(_ body: RoomMessage.Body) -> RoomMessage { RoomMessage(peer: base.peer, seq: base.seq, ts: base.ts, body: body) }
private let presence = msg(.presence(proto: 1, app: "0.3.0", name: "Alex", color: 3, status: .on))
private let ping = msg(.ping(id: "danger", d: 2, x: 0.25, y: 1))
private let emote = msg(.emote(ref: "gg", d: 2, x: 0.25, y: 1))
private let customRef = "c:" + String(repeating: "0123456789abcdef", count: 2)

private func decode(_ json: String) -> RoomMessage? { RoomProtocol.decode(Data(json.utf8)) }

/// The fixture message as JSON, with some fields replaced (a value of nil removes the field).
private func raw(_ m: RoomMessage, _ patch: [String: Any?]) -> String {
    var o = try! JSONSerialization.jsonObject(with: RoomProtocol.encode(m)) as! [String: Any]
    for (k, v) in patch { o[k] = v }
    return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
}

final class RoomProtocolTests: XCTestCase {
    func testRoundTrips() {
        for m in [presence, ping, emote, msg(.bye), msg(.emote(ref: customRef, d: 2, x: 0.25, y: 1))] {
            XCTAssertEqual(RoomProtocol.decode(RoomProtocol.encode(m)), m)
        }
    }

    func testRoundsXAndYTo4Decimals() {
        XCTAssertEqual(RoomProtocol.decode(RoomProtocol.encode(msg(.ping(id: "danger", d: 2, x: 0.123456, y: 0.987654))))?.body, .ping(id: "danger", d: 2, x: 0.1235, y: 0.9877))
        XCTAssertEqual(RoomProtocol.decode(RoomProtocol.encode(msg(.emote(ref: "gg", d: 2, x: 0.123456, y: 0.987654))))?.body, .emote(ref: "gg", d: 2, x: 0.1235, y: 0.9877))
    }

    /// Byte for byte what upstream's encodeMessage writes for the same message: 17 hand-picked and 60 random ones.
    func testEncodesExactlyAsUpstream() {
        let cases = Fixture.list("messages.json")
        XCTAssertGreaterThanOrEqual(cases.count, 77)
        for c in cases {
            let m = message(c["msg"] as! [String: Any])!
            XCTAssertEqual(String(decoding: RoomProtocol.encode(m), as: UTF8.self), c["json"] as? String)
        }
    }

    /// What upstream's decodeMessage makes of 126 inputs: valid ones, every rejection in its test table, numbers
    /// written in odd ways, repeated keys, a byte order mark, bytes that aren't UTF-8.
    func testDecodesExactlyAsUpstream() {
        let cases = Fixture.list("decode.json")
        XCTAssertGreaterThanOrEqual(cases.count, 126)
        var accepted = 0
        for c in cases {
            let bytes = Data(hex: c["bytes"] as! String)
            let expected = (c["result"] as? [String: Any]).flatMap(message)
            XCTAssertEqual(c["result"] is NSNull, expected == nil)
            XCTAssertEqual(RoomProtocol.decode(bytes), expected, String(decoding: bytes, as: UTF8.self))
            if expected != nil { accepted += 1 }
        }
        XCTAssertGreaterThan(accepted, 30)
        XCTAssertLessThan(accepted, cases.count - 60)
    }

    func testRejectsBytesThatAreNotJSON() {
        XCTAssertNil(decode("{nope"))
    }

    func testRejects() {
        let cases: [(String, String)] = [
            ("unknown type", raw(presence, ["t": "hello"])),
            ("short peer", raw(presence, ["peer": "abc"])),
            ("upper-case peer", raw(presence, ["peer": "0123456789ABCDEF"])),
            ("negative seq", raw(presence, ["seq": -1])),
            ("fractional seq", raw(presence, ["seq": 1.5])),
            ("unsafe seq", raw(presence, ["seq": 1_152_921_504_606_846_976])),
            ("null ts", raw(presence, ["ts": NSNull()])),
            ("unknown ping", raw(ping, ["ping": "hold"])),
            ("display 0", raw(ping, ["d": 0])),
            ("display 17", raw(ping, ["d": 17])),
            ("fractional display", raw(ping, ["d": 1.5])),
            ("x below 0", raw(ping, ["x": -0.01])),
            ("x above 1", raw(ping, ["x": 1.01])),
            ("string x", raw(ping, ["x": "0.5"])),
            ("boolean x", raw(ping, ["x": true])),
            ("colour 8", raw(presence, ["color": 8])),
            ("colour -1", raw(presence, ["color": -1])),
            ("colour as CSS", raw(presence, ["color": "red"])),
            ("unknown status", raw(presence, ["status": "away"])),
            ("huge app version", raw(presence, ["app": String(repeating: "x", count: 65)])),
            ("name not a string", raw(presence, ["name": 42])),
            ("fractional proto", raw(presence, ["proto": 1.5])),
            ("missing field", raw(presence, ["name": nil])),
            ("empty ref", raw(emote, ["e": ""])),
            ("upper-case slug", raw(emote, ["e": "GG"])),
            ("slug with a path", raw(emote, ["e": "../gg"])),
            ("slug over 40 characters", raw(emote, ["e": String(repeating: "a", count: 41)])),
            ("short custom hash", raw(emote, ["e": "c:0123"])),
            ("upper-case custom hash", raw(emote, ["e": "c:" + String(repeating: "ABCDEF0123456789", count: 2)])),
            ("non-string ref", raw(emote, ["e": 7])),
            ("missing ref", raw(emote, ["e": nil])),
            ("emote display 0", raw(emote, ["d": 0])),
            ("emote display 17", raw(emote, ["d": 17])),
            ("emote x above 1", raw(emote, ["x": 1.5])),
            ("emote string y", raw(emote, ["y": "0.5"])),
        ]
        for (label, json) in cases { XCTAssertNil(decode(json), label) }
    }

    func testRejectsNonObjects() {
        for json in ["null", "3", "\"x\"", "[]", "[\(raw(presence, [:]))]", ""] { XCTAssertNil(decode(json), json) }
    }

    func testKeepsKnownFieldsOnly() {
        XCTAssertEqual(decode(raw(ping, ["extra": "ignored"])), ping)
        XCTAssertEqual(decode(raw(emote, ["extra": "ignored", "ping": "danger"])), emote)
    }

    func testAcceptsAPresenceFromANewerProtocol() {
        // The version check is the room's job.
        XCTAssertEqual(decode(raw(presence, ["proto": 2]))?.body, .presence(proto: 2, app: "0.3.0", name: "Alex", color: 3, status: .on))
    }

    func testAcceptsAWellFormedSlugThisVersionDoesNotKnow() {
        XCTAssertEqual(decode(raw(emote, ["e": "brand_new_2"]))?.body, .emote(ref: "brand_new_2", d: 2, x: 0.25, y: 1))
    }

    func testSanitisesTheName() {
        XCTAssertEqual(decode(raw(presence, ["name": "\u{202e}Alex\u{0}"]))?.presenceName, "Alex")
        XCTAssertEqual(decode(raw(presence, ["name": "   "]))?.presenceName, "Player")
        XCTAssertEqual(decode(raw(presence, ["name": String(repeating: "🎮", count: 20)]))?.presenceName, String(repeating: "🎮", count: 16))
    }

    func testDeeplyNestedJunkIsRejectedNotCrashedOn() {
        let deep = String(repeating: "[", count: 100_000)
        XCTAssertNil(decode(deep))
        XCTAssertNil(Nostr.parseRelayMessage(deep + String(repeating: "]", count: 100_000)))
        XCTAssertNil(decode("{\"t\":\"bye\",\"peer\":\"0123456789abcdef\",\"seq\":1,\"ts\":1,\"x\":" + String(repeating: "[", count: 600) + String(repeating: "]", count: 600) + "}"))
        // Shallow extras are skipped over like any unknown field.
        XCTAssertNotNil(decode("{\"t\":\"bye\",\"peer\":\"0123456789abcdef\",\"seq\":1,\"ts\":1,\"x\":[[[{\"a\":[1,2,{}]}]]]}"))
    }
}

final class JSONTests: XCTestCase {
    func testWritesStringsAsJSONStringifyDoes() {
        XCTAssertEqual(JSON.quote("a\"b\\c/d"), "\"a\\\"b\\\\c/d\"")
        XCTAssertEqual(JSON.quote("\u{8}\u{c}\n\r\t\u{1}\u{1f}\u{7f}"), "\"\\b\\f\\n\\r\\t\\u0001\\u001f\u{7f}\"")
        XCTAssertEqual(JSON.quote("名前🎮\u{2028}"), "\"名前🎮\u{2028}\"")
    }

    func testWritesNumbersAsJSONStringifyDoes() {
        XCTAssertEqual(JSON.number(0), "0")
        XCTAssertEqual(JSON.number(-0.0), "0")
        XCTAssertEqual(JSON.number(1), "1")
        XCTAssertEqual(JSON.number(0.5), "0.5")
        XCTAssertEqual(JSON.number(0.0001), "0.0001")
        XCTAssertEqual(JSON.number(0.1235), "0.1235")
        XCTAssertEqual(JSON.number(.nan), "null")
        XCTAssertEqual(JSON.number(.infinity), "null")
    }

    func testReadsStrictJSONOnly() {
        XCTAssertEqual(JSON.parse(" [1, 2.5e1, -0, true, false, null, \"a\\u00e9\\ud83c\\udfae\", {\"k\": []}] "),
                       .array([.number(1), .number(25), .number(0), .bool(true), .bool(false), .null, .string("aé🎮"), .object(["k": .array([])])]))
        for bad in ["", "[1,]", "{\"a\":1,}", "01", "+1", "1.", ".5", "1e", "'a'", "[1] x", "nul", "\"a\nb\"", "\"\\x\"", "{a:1}", "NaN", "[1}{", "\"abc"] {
            XCTAssertNil(JSON.parse(bad), bad)
        }
        XCTAssertEqual(JSON.parse("{\"a\":1,\"a\":2}"), .object(["a": .number(2)])) // the last one wins, as in JavaScript
        XCTAssertEqual(JSON.parse("\"\\ud800x\""), .string("\u{fffd}x"))
    }

    func testNumbersAreNotBooleansAndIntegersAreChecked() {
        XCTAssertNil(JSONValue.bool(true).number)
        XCTAssertEqual(JSONValue.number(4).safeInteger, 4)
        XCTAssertNil(JSONValue.number(4.5).safeInteger)
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_991).safeInteger, 9_007_199_254_740_991)
        XCTAssertNil(JSONValue.number(9_007_199_254_740_992).safeInteger)
        XCTAssertNil(JSONValue.number(.infinity).safeInteger)
        XCTAssertNil(JSONValue.number(.infinity).integer)
        XCTAssertNil(JSONValue.number(1e300).integer)
    }

    func testChecksUTF8() {
        XCTAssertNotNil(JSON.parse(utf8: [0xef, 0xbb, 0xbf] + Array("[1]".utf8))) // a byte order mark is dropped
        XCTAssertNil(JSON.parse(utf8: Array("[1]".utf8) + [0xff]))
        XCTAssertNil(JSON.parse(utf8: [0x22, 0xc0, 0xaf, 0x22])) // overlong
        XCTAssertNil(JSON.parse(utf8: [0x22, 0xed, 0xa0, 0x80, 0x22])) // a surrogate
    }
}

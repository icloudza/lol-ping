import XCTest
@testable import LPRooms

final class RoomCodeTests: XCTestCase {
    func testMakeFormatParse() {
        let code = RoomCode.make(random9: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(code.count, 10)
        XCTAssertEqual(code.prefix(9), "123456789")
        let shown = RoomCode.format(code)
        XCTAssertTrue(shown.hasPrefix("PING-12345-6789"))
        XCTAssertEqual(try RoomCode.parse(shown).get(), code)
        XCTAssertEqual(try RoomCode.parse("join me: \(shown.lowercased()) !").get(), code)
        XCTAssertEqual(try RoomCode.parse(code).get(), code)
        XCTAssertEqual(try RoomCode.parse(shown, strict: true).get(), code)
    }

    func testLookalikesAndTypos() {
        let code = RoomCode.make(random9: [0, 1, 0, 1, 0, 1, 0, 1, 0]) // 010101010 + check
        let typed = RoomCode.format(code).replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l")
        XCTAssertEqual(try RoomCode.parse("PING" + typed.dropFirst(4)).get(), code)
        var bad = Array(RoomCode.format(RoomCode.make(random9: [1, 2, 3, 4, 5, 6, 7, 8, 9])))
        bad[5] = bad[5] == "2" ? "3" : "2"
        XCTAssertEqual(RoomCode.parse(String(bad)), .failure(.mistyped))
        XCTAssertEqual(RoomCode.parse("hello there"), .failure(.invalid))
        XCTAssertEqual(RoomCode.parse("STRAWBERRY jam"), .failure(.invalid))
    }

    func testEveryCodeRoundTrips() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let code = RoomCode.make(random9: (0..<9).map { _ in UInt8.random(in: 0...255, using: &rng) })
            XCTAssertEqual(try RoomCode.parse(RoomCode.format(code)).get(), code)
        }
    }
}

final class NamesTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(Names.sanitize("  Ann\u{200b}a\u{202e}  "), "Anna")
        XCTAssertEqual(Names.sanitize("\u{0000}\u{feff}"), "Player")
        XCTAssertEqual(Names.sanitize(String(repeating: "x", count: 40)).count, 16)
        XCTAssertEqual(Names.sanitize("😀😀", max: 1), "😀")
    }
}

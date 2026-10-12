import XCTest
@testable import LPRooms

// Ported from upstream's tests/main/relayRoom.test.ts: two rooms in one process meeting through a relay on loopback,
// the way two computers meet through a public one. Real WebSockets (URLSession), real signatures, real keys.

final class RelayRoomTests: XCTestCase {
    private var relay: FakeRelay!
    private var peers: [TestPeer] = []
    private let code = RoomCode.make(random9: Nostr.randomBytes(9))

    override func setUpWithError() throws {
        relay = try FakeRelay()
        peers = []
    }

    override func tearDown() {
        for p in peers { p.shutDown() }
        relay.close()
    }

    private func net() -> RelayTransport {
        RelayTransport(RelayTransportOptions(urls: [relay.url]))
    }

    private func peer(_ name: String, lan: LanTransport? = nil) -> TestPeer {
        let p = TestPeer(name: name, lan: lan, others: [net()], appVersion: "0.4.0", color: 2)
        peers.append(p)
        return p
    }

    func testTwoRoomsMeetOverARelayExchangeAPingAndSeeBye() {
        let a = peer("Ana")
        let b = peer("Ben")
        a.room.join(code)
        b.room.join(code)
        // (Ana's own presence can reach Ben a moment before it comes back to her, which is what makes her "ok".)
        until(6) { a.room.state.members.count == 2 && b.room.state.members.count == 2 && a.room.state.internet == .ok }
        XCTAssertEqual(a.room.state.members[1].name, "Ben")
        XCTAssertEqual(a.room.state.members[1].path, .internet)

        b.room.sendPing("omw", d: 1, x: 0.25, y: 0.5)
        until(6) { a.pings.count == 1 }
        XCTAssertEqual(a.pings.first, RemotePing(displayId: 1, x: 250, y: 250, id: "omw", tag: NameTag(name: "Ben", color: 2)))

        b.room.leave()
        until(6) { a.left }
        XCTAssertEqual(a.room.state.members.count, 1)
    }

    func testSwitchesAMemberToTheInternetPathWhenLANStops() {
        let lanB = TestPeer.lan(47_512, 47_511)
        let a = peer("Ana", lan: TestPeer.lan(47_511, 47_512))
        let b = peer("Ben", lan: lanB)
        a.room.join(code)
        b.room.join(code)
        until(6) { a.room.state.members.count == 2 && a.room.state.members[1].path == .lan }

        lanB.stop()
        until(8) { a.room.state.members.count == 2 && a.room.state.members[1].path == .internet }
    }

    func testTheByeReachesTheRelayBeforeTheSocketCloses() {
        let a = peer("Ana")
        a.room.join(code)
        until(6) { a.room.state.internet == .ok }
        let before = relay.eventCount
        a.room.quit()
        var closed = false
        a.transports[0].whenClosed { closed = true }
        until(2) { closed }
        XCTAssertEqual(relay.eventCount, before + 1)
    }
}

/// The URLSession WebSocket, against the relay on loopback.
final class RelaySocketTests: XCTestCase {
    private var relay: FakeRelay!
    private var socket: RelaySocket!
    private var messages: [RelaySocketMessage] = []
    private var opened = false
    private var closed = false

    override func setUpWithError() throws {
        relay = try FakeRelay()
        messages = []
        opened = false
        closed = false
    }

    override func tearDown() {
        socket?.close()
        relay.close()
    }

    private func connect(_ url: String? = nil) throws {
        socket = try URLSessionRelaySockets.main.factory(url ?? relay.url)
        socket.onOpen = { [unowned self] in self.opened = true }
        socket.onMessage = { [unowned self] in self.messages.append($0) }
        socket.onClose = { [unowned self] in self.closed = true }
    }

    func testOpensSendsAndReceivesText() throws {
        try connect()
        XCTAssertThrowsError(try socket.send("[\"TEST\",\"echo\"]")) // not open yet
        until { opened }
        try socket.send("[\"REQ\",\"s\",{\"kinds\":[24747],\"#x\":[\"t\"]}]")
        until { messages.count == 1 }
        XCTAssertEqual(messages, [.text("[\"EOSE\",\"s\"]")])
        XCTAssertFalse(closed)
    }

    func testReportsABinaryFrameAndAnOversizeFrameAsUnacceptable() throws {
        try connect()
        until { opened }
        try socket.send("[\"TEST\",\"binary\"]")
        until { messages.count == 1 }
        XCTAssertEqual(messages, [.unacceptable])
        try socket.send("[\"TEST\",\"huge\"]")
        until { messages.count == 2 || closed }
        XCTAssertEqual(messages.last, .unacceptable)
    }

    func testReportsTheRelayClosing() throws {
        try connect()
        until { opened }
        try socket.send("[\"TEST\",\"close\"]")
        until { closed }
        XCTAssertThrowsError(try socket.send("x"))
    }

    func testReportsAConnectionThatCannotBeMade() throws {
        let port = relay.port
        relay.close()
        try connect("ws://127.0.0.1:\(port)")
        until { closed }
        XCTAssertFalse(opened)
    }

    func testEmitsNothingAfterWeCloseIt() throws {
        try connect()
        until { opened }
        try socket.send("[\"TEST\",\"echo\"]")
        socket.close()
        let end = Date().addingTimeInterval(0.3)
        until(1) { Date() > end }
        XCTAssertEqual(messages, [])
        XCTAssertFalse(closed)
        XCTAssertThrowsError(try socket.send("x"))
    }

    func testRefusesURLsThatAreNotWebSockets() {
        for url in ["", "not a url", "https://nos.lol", "wss://", "file:///etc/hosts"] {
            XCTAssertThrowsError(try URLSessionRelaySockets.main.factory(url), url)
        }
    }
}

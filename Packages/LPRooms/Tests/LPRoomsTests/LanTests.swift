import Darwin
import XCTest
@testable import LPRooms

// Ported from upstream's tests/main/lanRoom.test.ts: two rooms on loopback, real sockets, real key derivation.
// Loopback carries no broadcast, so each transport is seeded with the other's port.

private let A_PORT: UInt16 = 47_501
private let B_PORT: UInt16 = 47_502

final class TestPeer {
    let lan: LanTransport?
    let transports: [Transport]
    let room: RoomManager
    var pings: [RemotePing] = []
    var toasts: [RoomToast] = []
    var packets = 0

    init(name: String, lan: LanTransport?, others: [Transport] = [], appVersion: String = "0.3.0", color: Int = 1) {
        self.lan = lan
        transports = (lan.map { [$0 as Transport] } ?? []) + others
        room = RoomManager(RoomDeps(
            transports: transports,
            scheduler: DispatchRoomScheduler(queue: .main),
            randomBytes: { Nostr.randomBytes($0) },
            deriveKeys: { code, done in RoomCrypto.deriveRoomKeys(code, queue: .main, completion: done) },
            appVersion: { appVersion },
            profile: { RoomProfile(name: name, color: color, limit: 0) },
            resolveTarget: { _ in RoomTarget(displayId: 1, width: 1000, height: 500) }
        ))
        room.onRemotePing = { [unowned self] in self.pings.append($0) }
        room.onToast = { [unowned self] in self.toasts.append($0) }
        if let lan {
            let inner = lan.onPacket
            lan.onPacket = { [unowned self] peer, packet in
                self.packets += 1
                inner?(peer, packet)
            }
        }
    }

    static func lan(_ port: UInt16, _ other: UInt16) -> LanTransport {
        LanTransport(LanOptions(port: port, bindAddress: "127.0.0.1", broadcast: false, seeds: [(host: "127.0.0.1", port: other)]))
    }

    var left: Bool { toasts.contains { if case .left = $0 { return true } else { return false } } }

    /// Says bye and waits until every socket is closed.
    func shutDown() {
        room.quit()
        var pending = transports.count
        for t in transports { t.whenClosed { pending -= 1 } }
        until { pending == 0 }
    }
}

/// A plain UDP socket bound to 127.0.0.1, or nil when the port is taken.
private func bindUDP(_ port: UInt16) -> Int32? {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if ok != 0 {
        close(fd)
        return nil
    }
    return fd
}

private func sendUDP(_ fd: Int32, _ bytes: [UInt8], to port: UInt16) {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

final class LanRoomTests: XCTestCase {
    private var open: [TestPeer] = []
    private let code = RoomCode.make(random9: Nostr.randomBytes(9))

    private func peer(_ port: UInt16, _ other: UInt16, _ name: String) -> TestPeer {
        let p = TestPeer(name: name, lan: TestPeer.lan(port, other))
        open.append(p)
        return p
    }

    override func tearDown() {
        for p in open { p.shutDown() }
        open = []
    }

    func testFindEachOtherExchangePingsSurviveARebindAndSeeALeave() {
        let a = peer(A_PORT, B_PORT, "Alice")
        let b = peer(B_PORT, A_PORT, "Bob")
        a.room.join(code)
        b.room.join(code)
        until { a.room.state.members.count == 2 && b.room.state.members.count == 2 }
        XCTAssertEqual(b.room.state.members[1].name, "Alice")
        XCTAssertEqual(b.room.state.members[1].path, .lan)
        XCTAssertEqual(a.lan?.status, .ok)

        a.room.sendPing("push", d: 1, x: 0.5, y: 0.5)
        until { b.pings.count == 1 }
        XCTAssertEqual(b.pings.first, RemotePing(displayId: 1, x: 500, y: 250, id: "push", tag: NameTag(name: "Alice", color: 1)))

        b.lan?.rebind()
        XCTAssertEqual(b.lan?.status, .starting)
        until { b.lan?.status == .ok }
        a.room.sendPing("omw", d: 1, x: 0, y: 0)
        until { b.pings.count == 2 }

        a.room.leave()
        until { b.left }
        XCTAssertEqual(b.room.state.members.count, 1)
    }

    func testSeeAMemberWhoLeftAndJoinedTheSameRoomAgain() {
        let a = peer(A_PORT, B_PORT, "Alice")
        let b = peer(B_PORT, A_PORT, "Bob")
        a.room.join(code)
        b.room.join(code)
        until { b.room.state.members.count == 2 }
        a.room.leave()
        until { b.room.state.members.count == 1 }
        a.room.join(code)
        until { b.room.state.members.count == 2 && a.room.state.members.count == 2 }
        a.room.sendPing("bait", d: 1, x: 0.1, y: 0.1)
        until { b.pings.count == 1 }
    }

    func testSurvivesTwoRebindsInARowWhilePacketsAreStillGoingOut() {
        let a = peer(A_PORT, B_PORT, "Alice")
        let b = peer(B_PORT, A_PORT, "Bob")
        a.room.join(code)
        b.room.join(code)
        until { a.room.state.members.count == 2 }
        for _ in 0..<200 { a.room.sendPing("push", d: 1, x: 0.5, y: 0.5) }
        a.lan?.rebind()
        a.lan?.rebind()
        until { a.lan?.status != .starting }
        XCTAssertEqual(a.lan?.status, .ok)
        // The new socket works. (Bob's flood guard let 100 of the 200 through and needs a moment to refill.)
        let refilled = Date().addingTimeInterval(0.2)
        until(1) { Date() > refilled }
        a.room.sendPing("omw", d: 1, x: 0, y: 0)
        until { b.pings.contains { $0.id == "omw" } }
        XCTAssertLessThanOrEqual(b.pings.filter { $0.id == "push" }.count, 130)
    }

    func testWhenClosedCallsBackOnceThePortIsFreeAgainAfterTheLastPacketsWentOut() {
        let listener = bindUDP(B_PORT)!
        defer { close(listener) }
        let a = peer(A_PORT, B_PORT, "Alice")
        a.room.join(code)
        until { a.lan?.status == .ok }
        XCTAssertNil(bindUDP(A_PORT)) // ours while the room runs
        a.room.quit() // sends a bye, then stops
        var closed = false
        a.lan?.whenClosed { closed = true }
        XCTAssertFalse(closed)
        until { closed }
        let probe = bindUDP(A_PORT)
        XCTAssertNotNil(probe)
        probe.map { _ = close($0) }

        // The bye is the last datagram the seed address got, and it opens with the room key.
        var last: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        while true {
            let n = recv(listener, &buffer, buffer.count, 0)
            if n <= 0 { break }
            last = Array(buffer[0..<n])
        }
        let keys = try! RoomCrypto.deriveRoomKeysSync(code)
        XCTAssertEqual(RoomCrypto.open(key: keys.msgKey, packet: Data(last)).flatMap(RoomProtocol.decode)?.type, "bye")
    }

    func testCapsJunkFromOneAddressBeforeItReachesDecryption() {
        let b = peer(B_PORT, A_PORT, "Bob")
        b.room.join(code)
        until { b.lan?.status == .ok }
        let junk = bindUDP(47_503)!
        defer { close(junk) }
        let before = b.packets
        for _ in 0..<500 { sendUDP(junk, Nostr.randomBytes(64), to: B_PORT) }
        let end = Date().addingTimeInterval(0.3)
        until(1) { Date() > end }
        let through = b.packets - before
        XCTAssertGreaterThan(through, 50)
        XCTAssertLessThanOrEqual(through, 130)
        XCTAssertEqual(b.room.state.members.count, 1)
    }

    func testDropsDatagramsLargerThanAPacket() {
        let b = peer(B_PORT, A_PORT, "Bob")
        b.room.join(code)
        until { b.lan?.status == .ok }
        let sender = bindUDP(47_503)!
        defer { close(sender) }
        var sizes: [Int] = []
        let inner = b.lan?.onPacket
        b.lan?.onPacket = { peer, packet in
            XCTAssertEqual(peer, "lan:127.0.0.1:47503")
            sizes.append(packet.count)
            inner?(peer, packet)
        }
        for size in [1201, 1200, 4000, 0, 29] { sendUDP(sender, [UInt8](repeating: 7, count: size), to: B_PORT) }
        until { sizes.count == 3 }
        let end = Date().addingTimeInterval(0.1)
        until(1) { Date() > end }
        XCTAssertEqual(sizes, [1200, 0, 29])
    }

    func testReportsAPortThatIsAlreadyTakenAsUnavailable() {
        let blocker = bindUDP(A_PORT)!
        let a = peer(A_PORT, B_PORT, "Alice")
        a.room.join(code)
        until { a.room.state.phase != .idle && a.lan?.status != .starting && a.lan?.status != .off }
        XCTAssertEqual(a.lan?.status, .unavailable)
        XCTAssertEqual(a.room.state.lan, .unavailable)
        // And a rebind once the port is free brings it back, as after a sleep.
        close(blocker)
        a.lan?.rebind()
        until { a.lan?.status == .ok }
        XCTAssertEqual(a.room.state.lan, .ok)
    }

    func testSendsNothingAndAnswersWhenClosedWhileItIsNotRunning() {
        let lan = TestPeer.lan(A_PORT, B_PORT)
        XCTAssertEqual(lan.status, .off)
        lan.broadcast(Data([1]))
        lan.send(to: "lan:127.0.0.1:\(B_PORT)", packet: Data([1]))
        lan.rebind()
        lan.stop()
        XCTAssertEqual(lan.status, .off)
        var closed = false
        lan.whenClosed { closed = true }
        until { closed }
    }

    func testReadsBroadcastAddressesLikeUpstream() {
        let list = LanTransport.broadcastAddresses()
        XCTAssertEqual(list.first, "255.255.255.255")
        XCTAssertEqual(Set(list).count, list.count)
        for a in list {
            let parts = a.split(separator: ".").compactMap { UInt8($0) }
            XCTAssertEqual(parts.count, 4, a)
            XCTAssertNotEqual(parts.first, 127, a) // never the loopback interface
        }
    }
}

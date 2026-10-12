import CryptoKit
import XCTest
@testable import LPRooms

// Ported from upstream's tests/main/relayConnection.test.ts, relayPool.test.ts and relayTransport.test.ts.

private let NOW = 1_780_000_000_000
private let TOPIC = String(repeating: "ab", count: 32)
private let ME = String(repeating: "11", count: 32)
private let OTHER = String(repeating: "22", count: 32)
private let E64 = String(repeating: "e", count: 64)
private var counter = 0

/// An event as a relay would deliver it. Nothing here checks signatures (relays do), so it carries a made-up one.
private func ev(_ pubkey: String = OTHER, kind: Int = 24747, topic: String = TOPIC, content: String = "AAAA", at: Int = NOW / 1000) -> NostrEvent {
    counter += 1
    let id = String(repeating: "0", count: 48) + String(format: "%016x", counter)
    return NostrEvent(id: id, pubkey: pubkey, createdAt: at, kind: kind, tags: [["x", topic]], content: content, sig: String(repeating: "0", count: 128))
}

/// Lets everything already queued on the main queue run.
private func drainMain() {
    var done = false
    DispatchQueue.main.async { done = true }
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

final class RelayConnectionTests: XCTestCase {
    private var clock: FakeScheduler!
    private var sockets: FakeSockets!
    private var conn: RelayConnection!
    private var events: [NostrEvent] = []
    private var echoes = 0
    private var states: [RelayState] = []
    private var lives = 0
    private var oks: [String] = []

    private func make(_ socket: @escaping RelaySocketFactory) -> RelayConnection {
        RelayConnection(RelayConnectionOptions(url: "wss://r.test", topic: TOPIC, pubkey: ME, socket: socket, random: { 0.5 }, scheduler: clock))
    }

    override func setUp() {
        clock = FakeScheduler(now: NOW)
        sockets = FakeSockets()
        events = []
        echoes = 0
        states = []
        lives = 0
        oks = []
        conn = make(sockets.factory)
        conn.onEvent = { [unowned self] in self.events.append($0) }
        conn.onEcho = { [unowned self] in self.echoes += 1 }
        conn.onState = { [unowned self] in self.states.append($0) }
        conn.onLive = { [unowned self] in self.lives += 1 }
        conn.onOk = { [unowned self] id, ok, message in self.oks.append("\(id) \(ok) \(message)") }
        conn.start()
    }

    override func tearDown() {
        conn.stop()
    }

    private var last: FakeSocket { sockets.last }

    /// Opens the newest socket: the connection subscribes and goes live.
    @discardableResult private func goLive() -> FakeSocket {
        last.open()
        return last
    }

    private func echo() {
        last.receive(event: ev(ME))
    }

    private func published(_ s: FakeSocket) -> [String] {
        s.sent.filter { $0.hasPrefix("[\"EVENT\"") }
    }

    func testOpensSubscribesAndGoesLive() {
        XCTAssertEqual(conn.state, .connecting)
        let s = goLive()
        XCTAssertEqual(s.sent, ["[\"REQ\",\"lolping\",{\"kinds\":[24747],\"#x\":[\"\(TOPIC)\"],\"since\":\(NOW / 1000 - 600),\"limit\":0}]"])
        XCTAssertEqual(conn.state, .live)
        XCTAssertEqual(lives, 1)
        XCTAssertEqual(states, [.connecting, .live])
    }

    func testPublishesOnlyWhileLive() {
        XCTAssertFalse(conn.publish("[\"EVENT\",1]"))
        let s = goLive()
        XCTAssertTrue(conn.publish("[\"EVENT\",2]"))
        XCTAssertEqual(Array(s.sent.dropFirst()), ["[\"EVENT\",2]"])
    }

    func testSeparatesEchoesFromOtherMembersEventsAndIgnoresOtherSubscriptionsKindsAndTopics() {
        let s = goLive()
        let theirs = ev()
        s.receive(event: theirs)
        echo()
        s.receive(event: ev(), sub: "other-sub")
        s.receive(event: ev(OTHER, kind: 1))
        s.receive(event: ev(OTHER, kind: 24747, topic: String(repeating: "cd", count: 32)))
        s.receive("[\"NOTICE\",\"hi\"]")
        s.receive("garbage")
        XCTAssertEqual(events, [theirs])
        XCTAssertEqual(echoes, 1)
    }

    func testIsHealthyAfterTheFirstEchoAndDownAfter25sWithoutOne() {
        goLive()
        XCTAssertFalse(conn.healthy)
        echo()
        XCTAssertTrue(conn.healthy)
        clock.advance(24_999)
        XCTAssertEqual(conn.state, .live)
        clock.advance(1)
        XCTAssertEqual(conn.state, .down)
        XCTAssertFalse(conn.healthy)
        clock.advance(1999)
        XCTAssertEqual(sockets.sockets.count, 1)
        clock.advance(1)
        XCTAssertEqual(sockets.sockets.count, 2)
    }

    func testEveryEchoPushesTheHealthDeadlineBack() {
        goLive()
        for _ in 0..<10 {
            clock.advance(20_000)
            echo()
        }
        XCTAssertEqual(conn.state, .live)
        XCTAssertEqual(sockets.sockets.count, 1)
    }

    func testASilentSocketIsClosedAndReconnectedAfter25sWithoutAnEcho() {
        let s = goLive()
        clock.advance(25_000)
        XCTAssertTrue(s.closed)
        clock.advance(2000)
        XCTAssertEqual(sockets.sockets.count, 2)
        goLive()
        XCTAssertEqual(conn.state, .live)
    }

    func testBacksOff2Then4Then8UpTo60sAndResetsAfter60sHealthy() {
        var gaps: [Int] = []
        for _ in 0..<7 {
            last.drop()
            let before = sockets.sockets.count
            var waited = 0
            while sockets.sockets.count == before {
                clock.advance(1000)
                waited += 1000
            }
            gaps.append(waited)
        }
        XCTAssertEqual(gaps, [2000, 4000, 8000, 16_000, 32_000, 60_000, 60_000])
        goLive()
        echo()
        for _ in 0..<6 {
            clock.advance(10_000)
            echo()
        }
        last.drop()
        clock.advance(2000)
        XCTAssertEqual(sockets.sockets.count, 9)
    }

    func testJittersTheBackoffBy20Percent() {
        for (random, expected) in [(0.0, 1600.0), (0.999999, 2400.0)] {
            let s = FakeSockets()
            let c = RelayConnection(RelayConnectionOptions(url: "wss://r.test", topic: TOPIC, pubkey: ME, socket: s.factory, random: { random }, scheduler: clock))
            c.start()
            s.last.drop()
            clock.advance(expected - 1)
            XCTAssertEqual(s.sockets.count, 1)
            clock.advance(2)
            XCTAssertEqual(s.sockets.count, 2)
            c.stop()
        }
    }

    func testCountsASocketThatHasNotOpenedWithin10sAsDown() {
        clock.advance(9999)
        XCTAssertEqual(conn.state, .connecting)
        clock.advance(1)
        XCTAssertEqual(conn.state, .down)
        XCTAssertTrue(sockets.sockets[0].closed)
    }

    func testRateLimitedCoolsFor30sPublishesNothingAndIsNotMarkedDownForMissingEchoes() {
        let s = goLive()
        echo()
        s.receive(["OK", E64, false, "rate-limited: slow down"])
        XCTAssertEqual(conn.state, .cooling)
        XCTAssertTrue(conn.healthy)
        XCTAssertFalse(conn.publish("[\"EVENT\",3]"))
        XCTAssertEqual(published(s), [])
        clock.advance(29_999)
        XCTAssertEqual(conn.state, .cooling)
        clock.advance(1)
        XCTAssertEqual(conn.state, .live)
        XCTAssertEqual(sockets.sockets.count, 1)
        clock.advance(25_000)
        XCTAssertEqual(conn.state, .down)
    }

    func testRetiresOnRefusals() {
        for prefix in ["blocked:", "restricted:", "auth-required:", "pow:", "invalid:"] {
            setUp()
            let s = goLive()
            s.receive(["OK", E64, false, "\(prefix) no"])
            XCTAssertEqual(conn.state, .retired, prefix)
            XCTAssertTrue(s.closed)
            clock.advance(600_000)
            XCTAssertEqual(sockets.sockets.count, 1)
            conn.reconnectNow(revive: true)
            XCTAssertEqual(sockets.sockets.count, 2)
            conn.stop()
        }
    }

    func testOtherRefusalsAndAcceptedEventsChangeNothing() {
        let s = goLive()
        s.receive(["OK", E64, false, "error: could not save"])
        s.receive(["OK", E64, false, "duplicate: have it"])
        s.receive(["OK", E64, true, "blocked: but accepted"])
        XCTAssertEqual(conn.state, .live)
    }

    func testEmitsOKResults() {
        goLive().receive(["OK", E64, true, ""])
        XCTAssertEqual(oks, ["\(E64) true "])
    }

    func testResubscribesAfterOneCLOSEDAndRetiresAfterASecond() {
        let s = goLive()
        s.receive(["CLOSED", "lolping", "error: restarting"])
        XCTAssertEqual(s.sent.filter { $0.hasPrefix("[\"REQ\"") }.count, 2)
        XCTAssertEqual(conn.state, .live)
        s.receive(["CLOSED", "other", "error: not ours"])
        XCTAssertEqual(conn.state, .live)
        s.receive(["CLOSED", "lolping", "error: restarting"])
        XCTAssertEqual(conn.state, .retired)
    }

    func testRetiresAfterAMessageOver64KB() {
        let s = goLive()
        s.receive("[\"NOTICE\",\"" + String(repeating: "x", count: 64 * 1024 - 13) + "\"]") // exactly 64 KB: fine
        XCTAssertEqual(conn.state, .live)
        s.receive(String(repeating: "x", count: 64 * 1024 + 1))
        XCTAssertEqual(conn.state, .retired)
    }

    func testRetiresAfterMoreThan400MessagesInOneSecond() {
        let s = goLive()
        for _ in 0..<400 { s.receive("[\"NOTICE\",\"x\"]") }
        XCTAssertEqual(conn.state, .live)
        clock.advance(1000)
        for _ in 0..<400 { s.receive("[\"NOTICE\",\"x\"]") }
        XCTAssertEqual(conn.state, .live)
        s.receive("[\"NOTICE\",\"x\"]")
        XCTAssertEqual(conn.state, .retired)
    }

    func testRetiresAfterABinaryFrameWhichNoNostrRelaySends() {
        let s = goLive()
        s.onMessage?(.unacceptable)
        XCTAssertEqual(conn.state, .retired)
    }

    func testRetiresWhenNoSocketCanBeOpenedToTheURL() {
        let c = make { _ in throw RelaySocketError.badURL }
        c.start()
        XCTAssertEqual(c.state, .retired)
        clock.advance(600_000)
        XCTAssertEqual(c.state, .retired)
    }

    func testReconnectNowTrueLeavesConnectingAndLiveRelaysAlone() {
        conn.reconnectNow(revive: true)
        XCTAssertEqual(sockets.sockets.count, 1)
        goLive()
        conn.reconnectNow(revive: true)
        XCTAssertEqual(sockets.sockets.count, 1)
        last.drop()
        conn.reconnectNow(revive: true)
        XCTAssertEqual(sockets.sockets.count, 2)
    }

    func testReconnectNowFalseSkipsTheBackoffButLeavesARetiredRelayAlone() {
        last.drop()
        XCTAssertEqual(sockets.sockets.count, 1)
        conn.reconnectNow(revive: false)
        XCTAssertEqual(sockets.sockets.count, 2)
        goLive().receive(["OK", E64, false, "blocked: go away"])
        conn.reconnectNow(revive: false)
        XCTAssertEqual(sockets.sockets.count, 2)
    }

    func testStopClosesTheSocketAndEmitsNothingAfterwards() {
        let s = goLive()
        let before = states.count
        conn.stop()
        XCTAssertTrue(s.closed)
        s.receive(event: ev())
        s.onClose?()
        clock.advance(600_000)
        XCTAssertEqual(events, [])
        XCTAssertEqual(states.count, before)
        XCTAssertEqual(sockets.sockets.count, 1)
    }

    func testAnOldSocketsEventsAreIgnoredOnceANewOneReplacedIt() {
        let old = goLive()
        conn.reconnectNow(revive: false)
        old.receive(event: ev())
        old.onClose?()
        XCTAssertEqual(events, [])
        XCTAssertEqual(conn.state, .connecting)
        XCTAssertEqual(sockets.sockets.count, 2)
    }
}

final class RelayPoolTests: XCTestCase {
    private let urls = ["wss://a.test", "wss://b.test", "wss://c.test"]
    private var clock: FakeScheduler!
    private var sockets: FakeSockets!
    private var pool: RelayPool!
    private var events: [NostrEvent] = []
    private var statuses: [TransportStatus] = []
    private var linkUps: [String] = []
    private var oks: [String] = []

    override func setUp() {
        clock = FakeScheduler(now: NOW)
        sockets = FakeSockets()
        pool = RelayPool(RelayPoolOptions(urls: urls, topic: TOPIC, pubkey: ME, socket: sockets.factory, random: { 0.5 }, scheduler: clock))
        events = []
        statuses = []
        linkUps = []
        oks = []
        pool.onEvent = { [unowned self] in self.events.append($0) }
        pool.onStatus = { [unowned self] in self.statuses.append($0) }
        pool.onLinkUp = { [unowned self] in self.linkUps.append($0) }
        pool.onOk = { [unowned self] id, ok in self.oks.append("\(id) \(ok)") }
    }

    override func tearDown() {
        pool.stop()
    }

    /// The newest socket for a relay.
    private func sock(_ url: String) -> FakeSocket { sockets.sockets.last { $0.url == url }! }
    private func openAll() { urls.forEach { sock($0).open() } }
    private func echo(from url: String) { sock(url).receive(event: ev(ME)) }
    private func from(_ url: String, _ e: NostrEvent) { sock(url).receive(event: e) }

    func testIsOffUntilStartedThenStarting() {
        XCTAssertEqual(pool.status, .off)
        pool.start()
        XCTAssertEqual(pool.status, .starting)
        XCTAssertEqual(sockets.sockets.map(\.url), urls)
    }

    func testPublishesToLiveRelaysOnlyIncludingAFreshOneBeforeItsFirstEcho() {
        pool.start()
        sock(urls[0]).open()
        sock(urls[1]).open()
        sock(urls[1]).receive(["OK", E64, false, "rate-limited: easy"])
        let e = ev(ME)
        XCTAssertEqual(pool.publish(e), 1)
        XCTAssertEqual(sock(urls[0]).published(), [e])
        XCTAssertEqual(sock(urls[1]).published(), []) // cooling
        XCTAssertEqual(sock(urls[2]).sent, []) // still connecting
    }

    func testGoesStartingThenOkOnTheFirstEchoThenUnavailableWhenNoRelayIsHealthyThenOkAgain() {
        pool.start()
        openAll()
        echo(from: urls[0])
        XCTAssertEqual(pool.status, .ok)
        sock(urls[0]).drop()
        XCTAssertEqual(pool.status, .unavailable)
        clock.advance(2000)
        sock(urls[0]).open()
        echo(from: urls[0])
        XCTAssertEqual(pool.status, .ok)
        XCTAssertEqual(statuses, [.starting, .ok, .unavailable, .ok])
    }

    func testStaysOkWhileAnyRelayIsHealthy() {
        pool.start()
        openAll()
        echo(from: urls[0])
        echo(from: urls[1])
        sock(urls[0]).drop()
        XCTAssertEqual(pool.status, .ok)
    }

    func testIsUnavailableAfter15sWithoutAnyEcho() {
        pool.start()
        openAll()
        clock.advance(14_999)
        XCTAssertEqual(pool.status, .starting)
        clock.advance(1)
        XCTAssertEqual(pool.status, .unavailable)
    }

    func testIsUnavailableAsSoonAsEveryRelayHasFailedToConnect() {
        pool.start()
        sock(urls[0]).drop()
        sock(urls[1]).drop()
        XCTAssertEqual(pool.status, .starting)
        sock(urls[2]).drop()
        XCTAssertEqual(pool.status, .unavailable)
        clock.advance(2000)
        sock(urls[0]).open()
        echo(from: urls[0])
        XCTAssertEqual(pool.status, .ok)
    }

    func testPassesAnEventThatArrivesFromSeveralRelaysOnce() {
        pool.start()
        openAll()
        let e = ev()
        urls.forEach { from($0, e) }
        XCTAssertEqual(events, [e])
    }

    func testForgetsIdsAfter512NewerOnes() {
        pool.start()
        openAll()
        let first = ev(content: "first")
        from(urls[0], first)
        for i in 0..<512 {
            if i % 100 == 0 { clock.advance(1000) }
            from(urls[0], ev(content: "n\(i)"))
        }
        clock.advance(1000)
        from(urls[1], first)
        XCTAssertEqual(events.filter { $0.id == first.id }.count, 2)
    }

    func testStillRemembersAnIdAfter511NewerOnes() {
        pool.start()
        openAll()
        let first = ev(content: "first")
        from(urls[0], first)
        for i in 0..<511 {
            if i % 100 == 0 { clock.advance(1000) }
            from(urls[0], ev(content: "n\(i)"))
        }
        clock.advance(1000)
        from(urls[1], first)
        XCTAssertEqual(events.filter { $0.id == first.id }.count, 1)
    }

    func testCapsIncomingEventsAt200PerSecondAcrossRelays() {
        pool.start()
        openAll()
        for i in 0..<150 { from(urls[0], ev(content: "a\(i)")) }
        for i in 0..<100 { from(urls[1], ev(content: "b\(i)")) }
        XCTAssertEqual(events.count, 200)
        clock.advance(1000)
        from(urls[2], ev(content: "later"))
        XCTAssertEqual(events.count, 201)
    }

    func testDoesNotCountDuplicatesAgainstTheBudget() {
        pool.start()
        openAll()
        let e = ev()
        for i in 0..<300 { from(urls[i % 3], e) }
        from(urls[0], ev(content: "new"))
        XCTAssertEqual(events.count, 2)
    }

    func testEmitsLinkUpEachTimeARelayGoesLive() {
        pool.start()
        openAll()
        sock(urls[1]).drop()
        clock.advance(2000)
        sock(urls[1]).open()
        XCTAssertEqual(linkUps, urls + [urls[1]])
    }

    func testForwardsOKResults() {
        pool.start()
        sock(urls[0]).open()
        sock(urls[0]).receive(["OK", E64, true, ""])
        XCTAssertEqual(oks, ["\(E64) true"])
    }

    func testRetryNowDuringBackoffKeepsOneSocketPerRelay() {
        pool.start()
        sockets.sockets.forEach { $0.drop() }
        pool.retryNow()
        pool.retryNow()
        pool.retryNow()
        clock.advance(120_000)
        for u in urls { XCTAssertEqual(sockets.sockets.filter { $0.url == u && !$0.closed }.count, 1) }
    }

    func testRetryNowRevivesRetiredRelaysWakeDoesNot() {
        pool.start()
        openAll()
        sock(urls[0]).receive(["OK", E64, false, "blocked: no"])
        func count() -> Int { sockets.sockets.filter { $0.url == self.urls[0] }.count }
        pool.wake()
        XCTAssertEqual(count(), 1)
        pool.retryNow()
        XCTAssertEqual(count(), 2)
    }

    func testWakeReconnectsEveryRelayThatIsNotRetired() {
        pool.start()
        openAll()
        pool.wake()
        XCTAssertEqual(sockets.sockets.count, 6)
        XCTAssertTrue(sockets.sockets.prefix(3).allSatisfy(\.closed))
    }

    func testStopClosesEverySocketAndEmitsNothingAfterwards() {
        pool.start()
        openAll()
        let n = statuses.count + events.count + linkUps.count
        pool.stop()
        XCTAssertTrue(sockets.sockets.allSatisfy(\.closed))
        from(urls[0], ev())
        clock.advance(600_000)
        XCTAssertEqual(statuses.count + events.count + linkUps.count, n)
        XCTAssertEqual(pool.status, .off)
    }
}

final class RelayTransportTests: XCTestCase {
    private let keys = RoomKeys(msgKey: Data(repeating: 1, count: 32), relayTopic: String(repeating: "cd", count: 32))
    private var clock: FakeScheduler!
    private var sockets: FakeSockets!
    private var relay: RelayTransport!
    private var packets: [(String, Data)] = []

    private func make(_ urls: [String], _ sockets: FakeSockets) -> RelayTransport {
        RelayTransport(RelayTransportOptions(urls: urls, socket: sockets.factory, random: { 0.5 }), scheduler: clock)
    }

    override func setUp() {
        clock = FakeScheduler(now: NOW)
        sockets = FakeSockets()
        relay = make(["wss://a.test"], sockets)
        packets = []
        relay.onPacket = { [unowned self] peer, data in self.packets.append((peer, data)) }
    }

    override func tearDown() {
        relay.stop()
    }

    private var last: FakeSocket { sockets.last }
    private func theirs(_ content: String) -> NostrEvent { ev(OTHER, topic: keys.relayTopic, content: content) }

    /// How long whenClosed() took, in fake milliseconds.
    private func closeTime(_ r: RelayTransport? = nil) -> Int {
        let start = clock.now()
        var at = -1
        (r ?? relay).whenClosed { [clock] in at = clock!.now() - start }
        for _ in 0..<100 {
            drainMain()
            if at >= 0 { break }
            clock.advance(10)
        }
        return at
    }

    func testIsASharedInternetTransport() {
        XCTAssertEqual(relay.kind, .internet)
        XCTAssertTrue(relay.shared)
        XCTAssertEqual(relay.status, .off)
    }

    func testWrapsAPacketAsAKind24747EventWithOurTopicBase64ContentAndAValidSignature() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([1, 2, 3]))
        let e = last.published()[0]
        XCTAssertEqual(e.kind, 24747)
        XCTAssertEqual(e.tags, [["x", keys.relayTopic]])
        XCTAssertEqual(e.content, "AQID")
        XCTAssertEqual(e.createdAt, 1_780_000_000)
        XCTAssertTrue(Nostr.Schnorr.verify(signature: unhex(e.sig), message: unhex(e.id), publicKey: unhex(e.pubkey)))
        let serialized = Nostr.serializeEvent(pubkey: e.pubkey, createdAt: e.createdAt, kind: e.kind, tags: e.tags, content: e.content)
        XCTAssertEqual(e.id, Hex.encode(SHA256.hash(data: Data(serialized.utf8))))
    }

    func testSubscribesToTheRoomsTopicOnEveryRelay() {
        let s = FakeSockets()
        let many = make(Relays.all, s)
        many.start(keys: keys)
        XCTAssertEqual(s.sockets.map(\.url), ["wss://nos.lol", "wss://nostr.mom", "wss://relay.snort.social", "wss://relay.agentry.com", "wss://relay.routstr.com", "wss://nostr.rblb.it"])
        s.sockets.forEach { $0.open() }
        for sock in s.sockets {
            XCTAssertEqual(sock.sent, [Nostr.reqMessage(subId: "lolping", topic: keys.relayTopic, since: NOW / 1000 - 600)])
        }
        many.stop()
    }

    func testSendToIsABroadcast() {
        relay.start(keys: keys)
        last.open()
        relay.send(to: "net:whoever", packet: Data([9]))
        XCTAssertEqual(last.published().map(\.content), ["CQ=="])
    }

    func testEmitsPacketForOtherMembersEvents() {
        relay.start(keys: keys)
        last.open()
        last.receive(event: theirs("AQID"))
        XCTAssertEqual(packets.map(\.0), ["net:\(OTHER)"])
        XCTAssertEqual(packets.map(\.1), [Data([1, 2, 3])])
    }

    func testDropsContentOver1600CharactersOrThatIsNotBase64() {
        relay.start(keys: keys)
        last.open()
        last.receive(event: theirs(String(repeating: "A", count: 1604)))
        last.receive(event: theirs("!!!!"))
        last.receive(event: theirs("AQI"))
        XCTAssertEqual(packets.count, 0)
    }

    func testUsesANewKeyPairOnEveryStart() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([1]))
        let first = last.published()[0].pubkey
        relay.stop()
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([1]))
        XCTAssertNotEqual(last.published()[0].pubkey, first)
    }

    func testStopWaitsForTheByesOK() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([7]))
        let bye = last.published()[0]
        let s = last
        relay.stop()
        XCTAssertEqual(relay.status, .off)
        _ = clock.after(100) { s.receive(["OK", bye.id, true, ""]) }
        XCTAssertEqual(closeTime(), 100)
        XCTAssertTrue(s.closed)
    }

    func testStopWaitsAtMost500ms() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([7]))
        relay.stop()
        XCTAssertFalse(last.closed)
        XCTAssertEqual(closeTime(), 500)
        XCTAssertTrue(last.closed)
    }

    func testStopWhileConnectingResolvesWhenClosedAtOnce() {
        relay.start(keys: keys)
        relay.broadcast(Data([7])) // no relay is live: it went nowhere
        relay.stop()
        XCTAssertEqual(closeTime(), 0)
    }

    func testPacketsFromAStoppedSessionAreNeverEmitted() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([7]))
        let old = last
        relay.stop() // still draining the bye
        relay.start(keys: keys)
        old.receive(event: theirs("AQID"))
        XCTAssertEqual(packets.count, 0)
    }

    func testForwardsStatusAndLinkUpFromThePool() {
        var statuses: [TransportStatus] = []
        var linkUps = 0
        relay.onStatus = { statuses.append($0) }
        relay.onLinkUp = { linkUps += 1 }
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([1]))
        let mine = last.published()[0]
        last.receive(event: mine)
        relay.stop()
        XCTAssertEqual(statuses, [.starting, .ok, .off])
        XCTAssertEqual(linkUps, 1)
    }

    func testWakeReconnectsALiveRelayRetryNowOnlyReconnectsOneThatIsDown() {
        relay.start(keys: keys)
        last.open()
        relay.wake()
        XCTAssertEqual(sockets.sockets.count, 2)
        last.open()
        relay.retryNow()
        XCTAssertEqual(sockets.sockets.count, 2)
        last.drop()
        relay.retryNow()
        XCTAssertEqual(sockets.sockets.count, 3)
    }

    func testStopAfterTheLastEventWasAcknowledgedClosesAtOnce() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([7]))
        last.receive(["OK", last.published()[0].id, true, ""])
        relay.stop()
        XCTAssertEqual(closeTime(), 0)
        XCTAssertTrue(last.closed)
    }

    func testWhileDrainingAByeClosesRelaysThatAreNotLiveAtOnceAndNeverReconnectsOne() {
        let f = FakeSockets()
        let three = make(["wss://a.test", "wss://b.test", "wss://c.test"], f)
        three.start(keys: keys)
        let (a, b, c) = (f.sockets[0], f.sockets[1], f.sockets[2])
        a.open()
        b.open()
        b.drop() // b waits out a 2 s backoff; c is still connecting
        three.broadcast(Data([7]))
        three.stop()
        XCTAssertTrue(c.closed)
        XCTAssertFalse(a.closed) // live: kept for the bye's OK
        clock.advance(3000)
        XCTAssertEqual(f.sockets.count, 3)
        XCTAssertTrue(a.closed)
    }

    func testARelayThatRateLimitsTheByeIsNotWaitedFor() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([7]))
        let bye = last.published()[0]
        relay.stop()
        last.receive(["OK", bye.id, false, "rate-limited: slow down"])
        XCTAssertTrue(last.closed)
        XCTAssertEqual(closeTime(), 0)
    }

    func testTwoStopsInARowBothFinishBeforeWhenClosedCallsBack() {
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([7]))
        relay.stop()
        clock.advance(300)
        relay.start(keys: keys)
        last.open()
        relay.broadcast(Data([8]))
        relay.stop()
        XCTAssertEqual(closeTime(), 500) // the second bye's wait, which outlasts the first
        XCTAssertTrue(sockets.sockets.allSatisfy(\.closed))
    }

    func testFlippingInternetOffAndOnUnderRoomManagerLeavesOneOpenSocketPerRelay() {
        let f = FakeSockets()
        let urls = ["wss://a.test", "wss://b.test"]
        let net = make(urls, f)
        let room = RoomManager(RoomDeps(
            transports: [net], scheduler: clock, randomBytes: { [UInt8](repeating: 0x12, count: $0) },
            deriveKeys: { [keys] _, done in done(.success(keys)) }, appVersion: { "0.4.0" },
            profile: { RoomProfile(name: "Me", color: 1, limit: 5) }, resolveTarget: { _ in nil }
        ))
        /// A relay that answers OK to everything it was sent.
        func ackAll() {
            for s in f.sockets where !s.closed { for e in s.published() { s.receive(["OK", e.id, true, ""]) } }
        }
        func open(_ url: String) -> [FakeSocket] { f.sockets.filter { $0.url == url && !$0.closed } }
        room.join(RoomCode.format(RoomCode.make(random9: [1, 2, 3, 4, 5, 6, 7, 8, 9])))
        f.sockets.forEach { $0.open() }
        clock.advance(1000)
        ackAll()
        room.setInternetAllowed(false)
        room.setInternetAllowed(true)
        f.sockets.filter { !$0.isOpen && !$0.closed }.forEach { $0.open() }
        for u in urls { XCTAssertEqual(open(u).count, 1) }
        room.setInternetAllowed(false)
        clock.advance(600)
        for u in urls { XCTAssertEqual(open(u).count, 0) }
        room.quit()
    }
}

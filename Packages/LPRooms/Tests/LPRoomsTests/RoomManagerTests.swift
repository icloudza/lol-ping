import XCTest
@testable import LPRooms

// Ported from upstream's tests/main/roomManager.test.ts, case for case.

private let KEYS = RoomKeys(msgKey: Data(repeating: 1, count: 32), relayTopic: "room")
private let CODE = RoomCode.make(random9: [1, 2, 3, 4, 5, 6, 7, 8, 9])
private let SELF = "abababababababab"

/// Another lolPing in the room, sending through a fake transport.
private final class Remote {
    var seq = 0
    let peer: String
    let key: String
    let transport: FakeTransport
    let clock: FakeScheduler

    init(_ peer: String, _ key: String, _ transport: FakeTransport, _ clock: FakeScheduler) {
        self.peer = peer
        self.key = key
        self.transport = transport
        self.clock = clock
    }

    func packet(_ fields: [String: Any], key: Data = KEYS.msgKey, ts: Int? = nil) -> Data {
        seq += 1
        var m: [String: Any] = ["peer": peer, "seq": seq, "ts": ts ?? clock.now()]
        m.merge(fields) { $1 }
        return RoomCrypto.seal(key: key, plain: try! JSONSerialization.data(withJSONObject: m))!
    }

    static func presenceFields(_ peer: String, _ extra: [String: Any]) -> [String: Any] {
        var m: [String: Any] = ["t": "presence", "proto": 1, "app": "0.3.0", "name": "P\(peer.first!)", "color": 2, "status": "on"]
        m.merge(extra) { $1 }
        return m
    }

    func presence(_ extra: [String: Any] = [:]) {
        transport.deliver(key, packet(Self.presenceFields(peer, extra)))
    }

    func ping(_ extra: [String: Any] = [:]) {
        var m: [String: Any] = ["t": "ping", "ping": "danger", "d": 1, "x": 0.5, "y": 0.25]
        m.merge(extra) { $1 }
        transport.deliver(key, packet(m))
    }

    func emote(_ extra: [String: Any] = [:]) {
        var m: [String: Any] = ["t": "emote", "e": "gg", "d": 1, "x": 0.5, "y": 0.25]
        m.merge(extra) { $1 }
        transport.deliver(key, packet(m))
    }

    func bye() {
        transport.deliver(key, packet(["t": "bye"]))
    }
}

private func decode(_ t: FakeTransport, to: String? = nil) -> [RoomMessage] {
    t.sent.filter { to == nil || $0.to == to }.map { RoomProtocol.decode(RoomCrypto.open(key: KEYS.msgKey, packet: $0.packet)!)! }
}

class RoomManagerTestCase: XCTestCase {
    var clock: FakeScheduler!
    var lan: FakeTransport!
    var room: RoomManager!
    var profile = RoomProfile(name: "Me", color: 1, limit: 5)
    var pings: [RemotePing] = []
    var emotes: [RemoteEmote] = []
    var toasts: [RoomToast] = []
    var saved: [String?] = []
    var states: [RoomState] = []
    private var others: [RoomManager] = []

    func makeRoom(
        _ transports: [Transport], fill: UInt8 = 0xab, appVersion: String = "0.3.0",
        randomBytes: ((Int) -> [UInt8])? = nil,
        deriveKeys: ((String, @escaping (Result<RoomKeys, Error>) -> Void) -> Void)? = nil,
        resolveTarget: ((Int) -> RoomTarget?)? = nil
    ) -> RoomManager {
        let r = RoomManager(RoomDeps(
            transports: transports,
            scheduler: clock,
            randomBytes: randomBytes ?? { [UInt8](repeating: fill, count: $0) },
            deriveKeys: deriveKeys ?? { _, done in done(.success(KEYS)) },
            appVersion: { appVersion },
            profile: { [unowned self] in self.profile },
            resolveTarget: resolveTarget ?? { d in d == 1 ? RoomTarget(displayId: 100, width: 1920, height: 1080) : nil }
        ))
        others.append(r)
        return r
    }

    override func setUp() {
        clock = FakeScheduler()
        lan = FakeTransport(.lan)
        profile = RoomProfile(name: "Me", color: 1, limit: 5)
        pings = []
        emotes = []
        toasts = []
        saved = []
        states = []
        others = []
        room = makeRoom([lan])
        room.onRemotePing = { [unowned self] in self.pings.append($0) }
        room.onRemoteEmote = { [unowned self] in self.emotes.append($0) }
        room.onToast = { [unowned self] in self.toasts.append($0) }
        room.onSaveCode = { [unowned self] in self.saved.append($0) }
        room.onState = { [unowned self] in self.states.append($0) }
    }

    override func tearDown() {
        for r in others { r.quit() }
        others = []
        room = nil
    }

    fileprivate func remote(_ peer: String, _ key: String, on transport: FakeTransport? = nil) -> Remote {
        Remote(peer, key, transport ?? lan, clock)
    }

    func sentMessages(_ to: String? = nil) -> [RoomMessage] {
        decode(lan, to: to)
    }

    func joinActive(_ r: RoomManager? = nil) {
        var result: JoinResult?
        (r ?? room).join(RoomCode.format(CODE)) { result = $0 }
        XCTAssertEqual(result, .ok)
        clock.advance(3000)
    }
}

final class RoomJoiningTests: RoomManagerTestCase {
    func testCreateJoinsANewRoomAnnouncesItselfAndBecomesActiveAfter3s() {
        room.create()
        XCTAssertEqual(room.state.phase, .joining)
        XCTAssertEqual(lan.started, KEYS)
        let first = sentMessages("*")[0]
        XCTAssertEqual(first.peer, SELF)
        XCTAssertEqual(first.body, .presence(proto: 1, app: "0.3.0", name: "Me", color: 1, status: .on))
        clock.advance(3000)
        let s = room.state
        XCTAssertEqual(s.phase, .active)
        XCTAssertTrue(s.code!.hasPrefix("PING-"))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(toasts, [.joinedRoom(code: s.code!)])
    }

    func testRejectsTextWithoutACodeAndAMistypedCodeWithoutStartingAnything() {
        var results: [JoinResult] = []
        room.join("hello") { results.append($0) }
        let typo = String(CODE.prefix(9)) + (CODE.last == "0" ? "1" : "0")
        room.join(typo) { results.append($0) }
        XCTAssertEqual(results, [.failure(.invalid), .failure(.mistyped)])
        XCTAssertNil(lan.started)
        XCTAssertEqual(room.state.phase, .idle)
    }

    func testLeavesARoomThatAlreadyHas8OtherMembers() {
        room.join(CODE)
        for i in 0..<8 { remote(String(repeating: "\(i)", count: 16), "lan:10.0.0.\(i):47474").presence() }
        clock.advance(3000)
        XCTAssertEqual(room.state.phase, .idle)
        XCTAssertEqual(toasts, [.full])
        XCTAssertEqual(sentMessages("*").last?.type, "bye")
        XCTAssertNil(lan.started)
        XCTAssertEqual(saved.count, 0)
    }

    func testJoiningAnotherRoomLeavesTheFirstOne() {
        joinActive()
        let other = RoomCode.make(random9: [9, 9, 9, 9, 9, 9, 9, 9, 9])
        room.join(other)
        XCTAssertTrue(sentMessages("*").contains { $0.type == "bye" })
        XCTAssertEqual(room.state.code, RoomCode.format(other))
    }

    func testStateIsEmittedOnlyWhenItChanges() {
        joinActive()
        let before = states.count
        XCTAssertEqual(states.last, room.state)
        room.profileChanged()
        clock.advance(1000)
        XCTAssertEqual(states.count, before)
        profile.name = "Renamed"
        room.profileChanged()
        XCTAssertEqual(states.count, before + 1)
        XCTAssertEqual(states.last?.members[0].name, "Renamed")
    }
}

final class RoomMemberTests: RoomManagerTestCase {
    func testAddsAMemberOnPresenceAndAnswersItOnceDirectly() {
        joinActive()
        let alex = remote("1111111111111111", "lan:10.0.0.2:47474")
        alex.presence(["name": "Alex", "color": 4])
        alex.presence(["name": "Alex", "color": 4])
        XCTAssertEqual(sentMessages("lan:10.0.0.2:47474").filter { $0.type == "presence" }.count, 1)
        let s = room.state
        XCTAssertTrue(s.members[0].isSelf)
        XCTAssertEqual(s.members[0].name, "Me")
        XCTAssertEqual(s.members[1], RoomMember(peer: alex.peer, name: "Alex", color: 4, path: .lan, status: .on, needsUpdate: false, noEmotes: true, muted: false, isSelf: false))
        XCTAssertEqual(toasts.last, .joined(name: "Alex"))
    }

    func testDoesNotToastMembersThatWereAlreadyThereWhenJoining() {
        room.join(CODE)
        remote("1111111111111111", "lan:a").presence()
        clock.advance(3000)
        XCTAssertEqual(toasts, [.joinedRoom(code: RoomCode.format(CODE))])
    }

    func testMarksAMemberOnAnotherProtocolVersionAsNeedingAnUpdate() {
        joinActive()
        remote("1111111111111111", "lan:a").presence(["proto": 2])
        XCTAssertTrue(room.state.members[1].needsUpdate)
    }

    func testFlagsMembersTooOldForEmotesAndNoOneElse() {
        joinActive()
        let old = remote("1111111111111111", "lan:a")
        let current = remote("2222222222222222", "lan:b")
        let odd = remote("3333333333333333", "lan:c")
        old.presence(["app": "0.4.0"])
        current.presence(["app": "0.5.0"])
        odd.presence(["app": "room-peer"])
        func flags() -> [String: Bool] { Dictionary(uniqueKeysWithValues: room.state.members.map { ($0.peer, $0.noEmotes) }) }
        XCTAssertEqual(flags(), [SELF: false, old.peer: true, current.peer: false, odd.peer: false])
        old.presence(["app": "0.5.1"]) // updated and relaunched under the same peer ID
        XCTAssertEqual(flags()[old.peer], false)
    }

    func testIgnoresPacketsSealedWithAnotherKeyAndItsOwnMessages() {
        joinActive()
        let stranger = remote("1111111111111111", "lan:a")
        lan.deliver("lan:a", stranger.packet(Remote.presenceFields(stranger.peer, [:]), key: Data(repeating: 2, count: 32)))
        remote(SELF, "lan:me").presence()
        XCTAssertEqual(room.state.members.count, 1)
    }

    func testFallsBackToConnectingAfter6sOfSilenceAndDropsTheMemberAfter15s() {
        joinActive()
        remote("1111111111111111", "lan:a").presence(["name": "Alex"])
        clock.advance(6000)
        XCTAssertEqual(room.state.members[1].path, .connecting)
        clock.advance(9000)
        XCTAssertEqual(room.state.members.count, 1)
        XCTAssertEqual(toasts.last, .disconnected(name: "Alex"))
    }

    func testShowsAMemberAsUnreachable20sAfterItAppearedWhenItsPathsAreDead() {
        let net = FakeTransport(.internet)
        let both = makeRoom([lan, net])
        joinActive(both)
        net.deliver("net:x", remote("1111111111111111", "net:x").packet(Remote.presenceFields("1", ["name": "Far"])))
        clock.advance(25_000)
        XCTAssertEqual(both.state.members[1].path, .unreachable) // heard over the internet: kept for 30 s
        XCTAssertEqual(both.state.members.count, 2)
    }

    func testGivesMembersAFreshGracePeriodAfterTheComputerSlept() {
        joinActive()
        remote("1111111111111111", "lan:a").presence(["name": "Alex"])
        clock.setSystemTime(clock.now() + 60_000) // asleep: the clock moved, no timers ran
        clock.advance(1000)
        XCTAssertEqual(room.state.members.map(\.name), ["Me", "Alex"])
        XCTAssertFalse(toasts.contains(.disconnected(name: "Alex")))
        clock.advance(15_000) // and really gone: dropped as usual
        XCTAssertEqual(room.state.members.count, 1)
        XCTAssertEqual(toasts.last, .disconnected(name: "Alex"))
    }

    func testRemovesAMemberThatSaysByeAndIgnoresItAfterwards() {
        joinActive()
        let alex = remote("1111111111111111", "lan:a")
        alex.presence(["name": "Alex"])
        alex.bye()
        XCTAssertEqual(room.state.members.count, 1)
        XCTAssertEqual(toasts.last, .left(name: "Alex"))
        alex.presence(["name": "Alex"])
        XCTAssertEqual(room.state.members.count, 1)
    }

    /// A presence sealed with the room key but stamped an hour ago: a captured packet replayed later, or a bad clock.
    private func stalePresence(_ r: Remote, name: String = "Old") {
        lan.deliver(r.key, r.packet(["t": "presence", "proto": 1, "app": "1", "name": name, "color": 0, "status": "on"], ts: clock.now() - 3_600_000))
    }

    func testNeverAddsAnswersOrCountsAMemberFromStalePacketsSoReplaysCannotFillTheRoom() {
        room.join(CODE)
        let ghosts = (0..<8).map { remote(String(repeating: "\($0)", count: 16), "lan:66.6.6.6:\($0)") }
        lan.sent = []
        for g in ghosts { for _ in 0..<4 { stalePresence(g, name: "Old\(g.peer.first!)") } }
        clock.advance(3000)
        XCTAssertEqual(room.state.phase, .active)
        XCTAssertEqual(room.state.members.count, 1)
        XCTAssertEqual(lan.sent.filter { $0.to.hasPrefix("lan:66.6.6.6") }.count, 0)
        XCTAssertEqual(toasts, [.joinedRoom(code: RoomCode.format(CODE))])
    }

    func testWarnsAboutAClockMoreThan10MinutesOffWithoutAddingAnyoneThenClears() {
        joinActive()
        let late = remote("1111111111111111", "lan:a")
        stalePresence(late)
        stalePresence(late)
        XCTAssertFalse(room.state.clockSkew)
        stalePresence(late)
        XCTAssertTrue(room.state.clockSkew)
        XCTAssertEqual(room.state.members.count, 1)
        XCTAssertTrue(room.state.members[0].isSelf)
        clock.advance(31_000)
        XCTAssertFalse(room.state.clockSkew)
    }

    func testBecomesLonelyAfter20sAlone() {
        joinActive()
        XCTAssertFalse(room.state.lonely)
        clock.advance(17_000)
        XCTAssertTrue(room.state.lonely)
        XCTAssertEqual(states.last?.lonely, true)
        remote("1111111111111111", "lan:a").presence()
        XCTAssertFalse(room.state.lonely)
    }

    func testKeepsMembersInTheOrderTheyAppeared() {
        joinActive()
        let a = remote("3333333333333333", "lan:a"), b = remote("1111111111111111", "lan:b"), c = remote("2222222222222222", "lan:c")
        a.presence()
        b.presence()
        c.presence()
        XCTAssertEqual(room.state.members.map(\.peer), [SELF, a.peer, b.peer, c.peer])
        b.bye()
        XCTAssertEqual(room.state.members.map(\.peer), [SELF, a.peer, c.peer])
    }

    func testAPathThatIsGoneIsForgottenAndAnsweredAgain() {
        joinActive()
        let alex = remote("1111111111111111", "lan:a")
        alex.presence()
        XCTAssertEqual(room.state.members[1].path, .lan)
        lan.onPeerGone?("lan:a")
        XCTAssertEqual(room.state.members[1].path, .connecting)
        lan.sent = []
        alex.presence()
        XCTAssertEqual(sentMessages("lan:a").map(\.type), ["presence"])
    }
}

final class RoomIncomingPingTests: RoomManagerTestCase {
    private var alex: Remote!

    override func setUp() {
        super.setUp()
        joinActive()
        alex = remote("1111111111111111", "lan:a")
        alex.presence(["name": "Alex", "color": 4])
    }

    func testMapsAPingOntoTheTargetDisplayWithTheSendersTag() {
        alex.ping(["ping": "push", "x": 0.5, "y": 0.25])
        XCTAssertEqual(pings, [RemotePing(displayId: 100, x: 960, y: 270, id: "push", tag: NameTag(name: "Alex", color: 4))])
    }

    func testShowsAPacketThatArrivesTwiceOnlyOnce() {
        let packet = alex.packet(["t": "ping", "ping": "danger", "d": 1, "x": 0, "y": 0])
        lan.deliver("lan:a", packet)
        lan.deliver("lan:b", packet)
        XCTAssertEqual(pings.count, 1)
    }

    func testDropsPingsFromStrangersWhilePausedWhileTheRoomIsMutedAndFromMutedMembers() {
        remote("2222222222222222", "lan:c").ping()
        room.setStatusFlags(paused: true, roomMuted: false)
        alex.ping()
        room.setStatusFlags(paused: false, roomMuted: true)
        alex.ping()
        room.setStatusFlags(paused: false, roomMuted: false)
        room.muteMember(alex.peer, true)
        XCTAssertTrue(room.state.members[1].muted)
        alex.ping()
        XCTAssertEqual(pings.count, 0)
        room.muteMember(alex.peer, false)
        alex.ping()
        XCTAssertEqual(pings.count, 1)
    }

    func testDropsPingsFromAMemberThatNeedsAnUpdate() {
        alex.presence(["proto": 2])
        alex.ping()
        XCTAssertEqual(pings.count, 0)
    }

    func testRateLimitsEachMember0MeaningUnlimited() {
        profile.limit = 2
        for _ in 0..<5 { alex.ping() }
        XCTAssertEqual(pings.count, 2)
        profile.limit = 0
        for _ in 0..<50 { alex.ping() }
        XCTAssertEqual(pings.count, 52)
    }

    func testDropsAPingWhenThereIsNoDisplayToShowItOn() {
        alex.ping(["d": 3]) // this setup's resolveTarget only knows display 1
        XCTAssertEqual(pings.count, 0)
    }
}

final class RoomIncomingEmoteTests: RoomManagerTestCase {
    private var alex: Remote!

    override func setUp() {
        super.setUp()
        joinActive()
        alex = remote("1111111111111111", "lan:a")
        alex.presence(["name": "Pa", "color": 2])
    }

    func testEmitsRemoteEmotesWithTheSendersTagMappedOntoTheTargetDisplay() {
        alex.emote(["e": "gg", "d": 1, "x": 0.5, "y": 0.25])
        XCTAssertEqual(emotes, [RemoteEmote(displayId: 100, x: 960, y: 270, ref: "gg", peer: alex.peer, tag: NameTag(name: "Pa", color: 2))])
        XCTAssertEqual(pings.count, 0)
    }

    func testPassesACustomRefAndAnUnknownSlugOnUnchangedForTheOverlayToResolve() {
        let custom = "c:" + String(repeating: "ab", count: 16)
        alex.emote(["e": custom])
        alex.emote(["e": "from_the_future"])
        XCTAssertEqual(emotes.map(\.ref), [custom, "from_the_future"])
    }

    func testKeepsAnEmoteAtTheVeryEdgeOfTheDisplayInsideIt() {
        alex.emote(["x": 0, "y": 1])
        XCTAssertEqual(emotes.first?.x, 0)
        XCTAssertEqual(emotes.first?.y, 1080)
    }

    func testDropsAnEmoteOutsideTheDisplayBeforeItReachesTheOverlayLikeAPing() {
        // NSNull stands for NaN, which JSON.stringify writes as null.
        let bad: [[String: Any]] = [["x": 1.5], ["y": -0.1], ["x": NSNull()], ["d": 0], ["e": "No Way"]]
        for b in bad { alex.emote(b) }
        XCTAssertEqual(emotes.count, 0)
    }

    func testUsesThePingGatesStrangersPausedRoomMutedMemberMutedAndNeedsUpdate() {
        remote("2222222222222222", "lan:c").emote()
        room.setStatusFlags(paused: true, roomMuted: false)
        alex.emote()
        room.setStatusFlags(paused: false, roomMuted: true)
        alex.emote()
        room.setStatusFlags(paused: false, roomMuted: false)
        room.muteMember(alex.peer, true)
        alex.emote()
        room.muteMember(alex.peer, false)
        alex.presence(["proto": 2])
        alex.emote()
        XCTAssertEqual(emotes.count, 0)
        alex.presence(["proto": 1])
        alex.emote()
        XCTAssertEqual(emotes.count, 1)
    }

    func testDropsAnEmoteWhenThereIsNoDisplayToShowItOnAndShowsAPacketThatArrivesTwiceOnce() {
        alex.emote(["d": 3]) // this setup's resolveTarget only knows display 1
        XCTAssertEqual(emotes.count, 0)
        let packet = alex.packet(["t": "emote", "e": "gg", "d": 1, "x": 0, "y": 0])
        lan.deliver("lan:a", packet)
        lan.deliver("lan:b", packet)
        XCTAssertEqual(emotes.count, 1)
    }

    func testSharesTheIncomingLimitWithPings() {
        profile.limit = 5
        for _ in 0..<3 {
            alex.ping()
            alex.emote()
        }
        XCTAssertEqual(pings.count + emotes.count, 5)
    }
}

final class RoomOutgoingTests: RoomManagerTestCase {
    func testSendsAnEmoteToEachMemberOverItsPathAndNothingWhenIdleOrPaused() {
        room.sendEmote("gg", d: 1, x: 0.1, y: 0.2)
        XCTAssertEqual(lan.sent.count, 0)
        joinActive()
        remote("1111111111111111", "lan:a").presence()
        remote("2222222222222222", "lan:b").presence()
        lan.sent = []
        room.sendEmote("gg", shared: (d: 1, x: 0.1, y: 0.2))
        XCTAssertEqual(lan.sent.map(\.to).sorted(), ["lan:a", "lan:b"])
        let m = sentMessages("lan:a")[0]
        XCTAssertEqual(m.peer, SELF)
        XCTAssertEqual(m.body, .emote(ref: "gg", d: 1, x: 0.1, y: 0.2))
        room.setStatusFlags(paused: true, roomMuted: false)
        lan.sent = []
        room.sendEmote("gg", d: 1, x: 0.1, y: 0.2)
        XCTAssertEqual(lan.sent.count, 0)
        room.setStatusFlags(paused: false, roomMuted: true) // muting the room only silences what we hear
        lan.sent = []
        room.sendEmote("gg", d: 1, x: 0.1, y: 0.2)
        XCTAssertEqual(lan.sent.count, 2)
    }

    func testSendsAPingToEachMemberOverItsPathAndNothingWhenIdleOrPaused() {
        room.sendPing("omw", d: 1, x: 0.1, y: 0.2)
        XCTAssertEqual(lan.sent.count, 0)
        joinActive()
        remote("1111111111111111", "lan:a").presence()
        remote("2222222222222222", "lan:b").presence()
        lan.sent = []
        room.sendPing("omw", shared: (d: 1, x: 0.1, y: 0.2))
        XCTAssertEqual(lan.sent.map(\.to).sorted(), ["lan:a", "lan:b"])
        let m = sentMessages("lan:a")[0]
        XCTAssertEqual(m.peer, SELF)
        XCTAssertEqual(m.body, .ping(id: "omw", d: 1, x: 0.1, y: 0.2))
        room.setStatusFlags(paused: true, roomMuted: false)
        lan.sent = []
        room.sendPing("omw", d: 1, x: 0.1, y: 0.2)
        XCTAssertEqual(lan.sent.count, 0)
        room.setStatusFlags(paused: false, roomMuted: true)
        lan.sent = []
        room.sendPing("omw", d: 1, x: 0.1, y: 0.2)
        XCTAssertEqual(lan.sent.count, 2)
    }

    func testNumbersItsMessagesAndStampsThemWithTheClock() {
        joinActive()
        remote("1111111111111111", "lan:a").presence()
        lan.sent = []
        room.sendPing("omw", d: 1, x: 0.123456, y: 0.987654)
        room.sendPing("omw", d: 1, x: 0, y: 1)
        let sent = sentMessages("lan:a")
        XCTAssertEqual(sent[1].seq, sent[0].seq + 1)
        XCTAssertEqual(sent[0].ts, clock.now())
        XCTAssertEqual(sent[0].body, .ping(id: "omw", d: 1, x: 0.1235, y: 0.9877))
    }

    func testAnnouncesAStatusChangeRightAway() {
        joinActive()
        lan.sent = []
        room.setStatusFlags(paused: true, roomMuted: false)
        XCTAssertEqual(sentMessages("*").map(\.presenceStatus), [.paused])
        lan.sent = []
        room.setStatusFlags(paused: false, roomMuted: true)
        XCTAssertEqual(sentMessages("*").map(\.presenceStatus), [.muted])
        XCTAssertEqual(room.state.members[0].status, .muted)
    }

    func testAlsoSendsPresenceAndByeStraightToKnownMembers() {
        joinActive()
        remote("1111111111111111", "lan:a").presence()
        lan.sent = []
        room.setStatusFlags(paused: true, roomMuted: false)
        XCTAssertEqual(sentMessages("lan:a").map(\.presenceStatus), [.paused])
        lan.sent = []
        room.leave()
        XCTAssertEqual(sentMessages("lan:a").map(\.type), ["bye"])
    }

    func testAnnouncesOnATransportAsSoonAsItComesUp() {
        joinActive()
        lan.sent = []
        lan.setStatus(.starting)
        lan.setStatus(.ok)
        XCTAssertEqual(sentMessages("*").map(\.type), ["presence"])
    }

    func testReAnnouncesEvery2sAndAfterAProfileChange() {
        joinActive()
        lan.sent = []
        clock.advance(2000)
        XCTAssertGreaterThanOrEqual(sentMessages("*").filter { $0.type == "presence" }.count, 1)
        lan.sent = []
        profile.name = "Renamed"
        room.profileChanged()
        XCTAssertEqual(sentMessages("*").map(\.presenceName), ["Renamed"])
    }

    func testLeaveSaysByeStopsAndForgetsTheCodeQuitKeepsIt() {
        joinActive()
        lan.sent = []
        room.leave()
        XCTAssertEqual(sentMessages("*").map(\.type), ["bye"])
        XCTAssertNil(lan.started)
        XCTAssertEqual(saved.last, .some(nil))
        XCTAssertEqual(room.state.phase, .idle)
        XCTAssertNil(room.state.code)
        XCTAssertEqual(room.state.members, [])

        joinActive()
        let before = saved.count
        XCTAssertEqual(saved.last, .some(CODE))
        room.quit()
        XCTAssertEqual(saved.count, before)
        XCTAssertEqual(room.state.phase, .idle)
    }

    func testUsesANewPeerIDOnEveryJoinSoLeavingAndComingBackIsNotMistakenForAReplay() {
        var n = 0
        let fresh = makeRoom([lan], randomBytes: { k in (0..<k).map { _ in n += 1; return UInt8(n & 255) } }, resolveTarget: { _ in nil })
        fresh.join(CODE)
        let first = sentMessages("*").last!
        fresh.leave()
        lan.sent = []
        fresh.join(CODE)
        let second = sentMessages("*")[0]
        XCTAssertNotEqual(second.peer, first.peer)
        XCTAssertEqual(second.seq, 1)
        fresh.quit()
    }

    func testGoesBackToIdleAndReportsFailureWhenTheKeysCannotBeDerived() {
        struct OutOfMemory: Error {}
        let broken = makeRoom([lan], fill: 0, deriveKeys: { _, done in done(.failure(OutOfMemory())) }, resolveTarget: { _ in nil })
        var result: JoinResult?
        broken.join(CODE) { result = $0 }
        XCTAssertEqual(result, .failure(.failed))
        XCTAssertEqual(broken.state.phase, .idle)
        var created: Bool?
        broken.create { created = $0 }
        XCTAssertEqual(created, false)
        XCTAssertEqual(broken.state.phase, .idle)
        XCTAssertNil(lan.started)
    }

    func testALeaveWhileTheKeysAreStillBeingDerivedWins() {
        var finish: ((Result<RoomKeys, Error>) -> Void)?
        let slow = makeRoom([lan], deriveKeys: { _, done in finish = done })
        var result: JoinResult?
        slow.join(CODE) { result = $0 }
        XCTAssertEqual(slow.state.phase, .joining)
        slow.leave()
        finish?(.success(KEYS))
        XCTAssertEqual(result, .ok)
        clock.advance(3000)
        XCTAssertEqual(slow.state.phase, .idle)
        XCTAssertNil(lan.started)
    }

    func testASecondJoinWhileTheFirstIsStillDerivingReplacesIt() {
        var pending: [(String, (Result<RoomKeys, Error>) -> Void)] = []
        let slow = makeRoom([lan], deriveKeys: { code, done in pending.append((code, done)) })
        let other = RoomCode.make(random9: [9, 9, 9, 9, 9, 9, 9, 9, 9])
        slow.join(CODE)
        slow.join(other)
        pending[0].1(.success(RoomKeys(msgKey: Data(repeating: 9, count: 32), relayTopic: "first")))
        XCTAssertNil(lan.started) // the first room's keys came too late to matter
        pending[1].1(.success(KEYS))
        XCTAssertEqual(lan.started, KEYS)
        XCTAssertEqual(slow.state.code, RoomCode.format(other))
        XCTAssertEqual(lan.starts, 1)
    }

    func testDoesNotSendAMessageThatCannotFitInAPacket() {
        joinActive()
        lan.sent = []
        profile.name = String(repeating: "x", count: 2000) // nothing the settings allow, but it must not crash
        room.profileChanged()
        XCTAssertEqual(lan.sent.count, 0)
    }
}

final class RoomTwoTransportTests: RoomManagerTestCase {
    private var net: FakeTransport!
    private var both: RoomManager!
    private var got: [RemotePing] = []

    override func setUp() {
        super.setUp()
        net = FakeTransport(.internet)
        got = []
        both = makeRoom([lan, net], fill: 0xcd, resolveTarget: { _ in RoomTarget(displayId: 1, width: 100, height: 100) })
        both.onRemotePing = { [unowned self] in self.got.append($0) }
        both.join(CODE)
        clock.advance(3000)
    }

    private func netPresence(_ r: Remote) -> Data {
        r.packet(["t": "presence", "proto": 1, "app": "1", "name": "Alex", "color": 1, "status": "on"])
    }

    func testUsesLANWhileItIsAliveFallsBackToTheInternetAndReturnsToLAN() {
        let alex = remote("1111111111111111", "lan:a")
        alex.presence()
        net.deliver("net:x", netPresence(alex))
        XCTAssertEqual(both.state.members[1].path, .lan)
        clock.advance(6000)
        net.deliver("net:x", netPresence(alex))
        XCTAssertEqual(both.state.members[1].path, .internet)
        lan.sent = []
        net.sent = []
        both.sendPing("omw", d: 1, x: 0, y: 0)
        XCTAssertEqual(lan.sent.count, 0)
        XCTAssertEqual(net.sent.map(\.to), ["*"]) // relays: one send reaches everyone
        alex.presence()
        XCTAssertEqual(both.state.members[1].path, .lan)
    }

    func testShowsAPingThatArrivesOverBothTransportsOnce() {
        let alex = remote("1111111111111111", "lan:a")
        alex.presence()
        let packet = alex.packet(["t": "ping", "ping": "push", "d": 1, "x": 0.5, "y": 0.5])
        lan.deliver("lan:a", packet)
        net.deliver("net:x", packet)
        XCTAssertEqual(got.count, 1)
    }

    func testUnicastsPresenceOnlyOnLAN() {
        remote("1111111111111111", "lan:a").presence()
        let b = remote("2222222222222222", "net:x")
        net.deliver("net:x", b.packet(["t": "presence", "proto": 1, "app": "1", "name": "B", "color": 1, "status": "on"]))
        clock.advance(1000) // relays: at most one presence a second
        lan.sent = []
        net.sent = []
        both.profileChanged()
        XCTAssertEqual(lan.sent.map(\.to).sorted(), ["*", "lan:a"])
        XCTAssertEqual(net.sent.map(\.to), ["*"])
    }
}

final class RoomInternetTests: RoomManagerTestCase {
    private var net: FakeTransport!
    private var inet: RoomManager!
    private var gone: [RoomToast] = []

    private func make(_ transports: [Transport]) -> RoomManager {
        let r = makeRoom(transports, fill: 0xef, appVersion: "0.4.0", resolveTarget: { _ in RoomTarget(displayId: 1, width: 100, height: 100) })
        r.onToast = { [unowned self] in self.gone.append($0) }
        return r
    }

    private func netPresence(_ r: Remote, _ extra: [String: Any] = [:]) {
        var m: [String: Any] = ["t": "presence", "proto": 1, "app": "0.4.0", "name": "P\(r.peer.first!)", "color": 3, "status": "on"]
        m.merge(extra) { $1 }
        net.deliver(r.key, r.packet(m))
    }

    override func setUp() {
        super.setUp()
        net = FakeTransport(.internet)
        gone = []
        inet = make([lan, net])
    }

    private func joinNow() {
        inet.join(CODE)
        clock.advance(3000)
        XCTAssertEqual(inet.state.phase, .active)
    }

    private func sendPing() {
        inet.sendPing("omw", d: 1, x: 0.5, y: 0.5)
    }

    func testSendsAPingOnceOverASharedTransportHoweverManyMembersUseIt() {
        joinNow()
        netPresence(remote("1111111111111111", "net:a"))
        netPresence(remote("2222222222222222", "net:b"))
        net.sent = []
        sendPing()
        XCTAssertEqual(net.sent.map(\.to), ["*"])
        XCTAssertEqual(decode(net)[0].body, .ping(id: "omw", d: 1, x: 0.5, y: 0.5))
    }

    func testCapsPingsOverASharedTransportAt5PerSecondWithBurstsOf10WhileLANMembersStillGetEveryPing() {
        joinNow()
        remote("1111111111111111", "lan:a").presence()
        netPresence(remote("2222222222222222", "net:b"))
        lan.sent = []
        net.sent = []
        for _ in 0..<15 { sendPing() }
        XCTAssertEqual(lan.sent.filter { $0.to == "lan:a" }.count, 15)
        XCTAssertEqual(decode(net).filter { $0.type == "ping" }.count, 10)
        net.sent = []
        clock.advance(1000)
        for _ in 0..<15 { sendPing() }
        XCTAssertEqual(decode(net).filter { $0.type == "ping" }.count, 5)
    }

    func testSendsAnEmoteOnceOverASharedTransportAndPingsAndEmotesShareOneCap() {
        joinNow()
        remote("1111111111111111", "lan:a").presence()
        netPresence(remote("2222222222222222", "net:b"))
        netPresence(remote("3333333333333333", "net:c"))
        lan.sent = []
        net.sent = []
        inet.sendEmote("gg", d: 1, x: 0.5, y: 0.5)
        XCTAssertEqual(net.sent.map(\.to), ["*"])
        XCTAssertEqual(decode(net)[0].body, .emote(ref: "gg", d: 1, x: 0.5, y: 0.5))
        net.sent = []
        clock.advance(1000)
        for i in 0..<15 {
            if i % 2 == 1 { sendPing() } else { inet.sendEmote("gg", d: 1, x: 0.5, y: 0.5) }
        }
        func sent() -> [String] { decode(net).map(\.type).filter { $0 != "presence" } }
        XCTAssertEqual(sent(), ["emote", "ping", "emote", "ping", "emote", "ping", "emote", "ping", "emote", "ping"])
        let toLan = decode(lan, to: "lan:a").map(\.type)
        XCTAssertEqual(toLan.filter { $0 == "emote" || $0 == "ping" }.count, 16) // LAN members still get every one
        net.sent = []
        clock.advance(1000)
        for _ in 0..<15 { inet.sendEmote("gg", d: 1, x: 0.5, y: 0.5) }
        XCTAssertEqual(sent().count, 5)
    }

    func testNeverCapsPresenceOrByeOverASharedTransport() {
        joinNow()
        netPresence(remote("2222222222222222", "net:b"))
        for _ in 0..<20 { sendPing() }
        clock.advance(1000)
        net.sent = []
        inet.setStatusFlags(paused: false, roomMuted: true)
        inet.leave()
        XCTAssertEqual(decode(net).map(\.type), ["presence", "bye"])
    }

    func testAnswersLinkUpAndNewMembersWithPresenceAtOnceThenAtMostOnceASecondTheLatestStateWinning() {
        joinNow()
        clock.advance(1500)
        net.sent = []
        net.linkUp()
        XCTAssertEqual(decode(net).map(\.type), ["presence"])
        netPresence(remote("2222222222222222", "net:b"))
        profile.name = "Later"
        inet.profileChanged()
        XCTAssertEqual(decode(net).count, 1)
        clock.advance(999)
        XCTAssertEqual(decode(net).count, 1)
        clock.advance(1)
        XCTAssertEqual(decode(net).map(\.presenceName), ["Me", "Later"])
    }

    func testJoiningOverRelaysOnlyAnnouncesAsSoonAsTheFirstRelayIsLiveNotAtThe10sRound() {
        let only = make([net])
        net.startStatus = .starting
        only.join(CODE)
        clock.advance(300)
        net.sent = []
        net.linkUp()
        clock.advance(700)
        XCTAssertTrue(decode(net).map(\.type).contains("presence"))
        only.quit()
    }

    func testSettles3sAfterTheInternetTransportLeavesStarting() {
        net.startStatus = .starting
        inet.join(CODE)
        clock.advance(5000)
        XCTAssertEqual(inet.state.phase, .joining)
        net.setStatus(.ok)
        clock.advance(2999)
        XCTAssertEqual(inet.state.phase, .joining)
        clock.advance(1)
        XCTAssertEqual(inet.state.phase, .active)
    }

    func testSettlesAtThe15sCapWhenTheInternetNeverLeavesStarting() {
        net.startStatus = .starting
        inet.join(CODE)
        clock.advance(14_999)
        XCTAssertEqual(inet.state.phase, .joining)
        clock.advance(1)
        XCTAssertEqual(inet.state.phase, .active)
    }

    func testNeverSettlesLaterThanTheCapWhenTheInternetComesUpLate() {
        net.startStatus = .starting
        inet.join(CODE)
        clock.advance(13_000)
        net.setStatus(.ok)
        clock.advance(2000)
        XCTAssertEqual(inet.state.phase, .active)
    }

    func testSettlesAfter3sWhenInternetIsNotAllowed() {
        inet.setInternetAllowed(false)
        net.startStatus = .starting
        inet.join(CODE)
        XCTAssertEqual(net.starts, 0)
        clock.advance(3000)
        XCTAssertEqual(inet.state.phase, .active)
        XCTAssertEqual(inet.state.internet, .off)
    }

    func testKeepsAnInternetPathAliveFor25sAndDropsAnInternetMemberAfter30s() {
        joinNow()
        netPresence(remote("2222222222222222", "net:b"))
        remote("1111111111111111", "lan:a").presence()
        clock.advance(24_000)
        XCTAssertEqual(inet.state.members.first { $0.peer == "2222222222222222" }?.path, .internet)
        XCTAssertNil(inet.state.members.first { $0.peer == "1111111111111111" }) // LAN only: 15 s
        clock.advance(1000)
        XCTAssertNotEqual(inet.state.members.first { $0.peer == "2222222222222222" }?.path, .internet)
        clock.advance(4000)
        XCTAssertEqual(inet.state.members.count, 2)
        clock.advance(1000)
        XCTAssertEqual(inet.state.members.count, 1)
        XCTAssertEqual(gone.filter { if case .disconnected = $0 { return true } else { return false } }.count, 2)
    }

    func testSetInternetAllowedFalseMidRoomStopsTheRelayTransportWithoutAByeAndForgetsInternetPaths() {
        joinNow()
        netPresence(remote("2222222222222222", "net:b"))
        net.sent = []
        inet.setInternetAllowed(false)
        XCTAssertEqual(net.sent.count, 0)
        XCTAssertNil(net.started)
        XCTAssertEqual(inet.state.internet, .off)
        XCTAssertNotEqual(inet.state.members[1].path, .internet)
        sendPing()
        XCTAssertEqual(net.sent.count, 0)
    }

    func testSetInternetAllowedTrueMidRoomStartsItWithTheCurrentKeysAndAnnounces() {
        inet.setInternetAllowed(false)
        joinNow()
        XCTAssertEqual(net.starts, 0)
        inet.setInternetAllowed(true)
        XCTAssertEqual(net.started, KEYS)
        XCTAssertEqual(decode(net).map(\.type), ["presence"])
        XCTAssertEqual(inet.state.internet, .ok)
    }

    func testTogglingInternetOffOnOffLeavesOneStoppedRelayTransport() {
        joinNow()
        inet.setInternetAllowed(false)
        inet.setInternetAllowed(true)
        inet.setInternetAllowed(false)
        XCTAssertEqual(net.starts - net.stops, 0)
        XCTAssertNil(net.started)
        XCTAssertEqual(inet.state.internet, .off)
    }
}

import Foundation

/// A ping from a room member, already placed on one of this machine's displays.
public struct RemotePing: Equatable, Sendable {
    public var displayId: UInt32
    /// Points from the display's top-left corner.
    public var x: Double
    public var y: Double
    public var id: String
    public var tag: NameTag
}

public struct RemoteEmote: Equatable, Sendable {
    public var displayId: UInt32
    public var x: Double
    public var y: Double
    public var ref: EmoteRef
    /// The sender, so their earlier emote can be replaced: everyone has one on screen at a time.
    public var peer: String
    public var tag: NameTag
}

public struct NameTag: Equatable, Sendable {
    public var name: String
    /// Index into `TagColors.all`.
    public var color: Int
}

public enum RoomToast: Equatable, Sendable {
    case joined(name: String)
    case left(name: String)
    case disconnected(name: String)
    /// `code` is the display form.
    case joinedRoom(code: String)
    case full
}

public struct RoomProfile: Equatable, Sendable {
    public var name: String
    /// Index into `TagColors.all`.
    public var color: Int
    /// Incoming pings and emotes per second per member; 0 = unlimited.
    public var limit: Int

    public init(name: String, color: Int, limit: Int) {
        self.name = name
        self.color = color
        self.limit = limit
    }
}

/// Where a ping for some display number lands here.
public struct RoomTarget: Equatable, Sendable {
    public var displayId: UInt32
    public var width: Double
    public var height: Double

    public init(displayId: UInt32, width: Double, height: Double) {
        self.displayId = displayId
        self.width = width
        self.height = height
    }
}

public struct RoomDeps {
    public var transports: [Transport]
    /// The clock and the timers. Must run its timers on the queue the manager is used on.
    public var scheduler: RoomScheduler
    public var randomBytes: (Int) -> [UInt8]
    /// Canonical code → keys. Must call back on the manager's queue, and should do the work elsewhere.
    public var deriveKeys: (String, @escaping (Result<RoomKeys, Error>) -> Void) -> Void
    /// Goes into presence, so the others know what this app can show. Read on every use.
    public var appVersion: () -> String
    /// Read on every use, so settings changes apply at once.
    public var profile: () -> RoomProfile
    /// Display number → where a ping for it lands here, or nil to drop it. The hook share mode will replace.
    public var resolveTarget: (Int) -> RoomTarget?

    public init(
        transports: [Transport],
        scheduler: RoomScheduler,
        randomBytes: @escaping (Int) -> [UInt8],
        deriveKeys: @escaping (String, @escaping (Result<RoomKeys, Error>) -> Void) -> Void,
        appVersion: @escaping () -> String,
        profile: @escaping () -> RoomProfile,
        resolveTarget: @escaping (Int) -> RoomTarget?
    ) {
        self.transports = transports
        self.scheduler = scheduler
        self.randomBytes = randomBytes
        self.deriveKeys = deriveKeys
        self.appVersion = appVersion
        self.profile = profile
        self.resolveTarget = resolveTarget
    }
}

/// The room: who is in it, what we send, and what we let through. Talks to the network only through transports,
/// which carry sealed packets.
///
/// Not thread-safe, like the JavaScript it is ported from: call everything on one queue (the main queue in the app),
/// which must be the queue the transports and the scheduler deliver on. Every handler runs there too.
public final class RoomManager {
    public static let maxMembers = 8
    private static let settleMs = 3000.0
    /// Relays can take a while to answer: the "room full" check never waits longer than this after joining.
    private static let settleCapMs = 15_000.0
    private static let tickMs = 1000.0
    /// How often presence is re-announced on each transport.
    private static func presenceMs(_ kind: TransportKind) -> Int { kind == .lan ? 2000 : 10_000 }
    /// How long a path counts as alive after the last packet over it.
    private static func aliveMs(_ kind: TransportKind) -> Int { kind == .lan ? 6000 : 25_000 }
    /// Silence before a member is dropped: longer once it was heard over the internet, where presence comes every 10 s.
    private static func dropMs(_ kind: TransportKind) -> Int { kind == .lan ? 15_000 : 30_000 }
    /// Pings and emotes over relays, per sender: one publish reaches everyone, and public relays only tolerate so much.
    public static let relayPingRate = 5.0
    public static let relayPingBurst = 10.0
    /// Presence asked for on a shared transport (a change, a new link, a new member): at most this often.
    private static let sharedPresenceMs = 1000
    /// The first app version that shows emotes.
    private static let emotesSince = "0.5.0"
    private static let unreachableMs = 20_000
    private static let lonelyMs = 20_000
    private static let staleStrikeLimit = 3
    /// A housekeeping tick this late means the computer slept: nobody was heard because we weren't listening.
    private static let sleepGapMs = 5000
    /// How long the clock warning stays up after the last stale presence.
    private static let skewHintMs = 30_000

    private final class Member {
        let peer: String
        var name: String
        var color: Int
        var status: MemberStatus
        var needsUpdate = false
        var noEmotes = false
        var muted = false
        let firstSeen: Int
        /// Ever heard over the internet: dropped after the longer silence.
        var viaInternet = false
        /// Per transport kind: the address it was last heard from, and when.
        var paths: [TransportKind: (key: PeerKey, seenAt: Int)] = [:]

        init(peer: String, name: String, color: Int, status: MemberStatus, firstSeen: Int) {
            self.peer = peer
            self.name = name
            self.color = color
            self.status = status
            self.firstSeen = firstSeen
        }
    }

    // MARK: Events

    /// The room changed. Not called when nothing in the state differs from the last call.
    public var onState: ((RoomState) -> Void)?
    public var onRemotePing: ((RemotePing) -> Void)?
    public var onRemoteEmote: ((RemoteEmote) -> Void)?
    public var onToast: ((RoomToast) -> Void)?
    /// The canonical code "rejoin last room" should remember, or nil to forget it.
    public var onSaveCode: ((String?) -> Void)?

    // MARK: State

    /// Our peer ID: random per join, since a peer that said bye stays "gone" to the others for their whole session.
    public private(set) var selfPeer: String
    private var phase: RoomPhase = .idle
    private var code: String?
    private var keys: RoomKeys?
    /// Bumped on every join and leave, so a join still deriving keys can tell it was cancelled.
    private var session = 0
    private var seq = 0
    private var members: [String: Member] = [:]
    /// Peer IDs in the order they appeared (a JavaScript Map keeps it; a dictionary doesn't).
    private var memberOrder: [String] = []
    private var answered = Set<PeerKey>()
    /// Per peer ID: stale presences seen, and when the last one came. Never turns into a member.
    private var staleStrikes: [String: (count: Int, at: Int)] = [:]
    private var guardian: ReplayGuard
    private let limiter: RateLimiter
    private var paused = false
    private var roomMuted = false
    private var aloneSince: Int?
    private var lastPresence: [TransportKind: Int] = [:]
    private var ticker: RoomTimer?
    private var lastTick = 0
    /// When we last woke from sleep: members count as heard then, so they get a fresh grace period.
    private var wokeAt = 0
    private var settle: RoomTimer?
    /// The settle timer has been cut down from the cap to `settleMs`.
    private var settleShort = false
    private var joinedAt = 0
    private var lastState: RoomState?
    private var internetAllowed = true
    /// The transports running for this room: all of them, except the internet one while it isn't allowed.
    private var active: [Transport] = []
    private let relayCap: RateLimiter
    /// A presence waiting out `sharedPresenceMs`, per shared transport.
    private var sharedTimers: [ObjectIdentifier: RoomTimer] = [:]
    private let deps: RoomDeps
    private var now: () -> Int

    public init(_ deps: RoomDeps) {
        self.deps = deps
        let scheduler = deps.scheduler
        now = { scheduler.now() }
        selfPeer = Hex.encode(deps.randomBytes(8))
        guardian = ReplayGuard(now: now)
        limiter = RateLimiter(now: now)
        relayCap = RateLimiter(now: now)
        for t in deps.transports {
            t.onPacket = { [weak self, unowned t] peer, packet in self?.onPacket(t, peer, packet) }
            t.onPeerGone = { [weak self, unowned t] peer in self?.onPeerGone(t, peer) }
            t.onStatus = { [weak self, unowned t] s in
                guard let self else { return }
                // A fresh socket: tell everyone now rather than at the next round. Relays say so per relay, with linkUp.
                if s == .ok, !t.shared { self.announce(t) }
                self.checkSettle()
                self.emitState()
            }
            t.onLinkUp = { [weak self, unowned t] in self?.announce(t) }
        }
    }

    deinit {
        // Nobody is left to say bye for; at least nothing keeps ticking or holding sockets.
        ticker?.cancel()
        settle?.cancel()
        for timer in sharedTimers.values { timer.cancel() }
        for t in active { t.stop() }
    }

    // MARK: Joining and leaving

    /// Starts a new room. `completion` gets false when the keys couldn't be derived (the room is idle again).
    public func create(completion: ((Bool) -> Void)? = nil) {
        start(RoomCode.make(random9: deps.randomBytes(9))) { completion?($0) }
    }

    /// Joins the room whose code is somewhere in `text`. `completion` runs on the manager's queue: at once when the
    /// text holds no usable code, otherwise once the keys are derived (the room is then joining, not yet active).
    public func join(_ text: String, completion: ((JoinResult) -> Void)? = nil) {
        switch RoomCode.parse(text) {
        case .failure(let e):
            completion?(.failure(e == .mistyped ? .mistyped : .invalid))
        case .success(let code):
            start(code) { completion?($0 ? .ok : .failure(.failed)) }
        }
    }

    /// Leaves the room and forgets it, so it isn't rejoined on the next launch.
    public func leave() {
        if phase == .idle { return }
        stop()
        onSaveCode?(nil)
    }

    /// Says bye on the way out, but keeps the code for "rejoin last room".
    public func quit() {
        if phase != .idle { stop() }
    }

    // MARK: Sending

    /// `d` is the display number, `x` and `y` the position as a fraction of that display (see `DisplayNumbers.toShared`).
    public func sendPing(_ ping: String, d: Int, x: Double, y: Double) {
        sendShared { peer, seq, ts in RoomMessage(peer: peer, seq: seq, ts: ts, body: .ping(id: ping, d: d, x: x, y: y)) }
    }

    public func sendPing(_ ping: String, shared: (d: Int, x: Double, y: Double)) {
        sendPing(ping, d: shared.d, x: shared.x, y: shared.y)
    }

    public func sendEmote(_ ref: EmoteRef, d: Int, x: Double, y: Double) {
        sendShared { peer, seq, ts in RoomMessage(peer: peer, seq: seq, ts: ts, body: .emote(ref: ref, d: d, x: x, y: y)) }
    }

    public func sendEmote(_ ref: EmoteRef, shared: (d: Int, x: Double, y: Double)) {
        sendEmote(ref, d: shared.d, x: shared.x, y: shared.y)
    }

    /// A ping or an emote: each member gets it over its own route; shared transports get one send, within the relay cap.
    private func sendShared(_ body: (String, Int, Int) -> RoomMessage) {
        if phase == .idle || keys == nil || paused { return }
        guard let packet = seal(body) else { return }
        var sharedRoutes: [Transport] = []
        for m in orderedMembers() {
            guard let route = route(m) else { continue }
            if route.transport.shared {
                if !sharedRoutes.contains(where: { $0 === route.transport }) { sharedRoutes.append(route.transport) }
            } else {
                route.transport.send(to: route.key, packet: packet)
            }
        }
        for t in sharedRoutes where relayCap.allow(t.kind.rawValue, perSecond: Self.relayPingRate, burst: Self.relayPingBurst) {
            t.broadcast(packet)
        }
    }

    // MARK: Settings

    /// `paused`: the app is switched off, so nothing is sent or shown. `roomMuted`: only what we hear is silenced.
    public func setStatusFlags(paused: Bool, roomMuted: Bool) {
        if paused == self.paused && roomMuted == self.roomMuted { return }
        self.paused = paused
        self.roomMuted = roomMuted
        announce()
        emitState()
    }

    public func muteMember(_ peer: String, _ on: Bool) {
        guard let m = members[peer] else { return }
        m.muted = on
        emitState()
    }

    /// "Allow internet connections". Turning it off mid-room sends no bye: a bye makes the others ignore our peer ID
    /// for their whole session, LAN included. Members only reachable over the internet time out instead.
    public func setInternetAllowed(_ on: Bool) {
        if on == internetAllowed { return }
        internetAllowed = on
        guard let keys else { return } // idle, or still deriving keys: start() reads the flag
        for t in deps.transports where t.kind == .internet {
            if on {
                if !isActive(t) { active.append(t) }
                t.start(keys: keys)
                announce(t)
                continue
            }
            active.removeAll { $0 === t }
            cancelShared(t)
            t.stop()
            for m in members.values {
                guard let p = m.paths[.internet] else { continue }
                answered.remove(p.key)
                m.paths[.internet] = nil
            }
        }
        checkSettle()
        emitState()
    }

    /// Name or colour changed: tell everyone now.
    public func profileChanged() {
        announce()
        emitState()
    }

    public var state: RoomState {
        let now = self.now()
        func status(_ kind: TransportKind) -> TransportStatus {
            phase == .idle ? .off : (active.first { $0.kind == kind }?.status ?? .off)
        }
        var list: [RoomMember] = []
        if phase != .idle {
            let p = deps.profile()
            list.append(RoomMember(peer: selfPeer, name: p.name, color: p.color, path: .lan, status: ownStatus(),
                                   needsUpdate: false, noEmotes: false, muted: false, isSelf: true))
            for m in orderedMembers() {
                list.append(RoomMember(peer: m.peer, name: m.name, color: m.color, path: path(m, now), status: m.status,
                                       needsUpdate: m.needsUpdate, noEmotes: m.noEmotes, muted: m.muted, isSelf: false))
            }
        }
        return RoomState(
            phase: phase,
            code: code.map(RoomCode.format),
            members: list,
            lan: status(.lan),
            internet: status(.internet),
            lonely: aloneSince.map { now - $0 >= Self.lonelyMs } ?? false,
            clockSkew: staleStrikes.values.contains { $0.count >= Self.staleStrikeLimit && now - $0.at < Self.skewHintMs }
        )
    }

    // MARK: Internals

    private func orderedMembers() -> [Member] {
        memberOrder.compactMap { members[$0] }
    }

    private func isActive(_ t: Transport) -> Bool {
        active.contains { $0 === t }
    }

    /// `done(false)` when the keys couldn't be derived: the room is back to idle.
    private func start(_ code: String, done: @escaping (Bool) -> Void) {
        if phase != .idle { leave() }
        session += 1
        let session = self.session
        selfPeer = Hex.encode(deps.randomBytes(8))
        seq = 0
        phase = .joining
        self.code = code
        guardian = ReplayGuard(now: now)
        aloneSince = now()
        emitState()
        deps.deriveKeys(code) { [weak self] result in
            guard let self else { return }
            guard case .success(let keys) = result else {
                if session == self.session { self.stop() }
                done(false)
                return
            }
            if session != self.session { // left while deriving
                done(true)
                return
            }
            self.keys = keys
            self.joinedAt = self.now()
            self.lastTick = self.joinedAt
            self.settleShort = false
            self.settle = self.deps.scheduler.after(Self.settleCapMs) { [weak self] in self?.settled() }
            for t in self.deps.transports where t.kind != .internet || self.internetAllowed {
                if !self.isActive(t) { self.active.append(t) }
            }
            for t in self.active { t.start(keys: keys) }
            self.announce()
            self.ticker = self.deps.scheduler.every(Self.tickMs) { [weak self] in self?.tick() }
            self.checkSettle()
            self.emitState()
            done(true)
        }
    }

    /// "Room full" is judged 3 s after the relays have answered or given up, so members only reachable over the
    /// internet count too; never later than `settleCapMs` after joining.
    private func checkSettle() {
        guard phase == .joining, let settle, !settleShort else { return }
        if active.contains(where: { $0.shared && ($0.status == .off || $0.status == .starting) }) { return }
        settleShort = true
        settle.cancel()
        let wait = min(Self.settleMs, Double(joinedAt) + Self.settleCapMs - Double(now()))
        self.settle = deps.scheduler.after(max(0, wait)) { [weak self] in self?.settled() }
    }

    private func settled() {
        settle = nil
        if members.count >= Self.maxMembers {
            stop()
            onToast?(.full)
            return
        }
        phase = .active
        onSaveCode?(code)
        if let code { onToast?(.joinedRoom(code: RoomCode.format(code))) }
        emitState()
    }

    private func stop() {
        session += 1
        if keys != nil {
            if let bye = seal({ peer, seq, ts in RoomMessage(peer: peer, seq: seq, ts: ts, body: .bye) }) {
                for t in active { spread(t, bye) }
            }
            for t in active { t.stop() }
        }
        active.removeAll()
        for timer in sharedTimers.values { timer.cancel() }
        sharedTimers.removeAll()
        ticker?.cancel()
        settle?.cancel()
        ticker = nil
        settle = nil
        phase = .idle
        code = nil
        keys = nil
        members.removeAll()
        memberOrder.removeAll()
        answered.removeAll()
        staleStrikes.removeAll()
        lastPresence.removeAll()
        aloneSince = nil
        emitState()
    }

    private func tick() {
        let now = self.now()
        if now - lastTick > Self.sleepGapMs { wokeAt = now }
        lastTick = now
        for (peer, s) in staleStrikes where now - s.at >= Self.skewHintMs { staleStrikes[peer] = nil }
        for m in orderedMembers() {
            let heard = max(m.paths.values.map(\.seenAt).max() ?? Int.min, m.firstSeen, wokeAt)
            if now - heard >= Self.dropMs(m.viaInternet ? .internet : .lan) { remove(m, left: false) }
        }
        for t in active where now - (lastPresence[t.kind] ?? 0) >= Self.presenceMs(t.kind) {
            sendPresence(t)
        }
        emitState()
    }

    private func onPacket(_ t: Transport, _ key: PeerKey, _ packet: Data) {
        guard let keys else { return }
        guard let plain = RoomCrypto.open(key: keys.msgKey, packet: packet), let msg = RoomProtocol.decode(plain),
              msg.peer != selfPeer else { return }
        let verdict = guardian.accept(peer: msg.peer, seq: msg.seq, ts: msg.ts)
        if verdict == .stale { return onStale(msg) }
        if verdict != .ok { return }
        staleStrikes[msg.peer] = nil

        if case .presence(let proto, let app, let name, let color, let status) = msg.body {
            return onPresence(t, key, peer: msg.peer, proto: proto, app: app, name: name, color: color, status: status)
        }
        let member = members[msg.peer]
        if case .bye = msg.body {
            guardian.markGone(msg.peer)
            if let member { remove(member, left: true) }
            return
        }
        guard let m = member else { return }
        heard(m, t, key)
        // Pings and emotes pass the same gates and share one budget per member.
        if paused || roomMuted || m.muted || m.needsUpdate { return }
        if !limiter.allow(m.peer, perSecond: Double(deps.profile().limit)) { return }
        let tag = NameTag(name: m.name, color: m.color)
        switch msg.body {
        case .ping(let id, let d, let x, let y):
            guard let target = deps.resolveTarget(d) else { return }
            onRemotePing?(RemotePing(displayId: target.displayId, x: x * target.width, y: y * target.height, id: id, tag: tag))
        case .emote(let ref, let d, let x, let y):
            guard let target = deps.resolveTarget(d) else { return }
            onRemoteEmote?(RemoteEmote(displayId: target.displayId, x: x * target.width, y: y * target.height, ref: ref, peer: m.peer, tag: tag))
        case .presence, .bye:
            return
        }
    }

    private func onPresence(_ t: Transport, _ key: PeerKey, peer: String, proto: Int, app: String, name: String, color: Int, status: MemberStatus) {
        let existing = members[peer]
        let isNew = existing == nil
        let m = existing ?? Member(peer: peer, name: name, color: color, status: status, firstSeen: now())
        if isNew {
            members[peer] = m
            memberOrder.append(peer)
            aloneSince = nil
        }
        m.name = name
        m.color = color
        m.status = status
        m.needsUpdate = proto != RoomProtocol.version
        m.noEmotes = RoomWire.isOlder(app, than: Self.emotesSince)
        heard(m, t, key)
        if !answered.contains(key) {
            answered.insert(key)
            if t.shared {
                announce(t) // everyone hears it anyway, so it's an ordinary presence
            } else if let packet = presencePacket() {
                t.send(to: key, packet: packet)
            }
        }
        if isNew, phase == .active { onToast?(.joined(name: m.name)) }
        emitState()
    }

    /// Packets more than 10 minutes off our clock. Anyone on the network can replay old ones, so they never create,
    /// refresh or reach a member; a few presences only raise the room-level clock warning.
    private func onStale(_ msg: RoomMessage) {
        guard case .presence = msg.body else { return }
        let s = staleStrikes[msg.peer] ?? (count: 0, at: 0)
        staleStrikes[msg.peer] = (count: s.count + 1, at: now())
        emitState()
    }

    private func onPeerGone(_ t: Transport, _ key: PeerKey) {
        for m in members.values where m.paths[t.kind]?.key == key { m.paths[t.kind] = nil }
        answered.remove(key)
        emitState()
    }

    private func heard(_ m: Member, _ t: Transport, _ key: PeerKey) {
        m.paths[t.kind] = (key: key, seenAt: now())
        if t.kind == .internet { m.viaInternet = true }
    }

    private func remove(_ m: Member, left: Bool) {
        members[m.peer] = nil
        memberOrder.removeAll { $0 == m.peer }
        limiter.forget(m.peer)
        for p in m.paths.values { answered.remove(p.key) }
        if members.isEmpty, phase != .idle { aloneSince = now() }
        onToast?(left ? .left(name: m.name) : .disconnected(name: m.name))
        emitState()
    }

    /// LAN while it is alive, else internet, else nothing.
    private func route(_ m: Member) -> (transport: Transport, key: PeerKey)? {
        let now = self.now()
        for kind in [TransportKind.lan, .internet] {
            guard let p = m.paths[kind], let transport = active.first(where: { $0.kind == kind }) else { continue }
            if now - p.seenAt < Self.aliveMs(kind) { return (transport, p.key) }
        }
        return nil
    }

    private func path(_ m: Member, _ now: Int) -> MemberPath {
        if let r = route(m) { return r.transport.kind == .lan ? .lan : .internet }
        return now - m.firstSeen < Self.unreachableMs ? .connecting : .unreachable
    }

    private func ownStatus() -> MemberStatus {
        paused ? .paused : roomMuted ? .muted : .on
    }

    private func presencePacket() -> Data? {
        let p = deps.profile()
        let app = deps.appVersion()
        let status = ownStatus()
        return seal { peer, seq, ts in
            RoomMessage(peer: peer, seq: seq, ts: ts, body: .presence(proto: RoomProtocol.version, app: app, name: p.name, color: p.color, status: status))
        }
    }

    /// Presence on one transport, or on every running one. A shared transport sends at most once a second: the first
    /// request goes out at once, later ones in that second become one presence at its end, with the latest state.
    private func announce(_ only: Transport? = nil) {
        if keys == nil { return }
        for t in only.map({ [$0] }) ?? active {
            if !isActive(t) { continue }
            if !t.shared {
                sendPresence(t)
                continue
            }
            let wait = lastPresence[t.kind].map { $0 + Self.sharedPresenceMs - now() } ?? 0
            if wait <= 0 {
                sendPresence(t)
            } else if sharedTimers[ObjectIdentifier(t)] == nil {
                sharedTimers[ObjectIdentifier(t)] = deps.scheduler.after(Double(wait)) { [weak self, weak t] in
                    guard let self, let t else { return }
                    self.sharedTimers[ObjectIdentifier(t)] = nil
                    if self.keys != nil, self.isActive(t) { self.sendPresence(t) }
                }
            }
        }
    }

    private func sendPresence(_ t: Transport) {
        cancelShared(t)
        if let packet = presencePacket() { spread(t, packet) }
        lastPresence[t.kind] = now()
    }

    private func cancelShared(_ t: Transport) {
        sharedTimers.removeValue(forKey: ObjectIdentifier(t))?.cancel()
    }

    /// Broadcast, and on LAN also straight to every member heard there: Wi-Fi broadcast has no retries and some
    /// routers filter it, unicast doesn't. Duplicates are dropped by the receiver's replay guard.
    private func spread(_ t: Transport, _ packet: Data) {
        t.broadcast(packet)
        if t.shared { return } // one send already reached everyone
        for m in orderedMembers() {
            if let key = m.paths[.lan]?.key { t.send(to: key, packet: packet) }
        }
    }

    /// Nil when the message doesn't fit in a packet (a name far beyond what settings allow): it just isn't sent.
    private func seal(_ body: (String, Int, Int) -> RoomMessage) -> Data? {
        guard let keys else { return nil }
        seq += 1
        return RoomCrypto.seal(key: keys.msgKey, plain: RoomProtocol.encode(body(selfPeer, seq, now())))
    }

    private func emitState() {
        let s = state
        if s == lastState { return }
        lastState = s
        onState?(s)
    }
}

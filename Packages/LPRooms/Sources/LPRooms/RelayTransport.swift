import Foundation

public struct RelayTransportOptions {
    /// The relays to use; upstream's pinned list unless tests or a development build say otherwise.
    public var urls: [String]
    /// Opens WebSockets; nil for URLSession's.
    public var socket: RelaySocketFactory?
    /// 0 ..< 1, for the reconnect jitter.
    public var random: () -> Double

    public init(urls: [String] = Relays.all, socket: RelaySocketFactory? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.urls = urls
        self.socket = socket
        self.random = random
    }
}

/// Room packets over public Nostr relays: each packet is one ephemeral event on the room's topic, signed with a key
/// made fresh on every join. One publish reaches every member, so this transport is shared. Members leave by bye or
/// timeout; relays have no per-peer connections, so `onPeerGone` is never called.
public final class RelayTransport: Transport {
    /// A sealed packet (≤ 1200 bytes) in base64.
    private static let maxContent = 1600
    /// Longest a stop waits for the relays to take the bye RoomManager sent just before.
    private static let drainMs = 500.0

    public let kind = TransportKind.internet
    public let shared = true
    public private(set) var status: TransportStatus = .off
    public var onPacket: ((PeerKey, Data) -> Void)?
    public var onPeerGone: ((PeerKey) -> Void)?
    public var onStatus: ((TransportStatus) -> Void)?
    public var onLinkUp: (() -> Void)?

    private var pool: RelayPool?
    private var pair: NostrKeyPair?
    private var topic = ""
    /// The id of the last event that reached a relay and isn't acknowledged yet: the bye a stop waits for.
    private var lastSent: String?
    /// Pools still letting a bye out, and who is waiting for them.
    private var closing = 0
    private var closedWaiters: [() -> Void] = []
    private let opts: RelayTransportOptions
    private let socket: RelaySocketFactory
    private let queue: DispatchQueue
    private let scheduler: RoomScheduler

    /// `queue` is where the transport is used and where its handlers run; `scheduler` must fire on it.
    public init(_ opts: RelayTransportOptions = RelayTransportOptions(), queue: DispatchQueue = .main, scheduler: RoomScheduler? = nil) {
        self.opts = opts
        self.queue = queue
        self.scheduler = scheduler ?? DispatchRoomScheduler(queue: queue)
        socket = opts.socket ?? (queue === DispatchQueue.main ? URLSessionRelaySockets.main : URLSessionRelaySockets(queue: queue)).factory
    }

    deinit {
        pool?.stop()
    }

    public func start(keys: RoomKeys) {
        if pool != nil { return }
        let pair = Nostr.makeKeyPair()
        let pool = RelayPool(RelayPoolOptions(urls: opts.urls, topic: keys.relayTopic, pubkey: pair.pubkey, socket: socket,
                                              random: opts.random, scheduler: scheduler))
        self.pool = pool
        self.pair = pair
        topic = keys.relayTopic
        lastSent = nil
        // A stopped pool can still be draining its bye: nothing it hears belongs to the session after it.
        pool.onEvent = { [weak self, weak pool] e in
            guard let self, self.pool === pool else { return }
            self.handleEvent(e)
        }
        pool.onStatus = { [weak self, weak pool] s in
            guard let self, self.pool === pool else { return }
            self.setStatus(s)
        }
        pool.onLinkUp = { [weak self, weak pool] _ in
            guard let self, self.pool === pool else { return }
            self.onLinkUp?()
        }
        pool.onOk = { [weak self, weak pool] id, _ in
            guard let self, self.pool === pool else { return }
            if id == self.lastSent { self.lastSent = nil } // nothing left to wait for on stop
        }
        pool.start()
    }

    /// Sends nothing new; lets the bye already sent reach the relays, then closes.
    public func stop() {
        guard let pool else { return }
        self.pool = nil
        pair = nil
        let pending = lastSent
        lastSent = nil
        setStatus(.off)
        // Relays that aren't live close at once and none reconnects: after a stop, no relay is contacted again.
        guard let pending, pool.drain() > 0 else {
            pool.stop()
            return
        }
        closing += 1
        var timer: RoomTimer?
        var finished = false
        let finish = { [weak self] in
            if finished { return }
            finished = true
            timer?.cancel()
            pool.onOkWhileDraining = nil
            pool.stop()
            self?.closed()
        }
        pool.onOkWhileDraining = { id in
            if id == pending { finish() }
        }
        timer = scheduler.after(Self.drainMs, finish)
    }

    private func closed() {
        closing -= 1
        if closing > 0 { return }
        let waiters = closedWaiters
        closedWaiters = []
        for w in waiters { w() }
    }

    public func whenClosed(_ completion: @escaping () -> Void) {
        if closing == 0 {
            queue.async(execute: completion)
        } else {
            closedWaiters.append(completion)
        }
    }

    /// Every member hears every event, so a packet for one is a packet for all.
    public func send(to _: PeerKey, packet: Data) {
        broadcast(packet)
    }

    public func broadcast(_ packet: Data) {
        guard let pool, let pair else { return }
        guard let e = Nostr.signEvent(pair, kind: Nostr.roomEventKind, tags: [["x", topic]], content: packet.base64EncodedString(),
                                      createdAt: scheduler.now() / 1000) else { return }
        lastSent = pool.publish(e) > 0 ? e.id : nil
    }

    /// Each relay of the running session, in list order; empty while stopped. For diagnostics only.
    public var relays: [RelayInfo] {
        pool?.relays ?? []
    }

    /// The Retry button.
    public func retryNow() {
        pool?.retryNow()
    }

    /// After sleep.
    public func wake() {
        pool?.wake()
    }

    private func handleEvent(_ e: NostrEvent) {
        guard e.content.utf16.count <= Self.maxContent, let packet = Self.base64(e.content) else { return }
        onPacket?("net:\(e.pubkey)", packet)
    }

    /// Strict base64, as upstream's pattern has it: the standard alphabet, whole groups of four, padding only at the
    /// end. Nil for anything else. Bits left over in a padded group are ignored, as Node ignores them.
    static func base64(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 4 == 0 else { return nil }
        func value(_ c: UInt8) -> UInt32? {
            switch c {
            case 0x41...0x5a: return UInt32(c - 0x41)
            case 0x61...0x7a: return UInt32(c - 0x61) + 26
            case 0x30...0x39: return UInt32(c - 0x30) + 52
            case 0x2b: return 62
            case 0x2f: return 63
            default: return nil
            }
        }
        var out = Data(capacity: chars.count / 4 * 3)
        var i = 0
        while i < chars.count {
            let last = i + 4 == chars.count
            guard let a = value(chars[i]), let b = value(chars[i + 1]) else { return nil }
            let (c3, c4) = (chars[i + 2], chars[i + 3])
            if last, c3 == 0x3d, c4 == 0x3d {
                out.append(UInt8((a << 2 | b >> 4) & 0xff))
            } else if last, c4 == 0x3d {
                guard let c = value(c3) else { return nil }
                out.append(UInt8((a << 2 | b >> 4) & 0xff))
                out.append(UInt8((b << 4 | c >> 2) & 0xff))
            } else {
                guard let c = value(c3), let d = value(c4) else { return nil }
                out.append(UInt8((a << 2 | b >> 4) & 0xff))
                out.append(UInt8((b << 4 | c >> 2) & 0xff))
                out.append(UInt8((c << 6 | d) & 0xff))
            }
            i += 4
        }
        return out
    }

    private func setStatus(_ s: TransportStatus) {
        if s == status { return }
        status = s
        onStatus?(s)
    }
}

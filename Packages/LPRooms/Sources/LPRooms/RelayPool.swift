import Foundation

struct RelayPoolOptions {
    var urls: [String]
    var topic: String
    var pubkey: String
    var socket: RelaySocketFactory
    var random: () -> Double
    var scheduler: RoomScheduler
}

/// Every pinned relay at once: publishes to each one that is live and merges what they deliver. Status is `ok` while
/// at least one relay sends our own events back.
final class RelayPool {
    /// How long a join waits for any relay to send our own events back before calling the internet unavailable.
    private static let unavailableMs = 15_000.0
    /// Each event arrives once per relay; remembering this many ids drops the copies.
    private static let dedupe = 512
    /// Incoming events per second from all relays together, after duplicates are dropped.
    private static let budgetPerSecond = 200

    /// An event from another member, deduplicated and within budget.
    var onEvent: ((NostrEvent) -> Void)?
    var onStatus: ((TransportStatus) -> Void)?
    /// A relay went live; the argument is its URL.
    var onLinkUp: ((String) -> Void)?
    var onOk: ((String, Bool) -> Void)?
    /// A second listener for OK results, for a stop that waits on its bye.
    var onOkWhileDraining: ((String) -> Void)?

    private(set) var status: TransportStatus = .off
    private var conns: [RelayConnection] = []
    /// Relays that went live at least once, and relays that failed before ever going live.
    private var everLive = Set<ObjectIdentifier>()
    private var failed = Set<ObjectIdentifier>()
    private var stopped = true
    private var timer: RoomTimer?
    private var seen = Set<String>()
    private var ring: [String] = []
    private var windowStart = 0
    private var windowCount = 0
    private let scheduler: RoomScheduler

    init(_ opts: RelayPoolOptions) {
        scheduler = opts.scheduler
        conns = opts.urls.map { url in
            let c = RelayConnection(RelayConnectionOptions(url: url, topic: opts.topic, pubkey: opts.pubkey, socket: opts.socket,
                                                           random: opts.random, scheduler: opts.scheduler))
            c.onEvent = { [weak self] e in self?.handleEvent(e) }
            c.onEcho = { [weak self] in self?.refresh() }
            c.onState = { [weak self, unowned c] s in
                guard let self else { return }
                if s == .down || s == .retired, !self.everLive.contains(ObjectIdentifier(c)) { self.failed.insert(ObjectIdentifier(c)) }
                self.refresh()
            }
            c.onLive = { [weak self, unowned c] in
                guard let self else { return }
                self.everLive.insert(ObjectIdentifier(c))
                self.onLinkUp?(url)
            }
            c.onOk = { [weak self] id, ok, _ in
                guard let self else { return }
                self.onOk?(id, ok)
                self.onOkWhileDraining?(id)
            }
            return c
        }
    }

    func start() {
        if !stopped { return }
        stopped = false
        setStatus(.starting)
        timer = scheduler.after(Self.unavailableMs) { [weak self] in
            guard let self else { return }
            if self.status == .starting { self.setStatus(.unavailable) }
        }
        for c in conns { c.start() }
    }

    /// Closes every relay; nothing is emitted afterwards.
    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        for c in conns { c.stop() }
        status = .off
    }

    /// How many relays it went to.
    func publish(_ e: NostrEvent) -> Int {
        let json = Nostr.eventMessage(e)
        return conns.filter { $0.publish(json) }.count
    }

    /// For a stop that waits on a bye: relays that aren't live close now, none reconnects. How many are still open.
    func drain() -> Int {
        for c in conns { c.drain() }
        return conns.filter { $0.state == .live }.count
    }

    /// Each relay as it stands, in the order of the list.
    var relays: [RelayInfo] {
        conns.map { RelayInfo(url: $0.url, state: $0.state, healthy: $0.healthy) }
    }

    /// The Retry button: every relay that is down or retired reconnects now; ones already connecting are left alone.
    func retryNow() {
        for c in conns { c.reconnectNow(revive: true) }
    }

    /// After sleep: sockets are likely dead, so every relay still in use reconnects now.
    func wake() {
        for c in conns { c.reconnectNow(revive: false) }
    }

    private func handleEvent(_ e: NostrEvent) {
        if stopped || seen.contains(e.id) { return }
        seen.insert(e.id)
        ring.append(e.id)
        if ring.count > Self.dedupe { seen.remove(ring.removeFirst()) }
        let now = scheduler.now()
        if now - windowStart >= 1000 {
            windowStart = now
            windowCount = 0
        }
        windowCount += 1
        if windowCount > Self.budgetPerSecond { return }
        onEvent?(e)
    }

    private func refresh() {
        if stopped { return }
        if conns.contains(where: \.healthy) {
            setStatus(.ok)
        } else if status == .ok {
            setStatus(.unavailable)
        } else if status == .starting, failed.count == conns.count {
            // Every relay failed before ever connecting (no internet at all): no point waiting out the 15 s.
            setStatus(.unavailable)
        }
    }

    private func setStatus(_ s: TransportStatus) {
        if s == status { return }
        status = s
        onStatus?(s)
    }
}

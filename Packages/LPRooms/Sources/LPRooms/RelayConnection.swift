import Foundation

/// connecting → live ⇄ cooling; down waits to reconnect; retired stays out for this room session.
public enum RelayState: String, Equatable, Sendable {
    case connecting
    case live
    case cooling
    case down
    case retired
}

/// One relay of a running transport, for diagnostics. Upstream has no such view; nothing in the room depends on it.
public struct RelayInfo: Equatable, Sendable {
    public var url: String
    public var state: RelayState
    /// Live (or cooling) and sending our own events back.
    public var healthy: Bool
}

struct RelayConnectionOptions {
    var url: String
    /// The room's relay topic: the only events we subscribe to.
    var topic: String
    /// Ours: events signed with it are our own coming back, which proves the relay delivers.
    var pubkey: String
    var socket: RelaySocketFactory
    var random: () -> Double
    var scheduler: RoomScheduler
}

/// One relay: keeps a subscription to the room's topic open, publishes while live, and judges the relay by whether
/// our own events come back. Each state owns exactly one timer (connect deadline, health deadline, cool-down or
/// backoff), so every transition starts by clearing it.
final class RelayConnection {
    private static let subId = "lolping"
    /// The replay guard's window: a relay that wrongly stored older events can't send them back.
    private static let sinceS = 600
    private static let connectMs = 10_000.0
    /// Presence goes out every 10 s, so a relay that sends none of ours back for this long isn't delivering.
    private static let healthMs = 25_000.0
    private static let backoffMinMs = 2000.0
    private static let backoffMaxMs = 60_000.0
    private static let backoffResetMs = 60_000
    private static let jitter = 0.2
    private static let coolMs = 30_000.0
    /// Far above what one room's subscription ever gets: a relay past these is attacking us, not talking to us.
    private static let maxMessage = 64 * 1024
    private static let maxPerSecond = 400
    private static let retirePrefixes = ["blocked:", "restricted:", "auth-required:", "pow:", "invalid:"]

    /// An event from someone else.
    var onEvent: ((NostrEvent) -> Void)?
    /// One of our own events came back.
    var onEcho: (() -> Void)?
    var onLive: (() -> Void)?
    var onOk: ((String, Bool, String) -> Void)?
    var onState: ((RelayState) -> Void)?

    let url: String
    private(set) var state: RelayState = .down
    private var sock: RelaySocket?
    private var stopped = true
    /// Waiting for a bye's OK before stopping: nothing reconnects any more.
    private var draining = false
    private var timer: RoomTimer?
    private var attempts = 0
    private var echoed = false
    private var healthySince: Int?
    private var closedOnce = false
    private var windowStart = 0
    private var windowCount = 0
    private let opts: RelayConnectionOptions

    init(_ opts: RelayConnectionOptions) {
        self.opts = opts
        url = opts.url
    }

    var healthy: Bool {
        (state == .live || state == .cooling) && echoed
    }

    func start() {
        if !stopped { return }
        stopped = false
        draining = false
        connect()
    }

    /// For good: closes the socket, and nothing is emitted afterwards.
    func stop() {
        stopped = true
        clearTimer()
        closeSocket()
        state = .down
    }

    /// False when the relay isn't live, so nothing went out.
    func publish(_ json: String) -> Bool {
        guard state == .live, let sock else { return false }
        do {
            try sock.send(json)
            return true
        } catch {
            return false // closing under us: the close handler takes it from here
        }
    }

    /// Skips any backoff. `revive` (Retry) reconnects only a relay that is down or retired, so pressing it again
    /// never undoes a connection in progress. Otherwise (wake from sleep) every relay but a retired one reconnects:
    /// its socket may have died while we slept.
    func reconnectNow(revive: Bool) {
        if stopped || draining { return }
        if revive ? state != .down && state != .retired : state == .retired { return }
        attempts = 0
        connect()
    }

    /// A stop that waits for a bye: a relay that isn't live didn't get it and closes now; none reconnects any more.
    func drain() {
        if stopped { return }
        if state != .live { return stop() }
        draining = true
    }

    private func connect() {
        clearTimer()
        closeSocket()
        echoed = false
        healthySince = nil
        closedOnce = false
        let sock: RelaySocket
        do {
            sock = try opts.socket(url)
        } catch {
            retire() // a malformed URL never gets better
            return
        }
        self.sock = sock
        sock.onOpen = { [weak self, weak sock] in
            guard let self, let sock, sock === self.sock else { return }
            self.subscribe()
            self.setState(.live)
            self.armHealth()
            if !self.stopped { self.onLive?() }
        }
        sock.onMessage = { [weak self, weak sock] message in
            guard let self, let sock, sock === self.sock else { return }
            self.handleMessage(message)
        }
        sock.onClose = { [weak self, weak sock] in
            guard let self, let sock, sock === self.sock else { return }
            self.down()
        }
        setState(.connecting)
        timer = opts.scheduler.after(Self.connectMs) { [weak self] in self?.down() }
    }

    private func subscribe() {
        try? sock?.send(Nostr.reqMessage(subId: Self.subId, topic: opts.topic, since: opts.scheduler.now() / 1000 - Self.sinceS))
    }

    private func handleMessage(_ message: RelaySocketMessage) {
        let now = opts.scheduler.now()
        if now - windowStart >= 1000 {
            windowStart = now
            windowCount = 0
        }
        windowCount += 1
        if windowCount > Self.maxPerSecond { return retire() }
        // Nostr is text only. JavaScript measures a string in UTF-16 units.
        guard case .text(let data) = message, data.utf16.count <= Self.maxMessage else { return retire() }
        guard let m = Nostr.parseRelayMessage(data) else { return }
        switch m {
        case .event(let subId, let e):
            guard subId == Self.subId, e.kind == Nostr.roomEventKind,
                  e.tags.contains(where: { $0.count >= 2 && $0[0] == "x" && $0[1] == opts.topic }) else { return }
            if e.pubkey == opts.pubkey {
                handleEcho()
            } else {
                onEvent?(e)
            }
        case .ok(let eventId, let ok, let message):
            onOk?(eventId, ok, message)
            if ok { return }
            if message.hasPrefix("rate-limited:") {
                cool()
            } else if Self.retirePrefixes.contains(where: { message.hasPrefix($0) }) {
                retire()
            }
        case .closed(let subId, _):
            guard subId == Self.subId else { return }
            if closedOnce { return retire() }
            closedOnce = true
            subscribe()
        case .eose, .notice:
            return
        }
    }

    private func handleEcho() {
        if state != .live && state != .cooling { return }
        if !echoed {
            echoed = true
            healthySince = opts.scheduler.now()
        }
        onEcho?()
        if state == .live { armHealth() }
    }

    /// Rate-limited: publish nothing for a while, and don't hold the missing echoes against it.
    private func cool() {
        if state != .live { return }
        if draining { return stop() } // it won't take the bye now
        clearTimer()
        setState(.cooling)
        timer = opts.scheduler.after(Self.coolMs) { [weak self] in
            guard let self else { return }
            self.setState(.live)
            self.armHealth()
        }
    }

    private func armHealth() {
        clearTimer()
        timer = opts.scheduler.after(Self.healthMs) { [weak self] in self?.down() }
    }

    private func down() {
        if stopped || state == .retired { return }
        if draining { return stop() }
        if let healthySince, opts.scheduler.now() - healthySince >= Self.backoffResetMs { attempts = 0 }
        clearTimer()
        closeSocket()
        echoed = false
        healthySince = nil
        setState(.down)
        let delay = min(Self.backoffMaxMs, Self.backoffMinMs * pow(2, Double(attempts)))
        attempts += 1
        timer = opts.scheduler.after(delay * (1 + (opts.random() * 2 - 1) * Self.jitter)) { [weak self] in self?.connect() }
    }

    private func retire() {
        clearTimer()
        closeSocket()
        echoed = false
        setState(.retired)
    }

    private func closeSocket() {
        let sock = self.sock
        self.sock = nil
        sock?.close()
    }

    private func clearTimer() {
        timer?.cancel()
        timer = nil
    }

    private func setState(_ s: RelayState) {
        if s == state { return }
        state = s
        if !stopped { onState?(s) }
    }
}

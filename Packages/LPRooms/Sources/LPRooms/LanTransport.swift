import Darwin
import Foundation

public struct LanOptions {
    public var port: UInt16
    /// An IPv4 address.
    public var bindAddress: String
    /// Off in tests: loopback carries no broadcast, and tests shouldn't spray the real network.
    public var broadcast: Bool
    /// Addresses (IPv4, not host names) that get every broadcast as unicast too.
    public var seeds: [(host: String, port: UInt16)]
    /// Packets per second accepted from one IP before decryption is even tried.
    public var floodPerSecond: Double
    /// Packets per second accepted from all IPs together.
    public var floodTotalPerSecond: Double

    public init(
        port: UInt16 = LanTransport.defaultPort,
        bindAddress: String = "0.0.0.0",
        broadcast: Bool = true,
        seeds: [(host: String, port: UInt16)] = [],
        floodPerSecond: Double = FloodLimits.default.perIp,
        floodTotalPerSecond: Double = FloodLimits.default.total
    ) {
        self.port = port
        self.bindAddress = bindAddress
        self.broadcast = broadcast
        self.seeds = seeds
        self.floodPerSecond = floodPerSecond
        self.floodTotalPerSecond = floodTotalPerSecond
    }
}

/// Room packets over UDP on the local network: presence is broadcast, everything else goes straight to the
/// address a peer's packets came from. No connections, so a lost packet or a network change heals itself.
///
/// One plain BSD socket, bound the way Node binds upstream's: to every interface, port 47474, without SO_REUSEADDR or
/// SO_REUSEPORT. So the port is exclusive: a second lolPing on the same Mac (this one or upstream's) finds it taken
/// and reports the LAN as unavailable, exactly as two copies of upstream do.
public final class LanTransport: Transport {
    /// lolPing's port. Every app in a room must use the same one: broadcasts go to it.
    public static let defaultPort: UInt16 = 47474
    private static let interfacesMs = 5000.0
    /// Most datagrams read per wake-up, so a flood can't keep the reading queue to itself.
    private static let readBatch = 64

    public let kind = TransportKind.lan
    public let shared = false
    public private(set) var status: TransportStatus = .off
    public var onPacket: ((PeerKey, Data) -> Void)?
    public var onPeerGone: ((PeerKey) -> Void)?
    public var onStatus: ((TransportStatus) -> Void)?
    public var onLinkUp: (() -> Void)?

    /// A socket, from before it is bound until it is closed.
    private final class Sock {
        var fd: Int32 = -1
        var source: DispatchSourceRead?
    }

    private var sock: Sock?
    /// Sockets still releasing the port, and who is waiting for that.
    private var closing = 0
    private var closedWaiters: [() -> Void] = []
    private var running = false
    private var targets: [String] = []
    private var refresh: RoomTimer?
    private let opts: LanOptions
    private let queue: DispatchQueue
    private let scheduler: RoomScheduler
    /// Reads the socket. The flood guard lives here, so a flood is thinned out before it reaches the caller's queue.
    private let io = DispatchQueue(label: "lolping.rooms.lan", qos: .userInitiated)
    private let flood: FloodGuard

    /// `queue` is where the transport is used and where its handlers run; `scheduler` must fire on it.
    public init(_ opts: LanOptions = LanOptions(), queue: DispatchQueue = .main, scheduler: RoomScheduler? = nil) {
        self.opts = opts
        self.queue = queue
        self.scheduler = scheduler ?? DispatchRoomScheduler(queue: queue)
        var limits = FloodLimits.default
        limits.perIp = opts.floodPerSecond
        limits.total = opts.floodTotalPerSecond
        flood = FloodGuard(now: { Int(Date().timeIntervalSince1970 * 1000) }, limits: limits)
    }

    deinit {
        refresh?.cancel()
        Self.release(sock) {}
    }

    public func start(keys _: RoomKeys) {
        if running { return }
        running = true
        readInterfaces()
        refresh = scheduler.every(Self.interfacesMs) { [weak self] in self?.readInterfaces() }
        open()
    }

    public func stop() {
        running = false
        refresh?.cancel()
        refresh = nil
        close()
        setStatus(.off)
    }

    /// Calls back once every socket this transport closed has released the port.
    public func whenClosed(_ completion: @escaping () -> Void) {
        if closing == 0 {
            queue.async(execute: completion)
        } else {
            closedWaiters.append(completion)
        }
    }

    /// After sleep or a network change: a fresh socket on the same port.
    public func rebind() {
        if !running { return }
        close()
        readInterfaces()
        open()
    }

    public func send(to peer: PeerKey, packet: Data) {
        // "lan:<address>:<port>"
        guard peer.hasPrefix("lan:"), let colon = peer.lastIndex(of: ":"), colon > peer.index(peer.startIndex, offsetBy: 3) else { return }
        let host = String(peer[peer.index(peer.startIndex, offsetBy: 4)..<colon])
        let digits = peer[peer.index(after: colon)...]
        guard !host.isEmpty, !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let port = UInt16(digits) else { return }
        send(packet, port: port, host: host)
    }

    public func broadcast(_ packet: Data) {
        if opts.broadcast {
            for host in targets { send(packet, port: opts.port, host: host) }
        }
        for s in opts.seeds { send(packet, port: s.port, host: s.host) }
    }

    /// Straight into the socket: UDP never blocks, and a send that fails (unreachable network, interface gone, full
    /// buffer) is a lost packet, which is fine.
    private func send(_ packet: Data, port: UInt16, host: String) {
        guard status == .ok, let fd = sock?.fd, fd >= 0, var addr = Self.address(host, port) else { return }
        packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func open() {
        setStatus(.starting)
        let sock = Sock()
        self.sock = sock
        // Not before the previous socket has let go of the port, and never in the caller's turn: start() and rebind()
        // return with the transport still starting, as upstream's do.
        afterClosing { [weak self, weak sock] in
            guard let self, let sock, self.sock === sock else { return }
            guard let fd = self.bind() else {
                // Upstream's 'error' event: the port is taken, or the address isn't ours.
                self.close()
                self.setStatus(.unavailable)
                return
            }
            sock.fd = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.io)
            source.setEventHandler { [weak self, weak sock] in self?.read(fd, sock) }
            source.setCancelHandler { Darwin.close(fd) }
            sock.source = source
            source.resume()
            self.setStatus(.ok)
        }
    }

    /// A bound, non-blocking UDP socket, or nil.
    private func bind() -> Int32? {
        guard var addr = Self.address(opts.bindAddress, opts.port) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return nil }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        guard bound == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1,
              !opts.broadcast || setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// On the reading queue: everything waiting on the socket, thinned by the flood guard, handed to the caller's queue.
    private func read(_ fd: Int32, _ sock: Sock?) {
        // One byte more than a packet may have, so an oversize datagram shows as one.
        var buffer = [UInt8](repeating: 0, count: RoomCrypto.maxPacket + 1)
        for _ in 0..<Self.readBatch {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    queue.async { [weak self] in
                        guard let self, let sock, self.sock === sock else { return }
                        self.close()
                        self.setStatus(.unavailable)
                    }
                }
                return
            }
            if n > RoomCrypto.maxPacket { continue }
            guard let ip = Self.text(from.sin_addr), flood.allow(ip) else { continue }
            let key = "lan:\(ip):\(UInt16(bigEndian: from.sin_port))"
            let packet = Data(buffer[0..<n])
            queue.async { [weak self] in
                guard let self, let sock, self.sock === sock else { return }
                self.onPacket?(key, packet)
            }
        }
    }

    /// Closes the current socket. Everything sent before is already with the kernel, so a bye sent just before still goes out.
    private func close() {
        guard let sock else { return }
        self.sock = nil
        closing += 1
        // Counted: two quick rebinds must not let a new socket bind while an older one still holds the port.
        Self.release(sock) { [weak self, queue] in
            queue.async {
                guard let self else { return }
                self.closing -= 1
                if self.closing > 0 { return }
                let waiters = self.closedWaiters
                self.closedWaiters = []
                for w in waiters { w() }
            }
        }
    }

    /// `done` runs (on any queue) once the descriptor is closed.
    private static func release(_ sock: Sock?, _ done: @escaping () -> Void) {
        guard let sock, let source = sock.source else { return done() } // never bound
        sock.source = nil
        let fd = sock.fd
        sock.fd = -1
        source.setCancelHandler {
            Darwin.close(fd)
            done()
        }
        source.cancel()
    }

    private func afterClosing(_ body: @escaping () -> Void) {
        whenClosed(body)
    }

    private func readInterfaces() {
        targets = Self.broadcastAddresses()
    }

    private func setStatus(_ s: TransportStatus) {
        if s == status { return }
        status = s
        onStatus?(s)
    }

    // MARK: Addresses

    private static func address(_ host: String, _ port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        return inet_pton(AF_INET, host, &addr.sin_addr) == 1 ? addr : nil
    }

    private static func text(_ a: in_addr) -> String? {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) }
    }

    /// Directed broadcast address of every IPv4 interface that is up, after the limited broadcast address: an OS may
    /// send 255.255.255.255 out of one interface only. The same list Node's `os.networkInterfaces()` gives upstream.
    static func broadcastAddresses() -> [String] {
        var out = ["255.255.255.255"]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return out }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard let text = text(in_addr(s_addr: (ip & m) | ~m)) else { continue }
            if !out.contains(text) { out.append(text) }
        }
        return out
    }
}

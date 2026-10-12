import Foundation
import XCTest
@testable import LPRooms

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: url(name))
    }

    /// A fixture file as plain Foundation JSON (the fixtures are trusted; the code under test never reads them).
    static func json(_ name: String) -> Any {
        try! JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])
    }

    static func list(_ name: String) -> [[String: Any]] {
        json(name) as! [[String: Any]]
    }
}

func unhex(_ s: String) -> [UInt8] {
    Hex.decode(s)!
}

extension Data {
    init(hex: String) {
        self.init(unhex(hex))
    }

    var hex: String { Hex.encode(self) }
}

/// Fake time, modelled on the fake timers upstream's tests use: `advance` runs what falls due, in order, with the
/// clock set to each timer's moment; `setSystemTime` moves the clock without firing anything (the computer slept).
final class FakeScheduler: RoomScheduler {
    private final class Entry: RoomTimer {
        var due: Double
        let interval: Double?
        let block: () -> Void
        let id: Int
        var cancelled = false

        init(due: Double, interval: Double?, id: Int, block: @escaping () -> Void) {
            self.due = due
            self.interval = interval
            self.id = id
            self.block = block
        }

        func cancel() {
            cancelled = true
        }
    }

    private var mono: Double = 0
    private var epoch: Int
    private var entries: [Entry] = []
    private var nextId = 0

    init(now: Int = 1_780_000_000_000) {
        epoch = now
    }

    func now() -> Int {
        epoch + Int(mono)
    }

    func after(_ ms: Double, _ block: @escaping () -> Void) -> RoomTimer {
        add(ms, nil, block)
    }

    func every(_ ms: Double, _ block: @escaping () -> Void) -> RoomTimer {
        add(ms, max(1, ms), block)
    }

    private func add(_ ms: Double, _ interval: Double?, _ block: @escaping () -> Void) -> RoomTimer {
        nextId += 1
        let e = Entry(due: mono + max(0, ms), interval: interval, id: nextId, block: block)
        entries.append(e)
        return e
    }

    func advance(_ ms: Double) {
        let target = mono + ms
        while true {
            entries.removeAll(where: \.cancelled)
            guard let next = entries.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) else { break }
            mono = max(mono, next.due)
            if let interval = next.interval {
                next.due += interval
            } else {
                next.cancelled = true
            }
            next.block()
        }
        mono = target
    }

    func setSystemTime(_ t: Int) {
        epoch = t - Int(mono)
    }

    var pending: Int { entries.filter { !$0.cancelled }.count }
}

/// Records what RoomManager sends; tests push packets in with deliver().
final class FakeTransport: Transport {
    let kind: TransportKind
    let shared: Bool
    private(set) var status: TransportStatus = .off
    var onPacket: ((PeerKey, Data) -> Void)?
    var onPeerGone: ((PeerKey) -> Void)?
    var onStatus: ((TransportStatus) -> Void)?
    var onLinkUp: (() -> Void)?

    var started: RoomKeys?
    var sent: [(to: String, packet: Data)] = []
    var starts = 0
    var stops = 0
    /// What start() reports: .starting holds it there, like relays that haven't answered yet.
    var startStatus: TransportStatus = .ok

    init(_ kind: TransportKind = .lan) {
        self.kind = kind
        shared = kind == .internet
    }

    func start(keys: RoomKeys) {
        starts += 1
        started = keys
        setStatus(startStatus)
    }

    func stop() {
        stops += 1
        started = nil
        setStatus(.off)
    }

    func whenClosed(_ completion: @escaping () -> Void) {
        completion()
    }

    func send(to peer: PeerKey, packet: Data) {
        sent.append((peer, packet))
    }

    func broadcast(_ packet: Data) {
        sent.append(("*", packet))
    }

    func deliver(_ peer: PeerKey, _ packet: Data) {
        onPacket?(peer, packet)
    }

    func setStatus(_ s: TransportStatus) {
        status = s
        onStatus?(s)
    }

    func linkUp() {
        onLinkUp?()
    }
}

/// A WebSocket stand-in: tests open it, push messages in and read what was sent.
final class FakeSocket: RelaySocket {
    var onOpen: (() -> Void)?
    var onMessage: ((RelaySocketMessage) -> Void)?
    var onClose: (() -> Void)?
    let url: String
    var isOpen = false
    var sent: [String] = []
    var closed = false

    init(url: String) {
        self.url = url
    }

    func send(_ text: String) throws {
        guard isOpen else { throw RelaySocketError.notOpen }
        sent.append(text)
    }

    /// Like a real socket, closing it ourselves fires no onClose we'd still listen to.
    func close() {
        closed = true
        isOpen = false
    }

    func open() {
        isOpen = true
        onOpen?()
    }

    func receive(_ text: String) {
        onMessage?(.text(text))
    }

    func receive(_ message: [Any]) {
        receive(String(decoding: try! JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]), as: UTF8.self))
    }

    func receive(event e: NostrEvent, sub: String = "lolping") {
        receive("[\"EVENT\",\"\(sub)\",\(Nostr.eventMessage(e).dropFirst(9))")
    }

    /// The relay or the network closes it.
    func drop() {
        closed = true
        isOpen = false
        onClose?()
    }

    /// Everything sent, parsed.
    func messages() -> [[Any]] {
        sent.map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [Any] }
    }

    /// The events published through it.
    func published() -> [NostrEvent] {
        sent.compactMap { text in
            guard text.hasPrefix("[\"EVENT\",") else { return nil }
            if case .event(_, let e)? = Nostr.parseRelayMessage("[\"EVENT\",\"s\",\(text.dropFirst(9))") { return e }
            return nil
        }
    }
}

final class FakeSockets {
    var sockets: [FakeSocket] = []

    var factory: RelaySocketFactory {
        { [self] url in
            let s = FakeSocket(url: url)
            sockets.append(s)
            return s
        }
    }

    var last: FakeSocket { sockets[sockets.count - 1] }
}

extension RoomMessage {
    var type: String {
        switch body {
        case .presence: return "presence"
        case .ping: return "ping"
        case .emote: return "emote"
        case .bye: return "bye"
        }
    }

    var presenceName: String? {
        if case .presence(_, _, let name, _, _) = body { return name }
        return nil
    }

    var presenceStatus: MemberStatus? {
        if case .presence(_, _, _, _, let status) = body { return status }
        return nil
    }
}

/// Waits, with the main run loop turning, until `condition` holds.
func until(_ timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > end {
            XCTFail("timed out", file: file, line: line)
            return
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

// A room member for the terminal: the counterpart of upstream's tools/room-peer, built on the same RoomService the
// app uses. It joins a room, drops pings (and emotes) at random spots and prints what it receives.
//
//   lprooms-peer PING-XXXXX-XXXXX [--name Swift] [--color 2] [--rate 1] [--emotes] [--seconds 30]
//                [--no-relay] [--port 47474] [--bind 0.0.0.0] [--no-broadcast] [--seed 127.0.0.1:47475]
//                [--relays wss://a,wss://b] [--verbose]
//   lprooms-peer new …        creates a room and prints its code
//   lprooms-peer dump FILE    writes keys, sealed packets and signed events as JSON, for upstream's code to check

import Foundation
import LPRooms

/// A few bundled emote slugs for the peer to send.
let peerEmotes = ["facepalm", "nice", "poro_snax", "gg_heart", "okay", "teamwork", "wahaha", "bee_happy"]

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}

/// Samples of everything this port puts on the wire, for the upstream modules to read back (see the interop notes).
func dump(to path: String) {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    var rng = SystemRandomNumberGenerator()
    var rooms: [[String: Any]] = []
    var packets: [[String: Any]] = []
    var events: [[String: Any]] = []
    let names = ["Alex", "名前だよ", "Qu\"ote\\ /slash", "🎮🎮 Zoë", "tab\there\u{7}\u{1f}\u{7f}\u{2028}é", ""]
    for i in 0..<4 {
        let code = RoomCode.make(random9: (0..<9).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let keys = try! RoomCrypto.deriveRoomKeysSync(code)
        rooms.append(["code": code, "display": RoomCode.format(code), "msgKey": hex(keys.msgKey), "relayTopic": keys.relayTopic])
        let pair = Nostr.makeKeyPair()
        for n in 0..<40 {
            let peer = hex(Data((0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) }))
            let x = Double.random(in: 0...1, using: &rng), y = n % 7 == 0 ? Double(n % 2) : Double.random(in: 0...1, using: &rng)
            let body: RoomMessage.Body
            switch n % 4 {
            case 0: body = .presence(proto: RoomProtocol.version, app: "0.5.1", name: names[(n / 4) % names.count], color: n % 8, status: MemberStatus.allCases[n % 3])
            case 1: body = .ping(id: RoomWire.pingIds[n % RoomWire.pingIds.count], d: 1 + n % 16, x: x, y: y)
            case 2: body = .emote(ref: n % 8 == 2 ? "c:" + String(repeating: "0123456789abcdef", count: 2) : peerEmotes[n % peerEmotes.count], d: 1 + n % 16, x: x, y: y)
            default: body = .bye
            }
            let msg = RoomMessage(peer: peer, seq: n + 1, ts: 1_780_000_000_000 + n * 977 + i, body: body)
            let plain = RoomProtocol.encode(msg)
            let packet = RoomCrypto.seal(key: keys.msgKey, plain: plain)!
            packets.append(["key": hex(keys.msgKey), "packet": hex(packet), "json": String(decoding: plain, as: UTF8.self)])
            let event = Nostr.signEvent(pair, kind: Nostr.roomEventKind, tags: [["x", keys.relayTopic]], content: packet.base64EncodedString(), createdAt: 1_780_000_000 + n)!
            events.append(["message": Nostr.eventMessage(event), "topic": keys.relayTopic, "packet": hex(packet), "pubkey": pair.pubkey])
        }
    }
    let out: [String: Any] = ["rooms": rooms, "packets": packets, "events": events]
    try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: path))
    print("wrote \(rooms.count) rooms, \(packets.count) packets, \(events.count) events to \(path)")
}

let name = option("--name") ?? "Swift"
let color = Int(option("--color") ?? "2") ?? 2
let rate = Double(option("--rate") ?? "1") ?? 1
let seconds = Double(option("--seconds") ?? "0") ?? 0
let emotes = flag("--emotes")
let noRelay = flag("--no-relay")
let verbose = flag("--verbose")
var lanOptions = LanOptions()
if let p = option("--port"), let port = UInt16(p) { lanOptions.port = port }
if let b = option("--bind") { lanOptions.bindAddress = b }
if flag("--no-broadcast") { lanOptions.broadcast = false }
while let seed = option("--seed") {
    let parts = seed.split(separator: ":")
    if parts.count == 2, let port = UInt16(parts[1]) { lanOptions.seeds.append((host: String(parts[0]), port: port)) }
}
var relayOptions = RelayTransportOptions()
if let urls = option("--relays") { relayOptions.urls = urls.split(separator: ",").map(String.init) }
if args.first == "dump", args.count == 2 {
    dump(to: args[1])
    exit(0)
}
let codeText = args.joined(separator: " ")
if codeText.isEmpty {
    print("usage: lprooms-peer PING-XXXXX-XXXXX|new [--name N] [--color 0-7] [--rate R] [--emotes] [--seconds S] [--no-relay] [--port P] [--bind A] [--no-broadcast] [--seed host:port] [--relays url,url] [--verbose]")
    exit(1)
}

let service = RoomService(
    appVersion: { "0.5.1" },
    profile: { RoomProfile(name: name, color: color, limit: 0) },
    resolveTarget: { d in RoomTarget(displayId: UInt32(d), width: 1000, height: 1000) },
    lanOptions: lanOptions,
    relayOptions: relayOptions
)
let room = service.manager

if verbose {
    // Under the room: every packet a transport hands up, whether or not it opens with the room key.
    for t in [service.lan as Transport, service.relay as Transport] {
        let inner = t.onPacket
        t.onPacket = { peer, packet in
            print("[packet] \(packet.count) bytes from \(peer)")
            inner?(peer, packet)
        }
    }
}

func describe(_ s: RoomState) -> String {
    let members = s.members.map { "\($0.name)(\($0.isSelf ? "self" : $0.path.rawValue),\($0.status.rawValue)\($0.needsUpdate ? ",needsUpdate" : "")\($0.noEmotes ? ",noEmotes" : ""))" }
    return "phase=\(s.phase.rawValue) code=\(s.code ?? "-") lan=\(s.lan.rawValue) internet=\(s.internet.rawValue) lonely=\(s.lonely) members=[\(members.joined(separator: " "))]"
}

room.onState = { print("[state] \(describe($0))") }
room.onRemotePing = { p in print("[in] \(p.id) on display \(p.displayId) at \(p.x / 1000), \(p.y / 1000) from \(p.tag.name)") }
room.onRemoteEmote = { e in print("[in] emote \(e.ref) on display \(e.displayId) at \(e.x / 1000), \(e.y / 1000) from \(e.tag.name)") }
room.onToast = { print("[toast] \($0)") }
room.onSaveCode = { print("[saveCode] \($0 ?? "nil")") }
room.setInternetAllowed(!noRelay)

if codeText == "new" {
    room.create { ok in if !ok { print("[error] could not derive keys") } }
} else {
    room.join(codeText) { result in
        if result != .ok {
            print("[error] join: \(result)")
            exit(1)
        }
    }
}

var sent = 0
if rate > 0 {
    Timer.scheduledTimer(withTimeInterval: 1 / rate, repeats: true) { _ in
        guard room.state.phase != .idle else { return }
        let x = Double.random(in: 0.1...0.9), y = Double.random(in: 0.1...0.9)
        sent += 1
        if emotes, sent % 2 == 0 {
            let slug = peerEmotes.randomElement()!
            room.sendEmote(slug, d: 1, x: x, y: y)
            print("[out] emote \(slug) at \(String(format: "%.4f, %.4f", x, y))")
        } else {
            let ping = RoomWire.pingIds.randomElement()!
            room.sendPing(ping, d: 1, x: x, y: y)
            print("[out] \(ping) at \(String(format: "%.4f, %.4f", x, y))")
        }
    }
}

func printRelays() {
    for r in service.relay.relays { print("[relay] \(r.url) \(r.state.rawValue)\(r.healthy ? " healthy" : "")") }
}
if verbose { DispatchQueue.main.asyncAfter(deadline: .now() + 16) { printRelays() } }

func leave() {
    if verbose { printRelays() }
    print("[quit] saying bye")
    room.quit()
    service.whenClosed {
        print("[quit] sockets closed")
        exit(0)
    }
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { leave() }
sigint.resume()
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { leave() }
sigterm.resume()
if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { leave() } }

RunLoop.main.run()

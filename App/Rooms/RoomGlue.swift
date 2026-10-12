import Foundation
import LPRooms

/// What the settings window and the menu bar show about the room.
struct RoomView: Equatable {
    enum Phase { case idle, joining, active }
    enum Link { case off, starting, ok, unavailable }

    struct Member: Identifiable, Equatable {
        let id: String
        var name: String
        /// Which of the eight tag colours.
        var color: Int
        /// "lan", "internet", "connecting" or "unreachable".
        var path: String
        /// "on", "paused" or "muted".
        var status: String
        var needsUpdate: Bool
        /// An app older than 0.5.0: it can't show our emotes.
        var noEmotes: Bool
        /// Muted by us, for this session.
        var muted: Bool
        var isSelf: Bool
    }

    var phase: Phase = .idle
    /// Display form, PING-XXXXX-XXXXX.
    var code: String?
    /// Us first, then everyone else in the order they appeared.
    var members: [Member] = []
    var lan: Link = .off
    var internet: Link = .off
    /// In a room and alone for 20 s: the code may be wrong.
    var lonely = false
    var clockSkew = false

    init() {}

    init(_ s: RoomState) {
        switch s.phase {
        case .idle: phase = .idle
        case .joining: phase = .joining
        case .active: phase = .active
        }
        code = s.code
        members = s.members.map {
            Member(id: $0.peer, name: $0.name, color: $0.color, path: $0.path.rawValue, status: $0.status.rawValue,
                   needsUpdate: $0.needsUpdate, noEmotes: $0.noEmotes, muted: $0.muted, isSelf: $0.isSelf)
        }
        lan = Self.link(s.lan)
        internet = Self.link(s.internet)
        lonely = s.lonely
        clockSkew = s.clockSkew
    }

    private static func link(_ s: TransportStatus) -> Link {
        switch s {
        case .off: return .off
        case .starting: return .starting
        case .ok: return .ok
        case .unavailable: return .unavailable
        }
    }
}

/// The room, as the rest of the app sees it: pings and emotes shared with other lolPing users (the upstream
/// Windows and Mac apps included), on the local network and through public Nostr relays. Main thread only.
final class RoomGlue {
    struct Profile {
        var name: String
        var color: Int
        var limit: Int
    }

    var onState: (() -> Void)?
    var onRemotePing: ((_ pingId: String, _ displayId: UInt32, _ x: Double, _ y: Double, _ tag: NameTag) -> Void)?
    var onRemoteEmote: ((_ ref: EmoteRef, _ peer: String, _ displayId: UInt32, _ x: Double, _ y: Double, _ tag: NameTag) -> Void)?
    var onToast: ((RoomToast) -> Void)?
    var onSaveCode: ((String?) -> Void)?

    private let service: RoomService
    private var manager: RoomManager { service.manager }

    var state: RoomView { RoomView(manager.state) }

    init(appVersion: String, profile: @escaping () -> Profile, displays: @escaping () -> [NumberedDisplay]) {
        service = RoomService(
            appVersion: { appVersion },
            profile: {
                let p = profile()
                return RoomProfile(name: p.name, color: p.color, limit: p.limit)
            },
            // A ping lands on our display with the same number, or the main one when this Mac has no such display.
            resolveTarget: { d in
                DisplayNumbers.resolveTarget(displays(), d: d).map {
                    RoomTarget(displayId: $0.id, width: $0.bounds.width, height: $0.bounds.height)
                }
            }
        )
        manager.onState = { [weak self] _ in self?.onState?() }
        manager.onRemotePing = { [weak self] p in
            self?.onRemotePing?(p.id, p.displayId, p.x, p.y, NameTag(name: p.tag.name, color: p.tag.color))
        }
        manager.onRemoteEmote = { [weak self] e in
            self?.onRemoteEmote?(e.ref, e.peer, e.displayId, e.x, e.y, NameTag(name: e.tag.name, color: e.tag.color))
        }
        manager.onToast = { [weak self] toast in self?.onToast?(toast) }
        manager.onSaveCode = { [weak self] code in self?.onSaveCode?(code) }
    }

    func create() { manager.create() }

    /// Joins the room whose code is in `text`. Calls back with nil once the keys are derived, or with what was wrong.
    func join(_ text: String, completion: @escaping (JoinError?) -> Void) {
        manager.join(text) { result in
            switch result {
            case .ok: completion(nil)
            case .failure(let error): completion(error)
            }
        }
    }

    func leave() { manager.leave() }

    /// Says bye, so the others see "left" instead of waiting for a timeout, and calls back once the sockets are closed.
    func quit(completion: @escaping () -> Void) {
        manager.quit()
        service.whenClosed(completion)
    }

    func sendPing(_ id: String, d: Int, x: Double, y: Double) { manager.sendPing(id, d: d, x: x, y: y) }
    func sendEmote(_ ref: EmoteRef, d: Int, x: Double, y: Double) { manager.sendEmote(ref, d: d, x: x, y: y) }
    func muteMember(_ peer: String, _ on: Bool) { manager.muteMember(peer, on) }
    func setStatusFlags(paused: Bool, roomMuted: Bool) { manager.setStatusFlags(paused: paused, roomMuted: roomMuted) }
    func setInternetAllowed(_ on: Bool) { manager.setInternetAllowed(on) }
    func profileChanged() { manager.profileChanged() }
    func systemDidWake() { service.systemDidWake() }
    func retryInternet() { service.retryInternet() }
}

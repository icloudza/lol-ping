import Foundation

/// The room with its two real transports, wired the way upstream's main process wires them: a LAN transport on UDP
/// port 47474, a relay transport on the pinned relays, the real clock and scrypt on a background queue.
///
/// Create it and use it on the main thread; every handler of `manager` runs on the main queue.
public final class RoomService {
    public let lan: LanTransport
    public let relay: RelayTransport
    public let manager: RoomManager

    /// - Parameters:
    ///   - appVersion: the app's version, "x.y.z". The others read it from presence: below 0.5.0 means "can't see emotes".
    ///   - profile: name, tag colour and incoming limit, read on every use so settings apply at once.
    ///   - resolveTarget: display number → where a ping for it lands here (`DisplayNumbers.resolveTarget`), or nil to drop it.
    public init(
        appVersion: @escaping () -> String,
        profile: @escaping () -> RoomProfile,
        resolveTarget: @escaping (Int) -> RoomTarget?,
        lanOptions: LanOptions = LanOptions(),
        relayOptions: RelayTransportOptions = RelayTransportOptions()
    ) {
        let scheduler = DispatchRoomScheduler(queue: .main)
        lan = LanTransport(lanOptions, queue: .main, scheduler: scheduler)
        relay = RelayTransport(relayOptions, queue: .main, scheduler: scheduler)
        manager = RoomManager(RoomDeps(
            transports: [lan, relay],
            scheduler: scheduler,
            randomBytes: { Nostr.randomBytes($0) },
            deriveKeys: { code, done in RoomCrypto.deriveRoomKeys(code, queue: .main, completion: done) },
            appVersion: appVersion,
            profile: profile,
            resolveTarget: resolveTarget
        ))
    }

    /// Call when the Mac wakes (NSWorkspace.didWakeNotification): the UDP socket is re-bound and every relay still in
    /// use reconnects, since both are likely dead after sleep.
    public func systemDidWake() {
        lan.rebind()
        relay.wake()
    }

    /// The Room page's Retry: relays that are down or retired reconnect now.
    public func retryInternet() {
        relay.retryNow()
    }

    /// Calls back on the main queue once both transports have let go of their sockets: after `manager.quit()`, that is
    /// when the bye is out (at most half a second) and the app can exit.
    public func whenClosed(_ completion: @escaping () -> Void) {
        lan.whenClosed { [relay] in relay.whenClosed(completion) }
    }
}

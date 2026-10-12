import Foundation

public enum TransportKind: String, Equatable, Sendable {
    case lan
    case internet
}

/// A transport-local address, e.g. "lan:192.168.1.20:47474" or "net:<relay pubkey>".
public typealias PeerKey = String

/// Moves sealed room packets and nothing else: keys, validation and every decision stay in RoomManager.
///
/// A transport lives on one queue (the main queue in the app): every method is called there and every handler runs
/// there. RoomManager sets the four handlers when it is created.
public protocol Transport: AnyObject {
    var kind: TransportKind { get }
    /// One send reaches every member (relays): RoomManager sends each packet once, never per member.
    var shared: Bool { get }
    var status: TransportStatus { get }

    /// A packet arrived from this address.
    var onPacket: ((PeerKey, Data) -> Void)? { get set }
    /// The link to this address is gone. (Neither transport here has per-peer links, so neither calls it.)
    var onPeerGone: ((PeerKey) -> Void)? { get set }
    var onStatus: ((TransportStatus) -> Void)? { get set }
    /// A new link came up: send presence now.
    var onLinkUp: (() -> Void)? { get set }

    func start(keys: RoomKeys)
    /// Sends nothing: RoomManager says bye before stopping.
    func stop()
    func send(to peer: PeerKey, packet: Data)
    /// LAN: UDP broadcast. Internet: every connected peer.
    func broadcast(_ packet: Data)
    /// Calls back, on the transport's queue, once a stop has finished flushing what was already sent (a bye).
    func whenClosed(_ completion: @escaping () -> Void)
}

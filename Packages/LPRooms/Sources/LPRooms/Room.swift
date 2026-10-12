import Foundation

public enum TransportStatus: String, Equatable, Sendable {
    case off
    case starting
    case ok
    case unavailable
}

public enum MemberPath: String, Equatable, Sendable {
    case lan
    case internet
    case connecting
    case unreachable
}

public enum MemberStatus: String, Equatable, Sendable, CaseIterable {
    case on
    case paused
    case muted
}

public struct RoomMember: Equatable, Identifiable, Sendable {
    /// Random per join, 16 lower-case hex characters.
    public var peer: String
    public var name: String
    /// Index into `TagColors.all`.
    public var color: Int
    public var path: MemberPath
    public var status: MemberStatus
    public var needsUpdate: Bool
    /// An app older than 0.5.0: it can't show our emotes.
    public var noEmotes: Bool
    /// Muted by us, for this session.
    public var muted: Bool
    public var isSelf: Bool

    public var id: String { peer }
}

public enum RoomPhase: String, Equatable, Sendable {
    case idle
    case joining
    case active
}

public struct RoomState: Equatable, Sendable {
    public var phase: RoomPhase
    /// Display form, PING-XXXXX-XXXXX.
    public var code: String?
    /// Us first, then everyone else in the order they appeared.
    public var members: [RoomMember]
    public var lan: TransportStatus
    public var internet: TransportStatus
    /// In a room and alone for 20 s: the code may be wrong.
    public var lonely: Bool
    /// Someone with the room key keeps sending packets more than 10 minutes off our clock: a device with a wrong
    /// clock, or old packets replayed. Only a hint: such packets never add a member.
    public var clockSkew: Bool
}

public enum JoinError: Error, Equatable, Sendable {
    /// No room code in the text.
    case invalid
    /// A code with a typo in it: the check character doesn't match.
    case mistyped
    /// The keys couldn't be derived.
    case failed
}

public enum JoinResult: Equatable, Sendable {
    case ok
    case failure(JoinError)
}

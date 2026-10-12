import Foundation

public enum ReplayVerdict: Equatable, Sendable {
    case ok
    case stale
    case replay
    case gone
}

/// Rejects packets seen before (per-peer sequence window), too old or new to trust, or from a peer that left.
public final class ReplayGuard {
    private static let window = 64
    /// Wide enough for machines whose clocks aren't synced; old enough captures can't be replayed later.
    private static let maxSkewMs = 10 * 60 * 1000

    private var peers: [String: (max: Int, bits: UInt64)] = [:]
    private var gone = Set<String>()
    private let now: () -> Int

    public init(now: @escaping () -> Int) {
        self.now = now
    }

    public func accept(peer: String, seq: Int, ts: Int) -> ReplayVerdict {
        if gone.contains(peer) { return .gone }
        if abs(ts - now()) > Self.maxSkewMs { return .stale }
        guard var p = peers[peer] else {
            peers[peer] = (max: seq, bits: 1)
            return .ok
        }
        if seq > p.max {
            let shift = seq - p.max
            p.bits = shift >= Self.window ? 1 : (p.bits << UInt64(shift)) | 1
            p.max = seq
            peers[peer] = p
            return .ok
        }
        let back = p.max - seq
        if back >= Self.window { return .replay }
        let bit: UInt64 = 1 << UInt64(back)
        if p.bits & bit != 0 { return .replay }
        p.bits |= bit
        peers[peer] = p
        return .ok
    }

    public func markGone(_ peer: String) {
        gone.insert(peer)
        peers[peer] = nil
    }
}

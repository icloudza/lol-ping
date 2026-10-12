import Foundation

public struct FloodLimits: Equatable, Sendable {
    /// Packets per second from one source address.
    public var perIp: Double
    /// Packets per second from all sources together: source addresses are easy to spoof on a LAN.
    public var total: Double
    /// Most source addresses remembered; past this the per-address budgets start over, so memory stays bounded.
    public var maxTracked: Int

    public init(perIp: Double, total: Double, maxTracked: Int) {
        self.perIp = perIp
        self.total = total
        self.maxTracked = maxTracked
    }

    public static let `default` = FloodLimits(perIp: 100, total: 800, maxTracked: 1024)
}

/// Decides, before any decryption is tried, whether a received packet is worth looking at.
public final class FloodGuard {
    private let perIp: RateLimiter
    private let total: RateLimiter
    private let limits: FloodLimits

    public init(now: @escaping () -> Int, limits: FloodLimits = .default) {
        perIp = RateLimiter(now: now)
        total = RateLimiter(now: now)
        self.limits = limits
    }

    public func allow(_ ip: String) -> Bool {
        if perIp.size >= limits.maxTracked { perIp.clear() }
        // Per address first, so one noisy source doesn't use up everyone else's share.
        return perIp.allow(ip, perSecond: limits.perIp) && total.allow("*", perSecond: limits.total)
    }

    public var tracked: Int { perIp.size }
}

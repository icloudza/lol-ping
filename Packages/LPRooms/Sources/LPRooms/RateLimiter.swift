import Foundation

/// Token bucket per key: `burst` tokens (one second's worth by default), refilled continuously at `perSecond`.
/// Excess calls are refused, never queued.
public final class RateLimiter {
    private var buckets: [String: (tokens: Double, at: Int)] = [:]
    private let now: () -> Int

    /// `now` is in milliseconds.
    public init(now: @escaping () -> Int) {
        self.now = now
    }

    /// `perSecond` 0 means unlimited.
    public func allow(_ key: String, perSecond: Double, burst: Double? = nil) -> Bool {
        if perSecond <= 0 { return true }
        let burst = burst ?? perSecond
        let now = self.now()
        var b = buckets[key] ?? (tokens: burst, at: now)
        b.tokens = min(burst, b.tokens + Double(now - b.at) / 1000 * perSecond)
        b.at = now
        defer { buckets[key] = b }
        if b.tokens < 1 { return false }
        b.tokens -= 1
        return true
    }

    public func forget(_ key: String) {
        buckets[key] = nil
    }

    /// How many keys have a bucket.
    public var size: Int { buckets.count }

    public func clear() {
        buckets.removeAll()
    }
}

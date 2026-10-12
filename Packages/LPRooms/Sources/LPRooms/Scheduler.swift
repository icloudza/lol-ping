import Foundation

/// A pending `after` or `every`. Cancelling one that already fired or was cancelled does nothing.
public protocol RoomTimer: AnyObject {
    func cancel()
}

/// The clock and timers of the room code: what `Date.now`, `setTimeout` and `setInterval` are upstream. Everything
/// in this package reads the time and schedules through one of these, so tests can run a room on a fake clock.
public protocol RoomScheduler: AnyObject {
    /// Milliseconds since 1970, a whole number like JavaScript's `Date.now()`: it goes into messages as `ts`.
    func now() -> Int
    /// Runs `block` once, `ms` from now.
    func after(_ ms: Double, _ block: @escaping () -> Void) -> RoomTimer
    /// Runs `block` every `ms`, first after `ms`.
    func every(_ ms: Double, _ block: @escaping () -> Void) -> RoomTimer
}

/// The real clock, with timers on one dispatch queue (the main queue in the app).
public final class DispatchRoomScheduler: RoomScheduler {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func now() -> Int {
        Int((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    public func after(_ ms: Double, _ block: @escaping () -> Void) -> RoomTimer {
        Token(queue: queue, ms: ms, repeats: false, block: block)
    }

    public func every(_ ms: Double, _ block: @escaping () -> Void) -> RoomTimer {
        Token(queue: queue, ms: ms, repeats: true, block: block)
    }

    private final class Token: RoomTimer {
        private var source: DispatchSourceTimer?

        init(queue: DispatchQueue, ms: Double, repeats: Bool, block: @escaping () -> Void) {
            // Strict: presence every 2 s is what keeps us in the room for the others, and a menu bar app with no window
            // on screen is otherwise fair game for App Nap, which stretches timers by many seconds.
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            // Uptime, like Node's timers: asleep, nothing fires, and RoomManager notices the gap on its next tick.
            let micros = Int(max(repeats ? 1 : 0, ms.isFinite ? ms : 0) * 1000)
            let delay = DispatchTimeInterval.microseconds(micros)
            source.schedule(deadline: .now() + delay, repeating: repeats ? delay : .never, leeway: .milliseconds(micros >= 1_000_000 ? 20 : 1))
            // The handler keeps the token alive, as a JavaScript timer fires whether or not anyone kept its handle.
            source.setEventHandler { [self] in
                guard self.source != nil else { return }
                if !repeats { cancel() }
                block()
            }
            self.source = source
            source.resume()
        }

        func cancel() {
            source?.cancel()
            source = nil
        }
    }
}

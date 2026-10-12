import ApplicationServices
import Foundation
import LPCore

/// Watches the whole system's mouse and keyboard through a Quartz event tap and lets the gesture engine decide what
/// to keep from other apps. Needs Accessibility permission.
///
/// The tap has a thread to itself. An active tap sits in the path of every input event, so anything slow here would
/// be felt as lag everywhere; the thread never waits on the main thread, and results cross over asynchronously.
final class EventTap {
    enum Status: Equatable {
        case stopped
        case running
        /// macOS refused to create the tap: the app isn't allowed under Accessibility.
        case refused
    }

    /// Stamped on the clicks this app posts itself, so the tap recognises them and lets them through.
    private static let ownEventTag: Int64 = 0x4C_6F6C_5069 // "LolPi"

    /// Both run on the main queue.
    var onAction: ((GestureAction) -> Void)?
    var onStatus: ((Status) -> Void)?
    private(set) var status = Status.stopped

    private let engine = GestureEngine() // touched on the tap thread only
    private var port: CFMachPort?
    private var thread: Thread?
    private let lock = NSLock()
    private var runLoop: CFRunLoop? // guarded by `lock`
    private var config = GestureConfig() // guarded by `lock`
    private var suspended = false // guarded by `lock`

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Puts the app in the Accessibility list and brings up the system's own prompt.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // MARK: - From the main thread

    /// Takes effect at once when the tap is running, and is remembered for when it starts.
    func apply(_ newConfig: GestureConfig) {
        lock.lock()
        config = newConfig
        lock.unlock()
        onTapThread { $0.deliver($0.engine.apply(newConfig)) }
    }

    /// Lets every event through untouched while the settings window records a key.
    func setSuspended(_ on: Bool) {
        lock.lock()
        suspended = on
        lock.unlock()
        onTapThread { $0.deliver($0.engine.setSuspended(on)) }
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.main() }
        t.name = "LolPing event tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    private func onTapThread(_ work: @escaping (EventTap) -> Void) {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if let self { work(self) }
        }
        CFRunLoopWakeUp(loop)
    }

    private func announce(_ s: Status) {
        DispatchQueue.main.async {
            if s != .running { self.thread = nil }
            self.status = s
            self.onStatus?(s)
        }
    }

    // MARK: - On the tap thread

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func main() {
        let watched: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let mask = watched.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(context).takeUnretainedValue()
            return tap.shouldConsume(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            announce(.refused)
            return
        }
        self.port = port
        let loop = CFRunLoopGetCurrent()!
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        // Once a second: notice keys whose release never arrived, and give up a gesture that has gone quiet.
        let housekeeping = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) { [weak self] _ in
            guard let self else { return }
            self.resync()
            self.deliver(self.engine.checkStall(now: Self.now))
        }
        CFRunLoopAddTimer(loop, housekeeping, .commonModes)

        lock.lock()
        runLoop = loop
        let startConfig = config, startSuspended = suspended
        lock.unlock()
        deliver(engine.apply(startConfig))
        deliver(engine.setSuspended(startSuspended))
        resync() // a key may already be held
        announce(.running)

        CFRunLoopRun()

        lock.lock()
        runLoop = nil
        lock.unlock()
        deliver(engine.setEnabled(false)) // takes down a wheel that is still showing
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopTimerInvalidate(housekeeping)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(port)
        self.port = nil
        announce(.stopped)
    }

    private func resync() {
        let held = KeyModifiers(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        deliver(engine.resync(modifiers: held) { CGEventSource.keyState(.combinedSessionState, key: $0) })
    }

    /// Passes the engine's decisions on: actions to the main queue, replays back into the event stream.
    @discardableResult
    private func deliver(_ outcome: GestureOutcome) -> Bool {
        if !outcome.actions.isEmpty {
            let actions = outcome.actions
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                actions.forEach { self.onAction?($0) }
            }
        }
        for replay in outcome.replays {
            switch replay {
            case .down(let button, let point): post(button, down: true, at: point)
            case .up(let button, let point): post(button, down: false, at: point)
            }
        }
        return outcome.consume
    }

    private func post(_ button: PointerButton, down: Bool, at point: CGPoint) {
        let type: CGEventType, cgButton: CGMouseButton, number: Int64
        switch button {
        case .primary: (type, cgButton, number) = (down ? .leftMouseDown : .leftMouseUp, .left, 0)
        case .secondary: (type, cgButton, number) = (down ? .rightMouseDown : .rightMouseUp, .right, 1)
        case .other(let n): (type, cgButton, number) = (down ? .otherMouseDown : .otherMouseUp, .center, Int64(n))
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        // The modifiers held right now, so a replayed Option-click is still an Option-click.
        event.flags = CGEventSource.flagsState(.combinedSessionState)
        event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventTag)
        event.post(tap: .cghidEventTap)
    }

    private func shouldConsume(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // macOS switches a tap off when it answers too slowly or the user holds a secure-input field: switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            resync()
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventTag { return false }
        let time = Self.now
        // Every event carries the modifier state; reading it from all of them means a missed flags-changed event
        // corrects itself on the next mouse move.
        deliver(engine.handle(.modifiers(KeyModifiers(eventFlags: event.flags.rawValue)), at: time))

        switch type {
        case .flagsChanged:
            return false
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return deliver(engine.handle(.keyDown(code, isRepeat: isRepeat), at: time))
        case .keyUp:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            return deliver(engine.handle(.keyUp(code), at: time))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return deliver(engine.handle(.moved(to: event.location), at: time))
        case .leftMouseDown: return deliver(engine.handle(.buttonDown(.primary, at: event.location), at: time))
        case .leftMouseUp: return deliver(engine.handle(.buttonUp(.primary, at: event.location), at: time))
        case .rightMouseDown: return deliver(engine.handle(.buttonDown(.secondary, at: event.location), at: time))
        case .rightMouseUp: return deliver(engine.handle(.buttonUp(.secondary, at: event.location), at: time))
        case .otherMouseDown, .otherMouseUp:
            let button = PointerButton.other(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
            let input: InputEvent = type == .otherMouseDown ? .buttonDown(button, at: event.location) : .buttonUp(button, at: event.location)
            return deliver(engine.handle(input, at: time))
        default:
            return false
        }
    }
}

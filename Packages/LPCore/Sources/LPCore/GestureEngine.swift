import CoreGraphics
import Foundation

/// A mouse button, as the gesture engine sees it.
public enum PointerButton: Hashable, Sendable {
    case primary
    case secondary
    /// Any other button, by the number the system gives it (2 is the middle button, 3 and 4 the side buttons).
    case other(Int)
}

/// What the event tap reports, already stripped of everything the engine doesn't need.
public enum InputEvent: Equatable, Sendable {
    /// The modifiers now held. Sent whenever they change; every mouse event's modifiers are fed through here too,
    /// which keeps the picture right while a password field hides keyboard events.
    case modifiers(KeyModifiers)
    case keyDown(UInt16, isRepeat: Bool)
    case keyUp(UInt16)
    case buttonDown(PointerButton, at: CGPoint)
    case buttonUp(PointerButton, at: CGPoint)
    case moved(to: CGPoint)
}

public struct GestureConfig: Equatable, Sendable {
    public struct Wheel: Equatable, Sendable {
        /// Nil: this wheel is off.
        public var trigger: Trigger?
        /// Trigger + click without a drag sends the wheel's quick item; otherwise the click goes to the app underneath.
        public var clickSends: Bool

        public init(trigger: Trigger?, clickSends: Bool = false) {
            self.trigger = trigger
            self.clickSends = clickSends
        }
    }

    public var ping = Wheel(trigger: .modifier(.option))
    public var emote = Wheel(trigger: nil)
    public var dragThreshold: Double = 8
    /// What each global shortcut does.
    public var hotkeys = Hotkeys.standard.byCombo
    public var isEnabled = true

    public init() {}

    public init(_ p: Preferences, enabled: Bool) {
        ping = Wheel(trigger: p.ping.trigger, clickSends: p.ping.clickSends)
        emote = Wheel(trigger: p.emote.isOn ? p.emote.trigger : nil, clickSends: p.emote.clickSends)
        dragThreshold = p.dragThreshold
        hotkeys = p.hotkeys.byCombo
        isEnabled = enabled
    }
}

/// What the app should do in response to input.
public enum GestureAction: Equatable, Sendable {
    /// Show the wheel centred where the button went down.
    case wheelOpened(WheelKind, at: CGPoint)
    case wheelMoved(to: CGPoint)
    /// The button came up at this point: send whatever is under it, then hide the wheel.
    case wheelReleased(at: CGPoint)
    /// Trigger + click: send the wheel's quick item here.
    case quickSent(WheelKind, at: CGPoint)
    /// Hide the wheel and send nothing.
    case cancelled
    /// The pause shortcut was pressed.
    case enabledChanged(Bool)
    /// Any other global shortcut was pressed.
    case hotkey(HotkeyAction)
}

/// A click the engine held back and now wants delivered to the app underneath after all.
public enum PointerReplay: Equatable, Sendable {
    case down(PointerButton, at: CGPoint)
    case up(PointerButton, at: CGPoint)
}

public struct GestureOutcome: Equatable, Sendable {
    /// Keep the event from reaching any other app.
    public var consume = false
    public var actions: [GestureAction] = []
    public var replays: [PointerReplay] = []

    public init() {}
}

/// Turns raw mouse and keyboard input into wheel gestures, and decides which events other apps never get to see.
///
/// A gesture starts when a button goes down while exactly one wheel's trigger is satisfied: its modifiers held and no
/// others, so ⌥ and ⌥⇧ can open different wheels. From then on the engine
/// owns that button: its press was withheld, so its release is withheld too, or the pair is replayed together when it
/// turns out to be an ordinary click. Whatever else happens, no app is left holding half a click.
///
/// The engine keeps no clock and calls nothing: it is fed events with a timestamp and answers with an outcome, which
/// makes every rule testable by a list of events.
public final class GestureEngine {
    /// A gesture with no pointer activity for this long is abandoned (the button-up was probably lost).
    public static let stallTimeout: TimeInterval = 10

    private struct Session {
        let wheel: WheelKind
        let button: PointerButton
        let origin: CGPoint
    }

    private enum Phase {
        case idle
        /// The press is withheld; a drag opens the wheel, a release makes it a click.
        case pressed(Session)
        /// The wheel is on screen.
        case open(Session)
        /// The gesture ended early; the button's release still belongs to the engine.
        case awaitingRelease(PointerButton)
    }

    public private(set) var config = GestureConfig()
    public private(set) var isEnabled = true
    public private(set) var isSuspended = false

    private var phase = Phase.idle
    private var modifiers: KeyModifiers = []
    private var keysDown = Set<UInt16>()
    /// Keys whose press was consumed: their release is consumed as well.
    private var consumedKeys = Set<UInt16>()
    private var consumeSecondaryRelease = false
    /// Another key was pressed while a trigger was held (⌥Tab, ⌃C…): the trigger is part of someone else's shortcut,
    /// so clicks are left alone until every trigger key is up again.
    private var shortcutInProgress = false
    private var lastPointerTime: TimeInterval = 0

    public init() {}

    public var isGestureActive: Bool {
        switch phase {
        case .pressed, .open: return true
        case .idle, .awaitingRelease: return false
        }
    }

    // MARK: - Control

    public func apply(_ newConfig: GestureConfig) -> GestureOutcome {
        var out = GestureOutcome()
        abandon(&out)
        config = newConfig
        isEnabled = newConfig.isEnabled
        return out
    }

    public func setEnabled(_ on: Bool) -> GestureOutcome {
        var out = GestureOutcome()
        if !on { abandon(&out) }
        isEnabled = on
        return out
    }

    /// While suspended every event passes untouched, the global shortcuts included (the settings window is recording a key).
    public func setSuspended(_ on: Bool) -> GestureOutcome {
        var out = GestureOutcome()
        if on { abandon(&out) }
        isSuspended = on
        return out
    }

    /// Call now and then: gives up a gesture that has seen no pointer activity for `stallTimeout`.
    public func checkStall(now: TimeInterval) -> GestureOutcome {
        var out = GestureOutcome()
        if isGestureActive && now - lastPointerTime > Self.stallTimeout { abandon(&out) }
        return out
    }

    /// Corrects the engine's idea of what is held from what the system says. Releases can go missing (a password
    /// field, the login window, the tap being switched off); a key is only ever forgotten here, never assumed down.
    public func resync(modifiers current: KeyModifiers, isKeyDown: (UInt16) -> Bool) -> GestureOutcome {
        var out = GestureOutcome()
        keysDown = keysDown.filter { consumedKeys.contains($0) || isKeyDown($0) }
        setModifiers(current, &out)
        if !anyTriggerHeld { shortcutInProgress = false }
        return out
    }

    // MARK: - Events

    public func handle(_ event: InputEvent, at time: TimeInterval) -> GestureOutcome {
        var out = GestureOutcome()
        switch event {
        case .modifiers(let now):
            setModifiers(now, &out)
        case .keyDown(let code, let isRepeat):
            keyDown(code, isRepeat: isRepeat, &out)
        case .keyUp(let code):
            keyUp(code, &out)
        case .buttonDown(let button, let point):
            lastPointerTime = time
            buttonDown(button, at: point, &out)
        case .buttonUp(let button, let point):
            lastPointerTime = time
            buttonUp(button, at: point, &out)
        case .moved(let point):
            lastPointerTime = time
            moved(to: point, &out)
        }
        return out
    }

    // MARK: - Triggers

    private var isActive: Bool { isEnabled && !isSuspended }

    private func trigger(_ wheel: WheelKind) -> Trigger? {
        wheel == .ping ? config.ping.trigger : config.emote.trigger
    }

    private func clickSends(_ wheel: WheelKind) -> Bool {
        wheel == .ping ? config.ping.clickSends : config.emote.clickSends
    }

    /// Whether the wheel's key is down. A side-button trigger has no key, so it is never "held".
    /// `exactly`: with no other modifier held, which is what starting a gesture takes. Once a gesture is under way
    /// an extra modifier doesn't end it.
    private func isHeld(_ wheel: WheelKind, exactly: Bool = true) -> Bool {
        func fits(_ wanted: KeyModifiers) -> Bool { exactly ? modifiers == wanted : modifiers.isSuperset(of: wanted) }
        switch trigger(wheel) {
        case .modifier(let m): return fits(m)
        case .key(let combo): return keysDown.contains(combo.keyCode) && fits(combo.modifiers)
        case .sideButton, nil: return false
        }
    }

    /// Loosely: a trigger with more held on top of it still counts, since that is how someone else's shortcut looks.
    private var anyTriggerHeld: Bool { isHeld(.ping, exactly: false) || isHeld(.emote, exactly: false) }

    private func isKeyTrigger(_ wheel: WheelKind) -> Bool { trigger(wheel)?.combo != nil }

    /// Whether this key, pressed with the modifiers held right now, is a wheel's trigger.
    private func isTriggerKey(_ code: UInt16) -> Bool {
        let pressed = Trigger.key(KeyCombo(keyCode: code, modifiers: modifiers))
        return trigger(.ping) == pressed || trigger(.emote) == pressed
    }

    /// Whether pressing `button` right now starts a gesture for this wheel.
    private func claims(_ wheel: WheelKind, _ button: PointerButton) -> Bool {
        switch trigger(wheel) {
        case .sideButton(let n): return button == .other(n)
        case .modifier, .key: return button == .primary && isHeld(wheel)
        case nil: return false
        }
    }

    private var session: Session? {
        switch phase {
        case .pressed(let s), .open(let s): return s
        case .idle, .awaitingRelease: return nil
        }
    }

    /// Ends a gesture without sending anything. The button is still down, so its release stays ours.
    private func abandon(_ out: inout GestureOutcome) {
        guard let s = session else { return }
        out.actions.append(.cancelled)
        phase = .awaitingRelease(s.button)
    }

    /// The key that started the gesture was let go before the button.
    private func triggerReleased(_ out: inout GestureOutcome) {
        switch phase {
        case .pressed(let s):
            if clickSends(s.wheel) {
                out.actions.append(.quickSent(s.wheel, at: s.origin))
                phase = .awaitingRelease(s.button)
            } else {
                // An ordinary click after all: hand the press over now, and let the real release follow on its own.
                out.replays.append(.down(s.button, at: s.origin))
                phase = .idle
            }
        case .open:
            abandon(&out)
        case .idle, .awaitingRelease:
            break
        }
    }

    // MARK: - Keyboard

    private func setModifiers(_ now: KeyModifiers, _ out: inout GestureOutcome) {
        guard now != modifiers else { return }
        let wasHeld = session.map { isHeld($0.wheel, exactly: false) } ?? false
        modifiers = now
        if !anyTriggerHeld { shortcutInProgress = false }
        if wasHeld, let s = session, !isHeld(s.wheel, exactly: false) { triggerReleased(&out) }
    }

    private func keyDown(_ code: UInt16, isRepeat: Bool, _ out: inout GestureOutcome) {
        let fresh = !isRepeat && !keysDown.contains(code)
        if case .idle = phase, !isTriggerKey(code), anyTriggerHeld { shortcutInProgress = true }
        keysDown.insert(code)

        // A key whose press was kept from other apps stays kept while it repeats, even if the modifiers it was
        // pressed with have been let go since.
        if isRepeat, consumedKeys.contains(code) {
            out.consume = true
            return
        }
        if !isSuspended, let action = config.hotkeys[KeyCombo(keyCode: code, modifiers: modifiers)], isEnabled || action.worksWhilePaused {
            out.consume = true
            consumedKeys.insert(code)
            guard fresh else { return }
            if action == .toggleEnabled {
                if isEnabled { abandon(&out) }
                isEnabled.toggle()
                out.actions.append(.enabledChanged(isEnabled))
            } else {
                out.actions.append(.hotkey(action))
            }
            return
        }
        if isActive {
            if code == KeyNames.escape, isGestureActive {
                out.consume = true
                consumedKeys.insert(code)
                abandon(&out)
                return
            }
            // A key used as a trigger would otherwise type its letter into whatever is underneath.
            if isTriggerKey(code) {
                out.consume = true
                consumedKeys.insert(code)
                return
            }
        }
        consumedKeys.remove(code) // this press went through, so an old "consume its release" note is stale
    }

    private func keyUp(_ code: UInt16, _ out: inout GestureOutcome) {
        let wasHeld = session.map { isHeld($0.wheel, exactly: false) } ?? false
        keysDown.remove(code)
        if consumedKeys.remove(code) != nil { out.consume = true }
        if !anyTriggerHeld { shortcutInProgress = false }
        if wasHeld, let s = session, !isHeld(s.wheel, exactly: false) { triggerReleased(&out) }
    }

    // MARK: - Pointer

    private func buttonDown(_ button: PointerButton, at point: CGPoint, _ out: inout GestureOutcome) {
        // A second press of a button whose release we were waiting for: that release was lost.
        if case .awaitingRelease(let owed) = phase, owed == button { phase = .idle }
        if button == .secondary { consumeSecondaryRelease = false }
        guard isActive else { return }

        if isGestureActive {
            // A right-click backs out of the wheel.
            if button == .secondary {
                out.consume = true
                consumeSecondaryRelease = true
                abandon(&out)
            }
            return
        }
        guard case .idle = phase, !shortcutInProgress else { return }
        // Exactly one wheel must want this press. With both keys held there is no telling which was meant, so the
        // click goes through untouched.
        var ping = claims(.ping, button), emote = claims(.emote, button)
        // "⌥ and Z" held satisfies a wheel on ⌥ as well; the one that names a key is the one that was meant.
        if ping, emote, isKeyTrigger(.ping) != isKeyTrigger(.emote) { (ping, emote) = (isKeyTrigger(.ping), isKeyTrigger(.emote)) }
        guard ping != emote else { return }
        out.consume = true
        phase = .pressed(Session(wheel: ping ? .ping : .emote, button: button, origin: point))
    }

    private func buttonUp(_ button: PointerButton, at point: CGPoint, _ out: inout GestureOutcome) {
        if button == .secondary, consumeSecondaryRelease {
            consumeSecondaryRelease = false
            out.consume = true
            return
        }
        switch phase {
        case .pressed(let s) where s.button == button:
            out.consume = true
            if clickSends(s.wheel) {
                out.actions.append(.quickSent(s.wheel, at: s.origin))
            } else {
                // No drag: it was a plain click. Deliver the press where it happened and the release where it ended.
                out.replays.append(.down(button, at: s.origin))
                out.replays.append(.up(button, at: point))
            }
            phase = .idle
        case .open(let s) where s.button == button:
            out.consume = true
            out.actions.append(.wheelReleased(at: point))
            phase = .idle
        case .awaitingRelease(let owed) where owed == button:
            out.consume = true
            phase = .idle
        default:
            break
        }
    }

    /// Movement is never consumed: holding it back would freeze the pointer.
    private func moved(to point: CGPoint, _ out: inout GestureOutcome) {
        switch phase {
        case .pressed(let s):
            let dx = point.x - s.origin.x, dy = point.y - s.origin.y
            guard (dx * dx + dy * dy).squareRoot() > config.dragThreshold else { return }
            phase = .open(s)
            out.actions.append(.wheelOpened(s.wheel, at: s.origin))
            out.actions.append(.wheelMoved(to: point))
        case .open:
            out.actions.append(.wheelMoved(to: point))
        case .idle, .awaitingRelease:
            break
        }
    }
}

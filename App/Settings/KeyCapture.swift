import AppKit
import LPCore
import SwiftUI

/// A button that records what the user presses: click it, then press. Esc or a click elsewhere backs out, and a
/// bare Delete clears when the field can be cleared.
/// The event tap stands aside while it listens, so even the app's own shortcuts reach this window.
struct KeyRecorder: View {
    enum Kind {
        /// A key, with or without modifiers.
        case shortcut
        /// That, or modifiers on their own, or an extra mouse button.
        case trigger
    }

    @EnvironmentObject var app: AppController
    /// What the button shows when it isn't listening, one keycap per entry. Empty: `placeholder`.
    let caps: [String]
    var placeholder = ""
    let kind: Kind
    var onClear: (() -> Void)?
    /// A shortcut arrives as `.key`.
    let onRecord: (Trigger) -> Void

    @State private var listening = false
    @State private var complaint: String?
    /// The modifiers down right now, and all that have been down since the last time none were.
    @State private var held: KeyModifiers = []
    @State private var gathered: KeyModifiers = []
    @State private var monitor: Any?

    var body: some View {
        Button {
            listening ? stop() : listen()
        } label: {
            HStack(spacing: 6) {
                if listening {
                    Text(complaint ?? (held.isEmpty ? prompt : held.symbols + " …")).foregroundStyle(complaint == nil ? .secondary : .primary)
                } else if caps.isEmpty {
                    Text(placeholder).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in Keycap(text: cap) }
                }
                Image(systemName: listening ? "record.circle" : "pencil").foregroundStyle(listening ? Color.red : Color.secondary)
            }
            .padding(.vertical, 2)
        }
        .help(app.text.recorderHelp)
        .onDisappear { if listening { stop() } }
    }

    private var prompt: String { kind == .trigger ? app.text.pressTrigger : app.text.pressShortcut }

    private func listen() {
        listening = true
        complaint = nil
        held = []
        gathered = []
        app.setRecordingKey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            switch event.type {
            case .keyDown:
                pressed(event)
                return nil
            case .flagsChanged:
                modifiersChanged(KeyModifiers(eventFlags: UInt64(event.modifierFlags.rawValue)))
                return event
            case .otherMouseDown where kind == .trigger && Trigger.buttonNumbers.contains(event.buttonNumber):
                finish(.sideButton(event.buttonNumber))
                return nil
            default:
                stop() // the click still does whatever it was aimed at
                return event
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        complaint = nil
        app.setRecordingKey(false)
    }

    private func finish(_ recorded: Trigger) {
        stop()
        onRecord(recorded)
    }

    /// Modifiers pressed and let go again with no key in between are a trigger of their own.
    private func modifiersChanged(_ now: KeyModifiers) {
        held = now
        if !now.isEmpty {
            gathered.formUnion(now)
            complaint = nil
        } else if !gathered.isEmpty {
            let all = gathered
            gathered = []
            if kind == .trigger { finish(.modifier(all)) }
        }
    }

    private func pressed(_ event: NSEvent) {
        if event.isARepeat { return } // a key that was already held when listening began
        let combo = KeyCombo(keyCode: event.keyCode, modifiers: KeyModifiers(eventFlags: UInt64(event.modifierFlags.rawValue)))
        gathered = [] // the modifiers belong to this key press, not to a trigger of their own
        if combo.modifiers.isEmpty {
            if combo.keyCode == KeyNames.escape { return stop() }
            if combo.keyCode == 51 || combo.keyCode == 117, let onClear { // Delete, Forward Delete
                stop()
                return onClear()
            }
        }
        guard combo.isUsable else {
            complaint = KeyNames.reserved.contains(combo.keyCode) ? app.text.keyReserved : app.text.keyUnusable
            return
        }
        finish(.key(combo))
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
    }
}

/// A recorder with a small button in front of it that empties the field. The recorder itself always ends at the
/// row's right edge, whether or not there is something to clear.
private struct ClearableRecorder: View {
    @EnvironmentObject var app: AppController
    let caps: [String]
    let placeholder: String
    let kind: KeyRecorder.Kind
    /// The label of the clearing command, when the field can be cleared at all.
    var clearTitle: String?
    /// Whether "Restore Default" would change anything.
    let canRestore: Bool
    let onClear: () -> Void
    let onRestore: () -> Void
    let onRecord: (Trigger) -> Void

    var body: some View {
        let clearable = clearTitle != nil && !caps.isEmpty
        HStack(spacing: 6) {
            if clearable {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(clearTitle ?? "")
            }
            KeyRecorder(caps: caps, placeholder: placeholder, kind: kind, onClear: clearable ? onClear : nil, onRecord: onRecord)
                .contextMenu {
                    Button(app.text.restoreDefault, action: onRestore).disabled(!canRestore)
                    if let clearTitle { Button(clearTitle, action: onClear).disabled(!clearable) }
                }
        }
    }
}

/// Sets what opens a wheel. `selection` nil: the wheel is off, which only a field with `allowsOff` can be.
struct TriggerField: View {
    @EnvironmentObject var app: AppController
    let selection: Trigger?
    let standard: Trigger
    var allowsOff = false
    let onPick: (Trigger?) -> Void

    var body: some View {
        let t = app.text
        ClearableRecorder(
            caps: selection.map(t.triggerCaps) ?? [], placeholder: t.off, kind: .trigger,
            clearTitle: allowsOff ? t.turnOff : nil, canRestore: selection != standard,
            onClear: { onPick(nil) }, onRestore: { onPick(standard) }, onRecord: { onPick($0) }
        )
    }
}

/// Sets a global shortcut, or none.
struct HotkeyField: View {
    @EnvironmentObject var app: AppController
    let combo: KeyCombo?
    let standard: KeyCombo?
    let onPick: (KeyCombo?) -> Void

    var body: some View {
        let t = app.text
        ClearableRecorder(
            caps: combo?.parts ?? [], placeholder: t.notSet, kind: .shortcut,
            clearTitle: t.clearKey, canRestore: combo != standard,
            onClear: { onPick(nil) }, onRestore: { onPick(standard) }, onRecord: { onPick($0.combo) }
        )
    }
}

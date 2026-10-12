import Foundation

/// The four modifier keys, left and right alike.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)

    public static let each: [KeyModifiers] = [.control, .option, .shift, .command]

    /// From the flags of a Quartz or AppKit event (both use the same bits for these four).
    public init(eventFlags: UInt64) {
        var m: KeyModifiers = []
        if eventFlags & 0x0004_0000 != 0 { m.insert(.control) }
        if eventFlags & 0x0008_0000 != 0 { m.insert(.option) }
        if eventFlags & 0x0002_0000 != 0 { m.insert(.shift) }
        if eventFlags & 0x0010_0000 != 0 { m.insert(.command) }
        self = m
    }

    private static let storedNames: [(String, KeyModifiers)] = [("control", .control), ("option", .option), ("shift", .shift), ("command", .command)]

    /// "control", "option"… one per modifier held, in the order macOS writes shortcuts.
    public var storedNames: [String] { Self.storedNames.filter { contains($0.1) }.map(\.0) }

    /// The modifiers named by `names`; nil when any of them isn't a modifier's name.
    public init?<S: Sequence>(storedNames names: S) where S.Element: StringProtocol {
        var m: KeyModifiers = []
        for name in names {
            guard let known = Self.storedNames.first(where: { $0.0 == name }) else { return nil }
            m.insert(known.1)
        }
        self = m
    }

    /// "⌃⌥⇧⌘", in the order macOS writes shortcuts.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }

    /// "⌥ Option" for a single modifier.
    public var title: String {
        switch self {
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        default: return symbols
        }
    }
}

/// A keyboard shortcut: a key and the modifiers held with it. Key codes are macOS virtual key codes.
public struct KeyCombo: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Its parts for drawing as keycaps: one per modifier, then the key.
    public var parts: [String] { KeyModifiers.each.filter(modifiers.contains).map(\.symbols) + [KeyNames.name(keyCode)] }
    /// "⌃⌥P".
    public var title: String { parts.joined() }

    /// Without ⌃, ⌥ or ⌘ the key is one that types: taking it away from every app is allowed, and worth a warning.
    public var isSafeGlobally: Bool { !modifiers.isDisjoint(with: [.control, .option, .command]) }

    /// Whether taking this key for the app costs something that is typed: no ⌃, ⌥ or ⌘, and not a function key.
    public var takesATypingKey: Bool { !isSafeGlobally && !KeyNames.functionKeys.contains(keyCode) }

    /// Whether the app can listen for this at all: a real key, and not one that typing or moving around can't do
    /// without (Return, Tab, Space, Delete, Esc, the arrows) unless ⌃, ⌥ or ⌘ is held with it.
    public var isUsable: Bool {
        keyCode < 128 && !KeyNames.modifierKeys.contains(keyCode) && (isSafeGlobally || !KeyNames.reserved.contains(keyCode))
    }
}

extension KeyCombo: Codable {
    /// "key:35", "key:35+control+option".
    public var storedValue: String { (["key:\(keyCode)"] + modifiers.storedNames).joined(separator: "+") }

    public init?(storedValue: String) {
        let parts = storedValue.split(separator: "+", omittingEmptySubsequences: false)
        guard let head = parts.first, head.hasPrefix("key:"), let code = UInt16(head.dropFirst(4)), code < 128,
              !KeyNames.modifierKeys.contains(code), let modifiers = KeyModifiers(storedNames: parts.dropFirst()) else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = KeyCombo(storedValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a shortcut: \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

public enum KeyNames {
    public static let escape: UInt16 = 53

    /// Keys that only exist as modifiers (they never arrive as key-down events).
    public static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Keys that can't be taken on their own: a key the app listens for stops reaching other apps, and losing one of
    /// these would break typing, confirming, or moving around.
    public static let reserved: Set<UInt16> = [36, 76, 48, 49, 51, 53, 123, 124, 125, 126]

    /// F1 to F20.
    public static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Enter", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11",
        111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// What is printed on the key with this code on a US keyboard, or "Key 93" for one this table doesn't know.
    public static func name(_ keyCode: UInt16) -> String { names[keyCode] ?? "Key \(keyCode)" }
}

/// What opens a wheel: modifiers held while dragging with the main button, a key (with or without modifiers) held
/// while dragging, or an extra mouse button dragged on its own.
public enum Trigger: Hashable, Sendable {
    /// One modifier or several. Never empty.
    case modifier(KeyModifiers)
    /// The button's number as the system reports it: 2 is the middle button, 3 and 4 the usual "back" and "forward".
    case sideButton(Int)
    case key(KeyCombo)

    public static let modifiers: [Trigger] = KeyModifiers.each.map(Trigger.modifier)
    public static let sideButtons: [Trigger] = [.sideButton(3), .sideButton(4)]
    public static let buttonNumbers = 2...31

    public var isSideButton: Bool {
        if case .sideButton = self { return true }
        return false
    }

    public var combo: KeyCombo? {
        if case .key(let combo) = self { return combo }
        return nil
    }

    /// Whether the trigger can be used at all (a stored one always can; this is for one just recorded).
    public var isUsable: Bool {
        switch self {
        case .modifier(let m): return !m.isEmpty
        case .sideButton(let n): return Self.buttonNumbers.contains(n)
        case .key(let combo): return combo.isUsable
        }
    }

    /// Its parts for drawing as keycaps; nil for a mouse button, which has a name instead.
    public var parts: [String]? {
        switch self {
        case .modifier(let m): return KeyModifiers.each.contains(m) ? [m.title] : KeyModifiers.each.filter(m.contains).map(\.symbols)
        case .key(let combo): return combo.parts
        case .sideButton: return nil
        }
    }
}

extension Trigger: Codable {
    /// "option", "control+option", "button:3", "key:35", "key:35+shift".
    public var storedValue: String {
        switch self {
        case .modifier(let m): return m.storedNames.joined(separator: "+")
        case .sideButton(let n): return "button:\(n)"
        case .key(let combo): return combo.storedValue
        }
    }

    public init?(storedValue: String) {
        if storedValue.hasPrefix("button:") {
            guard let n = Int(storedValue.dropFirst(7)), Self.buttonNumbers.contains(n) else { return nil }
            self = .sideButton(n)
        } else if storedValue.hasPrefix("key:") {
            guard let combo = KeyCombo(storedValue: storedValue), combo.isUsable else { return nil }
            self = .key(combo)
        } else {
            guard let m = KeyModifiers(storedNames: storedValue.split(separator: "+", omittingEmptySubsequences: false)), !m.isEmpty else { return nil }
            self = .modifier(m)
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = Trigger(storedValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a trigger: \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

/// Something a global shortcut can do.
public enum HotkeyAction: Hashable, Sendable {
    case toggleEnabled
    case openSettings
    case toggleMute
    case toggleRoomMute
    /// Send the item in the middle of the wheel where the pointer is.
    case quick(WheelKind)
    /// Send the item on one slice of the wheel where the pointer is, without opening the wheel.
    case slice(WheelKind, Int)

    public static let general: [HotkeyAction] = [.toggleEnabled, .quick(.ping), .quick(.emote), .toggleMute, .toggleRoomMute, .openSettings]
    public static func slices(_ kind: WheelKind) -> [HotkeyAction] { (0..<WheelMetrics.sliceCount).map { .slice(kind, $0) } }
    public static let all: [HotkeyAction] = general + slices(.ping) + slices(.emote)

    /// Pausing has to be undoable from the keyboard, and the settings window is where one goes to find out why
    /// nothing happens; everything else rests while the app is paused.
    public var worksWhilePaused: Bool { self == .toggleEnabled || self == .openSettings }

    /// "pause", "ping.quick", "emote.3".
    public var storedKey: String {
        switch self {
        case .toggleEnabled: return "pause"
        case .openSettings: return "settings"
        case .toggleMute: return "mute"
        case .toggleRoomMute: return "roomMute"
        case .quick(let kind): return "\(kind.rawValue).quick"
        case .slice(let kind, let index): return "\(kind.rawValue).\(index)"
        }
    }

    private static let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.storedKey, $0) })
    public init?(storedKey: String) {
        guard let action = Self.byKey[storedKey] else { return nil }
        self = action
    }
}

/// The global shortcuts: at most one key combination per action. An action that isn't in here has no shortcut.
public struct Hotkeys: Equatable, Sendable {
    private var combos: [HotkeyAction: KeyCombo]

    public init(_ combos: [HotkeyAction: KeyCombo] = [:]) { self.combos = combos }

    public static let standard = Hotkeys([.toggleEnabled: KeyCombo(keyCode: 35, modifiers: [.control, .option])]) // ⌃⌥P

    public subscript(action: HotkeyAction) -> KeyCombo? {
        get { combos[action] }
        set { combos[action] = newValue }
    }

    /// Every shortcut that is set, in the order the actions are listed.
    public var assigned: [(action: HotkeyAction, combo: KeyCombo)] {
        HotkeyAction.all.compactMap { action in combos[action].map { (action, $0) } }
    }

    public var byCombo: [KeyCombo: HotkeyAction] {
        Dictionary(assigned.map { ($0.combo, $0.action) }, uniquingKeysWith: { first, _ in first })
    }
}

extension Hotkeys: Codable {
    /// Saved as {"pause": "key:35+control+option"}. Entries that don't make sense are skipped rather than fatal.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.singleValueContainer().decode([String: String].self)
        combos = [:]
        for (key, value) in saved {
            if let action = HotkeyAction(storedKey: key), let combo = KeyCombo(storedValue: value) { combos[action] = combo }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: combos.map { ($0.key.storedKey, $0.value.storedValue) }))
    }
}

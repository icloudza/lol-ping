import Foundation

/// An image the user added as an emote. Its files live in the app's data folder, named after `id`.
public struct ImportedEmote: Codable, Hashable, Identifiable, Sendable {
    /// "c:" and 32 hex digits: a hash of the picture, so the same picture always gets the same id.
    public var id: String
    public var name: String
    /// The original file moves (a GIF or animated WebP) and was kept alongside the still.
    public var animated: Bool

    public init(id: String, name: String, animated: Bool) {
        self.id = id
        self.name = name
        self.animated = animated
    }

    public static let limit = 24
    public static let nameLimit = 24

    public static func isValidId(_ id: String) -> Bool {
        let u = Array(id.utf8)
        return u.count == 34 && u[0] == UInt8(ascii: "c") && u[1] == UInt8(ascii: ":")
            && u[2...].allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum LanguageChoice: String, Codable, CaseIterable, Sendable {
    case system
    case english = "en"
    case chinese = "zh-Hans"
}

/// Everything the user can set, as it is saved to `preferences.json`.
///
/// Reading is forgiving: a missing or unreadable field takes its default, and `repaired()` brings every value back
/// into range, so a hand-edited or older file never stops the app from starting.
public struct Preferences: Codable, Equatable, Sendable {
    public struct PingWheel: Codable, Equatable, Sendable {
        public var trigger: Trigger = .modifier(.option)
        /// Trigger + click (no drag) sends `quick` instead of passing the click on.
        public var clickSends = false
        public var slices = PingCatalog.standardWheel
        public var quick = PingCatalog.standardQuick
        /// How large a ping is drawn, in points.
        public var size: Double = 70
        /// How long a ping stays up, in seconds.
        public var duration: Double = 3.2

        public init() {}
    }

    public struct EmoteWheel: Codable, Equatable, Sendable {
        /// Off: the emote key does nothing, and the key stays remembered for when it is turned on again.
        public var isOn = true
        public var trigger: Trigger = .modifier(.control)
        public var clickSends = false
        public var slices = EmoteCatalog.standardWheel
        public var quick = EmoteCatalog.standardQuick
        public var size: Double = 150
        public var playsSound = true
        public var imported: [ImportedEmote] = []

        public init() {}
    }

    public struct Sound: Codable, Equatable, Sendable {
        /// 0 to 100.
        public var volume: Double = 70
        public var muted = false
        public var wheelTick = true

        public init() {}
    }

    public struct Room: Codable, Equatable, Sendable {
        /// Shown under your pings on other people's screens.
        public var name = "Player"
        /// Which of the eight tag colours.
        public var tagColor = 0
        /// How many pings and emotes a second are shown from each member; 0 lifts the limit.
        public var incomingLimit: Double = 5
        public var allowsInternet = true
        public var rejoinsOnLaunch = true
        /// The room to go back to on launch, without the PING prefix or dashes.
        public var lastCode: String?
        public var muted = false

        public init() {}
    }

    public struct Updates: Codable, Equatable, Sendable {
        public var checksAutomatically = true
        /// Downloads a new version in the background and installs it when the app quits, without asking first.
        public var installsAutomatically = false
        /// The newest version the app has already pointed out, so each release is announced once.
        public var announcedVersion: String?

        public init() {}
    }

    public var startsEnabled = true
    /// How far the pointer must travel with the button down before a wheel opens, in points.
    public var dragThreshold: Double = 8
    public var hotkeys = Hotkeys.standard
    public var ping = PingWheel()
    public var emote = EmoteWheel()
    public var sound = Sound()
    public var room = Room()
    public var updates = Updates()
    public var opensAtLogin = false
    public var language = LanguageChoice.system

    public init() {}

    public enum Limits {
        public static let dragThreshold: ClosedRange<Double> = 2...40
        public static let pingSize: ClosedRange<Double> = 60...220
        public static let pingDuration: ClosedRange<Double> = 1...8
        public static let emoteSize: ClosedRange<Double> = 80...300
        public static let volume: ClosedRange<Double> = 0...100
        public static let incomingLimit: ClosedRange<Double> = 0...20
        public static let tagColors = 8
        public static let nameLength = 16
    }

    // MARK: - Key conflicts

    /// One of the places a key can be assigned.
    public enum KeySlot: Hashable, Sendable {
        case pingTrigger
        case emoteTrigger
        case hotkey(HotkeyAction)
    }

    /// Two slots that ask for the same input. `first` is the one that keeps it when a saved file is repaired.
    public struct KeyConflict: Equatable, Sendable {
        public let first: KeySlot
        public let second: KeySlot
    }

    /// The first clash among everything that is assigned, if any. A trigger made of modifiers alone never clashes
    /// with a shortcut: the shortcut needs a key on top. Only an emote wheel that is on can clash.
    public var keyConflict: KeyConflict? {
        var taken: [(slot: KeySlot, trigger: Trigger)] = [(.pingTrigger, ping.trigger)]
        func claim(_ slot: KeySlot, _ trigger: Trigger) -> KeyConflict? {
            if let holder = taken.first(where: { $0.trigger == trigger }) { return KeyConflict(first: holder.slot, second: slot) }
            taken.append((slot, trigger))
            return nil
        }
        if emote.isOn, let clash = claim(.emoteTrigger, emote.trigger) { return clash }
        for (action, combo) in hotkeys.assigned {
            if let clash = claim(.hotkey(action), .key(combo)) { return clash }
        }
        return nil
    }

    // MARK: - Repair

    /// The same preferences with every value made valid: numbers in range, wheels complete and without repeats,
    /// unknown items replaced, and key conflicts settled in favour of the ping wheel and the pause shortcut.
    public func repaired() -> Preferences {
        var p = self
        func clamp(_ v: Double, _ r: ClosedRange<Double>, step: Double = 1) -> Double {
            guard v.isFinite else { return r.lowerBound }
            let snapped = (v / step).rounded() * step
            return min(r.upperBound, max(r.lowerBound, (snapped * 10).rounded() / 10))
        }
        p.dragThreshold = clamp(dragThreshold, Limits.dragThreshold)
        p.ping.size = clamp(ping.size, Limits.pingSize)
        p.ping.duration = clamp(ping.duration, Limits.pingDuration, step: 0.1)
        p.emote.size = clamp(emote.size, Limits.emoteSize)
        p.sound.volume = clamp(sound.volume, Limits.volume)
        p.room.incomingLimit = clamp(room.incomingLimit, Limits.incomingLimit)
        if !(0..<Limits.tagColors).contains(room.tagColor) { p.room.tagColor = 0 }

        let name = String(room.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.nameLength))
        p.room.name = name.isEmpty ? Preferences().room.name : name
        if let v = updates.announcedVersion, SemanticVersion(v) == nil { p.updates.announcedVersion = nil }
        if !ping.trigger.isUsable { p.ping.trigger = Preferences().ping.trigger }
        if !emote.trigger.isUsable { p.emote.trigger = Preferences().emote.trigger }
        for (action, combo) in hotkeys.assigned where !combo.isUsable { p.hotkeys[action] = nil }

        // Imported emotes: well-formed ids, no repeats, a usable name, and no more than the limit.
        var seen = Set<String>()
        p.emote.imported = emote.imported.filter { ImportedEmote.isValidId($0.id) && seen.insert($0.id).inserted }
            .prefix(ImportedEmote.limit)
            .map { e in
                let trimmed = String(e.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ImportedEmote.nameLimit))
                return ImportedEmote(id: e.id, name: trimmed.isEmpty ? String(e.id.dropFirst(2).prefix(6)) : trimmed, animated: e.animated)
            }

        p.ping.slices = Self.completeWheel(ping.slices, standard: PingCatalog.standardWheel, pool: PingCatalog.all.map(\.id), isKnown: PingCatalog.contains)
        if !PingCatalog.contains(ping.quick) { p.ping.quick = PingCatalog.standardQuick }
        let importedIds = Set(p.emote.imported.map(\.id))
        let knownEmote: (String) -> Bool = { EmoteCatalog.contains($0) || importedIds.contains($0) }
        p.emote.slices = Self.completeWheel(emote.slices, standard: EmoteCatalog.standardWheel, pool: EmoteCatalog.all.map(\.slug), isKnown: knownEmote)
        if !knownEmote(emote.quick) { p.emote.quick = EmoteCatalog.standardQuick }

        // Whatever comes first keeps a contested key: the ping wheel, then the emote wheel, then the shortcuts in the
        // order they are listed. The loser is switched off (the emote wheel) or loses its shortcut.
        while let clash = p.keyConflict {
            switch clash.second {
            case .hotkey(let action): p.hotkeys[action] = nil
            case .emoteTrigger, .pingTrigger: p.emote.isOn = false
            }
        }
        return p
    }

    /// Eight distinct known items. A slice that is unknown or a repeat gets the standard item for its position when that
    /// is still free, otherwise the first item of the pool that isn't on the wheel yet.
    static func completeWheel(_ slices: [String], standard: [String], pool: [String], isKnown: (String) -> Bool) -> [String] {
        var used = Set<String>()
        var result: [String?] = (0..<WheelMetrics.sliceCount).map { i in
            guard i < slices.count, isKnown(slices[i]), used.insert(slices[i]).inserted else { return nil }
            return slices[i]
        }
        for i in result.indices where result[i] == nil {
            let pick = !used.contains(standard[i]) ? standard[i] : (pool.first { !used.contains($0) } ?? standard[i])
            used.insert(pick)
            result[i] = pick
        }
        return result.compactMap { $0 }
    }

    // MARK: - Reading

    /// Reads a saved file. Anything missing or malformed inside it takes its default; only a file that isn't JSON at
    /// all fails.
    public static func decode(_ data: Data) throws -> Preferences {
        try JSONDecoder().decode(Preferences.self, from: data).repaired()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Forgiving decoding

private extension KeyedDecodingContainer {
    /// The value under `key`, or `fallback` when it is absent, null, or not of the expected type.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

extension Preferences {
    private enum FormerKeys: String, CodingKey { case pauseShortcut }
    private struct FormerCombo: Decodable {
        let keyCode: UInt16
        let modifiers: Int
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        startsEnabled = c.value(.startsEnabled, or: d.startsEnabled)
        dragThreshold = c.value(.dragThreshold, or: d.dragThreshold)
        hotkeys = c.value(.hotkeys, or: d.hotkeys)
        // Before there was a table of shortcuts, the pause shortcut had a field to itself.
        if !c.contains(.hotkeys), let old = try? decoder.container(keyedBy: FormerKeys.self).decode(FormerCombo.self, forKey: .pauseShortcut) {
            hotkeys[.toggleEnabled] = KeyCombo(keyCode: old.keyCode, modifiers: KeyModifiers(rawValue: old.modifiers))
        }
        ping = c.value(.ping, or: d.ping)
        emote = c.value(.emote, or: d.emote)
        sound = c.value(.sound, or: d.sound)
        room = c.value(.room, or: d.room)
        updates = c.value(.updates, or: d.updates)
        opensAtLogin = c.value(.opensAtLogin, or: d.opensAtLogin)
        language = c.value(.language, or: d.language)
    }
}

extension Preferences.PingWheel {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.PingWheel()
        trigger = c.value(.trigger, or: d.trigger)
        clickSends = c.value(.clickSends, or: d.clickSends)
        slices = c.value(.slices, or: d.slices)
        quick = c.value(.quick, or: d.quick)
        size = c.value(.size, or: d.size)
        duration = c.value(.duration, or: d.duration)
    }
}

extension Preferences.EmoteWheel {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.EmoteWheel()
        isOn = c.value(.isOn, or: d.isOn)
        trigger = c.value(.trigger, or: d.trigger)
        clickSends = c.value(.clickSends, or: d.clickSends)
        slices = c.value(.slices, or: d.slices)
        quick = c.value(.quick, or: d.quick)
        size = c.value(.size, or: d.size)
        playsSound = c.value(.playsSound, or: d.playsSound)
        imported = c.value(.imported, or: d.imported)
    }
}

extension Preferences.Sound {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.Sound()
        volume = c.value(.volume, or: d.volume)
        muted = c.value(.muted, or: d.muted)
        wheelTick = c.value(.wheelTick, or: d.wheelTick)
    }
}

extension Preferences.Room {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.Room()
        name = c.value(.name, or: d.name)
        tagColor = c.value(.tagColor, or: d.tagColor)
        incomingLimit = c.value(.incomingLimit, or: d.incomingLimit)
        allowsInternet = c.value(.allowsInternet, or: d.allowsInternet)
        rejoinsOnLaunch = c.value(.rejoinsOnLaunch, or: d.rejoinsOnLaunch)
        lastCode = c.value(.lastCode, or: d.lastCode)
        muted = c.value(.muted, or: d.muted)
    }
}

extension Preferences.Updates {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences.Updates()
        checksAutomatically = c.value(.checksAutomatically, or: d.checksAutomatically)
        installsAutomatically = c.value(.installsAutomatically, or: d.installsAutomatically)
        announcedVersion = c.value(.announcedVersion, or: d.announcedVersion)
    }
}

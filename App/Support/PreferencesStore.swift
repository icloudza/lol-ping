import Foundation
import LPCore

/// Keeps the preferences in memory and in `preferences.json` inside the app's data folder.
/// A change is live immediately; the file is written a moment later, in one piece.
final class PreferencesStore {
    enum Problem: Equatable {
        /// The file wasn't JSON. It was set aside as preferences.bak.json.
        case unreadable
        case notSaved(String)
    }

    static let folder: URL = {
        #if DEBUG
        // Development only: keeps a test run away from the real preferences.
        if let dir = ProcessInfo.processInfo.environment["LOLPING_SETTINGS_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "LolPing", isDirectory: true)
    }()

    private(set) var preferences: Preferences
    /// No preferences existed before this launch.
    let isFirstRun: Bool
    /// The saved emote key clashed with another key, and repairing the file turned the emote wheel off.
    let emoteWheelWasTurnedOff: Bool
    private(set) var problems: [Problem] = []
    /// Called with the new and the previous preferences after every change.
    var onChange: ((Preferences, Preferences) -> Void)?

    private let file: URL
    private let tidy: (inout Preferences) -> Void
    private var pendingSave: DispatchWorkItem?

    /// `tidy` runs on every new value before it is repaired: the place for rules this layer knows nothing about
    /// (what a room allows in a nickname, what counts as a room code).
    init(folder: URL = PreferencesStore.folder, firstRunDefaults: (inout Preferences) -> Void, tidy: @escaping (inout Preferences) -> Void) {
        file = folder.appendingPathComponent("preferences.json")
        self.tidy = tidy
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var loaded = Preferences()
        var firstRun = false, turnedOff = false
        if let data = try? Data(contentsOf: file) {
            if let raw = try? JSONDecoder().decode(Preferences.self, from: data) {
                loaded = raw
                turnedOff = raw.emote.isOn && !raw.repaired().emote.isOn
            } else {
                let backup = folder.appendingPathComponent("preferences.bak.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: file, to: backup)
                problems.append(.unreadable)
            }
        } else {
            firstRun = true
            firstRunDefaults(&loaded)
        }
        tidy(&loaded)
        preferences = loaded.repaired()
        isFirstRun = firstRun
        emoteWheelWasTurnedOff = turnedOff
        if firstRun { write() }
    }

    /// Changes the preferences. The result is tidied and repaired before it takes effect, so it may differ from what
    /// was asked for; the value now in force is returned.
    @discardableResult
    func update(_ change: (inout Preferences) -> Void) -> Preferences {
        var next = preferences
        change(&next)
        tidy(&next)
        next = next.repaired()
        guard next != preferences else { return preferences }
        let previous = preferences
        preferences = next
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: save)
        onChange?(next, previous)
        return next
    }

    /// Writes a pending change right away (on quit).
    func saveNow() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        write()
    }

    private func write() {
        do {
            try preferences.encoded().write(to: file, options: .atomic)
            problems.removeAll { if case .notSaved = $0 { return true } else { return false } }
        } catch {
            let problem = Problem.notSaved(error.localizedDescription)
            if !problems.contains(problem) { problems.append(problem) }
        }
    }
}

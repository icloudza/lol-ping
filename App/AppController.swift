import AppKit
import LPCore
import LPRooms
import ServiceManagement

/// The hub of the app: it owns the preferences, the event tap, the overlays, the menu bar icon, the room and the
/// update checker, and carries news between them. SwiftUI reads its published state. Main thread only.
final class AppController: ObservableObject {
    static let shared = AppController()

    enum Access {
        case granted
        /// Not allowed under Accessibility yet.
        case missing
        /// Listed as allowed, yet the tap is refused: a leftover entry from a differently signed copy.
        case stale
    }

    @Published private(set) var preferences: Preferences
    @Published private(set) var isEnabled: Bool
    @Published private(set) var access = Access.granted
    @Published private(set) var text: L10n
    @Published private(set) var room = RoomView()
    /// Nil when this build has no update checker.
    @Published private(set) var updates: AppUpdater.Status?
    @Published private(set) var problems: [String] = []
    /// The settings pane to show; `serial` makes asking for the same pane twice a new request.
    @Published private(set) var paneRequest: (pane: String, serial: Int)?

    let store: PreferencesStore
    let library: EmoteLibrary
    let overlays: OverlayManager
    private let tap = EventTap()
    private var statusItem: StatusItemController?
    private var rooms: RoomGlue?
    /// Nil in a build that carries no update address: every build but a released one.
    private let updater: AppUpdater?
    private var accessPoll: Timer?
    private var isRecordingKey = false
    private var hasStarted = false
    private var isQuitting = false

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    private init() {
        store = PreferencesStore(
            firstRunDefaults: { p in
                // A recognisable name and a colour of one's own, rather than everyone being a sky-blue "Player".
                p.room.name = NSUserName()
                p.room.tagColor = Int.random(in: 0..<TagColors.all.count)
            },
            tidy: { p in
                p.room.name = Names.sanitize(p.room.name)
                p.room.lastCode = p.room.lastCode.flatMap { try? RoomCode.parse($0).get() }
            }
        )
        library = EmoteLibrary(folder: PreferencesStore.folder.appendingPathComponent("emotes", isDirectory: true))
        // A picture whose file has gone is dropped; repairing then refills any wheel slice that showed it.
        let present = library.existing(store.preferences.emote.imported)
        if present.count != store.preferences.emote.imported.count { store.update { $0.emote.imported = present } }

        preferences = store.preferences
        isEnabled = store.preferences.startsEnabled
        let language = L10n(language: AppLanguage.resolve(store.preferences.language))
        text = language
        overlays = OverlayManager(preferences: store.preferences, text: language)
        updater = AppUpdater.isConfigured ? AppUpdater() : nil
        updates = updater?.status
        store.onChange = { [unowned self] new, old in preferencesChanged(new, old) }
        Self.tellSystem(language: store.preferences.language)
    }

    /// The windows macOS and Sparkle draw (update windows, open panels) take their language from the system, not
    /// from L10n. Recording the app's own choice as this app's language preference makes them agree with it; macOS
    /// reads it when the app starts, so a change shows there from the next launch on.
    private static func tellSystem(language: LanguageChoice) {
        switch language {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .chinese: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    // MARK: - Starting and stopping

    func start() {
        hasStarted = true
        ImageStore.shared.auditBundle()

        overlays.artFor = { [unowned self] ref, fromRoom in library.art(for: ref, among: preferences.emote.imported, fromRoom: fromRoom) }
        overlays.importedBadge = { [unowned self] id in library.still(id) }
        overlays.onPlaced = { [unowned self] placement in share(placement) }
        overlays.onDisplaysChanged = { [unowned self] in refreshRoom() }
        overlays.start()

        let item = StatusItemController(text: text)
        item.commands = StatusItemController.Commands(
            openSettings: { [unowned self] pane in showSettings(pane: pane) },
            setEnabled: { [unowned self] on in setEnabled(on) },
            quit: { NSApp.terminate(nil) },
            update: { [unowned self] in checkForUpdates() },
            joinFromClipboard: { [unowned self] in
                if let code = roomCodeOnClipboard() {
                    joinRoom(code) { _ in }
                } else {
                    overlays.notice(text.noCodeOnClipboard, text.noCodeOnClipboardHint)
                }
            },
            newRoom: { [unowned self] in rooms?.create() },
            copyRoomCode: { [unowned self] in copyRoomCode() },
            setRoomMuted: { [unowned self] on in store.update { $0.room.muted = on } },
            leaveRoom: { [unowned self] in rooms?.leave() }
        )
        statusItem = item

        startRoom()
        startUpdater()

        tap.onAction = { [unowned self] action in
            switch action {
            case .enabledChanged(let on): setEnabled(on)
            case .hotkey(let wanted): run(wanted)
            default: overlays.perform(action)
            }
        }
        tap.onStatus = { [unowned self] status in tapChanged(status) }
        tap.apply(GestureConfig(preferences, enabled: isEnabled))
        beginWatchingInput()
        refreshStatusItem()
        refreshProblems()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rooms?.systemDidWake()
        }

        #if DEBUG
        if let demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"] {
            Demo.run(demo, overlays: overlays)
            return
        }
        #endif
        // The app lives in the menu bar. The window opens by itself only when there is something to do in it.
        if !Self.hasFinishedOnboarding || !EventTap.isTrusted {
            showPermissions(atLaunch: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in overlays.notice(text.runningInMenuBar, text.runningInMenuBarHint) }
        }
    }

    /// Winds everything down, then calls back so the app can exit.
    func prepareToQuit(_ done: @escaping () -> Void) {
        guard hasStarted, !isQuitting else { return done() }
        isQuitting = true
        accessPoll?.invalidate()
        tap.stop()
        store.saveNow()
        statusItem?.remove()
        overlays.shutDown()
        // Leaving the room properly lets the others see "left" at once instead of a timeout later.
        if let rooms { rooms.quit(completion: done) } else { done() }
    }

    // MARK: - On and off

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        tap.apply(GestureConfig(preferences, enabled: on))
        overlays.notice(on ? text.statusOn : text.statusPaused, text.switchHint(preferences.hotkeys[.toggleEnabled]?.title))
        syncRoomFlags()
        refreshStatusItem()
    }

    /// What a global shortcut does. Pausing is not among them: the event tap has already switched itself by the time
    /// it reports that one.
    private func run(_ action: HotkeyAction) {
        switch action {
        case .toggleEnabled:
            setEnabled(!isEnabled)
        case .openSettings:
            showSettings()
        case .toggleMute:
            let muted = store.update { $0.sound.muted.toggle() }.sound.muted
            overlays.notice(text.soundNotice(muted: muted))
        case .toggleRoomMute:
            let muted = store.update { $0.room.muted.toggle() }.room.muted
            overlays.notice(text.roomNotice(muted: muted), muted ? text.roomNoticeHint : "")
        case .quick(let kind):
            overlays.send(kind == .ping ? .ping(preferences.ping.quick) : .emote(preferences.emote.quick), at: pointerLocation)
        case .slice(let kind, let index):
            let slices = kind == .ping ? preferences.ping.slices : preferences.emote.slices
            guard slices.indices.contains(index) else { return }
            overlays.send(kind == .ping ? .ping(slices[index]) : .emote(slices[index]), at: pointerLocation)
        }
    }

    /// Where the pointer is, in the event tap's coordinates (origin at the main display's top-left corner).
    private var pointerLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func refreshStatusItem() {
        guard !isQuitting else { return }
        statusItem?.show(access != .granted ? .needsAccess : isEnabled ? .on : .paused, enabled: isEnabled)
    }

    // MARK: - Accessibility

    private func beginWatchingInput() {
        if EventTap.isTrusted {
            accessPoll?.invalidate()
            accessPoll = nil
            access = .granted
            tap.start()
        } else {
            waitForAccess()
        }
    }

    /// The tap can't exist without permission, so look again every so often until the user has granted it.
    private func waitForAccess() {
        access = .missing
        overlays.dismissWheel()
        refreshStatusItem()
        guard accessPoll == nil else { return }
        accessPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, EventTap.isTrusted else { return }
            self.beginWatchingInput()
            self.refreshStatusItem()
        }
    }

    private func tapChanged(_ status: EventTap.Status) {
        switch status {
        case .running:
            access = .granted
        case .stopped:
            overlays.dismissWheel()
        case .refused:
            overlays.dismissWheel()
            if EventTap.isTrusted { access = .stale } else { waitForAccess() }
            // Unless it is up already: showing it again would replace the launch window and what follows it.
            if !PermissionsWindowController.shared.isVisible { showPermissions() }
        }
        refreshStatusItem()
    }

    /// What is left to do about Accessibility.
    enum AccessStep {
        case granted
        /// Never asked: macOS can still show its own prompt.
        case ask
        /// Asked before: the switch in System Settings is what is missing.
        case switchOn
        /// Listed as allowed and still refused.
        case stale
    }

    private static let askedForAccessKey = "permissions.askedForAccessibility"
    private static let onboardingKey = "permissions.onboardingDone"

    var accessStep: AccessStep {
        switch access {
        case .granted: return .granted
        case .stale: return .stale
        case .missing: return UserDefaults.standard.bool(forKey: Self.askedForAccessKey) ? .switchOn : .ask
        }
    }

    /// Whether the user has been through the permissions window once.
    static var hasFinishedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingKey) }
    }

    /// The app's name as System Settings lists it ("LolPing-Dev" for a development build).
    static let systemName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? L10n.appName

    /// The Accessibility row's button. The first time, macOS shows its own prompt, which also puts the app in the
    /// list; after that only the switch in System Settings is missing, so the list is opened directly.
    func requestAccess() {
        if accessStep == .ask {
            UserDefaults.standard.set(true, forKey: Self.askedForAccessKey)
            NSApp.activate(ignoringOtherApps: true) // or the prompt may come up behind another app
            EventTap.requestTrust()
        } else {
            openPrivacySettings("Privacy_Accessibility")
        }
        if EventTap.isTrusted { beginWatchingInput() } else { waitForAccess() }
        objectWillChange.send()
    }

    /// Opens a pane of Privacy & Security in System Settings.
    func openPrivacySettings(_ anchor: String) {
        // The address used since macOS 13 first, then the older one; the anchors are the same.
        for address in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
                        "x-apple.systempreferences:com.apple.preference.security?\(anchor)"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { break }
        }
    }

    func retryAccess() {
        beginWatchingInput()
        refreshStatusItem()
    }

    /// For an entry that is switched on and still doesn't work: removes this app's entry from the Accessibility
    /// list, so that allowing it again makes a fresh one.
    func resetAccess() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? ""]
        reset.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                UserDefaults.standard.set(false, forKey: Self.askedForAccessKey)
                self.waitForAccess()
                self.requestAccess()
            }
        }
        do { try reset.run() } catch { NSLog("LolPing: tccutil: %@", error.localizedDescription) }
    }

    func showPermissions(atLaunch: Bool = false) {
        PermissionsWindowController.shared.show(atLaunch: atLaunch) { [weak self] in
            guard let self, atLaunch, !self.isQuitting else { return }
            // The first time round, the settings are where to go next; later launches just say where the app lives.
            let firstTime = !Self.hasFinishedOnboarding
            Self.hasFinishedOnboarding = true
            if firstTime, self.access == .granted {
                self.showSettings()
            } else {
                self.overlays.notice(self.text.runningInMenuBar, self.text.runningInMenuBarHint)
            }
        }
    }

    /// While the settings window records a key, the tap must not react to it.
    func setRecordingKey(_ on: Bool) {
        guard on != isRecordingKey else { return }
        isRecordingKey = on
        tap.setSuspended(on)
    }

    // MARK: - Preferences

    /// Applies a change from the settings window, unless it would leave the keys in conflict; then nothing changes
    /// and the reason comes back.
    @discardableResult
    func change(_ edit: (inout Preferences) -> Void) -> String? {
        var candidate = preferences
        edit(&candidate)
        let keysTouched = candidate.ping.trigger != preferences.ping.trigger || candidate.hotkeys != preferences.hotkeys
            || candidate.emote.trigger != preferences.emote.trigger || candidate.emote.isOn != preferences.emote.isOn
        if keysTouched, let conflict = candidate.keyConflict { return text.conflict(conflict) }
        store.update(edit)
        return nil
    }

    private func preferencesChanged(_ new: Preferences, _ old: Preferences) {
        preferences = new
        guard hasStarted else { return }
        if new.language != old.language {
            text = L10n(language: AppLanguage.resolve(new.language))
            statusItem?.setText(text)
            NSApp.mainMenu = MainMenu.build(text)
            Self.tellSystem(language: new.language)
            refreshProblems()
        }
        tap.apply(GestureConfig(new, enabled: isEnabled))
        overlays.update(preferences: new, text: text)
        if new.room.name != old.room.name || new.room.tagColor != old.room.tagColor { rooms?.profileChanged() }
        if new.room.muted != old.room.muted {
            syncRoomFlags()
            refreshRoom()
        }
        if new.room.allowsInternet != old.room.allowsInternet {
            rooms?.setInternetAllowed(new.room.allowsInternet)
            refreshRoom()
        }
        if new.updates.checksAutomatically != old.updates.checksAutomatically { updater?.setChecksAutomatically(new.updates.checksAutomatically) }
        if new.updates.installsAutomatically != old.updates.installsAutomatically { updater?.setInstallsAutomatically(new.updates.installsAutomatically) }
        if new.opensAtLogin != old.opensAtLogin { applyLoginItem(new.opensAtLogin) }
    }

    private func applyLoginItem(_ on: Bool) {
        do {
            let service = SMAppService.mainApp
            if on, service.status != .enabled { try service.register() }
            if !on, service.status == .enabled { try service.unregister() }
        } catch {
            NSLog("LolPing: login item: %@", error.localizedDescription)
        }
    }

    /// A copy signed by a development team keeps its Accessibility grant from one build to the next.
    static let hasStableSignature: Bool = {
        var me: SecCode?
        var onDisk: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk,
              SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else { return false }
        return details[kSecCodeInfoTeamIdentifier as String] is String
    }()

    func refreshProblems() {
        var list: [String] = store.problems.map {
            switch $0 {
            case .unreadable: return text.prefsUnreadable
            case .notSaved(let reason): return text.prefsNotSaved(reason)
            }
        }
        if store.emoteWheelWasTurnedOff { list.append(text.emoteKeyTurnedOff) }
        list += ImageStore.shared.missingFiles.sorted().map(text.missingFile)
        problems = list
    }

    func previewPing(_ id: String) { overlays.previewPing(id) }
    func previewEmote(_ ref: String) { overlays.previewEmote(ref) }
    func openDataFolder() { NSWorkspace.shared.open(PreferencesStore.folder) }

    func showSettings(pane: String? = nil) {
        if let pane { paneRequest = (pane, (paneRequest?.serial ?? 0) + 1) }
        SettingsWindowController.shared.show()
    }

    // MARK: - The user's own emote pictures

    /// Adds pictures one after another. Returns a sentence for each one that couldn't be added.
    func addEmotes(from files: [URL]) -> [String] {
        var failures: [String] = []
        for file in files {
            switch library.add(file, to: preferences.emote.imported) {
            case .success(let emote): store.update { $0.emote.imported.append(emote) }
            case .failure(let error): failures.append(text.importFailure(error, file: file.lastPathComponent))
            }
        }
        return failures
    }

    func removeEmote(_ id: String) {
        store.update { $0.emote.imported.removeAll { $0.id == id } }
        library.discard(id)
    }

    // MARK: - Room

    private func startRoom() {
        let glue = RoomGlue(
            appVersion: Self.version,
            profile: { [unowned self] in
                RoomGlue.Profile(name: preferences.room.name, color: preferences.room.tagColor, limit: Int(preferences.room.incomingLimit))
            },
            displays: { [unowned self] in overlays.numbered }
        )
        rooms = glue
        glue.onState = { [unowned self] in refreshRoom() }
        glue.onRemotePing = { [unowned self] id, display, x, y, tag in
            overlays.showRemotePing(id, on: display, at: CGPoint(x: x, y: y), tag: tag)
        }
        glue.onRemoteEmote = { [unowned self] ref, peer, display, x, y, tag in
            overlays.showRemoteEmote(ref, from: peer, on: display, at: CGPoint(x: x, y: y), tag: tag)
        }
        glue.onSaveCode = { [unowned self] code in store.update { $0.room.lastCode = code } }
        glue.onToast = { [unowned self] event in
            let code = glue.state.code ?? ""
            switch event {
            case .joinedRoom(let c): overlays.notice(text.joinedRoom(c), text.joinedRoomHint)
            case .full: overlays.notice(text.roomFull, text.roomFullHint)
            case .joined(let name): overlays.notice(text.memberJoined(name), code)
            case .left(let name): overlays.notice(text.memberLeft(name), code)
            case .disconnected(let name): overlays.notice(text.memberLost(name), code)
            }
        }
        syncRoomFlags()
        glue.setInternetAllowed(preferences.room.allowsInternet)
        refreshRoom()
        if preferences.room.rejoinsOnLaunch, let code = preferences.room.lastCode { glue.join(code) { _ in } }
    }

    /// Passes on what the user placed: a position travels as a display number and a fraction of that display.
    private func share(_ placement: Placement) {
        guard let rooms, let spot = DisplayNumbers.toShared(overlays.numbered, displayId: placement.displayId, x: placement.point.x, y: placement.point.y) else { return }
        switch placement.item {
        case .ping(let id): rooms.sendPing(id, d: spot.d, x: spot.x, y: spot.y)
        case .emote(let ref): rooms.sendEmote(ref, d: spot.d, x: spot.x, y: spot.y)
        }
    }

    private func syncRoomFlags() {
        rooms?.setStatusFlags(paused: !isEnabled, roomMuted: preferences.room.muted)
    }

    private func refreshRoom() {
        guard !isQuitting, let rooms else { return }
        room = rooms.state
        statusItem?.room = .init(code: room.code, people: room.members.count, muted: preferences.room.muted)
    }

    /// This Mac's displays with the numbers a room uses, sized in pixels like System Settings shows them.
    var displayList: [(number: Int, width: Int, height: Int, isMain: Bool)] {
        overlays.numbered.map { display in
            let scale = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
            }?.backingScaleFactor ?? 1
            return (display.number, Int((display.bounds.width * scale).rounded()), Int((display.bounds.height * scale).rounded()), display.primary)
        }
    }

    /// A room code sitting on the clipboard. Nobody typed it, so only something that is unmistakably a code counts.
    func roomCodeOnClipboard() -> String? {
        guard let copied = NSPasteboard.general.string(forType: .string), let code = try? RoomCode.parse(copied, strict: true).get() else { return nil }
        return RoomCode.format(code)
    }

    func copyRoomCode() {
        guard let code = rooms?.state.code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func createRoom() { rooms?.create() }
    func joinRoom(_ entered: String, completion: @escaping (JoinError?) -> Void) {
        guard let rooms else { return completion(.failed) }
        rooms.join(entered, completion: completion)
    }
    func leaveRoom() { rooms?.leave() }
    func setMemberHidden(_ peer: String, _ hidden: Bool) { rooms?.muteMember(peer, hidden) }
    func retryInternet() { rooms?.retryInternet() }

    // MARK: - Updates

    private func startUpdater() {
        guard let updater else { return }
        updater.onChange = { [unowned self] in updaterChanged() }
        updater.onFoundInBackground = { [unowned self] version in
            // Each release is pointed out once; after that the menu and the settings keep saying it quietly.
            guard !isQuitting, preferences.updates.announcedVersion != version else { return }
            store.update { $0.updates.announcedVersion = version }
            overlays.notice(text.updateOut(version), text.updateOutHint)
        }
        updater.start(checksAutomatically: preferences.updates.checksAutomatically, installsAutomatically: preferences.updates.installsAutomatically)
        updaterChanged()
    }

    private func updaterChanged() {
        guard !isQuitting, let updater else { return }
        updates = updater.status
        statusItem?.updateItem = updater.status.pendingVersion.map { .get(version: $0) } ?? .check
    }

    /// Shows the new version with its notes and an Install button, or says the app is up to date.
    func checkForUpdates() { updater?.check() }

    /// The project's page on GitHub; nil when this build names no repository.
    static let projectPage: URL? = {
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "LPUpdateRepo") as? String,
              repository.split(separator: "/").count == 2, !repository.contains(" ") else { return nil }
        return URL(string: "https://github.com/\(repository)")
    }()
}

import AppKit
import LPCore
import LPRooms
import SwiftUI
import UniformTypeIdentifiers

private func points(_ value: Double) -> String { "\(Int(value)) pt" }

// MARK: - Keys

/// Tries a change to one of the key slots and remembers the refusal, if there is one, for the row it belongs to.
private struct KeyRefusal {
    var slot: Preferences.KeySlot?
    var reason: String?

    func note(for slot: Preferences.KeySlot) -> String? { self.slot == slot ? reason : nil }
}

private extension AppController {
    func assign(_ slot: Preferences.KeySlot, _ refusal: Binding<KeyRefusal>, _ edit: (inout Preferences) -> Void) {
        let reason = change(edit)
        refusal.wrappedValue = KeyRefusal(slot: reason == nil ? nil : slot, reason: reason)
    }
}

/// The row that sets a wheel's key. It appears on the wheel's own pane and again among the shortcuts.
private struct TriggerRow: View {
    @EnvironmentObject var app: AppController
    let kind: WheelKind
    @Binding var refusal: KeyRefusal

    var body: some View {
        let t = app.text, p = app.preferences
        let slot: Preferences.KeySlot = kind == .ping ? .pingTrigger : .emoteTrigger
        let trigger = kind == .ping ? p.ping.trigger : p.emote.trigger
        let isOff = kind == .emote && !p.emote.isOn
        let hint = kind == .ping ? (trigger.isSideButton ? t.pingButtonHint : t.pingKeyHint) : (isOff ? t.emoteOffHint : t.emoteKeyHint)
        let refused = refusal.note(for: slot)
        Row(title: kind == .ping ? t.pingKey : t.emoteKey, hint: hint,
            note: refused ?? (!isOff && trigger.combo != nil ? (trigger.combo?.takesATypingKey == true ? t.bareKeyNote : t.keyTriggerNote) : nil),
            isWarning: refused != nil, dimmed: kind == .ping && !app.isEnabled) {
            TriggerField(selection: isOff ? nil : trigger, standard: kind == .ping ? Preferences().ping.trigger : Preferences().emote.trigger,
                         allowsOff: kind == .emote) { picked in
                app.assign(slot, $refusal) {
                    switch (kind, picked) {
                    case (.ping, let picked?): $0.ping.trigger = picked
                    case (.ping, nil): break
                    case (.emote, let picked?):
                        $0.emote.trigger = picked
                        $0.emote.isOn = true
                    case (.emote, nil): $0.emote.isOn = false
                    }
                }
            }
        }
    }
}

// MARK: - Gesture

struct GesturePane: View {
    @EnvironmentObject var app: AppController
    @State private var refusal = KeyRefusal()

    var body: some View {
        let t = app.text, p = app.preferences
        let paused = !app.isEnabled
        Card {
            TriggerRow(kind: .ping, refusal: $refusal)
            RowDivider()
            SliderRow(title: t.dragDistance, hint: t.dragDistanceHint, range: Preferences.Limits.dragThreshold, dimmed: paused,
                      value: app.binding(\.dragThreshold), label: points)
            RowDivider()
            SwitchRow(title: t.clickSendsPing(t.triggerName(p.ping.trigger)), hint: t.clickSendsPingHint, dimmed: paused, isOn: app.binding(\.ping.clickSends))
        }
    }
}

// MARK: - Shortcut

struct ShortcutPane: View {
    @EnvironmentObject var app: AppController
    @State private var refusal = KeyRefusal()

    var body: some View {
        let t = app.text, p = app.preferences
        SectionLabel(title: t.wheelKeys, hint: t.wheelKeysHint)
        Card {
            TriggerRow(kind: .ping, refusal: $refusal)
            RowDivider()
            TriggerRow(kind: .emote, refusal: $refusal)
        }

        SectionLabel(title: t.actions)
        Card {
            ForEach(Array(HotkeyAction.general.enumerated()), id: \.offset) { index, action in
                if index > 0 { RowDivider() }
                hotkeyRow(action, title: t.hotkeyName(action), hint: t.hotkeyHint(action))
            }
        }

        SectionLabel(title: t.sendPings, hint: t.sendPingsHint)
        Card {
            ForEach(0..<WheelMetrics.sliceCount, id: \.self) { index in
                if index > 0 { RowDivider() }
                let id = p.ping.slices[index]
                hotkeyRow(.slice(.ping, index), title: t.pingName(id), badge: t.sliceNames[index],
                          image: ImageStore.shared.texture(PingCatalog.resolve(id).badge))
            }
        }

        SectionLabel(title: t.sendEmotes, hint: t.sendEmotesHint)
        Card {
            ForEach(0..<WheelMetrics.sliceCount, id: \.self) { index in
                if index > 0 { RowDivider() }
                let ref = p.emote.slices[index]
                let mine = p.emote.imported.first { $0.id == ref }
                hotkeyRow(.slice(.emote, index), title: mine?.name ?? EmoteCatalog[ref]?.displayName(chinese: t.isChinese) ?? ref, badge: t.sliceNames[index],
                          image: mine != nil ? app.library.still(ref) : ImageStore.shared.emoteBadge(ref))
            }
        }

        Card {
            SwitchRow(title: t.startsOn, hint: t.startsOnHint, isOn: app.binding(\.startsEnabled))
            RowDivider()
            Row(title: t.restoreAllKeysTitle, hint: t.restoreAllKeysHint) {
                Button(t.restoreAllKeys) {
                    refusal = KeyRefusal()
                    app.change {
                        let fresh = Preferences()
                        $0.ping.trigger = fresh.ping.trigger
                        $0.emote.trigger = fresh.emote.trigger
                        $0.emote.isOn = true
                        $0.hotkeys = fresh.hotkeys
                    }
                }
                .disabled(isStandard(p))
            }
        }
    }

    private func isStandard(_ p: Preferences) -> Bool {
        let fresh = Preferences()
        return p.ping.trigger == fresh.ping.trigger && p.emote.trigger == fresh.emote.trigger && p.emote.isOn && p.hotkeys == fresh.hotkeys
    }

    private func hotkeyRow(_ action: HotkeyAction, title: String, hint: String? = nil, badge: String? = nil, image: CGImage? = nil) -> some View {
        let t = app.text, combo = app.preferences.hotkeys[action]
        let refused = refusal.note(for: .hotkey(action))
        return Row(title: title, hint: hint, note: refused ?? (combo?.takesATypingKey == true ? t.bareKeyNote : nil), isWarning: refused != nil,
                   image: image, badge: badge) {
            HotkeyField(combo: combo, standard: Hotkeys.standard[action]) { picked in
                app.assign(.hotkey(action), $refusal) { $0.hotkeys[action] = picked }
            }
        }
    }
}

// MARK: - Look & sound

struct LookPane: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        let t = app.text, p = app.preferences
        Card {
            SliderRow(title: t.pingSize, range: Preferences.Limits.pingSize, value: app.binding(\.ping.size), label: points)
            RowDivider()
            SliderRow(title: t.pingDuration, hint: t.pingDurationHint, range: Preferences.Limits.pingDuration, step: 0.1,
                      value: app.binding(\.ping.duration)) { String(format: "%.1f s", $0) }
        }
        Card {
            SliderRow(title: t.volume, range: Preferences.Limits.volume, dimmed: p.sound.muted, value: app.binding(\.sound.volume)) { "\(Int($0))" }
            RowDivider()
            SwitchRow(title: t.muted, isOn: app.binding(\.sound.muted))
            RowDivider()
            SwitchRow(title: t.wheelTick, hint: t.wheelTickHint, isOn: app.binding(\.sound.wheelTick))
        }
    }
}

// MARK: - Ping wheel

struct PingWheelPane: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        let t = app.text, p = app.preferences
        let key = t.triggerName(p.ping.trigger)
        WheelEditor(
            arrangement: WheelArrangement(slices: p.ping.slices, quick: p.ping.quick),
            quickIsActive: p.ping.clickSends,
            triggerName: key,
            library: PingCatalog.all.map {
                LibraryItem(id: $0.id, image: ImageStore.shared.texture($0.badge), name: t.pingName($0.id),
                            badge: PingCatalog.extras.contains($0.id) ? t.extraBadge : nil)
            },
            standard: WheelArrangement(slices: PingCatalog.standardWheel, quick: PingCatalog.standardQuick),
            title: t.pingWheelTitle, hint: t.pingWheelHint(key), libraryTitle: t.allPings,
            onChange: { next in
                app.change {
                    $0.ping.slices = next.slices
                    $0.ping.quick = next.quick
                }
            },
            onTry: { app.previewPing($0) }
        ) { EmptyView() }
    }
}

// MARK: - Emotes

struct EmotesPane: View {
    @EnvironmentObject var app: AppController
    @State private var refusal = KeyRefusal()
    @State private var importFailures: [String] = []

    var body: some View {
        let t = app.text, p = app.preferences
        let off = !p.emote.isOn
        let key = t.triggerName(p.emote.trigger)
        Card {
            TriggerRow(kind: .emote, refusal: $refusal)
            RowDivider()
            SwitchRow(title: t.clickSendsEmote(key), hint: t.clickSendsEmoteHint, dimmed: off, isOn: app.binding(\.emote.clickSends))
            RowDivider()
            // Size and sound apply to emotes sent with a shortcut and to those from a room too, wheel or no wheel.
            SliderRow(title: t.emoteSize, range: Preferences.Limits.emoteSize, value: app.binding(\.emote.size), label: points)
            RowDivider()
            SwitchRow(title: t.emoteSound, hint: t.emoteSoundHint, isOn: app.binding(\.emote.playsSound))
        }

        WheelEditor(
            arrangement: WheelArrangement(slices: p.emote.slices, quick: p.emote.quick),
            quickIsActive: p.emote.clickSends && !off,
            triggerName: key,
            library: EmoteCatalog.all.map {
                LibraryItem(id: $0.slug, image: ImageStore.shared.emoteBadge($0.slug), name: $0.displayName(chinese: t.isChinese))
            } + p.emote.imported.map { mine in
                LibraryItem(id: mine.id, image: app.library.still(mine.id), name: mine.name, remove: {
                    importFailures = []
                    app.removeEmote(mine.id)
                })
            },
            standard: WheelArrangement(slices: EmoteCatalog.standardWheel, quick: EmoteCatalog.standardQuick),
            title: t.emoteWheelTitle, hint: t.emoteWheelHint(key), libraryTitle: t.allEmotes,
            roundImages: true, libraryHeight: 300,
            onFilesDropped: { importFailures = app.addEmotes(from: $0) },
            onChange: { next in
                app.change {
                    $0.emote.slices = next.slices
                    $0.emote.quick = next.quick
                }
            },
            onTry: { app.previewEmote($0) }
        ) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
                        if panel.runModal() == .OK { importFailures = app.addEmotes(from: panel.urls) }
                    } label: {
                        Label(t.addImage, systemImage: "photo.badge.plus")
                    }
                    Text(t.yourImages(p.emote.imported.count, of: ImportedEmote.limit)).font(.callout).foregroundStyle(.secondary)
                }
                Text(t.addImageHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(importFailures.enumerated()), id: \.offset) { _, failure in
                    Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Room

struct RoomPane: View {
    @EnvironmentObject var app: AppController
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private var topLimit: Double { Preferences.Limits.incomingLimit.upperBound }

    var body: some View {
        let t = app.text, p = app.preferences, room = app.room
        Card {
            Row(title: t.nickname, hint: t.nicknameHint) {
                TextField("", text: $nameDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 190).focused($nameFocused)
                    .onChange(of: nameDraft) { nameDraft = Names.clampInput(nameDraft) }
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { if !nameFocused { commitName() } }
            }
            RowDivider()
            Row(title: t.tagColor) {
                HStack(spacing: 8) {
                    ForEach(TagColors.all.indices, id: \.self) { i in
                        Circle().fill(Color(nsColor: .hex(TagColors.all[i]))).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: p.room.tagColor == i ? 2 : 0).padding(-3))
                            .contentShape(Circle())
                            .onTapGesture { app.change { $0.room.tagColor = i } }
                            .help(t.tagColorName(i + 1))
                    }
                }
            }
        }
        .onAppear { nameDraft = p.room.name }
        .onChange(of: p.room.name) { nameDraft = p.room.name }

        if room.phase == .idle { JoinCard() } else { CurrentRoom(room: room) }

        Card {
            SwitchRow(title: t.muteRoom, hint: t.muteRoomHint, isOn: app.binding(\.room.muted))
            RowDivider()
            Row(title: t.incomingLimit, hint: t.incomingLimitHint, dimmed: p.room.muted) {
                // The slider's last stop, one past the highest number, means "no limit" (saved as 0).
                SteppedSlider(value: Binding(get: { p.room.incomingLimit == 0 ? topLimit + 1 : p.room.incomingLimit },
                                             set: { v in app.change { $0.room.incomingLimit = v > topLimit ? 0 : v } }),
                              range: 1...(topLimit + 1)).frame(width: 200)
                Text(t.perSecond(Int(p.room.incomingLimit))).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
            RowDivider()
            SwitchRow(title: t.allowInternet, hint: t.allowInternetHint, isOn: app.binding(\.room.allowsInternet))
            RowDivider()
            SwitchRow(title: t.rejoin, isOn: app.binding(\.room.rejoinsOnLaunch))
            RowDivider()
            Row(title: t.displays, hint: t.displaysHint) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(app.displayList, id: \.number) { d in
                        Text("#\(d.number)\(d.isMain ? " \(t.mainDisplay)" : "") · \(d.width)×\(d.height)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        Text(t.privacyNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func commitName() {
        if nameDraft != app.preferences.room.name { app.change { $0.room.name = nameDraft } }
    }
}

private struct JoinCard: View {
    @EnvironmentObject var app: AppController
    @State private var code = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var edited = false

    var body: some View {
        let t = app.text
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.2.fill").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.joinTitle)
                        Text(t.joinHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(t.localNetworkHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    TextField("PING-XXXXX-XXXXX", text: $code)
                        .textFieldStyle(.roundedBorder).frame(width: 190)
                        .onChange(of: code) {
                            edited = true
                            failure = nil
                        }
                        .onSubmit(join)
                    Button(t.join, action: join).buttonStyle(.borderedProminent)
                        .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(t.newRoom) { app.createRoom() }.disabled(busy)
                    Spacer()
                }
                .padding(.leading, 42)
                if let failure { Text(failure).font(.callout).foregroundStyle(.red).padding(.leading, 42) }
            }
            .padding(14)
        }
        .onAppear {
            // A code already on the clipboard saves a paste, as long as nothing has been typed yet.
            if !edited, let waiting = app.roomCodeOnClipboard() {
                code = waiting
                DispatchQueue.main.async { edited = false }
            }
        }
    }

    private func join() {
        let t = app.text
        busy = true
        app.joinRoom(code) { error in
            busy = false
            switch error {
            case nil: failure = nil
            case .mistyped: failure = t.codeMistyped
            case .failed: failure = t.joinFailed
            case .invalid: failure = t.codeNotFound
            }
        }
    }
}

private struct CurrentRoom: View {
    @EnvironmentObject var app: AppController
    let room: RoomView
    @State private var justCopied = false

    var body: some View {
        let t = app.text
        Card {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.code ?? "").font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    Text(room.phase == .joining ? t.joining : t.shareCodeHint).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if room.phase == .joining { ProgressView().controlSize(.small) }
                Button(justCopied ? t.copied : t.copy) {
                    app.copyRoomCode()
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
                }
                Button(t.leave) { app.leaveRoom() }
            }
            .padding(14)
        }
        if room.lan == .unavailable {
            NoticeCard(symbol: "exclamationmark.triangle") {
                Text(t.lanUnavailable).font(.headline)
                Text(t.lanUnavailableHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if room.internet == .unavailable {
            NoticeCard(symbol: "exclamationmark.triangle") {
                Text(t.internetUnavailable).font(.headline)
                Text(t.internetUnavailableHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(t.tryAgain) { app.retryInternet() }
            }
        }
        Card {
            ForEach(room.members) { member in
                MemberRow(member: member)
                if member.id != room.members.last?.id { RowDivider() }
            }
            if room.members.count <= 1 {
                Group {
                    Text(room.lonely ? t.stillAlone : t.nobodyYet).foregroundStyle(.secondary)
                    if room.lonely && !app.preferences.room.allowsInternet { Text(t.internetOffNote).foregroundStyle(.orange) }
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
            }
            if room.clockSkew {
                Text(t.clockSkew).font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }
}

private struct MemberRow: View {
    @EnvironmentObject var app: AppController
    let member: RoomView.Member

    var body: some View {
        let t = app.text
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: .hex(TagColors.color(member.color)))).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.name)
                    if member.isSelf { Text("(\(t.you))").foregroundStyle(.secondary) }
                }
                if member.noEmotes { Text(t.memberNoEmotes).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !member.isSelf { Pill(text: t.pathName(member.path), tint: member.path == "unreachable" ? .orange : .secondary) }
            if member.status == "paused" { Pill(text: t.memberPaused) }
            if member.status == "muted" { Pill(text: t.memberMuted) }
            if member.needsUpdate { Pill(text: t.memberNeedsUpdate, tint: .red) }
            if !member.isSelf {
                Button(member.muted ? t.showMember : t.hideMember) { app.setMemberHidden(member.id, !member.muted) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

private struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        let t = app.text
        Card {
            SwitchRow(title: t.openAtLogin, hint: t.openAtLoginHint, isOn: app.binding(\.opensAtLogin))
            RowDivider()
            Row(title: t.languageTitle) {
                // Sized to its text, so it ends at the row's right edge like every other control.
                Picker("", selection: app.binding(\.language)) {
                    ForEach(LanguageChoice.allCases, id: \.self) { choice in Text(t.languageName(choice)).tag(choice) }
                }
                .labelsHidden().fixedSize()
            }
            if app.updates != nil {
                RowDivider()
                SwitchRow(title: t.autoCheck, hint: t.autoCheckHint, isOn: app.binding(\.updates.checksAutomatically))
                RowDivider()
                SwitchRow(title: t.autoInstall, hint: t.autoInstallHint, dimmed: !app.preferences.updates.checksAutomatically,
                          isOn: app.binding(\.updates.installsAutomatically))
            }
            RowDivider()
            Row(title: t.permissions, hint: t.permissionsRowHint) {
                Button(t.viewPermissions) { app.showPermissions() }
            }
        }
        if !app.problems.isEmpty { Card { bullets(t.attention, app.problems) } }
        Card { bullets(t.goodToKnow, t.notes(stableSignature: AppController.hasStableSignature)) }
            .onAppear { app.refreshProblems() }

        SectionLabel(title: t.about)
        updateCard
        Card {
            HStack(spacing: 12) {
                if let mark = BrandMark.image(pixels: 144) {
                    Image(decorative: mark, scale: 4).interpolation(.high)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.appName).font(.headline)
                    Text(t.versionLine(AppController.version)).font(.callout).foregroundStyle(.secondary)
                    if let checkedNote { Text(checkedNote).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                if let updates = app.updates {
                    Button(t.checkNow) { app.checkForUpdates() }.disabled(!updates.canCheck)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if let page = AppController.projectPage {
                RowDivider()
                Row(title: t.repository, hint: page.absoluteString.replacingOccurrences(of: "https://", with: "")) {
                    Button(t.openRepository) { NSWorkspace.shared.open(page) }
                }
            }
            RowDivider()
            Row(title: t.dataFolder, hint: t.dataFolderHint) {
                Button(t.openDataFolder) { app.openDataFolder() }
            }
        }
    }

    private var checkedNote: String? {
        guard let checked = app.updates?.lastCheck else { return nil }
        let clock = DateFormatter()
        clock.locale = app.text.language.locale
        clock.doesRelativeDateFormatting = true
        clock.timeStyle = .short
        clock.dateStyle = .short
        return app.text.lastChecked(clock.string(from: checked))
    }

    /// A version found in the background, waiting to be looked at.
    @ViewBuilder
    private var updateCard: some View {
        let t = app.text
        if let version = app.updates?.pendingVersion {
            NoticeCard(symbol: "arrow.down.circle", tint: .accentColor) {
                Text(t.updateFound(version)).font(.headline)
                Text(t.updateFoundHint).font(.callout).foregroundStyle(.secondary)
                Button(t.viewUpdate) { app.checkForUpdates() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func bullets(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { line in
                Text("• \(line)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

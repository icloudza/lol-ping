import AppKit
import LPCore
import LPRooms

/// Something the user just placed, in points from the top-left corner of the display it is on.
struct Placement {
    enum Item {
        case ping(String)
        case emote(String)
    }

    let item: Item
    let displayId: UInt32
    let point: CGPoint
}

/// Puts a transparent window over every display and draws the wheels, pings, emotes and notices on them.
final class OverlayManager {
    private struct Screen {
        let window: OverlayWindow
        let view: OverlayView
        /// The display's frame in the event tap's coordinates: points, origin at the main display's top-left, y down.
        var frame: DisplayRect
        /// The height of the menu bar on this display, so notices sit below it.
        var menuBarHeight: CGFloat
    }

    /// Fires for everything the user sends with a gesture. Previews from the settings window don't count.
    var onPlaced: ((Placement) -> Void)?
    var onDisplaysChanged: (() -> Void)?
    /// What an emote looks like; `fromRoom` when it was sent by someone else.
    var artFor: (_ ref: String, _ fromRoom: Bool) -> EmoteArt = { ref, _ in EmoteCatalog[ref].map(EmoteArt.bundled) ?? .missing }
    /// The still of one of the user's own pictures, for its wheel slice.
    var importedBadge: (String) -> CGImage? = { _ in nil }

    let sounds = SoundBank()
    private var preferences: Preferences
    private var text: L10n
    private var screens: [UInt32: Screen] = [:]
    private(set) var numbered: [NumberedDisplay] = []
    private var mainDisplay: UInt32 = 0
    /// Where a wheel is open right now.
    private var wheel: (display: UInt32, kind: WheelKind)?
    private var screenObserver: NSObjectProtocol?

    init(preferences: Preferences, text: L10n) {
        self.preferences = preferences
        self.text = text
    }

    func start() {
        sounds.loadBundled {}
        layOutScreens()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layOutScreens()
        }
    }

    func shutDown() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screens.values.forEach { $0.window.orderOut(nil) }
        screens.removeAll()
    }

    func update(preferences: Preferences, text: L10n) {
        self.preferences = preferences
        self.text = text
        screens.values.forEach { fillWheels($0.view) }
    }

    // MARK: - Gestures

    func perform(_ action: GestureAction) {
        switch action {
        case .wheelOpened(let kind, let at):
            guard let (id, local) = locate(at) else { return }
            dismissWheel()
            wheel = (id, kind)
            sounds.warmUp()
            screens[id]?.view.wheel(kind).show(at: local)
        case .wheelMoved(let to):
            guard let wheel, let screen = screens[wheel.display] else { return }
            screen.view.wheel(wheel.kind).pointerMoved(to: local(to, in: screen))
        case .wheelReleased(let at):
            guard let open = wheel, let screen = screens[open.display] else { return }
            wheel = nil
            guard let chosen = screen.view.wheel(open.kind).release(at: local(at, in: screen)) else { return }
            place(open.kind == .ping ? .ping(chosen.key) : .emote(chosen.key), on: open.display, at: chosen.at)
        case .quickSent(let kind, let at):
            guard let (id, local) = locate(at) else { return }
            place(kind == .ping ? .ping(preferences.ping.quick) : .emote(preferences.emote.quick), on: id, at: local)
        case .cancelled:
            dismissWheel()
        case .enabledChanged, .hotkey:
            break // the app's business, not the overlays'
        }
    }

    /// Places an item at a point given in the event tap's coordinates, as a shortcut does.
    func send(_ item: Placement.Item, at point: CGPoint) {
        guard let (id, local) = locate(point) else { return }
        place(item, on: id, at: local)
    }

    /// Takes down an open wheel. Also needed when the event tap stops, since no "cancelled" will come from it then.
    func dismissWheel() {
        guard let open = wheel else { return }
        wheel = nil
        screens[open.display]?.view.pingWheel.hide()
        screens[open.display]?.view.emoteWheel.hide()
    }

    private func place(_ item: Placement.Item, on display: UInt32, at point: CGPoint) {
        switch item {
        case .ping(let id):
            showPing(PingCatalog.resolve(id), on: display, at: point, tag: nil)
        case .emote(let ref):
            showEmote(from: "self", art: artFor(ref, false), on: display, at: point, tag: nil)
        }
        onPlaced?(Placement(item: item, displayId: display, point: point))
    }

    // MARK: - Showing things

    /// Plays a ping in the middle of the main display (the settings window's "try it").
    func previewPing(_ id: String) {
        guard let screen = screens[mainDisplay] else { return }
        showPing(PingCatalog.resolve(id), on: mainDisplay, at: CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2), tag: nil)
    }

    func previewEmote(_ ref: String) {
        guard let screen = screens[mainDisplay] else { return }
        showEmote(from: "preview", art: artFor(ref, false), on: mainDisplay, at: CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2), tag: nil)
    }

    /// A ping from someone in the room, already placed on one of this Mac's displays.
    func showRemotePing(_ id: String, on display: UInt32, at point: CGPoint, tag: NameTag) {
        showPing(PingCatalog.resolve(id), on: display, at: point, tag: tag)
    }

    func showRemoteEmote(_ ref: String, from peer: String, on display: UInt32, at point: CGPoint, tag: NameTag) {
        showEmote(from: peer, art: artFor(ref, true), on: display, at: point, tag: tag)
    }

    func notice(_ title: String, _ detail: String = "") {
        guard let screen = screens[mainDisplay] else { return }
        ToastFX.show(in: screen.view.toasts, title: title, body: detail, bounds: screen.view.bounds, topInset: screen.menuBarHeight, scale: screen.view.scale)
    }

    private var loudness: Double { preferences.sound.muted ? 0 : preferences.sound.volume / 100 }

    private func showPing(_ ping: Ping, on display: UInt32, at point: CGPoint, tag: NameTag?) {
        guard let screen = screens[display] else { return }
        PingFX.spawn(in: screen.view.pings, ping: ping, at: point, size: preferences.ping.size, duration: preferences.ping.duration, tag: tag, scale: screen.view.scale)
        sounds.play(ping.sound, volume: loudness)
    }

    private func showEmote(from sender: String, art: EmoteArt, on display: UInt32, at point: CGPoint, tag: NameTag?) {
        guard let screen = screens[display] else { return }
        // One emote per sender across all displays: their earlier one goes, wherever it was.
        for (id, other) in screens where id != display { other.view.stage.clear(owner: sender) }
        screen.view.stage.spawn(owner: sender, art: art, at: point, size: preferences.emote.size, tag: tag)
        if case .bundled(let emote) = art, emote.hasSound, preferences.emote.playsSound {
            sounds.play("emote:\(emote.slug)", volume: loudness)
        }
    }

    // MARK: - Displays

    private func locate(_ point: CGPoint) -> (UInt32, CGPoint)? {
        guard let (id, screen) = screens.first(where: { $0.value.frame.contains(x: point.x, y: point.y) }) else { return nil }
        return (id, local(point, in: screen))
    }

    private func local(_ point: CGPoint, in screen: Screen) -> CGPoint {
        CGPoint(x: point.x - screen.frame.x, y: point.y - screen.frame.y)
    }

    private func fillWheels(_ view: OverlayView) {
        let images = ImageStore.shared
        view.pingWheel.setLabels(idle: text.wheelIdleLabel(.ping), back: text.wheelBack)
        view.emoteWheel.setLabels(idle: text.wheelIdleLabel(.emote), back: text.wheelBack)
        view.pingWheel.setItems(preferences.ping.slices.enumerated().map { index, id in
            let ping = PingCatalog.resolve(id)
            // The four straight slices keep their colours; the diagonal ones stay pale until pointed at.
            let colour = images.texture(ping.badge)
            return WheelItem(key: ping.id, title: text.pingName(ping.id), tint: ping.tint,
                             resting: index % 2 == 0 ? colour : images.paleTexture(ping.badge), lit: colour)
        })
        view.emoteWheel.setItems(preferences.emote.slices.map { ref in
            let badge = EmoteCatalog.contains(ref) ? images.emoteBadge(ref) : (importedBadge(ref) ?? images.texture(PingCatalog.standInTexture))
            let name = EmoteCatalog[ref]?.displayName(chinese: text.isChinese) ?? preferences.emote.imported.first { $0.id == ref }?.name ?? "?"
            return WheelItem(key: ref, title: name, tint: nil, resting: badge, lit: badge)
        })
        let tick: (Int) -> Void = { [weak self] _ in
            guard let self, self.preferences.sound.wheelTick else { return }
            self.sounds.play(PingCatalog.tickSound, volume: self.loudness * 0.5)
        }
        view.pingWheel.onSliceChanged = tick
        view.emoteWheel.onSliceChanged = tick
    }

    private func layOutScreens() {
        dismissWheel()
        mainDisplay = CGMainDisplayID()
        var present = Set<UInt32>()
        var frames: [(id: UInt32, bounds: DisplayRect)] = []
        for nsScreen in NSScreen.screens {
            guard let id = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            present.insert(id)
            let cg = CGDisplayBounds(id)
            let frame = DisplayRect(x: cg.origin.x, y: cg.origin.y, width: cg.width, height: cg.height)
            frames.append((id, frame))
            let menuBar = nsScreen.frame.maxY - nsScreen.visibleFrame.maxY
            if var existing = screens[id], existing.view.scale == nsScreen.backingScaleFactor {
                existing.frame = frame
                existing.menuBarHeight = menuBar
                screens[id] = existing
                existing.window.setFrame(nsScreen.frame, display: true)
            } else {
                // New display, or its pixel density changed: the wheel's bitmaps are made for one density.
                screens[id]?.window.orderOut(nil)
                let window = OverlayWindow(frame: nsScreen.frame)
                let view = OverlayView(frame: NSRect(origin: .zero, size: nsScreen.frame.size), scale: nsScreen.backingScaleFactor)
                window.contentView = view
                fillWheels(view)
                window.setFrame(nsScreen.frame, display: true)
                window.orderFrontRegardless()
                screens[id] = Screen(window: window, view: view, frame: frame, menuBarHeight: menuBar)
            }
        }
        for id in screens.keys where !present.contains(id) {
            screens[id]?.window.orderOut(nil)
            screens[id] = nil
        }
        numbered = DisplayNumbers.number(frames, primaryId: mainDisplay)
        onDisplaysChanged?()
    }

    #if DEBUG
    /// Development only: the main display's overlay as it is drawn right now, over a plain backdrop.
    func debugSnapshot(backdrop: CGColor) -> CGImage? {
        guard let screen = screens[mainDisplay], let layer = screen.view.layer else { return nil }
        let scale = screen.view.scale
        let w = Int(screen.view.bounds.width * scale), h = Int(screen.view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(backdrop)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        (layer.presentation() ?? layer).render(in: ctx)
        return ctx.makeImage()
    }
    #endif
}

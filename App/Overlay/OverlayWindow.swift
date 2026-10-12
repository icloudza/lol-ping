import AppKit
import LPCore

/// A transparent, click-through, always-on-top window covering one display.
final class OverlayWindow: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        // Every Space, and over other apps' full-screen windows; never part of Mission Control or window cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Stops macOS pushing the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Everything drawn over one display, in layers: pings, emotes, the two wheels, notices. Points from the top-left, y down.
final class OverlayView: NSView {
    let pings = CALayer()
    let emotes = CALayer()
    let toasts = CALayer()
    private(set) var pingWheel: WheelLayer!
    private(set) var emoteWheel: WheelLayer!
    private(set) var stage: EmoteStage!
    let scale: CGFloat

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        // A flipped, layer-backed view: AppKit flips the backing layer's geometry, so sublayers are placed y down
        // and their contents still draw the right way up.
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        pingWheel = WheelLayer(kind: .ping, scale: scale)
        emoteWheel = WheelLayer(kind: .emote, scale: scale)
        stage = EmoteStage(layer: emotes, scale: scale)
        for l in [pings, emotes, pingWheel!, emoteWheel!, toasts] {
            if !(l is WheelLayer) { l.frame = bounds }
            root.addSublayer(l)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [pings, emotes, toasts] { l.frame = bounds }
        CATransaction.commit()
    }

    func wheel(_ kind: WheelKind) -> WheelLayer { kind == .emote ? emoteWheel : pingWheel }
}

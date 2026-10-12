import AppKit

/// The icon in the menu bar, and the menu under it.
final class StatusItemController: NSObject, NSMenuDelegate {
    enum Appearance { case on, paused, needsAccess }

    struct RoomSummary: Equatable {
        var code: String?
        var people = 0
        var muted = false
    }

    enum UpdateItem: Equatable {
        case check
        case get(version: String)
    }

    struct Commands {
        var openSettings: (_ pane: String?) -> Void = { _ in }
        var setEnabled: (Bool) -> Void = { _ in }
        var quit: () -> Void = {}
        var update: () -> Void = {}
        var joinFromClipboard: () -> Void = {}
        var newRoom: () -> Void = {}
        var copyRoomCode: () -> Void = {}
        var setRoomMuted: (Bool) -> Void = { _ in }
        var leaveRoom: () -> Void = {}
    }

    var commands = Commands()
    var room = RoomSummary()
    /// Nil: this build has no update checker, so the menu has no update entry.
    var updateItem: UpdateItem?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var text: L10n
    private var appearance = Appearance.on
    private var enabled = true
    private var handlers: [() -> Void] = []

    private lazy var onGlyph = Self.glyph("MenuBarIcon")
    private lazy var pausedGlyph = Self.glyph("MenuBarIconPaused")
    /// The same shape in solid orange, not tinted by the menu bar, so it catches the eye.
    private lazy var alertGlyph: NSImage? = {
        guard let shape = NSImage(named: "MenuBarIcon") else { return nil }
        let image = NSImage(size: shape.size, flipped: false) { rect in
            shape.draw(in: rect)
            NSColor.systemOrange.set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }()

    init(text: L10n) {
        self.text = text
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
    }

    private static func glyph(_ name: String) -> NSImage? {
        let image = NSImage(named: name)
        image?.isTemplate = true
        return image
    }

    func show(_ appearance: Appearance, enabled: Bool) {
        self.appearance = appearance
        self.enabled = enabled
        refreshIcon()
    }

    func setText(_ text: L10n) {
        self.text = text
        refreshIcon()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        switch appearance {
        case .on: button.image = onGlyph
        case .paused: button.image = pausedGlyph
        case .needsAccess: button.image = alertGlyph
        }
        button.toolTip = text.menuTooltip(on: enabled, needsAccess: appearance == .needsAccess)
    }

    // MARK: - Menu

    /// The menu is rebuilt each time it opens, so it always reflects the present state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        handlers.removeAll()

        addSwitch(text.menuEnabled, icon: Self.icon(NSImage(named: "MenuBarIcon")), isOn: enabled, to: menu, enabled: appearance != .needsAccess) { [weak self] on in
            self?.commands.setEnabled(on)
        }
        menu.addItem(.separator())

        let roomMenu = NSMenu()
        roomMenu.autoenablesItems = false
        if let code = room.code {
            add(text.menuRoomSummary(code, room.people), symbol: "number", to: roomMenu, enabled: false) {}
            roomMenu.addItem(.separator())
            add(text.menuCopyCode, symbol: "doc.on.doc", to: roomMenu) { [weak self] in self?.commands.copyRoomCode() }
            addSwitch(text.muteRoom, icon: Self.symbol("eye.slash"), isOn: room.muted, to: roomMenu) { [weak self] on in
                self?.commands.setRoomMuted(on)
            }
            add(text.menuLeaveRoom, symbol: "rectangle.portrait.and.arrow.right", to: roomMenu) { [weak self] in self?.commands.leaveRoom() }
            roomMenu.addItem(.separator())
        } else {
            add(text.menuJoinFromClipboard, symbol: "doc.on.clipboard", to: roomMenu) { [weak self] in self?.commands.joinFromClipboard() }
            add(text.menuNewRoom, symbol: "plus.circle", to: roomMenu) { [weak self] in self?.commands.newRoom() }
        }
        add(text.menuRoomSettings, symbol: "slider.horizontal.3", to: roomMenu) { [weak self] in self?.commands.openSettings("room") }
        let roomEntry = NSMenuItem(title: text.menuRoom, action: nil, keyEquivalent: "")
        Self.setIcon(Self.symbol("person.2"), on: roomEntry)
        roomEntry.submenu = roomMenu
        menu.addItem(roomEntry)

        add(text.menuSettings, symbol: "gearshape", to: menu, key: ",") { [weak self] in self?.commands.openSettings(nil) }
        if let updateItem {
            switch updateItem {
            case .check:
                add(text.menuCheckForUpdates, symbol: "arrow.triangle.2.circlepath", to: menu) { [weak self] in self?.commands.update() }
            case .get(let version):
                add(text.menuGetUpdate(version), symbol: "arrow.down.circle", to: menu) { [weak self] in self?.commands.update() }
            }
        }
        menu.addItem(.separator())
        add(text.menuQuit, symbol: "xmark.rectangle", to: menu, key: "q") { [weak self] in self?.commands.quit() }
    }

    private static func symbol(_ name: String) -> NSImage? {
        icon(NSImage(systemSymbolName: name, accessibilityDescription: nil))
    }

    /// The picture centred on a canvas that is the same size for every row. The system starts a menu's titles after
    /// its widest icon, so equal canvases put the titles at the same place in every menu, which is what lets the
    /// switch rows line up with the ordinary ones.
    static func icon(_ source: NSImage?) -> NSImage? {
        guard let source, source.size.width > 0, source.size.height > 0 else { return nil }
        let image = NSImage(size: MenuSwitchRow.Metrics.iconSize, flipped: false) { canvas in
            let scale = min(canvas.width / source.size.width, canvas.height / source.size.height, 1)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func setIcon(_ image: NSImage?, on entry: NSMenuItem) {
        entry.image = image
        // From macOS 27 on, the system leaves menu icons out unless an item insists on its own
        // (`preferredImageVisibility = .visible`, which is 1). Set by name so the app also builds with an older SDK.
        if entry.responds(to: Selector(("setPreferredImageVisibility:"))) { entry.setValue(1, forKey: "preferredImageVisibility") }
    }

    @discardableResult
    private func add(_ title: String, symbol: String, to menu: NSMenu, enabled: Bool = true, key: String = "", _ handler: @escaping () -> Void) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        entry.target = self
        entry.tag = handlers.count
        entry.isEnabled = enabled
        Self.setIcon(Self.symbol(symbol), on: entry)
        handlers.append(handler)
        menu.addItem(entry)
        return entry
    }

    /// A row with a switch at its right end. Flipping it leaves the menu open, as the system's own menus do.
    private func addSwitch(_ title: String, icon: NSImage?, isOn: Bool, to menu: NSMenu, enabled: Bool = true, _ handler: @escaping (Bool) -> Void) {
        let entry = NSMenuItem()
        entry.view = MenuSwitchRow(title: title, icon: icon, isOn: isOn, enabled: enabled, onChange: handler)
        menu.addItem(entry)
    }

    @objc private func run(_ sender: NSMenuItem) {
        if handlers.indices.contains(sender.tag) { handlers[sender.tag]() }
    }
}

/// A menu row drawn by the app: an icon and a title placed where the system puts them on ordinary rows, and a switch
/// on the right. A click anywhere on the row flips the switch.
final class MenuSwitchRow: NSView {
    /// Where an ordinary menu row keeps its icon, its title and its right-hand margin (measured on macOS 27).
    enum Metrics {
        static let iconLeft: CGFloat = 16
        static let iconSize = NSSize(width: 18, height: 16)
        static let titleLeft: CGFloat = 38
        /// Where key equivalents end on ordinary rows.
        static let right: CGFloat = 18
        static let height: CGFloat = 24
    }

    private let toggle: MenuSwitch
    private let isUsable: Bool
    private let onChange: (Bool) -> Void

    init(title: String, icon: NSImage?, isOn: Bool, enabled: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        isUsable = enabled
        toggle = MenuSwitch(isOn: isOn, enabled: enabled)
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = enabled ? .labelColor : .disabledControlTextColor
        label.sizeToFit()

        let width = (Metrics.titleLeft + label.frame.width + 24 + MenuSwitch.size.width + Metrics.right).rounded(.up)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.height))
        autoresizingMask = .width // the menu may be wider than this row needs

        if let icon {
            let picture = NSImageView(frame: NSRect(origin: NSPoint(x: Metrics.iconLeft, y: (Metrics.height - Metrics.iconSize.height) / 2), size: Metrics.iconSize))
            picture.image = icon
            picture.imageScaling = .scaleNone
            picture.contentTintColor = enabled ? .labelColor : .disabledControlTextColor
            addSubview(picture)
        }
        label.setFrameOrigin(NSPoint(x: Metrics.titleLeft, y: ((Metrics.height - label.frame.height) / 2).rounded()))
        addSubview(label)

        toggle.setFrameOrigin(NSPoint(x: width - Metrics.right - MenuSwitch.size.width, y: (Metrics.height - MenuSwitch.size.height) / 2))
        toggle.autoresizingMask = .minXMargin // stays at the right edge
        addSubview(toggle)

        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn)
        setAccessibilityEnabled(enabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseUp(with event: NSEvent) {
        guard isUsable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle.setOn(!toggle.isOn)
        setAccessibilityValue(toggle.isOn)
        onChange(toggle.isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isUsable else { return false }
        toggle.setOn(!toggle.isOn)
        setAccessibilityValue(toggle.isOn)
        onChange(toggle.isOn)
        return true
    }
}

/// A small switch drawn by hand. The system's `NSSwitch` turns grey in any window that isn't the key window, and a
/// menu never is, so there it would look switched off whatever its state.
private final class MenuSwitch: NSView {
    static let size = NSSize(width: 34, height: 16)
    private static let knobSize = NSSize(width: 20, height: 12)
    private static let inset: CGFloat = 2

    private(set) var isOn: Bool

    init(isOn: Bool, enabled: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        alphaValue = enabled ? 1 : 0.45
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setOn(_ on: Bool) {
        isOn = on
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.22)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let x = isOn ? bounds.maxX - Self.inset - Self.knobSize.width : Self.inset
        let knob = NSRect(origin: NSPoint(x: x, y: (bounds.height - Self.knobSize.height) / 2), size: Self.knobSize)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.height / 2, yRadius: knob.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Clicks belong to the row, which flips the switch wherever on it they land.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

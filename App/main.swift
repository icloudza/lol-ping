import AppKit
import LPCore
import SwiftUI

/// A menu bar app: no Dock icon except while the settings window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let openSettingsNote = Notification.Name((Bundle.main.bundleIdentifier ?? "LolPing") + ".openSettings")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch opens the first one's settings window instead.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        var demo = false
        #if DEBUG
        demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"] != nil // a development snapshot run beside the real app
        #endif
        if !others.isEmpty && !demo {
            DistributedNotificationCenter.default().postNotificationName(Self.openSettingsNote, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.openSettingsNote, object: nil, queue: .main) { _ in
            AppController.shared.showSettings()
        }
        NSApp.mainMenu = MainMenu.build()
        #if DEBUG
        // Development only: `LOLPING_DEMO=brand:<file.png>` writes the sidebar's header as a picture, without opening a window.
        if let demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"], demo.hasPrefix("brand:") {
            let header = SettingsView.BrandHeader(tagline: AppController.shared.text.tagline).padding(16).background(Color(white: 0.9))
            let renderer = ImageRenderer(content: header)
            renderer.scale = 4
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(demo.dropFirst(6))))
            }
            exit(0)
        }
        // Development only: `LOLPING_DEMO=panes:<folder>` draws every settings pane into <folder>/<pane>.png in a
        // window that is never put on screen.
        if let demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"], demo.hasPrefix("panes:") {
            let folder = URL(fileURLWithPath: String(demo.dropFirst(6)), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for pane in SettingsPane.allCases {
                let frame = NSRect(x: 0, y: 0, width: 1000, height: pane == .shortcut ? 2100 : 1100)
                let host = NSHostingView(rootView: SettingsView(pane: pane).environmentObject(AppController.shared))
                let window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: picture)
                try? picture.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(pane.rawValue).png"))
            }
            // The permissions window in each of its states, drawn the same way.
            let states: [(String, AppController.AccessStep, RoomView.Link)] = [
                ("ask", .ask, .off), ("switch-on", .switchOn, .off), ("stale", .stale, .unavailable), ("granted", .granted, .ok),
            ]
            for (name, step, lan) in states {
                let host = NSHostingView(rootView: PermissionsView(preview: (step, lan)).environmentObject(AppController.shared))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: PermissionsView.size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: picture)
                try? picture.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("permissions-\(name).png"))
            }
            exit(0)
        }
        // Development only: `LOLPING_DEMO=audio` times how long the calling thread is held by the sound calls after
        // the hardware has gone to sleep, and checks that a sound really starts. It plays one tick, all but silent.
        if ProcessInfo.processInfo.environment["LOLPING_DEMO"] == "audio" {
            let sounds = SoundBank()
            var loaded = false
            sounds.loadBundled { loaded = true }
            while !loaded { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            func held(_ work: () -> Void) -> String {
                let began = CFAbsoluteTimeGetCurrent()
                work()
                return String(format: "%.1f ms", (CFAbsoluteTimeGetCurrent() - began) * 1000)
            }
            print("warmUp held the caller for", held { sounds.warmUp() })
            print("play held the caller for", held { sounds.play(PingCatalog.tickSound, volume: 0.001) })
            let began = CFAbsoluteTimeGetCurrent()
            let state = sounds.debugState()
            print(String(format: "hardware up after %.0f ms: running=%@ playing=%d", (CFAbsoluteTimeGetCurrent() - began) * 1000, state.running ? "yes" : "no", state.playing))
            exit(0)
        }
        // Development only: `LOLPING_DEMO=switch:<file.png>` draws the menu's switch rows (on, off, unavailable) into a
        // picture without showing anything.
        if let demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"], demo.hasPrefix("switch:") {
            let rows = [(true, true), (false, true), (true, false)].map { on, enabled in
                MenuSwitchRow(title: AppController.shared.text.menuEnabled, icon: StatusItemController.icon(NSImage(named: "MenuBarIcon")), isOn: on, enabled: enabled) { _ in }
            }
            let stack = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: CGFloat(rows.count) * 30))
            stack.wantsLayer = true
            stack.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
            for (index, row) in rows.enumerated() {
                row.frame = NSRect(x: 0, y: CGFloat(rows.count - 1 - index) * 30 + 3, width: 220, height: row.frame.height)
                stack.addSubview(row)
            }
            let window = NSWindow(contentRect: stack.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = stack
            stack.layoutSubtreeIfNeeded()
            if let picture = stack.bitmapImageRepForCachingDisplay(in: stack.bounds) {
                stack.cacheDisplay(in: stack.bounds, to: picture)
                try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(demo.dropFirst(7))))
            }
            exit(0)
        }
        // Development only: `LOLPING_DEMO=menu:<folder>` pops the menu bar menu and its room submenu for a moment each
        // and saves pictures of them.
        if let demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"], demo.hasPrefix("menu:") {
            let folder = URL(fileURLWithPath: String(demo.dropFirst(5)), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: Capture.self)
            let controller = StatusItemController(text: AppController.shared.text)
            controller.updateItem = .check
            controller.room = .init(code: "PING-ABCDE-FGHJK", people: 3, muted: true)
            let main = NSMenu()
            main.autoenablesItems = false
            controller.menuNeedsUpdate(main)
            let corner = NSPoint(x: (NSScreen.main?.frame.maxX ?? 600) - 320, y: (NSScreen.main?.frame.minY ?? 0) + 320)
            for (name, menu) in [("main", main), ("room", main.items.compactMap(\.submenu).first ?? main)] {
                let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
                    for window in NSApp.windows where window.isVisible && window.frame.width > 60 {
                        if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() {
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
                        }
                    }
                    menu.cancelTracking()
                }
                RunLoop.main.add(timer, forMode: .common)
                menu.popUp(positioning: nil, at: corner, in: nil)
            }
            controller.remove()
            exit(0)
        }
        // Development only: `LOLPING_DEMO=import:<file>,<file>` adds emote pictures without showing anything, and prints the result.
        if let demo = ProcessInfo.processInfo.environment["LOLPING_DEMO"], demo.hasPrefix("import:") {
            let app = AppController.shared
            for path in demo.dropFirst("import:".count).split(separator: ",") {
                let failures = app.addEmotes(from: [URL(fileURLWithPath: String(path))])
                print(URL(fileURLWithPath: String(path)).lastPathComponent, "->", failures.isEmpty ? "ok" : failures.joined(separator: " | "))
            }
            for e in app.preferences.emote.imported {
                print(e.id, e.name, e.animated, app.library.still(e.id).map { "\($0.width)x\($0.height)" } ?? "no still")
            }
            app.removeEmote(app.preferences.emote.imported.first?.id ?? "")
            print("after remove:", app.preferences.emote.imported.count, "wheel ok:", Set(app.preferences.emote.slices).count == 8)
            exit(0)
        }
        #endif
        AppController.shared.start()
    }

    /// Opened again from Finder or Launchpad while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Give the app a moment to save and to leave the room properly.
        var replied = false
        let reply = {
            if replied { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        AppController.shared.prepareToQuit(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reply) // but never hang on the network
        return replied ? .terminateNow : .terminateLater
    }
}

/// The app, Edit and Window menus, so ⌘Q, ⌘W and the clipboard shortcuts work in the settings window.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LolPing"

        let app = NSMenu()
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: name))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

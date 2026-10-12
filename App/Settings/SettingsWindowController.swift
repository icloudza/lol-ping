import AppKit
import SwiftUI

/// The settings window. The Dock icon shows only while it is open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LolPing"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(AppController.shared))
            w.setContentSize(NSSize(width: 920, height: 700))
            w.center()
            w.setFrameAutosaveName("LolPingSettings")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// Development only: the window's content as a PNG.
    func debugSnapshot() -> Data? {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif

    func windowWillClose(_ notification: Notification) {
        // A key recorder that was listening when the window closed can't tidy up after itself.
        AppController.shared.setRecordingKey(false)
        NSApp.setActivationPolicy(.accessory)
    }
}

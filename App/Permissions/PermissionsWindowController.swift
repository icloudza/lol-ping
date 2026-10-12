import AppKit
import SwiftUI

/// The permissions window: shown at launch until the app is allowed under Accessibility and the user has been
/// through it once, and again whenever it is asked for from the settings.
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionsWindowController()
    private var window: NSWindow?
    /// What to do once the window has gone, however it went.
    private var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    /// `atLaunch`: the main button reads "Get Started" and waits for Accessibility; otherwise it is a plain "Done".
    func show(atLaunch: Bool, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        let view = PermissionsView(atLaunch: atLaunch, onDone: { [weak self] in self?.window?.close() })
            .environmentObject(AppController.shared)
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: PermissionsView.size),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = AppController.shared.text.permissions
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.contentViewController = NSHostingController(rootView: view)
            w.delegate = self
            window = w
        }
        window?.setContentSize(PermissionsView.size)
        if window?.isVisible != true { window?.center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.didClose(notification.object as? NSWindow)
        let then = onClose
        onClose = nil
        // On the next turn of the run loop: opening another window from inside a close callback confuses AppKit
        // about which window is key.
        DispatchQueue.main.async { then?() }
    }
}

/// The Dock icon shows only while one of the app's own windows is open.
enum AppWindows {
    static func didClose(_ closing: NSWindow?) {
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

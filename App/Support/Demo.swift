#if DEBUG
import AppKit
import LPCore
import LPRooms

/// Development only. `LOLPING_DEMO=<mode>` drives the overlay or the settings window without the event tap, and
/// `LOLPING_DEMO_OUT=<path prefix>` writes pictures of the result, so the look can be checked on a Mac that hasn't
/// granted Accessibility. Modes: wheel[:slice], emotewheel[:slice], pings, emotes, room:<code>, settings-<pane>,<pane>…
enum Demo {
    /// What the window server shows for one of this app's own windows (those need no screen-recording permission).
    /// The call has left the SDK headers but is still in CoreGraphics, so it is looked up by name.
    static func capture(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue()
    }

    static func save(_ image: CGImage?, to path: String) {
        guard let image else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func run(_ mode: String, overlays: OverlayManager) {
        guard let main = overlays.numbered.first else { return }
        let environment = ProcessInfo.processInfo.environment
        let out = environment["LOLPING_DEMO_OUT"]
        let centre = CGPoint(x: main.bounds.x + main.bounds.width / 2, y: main.bounds.y + main.bounds.height / 2)
        func after(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
        let name = mode.split(separator: ":").first.map(String.init) ?? mode
        let argument = mode.contains(":") ? String(mode[mode.index(after: mode.firstIndex(of: ":")!)...]) : nil

        switch name {
        case "wheel", "emotewheel":
            let kind: WheelKind = name == "wheel" ? .ping : .emote
            // The slice to point at (0 is up, clockwise), or "hub" to stay in the middle.
            let slice = Double(argument ?? "7") ?? -1
            after(0.5) { overlays.perform(.wheelOpened(kind, at: centre)) }
            after(0.8) {
                let angle = slice * .pi / 4, reach = slice < 0 ? 30.0 : 150.0
                overlays.perform(.wheelMoved(to: CGPoint(x: centre.x + reach * sin(angle) - 12, y: centre.y - reach * cos(angle) + 8)))
            }
        case "pings":
            for (i, ping) in PingCatalog.all.enumerated() {
                after(0.5 + Double(i) * 0.05) {
                    overlays.showRemotePing(ping.id, on: main.id, at: CGPoint(x: 200 + Double(i % 6) * 190, y: 260 + Double(i / 6) * 230),
                                            tag: NameTag(name: ping.id, color: i % TagColors.all.count))
                }
            }
            after(0.6) { overlays.notice("LolPing is on", "⌃⌥P switches it any time") }
        case "emotes":
            for (i, ref) in ["nice", "c:" + String(repeating: "0", count: 32), "poro_snax"].enumerated() {
                after(0.5) {
                    overlays.showRemoteEmote(ref, from: "peer\(i)", on: main.id, at: CGPoint(x: 300 + Double(i) * 260, y: 420),
                                             tag: NameTag(name: "Player \(i + 1)", color: i))
                }
            }
        case "room":
            let app = AppController.shared
            app.joinRoom(argument ?? "") { print("[join]", $0.map { "\($0)" } ?? "ok") }
            for i in 0..<12 {
                after(2 + Double(i)) {
                    overlays.perform(.quickSent(i % 2 == 0 ? .ping : .emote, at: CGPoint(x: centre.x - 300 + Double(i) * 50, y: centre.y + 200)))
                    let room = app.room
                    print("[room]", room.phase, room.code ?? "-", "lan=\(room.lan) net=\(room.internet)", room.members.map { "\($0.name)(\($0.path))" })
                }
            }
        default:
            if mode.hasPrefix("settings-") {
                let panes = mode.dropFirst("settings-".count).split(separator: ",").map(String.init)
                for (i, pane) in panes.enumerated() {
                    after(0.3 + Double(i) * 1.2) { AppController.shared.showSettings(pane: pane) }
                    after(1.2 + Double(i) * 1.2) {
                        if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                            save(capture(window), to: "\(out ?? "/tmp/lolping")-\(pane).png")
                        }
                        if i == panes.count - 1 { exit(0) }
                    }
                }
                return
            }
        }

        guard let out else { return }
        let moments = (environment["LOLPING_DEMO_AT"] ?? "1.5").split(separator: ",").compactMap { Double($0) }
        for (i, moment) in moments.enumerated() {
            after(moment) {
                // Over a plain backdrop, and exactly as the window server composites it (transparent where empty).
                save(overlays.debugSnapshot(backdrop: CGColor(gray: 0.32, alpha: 1)), to: "\(out)-\(i).png")
                if let window = NSApp.windows.first(where: { $0 is OverlayWindow && $0.screen == NSScreen.screens.first }) {
                    save(capture(window), to: "\(out)-\(i)ws.png")
                }
                if i == moments.count - 1 { exit(0) }
            }
        }
    }
}
#endif

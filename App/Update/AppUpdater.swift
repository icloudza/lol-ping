import AppKit
import Sparkle

/// In-app updates through Sparkle: it fetches the appcast, downloads the new version, checks its EdDSA signature,
/// swaps the app and relaunches. This class decides when, and tells the rest of the app what is going on.
///
/// A released build carries `SUFeedURL` and `SUPublicEDKey` in its Info.plist, written by the release pipeline.
/// A development build has neither, so it never checks and can never be replaced by the released app.
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    struct Status: Equatable {
        /// False while a check or a download is already under way.
        var canCheck = false
        var lastCheck: Date?
        /// A version found in the background that the user hasn't been shown yet.
        var pendingVersion: String?
    }

    /// Called on the main queue after every change of `status`.
    var onChange: (() -> Void)?
    /// A new version turned up while the app was busy being a menu bar app: say so without stealing the screen.
    var onFoundInBackground: ((String) -> Void)?
    private(set) var status = Status() {
        didSet { if status != oldValue { onChange?() } }
    }

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Bundle.main.bundleURL.pathExtension == "app" && feed.hasPrefix("https://") && !key.isEmpty
    }

    func start(checksAutomatically: Bool, installsAutomatically: Bool) {
        guard controller == nil, Self.isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            NSLog("LolPing: updates not started: %@", error.localizedDescription)
            return
        }
        self.controller = controller
        updater.automaticallyChecksForUpdates = checksAutomatically
        updater.automaticallyDownloadsUpdates = installsAutomatically
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.status.canCheck = updater.canCheckForUpdates }
        }
        status.lastCheck = updater.lastUpdateCheckDate
        // Once at every launch; after that Sparkle keeps to the interval in Info.plist.
        if checksAutomatically { updater.checkForUpdatesInBackground() }
    }

    /// The "Check for Updates" command. Sparkle shows the outcome itself: the new version with its notes, "you're up
    /// to date", or what went wrong. With a session already going, it brings that one to the front instead.
    func check() {
        controller?.updater.checkForUpdates()
    }

    func setChecksAutomatically(_ on: Bool) { controller?.updater.automaticallyChecksForUpdates = on }
    func setInstallsAutomatically(_ on: Bool) { controller?.updater.automaticallyDownloadsUpdates = on }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        status.lastCheck = updater.lastUpdateCheckDate
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// A menu bar app is rarely in front, and an update window that comes up behind everything else goes unseen.
    /// So an update found on schedule is announced the app's own way, and Sparkle's window waits to be asked for.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            // Sparkle's window is about to appear: give the app a Dock icon so the window can be found again.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            status.pendingVersion = update.displayVersionString
            onFoundInBackground?(update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        status.pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        status.pendingVersion = nil
        // After Sparkle's window has gone.
        DispatchQueue.main.async { AppWindows.didClose(nil) }
    }
}

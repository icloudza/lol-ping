import LPCore
import SwiftUI

/// One card listing what the app needs from macOS, each line with where it stands and the one thing to do about it.
/// Accessibility is required; the local network is only for rooms and is asked for by macOS itself.
struct PermissionsView: View {
    @EnvironmentObject var app: AppController
    var atLaunch = true
    /// Fixed states, for drawing the window without asking the system.
    var preview: (step: AppController.AccessStep, lan: RoomView.Link)?
    var onDone: () -> Void = {}

    static let size = CGSize(width: 540, height: 380)

    private var step: AppController.AccessStep { preview?.step ?? app.accessStep }
    private var lan: RoomView.Link { preview?.lan ?? app.room.lan }

    var body: some View {
        let t = app.text
        let ready = step == .granted
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let mark = BrandMark.image(pixels: 208) {
                    Image(decorative: mark, scale: 4).interpolation(.high).shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.permissionsHeadline).font(.system(size: 17, weight: .semibold))
                    Text(t.permissionsPromise).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                PermissionRow(symbol: "accessibility", title: t.permAccessibility, required: true, granted: ready,
                              caption: t.permAccessibilityCaption(step, appName: AppController.systemName), warns: step == .stale) {
                    switch step {
                    case .granted: EmptyView()
                    case .ask: Button(t.allow) { app.requestAccess() }.buttonStyle(.borderedProminent)
                    case .switchOn: Button(t.openSettings) { app.requestAccess() }.buttonStyle(.borderedProminent)
                    case .stale:
                        Button(t.tryAgain) { app.retryAccess() }
                        Button(t.resetAccess) { app.resetAccess() }.buttonStyle(.borderedProminent)
                    }
                }
                RowDivider().padding(.leading, 42)
                PermissionRow(symbol: "network", title: t.permLocalNetwork, required: false, granted: lan == .ok,
                              caption: t.permLocalNetworkCaption(unavailable: lan == .unavailable, appName: AppController.systemName),
                              warns: lan == .unavailable) {
                    if lan != .ok { Button(t.openSettings) { app.openPrivacySettings("Privacy_LocalNetwork") } }
                }
            }

            if ready {
                Label(t.permissionsReady(trigger: t.triggerName(app.preferences.ping.trigger), sideButton: app.preferences.ping.trigger.isSideButton),
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(t.permissionsFootnote).font(.callout).foregroundStyle(.tertiary)
                Spacer()
                if atLaunch && !ready { Button(t.later, action: onDone).keyboardShortcut(.cancelAction) }
                Button(atLaunch ? t.getStarted : t.done, action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(atLaunch && !ready)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PermissionRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let required: Bool
    let granted: Bool
    let caption: String
    var warns = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    PermissionBadge(required: required)
                }
                Text(caption).font(.callout).foregroundStyle(warns ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label(AppController.shared.text.allowed, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize()
            } else {
                HStack(spacing: 6) { trailing }.fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionBadge: View {
    let required: Bool

    var body: some View {
        let t = AppController.shared.text
        Text(required ? t.requiredBadge : t.optionalBadge)
            .font(.caption.weight(.medium))
            .foregroundStyle(required ? Color.red : Color.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background((required ? Color.red : Color.primary).opacity(0.12), in: Capsule())
    }
}

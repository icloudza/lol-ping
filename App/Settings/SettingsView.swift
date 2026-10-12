import LPCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case gesture, shortcut, look, wheel, emotes, room, general

    var id: String { rawValue }

    /// A filled symbol that sits well in a small square tile; none of them is wider than it is tall.
    var symbol: String {
        switch self {
        case .gesture: return "cursorarrow.click.2"
        case .shortcut: return "keyboard.fill"
        case .look: return "speaker.wave.2.fill"
        case .wheel: return "chart.pie.fill"
        case .emotes: return "face.smiling.inverse"
        case .room: return "person.2.fill"
        case .general: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .gesture: return .blue
        case .shortcut: return Color(nsColor: .systemGray)
        case .look: return .pink
        case .wheel: return .orange
        case .emotes: return .yellow
        case .room: return .green
        case .general: return Color(nsColor: .systemGray)
        }
    }

    func title(_ t: L10n) -> String {
        switch self {
        case .gesture: return t.paneGesture
        case .shortcut: return t.paneShortcut
        case .look: return t.paneLook
        case .wheel: return t.paneWheel
        case .emotes: return t.paneEmotes
        case .room: return t.paneRoom
        case .general: return t.paneGeneral
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppController
    @State private var pane: SettingsPane

    init(pane: SettingsPane = .gesture) { _pane = State(initialValue: pane) }

    var body: some View {
        let t = app.text
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if app.access != .granted { AccessCard() }
                    StatusCard()
                    Text(pane.title(t)).font(.title2.weight(.semibold)).padding(.top, 6)
                    switch pane {
                    case .gesture: GesturePane()
                    case .shortcut: ShortcutPane()
                    case .look: LookPane()
                    case .wheel: PingWheelPane()
                    case .emotes: EmotesPane()
                    case .room: RoomPane()
                    case .general: GeneralPane()
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 480)
        .onReceive(app.$paneRequest) { request in
            if let request, let wanted = SettingsPane(rawValue: request.pane) { pane = wanted }
        }
    }

    /// The mark, the app's name and its tagline, at the top of the sidebar.
    struct BrandHeader: View {
        let tagline: String

        var body: some View {
            HStack(spacing: 10) {
                if let mark = BrandMark.image(pixels: 160) {
                    Image(decorative: mark, scale: 4).interpolation(.high)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.appName).font(.headline)
                    Text(tagline).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A sidebar of fixed width: nothing to collapse, nothing to drag.
    private var sidebar: some View {
        let t = app.text
        return VStack(alignment: .leading, spacing: 2) {
            BrandHeader(tagline: t.tagline)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            ForEach(SettingsPane.allCases) { entry in
                SidebarRow(pane: entry, title: entry.title(t), selected: entry == pane) { pane = entry }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .frame(width: 210)
        .background(SidebarBackground().ignoresSafeArea())
    }
}

/// A sidebar entry: a white symbol on a coloured tile (all tiles the same size), then the pane's name.
private struct SidebarRow: View {
    let pane: SettingsPane
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Building blocks

/// One of the ping pictures that ship with the app.
struct TextureImage: View {
    let name: String
    var body: some View {
        if let image = ImageStore.shared.texture(name) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
        }
    }
}

/// A rounded panel holding a group of rows.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

/// A small heading above a card, for panes that hold several groups.
struct SectionLabel: View {
    let title: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let hint { Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }
}

/// A row: its name and an explanation on the left, a control on the right. The control always ends at the same
/// right edge, so give it its natural size rather than a wider frame.
struct Row<Control: View>: View {
    let title: String
    var hint: String?
    /// A second line under the hint; drawn in red when `isWarning`.
    var note: String?
    var isWarning = false
    var dimmed = false
    /// A small picture in front of the name.
    var image: CGImage?
    /// A short tag after the name.
    var badge: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge {
                        Text(badge).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                if let hint { Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let note {
                    Text(note).font(.callout).foregroundStyle(isWarning ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(dimmed ? 0.5 : 1)
    }
}

struct SwitchRow: View {
    let title: String
    var hint: String?
    var dimmed = false
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, hint: hint, dimmed: dimmed) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct SliderRow: View {
    let title: String
    var hint: String?
    let range: ClosedRange<Double>
    var step: Double = 1
    var dimmed = false
    @Binding var value: Double
    let label: (Double) -> String

    var body: some View {
        Row(title: title, hint: hint, dimmed: dimmed) {
            SteppedSlider(value: $value, range: range, step: step).frame(width: 200)
            Text(label(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }
}

/// A slider that moves in steps without drawing a row of tick marks under its track (which a stepped `Slider` does).
struct SteppedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        Slider(value: Binding(get: { value }, set: { moved in
            let snapped = (moved / step).rounded() * step
            // Rounded once more so 0.1 steps don't pick up binary dust like 3.2000000000000006.
            let tidy = (snapped * 100).rounded() / 100
            if tidy != value { value = min(range.upperBound, max(range.lowerBound, tidy)) }
        }), in: range)
    }
}

/// A tinted panel for something that wants attention.
struct NoticeCard<Content: View>: View {
    let symbol: String
    var tint: Color = .orange
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) { content }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }
}

extension AppController {
    /// A two-way link to one preference, for controls.
    func binding<T>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.preferences[keyPath: keyPath] }, set: { value in self.change { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Cards above every pane

/// The master switch, with a line saying how to use the app right now.
struct StatusCard: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        let t = app.text, p = app.preferences
        let blocked = app.access != .granted
        let title = blocked ? t.statusNeedsAccess : app.isEnabled ? t.statusOn : t.statusPaused
        let hint = blocked ? t.statusNeedsAccessHint
            : t.statusHint(trigger: t.triggerName(p.ping.trigger), sideButton: p.ping.trigger.isSideButton, shortcut: p.hotkeys[.toggleEnabled]?.title, on: app.isEnabled)
        Card {
            HStack(spacing: 12) {
                Circle().fill(blocked ? Color.orange : app.isEnabled ? Color.green : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if !blocked {
                    Toggle("", isOn: Binding(get: { app.isEnabled }, set: { app.setEnabled($0) })).labelsHidden().toggleStyle(.switch).controlSize(.large)
                }
            }
            .padding(14)
        }
    }
}

/// Shown until the app is allowed under Accessibility. The permissions window has the steps.
struct AccessCard: View {
    @EnvironmentObject var app: AppController

    var body: some View {
        let t = app.text
        NoticeCard(symbol: "lock.shield") {
            Text(t.statusNeedsAccess).font(.headline)
            Text(t.accessCardHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(t.viewPermissions) { app.showPermissions() }.buttonStyle(.borderedProminent).padding(.top, 4)
        }
    }
}

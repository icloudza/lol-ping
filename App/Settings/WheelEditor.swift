import LPCore
import SwiftUI
import UniformTypeIdentifiers

/// Something that can be put on a wheel: a ping or an emote.
struct LibraryItem: Identifiable {
    let id: String
    let image: CGImage?
    let name: String
    /// A small label on its tile.
    var badge: String?
    /// Present for the user's own pictures: adds a remove button to the tile.
    var remove: (() -> Void)?
}

/// Edits a wheel: a miniature of it on the left, every available item on the right.
///
/// Drag an item onto a slice, or onto the middle to make it the trigger + click item. Slices can be dragged onto each
/// other. Everything also works with two clicks: one to pick something up, one to put it down.
struct WheelEditor<Footer: View>: View {
    @EnvironmentObject var app: AppController
    let arrangement: WheelArrangement
    /// The middle is drawn faint when trigger + click isn't switched on.
    let quickIsActive: Bool
    let triggerName: String
    let library: [LibraryItem]
    let standard: WheelArrangement
    let title: String
    let hint: String
    let libraryTitle: String
    var roundImages = false
    /// A long library scrolls inside this height; nil lays every tile out.
    var libraryHeight: CGFloat?
    /// Set to accept image files dropped on the library.
    var onFilesDropped: (([URL]) -> Void)?
    let onChange: (WheelArrangement) -> Void
    let onTry: (String) -> Void
    @ViewBuilder var footer: Footer

    @State private var held: WheelArrangement.Origin?
    @State private var dragged: WheelArrangement.Origin?
    @State private var target: WheelArrangement.Destination?
    @State private var filesHovering = false

    private let side: CGFloat = 300
    private let hubRadius: CGFloat = 52
    private let rimRadius: CGFloat = 146
    private let imageRadius: CGFloat = 100

    private func entry(_ id: String) -> LibraryItem? { library.first { $0.id == id } }
    private func name(_ id: String) -> String { entry(id)?.name ?? "?" }

    private func move(_ origin: WheelArrangement.Origin, to destination: WheelArrangement.Destination) {
        if let next = arrangement.moving(origin, to: destination) { onChange(next) }
        held = nil
    }

    /// A click on a slice or the middle puts down what is held, or picks up what is there.
    private func clicked(_ destination: WheelArrangement.Destination, holding here: WheelArrangement.Origin) {
        if let held { move(held, to: destination) } else { held = here }
    }

    private func beginDrag(_ origin: WheelArrangement.Origin) -> NSItemProvider {
        dragged = origin
        return NSItemProvider(object: arrangement.item(at: origin) as NSString)
    }

    private func drop(on destination: WheelArrangement.Destination) -> some DropDelegate {
        WheelDrop(destination: destination, dragged: $dragged, target: $target) { origin in move(origin, to: destination) }
    }

    var body: some View {
        let t = app.text
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(t.resetWheel) {
                    held = nil
                    onChange(standard)
                }
                .disabled(arrangement == standard)
            }
            .padding(14)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                miniature
                shelf
            }
            .padding(14)
            Text(held.map { t.pickedHint(name(arrangement.item(at: $0))) } ?? " ")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .onExitCommand { held = nil }
    }

    private var miniature: some View {
        let t = app.text
        return ZStack {
            ForEach(arrangement.slices.indices, id: \.self) { i in
                SliceShape(index: i, inner: hubRadius, outer: rimRadius)
                    .fill(target == .slice(i) ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.09))
                    .contentShape(SliceShape(index: i, inner: hubRadius, outer: rimRadius))
                    .onTapGesture { clicked(.slice(i), holding: .slice(i)) }
                    .onDrop(of: [.plainText], delegate: drop(on: .slice(i)))
            }
            ForEach(arrangement.slices.indices, id: \.self) { i in
                let angle = CGFloat(i) * .pi / 4
                ItemImage(image: entry(arrangement.slices[i])?.image, round: roundImages)
                    .frame(width: 46, height: 46)
                    .padding(4)
                    .background(Circle().strokeBorder(Color.accentColor, lineWidth: held == .slice(i) ? 2 : 0))
                    .contentShape(Circle())
                    .help(t.sliceTooltip(i, name(arrangement.slices[i])))
                    .onTapGesture { clicked(.slice(i), holding: .slice(i)) }
                    .onDrag { beginDrag(.slice(i)) }
                    .onDrop(of: [.plainText], delegate: drop(on: .slice(i)))
                    .position(x: side / 2 + imageRadius * sin(angle), y: side / 2 - imageRadius * cos(angle))
            }
            VStack(spacing: 2) {
                ItemImage(image: entry(arrangement.quick)?.image, round: roundImages).frame(width: 40, height: 40)
                Text(t.quickCaption).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: hubRadius * 2 - 10, height: hubRadius * 2 - 10)
            .background(Circle().fill(target == .quick ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.09)))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: held == .quick ? 2 : 0))
            .opacity(quickIsActive ? 1 : 0.45)
            .contentShape(Circle())
            .help(t.quickTooltip(triggerName, name(arrangement.quick)))
            .onTapGesture { clicked(.quick, holding: .quick) }
            .onDrag { beginDrag(.quick) }
            .onDrop(of: [.plainText], delegate: drop(on: .quick))
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private func scrolling<Tiles: View>(@ViewBuilder _ tiles: () -> Tiles) -> some View {
        if let libraryHeight { ScrollView { tiles() }.frame(height: libraryHeight) } else { tiles() }
    }

    private var shelf: some View {
        let t = app.text
        return VStack(alignment: .leading, spacing: 6) {
            Text(libraryTitle).font(.headline)
            Text(t.libraryHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            scrolling {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                    ForEach(library) { item in
                        let origin = WheelArrangement.Origin.library(item.id)
                        let slice = arrangement.slices.firstIndex(of: item.id)
                        VStack(spacing: 4) {
                            ItemImage(image: item.image, round: roundImages).frame(width: 40, height: 40)
                            Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: held == origin ? 2 : 0))
                        .overlay(alignment: .topLeading) {
                            if let slice {
                                Text(t.sliceNames[slice]).font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.25), in: Capsule()).padding(4)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if let remove = item.remove {
                                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).padding(3).help(t.removeImage(item.name))
                            } else if let badge = item.badge {
                                Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.orange, in: Capsule()).padding(4)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            onTry(item.id)
                            held = held == origin ? nil : origin
                        }
                        .onDrag { beginDrag(origin) }
                    }
                }
                .padding(2)
            }
            footer
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: filesHovering ? 2 : 0, dash: [6])))
        .onDrop(of: onFilesDropped == nil ? [] : [.fileURL], isTargeted: $filesHovering) { providers in
            guard let onFilesDropped else { return false }
            var files: [URL] = []
            let all = DispatchGroup()
            for provider in providers {
                all.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { files.append(url) }
                        all.leave()
                    }
                }
            }
            all.notify(queue: .main) { onFilesDropped(files) }
            return true
        }
    }
}

private struct WheelDrop: DropDelegate {
    let destination: WheelArrangement.Destination
    @Binding var dragged: WheelArrangement.Origin?
    @Binding var target: WheelArrangement.Destination?
    let land: (WheelArrangement.Origin) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragged != nil }
    func dropEntered(info: DropInfo) { if dragged != nil { target = destination } }
    func dropExited(info: DropInfo) { if target == destination { target = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let origin = dragged else { return false }
        dragged = nil
        land(origin)
        return true
    }
}

/// One of the miniature's eight slices; index 0 points up and the rest follow clockwise.
private struct SliceShape: Shape {
    let index: Int
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let gap = 0.035
        let from = (Double(index) - 0.5) * .pi / 4 + gap - .pi / 2
        let to = (Double(index) + 0.5) * .pi / 4 - gap - .pi / 2
        var path = Path()
        path.addArc(center: centre, radius: inner, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
        path.addArc(center: centre, radius: outer, startAngle: .radians(to), endAngle: .radians(from), clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct ItemImage: View {
    let image: CGImage?
    var round = false

    var body: some View {
        if let image {
            let picture = Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
            if round { picture.clipShape(Circle()) } else { picture }
        } else {
            Image(systemName: "questionmark.circle").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

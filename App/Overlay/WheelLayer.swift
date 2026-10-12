import AppKit
import LPCore

/// What one slice of a wheel holds.
struct WheelItem {
    /// Handed back when the slice is chosen.
    let key: String
    /// Shown in the hub while the slice is pointed at.
    let title: String
    /// The colour of that title; nil for the wheel's neutral cream.
    let tint: UInt32?
    /// The badge while the slice is not pointed at, and while it is.
    let resting: CGImage?
    let lit: CGImage?
}

/// The wheel that appears under the pointer: a dark hub ringed in gold, eight dark slices around it, the slice being
/// pointed at lit in cyan, and a short arc on the hub's rim that follows the pointer.
///
/// The layer is a 640 pt square whose centre sits where the button went down. Its coordinates are y-down.
final class WheelLayer: CALayer {
    private enum Look {
        static let side: CGFloat = 640
        static let hub = WheelMetrics.hubRadius
        /// Where the four diagonal slices end.
        static let ring: Double = 206
        /// How far the four straight slices fade out to.
        static let reach = WheelMetrics.reachRadius
        static let badgeRadius = WheelMetrics.badgeRadius
        static let badgeLitScale: CGFloat = 1.3
        static let gold: UInt32 = 0xc8aa6e
        static let cream: UInt32 = 0xd9cba3
        static let cyan: UInt32 = 0x35d6dc
    }

    /// Called with the slice's index when the pointer crosses onto another slice.
    var onSliceChanged: ((Int) -> Void)?
    private(set) var isShowing = false

    private let kind: WheelKind
    private let scale: CGFloat
    /// Ping badges are small glyphs; emote art has more to show and gets more room.
    private var badgeSide: CGFloat { kind == .ping ? 38 : 50 }
    private var items: [WheelItem] = []
    private var idleTitle = ""
    private var litSlice: Int?
    private var origin = CGPoint.zero

    private var glows: [CALayer] = []
    private var badges: [CALayer] = []
    private var restingBadges: [CALayer] = []
    private var litBadges: [CALayer] = []
    private let pointerArc = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let backLayer = CATextLayer()

    init(kind: WheelKind, scale: CGFloat) {
        self.kind = kind
        self.scale = scale
        super.init()
        bounds = CGRect(x: 0, y: 0, width: Look.side, height: Look.side)
        opacity = 0
        transform = CATransform3DMakeScale(0.88, 0.88, 1)
        actions = ["position": NSNull()]
        assemble()
    }

    override init(layer: Any) {
        let other = layer as? WheelLayer
        kind = other?.kind ?? .ping
        scale = other?.scale ?? 2
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// The eight slices, starting at the top and going clockwise.
    func setItems(_ newItems: [WheelItem]) {
        items = newItems
        withoutAnimation {
            for i in badges.indices {
                let item = i < newItems.count ? newItems[i] : nil
                restingBadges[i].contents = item?.resting
                litBadges[i].contents = item?.lit
            }
        }
        refreshTitle()
    }

    /// The hub's text: what it says while nothing is pointed at, and the label beside the mouse glyph.
    func setLabels(idle: String, back: String) {
        idleTitle = idle
        withoutAnimation {
            backLayer.string = NSAttributedString(string: back, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .kern: 0.6, .foregroundColor: NSColor.hex(0x7c8a8c),
            ])
        }
        refreshTitle()
    }

    // MARK: - Gesture

    func show(at point: CGPoint) {
        origin = point
        withoutAnimation {
            position = point
            pointerArc.opacity = 0
        }
        light(nil)
        isShowing = true
        fade(in: true)
    }

    func pointerMoved(to point: CGPoint) {
        guard isShowing else { return }
        let dx = point.x - origin.x, dy = point.y - origin.y
        withoutAnimation {
            // The arc turns smoothly with the pointer; it is not tied to the slices.
            pointerArc.opacity = (dx * dx + dy * dy).squareRoot() > 14 ? 1 : 0
            pointerArc.transform = CATransform3DMakeRotation(atan2(dy, dx), 0, 0, 1)
        }
        light(WheelMetrics.slice(dx: dx, dy: dy))
    }

    /// Hides the wheel and says what was chosen: nil when the pointer was over the hub.
    func release(at point: CGPoint) -> (key: String, at: CGPoint)? {
        guard isShowing else { return nil }
        let slice = WheelMetrics.slice(dx: point.x - origin.x, dy: point.y - origin.y)
        hide()
        guard let slice, slice < items.count else { return nil }
        return (items[slice].key, origin)
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        fade(in: false)
        light(nil)
    }

    private func fade(in showing: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.11)
        CATransaction.setAnimationTimingFunction(Anim.easeOut)
        opacity = showing ? 1 : 0
        transform = showing ? CATransform3DIdentity : CATransform3DMakeScale(0.88, 0.88, 1)
        CATransaction.commit()
    }

    private func light(_ slice: Int?) {
        guard slice != litSlice else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        if let old = litSlice { style(old, lit: false) }
        litSlice = slice
        if let slice { style(slice, lit: true) }
        CATransaction.commit()
        refreshTitle()
        if let slice, isShowing { onSliceChanged?(slice) }
    }

    private func style(_ i: Int, lit: Bool) {
        glows[i].opacity = lit ? 1 : 0
        badges[i].transform = lit ? CATransform3DMakeScale(Look.badgeLitScale, Look.badgeLitScale, 1) : CATransform3DIdentity
        restingBadges[i].opacity = lit ? 0 : 1
        litBadges[i].opacity = lit ? 1 : 0
    }

    private func refreshTitle() {
        let item = litSlice.flatMap { $0 < items.count ? items[$0] : nil }
        let text = item?.title ?? idleTitle
        let color = NSColor.hex(item.map { $0.tint ?? Look.cream } ?? Look.cream, alpha: item == nil ? 0.75 : 1)
        // Long names shrink a little so they stay inside the hub.
        let size: CGFloat = text.count > 9 ? 14 : 17
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        withoutAnimation {
            titleLayer.string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold), .kern: 0.8, .foregroundColor: color, .shadow: shadow,
            ])
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    // MARK: - Drawing

    /// A point at `radius` from the centre; 0° is up and angles grow clockwise.
    private static func spoke(_ radius: Double, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: radius * sin(a), y: -radius * cos(a))
    }

    /// The outline of a slice between two radii, `halfWidth` degrees either side of straight up.
    private static func slicePath(from inner: Double, to outer: Double, halfWidth: Double) -> CGPath {
        let path = CGMutablePath()
        // In y-down coordinates "up" is -90° for Core Graphics, and its angles also grow clockwise on screen.
        let start = (-90 - halfWidth) * .pi / 180, end = (-90 + halfWidth) * .pi / 180
        path.addArc(center: .zero, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: .zero, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private static func gradient(_ stops: [(Double, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray, locations: stops.map { CGFloat($0.0) })!
    }

    /// Renders into a bitmap covering `rect` (points, y-down, origin at the wheel's centre).
    private func render(_ rect: CGRect, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = Int((rect.width * scale).rounded(.up)), h = Int((rect.height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        draw(ctx)
        return ctx.makeImage()
    }

    private static func fill(_ ctx: CGContext, _ path: CGPath, with gradient: CGGradient, radius: Double) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// A layer holding a picture of one slice (drawn pointing up), pivoting on the wheel's centre so it can be turned
    /// to any of the eight directions.
    private func sliceLayer(_ path: CGPath, turnedTo index: Int, draw: @escaping (CGContext) -> Void) -> CALayer {
        let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2).integral
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: box.size)
        layer.anchorPoint = CGPoint(x: -box.minX / box.width, y: -box.minY / box.height)
        layer.position = CGPoint(x: Look.side / 2, y: Look.side / 2)
        layer.contentsScale = scale
        layer.contents = render(box, draw)
        layer.transform = CATransform3DMakeRotation(CGFloat(index) * .pi / 4, 0, 0, 1)
        return layer
    }

    private func assemble() {
        let centre = CGPoint(x: Look.side / 2, y: Look.side / 2)
        let hub = Look.hub, ring = Look.ring, reach = Look.reach
        let gap = 0.5 // degrees shaved off each side, so neighbouring slices don't overlap under the dividing lines

        // Slices. Straight ones (up, right, down, left) are long and fade away; diagonal ones are shorter and solid.
        let longPath = Self.slicePath(from: hub, to: reach, halfWidth: 22.5 - gap)
        let shortPath = Self.slicePath(from: hub, to: ring, halfWidth: 22.5 - gap)
        let longShade = Self.gradient([(hub / reach, CGColor(gray: 0.02, alpha: 0.52)), (ring / reach, CGColor(gray: 0.02, alpha: 0.36)), (1, CGColor(gray: 0.02, alpha: 0))])
        let shortShade = Self.gradient([(hub / ring, CGColor(gray: 0.02, alpha: 0.60)), (0.93, CGColor(gray: 0.02, alpha: 0.54)), (1, CGColor(gray: 0.02, alpha: 0.34))])
        for i in 0..<WheelMetrics.sliceCount {
            let straight = i % 2 == 0
            addSublayer(sliceLayer(straight ? longPath : shortPath, turnedTo: i) { ctx in
                straight ? Self.fill(ctx, longPath, with: longShade, radius: reach) : Self.fill(ctx, shortPath, with: shortShade, radius: ring)
            })
        }

        // The cyan wash of the slice being pointed at: faint by the hub, strongest towards its outer edge.
        let cyan = Look.cyan
        let longGlow = Self.gradient([(hub / reach, .hex(0x127f88, alpha: 0.42)), (ring / reach * 0.9, .hex(cyan, alpha: 0.78)), (1, .hex(cyan, alpha: 0))])
        let shortGlow = Self.gradient([(hub / ring, .hex(0x127f88, alpha: 0.42)), (0.9, .hex(cyan, alpha: 0.80)), (1, .hex(cyan, alpha: 0.62))])
        for i in 0..<WheelMetrics.sliceCount {
            let straight = i % 2 == 0
            let glow = sliceLayer(straight ? longPath : shortPath, turnedTo: i) { ctx in
                straight ? Self.fill(ctx, longPath, with: longGlow, radius: reach) : Self.fill(ctx, shortPath, with: shortGlow, radius: ring)
            }
            glow.opacity = 0
            addSublayer(glow)
            glows.append(glow)
        }

        // Thin gold lines between the slices, brightest at the hub.
        let lines = CAGradientLayer()
        lines.type = .radial
        lines.frame = bounds
        lines.startPoint = CGPoint(x: 0.5, y: 0.5)
        lines.endPoint = CGPoint(x: 1, y: 1)
        let half = Double(Look.side / 2)
        lines.colors = [CGColor.hex(Look.gold, alpha: 0.85), CGColor.hex(Look.gold, alpha: 0.85), CGColor.hex(Look.gold, alpha: 0.35), CGColor.hex(Look.gold, alpha: 0)]
        lines.locations = [0, NSNumber(value: hub / half), NSNumber(value: ring / half), NSNumber(value: (ring + 40) / half)]
        let spokes = CAShapeLayer()
        spokes.frame = bounds
        let spokePath = CGMutablePath()
        for i in 0..<WheelMetrics.sliceCount {
            let angle = Double(i) * 45 + 22.5
            let a = Self.spoke(hub, angle), b = Self.spoke(ring + 40, angle)
            spokePath.move(to: CGPoint(x: centre.x + a.x, y: centre.y + a.y))
            spokePath.addLine(to: CGPoint(x: centre.x + b.x, y: centre.y + b.y))
        }
        spokes.path = spokePath
        spokes.strokeColor = CGColor(gray: 1, alpha: 1)
        spokes.lineWidth = 1.3
        spokes.contentsScale = scale
        lines.mask = spokes
        addSublayer(lines)

        // Badges.
        for i in 0..<WheelMetrics.sliceCount {
            let p = Self.spoke(Look.badgeRadius, Double(i) * 45)
            let badge = CALayer()
            badge.bounds = CGRect(x: 0, y: 0, width: badgeSide, height: badgeSide)
            badge.position = CGPoint(x: centre.x + p.x, y: centre.y + p.y)
            badge.shadowColor = .black
            badge.shadowOpacity = 0.55
            badge.shadowRadius = 3
            badge.shadowOffset = CGSize(width: 0, height: 1)
            let resting = CALayer(), lit = CALayer()
            for layer in [resting, lit] {
                layer.frame = badge.bounds
                layer.contentsGravity = .resizeAspect
                layer.contentsScale = scale
                if kind == .emote { // emote art is square: show it as a disc
                    layer.cornerRadius = badgeSide / 2
                    layer.masksToBounds = true
                }
                badge.addSublayer(layer)
            }
            lit.opacity = 0
            addSublayer(badge)
            badges.append(badge)
            restingBadges.append(resting)
            litBadges.append(lit)
        }

        // The hub: a near-black disc with a gold rim and a dark outline around that.
        let rim = hub + 7
        let hubLayer = CALayer()
        hubLayer.frame = CGRect(x: centre.x - rim, y: centre.y - rim, width: rim * 2, height: rim * 2)
        hubLayer.contentsScale = scale
        hubLayer.contents = render(CGRect(x: -rim, y: -rim, width: rim * 2, height: rim * 2)) { ctx in
            func circle(_ r: Double) -> CGRect { CGRect(x: -r, y: -r, width: r * 2, height: r * 2) }
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: circle(hub + 3))
            ctx.saveGState()
            ctx.addEllipse(in: circle(hub))
            ctx.clip()
            ctx.drawRadialGradient(Self.gradient([(0, .hex(0x14191b, alpha: 0.96)), (1, .hex(0x07090a, alpha: 0.96))]),
                                   startCenter: CGPoint(x: 0, y: -18), startRadius: 0, endCenter: .zero, endRadius: hub, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
            ctx.setStrokeColor(.hex(Look.gold))
            ctx.setLineWidth(2.6)
            ctx.strokeEllipse(in: circle(hub))
            ctx.setStrokeColor(.hex(0x6f5f3c, alpha: 0.55))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: circle(hub - 5))
            // A mouse with its right button filled in, beside the "back" label.
            ctx.translateBy(x: -26, y: 30)
            ctx.setStrokeColor(.hex(0x7c8a8c, alpha: 0.8))
            ctx.setLineWidth(1.3)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 11, height: 16), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
            ctx.strokePath()
            let button = CGMutablePath()
            button.move(to: CGPoint(x: 5.5, y: 0.4))
            button.addLine(to: CGPoint(x: 5.5, y: 7))
            button.addLine(to: CGPoint(x: 10.6, y: 7))
            button.addLine(to: CGPoint(x: 10.6, y: 5.5))
            button.addArc(center: CGPoint(x: 5.5, y: 5.5), radius: 5.1, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
            button.closeSubpath()
            ctx.setFillColor(.hex(0x7c8a8c, alpha: 0.8))
            ctx.addPath(button)
            ctx.fillPath()
        }
        addSublayer(hubLayer)

        // The arc on the rim that points at the pointer. Drawn facing right; turned by the pointer's angle.
        pointerArc.bounds = CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2)
        pointerArc.position = centre
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: hub - 9, startAngle: -0.30, endAngle: 0.30, clockwise: false)
        pointerArc.path = arc
        pointerArc.strokeColor = .hex(Look.cyan)
        pointerArc.fillColor = nil
        pointerArc.lineWidth = 3.4
        pointerArc.lineCap = .round
        pointerArc.shadowColor = .hex(Look.cyan)
        pointerArc.shadowOpacity = 0.9
        pointerArc.shadowRadius = 4
        pointerArc.shadowOffset = .zero
        pointerArc.opacity = 0
        pointerArc.contentsScale = scale
        addSublayer(pointerArc)

        titleLayer.frame = CGRect(x: centre.x - hub + 12, y: centre.y - 17, width: (hub - 12) * 2, height: 24)
        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .end
        titleLayer.contentsScale = scale
        addSublayer(titleLayer)

        backLayer.frame = CGRect(x: centre.x - 9, y: centre.y + 31, width: 70, height: 16)
        backLayer.alignmentMode = .left
        backLayer.contentsScale = scale
        addSublayer(backLayer)
    }
}

import AppKit
import LPCore
import LPRooms

/// A room member's name under a ping or emote.
struct NameTag {
    let name: String
    /// Which of the eight tag colours.
    let color: Int
}

enum PingFX {
    /// With more than this many on one display the oldest are dropped early, so a flood can't choke the overlay.
    static let maxPings = 60

    /// Adds one animated ping at `point` and removes it when its animation ends.
    static func spawn(in layer: CALayer, ping def: Ping, at point: CGPoint, size s: CGFloat, duration d: Double, tag: NameTag?, scale: CGFloat) {
        let color = CGColor.hex(def.tint)
        let root = CALayer()
        root.position = point
        root.actions = ["sublayers": NSNull()]

        // A soft coloured ellipse on the ground under the art.
        let ground = CAGradientLayer()
        ground.type = .radial
        ground.frame = CGRect(x: -0.42 * s, y: 0.2 * s, width: 0.84 * s, height: 0.24 * s)
        ground.colors = [color, CGColor.hex(def.tint, alpha: 0)]
        ground.startPoint = CGPoint(x: 0.5, y: 0.5)
        ground.endPoint = CGPoint(x: 1, y: 1)
        ground.opacity = 0
        root.addSublayer(ground)
        ground.add(Anim.keyframes("opacity", values: [0, 0.75, 0.55, 0], keyTimes: [0, 0.1, 0.85, 1], duration: d, timing: Anim.easeOut, in: ground), forKey: "ground")

        // Rings expand and fade at 0, 220 ms and 1.4 s.
        for delay in [0, 0.22, 1.4] {
            let ring = CAShapeLayer()
            let side = 1.09 * s
            ring.frame = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = color
            ring.lineWidth = 3
            ring.shadowColor = color
            ring.shadowOpacity = 1
            ring.shadowRadius = 8
            ring.shadowOffset = .zero
            ring.opacity = 0
            ring.contentsScale = scale
            root.addSublayer(ring)
            ring.add(Anim.keyframes("opacity", values: [0.95, 0], keyTimes: [0, 1], duration: 0.65, delay: delay, timing: Anim.easeOut, fill: .forwards, in: ring), forKey: "fade")
            ring.add(Anim.keyframes("transform.scale", values: [0.25, 1.35], keyTimes: [0, 1], duration: 0.65, delay: delay, timing: Anim.easeOut, in: ring), forKey: "grow")
        }

        // The art, anchored so the ground ellipse sits on the press point.
        let art = CALayer()
        art.frame = CGRect(x: -0.5 * s, y: -0.73 * s, width: s, height: s)
        root.addSublayer(art)
        art.add(life(d, in: art), forKey: "life")

        func picture(_ name: String) -> CALayer {
            let img = CALayer()
            img.frame = art.bounds
            img.contents = ImageStore.shared.texture(name)
            img.contentsGravity = .resize
            img.contentsScale = scale
            img.shadowColor = color // a glow in the ping's colour
            img.shadowOpacity = 1
            img.shadowRadius = 5
            img.shadowOffset = .zero
            return img
        }
        let bob: (CALayer, Double) -> Void = { layer, delay in
            layer.add(Anim.keyframes("transform.translation.y", values: [0, -5, 0], keyTimes: [0, 0.5, 1], duration: 1.6, delay: delay,
                                     timing: Anim.easeInOut, fill: .removed, repeats: true, additive: true, in: layer), forKey: "bob")
        }

        if def.isTwoPart {
            // All In: two halves slide in from opposite diagonals and clash, with a flash and a shake.
            let clash = CALayer()
            clash.frame = art.bounds
            art.addSublayer(clash)
            let slideTiming = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
            for (name, dx) in [(def.art[0], 0.64 * s), (def.art[1], -0.64 * s)] {
                let half = picture(name)
                clash.addSublayer(half)
                half.add(Anim.keyframes("transform.translation.x", values: [dx, 0], keyTimes: [0, 1], duration: 0.22, timing: slideTiming, additive: true, in: half), forKey: "slideX")
                half.add(Anim.keyframes("transform.translation.y", values: [-0.64 * s, 0], keyTimes: [0, 1], duration: 0.22, timing: slideTiming, additive: true, in: half), forKey: "slideY")
                half.add(Anim.keyframes("opacity", values: [0, 1], keyTimes: [0, 1], duration: 0.22, timing: slideTiming, in: half), forKey: "in")
            }
            clash.add(Anim.keyframes("transform.translation.x", values: [0, -3, 3, -2, 0], keyTimes: [0, 0.25, 0.5, 0.75, 1], duration: 0.25, delay: 0.22, additive: true, in: clash), forKey: "shakeX")
            clash.add(Anim.keyframes("transform.translation.y", values: [0, 2, -2, -1, 0], keyTimes: [0, 0.25, 0.5, 0.75, 1], duration: 0.25, delay: 0.22, additive: true, in: clash), forKey: "shakeY")
            bob(clash, 0.5)

            let flash = CAGradientLayer()
            flash.type = .radial
            flash.frame = CGRect(x: 0.25 * s, y: 0.25 * s, width: 0.5 * s, height: 0.5 * s)
            flash.colors = [CGColor.hex(0xffffff), color, CGColor.hex(def.tint, alpha: 0)]
            flash.locations = [0, 0.4, 1]
            flash.startPoint = CGPoint(x: 0.5, y: 0.5)
            flash.endPoint = CGPoint(x: 1, y: 1)
            flash.opacity = 0
            art.addSublayer(flash)
            flash.add(Anim.keyframes("opacity", values: [0, 1, 0], keyTimes: [0, 0.3, 1], duration: 0.35, delay: 0.2, timing: Anim.easeOut, fill: .forwards, in: flash), forKey: "flash")
            flash.add(Anim.keyframes("transform.scale", values: [0.3, 2.2], keyTimes: [0, 1], duration: 0.35, delay: 0.2, timing: Anim.easeOut, in: flash), forKey: "grow")
        } else {
            // Pop in with an overshoot, then bob gently.
            let pop = CALayer()
            pop.frame = art.bounds
            pop.addSublayer(picture(def.art.first ?? PingCatalog.standInTexture))
            art.addSublayer(pop)
            let overshoot = CAMediaTimingFunction(controlPoints: 0.2, 1.6, 0.4, 1)
            pop.add(Anim.keyframes("transform.scale", values: [0.4, 1.15, 1], keyTimes: [0, 0.6, 1], duration: 0.28, timing: overshoot, in: pop), forKey: "pop")
            pop.add(Anim.keyframes("opacity", values: [0, 1, 1], keyTimes: [0, 0.6, 1], duration: 0.28, timing: overshoot, in: pop), forKey: "in")
            bob(pop, 0.3)
        }

        if let tag { root.addSublayer(tagLayer(tag, top: 0.5 * s, duration: d, scale: scale)) }

        while (layer.sublayers?.count ?? 0) >= maxPings { layer.sublayers?.first?.removeFromSuperlayer() }
        layer.addSublayer(root)
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.15) { root.removeFromSuperlayer() }
    }

    /// Fully visible, then fading out over the last 13% of the duration.
    static func life(_ d: Double, in layer: CALayer) -> CAAnimation {
        Anim.keyframes("opacity", values: [1, 1, 0], keyTimes: [0, 0.87, 1], duration: d, in: layer)
    }

    /// The name tag, centred under the art. The text is never interpreted: the name comes from another machine.
    static func tagLayer(_ tag: NameTag, top: CGFloat, duration d: Double, scale: CGFloat) -> CALayer {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let string = NSAttributedString(string: tag.name, attributes: [
            .font: font, .kern: 0.2, .foregroundColor: NSColor.hex(TagColors.color(tag.color)), .shadow: shadow,
        ])
        let textWidth = min(206, ceil(string.size().width))
        let box = CALayer()
        box.bounds = CGRect(x: 0, y: 0, width: textWidth + 14, height: 20)
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        box.position = CGPoint(x: 0, y: top)
        box.cornerRadius = 4
        box.backgroundColor = CGColor(srgbRed: 8 / 255, green: 12 / 255, blue: 16 / 255, alpha: 0.62)
        let text = CATextLayer()
        text.frame = CGRect(x: 7, y: 1, width: textWidth, height: 18)
        text.string = string
        text.truncationMode = .end
        text.contentsScale = scale
        box.addSublayer(text)
        box.add(Anim.keyframes("transform.translation.y", values: [4, 0], keyTimes: [0, 1], duration: 0.25, timing: Anim.easeOut, fill: .removed, additive: true, in: box), forKey: "in")
        box.add(life(d, in: box), forKey: "life")
        return box
    }
}

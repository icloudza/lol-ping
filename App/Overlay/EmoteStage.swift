import AppKit
import LPCore

/// The emotes showing on one display. Each sender ("self", "preview", or a room member's id) has at most one at a
/// time: a new one replaces theirs.
final class EmoteStage {
    private final class Live {
        let root: CALayer
        var player: FramePlayer?
        var gone = false
        init(root: CALayer) { self.root = root }
    }

    /// How long an emote stays up, in seconds. The bundled animations are made to this length.
    static let duration: Double = 3

    private let layer: CALayer
    private let scale: CGFloat
    private var live: [String: Live] = [:]
    /// The bundled animations' files, read once each.
    private static var files: [String: Data] = [:]

    init(layer: CALayer, scale: CGFloat) {
        self.layer = layer
        self.scale = scale
    }

    /// Shows `art` centred on `point`, replacing the owner's emote if it has one on screen.
    func spawn(owner: String, art: EmoteArt, at point: CGPoint, size s: CGFloat, tag: NameTag?) {
        clear(owner: owner)
        let d = Self.duration
        let root = CALayer()
        root.position = point
        let entry = Live(root: root)
        live[owner] = entry

        switch art {
        case .bundled(let emote):
            let slug = emote.slug
            // A baked animation: a 320 px canvas holding 256 px of art, so it is drawn 1.25 times the art's size.
            if let data = Self.file(slug), let decoder = FrameDecoder(data: data) {
                let sheet = CALayer()
                sheet.frame = CGRect(x: -0.625 * s, y: -0.625 * s, width: 1.25 * s, height: 1.25 * s)
                sheet.contentsGravity = .resize
                sheet.contentsScale = scale
                root.addSublayer(sheet)
                let player = FramePlayer(decoder: decoder, layer: sheet, loops: false)
                // A file that can't be decoded: the placeholder plays instead, for the emote's usual time.
                player.onFailure = { [weak self, weak entry] in
                    guard let self, let entry, !entry.gone else { return }
                    sheet.removeFromSuperlayer()
                    entry.root.addSublayer(self.envelope(self.bubble(size: s), size: s, duration: d))
                }
                entry.player = player
                player.start()
            } else {
                root.addSublayer(envelope(bubble(size: s), size: s, duration: d))
            }
        case .image(let url, let animated):
            if let data = try? Data(contentsOf: url), let decoder = FrameDecoder(data: data) {
                let img = CALayer()
                img.frame = CGRect(x: 0, y: 0, width: s, height: s)
                img.contentsGravity = .resizeAspect
                img.contentsScale = scale
                img.shadowColor = CGColor(gray: 1, alpha: 1)
                img.shadowOpacity = 0.53
                img.shadowRadius = 4
                img.shadowOffset = .zero
                let player = FramePlayer(decoder: decoder, layer: img, loops: animated)
                entry.player = player
                player.start()
                root.addSublayer(envelope(img, size: s, duration: d))
            } else {
                root.addSublayer(envelope(bubble(size: s), size: s, duration: d))
            }
        case .missing:
            root.addSublayer(envelope(bubble(size: s), size: s, duration: d))
        }

        if let tag { root.addSublayer(PingFX.tagLayer(tag, top: 0.5 * s + 8, duration: d, scale: scale)) }
        layer.addSublayer(root)
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.15) { [weak self, weak entry] in
            if let self, let entry { self.end(owner, entry) }
        }
    }

    /// Removes the owner's emote at once, if it has one.
    func clear(owner: String) {
        if let entry = live[owner] { end(owner, entry) }
    }

    private func end(_ owner: String, _ entry: Live) {
        if entry.gone { return }
        entry.gone = true
        entry.player?.stop()
        entry.root.removeFromSuperlayer()
        if live[owner] === entry { live[owner] = nil }
    }

    private static func file(_ slug: String) -> Data? {
        if let hit = files[slug] { return hit }
        guard let url = ImageStore.emoteAnimation(slug), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        files[slug] = data
        return data
    }

    /// What a custom image or the placeholder plays in: pop in, bob, then shrink and fade over the last 0.35 s.
    /// (A bundled emote's baked animation does this itself.)
    private func envelope(_ child: CALayer, size s: CGFloat, duration d: Double) -> CALayer {
        let fx = CALayer()
        fx.frame = CGRect(x: -0.5 * s, y: -0.5 * s, width: s, height: s)
        fx.addSublayer(child)
        fx.add(Anim.keyframes("transform.scale", values: [0, 1.15, 1], keyTimes: [0, 0.6, 1], duration: 0.25, timing: Anim.easeOut, fill: .backwards, in: fx), forKey: "in")
        fx.add(Anim.keyframes("transform.translation.y", values: [0, -4, 4, 0], keyTimes: [0, 0.25, 0.75, 1], duration: 1.4,
                              timing: Anim.easeInOut, fill: .removed, repeats: true, additive: true, in: fx), forKey: "bob")
        fx.add(Anim.keyframes("transform.scale", values: [1, 0.85], keyTimes: [0, 1], duration: 0.35, delay: d - 0.35, timing: Anim.easeIn, fill: .forwards, in: fx), forKey: "out")
        fx.add(Anim.keyframes("opacity", values: [1, 0], keyTimes: [0, 1], duration: 0.35, delay: d - 0.35, timing: Anim.easeIn, fill: .forwards, in: fx), forKey: "fade")
        return fx
    }

    /// What stands in for an emote whose files are missing: a speech bubble with a question mark.
    private func bubble(size s: CGFloat) -> CALayer {
        let holder = CALayer()
        holder.frame = CGRect(x: 0, y: 0, width: s, height: s)
        holder.shadowColor = CGColor(gray: 1, alpha: 1)
        holder.shadowOpacity = 0.53
        holder.shadowRadius = 4
        holder.shadowOffset = .zero

        let body = CGRect(x: 0.08 * s, y: 0.08 * s, width: 0.84 * s, height: 0.68 * s)
        let tail = CAShapeLayer()
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: body.minX + 0.2 * body.width, y: body.maxY - 0.12 * body.height))
        tip.addLine(to: CGPoint(x: body.minX + 0.2 * body.width, y: body.maxY + 10))
        tip.addLine(to: CGPoint(x: body.minX + 0.42 * body.width, y: body.maxY - 0.03 * body.height))
        tail.path = tip
        tail.fillColor = .hex(0xf4efe2)
        tail.strokeColor = .hex(0xc8aa6e)
        tail.lineWidth = 3
        tail.lineJoin = .round
        holder.addSublayer(tail)

        let oval = CAShapeLayer()
        oval.path = CGPath(ellipseIn: body.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        oval.fillColor = .hex(0xf4efe2)
        oval.strokeColor = .hex(0xc8aa6e)
        oval.lineWidth = 3
        holder.addSublayer(oval)

        let font = NSFont.systemFont(ofSize: 0.4 * s, weight: .bold)
        let mark = CATextLayer()
        mark.string = NSAttributedString(string: "?", attributes: [.font: font, .foregroundColor: NSColor.hex(0x1f2a30)])
        mark.alignmentMode = .center
        mark.contentsScale = scale
        let lineHeight = ceil(font.ascender - font.descender)
        mark.frame = CGRect(x: body.minX, y: body.midY - lineHeight / 2, width: body.width, height: lineHeight)
        holder.addSublayer(mark)
        return holder
    }
}

import AppKit
import LPCore

/// A short notice in the top right corner of the main display.
enum ToastFX {
    static func show(in layer: CALayer, title: String, body: String, bounds: CGRect, topInset: CGFloat, scale: CGFloat, ms: Int = 1800) {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let primary = dark ? NSColor.white : NSColor(white: 0.1, alpha: 1)
        let secondary = dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.55)
        let titleText = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: primary])
        let bodyText = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary])
        let textWidth = min(420 - 72, max(260 - 72, ceil(max(titleText.size().width, bodyText.size().width)) + 2))
        let hasBody = !body.isEmpty
        let height: CGFloat = hasBody ? 62 : 48

        let toast = CALayer()
        toast.frame = CGRect(x: bounds.maxX - 24 - (textWidth + 72), y: topInset + 16, width: textWidth + 72, height: height)
        toast.cornerRadius = 10
        toast.backgroundColor = dark ? CGColor(gray: 0.125, alpha: 0.92) : CGColor(gray: 0.976, alpha: 0.95)
        toast.borderWidth = 1
        toast.borderColor = dark ? CGColor(gray: 1, alpha: 0.08) : CGColor(gray: 0, alpha: 0.06)
        toast.shadowColor = .black
        toast.shadowOpacity = 0.35
        toast.shadowRadius = 16
        toast.shadowOffset = CGSize(width: 0, height: 8)

        let icon = CALayer()
        icon.frame = CGRect(x: 16, y: (height - 28) / 2, width: 28, height: 28)
        icon.contents = BrandMark.image(pixels: 112)
        icon.contentsGravity = .resizeAspect
        toast.addSublayer(icon)

        func label(_ string: NSAttributedString, y: CGFloat, h: CGFloat) {
            let t = CATextLayer()
            t.string = string
            t.frame = CGRect(x: 56, y: y, width: textWidth, height: h)
            t.truncationMode = .end
            t.contentsScale = scale
            toast.addSublayer(t)
        }
        label(titleText, y: hasBody ? 12 : 15, h: 20)
        if hasBody { label(bodyText, y: 33, h: 17) }

        layer.addSublayer(toast)
        toast.add(Anim.keyframes("transform.translation.y", values: [-24, 0], keyTimes: [0, 1], duration: 0.3,
                                 timing: CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1), fill: .removed, additive: true, in: toast), forKey: "in")
        toast.add(Anim.keyframes("opacity", values: [0, 1], keyTimes: [0, 1], duration: 0.3, fill: .removed, in: toast), forKey: "fadeIn")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
            guard toast.superlayer != nil else { return }
            toast.add(Anim.keyframes("opacity", values: [1, 0], keyTimes: [0, 1], duration: 0.2, timing: Anim.easeIn, fill: .forwards, in: toast), forKey: "out")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { toast.removeFromSuperlayer() }
        }
    }
}

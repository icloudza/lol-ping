import AppKit
import LPCore

extension CGColor {
    /// An sRGB colour from 0xRRGGBB.
    static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}

extension NSColor {
    static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}

/// The pictures that ship with the app, decoded on first use and kept. Main thread only.
final class ImageStore {
    static let shared = ImageStore()

    private var textures: [String: CGImage] = [:]
    private var paleTextures: [String: CGImage] = [:]
    private var emoteBadges: [String: CGImage] = [:]
    /// Files that should be in the bundle and aren't, as "textures/x.png".
    private(set) var missingFiles = Set<String>()

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A ping picture by name. A stand-in is returned for one that can't be loaded.
    func texture(_ name: String) -> CGImage? {
        if let cached = textures[name] { return cached }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "textures"), let image = Self.decode(url) {
            textures[name] = image
            return image
        }
        missingFiles.insert("textures/\(name).png")
        return name == PingCatalog.standInTexture ? nil : texture(PingCatalog.standInTexture)
    }

    /// The same picture drained of colour to a pale cream: how the wheel shows a diagonal slice until it is pointed at.
    func paleTexture(_ name: String) -> CGImage? {
        if let cached = paleTextures[name] { return cached }
        guard let original = texture(name), let pale = Self.pale(original) else { return texture(name) }
        paleTextures[name] = pale
        return pale
    }

    func emoteBadge(_ slug: String) -> CGImage? {
        if let cached = emoteBadges[slug] { return cached }
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "emotes"), let image = Self.decode(url) else {
            missingFiles.insert("emotes/\(slug).png")
            return nil
        }
        emoteBadges[slug] = image
        return image
    }

    static func emoteAnimation(_ slug: String) -> URL? {
        Bundle.main.url(forResource: slug, withExtension: "webp", subdirectory: "emotes")
    }

    /// Looks for every file the catalogues name, so the settings window can say what is missing.
    func auditBundle() {
        for name in PingCatalog.textureNames { _ = texture(name) }
        for name in PingCatalog.soundNames where Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") == nil {
            missingFiles.insert("sounds/\(name).wav")
        }
        for emote in EmoteCatalog.all {
            _ = emoteBadge(emote.slug)
            if Self.emoteAnimation(emote.slug) == nil { missingFiles.insert("emotes/\(emote.slug).webp") }
            if emote.hasSound, Bundle.main.url(forResource: emote.slug, withExtension: "m4a", subdirectory: "emotes") == nil {
                missingFiles.insert("emotes/\(emote.slug).m4a")
            }
        }
    }

    /// Replaces each pixel's colour with cream at the pixel's own brightness, lifted a little so dark art stays legible.
    private static func pale(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let base = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let cream: (Double, Double, Double) = (0.96, 0.92, 0.82)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let alpha = Double(px[i + 3]) / 255
            guard alpha > 0 else { continue }
            let luma = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255 / alpha
            let light = min(1, 0.22 + luma * 1.15) * alpha * 255
            px[i] = UInt8(light * cream.0)
            px[i + 1] = UInt8(light * cream.1)
            px[i + 2] = UInt8(light * cream.2)
        }
        return ctx.makeImage()
    }
}

/// Keyframe animations where the easing applies to each step separately rather than to the whole run.
enum Anim {
    static let linear = CAMediaTimingFunction(name: .linear)
    static let easeOut = CAMediaTimingFunction(name: .easeOut)
    static let easeIn = CAMediaTimingFunction(name: .easeIn)
    static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)

    static func keyframes(_ keyPath: String, values: [Any], keyTimes: [Double], duration: CFTimeInterval, delay: CFTimeInterval = 0,
                          timing: CAMediaTimingFunction = linear, fill: CAMediaTimingFillMode = .both, repeats: Bool = false,
                          additive: Bool = false, in layer: CALayer) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = keyTimes.map { NSNumber(value: $0) }
        a.timingFunctions = Array(repeating: timing, count: max(0, values.count - 1))
        a.duration = duration
        a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = fill
        a.isRemovedOnCompletion = false
        a.isAdditive = additive
        if repeats { a.repeatCount = .infinity }
        return a
    }
}

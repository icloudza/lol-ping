import AppKit

/// The app's mark drawn edge to edge: the violet-to-pink tile with four arcs around a dot, the upper-right arc lit.
///
/// The app icon file can't stand in for this inside the app's own windows. It carries the margin and drop shadow a
/// Dock icon needs, and macOS may set it on a backing plate, so at small sizes it reads as a small icon in a grey box.
enum BrandMark {
    private static var cache: [Int: CGImage] = [:]

    /// The mark as a square bitmap, `pixels` on a side.
    static func image(pixels: Int) -> CGImage? {
        if let cached = cache[pixels] { return cached }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Drawn on a 100 unit square.
        ctx.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
        let tile = CGRect(x: 0, y: 0, width: 100, height: 100)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 22.5, cornerHeight: 22.5, transform: nil))
        ctx.clip()
        let colors = [CGColor.hex(0xa78bfa), CGColor.hex(0x8b5cf6), CGColor.hex(0xdb2777)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 100, y: 0), options: [])
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(11.6)
        for quarter in 0..<4 {
            // Each arc covers 58° of its quarter; angles are measured clockwise from straight up.
            let from = (90 - (CGFloat(quarter) * 90 + 16)) * .pi / 180, to = (90 - (CGFloat(quarter) * 90 + 74)) * .pi / 180
            ctx.setStrokeColor(CGColor(gray: 1, alpha: quarter == 0 ? 1 : 0.38))
            ctx.addArc(center: CGPoint(x: 50, y: 50), radius: 30.3, startAngle: from, endAngle: to, clockwise: true)
            ctx.strokePath()
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 41, y: 41, width: 18, height: 18))
        let image = ctx.makeImage()
        cache[pixels] = image
        return image
    }
}

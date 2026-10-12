// Draws LolPing's icon and writes it where the app expects it: every size of the app icon into the asset catalogue,
// and the menu bar glyph (on and paused) into App/Resources. Run from the project folder: swift Scripts/make-icon.swift
//
// The mark is a four-way wheel reduced to its bones: four arcs around a dot, the upper-right arc lit.
import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
func canvas(_ pixels: Int, unit: CGFloat) -> CGContext {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / unit, y: CGFloat(pixels) / unit)
    return ctx
}
func save(_ ctx: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// The four arcs and the dot around `c`. `lit` gives each arc's colour, starting with the upper-right one and going clockwise.
func mark(_ ctx: CGContext, c: CGPoint, radius: CGFloat, width: CGFloat, dot: CGFloat, arcs: [CGColor], dotColor: CGColor) {
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    for (i, color) in arcs.enumerated() {
        // Each arc covers 58° of its quarter, leaving gaps on the axes. Angles here are clockwise from straight up.
        let from = (90 - (CGFloat(i) * 90 + 16)) * .pi / 180, to = (90 - (CGFloat(i) * 90 + 74)) * .pi / 180
        ctx.setStrokeColor(color)
        ctx.addArc(center: c, radius: radius, startAngle: from, endAngle: to, clockwise: true)
        ctx.strokePath()
    }
    ctx.setFillColor(dotColor)
    ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
}

/// The app icon on a 1024 unit canvas: the standard macOS plate (824 wide) in violet running to pink.
func drawAppIcon(_ ctx: CGContext) {
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let c = CGPoint(x: 512, y: 512)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xdb2777))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xa78bfa)), (0.5, rgb(0x8b5cf6)), (1, rgb(0xdb2777))]),
                           start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // The three resting arcs first, then the lit arc and the dot with a soft shadow that lifts them off the plate.
    let faint = rgb(0xffffff, 0.36), clear = rgb(0xffffff, 0)
    mark(ctx, c: c, radius: 250, width: 96, dot: 0, arcs: [clear, faint, faint, faint], dotColor: clear)
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(0x4c1d95, 0.5))
    mark(ctx, c: c, radius: 250, width: 96, dot: 74, arcs: [rgb(0xffffff)], dotColor: rgb(0xffffff))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.drawLinearGradient(gradient([(0, rgb(0xffffff, 0.14)), (0.5, rgb(0xffffff, 0))]),
                           start: CGPoint(x: c.x, y: plate.maxY), end: CGPoint(x: c.x, y: plate.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184.5, cornerHeight: 184.5, transform: nil))
    ctx.setStrokeColor(rgb(0xffffff, 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

/// The menu bar glyph on a 100 unit canvas, in black: macOS tints a template image itself.
/// Paused: the whole mark fades and the lit arc goes away, so the two states differ in shape as well as in strength.
func drawMenuBarGlyph(_ ctx: CGContext, paused: Bool) {
    let ink = rgb(0x000000, paused ? 0.42 : 1)
    let arcs = paused ? [rgb(0x000000, 0), ink, ink, ink] : [ink, ink, ink, ink]
    mark(ctx, c: CGPoint(x: 50, y: 50), radius: 33, width: 13, dot: 10, arcs: arcs, dotColor: ink)
}

let iconSet = "App/Assets.xcassets/AppIcon.appiconset"
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let ctx = canvas(points * scale, unit: 1024)
        drawAppIcon(ctx)
        save(ctx, "\(iconSet)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
    }
}
for (name, paused) in [("MenuBarIcon", false), ("MenuBarIconPaused", true)] {
    for scale in [1, 2] {
        let ctx = canvas(18 * scale, unit: 100)
        drawMenuBarGlyph(ctx, paused: paused)
        save(ctx, "App/Resources/\(name)\(scale == 2 ? "@2x" : "").png")
    }
}
print("icon written")

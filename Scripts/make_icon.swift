import AppKit

// Renders a modern macOS app icon (rounded-square gradient + white shield + bolt)
// into AppIcon.iconset, then iconutil -> VPN/Resources/AppIcon.icns.

func shieldPath(in r: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let w = r.width, h = r.height
    let c = w * 0.18                 // rounded top-corner radius -> proper shield shoulders
    let topY = r.maxY
    let shoulder = r.minY + h * 0.42
    p.move(to: NSPoint(x: r.minX, y: shoulder))
    p.line(to: NSPoint(x: r.minX, y: topY - c))
    p.appendArc(withCenter: NSPoint(x: r.minX + c, y: topY - c), radius: c,
                startAngle: 180, endAngle: 90, clockwise: true)
    p.line(to: NSPoint(x: r.maxX - c, y: topY))
    p.appendArc(withCenter: NSPoint(x: r.maxX - c, y: topY - c), radius: c,
                startAngle: 90, endAngle: 0, clockwise: true)
    p.line(to: NSPoint(x: r.maxX, y: shoulder))
    p.curve(to: NSPoint(x: r.midX, y: r.minY),
            controlPoint1: NSPoint(x: r.maxX, y: r.minY + h * 0.16),
            controlPoint2: NSPoint(x: r.midX + w * 0.36, y: r.minY))
    p.curve(to: NSPoint(x: r.minX, y: shoulder),
            controlPoint1: NSPoint(x: r.midX - w * 0.36, y: r.minY),
            controlPoint2: NSPoint(x: r.minX, y: r.minY + h * 0.16))
    p.close()
    return p
}

func boltPath(in r: NSRect) -> NSBezierPath {
    let pts: [(CGFloat, CGFloat)] = [
        (0.60, 1.00), (0.28, 0.46), (0.48, 0.46),
        (0.40, 0.00), (0.74, 0.58), (0.54, 0.58)
    ]
    let p = NSBezierPath()
    for (i, pt) in pts.enumerated() {
        let q = NSPoint(x: r.minX + pt.0 * r.width, y: r.minY + pt.1 * r.height)
        if i == 0 { p.move(to: q) } else { p.line(to: q) }
    }
    p.close()
    return p
}

func drawIcon(px: CGFloat) {
    let margin = px * 0.085
    let rect = NSRect(x: margin, y: margin, width: px - 2 * margin, height: px - 2 * margin)
    let radius = rect.width * 0.225

    // Background gradient (deep indigo -> cyan), top to bottom.
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.36, blue: 0.98, alpha: 1.0),
        NSColor(srgbRed: 0.10, green: 0.74, blue: 0.92, alpha: 1.0)
    ])!
    grad.draw(in: bg, angle: -90)

    // Soft inner highlight at the top.
    let hi = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04),
                          xRadius: radius * 0.85, yRadius: radius * 0.85)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    hi.lineWidth = px * 0.012
    hi.stroke()

    // White shield.
    let sw = rect.width * 0.50
    let sh = rect.height * 0.58
    let shieldRect = NSRect(x: rect.midX - sw / 2,
                            y: rect.midY - sh / 2 + rect.height * 0.015,
                            width: sw, height: sh)
    // subtle drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = px * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    shieldPath(in: shieldRect).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Bolt cut into the shield (gradient blue to read as a cutout).
    let bw = sw * 0.44, bh = sh * 0.52
    let boltRect = NSRect(x: shieldRect.midX - bw / 2,
                          y: shieldRect.midY - bh / 2 + sh * 0.04,
                          width: bw, height: bh)
    NSColor(srgbRed: 0.18, green: 0.42, blue: 0.96, alpha: 1.0).setFill()
    boltPath(in: boltRect).fill()
}

func renderPNG(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(px: CGFloat(px))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(root)/VPN/Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in sizes {
    let data = renderPNG(px: px)
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("wrote iconset at \(iconset)")

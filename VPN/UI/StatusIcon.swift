import AppKit

/// Draws the menu-bar template icon — a shield (matching the app icon) that is an
/// outline when disconnected and a filled shield with a bolt cut-out when connected.
enum StatusIcon {
    static func shield(filled: Bool) -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let img = NSImage(size: size)
        img.lockFocus()
        let r = NSRect(x: 4, y: 2.0, width: 11, height: 15)
        let shield = shieldPath(in: r)
        shield.lineJoinStyle = .round
        NSColor.black.setFill()
        NSColor.black.setStroke()

        if filled {
            // shield + bolt subpath, even-odd -> bolt reads as a knockout
            let bolt = boltPath(in: boltRect(in: r))
            shield.append(bolt)
            shield.windingRule = .evenOdd
            shield.fill()
        } else {
            shield.lineWidth = 1.4
            shield.stroke()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private static func shieldPath(in r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r.width, h = r.height
        let c = w * 0.22
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

    private static func boltRect(in r: NSRect) -> NSRect {
        let bw = r.width * 0.42, bh = r.height * 0.5
        return NSRect(x: r.midX - bw / 2, y: r.minY + r.height * 0.26, width: bw, height: bh)
    }

    private static func boltPath(in r: NSRect) -> NSBezierPath {
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
}

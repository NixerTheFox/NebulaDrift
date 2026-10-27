// The cockpit canopy (G key): hull plating framing the window, with rivets, a rubber seal and stencils.
// The scratched glass itself is drawn in the shader so it can catch the light of what's outside.

import Cocoa

final class CockpitFrameView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Corner points of the window, clockwise from bottom-left. The bottom runs behind the console.
    private func windowCorners(_ b: CGRect) -> [CGPoint] {
        let w = b.width, h = b.height
        let sideLow = w * 0.035, sideHigh = w * 0.075, top = h * 0.07
        let chamfer = min(w, h) * 0.08
        return [CGPoint(x: sideLow, y: h + 20), CGPoint(x: sideLow, y: h * 0.5),
                CGPoint(x: sideHigh, y: top + chamfer), CGPoint(x: sideHigh + chamfer, y: top),
                CGPoint(x: w - sideHigh - chamfer, y: top), CGPoint(x: w - sideHigh, y: top + chamfer),
                CGPoint(x: w - sideLow, y: h * 0.5), CGPoint(x: w - sideLow, y: h + 20)]
    }

    private func windowPath(_ pts: [CGPoint], radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: pts[0])
        for i in 1..<(pts.count - 1) {
            p.addArc(tangent1End: pts[i], tangent2End: pts[i + 1], radius: radius)
        }
        p.addLine(to: pts[pts.count - 1])
        p.closeSubpath()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        drawFrame(in: c, bounds: bounds)
    }

    /// Draws the frame into a y-down context (also used by --snapshot, with no view on screen).
    func drawFrame(in c: CGContext, bounds b: CGRect) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        defer { NSGraphicsContext.current = previous }
        let u = InstrumentPanel.panelHeight(for: b.size)
        let pts = windowCorners(b)
        let window = windowPath(pts, radius: min(b.width, b.height) * 0.03)

        // Hull plating around the window.
        c.saveGState()
        c.addRect(b)
        c.addPath(window)
        c.clip(using: .evenOdd)
        let hull = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgb(0.075, 0.08, 0.075), rgb(0.03, 0.032, 0.03)] as CFArray, locations: nil)!
        c.drawLinearGradient(hull, start: .zero, end: CGPoint(x: 0, y: b.height), options: [])
        // Brushed grain and grime.
        var seed: UInt64 = 99
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 40) / CGFloat(1 << 24)
        }
        c.setLineWidth(1)
        var y: CGFloat = 0
        while y < b.height {
            c.setStrokeColor(rgb(1, 1, 1, 0.004 + 0.012 * rnd()))
            c.move(to: CGPoint(x: 0, y: y))
            c.addLine(to: CGPoint(x: b.width, y: y))
            c.strokePath()
            y += 1 + 2.5 * rnd()
        }
        // Panel seams.
        c.setStrokeColor(rgb(0, 0, 0, 0.6))
        c.setLineWidth(1.5)
        let seamY = pts[3].y * 0.45
        c.move(to: CGPoint(x: 0, y: seamY)); c.addLine(to: CGPoint(x: b.width, y: seamY))
        c.move(to: CGPoint(x: pts[1].x * 0.45, y: seamY)); c.addLine(to: CGPoint(x: pts[1].x * 0.45, y: b.height))
        c.move(to: CGPoint(x: b.width - pts[1].x * 0.45, y: seamY)); c.addLine(to: CGPoint(x: b.width - pts[1].x * 0.45, y: b.height))
        c.strokePath()
        c.setStrokeColor(rgb(1, 1, 1, 0.06))
        c.setLineWidth(1)
        c.move(to: CGPoint(x: 0, y: seamY + 1.5)); c.addLine(to: CGPoint(x: b.width, y: seamY + 1.5))
        c.strokePath()

        // Rivets in a row just outside the seal, all the way round.
        let spacing = max(26, u * 0.2)
        for i in 1..<(pts.count - 2) {
            let a = pts[i], z = pts[i + 1]
            let len = hypot(z.x - a.x, z.y - a.y)
            var n = CGPoint(x: -(z.y - a.y) / len, y: (z.x - a.x) / len)
            let mid = CGPoint(x: (a.x + z.x) / 2, y: (a.y + z.y) / 2)
            if window.contains(CGPoint(x: mid.x + n.x * 4, y: mid.y + n.y * 4)) { n = CGPoint(x: -n.x, y: -n.y) }
            let off = max(12, u * 0.09)
            var t = spacing * 0.5
            while t < len - spacing * 0.3 {
                let p = CGPoint(x: a.x + (z.x - a.x) * t / len + n.x * off, y: a.y + (z.y - a.y) * t / len + n.y * off)
                rivet(c, p, max(2.5, u * 0.018))
                t += spacing
            }
        }
        // Stencils.
        stencil("CANOPY 2-A   ·   PRESSURE RATED 1.2 ATM", CGPoint(x: pts[3].x + 10, y: seamY * 0.5), size: max(9, u * 0.07))
        stencil("DO NOT OPEN IN FLIGHT", CGPoint(x: b.width - pts[3].x - 10, y: seamY * 0.5), size: max(9, u * 0.07),
                alignRight: true)
        c.restoreGState()

        // Soft shading on the glass just inside the frame, for depth.
        c.saveGState()
        c.addPath(window)
        c.clip()
        c.setShadow(offset: CGSize(width: 0, height: 4), blur: 28, color: rgb(0, 0, 0, 0.85))
        c.addPath(window)
        c.setStrokeColor(rgb(0, 0, 0, 1))
        c.setLineWidth(10)
        c.strokePath()
        c.restoreGState()

        // Rubber seal with a worn highlight.
        c.addPath(window)
        c.setStrokeColor(rgb(0.025, 0.025, 0.025))
        c.setLineWidth(max(7, u * 0.05))
        c.strokePath()
        c.addPath(window)
        c.setStrokeColor(rgb(0.4, 0.4, 0.38, 0.2))
        c.setLineWidth(1)
        c.strokePath()
    }

    private func rivet(_ c: CGContext, _ p: CGPoint, _ r: CGFloat) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: rgb(0, 0, 0, 0.8))
        c.setFillColor(rgb(0.16, 0.16, 0.16))
        c.fillEllipse(in: rect)
        c.restoreGState()
        c.saveGState()
        c.addEllipse(in: rect)
        c.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(0.36, 0.36, 0.35), rgb(0.1, 0.1, 0.1)] as CFArray, locations: nil)!
        c.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        c.restoreGState()
    }

    private func stencil(_ s: String, _ p: CGPoint, size: CGFloat, alignRight: Bool = false) {
        let font = NSFont(name: "DINCondensed-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        let str = NSAttributedString(string: s, attributes: [.font: font, .kern: size * 0.12,
                                                             .foregroundColor: NSColor(red: 0.86, green: 0.83, blue: 0.74, alpha: 0.26)])
        let sz = str.size()
        str.draw(at: CGPoint(x: alignRight ? p.x - sz.width : p.x, y: p.y - sz.height / 2))
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

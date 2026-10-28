// A retro-futuristic digital dashboard (V key): a green vacuum-fluorescent instrument cluster under a smoked
// glass hood, like the dashboards of the mid-80s: segmented bar gauges, a bar-graph tachometer, seven-segment
// readouts, warning lamps and a dot-matrix display showing the song. Drawn with Core Graphics, y-down.

import Cocoa

final class Dashboard {
    typealias Source = InstrumentPanel.Source

    var source = Source.system

    // Vacuum-fluorescent green, the pink of the warning lamps, and the red of the peak lamp and redline.
    private static let vfd = (r: CGFloat(0.36), g: CGFloat(1.0), b: CGFloat(0.52))
    private static let pink = (r: CGFloat(1.0), g: CGFloat(0.32), b: CGFloat(0.62))
    private static let red = (r: CGFloat(1.0), g: CGFloat(0.33), b: CGFloat(0.22))
    private static let tachColumns = 46, barSegments = 12, fluxSegments = 12

    private var time: Float = 0, chaos: Float = 0, chaosClock: Float = 0
    private var chaosTargets = [Float](repeating: 0, count: 16)
    private var flux = InstrumentPanel.Spring(), rpm = InstrumentPanel.Spring(), speed = InstrumentPanel.Spring()
    private var bars = [InstrumentPanel.Spring](repeating: .init(), count: 3)
    private var peaks: [Float] = [0, 0, 0], peakAge: [Float] = [0, 0, 0]
    private var lampGlow = [Float](repeating: 0, count: 7) // WARP, TIDAL, BEAT, SYS, MIC, FILE, PEAK
    private var beatLamp: Float = 0, arrows: Float = 0
    private var distance: Double = 0 // light-years, on the trip meter
    private var lightSpeeds: Float = 0

    private var song = "", alarmText = ""
    private var songScroll: Double = 0, songHold: Double = 0

    // MARK: Update

    func update(_ i: PanelInput, dt rawDt: Float) {
        let dt = min(rawDt, 1 / 30)
        time += dt
        chaos = max(i.alarm - 0.1, 0) / 0.9
        if chaos > 0.02 {
            chaosClock -= dt
            if chaosClock <= 0 {
                chaosClock = .random(in: 0.04...0.14) / max(chaos, 0.3)
                for k in chaosTargets.indices { chaosTargets[k] = .random(in: -0.1...1.15) }
            }
        }
        func mixed(_ normal: Float, _ k: Int) -> Float { normal + (chaosTargets[k] - normal) * chaos }
        let hard: Float = 1 + 2 * chaos
        flux.step(to: mixed(i.level, 0), dt: dt, stiffness: 60 * hard, damping: 11)
        for (k, level) in [i.bass, i.mid, i.treble].enumerated() {
            bars[k].step(to: mixed(level, 1 + k), dt: dt, stiffness: 220 * hard, damping: 22)
            // Peak hold: the top segment stays lit a moment, then drops.
            peakAge[k] += dt
            if bars[k].pos >= peaks[k] {
                peaks[k] = bars[k].pos
                peakAge[k] = 0
            } else if peakAge[k] > 0.7 {
                peaks[k] = max(peaks[k] - dt * 0.9, bars[k].pos)
            }
        }
        // Engine revs (thousands): the music's energy, with a kick on every beat.
        let revs = 0.7 + 6.2 * min(0.6 * i.level + 0.5 * i.bass, 1.1) + 0.5 * i.beat
        rpm.step(to: mixed(revs / 7.5, 4) * 7.5, dt: dt, stiffness: 90 * hard, damping: 12)
        speed.step(to: mixed(i.speed / maxSpeed, 5) * maxSpeed, dt: dt, stiffness: 40 * hard * hard, damping: 9)
        lightSpeeds = lightSpeedsFor(speed.pos)
        distance += Double(lightSpeeds * dt) * 0.1

        beatLamp = max(beatLamp * expf(-dt * 7), i.beat)
        arrows = max(arrows * expf(-dt * 5), i.beat > 0.5 ? 1 : 0) // the hazard arrows flash on the beat
        let peakLit: Float = max(bars[0].pos, bars[1].pos, bars[2].pos) > 0.93 ? 1 : 0
        var on: [Float] = [lightSpeeds >= 10 ? 1 : 0, chaos > 0.02 && sin(time * 11) > 0 ? 1 : 0, beatLamp,
                           source == .system ? 1 : 0, source == .mic ? 1 : 0, source == .file ? 1 : 0, peakLit]
        if chaos > 0.02 {
            for k in on.indices where k != 1 { on[k] = chaosTargets[6 + k] > 0.5 ? 1 : on[k] * (1 - chaos) }
            arrows = sin(time * 17) > 0 ? 1 : 0
        }
        for k in on.indices {
            // Fluorescent segments light almost at once and fade out quickly.
            let rate: Float = on[k] > lampGlow[k] ? 30 : 12
            lampGlow[k] += (on[k] - lampGlow[k]) * (1 - expf(-dt * rate))
        }

        if songHold > 0 { songHold -= Double(dt) } else { songScroll += Double(dt) * 14 } // dot columns a second
    }

    /// What the dot-matrix display shows (scrolling when it doesn't fit).
    func setSong(_ text: String) {
        guard text != song else { return }
        song = text
        songScroll = 0
        songHold = 1.5
    }

    /// Whether the tidal-stress warning is showing (the console's alarm banner isn't, with the dashboard).
    var alarmActive: Bool { chaos > 0.02 }

    // MARK: Layout

    private struct Layout {
        var u: CGFloat, width: CGFloat, strip: CGFloat
        var hood = CGRect.zero, face = CGRect.zero, odometer = CGRect.zero, song = CGRect.zero
        var dots = CGRect.zero // the song display's dot field
        var flux = CGRect.zero, speedBox = CGRect.zero, tach = CGRect.zero
        var bars: [CGRect] = [], lamps: [CGRect] = [], warp: [CGRect] = [], scaleDots: [CGPoint] = []
        var speedDigits: [CGRect] = [], rpmDigits: [CGRect] = [], odoDigits: [CGRect] = []
        var peak = CGRect.zero, arrowLeft = CGRect.zero, arrowRight = CGRect.zero
        var dotPitch: CGFloat = 1
    }

    private static func unit(_ size: CGSize) -> CGFloat { max(min(size.height * 0.2, size.width / 5.6, 200), 44) }

    /// Height of the dashboard strip (with the shade it casts upward), along the bottom of a view.
    static func stripHeight(for size: CGSize) -> CGFloat { unit(size) * 1.12 }

    private func layout(_ size: CGSize) -> Layout {
        let u = Self.unit(size)
        var l = Layout(u: u, width: size.width, strip: u * 1.12)
        let f = CGRect(x: (size.width - 4.6 * u) / 2, y: 0.17 * u, width: 4.6 * u, height: 0.72 * u)
        l.face = f
        l.hood = CGRect(x: f.minX - 0.14 * u, y: 0.05 * u, width: f.width + 0.28 * u, height: f.maxY - 0.05 * u)
        l.odometer = CGRect(x: f.minX + 0.05 * u, y: 0.97 * u, width: 1.05 * u, height: 0.11 * u)
        l.song = CGRect(x: f.minX + 1.25 * u, y: 0.97 * u, width: f.width - 1.3 * u, height: 0.11 * u)
        let p = l.song.height * 0.78 / CGFloat(DotMatrix.rows)
        l.dotPitch = p
        let dotsX = l.song.minX + 0.2 * u
        l.dots = CGRect(x: dotsX, y: l.song.minY + (l.song.height - 7 * p) / 2,
                        width: ((l.song.maxX - 0.06 * u - dotsX) / p).rounded(.down) * p, height: 7 * p)

        l.flux = CGRect(x: f.minX + 0.2 * u, y: f.minY + 0.23 * u, width: 0.1 * u, height: 0.36 * u)
        l.bars = (0..<3).map { CGRect(x: f.minX + (3.8 + 0.25 * CGFloat($0)) * u, y: f.minY + 0.2 * u, width: 0.08 * u,
                                      height: 0.4 * u) }
        l.speedBox = CGRect(x: f.minX + 1.4 * u, y: f.minY + 0.14 * u, width: 0.95 * u, height: 0.22 * u)
        l.tach = CGRect(x: f.minX + 1.0 * u, y: f.minY + 0.34 * u, width: 2.35 * u, height: 0.28 * u)
        let box = l.speedBox
        l.speedDigits = (0..<3).map {
            CGRect(x: box.maxX - 0.2 * u - CGFloat(3 - $0) * 0.125 * u + 0.015 * u, y: box.minY + 0.03 * u,
                   width: 0.095 * u, height: 0.165 * u)
        }
        l.warp = (0..<3).map {
            let k = CGFloat($0)
            return CGRect(x: box.minX + (0.07 + 0.06 * k) * u, y: box.minY + (0.1 - 0.025 * k) * u, width: 0.035 * u,
                          height: (0.05 + 0.025 * k) * u)
        }
        l.scaleDots = (0..<6).map {
            CGPoint(x: box.minX + 0.08 * u + CGFloat($0) * (box.width - 0.16 * u) / 5, y: box.maxY + 0.035 * u)
        }
        l.rpmDigits = (0..<2).map {
            CGRect(x: f.minX + (1.02 + 0.064 * CGFloat($0)) * u, y: f.minY + 0.42 * u, width: 0.05 * u, height: 0.085 * u)
        }
        l.odoDigits = (0..<7).map {
            CGRect(x: l.odometer.minX + (0.08 + 0.06 * CGFloat($0)) * u, y: l.odometer.minY + 0.0175 * u,
                   width: 0.045 * u, height: 0.075 * u)
        }
        // Two pink lamps, then four green ones.
        let lampX: [CGFloat] = [1.62, 1.85, 2.4, 2.63, 2.86, 3.09]
        l.lamps = lampX.map { CGRect(x: f.minX + $0 * u, y: f.minY + 0.035 * u, width: 0.2 * u, height: 0.07 * u) }
        l.peak = CGRect(x: f.minX + 4.25 * u, y: f.minY + 0.06 * u, width: 0.13 * u, height: 0.06 * u)
        l.arrowLeft = CGRect(x: f.minX + 0.75 * u, y: f.minY + 0.17 * u, width: 0.2 * u, height: 0.1 * u)
        l.arrowRight = CGRect(x: f.minX + 3.35 * u, y: f.minY + 0.17 * u, width: 0.2 * u, height: 0.1 * u)
        return l
    }

    /// Column `i` of the tachometer and how many dashes it is made of. The columns grow taller toward the top of
    /// the rev range, as on the real thing.
    private func tachColumn(_ l: Layout, _ i: Int) -> (rect: CGRect, dashes: Int) {
        let pitch = l.tach.width / CGFloat(Self.tachColumns)
        let t = CGFloat(i) / CGFloat(Self.tachColumns - 1)
        let s = min(max((t - 0.12) / 0.83, 0), 1)
        var profile = 0.12 + 0.88 * s * s * (3 - 2 * s)
        if t > 0.9 { profile *= 1 - (t - 0.9) * 0.5 }
        let dashPitch = 0.024 * l.u
        let dashes = max(2, Int((profile * l.tach.height / dashPitch).rounded()))
        let h = CGFloat(dashes) * dashPitch
        return (CGRect(x: l.tach.minX + CGFloat(i) * pitch + pitch * 0.19, y: l.tach.maxY - h, width: pitch * 0.62,
                       height: h), dashes)
    }

    // MARK: Shapes

    private static let digitMasks: [UInt8] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F, 0x00, 0x40]
    private static let blank = 10

    /// A seven-segment digit in `cell`, slanted like the real ones; `mask` bits are segments a-g.
    private func addSevenSegment(_ p: CGMutablePath, _ cell: CGRect, _ mask: UInt8) {
        let w = cell.width, h = cell.height, t = w * 0.18, g = t * 0.14, skew: CGFloat = 0.08
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cell.minX + x + (h / 2 - y) * skew, y: cell.minY + y) }
        func horizontal(_ y: CGFloat) {
            let x0 = t / 2, x1 = w - t / 2
            p.addLines(between: [pt(x0 + g, y), pt(x0 + g + t / 2, y - t / 2), pt(x1 - g - t / 2, y - t / 2), pt(x1 - g, y),
                                 pt(x1 - g - t / 2, y + t / 2), pt(x0 + g + t / 2, y + t / 2)])
            p.closeSubpath()
        }
        func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            p.addLines(between: [pt(x, y0 + g), pt(x + t / 2, y0 + g + t / 2), pt(x + t / 2, y1 - g - t / 2), pt(x, y1 - g),
                                 pt(x - t / 2, y1 - g - t / 2), pt(x - t / 2, y0 + g + t / 2)])
            p.closeSubpath()
        }
        let top = t / 2, mid = h / 2, bottom = h - t / 2, left = t / 2, right = w - t / 2
        if mask & 1 != 0 { horizontal(top) }
        if mask & 2 != 0 { vertical(right, top, mid) }
        if mask & 4 != 0 { vertical(right, mid, bottom) }
        if mask & 8 != 0 { horizontal(bottom) }
        if mask & 16 != 0 { vertical(left, mid, bottom) }
        if mask & 32 != 0 { vertical(left, top, mid) }
        if mask & 64 != 0 { horizontal(mid) }
    }

    /// The decimal point after a digit cell.
    private func addDecimalPoint(_ p: CGMutablePath, _ cell: CGRect) {
        let r = cell.width * 0.09
        p.addEllipse(in: CGRect(x: cell.maxX + cell.width * 0.06, y: cell.maxY - 2 * r, width: 2 * r, height: 2 * r))
    }

    private func addArrow(_ p: CGMutablePath, _ r: CGRect, left: Bool) {
        let s: CGFloat = left ? -1 : 1
        let pts: [(CGFloat, CGFloat)] = [(-1, -0.32), (0.15, -0.32), (0.15, -1), (1, 0), (0.15, 1), (0.15, 0.32), (-1, 0.32)]
        p.addLines(between: pts.map { CGPoint(x: r.midX + s * $0.0 * r.width / 2, y: r.midY + $0.1 * r.height / 2) })
        p.closeSubpath()
    }

    /// Segment `k` (0 = bottom) of a vertical bar gauge.
    private func barSegment(_ bar: CGRect, _ k: Int, _ count: Int) -> CGRect {
        let h = bar.height / CGFloat(count)
        return CGRect(x: bar.minX, y: bar.maxY - CGFloat(k + 1) * h + h * 0.14, width: bar.width, height: h * 0.72)
    }

    // MARK: Drawing helpers

    /// Device pixels per point of the context being drawn (shadow blurs are in device pixels).
    private var pixelScale: CGFloat = 1

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private func color(_ k: (r: CGFloat, g: CGFloat, b: CGFloat), _ a: CGFloat = 1) -> CGColor { rgb(k.r, k.g, k.b, a) }

    /// Lit things glow: a soft halo, then the bright segment.
    private func glowFill(_ c: CGContext, _ path: CGPath, _ k: (r: CGFloat, g: CGFloat, b: CGFloat), alpha: CGFloat = 1,
                          blur: CGFloat) {
        c.saveGState()
        c.setShadow(offset: .zero, blur: blur * pixelScale, color: color(k, 0.9 * alpha))
        c.addPath(path)
        c.setFillColor(color(k, alpha))
        c.fillPath()
        c.restoreGState()
    }

    private static let labelFont = "DINCondensed-Bold"

    private func text(_ s: String, _ p: CGPoint, size: CGFloat, color: CGColor, align: NSTextAlignment = .center) {
        let font = NSFont(name: Self.labelFont, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white,
                                                             .kern: size * 0.06])
        let sz = str.size()
        let x = align == .left ? p.x : (align == .right ? p.x - sz.width : p.x - sz.width / 2)
        // DIN Condensed sits high in its line box; nudge it down to look optically centred.
        str.draw(at: CGPoint(x: x, y: p.y - sz.height / 2 + size * 0.08))
    }

    private func glowText(_ c: CGContext, _ s: String, _ p: CGPoint, size: CGFloat, color: CGColor, blur: CGFloat,
                          align: NSTextAlignment = .center) {
        c.saveGState()
        c.setShadow(offset: .zero, blur: blur * pixelScale, color: color.copy(alpha: color.alpha * 0.8))
        text(s, p, size: size, color: color, align: align)
        c.restoreGState()
    }

    private func linearGradient(_ c: CGContext, _ r: CGRect, _ colors: [CGColor], vertical: Bool = true) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                 locations: nil) else { return }
        c.saveGState()
        c.clip(to: r)
        c.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY),
                             end: vertical ? CGPoint(x: r.minX, y: r.maxY) : CGPoint(x: r.maxX, y: r.minY),
                             options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
        c.restoreGState()
    }

    private func withAppKitContext(_ c: CGContext, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }

    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
    }

    // MARK: Static parts

    /// Every segment of the display: lit (with glow) or as the faint unlit phosphor.
    private func drawSegments(_ c: CGContext, _ l: Layout, lit on: Bool) {
        let u = l.u
        let blur = 0.022 * u
        func fill(_ path: CGPath, _ k: (r: CGFloat, g: CGFloat, b: CGFloat)) {
            if on {
                glowFill(c, path, k, blur: blur)
            } else {
                c.addPath(path)
                c.setFillColor(color(k, 0.075))
                c.fillPath()
            }
        }
        let segments = CGMutablePath()
        for k in 0..<Self.fluxSegments { segments.addRect(barSegment(l.flux, k, Self.fluxSegments)) }
        for bar in l.bars {
            for k in 0..<Self.barSegments { segments.addRect(barSegment(bar, k, Self.barSegments)) }
        }
        for i in 0..<Self.tachColumns {
            let (r, dashes) = tachColumn(l, i)
            let dp = r.height / CGFloat(dashes)
            for j in 0..<dashes {
                segments.addRect(CGRect(x: r.minX, y: r.maxY - CGFloat(j + 1) * dp + dp * 0.15, width: r.width,
                                        height: dp * 0.7))
            }
        }
        l.warp.forEach { segments.addRect($0) }
        for d in l.scaleDots {
            segments.addEllipse(in: CGRect(x: d.x - 0.012 * u, y: d.y - 0.012 * u, width: 0.024 * u, height: 0.024 * u))
        }
        addArrow(segments, l.arrowLeft, left: true)
        addArrow(segments, l.arrowRight, left: false)
        fill(segments, Self.vfd)

        // Warning lamps: coloured windows with their legend in black.
        let names = ["WARP", "TIDAL", "BEAT", "SYS", "MIC", "FILE", "PEAK"]
        for k in 0..<7 {
            let r = k < 6 ? l.lamps[k] : l.peak
            let kind = k < 2 ? Self.pink : (k == 6 ? Self.red : Self.vfd)
            fill(CGPath(roundedRect: r, cornerWidth: 0.012 * u, cornerHeight: 0.012 * u, transform: nil), kind)
            text(names[k], CGPoint(x: r.midX, y: r.midY), size: r.height * 0.62,
                 color: on ? rgb(0.02, 0.05, 0.03, 0.9) : color(kind, 0.12))
        }
        if !on {
            // Ghost eights behind every digit.
            let eights = CGMutablePath()
            for d in l.speedDigits + l.rpmDigits + l.odoDigits { addSevenSegment(eights, d, 0x7F) }
            fill(eights, Self.vfd)
            // The song display's dot field.
            let p = l.dotPitch
            var x = l.dots.minX
            while x < l.dots.maxX - p * 0.5 {
                for r in 0..<DotMatrix.rows {
                    c.addRect(CGRect(x: x, y: l.dots.minY + CGFloat(r) * p, width: p * 0.78, height: p * 0.78))
                }
                x += p
            }
            c.setFillColor(color(Self.vfd, 0.06))
            c.fillPath()
        }
    }

    private func drawStatic(_ c: CGContext, _ l: Layout) {
        let u = l.u, W = l.width
        let top = 0.2 * u
        linearGradient(c, CGRect(x: 0, y: 0, width: W, height: top + 1), [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.6)])

        // The dashboard: black textured plastic, with a soft highlight along its top edge.
        let body = CGRect(x: 0, y: top, width: W, height: l.strip - top)
        linearGradient(c, body, [rgb(0.095, 0.095, 0.1), rgb(0.03, 0.03, 0.034)])
        var rng = LCG(seed: 23)
        for _ in 0..<Int(W * body.height / 30) {
            let x = rng.next() * W, y = top + rng.next() * body.height, s = 0.6 + rng.next()
            c.setFillColor(rgb(1, 1, 1, 0.015 + 0.03 * rng.next()))
            c.fill(CGRect(x: x, y: y, width: s, height: s))
        }
        c.setFillColor(rgb(1, 1, 1, 0.1))
        c.fill(CGRect(x: 0, y: top, width: W, height: max(1, 0.008 * u)))
        c.setFillColor(rgb(0, 0, 0, 0.5))
        c.fill(CGRect(x: 0, y: top + max(1, 0.008 * u), width: W, height: 1))
        for x in [l.hood.minX - 0.7 * u, l.hood.maxX + 0.7 * u] {
            c.setFillColor(rgb(0, 0, 0, 0.55))
            c.fill(CGRect(x: x, y: top, width: 1, height: body.height))
            c.setFillColor(rgb(1, 1, 1, 0.05))
            c.fill(CGRect(x: x + 1, y: top, width: 1, height: body.height))
        }

        // The hood over the cluster, casting its shadow onto the dash.
        let h = l.hood
        let hood = CGMutablePath()
        hood.move(to: CGPoint(x: h.minX, y: h.maxY))
        hood.addLine(to: CGPoint(x: h.minX + 0.03 * u, y: h.minY + 0.12 * u))
        hood.addCurve(to: CGPoint(x: h.midX, y: h.minY), control1: CGPoint(x: h.minX + 0.06 * u, y: h.minY + 0.01 * u),
                      control2: CGPoint(x: h.minX + 0.4 * u, y: h.minY))
        hood.addCurve(to: CGPoint(x: h.maxX - 0.03 * u, y: h.minY + 0.12 * u),
                      control1: CGPoint(x: h.maxX - 0.4 * u, y: h.minY),
                      control2: CGPoint(x: h.maxX - 0.06 * u, y: h.minY + 0.01 * u))
        hood.addLine(to: CGPoint(x: h.maxX, y: h.maxY))
        hood.closeSubpath()
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 0.025 * u * pixelScale), blur: 0.07 * u * pixelScale,
                    color: rgb(0, 0, 0, 0.9))
        c.addPath(hood)
        c.setFillColor(rgb(0.04, 0.04, 0.045))
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(hood)
        c.clip()
        linearGradient(c, h, [rgb(0.12, 0.12, 0.13), rgb(0.05, 0.05, 0.055), rgb(0.025, 0.025, 0.03)])
        c.restoreGState()
        c.addPath(hood)
        c.setLineWidth(max(1, 0.006 * u))
        c.setStrokeColor(rgb(1, 1, 1, 0.09))
        c.strokePath()

        // Recesses: the cluster window and the two small displays below it.
        for r in [l.face, l.odometer, l.song] {
            let radius = r.height > 0.3 * u ? 0.07 * u : 0.025 * u
            let rim = r.insetBy(dx: -0.012 * u, dy: -0.012 * u)
            c.addPath(CGPath(roundedRect: rim, cornerWidth: radius + 0.012 * u, cornerHeight: radius + 0.012 * u,
                             transform: nil))
            c.setFillColor(rgb(0, 0, 0, 0.9))
            c.fillPath()
            let shape = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            c.addPath(shape)
            c.setFillColor(rgb(0.012, 0.02, 0.017))
            c.fillPath()
            // The fine grid of a fluorescent display, barely visible.
            c.saveGState()
            c.addPath(shape)
            c.clip()
            let step = max(2, 0.012 * u)
            var x = r.minX
            while x < r.maxX { c.addRect(CGRect(x: x, y: r.minY, width: 0.5, height: r.height)); x += step }
            var y = r.minY
            while y < r.maxY { c.addRect(CGRect(x: r.minX, y: y, width: r.width, height: 0.5)); y += step }
            c.setFillColor(color(Self.vfd, 0.02))
            c.fillPath()
            c.restoreGState()
        }

        drawSegments(c, l, lit: false)

        // Legends and frames, lit permanently.
        let blur = 0.02 * u
        let legend = color(Self.vfd, 0.9)
        let f = l.face
        func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ align: NSTextAlignment = .center,
                   _ k: CGColor? = nil) {
            glowText(c, s, CGPoint(x: x, y: y), size: size * u, color: k ?? legend, blur: blur, align: align)
        }
        label("FLUX", l.flux.midX + 0.04 * u, l.flux.minY - 0.055 * u, 0.055)
        label("F", l.flux.maxX + 0.05 * u, l.flux.minY + 0.015 * u, 0.045, .left)
        label("1/2", l.flux.maxX + 0.05 * u, l.flux.midY, 0.04, .left)
        label("E", l.flux.maxX + 0.05 * u, l.flux.maxY - 0.015 * u, 0.045, .left)
        label("REACTOR OUTPUT", l.flux.midX + 0.04 * u, f.minY + 0.665 * u, 0.035)
        label("SPEED", l.speedBox.minX - 0.05 * u, l.speedBox.maxY - 0.04 * u, 0.06, .right)
        c.saveGState()
        c.setShadow(offset: .zero, blur: blur * pixelScale, color: color(Self.vfd, 0.8))
        c.setStrokeColor(legend)
        c.setLineWidth(max(1, 0.007 * u))
        c.stroke(l.speedBox)
        let points = CGMutablePath()
        addDecimalPoint(points, l.speedDigits[1])
        addDecimalPoint(points, l.odoDigits[5])
        c.addPath(points)
        c.setFillColor(color(Self.vfd))
        c.fillPath()
        c.restoreGState()
        label("c", l.speedBox.maxX - 0.09 * u, l.speedDigits[0].maxY - 0.04 * u, 0.08)
        label("WARP", l.warp[1].midX, l.speedBox.minY + 0.18 * u, 0.033)
        for (j, s) in ["1", "2", "5", "10", "20", "50"].enumerated() {
            label(s, l.scaleDots[j].x, l.scaleDots[j].y + 0.045 * u, 0.035)
        }
        label("x100 r/min", l.rpmDigits[1].maxX + 0.025 * u, l.rpmDigits[1].maxY - 0.02 * u, 0.034, .left)
        label("TACH", l.tach.minX - 0.04 * u, l.tach.maxY - 0.03 * u, 0.06, .right)
        let pitch = l.tach.width / CGFloat(Self.tachColumns)
        func tachX(_ v: CGFloat) -> CGFloat { l.tach.minX + (v - 0.5) / 7 * (l.tach.width - pitch) + pitch / 2 }
        for (k, s) in ["0.5", "1", "2", "3", "4", "5", "6", "7"].enumerated() {
            label(s, tachX(k == 0 ? 0.5 : CGFloat(k)), l.tach.maxY + 0.045 * u, 0.04)
        }
        label("x1000 r/min", l.tach.maxX + 0.03 * u, l.tach.maxY + 0.045 * u, 0.032, .left)
        // Redline over the top of the rev range.
        let last = tachColumn(l, Self.tachColumns - 1).rect
        c.saveGState()
        c.setShadow(offset: .zero, blur: blur * pixelScale, color: color(Self.red, 0.8))
        c.setFillColor(color(Self.red, 0.9))
        c.fill(CGRect(x: tachX(6.5), y: last.minY - 0.03 * u, width: l.tach.maxX - tachX(6.5), height: max(1, 0.008 * u)))
        c.restoreGState()
        for (k, name) in ["BASS", "MID", "TREB"].enumerated() {
            let b = l.bars[k], m = 0.014 * u
            c.saveGState()
            c.setShadow(offset: .zero, blur: blur * pixelScale, color: color(Self.vfd, 0.7))
            c.addLines(between: [CGPoint(x: b.minX - m + 0.03 * u, y: b.minY - m), CGPoint(x: b.minX - m, y: b.minY - m),
                                 CGPoint(x: b.minX - m, y: b.maxY + m), CGPoint(x: b.maxX + m, y: b.maxY + m),
                                 CGPoint(x: b.maxX + m, y: b.minY - m), CGPoint(x: b.maxX + m - 0.03 * u, y: b.minY - m)])
            c.setStrokeColor(legend)
            c.setLineWidth(max(1, 0.006 * u))
            c.strokePath()
            c.restoreGState()
            label("10", b.minX - 0.03 * u, b.minY + 0.01 * u, 0.03, .right)
            label("5", b.minX - 0.03 * u, b.midY, 0.03, .right)
            label("0", b.minX - 0.03 * u, b.maxY - 0.01 * u, 0.03, .right)
            label(name, b.midX, f.minY + 0.665 * u, 0.04)
        }
        label("LY", l.odometer.minX + 0.55 * u, l.odometer.midY, 0.055, .left)
        label("TRIP", l.odometer.maxX - 0.06 * u, l.odometer.midY, 0.035, .right, color(Self.vfd, 0.6))
        // A note symbol at the start of the song display.
        let note = DotMatrix.glyphColumns(DotMatrix.note)
        let p = l.dotPitch
        let notePath = CGMutablePath()
        for (x, bits) in note.enumerated() {
            for r in 0..<DotMatrix.rows where bits & (1 << r) != 0 {
                notePath.addRect(CGRect(x: l.song.minX + 0.06 * u + CGFloat(x) * p, y: l.dots.minY + CGFloat(r) * p,
                                        width: p * 0.78, height: p * 0.78))
            }
        }
        glowFill(c, notePath, Self.vfd, alpha: 0.9, blur: blur * 0.7)
        c.setFillColor(color(Self.vfd, 0.25))
        c.fill(CGRect(x: l.dots.minX - 0.04 * u, y: l.song.minY + 0.015 * u, width: 1, height: l.song.height - 0.03 * u))
    }

    // MARK: Caches

    /// A pre-rendered image and where it goes.
    private struct Sprite {
        var image: CGImage
        var rect: CGRect
    }

    /// Everything that can be drawn once per window size and scale.
    private struct Caches {
        var size: CGSize
        var scale: CGFloat
        var back: CGImage
        // The lit-segment layer, cut into the pieces that light up together (Core Graphics processes a whole image
        // on every draw, however tightly it is clipped).
        var flux: Sprite, bars: [Sprite], tach: Sprite, warp: Sprite, scaleDots: [Sprite], arrows: [Sprite]
        var lamps: [Sprite]       // the six lamps, then PEAK
        var digits: [[CGImage]]   // 0-9, blank, "-" for the speed, revs and trip digits
        var digitMargin: [CGFloat]
    }

    private var caches: Caches?
    private var songImage: CGImage?
    private var songRendered: String?
    private var songColumns = 0
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders `body` (y-down, in points, from `rect`'s origin) into an image at `scale`.
    private func render(_ rect: CGRect, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let w = max(Int((rect.width * scale).rounded(.up)), 1), h = max(Int((rect.height * scale).rounded(.up)), 1)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: info)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        let previousScale = pixelScale
        pixelScale = scale
        withAppKitContext(ctx) { body(ctx) }
        pixelScale = previousScale
        return ctx.makeImage()
    }

    /// Draws an image upright into `rect` of a y-down context.
    private func drawImage(_ c: CGContext, _ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        guard alpha > 0.01 else { return }
        c.saveGState()
        if alpha < 1 { c.setAlpha(alpha) }
        c.translateBy(x: rect.minX, y: rect.maxY)
        c.scaleBy(x: 1, y: -1)
        c.interpolationQuality = .none
        c.draw(image, in: CGRect(origin: .zero, size: rect.size))
        c.restoreGState()
    }

    private func makeCaches(_ l: Layout, size: CGSize, scale: CGFloat) -> Caches? {
        let u = l.u, g = 0.04 * u
        let strip = CGRect(x: 0, y: 0, width: l.width, height: l.strip)
        guard let back = render(strip, scale: scale, { drawStatic($0, l) }),
              let lit = render(strip, scale: scale, { drawSegments($0, l, lit: true) }) else { return nil }
        func piece(_ r: CGRect) -> Sprite {
            let x0 = (r.minX * scale).rounded(.down), y0 = (r.minY * scale).rounded(.down)
            let px = CGRect(x: x0, y: y0, width: (r.maxX * scale).rounded(.up) - x0, height: (r.maxY * scale).rounded(.up) - y0)
            return Sprite(image: lit.cropping(to: px) ?? lit,
                          rect: CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale,
                                       height: px.height / scale))
        }
        let warp = CGRect(x: l.warp[0].minX - g, y: l.speedBox.minY + 0.01 * u,
                          width: l.warp[2].maxX + 0.012 * u - l.warp[0].minX + g, height: 0.14 * u)
        // (Lamps sit close together: only a little of the glow around each, so as not to light the next one.)
        let lamps = (l.lamps + [l.peak]).map { piece($0.insetBy(dx: -0.012 * u, dy: -g)) }
        let cells = [l.speedDigits[0], l.rpmDigits[0], l.odoDigits[0]]
        let margins = cells.map { $0.height * 0.3 }
        let digits = cells.indices.map { s -> [CGImage] in
            let cell = cells[s], m = margins[s]
            return Self.digitMasks.map { mask in
                render(CGRect(x: 0, y: 0, width: cell.width + 2 * m, height: cell.height + 2 * m), scale: scale) { c in
                    let path = CGMutablePath()
                    self.addSevenSegment(path, CGRect(x: m, y: m, width: cell.width, height: cell.height), mask)
                    self.glowFill(c, path, Self.vfd, blur: cell.height * 0.09)
                }!
            }
        }
        songRendered = nil
        return Caches(size: size, scale: scale, back: back, flux: piece(l.flux.insetBy(dx: -g, dy: -g)),
                      bars: l.bars.map { piece($0.insetBy(dx: -g, dy: -g)) },
                      tach: piece(l.tach.insetBy(dx: -g, dy: -g)), warp: piece(warp),
                      scaleDots: l.scaleDots.map { piece(CGRect(x: $0.x - 0.03 * u, y: $0.y - 0.03 * u, width: 0.06 * u,
                                                                height: 0.06 * u)) },
                      arrows: [piece(l.arrowLeft.insetBy(dx: -g, dy: -g)), piece(l.arrowRight.insetBy(dx: -g, dy: -g))],
                      lamps: lamps, digits: digits, digitMargin: margins)
    }

    /// The message as lit dots, with room around them for the glow.
    private func renderSong(_ text: String, _ l: Layout, scale: CGFloat) {
        var cols = DotMatrix.columns(text)
        if !cols.isEmpty { cols.removeLast() }
        let p = l.dotPitch, m = 2 * p
        songImage = render(CGRect(x: 0, y: 0, width: CGFloat(cols.count) * p + 2 * m, height: 7 * p + 2 * m),
                           scale: scale) { c in
            let path = CGMutablePath()
            for (x, bits) in cols.enumerated() {
                for r in 0..<DotMatrix.rows where bits & (1 << r) != 0 {
                    path.addRect(CGRect(x: m + CGFloat(x) * p, y: m + CGFloat(r) * p, width: p * 0.78, height: p * 0.78))
                }
            }
            self.glowFill(c, path, Self.vfd, blur: p * 0.9)
        }
        songColumns = cols.count
        songRendered = text
    }

    // MARK: Draw

    /// Draws the strip along the bottom of a view of `viewSize`: everything but the glass. `ctx` must be y-down.
    func draw(in ctx: CGContext, viewSize: CGSize) {
        let l = layout(viewSize)
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max((t.a * t.a + t.b * t.b).squareRoot(), 1)
        if caches?.size != viewSize || caches?.scale != scale {
            colorSpace = ctx.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            caches = makeCaches(l, size: viewSize, scale: scale)
        }
        guard let k = caches else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: viewSize.height - l.strip)
        drawImage(ctx, k.back, in: CGRect(x: 0, y: 0, width: l.width, height: l.strip))
        drawDynamic(ctx, l, k)
        ctx.restoreGState()
    }

    private func drawDynamic(_ c: CGContext, _ l: Layout, _ k: Caches) {
        let u = l.u, g = 0.04 * u // room for the glow around lit segments
        // Under tidal stress the whole display flickers.
        let flicker: CGFloat = chaos > 0.02 && Float.random(in: 0...1) < chaos * 0.3 ? 0.35 : 1
        func paint(_ s: Sprite, clip: CGRect? = nil, alpha: CGFloat = 1) {
            guard alpha > 0.01 else { return }
            c.saveGState()
            if let clip { c.clip(to: clip) }
            drawImage(c, s.image, in: s.rect, alpha: alpha)
            c.restoreGState()
        }
        func bar(_ s: Sprite, _ r: CGRect, _ count: Int, _ value: Float, _ peak: Float) {
            let h = r.height / CGFloat(count)
            let n = Int((min(max(value, 0), 1) * Float(count)).rounded())
            if n > 0 {
                paint(s, clip: CGRect(x: r.minX - g, y: r.maxY - CGFloat(n) * h, width: r.width + 2 * g,
                                      height: CGFloat(n) * h + g), alpha: flicker)
            }
            let p = Int((min(max(peak, 0), 1) * Float(count)).rounded())
            if p > n {
                paint(s, clip: CGRect(x: r.minX - g, y: r.maxY - CGFloat(p) * h, width: r.width + 2 * g, height: h),
                      alpha: flicker)
            }
        }
        bar(k.flux, l.flux, Self.fluxSegments, flux.pos, 0)
        for i in 0..<3 { bar(k.bars[i], l.bars[i], Self.barSegments, bars[i].pos, peaks[i]) }

        // Tachometer: every column up to the revs.
        let pitch = l.tach.width / CGFloat(Self.tachColumns)
        let n = min(max(Int(((rpm.pos - 0.5) / 7 * Float(Self.tachColumns - 1)).rounded(.down)) + 1, 0), Self.tachColumns)
        if n > 0 {
            paint(k.tach, clip: CGRect(x: l.tach.minX - g, y: l.tach.minY - g, width: CGFloat(n) * pitch + g,
                                       height: l.tach.height + 2 * g), alpha: flicker)
        }
        let warp = lightSpeeds >= 40 ? 3 : lightSpeeds >= 20 ? 2 : lightSpeeds >= 10 ? 1 : 0
        if warp > 0 {
            paint(k.warp, clip: CGRect(x: l.warp[0].minX - g, y: l.speedBox.minY,
                                       width: l.warp[warp - 1].maxX + 0.012 * u - l.warp[0].minX + g,
                                       height: l.speedBox.height), alpha: flicker)
        }
        let marks: [Float] = [1, 2, 5, 10, 20, 50]
        if let j = marks.lastIndex(where: { lightSpeeds >= $0 }) { paint(k.scaleDots[j], alpha: flicker) }
        k.arrows.forEach { paint($0, alpha: CGFloat(arrows) * flicker) }
        for (i, lamp) in k.lamps.enumerated() { paint(lamp, alpha: CGFloat(lampGlow[i]) * flicker) }

        // Seven-segment readouts.
        func digit(_ size: Int, _ cell: CGRect, _ value: Int) {
            var d = value
            if chaos > 0.02 && Float.random(in: 0...1) < chaos * 0.3 { d = Int.random(in: 0...9) }
            let m = k.digitMargin[size]
            drawImage(c, k.digits[size][d], in: CGRect(x: cell.minX - m, y: cell.minY - m, width: cell.width + 2 * m,
                                                       height: cell.height + 2 * m), alpha: flicker)
        }
        let tenths = min(Int((lightSpeeds * 10).rounded()), 999)
        digit(0, l.speedDigits[0], tenths >= 100 ? tenths / 100 : Self.blank)
        digit(0, l.speedDigits[1], tenths / 10 % 10)
        digit(0, l.speedDigits[2], tenths % 10)
        let hundreds = min(max(Int((rpm.pos * 10).rounded()), 0), 99)
        digit(1, l.rpmDigits[0], hundreds >= 10 ? hundreds / 10 : Self.blank)
        digit(1, l.rpmDigits[1], hundreds % 10)
        var trip = Int(distance * 10) % 10_000_000
        for i in stride(from: 6, through: 0, by: -1) {
            digit(2, l.odoDigits[i], trip % 10)
            trip /= 10
        }

        // The song, or the alarm while tidal forces scramble everything.
        if chaos > 0.02 { alarmText = "!! TIDAL STRESS \(Int(chaos * 100))% !!" }
        let text = chaos > 0.02 ? alarmText : song
        if text != songRendered || songImage == nil { renderSong(text, l, scale: k.scale) }
        guard let image = songImage else { return }
        let p = l.dotPitch, m = 2 * p
        let visible = Int((l.dots.width / p).rounded())
        c.saveGState()
        c.clip(to: l.dots.insetBy(dx: -p, dy: -p))
        let alpha: CGFloat = chaos > 0.02 ? (sin(time * 11) > -0.2 ? 1 : 0.15) : flicker
        func paintSong(_ x: CGFloat) {
            drawImage(c, image, in: CGRect(x: x - m, y: l.dots.minY - m, width: CGFloat(image.width) / k.scale,
                                           height: CGFloat(image.height) / k.scale), alpha: alpha)
        }
        if songColumns <= visible || chaos > 0.02 {
            paintSong(l.dots.minX + (CGFloat(visible - songColumns) / 2).rounded(.down) * p)
        } else {
            // A marquee: steps one dot column at a time, then starts over after a gap.
            let loop = songColumns + 12
            if songScroll >= Double(loop) {
                songScroll = 0
                songHold = 1.5
            }
            let x = l.dots.minX - CGFloat(songScroll.rounded(.down)) * p
            paintSong(x)
            paintSong(x + CGFloat(loop) * p)
        }
        c.restoreGState()
    }

    // MARK: Glass

    /// The smoked glass over the displays, along the bottom of a view. It never changes, so it is drawn once.
    func drawGlass(in c: CGContext, viewSize: CGSize) {
        let l = layout(viewSize)
        let u = l.u
        var rng = LCG(seed: 41)
        c.saveGState()
        c.translateBy(x: 0, y: viewSize.height - l.strip)
        for r in [l.face, l.odometer, l.song] {
            let big = r.height > 0.3 * u
            let radius = big ? 0.07 * u : 0.025 * u
            let shape = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            c.saveGState()
            c.addPath(shape)
            c.clip()
            // Smoked, faintly green-tinted acrylic.
            c.setFillColor(rgb(0, 0.03, 0.02, 0.14))
            c.fill(r)
            // The hood's shadow across the top of the glass.
            linearGradient(c, CGRect(x: r.minX, y: r.minY, width: r.width, height: (big ? 0.2 : 0.05) * u),
                           [rgb(0, 0, 0, 0.6), rgb(0, 0, 0, 0)])
            // Broad slanted reflections of the cabin, as on curved glass.
            func sheen(_ x0: CGFloat, _ w: CGFloat, _ a: CGFloat) {
                let slant = r.height * 0.6
                let band = CGMutablePath()
                band.addLines(between: [CGPoint(x: x0 + slant, y: r.minY), CGPoint(x: x0 + slant + w, y: r.minY),
                                        CGPoint(x: x0 + w, y: r.maxY), CGPoint(x: x0, y: r.maxY)])
                band.closeSubpath()
                c.saveGState()
                c.addPath(band)
                c.clip()
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(1, 1, 1, 0), rgb(1, 1, 1, a), rgb(1, 1, 1, 0)] as CFArray,
                                      locations: [0, 0.5, 1])!
                c.drawLinearGradient(grad, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x0 + w, y: 0), options: [])
                c.restoreGState()
            }
            sheen(r.minX + r.width * 0.08, r.width * 0.16, 0.075)
            sheen(r.minX + r.width * 0.27, r.width * 0.04, 0.05)
            sheen(r.minX + r.width * 0.62, r.width * 0.22, 0.04)
            // A gloss along the upper edge, and the lower edge of the glass catching the light.
            linearGradient(c, CGRect(x: r.minX, y: r.minY + r.height * 0.04, width: r.width, height: r.height * 0.3),
                           [rgb(1, 1, 1, 0.06), rgb(1, 1, 1, 0)])
            linearGradient(c, CGRect(x: r.minX, y: r.maxY - r.height * 0.12, width: r.width, height: r.height * 0.12),
                           [rgb(1, 1, 1, 0), rgb(1, 1, 1, 0.06)])
            // Dust and fine scratches.
            for _ in 0..<Int(r.width * r.height / (0.02 * u * u)) {
                let x = r.minX + rng.next() * r.width, y = r.minY + rng.next() * r.height, s = 0.4 + rng.next() * 0.9
                c.setFillColor(rgb(1, 1, 1, 0.04 + 0.08 * rng.next()))
                c.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
            }
            for _ in 0..<(big ? 9 : 2) {
                let x = r.minX + rng.next() * r.width, y = r.minY + rng.next() * r.height
                let len = (0.05 + rng.next() * 0.25) * u, a = (rng.next() - 0.5) * 0.8
                c.move(to: CGPoint(x: x, y: y))
                c.addCurve(to: CGPoint(x: x + len, y: y + len * a),
                           control1: CGPoint(x: x + len * 0.3, y: y + len * a * 0.2),
                           control2: CGPoint(x: x + len * 0.7, y: y + len * a * 0.5))
                c.setStrokeColor(rgb(1, 1, 1, 0.05 + 0.04 * rng.next()))
                c.setLineWidth(0.5)
                c.strokePath()
            }
            // Smudges.
            for _ in 0..<(big ? 3 : 1) {
                let p = CGPoint(x: r.minX + rng.next() * r.width, y: r.minY + rng.next() * r.height)
                let radius = (0.08 + rng.next() * 0.12) * u
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(1, 1, 1, 0.025), rgb(1, 1, 1, 0)] as CFArray, locations: nil)!
                c.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
            }
            c.restoreGState()
            // A thin bevel where the glass meets its frame.
            c.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius,
                             transform: nil))
            c.setStrokeColor(rgb(1, 1, 1, 0.07))
            c.setLineWidth(1)
            c.strokePath()
        }
        c.restoreGState()
    }
}

/// Transparent overlay that shows the dashboard along the bottom of the space view.
final class DashboardView: NSView {
    let dashboard = Dashboard()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        dashboard.draw(in: ctx, viewSize: bounds.size)
    }

    func refresh() {
        let h = Dashboard.stripHeight(for: bounds.size)
        setNeedsDisplay(NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h))
    }
}

/// The dashboard's glass, in a layer of its own above it: drawn once per size, composited by the GPU.
final class DashboardGlassView: NSView {
    weak var dashboard: Dashboard?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        dashboard?.drawGlass(in: ctx, viewSize: bounds.size)
    }
}

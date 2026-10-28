// Instrument console from an old spacecraft: analog gauges, faders, knobs, levers and lamps,
// all driven by the music. Drawn with Core Graphics in y-down (flipped) coordinates.

import Cocoa

struct PanelInput {
    var bands: [Float]
    var bass: Float
    var mid: Float
    var treble: Float
    var level: Float
    var beat: Float
    var speed: Float
    var hue: Float
    var centroid: Float
    var roll: Float
    var alarm: Float = 0 // tidal stress from a passing black hole: the instruments go haywire
}

final class InstrumentPanel {
    enum Source: Int { case system, mic, file }

    /// Damped spring, so needles and faders move like real hardware (with a little overshoot).
    struct Spring {
        var pos: Float = 0
        var vel: Float = 0

        mutating func step(to target: Float, dt: Float, stiffness: Float = 140, damping: Float = 13) {
            vel += ((target - pos) * stiffness - vel * damping) * dt
            pos += vel * dt
        }
    }

    static let faderCount = 12

    var source = Source.system
    private var gauges = [Spring](repeating: Spring(), count: 3)
    private var velocity = Spring()
    private var faders = [Spring](repeating: Spring(), count: faderCount)
    private var levers = [Spring](repeating: Spring(), count: 2)
    private var knobAngles: [CGFloat] = [0, 0, 0]
    private var beatLamp: Float = 0
    private var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var bass: Float = 0
    private var centroid: Float = 0.5
    private var time: Float = 0
    // Haywire state while a black hole's tidal forces scramble the electronics.
    private(set) var chaos: Float = 0
    private var chaosTargets = [Float](repeating: 0, count: 28)
    // Warm-up/cool-down of everything that glows.
    private var lampGlow = [Float](repeating: 0, count: 4)
    private var bulb: Float = 0 // the little bulbs lighting the VU meters
    private var nixieDigits = [Int](repeating: 0, count: InstrumentPanel.nixieCount)
    private var nixiePrevious = [Int](repeating: 0, count: InstrumentPanel.nixieCount)
    private var nixieAge = [Float](repeating: 1, count: InstrumentPanel.nixieCount)
    private var chaosClock: Float = 0
    private var knobSpin: [CGFloat] = [0, 0, 0]
    private var distance: Double = 0 // travelled, in "AU", shown on the drum counter

    /// Everything that can be drawn once per window size and scale, then stamped every frame.
    private struct Caches {
        var size: CGSize
        var scale: CGFloat
        var strip: CGRect           // the console strip, in its own coordinates
        var back: CGImage           // all that never moves
        var front: CGImage          // unchanging parts lying over moving ones: tube cages and glass, meter shrouds...
        var litFaces: [Sprite]      // meter faces lit by their bulbs at full strength
        var hazedTubes: [Sprite]    // tubes filled with neon haze at full strength
        var lever: Sprite           // throttle grip with its stem and shadow, from the grip's top-left corner
        var cap: Sprite             // fader cap with its shadow, from the cap's top-left corner
        var bulb: Sprite            // a meter bulb with its glow, from its centre
        var dot: Sprite             // the Nixie decimal point, lit, from its top-left corner
        var digits: [Sprite]        // lit Nixie numerals, from the digit box's top-left corner
        var drumDigits: [[CGImage]] // distance counter figures: [white, red][0...9], one drum cell each
        var alarm: [Sprite]         // the alarm banner, dim and flashing, in view coordinates
        var lamps: [Int: Sprite] = [:] // status lamps by kind and warmth step, from the lamp's centre
    }

    /// A pre-rendered image and where it goes, relative to an anchor point.
    private struct Sprite {
        var image: CGImage
        var rect: CGRect
    }

    private var caches: Caches?
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Update

    func update(_ i: PanelInput, dt rawDt: Float) {
        let dt = min(rawDt, 1 / 30)
        time += dt
        chaos = max(i.alarm - 0.1, 0) / 0.9 // ignore the faint pull while it's still far off
        // Under tidal stress every instrument chases new random readings several times a second.
        if chaos > 0.02 {
            chaosClock -= dt
            if chaosClock <= 0 {
                chaosClock = .random(in: 0.04...0.14) / max(chaos, 0.3)
                for k in chaosTargets.indices { chaosTargets[k] = .random(in: -0.1...1.15) }
            }
        }
        func mixed(_ normal: Float, _ k: Int) -> Float { normal + (chaosTargets[k] - normal) * chaos }
        let hard: Float = 1 + 2 * chaos // stiffer springs: needles slam about
        gauges[0].step(to: mixed(i.bass, 0), dt: dt, stiffness: 140 * hard)
        gauges[1].step(to: mixed(i.mid, 1), dt: dt, stiffness: 140 * hard)
        gauges[2].step(to: mixed(i.treble, 2), dt: dt, stiffness: 140 * hard)
        velocity.step(to: mixed(min(i.speed / 1.2, 1), 3), dt: dt, stiffness: 40 * hard * hard, damping: 9)
        let n = i.bands.count
        for k in 0..<Self.faderCount {
            let lo = k * n / Self.faderCount, hi = max((k + 1) * n / Self.faderCount, lo + 1)
            let v = i.bands[lo..<hi].reduce(0, +) / Float(hi - lo)
            faders[k].step(to: mixed(v, 4 + k), dt: dt, stiffness: 260, damping: 24)
        }
        levers[0].step(to: mixed(i.level, 16), dt: dt, stiffness: 50 * hard, damping: 10)
        levers[1].step(to: mixed(i.beat, 17), dt: dt, stiffness: 220, damping: 14)
        for k in 0..<3 {
            knobSpin[k] += CGFloat(chaos * (chaosTargets[18 + k] - 0.5) * 40 * dt)
            knobSpin[k] *= CGFloat(expf(-dt * (chaos > 0.02 ? 0 : 0.8)))
        }
        knobAngles[0] = CGFloat(i.hue) * 2 * .pi + knobSpin[0]
        knobAngles[1] = CGFloat((i.centroid - 0.5) * 2) * .pi * 0.75 + knobSpin[1]
        knobAngles[2] = CGFloat(i.roll) * 3 + knobSpin[2]
        beatLamp = max(beatLamp * expf(-dt * 7), i.beat)

        // Filament lamps glow up quickly and fade out slowly.
        var lit: [Float] = [beatLamp, source == .system ? 1 : 0, source == .mic ? 1 : 0, source == .file ? 1 : 0]
        if chaos > 0.02 {
            for k in lit.indices { lit[k] = chaosTargets[20 + k] > 0.5 ? 1 : lit[k] * (1 - chaos) }
        }
        for k in lit.indices {
            let rate: Float = lit[k] > lampGlow[k] ? 14 : 4
            lampGlow[k] += (lit[k] - lampGlow[k]) * (1 - expf(-dt * rate))
        }
        // Meter bulbs warm up at power-on, hum faintly, and stutter under tidal stress.
        let bulbTarget: Float = (chaos > 0.02 && Float.random(in: 0...1) < chaos * 0.25) ? 0.25 : 1
        bulb += (bulbTarget - bulb) * (1 - expf(-dt * 3)) 

        // Nixie readout, 00.00 c ... 10.00 c: when a digit changes, the new cathode ignites and the old one leaves an afterglow.
        let value = min(max(velocity.pos, 0), 1) * 10
        var digits = Array(String(format: "%04d", Int((value * 100).rounded(.down)))).map { Int(String($0)) ?? 0 }
        if chaos > 0.02 {
            for k in digits.indices where chaosTargets[21 + k] < chaos { digits[k] = Int.random(in: 0...9) }
        }
        for k in digits.indices {
            nixieAge[k] += dt
            if digits[k] != nixieDigits[k] {
                nixiePrevious[k] = nixieDigits[k]
                nixieDigits[k] = digits[k]
                nixieAge[k] = 0
            }
        }
        distance += Double(i.speed * dt) * 2.5
        bands = i.bands
        bass = i.bass
        centroid = i.centroid
    }

    // MARK: Layout

    struct Layout {
        var u: CGFloat           // panel height; everything is sized from it
        var shadow: CGFloat      // shade cast upward onto the view
        var stripHeight: CGFloat // shadow + panel
        var panelTop: CGFloat
        var levers = CGRect.zero, gauges = CGRect.zero, dial = CGRect.zero
        var faders = CGRect.zero, scope = CGRect.zero, knobs = CGRect.zero, lamps = CGRect.zero
    }

    static func panelHeight(for size: CGSize) -> CGFloat {
        max(min(size.height * 0.26, size.width / 10.9, 200), 40)
    }

    private func layout(for size: CGSize) -> Layout {
        let u = Self.panelHeight(for: size)
        let shadow = u * 0.15
        var l = Layout(u: u, shadow: shadow, stripHeight: u + shadow, panelTop: shadow)
        let widths: [CGFloat] = [0.8, 2.34, 1.5, 1.68, 1.4, 1.46, 0.6].map { $0 * u }
        let gap = 0.12 * u
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        var x = (size.width - total) / 2
        let y = shadow + 0.13 * u
        let h = 0.74 * u
        var rects: [CGRect] = []
        for w in widths {
            rects.append(CGRect(x: x, y: y, width: w, height: h))
            x += w + gap
        }
        (l.levers, l.gauges, l.dial, l.faders, l.scope, l.knobs, l.lamps) =
            (rects[0], rects[1], rects[2], rects[3], rects[4], rects[5], rects[6])
        return l
    }

    private func content(_ plate: CGRect, _ u: CGFloat) -> CGRect {
        CGRect(x: plate.minX + 0.06 * u, y: plate.minY + 0.13 * u, width: plate.width - 0.12 * u,
               height: plate.height - 0.17 * u)
    }

    // MARK: Draw

    /// Draws the console along the bottom of a view of `viewSize`. `ctx` must be y-down.
    func draw(in ctx: CGContext, viewSize: CGSize) {
        let l = layout(for: viewSize)
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max((t.a * t.a + t.b * t.b).squareRoot(), 1)
        if caches?.size != viewSize || caches?.scale != scale {
            colorSpace = ctx.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            caches = makeCaches(l, viewSize: viewSize, scale: scale)
        }
        guard var k = caches else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: viewSize.height - l.stripHeight)
        drawImage(ctx, k.back, in: k.strip)
        withAppKitContext(ctx) { drawDynamic(ctx, l, &k) }
        caches = k
        ctx.restoreGState()
        if chaos > 0.02 { withAppKitContext(ctx) { drawAlarm(ctx, viewSize: viewSize) } }
    }

    /// Flashing master alarm across the top of the view while tidal forces grip the ship.
    private func drawAlarm(_ c: CGContext, viewSize: CGSize) {
        let flash = sin(time * 11) > -0.1
        let r = Self.alarmRect(viewSize)
        let a = CGFloat(min(chaos * 2, 1))
        // The banner itself (glow, stripes and frame) is drawn once in each of its two states and faded in.
        if let k = caches { drawSprite(c, k.alarm[flash ? 1 : 0], at: .zero, alpha: a) }
        let color = NSColor(red: 1, green: flash ? 0.92 : 0.35, blue: flash ? 0.85 : 0.3, alpha: a)
        text("⚠  GRAVITATIONAL ANOMALY  —  TIDAL STRESS \(Int(chaos * 100))%  ⚠", CGPoint(x: r.midX, y: r.midY),
             size: r.height * 0.42, color: color)
    }

    private static func alarmRect(_ viewSize: CGSize) -> CGRect {
        let w = min(viewSize.width * 0.62, 760), h = max(44, min(viewSize.height * 0.075, 70))
        return CGRect(x: (viewSize.width - w) / 2, y: viewSize.height * 0.09, width: w, height: h)
    }

    /// The alarm banner without its text, fully faded in.
    private func drawAlarmBanner(_ c: CGContext, _ r: CGRect, flash: Bool) {
        let h = r.height
        let a: CGFloat = 1
        let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        c.saveGState()
        c.setShadow(offset: .zero, blur: flash ? 30 : 8, color: rgb(1, 0.1, 0.05, (flash ? 0.9 : 0.3) * a))
        c.addPath(path)
        c.setFillColor(flash ? rgb(0.55, 0.02, 0.02, 0.85 * a) : rgb(0.12, 0.01, 0.01, 0.75 * a))
        c.fillPath()
        c.restoreGState()
        // Hazard stripes along the top and bottom edges.
        c.saveGState()
        c.addPath(path)
        c.clip()
        c.setFillColor(rgb(1, 0.8, 0.1, 0.8 * a))
        for band in [r.minY, r.maxY - h * 0.12] {
            var x = r.minX - h
            while x < r.maxX {
                c.move(to: CGPoint(x: x, y: band + h * 0.12))
                c.addLine(to: CGPoint(x: x + h * 0.12, y: band))
                c.addLine(to: CGPoint(x: x + h * 0.24, y: band))
                c.addLine(to: CGPoint(x: x + h * 0.12, y: band + h * 0.12))
                c.fillPath()
                x += h * 0.24
            }
        }
        c.restoreGState()
        c.addPath(path)
        c.setStrokeColor(rgb(1, 0.25, 0.2, a))
        c.setLineWidth(2)
        c.strokePath()
    }

    /// Whether the alarm banner (drawn outside the console strip) needs redrawing.
    var alarmActive: Bool { chaos > 0.02 }

    // MARK: Static parts (cached)

    private func drawStatic(_ c: CGContext, _ l: Layout, width: CGFloat) {
        let u = l.u
        let panel = CGRect(x: 0, y: l.panelTop, width: width, height: u)

        // Shade cast onto the space view above the console.
        linearGradient(c, CGRect(x: 0, y: 0, width: width, height: l.shadow),
                       [rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.55)], vertical: true)

        // Painted gunmetal with brushed grain.
        linearGradient(c, panel, [rgb(0.2, 0.215, 0.2), rgb(0.105, 0.115, 0.105)], vertical: true)
        var rng = LCG(seed: 7)
        c.setLineWidth(1)
        var y = panel.minY + 1
        while y < panel.maxY {
            c.setStrokeColor(rgb(1, 1, 1, 0.012 + 0.03 * rng.next()))
            c.move(to: CGPoint(x: 0, y: y))
            c.addLine(to: CGPoint(x: width, y: y))
            c.strokePath()
            y += 1 + 2 * rng.next()
        }
        // Chrome trim along the top edge.
        c.setFillColor(rgb(0.55, 0.57, 0.55))
        c.fill(CGRect(x: 0, y: panel.minY, width: width, height: max(1.5, u * 0.012)))
        c.setFillColor(rgb(0, 0, 0, 0.6))
        c.fill(CGRect(x: 0, y: panel.minY + max(1.5, u * 0.012), width: width, height: 1))
        // Hazard stripes at both ends, where the console meets the hull.
        for side in [CGFloat(0), width - 0.18 * u] {
            let r = CGRect(x: side, y: panel.minY + 0.06 * u, width: 0.18 * u, height: u * 0.88)
            c.saveGState()
            c.clip(to: r)
            c.setFillColor(rgb(0.1, 0.1, 0.09))
            c.fill(r)
            c.setFillColor(rgb(0.78, 0.6, 0.12, 0.85))
            var sx = r.minX - r.height
            while sx < r.maxX {
                c.move(to: CGPoint(x: sx, y: r.maxY))
                c.addLine(to: CGPoint(x: sx + 0.06 * u, y: r.maxY))
                c.addLine(to: CGPoint(x: sx + 0.06 * u + r.height, y: r.minY))
                c.addLine(to: CGPoint(x: sx + r.height, y: r.minY))
                c.fillPath()
                sx += 0.12 * u
            }
            c.restoreGState()
        }

        plate(c, l.levers, u, title: "THROTTLE")
        plate(c, l.gauges, u, title: "SPECTRAL LOAD")
        plate(c, l.dial, u, title: "VELOCITY  ·  c")
        plate(c, l.faders, u, title: "BAND EQUALIZER")
        plate(c, l.scope, u, title: "SCOPE")
        plate(c, l.knobs, u, title: "TRIM")
        plate(c, l.lamps, u, title: "STATUS")

        staticLevers(c, l)
        staticGauges(c, l)
        staticNixies(c, l)
        staticFaders(c, l)
        staticScope(c, l)
        staticKnobs(c, l)
        staticLamps(c, l)

        // A dim cabin: darken all the metalwork so only what's lit really glows.
        c.setFillColor(rgb(0, 0, 0, 0.42))
        c.fill(panel)
    }

    private func plate(_ c: CGContext, _ r: CGRect, _ u: CGFloat, title: String?) {
        let path = CGPath(roundedRect: r, cornerWidth: 0.035 * u, cornerHeight: 0.035 * u, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 0.012 * u), blur: 0.03 * u, color: rgb(0, 0, 0, 0.7))
        c.addPath(path)
        c.setFillColor(rgb(0.15, 0.16, 0.15))
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(path)
        c.clip()
        linearGradient(c, r, [rgb(0.19, 0.2, 0.19), rgb(0.125, 0.135, 0.125)], vertical: true)
        c.restoreGState()
        c.addPath(path)
        c.setStrokeColor(rgb(0, 0, 0, 0.7))
        c.setLineWidth(1)
        c.strokePath()
        c.setStrokeColor(rgb(1, 1, 1, 0.07))
        c.move(to: CGPoint(x: r.minX + 0.04 * u, y: r.maxY - 0.5))
        c.addLine(to: CGPoint(x: r.maxX - 0.04 * u, y: r.maxY - 0.5))
        c.strokePath()
        let inset = 0.04 * u
        for p in [CGPoint(x: r.minX + inset, y: r.minY + inset), CGPoint(x: r.maxX - inset, y: r.minY + inset),
                  CGPoint(x: r.minX + inset, y: r.maxY - inset), CGPoint(x: r.maxX - inset, y: r.maxY - inset)] {
            screw(c, p, 0.02 * u)
        }
        if let title {
            text(title, CGPoint(x: r.midX, y: r.minY + 0.068 * u), size: 0.06 * u, color: paint(0.75))
        }
    }

    private func staticLevers(_ c: CGContext, _ l: Layout) {
        let u = l.u, r = content(l.levers, u)
        for (k, name) in ["THRUST", "PULSE"].enumerated() {
            let slot = leverSlot(r, k, u)
            let path = CGPath(roundedRect: slot, cornerWidth: slot.width / 2, cornerHeight: slot.width / 2,
                              transform: nil)
            c.addPath(path)
            c.setFillColor(rgb(0.03, 0.03, 0.03))
            c.fillPath()
            c.addPath(path)
            c.setStrokeColor(rgb(1, 1, 1, 0.12))
            c.setLineWidth(1)
            c.strokePath()
            for i in 0...4 {
                let y = slot.maxY - slot.height * CGFloat(i) / 4
                c.setStrokeColor(paint(0.5))
                c.move(to: CGPoint(x: slot.maxX + 0.015 * u, y: y))
                c.addLine(to: CGPoint(x: slot.maxX + (i % 2 == 0 ? 0.05 : 0.03) * u, y: y))
                c.strokePath()
            }
            text(name, CGPoint(x: slot.midX, y: r.maxY - 0.035 * u), size: 0.05 * u, color: paint(0.8))
        }
    }

    private func leverSlot(_ r: CGRect, _ k: Int, _ u: CGFloat) -> CGRect {
        let cx = r.minX + r.width * (CGFloat(k) + 0.5) / 2
        return CGRect(x: cx - 0.022 * u, y: r.minY + 0.05 * u, width: 0.044 * u, height: r.height - 0.17 * u)
    }

    private func gaugeFace(_ l: Layout, _ k: Int) -> CGRect {
        let u = l.u, r = content(l.gauges, u)
        let w = (r.width - 0.08 * u * 2) / 3
        return CGRect(x: r.minX + CGFloat(k) * (w + 0.08 * u), y: r.minY + 0.01 * u, width: w, height: r.height - 0.02 * u)
    }

    private func gaugeGeometry(_ face: CGRect) -> (pivot: CGPoint, radius: CGFloat) {
        (CGPoint(x: face.midX, y: face.maxY + face.height * 0.2), face.height * 0.95)
    }

    private func staticGauges(_ c: CGContext, _ l: Layout) {
        let u = l.u
        for (k, name) in ["BASS", "MID", "TREBLE"].enumerated() {
            let outer = gaugeFace(l, k)
            bezelRect(c, outer, u)
            let face = outer.insetBy(dx: 0.025 * u, dy: 0.025 * u)
            let path = CGPath(roundedRect: face, cornerWidth: 0.02 * u, cornerHeight: 0.02 * u, transform: nil)
            c.saveGState()
            c.addPath(path)
            c.clip()
            linearGradient(c, face, [rgb(0.42, 0.39, 0.32), rgb(0.5, 0.45, 0.35)], vertical: true)
            let (pivot, R) = gaugeGeometry(face)
            // Red overload zone.
            c.setStrokeColor(rgb(0.75, 0.12, 0.08))
            c.setLineWidth(0.035 * u)
            c.addArc(center: pivot, radius: R * 0.84, startAngle: gaugeAngle(0.75) - .pi / 2,
                     endAngle: gaugeAngle(1) - .pi / 2, clockwise: false)
            c.strokePath()
            c.setStrokeColor(rgb(0.12, 0.1, 0.08))
            c.setLineWidth(max(1, 0.006 * u))
            c.addArc(center: pivot, radius: R * 0.8, startAngle: gaugeAngle(0) - .pi / 2,
                     endAngle: gaugeAngle(1) - .pi / 2, clockwise: false)
            c.strokePath()
            for i in 0...20 {
                let v = CGFloat(i) / 20
                let a = gaugeAngle(v)
                let major = i % 5 == 0
                c.setLineWidth(major ? max(1.2, 0.01 * u) : max(0.8, 0.005 * u))
                c.move(to: polar(pivot, R * 0.8, a))
                c.addLine(to: polar(pivot, R * (major ? 0.9 : 0.86), a))
                c.strokePath()
                if major {
                    text(["0", "25", "50", "75", "100"][i / 5], polar(pivot, R * 0.98, a), size: 0.05 * u,
                         color: NSColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 1))
                }
            }
            text(name, CGPoint(x: face.midX, y: face.maxY - face.height * 0.2), size: 0.065 * u,
                 color: NSColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 0.9))
            text("%", CGPoint(x: face.midX, y: face.maxY - face.height * 0.42), size: 0.045 * u,
                 color: NSColor(red: 0.15, green: 0.12, blue: 0.1, alpha: 0.6))
            c.restoreGState()
        }
    }

    private func gaugeAngle(_ v: CGFloat) -> CGFloat { (-48 + 96 * v) * .pi / 180 }

    // MARK: Nixie tubes (velocity readout) and distance counter

    static let nixieCount = 4
    private static let neon = (r: CGFloat(1.0), g: CGFloat(0.4), b: CGFloat(0.1))

    /// The tube row (upper part of the plate) and the drum counter row beneath it.
    private func nixieRows(_ l: Layout) -> (tubes: CGRect, counter: CGRect) {
        let r = content(l.dial, l.u)
        let counterH = r.height * 0.27
        return (CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - counterH - 0.02 * l.u),
                CGRect(x: r.minX, y: r.maxY - counterH, width: r.width, height: counterH))
    }

    /// Tall, narrow cylinders like real IN-14 style tubes, centred in the row.
    private func nixieTubes(_ l: Layout) -> [CGRect] {
        let row = nixieRows(l).tubes
        let gap = 0.035 * l.u
        let w = min(row.height * 0.6, (row.width - gap * CGFloat(Self.nixieCount - 1)) / CGFloat(Self.nixieCount))
        let total = w * CGFloat(Self.nixieCount) + gap * CGFloat(Self.nixieCount - 1)
        return (0..<Self.nixieCount).map { k in
            CGRect(x: row.midX - total / 2 + CGFloat(k) * (w + gap), y: row.minY, width: w, height: row.height)
        }
    }

    /// Glass envelope (above the black base).
    private func nixieGlass(_ tube: CGRect) -> CGRect {
        CGRect(x: tube.minX, y: tube.minY + tube.width * 0.12, width: tube.width,
               height: tube.height * 0.9 - tube.width * 0.12)
    }

    private func nixieGlassPath(_ g: CGRect) -> CGPath {
        let p = CGMutablePath()
        let dome = g.width * 0.42
        p.move(to: CGPoint(x: g.minX, y: g.maxY))
        p.addLine(to: CGPoint(x: g.minX, y: g.minY + dome))
        p.addCurve(to: CGPoint(x: g.midX, y: g.minY), control1: CGPoint(x: g.minX, y: g.minY + dome * 0.2),
                   control2: CGPoint(x: g.minX + g.width * 0.2, y: g.minY))
        p.addCurve(to: CGPoint(x: g.maxX, y: g.minY + dome), control1: CGPoint(x: g.maxX - g.width * 0.2, y: g.minY),
                   control2: CGPoint(x: g.maxX, y: g.minY + dome * 0.2))
        p.addLine(to: CGPoint(x: g.maxX, y: g.maxY))
        p.closeSubpath()
        return p
    }

    /// Where the numerals sit inside a tube.
    private func digitBox(_ g: CGRect) -> CGRect {
        let h = g.height * 0.58
        let w = min(h * 0.58, g.width * 0.72)
        return CGRect(x: g.midX - w / 2, y: g.minY + g.height * 0.24, width: w, height: h)
    }

    /// A Nixie numeral as bent wire: strokes in a unit box (x right, y down), then scaled into `box`.
    private func nixieDigit(_ d: Int, in box: CGRect) -> CGPath {
        let p = CGMutablePath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height) }
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            p.addEllipse(in: CGRect(x: box.minX + x * box.width, y: box.minY + y * box.height,
                                    width: w * box.width, height: h * box.height))
        }
        switch d {
        case 0: oval(0.06, 0.02, 0.88, 0.96)
        case 1:
            p.move(to: pt(0.55, 0.98)); p.addLine(to: pt(0.55, 0.02)); p.addLine(to: pt(0.28, 0.2))
        case 2:
            p.move(to: pt(0.1, 0.24))
            p.addCurve(to: pt(0.5, 0.02), control1: pt(0.1, 0.1), control2: pt(0.28, 0.02))
            p.addCurve(to: pt(0.9, 0.27), control1: pt(0.74, 0.02), control2: pt(0.9, 0.12))
            p.addCurve(to: pt(0.08, 0.98), control1: pt(0.9, 0.5), control2: pt(0.3, 0.7))
            p.addLine(to: pt(0.94, 0.98))
        case 3:
            p.move(to: pt(0.08, 0.15))
            p.addCurve(to: pt(0.5, 0.02), control1: pt(0.2, 0.05), control2: pt(0.34, 0.02))
            p.addCurve(to: pt(0.86, 0.25), control1: pt(0.74, 0.02), control2: pt(0.86, 0.12))
            p.addCurve(to: pt(0.4, 0.47), control1: pt(0.86, 0.4), control2: pt(0.62, 0.47))
            p.addCurve(to: pt(0.92, 0.72), control1: pt(0.7, 0.47), control2: pt(0.92, 0.56))
            p.addCurve(to: pt(0.5, 0.98), control1: pt(0.92, 0.88), control2: pt(0.74, 0.98))
            p.addCurve(to: pt(0.06, 0.84), control1: pt(0.3, 0.98), control2: pt(0.14, 0.93))
        case 4:
            p.move(to: pt(0.72, 0.98)); p.addLine(to: pt(0.72, 0.02)); p.addLine(to: pt(0.05, 0.7))
            p.addLine(to: pt(0.95, 0.7))
        case 5:
            p.move(to: pt(0.88, 0.02)); p.addLine(to: pt(0.2, 0.02)); p.addLine(to: pt(0.13, 0.46))
            p.addCurve(to: pt(0.52, 0.36), control1: pt(0.26, 0.39), control2: pt(0.38, 0.36))
            p.addCurve(to: pt(0.92, 0.67), control1: pt(0.78, 0.36), control2: pt(0.92, 0.5))
            p.addCurve(to: pt(0.5, 0.98), control1: pt(0.92, 0.86), control2: pt(0.74, 0.98))
            p.addCurve(to: pt(0.06, 0.84), control1: pt(0.3, 0.98), control2: pt(0.14, 0.93))
        case 6:
            p.move(to: pt(0.82, 0.06))
            p.addCurve(to: pt(0.1, 0.66), control1: pt(0.4, 0.12), control2: pt(0.1, 0.38))
            oval(0.1, 0.4, 0.82, 0.58)
        case 7:
            p.move(to: pt(0.06, 0.02)); p.addLine(to: pt(0.94, 0.02)); p.addLine(to: pt(0.36, 0.98))
        case 8:
            oval(0.17, 0.02, 0.66, 0.43); oval(0.08, 0.45, 0.84, 0.53)
        default: // 9
            oval(0.08, 0.02, 0.82, 0.58)
            p.move(to: pt(0.9, 0.34))
            p.addCurve(to: pt(0.18, 0.94), control1: pt(0.9, 0.62), control2: pt(0.6, 0.88))
        }
        return p
    }

    private func nixieMesh(_ c: CGContext, _ g: CGRect, _ color: CGColor) {
        let cell = max(2.5, g.width * 0.085)
        c.setStrokeColor(color)
        c.setLineWidth(0.5)
        let top = g.minY + g.height * 0.18, bottom = g.maxY - g.height * 0.1
        var row = 0
        var y = top
        while y < bottom {
            var x = g.minX + (row % 2 == 0 ? 0 : cell * 0.5)
            while x < g.maxX {
                let hex = CGMutablePath()
                for k in 0..<6 {
                    let a = CGFloat(k) / 6 * 2 * .pi + .pi / 6
                    let q = CGPoint(x: x + cos(a) * cell * 0.5, y: y + sin(a) * cell * 0.5)
                    k == 0 ? hex.move(to: q) : hex.addLine(to: q)
                }
                hex.closeSubpath()
                c.addPath(hex)
                x += cell
            }
            y += cell * 0.87
            row += 1
        }
        c.strokePath()
    }

    private func staticNixies(_ c: CGContext, _ l: Layout) {
        let u = l.u
        for tube in nixieTubes(l) {
            let g = nixieGlass(tube)
            // Black phenolic base with leads running down into the panel.
            let base = CGRect(x: tube.minX + tube.width * 0.04, y: g.maxY - 0.004 * u, width: tube.width * 0.92,
                              height: tube.maxY - g.maxY)
            c.setStrokeColor(rgb(0.55, 0.5, 0.42))
            c.setLineWidth(max(0.8, 0.004 * u))
            for k in 0..<4 {
                let x = base.minX + base.width * (0.2 + 0.2 * CGFloat(k))
                c.move(to: CGPoint(x: x, y: base.maxY - 1))
                c.addLine(to: CGPoint(x: x, y: base.maxY + 0.02 * u))
            }
            c.strokePath()
            c.addPath(CGPath(roundedRect: base, cornerWidth: base.height * 0.3, cornerHeight: base.height * 0.3, transform: nil))
            c.setFillColor(rgb(0.06, 0.05, 0.05))
            c.fillPath()
            linearGradient(c, base, [rgb(1, 1, 1, 0.12), rgb(1, 1, 1, 0)], vertical: true)

            let path = nixieGlassPath(g)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 0.01 * u), blur: 0.025 * u, color: rgb(0, 0, 0, 0.8))
            c.addPath(path)
            c.setFillColor(rgb(0.045, 0.035, 0.03))
            c.fillPath()
            c.restoreGState()

            c.saveGState()
            c.addPath(path)
            c.clip()
            // Mirror-like getter flash in the dome.
            let getter = CGRect(x: g.minX, y: g.minY, width: g.width, height: g.width * 0.5)
            linearGradient(c, getter, [rgb(0.42, 0.42, 0.45, 0.8), rgb(0.2, 0.2, 0.22, 0)], vertical: true)
            // Back half of the anode cage.
            nixieMesh(c, g, rgb(0.45, 0.4, 0.34, 0.22))
            // Support rods and the two mica spacers.
            let box = digitBox(g)
            c.setStrokeColor(rgb(0.5, 0.48, 0.45, 0.55))
            c.setLineWidth(max(0.7, 0.004 * u))
            for x in [g.minX + g.width * 0.1, g.maxX - g.width * 0.1] {
                c.move(to: CGPoint(x: x, y: box.minY - g.height * 0.08))
                c.addLine(to: CGPoint(x: x, y: g.maxY))
            }
            c.strokePath()
            for y in [box.minY - g.height * 0.08, box.maxY + g.height * 0.07] {
                let mica = CGRect(x: g.minX + g.width * 0.04, y: y - g.width * 0.06, width: g.width * 0.92, height: g.width * 0.12)
                c.setFillColor(rgb(0.82, 0.76, 0.64, 0.28))
                c.fillEllipse(in: mica)
                c.setStrokeColor(rgb(0.9, 0.85, 0.75, 0.35))
                c.setLineWidth(0.6)
                c.strokeEllipse(in: mica)
            }
            // The stack of unlit cathodes: every digit's wire, each a little deeper in the tube.
            c.setLineCap(.round)
            c.setLineJoin(.round)
            for (depth, d) in [1, 7, 4, 2, 5, 3, 9, 6, 0, 8].enumerated() {
                let k = CGFloat(depth) * 0.012
                let b = box.insetBy(dx: box.width * k, dy: box.height * k)
                c.addPath(nixieDigit(d, in: b))
                c.setStrokeColor(rgb(0.55, 0.5, 0.46, 0.22))
                c.setLineWidth(max(0.6, box.height * 0.022))
                c.strokePath()
            }
            c.restoreGState()
            c.addPath(path)
            c.setStrokeColor(rgb(0.7, 0.66, 0.6, 0.45))
            c.setLineWidth(1)
            c.strokePath()
            // Tip-off nub on top of the dome.
            let nub = CGRect(x: g.midX - g.width * 0.06, y: g.minY - g.width * 0.1, width: g.width * 0.12, height: g.width * 0.13)
            c.addPath(CGPath(roundedRect: nub, cornerWidth: nub.width / 2, cornerHeight: nub.width / 2, transform: nil))
            c.setFillColor(rgb(0.35, 0.33, 0.3, 0.8))
            c.fillPath()
        }

        // Drum counter window for the distance travelled.
        let row = nixieRows(l).counter
        text("DIST", CGPoint(x: row.minX + 0.05 * u, y: row.midY - row.height * 0.18), size: row.height * 0.38, color: paint(0.75))
        text("AU", CGPoint(x: row.minX + 0.05 * u, y: row.midY + row.height * 0.24), size: row.height * 0.32, color: paint(0.55))
        let win = counterWindow(l)
        bezelRect(c, win.insetBy(dx: -0.012 * u, dy: -0.012 * u), u)
        c.setFillColor(rgb(0.02, 0.02, 0.02))
        c.fill(win)
        // The drums themselves (their figures are drawn every frame).
        let n = counterDigits(win)
        let dw = win.width / CGFloat(n)
        for i in 0..<n {
            let cell = CGRect(x: win.minX + CGFloat(i) * dw, y: win.minY, width: dw, height: win.height)
            linearGradient(c, cell.insetBy(dx: 1, dy: 0), [rgb(0.05, 0.05, 0.05), rgb(0.16, 0.16, 0.15), rgb(0.05, 0.05, 0.05)],
                           vertical: true)
        }
    }

    /// The counter window spans the whole row beneath the tubes (after the DIST/AU label).
    private func counterWindow(_ l: Layout) -> CGRect {
        let row = nixieRows(l).counter
        let x = row.minX + 0.12 * l.u
        return CGRect(x: x, y: row.minY + row.height * 0.04, width: row.maxX - x, height: row.height * 0.92)
    }

    /// As many drums as fit at a natural drum shape.
    private func counterDigits(_ win: CGRect) -> Int { min(max(Int(win.width / (win.height * 0.66)), 6), 12) }

    private func faderColumns(_ l: Layout) -> (rect: CGRect, width: CGFloat) {
        let r = content(l.faders, l.u)
        return (r, r.width / CGFloat(Self.faderCount))
    }

    private func faderTrack(_ l: Layout, _ k: Int) -> (x: CGFloat, top: CGFloat, bottom: CGFloat) {
        let (r, cw) = faderColumns(l)
        return (r.minX + cw * (CGFloat(k) + 0.5), r.minY + 0.04 * l.u, r.maxY - 0.11 * l.u)
    }

    private func staticFaders(_ c: CGContext, _ l: Layout) {
        let u = l.u
        let (r, cw) = faderColumns(l)
        for k in 0..<Self.faderCount {
            let t = faderTrack(l, k)
            for i in 0...8 {
                let y = t.bottom - (t.bottom - t.top) * CGFloat(i) / 8
                c.setStrokeColor(paint(i % 4 == 0 ? 0.55 : 0.3))
                c.setLineWidth(1)
                c.move(to: CGPoint(x: t.x - cw * 0.42, y: y))
                c.addLine(to: CGPoint(x: t.x - cw * 0.2, y: y))
                c.strokePath()
            }
            let slot = CGRect(x: t.x - 0.009 * u, y: t.top - 0.01 * u, width: 0.018 * u,
                              height: t.bottom - t.top + 0.02 * u)
            c.addPath(CGPath(roundedRect: slot, cornerWidth: slot.width / 2, cornerHeight: slot.width / 2,
                             transform: nil))
            c.setFillColor(rgb(0.02, 0.02, 0.02))
            c.fillPath()
            let f = AudioAnalyzer.bandFrequency((Float(k) + 0.5) * Float(AudioAnalyzer.bandCount) / Float(Self.faderCount))
            let label = f < 1000 ? "\(Int(f.rounded()))" : (f < 10000 ? String(format: "%.1fK", f / 1000)
                                                                          : String(format: "%.0fK", f / 1000))
            text(label, CGPoint(x: t.x, y: r.maxY - 0.04 * u), size: min(0.045 * u, cw * 0.5), color: paint(0.7))
        }
    }

    private func scopeScreen(_ l: Layout) -> CGRect {
        content(l.scope, l.u).insetBy(dx: 0.01 * l.u, dy: 0.005 * l.u)
    }

    private func staticScope(_ c: CGContext, _ l: Layout) {
        let u = l.u
        let s = scopeScreen(l)
        bezelRect(c, s.insetBy(dx: -0.025 * u, dy: -0.025 * u), u)
        let path = CGPath(roundedRect: s, cornerWidth: 0.05 * u, cornerHeight: 0.05 * u, transform: nil)
        c.saveGState()
        c.addPath(path)
        c.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgb(0.04, 0.13, 0.07), rgb(0.01, 0.035, 0.02)] as CFArray, locations: nil)!
        c.drawRadialGradient(grad, startCenter: CGPoint(x: s.midX, y: s.midY), startRadius: 0,
                             endCenter: CGPoint(x: s.midX, y: s.midY), endRadius: s.width * 0.65, options: [])
        c.setStrokeColor(rgb(0.35, 1, 0.55, 0.12))
        c.setLineWidth(1)
        for i in 1..<8 {
            let x = s.minX + s.width * CGFloat(i) / 8
            c.move(to: CGPoint(x: x, y: s.minY))
            c.addLine(to: CGPoint(x: x, y: s.maxY))
        }
        for i in 1..<4 {
            let y = s.minY + s.height * CGFloat(i) / 4
            c.move(to: CGPoint(x: s.minX, y: y))
            c.addLine(to: CGPoint(x: s.maxX, y: y))
        }
        c.strokePath()
        c.restoreGState()
    }

    private func knobGeometry(_ l: Layout, _ k: Int) -> (center: CGPoint, radius: CGFloat) {
        let r = content(l.knobs, l.u)
        let cw = r.width / 3
        let radius = min(cw * 0.3, 0.12 * l.u)
        return (CGPoint(x: r.minX + cw * (CGFloat(k) + 0.5), y: r.minY + r.height * 0.42), radius)
    }

    private func staticKnobs(_ c: CGContext, _ l: Layout) {
        let u = l.u
        for (k, name) in ["HUE", "TONE", "ROLL"].enumerated() {
            let (center, kr) = knobGeometry(l, k)
            c.setStrokeColor(paint(0.6))
            for i in 0...10 {
                let a = (-135 + 27 * CGFloat(i)) * .pi / 180
                c.setLineWidth(i % 5 == 0 ? 1.6 : 1)
                c.move(to: polar(center, kr * 1.22, a))
                c.addLine(to: polar(center, kr * (i % 5 == 0 ? 1.45 : 1.36), a))
                c.strokePath()
            }
            // Knurled body with a shadow.
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 0.015 * u), blur: 0.03 * u, color: rgb(0, 0, 0, 0.8))
            c.addEllipse(in: CGRect(x: center.x - kr, y: center.y - kr, width: 2 * kr, height: 2 * kr))
            c.setFillColor(rgb(0.08, 0.08, 0.08))
            c.fillPath()
            c.restoreGState()
            c.setStrokeColor(rgb(0.3, 0.3, 0.3))
            c.setLineWidth(1)
            for i in 0..<40 {
                let a = CGFloat(i) / 40 * 2 * .pi
                c.move(to: polar(center, kr * 0.86, a))
                c.addLine(to: polar(center, kr, a))
            }
            c.strokePath()
            let cap = kr * 0.78
            c.saveGState()
            c.addEllipse(in: CGRect(x: center.x - cap, y: center.y - cap, width: 2 * cap, height: 2 * cap))
            c.clip()
            linearGradient(c, CGRect(x: center.x - cap, y: center.y - cap, width: 2 * cap, height: 2 * cap),
                           [rgb(0.42, 0.42, 0.41), rgb(0.14, 0.14, 0.14)], vertical: true)
            c.restoreGState()
            text(name, CGPoint(x: center.x, y: center.y + kr * 1.45 + 0.06 * u), size: 0.05 * u, color: paint(0.8))
        }
    }

    private func lampGeometry(_ l: Layout) -> [(center: CGPoint, radius: CGFloat, name: String)] {
        let u = l.u, r = content(l.lamps, u)
        var out: [(CGPoint, CGFloat, String)] = [(CGPoint(x: r.minX + 0.08 * u, y: r.minY + 0.09 * u), 0.055 * u, "BEAT")]
        let rowTop = r.minY + 0.25 * u
        for (i, name) in ["SYS", "MIC", "FILE"].enumerated() {
            out.append((CGPoint(x: r.minX + 0.08 * u, y: rowTop + CGFloat(i) * 0.11 * u), 0.03 * u, name))
        }
        return out
    }

    private func staticLamps(_ c: CGContext, _ l: Layout) {
        let u = l.u
        for (i, lamp) in lampGeometry(l).enumerated() {
            let br = lamp.radius * 1.35
            c.addEllipse(in: CGRect(x: lamp.center.x - br, y: lamp.center.y - br, width: 2 * br, height: 2 * br))
            c.setFillColor(rgb(0.3, 0.31, 0.3))
            c.fillPath()
            c.addEllipse(in: CGRect(x: lamp.center.x - br, y: lamp.center.y - br, width: 2 * br, height: 2 * br))
            c.setStrokeColor(rgb(0, 0, 0, 0.8))
            c.setLineWidth(1)
            c.strokePath()
            text(lamp.name, CGPoint(x: lamp.center.x + br + 0.025 * u, y: lamp.center.y), size: 0.05 * u,
                 color: paint(0.8), alignLeft: true)
        }
    }

    // MARK: Moving parts (every frame)

    private func drawDynamic(_ c: CGContext, _ l: Layout, _ k: inout Caches) {
        let u = l.u

        // Throttle levers.
        for i in 0..<2 {
            let slot = leverSlot(content(l.levers, u), i, u)
            let v = CGFloat(min(max(levers[i].pos, 0), 1.05))
            let y = slot.maxY - slot.width / 2 - v * (slot.height - slot.width)
            drawSprite(c, k.lever, at: CGPoint(x: slot.midX - 0.11 * u, y: y - 0.035 * u))
        }

        // VU gauges.
        for i in 0..<3 {
            let face = gaugeFace(l, i).insetBy(dx: 0.025 * u, dy: 0.025 * u)
            let (pivot, R) = gaugeGeometry(face)
            // Light from one small warm bulb behind the bottom-centre of the face, faded in over the unlit face.
            let b = CGFloat(bulb) * CGFloat(Float.random(in: 0.97...1.0))
            drawSprite(c, k.litFaces[i], at: .zero, alpha: b)
            c.saveGState()
            c.addPath(CGPath(roundedRect: face, cornerWidth: 0.02 * u, cornerHeight: 0.02 * u, transform: nil))
            c.clip()
            let a = gaugeAngle(CGFloat(min(max(gauges[i].pos, -0.03), 1.06)))
            // The needle casts a long shadow away from the bulb: soft lines (blurring it every frame costs too much).
            let needleW = max(1.2, 0.009 * u), soft = 0.006 * u
            let shadowPivot = CGPoint(x: pivot.x, y: pivot.y - 0.012 * u)
            c.setLineCap(.round)
            for (extra, alpha) in [(CGFloat(3), CGFloat(0.14)), (1.2, 0.22)] {
                c.setStrokeColor(rgb(0, 0, 0, alpha))
                c.setLineWidth(needleW + extra * soft)
                c.move(to: shadowPivot)
                c.addLine(to: polar(shadowPivot, R * 0.94, a))
                c.strokePath()
            }
            c.setLineCap(.butt)
            c.setStrokeColor(rgb(0.12, 0.08, 0.06))
            c.setLineWidth(needleW)
            c.move(to: pivot)
            c.addLine(to: polar(pivot, R * 0.94, a))
            c.strokePath()
            // Shroud along the bottom hiding the bulb, and the glass (cached); the bulb peeks over the shroud.
            drawFront(c, k)
            drawSprite(c, k.bulb, at: CGPoint(x: face.midX, y: face.maxY - face.height * 0.1), alpha: b)
            c.restoreGState()
        }

        // Velocity on the Nixie tubes, "00.00" to "10.00" (fractions of light speed). Under tidal stress they scramble.
        for (i, tube) in nixieTubes(l).enumerated() {
            let g = nixieGlass(tube)
            let box = digitBox(g)
            let lit = CGFloat(Float.random(in: 0.92...1.0)) * (chaos > 0.02 && Float.random(in: 0...1) < chaos * 0.3 ? 0.2 : 1)
            // Neon haze filling the glass around the glowing cathode.
            drawSprite(c, k.hazedTubes[i], at: .zero, alpha: lit)
            // The glass has straight sides and the digits sit well below its dome: a rectangular clip does the same
            // job as the glass outline here, and is far cheaper to draw through.
            c.saveGState()
            c.clip(to: g)
            // The previous cathode's afterglow, then the new one igniting.
            let age = CGFloat(nixieAge[i])
            let ignite = min(age / 0.06, 1) * lit
            let after = max(1 - age / 0.18, 0) * 0.6 * lit
            for (d, glow) in [(nixiePrevious[i], after), (nixieDigits[i], ignite)] where glow > 0.01 {
                drawSprite(c, k.digits[d], at: box.origin, alpha: glow)
            }
            // Decimal point cathode after the second digit.
            if i == 1 {
                let r = box.height * 0.045
                drawSprite(c, k.dot, at: CGPoint(x: g.maxX - g.width * 0.13 - r, y: box.maxY - r), alpha: lit)
            }
            drawFront(c, k) // the cage and glass in front
            c.restoreGState()
        }

        // Distance drum counter: white figures on black drums; the last drum rolls continuously.
        let win = counterWindow(l)
        let n = counterDigits(win)
        let dw = win.width / CGFloat(n)
        let whole = Int(distance)
        let frac = CGFloat(distance - Double(whole))
        c.saveGState()
        c.clip(to: win)
        for i in 0..<n {
            let place = n - 1 - i
            let power = Int(pow(10.0, Double(place)))
            let digit = (whole / power) % 10
            // Only the last drum rolls smoothly; the others flip when the one to their right wraps (like a real counter).
            var roll: CGFloat = place == 0 ? frac : 0
            if place > 0 && (whole % power) == power - 1 { roll = frac }
            for (offset, value) in [(CGFloat(0), digit), (CGFloat(1), (digit + 1) % 10)] {
                let y = win.minY + (offset - roll) * win.height
                drawImage(c, k.drumDigits[i == n - 1 ? 1 : 0][value],
                          in: CGRect(x: win.minX + CGFloat(i) * dw, y: y, width: dw, height: win.height))
            }
        }
        drawFront(c, k) // the gaps between drums and their curvature
        c.restoreGState()

        // Fader caps.
        let (_, cw) = faderColumns(l)
        for i in 0..<Self.faderCount {
            let t = faderTrack(l, i)
            let v = CGFloat(min(max(faders[i].pos, 0), 1))
            let y = t.bottom - v * (t.bottom - t.top)
            let capW = min(cw * 0.72, 0.075 * u), capH = 0.05 * u
            drawSprite(c, k.cap, at: CGPoint(x: t.x - capW / 2, y: y - capH / 2))
        }

        // Scope traces: spectrum, plus a bass-driven sine sweep.
        let s = scopeScreen(l)
        c.saveGState()
        c.addPath(CGPath(roundedRect: s, cornerWidth: 0.05 * u, cornerHeight: 0.05 * u, transform: nil))
        c.clip()
        let spectrum = CGMutablePath()
        for (i, v) in bands.enumerated() {
            let p = CGPoint(x: s.minX + s.width * CGFloat(i) / CGFloat(max(bands.count - 1, 1)),
                            y: s.maxY - s.height * (0.08 + 0.8 * CGFloat(v)))
            i == 0 ? spectrum.move(to: p) : spectrum.addLine(to: p)
        }
        let wave = CGMutablePath()
        let cycles = 2 + Double(centroid) * 6
        for i in 0...80 {
            let t = Double(i) / 80
            let y = s.midY - s.height * 0.32 * CGFloat(bass) * CGFloat(sin(t * cycles * 2 * .pi - Double(time) * 6))
            let p = CGPoint(x: s.minX + s.width * CGFloat(t), y: y)
            i == 0 ? wave.move(to: p) : wave.addLine(to: p)
        }
        if chaos > 0.02 {
            // Signal breaks up into noise.
            let noise = CGMutablePath()
            for i in 0...120 {
                let p = CGPoint(x: s.minX + s.width * CGFloat(i) / 120,
                                y: s.midY + s.height * 0.45 * CGFloat(chaos) * CGFloat.random(in: -1...1))
                i == 0 ? noise.move(to: p) : noise.addLine(to: p)
            }
            spectrum.addPath(noise)
        }
        for (path, alpha) in [(wave, CGFloat(0.45)), (spectrum, 1)] {
            c.addPath(path)
            c.setStrokeColor(rgb(0.4, 1, 0.6, 0.18 * alpha))
            c.setLineWidth(0.03 * u)
            c.strokePath()
            c.addPath(path)
            c.setStrokeColor(rgb(0.6, 1, 0.72, 0.95 * alpha))
            c.setLineWidth(max(1, 0.008 * u))
            c.strokePath()
        }
        drawFront(c, k) // scanlines and glass
        if chaos > 0.02 && sin(time * 14) > -0.2 {
            c.setFillColor(rgb(0.6, 0.02, 0.02, 0.45 * CGFloat(chaos)))
            c.fill(s)
            text("WARNING", CGPoint(x: s.midX, y: s.midY - s.height * 0.14), size: s.height * 0.3,
                 color: NSColor(red: 1, green: 0.25, blue: 0.2, alpha: 1))
            text("TIDAL STRESS \(Int(chaos * 100))%", CGPoint(x: s.midX, y: s.midY + s.height * 0.22),
                 size: s.height * 0.16, color: NSColor(red: 1, green: 0.5, blue: 0.4, alpha: 1))
        }
        c.restoreGState()

        // Knob pointers.
        for i in 0..<3 {
            let (center, kr) = knobGeometry(l, i)
            c.setStrokeColor(rgb(0.95, 0.93, 0.85))
            c.setLineWidth(max(1.5, 0.012 * u))
            c.setLineCap(.round)
            c.move(to: polar(center, kr * 0.25, knobAngles[i]))
            c.addLine(to: polar(center, kr * 0.72, knobAngles[i]))
            c.strokePath()
        }
        c.setLineCap(.butt)

        // Lamps: each kind and warmth step (of 16) is drawn once, glow and all.
        for (i, lamp) in lampGeometry(l).enumerated() {
            let step = Int((CGFloat(min(max(lampGlow[i], 0), 1)) * 16).rounded())
            let key = (i == 0 ? 0 : 100) + step
            if k.lamps[key] == nil { k.lamps[key] = makeLamp(i, lamp.radius, on: CGFloat(step) / 16, scale: k.scale) }
            if let sprite = k.lamps[key] { drawSprite(c, sprite, at: lamp.center) }
        }
    }

    // MARK: Caches

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
        withAppKitContext(ctx) { body(ctx) }
        return ctx.makeImage()
    }

    /// A sprite of what `body` draws within `bounds`, positioned relative to `anchor`.
    private func makeSprite(_ bounds: CGRect, anchor: CGPoint, scale: CGFloat, _ body: (CGContext) -> Void) -> Sprite {
        let r = bounds.integral
        let image = render(r, scale: scale, body) ?? render(CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1) { _ in }!
        return Sprite(image: image, rect: r.offsetBy(dx: -anchor.x, dy: -anchor.y))
    }

    /// Draws an image upright into `rect` of a y-down context.
    private func drawImage(_ c: CGContext, _ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        guard alpha > 0.002 else { return }
        c.saveGState()
        if alpha < 1 { c.setAlpha(alpha) }
        c.translateBy(x: rect.minX, y: rect.maxY)
        c.scaleBy(x: 1, y: -1)
        c.interpolationQuality = .none
        c.draw(image, in: CGRect(origin: .zero, size: rect.size))
        c.restoreGState()
    }

    private func drawSprite(_ c: CGContext, _ sprite: Sprite, at anchor: CGPoint, alpha: CGFloat = 1) {
        drawImage(c, sprite.image, in: sprite.rect.offsetBy(dx: anchor.x, dy: anchor.y), alpha: alpha)
    }

    /// Paints the front layer (within the current clip).
    private func drawFront(_ c: CGContext, _ k: Caches) {
        drawImage(c, k.front, in: k.strip)
    }

    private func makeCaches(_ l: Layout, viewSize: CGSize, scale: CGFloat) -> Caches? {
        let u = l.u
        let strip = CGRect(x: 0, y: 0, width: viewSize.width, height: l.stripHeight)
        guard let back = render(strip, scale: scale, { drawStatic($0, l, width: viewSize.width) }),
              let front = render(strip, scale: scale, { drawFronts($0, l) }) else { return nil }
        // The unlit panel under a glow, so the glow can be faded in over it.
        func lit(_ r: CGRect, _ shape: CGPath, _ effect: (CGContext) -> Void) -> Sprite {
            makeSprite(r, anchor: .zero, scale: scale) { c in
                c.addPath(shape)
                c.clip()
                self.drawImage(c, back, in: strip)
                effect(c)
            }
        }
        let litFaces = (0..<3).map { i -> Sprite in
            let face = gaugeFace(l, i).insetBy(dx: 0.025 * u, dy: 0.025 * u)
            let bulbAt = CGPoint(x: face.midX, y: face.maxY - face.height * 0.04)
            return lit(face, CGPath(roundedRect: face, cornerWidth: 0.02 * u, cornerHeight: 0.02 * u, transform: nil)) { c in
                c.setBlendMode(.screen)
                let light = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                       colors: [rgb(1, 0.78, 0.45, 0.55), rgb(0.95, 0.6, 0.28, 0.3),
                                                rgb(0.8, 0.45, 0.2, 0)] as CFArray, locations: [0, 0.45, 1])!
                c.drawRadialGradient(light, startCenter: bulbAt, startRadius: 0, endCenter: bulbAt,
                                     endRadius: face.height * 1.15, options: [])
            }
        }
        let (nr, ng, nb) = Self.neon
        let tubes = nixieTubes(l)
        let hazedTubes = tubes.map { tube -> Sprite in
            let g = nixieGlass(tube)
            let box = digitBox(g)
            return lit(g, nixieGlassPath(g)) { c in
                let center = CGPoint(x: box.midX, y: box.midY)
                let haze = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [rgb(nr, ng, nb, 0.16), rgb(nr, ng * 0.8, nb, 0)] as CFArray, locations: nil)!
                c.drawRadialGradient(haze, startCenter: center, startRadius: 0, endCenter: center,
                                     endRadius: box.height * 0.8, options: [])
            }
        }

        // Throttle grip, with its stem and drop shadow.
        let grip = CGRect(x: 0, y: 0, width: 0.22 * u, height: 0.07 * u)
        let lever = makeSprite(grip.insetBy(dx: -0.1 * u, dy: -0.1 * u), anchor: .zero, scale: scale) { c in
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 0.02 * u), blur: 0.035 * u, color: self.rgb(0, 0, 0, 0.8))
            c.setFillColor(self.rgb(0.25, 0.25, 0.25))
            c.fill(CGRect(x: 0.098 * u, y: 0.015 * u, width: 0.024 * u, height: 0.04 * u))
            c.addPath(CGPath(roundedRect: grip, cornerWidth: 0.03 * u, cornerHeight: 0.03 * u, transform: nil))
            c.setFillColor(self.rgb(0.55, 0.08, 0.06))
            c.fillPath()
            c.restoreGState()
            c.saveGState()
            c.addPath(CGPath(roundedRect: grip, cornerWidth: 0.03 * u, cornerHeight: 0.03 * u, transform: nil))
            c.clip()
            self.linearGradient(c, grip, [self.rgb(0.85, 0.22, 0.15), self.rgb(0.4, 0.05, 0.04)], vertical: true)
            c.setStrokeColor(self.rgb(0, 0, 0, 0.35))
            c.setLineWidth(1)
            var gx = grip.minX + 0.03 * u
            while gx < grip.maxX - 0.02 * u {
                c.move(to: CGPoint(x: gx, y: grip.minY))
                c.addLine(to: CGPoint(x: gx, y: grip.maxY))
                gx += 0.025 * u
            }
            c.strokePath()
            c.restoreGState()
        }

        // Fader cap.
        let capRect = CGRect(x: 0, y: 0, width: min(faderColumns(l).width * 0.72, 0.075 * u), height: 0.05 * u)
        let cap = makeSprite(capRect.insetBy(dx: -0.06 * u, dy: -0.06 * u), anchor: .zero, scale: scale) { c in
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 0.012 * u), blur: 0.02 * u, color: self.rgb(0, 0, 0, 0.8))
            c.setFillColor(self.rgb(0.5, 0.5, 0.48))
            c.fill(capRect)
            c.restoreGState()
            self.linearGradient(c, capRect, [self.rgb(0.78, 0.78, 0.75), self.rgb(0.3, 0.3, 0.29)], vertical: true)
            c.setFillColor(self.rgb(1, 1, 1, 0.9))
            c.fill(CGRect(x: capRect.minX + 1, y: capRect.midY - 0.5, width: capRect.width - 2, height: 1.2))
        }

        // Meter bulb peeking over the shroud, with its glow (anchored at the top of the shroud, centred).
        let bulbRect = CGRect(x: -0.016 * u, y: -0.008 * u, width: 0.032 * u, height: 0.016 * u)
        let bulb = makeSprite(bulbRect.insetBy(dx: -0.08 * u, dy: -0.08 * u), anchor: .zero, scale: scale) { c in
            c.setShadow(offset: .zero, blur: 0.03 * u, color: self.rgb(1, 0.7, 0.35, 0.8))
            c.setFillColor(self.rgb(1, 0.88, 0.65))
            c.fillEllipse(in: bulbRect)
        }

        // Lit Nixie numerals: a wide soft bloom, the orange glow, then the hot core of the wire.
        let box = digitBox(nixieGlass(tubes[0]))
        let boxAt0 = CGRect(origin: .zero, size: box.size)
        let digits = (0...9).map { d -> Sprite in
            makeSprite(boxAt0.insetBy(dx: -box.height * 0.4, dy: -box.height * 0.4), anchor: .zero, scale: scale) { c in
                c.setLineCap(.round)
                c.setLineJoin(.round)
                let digit = self.nixieDigit(d, in: boxAt0)
                for (width, color, blur) in [(box.height * 0.1, self.rgb(nr, ng, nb, 0.16), box.height * 0.14),
                                             (box.height * 0.05, self.rgb(nr, ng + 0.05, nb, 0.9), box.height * 0.04),
                                             (box.height * 0.02, self.rgb(1, 0.8, 0.55), CGFloat(0))] {
                    c.saveGState()
                    if blur > 0 { c.setShadow(offset: .zero, blur: blur, color: self.rgb(nr, ng, nb, 0.7)) }
                    c.addPath(digit)
                    c.setStrokeColor(color)
                    c.setLineWidth(max(0.8, width))
                    c.strokePath()
                    c.restoreGState()
                }
            }
        }
        let r = box.height * 0.045
        let dotRect = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        let dot = makeSprite(dotRect.insetBy(dx: -box.height * 0.25, dy: -box.height * 0.25), anchor: .zero, scale: scale) { c in
            c.setShadow(offset: .zero, blur: box.height * 0.08, color: self.rgb(nr, ng, nb, 1))
            c.setFillColor(self.rgb(1, 0.7, 0.4))
            c.fillEllipse(in: dotRect)
        }

        // Distance counter figures, one drum cell each.
        let win = counterWindow(l)
        let cell = CGRect(x: 0, y: 0, width: win.width / CGFloat(counterDigits(win)), height: win.height)
        let drumDigits = [NSColor(red: 0.93, green: 0.91, blue: 0.85, alpha: 1), NSColor(red: 0.95, green: 0.35, blue: 0.25, alpha: 1)]
            .map { color in
                (0...9).map { value in
                    render(cell, scale: scale) { _ in
                        self.text("\(value)", CGPoint(x: cell.midX, y: cell.midY), size: cell.height * 0.78, color: color)
                    }!
                }
            }

        let banner = Self.alarmRect(viewSize)
        let alarm = [false, true].map { flash in
            makeSprite(banner.insetBy(dx: -50, dy: -50), anchor: .zero, scale: scale) { c in
                self.drawAlarmBanner(c, banner, flash: flash)
            }
        }

        return Caches(size: viewSize, scale: scale, strip: strip, back: back, front: front, litFaces: litFaces,
                      hazedTubes: hazedTubes, lever: lever, cap: cap, bulb: bulb, dot: dot, digits: digits,
                      drumDigits: drumDigits, alarm: alarm)
    }

    /// A status lamp at a given warmth, with its glow, anchored at its centre.
    private func makeLamp(_ i: Int, _ radius: CGFloat, on: CGFloat, scale: CGFloat) -> Sprite {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.62, 0.15), (0.35, 1, 0.45), (0.35, 1, 0.45), (0.35, 1, 0.45)]
        let (r, g, b) = colors[i]
        let rect = CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)
        return makeSprite(rect.insetBy(dx: -radius * 6, dy: -radius * 6), anchor: .zero, scale: scale) { c in
            c.saveGState()
            if on > 0.05 {
                c.setShadow(offset: .zero, blur: radius * 2.4 * on, color: self.rgb(r, g, b, 0.55 * on))
            }
            c.addEllipse(in: rect)
            let k = 0.18 + 0.82 * on
            c.setFillColor(self.rgb(r * k, g * k, b * k))
            c.fillPath()
            c.restoreGState()
            c.addEllipse(in: rect.insetBy(dx: radius * 0.45, dy: radius * 0.45).offsetBy(dx: -radius * 0.2, dy: -radius * 0.25))
            c.setFillColor(self.rgb(1, 1, 1, 0.25 + 0.35 * on))
            c.fillPath()
        }
    }

    /// Unchanging parts that lie over moving ones, drawn once and painted after what they cover.
    private func drawFronts(_ c: CGContext, _ l: Layout) {
        let u = l.u
        // VU meters: the shroud hiding the bulb, and the gloss of the glass.
        for i in 0..<3 {
            let face = gaugeFace(l, i).insetBy(dx: 0.025 * u, dy: 0.025 * u)
            c.saveGState()
            c.addPath(CGPath(roundedRect: face, cornerWidth: 0.02 * u, cornerHeight: 0.02 * u, transform: nil))
            c.clip()
            let shroud = CGRect(x: face.minX, y: face.maxY - face.height * 0.1, width: face.width, height: face.height * 0.1)
            linearGradient(c, shroud, [rgb(0.1, 0.09, 0.08), rgb(0.03, 0.03, 0.03)], vertical: true)
            linearGradient(c, face, [rgb(1, 1, 1, 0.1), rgb(1, 1, 1, 0)], vertical: false, endFraction: 0.55)
            c.restoreGState()
        }
        // Nixie tubes: the front of the anode cage, faintly lit by the glow behind it, and reflections on the glass.
        for tube in nixieTubes(l) {
            let g = nixieGlass(tube)
            c.saveGState()
            c.addPath(nixieGlassPath(g))
            c.clip()
            nixieMesh(c, g, rgb(0.9, 0.55, 0.3, 0.13))
            linearGradient(c, CGRect(x: g.minX + g.width * 0.08, y: g.minY, width: g.width * 0.14, height: g.height),
                           [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.02)], vertical: false)
            linearGradient(c, CGRect(x: g.maxX - g.width * 0.16, y: g.minY, width: g.width * 0.08, height: g.height),
                           [rgb(1, 1, 1, 0.0), rgb(1, 1, 1, 0.1)], vertical: false)
            c.restoreGState()
        }
        // Drum counter: the gaps between drums, and their curvature (dark at the top and bottom of the window).
        let win = counterWindow(l)
        let n = counterDigits(win)
        let dw = win.width / CGFloat(n)
        c.saveGState()
        c.clip(to: win)
        c.setFillColor(rgb(0, 0, 0, 0.6))
        for i in 0..<n {
            c.fill(CGRect(x: win.minX + CGFloat(i + 1) * dw - 0.5, y: win.minY, width: 1, height: win.height))
        }
        linearGradient(c, win, [rgb(0, 0, 0, 0.75), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.75)], vertical: true)
        c.restoreGState()
        // Scope: scanlines and the glass.
        let s = scopeScreen(l)
        c.saveGState()
        c.addPath(CGPath(roundedRect: s, cornerWidth: 0.05 * u, cornerHeight: 0.05 * u, transform: nil))
        c.clip()
        c.setFillColor(rgb(0, 0, 0, 0.18))
        var sy = s.minY
        while sy < s.maxY {
            c.fill(CGRect(x: s.minX, y: sy, width: s.width, height: 1))
            sy += 3
        }
        linearGradient(c, s, [rgb(1, 1, 1, 0.08), rgb(1, 1, 1, 0)], vertical: true, endFraction: 0.5)
        c.restoreGState()
    }

    // MARK: Helpers

    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Off-white stencil paint used for labels.
    private func paint(_ a: CGFloat) -> NSColor { NSColor(red: 0.86, green: 0.83, blue: 0.74, alpha: a) }
    private func paint(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 0.86, green: 0.83, blue: 0.74, alpha: a) }

    /// Point at `angle` measured clockwise from straight up (y-down coordinates).
    private func polar(_ c: CGPoint, _ r: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: c.x + r * sin(angle), y: c.y - r * cos(angle))
    }

    private func linearGradient(_ c: CGContext, _ r: CGRect, _ colors: [CGColor], vertical: Bool,
                                endFraction: CGFloat = 1) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                 locations: nil) else { return }
        c.saveGState()
        c.clip(to: r)
        let start = CGPoint(x: r.minX, y: r.minY)
        let end = vertical ? CGPoint(x: r.minX, y: r.minY + r.height * endFraction)
                           : CGPoint(x: r.minX + r.width * endFraction, y: r.minY + r.height * endFraction)
        c.drawLinearGradient(g, start: start, end: end, options: [.drawsAfterEndLocation])
        c.restoreGState()
    }

    private func bezelRect(_ c: CGContext, _ r: CGRect, _ u: CGFloat) {
        let path = CGPath(roundedRect: r, cornerWidth: 0.03 * u, cornerHeight: 0.03 * u, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 0.01 * u), blur: 0.025 * u, color: rgb(0, 0, 0, 0.8))
        c.addPath(path)
        c.setFillColor(rgb(0.3, 0.3, 0.3))
        c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(path)
        c.clip()
        linearGradient(c, r, [rgb(0.62, 0.63, 0.61), rgb(0.18, 0.19, 0.18)], vertical: true)
        c.restoreGState()
    }

    private func screw(_ c: CGContext, _ p: CGPoint, _ r: CGFloat) {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        c.saveGState()
        c.addEllipse(in: rect)
        c.clip()
        linearGradient(c, rect, [rgb(0.7, 0.7, 0.68), rgb(0.22, 0.22, 0.22)], vertical: true)
        c.restoreGState()
        var rng = LCG(seed: UInt64(abs(p.x * 31 + p.y * 17)))
        let a = rng.next() * .pi
        c.setStrokeColor(rgb(0.08, 0.08, 0.08))
        c.setLineWidth(max(1, r * 0.3))
        c.move(to: CGPoint(x: p.x - cos(a) * r * 0.7, y: p.y - sin(a) * r * 0.7))
        c.addLine(to: CGPoint(x: p.x + cos(a) * r * 0.7, y: p.y + sin(a) * r * 0.7))
        c.strokePath()
    }

    private static let labelFont = "DINCondensed-Bold"

    private func text(_ s: String, _ p: CGPoint, size: CGFloat, color: NSColor, alignLeft: Bool = false) {
        let font = NSFont(name: Self.labelFont, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color,
                                                             .kern: size * 0.06])
        let sz = str.size()
        // DIN Condensed sits high in its line box; nudge it down to look optically centred.
        str.draw(at: CGPoint(x: alignLeft ? p.x : p.x - sz.width / 2, y: p.y - sz.height / 2 + size * 0.08))
    }

    private func withAppKitContext(_ c: CGContext, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }
}

/// Transparent overlay that shows the console over the bottom of the space view.
final class InstrumentPanelView: NSView {
    let panel = InstrumentPanel()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        panel.draw(in: ctx, viewSize: bounds.size)
    }

    private var alarmWasActive = false

    func refresh() {
        if panel.alarmActive || alarmWasActive {
            needsDisplay = true // the alarm banner sits outside the console strip
        } else {
            let h = InstrumentPanel.panelHeight(for: bounds.size) * 1.2
            setNeedsDisplay(NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h))
        }
        alarmWasActive = panel.alarmActive
    }
}

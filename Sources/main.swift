// Nebula Drift — an audio visualizer for macOS.
// Fly through space: stars stream past, nebula clouds take their colour from the music.

import Cocoa
import MetalKit
import AVFoundation
import Accelerate
import CoreAudio
import ImageIO
import UniformTypeIdentifiers

// MARK: - Audio analysis

struct AudioFeatures {
    var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beat: Float = 0
    var beatAge: Float = 10
    var centroid: Float = 0.5
}

final class AudioAnalyzer {
    static let fftSize = 2048
    static let bandCount = 64
    static let minFreq: Float = 30
    static let maxFreq: Float = 16000

    static func bandFrequency(_ i: Float) -> Float {
        minFreq * powf(maxFreq / minFreq, i / Float(bandCount))
    }

    private static let bassEnd = (0..<bandCount).first { bandFrequency(Float($0) + 0.5) >= 160 } ?? 8
    private static let midEnd = (0..<bandCount).first { bandFrequency(Float($0) + 0.5) >= 2500 } ?? 40

    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 16384) // power of two
    private var writeIndex = 0
    private var lastPush: CFTimeInterval = 0
    private var sampleRate: Float = 48000
    private var heardSound = false

    var hasHeardSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heardSound
    }

    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: AudioAnalyzer.fftSize, isHalfWindow: false)
    private let dft = try! vDSP.DiscreteFourierTransform(count: AudioAnalyzer.fftSize, direction: .forward,
                                                         transformType: .complexComplex, ofType: Float.self)
    private let zeros = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var re = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var im = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var bandRanges: [(lo: Int, hi: Int, freq: Float)] = []
    private var rangesRate: Float = 0

    private var state = AudioFeatures()
    private var peaks = SIMD4<Float>(repeating: 0.3)
    private var bassAvg: Float = 0
    private var beatArmed = true

    /// Called from audio threads with mono samples.
    func push(_ samples: UnsafePointer<Float>, count: Int, sampleRate rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        sampleRate = rate
        let mask = ring.count - 1
        var w = writeIndex
        for i in 0..<count {
            ring[w] = samples[i]
            w = (w + 1) & mask
        }
        writeIndex = w
        lastPush = CACurrentMediaTime()
        if !heardSound {
            for i in 0..<count where abs(samples[i]) > 1e-4 {
                heardSound = true
                break
            }
        }
    }

    func analyze(dt: Float) -> AudioFeatures {
        let n = Self.fftSize
        var samples = [Float](repeating: 0, count: n)
        lock.lock()
        let live = CACurrentMediaTime() - lastPush < 0.35
        let rate = sampleRate
        if live {
            let mask = ring.count - 1
            var r = (writeIndex - n + ring.count) & mask
            for i in 0..<n {
                samples[i] = ring[r]
                r = (r + 1) & mask
            }
        }
        lock.unlock()

        var raw = [Float](repeating: 0, count: Self.bandCount)
        if live {
            if rate != rangesRate { buildRanges(rate) }
            dft.transform(inputReal: vDSP.multiply(samples, window), inputImaginary: zeros,
                          outputReal: &re, outputImaginary: &im)
            let scale = 4 / Float(n)
            for (b, range) in bandRanges.enumerated() {
                var m: Float = 0
                for k in range.lo...range.hi {
                    let power: Float = re[k] * re[k] + im[k] * im[k]
                    m = max(m, power.squareRoot())
                }
                // dB with a gentle tilt so highs aren't drowned out by the bass.
                let db = 20 * log10f(m * scale + 1e-7) + 3 * log2f(range.freq / 1000)
                raw[b] = min(max((db + 72) / 60, 0), 1)
            }
        }

        let attack = 1 - expf(-dt * 30)
        let release = 1 - expf(-dt * 6)
        for b in 0..<Self.bandCount {
            let v = raw[b], o = state.bands[b]
            state.bands[b] = o + (v - o) * (v > o ? attack : release)
        }

        func mean(_ a: [Float], _ r: Range<Int>) -> Float {
            a[r].reduce(0, +) / Float(max(r.count, 1))
        }

        // Beat detection: bass jumping above its recent average.
        let bassInst = mean(raw, 0..<Self.bassEnd)
        bassAvg += (bassInst - bassAvg) * (1 - expf(-dt * 2.5))
        state.beatAge += dt
        // One beat per hit: after firing, the bass must fall back toward its average before it can fire again,
        // so a long kick or a sustained bass note doesn't re-trigger (which made double rings).
        if bassInst - bassAvg < 0.025 { beatArmed = true }
        if live && beatArmed && bassInst - bassAvg > 0.07 && bassInst > 0.25 && state.beatAge > 0.3 {
            beatArmed = false
            state.beatAge = 0
            state.beat = 1
        }
        state.beat *= expf(-dt * 5)

        // Auto-gain so quiet and loud material both move the visuals.
        let v = SIMD4<Float>(mean(state.bands, 0..<Self.bassEnd),
                             mean(state.bands, Self.bassEnd..<Self.midEnd),
                             mean(state.bands, Self.midEnd..<Self.bandCount),
                             mean(state.bands, 0..<Self.bandCount))
        peaks = simd_max(simd_max(v, peaks - SIMD4(repeating: dt * 0.05)), SIMD4(repeating: 0.2))
        let rel = simd_clamp(v / peaks, .zero, SIMD4(repeating: 1))
        let shaped = simd_clamp((rel - 0.3) / 0.7, .zero, SIMD4(repeating: 1))
        state.bass = shaped.x
        state.mid = shaped.y
        state.treble = shaped.z
        state.level = rel.w * rel.w

        var weighted: Float = 0, total: Float = 1e-4
        for (i, b) in state.bands.enumerated() {
            weighted += Float(i) * b
            total += b
        }
        state.centroid += (weighted / total / Float(Self.bandCount) - state.centroid) * (1 - expf(-dt))
        return state
    }

    private func buildRanges(_ rate: Float) {
        let n = Float(Self.fftSize)
        let last = Self.fftSize / 2 - 1
        bandRanges = (0..<Self.bandCount).map { i in
            let lo = Self.bandFrequency(Float(i)), hi = Self.bandFrequency(Float(i + 1))
            let a = min(max(Int(lo * n / rate), 1), last)
            let b = min(max(Int(hi * n / rate), a), last)
            return (a, b, (lo * hi).squareRoot())
        }
        rangesRate = rate
    }
}

// MARK: - Audio sources

/// Captures everything the Mac is playing with a Core Audio process tap.
/// Needs only the "System Audio Recording Only" permission (NSAudioCaptureUsageDescription), not screen recording.
final class SystemAudioCapture {
    private let analyzer: AudioAnalyzer
    private let queue = DispatchQueue(label: "nebuladrift.system-audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var scratch = [Float](repeating: 0, count: 8192)

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    deinit { stop() }

    func start() throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "Nebula Drift"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create audio tap")

        var format = AudioStreamBasicDescription()
        try check(getProperty(tapID, kAudioTapPropertyFormat, &format), "read tap format")
        let rate = Float(format.mSampleRate > 0 ? format.mSampleRate : 48000)

        var outputID = AudioObjectID(kAudioObjectUnknown)
        try check(getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                              &outputID), "find output device")
        var uidRef: Unmanaged<CFString>?
        try check(getProperty(outputID, kAudioDevicePropertyDeviceUID, &uidRef), "read output device")
        guard let outputUID = uidRef?.takeRetainedValue() as String? else { throw captureError("read output device") }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nebula Drift Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create tap device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), rate: rate)
        }, "start tap")
        try check(AudioDeviceStart(aggregateID, procID), "start tap")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func consume(_ abl: UnsafeMutableAudioBufferListPointer, rate: Float) {
        guard let first = abl.first, let d0 = first.mData else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard count > 0 else { return }
        if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
        let a = d0.assumingMemoryBound(to: Float.self)
        if abl.count >= 2, let d1 = abl[1].mData {
            let b = d1.assumingMemoryBound(to: Float.self)
            for i in 0..<count { scratch[i] = 0.5 * (a[i] + b[i]) }
        } else if channels > 1 {
            for i in 0..<count {
                var s: Float = 0
                for c in 0..<channels { s += a[i * channels + c] }
                scratch[i] = s / Float(channels)
            }
        } else {
            analyzer.push(a, count: count, sampleRate: rate)
            return
        }
        scratch.withUnsafeBufferPointer { analyzer.push($0.baseAddress!, count: count, sampleRate: rate) }
    }

    private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw captureError("\(what) (error \(status))") }
    }

    private func captureError(_ message: String) -> NSError {
        NSError(domain: "NebulaDrift", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't \(message)"])
    }
}

final class AudioSources {
    private let analyzer: AudioAnalyzer
    private var system: SystemAudioCapture?
    private var engine: AVAudioEngine?
    private var generation = 0
    var onStatus: ((String) -> Void)?

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    func stopAll() {
        generation += 1
        system?.stop()
        system = nil
        engine?.stop()
        engine = nil
    }

    func startSystemAudio() {
        stopAll()
        let capture = SystemAudioCapture(analyzer: analyzer)
        do {
            try capture.start()
            system = capture
            onStatus?("♪ System audio")
        } catch {
            onStatus?("\(error.localizedDescription). Press M for the mic or O to open a file.")
            return
        }
        // A denied permission doesn't raise an error, the tap just delivers silence.
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == gen, !self.analyzer.hasHeardSound else { return }
            self.onStatus?("Only silence so far. Play something, or allow Nebula Drift under System Settings › " +
                           "Privacy & Security › Screen & System Audio Recording › System Audio Recording Only.")
        }
    }

    func startMicrophone() {
        stopAll()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            onStatus?("No microphone input available")
            return
        }
        installTap(on: input, format: format)
        do {
            try engine.start()
            self.engine = engine
            onStatus?("🎙 Microphone")
        } catch {
            onStatus?("Microphone failed: \(error.localizedDescription)")
        }
    }

    func play(file url: URL) {
        stopAll()
        do {
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            installTap(on: engine.mainMixerNode, format: engine.mainMixerNode.outputFormat(forBus: 0))
            try engine.start()
            self.engine = engine
            scheduleLoop(file, on: player, generation: generation)
            player.play()
            onStatus?("▶ \(url.deletingPathExtension().lastPathComponent)")
        } catch {
            onStatus?("Couldn't play \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func scheduleLoop(_ file: AVAudioFile, on player: AVAudioPlayerNode, generation gen: Int) {
        player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.scheduleLoop(file, on: player, generation: gen)
            }
        }
    }

    private func installTap(on node: AVAudioNode, format: AVAudioFormat) {
        let analyzer = self.analyzer
        let rate = Float(format.sampleRate)
        var mono = [Float](repeating: 0, count: 4096)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            if channels == 1 {
                analyzer.push(data[0], count: frames, sampleRate: rate)
                return
            }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += data[c][i] }
                mono[i] = s / Float(channels)
            }
            mono.withUnsafeBufferPointer { analyzer.push($0.baseAddress!, count: frames, sampleRate: rate) }
        }
    }
}

// MARK: - Rendering

/// Must match `Uniforms` in Shaders.metal.
struct Uniforms {
    var resolution: SIMD2<Float> = .zero
    var time: Float = 0
    var aspect: Float = 1
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beat: Float = 0
    var speed: Float = 0
    var hue: Float = 0
    var roll: Float = 0
    var travel: Float = 0
    var dither: Float = 1
    var ditherStrength: Float = 2
    var aberration: Float = 1
    var blackHole = SIMD4<Float>.zero  // screen centre x, y (aspect-scaled, unrotated), shadow radius, active
    var blackHole2 = SIMD4<Float>.zero // disc angle on screen, tidal stress (0...1), seed, unused
    var glass = SIMD4<Float>.zero      // cockpit glass: on (0/1)
    var blackHole3 = SIMD4<Float>.zero // disc normal x, y, z (screen frame), fade-in alpha
    var blackHole4 = SIMD4<Float>.zero // inner edge, outer edge (in r_s), temperature scale, kind
}

enum DitherMode: Int, CaseIterable {
    case off, smooth, retro

    var label: String {
        switch self {
        case .off: "Dither: Off"
        case .smooth: "Dither: Smooth (removes banding)"
        case .retro: "Dither: Retro"
        }
    }
}

struct Star {
    var a: SIMD4<Float> // x, y, z, tail z
    var b: SIMD4<Float> // size, seed, brightness, unused
}

/// A nebula or galaxy far away that drifts toward the camera.
struct SpaceObject {
    var xy: SIMD2<Float>
    var z: Float            // nebula: depth of its farthest layer; galaxy: depth of its centre
    var size: Float
    var seed: Float
    var rotation: Float
    var spin: Float
    var extra: SIMD4<Float> // nebula: hue shift; galaxy: arm count, disc normal x, normal y
    var flyThrough = false  // on a collision course: we'll fly right through it
}

/// Moves the nebulae or galaxies toward us and drops them once passed (the renderer decides when to spawn).
struct ObjectField {
    static let extent: Float = 1.8         // drawn size in radii (matches the shader's cut-off)

    let maxCount: Int
    let spawnZ: Float                      // far away: starts as a speck near the centre
    let approach: Float                    // how fast it zooms in, relative to the star speed
    /// Below this depth (in object sizes) it stops zooming and drifts at a constant, slow speed:
    /// a small value means crossing it takes many seconds while the nearby stars rush past.
    let nearFactor: Float
    let sizes: ClosedRange<Float>
    let depth: Float                       // front-to-back thickness, as a fraction of its size
    /// Galaxies are 3D discs we can fly all the way through and out the back: once close they approach
    /// at constant speed (instead of an endless zoom) and are dropped only when fully behind us.
    let disc: Bool
    let throughChance: Float               // probability that a new one is on a collision course
    let throughOffset: ClosedRange<Float>  // how far off-centre we cross it, in object radii
    let extras: (_ flyThrough: Bool) -> SIMD4<Float>
    var objects: [SpaceObject] = []

    func make(z: Float? = nil, through: Bool? = nil, size fixedSize: Float? = nil) -> SpaceObject {
        let angle = Float.random(in: 0..<(2 * .pi))
        let size = fixedSize ?? Float.random(in: sizes)
        let flyThrough = through ?? (Float.random(in: 0...1) < throughChance)
        // Usually it sails past to one side; rarely we're headed straight into it.
        let dist = flyThrough ? size * .random(in: throughOffset) : size * Self.extent + .random(in: 0.2...0.9)
        return SpaceObject(xy: SIMD2(cosf(angle), sinf(angle)) * dist, z: z ?? spawnZ, size: size,
                           seed: .random(in: 0...1), rotation: .random(in: 0..<(2 * .pi)),
                           spin: .random(in: -0.03...0.03), extra: extras(flyThrough), flyThrough: flyThrough)
    }

    /// Puts an object on a collision course right now (replacing the oldest if the field is full).
    mutating func spawnFlyThrough() {
        if objects.count >= maxCount { objects.removeFirst() }
        objects.append(make(through: true))
    }

    mutating func update(dt: Float, speed: Float, screenRadius: Float) {
        // Far away it zooms in steadily (exponential); once close it keeps coming at full speed, so it
        // looms ever faster and sweeps past us, out behind the camera, rather than easing to a stop.
        for i in objects.indices {
            let o = objects[i]
            objects[i].z -= speed * approach * dt * max(o.z, o.size * nearFactor)
            objects[i].rotation += o.spin * dt
        }
        // Drop it only once it is entirely behind us, or entirely outside the view.
        objects.removeAll { o in
            let reach = disc ? o.size * 1.5 : 0 // a galaxy's centre depth; a nebula's z is already its far edge
            return o.z + reach < 0
                || (o.z + reach > 0 && (simd_length(o.xy) - o.size * Self.extent) / (o.z + reach) > screenRadius)
        }
    }

    /// Fades in as it emerges from the distance (each layer fades out on its own as we pass it, in the shader).
    func alpha(_ o: SpaceObject) -> Float {
        let t = min(max((spawnZ - o.z) / (spawnZ * 0.4), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Three float4 per slot, projected per layer in the shader:
    /// (world x, world y, depth, size), (seed, rotation, extra.x, alpha), (thickness, fly-through, extra.y, extra.z).
    func packed() -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: maxCount * 3)
        for (i, o) in objects.prefix(maxCount).enumerated() {
            out[i * 3] = SIMD4(o.xy.x, o.xy.y, o.z, o.size)
            out[i * 3 + 1] = SIMD4(o.seed, o.rotation, o.extra.x, alpha(o))
            out[i * 3 + 2] = SIMD4(o.size * depth, o.flyThrough ? 1 : 0, o.extra.y, o.extra.z)
        }
        return out
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    static let nearPlane: Float = 0.004
    static let maxInFlight = 3
    static let maxRings = 10 // must match MAX_RINGS in Shaders.metal
    static let spawnGap: ClosedRange<Float> = 15...35 // seconds of empty space between nebulae/galaxies
    // Share of spawns: gas clouds 60%, nebulae 30%, galaxies 9%, black holes under 1%.
    static let blackHoleChance: Float = 0.008
    static let galaxyChance: Float = 0.09
    static let nebulaChance: Float = 0.30
    /// Cloud kinds (must match the shader): nebulae 0-6, gas clouds 7-12.
    static let nebulaKinds: [Float] = [0, 1, 2, 3, 4, 5, 6]
    static let gasKinds: [Float] = [7, 8, 9, 10, 11, 12]
    static let blackHoleSpawnZ: Float = 200
    static let starCount = 12000
    static let starFar: Float = 6 // stars are born this deep (matches STAR_FAR in Shaders.metal)
    static let ringLifetime: Float = 2.6
    static let scenePixelFormat = MTLPixelFormat.rgba16Float

    let device: MTLDevice
    var ditherMode = DitherMode.smooth
    var ditherStrength = 2 // 1 light ... 4 heavy
    var aberration = true
    var cockpitGlass = false
    /// Called after every simulation step with what the instrument console shows.
    var onFrame: ((PanelInput, Float) -> Void)?
    private let statsLock = NSLock()
    private var statFrames = 0
    private var statGPUTime: Double = 0
    private let queue: MTLCommandQueue
    private let bgPipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private var sceneTexture: MTLTexture?
    private var ringAges: [Float] = []
    private var lastBeatAge: Float = .infinity
    private var spawnTimer: Float = .random(in: 15...35)
    private var blackHole: SpaceObject?
    private var tidalStress: Float = 0

    /// A black hole always passes close beside us, never through. `rotation` is its disc's angle on screen.
    /// What kind of black hole this is (all lengths in Schwarzschild radii, r_s).
    struct BlackHoleVariant {
        enum Kind: Int { case standard = 0, quasar = 1, bare = 2, torus = 3 }
        var kind: Kind
        var innerEdge: Float  // ~2 for a fast-spinning hole, ~3 for a slow one
        var outerEdge: Float
        var thickness: Float  // disc half-height / radius
        var temperature: Float
        var spin: Float       // +1 / -1: which way the disc orbits

        init(seed: Float) {
            func f(_ k: Float) -> Float { let x = seed * k; return x - floorf(x) }
            let k = f(3.7)
            kind = k < 0.12 ? .bare : (k < 0.37 ? .quasar : (k < 0.52 ? .torus : .standard))
            innerEdge = 2.0 + 1.2 * f(1.9)
            outerEdge = 9 + 13 * f(2.7)
            thickness = kind == .torus ? 0.22 + 0.1 * f(5.1) : 0.02 + 0.09 * powf(f(5.1), 1.5)
            temperature = kind == .quasar ? 1.4 + 0.3 * f(8.3) : 0.6 + 0.8 * f(8.3)
            spin = f(4.9) > 0.5 ? 1 : -1
        }
    }

    /// A black hole far ahead. `size` is its shadow radius (≈ 2.6 r_s) in world units; `extra.xyz` is the
    /// disc's normal. Our path passes beside it, above or below the disc, never through the disc itself.
    static func makeBlackHole(z: Float, seed: Float = .random(in: 0...1)) -> SpaceObject {
        let size = Float.random(in: 0.1...0.22)
        let rs = size / 2.6
        let v = BlackHoleVariant(seed: seed)
        var best = SpaceObject(xy: .zero, z: z, size: size, seed: seed, rotation: 0, spin: 0, extra: .zero)
        for _ in 0..<24 {
            // Disc orientation: mostly seen fairly edge-on, sometimes much more open.
            let open = Float.random(in: 0...1) < 0.2 ? Float.random(in: 0.5...0.9) : Float.random(in: 0...0.45)
            let az = Float.random(in: 0..<(2 * .pi))
            let n = SIMD3(cosf(az) * (1 - open * open).squareRoot(), sinf(az) * (1 - open * open).squareRoot(), open)
            // Offset toward the disc's "up" side so we fly over it.
            var side = SIMD2(n.x, n.y)
            side = simd_length(side) > 0.2 ? simd_normalize(side) : SIMD2(cosf(az + 1.3), sinf(az + 1.3))
            if Bool.random() { side = -side }
            let lateral = Float.random(in: 13...22) * rs
            let xy = side * lateral
            // Where (if anywhere) does our straight path cross the disc plane, and how far from the hole is that?
            let crossing: Float
            if abs(n.z) > 1e-3 {
                let zc = -(xy.x * n.x + xy.y * n.y) / n.z // camera-relative z of the hole when we cross
                crossing = simd_length(SIMD3(xy.x, xy.y, zc)) / rs
            } else {
                crossing = .infinity
            }
            best = SpaceObject(xy: xy, z: z, size: size, seed: seed, rotation: 0, spin: 0, extra: SIMD4(n.x, n.y, n.z, 0))
            if crossing > v.outerEdge * 1.6 + 6 { break }
        }
        return best
    }

    private func updateBlackHole(dt: Float) {
        guard var bh = blackHole else {
            tidalStress = max(tidalStress - dt * 0.5, 0)
            u.blackHole = .zero
            u.blackHole2 = .zero
            u.blackHole3 = .zero
            return
        }
        // Zooms in from afar, then drifts past at a steady, unhurried pace.
        bh.z -= u.speed * 0.9 * dt * max(bh.z, bh.size * 5)
        // Tidal stress peaks as we pass closest, and lingers a moment after.
        let proximity = bh.size / simd_length(SIMD3(bh.xy.x, bh.xy.y, bh.z))
        let target = min(max((proximity - 0.05) / 0.12, 0), 1)
        tidalStress += (target - tidalStress) * (1 - expf(-dt * 3))
        blackHole = bh.z < -simd_length(bh.xy) * 3 ? nil : bh
        // Hand the shader its 3D position and disc orientation in the (roll-rotated) screen frame.
        let c = cosf(-u.roll), s = sinf(-u.roll)
        func turn(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2(c * x - s * y, s * x + c * y) }
        let p = turn(bh.xy.x, bh.xy.y), n = turn(bh.extra.x, bh.extra.y)
        let t = min(max((Self.blackHoleSpawnZ - bh.z) / (Self.blackHoleSpawnZ * 0.4), 0), 1)
        let v = BlackHoleVariant(seed: bh.seed)
        u.blackHole = SIMD4(p.x, p.y, bh.z, bh.size / 2.6)
        u.blackHole2 = SIMD4(v.thickness, tidalStress, bh.seed, v.spin)
        u.blackHole3 = SIMD4(n.x, n.y, bh.extra.z, max(t * t * (3 - 2 * t), 0.002))
        u.blackHole4 = SIMD4(v.innerEdge, v.outerEdge, v.temperature, Float(v.kind.rawValue))
    }

    /// Summon a black hole now (it still takes a while to arrive).
    func spawnBlackHole() {
        nebulae.objects = []
        galaxies.objects = []
        blackHole = Self.makeBlackHole(z: 80)
    }

    /// For --snapshot: one galaxy of a chosen seed and arm count, seen at a moderate tilt.
    func placeGalaxyForTesting(seed: Float, arms: Float, tilt: Float) {
        var g = galaxies.make(z: 0.85, through: false)
        g.xy = SIMD2(0.05, 0.0)
        g.size = 0.6
        g.seed = seed
        let n = Renderer.galaxyNormal(tiltDegrees: tilt, azimuth: 1.2)
        g.extra = SIMD4(arms, n.x, n.y, 0)
        galaxies.objects = [g]
        nebulae.objects = []
        blackHole = nil
        spawnTimer = 1000
    }

    /// For --snapshot: one cloud of a chosen kind, close and slightly off-centre.
    func placeNebulaForTesting(kind: Float, variation: Float = 0.5) {
        var n = makeCloud(gas: kind >= 7, z: 0.7, through: false, kind: kind)
        n.xy = SIMD2(0.12, 0.05)
        n.size = 0.5
        n.extra.z = variation
        nebulae.objects = [n]
        galaxies.objects = []
        blackHole = nil
        spawnTimer = 1000
    }

    /// For --snapshot: a black hole at a given depth and sideways offset (in its own sizes).
    func placeBlackHoleForTesting(zRs: Float, stress: Float, seed: Float = 0.6) {
        nebulae.objects = []
        galaxies.objects = []
        var bh = Self.makeBlackHole(z: 1, seed: seed)
        bh.z = zRs * bh.size / 2.6
        blackHole = bh
        tidalStress = stress
        spawnTimer = 1000
    }
    // Slot counts must match MAX_NEBULAE / MAX_GALAXIES in Shaders.metal.
    private var nebulae = ObjectField(maxCount: 2, spawnZ: 200, approach: 0.6, nearFactor: 0.45, sizes: 0.4...0.65,
                                      depth: 1.0, disc: false,
                                      throughChance: 0.05, throughOffset: 0...0.35,
                                      extras: { _ in SIMD4(.random(in: -0.15...0.25), 0, 0, 0) })
    // Galaxies are much farther away: they approach slower and show up less often.
    private var galaxies = ObjectField(maxCount: 2, spawnZ: 200, approach: 0.5, nearFactor: 0.35, sizes: 0.35...1.1,
                                       depth: 0.22, disc: true,
                                       throughChance: 0.05,
                                       throughOffset: 0.35...0.65, // through the arms, not the blinding core
                                       extras: { Renderer.galaxyExtras(flyThrough: $0) })
    private let starBuffers: [MTLBuffer]

    /// Arm count and a random 3D orientation: anything from face-on to (sometimes) razor-thin edge-on.
    /// Fly-through galaxies stay fairly open so our path actually crosses the disc.
    static func galaxyExtras(flyThrough: Bool) -> SIMD4<Float> {
        let arms = Float([0, 2, 2, 2, 2, 3, 3, 4].randomElement()!)
        let maxTilt: Float = flyThrough ? 55 : (Float.random(in: 0...1) < 0.15 ? 88 : 78)
        let tilt = Float.random(in: 0...maxTilt) * .pi / 180
        let azimuth = Float.random(in: 0..<(2 * .pi))
        return SIMD4(arms, sinf(tilt) * cosf(azimuth), sinf(tilt) * sinf(azimuth), 0)
    }

    static func galaxyNormal(tiltDegrees: Float, azimuth: Float) -> SIMD2<Float> {
        let t = tiltDegrees * .pi / 180
        return SIMD2(sinf(t) * cosf(azimuth), sinf(t) * sinf(azimuth))
    }
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: Renderer.maxInFlight)

    private var stars: [Star] = []
    private var spectrum = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var u = Uniforms()
    private var hueBase: Float = Float.random(in: 0...1)
    private var lastTime = CACurrentMediaTime()
    private let features: (Float) -> AudioFeatures

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, shaderSource: String,
         features: @escaping (Float) -> AudioFeatures) throws {
        self.device = device
        self.features = features
        queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: shaderSource, options: nil)

        let bg = MTLRenderPipelineDescriptor()
        bg.vertexFunction = library.makeFunction(name: "bgVertex")
        bg.fragmentFunction = library.makeFunction(name: "bgFragment")
        bg.colorAttachments[0].pixelFormat = Self.scenePixelFormat
        bgPipeline = try device.makeRenderPipelineState(descriptor: bg)

        let post = MTLRenderPipelineDescriptor()
        post.vertexFunction = library.makeFunction(name: "bgVertex")
        post.fragmentFunction = library.makeFunction(name: "postFragment")
        post.colorAttachments[0].pixelFormat = pixelFormat
        postPipeline = try device.makeRenderPipelineState(descriptor: post)

        let st = MTLRenderPipelineDescriptor()
        st.vertexFunction = library.makeFunction(name: "starVertex")
        st.fragmentFunction = library.makeFunction(name: "starFragment")
        let ca = st.colorAttachments[0]!
        ca.pixelFormat = Self.scenePixelFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .zero
        ca.destinationAlphaBlendFactor = .one
        starPipeline = try device.makeRenderPipelineState(descriptor: st)

        let length = MemoryLayout<Star>.stride * Self.starCount
        starBuffers = (0..<Self.maxInFlight).map { _ in device.makeBuffer(length: length, options: .storageModeShared)! }
        super.init()
        nebulae.objects = [makeCloud(gas: true, z: 8, through: false)]

        stars = (0..<Self.starCount).map { _ in
            var s = Star(a: .zero, b: .zero)
            respawn(&s, aspect: 16 / 9, z: .random(in: 0.03...Self.starFar))
            return s
        }
    }

    /// b.w holds the star's true depth; a.z / a.w are the head and tail depths actually drawn.
    /// Stars fill a deep box of space ahead of us: far ones start as faint specks near the centre.
    private func respawn(_ s: inout Star, aspect: Float, z: Float = .random(in: (Renderer.starFar * 0.85)...Renderer.starFar)) {
        var xy: SIMD2<Float>
        repeat {
            xy = SIMD2(.random(in: -aspect...aspect), .random(in: -1...1)) * 1.15
        } while simd_length(xy) < Self.nearPlane * 6 // dead-centre stars would never leave the screen
        let r = Float.random(in: 0...1)
        let big = Float.random(in: 0...1)
        // Mostly small and dim, a few big bright ones.
        s.a = SIMD4(xy.x, xy.y, z, z)
        s.b = SIMD4(0.5 + 2.2 * big * big * big, .random(in: 0...1), r * r * 0.9 + 0.1, z)
    }

    func step(dt: Float, size: CGSize) {
        let f = features(dt)
        let aspect = Float(size.width / max(size.height, 1))
        u.resolution = SIMD2(Float(size.width), Float(size.height))
        u.aspect = aspect
        u.time += dt

        let target = 0.10 + f.level * 0.5 + f.bass * 0.35 + f.beat * 0.7
        u.speed += (target - u.speed) * (1 - expf(-dt * 2.5))
        u.travel += u.speed * dt
        u.bass = f.bass
        u.mid = f.mid
        u.treble = f.treble
        u.level = f.level
        u.beat = f.beat
        u.dither = Float(ditherMode.rawValue)
        u.ditherStrength = Float(ditherStrength)
        u.aberration = aberration ? 1 : 0
        u.glass = SIMD4(cockpitGlass ? 1 : 0, 0, 0, 0)

        // Each beat launches its own ring; older rings keep expanding until they fade out.
        ringAges = ringAges.map { $0 + dt }.filter { $0 < Self.ringLifetime }
        if f.beatAge < lastBeatAge && (ringAges.last ?? .infinity) > 0.25 {
            ringAges.append(f.beatAge)
            if ringAges.count > Self.maxRings { ringAges.removeFirst() }
        }
        lastBeatAge = f.beatAge

        // Nebulae and galaxies: one or two of each at a time, drifting toward us slower than the stars.
        let screenR = (aspect * aspect + 1).squareRoot()
        let hadObject = !nebulae.objects.isEmpty || !galaxies.objects.isEmpty || blackHole != nil
        nebulae.update(dt: dt, speed: u.speed, screenRadius: screenR)
        galaxies.update(dt: dt, speed: u.speed, screenRadius: screenR)
        updateBlackHole(dt: dt)
        // Only one nebula, galaxy or (very rarely) black hole at a time, with a long, quiet gap in between.
        if nebulae.objects.isEmpty && galaxies.objects.isEmpty && blackHole == nil {
            if hadObject { spawnTimer = .random(in: Self.spawnGap) }
            spawnTimer -= dt
            if spawnTimer <= 0 {
                let roll = Float.random(in: 0...1)
                if roll < Self.blackHoleChance {
                    blackHole = Self.makeBlackHole(z: Self.blackHoleSpawnZ)
                } else if roll < Self.blackHoleChance + Self.galaxyChance {
                    galaxies.objects = [galaxies.make()]
                } else if roll < Self.blackHoleChance + Self.galaxyChance + Self.nebulaChance {
                    nebulae.objects = [makeCloud(gas: false)]
                } else {
                    nebulae.objects = [makeCloud(gas: true)]
                }
            }
        }
        hueBase = fmodf(hueBase + dt * (0.006 + f.treble * 0.02 + f.beat * 0.03), 1)
        u.hue = hueBase + f.centroid * 0.35
        u.roll = u.time * 0.02 + sinf(u.time * 0.13) * 0.25 + f.bass * 0.03 * sinf(u.time * 2)
        spectrum = f.bands
        onFrame?(PanelInput(bands: f.bands, bass: f.bass, mid: f.mid, treble: f.treble, level: f.level, beat: f.beat,
                            speed: u.speed, hue: u.hue, centroid: f.centroid, roll: u.roll,
                            alarm: u.blackHole2.y), dt)

        let maxR = (aspect * aspect + 1).squareRoot() + 0.15
        let tail = max(min(u.speed * 0.18, 0.5), 0.0005)
        let near = Self.nearPlane
        for i in stars.indices {
            var s = stars[i]
            s.b.w -= u.speed * dt
            // The head stops at the near plane (already far off-screen); the tail keeps sweeping outward.
            let tailZ = max(s.b.w + tail, near)
            if tailZ <= near || simd_length(SIMD2(s.a.x, s.a.y)) / tailZ > maxR {
                respawn(&s, aspect: aspect)
                stars[i] = s
                continue
            }
            s.a.z = max(s.b.w, near)
            s.a.w = tailZ
            stars[i] = s
        }
    }

    func encode(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor) {
        let buffer = starBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % Self.maxInFlight
        stars.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let target = pass.colorAttachments[0].texture else { return }
        let scene = sceneTexture(width: target.width, height: target.height)

        // Scene pass: nebula + stars into a high-precision texture.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .dontCare
        scenePass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        var rings = ringAges + [Float](repeating: 100, count: Self.maxRings - ringAges.count)
        enc.setRenderPipelineState(bgPipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        spectrum.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.setFragmentBytes(&rings, length: MemoryLayout<Float>.stride * rings.count, index: 2)
        var neb = nebulae.packed()
        enc.setFragmentBytes(&neb, length: MemoryLayout<SIMD4<Float>>.stride * neb.count, index: 3)
        var gal = galaxies.packed()
        enc.setFragmentBytes(&gal, length: MemoryLayout<SIMD4<Float>>.stride * gal.count, index: 4)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(starPipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stars.count)
        enc.endEncoding()

        // Post pass: dither down to the 8-bit output.
        guard let post = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        post.setRenderPipelineState(postPipeline)
        post.setFragmentTexture(scene, index: 0)
        post.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        post.setFragmentBytes(&rings, length: MemoryLayout<Float>.stride * rings.count, index: 2)
        post.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        post.endEncoding()
    }

    private func sceneTexture(width: Int, height: Int) -> MTLTexture {
        if let t = sceneTexture, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.scenePixelFormat, width: width,
                                                            height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let t = device.makeTexture(descriptor: desc)!
        sceneTexture = t
        return t
    }

    /// Steer straight into a nebula or galaxy right now.
    func spawnFlyThrough(galaxy: Bool? = nil) {
        nebulae.objects = []
        galaxies.objects = []
        if galaxy ?? (Float.random(in: 0...1) < 0.25) {
            galaxies.spawnFlyThrough()
        } else {
            nebulae.objects = [makeCloud(gas: Float.random(in: 0...1) < 0.66, through: true)]
        }
    }

    /// A gas cloud (big, diffuse) or a nebula (more compact and structured), with its kind, a random
    /// variation (texture scale, palette) and hue.
    func makeCloud(gas: Bool, z: Float? = nil, through: Bool? = nil, kind: Float? = nil) -> SpaceObject {
        let size: Float = gas ? .random(in: 0.5...1.3) : .random(in: 0.3...0.75)
        var o = nebulae.make(z: z, through: through, size: size)
        o.extra.y = kind ?? (gas ? Self.gasKinds : Self.nebulaKinds).randomElement()!
        o.extra.z = .random(in: 0...1)
        return o
    }

    /// For --snapshot: depth of the current nebula or galaxy (nil once it has passed).
    var testObjectDepth: Float? { nebulae.objects.first?.z ?? galaxies.objects.first?.z }

    /// For --snapshot: deep inside a nebula (or a galaxy) at the given screen radius.
    func placeFlyThroughForTesting(galaxy: Bool, radius: Float) {
        var field = galaxy ? galaxies : nebulae
        var o = field.make(z: 1, through: true)
        if galaxy {
            // Just above the disc, looking down through it at a slant.
            o.z = o.size / radius
            let n = Renderer.galaxyNormal(tiltDegrees: 50, azimuth: 1.1)
            o.extra = SIMD4(2, n.x, n.y, 0)
        } else {
            o.z = o.size / radius + o.size * field.depth * 0.5 // `radius` is for the middle layer
        }
        field.objects = [o]
        if galaxy {
            galaxies = field
            nebulae.objects = []
        } else {
            nebulae = field
            galaxies.objects = []
        }
    }

    /// For --snapshot: start just before flying straight through a cloud of `kind`, or a galaxy if nil.
    func startFlyTest(cloudKind: Float?) {
        nebulae.objects = []
        galaxies.objects = []
        blackHole = nil
        spawnTimer = 1000
        if let kind = cloudKind {
            var o = makeCloud(gas: kind >= 7, z: 1, through: true, kind: kind)
            o.size = 0.8
            o.xy = SIMD2(0.08, 0.05)
            o.z = o.size * 3.5
            nebulae.objects = [o]
        } else {
            var o = galaxies.make(z: 1, through: true, size: 0.8)
            o.xy = SIMD2(0.35, 0.2)
            o.z = o.size * 3
            let n = Renderer.galaxyNormal(tiltDegrees: 45, azimuth: 0.8)
            o.extra = SIMD4(2, n.x, n.y, 0)
            galaxies.objects = [o]
        }
    }

    /// Frames drawn and GPU time spent since the last call.
    func takeStats() -> (frames: Int, gpuSeconds: Double) {
        statsLock.lock()
        defer { statsLock.unlock() }
        let out = (statFrames, statGPUTime)
        statFrames = 0
        statGPUTime = 0
        return out
    }

    /// For --snapshot: a freshly spawned nebula and galaxy, to follow their journey.
    func spawnFreshForTesting() {
        nebulae.objects = [makeCloud(gas: false, through: false)]
        galaxies.objects = [galaxies.make(through: false)]
    }

    /// For --snapshot: put a nebula and a galaxy at known spots so they can be inspected.
    func placeObjectsForTesting() {
        var n = nebulae.make(z: 0.45)
        n.xy = SIMD2(0.32, 0.16)
        n.size = 0.36
        nebulae.objects = [n]
        var g = galaxies.make(z: 1.1, through: false)
        g.xy = SIMD2(-0.62, -0.05)
        g.size = 0.55
        let gn = Renderer.galaxyNormal(tiltDegrees: 58, azimuth: 3.3)
        g.extra = SIMD4(2, gn.x, gn.y, 0)
        galaxies.objects = [g]
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inFlight.wait()
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.1))
        lastTime = now
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        step(dt: dt, size: view.drawableSize)
        encode(cb, pass: pass)
        cb.present(drawable)
        let sem = inFlight
        cb.addCompletedHandler { [weak self] cb in
            if let self {
                self.statsLock.lock()
                self.statFrames += 1
                self.statGPUTime += max(cb.gpuEndTime - cb.gpuStartTime, 0)
                self.statsLock.unlock()
            }
            sem.signal()
        }
        cb.commit()
    }

    /// Renders one frame offscreen and writes it as a PNG (used by --snapshot).
    func snapshot(width: Int, height: Int, to url: URL, overlay: ((CGContext) -> Void)? = nil) throws {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                            mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .managed
        let tex = device.makeTexture(descriptor: desc)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cb = queue.makeCommandBuffer()!
        encode(cb, pass: pass)
        let blit = cb.makeBlitCommandEncoder()!
        blit.synchronize(resource: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        if let overlay {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            overlay(ctx)
            ctx.restoreGState()
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - UI

final class VisualizerView: MTKView {
    var onKey: ((NSEvent) -> Bool)?
    var onDropFile: ((URL) -> Void)?
    var renderScale: CGFloat = 1 { didSet { needsLayout = true } }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        let scale = min(renderScale, window?.backingScaleFactor ?? 1)
        drawableSize = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL else {
            return false
        }
        onDropFile?(url)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let analyzer = AudioAnalyzer()
    private lazy var sources = AudioSources(analyzer: analyzer)
    private var window: NSWindow!
    private var view: VisualizerView!
    private var renderer: Renderer!
    private var hud: NSTextField!
    private var hudToken = 0
    private static let hints = "S  system audio    M  microphone    O  open file (or drop one)    " +
                               "F  full screen    I  instruments    P  stats    T  fly into the next one    B  black hole\n" +
                               "G  cockpit glass    D  dither style    ⇧D  dither strength    C  chromatic aberration    Q  quality    H  hints"
    private let instruments = InstrumentPanelView()
    private let stats = StatsOverlay()
    private let cockpit = CockpitFrameView()
    private var lastMouseMove = CACurrentMediaTime()
    private var cursorTimer: Timer?
    private var panelClock: Float = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        guard let device = MTLCreateSystemDefaultDevice(),
              let shaderURL = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            fatalError("Metal or shader source unavailable")
        }

        view = VisualizerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 780), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = 120
        view.registerForDraggedTypes([.fileURL])
        do {
            renderer = try Renderer(device: device, pixelFormat: view.colorPixelFormat, shaderSource: source) {
                [analyzer] dt in analyzer.analyze(dt: dt)
            }
        } catch {
            fatalError("Shader compile failed: \(error)")
        }
        if UserDefaults.standard.object(forKey: "dither") != nil {
            renderer.ditherMode = DitherMode(rawValue: UserDefaults.standard.integer(forKey: "dither")) ?? .smooth
        }
        if UserDefaults.standard.object(forKey: "ditherStrength") != nil {
            renderer.ditherStrength = min(max(UserDefaults.standard.integer(forKey: "ditherStrength"), 1), 4)
        }
        if UserDefaults.standard.object(forKey: "aberration") != nil {
            renderer.aberration = UserDefaults.standard.bool(forKey: "aberration")
        }
        view.delegate = renderer
        view.onKey = { [weak self] in self?.handleKey($0) ?? false }
        view.onDropFile = { [weak self] in self?.playFile($0) }

        instruments.frame = view.bounds
        instruments.autoresizingMask = [.width, .height]
        instruments.wantsLayer = true
        instruments.isHidden = UserDefaults.standard.bool(forKey: "instrumentsHidden")
        cockpit.frame = view.bounds
        cockpit.autoresizingMask = [.width, .height]
        cockpit.wantsLayer = true
        cockpit.layerContentsRedrawPolicy = .duringViewResize
        view.addSubview(cockpit) // below the console, HUD and stats (added after)
        setCockpit(UserDefaults.standard.bool(forKey: "cockpit"))
        view.addSubview(instruments)

        stats.source = { [weak self] in self?.renderer.takeStats() ?? (0, 0) }
        stats.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stats)
        NSLayoutConstraint.activate([
            stats.topAnchor.constraint(equalTo: view.topAnchor, constant: 34),
            stats.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        stats.isHidden = !UserDefaults.standard.bool(forKey: "showStats")
        renderer.onFrame = { [weak self] input, dt in
            guard let self, !self.instruments.isHidden else { return }
            self.instruments.panel.update(input, dt: dt)
            // Redraw the console at about 60 Hz; the springs still integrate every frame.
            self.panelClock += dt
            if self.panelClock >= 1 / 62 {
                self.panelClock = 0
                self.instruments.refresh()
            }
        }

        hud = NSTextField(labelWithString: "")
        hud.font = .systemFont(ofSize: 13, weight: .medium)
        hud.textColor = NSColor(white: 1, alpha: 0.85)
        hud.maximumNumberOfLines = 0
        hud.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 6
        hud.shadow = shadow
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -22),
            hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 38),
        ])

        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                                               .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Nebula Drift"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()

        // Hide the mouse pointer after it has been still for a couple of seconds; it returns when moved.
        window.acceptsMouseMovedEvents = true
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] e in
            self?.lastMouseMove = CACurrentMediaTime()
            return e
        }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, CACurrentMediaTime() - self.lastMouseMove > 2, NSApp.isActive,
                  self.window.isKeyWindow, self.window.attachedSheet == nil,
                  self.view.bounds.contains(self.view.convert(self.window.mouseLocationOutsideOfEventStream, from: nil))
            else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }

        sources.onStatus = { [weak self] in self?.showHUD($0) }
        sources.startSystemAudio()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { sources.stopAll() }

    func windowDidEnterFullScreen(_ notification: Notification) { NSCursor.setHiddenUntilMouseMoves(true) }

    private func showHUD(_ message: String, seconds: Double = 6) {
        hudToken += 1
        let token = hudToken
        hud.stringValue = message + "\n" + Self.hints
        hud.alphaValue = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.hudToken == token else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 1.2; self.hud.animator().alphaValue = 0 }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, window.styleMask.contains(.fullScreen) { // Esc
            window.toggleFullScreen(nil)
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p":
            stats.isHidden.toggle()
            UserDefaults.standard.set(!stats.isHidden, forKey: "showStats")
        case "b":
            renderer.spawnBlackHole()
            showHUD("Gravitational anomaly detected ahead", seconds: 3)
        case "t":
            renderer.spawnFlyThrough()
            showHUD("Course set: straight into the next one", seconds: 2)
        case "i":
            instruments.isHidden.toggle()
            UserDefaults.standard.set(instruments.isHidden, forKey: "instrumentsHidden")
        case "s": useSystemAudio()
        case "m": useMicrophone()
        case "o": openFile()
        case "f": window.toggleFullScreen(nil)
        case "d" where event.modifierFlags.contains(.shift):
            renderer.ditherStrength = renderer.ditherStrength % 4 + 1
            UserDefaults.standard.set(renderer.ditherStrength, forKey: "ditherStrength")
            let names = ["Light", "Medium", "Strong", "Heavy"]
            showHUD("Dither strength: \(names[renderer.ditherStrength - 1])", seconds: 2)
        case "g":
            setCockpit(!renderer.cockpitGlass)
            UserDefaults.standard.set(renderer.cockpitGlass, forKey: "cockpit")
            showHUD(renderer.cockpitGlass ? "Cockpit: canopy glass" : "Cockpit: open view", seconds: 2)
        case "c":
            renderer.aberration.toggle()
            UserDefaults.standard.set(renderer.aberration, forKey: "aberration")
            showHUD(renderer.aberration ? "Chromatic aberration: On" : "Chromatic aberration: Off", seconds: 2)
        case "d":
            let next = DitherMode(rawValue: (renderer.ditherMode.rawValue + 1) % DitherMode.allCases.count)!
            renderer.ditherMode = next
            UserDefaults.standard.set(next.rawValue, forKey: "dither")
            showHUD(next.label, seconds: 2)
        case "q":
            view.renderScale = view.renderScale > 1 ? 1 : 2
            showHUD(view.renderScale > 1 ? "Quality: Retina" : "Quality: Standard (smoother)", seconds: 2)
        case "h":
            if hud.alphaValue > 0.5 {
                hudToken += 1
                hud.alphaValue = 0
            } else {
                showHUD("Nebula Drift", seconds: 8)
            }
        default: return false
        }
        return true
    }

    private func setCockpit(_ on: Bool) {
        renderer.cockpitGlass = on
        cockpit.isHidden = !on
    }

    @objc func useSystemAudio() {
        instruments.panel.source = .system
        sources.startSystemAudio()
    }

    @objc func useMicrophone() {
        instruments.panel.source = .mic
        sources.startMicrophone()
    }

    private func playFile(_ url: URL) {
        instruments.panel.source = .file
        sources.play(file: url)
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.playFile(url) }
        }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nebula Drift",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nebula Drift", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Nebula Drift", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let sourceItem = NSMenuItem()
        let sourceMenu = NSMenu(title: "Source")
        for (title, action, key) in [("System Audio", #selector(useSystemAudio), "1"),
                                     ("Microphone", #selector(useMicrophone), "2"),
                                     ("Open Audio File…", #selector(openFile), "o")] {
            let item = sourceMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        sourceItem.submenu = sourceMenu
        main.addItem(sourceItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                                  keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}

// MARK: - Entry point

/// `--snapshot <dir>` renders a calm and a loud frame with synthetic audio, for testing without a window.
func runSnapshot(dir: String) throws {
    guard let device = MTLCreateSystemDefaultDevice(),
          let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal") else {
        throw NSError(domain: "NebulaDrift", code: 2)
    }
    let source = try String(contentsOf: url, encoding: .utf8)
    for (name, loud, dither) in [("calm", Float(0.1), DitherMode.smooth), ("loud", 1, .smooth), ("retro", 1, .retro)] {
        var t: Float = 0
        let panel = InstrumentPanel()
        let renderer = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { dt in
            t += dt
            var f = AudioFeatures()
            f.bands = (0..<AudioAnalyzer.bandCount).map { i in
                loud * (0.75 - Float(i) / 140 + 0.2 * sinf(Float(i) * 0.5 + t * 3))
            }
            f.bass = loud * 0.85
            f.mid = loud * 0.6
            f.treble = loud * 0.5
            f.level = loud * 0.7
            f.beat = loud * 0.6
            f.beatAge = loud > 0.5 ? fmodf(t, 0.5) : 10
            f.centroid = 0.4
            return f
        }
        renderer.ditherMode = dither
        renderer.onFrame = { panel.update($0, dt: $1) }
        for _ in 0..<180 { renderer.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900)) }
        if name != "calm" {
            renderer.placeObjectsForTesting()
            renderer.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900))
        }
        try renderer.snapshot(width: 1600, height: 900, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) {
            panel.draw(in: $0, viewSize: CGSize(width: 1600, height: 900))
        }
    }
    // Fly-throughs: deep inside a nebula and a galaxy.
    for (name, galaxy, radius) in [("through_nebula", false, Float(12)), ("through_galaxy", true, Float(9))] {
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
            var f = AudioFeatures()
            f.level = 0.5
            f.mid = 0.5
            f.treble = 0.4
            return f
        }
        r.placeFlyThroughForTesting(galaxy: galaxy, radius: radius)
        r.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900))
        try r.snapshot(width: 1600, height: 900, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    // Beat detector check: long, sustained kicks every 0.5 s for 10 s should give ~20 beats, not doubles.
    do {
        let analyzer = AudioAnalyzer()
        let rate: Float = 48000
        var beats = 0, lastAge: Float = .infinity, t: Float = 0
        var buffer = [Float](repeating: 0, count: 800) // 1/60 s of audio
        for _ in 0..<600 {
            for i in buffer.indices {
                let time = t + Float(i) / rate
                let phase = fmodf(time, 0.5)
                let env = phase < 0.4 ? expf(-phase * 2) : 0 // a long 0.4 s tail on each kick
                buffer[i] = sinf(2 * .pi * 60 * time) * 0.6 * env
            }
            buffer.withUnsafeBufferPointer { analyzer.push($0.baseAddress!, count: $0.count, sampleRate: rate) }
            let f = analyzer.analyze(dt: 1 / 60)
            if f.beatAge < lastAge { beats += 1 }
            lastAge = f.beatAge
            t += Float(buffer.count) / rate
        }
        print("beat check: \(beats) beats from 20 kicks")
    }

    // GPU cost of a frame with a black hole close by.
    do {
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in AudioFeatures() }
        r.placeBlackHoleForTesting(zRs: 30, stress: 0, seed: 0.8 / 3.7)
        r.step(dt: 1 / 60, size: CGSize(width: 1512, height: 900))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("bench.png")
        try r.snapshot(width: 1512, height: 900, to: url)
        let t0 = CACurrentMediaTime()
        for _ in 0..<10 { try r.snapshot(width: 1512, height: 900, to: url) }
        let withHole = (CACurrentMediaTime() - t0) * 100
        r.spawnFlyThrough(galaxy: false)
        r.placeBlackHoleForTesting(zRs: 30, stress: 0, seed: 0.8 / 3.7)
        let plain = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in AudioFeatures() }
        plain.step(dt: 1 / 60, size: CGSize(width: 1512, height: 900))
        try plain.snapshot(width: 1512, height: 900, to: url)
        let t1 = CACurrentMediaTime()
        for _ in 0..<10 { try plain.snapshot(width: 1512, height: 900, to: url) }
        let without = (CACurrentMediaTime() - t1) * 100
        print(String(format: "frame with black hole %.1f ms, without %.1f ms (both incl. PNG write)", withHole, without))
    }

    // Black hole variants: standard, quasar, bare, torus (seeds chosen so fract(seed * 3.7) picks each kind).
    for (name, kindR) in [("standard", Float(0.8)), ("quasar", 0.25), ("bare", 0.05), ("torus", 0.45)] {
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in AudioFeatures() }
        for _ in 0..<30 { r.step(dt: 1 / 60, size: CGSize(width: 800, height: 450)) }
        r.placeBlackHoleForTesting(zRs: 70, stress: 0, seed: kindR / 3.7)
        r.step(dt: 1 / 60, size: CGSize(width: 800, height: 450))
        try r.snapshot(width: 800, height: 450, to: URL(fileURLWithPath: dir).appendingPathComponent("bh_\(name).png"))
    }

    // Fly-through artifact check: frames every 0.75 s while passing straight through clouds and a galaxy.
    for (name, kind) in [("emission", Float?(0)), ("molecular", 8), ("veil", 7), ("galaxy", nil)] {
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
            var f = AudioFeatures()
            f.level = 0.4
            f.bass = 0.3
            return f
        }
        r.startFlyTest(cloudKind: kind)
        for frame in 0..<8 {
            for _ in 0..<45 { r.step(dt: 1 / 60, size: CGSize(width: 640, height: 360)) }
            try r.snapshot(width: 640, height: 360, to: URL(fileURLWithPath: dir).appendingPathComponent("fly_\(name)\(frame).png"))
        }
    }

    // Galaxy gallery: one frame per type (seed chosen so that fract(seed * 11.3) picks it).
    let types: [(String, Float, Float, Float)] = [("grand", 0.17, 2, 35), ("flocculent", 0.44, 3, 30), ("barred", 0.64, 2, 25),
                                                  ("irregular", 0.81, 2, 40), ("ring", 0.94, 2, 30),
                                                  ("lenticular", 0.25, 0, 78), ("elliptical", 0.75, 0, 50)]
    for (name, tr, arms, tilt) in types {
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
            var f = AudioFeatures()
            f.level = 0.3
            return f
        }
        r.placeGalaxyForTesting(seed: tr / 11.3, arms: arms, tilt: tilt)
        r.step(dt: 1 / 60, size: CGSize(width: 800, height: 450))
        try r.snapshot(width: 800, height: 450, to: URL(fileURLWithPath: dir).appendingPathComponent("galaxy_\(name).png"))
    }

    // One frame per cloud kind (nebulae 0-6, gas clouds 7-12).
    for k in 0...12 {
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
            var f = AudioFeatures()
            f.level = 0.3
            return f
        }
        r.placeNebulaForTesting(kind: Float(k))
        r.step(dt: 1 / 60, size: CGSize(width: 800, height: 450))
        try r.snapshot(width: 800, height: 450, to: URL(fileURLWithPath: dir).appendingPathComponent("kind\(k).png"))
    }

    // Black hole: approaching, close, and the violent pass (with the console and its alarm).
    for (name, z, stress, seed) in [("blackhole_far", Float(110), Float(0), Float(0.8 / 3.7)),
                                    ("blackhole_near", 45, 0.3, 0.8 / 3.7), ("blackhole_pass", 8, 0.9, 0.8 / 3.7),
                                    ("blackhole_torus_pass", 10, 0.6, 0.45 / 3.7)] {
        let panel = InstrumentPanel()
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
            var f = AudioFeatures()
            f.level = 0.5
            f.bass = 0.5
            return f
        }
        r.onFrame = { panel.update($0, dt: $1) }
        for _ in 0..<60 { r.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900)) }
        r.placeBlackHoleForTesting(zRs: z, stress: stress, seed: seed)
        for _ in 0..<12 { r.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900)) }
        try r.snapshot(width: 1600, height: 900, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) {
            panel.draw(in: $0, viewSize: CGSize(width: 1600, height: 900))
        }
    }

    // Cockpit canopy: scratched glass catching the light of a nebula, and of a black hole.
    for (name, hole) in [("cockpit_nebula", false), ("cockpit_blackhole", true)] {
        let panel = InstrumentPanel()
        let frame = CockpitFrameView()
        let r = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
            var f = AudioFeatures()
            f.level = 0.5
            f.bass = 0.4
            return f
        }
        r.cockpitGlass = true
        r.onFrame = { panel.update($0, dt: $1) }
        for _ in 0..<60 { r.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900)) }
        if hole { r.placeBlackHoleForTesting(zRs: 60, stress: 0) } else { r.placeNebulaForTesting(kind: 0) }
        r.step(dt: 1 / 60, size: CGSize(width: 1600, height: 900))
        try r.snapshot(width: 1600, height: 900, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) {
            frame.drawFrame(in: $0, bounds: CGRect(x: 0, y: 0, width: 1600, height: 900))
            panel.draw(in: $0, viewSize: CGSize(width: 1600, height: 900))
        }
    }

    // Fly-through sequence: one frame every 1.5 s while heading straight into a nebula.
    let pass = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
        var f = AudioFeatures()
        f.level = 0.4
        f.bass = 0.3
        return f
    }
    pass.spawnFlyThrough(galaxy: false)
    var trace: [String] = []
    for frame in 0..<10 {
        try pass.snapshot(width: 640, height: 360, to: URL(fileURLWithPath: dir).appendingPathComponent("pass\(frame).png"))
        trace.append(pass.testObjectDepth.map { String(format: "%.2f", $0) } ?? "gone")
        for _ in 0..<90 { pass.step(dt: 1 / 60, size: CGSize(width: 640, height: 360)) }
    }
    print("fly-through depth every 1.5 s:", trace.joined(separator: " "))

    // Journey: follow a fresh nebula and galaxy from spawn until they leave the screen.
    let journey = try Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source) { _ in
        var f = AudioFeatures()
        f.level = 0.4
        f.bass = 0.3
        return f
    }
    journey.spawnFreshForTesting()
    for frame in 0..<5 {
        try journey.snapshot(width: 800, height: 450,
                             to: URL(fileURLWithPath: dir).appendingPathComponent("journey\(frame).png"))
        for _ in 0..<(60 * 3) { journey.step(dt: 1 / 60, size: CGSize(width: 800, height: 450)) }
    }
    print("Snapshots written to \(dir)")
}

/// `--bench-console <dir>` times the instrument console's redraw (CPU only, no GPU needed) at Retina and normal
/// resolution, calm and under tidal stress, and writes each last frame as a PNG.
func runConsoleBench(dir: String, profileSeconds: Double = 0) {
    let cases: [(String, Int, Int, Int, Float)] = [("retina", 1600, 900, 2, 0), ("retina_alarm", 1600, 900, 2, 0.8),
                                                    ("standard", 1280, 780, 1, 0)]
    for (name, w, h, scale, alarm) in profileSeconds > 0 ? [cases[0]] : cases {
        let size = CGSize(width: w, height: h)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w * scale, height: h * scale, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        ctx.translateBy(x: 0, y: CGFloat(h * scale))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        let panel = InstrumentPanel()
        var t: Float = 0
        func frame() {
            t += 1 / 60
            let bands = (0..<AudioAnalyzer.bandCount).map { i in 0.5 + 0.3 * sinf(Float(i) * 0.4 + t * 5) }
            panel.update(PanelInput(bands: bands, bass: 0.5 + 0.4 * sinf(t * 7), mid: 0.5 + 0.3 * sinf(t * 3),
                                    treble: 0.4 + 0.3 * sinf(t * 11), level: 0.6, beat: fmodf(t, 0.5) < 0.1 ? 1 : 0,
                                    speed: 0.4 + 0.3 * sinf(t), hue: t * 0.05, centroid: 0.5, roll: t * 0.02,
                                    alarm: alarm), dt: 1 / 60)
            ctx.clear(CGRect(origin: .zero, size: size))
            panel.draw(in: ctx, viewSize: size)
        }
        for _ in 0..<20 { frame() }
        var count = 240
        let t0 = CACurrentMediaTime()
        if profileSeconds > 0 {
            // Keep redrawing for a profiler to sample.
            count = 0
            while CACurrentMediaTime() - t0 < profileSeconds {
                frame()
                count += 1
            }
        } else {
            for _ in 0..<count { frame() }
        }
        let ms = (CACurrentMediaTime() - t0) / Double(count) * 1000
        print(String(format: "console redraw %@ (%dx%d @%dx): %.2f ms", name, w, h, scale, ms))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("console_\(name).png")
        if let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--bench-console"), i + 1 < args.count {
    try? FileManager.default.createDirectory(atPath: args[i + 1], withIntermediateDirectories: true)
    let seconds = args.firstIndex(of: "--profile-seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    runConsoleBench(dir: args[i + 1], profileSeconds: seconds ?? 0)
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    do { try runSnapshot(dir: args[i + 1]) } catch { print("Snapshot failed: \(error)"); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

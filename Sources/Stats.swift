// Performance numbers for the stats overlay (P key).

import Cocoa
import IOKit

enum SystemStats {
    /// CPU time (user + system) this process has used, in seconds.
    static func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Whole-GPU utilization as reported by the graphics driver, in percent (all apps, not just this one).
    static func gpuUtilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? [String: Any],
               let util = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, util)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }
}

/// Small translucent readout in the top-right corner.
final class StatsOverlay: NSTextField {
    private var timer: Timer?
    private var lastWall = CACurrentMediaTime()
    private var lastCPU = SystemStats.processCPUTime()
    private var gpuPercent: Int?
    var source: (() -> (frames: Int, gpuSeconds: Double))?

    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        textColor = NSColor(red: 0.6, green: 1, blue: 0.72, alpha: 0.95)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        layer?.cornerRadius = 6
        alignment = .right
    }

    override var isHidden: Bool {
        didSet { isHidden ? stop() : start() }
    }

    private func start() {
        guard timer == nil else { return }
        lastWall = CACurrentMediaTime()
        lastCPU = SystemStats.processCPUTime()
        _ = source?()
        stringValue = " measuring… "
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime(), cpu = SystemStats.processCPUTime()
        let wall = max(now - lastWall, 1e-3)
        let cpuPercent = (cpu - lastCPU) / wall * 100
        lastWall = now
        lastCPU = cpu
        let (frames, gpuSeconds) = source?() ?? (0, 0)
        let fps = Double(frames) / wall
        let gpuMs = frames > 0 ? gpuSeconds / Double(frames) * 1000 : 0
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let util = SystemStats.gpuUtilization()
            DispatchQueue.main.async { self?.gpuPercent = util }
        }
        let gpu = gpuPercent.map { "\($0)%" } ?? "n/a"
        stringValue = String(format: " FPS %3.0f   CPU %3.0f%%   GPU %@ (%.1f ms/frame) ", fps, cpuPercent, gpu, gpuMs)
    }
}

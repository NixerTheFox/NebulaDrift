// `--bench-gpu`: how long the GPU spends on a frame (Metal's own timestamps, no read-back), for the heaviest
// scenes at MacBook Pro Retina and standard resolution.

import Metal

func runGPUBench() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
          let source = try? String(contentsOf: url, encoding: .utf8),
          let queue = device.makeCommandQueue() else {
        print("GPU benchmark: Metal unavailable")
        return
    }
    print("GPU: \(device.name)")
    let scenes: [(String, (Renderer) -> Void)] = [
        ("plain", { _ in }),
        ("black hole", { $0.placeBlackHoleForTesting(zRs: 30, stress: 0, seed: 0.8 / 3.7) }),
        ("cockpit glass", { $0.cockpitGlass = true }),
        ("black hole + glass", { r in
            r.cockpitGlass = true
            r.placeBlackHoleForTesting(zRs: 30, stress: 0, seed: 0.8 / 3.7)
        }),
    ]
    for (w, h) in [(3024, 1964), (1512, 982)] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc) else { continue }
        for (name, setup) in scenes {
            guard let r = try? Renderer(device: device, pixelFormat: .bgra8Unorm, shaderSource: source,
                                        features: { _ in AudioFeatures() }) else { continue }
            setup(r)
            r.step(dt: 1 / 60, size: CGSize(width: w, height: h))
            var total: Double = 0
            let warmUp = 3, frames = 12
            for i in 0..<(warmUp + frames) {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                guard let cb = queue.makeCommandBuffer() else { continue }
                r.encode(cb, pass: pass)
                cb.commit()
                cb.waitUntilCompleted()
                if i >= warmUp { total += cb.gpuEndTime - cb.gpuStartTime }
            }
            print(String(format: "GPU %dx%d %@: %.2f ms/frame", w, h, name, total / Double(frames) * 1000))
        }
    }
}

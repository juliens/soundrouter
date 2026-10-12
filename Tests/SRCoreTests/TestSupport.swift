import SRCore

/// Planar float buffers with the pointer arrays expected by the SRCore C API.
final class Planes {
    let channels: Int
    let frames: Int
    let data: [UnsafeMutablePointer<Float>]
    let mut: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    let const: UnsafeMutablePointer<UnsafePointer<Float>?>

    init(channels: Int, frames: Int) {
        self.channels = channels
        self.frames = frames
        data = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            p.initialize(repeating: 0, count: max(frames, 1))
            return p
        }
        mut = .allocate(capacity: max(channels, 1))
        const = .allocate(capacity: max(channels, 1))
        for c in 0..<channels {
            mut[c] = data[c]
            const[c] = UnsafePointer(data[c])
        }
    }

    deinit {
        data.forEach { $0.deallocate() }
        mut.deallocate()
        const.deallocate()
    }

    subscript(c: Int, i: Int) -> Float {
        get { data[c][i] }
        set { data[c][i] = newValue }
    }

    func fill(_ f: (Int, Int) -> Float) {
        for c in 0..<channels { for i in 0..<frames { data[c][i] = f(c, i) } }
    }

    func channel(_ c: Int) -> [Float] { Array(UnsafeBufferPointer(start: data[c], count: frames)) }
}

/// Owns a heap SRMixPlan.
final class Plan {
    let ptr: UnsafeMutablePointer<SRMixPlan>

    struct Src { var channels: UInt32 = 2; var volume: Float = 1; var muted = false; var active = true }

    init(outputs: UInt32, sources: [Src], routes: [(UInt32, UInt32, UInt32, Float)],
         volume: Float = 1, muted: Bool = false) {
        ptr = sr_mix_plan_create(UInt32(routes.count))
        ptr.pointee.outputChannels = outputs
        ptr.pointee.volume = volume
        ptr.pointee.muted = muted
        ptr.pointee.sourceCount = UInt32(sources.count)
        let s = sr_mix_plan_sources(ptr)!
        for (i, src) in sources.enumerated() {
            s[i] = SRMixSource(channels: src.channels, volume: src.volume, muted: src.muted,
                               active: src.active)
        }
        let r = sr_mix_plan_routes(ptr)!
        for (i, rt) in routes.enumerated() {
            r[i] = SRRoute(sourceIndex: rt.0, sourceChannel: rt.1, outputChannel: rt.2, gain: rt.3)
        }
        ptr.pointee.routeCount = UInt32(routes.count)
    }

    deinit { sr_mix_plan_destroy(ptr) }
}

/// Array of per-source plane arrays for sr_mix_render.
final class SourceList {
    let ptr: UnsafeMutablePointer<UnsafePointer<UnsafePointer<Float>?>?>
    let count: Int
    init(_ sources: [Planes?]) {
        count = sources.count
        ptr = .allocate(capacity: max(sources.count, 1))
        for (i, s) in sources.enumerated() { ptr[i] = s.map { UnsafePointer($0.const) } }
    }
    deinit { ptr.deallocate() }
}

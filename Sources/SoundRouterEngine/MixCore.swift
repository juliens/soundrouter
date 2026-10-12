import Darwin
import Foundation
import SRCore

// Real-time mix core of a DeviceEngine.
//
// RT-SAFETY CHOICE: the mix loop is written in "C-style" Swift rather than a C helper (SRCore
// is owned by another component). Everything the mix thread touches is a trivially-typed
// struct (`MixContext`, `RenderState`) reached through Unsafe*Pointers allocated on the
// control queue: no class references, no arrays, no closures, no existential or generic
// dispatch — hence no allocation, no ARC traffic, no locks and no Objective-C on the RT thread.
// Only SRCore [RT] functions, mach_absolute_time and mach_wait_until are called.
// Swift objects that own C resources (`SourceBuffers`) are kept alive by a `RenderResources`
// box retained by each published RenderState and released by the slot's freeFn, which SRCore
// runs on the writer (control) thread once the reader has passed a quiescent point.

// MARK: - Shm header atomics

/// SRShmHeader's `_Atomic` fields are not imported into Swift (clang importer skips C11
/// atomics), so they are accessed at their fixed byte offsets (layout frozen by the
/// `_Static_assert(sizeof == 512)` contract, checked by `ShmField.validateLayout`).
/// Aligned 32/64-bit loads/stores are single-copy atomic on arm64 and x86_64; ordering is
/// relaxed, which is sufficient for heartbeat/volume/seq polling (mixWriteFrame, the only
/// field needing release semantics, is published by sr_device_write_mix in C).
enum ShmField {
    static let engineHeartbeat = 40          // u64
    static let mixWriteFrame = 48            // i64
    static let passThruWriteFrame = 56       // i64
    static let driverIORunning = 64          // u32
    static let driverMapped = 68             // u32
    static let volumeBits = 72               // u32
    static let muted = 76                    // u32
    static let hostVolumeBits = 80           // u32
    static let hostMuted = 84                // u32
    static let hostControlSeq = 88           // u32
    static let requestedSampleRateBits = 96  // u64
    static let underrunCount = 104           // u64

    @inline(__always)
    static func load32(_ h: UnsafeMutablePointer<SRShmHeader>, _ offset: Int) -> UInt32 {
        sr_atomic_load_u32(UnsafeRawPointer(h) + offset)
    }

    @inline(__always)
    static func load64(_ h: UnsafeMutablePointer<SRShmHeader>, _ offset: Int) -> UInt64 {
        sr_atomic_load_u64(UnsafeRawPointer(h) + offset)
    }

    @inline(__always)
    static func store32(_ h: UnsafeMutablePointer<SRShmHeader>, _ offset: Int, _ v: UInt32) {
        sr_atomic_store_u32(UnsafeMutableRawPointer(h) + offset, v)
    }

    @inline(__always)
    static func store64(_ h: UnsafeMutablePointer<SRShmHeader>, _ offset: Int, _ v: UInt64) {
        sr_atomic_store_u64(UnsafeMutableRawPointer(h) + offset, v)
    }

    /// Checks the offsets above against the fields Swift can see.
    static func validateLayout() -> String? {
        if MemoryLayout<SRShmHeader>.size != 512 { return "sizeof(SRShmHeader) = \(MemoryLayout<SRShmHeader>.size)" }
        if MemoryLayout<SRShmHeader>.offset(of: \SRShmHeader.sampleRate) != 16 { return "sampleRate offset" }
        if MemoryLayout<SRShmHeader>.offset(of: \SRShmHeader.anchorHostTime) != 24 { return "anchorHostTime offset" }
        if MemoryLayout<SRShmHeader>.offset(of: \SRShmHeader.hasPassThru) != 32 { return "hasPassThru offset" }
        if MemoryLayout<SRShmHeader>.offset(of: \SRShmHeader._reserved) != 112 { return "_reserved offset" }
        return nil
    }
}

/// SRMeters also only has `_Atomic` fields; Swift sees it as an empty struct, so it is
/// allocated raw with its C size (sr_meters_size()).
enum MetersAlloc {
    static let byteCount = sr_meters_size()

    static func allocate() -> UnsafeMutablePointer<SRMeters> {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        return raw.assumingMemoryBound(to: SRMeters.self)
    }

    static func free(_ m: UnsafeMutablePointer<SRMeters>) {
        UnsafeMutableRawPointer(m).deallocate()
    }
}

// MARK: - Buffers shared between a producer and the mix thread (or mix thread and a monitor)

/// SPSC ring + drift resampler pair. Destroyed on deinit, which only ever happens on the
/// control queue (last reference held by a Swift owner or a retired RenderState).
final class SourceBuffers {
    let ring: OpaquePointer
    let resampler: OpaquePointer
    let channels: Int
    let srcRate: Double
    let dstRate: Double
    let targetFill: UInt32

    /// - producerFrames: typical burst size of the producer (IO buffer size), in src frames.
    /// - consumerFrames: burst size of the consumer (mix cycle / monitor IO buffer), in dst frames.
    init?(channels: Int, srcRate: Double, dstRate: Double, producerFrames: UInt32, consumerFrames: UInt32) {
        let consumerInSrc = Double(consumerFrames) * srcRate / max(dstRate, 1)
        let target = UInt32(max(Double(producerFrames) + consumerInSrc, 2 * consumerInSrc).rounded(.up))
        let capacity = max(target * 4, consumerFrames * 8, 4096)
        guard channels > 0,
              let ring = sr_ring_create(UInt32(channels), capacity) else { return nil }
        guard let drs = sr_drs_create(UInt32(channels), srcRate, dstRate, target) else {
            sr_ring_destroy(ring)
            return nil
        }
        self.ring = ring
        self.resampler = drs
        self.channels = channels
        self.srcRate = srcRate
        self.dstRate = dstRate
        self.targetFill = target
    }

    var underruns: UInt64 { sr_drs_underruns(resampler) }

    deinit {
        sr_drs_destroy(resampler)
        sr_ring_destroy(ring)
    }
}

/// Keeps the Swift owners of everything a RenderState points to alive.
final class RenderResources {
    let objects: [AnyObject]
    init(_ objects: [AnyObject]) { self.objects = objects }
}

// MARK: - RenderState (published via SRPlanSlot)

enum RenderSourceKind: UInt8 {
    case silent = 0     // inactive: plan marks it inactive, planes stay zero
    case ring = 1       // application tap / input device: sr_drs_pull
    case passThru = 2   // sr_device_read_passthru
}

struct RenderSourceSpec {
    var kind: RenderSourceKind
    var channels: Int
    var volume: Float
    var muted: Bool
    var buffers: SourceBuffers?
}

/// Immutable, C-layout-compatible snapshot of one device's graph: the SRMixPlan plus the
/// pointer tables the mix thread needs. Built on the control queue, swapped atomically.
struct RenderState {
    var plan: UnsafeMutablePointer<SRMixPlan>
    var sourceCount: Int
    var kinds: UnsafeMutablePointer<UInt8>
    var rings: UnsafeMutablePointer<OpaquePointer?>
    var resamplers: UnsafeMutablePointer<OpaquePointer?>
    /// Per source: pointer to its first plane pointer inside `planePointers`.
    var planeTable: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?>
    var planePointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    var scratch: UnsafeMutablePointer<Float>
    var monitorCount: Int
    var monitorRings: UnsafeMutablePointer<OpaquePointer?>
    var resources: UnsafeMutableRawPointer?

    static let maxMonitors = 16

    /// Byte offset of SRMixPlan.routes (flexible array member, not imported into Swift).
    static let routesOffset: Int = {
        let off = MemoryLayout<SRMixPlan>.offset(of: \SRMixPlan.routeCount)! + MemoryLayout<UInt32>.size
        let align = MemoryLayout<SRRoute>.alignment
        return (off + align - 1) / align * align
    }()

    /// Allocates a RenderState. `routes` must reference indices < sources.count and channels in range.
    static func create(outputChannels: Int, volume: Float, muted: Bool, sources: [RenderSourceSpec],
                       routes: [SRRoute], monitors: [SourceBuffers], cycleFrames: Int)
        -> UnsafeMutablePointer<RenderState>? {
        let n = min(sources.count, Int(SR_MAX_SOURCES))
        guard let plan = sr_mix_plan_create(UInt32(routes.count)) else { return nil }
        plan.pointee.outputChannels = UInt32(outputChannels)
        plan.pointee.volume = volume
        plan.pointee.muted = muted
        plan.pointee.sourceCount = UInt32(n)
        withUnsafeMutablePointer(to: &plan.pointee.sources) { tuple in
            tuple.withMemoryRebound(to: SRMixSource.self, capacity: Int(SR_MAX_SOURCES)) { src in
                for i in 0..<n {
                    let s = sources[i]
                    src[i] = SRMixSource(channels: UInt32(s.channels), volume: s.volume, muted: s.muted,
                                         active: s.kind != .silent)
                }
            }
        }
        let routePtr = (UnsafeMutableRawPointer(plan) + routesOffset).assumingMemoryBound(to: SRRoute.self)
        var rc = 0
        for r in routes where Int(r.sourceIndex) < n {
            routePtr[rc] = r
            rc += 1
        }
        plan.pointee.routeCount = UInt32(rc)

        let totalPlanes = max(1, sources.prefix(n).reduce(0) { $0 + $1.channels })
        let st = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        let kinds = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(SR_MAX_SOURCES))
        let rings = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: Int(SR_MAX_SOURCES))
        let drs = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: Int(SR_MAX_SOURCES))
        let table = UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?>.allocate(capacity: Int(SR_MAX_SOURCES))
        let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: totalPlanes)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: totalPlanes * cycleFrames)
        scratch.initialize(repeating: 0, count: totalPlanes * cycleFrames)
        kinds.initialize(repeating: 0, count: Int(SR_MAX_SOURCES))
        rings.initialize(repeating: nil, count: Int(SR_MAX_SOURCES))
        drs.initialize(repeating: nil, count: Int(SR_MAX_SOURCES))
        table.initialize(repeating: nil, count: Int(SR_MAX_SOURCES))
        planes.initialize(repeating: nil, count: totalPlanes)

        var keep: [AnyObject] = []
        var p = 0
        for i in 0..<n {
            let s = sources[i]
            kinds[i] = s.kind.rawValue
            if s.kind == .ring, let b = s.buffers {
                rings[i] = b.ring
                drs[i] = b.resampler
                keep.append(b)
            } else if s.kind == .ring {
                kinds[i] = RenderSourceKind.silent.rawValue
            }
            table[i] = planes + p
            for c in 0..<s.channels {
                planes[p + c] = scratch + (p + c) * cycleFrames
            }
            p += s.channels
        }
        let mcount = min(monitors.count, maxMonitors)
        let mrings = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: maxMonitors)
        mrings.initialize(repeating: nil, count: maxMonitors)
        for i in 0..<mcount {
            mrings[i] = monitors[i].ring
            keep.append(monitors[i])
        }
        st.initialize(to: RenderState(plan: plan, sourceCount: n, kinds: kinds, rings: rings, resamplers: drs,
                                      planeTable: table, planePointers: planes, scratch: scratch,
                                      monitorCount: mcount, monitorRings: mrings,
                                      resources: Unmanaged.passRetained(RenderResources(keep)).toOpaque()))
        return st
    }

    /// SRPlanSlot freeFn. Runs on the control queue (sr_slot_publish / collect / destroy).
    static let free: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
        guard let raw else { return }
        let st = raw.assumingMemoryBound(to: RenderState.self)
        let s = st.pointee
        sr_mix_plan_destroy(s.plan)
        s.kinds.deallocate()
        s.rings.deallocate()
        s.resamplers.deallocate()
        s.planeTable.deallocate()
        s.planePointers.deallocate()
        s.scratch.deallocate()
        s.monitorRings.deallocate()
        if let r = s.resources { Unmanaged<RenderResources>.fromOpaque(r).release() }
        st.deinitialize(count: 1)
        st.deallocate()
    }
}

// MARK: - Mix thread

/// Everything the mix thread reads. Allocated once per DeviceEngine run.
struct MixContext {
    var header: UnsafeMutablePointer<SRShmHeader>
    var slot: OpaquePointer
    var meters: UnsafeMutablePointer<SRMeters>
    var cycle: UInt32
    var channels: UInt32
    var sampleRate: Double
    var outPlanes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    var outStorage: UnsafeMutablePointer<Float>
    var lead: Int64
    var passThruDelay: Int64
    var anchorHostTime: UInt64
    var hostTicksPerSample: Double
    // Control -> RT flags (plain word stores; re-read every iteration after an opaque call).
    var stopRequested: UInt32
    var resyncRequested: UInt32
    // RT -> control statistics.
    var realtimeStatus: Int32        // realtimePending until the thread has tried to promote itself
    var resyncCount: UInt64
    var cyclesRendered: UInt64

    static let realtimePending = Int32.min

    static func allocate(header: UnsafeMutablePointer<SRShmHeader>, slot: OpaquePointer,
                         meters: UnsafeMutablePointer<SRMeters>, cycle: Int, channels: Int,
                         sampleRate: Double) -> UnsafeMutablePointer<MixContext> {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticksPerSecond = 1e9 * Double(tb.denom) / Double(tb.numer)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: channels * cycle)
        out.initialize(repeating: 0, count: channels * cycle)
        let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        for c in 0..<channels { (planes + c).initialize(to: out + c * cycle) }
        let ctx = UnsafeMutablePointer<MixContext>.allocate(capacity: 1)
        ctx.initialize(to: MixContext(
            header: header, slot: slot, meters: meters, cycle: UInt32(cycle), channels: UInt32(channels),
            sampleRate: sampleRate, outPlanes: planes, outStorage: out,
            lead: Int64(2 * cycle), passThruDelay: Int64(3 * cycle + 512),
            anchorHostTime: header.pointee.anchorHostTime, hostTicksPerSample: ticksPerSecond / sampleRate,
            stopRequested: 0, resyncRequested: 0, realtimeStatus: MixContext.realtimePending, resyncCount: 0, cyclesRendered: 0))
        return ctx
    }

    static func free(_ ctx: UnsafeMutablePointer<MixContext>) {
        ctx.pointee.outPlanes.deallocate()
        ctx.pointee.outStorage.deallocate()
        ctx.deinitialize(count: 1)
        ctx.deallocate()
    }
}

enum MixThread {
    /// Starts the RT mix thread. Returns nil on failure.
    static func start(_ ctx: UnsafeMutablePointer<MixContext>) -> pthread_t? {
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_setstacksize(&attr, 512 * 1024)
        var tid: pthread_t?
        let rc = pthread_create(&tid, &attr, { raw in
            MixThread.main(raw.assumingMemoryBound(to: MixContext.self))
            return nil
        }, UnsafeMutableRawPointer(ctx))
        pthread_attr_destroy(&attr)
        return rc == 0 ? tid : nil
    }

    static func stop(_ ctx: UnsafeMutablePointer<MixContext>, thread: pthread_t) {
        ctx.pointee.stopRequested = 1
        pthread_join(thread, nil)
    }

    // ---------------------------------------------------------------- RT code below

    /// Thread body. RT-safe after sr_thread_set_realtime.
    static func main(_ ctx: UnsafeMutablePointer<MixContext>) {
        pthread_setname_np("io.soundrouter.mix")
        ctx.pointee.realtimeStatus = sr_thread_set_realtime(ctx.pointee.cycle, ctx.pointee.sampleRate)

        let h = ctx.pointee.header
        let cycle = Int64(ctx.pointee.cycle)
        let lead = ctx.pointee.lead
        var writePos = sr_device_now_sample_time(h) + cycle

        while ctx.pointee.stopRequested == 0 {
            let now = sr_device_now_sample_time(h)
            if ctx.pointee.resyncRequested != 0 || writePos < now - cycle || writePos > now + 4 * cycle {
                // After sleep, a stall or an explicit request: restart just ahead of "now".
                ctx.pointee.resyncRequested = 0
                ctx.pointee.resyncCount &+= 1
                writePos = now + cycle
            }
            let target = now + lead
            while writePos < target {
                renderCycle(ctx, at: writePos)
                writePos += cycle
                ctx.pointee.cyclesRendered &+= 1
            }
            ShmField.store64(h, ShmField.engineHeartbeat, mach_absolute_time())

            // Sleep until the device clock reaches writePos - lead (next cycle boundary).
            let wakeSample = writePos - lead
            let wakeHost = ctx.pointee.anchorHostTime
                &+ UInt64(max(0, Double(wakeSample) * ctx.pointee.hostTicksPerSample))
            let nowHost = mach_absolute_time()
            // Never sleep longer than 4 cycles (keeps stop latency bounded if the clock jumps).
            let maxSleep = UInt64(Double(4 * cycle) * ctx.pointee.hostTicksPerSample)
            if wakeHost > nowHost {
                mach_wait_until(min(wakeHost, nowHost &+ maxSleep))
            }
        }
    }

    @inline(__always)
    static func renderCycle(_ ctx: UnsafeMutablePointer<MixContext>, at pos: Int64) {
        let h = ctx.pointee.header
        let slot = ctx.pointee.slot
        let frames = ctx.pointee.cycle
        let outPlanes = UnsafePointer(ctx.pointee.outPlanes)
        let outConst = UnsafeRawPointer(ctx.pointee.outPlanes).assumingMemoryBound(to: UnsafePointer<Float>?.self)

        guard let raw = sr_slot_acquire(slot) else {
            ctx.pointee.outStorage.update(repeating: 0, count: Int(ctx.pointee.channels) * Int(frames))
            sr_device_write_mix(h, pos, outConst, frames)
            sr_slot_release(slot)
            return
        }
        let st = raw.assumingMemoryBound(to: RenderState.self)
        let n = st.pointee.sourceCount
        var i = 0
        while i < n {
            let kind = st.pointee.kinds[i]
            if let planes = st.pointee.planeTable[i] {
                if kind == RenderSourceKind.ring.rawValue {
                    _ = sr_drs_pull(st.pointee.resamplers[i], st.pointee.rings[i], UnsafePointer(planes), frames)
                } else if kind == RenderSourceKind.passThru.rawValue {
                    _ = sr_device_read_passthru(h, pos - ctx.pointee.passThruDelay, UnsafePointer(planes), frames)
                }
            }
            i += 1
        }
        let sourcePlanes = UnsafeRawPointer(st.pointee.planeTable)
            .assumingMemoryBound(to: UnsafePointer<UnsafePointer<Float>?>?.self)
        sr_mix_render(st.pointee.plan, sourcePlanes, outPlanes, frames, ctx.pointee.meters)
        sr_device_write_mix(h, pos, outConst, frames)
        var m = 0
        let mc = st.pointee.monitorCount
        while m < mc {
            if let ring = st.pointee.monitorRings[m] {
                _ = sr_ring_write(ring, outConst, frames)
            }
            m += 1
        }
        sr_slot_release(slot)
    }
}

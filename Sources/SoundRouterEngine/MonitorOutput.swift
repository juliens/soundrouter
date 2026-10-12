import AudioToolbox
import CoreAudio
import Foundation
import SRCore
import SoundRouterKit

/// Monitor routing parameters, hot-swapped through an SRPlanSlot.
struct MonitorParams {
    var gain: Float                          // volume, 0 when muted
    var routeCount: Int
    var deviceChannels: UnsafeMutablePointer<Int32>
    var monitorChannels: UnsafeMutablePointer<Int32>

    static func create(_ m: Monitor, deviceChannelCount: Int) -> UnsafeMutablePointer<MonitorParams> {
        let routes = m.routes.filter { $0.deviceChannel >= 0 && $0.deviceChannel < deviceChannelCount && $0.monitorChannel >= 0 }
        let dc = UnsafeMutablePointer<Int32>.allocate(capacity: max(routes.count, 1))
        let mc = UnsafeMutablePointer<Int32>.allocate(capacity: max(routes.count, 1))
        for (i, r) in routes.enumerated() {
            (dc + i).initialize(to: Int32(r.deviceChannel))
            (mc + i).initialize(to: Int32(r.monitorChannel))
        }
        let p = UnsafeMutablePointer<MonitorParams>.allocate(capacity: 1)
        p.initialize(to: MonitorParams(gain: m.muted ? 0 : m.volume, routeCount: routes.count,
                                       deviceChannels: dc, monitorChannels: mc))
        return p
    }

    static let free: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
        guard let raw else { return }
        let p = raw.assumingMemoryBound(to: MonitorParams.self)
        p.pointee.deviceChannels.deallocate()
        p.pointee.monitorChannels.deallocate()
        p.deinitialize(count: 1)
        p.deallocate()
    }
}

struct MonitorIOContext {
    var ring: OpaquePointer
    var resampler: OpaquePointer
    var slot: OpaquePointer
    var planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    var storage: UnsafeMutablePointer<Float>
    var channels: UInt32          // virtual device channels (ring channels)
    var maxFrames: UInt32
}

/// [RT] AUHAL output render callback: ring -> drift resampler -> channel mapping.
private let monitorRenderCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let c = refCon.assumingMemoryBound(to: MonitorIOContext.self)
    let out = UnsafeMutableAudioBufferListPointer(ioData)
    let outCount = out.count
    var b = 0
    while b < outCount {
        if let d = out[b].mData { memset(d, 0, Int(out[b].mDataByteSize)) }
        b += 1
    }
    guard frames <= c.pointee.maxFrames else { return noErr }
    _ = sr_drs_pull(c.pointee.resampler, c.pointee.ring, UnsafePointer(c.pointee.planes), frames)
    let slot = c.pointee.slot
    if let raw = sr_slot_acquire(slot) {
        let p = raw.assumingMemoryBound(to: MonitorParams.self)
        let gain = p.pointee.gain
        let n = p.pointee.routeCount
        var r = 0
        while r < n {
            let dch = Int(p.pointee.deviceChannels[r])
            let mch = Int(p.pointee.monitorChannels[r])
            if gain != 0, dch < Int(c.pointee.channels), mch < outCount,
               let dst = out[mch].mData?.assumingMemoryBound(to: Float.self),
               let src = c.pointee.planes[dch] {
                let count = min(Int(frames), Int(out[mch].mDataByteSize) / 4)
                var k = 0
                while k < count { dst[k] += src[k] * gain; k += 1 }
            }
            r += 1
        }
    }
    sr_slot_release(slot)
    return noErr
}

/// One monitor: AUHAL output on a physical device fed by the mix thread through a ring.
final class MonitorOutput {
    let id: UUID
    private(set) var monitor: Monitor
    private let deviceChannels: Int
    private let deviceRate: Double
    private let cycle: Int
    private unowned let env: EngineEnvironment
    private let onChange: () -> Void

    private(set) var state: SourceState = .disconnected
    private(set) var buffers: SourceBuffers?
    private var unit: AudioUnit?
    private var ioContext: UnsafeMutablePointer<MonitorIOContext>?
    private var slot: OpaquePointer?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var rateListener: CAListener?
    private var stopped = true

    init(monitor: Monitor, deviceChannels: Int, deviceRate: Double, cycle: Int, env: EngineEnvironment,
         onChange: @escaping () -> Void) {
        id = monitor.id
        self.monitor = monitor
        self.deviceChannels = deviceChannels
        self.deviceRate = deviceRate
        self.cycle = cycle
        self.env = env
        self.onChange = onChange
    }

    deinit { teardown() }

    var underruns: UInt64 { buffers?.underruns ?? 0 }

    func start() {
        stopped = false
        attach()
    }

    func stop() {
        stopped = true
        teardown()
    }

    /// Hot update of volume / mute / routes (no restart).
    func update(_ m: Monitor) {
        monitor = m
        if let slot { sr_slot_publish(slot, MonitorParams.create(m, deviceChannelCount: deviceChannels)) }
    }

    func collect() {
        if let slot { sr_slot_collect(slot) }
    }

    func handle(_ event: HardwareEvent) {
        guard !stopped else { return }
        switch event {
        case .devicesChanged:
            let dev = CA.device(forUID: monitor.deviceUID)
            if dev != deviceID || unit == nil { restart() }
        case .didWake: if unit == nil { attach() }
        default: break
        }
    }

    private func restart() {
        teardown()
        attach()
    }

    private func attach() {
        guard !stopped, unit == nil else { return }
        guard let dev = CA.device(forUID: monitor.deviceUID) else {
            setState(.disconnected)
            return
        }
        deviceID = dev
        do {
            try setup(device: dev)
            setState(.active)
        } catch {
            Log.error("Monitor \(monitor.deviceUID): \(error)")
            teardown()
            setState(.error)
        }
    }

    private func setup(device dev: AudioObjectID) throws {
        let u = try AUHAL.make()
        unit = u
        try AUHAL.set(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(0), "EnableIO input")
        try AUHAL.set(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1), "EnableIO output")
        try AUHAL.set(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, dev, "CurrentDevice")
        let hw = try AUHAL.get(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
                               AudioStreamBasicDescription(), "hardware output format")
        let outChannels = max(hw.mChannelsPerFrame, 1)
        let rate = hw.mSampleRate > 0 ? hw.mSampleRate : (CA.nominalSampleRate(dev) ?? deviceRate)
        try AUHAL.set(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                      AUHAL.floatPlanar(rate: rate, channels: outChannels), "client output format")
        let maxSlice = (try? AUHAL.get(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       UInt32(0), "MaximumFramesPerSlice")) ?? 0
        let maxFrames = max(maxSlice, 4096)
        let ioFrames = CA.requestBufferFrameSize(dev, UInt32(cycle)) ?? 512

        // Producer: mix thread (cycle frames at device rate). Consumer: this unit (ioFrames at monitor rate).
        guard let buf = SourceBuffers(channels: deviceChannels, srcRate: deviceRate, dstRate: rate,
                                      producerFrames: UInt32(cycle), consumerFrames: ioFrames),
              let slot = sr_slot_create(MonitorParams.free) else {
            throw CAError(-1, "monitor buffer allocation")
        }
        self.slot = slot
        sr_slot_publish(slot, MonitorParams.create(monitor, deviceChannelCount: deviceChannels))

        let storage = UnsafeMutablePointer<Float>.allocate(capacity: deviceChannels * Int(maxFrames))
        storage.initialize(repeating: 0, count: deviceChannels * Int(maxFrames))
        let planes = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: deviceChannels)
        for c in 0..<deviceChannels { (planes + c).initialize(to: storage + c * Int(maxFrames)) }
        let ctx = UnsafeMutablePointer<MonitorIOContext>.allocate(capacity: 1)
        ctx.initialize(to: MonitorIOContext(ring: buf.ring, resampler: buf.resampler, slot: slot, planes: planes,
                                            storage: storage, channels: UInt32(deviceChannels), maxFrames: maxFrames))
        ioContext = ctx
        try AUHAL.set(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                      AURenderCallbackStruct(inputProc: monitorRenderCallback, inputProcRefCon: UnsafeMutableRawPointer(ctx)),
                      "SetRenderCallback")
        try caCheck(AudioUnitInitialize(u), "AudioUnitInitialize")
        buffers = buf
        try caCheck(AudioOutputUnitStart(u), "AudioOutputUnitStart")
        rateListener = CAListener(object: dev, selector: kAudioDevicePropertyNominalSampleRate, queue: env.queue) { [weak self] in
            Log.info("Monitor device rate changed; restarting monitor")
            self?.restart()
        }
        Log.info("Monitor \(monitor.displayName) started (\(rate) Hz, \(outChannels) ch)")
    }

    private func teardown() {
        rateListener?.remove()
        rateListener = nil
        if let u = unit {
            AUHAL.dispose(u)
            unit = nil
        }
        if let ctx = ioContext {
            ctx.pointee.storage.deallocate()
            ctx.pointee.planes.deallocate()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            ioContext = nil
        }
        if let s = slot {
            sr_slot_destroy(s)
            slot = nil
        }
        let had = buffers != nil
        buffers = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if had && !stopped { onChange() }
    }

    private func setState(_ s: SourceState) {
        let changed = s != state
        state = s
        if changed { onChange() }
    }
}

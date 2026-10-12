import CoreAudio
import Darwin
import Foundation
import SRCore
import SoundRouterKit

/// Audio graph of one enabled VirtualDevice: shm segment, RT mix thread, capture sources,
/// monitors and meters. All methods run on the control queue.
final class DeviceEngine {
    let id: UUID
    private(set) var device: VirtualDevice
    private(set) var cycle: Int
    private unowned let env: EngineEnvironment
    /// Called with commands derived from host (HAL client) control changes.
    private let onHostCommand: (ConfigCommand) -> Void

    private var shm = SRDeviceShm()
    private var shmOpen = false
    private var slot: OpaquePointer?
    private let meters: UnsafeMutablePointer<SRMeters>
    private var ctx: UnsafeMutablePointer<MixContext>?
    private var thread: pthread_t?
    private var captures: [UUID: CaptureSource] = [:]
    private var monitors: [UUID: MonitorOutput] = [:]
    private var lastHostSeq: UInt32 = 0
    private var lastRequestedRateBits: UInt64 = 0
    private var rebuildPending = false
    private(set) var lastError: String?
    private var loggedRealtime = false

    var running: Bool { thread != nil }

    init(device: VirtualDevice, cycle: Int, env: EngineEnvironment, onHostCommand: @escaping (ConfigCommand) -> Void) {
        id = device.id
        self.device = device
        self.cycle = cycle
        self.env = env
        self.onHostCommand = onHostCommand
        meters = MetersAlloc.allocate()
    }

    deinit {
        stop(unlink: false)
        MetersAlloc.free(meters)
    }

    // MARK: Lifecycle

    func start() {
        guard thread == nil else { return }
        lastError = nil
        let rc = sr_device_shm_open(&shm, device.uid.uppercased(), UInt32(device.outputChannelCount),
                                    device.sampleRate, device.hasPassThru)
        guard rc == 0, let header = shm.header else {
            lastError = "shm_open failed (\(String(cString: strerror(rc))))"
            Log.error("Device \(device.name): \(lastError!)")
            return
        }
        shmOpen = true
        lastHostSeq = ShmField.load32(header, ShmField.hostControlSeq)
        lastRequestedRateBits = ShmField.load64(header, ShmField.requestedSampleRateBits)
        mirrorVolume()

        guard let s = sr_slot_create(RenderState.free) else {
            lastError = "slot allocation failed"
            return
        }
        slot = s
        sr_meters_reset(meters)

        syncCaptures()
        syncMonitors()
        publishRenderState()

        let c = MixContext.allocate(header: header, slot: s, meters: meters, cycle: cycle,
                                    channels: device.outputChannelCount, sampleRate: device.sampleRate)
        ctx = c
        guard let t = MixThread.start(c) else {
            lastError = "could not start mix thread"
            Log.error("Device \(device.name): \(lastError!)")
            return
        }
        thread = t
        loggedRealtime = false
        Log.info("Device \(device.name) [\(device.uid)] running: \(device.outputChannelCount) ch @ \(device.sampleRate) Hz, cycle \(cycle)")
    }

    /// Stops the mixer, sources and monitors. `unlink` removes the shm segment (device deleted
    /// or disabled); on engine shutdown it is kept so the driver keeps serving silence.
    func stop(unlink: Bool) {
        if let t = thread, let c = ctx { MixThread.stop(c, thread: t) }
        thread = nil
        for c in captures.values { c.stop() }
        captures.removeAll()
        for m in monitors.values { m.stop() }
        monitors.removeAll()
        if let s = slot {
            sr_slot_destroy(s)   // mix thread joined: frees current + retired states
            slot = nil
        }
        if let c = ctx {
            MixContext.free(c)
            ctx = nil
        }
        if shmOpen {
            sr_device_shm_close(&shm)
            shmOpen = false
        }
        if unlink { sr_device_shm_unlink(device.uid.uppercased()) }
    }

    /// Needs a full restart (new shm geometry / cycle)?
    static func needsRestart(old: VirtualDevice, new: VirtualDevice, oldCycle: Int, newCycle: Int) -> Bool {
        old.outputChannelCount != new.outputChannelCount || old.sampleRate != new.sampleRate
            || old.hasPassThru != new.hasPassThru || oldCycle != newCycle
    }

    /// Applies a new config for this device. Gain/route/volume changes are hot.
    func update(device new: VirtualDevice, cycle newCycle: Int) {
        if DeviceEngine.needsRestart(old: device, new: new, oldCycle: cycle, newCycle: newCycle) {
            Log.info("Device \(new.name): geometry changed, restarting mixer")
            stop(unlink: false)
            device = new
            cycle = newCycle
            start()
            return
        }
        device = new
        mirrorVolume()
        guard running else { start(); return }
        syncCaptures()
        syncMonitors()
        publishRenderState()
    }

    // MARK: Graph sync

    private func syncCaptures() {
        var wanted: [UUID: Source] = [:]
        for s in device.sources.prefix(Int(SR_MAX_SOURCES)) where s.enabled && s.kind != .passThru {
            wanted[s.id] = s
        }
        for (sid, cap) in captures {
            guard let s = wanted[sid] else {
                cap.stop()
                captures[sid] = nil
                continue
            }
            if !DeviceEngine.sameCapture(cap.config, s) {
                cap.stop()
                captures[sid] = nil
            }
        }
        for (sid, s) in wanted where captures[sid] == nil {
            let onChange: () -> Void = { [weak self] in self?.schedulePublish() }
            let cap: CaptureSource
            switch s.kind {
            case .application:
                cap = ApplicationCapture(source: s, deviceRate: device.sampleRate, cycle: cycle, env: env, onChange: onChange)
            case .inputDevice:
                cap = InputCapture(source: s, deviceRate: device.sampleRate, cycle: cycle, env: env, onChange: onChange)
            case .passThru:
                continue
            }
            captures[sid] = cap
            cap.start()
        }
    }

    /// Capture needs to be recreated when anything but volume/mute/displayName changed.
    private static func sameCapture(_ a: Source, _ b: Source) -> Bool {
        a.kind == b.kind && a.channelCount == b.channelCount && a.application == b.application
            && a.inputDevice == b.inputDevice && a.enabled == b.enabled
    }

    private func syncMonitors() {
        var wanted: [UUID: Monitor] = [:]
        for m in device.monitors where m.enabled { wanted[m.id] = m }
        for (mid, mon) in monitors {
            guard let m = wanted[mid], m.deviceUID == mon.monitor.deviceUID else {
                mon.stop()
                monitors[mid] = nil
                continue
            }
            if m != mon.monitor { mon.update(m) }
        }
        for (mid, m) in wanted where monitors[mid] == nil {
            let mon = MonitorOutput(monitor: m, deviceChannels: device.outputChannelCount, deviceRate: device.sampleRate,
                                    cycle: cycle, env: env) { [weak self] in self?.schedulePublish() }
            monitors[mid] = mon
            mon.start()
        }
    }

    /// Coalesces state-change notifications from sources/monitors into one publish.
    private func schedulePublish() {
        guard !rebuildPending else { return }
        rebuildPending = true
        env.queue.async { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            if self.running { self.publishRenderState() }
        }
    }

    /// Builds a new RenderState from the current device config + live source buffers and
    /// publishes it (atomic pointer swap; the previous one is retired by SRPlanSlot).
    private func publishRenderState() {
        guard let slot else { return }
        let srcs = Array(device.sources.prefix(Int(SR_MAX_SOURCES)))
        if device.sources.count > srcs.count {
            Log.warning("Device \(device.name): only the first \(SR_MAX_SOURCES) sources are mixed")
        }
        var specs: [RenderSourceSpec] = []
        var index: [UUID: Int] = [:]
        for (i, s) in srcs.enumerated() {
            index[s.id] = i
            var spec = RenderSourceSpec(kind: .silent, channels: max(1, s.channelCount), volume: s.volume,
                                        muted: s.muted, buffers: nil)
            if s.enabled {
                switch s.kind {
                case .passThru:
                    spec.kind = .passThru
                    spec.channels = device.outputChannelCount
                case .application, .inputDevice:
                    if let cap = captures[s.id], cap.state == .active, let b = cap.buffers, b.channels == spec.channels {
                        spec.kind = .ring
                        spec.buffers = b
                    }
                }
            }
            specs.append(spec)
        }
        var routes: [SRRoute] = []
        let sourcesByID = Dictionary(device.sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in device.routes {
            guard let si = index[r.sourceID], r.sourceChannel >= 0, r.sourceChannel < specs[si].channels,
                  r.outputChannel >= 0, r.outputChannel < device.outputChannelCount else { continue }
            // Per-channel volume/mute is folded into the route gain: hot-swapped with the plan.
            let channelGain = sourcesByID[r.sourceID]?.channelGain(r.sourceChannel) ?? 1
            routes.append(SRRoute(sourceIndex: UInt32(si), sourceChannel: UInt32(r.sourceChannel),
                                  outputChannel: UInt32(r.outputChannel), gain: r.gain * channelGain))
        }
        let monitorBuffers = device.monitors.compactMap { m -> SourceBuffers? in
            guard let mon = monitors[m.id], mon.state == .active else { return nil }
            return mon.buffers
        }
        guard let st = RenderState.create(outputChannels: device.outputChannelCount, volume: device.volume,
                                          muted: device.muted, sources: specs, routes: routes,
                                          monitors: monitorBuffers, cycleFrames: cycle) else {
            Log.error("Device \(device.name): could not allocate render state")
            return
        }
        sr_slot_publish(slot, UnsafeMutableRawPointer(st))
    }

    private func mirrorVolume() {
        guard shmOpen, let h = shm.header else { return }
        ShmField.store32(h, ShmField.volumeBits, sr_float_to_bits(device.volume))
        ShmField.store32(h, ShmField.muted, device.muted ? 1 : 0)
    }

    // MARK: Periodic work (~10 Hz)

    func poll() {
        if let slot { sr_slot_collect(slot) }
        for m in monitors.values { m.collect() }
        for c in captures.values { c.poll() }
        if let c = ctx, running, !loggedRealtime, c.pointee.realtimeStatus != MixContext.realtimePending {
            loggedRealtime = true
            if c.pointee.realtimeStatus != 0 {
                Log.warning("Device \(device.name): could not promote mix thread to real-time (\(c.pointee.realtimeStatus))")
            }
        }
        guard shmOpen, let h = shm.header else { return }
        let seq = ShmField.load32(h, ShmField.hostControlSeq)
        if seq != lastHostSeq {
            lastHostSeq = seq
            let vol = sr_bits_to_float(ShmField.load32(h, ShmField.hostVolumeBits))
            let muted = ShmField.load32(h, ShmField.hostMuted) != 0
            if vol.isFinite, vol != device.volume || muted != device.muted {
                Log.debug("Device \(device.name): host control volume=\(vol) muted=\(muted)")
                onHostCommand(.setDeviceVolume(id: id, volume: min(max(vol, 0), 1), muted: muted))
            }
        }
        let rateBits = ShmField.load64(h, ShmField.requestedSampleRateBits)
        if rateBits != lastRequestedRateBits {
            lastRequestedRateBits = rateBits
            let rate = sr_bits_to_double(rateBits)
            if rateBits != 0, rate != device.sampleRate, supportedSampleRates.contains(rate) {
                Log.info("Device \(device.name): host requested sample rate \(rate)")
                onHostCommand(.setDeviceSampleRate(id: id, sampleRate: rate))
            }
        }
    }

    func handle(_ event: HardwareEvent) {
        for c in captures.values { c.handle(event) }
        for m in monitors.values { m.handle(event) }
        if case .didWake = event, let c = ctx { c.pointee.resyncRequested = 1 }
    }

    // MARK: Status / meters

    func status() -> DeviceStatus {
        var srcStatus: [SourceStatus] = []
        var underruns: UInt64 = 0
        if shmOpen, let h = shm.header { underruns &+= ShmField.load64(h, ShmField.underrunCount) }
        for s in device.sources {
            if !s.enabled {
                srcStatus.append(SourceStatus(id: s.id, state: .disabled))
            } else if s.kind == .passThru {
                srcStatus.append(SourceStatus(id: s.id, state: running ? .active : .error, message: running ? nil : lastError))
            } else if let c = captures[s.id] {
                srcStatus.append(SourceStatus(id: s.id, state: c.state, message: c.message))
                underruns &+= c.buffers?.underruns ?? 0
            } else {
                srcStatus.append(SourceStatus(id: s.id, state: .error, message: lastError ?? "not started"))
            }
        }
        let monStatus = device.monitors.map { m -> MonitorStatus in
            if !m.enabled { return MonitorStatus(id: m.id, state: .disabled) }
            return MonitorStatus(id: m.id, state: monitors[m.id]?.state ?? .error)
        }
        return DeviceStatus(id: id, visibleInSystem: CA.device(forUID: device.uid) != nil, running: running,
                            sources: srcStatus, monitors: monStatus, underruns: underruns)
    }

    func meterSnapshot() -> MeterSnapshot {
        var sources: [UUID: [Float]] = [:]
        for (i, s) in device.sources.prefix(Int(SR_MAX_SOURCES)).enumerated() {
            let ch = s.kind == .passThru ? device.outputChannelCount : s.channelCount
            sources[s.id] = (0..<min(Int(SR_MAX_CHANNELS), max(ch, 0))).map { sr_meters_take_source(meters, UInt32(i), UInt32($0)) }
        }
        let outputs = (0..<device.outputChannelCount).map { sr_meters_take_output(meters, UInt32($0)) }
        return MeterSnapshot(deviceID: id, sources: sources, outputs: outputs)
    }

    /// Selftest hook.
    var diagnostics: (heartbeat: UInt64, mixWriteFrame: Int64, cycles: UInt64, realtime: Int32)? {
        guard shmOpen, let h = shm.header, let c = ctx else { return nil }
        return (ShmField.load64(h, ShmField.engineHeartbeat),
                Int64(bitPattern: ShmField.load64(h, ShmField.mixWriteFrame)),
                c.pointee.cyclesRendered, c.pointee.realtimeStatus)
    }
}

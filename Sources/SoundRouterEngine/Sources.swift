import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import SRCore
import SoundRouterKit

/// Services shared by all device engines. Every method is called on `queue`.
protocol EngineEnvironment: AnyObject {
    var queue: DispatchQueue { get }
    /// TCC Audio Capture result observed by a tap attempt.
    func reportAudioCapture(_ state: PermissionState)
    var audioCapturePermission: PermissionState { get }
}

enum HardwareEvent {
    case processListChanged
    case devicesChanged
    case defaultOutputChanged     // device or its nominal rate
    case didWake
}

/// A capture source feeding a SourceBuffers ring (application tap or input device).
protocol CaptureSource: AnyObject {
    var id: UUID { get }
    var config: Source { get }
    var state: SourceState { get }
    var message: String? { get }
    /// Non-nil while the producer is running.
    var buffers: SourceBuffers? { get }
    func start()
    func stop()
    func handle(_ event: HardwareEvent)
    /// ~10 Hz on the control queue.
    func poll()
}

// MARK: - Application source (process tap, macOS 14.2+)

/// Context read by the tap IOProc (RT). Allocated/freed on the control queue, only after
/// the IOProc has been stopped and destroyed.
struct TapIOContext {
    var ring: OpaquePointer
    var planes: UnsafeMutablePointer<UnsafePointer<Float>?>   // capacity 64
    var sawSignal: UInt32                                      // RT -> control: non-zero sample seen
    var callbacks: UInt64
}

final class ApplicationCapture: CaptureSource {
    let id: UUID
    let config: Source
    private let app: ApplicationSource
    private let deviceRate: Double
    private let cycle: Int
    private unowned let env: EngineEnvironment
    private let onChange: () -> Void

    private(set) var state: SourceState = .waiting
    private(set) var message: String?
    private(set) var buffers: SourceBuffers?

    private var processes: [AudioObjectID] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var ioContext: UnsafeMutablePointer<TapIOContext>?
    private var runningOutputSince: Date?
    private var lastSilentRetry: Date?
    private var stopped = true

    init(source: Source, deviceRate: Double, cycle: Int, env: EngineEnvironment, onChange: @escaping () -> Void) {
        id = source.id
        config = source
        app = source.application ?? ApplicationSource()
        self.deviceRate = deviceRate
        self.cycle = cycle
        self.env = env
        self.onChange = onChange
    }

    deinit { teardown() }

    func start() {
        stopped = false
        attach(force: true)
    }

    func stop() {
        stopped = true
        teardown()
        processes = []
        setState(.waiting, nil, notify: false)
    }

    func handle(_ event: HardwareEvent) {
        guard !stopped else { return }
        switch event {
        case .processListChanged: attach(force: false)
        case .defaultOutputChanged, .didWake: attach(force: true)
        case .devicesChanged: break
        }
    }

    func poll() {
        guard !stopped, let ctx = ioContext else { return }
        if ctx.pointee.sawSignal != 0 {
            runningOutputSince = nil
            if env.audioCapturePermission != .granted { env.reportAudioCapture(.granted) }
            if message != nil { message = nil }
            return
        }
        // Heuristic for a silently refused TCC permission: the target is producing output
        // but the tap only ever delivers exact zeros.
        let producing = processes.contains { CA.processIsRunningOutput($0) }
        if !producing { runningOutputSince = nil; return }
        let since = runningOutputSince ?? Date()
        runningOutputSince = since
        if Date().timeIntervalSince(since) > 5, env.audioCapturePermission != .granted {
            message = "No audio received while the application is playing — check System Settings › Privacy & Security › Screen & System Audio Recording"
            env.reportAudioCapture(.denied)
            // A tap created while TCC refused stays silent forever: recreate it periodically
            // so granting the permission in System Settings takes effect without a restart.
            if Date().timeIntervalSince(lastSilentRetry ?? .distantPast) > 10 {
                lastSilentRetry = Date()
                runningOutputSince = nil
                attach(force: true)
            }
        }
    }

    // MARK: private

    private func resolveProcesses() -> [AudioObjectID] {
        let all = CA.processObjects()
        if let bundle = app.bundleID, !bundle.isEmpty {
            let prefix = bundle + "."
            return all.filter { p in
                guard let b = CA.processBundleID(p) else { return false }
                return b == bundle || b.hasPrefix(prefix)
            }.sorted()
        }
        if let pid = app.pid, let p = CA.processObject(forPID: pid) {
            if let path = app.executablePath, let actual = CA.executablePath(pid: pid), actual != path {
                // pid was recycled by another program; fall through to path matching.
            } else {
                return [p]
            }
        }
        if let path = app.executablePath, !path.isEmpty {
            return all.filter { p in
                guard let pid = CA.processPID(p) else { return false }
                return CA.executablePath(pid: pid) == path
            }.sorted()
        }
        return []
    }

    private func attach(force: Bool) {
        let procs = resolveProcesses()
        if !force && procs == processes && (ioProcID != nil || procs.isEmpty) { return }
        teardown()
        processes = procs
        guard !procs.isEmpty else {
            setState(.waiting, "Application not running")
            return
        }
        do {
            try createTap()
            setState(.active, nil)
        } catch let e as CAError {
            teardown()
            let permission = e.status == kAudioHardwareIllegalOperationError || e.status == kAudioDevicePermissionsError
                || e.status == OSStatus(bitPattern: 0x6E6F7065) // 'nope'
            if permission {
                env.reportAudioCapture(.denied)
                setState(.permissionDenied, "Audio capture permission denied (\(e))")
            } else {
                setState(.error, e.description)
            }
            Log.error("Tap for \(app.bundleID ?? app.executablePath ?? "?"): \(e)")
        } catch {
            teardown()
            setState(.error, "\(error)")
        }
    }

    private func createTap() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.name = "SoundRouter \(config.displayName)"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = app.muteWhenCapturing ? .mutedWhenTapped : .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        var fmt = AudioStreamBasicDescription()
        var addr = CA.address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try caCheck(AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt), "kAudioTapPropertyFormat")
        guard fmt.mFormatID == kAudioFormatLinearPCM, fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              fmt.mBitsPerChannel == 32, fmt.mSampleRate > 0, fmt.mChannelsPerFrame > 0 else {
            throw CAError(-1, "Unsupported tap format \(fmt)")
        }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundRouter Tap \(id.uuidString.prefix(8))",
            kAudioAggregateDeviceUIDKey: "io.soundrouter.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "AudioHardwareCreateAggregateDevice")
        aggregateID = agg

        let producer = CA.requestBufferFrameSize(agg, UInt32(cycle)) ?? 512
        guard let buf = SourceBuffers(channels: config.channelCount, srcRate: fmt.mSampleRate, dstRate: deviceRate,
                                      producerFrames: producer, consumerFrames: UInt32(cycle)) else {
            throw CAError(-1, "ring allocation")
        }
        let planes = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: Int(SR_MAX_CHANNELS))
        planes.initialize(repeating: nil, count: Int(SR_MAX_CHANNELS))
        let ctx = UnsafeMutablePointer<TapIOContext>.allocate(capacity: 1)
        ctx.initialize(to: TapIOContext(ring: buf.ring, planes: planes, sawSignal: 0, callbacks: 0))
        ioContext = ctx

        // RT block: captures only a raw pointer. No allocation / ARC / locks inside.
        let block: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            ApplicationCapture.ioBlock(ctx, inInputData)
        }
        var procID: AudioDeviceIOProcID?
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil, block), "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        buffers = buf
        try caCheck(AudioDeviceStart(agg, procID), "AudioDeviceStart")
        Log.info("Tap started for \(config.displayName) (\(processes.count) process(es), \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch)")
    }

    /// [RT]
    @inline(__always)
    static func ioBlock(_ ctx: UnsafeMutablePointer<TapIOContext>, _ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let count = abl.count
        guard count > 0 else { return }
        ctx.pointee.callbacks &+= 1
        let first = abl[0]
        guard let data0 = first.mData else { return }
        let ring = ctx.pointee.ring
        if count == 1 {
            let chans = max(first.mNumberChannels, 1)
            let frames = first.mDataByteSize / (4 * chans)
            let samples = data0.assumingMemoryBound(to: Float.self)
            if ctx.pointee.sawSignal == 0 {
                var k = 0
                let total = Int(frames * chans)
                while k < total { if samples[k] != 0 { ctx.pointee.sawSignal = 1; break }; k += 1 }
            }
            _ = sr_ring_write_interleaved(ring, samples, chans, frames)
        } else {
            let n = min(count, Int(SR_MAX_CHANNELS))
            let frames = first.mDataByteSize / 4
            var c = 0
            while c < n {
                ctx.pointee.planes[c] = UnsafePointer(abl[c].mData?.assumingMemoryBound(to: Float.self))
                c += 1
            }
            if ctx.pointee.sawSignal == 0, let p = ctx.pointee.planes[0] {
                var k = 0
                while k < Int(frames) { if p[k] != 0 { ctx.pointee.sawSignal = 1; break }; k += 1 }
            }
            // Ring channel count is 2 (application sources); extra planes are ignored by index.
            _ = sr_ring_write(ring, ctx.pointee.planes, frames)
        }
    }

    /// Teardown order (spec): stop IOProc, destroy IOProc, destroy aggregate, destroy tap.
    private func teardown() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let ctx = ioContext {
            ctx.pointee.planes.deallocate()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            ioContext = nil
        }
        runningOutputSince = nil
        let hadBuffers = buffers != nil
        buffers = nil   // RenderState(s) still referencing it keep it alive until retired
        if hadBuffers && !stopped { onChange() }
    }

    private func setState(_ s: SourceState, _ msg: String?, notify: Bool = true) {
        let changed = s != state || msg != message
        state = s
        message = msg
        if changed && notify { onChange() }
    }
}

// MARK: - Input device source (AUHAL input)

struct InputIOContext {
    var unit: AudioUnit
    var abl: UnsafeMutablePointer<AudioBufferList>
    var planes: UnsafeMutablePointer<UnsafePointer<Float>?>
    var storage: UnsafeMutablePointer<Float>
    var channels: UInt32
    var maxFrames: UInt32
    var ring: OpaquePointer
}

/// [RT] AUHAL input callback.
private let inputRenderCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    let c = refCon.assumingMemoryBound(to: InputIOContext.self)
    let maxFrames = c.pointee.maxFrames
    guard frames <= maxFrames else { return kAudio_ParamError }
    let abl = UnsafeMutableAudioBufferListPointer(c.pointee.abl)
    let n = Int(c.pointee.channels)
    var i = 0
    while i < n {
        abl[i].mNumberChannels = 1
        abl[i].mDataByteSize = frames * 4
        abl[i].mData = UnsafeMutableRawPointer(c.pointee.storage + i * Int(maxFrames))
        i += 1
    }
    let st = AudioUnitRender(c.pointee.unit, flags, timeStamp, bus, frames, c.pointee.abl)
    if st == noErr {
        _ = sr_ring_write(c.pointee.ring, c.pointee.planes, frames)
    }
    return st
}

final class InputCapture: CaptureSource {
    let id: UUID
    let config: Source
    private let input: InputDeviceSource
    private let deviceRate: Double
    private let cycle: Int
    private unowned let env: EngineEnvironment
    private let onChange: () -> Void

    private(set) var state: SourceState = .disconnected
    private(set) var message: String?
    private(set) var buffers: SourceBuffers?

    private var unit: AudioUnit?
    private var ioContext: UnsafeMutablePointer<InputIOContext>?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var rateListener: CAListener?
    private var stopped = true
    private var requestingAccess = false

    init(source: Source, deviceRate: Double, cycle: Int, env: EngineEnvironment, onChange: @escaping () -> Void) {
        id = source.id
        config = source
        input = source.inputDevice ?? InputDeviceSource(deviceUID: "", channels: [])
        self.deviceRate = deviceRate
        self.cycle = cycle
        self.env = env
        self.onChange = onChange
    }

    deinit { teardown() }

    func start() {
        stopped = false
        attach()
    }

    func stop() {
        stopped = true
        teardown()
    }

    func handle(_ event: HardwareEvent) {
        guard !stopped else { return }
        switch event {
        case .devicesChanged:
            let dev = CA.device(forUID: input.deviceUID)
            if dev != deviceID || unit == nil { restart() }
        case .didWake: if unit == nil { attach() }
        case .processListChanged, .defaultOutputChanged: break
        }
    }

    func poll() {
        // Permission granted later in System Settings: attach without needing a restart.
        if state == .permissionDenied, unit == nil, !requestingAccess, !stopped,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            attach()
        }
    }

    private func restart() {
        teardown()
        attach()
    }

    private func attach() {
        guard !stopped, unit == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            setState(.permissionDenied, "Waiting for microphone permission")
            if !requestingAccess {
                requestingAccess = true
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    guard let self else { return }
                    self.env.queue.async {
                        self.requestingAccess = false
                        self.attach()
                    }
                }
            }
            return
        default:
            setState(.permissionDenied, "Microphone permission denied")
            return
        }
        guard let dev = CA.device(forUID: input.deviceUID) else {
            setState(.disconnected, "Input device not connected")
            return
        }
        deviceID = dev
        do {
            try setupUnit(device: dev)
            setState(.active, nil)
        } catch {
            teardown()
            setState(.error, "\(error)")
            Log.error("Input \(input.deviceUID): \(error)")
        }
    }

    private func setupUnit(device dev: AudioObjectID) throws {
        let u = try AUHAL.make()
        unit = u
        try AUHAL.set(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "EnableIO input")
        try AUHAL.set(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "EnableIO output")
        try AUHAL.set(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, dev, "CurrentDevice")
        let hw = try AUHAL.get(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                               AudioStreamBasicDescription(), "hardware input format")
        let hwChannels = Int(hw.mChannelsPerFrame)
        let chans = input.channels
        guard !chans.isEmpty, hwChannels > 0 else { throw CAError(-1, "device has no input channels") }
        if let bad = chans.first(where: { $0 < 0 || $0 >= hwChannels }) {
            throw CAError(-1, "channel \(bad + 1) out of range (device has \(hwChannels) inputs)")
        }
        let rate = hw.mSampleRate > 0 ? hw.mSampleRate : (CA.nominalSampleRate(dev) ?? deviceRate)
        let map: [Int32] = chans.map { Int32($0) }
        try map.withUnsafeBufferPointer { p in
            try caCheck(AudioUnitSetProperty(u, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                             p.baseAddress, UInt32(p.count * 4)), "ChannelMap")
        }
        try AUHAL.set(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                      AUHAL.floatPlanar(rate: rate, channels: UInt32(chans.count)), "client input format")
        let maxSlice = (try? AUHAL.get(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       UInt32(0), "MaximumFramesPerSlice")) ?? 0
        let maxFrames = max(maxSlice, 4096)

        let producer = CA.requestBufferFrameSize(dev, UInt32(cycle)) ?? 512
        guard let buf = SourceBuffers(channels: chans.count, srcRate: rate, dstRate: deviceRate,
                                      producerFrames: producer, consumerFrames: UInt32(cycle)) else {
            throw CAError(-1, "ring allocation")
        }
        let abl = AudioBufferList.allocate(maximumBuffers: chans.count)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: chans.count * Int(maxFrames))
        storage.initialize(repeating: 0, count: chans.count * Int(maxFrames))
        let planes = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: chans.count)
        for c in 0..<chans.count {
            (planes + c).initialize(to: UnsafePointer(storage + c * Int(maxFrames)))
            abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maxFrames * 4,
                                 mData: UnsafeMutableRawPointer(storage + c * Int(maxFrames)))
        }
        let ctx = UnsafeMutablePointer<InputIOContext>.allocate(capacity: 1)
        ctx.initialize(to: InputIOContext(unit: u, abl: abl.unsafeMutablePointer, planes: planes, storage: storage,
                                          channels: UInt32(chans.count), maxFrames: maxFrames, ring: buf.ring))
        ioContext = ctx
        try AUHAL.set(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                      AURenderCallbackStruct(inputProc: inputRenderCallback, inputProcRefCon: UnsafeMutableRawPointer(ctx)),
                      "SetInputCallback")
        try caCheck(AudioUnitInitialize(u), "AudioUnitInitialize")
        buffers = buf
        try caCheck(AudioOutputUnitStart(u), "AudioOutputUnitStart")
        rateListener = CAListener(object: dev, selector: kAudioDevicePropertyNominalSampleRate, queue: env.queue) { [weak self] in
            Log.info("Input device rate changed; restarting source")
            self?.restart()
        }
        Log.info("Input \(config.displayName) started (\(rate) Hz, channels \(chans))")
    }

    private func teardown() {
        rateListener?.remove()
        rateListener = nil
        if let u = unit {
            AUHAL.dispose(u)   // synchronous stop: callback no longer runs afterwards
            unit = nil
        }
        if let ctx = ioContext {
            free(ctx.pointee.abl)  // AudioBufferList.allocate uses malloc
            ctx.pointee.storage.deallocate()
            ctx.pointee.planes.deallocate()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
            ioContext = nil
        }
        let had = buffers != nil
        buffers = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if had && !stopped { onChange() }
    }

    private func setState(_ s: SourceState, _ msg: String?) {
        let changed = s != state || msg != message
        state = s
        message = msg
        if changed { onChange() }
    }
}

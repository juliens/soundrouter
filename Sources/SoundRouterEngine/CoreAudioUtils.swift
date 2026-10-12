import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// Non-real-time Core Audio helpers (control queue only).

struct CAError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    init(_ status: OSStatus, _ what: String) {
        self.status = status
        self.what = what
    }
    var description: String { "\(what) failed (\(CA.fourCC(status)))" }
}

@inline(__always)
func caCheck(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw CAError(status, what()) }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Renders an OSStatus as a four-char code when printable.
    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "' \(status)"
        }
        return "\(status)"
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return st == noErr ? value : nil
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         zero: T) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let st = items.withUnsafeMutableBytes { buf in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!)
        }
        guard st == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref)
        guard st == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    // MARK: Devices

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let d = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
              d != kAudioObjectUnknown else { return nil }
        return d
    }

    /// kAudioHardwarePropertyTranslateUIDToDevice; nil when no device has this UID.
    static func device(forUID uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier: CFString = uid as CFString
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &qualifier) { q in
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<CFString>.size), q, &size, &dev)
        }
        guard st == noErr, dev != kAudioObjectUnknown else { return nil }
        if let alive = scalar(dev, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)), alive == 0 { return nil }
        return dev
    }

    static func deviceUID(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }

    static func nominalSampleRate(_ dev: AudioObjectID) -> Double? {
        scalar(dev, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func bufferFrameSize(_ dev: AudioObjectID) -> UInt32? {
        scalar(dev, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Requests an IO buffer of `frames` for this process on `dev` (clamped to the device's
    /// supported range) and returns the size actually in effect. The HAL's default (512) is
    /// the main contributor to monitoring latency; matching it to the mix cycle removes most of it.
    @discardableResult
    static func requestBufferFrameSize(_ dev: AudioObjectID, _ frames: UInt32) -> UInt32? {
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var wanted = Double(frames)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &range) == noErr, range.mMaximum > 0 {
            wanted = min(max(wanted, range.mMinimum), range.mMaximum)
        }
        var value = UInt32(wanted)
        addr.mSelector = kAudioDevicePropertyBufferFrameSize
        let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if st != noErr { Log.warning("Could not set IO buffer size \(value) on device \(dev): \(st)") }
        return bufferFrameSize(dev)
    }

    /// Nominal rate of the default output device, snapped to a supported rate (fallback 48 kHz).
    static func defaultOutputSampleRate(supported: [Double]) -> Double {
        if let d = defaultOutputDevice(), let r = nominalSampleRate(d), supported.contains(r) { return r }
        return 48_000
    }

    // MARK: Processes (macOS 14.2+)

    static func processObjects() -> [AudioObjectID] {
        array(system, kAudioHardwarePropertyProcessObjectList, zero: AudioObjectID(0))
    }

    static func processBundleID(_ p: AudioObjectID) -> String? {
        string(p, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func processPID(_ p: AudioObjectID) -> pid_t? {
        scalar(p, kAudioProcessPropertyPID, initial: pid_t(-1)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func processIsRunningOutput(_ p: AudioObjectID) -> Bool {
        (scalar(p, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &obj)
        guard st == noErr, obj != kAudioObjectUnknown else { return nil }
        return obj
    }

    static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}

/// Owns one AudioObjectAddPropertyListenerBlock registration; removed on `remove()`/deinit.
final class CAListener {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          queue: DispatchQueue, handler: @escaping () -> Void) {
        self.object = object
        self.addr = CA.address(selector, scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        let st = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        if st != noErr {
            Log.warning("AudioObjectAddPropertyListenerBlock(\(selector)) on \(object): \(CA.fourCC(st))")
            return nil
        }
        active = true
    }

    func remove() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
    }

    deinit { remove() }
}

/// Helpers for AUHAL units.
enum AUHAL {
    static func make() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CAError(-1, "AudioComponentFindNext(HALOutput)") }
        var unit: AudioUnit?
        try caCheck(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        guard let u = unit else { throw CAError(-1, "AudioComponentInstanceNew") }
        return u
    }

    static func set<T>(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope,
                       _ element: AudioUnitElement, _ value: T, _ what: String) throws {
        var v = value
        try withUnsafePointer(to: &v) {
            try caCheck(AudioUnitSetProperty(unit, prop, scope, element, $0, UInt32(MemoryLayout<T>.size)), what)
        }
    }

    static func get<T>(_ unit: AudioUnit, _ prop: AudioUnitPropertyID, _ scope: AudioUnitScope,
                       _ element: AudioUnitElement, _ initial: T, _ what: String) throws -> T {
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &v) {
            try caCheck(AudioUnitGetProperty(unit, prop, scope, element, $0, &size), what)
        }
        return v
    }

    static func floatPlanar(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    static func dispose(_ unit: AudioUnit) {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}

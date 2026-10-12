// Shared Core Audio helpers for the integration tools.
// Tools are compiled together with this file, e.g.:
//   swiftc -O IntegrationTests/Tools/CoreAudioUtil.swift IntegrationTests/Tools/list_devices.swift -o build/list_devices
// (IntegrationTests/run_tool.sh does this and caches the binary.)

import CoreAudio
import Foundation

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func allDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func uid(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }
    static func name(_ dev: AudioObjectID) -> String? { string(dev, kAudioObjectPropertyName) }

    static func device(uid: String) -> AudioObjectID? {
        allDevices().first { self.uid($0) == uid }
    }

    /// Total channels for input (`kAudioObjectPropertyScopeInput`) or output scope.
    static func channelCount(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalRate(_ dev: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        return rate
    }

    @discardableResult
    static func setNominalRate(_ dev: AudioObjectID, _ rate: Double) -> OSStatus {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var r: Float64 = rate
        let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
        // Rate changes are asynchronous; wait until applied (max 2 s).
        for _ in 0..<40 where nominalRate(dev) != rate { usleep(50_000) }
        return st
    }

    static func availableRates(_ dev: AudioObjectID) -> [ClosedRange<Double>] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum...$0.mMaximum }
    }

    /// First device whose UID or name matches `key` (UID exact, name exact or contains).
    static func find(_ key: String) -> AudioObjectID? {
        let devs = allDevices()
        return devs.first { uid($0) == key } ?? devs.first { name($0) == key }
            ?? devs.first { name($0)?.contains(key) == true }
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
    exit(1)
}

/// Minimal "--flag value" parser.
struct Args {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ argv: [String] = Array(CommandLine.arguments.dropFirst())) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    values[String(a.dropFirst(2))] = argv[i + 1]
                    i += 2
                    continue
                }
                flags.insert(String(a.dropFirst(2)))
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ k: String) -> String? { values[k] }
    func double(_ k: String, _ d: Double) -> Double { values[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { values[k].flatMap(Int.init) ?? d }
    func has(_ k: String) -> Bool { flags.contains(k) || values[k] != nil }
}

/// Deterministic test signal: per-channel sine + LCG noise, quantized to 24-bit so it survives
/// any Float32 <-> Int24 path exactly. Values in [-0.5, 0.5).
struct TestSignal {
    let sampleRate: Double
    func sample(frame: Int, channel: Int) -> Float {
        let f = 440.0 * Double(channel + 1)
        let s = 0.3 * sin(2 * Double.pi * f * Double(frame) / sampleRate)
        var x = UInt64(truncatingIfNeeded: frame &* 2_654_435_761 &+ channel &* 97 &+ 12345)
        x = x &* 6364136223846793005 &+ 1442695040888963407
        let noise = Double(Int64(bitPattern: x >> 11) % 1_000_000) / 1_000_000 * 0.1
        let v = s + noise
        return Float((v * 8_388_608).rounded() / 8_388_608)
    }
}

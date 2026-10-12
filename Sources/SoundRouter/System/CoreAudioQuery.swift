import AppKit
import CoreAudio
import Darwin
import Foundation
import Observation

/// A Core Audio device as seen by the app (read-only queries, no audio I/O).
struct AudioDeviceInfo: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
}

/// A process known to Core Audio (macOS 14.2+ process objects).
struct AudioProcessInfo: Identifiable, Hashable {
    var id: AudioObjectID
    var pid: Int32
    var bundleID: String?
    var executablePath: String?
    var name: String
}

/// Thin wrappers over AudioObjectGetPropertyData. Queries only; never starts audio.
enum CoreAudioQuery {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? value : nil
    }

    static func channelCount(_ device: AudioObjectID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func devices() -> [AudioDeviceInfo] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return AudioDeviceInfo(id: id, uid: uid, name: name,
                                   inputChannels: channelCount(id, input: true),
                                   outputChannels: channelCount(id, input: false))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Processes registered with Core Audio (includes daemons without UI).
    static func processes() -> [AudioProcessInfo] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard let pid = scalar(obj, kAudioProcessPropertyPID, pid_t(0)), pid > 0 else { return nil }
            let bundleID = string(obj, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            let path = executablePath(pid: pid)
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? bundleID ?? "pid \(pid)"
            return AudioProcessInfo(id: obj, pid: pid, bundleID: bundleID, executablePath: path, name: name)
        }
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A running GUI application offered in the "+" source menu.
struct RunningAppEntry: Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var bundleID: String?
    var executablePath: String?
    var icon: NSImage?
}

/// Live lists used by the source and monitor menus (running apps, Core Audio devices, Option key).
@Observable
@MainActor
final class SourceCatalog {
    private(set) var runningApps: [RunningAppEntry] = []
    private(set) var audioDevices: [AudioDeviceInfo] = []
    private(set) var backgroundProcesses: [AudioProcessInfo] = []
    private(set) var optionKeyHeld = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        refreshApps()
        refreshDevices()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            })
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                guard let self, self.optionKeyHeld != held else { return }
                self.optionKeyHeld = held
                if held { self.refreshProcesses() }
            }
            return event
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        deviceListener = listener
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
    }

    func refreshApps() {
        let own = Bundle.main.bundleIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { ($0.activationPolicy == .regular || $0.activationPolicy == .accessory)
                && $0.bundleIdentifier != own && !$0.isTerminated }
            .map { app in
                let icon = app.icon.map { img -> NSImage in
                    let copy = img.copy() as? NSImage ?? img
                    copy.size = NSSize(width: 16, height: 16)
                    return copy
                }
                return RunningAppEntry(pid: app.processIdentifier,
                                       name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                                       bundleID: app.bundleIdentifier,
                                       executablePath: app.executableURL?.path, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshDevices() {
        audioDevices = CoreAudioQuery.devices()
    }

    /// Core Audio processes that are not regular/accessory apps (F14, best effort).
    func refreshProcesses() {
        let uiPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .map(\.processIdentifier))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        backgroundProcesses = CoreAudioQuery.processes()
            .filter { !uiPIDs.contains($0.pid) && $0.pid != ownPID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var inputDevices: [AudioDeviceInfo] { audioDevices.filter { $0.inputChannels > 0 } }
    var outputDevices: [AudioDeviceInfo] { audioDevices.filter { $0.outputChannels > 0 } }

    func device(uid: String) -> AudioDeviceInfo? { audioDevices.first { $0.uid == uid } }
}

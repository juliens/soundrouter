import AVFoundation
import AppKit
import CoreAudio
import Foundation
import SoundRouterKit

/// Owns the config store, the device engines and the hardware watchers.
/// Every stateful operation runs on `queue` (serial "control" queue).
final class EngineController: EngineEnvironment {
    let queue = DispatchQueue(label: "io.soundrouter.engine.control", qos: .userInitiated)
    let store: ConfigStore
    private var engines: [UUID: DeviceEngine] = [:]
    private(set) var audioCapturePermission: PermissionState = .unknown
    private var listeners: [CAListener] = []
    private var defaultOutputRateListener: CAListener?
    private var pollTimer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
    }

    static var engineVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    // MARK: Lifecycle

    /// Loads config, publishes devices.json, builds the graph and starts watchers.
    /// `hardware == false` (selftest) skips Core Audio listeners and workspace notifications.
    func start(hardware: Bool = true) {
        queue.sync {
            store.load()
            Log.level = store.config.settings.logLevel
            store.publishDevices()
            applyGraph()
            if hardware { startWatchers() }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            pollTimer = t
            started = true
        }
    }

    /// Stops every mixer without unlinking shm segments (the driver keeps serving silence).
    func shutdown() {
        queue.sync {
            pollTimer?.cancel()
            pollTimer = nil
            listeners.forEach { $0.remove() }
            listeners.removeAll()
            defaultOutputRateListener = nil
            for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
            workspaceObservers.removeAll()
            for e in engines.values { e.stop(unlink: false) }
            engines.removeAll()
            started = false
            Log.info("Engine stopped")
        }
    }

    // MARK: EngineEnvironment

    func reportAudioCapture(_ state: PermissionState) {
        if audioCapturePermission != state {
            Log.info("Audio capture permission: \(state.rawValue)")
            audioCapturePermission = state
        }
    }

    static var microphonePermission: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    // MARK: Commands (control queue)

    func perform(_ command: ConfigCommand) -> CommandResult {
        dispatchPrecondition(condition: .onQueue(queue))
        let defaultRate = CA.defaultOutputSampleRate(supported: supportedSampleRates)
        do {
            let created = try store.apply(command, defaultSampleRate: defaultRate)
            Log.level = store.config.settings.logLevel
            applyGraph()
            return CommandResult(ok: true, config: store.config, createdID: created)
        } catch {
            Log.info("Command rejected: \(error)")
            return CommandResult(ok: false, error: "\(error)", config: store.config)
        }
    }

    /// Diff-applies the config to the running engines.
    private func applyGraph() {
        let config = store.config
        let cycle = config.settings.cycleFrames
        var wanted: [UUID: VirtualDevice] = [:]
        for d in config.devices where d.enabled { wanted[d.id] = d }
        for (id, engine) in engines where wanted[id] == nil {
            Log.info("Device \(engine.device.name) removed/disabled")
            engine.stop(unlink: true)
            engines[id] = nil
        }
        for d in config.devices where d.enabled {
            if let e = engines[d.id] {
                if e.device != d || e.cycle != cycle { e.update(device: d, cycle: cycle) }
            } else {
                let e = DeviceEngine(device: d, cycle: cycle, env: self) { [weak self] cmd in
                    guard let self else { return }
                    // Host (HAL client) control change -> regular command path (persist + apply).
                    self.queue.async { _ = self.perform(cmd) }
                }
                engines[d.id] = e
                e.start()
            }
        }
    }

    private func poll() {
        for e in engines.values { e.poll() }
    }

    // MARK: Status / meters

    func status() -> EngineStatus {
        dispatchPrecondition(condition: .onQueue(queue))
        let devices = store.config.devices.map { d -> DeviceStatus in
            if let e = engines[d.id] { return e.status() }
            return DeviceStatus(id: d.id, visibleInSystem: CA.device(forUID: d.uid) != nil, running: false,
                                sources: d.sources.map { SourceStatus(id: $0.id, state: .disabled) },
                                monitors: d.monitors.map { MonitorStatus(id: $0.id, state: .disabled) },
                                underruns: 0)
        }
        return EngineStatus(engineVersion: EngineController.engineVersion,
                            driverInstalled: FileManager.default.fileExists(atPath: SRPaths.driverBundle.path),
                            audioCapturePermission: audioCapturePermission,
                            microphonePermission: EngineController.microphonePermission,
                            devices: devices)
    }

    func meters(deviceID: UUID) -> MeterSnapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        return engines[deviceID]?.meterSnapshot() ?? MeterSnapshot(deviceID: deviceID, sources: [:], outputs: [])
    }

    func engine(_ id: UUID) -> DeviceEngine? { engines[id] }

    // MARK: Hardware / system events

    private func broadcast(_ event: HardwareEvent) {
        for e in engines.values { e.handle(event) }
    }

    private func startWatchers() {
        let sys = CA.system
        if let l = CAListener(object: sys, selector: kAudioHardwarePropertyProcessObjectList, queue: queue, handler: { [weak self] in
            self?.broadcast(.processListChanged)
        }) { listeners.append(l) }
        if let l = CAListener(object: sys, selector: kAudioHardwarePropertyDevices, queue: queue, handler: { [weak self] in
            self?.broadcast(.devicesChanged)
        }) { listeners.append(l) }
        if let l = CAListener(object: sys, selector: kAudioHardwarePropertyDefaultOutputDevice, queue: queue, handler: { [weak self] in
            Log.info("Default output device changed; recreating taps")
            self?.watchDefaultOutputRate()
            self?.broadcast(.defaultOutputChanged)
        }) { listeners.append(l) }
        watchDefaultOutputRate()

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            Log.info("System will sleep")
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                Log.info("System did wake; resyncing")
                self.broadcast(.didWake)
            }
        })
    }

    private func watchDefaultOutputRate() {
        defaultOutputRateListener = nil
        guard let dev = CA.defaultOutputDevice() else { return }
        defaultOutputRateListener = CAListener(object: dev, selector: kAudioDevicePropertyNominalSampleRate, queue: queue) { [weak self] in
            Log.info("Default output sample rate changed; recreating taps")
            self?.broadcast(.defaultOutputChanged)
        }
    }
}

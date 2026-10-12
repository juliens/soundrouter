import AppKit
import Foundation
import SoundRouterKit

/// DEV/OFFLINE mode (SOUNDROUTER_OFFLINE=1): an in-process fake engine so the UI can be
/// exercised without the LaunchAgent. Config changes go through the shared ConfigReducer;
/// meters are synthesized. Nothing is persisted and no audio is touched.
final class OfflineEngineBackend: EngineBackend, @unchecked Sendable {
    var onConnectionLost: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var config: RouterConfig
    private let startTime = Date()

    init() {
        var cfg = ConfigReducer.defaultConfig()
        // Seed a demo device so the editor has something to show.
        if let created = try? ConfigReducer.apply(.createDevice(name: "Demo Device"), to: cfg,
                                                  defaultSampleRate: 48_000) {
            cfg = created.0
            if let id = created.1 {
                let chrome = Source.application(ApplicationSource(bundleID: "com.google.Chrome"),
                                                displayName: "Google Chrome")
                if let added = try? ConfigReducer.apply(.addSource(deviceID: id, source: chrome),
                                                        to: cfg, defaultSampleRate: 48_000) {
                    cfg = added.0
                }
                if let out = CoreAudioQuery.devices().first(where: { $0.outputChannels > 0 }) {
                    let monitor = Monitor(deviceUID: out.uid, displayName: out.name,
                                          routes: [MonitorRoute(deviceChannel: 0, monitorChannel: 0),
                                                   MonitorRoute(deviceChannel: 1, monitorChannel: 1)])
                    if let added = try? ConfigReducer.apply(.addMonitor(deviceID: id, monitor: monitor),
                                                            to: cfg, defaultSampleRate: 48_000) {
                        cfg = added.0
                    }
                }
            }
        }
        config = cfg
    }

    func reset() {}

    func hello() async throws -> Int { engineProtocolVersion }

    func getConfig() async throws -> RouterConfig {
        lock.withLock { config }
    }

    func perform(_ command: ConfigCommand) async throws -> CommandResult {
        lock.withLock {
            do {
                let (newConfig, created) = try ConfigReducer.apply(command, to: config, defaultSampleRate: 48_000)
                config = newConfig
                return CommandResult(ok: true, config: newConfig, createdID: created)
            } catch {
                return CommandResult(ok: false, error: String(describing: error), config: config)
            }
        }
    }

    func getStatus() async throws -> EngineStatus {
        let cfg = lock.withLock { config }
        let runningBundles = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let inputUIDs = Set(CoreAudioQuery.devices().map(\.uid))
        let devices = cfg.devices.map { device -> DeviceStatus in
            let sources = device.sources.map { src -> SourceStatus in
                if !src.enabled { return SourceStatus(id: src.id, state: .disabled) }
                switch src.kind {
                case .passThru:
                    return SourceStatus(id: src.id, state: .active)
                case .application:
                    if let b = src.application?.bundleID, !runningBundles.contains(b) {
                        return SourceStatus(id: src.id, state: .waiting, message: "Application not running")
                    }
                    return SourceStatus(id: src.id, state: .active)
                case .inputDevice:
                    if let uid = src.inputDevice?.deviceUID, !inputUIDs.contains(uid) {
                        return SourceStatus(id: src.id, state: .disconnected, message: "Device disconnected")
                    }
                    return SourceStatus(id: src.id, state: .active)
                }
            }
            let monitors = device.monitors.map {
                MonitorStatus(id: $0.id, state: !$0.enabled ? .disabled
                              : inputUIDs.contains($0.deviceUID) ? .active : .disconnected)
            }
            return DeviceStatus(id: device.id, visibleInSystem: device.enabled, running: device.enabled,
                                sources: sources, monitors: monitors, underruns: 0)
        }
        return EngineStatus(engineVersion: "offline", driverInstalled: true,
                            audioCapturePermission: .granted, microphonePermission: .granted,
                            devices: devices)
    }

    func getMeters(deviceID: UUID) async throws -> MeterSnapshot {
        let cfg = lock.withLock { config }
        guard let device = cfg.devices.first(where: { $0.id == deviceID }) else {
            return MeterSnapshot(deviceID: deviceID, sources: [:], outputs: [])
        }
        let t = Date().timeIntervalSince(startTime)
        var sourcePeaks: [UUID: [Float]] = [:]
        var outputs = [Float](repeating: 0, count: device.outputChannelCount)
        for (index, src) in device.sources.enumerated() {
            let active = src.enabled && !src.muted
            let channels = min(2, src.channelCount)
            var peaks: [Float] = []
            for ch in 0..<channels {
                let phase = t * (1.3 + Double(index) * 0.7) + Double(ch) * 0.9
                let envelope = 0.5 + 0.5 * sin(phase)
                let noise = Double.random(in: 0...0.25)
                peaks.append(active ? Float(min(1, envelope * 0.7 + noise)) * src.volume : 0)
            }
            sourcePeaks[src.id] = peaks
            for route in device.routes where route.sourceID == src.id && route.outputChannel < outputs.count {
                let p = route.sourceChannel < peaks.count ? peaks[route.sourceChannel] : (peaks.first ?? 0)
                outputs[route.outputChannel] = min(1, outputs[route.outputChannel] + p * route.gain * 0.8)
            }
        }
        let gain: Float = device.muted ? 0 : device.volume
        return MeterSnapshot(deviceID: deviceID, sources: sourcePeaks, outputs: outputs.map { $0 * gain })
    }
}

import AppKit
import Foundation
import Observation
import SoundRouterKit

enum EngineState: Equatable {
    case connecting
    case connected
    case notRunning
    case versionMismatch(engineVersion: Int)
}

/// Single point of contact between the UI and the engine. The engine owns the configuration;
/// `config` here is only the last copy returned by the engine.
@Observable
@MainActor
final class EngineClient {
    private(set) var engineState: EngineState = .connecting
    private(set) var config = RouterConfig()
    private(set) var status: EngineStatus?
    /// Last command error, shown as an alert.
    var lastError: String?
    /// Device whose meters are polled at 30 Hz.
    var meteredDeviceID: UUID? {
        didSet { if oldValue != meteredDeviceID { meters.reset() } }
    }
    /// Set by the main window while it is on screen.
    var windowVisible = false

    let meters = MeterStore()
    let isOffline: Bool
    /// Dev hook (SOUNDROUTER_SNAPSHOT=<png>): the window may be "occluded" when captured headless.
    @ObservationIgnored private let isSnapshotRun = ProcessInfo.processInfo.environment["SOUNDROUTER_SNAPSHOT"] != nil

    @ObservationIgnored private let backend: EngineBackend
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeRunning = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: ConfigCommand] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    init() {
        let offline = ProcessInfo.processInfo.environment["SOUNDROUTER_OFFLINE"] == "1"
        isOffline = offline
        backend = offline ? OfflineEngineBackend() : XPCEngineBackend()
        backend.onConnectionLost = { [weak self] in
            Task { @MainActor in self?.connectionLost() }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard statusTask == nil else { return }
        reconnect()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.pollStatus()
            }
        }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                await self?.pollMeters()
            }
        }
    }

    /// Starts the handshake loop (hello → version check → getConfig) unless already running.
    func reconnect() {
        guard !handshakeRunning else { return }
        handshakeRunning = true
        if engineState == .connected { engineState = .connecting }
        connectTask = Task { [weak self] in
            var delay: Duration = .milliseconds(500)
            while !Task.isCancelled {
                guard let self else { return }
                if await self.handshake() { break }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(5))
            }
            self?.handshakeRunning = false
        }
    }

    private func handshake() async -> Bool {
        do {
            let version = try await backend.hello()
            if version != engineProtocolVersion {
                engineState = .versionMismatch(engineVersion: version)
                backend.reset()
                return false
            }
            config = try await backend.getConfig()
            status = try? await backend.getStatus()
            engineState = .connected
            return true
        } catch {
            engineState = .notRunning
            backend.reset()
            EngineAgent.repairRegistrationOnce()
            return false
        }
    }

    private func connectionLost() {
        guard engineState == .connected else { return }
        engineState = .connecting
        reconnect()
    }

    private func pollStatus() async {
        guard engineState == .connected else { return }
        do {
            status = try await backend.getStatus()
        } catch {
            engineState = .notRunning
            backend.reset()
            reconnect()
        }
    }

    private func pollMeters() async {
        guard engineState == .connected, windowVisible, let id = meteredDeviceID,
              NSApp?.occlusionState.contains(.visible) ?? true || isSnapshotRun else { return }
        if let snapshot = try? await backend.getMeters(deviceID: id), snapshot.deviceID == meteredDeviceID {
            meters.ingest(snapshot)
        }
    }

    // MARK: Commands

    /// Sends a command, adopts the returned config. Returns the result (nil on transport error).
    @discardableResult
    func perform(_ command: ConfigCommand) async -> CommandResult? {
        guard engineState == .connected else {
            lastError = engineState == .notRunning
                ? EngineError.notConnected.localizedDescription
                : "The engine is not available."
            return nil
        }
        do {
            let result = try await backend.perform(command)
            if result.ok {
                if let cfg = result.config { config = cfg }
            } else {
                lastError = result.error ?? "The engine rejected the change."
            }
            if let s = try? await backend.getStatus() { status = s }
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Fire-and-forget variant.
    func send(_ command: ConfigCommand) {
        Task { await perform(command) }
    }

    /// Coalesces rapid updates (sliders): only the latest pending command per key is sent,
    /// never more than one in flight per key.
    func sendCoalesced(key: String, _ command: ConfigCommand) {
        pending[key] = command
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            while let next = pending.removeValue(forKey: key) {
                await perform(next)
            }
            inFlight.remove(key)
        }
    }

    // MARK: Convenience accessors

    func device(_ id: UUID?) -> VirtualDevice? {
        guard let id else { return nil }
        return config.devices.first { $0.id == id }
    }

    func deviceStatus(_ id: UUID) -> DeviceStatus? {
        status?.devices.first { $0.id == id }
    }

    func sourceStatus(device: UUID, source: UUID) -> SourceStatus? {
        deviceStatus(device)?.sources.first { $0.id == source }
    }

    func monitorStatus(device: UUID, monitor: UUID) -> MonitorStatus? {
        deviceStatus(device)?.monitors.first { $0.id == monitor }
    }

    /// Driver presence: from the engine when connected, else from the file system.
    var driverInstalled: Bool {
        if let status { return status.driverInstalled }
        return FileManager.default.fileExists(atPath: SRPaths.driverBundle.path)
    }
}

// MARK: - Meters

struct MeterLevel: Equatable {
    var level: Float = 0
    var peak: Float = 0
    var peakTime: TimeInterval = 0
}

/// Decayed levels with peak hold, fed by 30 Hz snapshots.
@Observable
@MainActor
final class MeterStore {
    private(set) var sources: [UUID: [MeterLevel]] = [:]
    private(set) var outputs: [MeterLevel] = []
    @ObservationIgnored private var lastUpdate: TimeInterval = 0

    static let holdTime: TimeInterval = 1.5
    /// Fraction of level kept per second (fast fall-off).
    static let levelDecayPerSecond: Float = 0.02
    /// Peak fall-off after hold, per second.
    static let peakDecayPerSecond: Float = 0.3

    func reset() {
        sources = [:]
        outputs = []
    }

    func ingest(_ snapshot: MeterSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(lastUpdate == 0 ? 1.0 / 30 : min(0.5, now - lastUpdate))
        lastUpdate = now
        var newSources: [UUID: [MeterLevel]] = [:]
        for (id, peaks) in snapshot.sources {
            let old = sources[id] ?? []
            newSources[id] = peaks.enumerated().map { i, p in
                Self.step(i < old.count ? old[i] : MeterLevel(), input: p, dt: dt, now: now)
            }
        }
        sources = newSources
        let old = outputs
        outputs = snapshot.outputs.enumerated().map { i, p in
            Self.step(i < old.count ? old[i] : MeterLevel(), input: p, dt: dt, now: now)
        }
    }

    private static func step(_ m: MeterLevel, input: Float, dt: Float, now: TimeInterval) -> MeterLevel {
        var m = m
        let v = max(0, min(1, input.isFinite ? input : 0))
        m.level = max(v, m.level * pow(levelDecayPerSecond, dt))
        if v >= m.peak {
            m.peak = v
            m.peakTime = now
        } else if now - m.peakTime > holdTime {
            m.peak = max(m.level, m.peak - peakDecayPerSecond * dt)
        }
        return m
    }
}

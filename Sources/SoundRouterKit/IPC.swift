import Foundation

// XPC contract between the control app (client) and the engine agent (Mach service).
// Payloads are JSON-encoded Codable values carried as Data so the protocol stays stable;
// `protocolVersion` is checked by `hello`.

public let engineMachServiceName = "io.soundrouter.engine.xpc"
public let engineLaunchAgentPlistName = "io.soundrouter.engine.plist"
public let engineProtocolVersion = 1

@objc public protocol EngineXPCProtocol {
    /// Returns the engine protocol version. Client must refuse to talk to a different major.
    func hello(clientProtocolVersion: Int, reply: @escaping (Int) -> Void)
    /// Returns JSON-encoded `RouterConfig`.
    func getConfig(reply: @escaping (Data) -> Void)
    /// Takes JSON-encoded `ConfigCommand`. Reply: JSON-encoded `CommandResult`.
    func perform(command: Data, reply: @escaping (Data) -> Void)
    /// Returns JSON-encoded `EngineStatus` (cheap; polled ~1 Hz and after each command).
    func getStatus(reply: @escaping (Data) -> Void)
    /// Returns JSON-encoded `MeterSnapshot` (polled at 30 Hz while a window is visible).
    func getMeters(deviceID: String, reply: @escaping (Data) -> Void)
}

/// CRUD commands. The engine validates each one (bounds, single pass-thru, …) before
/// persisting and applying. Gain/route changes are applied hot; channel count or sample
/// rate changes reconfigure the driver device.
public enum ConfigCommand: Codable, Sendable {
    // Devices (F1, F3, F10, F12)
    case createDevice(name: String)                       // default: pass-thru + 2 ch, rate of default output
    case duplicateDevice(id: UUID)
    case deleteDevice(id: UUID)
    case renameDevice(id: UUID, name: String)
    case setDeviceEnabled(id: UUID, enabled: Bool)
    case setDeviceSampleRate(id: UUID, sampleRate: Double)
    case setDeviceChannelCount(id: UUID, count: Int)
    case setDeviceVolume(id: UUID, volume: Float, muted: Bool)
    // Sources (F4–F7)
    case addSource(deviceID: UUID, source: Source)        // stereo source on stereo device: auto 1:1 routes
    case removeSource(deviceID: UUID, sourceID: UUID)
    case updateSource(deviceID: UUID, source: Source)     // enabled, volume, muted, options, channels
    // Routes (F9)
    case addRoute(deviceID: UUID, route: Route)
    case removeRoute(deviceID: UUID, route: Route)        // matched on source/channels, gain ignored
    case setRoutes(deviceID: UUID, routes: [Route])
    // Monitors (F11)
    case addMonitor(deviceID: UUID, monitor: Monitor)
    case updateMonitor(deviceID: UUID, monitor: Monitor)
    case removeMonitor(deviceID: UUID, monitorID: UUID)
    // Whole config (F16, v2) and settings
    case replaceConfig(RouterConfig)
    case updateSettings(EngineSettings)
}

public struct CommandResult: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    /// Config after the command (always present when ok).
    public var config: RouterConfig?
    /// Id of the created object for create/duplicate commands.
    public var createdID: UUID?

    public init(ok: Bool, error: String? = nil, config: RouterConfig? = nil, createdID: UUID? = nil) {
        self.ok = ok
        self.error = error
        self.config = config
        self.createdID = createdID
    }
}

public struct EngineStatus: Codable, Sendable {
    public var engineVersion: String
    public var driverInstalled: Bool
    public var audioCapturePermission: PermissionState
    public var microphonePermission: PermissionState
    public var devices: [DeviceStatus]

    public init(engineVersion: String, driverInstalled: Bool, audioCapturePermission: PermissionState,
                microphonePermission: PermissionState, devices: [DeviceStatus]) {
        self.engineVersion = engineVersion
        self.driverInstalled = driverInstalled
        self.audioCapturePermission = audioCapturePermission
        self.microphonePermission = microphonePermission
        self.devices = devices
    }
}

public enum PermissionState: String, Codable, Sendable {
    case unknown, granted, denied
}

public struct DeviceStatus: Codable, Sendable {
    public var id: UUID
    /// Driver has published the device to Core Audio.
    public var visibleInSystem: Bool
    /// Engine mixer running for this device.
    public var running: Bool
    public var sources: [SourceStatus]
    public var monitors: [MonitorStatus]
    public var underruns: UInt64

    public init(id: UUID, visibleInSystem: Bool, running: Bool, sources: [SourceStatus],
                monitors: [MonitorStatus], underruns: UInt64) {
        self.id = id
        self.visibleInSystem = visibleInSystem
        self.running = running
        self.sources = sources
        self.monitors = monitors
        self.underruns = underruns
    }
}

public enum SourceState: String, Codable, Sendable {
    case active            // capturing
    case disabled          // source.enabled == false
    case waiting           // application not running: greyed but active, will attach on launch
    case disconnected      // input device absent: greyed, config kept
    case permissionDenied  // TCC audio capture / microphone refused
    case error
}

public struct SourceStatus: Codable, Sendable {
    public var id: UUID
    public var state: SourceState
    public var message: String?
    public init(id: UUID, state: SourceState, message: String? = nil) {
        self.id = id
        self.state = state
        self.message = message
    }
}

public struct MonitorStatus: Codable, Sendable {
    public var id: UUID
    public var state: SourceState   // active / disabled / disconnected / error
    public init(id: UUID, state: SourceState) {
        self.id = id
        self.state = state
    }
}

/// Peak levels (linear 0...1) since last poll.
public struct MeterSnapshot: Codable, Sendable {
    public var deviceID: UUID
    /// sourceID -> peaks per channel (max 2 channels metered per source).
    public var sources: [UUID: [Float]]
    /// one entry per output channel.
    public var outputs: [Float]
    public init(deviceID: UUID, sources: [UUID: [Float]], outputs: [Float]) {
        self.deviceID = deviceID
        self.sources = sources
        self.outputs = outputs
    }
}

public enum SRJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

public enum SRPaths {
    /// ~/Library/Application Support/SoundRouter
    public static var userSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundRouter", isDirectory: true)
    }
    public static var configFile: URL { userSupportDirectory.appendingPathComponent("config.json") }
    /// Written by the engine, read by the driver (inside coreaudiod).
    public static let driverDevicesFile = URL(fileURLWithPath: "/Library/Application Support/SoundRouter/devices.json")
    public static let driverBundle = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/SoundRouter.driver")
    public static let devicesChangedNotification = "io.soundrouter.devices-changed"
}

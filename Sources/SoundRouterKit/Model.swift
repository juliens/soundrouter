import Foundation

// Configuration model shared by the engine (owner) and the control app (editor).
// Serialized as JSON in ~/Library/Application Support/SoundRouter/config.json.

public let currentSchemaVersion = 1
public let supportedSampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
public let maxOutputChannels = 64

public struct RouterConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int = currentSchemaVersion
    public var devices: [VirtualDevice] = []
    public var settings: EngineSettings = EngineSettings()

    public init(devices: [VirtualDevice] = [], settings: EngineSettings = EngineSettings()) {
        self.devices = devices
        self.settings = settings
    }
}

public struct EngineSettings: Codable, Equatable, Sendable {
    /// Mix cycle in frames, 64...1024.
    public var cycleFrames: Int = 256
    public var logLevel: LogLevel = .info

    public init(cycleFrames: Int = 256, logLevel: LogLevel = .info) {
        self.cycleFrames = cycleFrames
        self.logLevel = logLevel
    }
}

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case error, warning, info, debug
}

public struct VirtualDevice: Codable, Equatable, Identifiable, Sendable {
    /// Stable; used as the Core Audio device UID (uppercase UUID string). Never modified.
    public var id: UUID
    public var name: String
    public var enabled: Bool = true
    public var sampleRate: Double = 48_000
    public var outputChannelCount: Int = 2
    public var volume: Float = 1
    public var muted: Bool = false
    public var sources: [Source] = []
    public var routes: [Route] = []
    public var monitors: [Monitor] = []

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, sampleRate: Double = 48_000,
                outputChannelCount: Int = 2, volume: Float = 1, muted: Bool = false,
                sources: [Source] = [], routes: [Route] = [], monitors: [Monitor] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sampleRate = sampleRate
        self.outputChannelCount = outputChannelCount
        self.volume = volume
        self.muted = muted
        self.sources = sources
        self.routes = routes
        self.monitors = monitors
    }

    public var uid: String { id.uuidString }
    public var hasPassThru: Bool { sources.contains { $0.kind == .passThru } }
}

public enum SourceKind: String, Codable, Sendable {
    case application, inputDevice, passThru
}

public struct Source: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    public var enabled: Bool = true
    public var volume: Float = 1
    public var muted: Bool = false
    /// application: always 2. passThru: == device.outputChannelCount. inputDevice: channels.count.
    public var channelCount: Int
    /// Display name (app name / device name). Informational only.
    public var displayName: String = ""
    /// Optional per-channel volume (linear) and mute, indexed by source channel. Missing or
    /// short arrays mean 1 / not muted, so older configs stay valid.
    public var channelVolumes: [Float]?
    public var channelMuted: [Bool]?

    // kind == .application
    public var application: ApplicationSource?
    // kind == .inputDevice
    public var inputDevice: InputDeviceSource?

    public init(id: UUID = UUID(), kind: SourceKind, enabled: Bool = true, volume: Float = 1,
                muted: Bool = false, channelCount: Int, displayName: String = "",
                application: ApplicationSource? = nil, inputDevice: InputDeviceSource? = nil) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.volume = volume
        self.muted = muted
        self.channelCount = channelCount
        self.displayName = displayName
        self.application = application
        self.inputDevice = inputDevice
    }

    public func channelVolume(_ channel: Int) -> Float {
        guard let v = channelVolumes, channel >= 0, channel < v.count else { return 1 }
        return v[channel]
    }

    public func isChannelMuted(_ channel: Int) -> Bool {
        guard let m = channelMuted, channel >= 0, channel < m.count else { return false }
        return m[channel]
    }

    /// Effective per-channel gain applied on top of the source volume (0 when muted).
    public func channelGain(_ channel: Int) -> Float {
        isChannelMuted(channel) ? 0 : channelVolume(channel)
    }

    public mutating func setChannelVolume(_ channel: Int, _ volume: Float) {
        var v = channelVolumes ?? []
        if v.count < channelCount { v += Array(repeating: 1, count: channelCount - v.count) }
        if channel >= 0, channel < v.count { v[channel] = volume }
        channelVolumes = v
    }

    public mutating func setChannelMuted(_ channel: Int, _ muted: Bool) {
        var m = channelMuted ?? []
        if m.count < channelCount { m += Array(repeating: false, count: channelCount - m.count) }
        if channel >= 0, channel < m.count { m[channel] = muted }
        channelMuted = m
    }

    public static func passThru(channels: Int) -> Source {
        Source(kind: .passThru, channelCount: channels, displayName: "Pass-Thru")
    }

    public static func application(_ app: ApplicationSource, displayName: String) -> Source {
        Source(kind: .application, channelCount: 2, displayName: displayName, application: app)
    }

    public static func inputDevice(_ dev: InputDeviceSource, displayName: String) -> Source {
        Source(kind: .inputDevice, channelCount: dev.channels.count, displayName: displayName,
               inputDevice: dev)
    }
}

public struct ApplicationSource: Codable, Equatable, Sendable {
    /// Preferred identity. nil for processes without a bundle (then `pid`/`executablePath`).
    public var bundleID: String?
    public var pid: Int32?
    /// For bundle-less processes, used to re-find the process after relaunch.
    public var executablePath: String?
    public var muteWhenCapturing: Bool = true

    public init(bundleID: String? = nil, pid: Int32? = nil, executablePath: String? = nil,
                muteWhenCapturing: Bool = true) {
        self.bundleID = bundleID
        self.pid = pid
        self.executablePath = executablePath
        self.muteWhenCapturing = muteWhenCapturing
    }
}

public struct InputDeviceSource: Codable, Equatable, Sendable {
    /// Core Audio device UID (may be another SoundRouter virtual device).
    public var deviceUID: String
    /// 0-based device input channels used, in order. Source channel i = device channel channels[i].
    public var channels: [Int]

    public init(deviceUID: String, channels: [Int]) {
        self.deviceUID = deviceUID
        self.channels = channels
    }
}

public struct Route: Codable, Equatable, Hashable, Sendable {
    public var sourceID: UUID
    /// 0-based channel within the source.
    public var sourceChannel: Int
    /// 0-based output channel of the device.
    public var outputChannel: Int
    public var gain: Float = 1

    public init(sourceID: UUID, sourceChannel: Int, outputChannel: Int, gain: Float = 1) {
        self.sourceID = sourceID
        self.sourceChannel = sourceChannel
        self.outputChannel = outputChannel
        self.gain = gain
    }
}

public struct Monitor: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Core Audio UID of a physical output device.
    public var deviceUID: String
    public var displayName: String = ""
    public var enabled: Bool = true
    public var volume: Float = 1
    public var muted: Bool = false
    /// Device output channel -> monitor device channel (0-based).
    public var routes: [MonitorRoute] = []

    public init(id: UUID = UUID(), deviceUID: String, displayName: String = "", enabled: Bool = true,
                volume: Float = 1, muted: Bool = false, routes: [MonitorRoute] = []) {
        self.id = id
        self.deviceUID = deviceUID
        self.displayName = displayName
        self.enabled = enabled
        self.volume = volume
        self.muted = muted
        self.routes = routes
    }
}

public struct MonitorRoute: Codable, Equatable, Hashable, Sendable {
    public var deviceChannel: Int
    public var monitorChannel: Int
    public init(deviceChannel: Int, monitorChannel: Int) {
        self.deviceChannel = deviceChannel
        self.monitorChannel = monitorChannel
    }
}

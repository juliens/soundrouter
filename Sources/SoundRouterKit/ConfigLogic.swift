import Foundation

// Pure, synchronous config logic used by the engine (and unit tests).
// CONTRACT — implementations are filled in by the core agent; signatures must not change.

public struct ConfigError: Error, CustomStringConvertible, Equatable, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum ConfigValidator {
    /// Throws the first violation found:
    /// - device ids unique; 1...64 output channels; sampleRate in supportedSampleRates; name non-empty
    /// - at most one passThru source per device, whose channelCount == outputChannelCount
    /// - application sources: channelCount == 2 and bundleID or pid/executablePath set
    /// - inputDevice sources: channels non-empty, channelCount == channels.count
    /// - routes reference existing sources and in-range channels, no exact duplicate
    ///   (same source/sourceChannel/outputChannel)
    /// - monitor routes: deviceChannel in range, monitorChannel >= 0
    /// - settings.cycleFrames in 64...1024
    public static func validate(_ config: RouterConfig) throws {
        guard (64...1024).contains(config.settings.cycleFrames) else {
            throw ConfigError("cycleFrames \(config.settings.cycleFrames) out of range 64...1024")
        }
        var deviceIDs = Set<UUID>()
        for device in config.devices {
            guard deviceIDs.insert(device.id).inserted else {
                throw ConfigError("duplicate device id \(device.id)")
            }
            try validate(device)
        }
    }

    static func validate(_ device: VirtualDevice) throws {
        let d = "device \"\(device.name)\""
        guard !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigError("device \(device.id) has an empty name")
        }
        guard (1...maxOutputChannels).contains(device.outputChannelCount) else {
            throw ConfigError("\(d): output channel count \(device.outputChannelCount) out of range 1...\(maxOutputChannels)")
        }
        guard supportedSampleRates.contains(device.sampleRate) else {
            throw ConfigError("\(d): unsupported sample rate \(device.sampleRate)")
        }

        var sources = [UUID: Source]()
        var passThruCount = 0
        for source in device.sources {
            guard sources[source.id] == nil else {
                throw ConfigError("\(d): duplicate source id \(source.id)")
            }
            sources[source.id] = source
            switch source.kind {
            case .passThru:
                passThruCount += 1
                guard passThruCount <= 1 else { throw ConfigError("\(d): more than one Pass-Thru source") }
                guard source.channelCount == device.outputChannelCount else {
                    throw ConfigError("\(d): Pass-Thru has \(source.channelCount) channels, device has \(device.outputChannelCount)")
                }
            case .application:
                guard source.channelCount == 2 else {
                    throw ConfigError("\(d): application source \(source.id) must have 2 channels")
                }
                guard let app = source.application,
                      app.bundleID?.isEmpty == false || app.pid != nil || app.executablePath?.isEmpty == false
                else {
                    throw ConfigError("\(d): application source \(source.id) has no bundleID, pid or executablePath")
                }
            case .inputDevice:
                guard let input = source.inputDevice, !input.channels.isEmpty else {
                    throw ConfigError("\(d): input device source \(source.id) has no channels")
                }
                guard source.channelCount == input.channels.count else {
                    throw ConfigError("\(d): input device source \(source.id) channelCount != channels.count")
                }
                guard input.channels.allSatisfy({ $0 >= 0 }) else {
                    throw ConfigError("\(d): input device source \(source.id) has a negative channel")
                }
            }
        }

        struct RouteKey: Hashable { var source: UUID; var sc: Int; var oc: Int }
        var seen = Set<RouteKey>()
        for route in device.routes {
            guard let source = sources[route.sourceID] else {
                throw ConfigError("\(d): route references unknown source \(route.sourceID)")
            }
            guard (0..<source.channelCount).contains(route.sourceChannel) else {
                throw ConfigError("\(d): route source channel \(route.sourceChannel) out of range")
            }
            guard (0..<device.outputChannelCount).contains(route.outputChannel) else {
                throw ConfigError("\(d): route output channel \(route.outputChannel) out of range")
            }
            guard seen.insert(RouteKey(source: route.sourceID, sc: route.sourceChannel,
                                       oc: route.outputChannel)).inserted else {
                throw ConfigError("\(d): duplicate route \(route.sourceChannel) -> \(route.outputChannel)")
            }
        }

        for monitor in device.monitors {
            for r in monitor.routes {
                guard (0..<device.outputChannelCount).contains(r.deviceChannel) else {
                    throw ConfigError("\(d): monitor route device channel \(r.deviceChannel) out of range")
                }
                guard r.monitorChannel >= 0 else {
                    throw ConfigError("\(d): monitor route channel \(r.monitorChannel) is negative")
                }
            }
        }
    }
}

public enum ConfigMigration {
    private struct VersionProbe: Decodable { var schemaVersion: Int? }

    /// Decodes a config of any known schemaVersion and migrates it to `currentSchemaVersion`.
    /// Throws on unreadable/invalid JSON or on validation failure after migration.
    public static func load(_ data: Data) throws -> RouterConfig {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            throw ConfigError("unreadable config: \(error.localizedDescription)")
        }
        guard let version = probe.schemaVersion else {
            throw ConfigError("config has no schemaVersion")
        }
        guard version >= 1 else { throw ConfigError("invalid schemaVersion \(version)") }
        guard version <= currentSchemaVersion else {
            throw ConfigError("config schemaVersion \(version) is newer than supported (\(currentSchemaVersion))")
        }

        var config: RouterConfig
        switch version {
        case 1:
            do {
                config = try JSONDecoder().decode(RouterConfig.self, from: data)
            } catch {
                throw ConfigError("invalid config: \(error)")
            }
        // Future: case 2...: decode the old shape and convert step by step.
        default:
            throw ConfigError("no migration path from schemaVersion \(version)")
        }
        config.schemaVersion = currentSchemaVersion
        try ConfigValidator.validate(config)
        return config
    }
}

public enum ConfigReducer {
    /// Applies `command` to `config` and returns the new config plus the id of any created
    /// object. Throws ConfigError if the command references unknown objects or would produce
    /// an invalid config (result is validated). Pure: no I/O.
    /// - createDevice: pass-thru source + 2 channels + 1:1 routes, sampleRate = defaultSampleRate
    /// - setDeviceChannelCount: resizes pass-thru channelCount and its 1:1 routes; drops routes
    ///   and monitor routes to channels >= count
    /// - addSource: if source & device both have 2 channels (or passThru), adds 1:1 routes
    /// - removeSource: removes its routes
    /// - duplicateDevice: new ids for device & sources (routes remapped), name + " copy"
    public static func apply(_ command: ConfigCommand, to config: RouterConfig,
                             defaultSampleRate: Double) throws -> (RouterConfig, UUID?) {
        var cfg = config
        var created: UUID?

        func deviceIndex(_ id: UUID) throws -> Int {
            guard let i = cfg.devices.firstIndex(where: { $0.id == id }) else {
                throw ConfigError("unknown device \(id)")
            }
            return i
        }

        switch command {
        case .createDevice(let name):
            let rate = supportedSampleRates.contains(defaultSampleRate) ? defaultSampleRate : 48_000
            let pt = Source.passThru(channels: 2)
            let device = VirtualDevice(name: name, sampleRate: rate, outputChannelCount: 2,
                                       sources: [pt], routes: oneToOne(pt.id, channels: 2))
            cfg.devices.append(device)
            created = device.id

        case .duplicateDevice(let id):
            let i = try deviceIndex(id)
            var copy = cfg.devices[i]
            copy.id = UUID()
            copy.name += " copy"
            var map = [UUID: UUID]()
            for s in copy.sources.indices {
                let newID = UUID()
                map[copy.sources[s].id] = newID
                copy.sources[s].id = newID
            }
            copy.routes = copy.routes.compactMap { r in
                guard let n = map[r.sourceID] else { return nil }
                var r = r
                r.sourceID = n
                return r
            }
            for m in copy.monitors.indices { copy.monitors[m].id = UUID() }
            cfg.devices.insert(copy, at: i + 1)
            created = copy.id

        case .deleteDevice(let id):
            cfg.devices.remove(at: try deviceIndex(id))

        case .renameDevice(let id, let name):
            cfg.devices[try deviceIndex(id)].name = name

        case .setDeviceEnabled(let id, let enabled):
            cfg.devices[try deviceIndex(id)].enabled = enabled

        case .setDeviceSampleRate(let id, let sampleRate):
            cfg.devices[try deviceIndex(id)].sampleRate = sampleRate

        case .setDeviceChannelCount(let id, let count):
            let i = try deviceIndex(id)
            guard (1...maxOutputChannels).contains(count) else {
                throw ConfigError("channel count \(count) out of range 1...\(maxOutputChannels)")
            }
            var dev = cfg.devices[i]
            let old = dev.outputChannelCount
            dev.outputChannelCount = count
            let ptIndex = dev.sources.firstIndex { $0.kind == .passThru }
            if let p = ptIndex { dev.sources[p].channelCount = count }
            let ptID = ptIndex.map { dev.sources[$0].id }
            dev.routes.removeAll { r in
                r.outputChannel >= count || (r.sourceID == ptID && r.sourceChannel >= count)
            }
            if let ptID, count > old {
                for ch in old..<count {
                    let r = Route(sourceID: ptID, sourceChannel: ch, outputChannel: ch)
                    if !dev.routes.contains(where: { sameRoute($0, r) }) { dev.routes.append(r) }
                }
            }
            for m in dev.monitors.indices {
                dev.monitors[m].routes.removeAll { $0.deviceChannel >= count }
            }
            cfg.devices[i] = dev

        case .setDeviceVolume(let id, let volume, let muted):
            let i = try deviceIndex(id)
            cfg.devices[i].volume = min(max(volume.isFinite ? volume : 0, 0), 1)
            cfg.devices[i].muted = muted

        case .addSource(let deviceID, let source):
            let i = try deviceIndex(deviceID)
            var dev = cfg.devices[i]
            var src = source
            if dev.sources.contains(where: { $0.id == src.id }) { src.id = UUID() }
            if src.kind == .passThru {
                guard !dev.hasPassThru else { throw ConfigError("device already has a Pass-Thru source") }
                src.channelCount = dev.outputChannelCount
                dev.routes += oneToOne(src.id, channels: dev.outputChannelCount)
            } else if src.channelCount == 2 && dev.outputChannelCount == 2 {
                dev.routes += oneToOne(src.id, channels: 2)
            }
            dev.sources.append(src)
            cfg.devices[i] = dev
            created = src.id

        case .removeSource(let deviceID, let sourceID):
            let i = try deviceIndex(deviceID)
            guard cfg.devices[i].sources.contains(where: { $0.id == sourceID }) else {
                throw ConfigError("unknown source \(sourceID)")
            }
            cfg.devices[i].sources.removeAll { $0.id == sourceID }
            cfg.devices[i].routes.removeAll { $0.sourceID == sourceID }

        case .updateSource(let deviceID, let source):
            let i = try deviceIndex(deviceID)
            guard let s = cfg.devices[i].sources.firstIndex(where: { $0.id == source.id }) else {
                throw ConfigError("unknown source \(source.id)")
            }
            cfg.devices[i].sources[s] = source
            cfg.devices[i].routes.removeAll {
                $0.sourceID == source.id && $0.sourceChannel >= source.channelCount
            }

        case .addRoute(let deviceID, let route):
            let i = try deviceIndex(deviceID)
            if let r = cfg.devices[i].routes.firstIndex(where: { sameRoute($0, route) }) {
                cfg.devices[i].routes[r].gain = route.gain
            } else {
                cfg.devices[i].routes.append(route)
            }

        case .removeRoute(let deviceID, let route):
            let i = try deviceIndex(deviceID)
            guard cfg.devices[i].routes.contains(where: { sameRoute($0, route) }) else {
                throw ConfigError("unknown route")
            }
            cfg.devices[i].routes.removeAll { sameRoute($0, route) }

        case .setRoutes(let deviceID, let routes):
            cfg.devices[try deviceIndex(deviceID)].routes = routes

        case .addMonitor(let deviceID, let monitor):
            let i = try deviceIndex(deviceID)
            var m = monitor
            if cfg.devices[i].monitors.contains(where: { $0.id == m.id }) { m.id = UUID() }
            cfg.devices[i].monitors.append(m)
            created = m.id

        case .updateMonitor(let deviceID, let monitor):
            let i = try deviceIndex(deviceID)
            guard let m = cfg.devices[i].monitors.firstIndex(where: { $0.id == monitor.id }) else {
                throw ConfigError("unknown monitor \(monitor.id)")
            }
            cfg.devices[i].monitors[m] = monitor

        case .removeMonitor(let deviceID, let monitorID):
            let i = try deviceIndex(deviceID)
            guard cfg.devices[i].monitors.contains(where: { $0.id == monitorID }) else {
                throw ConfigError("unknown monitor \(monitorID)")
            }
            cfg.devices[i].monitors.removeAll { $0.id == monitorID }

        case .replaceConfig(let newConfig):
            cfg = newConfig
            guard cfg.schemaVersion == currentSchemaVersion else {
                throw ConfigError("unsupported schemaVersion \(cfg.schemaVersion)")
            }

        case .updateSettings(let settings):
            cfg.settings = settings
        }

        try ConfigValidator.validate(cfg)
        return (cfg, created)
    }

    /// Default config for first launch / fallback: no devices.
    public static func defaultConfig() -> RouterConfig { RouterConfig() }

    private static func oneToOne(_ sourceID: UUID, channels: Int) -> [Route] {
        (0..<channels).map { Route(sourceID: sourceID, sourceChannel: $0, outputChannel: $0) }
    }

    private static func sameRoute(_ a: Route, _ b: Route) -> Bool {
        a.sourceID == b.sourceID && a.sourceChannel == b.sourceChannel
            && a.outputChannel == b.outputChannel
    }
}

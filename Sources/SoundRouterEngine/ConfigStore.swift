import Darwin
import Foundation
import notify
import SoundRouterKit

/// Owns the persisted `RouterConfig`. Control queue only.
///
/// Paths: `SOUNDROUTER_CONFIG_DIR` (env) overrides BOTH the user config directory and the
/// directory of devices.json (used by `--selftest` and development runs).
final class ConfigStore {
    let configFile: URL
    let backupFile: URL
    let devicesFile: URL
    private(set) var config: RouterConfig = ConfigReducer.defaultConfig()
    /// Last error writing devices.json (nil when the last write succeeded).
    private(set) var devicesFileError: String?
    /// Last error persisting config.json.
    private(set) var configFileError: String?

    init(overrideDirectory: URL? = ConfigStore.environmentOverride()) {
        if let dir = overrideDirectory {
            configFile = dir.appendingPathComponent("config.json")
            devicesFile = dir.appendingPathComponent("devices.json")
        } else {
            configFile = SRPaths.configFile
            devicesFile = SRPaths.driverDevicesFile
        }
        backupFile = configFile.appendingPathExtension("bak")
    }

    static func environmentOverride() -> URL? {
        guard let p = ProcessInfo.processInfo.environment["SOUNDROUTER_CONFIG_DIR"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    // MARK: Load / persist

    /// Loads config.json via ConfigMigration. Missing file -> default config (persisted).
    /// Unreadable / invalid -> copied to config.json.bak, default config (persisted).
    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: configFile.path) else {
            Log.info("No config at \(configFile.path); starting with default config")
            config = ConfigReducer.defaultConfig()
            persist()
            return
        }
        do {
            let data = try Data(contentsOf: configFile)
            config = try ConfigMigration.load(data)
            Log.info("Loaded config: \(config.devices.count) device(s)")
            // Re-persist if migration changed the schema version on disk.
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (raw["schemaVersion"] as? Int) != currentSchemaVersion {
                persist()
            }
        } catch {
            Log.error("Invalid config \(configFile.path): \(error). Backing up to \(backupFile.lastPathComponent) and using default config")
            try? fm.removeItem(at: backupFile)
            do { try fm.copyItem(at: configFile, to: backupFile) } catch {
                Log.error("Could not back up invalid config: \(error)")
            }
            config = ConfigReducer.defaultConfig()
            persist()
        }
    }

    func persist() {
        do {
            try ConfigStore.atomicWrite(SRJSON.encode(config), to: configFile, mode: 0o600)
            configFileError = nil
        } catch {
            configFileError = "\(error)"
            Log.error("Could not write \(configFile.path): \(error)")
        }
    }

    /// Applies a command through ConfigReducer. On success: config replaced, persisted,
    /// devices.json rewritten + notification posted. Throws ConfigError otherwise.
    @discardableResult
    func apply(_ command: ConfigCommand, defaultSampleRate: Double) throws -> UUID? {
        let (newConfig, created) = try ConfigReducer.apply(command, to: config, defaultSampleRate: defaultSampleRate)
        let devicesChanged = ConfigStore.driverDevices(newConfig) != ConfigStore.driverDevices(config)
        config = newConfig
        persist()
        // Only the driver-visible subset matters to coreaudiod; retry after a failed write.
        if devicesChanged || devicesFileError != nil { publishDevices() }
        return created
    }

    // MARK: devices.json (engine -> driver)

    struct DriverDevice: Codable, Equatable {
        var id: String
        var name: String
        var channels: Int
        var sampleRate: Double
        var passThru: Bool
    }

    struct DriverDevicesFile: Codable, Equatable {
        var schemaVersion: Int = 1
        var devices: [DriverDevice]
    }

    static func driverDevices(_ config: RouterConfig) -> DriverDevicesFile {
        DriverDevicesFile(devices: config.devices.filter(\.enabled).map {
            DriverDevice(id: $0.uid.uppercased(), name: $0.name, channels: $0.outputChannelCount,
                         sampleRate: $0.sampleRate, passThru: $0.hasPassThru)
        })
    }

    /// Writes devices.json atomically (mode 0644 so coreaudiod can read it) and posts
    /// SR_NOTIFY_DEVICES_CHANGED. A write failure is logged and kept in `devicesFileError`.
    func publishDevices() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(ConfigStore.driverDevices(config))
            try ConfigStore.atomicWrite(data, to: devicesFile, mode: 0o644)
            devicesFileError = nil
        } catch {
            devicesFileError = "Cannot write \(devicesFile.path): \(error)"
            Log.error(devicesFileError!)
        }
        let st = notify_post(SRPaths.devicesChangedNotification)
        if st != 0 { Log.warning("notify_post failed: \(st)") }
    }

    // MARK: Atomic write

    struct IOError: Error, CustomStringConvertible {
        let description: String
    }

    /// Write to a temp file in the same directory, fchmod, fsync, rename over the target.
    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard fd >= 0 else { throw IOError(description: "open(\(tmp.path)): \(String(cString: strerror(errno)))") }
        var ok = true
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    ok = false
                    return
                }
                off += n
            }
        }
        let err = errno
        fchmod(fd, mode)
        if ok { fsync(fd) }
        close(fd)
        guard ok else {
            unlink(tmp.path)
            throw IOError(description: "write(\(tmp.path)): \(String(cString: strerror(err)))")
        }
        if rename(tmp.path, url.path) != 0 {
            let e = errno
            unlink(tmp.path)
            throw IOError(description: "rename(\(url.path)): \(String(cString: strerror(e)))")
        }
    }
}

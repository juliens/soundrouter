import Foundation
import SRCore
import SoundRouterKit

/// `SoundRouterEngine --selftest`: non-interactive checks that never touch TCC-protected
/// APIs (no taps, no input units, no monitors). Uses $SOUNDROUTER_CONFIG_DIR or a temp dir
/// for config.json AND devices.json. Creates one pass-thru device (POSIX shm + RT mix
/// thread) for ~0.3 s, then deletes it (segment unlinked). Returns the process exit code.
enum SelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ what: String) {
        print("\(cond ? "PASS" : "FAIL")  \(what)")
        if !cond { failures += 1 }
    }

    static func run() -> Int32 {
        Log.mirrorToStderr = true
        let dir: URL
        if let d = ConfigStore.environmentOverride() {
            dir = d
        } else {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("soundrouter-selftest-\(getpid())", isDirectory: true)
            setenv("SOUNDROUTER_CONFIG_DIR", dir.path, 1)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("selftest dir: \(dir.path)")

        // 1. ABI checks for fields Swift cannot see.
        let layout = ShmField.validateLayout()
        check(layout == nil, "SRShmHeader layout matches hard-coded atomic offsets \(layout ?? "")")
        check(RenderState.routesOffset == 404, "SRMixPlan.routes offset = \(RenderState.routesOffset) (expected 404)")

        // 2. Invalid config -> .bak + default config.
        let store = ConfigStore()
        try? FileManager.default.removeItem(at: store.backupFile)
        try? Data("{ not json".utf8).write(to: store.configFile)
        store.load()
        check(FileManager.default.fileExists(atPath: store.backupFile.path), "invalid config backed up to config.json.bak")
        check(store.config == ConfigReducer.defaultConfig(), "fallback to default config")

        // 3. Commands through the controller (creates a real device engine: shm + mix thread).
        let controller = EngineController(store: ConfigStore())
        controller.start(hardware: false)
        var created: UUID?
        controller.queue.sync {
            let r = controller.perform(.createDevice(name: "Selftest"))
            check(r.ok, "createDevice ok \(r.error ?? "")")
            created = r.createdID
            if let id = created {
                let r2 = controller.perform(.setDeviceVolume(id: id, volume: 0.5, muted: false))
                check(r2.ok, "setDeviceVolume ok \(r2.error ?? "")")
                let bad = controller.perform(.setDeviceChannelCount(id: id, count: 999))
                check(!bad.ok, "invalid channel count rejected")
            }
        }
        guard let id = created else {
            controller.shutdown()
            return 1
        }

        // devices.json + persisted config.
        let reloaded = ConfigStore()
        reloaded.load()
        check(reloaded.config.devices.first?.id == id && reloaded.config.devices.first?.volume == 0.5,
              "config.json persisted and reloadable")
        if let data = try? Data(contentsOf: reloaded.devicesFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devs = obj["devices"] as? [[String: Any]] {
            check(obj["schemaVersion"] as? Int == 1 && devs.first?["id"] as? String == id.uuidString.uppercased()
                  && devs.first?["passThru"] as? Bool == true, "devices.json written in driver format")
        } else {
            check(false, "devices.json readable")
        }

        // 4. Mix thread runs, publishes mix frames and heartbeat.
        usleep(300_000)
        controller.queue.sync {
            guard let diag = controller.engine(id)?.diagnostics else {
                check(false, "device engine running")
                return
            }
            check(diag.cycles > 10, "mix thread rendered \(diag.cycles) cycles")
            check(diag.mixWriteFrame > 0, "mixWriteFrame advanced (\(diag.mixWriteFrame))")
            check(diag.heartbeat > 0, "engine heartbeat written")
            print("info  sr_thread_set_realtime returned \(diag.realtime)")
            // Hot changes: several plan swaps while the mix thread runs.
            for v in stride(from: Float(0.1), through: 1.0, by: 0.1) {
                _ = controller.perform(.setDeviceVolume(id: id, volume: v, muted: false))
            }
            let st = controller.status()
            check(st.devices.first?.running == true, "status reports device running")
            let m = controller.meters(deviceID: id)
            check(m.outputs.count == 2, "meter snapshot has 2 outputs")
        }
        usleep(100_000)
        controller.queue.sync {
            let r = controller.perform(.setDeviceChannelCount(id: id, count: 4))
            check(r.ok, "channel count change (mixer restart) ok \(r.error ?? "")")
        }
        usleep(200_000)
        controller.queue.sync {
            check((controller.engine(id)?.diagnostics?.cycles ?? 0) > 5, "mixer running after restart")
            let r = controller.perform(.deleteDevice(id: id))
            check(r.ok && controller.engine(id) == nil, "deleteDevice stops the engine")
        }
        controller.shutdown()
        print(failures == 0 ? "selftest OK" : "selftest FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}

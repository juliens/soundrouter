// srctl — minimal XPC client for the SoundRouter engine (integration tests, debugging).
//
// Build:  make srctl
//   (= swiftc -O -parse-as-library Sources/SoundRouterKit/*.swift IntegrationTests/Tools/srctl.swift -o build/srctl)
// The engine only accepts callers signed with the same Team ID: sign srctl with the same
// SIGN_IDENTITY as the app (the Makefile does), or use a dev build of the engine.
//
// Usage:
//   srctl hello
//   srctl status                         EngineStatus JSON
//   srctl config                         RouterConfig JSON
//   srctl devices                        "<uuid>\t<name>\t<rate>\t<channels>"
//   srctl underruns                      "<uuid>\t<name>\t<underruns>" (one line per device)
//   srctl create-device NAME [--rate R] [--channels N]
//   srctl delete-device DEVICE
//   srctl add-app DEVICE BUNDLEID        (or: --pid PID | --path /usr/bin/afplay) [--no-mute]
//   srctl add-input DEVICE INPUT_UID CH[,CH...]
//   srctl meters DEVICE [--count N]      N snapshots at 10 Hz (default 1)
// DEVICE is a device UUID or its exact name.

import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String), engine(String), timeout, notFound(String)
    var description: String {
        switch self {
        case .usage(let s): return "usage: \(s)"
        case .engine(let s): return "engine error: \(s)"
        case .timeout: return "timed out waiting for the engine (is io.soundrouter.engine running?)"
        case .notFound(let s): return "device not found: \(s)"
        }
    }
}

final class EngineClient {
    private let connection: NSXPCConnection
    private let timeout: TimeInterval = 5

    init() {
        connection = NSXPCConnection(machServiceName: engineMachServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: EngineXPCProtocol.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    /// Runs one XPC call synchronously.
    private func call<T>(_ body: (EngineXPCProtocol, @escaping (T) -> Void) -> Void) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        var failure: Error?
        let proxy = connection.remoteObjectProxyWithErrorHandler { err in
            failure = err
            sem.signal()
        }
        guard let engine = proxy as? EngineXPCProtocol else { throw CLIError.engine("bad proxy") }
        body(engine) { value in
            result = value
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw CLIError.timeout }
        if let failure { throw CLIError.engine(failure.localizedDescription) }
        guard let result else { throw CLIError.engine("no reply") }
        return result
    }

    func hello() throws -> Int {
        try call { e, r in e.hello(clientProtocolVersion: engineProtocolVersion, reply: r) }
    }
    func configData() throws -> Data { try call { e, r in e.getConfig(reply: r) } }
    func config() throws -> RouterConfig { try SRJSON.decode(RouterConfig.self, configData()) }
    func statusData() throws -> Data { try call { e, r in e.getStatus(reply: r) } }
    func status() throws -> EngineStatus { try SRJSON.decode(EngineStatus.self, statusData()) }
    func metersData(_ id: UUID) throws -> Data {
        try call { e, r in e.getMeters(deviceID: id.uuidString, reply: r) }
    }

    @discardableResult
    func perform(_ command: ConfigCommand) throws -> CommandResult {
        let data: Data = try call { e, r in e.perform(command: SRJSON.encode(command), reply: r) }
        let result = try SRJSON.decode(CommandResult.self, data)
        if !result.ok { throw CLIError.engine(result.error ?? "command refused") }
        return result
    }

    func resolveDevice(_ key: String) throws -> VirtualDevice {
        let cfg = try config()
        if let id = UUID(uuidString: key), let d = cfg.devices.first(where: { $0.id == id }) { return d }
        if let d = cfg.devices.first(where: { $0.name == key }) { return d }
        throw CLIError.notFound(key)
    }
}

func printData(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Returns the value following `flag` in `args` and removes both.
func takeOption(_ flag: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func takeFlag(_ flag: String, _ args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

@main
struct SRCtl {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("usage: srctl hello|status|config|devices|underruns|create-device|delete-device|add-app|add-input|meters ...\n".utf8))
            exit(2)
        }
        let cmd = args.removeFirst()
        do {
            try run(cmd, &args)
        } catch {
            FileHandle.standardError.write(Data("srctl: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ cmd: String, _ args: inout [String]) throws {
        let client = EngineClient()
        switch cmd {
        case "hello":
            let v = try client.hello()
            print("engine protocol \(v) (client \(engineProtocolVersion))")
            if v != engineProtocolVersion { exit(3) }

        case "status":
            printData(try client.statusData())

        case "config":
            printData(try client.configData())

        case "devices":
            for d in try client.config().devices {
                print("\(d.id.uuidString)\t\(d.name)\t\(Int(d.sampleRate))\t\(d.outputChannelCount)")
            }

        case "underruns":
            let cfg = try client.config()
            let names = Dictionary(uniqueKeysWithValues: cfg.devices.map { ($0.id, $0.name) })
            for d in try client.status().devices {
                print("\(d.id.uuidString)\t\(names[d.id] ?? "?")\t\(d.underruns)")
            }

        case "create-device":
            let rate = takeOption("--rate", &args).flatMap(Double.init)
            let channels = takeOption("--channels", &args).flatMap(Int.init)
            guard let name = args.first else { throw CLIError.usage("srctl create-device NAME [--rate R] [--channels N]") }
            let res = try client.perform(.createDevice(name: name))
            guard let id = res.createdID else { throw CLIError.engine("no createdID in reply") }
            if let rate { try client.perform(.setDeviceSampleRate(id: id, sampleRate: rate)) }
            if let channels { try client.perform(.setDeviceChannelCount(id: id, count: channels)) }
            print(id.uuidString)

        case "delete-device":
            guard let key = args.first else { throw CLIError.usage("srctl delete-device DEVICE") }
            try client.perform(.deleteDevice(id: try client.resolveDevice(key).id))

        case "add-app":
            let pid = takeOption("--pid", &args).flatMap(Int32.init)
            let path = takeOption("--path", &args)
            let noMute = takeFlag("--no-mute", &args)
            guard let key = args.first else {
                throw CLIError.usage("srctl add-app DEVICE (BUNDLEID | --pid PID | --path EXE) [--no-mute]")
            }
            let bundleID = args.count > 1 ? args[1] : nil
            guard bundleID != nil || pid != nil || path != nil else {
                throw CLIError.usage("srctl add-app DEVICE (BUNDLEID | --pid PID | --path EXE)")
            }
            let dev = try client.resolveDevice(key)
            let app = ApplicationSource(bundleID: bundleID, pid: pid, executablePath: path,
                                        muteWhenCapturing: !noMute)
            let display = bundleID ?? path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid!)"
            let src = Source.application(app, displayName: display)
            try client.perform(.addSource(deviceID: dev.id, source: src))
            print(src.id.uuidString)

        case "add-input":
            guard args.count >= 3 else { throw CLIError.usage("srctl add-input DEVICE INPUT_UID CH[,CH...]") }
            let dev = try client.resolveDevice(args[0])
            let chans = args[2].split(separator: ",").compactMap { Int($0) }
            let src = Source.inputDevice(InputDeviceSource(deviceUID: args[1], channels: chans),
                                         displayName: args[1])
            try client.perform(.addSource(deviceID: dev.id, source: src))
            print(src.id.uuidString)

        case "meters":
            let count = takeOption("--count", &args).flatMap(Int.init) ?? 1
            guard let key = args.first else { throw CLIError.usage("srctl meters DEVICE [--count N]") }
            let dev = try client.resolveDevice(key)
            for i in 0..<max(1, count) {
                let snap = try SRJSON.decode(MeterSnapshot.self, client.metersData(dev.id))
                let outs = snap.outputs.map { String(format: "%.3f", $0) }.joined(separator: " ")
                print("out: \(outs)")
                for (sid, peaks) in snap.sources {
                    print("  src \(sid.uuidString): " + peaks.map { String(format: "%.3f", $0) }.joined(separator: " "))
                }
                if i + 1 < count { Thread.sleep(forTimeInterval: 0.1) }
            }

        default:
            throw CLIError.usage("unknown command '\(cmd)'")
        }
    }
}

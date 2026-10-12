import Foundation
import SoundRouterKit

/// Errors surfaced by an engine backend.
enum EngineError: Error, LocalizedError {
    case notConnected
    case timeout
    case xpc(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The SoundRouter engine is not running."
        case .timeout: return "The SoundRouter engine did not answer in time."
        case .xpc(let message): return "Connection to the engine failed: \(message)"
        case .decode(let message): return "Unexpected reply from the engine: \(message)"
        }
    }
}

/// Abstraction over the engine so the UI can run against the real XPC service or an
/// in-process fake (SOUNDROUTER_OFFLINE=1, see OfflineEngine.swift).
protocol EngineBackend: AnyObject {
    /// Called (on any queue) when the underlying connection is interrupted or invalidated.
    var onConnectionLost: (@Sendable () -> Void)? { get set }
    /// Drops the current connection; the next call opens a fresh one.
    func reset()

    func hello() async throws -> Int
    func getConfig() async throws -> RouterConfig
    func perform(_ command: ConfigCommand) async throws -> CommandResult
    func getStatus() async throws -> EngineStatus
    func getMeters(deviceID: UUID) async throws -> MeterSnapshot
}

/// Resumes a checked continuation at most once (XPC reply, error handler and timeout race).
private final class OnceContinuation<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// Talks to the engine LaunchAgent over its Mach service.
final class XPCEngineBackend: EngineBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    var onConnectionLost: (@Sendable () -> Void)?

    deinit { connection?.invalidate() }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: engineMachServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: EngineXPCProtocol.self)
        c.interruptionHandler = { [weak self] in
            // Engine crashed or was restarted by launchd; the connection object stays usable.
            self?.onConnectionLost?()
        }
        c.invalidationHandler = { [weak self, weak c] in
            guard let self else { return }
            self.lock.lock()
            let wasCurrent = self.connection === c
            if wasCurrent { self.connection = nil }
            self.lock.unlock()
            if wasCurrent { self.onConnectionLost?() }
        }
        c.resume()
        connection = c
        return c
    }

    func reset() {
        lock.lock()
        let c = connection
        connection = nil
        lock.unlock()
        c?.invalidate()
    }

    private func call<T>(timeout: TimeInterval = 3,
                         _ body: @escaping (EngineXPCProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        let conn = currentConnection()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = OnceContinuation(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(EngineError.xpc(error.localizedDescription)))
            }
            guard let engine = proxy as? EngineXPCProtocol else {
                once.resume(.failure(EngineError.notConnected))
                return
            }
            body(engine) { value in once.resume(.success(value)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(EngineError.timeout))
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try SRJSON.decode(type, data)
        } catch {
            throw EngineError.decode(String(describing: error))
        }
    }

    func hello() async throws -> Int {
        try await call { engine, reply in
            engine.hello(clientProtocolVersion: engineProtocolVersion, reply: reply)
        }
    }

    func getConfig() async throws -> RouterConfig {
        let data: Data = try await call { engine, reply in engine.getConfig(reply: reply) }
        return try decode(RouterConfig.self, data)
    }

    func perform(_ command: ConfigCommand) async throws -> CommandResult {
        let payload = SRJSON.encode(command)
        let data: Data = try await call(timeout: 10) { engine, reply in
            engine.perform(command: payload, reply: reply)
        }
        return try decode(CommandResult.self, data)
    }

    func getStatus() async throws -> EngineStatus {
        let data: Data = try await call { engine, reply in engine.getStatus(reply: reply) }
        return try decode(EngineStatus.self, data)
    }

    func getMeters(deviceID: UUID) async throws -> MeterSnapshot {
        let id = deviceID.uuidString
        let data: Data = try await call(timeout: 1) { engine, reply in
            engine.getMeters(deviceID: id, reply: reply)
        }
        return try decode(MeterSnapshot.self, data)
    }
}

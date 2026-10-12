import Foundation
import Security
import SoundRouterKit

/// Exported object: decodes JSON payloads and forwards to the controller on its queue.
final class EngineXPCHandler: NSObject, EngineXPCProtocol {
    private let controller: EngineController

    init(controller: EngineController) {
        self.controller = controller
    }

    func hello(clientProtocolVersion: Int, reply: @escaping (Int) -> Void) {
        if clientProtocolVersion != engineProtocolVersion {
            Log.warning("Client protocol \(clientProtocolVersion) != engine protocol \(engineProtocolVersion)")
        }
        reply(engineProtocolVersion)
    }

    func getConfig(reply: @escaping (Data) -> Void) {
        controller.queue.async { reply(SRJSON.encode(self.controller.store.config)) }
    }

    func perform(command: Data, reply: @escaping (Data) -> Void) {
        let decoded: ConfigCommand
        do {
            decoded = try SRJSON.decode(ConfigCommand.self, command)
        } catch {
            reply(SRJSON.encode(CommandResult(ok: false, error: "Malformed command: \(error)")))
            return
        }
        controller.queue.async { reply(SRJSON.encode(self.controller.perform(decoded))) }
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        controller.queue.async { reply(SRJSON.encode(self.controller.status())) }
    }

    func getMeters(deviceID: String, reply: @escaping (Data) -> Void) {
        guard let id = UUID(uuidString: deviceID) else {
            reply(SRJSON.encode(MeterSnapshot(deviceID: UUID(uuid: UUID_NULL), sources: [:], outputs: [])))
            return
        }
        controller.queue.async { reply(SRJSON.encode(self.controller.meters(deviceID: id))) }
    }
}

/// NSXPCListener on the LaunchAgent's Mach service with caller verification.
final class XPCService: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let handler: EngineXPCHandler
    /// Team ID of the engine's own signature (nil when ad-hoc signed / unsigned).
    private let teamID: String?

    static let appIdentifier = "io.soundrouter.app"
    /// Identifiers accepted from ad-hoc / linker-signed dev builds (`swift build` uses the product name).
    static let devIdentifiers: Set<String> = ["io.soundrouter.app", "SoundRouter"]

    init(controller: EngineController) {
        listener = NSXPCListener(machServiceName: engineMachServiceName)
        handler = EngineXPCHandler(controller: controller)
        teamID = XPCService.ownTeamID()
        super.init()
        listener.delegate = self
        if let teamID {
            Log.info("XPC: requiring callers signed by team \(teamID)")
        } else {
            Log.warning("XPC: engine is not signed with a Team ID (dev build); accepting same-uid callers only")
        }
    }

    func resume() {
        listener.resume()
        Log.info("XPC listening on \(engineMachServiceName)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else {
            Log.warning("XPC: rejected connection from uid \(connection.effectiveUserIdentifier)")
            return false
        }
        if let teamID {
            // Same Team ID (spec: "même Team ID"), Apple-anchored Developer ID / development cert.
            let req = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
            connection.setCodeSigningRequirement(req)
        } else {
            let pid = connection.processIdentifier
            if let ident = XPCService.signingIdentifier(pid: pid) {
                guard XPCService.devIdentifiers.contains(ident) else {
                    Log.warning("XPC: rejected dev connection from pid \(pid) (identifier \(ident))")
                    return false
                }
            } else {
                Log.warning("XPC: could not read signing identifier of pid \(pid); accepting same-uid caller")
            }
        }
        connection.exportedInterface = NSXPCInterface(with: EngineXPCProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        Log.debug("XPC: accepted connection from pid \(connection.processIdentifier)")
        return true
    }

    // MARK: Code signing helpers

    private static func signingInfo(_ code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let sc = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code, let info = signingInfo(code) else { return nil }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    /// Dev builds only (pid-based lookup is racy; signed builds use setCodeSigningRequirement).
    static func signingIdentifier(pid: pid_t) -> String? {
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code,
              let info = signingInfo(code) else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }
}

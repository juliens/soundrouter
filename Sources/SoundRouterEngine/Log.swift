import Foundation
import os
import SoundRouterKit

/// Thin wrapper around os.Logger (subsystem io.soundrouter.engine) with a runtime level taken
/// from `EngineSettings.logLevel`. Never call from an audio thread.
enum Log {
    private static let logger = Logger(subsystem: "io.soundrouter.engine", category: "engine")

    /// Current threshold. Mutated only from the control queue (and at startup).
    static var level: LogLevel = .info
    /// Mirror messages on stderr (selftest / `SOUNDROUTER_LOG_STDERR=1`).
    static var mirrorToStderr = ProcessInfo.processInfo.environment["SOUNDROUTER_LOG_STDERR"] == "1"

    private static func rank(_ l: LogLevel) -> Int {
        switch l {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        case .debug: return 3
        }
    }

    private static func enabled(_ l: LogLevel) -> Bool { rank(l) <= rank(level) }

    private static func mirror(_ tag: String, _ message: String) {
        guard mirrorToStderr else { return }
        FileHandle.standardError.write(Data("[\(tag)] \(message)\n".utf8))
    }

    static func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        mirror("error", m)
    }

    static func warning(_ message: @autoclosure () -> String) {
        guard enabled(.warning) else { return }
        let m = message()
        logger.warning("\(m, privacy: .public)")
        mirror("warn", m)
    }

    static func info(_ message: @autoclosure () -> String) {
        guard enabled(.info) else { return }
        let m = message()
        logger.info("\(m, privacy: .public)")
        mirror("info", m)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled(.debug) else { return }
        let m = message()
        logger.debug("\(m, privacy: .public)")
        mirror("debug", m)
    }
}

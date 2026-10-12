import AppKit
import Foundation
import ServiceManagement
import SoundRouterKit

/// Deep links into System Settings.
enum SystemSettingsLink {
    static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    static let audioCapture = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    @MainActor static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Runs the privileged scripts shipped in Contents/Resources.
enum PrivilegedScript {
    enum Failure: Error, LocalizedError {
        case scriptMissing(String)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing(let name): return "\(name) was not found in the application bundle."
            case .cancelled: return "The operation was cancelled."
            case .failed(let message): return message
            }
        }
    }

    /// Runs `Contents/Resources/<name>` with administrator privileges via NSAppleScript
    /// ("do shell script … with administrator privileges" shows the system auth prompt).
    @MainActor
    static func run(_ name: String) async throws {
        guard let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                        withExtension: (name as NSString).pathExtension) else {
            throw Failure.scriptMissing(name)
        }
        // Let SwiftUI render the "working" state before the modal auth prompt blocks the main thread.
        try? await Task.sleep(for: .milliseconds(100))
        let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "/bin/bash \(quoted)"
        let source = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            if code == -128 { throw Failure.cancelled }
            throw Failure.failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "The script failed.")
        }
    }
}

enum DriverInstaller {
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: SRPaths.driverBundle.path)
    }

    /// Installs the HAL driver (copies the bundle, restarts coreaudiod). Prompts for admin rights.
    @MainActor
    static func install() async throws {
        try await PrivilegedScript.run("install-driver.sh")
    }

    /// Removes driver, agent and configuration (uninstall.sh), after unregistering login items.
    @MainActor
    static func uninstall() async throws {
        try? await EngineAgent.service.unregister()
        try? await SMAppService.mainApp.unregister()
        try await PrivilegedScript.run("uninstall.sh")
    }
}

/// The engine LaunchAgent registered through SMAppService.
enum EngineAgent {
    static var service: SMAppService { SMAppService.agent(plistName: engineLaunchAgentPlistName) }

    private static var repairAttempted = false

    /// Replacing the app bundle (rebuild, update) invalidates the launchd job: it stays
    /// "enabled" but can no longer spawn the engine. Re-register once per app launch when the
    /// engine is unreachable while the agent claims to be enabled.
    @MainActor
    static func repairRegistrationOnce() {
        guard !repairAttempted, ProcessInfo.processInfo.environment["SOUNDROUTER_OFFLINE"] != "1" else { return }
        let setupDone = UserDefaults.standard.bool(forKey: AppInfo.firstLaunchKey)
        switch service.status {
        case .enabled:
            repairAttempted = true
            Task {
                try? await service.unregister()
                try? service.register()
            }
        case .notRegistered where setupDone:
            // App moved (e.g. installed into /Applications) after setup: register from here.
            repairAttempted = true
            try? service.register()
        default:
            break
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires approval in Login Items"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found (run from the app bundle)"
        @unknown default: return "Unknown"
        }
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    static let firstLaunchKey = "firstLaunchCompleted"
}

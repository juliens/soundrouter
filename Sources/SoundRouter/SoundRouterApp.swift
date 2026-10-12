import AppKit
import SoundRouterKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (dev); harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Dev hook: SOUNDROUTER_SNAPSHOT=/path.png renders the main window to a PNG and quits.
        if let path = ProcessInfo.processInfo.environment["SOUNDROUTER_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }

    // The engine keeps running without the app (F15), so quitting with the window is fine.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SoundRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var client = EngineClient()
    @State private var catalog = SourceCatalog()
    @State private var ui = UIState()

    var body: some Scene {
        Window("SoundRouter", id: "main") {
            MainView()
                .environment(client)
                .environment(catalog)
                .environment(ui)
                .task { client.start() }
        }
        .defaultSize(width: 1220, height: 760)
        .commands {
            AppCommands(client: client, ui: ui)
        }

        Settings {
            SettingsView()
                .environment(client)
                .environment(ui)
        }

        Window("About SoundRouter", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

/// Small shared UI state (selection, assistant visibility).
@Observable
@MainActor
final class UIState {
    var selectedDeviceID: UUID?
    var showAssistant = false
}

struct AppCommands: Commands {
    let client: EngineClient
    let ui: UIState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SoundRouter") { openWindow(id: "about") }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Device") {
                Task {
                    let name = DeviceNaming.nextName(in: client.config)
                    if let r = await client.perform(.createDevice(name: name)), let id = r.createdID {
                        ui.selectedDeviceID = id
                    }
                }
            }
            .keyboardShortcut("n")
            .disabled(client.engineState != .connected)
        }
        CommandGroup(replacing: .help) {
            Button("Setup Assistant…") { ui.showAssistant = true }
        }
    }
}

enum DeviceNaming {
    static func nextName(in config: RouterConfig) -> String {
        let names = Set(config.devices.map(\.name))
        if !names.contains("Virtual Device") { return "Virtual Device" }
        var i = 2
        while names.contains("Virtual Device \(i)") { i += 1 }
        return "Virtual Device \(i)"
    }
}

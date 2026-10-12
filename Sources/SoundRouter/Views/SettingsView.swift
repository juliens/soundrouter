import AppKit
import ServiceManagement
import SoundRouterKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EngineSettingsPane().tabItem { Label("Engine", systemImage: "cpu") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

/// Launch at login + engine agent registration.
struct GeneralSettings: View {
    @Environment(EngineClient.self) private var client
    @State private var mainStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var agentStatus: SMAppService.Status = EngineAgent.service.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open SoundRouter at login", isOn: Binding(
                    get: { mainStatus == .enabled },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch { self.error = error.localizedDescription }
                        refresh()
                    }))
                Text("Virtual devices keep working without the app; this only opens the editor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Background engine") {
                LabeledContent("Login item", value: EngineAgent.describe(agentStatus))
                LabeledContent("Connection", value: connectionText)
                if let v = client.status?.engineVersion { LabeledContent("Engine version", value: v) }
                HStack {
                    if agentStatus != .enabled {
                        Button("Register Engine") {
                            do { try EngineAgent.service.register() } catch { self.error = error.localizedDescription }
                            refresh()
                            client.reconnect()
                        }
                    }
                    if agentStatus == .requiresApproval || agentStatus == .notRegistered {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Button("Reconnect") { client.reconnect() }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var connectionText: String {
        switch client.engineState {
        case .connected: return client.isOffline ? "Offline (fake engine)" : "Connected"
        case .connecting: return "Connecting…"
        case .notRunning: return "Not running"
        case .versionMismatch(let v): return "Protocol mismatch (engine \(v))"
        }
    }

    private func refresh() {
        mainStatus = SMAppService.mainApp.status
        agentStatus = EngineAgent.service.status
    }
}

/// Log level and mix cycle size (engine settings).
struct EngineSettingsPane: View {
    @Environment(EngineClient.self) private var client
    static let cycleSizes = [64, 128, 256, 512, 1024]

    var body: some View {
        let settings = client.config.settings
        Form {
            Picker("Mix cycle", selection: Binding(get: { settings.cycleFrames }, set: { v in
                var s = settings
                s.cycleFrames = v
                client.send(.updateSettings(s))
            })) {
                ForEach(Self.cycleSizes, id: \.self) { n in Text("\(n) frames").tag(n) }
            }
            Text("Smaller cycles lower latency but cost more CPU. Default: 256 frames.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Log level", selection: Binding(get: { settings.logLevel }, set: { v in
                var s = settings
                s.logLevel = v
                client.send(.updateSettings(s))
            })) {
                ForEach(LogLevel.allCases, id: \.self) { l in Text(l.rawValue.capitalized).tag(l) }
            }
        }
        .formStyle(.grouped)
        .disabled(client.engineState != .connected)
    }
}

/// Import / export (F16) and uninstall.
struct AdvancedSettings: View {
    @Environment(EngineClient.self) private var client
    @State private var confirmUninstall = false
    @State private var confirmImport: RouterConfig?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Configuration") {
                HStack {
                    Button("Export…", action: exportConfig)
                    Button("Import…", action: importConfig)
                        .disabled(client.engineState != .connected)
                }
                Text("Import replaces every virtual device.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Uninstall") {
                Button("Uninstall SoundRouter…", role: .destructive) { confirmUninstall = true }
                    .disabled(working)
                Text("Removes the driver, the background engine and the configuration. Requires an administrator password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $confirmUninstall) {
            UninstallConfirmation(working: $working) { result in
                message = result
            }
        }
        .confirmationDialog("Replace the current configuration?",
                            isPresented: Binding(get: { confirmImport != nil }, set: { if !$0 { confirmImport = nil } }),
                            titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                if let cfg = confirmImport {
                    Task {
                        if let r = await client.perform(.replaceConfig(cfg)), r.ok { message = "Configuration imported." }
                    }
                }
                confirmImport = nil
            }
        } message: {
            Text("\(confirmImport?.devices.count ?? 0) device(s) will replace the current ones.")
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SoundRouter.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SRJSON.encoder.encode(client.config).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            client.lastError = error.localizedDescription
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            // The engine validates and migrates on replaceConfig; decode here to catch garbage early.
            confirmImport = try SRJSON.decode(RouterConfig.self, data)
        } catch {
            client.lastError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

struct UninstallConfirmation: View {
    @Binding var working: Bool
    var onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Uninstall SoundRouter?", systemImage: "trash")
                .font(.title3.weight(.semibold))
            Text("""
            This removes:
            • the audio driver (coreaudiod will restart; audio may cut briefly),
            • the background engine and its login item,
            • your virtual devices and configuration.
            Applications using a SoundRouter device will switch to another device.
            """)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Uninstalling…" : "Uninstall", role: .destructive) {
                    working = true
                    Task {
                        do {
                            try await DriverInstaller.uninstall()
                            NSApp.terminate(nil)
                        } catch PrivilegedScript.Failure.cancelled {
                            onDone("Uninstall cancelled.")
                        } catch {
                            onDone(error.localizedDescription)
                        }
                        working = false
                        dismiss()
                    }
                }
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

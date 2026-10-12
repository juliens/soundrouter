import SoundRouterKit
import SwiftUI

struct MainView: View {
    @Environment(EngineClient.self) private var client
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        NavigationSplitView {
            DeviceSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                BannerStack()
                if let device = client.device(ui.selectedDeviceID) {
                    DeviceDetailView(device: device)
                        .id(device.id)
                } else {
                    EmptyDetailView()
                }
            }
        }
        .onAppear {
            client.windowVisible = true
            if !client.isOffline,
               !UserDefaults.standard.bool(forKey: AppInfo.firstLaunchKey) || !DriverInstaller.isInstalled {
                ui.showAssistant = true
            }
        }
        .onDisappear { client.windowVisible = false }
        .onChange(of: ui.selectedDeviceID, initial: true) { _, id in
            client.meteredDeviceID = id
        }
        .onChange(of: client.config.devices.map(\.id)) { _, ids in
            if let sel = ui.selectedDeviceID, !ids.contains(sel) { ui.selectedDeviceID = ids.first }
            if ui.selectedDeviceID == nil { ui.selectedDeviceID = ids.first }
        }
        .sheet(isPresented: $ui.showAssistant) {
            FirstLaunchAssistant()
        }
        .alert("SoundRouter", isPresented: Binding(get: { client.lastError != nil },
                                                   set: { if !$0 { client.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(client.lastError ?? "")
        }
    }
}

struct EmptyDetailView: View {
    @Environment(EngineClient.self) private var client

    var body: some View {
        ContentUnavailableView {
            Label(client.config.devices.isEmpty ? "No Virtual Device" : "No Selection",
                  systemImage: "hifispeaker.2")
        } description: {
            Text(client.config.devices.isEmpty
                 ? "Create a virtual device to combine applications and inputs into one microphone."
                 : "Select a device in the sidebar.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar (F1)

struct DeviceSidebar: View {
    @Environment(EngineClient.self) private var client
    @Environment(UIState.self) private var ui
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deleteCandidate: VirtualDevice?

    var body: some View {
        @Bindable var ui = ui
        List(selection: $ui.selectedDeviceID) {
            Section("Devices") {
                ForEach(client.config.devices) { device in
                    row(device)
                        .tag(device.id)
                        .contextMenu { contextMenu(device) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    createDevice()
                } label: {
                    Label("New Device", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(client.engineState != .connected)
                Spacer()
                EngineStateIndicator()
            }
            .padding(10)
        }
        .confirmationDialog("Delete \(deleteCandidate?.name ?? "device")?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleteCandidate { client.send(.deleteDevice(id: d.id)) }
                deleteCandidate = nil
            }
        } message: {
            Text("Applications using this device will lose it.")
        }
    }

    @ViewBuilder
    private func row(_ device: VirtualDevice) -> some View {
        HStack {
            Image(systemName: device.hasPassThru ? "speaker.wave.2.circle" : "mic.circle")
                .foregroundStyle(device.enabled ? Color.accentColor : .secondary)
            if renamingID == device.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(device) }
                    .onExitCommand { renamingID = nil }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).lineLimit(1)
                    Text("\(device.outputChannelCount) ch · \(SampleRateFormat.string(device.sampleRate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { device.enabled },
                                            set: { client.send(.setDeviceEnabled(id: device.id, enabled: $0)) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Enable \(device.name)")
        }
        .opacity(device.enabled ? 1 : 0.6)
    }

    @ViewBuilder
    private func contextMenu(_ device: VirtualDevice) -> some View {
        Button("Rename") {
            renameText = device.name
            renamingID = device.id
        }
        Button("Duplicate") {
            Task {
                if let r = await client.perform(.duplicateDevice(id: device.id)), let id = r.createdID {
                    ui.selectedDeviceID = id
                }
            }
        }
        Divider()
        Button(device.enabled ? "Disable" : "Enable") {
            client.send(.setDeviceEnabled(id: device.id, enabled: !device.enabled))
        }
        Divider()
        Button("Delete…", role: .destructive) { deleteCandidate = device }
    }

    private func commitRename(_ device: VirtualDevice) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingID = nil
        guard !name.isEmpty, name != device.name else { return }
        client.send(.renameDevice(id: device.id, name: name))
    }

    private func createDevice() {
        Task {
            if let r = await client.perform(.createDevice(name: DeviceNaming.nextName(in: client.config))),
               let id = r.createdID {
                ui.selectedDeviceID = id
            }
        }
    }
}

struct EngineStateIndicator: View {
    @Environment(EngineClient.self) private var client

    var body: some View {
        let (color, text): (Color, String) = {
            switch client.engineState {
            case .connected: return (.green, client.isOffline ? "Offline mode" : "Engine running")
            case .connecting: return (.yellow, "Connecting…")
            case .notRunning: return (.red, "Engine stopped")
            case .versionMismatch: return (.orange, "Version mismatch")
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum SampleRateFormat {
    static func string(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }
}

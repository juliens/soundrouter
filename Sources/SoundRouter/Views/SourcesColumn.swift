import AppKit
import SoundRouterKit
import SwiftUI
import UniformTypeIdentifiers

struct SourcesColumn: View {
    let device: VirtualDevice
    let routing: RoutingActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sources").font(.headline)
                Spacer()
                AddSourceMenu(device: device)
            }
            .frame(height: 22)
            if device.sources.isEmpty {
                Text("No sources. Use + to add an application, an input device or Pass-Thru.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            ForEach(device.sources) { source in
                SourceBlock(device: device, source: source, routing: routing)
            }
        }
    }
}

// MARK: - "+" menu (F4, F6, F14)

struct AddSourceMenu: View {
    let device: VirtualDevice
    @Environment(EngineClient.self) private var client
    @Environment(SourceCatalog.self) private var catalog

    var body: some View {
        Menu {
            Menu("Running Applications") {
                if catalog.runningApps.isEmpty { Text("None") }
                ForEach(catalog.runningApps) { app in
                    Button {
                        addApplication(bundleID: app.bundleID, pid: app.pid, path: app.executablePath, name: app.name)
                    } label: {
                        if let icon = app.icon {
                            Label { Text(app.name) } icon: { Image(nsImage: icon) }
                        } else {
                            Text(app.name)
                        }
                    }
                    .disabled(app.bundleID.map(hasApp) ?? false)
                }
            }
            Button("Installed Application…") { chooseInstalledApplications() }
            Divider()
            Menu("Input Devices") {
                if catalog.inputDevices.isEmpty { Text("None") }
                ForEach(catalog.inputDevices) { dev in
                    Button(inputTitle(dev)) { addInputDevice(dev) }
                        .disabled(dev.uid == device.uid)
                }
            }
            Button("Pass-Thru") {
                client.send(.addSource(deviceID: device.id, source: .passThru(channels: device.outputChannelCount)))
            }
            .disabled(device.hasPassThru)
            if catalog.optionKeyHeld {
                Divider()
                Menu("Background Processes") {
                    if catalog.backgroundProcesses.isEmpty { Text("None found") }
                    ForEach(catalog.backgroundProcesses) { p in
                        Button("\(p.name)  (\(p.bundleID ?? "pid \(p.pid)"))") {
                            addApplication(bundleID: p.bundleID, pid: p.pid, path: p.executablePath, name: p.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a source (hold Option for background processes)")
        .accessibilityLabel("Add source")
        .onAppear { catalog.refreshApps() }
    }

    private func hasApp(_ bundleID: String) -> Bool {
        device.sources.contains { $0.application?.bundleID == bundleID }
    }

    private func inputTitle(_ dev: AudioDeviceInfo) -> String {
        let isRouter = client.config.devices.contains { $0.uid == dev.uid }
        return "\(dev.name) — \(dev.inputChannels) ch" + (isRouter ? " (SoundRouter)" : "")
    }

    private func addApplication(bundleID: String?, pid: Int32?, path: String?, name: String) {
        let app = bundleID != nil
            ? ApplicationSource(bundleID: bundleID)
            : ApplicationSource(pid: pid, executablePath: path)
        client.send(.addSource(deviceID: device.id, source: .application(app, displayName: name)))
    }

    private func addInputDevice(_ dev: AudioDeviceInfo) {
        let channels = Array(0..<min(dev.inputChannels, maxOutputChannels))
        client.send(.addSource(deviceID: device.id,
                               source: .inputDevice(InputDeviceSource(deviceUID: dev.uid, channels: channels),
                                                    displayName: dev.name)))
    }

    private func chooseInstalledApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                client.lastError = "\(url.lastPathComponent) has no bundle identifier."
                continue
            }
            let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
            if !hasApp(bundleID) {
                addApplication(bundleID: bundleID, pid: nil, path: nil, name: name)
            }
        }
    }
}

// MARK: - Source block (F5, F7, F8, F13)

struct SourceBlock: View {
    let device: VirtualDevice
    let source: Source
    let routing: RoutingActions
    @Environment(EngineClient.self) private var client
    @Environment(SourceCatalog.self) private var catalog
    @State private var showOptions = false

    private var state: SourceState? { client.sourceStatus(device: device.id, source: source.id)?.state }
    private var greyed: Bool {
        guard source.enabled else { return true }
        switch state {
        case .waiting, .disconnected, .permissionDenied, .error, .disabled: return true
        default: return false
        }
    }
    private var name: String { SourceNaming.name(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SourceIcon(source: source).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.medium)).lineLimit(1)
                    stateText
                }
                Spacer(minLength: 4)
                Toggle("Enabled", isOn: Binding(get: { source.enabled }, set: { v in update { $0.enabled = v } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Enable \(name)")
                Button {
                    client.send(.removeSource(deviceID: device.id, sourceID: source.id))
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove source")
                .accessibilityLabel("Remove \(name)")
            }

            // Master volume/mute of the whole source.
            VolumeControl(label: name, volume: source.volume, muted: source.muted) { v, m in
                var s = source
                s.volume = v
                s.muted = m
                client.sendCoalesced(key: "src-\(source.id)", .updateSource(deviceID: device.id, source: s))
            }

            // One strip per channel: volume, mute, meter and the connection port.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<source.channelCount, id: \.self) { ch in
                    channelStrip(ch)
                }
            }

            DisclosureGroup("Options", isExpanded: $showOptions) {
                options.padding(.top, 4)
            }
            .font(.callout)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(CableColor.color(for: source.id).opacity(greyed ? 0.2 : 0.6)))
        .opacity(greyed ? 0.6 : 1)
        .contextMenu {
            Button(source.enabled ? "Disable" : "Enable") { update { $0.enabled.toggle() } }
            Button(source.muted ? "Unmute" : "Mute") { update { $0.muted.toggle() } }
            Divider()
            Button("Remove Source", role: .destructive) {
                client.send(.removeSource(deviceID: device.id, sourceID: source.id))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source \(name)")
    }

    private func channelStrip(_ ch: Int) -> some View {
        let routed = device.routes.filter { $0.sourceID == source.id && $0.sourceChannel == ch }
        let levels = client.meters.sources[source.id] ?? []
        let label = SourceNaming.channelLabel(source, ch)
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            VolumeControl(label: "\(name) \(label)", volume: source.channelVolume(ch),
                          muted: source.isChannelMuted(ch)) { v, m in
                var s = source
                s.setChannelVolume(ch, v)
                s.setChannelMuted(ch, m)
                client.sendCoalesced(key: "src-\(source.id)-ch\(ch)", .updateSource(deviceID: device.id, source: s))
            }
            .controlSize(.mini)
            MeterBar(level: ch < levels.count ? levels[ch] : MeterLevel(), thickness: 4)
                .frame(width: 44)
            PortView(id: .source(source.id, ch), label: "Source \(name) channel \(ch + 1)",
                     connected: !routed.isEmpty, tint: CableColor.color(for: source.id))
                .contextMenu {
                    Menu("Connect to…") {
                        ForEach(0..<device.outputChannelCount, id: \.self) { o in
                            Toggle("Output \(o + 1)",
                                   isOn: Binding(get: { routing.isRouted(source: source.id, channel: ch, output: o) },
                                                 set: { _ in routing.toggleRoute(source: source.id, channel: ch, output: o) }))
                        }
                    }
                    if !routed.isEmpty {
                        Menu("Disconnect from…") {
                            ForEach(routed, id: \.self) { r in
                                Button("Output \(r.outputChannel + 1)") {
                                    routing.removeRoute(source: source.id, channel: ch, output: r.outputChannel)
                                }
                            }
                        }
                    }
                }
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var stateText: some View {
        let (text, color): (String?, Color) = {
            if !source.enabled { return ("Disabled", .secondary) }
            let st = client.sourceStatus(device: device.id, source: source.id)
            switch st?.state {
            case .waiting?: return (st?.message ?? "Waiting for the application to start", .secondary)
            case .disconnected?: return (st?.message ?? "Device disconnected", .orange)
            case .permissionDenied?: return (st?.message ?? "Permission denied", .red)
            case .error?: return (st?.message ?? "Error", .red)
            case .active?: return (kindText, .secondary)
            default: return (kindText, .secondary)
            }
        }()
        if let text {
            Text(text).font(.caption).foregroundStyle(color).lineLimit(1)
        }
    }

    private var kindText: String {
        switch source.kind {
        case .application: return "Application · stereo"
        case .inputDevice: return "Input device · \(source.channelCount) ch"
        case .passThru: return "Pass-Thru · \(source.channelCount) ch"
        }
    }

    @ViewBuilder
    private var options: some View {
        switch source.kind {
        case .application:
            Toggle("Mute application while capturing",
                   isOn: Binding(get: { source.application?.muteWhenCapturing ?? true },
                                 set: { v in update { $0.application?.muteWhenCapturing = v } }))
                .toggleStyle(.checkbox)
            if let b = source.application?.bundleID {
                Text(b).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let p = source.application?.executablePath {
                Text(p).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .inputDevice:
            inputChannelOptions
        case .passThru:
            Text("Receives what applications play to this device. Channels follow the device's output count.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inputChannelOptions: some View {
        let used = source.inputDevice?.channels ?? []
        let available = catalog.device(uid: source.inputDevice?.deviceUID ?? "")?.inputChannels
            ?? ((used.max() ?? 0) + 1)
        Text("Channels used").font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 5), alignment: .leading, spacing: 2) {
            ForEach(0..<min(available, maxOutputChannels), id: \.self) { ch in
                Toggle("\(ch + 1)", isOn: Binding(get: { used.contains(ch) }, set: { on in setInputChannel(ch, on) }))
                    .toggleStyle(.checkbox)
                    .disabled(used == [ch])
                    .accessibilityLabel("Use input channel \(ch + 1)")
            }
        }
    }

    private func setInputChannel(_ ch: Int, _ on: Bool) {
        guard var input = source.inputDevice else { return }
        let old = input.channels
        var set = Set(old)
        if on { set.insert(ch) } else { set.remove(ch) }
        guard !set.isEmpty else { return }
        input.channels = set.sorted()
        var newSource = source
        newSource.inputDevice = input
        newSource.channelCount = input.channels.count
        // Per-channel volume/mute follow their device channel.
        newSource.channelVolumes = input.channels.map { dc in old.firstIndex(of: dc).map { source.channelVolume($0) } ?? 1 }
        newSource.channelMuted = input.channels.map { dc in old.firstIndex(of: dc).map { source.isChannelMuted($0) } ?? false }
        // Remap routes: source channel i = device channel channels[i].
        let remapped: [Route] = device.routes.compactMap { r in
            guard r.sourceID == source.id else { return r }
            guard r.sourceChannel < old.count, let idx = input.channels.firstIndex(of: old[r.sourceChannel]) else { return nil }
            var r2 = r
            r2.sourceChannel = idx
            return r2
        }
        let deviceID = device.id
        Task {
            if input.channels.count < old.count {
                await client.perform(.setRoutes(deviceID: deviceID, routes: remapped))
                await client.perform(.updateSource(deviceID: deviceID, source: newSource))
            } else {
                await client.perform(.updateSource(deviceID: deviceID, source: newSource))
                await client.perform(.setRoutes(deviceID: deviceID, routes: remapped))
            }
        }
    }

    private func update(_ change: (inout Source) -> Void) {
        var s = source
        change(&s)
        client.send(.updateSource(deviceID: device.id, source: s))
    }
}

struct SourceMeter: View {
    let sourceID: UUID
    let channels: Int
    @Environment(EngineClient.self) private var client

    var body: some View {
        MeterStack(levels: client.meters.sources[sourceID] ?? [], channels: channels)
    }
}

struct SourceIcon: View {
    let source: Source

    var body: some View {
        switch source.kind {
        case .application:
            if let icon = Self.appIcon(source.application) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        case .inputDevice:
            Image(systemName: "mic").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
        case .passThru:
            Image(systemName: "arrow.left.arrow.right.circle").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    static func appIcon(_ app: ApplicationSource?) -> NSImage? {
        if let b = app?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let p = app?.executablePath { return NSWorkspace.shared.icon(forFile: p) }
        return nil
    }
}

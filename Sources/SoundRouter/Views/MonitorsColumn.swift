import SoundRouterKit
import SwiftUI

/// Monitors (F11): listen to all or part of the device on a physical output.
struct MonitorsColumn: View {
    let device: VirtualDevice
    let routing: RoutingActions
    @Environment(EngineClient.self) private var client
    @Environment(SourceCatalog.self) private var catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monitors").font(.headline)
                Spacer()
                Menu {
                    let outputs = catalog.outputDevices.filter { dev in
                        !client.config.devices.contains { $0.uid == dev.uid }
                    }
                    if outputs.isEmpty { Text("No output devices") }
                    ForEach(outputs) { dev in
                        Button("\(dev.name) — \(dev.outputChannels) ch") { addMonitor(dev) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Listen to this device on an output")
                .accessibilityLabel("Add monitor")
            }
            .frame(height: 22)
            if device.monitors.isEmpty {
                Text("No monitor. Use + to listen to this device on speakers or headphones.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            ForEach(device.monitors) { monitor in
                MonitorBlock(device: device, monitor: monitor, routing: routing)
            }
        }
    }

    private func addMonitor(_ dev: AudioDeviceInfo) {
        let n = min(device.outputChannelCount, dev.outputChannels)
        let routes = (0..<n).map { MonitorRoute(deviceChannel: $0, monitorChannel: $0) }
        client.send(.addMonitor(deviceID: device.id,
                                monitor: Monitor(deviceUID: dev.uid, displayName: dev.name, routes: routes)))
    }
}

struct MonitorBlock: View {
    let device: VirtualDevice
    let monitor: Monitor
    let routing: RoutingActions
    @Environment(EngineClient.self) private var client

    private var name: String { monitor.displayName.isEmpty ? monitor.deviceUID : monitor.displayName }
    private var state: SourceState? { client.monitorStatus(device: device.id, monitor: monitor.id)?.state }
    private var greyed: Bool { !monitor.enabled || state == .disconnected || state == .error }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "headphones").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.medium)).lineLimit(1)
                    Text(stateText).font(.caption)
                        .foregroundStyle(state == .disconnected || state == .error ? Color.orange : .secondary)
                }
                Spacer(minLength: 4)
                Toggle("Enabled", isOn: Binding(get: { monitor.enabled }, set: { v in update { $0.enabled = v } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Enable monitor \(name)")
                Button {
                    client.send(.removeMonitor(deviceID: device.id, monitorID: monitor.id))
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove monitor")
                .accessibilityLabel("Remove monitor \(name)")
            }
            VolumeControl(label: "Monitor \(name)", volume: monitor.volume, muted: monitor.muted) { v, m in
                var mon = monitor
                mon.volume = v
                mon.muted = m
                client.sendCoalesced(key: "mon-\(monitor.id)", .updateMonitor(deviceID: device.id, monitor: mon))
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<routing.monitorChannelCount(monitor), id: \.self) { ch in
                    monitorPort(ch)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .opacity(greyed ? 0.6 : 1)
        .contextMenu {
            Button(monitor.enabled ? "Disable" : "Enable") { update { $0.enabled.toggle() } }
            Button("Remove Monitor", role: .destructive) {
                client.send(.removeMonitor(deviceID: device.id, monitorID: monitor.id))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monitor \(name)")
    }

    private var stateText: String {
        if !monitor.enabled { return "Disabled" }
        switch state {
        case .disconnected?: return "Device disconnected"
        case .error?: return "Error"
        default: return "\(monitor.routes.count) connection\(monitor.routes.count == 1 ? "" : "s")"
        }
    }

    private func monitorPort(_ ch: Int) -> some View {
        let routed = monitor.routes.filter { $0.monitorChannel == ch }
        return HStack(spacing: 4) {
            PortView(id: .monitor(monitor.id, ch), label: "Monitor \(name) channel \(ch + 1)",
                     connected: !routed.isEmpty, tint: .secondary)
                .contextMenu {
                    Menu("Connect from…") {
                        ForEach(0..<device.outputChannelCount, id: \.self) { o in
                            Toggle("Output \(o + 1)",
                                   isOn: Binding(get: { routing.isMonitorRouted(monitor: monitor.id, deviceChannel: o, monitorChannel: ch) },
                                                 set: { _ in routing.toggleMonitorRoute(monitor: monitor.id, deviceChannel: o, monitorChannel: ch) }))
                        }
                    }
                    if !routed.isEmpty {
                        Menu("Disconnect from…") {
                            ForEach(routed, id: \.self) { r in
                                Button("Output \(r.deviceChannel + 1)") {
                                    routing.removeMonitorRoute(monitor: monitor.id, deviceChannel: r.deviceChannel, monitorChannel: ch)
                                }
                            }
                        }
                    }
                }
            Text("Ch \(ch + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(height: 22)
    }

    private func update(_ change: (inout Monitor) -> Void) {
        var m = monitor
        change(&m)
        client.send(.updateMonitor(deviceID: device.id, monitor: m))
    }
}

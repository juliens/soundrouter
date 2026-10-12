import SoundRouterKit
import SwiftUI

struct DeviceDetailView: View {
    let device: VirtualDevice
    @Environment(EngineClient.self) private var client

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader(device: device)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if !device.enabled {
                HStack(spacing: 10) {
                    Image(systemName: "power.circle.fill").foregroundStyle(.orange)
                    Text("This device is off: it is hidden from the system and nothing is captured or mixed.")
                    Spacer()
                    Button("Turn On") { client.send(.setDeviceEnabled(id: device.id, enabled: true)) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            RoutingEditor(device: device)
                .opacity(device.enabled ? 1 : 0.55)
        }
        .disabled(client.engineState != .connected)
    }
}

/// Header: editable name, sample rate (F12), global volume/mute (F8), channel count (F10).
struct DeviceHeader: View {
    let device: VirtualDevice
    @Environment(EngineClient.self) private var client
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Device name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    .accessibilityLabel("Device name")
                statusLine
            }
            .frame(minWidth: 180)

            Spacer(minLength: 8)

            Picker("Sample rate", selection: Binding(get: { device.sampleRate },
                                                     set: { client.send(.setDeviceSampleRate(id: device.id, sampleRate: $0)) })) {
                ForEach(supportedSampleRates, id: \.self) { rate in
                    Text(SampleRateFormat.string(rate)).tag(rate)
                }
            }
            .fixedSize()

            Stepper(value: Binding(get: { device.outputChannelCount },
                                   set: { client.send(.setDeviceChannelCount(id: device.id, count: $0)) }),
                    in: 1...maxOutputChannels) {
                Text("\(device.outputChannelCount) ch").monospacedDigit()
            }
            .fixedSize()
            .accessibilityLabel("Output channel count")
            .accessibilityValue("\(device.outputChannelCount)")

            VolumeControl(label: device.name, volume: device.volume, muted: device.muted) { v, m in
                client.sendCoalesced(key: "dev-vol-\(device.id)", .setDeviceVolume(id: device.id, volume: v, muted: m))
            }
            .frame(width: 180)

            Toggle("Enabled", isOn: Binding(get: { device.enabled },
                                            set: { client.send(.setDeviceEnabled(id: device.id, enabled: $0)) }))
                .toggleStyle(.switch)
                .help("Publish this device to the system")
        }
        .onAppear { name = device.name }
        .onChange(of: device.name) { _, n in if !nameFocused { name = n } }
    }

    @ViewBuilder
    private var statusLine: some View {
        let st = client.deviceStatus(device.id)
        HStack(spacing: 8) {
            if !device.enabled {
                Text("Disabled")
            } else if let st {
                Label(st.visibleInSystem ? "Visible in Sound settings" : "Not published",
                      systemImage: st.visibleInSystem ? "checkmark.circle" : "xmark.circle")
                if st.underruns > 0 { Text("\(st.underruns) underruns") }
            }
            Text(device.hasPassThru ? "Input + Output" : "Input only")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { name = device.name; return }
        if n != device.name { client.send(.renameDevice(id: device.id, name: n)) }
    }
}

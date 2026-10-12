import ServiceManagement
import SoundRouterKit
import SwiftUI

/// First-launch assistant: 1) driver, 2) background engine, 3) permissions.
struct FirstLaunchAssistant: View {
    @Environment(EngineClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var installing = false
    @State private var driverInstalled = DriverInstaller.isInstalled
    @State private var agentStatus = EngineAgent.service.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "hifispeaker.2.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Welcome to SoundRouter").font(.title2.weight(.semibold))
                    Text("Step \(step + 1) of 3").foregroundStyle(.secondary)
                }
            }
            Divider()
            Group {
                switch step {
                case 0: driverStep
                case 1: engineStep
                default: permissionsStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button("Skip Setup") { finish() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 2 {
                    Button("Continue") { error = nil; step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            driverInstalled = DriverInstaller.isInstalled
            agentStatus = EngineAgent.service.status
        }
    }

    private var driverStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Install the audio driver").font(.headline)
            Text("SoundRouter publishes its virtual devices through a Core Audio driver installed in /Library/Audio/Plug-Ins/HAL. Installing it requires an administrator password and briefly restarts the system audio service.")
                .fixedSize(horizontal: false, vertical: true)
            if driverInstalled {
                Label("Driver installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(installing ? "Installing…" : "Install Driver…") {
                    installing = true
                    Task {
                        do {
                            try await DriverInstaller.install()
                            error = nil
                        } catch PrivilegedScript.Failure.cancelled {
                        } catch {
                            self.error = error.localizedDescription
                        }
                        driverInstalled = DriverInstaller.isInstalled
                        installing = false
                    }
                }
                .disabled(installing)
            }
        }
    }

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Enable the background engine").font(.headline)
            Text("The engine mixes audio even when this window is closed and starts at login. macOS may ask you to allow it in Login Items.")
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Status", value: EngineAgent.describe(agentStatus))
            HStack {
                if agentStatus != .enabled {
                    Button("Enable Engine") {
                        do { try EngineAgent.service.register() } catch { self.error = error.localizedDescription }
                        agentStatus = EngineAgent.service.status
                        client.reconnect()
                    }
                } else {
                    Label("Engine enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if agentStatus == .requiresApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3. Permissions").font(.headline)
            Text("The engine asks for two permissions the first time it needs them:")
            Label("Audio Capture — to record the sound of applications you add as sources.", systemImage: "waveform")
            Label("Microphone — to use input devices (microphones, interfaces) as sources.", systemImage: "mic")
            Text("If you declined a prompt, allow “SoundRouter Engine” in System Settings.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Audio Capture Settings") { SystemSettingsLink.open(SystemSettingsLink.audioCapture) }
                Button("Microphone Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: AppInfo.firstLaunchKey)
        dismiss()
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("SoundRouter").font(.title.weight(.semibold))
            Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            Text("Virtual audio router for macOS").font(.callout)
            ScrollView {
                Text(License.mit)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
        }
        .padding(20)
        .frame(width: 460)
    }
}

enum License {
    static let mit = """
    MIT License

    Copyright (c) 2026 SoundRouter contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """
}

import SoundRouterKit
import SwiftUI

/// Problem banners shown above the editor: engine stopped, driver missing, permissions denied.
struct BannerStack: View {
    @Environment(EngineClient.self) private var client
    @State private var installing = false

    var body: some View {
        VStack(spacing: 6) {
            switch client.engineState {
            case .notRunning:
                Banner(icon: "bolt.slash.fill", tint: .red,
                       title: "The SoundRouter engine is not running",
                       message: "Virtual devices stay visible but silent. Allow SoundRouter in Login Items to start the background engine.") {
                    Button("Open Login Items") { SystemSettingsLink.open(SystemSettingsLink.loginItems) }
                    Button("Retry") { client.reconnect() }
                }
            case .versionMismatch(let v):
                Banner(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Engine version mismatch",
                       message: "The engine speaks protocol \(v), this app expects \(engineProtocolVersion). Reinstall SoundRouter.") {
                    EmptyView()
                }
            case .connecting, .connected:
                EmptyView()
            }

            if !client.driverInstalled {
                Banner(icon: "puzzlepiece.extension.fill", tint: .orange,
                       title: "The audio driver is not installed",
                       message: "Virtual devices cannot appear in Sound settings until the driver is installed.") {
                    Button(installing ? "Installing…" : "Install Driver…") {
                        installing = true
                        Task {
                            do { try await DriverInstaller.install() } catch PrivilegedScript.Failure.cancelled {
                            } catch { client.lastError = error.localizedDescription }
                            installing = false
                        }
                    }
                    .disabled(installing)
                }
            }

            if client.status?.audioCapturePermission == .denied {
                Banner(icon: "waveform.slash", tint: .orange,
                       title: "Audio capture permission denied",
                       message: "Application sources are silent. Allow SoundRouter Engine in Privacy & Security > Audio Capture.") {
                    Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.audioCapture) }
                }
            }
            if client.status?.microphonePermission == .denied {
                Banner(icon: "mic.slash.fill", tint: .orange,
                       title: "Microphone permission denied",
                       message: "Input device sources are silent. Allow SoundRouter Engine in Privacy & Security > Microphone.") {
                    Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, hasBanner ? 8 : 0)
    }

    private var hasBanner: Bool {
        if case .notRunning = client.engineState { return true }
        if case .versionMismatch = client.engineState { return true }
        return !client.driverInstalled || client.status?.audioCapturePermission == .denied
            || client.status?.microphonePermission == .denied
    }
}

struct Banner<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

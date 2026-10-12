import SwiftUI

/// Level meter bar (dB scale, -60…0 dBFS) with peak-hold tick.
struct MeterBar: View {
    var level: MeterLevel
    var axis: Axis = .horizontal
    var thickness: CGFloat = 5

    static func position(_ linear: Float) -> CGFloat {
        guard linear > 0 else { return 0 }
        let db = 20 * log10(Double(linear))
        return CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let fill = Self.position(level.level) * length
            let peak = Self.position(level.peak) * length
            ZStack(alignment: axis == .horizontal ? .leading : .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08))
                LinearGradient(colors: [.green, .green, .yellow, .red],
                               startPoint: axis == .horizontal ? .leading : .bottom,
                               endPoint: axis == .horizontal ? .trailing : .top)
                    .mask(alignment: axis == .horizontal ? .leading : .bottom) {
                        Rectangle().frame(width: axis == .horizontal ? fill : nil,
                                          height: axis == .vertical ? fill : nil)
                    }
                if level.peak > 0.001 {
                    Rectangle()
                        .fill(level.peak >= 0.99 ? Color.red : Color.primary.opacity(0.7))
                        .frame(width: axis == .horizontal ? 2 : nil, height: axis == .vertical ? 2 : nil)
                        .offset(x: axis == .horizontal ? max(0, peak - 2) : 0,
                                y: axis == .vertical ? -max(0, peak - 2) : 0)
                }
            }
        }
        .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(level.level > 0 ? String(format: "%.0f dB", 20 * log10(Double(level.level))) : "silent")
    }
}

/// Stack of horizontal meters, one per channel.
struct MeterStack: View {
    var levels: [MeterLevel]
    var channels: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<max(1, channels), id: \.self) { i in
                MeterBar(level: i < levels.count ? levels[i] : MeterLevel(), thickness: 4)
            }
        }
    }
}

/// Volume slider + mute toggle that keeps a local value while dragging and sends
/// coalesced updates (the engine applies gains hot).
struct VolumeControl: View {
    var label: String
    var volume: Float
    var muted: Bool
    var onChange: (_ volume: Float, _ muted: Bool) -> Void

    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onChange(Float(dragValue ?? Double(volume)), !muted)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : speakerIcon)
                    .frame(width: 18)
                    .foregroundStyle(muted ? Color.red : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(muted ? "Unmute" : "Mute")
            .accessibilityLabel(muted ? "Unmute \(label)" : "Mute \(label)")

            Slider(value: Binding(get: { dragValue ?? Double(volume) },
                                  set: { v in
                                      dragValue = v
                                      onChange(Float(v), muted)
                                  }),
                   in: 0...1,
                   onEditingChanged: { editing in if !editing { dragValue = nil } })
                .controlSize(.small)
                .accessibilityLabel("\(label) volume")
                .accessibilityValue("\(Int((dragValue ?? Double(volume)) * 100)) percent")
        }
    }

    private var speakerIcon: String {
        let v = dragValue ?? Double(volume)
        return v < 0.01 ? "speaker.fill" : v < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}

/// Stable per-source colour for cables.
enum CableColor {
    static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .mint, .indigo]

    static func color(for id: UUID) -> Color {
        let h = id.uuid.0 ^ id.uuid.5 ^ id.uuid.10 ^ id.uuid.15
        return palette[Int(h) % palette.count]
    }
}

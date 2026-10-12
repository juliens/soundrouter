// Writes a known test signal to a WAV file (Float32), for app-capture tests (afplay, browser, ...).
//
//   tone_gen OUT.wav [--rate 48000] [--seconds 10] [--freq 1000] [--kind sine|signal]
//     sine    pure sine at --freq, amplitude 0.5
//     signal  the deterministic TestSignal used by passthru_bitexact / capture_check (stereo)

import AVFoundation
import Foundation

@main
struct ToneGen {
    static func main() {
        let args = Args()
        guard let path = args.positional.first else { fail("usage: tone_gen OUT.wav [--rate R] [--seconds S] [--freq F] [--kind sine|signal]") }
        let rate = args.double("rate", 48_000)
        let seconds = args.double("seconds", 10)
        let freq = args.double("freq", 1000)
        let kind = args.string("kind") ?? "signal"
        let frames = AVAudioFrameCount(rate * seconds)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { fail("format") }
        buffer.frameLength = frames
        let signal = TestSignal(sampleRate: rate)
        for c in 0..<2 {
            let p = buffer.floatChannelData![c]
            for f in 0..<Int(frames) {
                p[f] = kind == "sine" ? Float(0.5 * sin(2 * Double.pi * freq * Double(f) / rate))
                                      : signal.sample(frame: f, channel: c)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch { fail("write \(path): \(error)") }
        print("wrote \(path): \(kind), \(Int(rate)) Hz, \(seconds) s, stereo")
    }
}

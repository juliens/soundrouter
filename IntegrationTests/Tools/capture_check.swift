// Records the input side of a SoundRouter device and correlates it with a reference file
// (spec test table "capture d'application": known signal played by a test process,
// correlation with the captured signal).
//
//   capture_check --reference tone.wav [--device SoundRouter] [--seconds 4] [--min-corr 0.9]
//
// Records --seconds from the device input (channel 0), takes a 4096-frame window with signal,
// searches it in the reference (channel 0) with a normalized cross-correlation and asserts the
// peak is >= --min-corr. Level differences (gains, volume) do not matter; resampling does a
// little (keep the file rate = device rate for a ~1.0 peak).

import Accelerate
import AVFoundation
import CoreAudio
import Foundation

final class RecState: @unchecked Sendable {
    let capacity: Int, inCh: Int
    let buf: UnsafeMutablePointer<Float>
    var pos = 0
    init(capacity: Int, inCh: Int) {
        self.capacity = capacity; self.inCh = inCh
        buf = .allocate(capacity: capacity); buf.initialize(repeating: 0, count: capacity)
    }
}

@main
struct CaptureCheck {
    static func main() {
        let args = Args()
        guard let refPath = args.string("reference") else { fail("--reference FILE required") }
        let key = args.string("device") ?? "SoundRouter"
        let seconds = args.double("seconds", 4)
        let minCorr = args.double("min-corr", 0.9)
        guard let dev = CA.find(key) else { fail("no device matching '\(key)'") }
        let rate = CA.nominalRate(dev)
        let inCh = CA.channelCount(dev, kAudioObjectPropertyScopeInput)
        guard inCh > 0 else { fail("device has no input channels") }
        print("device: \(CA.name(dev) ?? "?") rate=\(Int(rate)) in=\(inCh)")

        // Reference, channel 0.
        let ref: [Float]
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: refPath))
            let fmt = file.processingFormat
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { fail("buffer") }
            try file.read(into: b)
            ref = Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
            if fmt.sampleRate != rate { print("WARN: reference is \(Int(fmt.sampleRate)) Hz, device \(Int(rate)) Hz") }
        } catch { fail("read \(refPath): \(error)") }

        // Record channel 0.
        let state = RecState(capacity: Int(rate * seconds), inCh: inCh)
        var procID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = list.first, first.mNumberChannels > 0,
                  let p = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let n = Int(first.mNumberChannels)
            let frames = Int(first.mDataByteSize) / (4 * n)
            for f in 0..<frames where state.pos < state.capacity {
                state.buf[state.pos] = p[f * n]
                state.pos += 1
            }
        }
        guard st == noErr, let procID else { fail("IOProc: \(st)") }
        AudioDeviceStart(dev, procID)
        let deadline = Date().addingTimeInterval(seconds + 5)
        while state.pos < state.capacity && Date() < deadline { usleep(100_000) }
        AudioDeviceStop(dev, procID)
        AudioDeviceDestroyIOProcID(dev, procID)
        let rec = Array(UnsafeBufferPointer(start: state.buf, count: state.pos))

        var rms: Float = 0
        vDSP_rmsqv(rec, 1, &rms, vDSP_Length(rec.count))
        print("captured \(rec.count) frames, RMS \(String(format: "%.4f", rms))")
        guard rms > 1e-4 else { fail("capture is silent (source not active? permission denied? app not playing?)") }

        // Window: first 4096 frames after the recording's first non-silent sample + 0.1 s.
        let w = 4096
        guard let firstSound = rec.firstIndex(where: { abs($0) > 1e-3 }), firstSound + Int(rate / 10) + w <= rec.count
        else { fail("not enough signal in the capture") }
        let window = Array(rec[(firstSound + Int(rate / 10))..<(firstSound + Int(rate / 10) + w)])
        guard ref.count > w else { fail("reference too short") }

        // Cross-correlation: vDSP_conv computes C[n] = sum_k A[n+k] * F[k].
        let lags = ref.count - w + 1
        var corr = [Float](repeating: 0, count: lags)
        vDSP_conv(ref, 1, window, 1, &corr, 1, vDSP_Length(lags), vDSP_Length(w))
        // Normalize by energies (sliding energy of the reference).
        var winE: Float = 0
        vDSP_svesq(window, 1, &winE, vDSP_Length(w))
        var best = (lag: 0, value: Float(-1))
        var refE: Float = 0
        vDSP_svesq(ref, 1, &refE, vDSP_Length(w))
        for n in 0..<lags {
            if n > 0 { refE += ref[n + w - 1] * ref[n + w - 1] - ref[n - 1] * ref[n - 1] }
            let denom = sqrt(max(refE, 1e-12) * winE)
            let c = corr[n] / denom
            if c > best.value { best = (n, c) }
        }
        print("peak normalized correlation \(String(format: "%.4f", best.value)) at reference frame \(best.lag)")
        if Double(best.value) < minCorr { fail("correlation \(best.value) < \(minCorr)") }
        print("PASS")
    }
}

// Pass-thru bit-exactness test (spec J1 exit criterion, test table "driver: pass-thru bit-exact").
//
// Plays a deterministic 24-bit-quantized signal into the output side of a SoundRouter device
// and records its input side in the same HAL IOProc (no AUHAL conversion in the path), finds
// the loopback latency by exact pattern search (falls back to cross-correlation for the
// diagnostic) and asserts every sample is identical.
//
//   passthru_bitexact [--device SoundRouter] [--rate 48000] [--seconds 3]
//
// Preconditions: the device has exactly one source, the pass-thru, routed 1:1 with gain 1,
// device volume 1 / unmuted, no monitor feeding back, no other app playing into it.

import CoreAudio
import Foundation

final class LoopState: @unchecked Sendable {
    let outCh: Int, inCh: Int
    let playFrames: Int, recCapacity: Int
    let play: UnsafeMutablePointer<Float>   // interleaved outCh
    let rec: UnsafeMutablePointer<Float>    // interleaved inCh
    var playPos = 0
    var recPos = 0
    init(outCh: Int, inCh: Int, playFrames: Int, recCapacity: Int) {
        self.outCh = outCh; self.inCh = inCh
        self.playFrames = playFrames; self.recCapacity = recCapacity
        play = .allocate(capacity: playFrames * outCh); play.initialize(repeating: 0, count: playFrames * outCh)
        rec = .allocate(capacity: recCapacity * inCh); rec.initialize(repeating: 0, count: recCapacity * inCh)
    }
}

@main
struct PassThruBitExact {
    static func main() {
        let args = Args()
        let key = args.string("device") ?? "SoundRouter"
        let rate = args.double("rate", 48_000)
        let seconds = args.double("seconds", 3)
        guard let dev = CA.find(key) else { fail("no device matching '\(key)' (run list_devices)") }
        print("device: \(CA.name(dev) ?? "?") uid=\(CA.uid(dev) ?? "?")")

        if CA.nominalRate(dev) != rate {
            let st = CA.setNominalRate(dev, rate)
            if CA.nominalRate(dev) != rate { fail("cannot set rate \(rate) (status \(st), now \(CA.nominalRate(dev)))") }
        }
        let outCh = CA.channelCount(dev, kAudioObjectPropertyScopeOutput)
        let inCh = CA.channelCount(dev, kAudioObjectPropertyScopeInput)
        guard outCh > 0, inCh > 0 else { fail("device needs input and output (pass-thru) channels: in=\(inCh) out=\(outCh)") }
        let ch = min(outCh, inCh)
        print("rate=\(Int(rate)) in=\(inCh) out=\(outCh) compared channels=\(ch)")

        let lead = Int(rate / 2), sigFrames = Int(rate * seconds), tail = Int(rate)
        let state = LoopState(outCh: outCh, inCh: inCh, playFrames: lead + sigFrames + tail,
                              recCapacity: lead + sigFrames + tail + Int(rate))
        let signal = TestSignal(sampleRate: rate)
        for f in 0..<sigFrames {
            for c in 0..<ch { state.play[(lead + f) * outCh + c] = signal.sample(frame: f, channel: c) }
        }

        var procID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, _, outData, _ in
            // Output: interleave device channels across buffers.
            let outList = UnsafeMutableAudioBufferListPointer(outData)
            var base = 0
            for buf in outList {
                let n = Int(buf.mNumberChannels)
                guard n > 0, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = Int(buf.mDataByteSize) / (4 * n)
                for f in 0..<frames {
                    let src = state.playPos + f
                    for c in 0..<n {
                        p[f * n + c] = src < state.playFrames ? state.play[src * state.outCh + base + c] : 0
                    }
                }
                base += n
            }
            if let first = outList.first, first.mNumberChannels > 0 {
                state.playPos += Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
            }
            // Input.
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            base = 0
            var framesIn = 0
            for buf in inList {
                let n = Int(buf.mNumberChannels)
                guard n > 0, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                framesIn = Int(buf.mDataByteSize) / (4 * n)
                for f in 0..<framesIn where state.recPos + f < state.recCapacity {
                    for c in 0..<n { state.rec[(state.recPos + f) * state.inCh + base + c] = p[f * n + c] }
                }
                base += n
            }
            state.recPos += framesIn
        }
        guard st == noErr, let procID else { fail("AudioDeviceCreateIOProcIDWithBlock: \(st)") }
        guard AudioDeviceStart(dev, procID) == noErr else { fail("AudioDeviceStart failed") }
        let deadline = Date().addingTimeInterval(seconds + 10)
        while state.recPos < state.recCapacity && Date() < deadline { usleep(100_000) }
        AudioDeviceStop(dev, procID)
        AudioDeviceDestroyIOProcID(dev, procID)
        let recorded = min(state.recPos, state.recCapacity)
        print("played \(state.playPos) frames, recorded \(recorded) frames")

        // Locate the signal start in the recording (exact match of the first 256 frames, channel 0).
        let probe = 256
        var lag: Int? = nil
        search: for l in 0..<max(0, recorded - sigFrames) {
            for k in 0..<probe where state.rec[(l + k) * inCh] != signal.sample(frame: k, channel: 0) { continue search }
            lag = l
            break
        }
        guard let lag else {
            // Diagnostic: best normalized correlation of a 1024-frame window.
            let w = 1024
            var best = (lag: 0, corr: -1.0)
            let ref = (0..<w).map { Double(signal.sample(frame: $0, channel: 0)) }
            let refE = ref.reduce(0) { $0 + $1 * $1 }
            for l in 0..<max(0, recorded - w) {
                var dot = 0.0, e = 0.0
                for k in 0..<w { let x = Double(state.rec[(l + k) * inCh]); dot += x * ref[k]; e += x * x }
                let c = e > 0 ? dot / sqrt(e * refE) : 0
                if c > best.corr { best = (l, c) }
            }
            fail("signal not found bit-exact; best correlation \(String(format: "%.6f", best.corr)) at input frame \(best.lag)"
                 + " (\(best.lag - lead) frames after output start). Check gains, volume, routes, sample rate.")
        }
        print("loopback offset: \(lag - lead) frames (\(String(format: "%.2f", Double(lag - lead) / rate * 1000)) ms)")

        var mismatches = 0
        var maxErr: Float = 0
        var firstBad: (Int, Int)? = nil
        for f in 0..<sigFrames {
            for c in 0..<ch {
                let a = state.rec[(lag + f) * inCh + c], b = signal.sample(frame: f, channel: c)
                if a != b {
                    mismatches += 1
                    maxErr = max(maxErr, abs(a - b))
                    if firstBad == nil { firstBad = (f, c) }
                }
            }
        }
        if mismatches > 0 {
            fail("\(mismatches) mismatching samples over \(sigFrames * ch); max error \(maxErr); first at frame \(firstBad!.0) ch \(firstBad!.1)")
        }
        print("PASS: \(sigFrames) frames x \(ch) channels bit-exact at \(Int(rate)) Hz")
    }
}

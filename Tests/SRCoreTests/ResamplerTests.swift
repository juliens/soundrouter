import Foundation
import SRCore
import XCTest

final class ResamplerTests: XCTestCase {
    /// Continuous sine generator.
    struct Sine {
        var phase = 0.0
        let step: Double
        init(freq: Double, rate: Double) { step = 2 * .pi * freq / rate }
        mutating func fill(_ p: Planes, _ n: Int) {
            for i in 0..<n {
                let v = Float(sin(phase))
                for c in 0..<p.channels { p[c, i] = v }
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }
    }

    func testUnityRatioIsTransparent() {
        let ring = sr_ring_create(1, 8192)!
        let drs = sr_drs_create(1, 48_000, 48_000, 1024)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        var input = [Float]()
        var gen = Sine(freq: 997, rate: 48_000)
        let buf = Planes(channels: 1, frames: 1024)
        gen.fill(buf, 1024)
        input += buf.channel(0)
        sr_ring_write(ring, buf.const, 1024)

        let out = Planes(channels: 1, frames: 256)
        var output = [Float]()
        for _ in 0..<400 {
            XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 256)
            output += out.channel(0)
            gen.fill(buf, 256)
            input += buf.channel(0)[0..<256]
            sr_ring_write(ring, buf.const, 256)
        }
        XCTAssertEqual(sr_drs_ratio(drs), 1.0)
        XCTAssertEqual(sr_drs_underruns(drs), 0)
        // Kernel latency is exactly 2 samples; with mu == 0 Hermite returns the sample itself.
        var maxErr: Float = 0
        for g in 2..<output.count { maxErr = max(maxErr, abs(output[g] - input[g - 2])) }
        XCTAssertLessThan(maxErr, 1e-6)
    }

    func testRateConversionPreservesFrequency() {
        let src = 44_100.0, dst = 48_000.0, freq = 1_000.0
        let ring = sr_ring_create(2, 16384)!
        let drs = sr_drs_create(2, src, dst, 2048)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        XCTAssertEqual(sr_drs_ratio(drs), src / dst, accuracy: 1e-12)
        var gen = Sine(freq: freq, rate: src)
        let buf = Planes(channels: 2, frames: 4096)
        gen.fill(buf, 2048)
        sr_ring_write(ring, buf.const, 2048)

        let out = Planes(channels: 2, frames: 256)
        var output = [Float]()
        var owed = 0.0
        let seconds = 6.0
        let cycles = Int(seconds * dst / 256)
        for _ in 0..<cycles {
            sr_drs_pull(drs, ring, out.mut, 256)
            output += out.channel(1)
            owed += 256 * src / dst
            let n = Int(owed)
            owed -= Double(n)
            gen.fill(buf, n)
            sr_ring_write(ring, buf.const, UInt32(n))
        }
        XCTAssertEqual(sr_drs_underruns(drs), 0)
        // Measure over the last 4 seconds (after controller settling).
        let tail = output.suffix(Int(4 * dst))
        var crossings = 0
        var prev = tail.first!
        var peak: Float = 0
        for v in tail.dropFirst() {
            if (prev < 0 && v >= 0) || (prev >= 0 && v < 0) { crossings += 1 }
            prev = v
            peak = max(peak, abs(v))
        }
        let measured = Double(crossings) / 2 / 4
        XCTAssertEqual(measured, freq, accuracy: 1.0, "measured \(measured) Hz")
        XCTAssertEqual(peak, 1, accuracy: 0.02)
        XCTAssertEqual(sr_drs_ratio(drs), src / dst, accuracy: src / dst * 0.001)
    }

    /// Producer and consumer on independent clocks (producer +/-0.3 %), bursty producer blocks,
    /// 10 simulated minutes: no underrun after warm-up and the fill level stays bounded.
    private func runDrift(ppm: Double, file: StaticString = #filePath, line: UInt = #line) {
        let rate = 48_000.0, target: UInt32 = 2048
        let prodBlock = 480, consBlock = 256
        let ring = sr_ring_create(2, 16384)!
        let drs = sr_drs_create(2, rate, rate, target)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        let block = Planes(channels: 2, frames: prodBlock)
        var gen = Sine(freq: 440, rate: rate)
        gen.fill(block, prodBlock)
        let out = Planes(channels: 2, frames: consBlock)

        let prodPeriod = Double(prodBlock) / (rate * (1 + ppm * 1e-6))
        let consPeriod = Double(consBlock) / rate
        var tProd = 0.0, tCons = 0.0
        let duration = 600.0, warmup = 60.0
        var underrunsAtWarmup: UInt64?
        var minFill = UInt32.max, maxFill: UInt32 = 0
        var ratioSum = 0.0, ratioCount = 0
        while tCons < duration {
            if tProd <= tCons {
                sr_ring_write(ring, block.const, UInt32(prodBlock))
                tProd += prodPeriod
            } else {
                let fill = sr_ring_readable(ring)
                sr_drs_pull(drs, ring, out.mut, UInt32(consBlock))
                tCons += consPeriod
                if tCons >= warmup {
                    if underrunsAtWarmup == nil { underrunsAtWarmup = sr_drs_underruns(drs) }
                    minFill = min(minFill, fill)
                    maxFill = max(maxFill, fill)
                    ratioSum += sr_drs_ratio(drs)
                    ratioCount += 1
                }
            }
        }
        XCTAssertEqual(sr_drs_underruns(drs), underrunsAtWarmup, "underruns after warm-up", file: file, line: line)
        XCTAssertEqual(sr_drs_underruns(drs), 0, file: file, line: line)
        XCTAssertEqual(sr_ring_overflows(ring), 0, file: file, line: line)
        XCTAssertGreaterThan(minFill, target / 2, "min fill \(minFill)", file: file, line: line)
        XCTAssertLessThan(maxFill, target * 3 / 2, "max fill \(maxFill)", file: file, line: line)
        XCTAssertEqual(ratioSum / Double(ratioCount), 1 + ppm * 1e-6, accuracy: 5e-5, "mean ratio", file: file, line: line)
        XCTAssertEqual(sr_drs_ratio(drs), 1 + ppm * 1e-6, accuracy: 5e-4, file: file, line: line)
        print("drift \(ppm) ppm: fill [\(minFill), \(maxFill)] target \(target), ratio \(sr_drs_ratio(drs))")
    }

    func testDriftFastProducer() { runDrift(ppm: 3000) }
    func testDriftSlowProducer() { runDrift(ppm: -3000) }

    func testUnderrunWaitsForRefill() {
        let ring = sr_ring_create(1, 8192)!
        let drs = sr_drs_create(1, 48_000, 48_000, 1024)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        let buf = Planes(channels: 1, frames: 1024)
        buf.fill { _, _ in 0.5 }
        let out = Planes(channels: 1, frames: 256)

        // Not primed yet: silence, not counted as underrun.
        sr_ring_write(ring, buf.const, 512)
        XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 0)
        XCTAssertEqual(out.channel(0), [Float](repeating: 0, count: 256))
        XCTAssertEqual(sr_drs_underruns(drs), 0)

        sr_ring_write(ring, buf.const, 512) // reaches target
        var pulls = 0
        var last: UInt32 = 256
        while last == 256 && pulls < 10 {
            last = sr_drs_pull(drs, ring, out.mut, 256)
            pulls += 1
        }
        XCTAssertLessThan(last, 256) // partial block: ring exhausted
        XCTAssertTrue((4...6).contains(pulls), "pulls \(pulls)")
        XCTAssertEqual(out[0, 255], 0) // rest of the block is silence
        XCTAssertEqual(sr_drs_underruns(drs), 1)
        // Starved: silence without counting again, until the fill reaches target.
        for _ in 0..<5 { XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 0) }
        sr_ring_write(ring, buf.const, 600)
        XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 0)
        XCTAssertEqual(sr_drs_underruns(drs), 1)
        sr_ring_write(ring, buf.const, 600)
        XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 256)
        XCTAssertEqual(out[0, 255], 0.5, accuracy: 1e-6)
    }

    func testOverflowSkipsToTarget() {
        let ring = sr_ring_create(1, 16384)!
        let drs = sr_drs_create(1, 48_000, 48_000, 1000)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        let buf = Planes(channels: 1, frames: 4000)
        sr_ring_write(ring, buf.const, 4000)
        let out = Planes(channels: 1, frames: 256)
        XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 256)
        let fill = sr_ring_readable(ring)
        XCTAssertTrue((1000 - 260...1000 - 250).contains(fill), "fill \(fill)")
    }

    func testRatioClamped() {
        let ring = sr_ring_create(1, 65536)!
        let drs = sr_drs_create(1, 48_000, 48_000, 10_000)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        let buf = Planes(channels: 1, frames: 29_000)
        sr_ring_write(ring, buf.const, 29_000) // < 3x target: no skip, huge positive error
        let out = Planes(channels: 1, frames: 256)
        for _ in 0..<50 { sr_drs_pull(drs, ring, out.mut, 256) }
        XCTAssertLessThanOrEqual(sr_drs_ratio(drs), 1.01 + 1e-12)
        XCTAssertGreaterThan(sr_drs_ratio(drs), 1.0)
    }

    func testResetRestartsPriming() {
        let ring = sr_ring_create(1, 8192)!
        let drs = sr_drs_create(1, 48_000, 48_000, 512)!
        defer { sr_ring_destroy(ring); sr_drs_destroy(drs) }
        let buf = Planes(channels: 1, frames: 1024)
        sr_ring_write(ring, buf.const, 1024)
        let out = Planes(channels: 1, frames: 256)
        XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 256)
        sr_drs_reset(drs)
        sr_ring_skip(ring, sr_ring_readable(ring))
        XCTAssertEqual(sr_drs_pull(drs, ring, out.mut, 256), 0)
        XCTAssertEqual(sr_drs_underruns(drs), 0)
    }
}

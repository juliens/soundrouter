import Foundation
import SRCore
import XCTest

final class BenchmarkTests: XCTestCase {
    /// One mix cycle of a stereo device with 3 stereo sources (one at 44.1 kHz):
    /// 3 x sr_drs_pull + sr_mix_render at 256 frames. Spec target: < 2 % of one core.
    func testMixCycleCost() {
        let frames = 256, rate = 48_000.0
        let srcRates = [48_000.0, 44_100.0, 48_000.0]
        let rings = srcRates.map { _ in sr_ring_create(2, 16384)! }
        let drs = srcRates.map { sr_drs_create(2, $0, rate, 1024)! }
        defer { rings.forEach { sr_ring_destroy($0) }; drs.forEach { sr_drs_destroy($0) } }
        let pulled = srcRates.map { _ in Planes(channels: 2, frames: frames) }
        let out = Planes(channels: 2, frames: frames)
        let input = Planes(channels: 2, frames: 1024)
        input.fill { c, i in Float(sin(Double(i) * 0.05 + Double(c))) * 0.5 }
        let meters = UnsafeMutablePointer<SRMeters>.allocate(capacity: 1)
        defer { meters.deallocate() }
        sr_meters_reset(meters)
        let plan = Plan(outputs: 2, sources: [.init(), .init(volume: 0.7), .init()],
                        routes: [(0, 0, 0, 1), (0, 1, 1, 1), (1, 0, 0, 1), (1, 1, 1, 1),
                                 (2, 0, 0, 0.5), (2, 1, 1, 0.5)])
        let list = SourceList(pulled)
        var owed = [0.0, 0.0, 0.0]
        for s in 0..<3 { sr_ring_write(rings[s], input.const, 1024) }

        let cycles = 20_000
        var total: UInt64 = 0
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        for _ in 0..<cycles {
            for s in 0..<3 { // producers (not timed)
                owed[s] += Double(frames) * srcRates[s] / rate
                let n = Int(owed[s])
                owed[s] -= Double(n)
                sr_ring_write(rings[s], input.const, UInt32(n))
            }
            let t0 = mach_absolute_time()
            for s in 0..<3 { sr_drs_pull(drs[s], rings[s], pulled[s].mut, UInt32(frames)) }
            sr_mix_render(plan.ptr, list.ptr, out.mut, UInt32(frames), meters)
            total += mach_absolute_time() - t0
        }
        let nsPerCycle = Double(total) * Double(tb.numer) / Double(tb.denom) / Double(cycles)
        let budgetNs = Double(frames) / rate * 1e9
        let pct = nsPerCycle / budgetNs * 100
        print(String(format: "BENCH mix cycle (stereo, 3 sources, 256 frames): %.0f ns/cycle = %.3f %% of one core",
                     nsPerCycle, pct))
        for s in 0..<3 { XCTAssertEqual(sr_drs_underruns(drs[s]), 0) }
        XCTAssertLessThan(pct, 2.0)
    }
}

import SRCore
import XCTest

final class MixTests: XCTestCase {
    let frames = 64

    private func stereo(_ l: Float, _ r: Float) -> Planes {
        let p = Planes(channels: 2, frames: frames)
        p.fill { c, _ in c == 0 ? l : r }
        return p
    }

    private func render(_ plan: Plan, _ sources: [Planes?], outputs: Int = 2,
                        meters: UnsafeMutablePointer<SRMeters>? = nil) -> Planes {
        let out = Planes(channels: outputs, frames: frames)
        out.fill { _, _ in 42 } // must be overwritten
        let list = SourceList(sources)
        sr_mix_render(plan.ptr, list.ptr, out.mut, UInt32(frames), meters)
        return out
    }

    private func assertConst(_ p: Planes, _ c: Int, _ v: Float, accuracy: Float = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<p.frames {
            XCTAssertEqual(p[c, i], v, accuracy: accuracy, "ch \(c) frame \(i)", file: file, line: line)
            if abs(p[c, i] - v) > accuracy { return }
        }
    }

    func testMetersLayout() {
        XCTAssertEqual(MemoryLayout<SRMeters>.size, Int(SR_MAX_SOURCES) * Int(SR_MAX_CHANNELS) * 4 + Int(SR_MAX_CHANNELS) * 4)
        XCTAssertEqual(sr_meters_size(), MemoryLayout<SRMeters>.size)
    }

    func testRoutingSwap() {
        let plan = Plan(outputs: 2, sources: [.init()], routes: [(0, 0, 1, 1), (0, 1, 0, 1)])
        let out = render(plan, [stereo(0.1, 0.2)])
        assertConst(out, 0, 0.2)
        assertConst(out, 1, 0.1)
    }

    func testUnroutedOutputIsSilent() {
        let plan = Plan(outputs: 3, sources: [.init()], routes: [(0, 0, 0, 1)])
        let out = render(plan, [stereo(0.3, 0.4)], outputs: 3)
        assertConst(out, 0, 0.3)
        assertConst(out, 1, 0)
        assertConst(out, 2, 0)
    }

    func testGains() {
        let plan = Plan(outputs: 2, sources: [.init(volume: 0.5)], routes: [(0, 0, 0, 0.5), (0, 1, 1, 1)],
                        volume: 0.8)
        let out = render(plan, [stereo(0.5, -0.5)])
        assertConst(out, 0, 0.5 * 0.5 * 0.5 * 0.8)
        assertConst(out, 1, -0.5 * 0.5 * 0.8)
    }

    func testSumOfRoutesIntoSameChannel() {
        let plan = Plan(outputs: 2, sources: [.init(), .init(channels: 1)],
                        routes: [(0, 0, 0, 1), (0, 1, 0, 1), (1, 0, 0, 0.5), (1, 0, 1, 1)])
        let mono = Planes(channels: 1, frames: frames)
        mono.fill { _, _ in 0.2 }
        let out = render(plan, [stereo(0.1, 0.3), mono])
        assertConst(out, 0, 0.1 + 0.3 + 0.1)
        assertConst(out, 1, 0.2)
    }

    func testDeviceMute() {
        let plan = Plan(outputs: 2, sources: [.init()], routes: [(0, 0, 0, 1), (0, 1, 1, 1)], muted: true)
        let out = render(plan, [stereo(0.5, 0.5)])
        assertConst(out, 0, 0)
        assertConst(out, 1, 0)
    }

    func testSourceMuteDisabledAndMissing() {
        let plan = Plan(outputs: 1,
                        sources: [.init(muted: true), .init(active: false), .init(), .init()],
                        routes: [(0, 0, 0, 1), (1, 0, 0, 1), (2, 0, 0, 1), (3, 0, 0, 1)])
        // Source 3 has no planes (NULL): contributes nothing.
        let out = render(plan, [stereo(0.1, 0), stereo(0.2, 0), stereo(0.4, 0), nil], outputs: 1)
        assertConst(out, 0, 0.4)
    }

    func testClipping() {
        let plan = Plan(outputs: 2, sources: [.init(), .init()],
                        routes: [(0, 0, 0, 1), (1, 0, 0, 1), (0, 1, 1, 1), (1, 1, 1, 1)])
        let out = render(plan, [stereo(0.8, -0.8), stereo(0.8, -0.8)])
        assertConst(out, 0, 1)
        assertConst(out, 1, -1)
    }

    func testOutOfRangeRoutesIgnored() {
        let plan = Plan(outputs: 2, sources: [.init(channels: 1)],
                        routes: [(0, 1, 0, 1), (0, 0, 5, 1), (7, 0, 0, 1), (0, 0, 1, 1)])
        let mono = Planes(channels: 1, frames: frames)
        mono.fill { _, _ in 0.25 }
        let out = render(plan, [mono])
        assertConst(out, 0, 0)
        assertConst(out, 1, 0.25)
    }

    func testMeters() {
        let meters = UnsafeMutablePointer<SRMeters>.allocate(capacity: 1)
        defer { meters.deallocate() }
        sr_meters_reset(meters)
        let plan = Plan(outputs: 2, sources: [.init(volume: 0.5), .init(muted: true)],
                        routes: [(0, 0, 0, 1), (0, 1, 1, 4), (1, 0, 0, 1)])
        let a = stereo(0.5, -0.6)
        a[0, 10] = -0.9 // peak is on absolute value
        _ = render(plan, [a, stereo(1, 1)], meters: meters)
        XCTAssertEqual(sr_meters_take_source(meters, 0, 0), 0.45, accuracy: 1e-6) // after volume
        XCTAssertEqual(sr_meters_take_source(meters, 0, 1), 0.3, accuracy: 1e-6)
        XCTAssertEqual(sr_meters_take_source(meters, 1, 0), 0) // muted
        XCTAssertEqual(sr_meters_take_output(meters, 0), 0.45, accuracy: 1e-6)
        XCTAssertEqual(sr_meters_take_output(meters, 1), 1, accuracy: 1e-6) // after clip (1.2 -> 1)
        // Take resets.
        XCTAssertEqual(sr_meters_take_source(meters, 0, 0), 0)
        XCTAssertEqual(sr_meters_take_output(meters, 1), 0)
        // Max accumulates across renders until taken.
        _ = render(plan, [stereo(0.2, 0), stereo(0, 0)], meters: meters)
        _ = render(plan, [stereo(0.1, 0), stereo(0, 0)], meters: meters)
        XCTAssertEqual(sr_meters_take_output(meters, 0), 0.1, accuracy: 1e-6)
        // Out-of-range indices are harmless.
        XCTAssertEqual(sr_meters_take_source(meters, 99, 0), 0)
        XCTAssertEqual(sr_meters_take_output(meters, 99), 0)
    }
}

import Foundation
import SRCore
import XCTest

nonisolated(unsafe) private var freedPointers: [UnsafeMutableRawPointer] = []

private func trackFree(_ p: UnsafeMutableRawPointer?) {
    if let p { freedPointers.append(p) }
}

final class PlanSlotTests: XCTestCase {
    override func setUp() { freedPointers = [] }

    private func token(_ v: Int) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: 0x1000 * v)! }

    func testRetiredFreedOnlyAfterReaderRelease() {
        let slot = sr_slot_create(trackFree)!
        let a = token(1), b = token(2), c = token(3)
        sr_slot_publish(slot, a)
        XCTAssertEqual(sr_slot_acquire(slot), a)
        sr_slot_publish(slot, b)          // reader still inside with `a`
        XCTAssertTrue(freedPointers.isEmpty)
        sr_slot_collect(slot)
        XCTAssertTrue(freedPointers.isEmpty)
        sr_slot_release(slot)
        XCTAssertTrue(freedPointers.isEmpty) // never freed by the reader
        sr_slot_collect(slot)
        XCTAssertEqual(freedPointers, [a])

        // Reader quiescent at publish time: old pointer freed immediately.
        XCTAssertEqual(sr_slot_acquire(slot), b)
        sr_slot_release(slot)
        sr_slot_publish(slot, c)
        XCTAssertEqual(freedPointers, [a, b])

        // Reader enters after publish: it sees the new pointer.
        XCTAssertEqual(sr_slot_acquire(slot), c)
        sr_slot_release(slot)

        sr_slot_destroy(slot)
        XCTAssertEqual(freedPointers, [a, b, c])
    }

    func testMultipleRetiredWhileReaderInside() {
        let slot = sr_slot_create(trackFree)!
        sr_slot_publish(slot, token(1))
        _ = sr_slot_acquire(slot)
        for i in 2...20 { sr_slot_publish(slot, token(i)) }
        // Pointers 2...19 were retired while the reader was inside too (conservative).
        XCTAssertTrue(freedPointers.isEmpty)
        sr_slot_release(slot)
        sr_slot_collect(slot)
        XCTAssertEqual(Set(freedPointers), Set((1...19).map(token)))
        sr_slot_destroy(slot)
        XCTAssertEqual(freedPointers.count, 20)
    }

    func testConcurrentReaderSmoke() {
        // Real plans, real reader thread: must not crash or read freed memory (run under ASan
        // for stronger guarantees).
        let slot = sr_slot_create { p in sr_mix_plan_destroy(p?.assumingMemoryBound(to: SRMixPlan.self)) }!
        let slotAddr = UInt(bitPattern: slot)
        let stop = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        stop.initialize(to: false)
        let stopAddr = UInt(bitPattern: stop)
        let done = expectation(description: "reader")
        func makePlan(_ v: UInt32) -> UnsafeMutablePointer<SRMixPlan> {
            let p = sr_mix_plan_create(4)!
            p.pointee.outputChannels = v
            p.pointee.routeCount = v
            return p
        }
        sr_slot_publish(slot, makePlan(1))
        Thread {
            let s = OpaquePointer(bitPattern: slotAddr)!
            let stop = UnsafeMutablePointer<Bool>(bitPattern: stopAddr)!
            var bad = 0
            while !stop.pointee {
                if let p = sr_slot_acquire(s)?.assumingMemoryBound(to: SRMixPlan.self) {
                    if p.pointee.outputChannels != p.pointee.routeCount { bad += 1 }
                }
                sr_slot_release(s)
            }
            XCTAssertEqual(bad, 0)
            done.fulfill()
        }.start()
        for i in 0..<20_000 { sr_slot_publish(slot, makePlan(UInt32(1 + i % 4))) }
        stop.pointee = true
        wait(for: [done], timeout: 10)
        sr_slot_destroy(slot)
        stop.deallocate()
    }
}

/// Raw access to SRShmHeader's _Atomic fields, which Swift does not import (offsets from sr_shm.h).
private enum Hdr {
    static func u32(_ h: UnsafeMutablePointer<SRShmHeader>, _ off: Int) -> UInt32 {
        UnsafeMutableRawPointer(h).load(fromByteOffset: off, as: UInt32.self)
    }
    static func i64(_ h: UnsafeMutablePointer<SRShmHeader>, _ off: Int) -> Int64 {
        UnsafeMutableRawPointer(h).load(fromByteOffset: off, as: Int64.self)
    }
    static func setI64(_ h: UnsafeMutablePointer<SRShmHeader>, _ off: Int, _ v: Int64) {
        UnsafeMutableRawPointer(h).storeBytes(of: v, toByteOffset: off, as: Int64.self)
    }
}

final class ShmTests: XCTestCase {
    func testCreateReopenAndIndexMath() throws {
        let uuid = UUID().uuidString
        defer { sr_device_shm_unlink(uuid) }
        sr_device_shm_unlink(uuid)

        var shm = SRDeviceShm()
        XCTAssertEqual(sr_device_shm_open(&shm, uuid, 2, 48_000, true), 0)
        var h = try XCTUnwrap(shm.header)
        XCTAssertEqual(h.pointee.magic, SR_SHM_MAGIC)
        XCTAssertEqual(h.pointee.version, SR_SHM_VERSION)
        XCTAssertEqual(h.pointee.channelCount, 2)
        XCTAssertEqual(h.pointee.ringFrames, SR_RING_FRAMES)
        XCTAssertEqual(h.pointee.sampleRate, 48_000)
        XCTAssertEqual(h.pointee.hasPassThru, 1)
        XCTAssertEqual(shm.size, sr_shm_size(2))
        XCTAssertTrue(withUnsafeBytes(of: shm.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            .hasPrefix("/sr."))
        let anchor = h.pointee.anchorHostTime
        XCTAssertNotEqual(anchor, 0)
        XCTAssertEqual(sr_bits_to_float(Hdr.u32(h, 72)), 1)

        // Sample clock advances with host time.
        let t0 = sr_device_now_sample_time(h)
        Thread.sleep(forTimeInterval: 0.05)
        let t1 = sr_device_now_sample_time(h)
        XCTAssertGreaterThanOrEqual(t0, 0)
        XCTAssertEqual(Double(t1 - t0), 2400, accuracy: 1500)

        // write_mix across the ring boundary.
        let ring = Int64(SR_RING_FRAMES)
        let n = 256
        let mix = Planes(channels: 2, frames: n)
        mix.fill { c, i in Float(c * 1000 + i + 1) }
        let st = 5 * ring - 100
        sr_device_write_mix(h, st, mix.const, UInt32(n))
        XCTAssertEqual(Hdr.i64(h, 48), st + Int64(n))
        for c in 0..<2 {
            let plane = sr_shm_mix_plane(h, UInt32(c))!
            for i in 0..<n {
                let idx = Int((st + Int64(i)) & Int64(SR_RING_MASK))
                XCTAssertEqual(plane[idx], Float(c * 1000 + i + 1))
            }
            XCTAssertEqual(plane[Int(ring) - 101], 0)
            XCTAssertEqual(plane[156], 0)
        }

        // read_passthru: driver wrote [W - 300, W) crossing the boundary.
        let w = 7 * ring + 200
        for c in 0..<2 {
            let plane = sr_shm_passthru_plane(h, UInt32(c))!
            for t in (w - 300)..<w { plane[Int(t & Int64(SR_RING_MASK))] = Float(t - (w - 300) + 1) * (c == 0 ? 1 : -1) }
        }
        Hdr.setI64(h, 56, w)
        let rd = Planes(channels: 2, frames: 512)
        rd.fill { _, _ in 99 }
        // Request [W - 400, W + 112): 100 frames before... are still inside the ring window
        // (stale content, but inside [W - RING, W)), 300 real, 112 in the future -> silence.
        let got = sr_device_read_passthru(h, w - 400, rd.mut, 512)
        XCTAssertEqual(got, 400)
        for i in 100..<400 { XCTAssertEqual(rd[0, i], Float(i - 99)); XCTAssertEqual(rd[1, i], -Float(i - 99)) }
        for i in 400..<512 { XCTAssertEqual(rd[0, i], 0); XCTAssertEqual(rd[1, i], 0) }
        // Frames older than the ring window are silence.
        rd.fill { _, _ in 99 }
        XCTAssertEqual(sr_device_read_passthru(h, w - ring - 12, rd.mut, 512), 500)
        for i in 0..<12 { XCTAssertEqual(rd[0, i], 0) }
        XCTAssertNotEqual(rd[0, 12], 99)
        // Entirely in the future.
        XCTAssertEqual(sr_device_read_passthru(h, w + 10, rd.mut, 64), 0)
        for i in 0..<64 { XCTAssertEqual(rd[1, i], 0) }

        sr_device_shm_close(&shm)
        XCTAssertNil(shm.header)

        // Reopen with identical parameters keeps the segment and its anchor.
        var shm2 = SRDeviceShm()
        XCTAssertEqual(sr_device_shm_open(&shm2, uuid, 2, 48_000, true), 0)
        h = try XCTUnwrap(shm2.header)
        XCTAssertEqual(h.pointee.anchorHostTime, anchor)
        XCTAssertEqual(Hdr.i64(h, 48), st + Int64(n))
        sr_device_shm_close(&shm2)

        // Different channel count: recreated with a fresh anchor and layout.
        var shm3 = SRDeviceShm()
        XCTAssertEqual(sr_device_shm_open(&shm3, uuid, 4, 48_000, false), 0)
        h = try XCTUnwrap(shm3.header)
        XCTAssertEqual(h.pointee.channelCount, 4)
        XCTAssertEqual(h.pointee.hasPassThru, 0)
        XCTAssertNotEqual(h.pointee.anchorHostTime, anchor)
        XCTAssertEqual(Hdr.i64(h, 48), 0)
        XCTAssertEqual(shm3.size, sr_shm_size(4))
        // No pass-thru: always silence.
        let rd4 = Planes(channels: 4, frames: 16)
        rd4.fill { _, _ in 1 }
        XCTAssertEqual(sr_device_read_passthru(h, 0, rd4.mut, 16), 0)
        XCTAssertEqual(rd4.channel(3), [Float](repeating: 0, count: 16))
        sr_device_shm_close(&shm3)

        XCTAssertNotEqual(sr_device_shm_open(&shm3, uuid, 0, 48_000, false), 0)
    }

    func testRealtimeThreadPromotion() {
        let done = expectation(description: "rt")
        Thread {
            XCTAssertEqual(sr_thread_set_realtime(256, 48_000), 0)
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 5)
        XCTAssertNotEqual(sr_thread_set_realtime(0, 48_000), 0)
    }
}

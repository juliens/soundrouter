import Foundation
import SRCore
import XCTest

final class RingTests: XCTestCase {
    func testCapacityRoundsToPowerOfTwo() {
        let r = sr_ring_create(2, 100)!
        defer { sr_ring_destroy(r) }
        XCTAssertEqual(sr_ring_capacity(r), 128)
        XCTAssertEqual(sr_ring_channels(r), 2)
        XCTAssertEqual(sr_ring_writable(r), 128)
        XCTAssertEqual(sr_ring_readable(r), 0)
        XCTAssertNil(sr_ring_create(0, 16))
    }

    func testWraparound() {
        let r = sr_ring_create(2, 8)!
        defer { sr_ring_destroy(r) }
        var next: Float = 0
        var expected: Float = 0
        let src = Planes(channels: 2, frames: 8)
        let dst = Planes(channels: 2, frames: 8)
        // Many cycles of uneven write/read sizes cross the wrap point in every position.
        for cycle in 0..<200 {
            let w = 1 + cycle % 7
            let writable = Int(sr_ring_writable(r))
            let n = min(w, writable)
            for i in 0..<n { src[0, i] = next + Float(i); src[1, i] = -(next + Float(i)) }
            XCTAssertEqual(sr_ring_write(r, src.const, UInt32(n)), UInt32(n))
            next += Float(n)
            let rn = Int(sr_ring_read(r, dst.mut, UInt32(1 + (cycle * 3) % 8)))
            for i in 0..<rn {
                XCTAssertEqual(dst[0, i], expected + Float(i))
                XCTAssertEqual(dst[1, i], -(expected + Float(i)))
            }
            expected += Float(rn)
        }
        XCTAssertEqual(sr_ring_overflows(r), 0)
    }

    func testOverflowDropsExcess() {
        let r = sr_ring_create(1, 8)!
        defer { sr_ring_destroy(r) }
        let src = Planes(channels: 1, frames: 10)
        src.fill { _, i in Float(i) }
        XCTAssertEqual(sr_ring_write(r, src.const, 10), 8)
        XCTAssertEqual(sr_ring_overflows(r), 1)
        XCTAssertEqual(sr_ring_writable(r), 0)
        XCTAssertEqual(sr_ring_write(r, src.const, 1), 0)
        XCTAssertEqual(sr_ring_overflows(r), 2)
        let dst = Planes(channels: 1, frames: 8)
        XCTAssertEqual(sr_ring_read(r, dst.mut, 8), 8)
        XCTAssertEqual(dst.channel(0), (0..<8).map(Float.init))
    }

    func testPeekAndSkip() {
        let r = sr_ring_create(1, 16)!
        defer { sr_ring_destroy(r) }
        let src = Planes(channels: 1, frames: 10)
        src.fill { _, i in Float(i) }
        sr_ring_write(r, src.const, 10)
        let dst = Planes(channels: 1, frames: 4)
        XCTAssertEqual(sr_ring_peek(r, dst.mut, 4), 4)
        XCTAssertEqual(dst.channel(0), [0, 1, 2, 3])
        XCTAssertEqual(sr_ring_readable(r), 10)
        sr_ring_skip(r, 6)
        XCTAssertEqual(sr_ring_readable(r), 4)
        XCTAssertEqual(sr_ring_read(r, dst.mut, 4), 4)
        XCTAssertEqual(dst.channel(0), [6, 7, 8, 9])
        sr_ring_skip(r, 100) // clamped
        XCTAssertEqual(sr_ring_readable(r), 0)
        XCTAssertEqual(sr_ring_read(r, dst.mut, 4), 0)
    }

    func testInterleavedWrite() {
        let r = sr_ring_create(2, 16)!
        defer { sr_ring_destroy(r) }
        // 3-channel source into a 2-channel ring: third channel dropped.
        let three: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertEqual(sr_ring_write_interleaved(r, three, 3, 3), 3)
        // Mono source: missing channel zero-filled.
        let mono: [Float] = [10, 11]
        XCTAssertEqual(sr_ring_write_interleaved(r, mono, 1, 2), 2)
        let dst = Planes(channels: 2, frames: 5)
        XCTAssertEqual(sr_ring_read(r, dst.mut, 5), 5)
        XCTAssertEqual(dst.channel(0), [1, 4, 7, 10, 11])
        XCTAssertEqual(dst.channel(1), [2, 5, 8, 0, 0])
    }

    func testConcurrentProducerConsumer() {
        let total = 1_000_000
        let r = sr_ring_create(2, 1024)!
        defer { sr_ring_destroy(r) }
        let producerDone = expectation(description: "producer")
        let ringAddr = UInt(bitPattern: r)

        Thread {
            let ring = OpaquePointer(bitPattern: ringAddr)!
            let src = Planes(channels: 2, frames: 97)
            var next = 0
            var chunk = 1
            while next < total {
                let n = min(chunk, total - next)
                for i in 0..<n { src[0, i] = Float(next + i); src[1, i] = Float(-(next + i)) }
                var written = 0
                while written < n {
                    // Only offer what fits to avoid counted overflows.
                    let space = Int(sr_ring_writable(ring))
                    if space == 0 { continue }
                    let k = min(space, n - written)
                    let ptrs: [UnsafePointer<Float>?] = [UnsafePointer(src.data[0] + written),
                                                         UnsafePointer(src.data[1] + written)]
                    written += Int(sr_ring_write(ring, ptrs, UInt32(k)))
                }
                next += n
                chunk = chunk % 97 + 1
            }
            producerDone.fulfill()
        }.start()

        let dst = Planes(channels: 2, frames: 61)
        var expected = 0
        var errors = 0
        var chunk = 1
        while expected < total {
            let n = Int(sr_ring_read(r, dst.mut, UInt32(chunk)))
            for i in 0..<n {
                if dst[0, i] != Float(expected + i) || dst[1, i] != Float(-(expected + i)) { errors += 1 }
            }
            expected += n
            chunk = chunk % 61 + 1
        }
        wait(for: [producerDone], timeout: 60)
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(expected, total)
        XCTAssertEqual(sr_ring_overflows(r), 0)
        XCTAssertEqual(sr_ring_readable(r), 0)
    }
}

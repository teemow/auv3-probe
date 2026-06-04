import Foundation
import Atomics

// A single-producer / single-consumer lock-free ring buffer of Float samples.
//
// The AUv3 render block (a realtime thread) is the *producer*: it must never
// allocate, lock, or block. The networking thread that drains samples for the
// audio stream is the *consumer*. Head/tail indices are atomics with
// acquire/release ordering so the consumer never observes a sample slot before
// the producer has finished writing it (and vice-versa). The backing storage is
// allocated once at construction; `write`/`read` only copy and advance indices.
//
// Realtime contract:
//   - `write(_:)` is called only from the render thread; it is wait-free and
//     allocation-free. If the buffer is full it drops the overflow (returns the
//     count actually written) rather than blocking — dropping audio is the
//     correct failure mode for a non-essential tap.
//   - `read(into:)` is called only from the networking thread.
//
// Per docs/auv3-extension.md, this is the MVP "preallocated buffers + atomics"
// approach; a C core is only warranted if profiling shows glitches.
public final class RealtimeRing: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    // Monotonically increasing total counts; the slot is `index % capacity`.
    // Using ever-increasing counters makes "full vs empty" unambiguous.
    private let head = UnsafeAtomic<Int>.create(0) // total written (producer)
    private let tail = UnsafeAtomic<Int>.create(0) // total read (consumer)

    /// Create a ring that can hold `capacity` Float samples.
    public init(capacity: Int) {
        precondition(capacity > 0, "ring capacity must be positive")
        self.capacity = capacity
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        buf.initialize(repeating: 0)
        self.storage = buf
    }

    deinit {
        storage.deallocate()
        head.destroy()
        tail.destroy()
    }

    /// Number of samples currently available to read.
    public var availableToRead: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        return h - t
    }

    /// Free space available to write right now.
    public var availableToWrite: Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        return capacity - (h - t)
    }

    /// Producer side (render thread). Copies up to `count` samples from `data`,
    /// returning how many were actually written (fewer than `count` when full).
    /// Wait-free and allocation-free.
    @discardableResult
    public func write(_ data: UnsafePointer<Float>, count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        let n = Swift.min(count, free)
        if n <= 0 { return 0 }

        let start = h % capacity
        let firstChunk = Swift.min(n, capacity - start)
        storage.baseAddress!.advanced(by: start).update(from: data, count: firstChunk)
        if n > firstChunk {
            storage.baseAddress!.update(from: data.advanced(by: firstChunk), count: n - firstChunk)
        }
        // Release so the consumer sees the sample writes before the new head.
        head.store(h + n, ordering: .releasing)
        return n
    }

    /// Consumer side (networking thread). Copies up to `out.count` samples into
    /// `out`, returning how many were read.
    @discardableResult
    public func read(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        let avail = h - t
        let n = Swift.min(out.count, avail)
        if n <= 0 { return 0 }

        let start = t % capacity
        let firstChunk = Swift.min(n, capacity - start)
        out.baseAddress!.update(from: storage.baseAddress!.advanced(by: start), count: firstChunk)
        if n > firstChunk {
            out.baseAddress!.advanced(by: firstChunk).update(from: storage.baseAddress!, count: n - firstChunk)
        }
        // Release so the producer sees freed space after we've copied out.
        tail.store(t + n, ordering: .releasing)
        return n
    }
}

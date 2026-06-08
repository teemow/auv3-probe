import Foundation
import Atomics

// A single-producer / single-consumer lock-free ring buffer of trivially
// copyable value `Element`s. It is the value-at-a-time sibling of RealtimeRing
// (which does bulk Float copies with wrap-around); the realtime threads in this
// project push/pop fixed-size structs (MIDI commands, observed events) one at a
// time, so a generic element ring removes the copy-paste between them.
//
// Realtime contract (whichever end is the render thread):
//   - `push(_:)` and `pop(into:)` are each called from a single, fixed thread.
//     Both are wait-free and allocation-free.
//   - On overflow `push` drops the element (returns false) rather than blocking —
//     dropping under overload is the correct non-essential failure mode here.
//
// Head/tail are ever-increasing atomic counters with acquire/release ordering so
// the consumer never observes a slot before the producer finished writing it
// (and vice-versa). Storage is allocated once at construction.
//
// `Element` must be a trivial value type (no ARC) so copies on the realtime
// thread never retain/release.
public final class SPSCRing<Element>: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Element>
    private let capacity: Int
    private let head = UnsafeAtomic<Int>.create(0) // total written (producer)
    private let tail = UnsafeAtomic<Int>.create(0) // total read (consumer)

    /// Create a ring that can hold `capacity` elements. `empty` seeds the backing
    /// storage; its value is never read (slots are written before they are read),
    /// it exists only to initialize the buffer.
    public init(capacity: Int, empty: Element) {
        precondition(capacity > 0, "ring capacity must be positive")
        self.capacity = capacity
        let buf = UnsafeMutableBufferPointer<Element>.allocate(capacity: capacity)
        buf.initialize(repeating: empty)
        self.storage = buf
    }

    deinit {
        storage.deallocate()
        head.destroy()
        tail.destroy()
    }

    /// Number of elements currently available to read.
    public var availableToRead: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        return h - t
    }

    /// Producer side. Enqueues one element, returning false if the ring is full
    /// (the element is dropped). Wait-free.
    @discardableResult
    public func push(_ element: Element) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if h - t >= capacity { return false } // full: drop
        storage[h % capacity] = element
        // Release so the consumer sees the element write before the new head.
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// Consumer side. Pops the oldest element into `out`, returning true if one
    /// was available. Wait-free and allocation-free.
    @discardableResult
    public func pop(into out: inout Element) -> Bool {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        if h - t <= 0 { return false } // empty
        out = storage[t % capacity]
        // Release so the producer sees freed space after we've copied out.
        tail.store(t + 1, ordering: .releasing)
        return true
    }
}

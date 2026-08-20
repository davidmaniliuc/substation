import Foundation
import Synchronization

/// Single-producer / single-consumer float ring.
///
/// The producer is the emulator thread and the consumer is the CoreAudio render
/// callback, which may never block and may never allocate — so this holds one
/// preallocated buffer and two atomics, and no lock.
///
/// The two indices are monotonically increasing and masked on use, so `filled`
/// is a plain subtraction and a full ring is distinguishable from an empty one
/// without wasting a slot.
final class AudioRing: @unchecked Sendable {
    let capacity: Int

    private let buffer: UnsafeMutablePointer<Float>
    private let mask: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two so the index masking is a
    /// bitwise AND rather than a modulo in the audio callback.
    init(capacity: Int) {
        let rounded = max(2, capacity).nextPowerOfTwo
        self.capacity = rounded
        self.mask = rounded - 1
        self.buffer = .allocate(capacity: rounded)
        self.buffer.initialize(repeating: 0, count: rounded)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    var filled: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    var freeSpace: Int { capacity - filled }

    /// Producer side. Writes as much as fits and returns how much that was;
    /// it never overwrites unread samples.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        guard n > 0 else { return 0 }

        for i in 0..<n {
            buffer[(w + i) & mask] = src[i]
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer side. Returns how many samples were actually available; on
    /// underrun that is fewer than asked for, and the caller writes silence.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, w - r)
        guard n > 0 else { return 0 }

        for i in 0..<n {
            dst[i] = buffer[(r + i) & mask]
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }
}

private extension Int {
    var nextPowerOfTwo: Int {
        guard self > 1 else { return 1 }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}

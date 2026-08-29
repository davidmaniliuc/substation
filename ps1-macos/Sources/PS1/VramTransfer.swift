import Foundation

/// The CPU->VRAM (GP0(A0)) transfer FSM, mirroring `vram.zig:51-115`.
///
/// Extracted so `ShadowVram` and the Metal encoder share ONE transcription.
/// Phase B is a second rasterizer by necessity, and the spec's mitigation is
/// that no THIRD one appears — this is that mitigation, made structural.
///
/// It owns the cursor and nothing else: bounds checking and the E6 mask belong
/// to whoever does the writing, because the shadow clips in Swift and the GPU
/// clips by construction of the instance box.
struct VramTransfer {
    /// The pixels one 32-bit word produces: two, or one when the second would
    /// fall past the end of an odd-sized transfer. Returned by value rather
    /// than through a closure so the caller can mutate its own storage without
    /// an exclusivity conflict against the transfer it is driving.
    struct WordPixels {
        private(set) var count = 0
        private var xs = (0, 0)
        private var ys = (0, 0)
        private var vs: (UInt16, UInt16) = (0, 0)

        subscript(i: Int) -> (x: Int, y: Int, value: UInt16) {
            i == 0 ? (xs.0, ys.0, vs.0) : (xs.1, ys.1, vs.1)
        }

        fileprivate mutating func append(_ x: Int, _ y: Int, _ v: UInt16) {
            if count == 0 { xs.0 = x; ys.0 = y; vs.0 = v } else { xs.1 = x; ys.1 = y; vs.1 = v }
            count += 1
        }
    }

    private(set) var active = false
    private(set) var x = 0, y = 0, w = 0, h = 0
    /// Pixel index within the transfer. `currX`/`currY` are derived from it,
    /// which is exactly `vram.zig`'s wrap-at-write_w behaviour with one
    /// variable instead of two.
    private var cursor = 0
    private var remaining = 0

    /// A transfer's width and height are taken modulo the VRAM axis, so 0
    /// means the WHOLE AXIS rather than an empty rectangle.
    static func axisExtent(_ size: Int, _ full: Int) -> Int { size == 0 ? full : size }

    var currX: Int { w == 0 ? 0 : cursor % w }
    var currY: Int { w == 0 ? 0 : cursor / w }
    var pixelCount: Int { w * h }

    mutating func setup(x: Int, y: Int, w: Int, h: Int) {
        self.w = Self.axisExtent(w, 1024)
        self.h = Self.axisExtent(h, 512)
        self.x = x
        self.y = y
        cursor = 0
        remaining = (self.w * self.h + 1) / 2
        active = remaining > 0
    }

    mutating func abort() { active = false }

    mutating func consume(_ value: UInt32) -> WordPixels {
        var out = WordPixels()
        guard active else { return out }
        out.append(x + currX, y + currY, UInt16(truncatingIfNeeded: value))
        cursor += 1
        if cursor < pixelCount {
            out.append(x + currX, y + currY, UInt16(truncatingIfNeeded: value >> 16))
            cursor += 1
        }
        if remaining > 0 { remaining -= 1 }
        if remaining == 0 { active = false }
        return out
    }

    /// Advances by up to `words` words in one go and reports the contiguous
    /// slice of transfer PIXEL INDICES that run covers. A run always starts on
    /// an even pixel index, because every word writes two, which is what lets
    /// the shader recover the word from the pixel with a single shift.
    mutating func plan(words n: Int) -> (first: Int, last: Int, consumed: Int)? {
        guard active, n > 0 else { return nil }
        let first = cursor
        let consumed = min(n, remaining)
        let after = min(first + 2 * consumed, pixelCount)
        cursor = after
        remaining -= consumed
        if remaining == 0 { active = false }
        guard after > first else { return nil }
        return (first, after - 1, consumed)
    }
}

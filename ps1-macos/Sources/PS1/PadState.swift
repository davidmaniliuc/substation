import Foundation

/// The two sticks as the pad reports them: one byte per axis, 0x80 centred,
/// Y growing DOWN, the convention `ps1_set_analog` takes.
struct Sticks: Equatable, Sendable {
    var lx: UInt8 = 0x80
    var ly: UInt8 = 0x80
    var rx: UInt8 = 0x80
    var ry: UInt8 = 0x80

    static let centred = Sticks()

    init(lx: UInt8 = 0x80, ly: UInt8 = 0x80, rx: UInt8 = 0x80, ry: UInt8 = 0x80) {
        self.lx = lx; self.ly = ly; self.rx = rx; self.ry = ry
    }

    /// From GameController's -1...1, whose Y grows UP.
    init(leftX: Float, leftY: Float, rightX: Float, rightY: Float) {
        self.init(lx: Self.byte(leftX), ly: Self.byte(-leftY),
                  rx: Self.byte(rightX), ry: Self.byte(-rightY))
    }

    /// No deadzone here: GameController applies one, and games their own.
    static func byte(_ v: Float) -> UInt8 {
        UInt8(((min(max(v, -1), 1) + 1) * 127.5).rounded())
    }

    /// One word, so it crosses to the emulator thread through an `Atomic`.
    var packed: UInt32 {
        UInt32(lx) | UInt32(ly) << 8 | UInt32(rx) << 16 | UInt32(ry) << 24
    }

    init(packed v: UInt32) {
        self.init(lx: UInt8(truncatingIfNeeded: v), ly: UInt8(truncatingIfNeeded: v >> 8),
                  rx: UInt8(truncatingIfNeeded: v >> 16), ry: UInt8(truncatingIfNeeded: v >> 24))
    }
}

/// What the pad tells the host after a frame: its mode LED and both motors.
struct PadStatus: Equatable, Sendable {
    var analog: Bool
    /// 0 or 255: the small motor has one speed.
    var small: UInt8
    var large: UInt8

    static let idle = PadStatus(analog: false, small: 0, large: 0)

    init(analog: Bool, small: UInt8, large: UInt8) {
        self.analog = analog; self.small = small; self.large = large
    }

    var packed: UInt32 {
        (analog ? 1 : 0) | UInt32(small) << 8 | UInt32(large) << 16
    }

    init(packed v: UInt32) {
        self.init(analog: v & 1 != 0, small: UInt8(truncatingIfNeeded: v >> 8),
                  large: UInt8(truncatingIfNeeded: v >> 16))
    }
}

import Foundation

/// One bit each, in `sio.zig`'s packet order: byte 0 is the low half, byte 1
/// the high half. The raw value IS the bit mask.
enum PadButton: UInt16, CaseIterable {
    case select   = 0x0001
    case l3       = 0x0002
    case r3       = 0x0004
    case start    = 0x0008
    case up       = 0x0010
    case right    = 0x0020
    case down     = 0x0040
    case left     = 0x0080
    case l2       = 0x0100
    case r2       = 0x0200
    case l1       = 0x0400
    case r1       = 0x0800
    case triangle = 0x1000
    case circle   = 0x2000
    case cross    = 0x4000
    case square   = 0x8000
}

/// Accumulates pressed buttons into the mask the core wants.
///
/// The inversion is the whole point: the pad reports **0 for pressed**, so idle
/// is 0xFFFF and pressing CLEARS a bit. Getting this backwards makes every
/// button appear held down at once, which reads as a stuck controller.
struct InputMap {
    private var pressed: UInt16 = 0
    /// Centred for the keyboard, which has no sticks.
    var sticks = Sticks.centred

    var mask: UInt16 { ~pressed }

    mutating func press(_ b: PadButton) { pressed |= b.rawValue }
    mutating func release(_ b: PadButton) { pressed &= ~b.rawValue }
    mutating func reset() {
        pressed = 0
        sticks = .centred
    }
}

/// Anything a key can be bound to: a pad button, or the Analog button, which
/// is not in the button mask (the pad handles it itself).
enum PadControl: Hashable {
    case button(PadButton)
    case analog

    var title: String {
        switch self {
        case .button(let b): return b.title
        case .analog: return "Analog"
        }
    }
}

extension PadButton {
    /// The name printed on the pad, for the Settings window.
    var title: String {
        switch self {
        case .select: return "Select"
        case .l3: return "L3"
        case .r3: return "R3"
        case .start: return "Start"
        case .up: return "D-Pad Up"
        case .right: return "D-Pad Right"
        case .down: return "D-Pad Down"
        case .left: return "D-Pad Left"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l1: return "L1"
        case .r1: return "R1"
        case .triangle: return "Triangle △"
        case .circle: return "Circle ○"
        case .cross: return "Cross ✕"
        case .square: return "Square □"
        }
    }
}

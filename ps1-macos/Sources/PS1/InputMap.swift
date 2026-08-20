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

    var mask: UInt16 { ~pressed }

    mutating func press(_ b: PadButton) { pressed |= b.rawValue }
    mutating func release(_ b: PadButton) { pressed &= ~b.rawValue }
    mutating func reset() { pressed = 0 }

    /// macOS virtual key codes. WASD is deliberately absent: the D-pad is on
    /// the arrows and the face buttons are on the right hand.
    static func button(forKey keyCode: UInt16) -> PadButton? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 6:   return .cross     // Z
        case 7:   return .square    // X
        case 8:   return .circle    // C
        case 9:   return .triangle  // V
        case 36:  return .start     // Return
        case 49:  return .select    // Space
        case 12:  return .l1        // Q
        case 13:  return .r1        // W
        case 0:   return .l2        // A
        case 1:   return .r2        // S
        default:  return nil
        }
    }
}

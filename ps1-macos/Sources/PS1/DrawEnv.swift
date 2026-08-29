import Foundation
import CPs1

/// GP0(E1)-(E6) plus GP1(09), mirroring `ps1-core/src/gpu/registers.zig`'s
/// `DrawingEnv`.
///
/// A second transcription, accepted knowingly: the encoder needs the resolved
/// values on the CPU to write them into each instance record, and reaching
/// into the Zig struct across the C ABI would make the layout of an internal
/// type part of the contract. It is 60 lines of pure bit arithmetic with no
/// state machine in it, and the fixture ladder checks it end to end.
struct DrawEnv {
    var drawMode: UInt32 = 0      // E1
    var texWindow: UInt32 = 0     // E2
    var areaTopLeft: UInt32 = 0   // E3
    var areaBotRight: UInt32 = 0  // E4
    var offset: UInt32 = 0        // E5
    var maskBit: UInt32 = 0       // E6

    /// GP1(09): until the BIOS enables it, E1 bit 11 is forced to 0 wherever
    /// it would otherwise be written.
    var textureDisableAllowed = false

    /// E1 bits a textured polygon's texpage word writes through: texpage x/y,
    /// semi-transparency mode, texture colour depth (bits 0-8) and texture
    /// disable (bit 11).
    static let e1TexpageMask: UInt32 = 0b0000_1001_1111_1111

    mutating func apply(_ cmd: Ps1GpuCommand) {
        switch cmd.commandKind {
        case PS1_GPU_SET_DRAW_ENV:
            switch cmd.opcode {
            case 0xE1: drawMode = maskTextureDisable(cmd.value)
            case 0xE2: texWindow = cmd.value
            case 0xE3: areaTopLeft = cmd.value
            case 0xE4: areaBotRight = cmd.value
            case 0xE5: offset = cmd.value
            case 0xE6: maskBit = cmd.value
            default: break
            }
        case PS1_GPU_LATCH_TEXPAGE:
            let new = maskTextureDisable(UInt32(cmd.tpage) & Self.e1TexpageMask)
            drawMode = (drawMode & ~Self.e1TexpageMask) | new
        case PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED:
            textureDisableAllowed = cmd.value != 0
        case PS1_GPU_RESET_DRAW_ENV:
            self = DrawEnv()
        default:
            break
        }
    }

    private func maskTextureDisable(_ v: UInt32) -> UInt32 {
        textureDisableAllowed ? v : v & ~(UInt32(1) << 11)
    }

    /// Two 11-bit SIGNED fields. 0x7FF is -1, not 2047.
    var offsetX: Int { Self.sext11(offset & 0x7FF) }
    var offsetY: Int { Self.sext11((offset >> 11) & 0x7FF) }

    private static func sext11(_ v: UInt32) -> Int {
        let x = Int(v)
        return x >= 0x400 ? x - 0x800 : x
    }

    /// The drawing area, INCLUSIVE on both ends. Two 10-bit fields per
    /// register, x in the low half.
    var clip: (x0: Int, y0: Int, x1: Int, y1: Int) {
        (Int(areaTopLeft & 0x3FF), Int((areaTopLeft >> 10) & 0x3FF),
         Int(areaBotRight & 0x3FF), Int((areaBotRight >> 10) & 0x3FF))
    }

    var ditherEnabled: Bool { (drawMode & (1 << 9)) != 0 }
    var blendMode: UInt32 { (drawMode >> 5) & 3 }
    var maskSet: Bool { (maskBit & 1) != 0 }
    var maskCheck: Bool { (maskBit & 2) != 0 }
}

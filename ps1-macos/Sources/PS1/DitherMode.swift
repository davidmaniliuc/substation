import Foundation

/// Where the rasterizer samples the 4x4 ordered-dither pattern.
///
/// The offsets are hardware and the table is not a setting; the coordinate
/// that indexes it above 1x is, because off the native lattice there is no
/// hardware answer to reproduce. The three modes are declared in
/// `PrimInstance.h`, which both the Metal compiler and this module read, and
/// `ditherModeRawValuesMatchTheShaderHeader` pins these raw values to them.
///
/// What the player actually sees:
///
/// - `.scaled` samples per subtexel. The pattern stays four screen pixels wide
///   at every resolution, so it disappears into the picture and a Gouraud ramp
///   reads as a smooth gradient. This is the default.
/// - `.native` samples per native pixel, giving every subtexel of a pixel that
///   pixel's own 1x offset. Faithful to what the console put on a CRT, but
///   at 8x the cross-hatch is 8-by-8 blocks and plainly visible.
/// - `.off` quantises straight to 5 bits, which is 32 levels per channel and
///   shows as hard banding on any slow gradient — Crash Bandicoot's sand is
///   the standing example.
///
/// At 1x `.native` and `.scaled` are the same expression, so the shipped
/// default resolution renders byte-identically under either and neither can
/// move the Gate 1 fixture hashes.
public enum DitherMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case native = 1
    case scaled = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .native: return "Native (Accurate)"
        case .scaled: return "Scaled (Smooth)"
        }
    }

    /// The value `Ps1RasterUniforms.dither_mode` carries.
    public var uniformValue: UInt32 { UInt32(rawValue) }
}

/// The persisted dither setting: where it is stored, and a load that REJECTS.
///
/// A type of its own for the same reason `InternalResolution` is one — the
/// load rule is reachable from a test without a window — and the same shape:
/// `init` resolves, `set` persists.
///
/// It reads `object(forKey:)` rather than `integer(forKey:)`, and that is the
/// whole difference from `InternalResolution`. There, 0 is outside `range`, so
/// the 0 that `integer(forKey:)` invents for a missing key is lifted to the
/// default by the clamp. Here 0 is a VALID mode — `.off`, the worst-looking of
/// the three — so an absent key would read back as a deliberate choice of it.
/// An unrecognised stored value falls back the same way: a `UserDefaults`
/// integer is DATA, not a literal.
struct DitherSetting {
    static let defaultsKey = "ditherMode"
    /// Smooth, not accurate. At the shipped 1x it is byte-identical to
    /// `.native`, so this only decides what a player who has already chosen a
    /// higher internal resolution sees — and they chose it for the picture.
    static let defaultMode = DitherMode.scaled

    private let defaults: UserDefaults
    private let key: String
    private(set) var mode: DitherMode

    init(key: String = DitherSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        if let raw = defaults.object(forKey: key) as? Int,
           let stored = DitherMode(rawValue: raw) {
            self.mode = stored
        } else {
            self.mode = Self.defaultMode
        }
    }

    mutating func set(_ value: DitherMode) {
        mode = value
        defaults.set(value.rawValue, forKey: key)
    }
}

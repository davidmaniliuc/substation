import Foundation

/// Where the rasterizer samples the 4x4 ordered-dither pattern.
///
/// The offsets are hardware and the table is not a setting; the coordinate
/// that indexes it above 1x is, because off the native lattice there is no
/// hardware answer to reproduce. The four modes are declared in
/// `PrimInstance.h`, which both the Metal compiler and this module read, and
/// `ditherModeRawValuesMatchTheShaderHeader` pins these raw values to them.
///
/// What the player actually sees:
///
/// - `.scaled` samples per subtexel. The pattern stays four screen pixels wide
///   at every resolution, so it disappears into the picture and a Gouraud ramp
///   reads as a smooth gradient.
/// - `.native` samples per native pixel, giving every subtexel of a pixel that
///   pixel's own 1x offset. Faithful to what the console put on a CRT, but
///   at 8x the cross-hatch is 8-by-8 blocks and plainly visible.
/// - `.off` quantises straight to 5 bits, which is 32 levels per channel and
///   shows as hard banding on any slow gradient — Crash Bandicoot's sand is
///   the standing example.
/// - `.trueColor` turns dithering off and keeps the pre-truncation eight-bit
///   colour in a display-only sidecar texture, so a shading ramp has 256 levels
///   per channel instead of 32 — on a textured surface as well as an untextured
///   one, which took a second fix: the modulation crops its shade to five bits
///   for VRAM's value and must not for the sidecar's. VRAM is written exactly
///   as it is at `.off`, so nothing a gate reads can move — which is what lets
///   this be the default at every internal resolution, 1x included.
///   DuckStation has to rebuild pipelines for the equivalent setting and gives
///   up bit-exactness to get the smoothness; we give up neither.
///
/// At 1x `.native` and `.scaled` are the same expression, so the shipped
/// default resolution renders byte-identically under either and neither can
/// move the Gate 1 fixture hashes.
public enum DitherMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case native = 1
    case scaled = 2
    case trueColor = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .native: return "Native (Accurate)"
        case .scaled: return "Scaled (Smooth)"
        case .trueColor: return "True Colour"
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
/// the four — so an absent key would read back as a deliberate choice of it.
/// An unrecognised stored value falls back the same way: a `UserDefaults`
/// integer is DATA, not a literal.
struct DitherSetting {
    static let defaultsKey = "ditherMode"
    /// Eight bits per channel, and no dither pattern at all.
    ///
    /// It can be the default at every internal resolution — 1x included —
    /// because VRAM is written exactly as it is at `.off`: no fixture hash
    /// moves, downsample-invariance is untouched, and `PS1_LIVE_DIFF` compares
    /// the same bytes it always did. `.scaled`, the previous default, knowingly
    /// traded downsample-invariance above 1x for its smoother pattern; this
    /// trades nothing.
    ///
    /// What it DOES change is which divergence class `PS1_LIVE_DIFF` reports:
    /// the software shadow dithers and this does not, so at the shipped default
    /// the oracle is as loud as it is at `.off`. Switch to `.native` before
    /// reading anything into a run.
    static let defaultMode = DitherMode.trueColor

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

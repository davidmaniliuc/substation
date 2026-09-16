import Foundation

/// PGXP geometry correction and its six sub-settings.
///
/// Shaped after `InternalResolution` — `init` resolves from `UserDefaults`,
/// `set` persists, and the rule lives in the type so it is reachable from a
/// test without a window.
///
/// `enabled` defaults OFF, and for the same reason internal resolution
/// defaults to 1×: off is the configuration the byte-exact oracle covers.
/// Selecting PGXP opts out of that knowingly; the shipped configuration must
/// not opt out for the player.
///
/// The other six are SUB-SETTINGS, not peers. Each is ANDed with `enabled`
/// inside the core, so one set while geometry correction is off does nothing
/// at all — which is why the menu disables rather than merely ignores them.
///
/// Four of them invert this type's original reasoning and the inversion is a
/// trap rather than a style note. `enabled` and `vertexCache` can be read with
/// `bool(forKey:)` precisely because they default to false and false is what a
/// missing key returns. `cpu`, `culling` and `textureCorrection` default to
/// TRUE and `tolerance` to -1, so for those four absence has to be probed with
/// `object(forKey:)`, the way `MultiDiscSetting` and `VolumeSetting` do, or the
/// setting ships wrong on every first launch. For `tolerance` there is a
/// second reason: 0 is a legitimate value — it admits only a candidate exactly
/// on the integer grid — and `float(forKey:)` cannot tell it from an absent
/// key. `colorCorrection` is the third setting that defaults false — like
/// `enabled` and `vertexCache`, `bool(forKey:)` would give the right answer
/// for a missing key — but it still probes with `object(forKey:)` anyway, for
/// uniformity with the other sub-settings rather than necessity: the next
/// default-ON setting added beside it must not inherit a probe-free idiom
/// that happens to work only for `false`.
struct PgxpSetting {
    static let defaultsKey = "pgxpEnabled"

    private let defaults: UserDefaults
    private let key: String

    private(set) var enabled: Bool
    /// Propagation through ordinary CPU arithmetic. Ships ON, unlike in the
    /// reference — measured, it is the difference between PGXP working and not
    /// working at all. See `Bus.pgxp_cpu`.
    private(set) var cpu: Bool
    /// Float NCLIP. The one sub-setting that ships on.
    private(set) var culling: Bool
    /// The position-keyed second lookup. 83 MB while on.
    private(set) var vertexCache: Bool
    /// How far a candidate may sit from its integer vertex, in pixels.
    /// Negative disables the check.
    private(set) var tolerance: Float
    /// Perspective-correct texturing. Ships ON, like `culling` — these two are
    /// the picture, where `cpu` and `vertexCache` are the workarounds.
    private(set) var textureCorrection: Bool
    /// Perspective-correct vertex colour. Ships OFF, unlike `culling` and
    /// `textureCorrection`: it is the one correction the reference carries a
    /// per-game disable list for, and a feature with a per-game disable list in
    /// the reference is not a feature to default on.
    private(set) var colorCorrection: Bool

    private var cpuKey: String { key + ".cpu" }
    private var cullingKey: String { key + ".culling" }
    private var vertexCacheKey: String { key + ".vertexCache" }
    private var toleranceKey: String { key + ".tolerance" }
    private var textureCorrectionKey: String { key + ".textureCorrection" }
    private var colorCorrectionKey: String { key + ".colorCorrection" }

    init(key: String = PgxpSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.bool(forKey: key)
        self.cpu = (defaults.object(forKey: key + ".cpu") as? NSNumber)?.boolValue ?? true
        self.vertexCache = defaults.bool(forKey: key + ".vertexCache")
        self.culling = (defaults.object(forKey: key + ".culling") as? NSNumber)?.boolValue ?? true
        self.tolerance = (defaults.object(forKey: key + ".tolerance") as? NSNumber)?.floatValue ?? -1
        self.textureCorrection =
            (defaults.object(forKey: key + ".textureCorrection") as? NSNumber)?.boolValue ?? true
        self.colorCorrection =
            (defaults.object(forKey: key + ".colorCorrection") as? NSNumber)?.boolValue ?? false
    }

    mutating func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: key)
    }

    mutating func setCpu(_ value: Bool) {
        cpu = value
        defaults.set(value, forKey: cpuKey)
    }

    mutating func setCulling(_ value: Bool) {
        culling = value
        defaults.set(value, forKey: cullingKey)
    }

    mutating func setVertexCache(_ value: Bool) {
        vertexCache = value
        defaults.set(value, forKey: vertexCacheKey)
    }

    mutating func setTolerance(_ value: Float) {
        tolerance = value
        defaults.set(value, forKey: toleranceKey)
    }

    mutating func setTextureCorrection(_ value: Bool) {
        textureCorrection = value
        defaults.set(value, forKey: textureCorrectionKey)
    }

    mutating func setColorCorrection(_ value: Bool) {
        colorCorrection = value
        defaults.set(value, forKey: colorCorrectionKey)
    }
}

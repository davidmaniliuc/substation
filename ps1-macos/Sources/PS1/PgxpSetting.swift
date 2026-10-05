import Foundation

/// PGXP geometry correction and its six sub-settings.
///
/// Shaped after `InternalResolution`: `init` resolves from `UserDefaults`,
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
/// at all, which is why the menu disables rather than merely ignores them.
///
/// Four of them invert this type's original reasoning and the inversion is a
/// trap rather than a style note. `enabled` and `vertexCache` can be read with
/// `bool(forKey:)` precisely because they default to false and false is what a
/// missing key returns. `cpu`, `culling` and `textureCorrection` default to
/// TRUE and `tolerance` to -1, so for those four absence has to be probed with
/// `object(forKey:)`, the way `MultiDiscSetting` and `VolumeSetting` do, or the
/// setting ships wrong on every first launch. For `tolerance` there is a
/// second reason: 0 is a legitimate value (it admits only a candidate exactly
/// on the integer grid), and `float(forKey:)` cannot tell it from an absent
/// key. `colorCorrection` is the third setting that defaults false (like
/// `enabled` and `vertexCache`, `bool(forKey:)` would give the right answer
/// for a missing key), but it still probes with `object(forKey:)` anyway, for
/// uniformity with the other sub-settings rather than necessity: the next
/// default-ON setting added beside it must not inherit a probe-free idiom
/// that happens to work only for `false`.
struct PgxpSetting {
    static let defaultsKey = "pgxpEnabled"

    private let defaults: UserDefaults
    private let key: String

    private(set) var enabled: Bool
    /// Propagation through ordinary CPU arithmetic. Ships ON, unlike in the
    /// reference: measured, it is the difference between PGXP working and not
    /// working at all. See `Bus.pgxp_cpu`.
    private(set) var cpu: Bool
    /// Float NCLIP. The one sub-setting that ships on.
    private(set) var culling: Bool
    /// The position-keyed second lookup. 83 MB while on.
    private(set) var vertexCache: Bool
    /// How far a candidate may sit from its integer vertex, in pixels.
    /// Negative disables the check.
    private(set) var tolerance: Float
    /// Perspective-correct texturing. Ships ON, like `culling`: these two are
    /// the picture, where `cpu` and `vertexCache` are the workarounds.
    private(set) var textureCorrection: Bool
    /// Perspective-correct vertex colour. Ships OFF, unlike `culling` and
    /// `textureCorrection`: it is the one correction the reference carries a
    /// per-game disable list for, and a feature with a per-game disable list in
    /// the reference is not a feature to default on.
    private(set) var colorCorrection: Bool

    /// The PGXP depth buffer. Ships OFF, like `colorCorrection`: `object(forKey:)`
    /// is read anyway for the same uniformity reason, not because `bool(forKey:)`
    /// would give the wrong answer for a missing key.
    private(set) var depthBuffer: Bool
    /// Transparent polygons test but never write the depth buffer. OFF by
    /// default; acts only while `depthBuffer` is also on.
    private(set) var transparentDepth: Bool
    /// A primitive whose positions resolved but which lacks depths is drawn at
    /// integer positions. OFF by default.
    private(set) var disable2d: Bool
    /// Project from the GTE's exact accumulator instead of its rounded
    /// registers. OFF by default, the reference's own.
    private(set) var preserveProjection: Bool

    private var cpuKey: String { key + ".cpu" }
    private var cullingKey: String { key + ".culling" }
    private var vertexCacheKey: String { key + ".vertexCache" }
    private var toleranceKey: String { key + ".tolerance" }
    private var textureCorrectionKey: String { key + ".textureCorrection" }
    private var colorCorrectionKey: String { key + ".colorCorrection" }
    private var depthBufferKey: String { key + ".depthBuffer" }
    private var transparentDepthKey: String { key + ".transparentDepth" }
    private var disable2dKey: String { key + ".disable2d" }
    private var preserveProjectionKey: String { key + ".preserveProjection" }

    init(key: String = PgxpSetting.defaultsKey,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        self.enabled = defaults.bool(forKey: key)
        self.cpu = (defaults.object(forKey: key + ".cpu") as? NSNumber)?.boolValue ?? Shipped.cpu
        self.vertexCache = defaults.bool(forKey: key + ".vertexCache")
        self.culling = (defaults.object(forKey: key + ".culling") as? NSNumber)?.boolValue ?? Shipped.culling
        self.tolerance =
            (defaults.object(forKey: key + ".tolerance") as? NSNumber)?.floatValue ?? Shipped.tolerance
        self.textureCorrection =
            (defaults.object(forKey: key + ".textureCorrection") as? NSNumber)?.boolValue
            ?? Shipped.textureCorrection
        self.colorCorrection =
            (defaults.object(forKey: key + ".colorCorrection") as? NSNumber)?.boolValue
            ?? Shipped.colorCorrection
        self.depthBuffer =
            (defaults.object(forKey: key + ".depthBuffer") as? NSNumber)?.boolValue ?? Shipped.depthBuffer
        self.transparentDepth =
            (defaults.object(forKey: key + ".transparentDepth") as? NSNumber)?.boolValue
            ?? Shipped.transparentDepth
        self.disable2d =
            (defaults.object(forKey: key + ".disable2d") as? NSNumber)?.boolValue ?? Shipped.disable2d
        self.preserveProjection =
            (defaults.object(forKey: key + ".preserveProjection") as? NSNumber)?.boolValue
            ?? Shipped.preserveProjection
    }

    /// The value each setting takes when its key is absent. `enabled` and
    /// `vertexCache` are read with `bool(forKey:)`, whose missing-key answer
    /// is already theirs; they are listed so `isDefault` has one table to read.
    private enum Shipped {
        static let enabled = false
        static let cpu = true
        static let culling = true
        static let vertexCache = false
        static let tolerance: Float = -1
        static let textureCorrection = true
        static let colorCorrection = false
        static let depthBuffer = false
        static let transparentDepth = false
        static let disable2d = false
        static let preserveProjection = false
    }

    /// Whether every value is the shipped one, whatever is stored. A setting
    /// turned on and back off reads as default here though its key remains.
    var isDefault: Bool {
        enabled == Shipped.enabled && cpu == Shipped.cpu && culling == Shipped.culling
            && vertexCache == Shipped.vertexCache && tolerance == Shipped.tolerance
            && textureCorrection == Shipped.textureCorrection
            && colorCorrection == Shipped.colorCorrection && depthBuffer == Shipped.depthBuffer
            && transparentDepth == Shipped.transparentDepth && disable2d == Shipped.disable2d
            && preserveProjection == Shipped.preserveProjection
    }

    /// Removes every key, so the next launch reads the shipped values as a
    /// first launch does, and a later change to a default reaches this player.
    mutating func restoreDefaults() {
        for k in [key, cpuKey, cullingKey, vertexCacheKey, toleranceKey, textureCorrectionKey,
                  colorCorrectionKey, depthBufferKey, transparentDepthKey, disable2dKey,
                  preserveProjectionKey] {
            defaults.removeObject(forKey: k)
        }
        self = PgxpSetting(key: key, defaults: defaults)
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

    mutating func setDepthBuffer(_ value: Bool) {
        depthBuffer = value
        defaults.set(value, forKey: depthBufferKey)
    }

    mutating func setTransparentDepth(_ value: Bool) {
        transparentDepth = value
        defaults.set(value, forKey: transparentDepthKey)
    }

    mutating func setDisable2d(_ value: Bool) {
        disable2d = value
        defaults.set(value, forKey: disable2dKey)
    }

    mutating func setPreserveProjection(_ value: Bool) {
        preserveProjection = value
        defaults.set(value, forKey: preserveProjectionKey)
    }
}

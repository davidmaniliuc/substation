import Foundation

/// Where downloaded covers come from: a URL template with `${serial}` in it.
///
/// A template rather than a hardcoded URL, which is the shape DuckStation's
/// own cover downloader uses — it makes the 2D/3D choice one setting instead
/// of two code paths, and lets any other serial-keyed collection be pointed at
/// without a build.
///
/// The default is a FORK of `xlenore/psx-covers` rather than the upstream
/// repo: a fork cannot be renamed, retired or restructured out from under the
/// library, and covers the collection is missing can be added to it directly.
struct CoverSource: Equatable, Sendable {
    /// The scans: square jewel-case fronts, which is what `GameTile` draws at
    /// 1:1.
    static let flat =
        "https://raw.githubusercontent.com/davidmaniliuc/psx-covers/main/covers/default/${serial}.jpg"
    /// Rendered 3D cases. PNG, and a different aspect — they carry a spine.
    static let threeD =
        "https://raw.githubusercontent.com/davidmaniliuc/psx-covers/main/covers/3d/${serial}.png"

    let template: String

    init(template: String = CoverSource.flat) {
        self.template = template
    }

    /// Nil when the template produces nothing a URL can be made of, so a
    /// mistyped setting fails per-disc instead of trapping.
    func url(forSerial serial: String) -> URL? {
        URL(string: template.replacingOccurrences(of: "${serial}", with: serial))
    }
}

/// The chosen template, persisted. Shaped after `InternalResolution`: the
/// default lives in `init`, `set` persists, and both are reachable from a test
/// without a window.
///
/// Unlike `VolumeSetting` the absent key is unambiguous — no template means the
/// default one — so `string(forKey:)` returning nil is all the probe needed.
struct CoverSourceSetting {
    private let defaults: UserDefaults
    private let key = "coverSourceTemplate"

    private(set) var source: CoverSource

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.source = CoverSource(template: defaults.string(forKey: key) ?? CoverSource.flat)
    }

    mutating func set(_ source: CoverSource) {
        self.source = source
        defaults.set(source.template, forKey: key)
    }
}

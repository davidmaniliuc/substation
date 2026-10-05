import CPs1

/// One game's PGXP overrides, from the core's preset table (generated from
/// DuckStation's per-game database). A nil field leaves the player's own
/// setting in force.
///
/// Folded in here rather than applied by the core: the runner re-applies every
/// PGXP setting every frame, so an override set inside the core would be
/// undone on the next one. `EmulatorViewModel.applyPgxp` is where it lands.
struct PgxpPreset: Equatable, Sendable {
    var enabled: Bool?
    var cpu: Bool?
    var culling: Bool?
    var vertexCache: Bool?
    var textureCorrection: Bool?
    var colorCorrection: Bool?
    var depthBuffer: Bool?
    var disable2d: Bool?
    var preserveProjection: Bool?
    var tolerance: Float?

    /// Nil for a disc with no serial, or a game the table does not list.
    static func lookup(serial: String?) -> PgxpPreset? {
        guard let serial, !serial.isEmpty else { return nil }
        var raw = Ps1PgxpPreset()
        guard serial.withCString({ ps1_lookup_pgxp_preset($0, &raw) }) != 0 else { return nil }
        return PgxpPreset(
            enabled: flag(raw.enabled),
            cpu: flag(raw.cpu),
            culling: flag(raw.culling),
            vertexCache: flag(raw.vertex_cache),
            textureCorrection: flag(raw.texture_correction),
            colorCorrection: flag(raw.color_correction),
            depthBuffer: flag(raw.depth_buffer),
            disable2d: flag(raw.disable_2d),
            preserveProjection: flag(raw.preserve_projection),
            tolerance: raw.has_tolerance != 0 ? raw.tolerance : nil)
    }

    /// The ABI's -1 / 0 / 1.
    private static func flag(_ value: Int8) -> Bool? {
        value < 0 ? nil : value != 0
    }

    /// What the preset sets, in the Settings window's own titles, in the order
    /// the Enhancements pane lists them.
    var changes: [String] {
        let switches: [(SettingInfo, Bool?)] = [
            (SettingsCopy.pgxp, enabled),
            (SettingsCopy.textureCorrection, textureCorrection),
            (SettingsCopy.colorCorrection, colorCorrection),
            (SettingsCopy.culling, culling),
            (SettingsCopy.disable2d, disable2d),
            (SettingsCopy.depthBuffer, depthBuffer),
            (SettingsCopy.cpuMode, cpu),
            (SettingsCopy.preserveProjection, preserveProjection),
            (SettingsCopy.vertexCache, vertexCache),
        ]
        var out = switches.compactMap { info, value in
            value.map { "\(info.title) \($0 ? "on" : "off")" }
        }
        if let tolerance {
            out.append("\(SettingsCopy.tolerance.title) \(tolerance.formatted()) px")
        }
        return out
    }
}

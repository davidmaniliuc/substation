import Foundation

extension DitherMode: Codable {}
extension TextureFilter: Codable {}
extension Widescreen: Codable {}
extension Deinterlacing: Codable {}
extension DisplayEffect: Codable {}
extension CpuEngine: Codable {}
extension VramReadbacks: Codable {}

/// PGXP vertex-position tolerance, as a discrete choice matching the Settings
/// picker and the core's per-game presets.
enum PgxpTolerance: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case off = "off"
    case half = "0.5"
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"

    var id: Self { self }

    var floatValue: Float {
        switch self {
        case .off: -1
        case .half: 0.5
        case .one: 1
        case .two: 2
        case .three: 3
        case .four: 4
        }
    }

    var optionalFloat: Float? {
        self == .off ? nil : floatValue
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .half: "0.5 px"
        case .one: "1 px"
        case .two: "2 px"
        case .three: "3 px"
        case .four: "4 px"
        }
    }

    init(floatValue: Float) {
        if floatValue < 0 {
            self = .off
        } else if floatValue <= 0.5 {
            self = .half
        } else if floatValue <= 1 {
            self = .one
        } else if floatValue <= 2 {
            self = .two
        } else if floatValue <= 3 {
            self = .three
        } else {
            self = .four
        }
    }
}

/// Per-game setting overrides for a single game profile.
///
/// Every field is optional: `nil` inherits the global setting. Clearing every
/// field leaves `isEmpty == true`, and `GameOverridesStore` removes the game's
/// record from disk so only games with active overrides are stored.
struct GameOverrides: Codable, Equatable, Sendable {
    // Video
    var internalScale: Int?
    var ditherMode: DitherMode?
    var textureFilter: TextureFilter?
    var spriteFilter: TextureFilter?
    var widescreen: Widescreen?
    var deinterlacing: Deinterlacing?
    var displayEffect: DisplayEffect?
    var vramReadbacks: VramReadbacks?

    // Enhancements (PGXP)
    var pgxpEnabled: Bool?
    var pgxpUsePresets: Bool?
    var pgxpTextureCorrection: Bool?
    var pgxpColorCorrection: Bool?
    var pgxpCulling: Bool?
    var pgxpDisable2d: Bool?
    var pgxpDepthBuffer: Bool?
    var pgxpTransparentDepth: Bool?
    var pgxpCpuMode: Bool?
    var pgxpPreserveProjection: Bool?
    var pgxpVertexCache: Bool?
    var pgxpTolerance: PgxpTolerance?

    // Emulation / Performance
    var cpuEngine: CpuEngine?
    var cpuOverclockEnabled: Bool?
    var cpuOverclockPercent: Int?
    var cdReadSpeedup: Int?
    var cdSeekSpeedup: Int?
    var runaheadFrames: Int?
    var fastBoot: Bool?

    /// Returns a copy with values clamped to their valid ranges and an
    /// `.automatic` VRAM readbacks choice normalised to `nil` (no override).
    func normalized() -> GameOverrides {
        var copy = self
        if let scale = copy.internalScale {
            copy.internalScale = InternalResolution.clamp(scale)
        }
        if copy.vramReadbacks == .automatic {
            copy.vramReadbacks = nil
        }
        if let percent = copy.cpuOverclockPercent {
            let minChoice = CpuOverclockSetting.choices.first ?? 10
            let maxChoice = CpuOverclockSetting.choices.last ?? 1000
            let clamped = min(max(percent, minChoice), maxChoice)
            copy.cpuOverclockPercent = Int((Double(clamped) / 10).rounded()) * 10
        }
        if let read = copy.cdReadSpeedup {
            copy.cdReadSpeedup = min(max(read, CdSpeedupSetting.choices.first ?? 1),
                                     CdSpeedupSetting.choices.last ?? 10)
        }
        if let seek = copy.cdSeekSpeedup {
            copy.cdSeekSpeedup = min(max(seek, CdSpeedupSetting.choices.first ?? 1),
                                     CdSpeedupSetting.choices.last ?? 10)
        }
        if let frames = copy.runaheadFrames {
            copy.runaheadFrames = min(max(frames, 0), RunaheadSetting.maxFrames)
        }
        return copy
    }

    /// Number of settings explicitly overridden on this profile.
    var overrideCount: Int {
        var count = 0
        if internalScale != nil { count += 1 }
        if ditherMode != nil { count += 1 }
        if textureFilter != nil { count += 1 }
        if spriteFilter != nil { count += 1 }
        if widescreen != nil { count += 1 }
        if deinterlacing != nil { count += 1 }
        if displayEffect != nil { count += 1 }
        if let vramReadbacks, vramReadbacks != .automatic { count += 1 }

        if pgxpEnabled != nil { count += 1 }
        if pgxpUsePresets != nil { count += 1 }
        if pgxpTextureCorrection != nil { count += 1 }
        if pgxpColorCorrection != nil { count += 1 }
        if pgxpCulling != nil { count += 1 }
        if pgxpDisable2d != nil { count += 1 }
        if pgxpDepthBuffer != nil { count += 1 }
        if pgxpTransparentDepth != nil { count += 1 }
        if pgxpCpuMode != nil { count += 1 }
        if pgxpPreserveProjection != nil { count += 1 }
        if pgxpVertexCache != nil { count += 1 }
        if pgxpTolerance != nil { count += 1 }

        if cpuEngine != nil { count += 1 }
        if cpuOverclockEnabled != nil { count += 1 }
        if cpuOverclockPercent != nil { count += 1 }
        if cdReadSpeedup != nil { count += 1 }
        if cdSeekSpeedup != nil { count += 1 }
        if runaheadFrames != nil { count += 1 }
        if fastBoot != nil { count += 1 }
        return count
    }

    var isEmpty: Bool { overrideCount == 0 }

    /// Merges per-game overrides over global settings deterministically.
    ///
    /// Any `nil` field inherits from `global`. Numeric fields are clamped to
    /// valid ranges, an unavailable CPU engine falls back to the cached
    /// interpreter, and `legacyVramReadbacks` preserves choices saved in the
    /// existing `VramReadbacksSetting` UserDefaults dictionary.
    static func resolve(
        global: GlobalGameSettings,
        override: GameOverrides?,
        legacyVramReadbacks: VramReadbacks = .automatic,
        isCpuEngineAvailable: (CpuEngine) -> Bool = Ps1Core.isCpuEngineAvailable
    ) -> ResolvedGameSettings {
        let o = override?.normalized() ?? GameOverrides()
        let rawEngine = o.cpuEngine ?? global.cpuEngine
        let engine = isCpuEngineAvailable(rawEngine) ? rawEngine : .cachedInterpreter

        let vram: VramReadbacks = {
            if let explicit = o.vramReadbacks, explicit != .automatic {
                return explicit
            }
            return legacyVramReadbacks
        }()

        return ResolvedGameSettings(
            internalScale: InternalResolution.clamp(o.internalScale ?? global.internalScale),
            ditherMode: o.ditherMode ?? global.ditherMode,
            textureFilter: o.textureFilter ?? global.textureFilter,
            spriteFilter: o.spriteFilter ?? global.spriteFilter,
            widescreen: o.widescreen ?? global.widescreen,
            deinterlacing: o.deinterlacing ?? global.deinterlacing,
            displayEffect: o.displayEffect ?? global.displayEffect,
            vramReadbacks: vram,
            pgxpEnabled: o.pgxpEnabled ?? global.pgxpEnabled,
            pgxpUsePresets: o.pgxpUsePresets ?? global.pgxpUsePresets,
            pgxpTextureCorrection: o.pgxpTextureCorrection ?? global.pgxpTextureCorrection,
            pgxpColorCorrection: o.pgxpColorCorrection ?? global.pgxpColorCorrection,
            pgxpCulling: o.pgxpCulling ?? global.pgxpCulling,
            pgxpDisable2d: o.pgxpDisable2d ?? global.pgxpDisable2d,
            pgxpDepthBuffer: o.pgxpDepthBuffer ?? global.pgxpDepthBuffer,
            pgxpTransparentDepth: o.pgxpTransparentDepth ?? global.pgxpTransparentDepth,
            pgxpCpuMode: o.pgxpCpuMode ?? global.pgxpCpuMode,
            pgxpPreserveProjection: o.pgxpPreserveProjection ?? global.pgxpPreserveProjection,
            pgxpVertexCache: o.pgxpVertexCache ?? global.pgxpVertexCache,
            pgxpTolerance: o.pgxpTolerance ?? global.pgxpTolerance,
            cpuEngine: engine,
            cpuOverclockEnabled: o.cpuOverclockEnabled ?? global.cpuOverclockEnabled,
            cpuOverclockPercent: o.cpuOverclockPercent ?? global.cpuOverclockPercent,
            cdReadSpeedup: o.cdReadSpeedup ?? global.cdReadSpeedup,
            cdSeekSpeedup: o.cdSeekSpeedup ?? global.cdSeekSpeedup,
            runaheadFrames: o.runaheadFrames ?? global.runaheadFrames,
            fastBoot: o.fastBoot ?? global.fastBoot
        )
    }
}

/// Snapshot of the player's global settings that a per-game profile can override.
struct GlobalGameSettings: Equatable, Sendable {
    var internalScale: Int
    var ditherMode: DitherMode
    var textureFilter: TextureFilter
    var spriteFilter: TextureFilter
    var widescreen: Widescreen
    var deinterlacing: Deinterlacing
    var displayEffect: DisplayEffect

    var pgxpEnabled: Bool
    var pgxpUsePresets: Bool
    var pgxpTextureCorrection: Bool
    var pgxpColorCorrection: Bool
    var pgxpCulling: Bool
    var pgxpDisable2d: Bool
    var pgxpDepthBuffer: Bool
    var pgxpTransparentDepth: Bool
    var pgxpCpuMode: Bool
    var pgxpPreserveProjection: Bool
    var pgxpVertexCache: Bool
    var pgxpTolerance: PgxpTolerance

    var cpuEngine: CpuEngine
    var cpuOverclockEnabled: Bool
    var cpuOverclockPercent: Int
    var cdReadSpeedup: Int
    var cdSeekSpeedup: Int
    var runaheadFrames: Int
    var fastBoot: Bool
}

/// Effective settings for one game after merging its overrides over global settings.
struct ResolvedGameSettings: Equatable, Sendable {
    var internalScale: Int
    var ditherMode: DitherMode
    var textureFilter: TextureFilter
    var spriteFilter: TextureFilter
    var widescreen: Widescreen
    var deinterlacing: Deinterlacing
    var displayEffect: DisplayEffect
    var vramReadbacks: VramReadbacks

    var pgxpEnabled: Bool
    var pgxpUsePresets: Bool
    var pgxpTextureCorrection: Bool
    var pgxpColorCorrection: Bool
    var pgxpCulling: Bool
    var pgxpDisable2d: Bool
    var pgxpDepthBuffer: Bool
    var pgxpTransparentDepth: Bool
    var pgxpCpuMode: Bool
    var pgxpPreserveProjection: Bool
    var pgxpVertexCache: Bool
    var pgxpTolerance: PgxpTolerance

    var cpuEngine: CpuEngine
    var cpuOverclockEnabled: Bool
    var cpuOverclockPercent: Int
    var cdReadSpeedup: Int
    var cdSeekSpeedup: Int
    var runaheadFrames: Int
    var fastBoot: Bool

    /// What the session receives for CPU clock: 100 while overclock control is off.
    var cpuOverclockEffective: Int {
        cpuOverclockEnabled ? cpuOverclockPercent : CpuOverclockSetting.defaultPercent
    }

    var pgxpSettings: PgxpSettings {
        PgxpSettings(
            enabled: pgxpEnabled,
            cpu: pgxpCpuMode,
            culling: pgxpCulling,
            vertexCache: pgxpVertexCache,
            textureCorrection: pgxpTextureCorrection,
            colorCorrection: pgxpColorCorrection,
            depthBuffer: pgxpDepthBuffer,
            transparentDepth: pgxpTransparentDepth,
            disable2d: pgxpDisable2d,
            preserveProjection: pgxpPreserveProjection,
            tolerance: pgxpTolerance.optionalFloat
        )
    }

    func sessionSettings(gain: Float, rewindBudget: Int) -> SessionSettings {
        SessionSettings(
            gain: gain,
            cpuEngine: cpuEngine,
            runaheadFrames: runaheadFrames,
            rewindBudget: rewindBudget,
            scale: internalScale,
            dither: ditherMode,
            textureFilter: textureFilter,
            spriteFilter: spriteFilter,
            pgxp: pgxpSettings,
            pgxpUsePresets: pgxpUsePresets,
            vramReadbacks: vramReadbacks,
            cpuOverclock: cpuOverclockEffective,
            displayEffect: displayEffect,
            widescreen: widescreen,
            cdReadSpeedup: cdReadSpeedup,
            cdSeekSpeedup: cdSeekSpeedup,
            deinterlacing: deinterlacing
        )
    }
}

/// Identifies a game in the per-game settings sheet, whether opened from the
/// library or from a running game.
struct GameSettingsTarget: Identifiable, Equatable, Sendable {
    /// Canonical game key: the first disc's serial, else its path hash, so all
    /// discs of a multi-disc game share one profile.
    let key: String
    let title: String
    /// Primary (or currently inserted) disc serial, for PGXP preset lookup and
    /// Automatic VRAM readbacks status.
    let serial: String?
    /// Every disc serial belonging to this game, kept in step with legacy
    /// `VramReadbacksSetting` entries.
    let serials: [String]
    let discCount: Int
    let region: DiscIdentity.Region?
    let coverURL: URL?

    var id: String { key }

    var subtitle: String {
        var parts: [String] = []
        if let serial, !serial.isEmpty { parts.append(serial) }
        if let region { parts.append(GameInfo.region(region)) }
        if discCount > 1 { parts.append("\(discCount) discs") }
        return parts.joined(separator: " · ")
    }
}

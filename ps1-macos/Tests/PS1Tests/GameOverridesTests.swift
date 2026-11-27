import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import PS1

private func makeTempDir(_ prefix: String = "game-overrides") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "game-overrides-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

private func baselineGlobal() -> GlobalGameSettings {
    GlobalGameSettings(
        internalScale: 1,
        ditherMode: .trueColor,
        textureFilter: .nearest,
        spriteFilter: .nearest,
        widescreen: .off,
        deinterlacing: .progressive,
        displayEffect: .none,
        pgxpEnabled: false,
        pgxpUsePresets: true,
        pgxpTextureCorrection: true,
        pgxpColorCorrection: false,
        pgxpCulling: true,
        pgxpDisable2d: false,
        pgxpDepthBuffer: false,
        pgxpTransparentDepth: false,
        pgxpCpuMode: true,
        pgxpPreserveProjection: false,
        pgxpVertexCache: false,
        pgxpTolerance: .off,
        cpuEngine: .recompiler,
        cpuOverclockEnabled: false,
        cpuOverclockPercent: 100,
        cdReadSpeedup: 1,
        cdSeekSpeedup: 1,
        runaheadFrames: 0,
        fastBoot: false
    )
}

private func fullyOverridden() -> GameOverrides {
    GameOverrides(
        internalScale: 6,
        ditherMode: .native,
        textureFilter: .bilinear,
        spriteFilter: .scale2x,
        widescreen: .wide16x9,
        deinterlacing: .adaptive,
        displayEffect: .crt,
        vramReadbacks: .on,
        pgxpEnabled: true,
        pgxpUsePresets: false,
        pgxpTextureCorrection: false,
        pgxpColorCorrection: true,
        pgxpCulling: false,
        pgxpDisable2d: true,
        pgxpDepthBuffer: true,
        pgxpTransparentDepth: true,
        pgxpCpuMode: false,
        pgxpPreserveProjection: true,
        pgxpVertexCache: true,
        pgxpTolerance: .three,
        cpuEngine: .interpreter,
        cpuOverclockEnabled: true,
        cpuOverclockPercent: 250,
        cdReadSpeedup: 4,
        cdSeekSpeedup: 6,
        runaheadFrames: 2,
        fastBoot: true
    )
}

// MARK: - Model & Resolution

@Suite struct GameOverridesModelTests {
    @Test func emptyOverridesHaveZeroCountAndRoundTrip() throws {
        let empty = GameOverrides()
        #expect(empty.isEmpty)
        #expect(empty.overrideCount == 0)

        let data = try JSONEncoder().encode(empty)
        let decoded = try JSONDecoder().decode(GameOverrides.self, from: data)
        #expect(decoded == empty)
        #expect(decoded.isEmpty)
    }

    @Test func partialOverridesEncodeDecodeAndCountAccurately() throws {
        var overrides = GameOverrides()
        overrides.internalScale = 4
        overrides.widescreen = .wide16x10
        overrides.pgxpEnabled = true
        overrides.fastBoot = true

        #expect(!overrides.isEmpty)
        #expect(overrides.overrideCount == 4)

        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode(GameOverrides.self, from: data)
        #expect(decoded == overrides)
        #expect(decoded.ditherMode == nil)
        #expect(decoded.cpuEngine == nil)
    }

    @Test func fullOverridesRoundTripAndCountAll27Fields() throws {
        let full = fullyOverridden()
        #expect(full.overrideCount == 27)
        #expect(!full.isEmpty)

        let data = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(GameOverrides.self, from: data)
        #expect(decoded == full)
    }

    @Test func normalizationClampsRangesAndDropsAutomaticVram() {
        var dirty = GameOverrides()
        dirty.internalScale = 99
        dirty.vramReadbacks = .automatic
        dirty.cpuOverclockPercent = 1234
        dirty.cdReadSpeedup = 0
        dirty.cdSeekSpeedup = 50
        dirty.runaheadFrames = 9

        let clean = dirty.normalized()
        #expect(clean.internalScale == 8)
        #expect(clean.vramReadbacks == nil)
        #expect(clean.cpuOverclockPercent == 1000)
        #expect(clean.cdReadSpeedup == 1)
        #expect(clean.cdSeekSpeedup == 10)
        #expect(clean.runaheadFrames == RunaheadSetting.maxFrames)
        #expect(clean.overrideCount == 5)

        var onlyAuto = GameOverrides()
        onlyAuto.vramReadbacks = .automatic
        #expect(onlyAuto.isEmpty)
        #expect(onlyAuto.normalized().isEmpty)
    }

    @Test func pgxpToleranceRoundTripsFloatsAndCodable() throws {
        for choice in PgxpTolerance.allCases {
            #expect(PgxpTolerance(floatValue: choice.floatValue) == choice)
            let data = try JSONEncoder().encode(choice)
            #expect(try JSONDecoder().decode(PgxpTolerance.self, from: data) == choice)
            #expect(!choice.title.isEmpty)
        }
        #expect(PgxpTolerance.off.optionalFloat == nil)
        #expect(PgxpTolerance.half.optionalFloat == 0.5)
        #expect(PgxpTolerance.four.optionalFloat == 4)
    }

    @Test func resolveInheritsEveryGlobalFieldWhenOverrideIsNilOrEmpty() {
        let global = baselineGlobal()
        for override in [nil, GameOverrides()] {
            let resolved = GameOverrides.resolve(
                global: global,
                override: override,
                legacyVramReadbacks: .off,
                isCpuEngineAvailable: { _ in true }
            )
            #expect(resolved.internalScale == global.internalScale)
            #expect(resolved.ditherMode == global.ditherMode)
            #expect(resolved.textureFilter == global.textureFilter)
            #expect(resolved.spriteFilter == global.spriteFilter)
            #expect(resolved.widescreen == global.widescreen)
            #expect(resolved.deinterlacing == global.deinterlacing)
            #expect(resolved.displayEffect == global.displayEffect)
            #expect(resolved.vramReadbacks == .off)
            #expect(resolved.pgxpEnabled == global.pgxpEnabled)
            #expect(resolved.pgxpUsePresets == global.pgxpUsePresets)
            #expect(resolved.pgxpTextureCorrection == global.pgxpTextureCorrection)
            #expect(resolved.pgxpColorCorrection == global.pgxpColorCorrection)
            #expect(resolved.pgxpCulling == global.pgxpCulling)
            #expect(resolved.pgxpDisable2d == global.pgxpDisable2d)
            #expect(resolved.pgxpDepthBuffer == global.pgxpDepthBuffer)
            #expect(resolved.pgxpTransparentDepth == global.pgxpTransparentDepth)
            #expect(resolved.pgxpCpuMode == global.pgxpCpuMode)
            #expect(resolved.pgxpPreserveProjection == global.pgxpPreserveProjection)
            #expect(resolved.pgxpVertexCache == global.pgxpVertexCache)
            #expect(resolved.pgxpTolerance == global.pgxpTolerance)
            #expect(resolved.cpuEngine == global.cpuEngine)
            #expect(resolved.cpuOverclockEnabled == global.cpuOverclockEnabled)
            #expect(resolved.cpuOverclockPercent == global.cpuOverclockPercent)
            #expect(resolved.cpuOverclockEffective == 100)
            #expect(resolved.cdReadSpeedup == global.cdReadSpeedup)
            #expect(resolved.cdSeekSpeedup == global.cdSeekSpeedup)
            #expect(resolved.runaheadFrames == global.runaheadFrames)
            #expect(resolved.fastBoot == global.fastBoot)
        }
    }

    @Test func resolveMergesEveryOverriddenFieldAndBuildsSessionSettings() {
        let global = baselineGlobal()
        let full = fullyOverridden()
        let resolved = GameOverrides.resolve(
            global: global,
            override: full,
            legacyVramReadbacks: .off,
            isCpuEngineAvailable: { _ in true }
        )

        #expect(resolved.internalScale == 6)
        #expect(resolved.ditherMode == .native)
        #expect(resolved.textureFilter == .bilinear)
        #expect(resolved.spriteFilter == .scale2x)
        #expect(resolved.widescreen == .wide16x9)
        #expect(resolved.deinterlacing == .adaptive)
        #expect(resolved.displayEffect == .crt)
        #expect(resolved.vramReadbacks == .on)
        #expect(resolved.pgxpEnabled == true)
        #expect(resolved.pgxpUsePresets == false)
        #expect(resolved.pgxpTextureCorrection == false)
        #expect(resolved.pgxpColorCorrection == true)
        #expect(resolved.pgxpCulling == false)
        #expect(resolved.pgxpDisable2d == true)
        #expect(resolved.pgxpDepthBuffer == true)
        #expect(resolved.pgxpTransparentDepth == true)
        #expect(resolved.pgxpCpuMode == false)
        #expect(resolved.pgxpPreserveProjection == true)
        #expect(resolved.pgxpVertexCache == true)
        #expect(resolved.pgxpTolerance == .three)
        #expect(resolved.cpuEngine == .interpreter)
        #expect(resolved.cpuOverclockEnabled == true)
        #expect(resolved.cpuOverclockPercent == 250)
        #expect(resolved.cpuOverclockEffective == 250)
        #expect(resolved.cdReadSpeedup == 4)
        #expect(resolved.cdSeekSpeedup == 6)
        #expect(resolved.runaheadFrames == 2)
        #expect(resolved.fastBoot == true)

        let session = resolved.sessionSettings(gain: 0.75, rewindBudget: 128 << 20)
        #expect(session.gain == 0.75)
        #expect(session.rewindBudget == 128 << 20)
        #expect(session.scale == 6)
        #expect(session.dither == .native)
        #expect(session.textureFilter == .bilinear)
        #expect(session.spriteFilter == .scale2x)
        #expect(session.widescreen == .wide16x9)
        #expect(session.deinterlacing == .adaptive)
        #expect(session.displayEffect == .crt)
        #expect(session.vramReadbacks == .on)
        #expect(session.pgxp.enabled == true)
        #expect(session.pgxp.textureCorrection == false)
        #expect(session.pgxp.colorCorrection == true)
        #expect(session.pgxp.culling == false)
        #expect(session.pgxp.disable2d == true)
        #expect(session.pgxp.depthBuffer == true)
        #expect(session.pgxp.transparentDepth == true)
        #expect(session.pgxp.cpu == false)
        #expect(session.pgxp.preserveProjection == true)
        #expect(session.pgxp.vertexCache == true)
        #expect(session.pgxp.tolerance == 3)
        #expect(session.pgxpUsePresets == false)
        #expect(session.cpuEngine == .interpreter)
        #expect(session.cpuOverclock == 250)
        #expect(session.cdReadSpeedup == 4)
        #expect(session.cdSeekSpeedup == 6)
        #expect(session.runaheadFrames == 2)
    }

    @Test func resolveFallsBackWhenCpuEngineUnavailableAndDisablesOverclockWhenOff() {
        let global = baselineGlobal()
        var override = GameOverrides()
        override.cpuEngine = .recompiler
        override.cpuOverclockEnabled = false
        override.cpuOverclockPercent = 300

        let resolved = GameOverrides.resolve(
            global: global,
            override: override,
            isCpuEngineAvailable: { $0 != .recompiler }
        )
        #expect(resolved.cpuEngine == .cachedInterpreter)
        #expect(resolved.cpuOverclockEffective == 100)
    }

    @Test func targetSubtitleFormatsSerialRegionAndDiscCount() {
        let multi = GameSettingsTarget(
            key: "SCUS-94163", title: "Final Fantasy VII", serial: "SCUS-94163",
            serials: ["SCUS-94163", "SCUS-94164", "SCUS-94165"], discCount: 3,
            region: .america, coverURL: nil
        )
        #expect(multi.subtitle == "SCUS-94163 · North America · 3 discs")

        let single = GameSettingsTarget(
            key: "SLUS-00594", title: "Crash Bandicoot", serial: "SLUS-00594",
            serials: ["SLUS-00594"], discCount: 1, region: .america, coverURL: nil
        )
        #expect(single.subtitle == "SLUS-00594 · North America")
    }
}

// MARK: - Persistence Store

@Suite struct GameOverridesStoreTests {
    @Test func missingFileReadsAsEmptyAndNoOpWritesNothing() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = GameOverridesStore(directory: dir)
        #expect(store.all.isEmpty)
        #expect(store.overrides(for: "SLUS-00594") == nil)
        #expect(!store.hasOverrides(for: "SLUS-00594"))

        store.remove(for: "SLUS-00594")
        store.set(GameOverrides(), for: "SLUS-00594")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("overrides.json").path))
    }

    @Test func overridesSurviveAReloadAndClearingRemovesRecord() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = GameOverridesStore(directory: dir)
        store.update(for: "SLUS-00594") {
            $0.internalScale = 4
            $0.widescreen = .wide16x9
        }
        store.update(for: "SCES-00344") {
            $0.pgxpEnabled = true
        }

        let reloaded = GameOverridesStore(directory: dir)
        #expect(reloaded.overrides(for: "SLUS-00594")?.internalScale == 4)
        #expect(reloaded.overrides(for: "SLUS-00594")?.widescreen == .wide16x9)
        #expect(reloaded.overrides(for: "SCES-00344")?.pgxpEnabled == true)
        #expect(reloaded.hasOverrides(for: "SLUS-00594"))

        // Clearing every field individually removes the key cleanly.
        reloaded.update(for: "SLUS-00594") {
            $0.internalScale = nil
            $0.widescreen = nil
        }
        #expect(reloaded.overrides(for: "SLUS-00594") == nil)
        #expect(!reloaded.hasOverrides(for: "SLUS-00594"))
        #expect(reloaded.all.keys.sorted() == ["SCES-00344"])

        let afterClear = GameOverridesStore(directory: dir)
        #expect(afterClear.overrides(for: "SLUS-00594") == nil)
        #expect(afterClear.overrides(for: "SCES-00344")?.pgxpEnabled == true)
    }

    @Test func aDamagedFileReadsAsEmptyAndIsLeftAloneUntilNextWrite() throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overrides.json")
        try Data("not valid json".utf8).write(to: file)

        let store = GameOverridesStore(directory: dir)
        #expect(store.all.isEmpty)
        #expect(try Data(contentsOf: file) == Data("not valid json".utf8))

        store.update(for: "SLUS-00707") { $0.fastBoot = true }
        #expect(GameOverridesStore(directory: dir).overrides(for: "SLUS-00707")?.fastBoot == true)
        let aside = dir.appendingPathComponent("overrides.damaged.json")
        #expect(try Data(contentsOf: aside) == Data("not valid json".utf8))
    }

    @Test func aRecordThatNoLongerDecodesSurvivesWritesToOtherGames() throws {
        let dir = makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overrides.json")
        let json = #"{"SLUS-00594":{"internalScale":4},"SCES-00344":{"ditherMode":99,"fastBoot":true}}"#
        try Data(json.utf8).write(to: file)

        let store = GameOverridesStore(directory: dir)
        #expect(store.overrides(for: "SLUS-00594")?.internalScale == 4)
        #expect(store.overrides(for: "SCES-00344") == nil)

        store.update(for: "SLUS-00707") { $0.fastBoot = true }
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let kept = written?["SCES-00344"] as? [String: Any]
        #expect(kept?["ditherMode"] as? Int == 99)
        #expect(kept?["fastBoot"] as? Bool == true)

        let reloaded = GameOverridesStore(directory: dir)
        #expect(reloaded.overrides(for: "SLUS-00594")?.internalScale == 4)
        #expect(reloaded.overrides(for: "SLUS-00707")?.fastBoot == true)

        // A profile set for that game afterwards replaces the unreadable one.
        reloaded.update(for: "SCES-00344") { $0.pgxpEnabled = true }
        #expect(GameOverridesStore(directory: dir).overrides(for: "SCES-00344")
                == GameOverrides(pgxpEnabled: true))
    }
}

// MARK: - Live ViewModel & Multi-Game Isolation

@MainActor
private func makeModel(
    _ defaults: UserDefaults,
    overridesDir: URL,
    bios: BiosLibrary? = nil
) -> EmulatorViewModel {
    let root = makeTempDir("vm")
    let store = SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                               slotsDirectory: root.appendingPathComponent("slots"))
    var autoSave = AutoSaveSetting(key: "a", defaults: defaults)
    autoSave.set(0)
    let readbacks = VramReadbacksSetting(key: "vram", defaults: defaults)
    let overrides = GameOverridesStore(directory: overridesDir)
    guard let bios else {
        return EmulatorViewModel(saveStates: store, autoSave: autoSave,
                                 vramReadbacks: readbacks, gameOverrides: overrides)
    }
    return EmulatorViewModel(saveStates: store, autoSave: autoSave, bios: bios,
                             vramReadbacks: readbacks, gameOverrides: overrides)
}

private func makeBin(name: String, serial: String? = nil) throws -> GameEntry {
    let dir = makeTempDir("disc")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(repeating: 0, count: 2352).write(to: url)
    return GameEntry(url: url, identity: DiscIdentity(region: .america, serial: serial, volumeID: nil))
}

@MainActor
@Suite struct PerGameOverridesIntegrationTests {
    @Test func bootCarriesPerGameOverridesAndFastBootBeforeStart() throws {
        try withSuite { defaults in
            let overridesDir = makeTempDir()
            let biosDir = makeTempDir("bios")
            try FileManager.default.createDirectory(at: biosDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: overridesDir)
                try? FileManager.default.removeItem(at: biosDir)
            }
            try Data(repeating: 0, count: 524288).write(to: biosDir.appendingPathComponent("SCPH-1001.bin"))
            let biosKey = "override-bios-\(UUID().uuidString)"
            let bios = BiosLibrary(folderKey: biosKey, explicitKey: biosKey + ".explicit")
            defer { UserDefaults.standard.removeObject(forKey: biosKey) }
            try? bios.setFolder(biosDir)

            let model = makeModel(defaults, overridesDir: overridesDir, bios: bios)
            let savedScale = model.internalScale
            let savedFastBoot = model.fastBoot
            let savedWidescreen = model.widescreen
            defer {
                model.internalScale = savedScale
                model.fastBoot = savedFastBoot
                model.widescreen = savedWidescreen
            }
            model.internalScale = 1
            model.fastBoot = false
            model.widescreen = .off

            let discDir = makeTempDir("boot-disc")
            try FileManager.default.createDirectory(at: discDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: discDir) }
            let discURL = discDir.appendingPathComponent("test-override-game.bin")
            try Data(repeating: 0, count: 2352).write(to: discURL)
            let entry = GameEntry(url: discURL)
            let key = SaveStateStore.key(for: entry)

            model.updateGameOverrides(forKey: key) {
                $0.internalScale = 5
                $0.widescreen = .wide16x9
                $0.cdReadSpeedup = 4
                $0.runaheadFrames = 2
                $0.vramReadbacks = .on
                $0.fastBoot = true
            }

            let session = ScriptedSession()
            var capturedConfig: SessionConfig?
            model.makeSession = { cfg throws(Ps1Error) in
                capturedConfig = cfg
                return session
            }

            model.load(disc: discURL)
            defer { model.ejectNowForTesting() }

            let cfg = try #require(capturedConfig)
            #expect(cfg.fastBoot == true)
            #expect(cfg.settings.scale == 5)
            #expect(cfg.settings.widescreen == .wide16x9)
            #expect(cfg.settings.cdReadSpeedup == 4)
            #expect(cfg.settings.runaheadFrames == 2)
            #expect(cfg.settings.vramReadbacks == .on)

            // Global settings stay untouched.
            #expect(model.internalScale == 1)
            #expect(model.fastBoot == false)
            #expect(model.widescreen == .off)

            let startIndex = try #require(session.calls.firstIndex(of: "start()"))
            #expect(!session.calls[..<startIndex].contains("setSettings"))
        }
    }

    @Test func twoOpenGamesIsolateOverridesAndRespondSelectivelyToGlobalAndPerGameChanges() {
        withSuite { defaults in
            let overridesDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: overridesDir) }
            let model = makeModel(defaults, overridesDir: overridesDir)

            let savedScale = model.internalScale
            let savedEffect = model.displayEffect
            let savedWidescreen = model.widescreen
            let savedFilter = model.textureFilter
            let savedOverclockOn = model.cpuOverclockEnabled
            defer {
                model.internalScale = savedScale
                model.displayEffect = savedEffect
                model.widescreen = savedWidescreen
                model.textureFilter = savedFilter
                model.cpuOverclockEnabled = savedOverclockOn
            }
            model.internalScale = 2
            model.displayEffect = .none
            model.widescreen = .off
            model.textureFilter = .nearest
            model.cpuOverclockEnabled = false

            let sessionA = ScriptedSession()
            let sessionB = ScriptedSession()
            model.installSessionForTesting(sessionA, resumeKey: "GAME-A", ownWindow: true)
            model.installSessionForTesting(sessionB, resumeKey: "GAME-B", ownWindow: true)
            defer { model.ejectAllForTesting() }
            let gameA = model.games[0]
            let gameB = model.games[1]

            model.updateGameOverrides(forKey: "GAME-A") {
                $0.internalScale = 6
                $0.widescreen = .wide16x9
                $0.cpuOverclockEnabled = true
                $0.cpuOverclockPercent = 200
            }
            model.updateGameOverrides(forKey: "GAME-B") {
                $0.internalScale = 3
                $0.ditherMode = .off
            }

            // Each open game gets its own resolved settings, aspect ratio and CPU badge.
            #expect(sessionA.settings.last?.scale == 6)
            #expect(sessionA.settings.last?.widescreen == .wide16x9)
            #expect(sessionA.settings.last?.cpuOverclock == 200)
            #expect(gameA.widescreenAspect == Widescreen.wide16x9.aspect)
            #expect(model.cpuOverclock(for: gameA) == 200)

            #expect(sessionB.settings.last?.scale == 3)
            #expect(sessionB.settings.last?.dither == .off)
            #expect(sessionB.settings.last?.widescreen == .off)
            #expect(gameB.widescreenAspect == Widescreen.off.aspect)
            #expect(model.cpuOverclock(for: gameB) == 100)

            // Output size reads each game's resolved scale.
            var display = Ps1Display()
            display.width = 320
            display.height = 240
            display.enabled = 1
            sessionA.newestDisplay = display
            sessionB.newestDisplay = display
            #expect(gameA.outputSize?.height == 240 * 6)
            #expect(gameB.outputSize?.height == 240 * 3)

            // Changing a global setting updates non-overridden fields in both games
            // without clobbering either game's overridden internalScale.
            model.displayEffect = .crt
            model.internalScale = 4
            #expect(sessionA.settings.last?.displayEffect == .crt)
            #expect(sessionB.settings.last?.displayEffect == .crt)
            #expect(sessionA.settings.last?.scale == 6)
            #expect(sessionB.settings.last?.scale == 3)

            // Changing a per-game override for Game A pushes ONLY to Game A and leaves global intact.
            let bCountBefore = sessionB.settings.count
            model.updateGameOverrides(forKey: "GAME-A") { $0.textureFilter = .bilinear }
            #expect(sessionA.settings.last?.textureFilter == .bilinear)
            #expect(sessionB.settings.count == bCountBefore)
            #expect(model.textureFilter == .nearest)

            // Resetting Game A restores global settings live while leaving Game B untouched.
            let targetA = GameSettingsTarget(
                key: "GAME-A", title: "Game A", serial: nil, serials: [],
                discCount: 1, region: nil, coverURL: nil
            )
            model.resetGameOverrides(for: targetA)
            #expect(sessionA.settings.last?.scale == 4)
            #expect(sessionA.settings.last?.widescreen == .off)
            #expect(sessionA.settings.last?.textureFilter == .nearest)
            #expect(sessionA.settings.last?.cpuOverclock == 100)
            #expect(gameA.widescreenAspect == Widescreen.off.aspect)
            #expect(sessionB.settings.last?.scale == 3)
        }
    }

    @Test func pgxpPerGameOverridesAffectPresetAndEffectiveFlags() throws {
        try withSuite { defaults in
            let overridesDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: overridesDir) }
            let model = makeModel(defaults, overridesDir: overridesDir)

            let savedPgxp = model.pgxpEnabled
            let savedPresets = model.pgxpUsePresets
            let savedDepth = model.pgxpDepthBuffer
            defer {
                model.pgxpEnabled = savedPgxp
                model.pgxpUsePresets = savedPresets
                model.pgxpDepthBuffer = savedDepth
            }
            model.pgxpEnabled = false
            model.pgxpUsePresets = true
            model.pgxpDepthBuffer = false

            let session = ScriptedSession()
            model.installSessionForTesting(session, resumeKey: "SCES-00010")
            defer { model.ejectNowForTesting() }
            let entry = try makeBin(name: "preset-game.bin", serial: "SCES-00010")
            defer { try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent()) }
            model.game!.changeDisc(to: entry)
            session.answerSwap(nil)

            // Preset is active while global pgxpUsePresets is true.
            #expect(model.pgxpPreset?.cpu == true)
            #expect(model.pgxpPresetDecides(\.cpu))
            #expect(!model.pgxpEffectivelyEnabled)

            // Override PGXP & Depth Buffer on, and Automatic Game Fixes off for this game only.
            model.updateGameOverrides(forKey: "SCES-00010") {
                $0.pgxpEnabled = true
                $0.pgxpDepthBuffer = true
                $0.pgxpUsePresets = false
            }
            #expect(model.pgxpPreset == nil)
            #expect(!model.pgxpPresetDecides(\.cpu))
            #expect(model.pgxpEffectivelyEnabled)
            #expect(model.pgxpEffectiveDepthBuffer)
            #expect(session.settings.last?.pgxp.enabled == true)
            #expect(session.settings.last?.pgxp.depthBuffer == true)
            #expect(session.settings.last?.pgxpUsePresets == false)

            // Global settings stay untouched.
            #expect(!model.pgxpEnabled)
            #expect(model.pgxpUsePresets)
            #expect(!model.pgxpDepthBuffer)
        }
    }

    @Test func multiDiscGamesShareOneOverrideKeyAndSyncVramReadbacks() throws {
        try withSuite { defaults in
            let overridesDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: overridesDir) }
            let model = makeModel(defaults, overridesDir: overridesDir)

            let folder = makeTempDir("ff7")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let disc1URL = folder.appendingPathComponent("Final Fantasy VII (Disc 1) (USA).bin")
            let disc2URL = folder.appendingPathComponent("Final Fantasy VII (Disc 2) (USA).bin")
            try Data(repeating: 0, count: 2352).write(to: disc1URL)
            try Data(repeating: 0, count: 2352).write(to: disc2URL)

            let disc1 = GameEntry(url: disc1URL, identity: DiscIdentity(region: .america, serial: "SCUS-94163", volumeID: nil))
            let disc2 = GameEntry(url: disc2URL, identity: DiscIdentity(region: .america, serial: "SCUS-94164", volumeID: nil))

            // Both discs map to disc 1's key under DiscGrouping / LibraryCollection.statsKeys.
            let keys = LibraryCollection.statsKeys([disc1, disc2])
            #expect(keys[disc1.id] == "SCUS-94163")
            #expect(keys[disc2.id] == "SCUS-94163")

            // Setting VRAM readbacks via GameSettingsTarget syncs both disc serials
            // and carries over on disc swap.
            let target = GameSettingsTarget(
                key: "SCUS-94163", title: "Final Fantasy VII", serial: "SCUS-94163",
                serials: ["SCUS-94163", "SCUS-94164"], discCount: 2,
                region: .america, coverURL: nil
            )
            let session = ScriptedSession()
            model.installSessionForTesting(session, resumeKey: "SCUS-94163")
            defer { model.ejectNowForTesting() }

            model.setGameVramReadbacks(.on, for: target)
            #expect(session.settings.last?.vramReadbacks == .on)
            #expect(VramReadbacksSetting(key: "vram", defaults: defaults).choice(serial: "SCUS-94163") == .on)
            #expect(VramReadbacksSetting(key: "vram", defaults: defaults).choice(serial: "SCUS-94164") == .on)

            model.game!.changeDisc(to: disc2)
            #expect(session.pendingSwap?.readbacks == .on)
            session.answerSwap(nil)
            #expect(session.settings.last?.vramReadbacks == .on)
        }
    }

    @Test func legacyVramReadbacksUserDefaultsRemainCompatibleAndResetCleanly() {
        withSuite { defaults in
            var legacy = VramReadbacksSetting(key: "vram", defaults: defaults)
            legacy.set(.on, serial: "SLUS-00594")

            let overridesDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: overridesDir) }
            let model = makeModel(defaults, overridesDir: overridesDir)

            let target = GameSettingsTarget(
                key: "SLUS-00594", title: "Crash Bandicoot", serial: "SLUS-00594",
                serials: ["SLUS-00594"], discCount: 1, region: .america, coverURL: nil
            )

            #expect(model.vramReadbacksChoice(for: target) == .on)
            #expect(model.activeOverrideCount(for: target) == 1)
            #expect(model.resolvedSettings(forKey: "SLUS-00594", serial: "SLUS-00594").vramReadbacks == .on)

            let session = ScriptedSession()
            model.installSessionForTesting(session, resumeKey: "SLUS-00594")
            defer { model.ejectNowForTesting() }
            model.game!.discSerial = "SLUS-00594"

            model.resetGameOverrides(for: target)
            #expect(model.vramReadbacksChoice(for: target) == .automatic)
            #expect(model.activeOverrideCount(for: target) == 0)
            #expect(VramReadbacksSetting(key: "vram", defaults: defaults).choice(serial: "SLUS-00594") == .automatic)
            #expect(session.settings.last?.vramReadbacks == .automatic)
        }
    }

    @Test func gameSettingsSheetPausesRestoresAndIntegratesWithPauseMenu() {
        withSuite { defaults in
            let overridesDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: overridesDir) }
            let model = makeModel(defaults, overridesDir: overridesDir)
            let session = ScriptedSession()
            model.installSessionForTesting(session, resumeKey: "SLUS-00594")
            defer { model.ejectNowForTesting() }
            let game = model.game!
            game.discTitle = "Crash Bandicoot"
            game.isPaused = false

            // Opening directly during active play pauses and releases held keys.
            _ = model.keyDown(UInt16(kVK_DownArrow))
            #expect(game.inputMaskForTesting != 0xFFFF)
            game.openGameSettings()
            #expect(game.gameSettingsTarget?.key == "SLUS-00594")
            #expect(game.isPaused)
            #expect(game.inputMaskForTesting == 0xFFFF)
            #expect(!game.canUseStates)

            game.closeGameSettings()
            #expect(game.gameSettingsTarget == nil)
            #expect(!game.isPaused)
            #expect(game.canUseStates)

            // Opening when already paused keeps the game paused on close.
            game.isPaused = true
            game.openGameSettings()
            game.closeGameSettings()
            #expect(game.isPaused)

            // Pause menu navigation confirms `.gameSettings` and opens the sheet
            // without losing the pause menu's pause ownership.
            game.isPaused = false
            game.setSurface(.pauseMenu, open: true)
            game.pointMenu(at: .gameSettings)
            game.surfaceMove(.confirm)
            #expect(game.gameSettingsTarget?.key == "SLUS-00594")
            #expect(game.isPaused)
            game.closeGameSettings()
            #expect(game.isOpen(.pauseMenu))
            #expect(game.isPaused)
            game.setSurface(.pauseMenu, open: false)
            #expect(!game.isPaused)
        }
    }

    @Test func gameSettingsWindowTracksAndForgetsOpenSheetWindows() {
        let winA = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let winB = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        GameSettingsWindow.record(winA)
        defer { GameSettingsWindow.forget(winA) }
        #expect(GameSettingsWindow.owns(windowNumber: winA.windowNumber))
        #expect(!GameSettingsWindow.owns(windowNumber: winB.windowNumber))
        GameSettingsWindow.forget(winA)
        #expect(!GameSettingsWindow.owns(windowNumber: winA.windowNumber))
    }
}

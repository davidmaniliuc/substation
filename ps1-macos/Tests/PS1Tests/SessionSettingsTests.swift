import CPs1
import Foundation
import Testing
@testable import PS1

/// `SessionSettings` as it crosses `ps1_session_set_settings`.
struct SessionSettingsTests {
    @Test func theHeaderAgreesOnTheSize() {
        #expect(MemoryLayout<Ps1SessionSettings>.size == 64)
    }

    @Test func aSettingsValueCrossesFieldForField() {
        let pgxp = PgxpSettings(enabled: true, cpu: true, culling: true, vertexCache: true,
                                textureCorrection: true, colorCorrection: true, depthBuffer: true,
                                transparentDepth: true, disable2d: true, preserveProjection: true,
                                tolerance: 2)
        let s = SessionSettings(gain: 0.5, cpuEngine: .recompiler, runaheadFrames: 2,
                                rewindBudget: 256 << 20, scale: 4, dither: .native,
                                textureFilter: .bilinear, spriteFilter: .bilinear, pgxp: pgxp,
                                pgxpUsePresets: true, vramReadbacks: .off)
        let c = s.c
        #expect(c.size == 64)
        #expect(c.gain == 0.5)
        #expect(c.cpu_engine == 2)
        #expect(c.runahead == 2)
        #expect(c.rewind_budget == 256 << 20)
        #expect(c.scale == 4)
        #expect(c.dither == 1)
        #expect(c.texture_filter == 1)
        #expect(c.sprite_filter == 1)
        #expect(c.pgxp.enabled == 1)
        #expect(c.pgxp.cpu == 1)
        #expect(c.pgxp.culling == 1)
        #expect(c.pgxp.vertex_cache == 1)
        #expect(c.pgxp.texture_correction == 1)
        #expect(c.pgxp.color_correction == 1)
        #expect(c.pgxp.depth_buffer == 1)
        #expect(c.pgxp.transparent_depth == 1)
        #expect(c.pgxp.disable_2d == 1)
        #expect(c.pgxp.preserve_projection == 1)
        #expect(c.pgxp.tolerance == 2)
        #expect(c.pgxp_use_presets == 1)
        #expect(c.vram_readbacks == 2)
    }
}

/// A throwaway suite: the hosted tests share the app's defaults.
private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "session-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

@MainActor private func makeModel(_ defaults: UserDefaults, bios: BiosLibrary? = nil) -> EmulatorViewModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-vm-\(UUID().uuidString)")
    let store = SaveStateStore(resumeDirectory: root.appendingPathComponent("resume"),
                               slotsDirectory: root.appendingPathComponent("slots"))
    var autoSave = AutoSaveSetting(key: "a", defaults: defaults)
    autoSave.set(0)
    let readbacks = VramReadbacksSetting(key: "k", defaults: defaults)
    guard let bios else { return EmulatorViewModel(saveStates: store, autoSave: autoSave, vramReadbacks: readbacks) }
    return EmulatorViewModel(saveStates: store, autoSave: autoSave, bios: bios, vramReadbacks: readbacks)
}

private func makeEntry(serial: String) throws -> GameEntry {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-disc-\(UUID().uuidString).bin")
    try Data(repeating: 0, count: 2352).write(to: url)
    return GameEntry(url: url, identity: DiscIdentity(region: nil, serial: serial, volumeID: nil))
}

/// A running game on `serial`: a swap to it, answered.
@MainActor private func run(_ model: EmulatorViewModel, _ session: ScriptedSession, serial: String) throws {
    model.installSessionForTesting(session, resumeKey: "k")
    model.game!.changeDisc(to: try makeEntry(serial: serial))
    session.answerSwap(nil)
}

/// The view model's side: one value, sent whole, carrying the player's own
/// values. The session folds the tables.
@MainActor struct SessionSettingsViewModelTests {
    @Test func aBootCarriesEverySettingInTheConfig() throws {
        try withSuite { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-bios-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data(repeating: 0, count: 524288).write(to: dir.appendingPathComponent("SCPH-1001.bin"))
            let key = "settings-bios-\(UUID().uuidString)"
            let bios = BiosLibrary(folderKey: key, explicitKey: key + ".explicit")
            defer { UserDefaults.standard.removeObject(forKey: key) }
            try? bios.setFolder(dir)
            let model = makeModel(defaults, bios: bios)
            let session = ScriptedSession()
            var config: SessionConfig?
            model.makeSession = { cfg throws(Ps1Error) in
                config = cfg
                return session
            }
            // One fixed name: a started game is marked played in the shared stats.
            let disc = FileManager.default.temporaryDirectory.appendingPathComponent("vm-settings-disc.bin")
            try Data(repeating: 0, count: 2352).write(to: disc)

            model.load(disc: disc)
            defer { model.ejectNowForTesting() }
            let s = try #require(config?.settings)
            #expect(s.cpuEngine == model.cpuEngine)
            #expect(s.runaheadFrames == model.runaheadFrames)
            #expect(s.rewindBudget == (model.rewindEnabled ? model.rewindMemoryMB << 20 : 0))
            #expect(s.scale == model.internalScale)
            #expect(s.dither == model.ditherMode)
            #expect(s.textureFilter == model.textureFilter)
            #expect(s.spriteFilter == model.spriteFilter)
            #expect(s.pgxp.enabled == model.pgxpEnabled)
            #expect(s.pgxp.cpu == model.pgxpCpu)
            #expect(s.pgxpUsePresets == model.pgxpUsePresets)
            #expect(s.cpuOverclock == model.cpuOverclockEffective)
            #expect(s.gain == (model.isMuted ? 0 : Float(model.volume)))
            let start = try #require(session.calls.firstIndex(of: "start()"))
            #expect(!session.calls[..<start].contains("setSettings"))
        }
    }

    @Test func theSettingsCarryThePlayersPgxpNotThePresets() throws {
        try withSuite { defaults in
            let model = makeModel(defaults)
            let usePresets = model.pgxpUsePresets
            let cpu = model.pgxpCpu
            defer {
                model.pgxpUsePresets = usePresets
                model.pgxpCpu = cpu
            }
            model.pgxpUsePresets = true
            model.pgxpCpu = false
            let session = ScriptedSession()
            try run(model, session, serial: "SCES-00010")
            defer { model.ejectNowForTesting() }

            #expect(model.pgxpPreset?.cpu == true)
            let last = try #require(session.settings.last)
            #expect(last.pgxp.cpu == false)
            #expect(last.pgxpUsePresets)
        }
    }

    @Test func eachSettingChangeSendsOneValue() throws {
        // Each changes one setting and hands back its undo: the hosted tests
        // share the app's defaults.
        let rows: [(String, (EmulatorViewModel) -> () -> Void)] = [
            ("scale", { m in let o = m.internalScale; m.internalScale = o == 3 ? 2 : 3; return { m.internalScale = o } }),
            ("dither", { m in let o = m.ditherMode; m.ditherMode = o == .native ? .off : .native; return { m.ditherMode = o } }),
            ("texture filter", { m in let o = m.textureFilter; m.textureFilter = o == .nearest ? .bilinear : .nearest
                return { m.textureFilter = o } }),
            ("sprite filter", { m in let o = m.spriteFilter; m.spriteFilter = o == .nearest ? .bilinear : .nearest
                return { m.spriteFilter = o } }),
            ("pgxp", { m in let o = m.pgxpEnabled; m.pgxpEnabled = !o; return { m.pgxpEnabled = o } }),
            ("engine", { m in let o = m.cpuEngine; m.cpuEngine = o == .interpreter ? .cachedInterpreter : .interpreter
                return { m.cpuEngine = o } }),
            ("runahead", { m in let o = m.runaheadFrames; m.runaheadFrames = o == 2 ? 1 : 2; return { m.runaheadFrames = o } }),
            ("rewind memory", { m in let o = m.rewindMemoryMB; m.rewindMemoryMB = o == 256 ? 128 : 256
                return { m.rewindMemoryMB = o } }),
            ("volume", { m in let o = m.volume; m.volume = o == 0.5 ? 0.25 : 0.5; return { m.volume = o } }),
            ("clock speed control", { m in let o = m.cpuOverclockEnabled; m.cpuOverclockEnabled = !o
                return { m.cpuOverclockEnabled = o } }),
            ("clock speed", { m in let o = m.cpuOverclockPercent; m.cpuOverclockPercent = o == 200 ? 150 : 200
                return { m.cpuOverclockPercent = o } }),
        ]
        try withSuite { defaults in
            let model = makeModel(defaults)
            let session = ScriptedSession()
            model.installSessionForTesting(session, resumeKey: "k")
            defer { model.ejectNowForTesting() }
            for (name, change) in rows {
                let before = session.calls.count
                let restore = change(model)
                defer { restore() }
                let sent = session.calls[before...].filter { $0 == "setSettings" }.count
                #expect(sent == 1, "\(name) sends one value")
            }
        }
        // Each row's value reaches the struct.
        try withSuite { defaults in
            let model = makeModel(defaults)
            let session = ScriptedSession()
            model.installSessionForTesting(session, resumeKey: "k")
            defer { model.ejectNowForTesting() }
            let scale = model.internalScale
            defer { model.internalScale = scale }
            model.internalScale = scale == 3 ? 2 : 3
            #expect(session.settings.last?.scale == model.internalScale)
            let dither = model.ditherMode
            defer { model.ditherMode = dither }
            model.ditherMode = dither == .native ? .off : .native
            #expect(session.settings.last?.dither == model.ditherMode)
            let runahead = model.runaheadFrames
            defer { model.runaheadFrames = runahead }
            model.runaheadFrames = runahead == 2 ? 1 : 2
            #expect(session.settings.last?.runaheadFrames == model.runaheadFrames)
            let overclockOn = model.cpuOverclockEnabled
            let overclock = model.cpuOverclockPercent
            defer {
                model.cpuOverclockEnabled = overclockOn
                model.cpuOverclockPercent = overclock
            }
            model.cpuOverclockPercent = 300
            model.cpuOverclockEnabled = true
            #expect(session.settings.last?.cpuOverclock == 300)
            model.cpuOverclockEnabled = false
            #expect(session.settings.last?.cpuOverclock == 100)
        }
    }

    @Test func aRefusedSwapKeepsTheOldDiscsPreset() throws {
        try withSuite { defaults in
            let model = makeModel(defaults)
            let usePresets = model.pgxpUsePresets
            defer { model.pgxpUsePresets = usePresets }
            model.pgxpUsePresets = true
            let session = ScriptedSession()
            try run(model, session, serial: "SLUS-00707")
            defer { model.ejectNowForTesting() }

            model.game!.changeDisc(to: try makeEntry(serial: "SCES-00010"))
            #expect(model.pgxpPreset == nil)
            session.answerSwap(.badCue)
            #expect(model.pgxpPreset == nil)
            #expect(model.discSerial == "SLUS-00707")

            model.game!.changeDisc(to: try makeEntry(serial: "SCES-00010"))
            session.answerSwap(nil)
            #expect(model.pgxpPreset?.cpu == true)
            #expect(model.discSerial == "SCES-00010")
        }
    }
}

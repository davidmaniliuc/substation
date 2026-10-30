import AppKit
import Carbon.HIToolbox
import SwiftUI
import GameController
import UniformTypeIdentifiers

@MainActor
@Observable
public final class EmulatorViewModel {
    enum Stage { case onboarding, library, playing }

    /// `.playing` while any game is open.
    private(set) var stage: Stage = .onboarding
    /// Every open game, in the order they opened. In New Window mode each
    /// has a window of its own; at most one plays in the library's window.
    private(set) var games: [OpenGame] = []
    /// The game that runs: the one whose window came forward last. Every
    /// other open game sits paused, silent and deaf (`OpenGame.backgrounded`).
    /// Nil when the running game closed and no other has come forward since.
    private(set) var game: OpenGame?
    /// Which game runs, and the card hand-over between two.
    private var gameSwitch = GameSwitch(running: nil)
    /// A hand-over waits on a session's answer; a newer switch waits behind
    /// it, so one game's cards are on disk before the next reads them.
    private var switchInFlight = false
    private var queuedSwitch: UUID?

    /// The game playing in the library's window, if any.
    var libraryGame: OpenGame? { games.first { !$0.inOwnWindow } }
    func game(with id: UUID) -> OpenGame? { games.first { $0.id == id } }
    /// The running game is in a window of its own, with the library left
    /// open in the main one.
    var gameInOwnWindow: Bool { game?.inOwnWindow ?? false }
    /// The main window shows the library: always, unless a game plays in it.
    var libraryVisible: Bool { stage != .onboarding && libraryGame == nil }
    /// Some game window should be open: a game's, or the one holding the
    /// alerts of a launch that belongs there. Not for a resume sheet, which
    /// floats on its own (`resumeInPanel`).
    var gameWindowShown: Bool { games.contains { $0.inOwnWindow } || launchWindowShown }
    /// The alerts of a launch from outside the library, in New Window mode,
    /// go in a game window of their own (`GameWindowContent.launch`).
    var launchWindowShown: Bool { launchInGameWindow && launchAlertShown }
    /// The resume sheet of a launch from outside the library floats in a
    /// panel of its own (`LaunchPanel`) in either mode: Finder and Spotlight
    /// may launch the app without a window, and the library's sheet then
    /// waited for a Dock click. The window the game plays in opens only once
    /// there is a game, or an alert, to put in it.
    var resumeInPanel: Bool { launchFromOutside && resumeOffer != nil }
    /// The floating sheet has closed onto something the library's window
    /// must show: in Library Window mode the game plays there, and a
    /// launch's alerts go there. A cancel leaves nothing to show, so it
    /// opens no window: the player asked for a game, not the library.
    var libraryWantedAfterPanel: Bool {
        !launchInGameWindow && (libraryGame != nil || launchAlertShown)
    }
    /// A disc opened from outside the library (Finder, Spotlight, Open Disc),
    /// whichever window it plays in.
    private(set) var launchFromOutside = false
    /// A disc opened from outside the library (Finder, Open Disc) in New
    /// Window mode: its resume sheet floats (`resumeInPanel`) and its alerts
    /// go in the game window, which opens for them, so the library is never
    /// needed to start it. A click in the library keeps them there, where
    /// the click was.
    private(set) var launchInGameWindow = false
    /// A game window to open or bring forward, from whichever window sees
    /// the change (`GameWindowOpener`). Numbered, so asking twice for the
    /// same window is still a change.
    struct WindowRequest: Equatable {
        let content: GameWindowContent
        let number: Int
    }
    private(set) var windowRequest: WindowRequest?

    private func requestWindow(_ content: GameWindowContent) {
        windowRequest = WindowRequest(content: content, number: (windowRequest?.number ?? 0) + 1)
    }

    /// Whether a game window should still be open.
    func wantsWindow(_ content: GameWindowContent) -> Bool {
        switch content {
        case .launch: launchWindowShown
        case .game(let id): game(with: id)?.inOwnWindow == true
        }
    }

    /// One of a launch's alerts is up (the ones `LaunchDialogs` presents).
    var launchAlertShown: Bool { resumeFailure != nil || errorMessage != nil || showRawBinWarning }
    var errorMessage: String?
    var showRawBinWarning = false

    /// Builds every session `load(disc:)` starts. A test replaces it.
    @ObservationIgnored var makeSession: @MainActor (SessionConfig) throws(Ps1Error) -> any GameSession = {
        config throws(Ps1Error) in try Session(config)
    }
    private let bios: BiosLibrary
    /// The running game's view of the session, for the view that draws it.
    var discTitle: String { game?.discTitle ?? "" }

    let library = GameLibrary()
    let covers = CoverStore()
    /// Last played and active play time per game. Outlives every disc, like
    /// `covers`.
    let playStats = PlayStatsStore()
    /// Bumped after every state write so the menus re-read their timestamps.
    private(set) var stateRevision = 0
    func stateWritten() { stateRevision += 1 }
    private var coverSourceSetting = CoverSourceSetting()
    private var autoCoverSetting = AutoCoverSetting()
    private var sweepPolicy = CoverSweepPolicy()

    /// One shared pair of cards for the whole library. Outlives every disc,
    /// like `covers` and unlike `session`, which reads and writes them.
    let cards = MemoryCardStore()

    /// Every saved machine of every game. Outlives every disc, like `cards`.
    let saveStates: SaveStateStore
    private var resumeOnExit = ResumeOnExitSetting()
    private var autoSave: AutoSaveSetting
    private var fastBootSetting = FastBootSetting()
    private var exitGate = ExitGate()
    /// True from Yes until the exit actually finishes: up to the 3 s save
    /// fallback. The gate has already handed its intent back by then, so this
    /// is what keeps a second leave-request (and a second exit save) out of
    /// that window.
    private(set) var finishingExit = false
    /// The game the exit sheet is asking about.
    private var promptGame: OpenGame?
    /// The games a quit has still to ask about, each on its own sheet once
    /// the one before is answered.
    private var quitQueue: [OpenGame] = []

    /// The exit sheet, on whichever game it is asking about.
    var exitPrompt: ExitIntent? { promptGame?.exitPrompt }
    var resumeOffer: ResumeOffer?
    var resumeFailure: ResumeFailure?
    /// Set by the app delegate while ⌘Q waits on the sheet.
    var terminateReply: ((Bool) -> Void)?

    /// Set once an exit has been confirmed, so the `terminate` that follows
    /// is not asked again.
    private(set) var exitConfirmed = false

    var autoSaveInterval: TimeInterval? { autoSave.interval }

    var autoSaveMinutes: Int {
        get { autoSave.minutes }
        set { autoSave.set(newValue) }
    }

    var saveStateOnExit: Bool {
        get { resumeOnExit.enabled }
        set { resumeOnExit.set(newValue) }
    }

    /// Read when a game starts, so a change applies from the next one.
    var fastBoot: Bool {
        get { fastBootSetting.enabled }
        set { fastBootSetting.set(newValue) }
    }

    private var vibrationSetting = VibrationSetting()
    var vibration: Bool {
        get { vibrationSetting.enabled }
        set { vibrationSetting.set(newValue) }
    }
    private let haptics = PadHaptics()

    /// Kept by the resign/become-active observers in `init`, so the rumble
    /// gate and the play clock read one value.
    private(set) var appActive = NSApp?.isActive ?? true

    private var rumbleAllowed: Bool {
        vibration && game.map { !$0.isPaused && !$0.backgrounded } == true && !isDialogShown && appActive
    }

    struct ResumeFailure: Identifiable {
        let id = UUID()
        let message: String
        let freshBoot: URL
    }

    /// Bumped whenever a cover is added or removed. The grid keys off it: the
    /// covers live on disk rather than in observable state, so nothing else
    /// would tell SwiftUI that a tile's picture changed.
    private(set) var coverRevision = 0 {
        didSet { publishGamesToSystem() }
    }

    private var input = InputMap()

    /// Retained so a future teardown can remove it. It is deliberately NOT
    /// removed in `deinit`: `deinit` on a @MainActor class is nonisolated and
    /// cannot touch isolated state, and the alternatives (`nonisolated` (which
    /// a mutable stored property rejects), or `nonisolated(unsafe)`) buy
    /// nothing here, because this model lives for the whole process.
    private var keyMonitor: Any?

    public convenience init() {
        self.init(saveStates: SaveStateStore(), autoSave: AutoSaveSetting())
    }

    /// `bios` is injectable for `BiosLibrary`'s own reason: the hosted tests
    /// share the app's defaults, and the default keys are the player's folder.
    init(saveStates: SaveStateStore, autoSave: AutoSaveSetting,
         rewind: RewindSetting = RewindSetting(), bios: BiosLibrary = BiosLibrary(),
         vramReadbacks: VramReadbacksSetting = VramReadbacksSetting(),
         gameWindow: GameWindowSetting = GameWindowSetting()) {
        self.saveStates = saveStates
        self.autoSave = autoSave
        self.rewindSetting = rewind
        self.vramReadbacksSetting = vramReadbacks
        self.gameWindowSetting = gameWindow
        self.bios = bios
        stage = (bios.folderURL != nil && library.folderURL != nil) ? .library : .onboarding
        if stage == .onboarding { surveyBios() }
        observeControllers()
        observeKeyboard()
        observeRumbleGate()

        // Set here rather than at the declaration because it captures self.
        // `GameLibrary.init` may already have started a scan, but that scan
        // publishes from inside a Task and so cannot have finished before this
        // initializer returns: the first scan is covered.
        library.didFinishScan = { [weak self] in
            self?.autoDownloadCoversIfEnabled()
            self?.publishGamesToSystem()
        }

        // ⌘Q does not go through eject(), so the pending write would be lost
        // with the process. Tearing the machine down is what flushes it, and
        // it is synchronous: a Task here would not be scheduled before exit.
        //
        // `queue: nil` is DOCUMENTED to run the block synchronously on the
        // posting thread, which is the guarantee this needs and what
        // `MainActor.assumeIsolated` below presumes. `queue: .main` looked
        // equivalent (NotificationCenter runs the block inline for a non-nil
        // queue when it equals `OperationQueue.current`, which holds today
        // because the notification is posted from the main run loop), but
        // that is implementation behaviour, not a contract. If it ever
        // enqueued instead, the block would run after `NSApplication` had
        // already returned from `terminate:`, and the process would exit with
        // the save unwritten.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardownAllGames() }
        }

        // A local key monitor stops seeing events once the app is in the
        // background, so a Tab released after ⌘Tab-ing away never reaches
        // `keyUp` and the game would go on fast-forwarding behind the player.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appActive = false
                self?.setFastForwarding(false)
                // The same trap as Tab: a held key's release is never seen.
                self?.game?.releaseRewind()
                self?.haptics.stop()
                self?.game?.updatePlayClock()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appActive = true
                self?.game?.updatePlayClock()
            }
        }
        // "Today" in a state's menu title becomes "Yesterday" at midnight.
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stateRevision += 1 }
        }
    }


    /// Internal resolution, 1...8, persisted. `public` to match the app-facing
    /// seams beside it (`isPaused`, `rescanLibrary()`) rather than because a
    /// module boundary requires it: `Sources/PS1App` is a directory inside the
    /// single `PS1` module, not a second target.
    ///
    /// A computed seam over a stored struct: `@Observable` instruments the
    /// stored `resolution`, so mutating it through here notifies observers and
    /// `GameScreen` hands the new scale to the session.
    private var resolution = InternalResolution()

    public var internalScale: Int {
        get { resolution.scale }
        set {
            let before = resolution.scale
            resolution.set(newValue)
            pushSettings()
            if resolution.scale != before {
                settingNotice(NoticeIcon.resolution, "Resolution \(resolution.scale)×")
            }
        }
    }

    /// Where the dither pattern is sampled, persisted: the same computed seam
    /// over a stored struct as `internalScale` above.
    ///
    /// `GameScreen` hands it to the session on a change, as it does the
    /// scale, the two filters and the toolbar band.
    private var ditherSetting = DitherSetting()

    public var ditherMode: DitherMode {
        get { ditherSetting.mode }
        set {
            ditherSetting.set(newValue)
            pushSettings()
        }
    }

    private var libraryLayout = LibraryLayoutSetting()

    /// The grid's LIVE tile width in points, clamped by the setting and
    /// fitted to the grid's size, so it never lays out fewer than
    /// `LibraryLayoutSetting.fewestColumns`. Setting it persists nothing;
    /// `commitCoverSize()` does.
    var libraryTileSize: Double {
        get {
            LibraryLayoutSetting.fitted(libraryLayout.tileSize, width: Double(libraryGridWidth),
                                        height: Double(libraryGridHeight))
        }
        set { libraryLayout.setTileSize(newValue) }
    }

    private var libraryThemeSetting = LibraryThemeSetting()

    /// The library's look, and the Settings window's scheme. Settings ▸
    /// General ▸ Appearance binds here.
    var libraryTheme: LibraryTheme {
        get { libraryThemeSetting.theme }
        set { libraryThemeSetting.set(newValue) }
    }

    /// Injectable for `BiosLibrary`'s reason: the hosted tests share the
    /// app's defaults, where the player's choice lives.
    private var gameWindowSetting: GameWindowSetting

    /// Settings ▸ General ▸ Games binds here.
    var gameWindowMode: GameWindowMode {
        get { gameWindowSetting.mode }
        set { gameWindowSetting.set(newValue) }
    }

    var gameWindowFullScreen: Bool {
        get { gameWindowSetting.fullScreen }
        set { gameWindowSetting.setFullScreen(newValue) }
    }

    /// The toolbar's tab, for the session only: which section is open is a
    /// question asked now. Read it through `libraryTabShown`.
    var libraryTab = LibraryTab.all

    /// The grid's order, for the session only, as the tab is. Recently
    /// Played ignores it: newest first is that tab's whole point.
    var libraryOrder = LibraryOrder()

    /// The toolbar search, for the session only, as the tab is.
    var librarySearch = ""
    /// Bumped by Library ▸ Find (⌘F); the toolbar's field takes focus on
    /// each change. A counter rather than a flag, so a second ⌘F after the
    /// field lost focus is still a change.
    var librarySearchFocusRequest = 0

    /// The grid's laid-out width, for the session: Bigger/Smaller Covers
    /// step by a column at this width.
    var libraryGridWidth: CGFloat = 0
    /// The grid's visible height, for the session: it decides how big the
    /// biggest cover may be.
    var libraryGridHeight: CGFloat = 0

    /// The grid's column count now.
    private var libraryColumns: Int {
        GridSelection.columns(width: libraryGridWidth, minimum: libraryTileSize,
                              spacing: LibraryLayoutSetting.tileSpacing)
    }

    /// The size one column fewer (bigger covers) or one more (smaller) needs
    /// at this width, or nil when the size range cannot reach it. Only on a
    /// grid in front of the player: in a game it would move a size nobody
    /// can see.
    private func coverSize(columnDelta: Int) -> Double? {
        guard libraryVisible else { return nil }
        let width = Double(libraryGridWidth)
        let columns = libraryColumns + columnDelta
        guard columns >= LibraryLayoutSetting.fewestColumns(
            width: width, height: Double(libraryGridHeight)) else { return nil }
        return LibraryLayoutSetting.size(forColumns: columns, width: width)
    }

    var canGrowCovers: Bool { coverSize(columnDelta: -1) != nil }
    var canShrinkCovers: Bool { coverSize(columnDelta: 1) != nil }
    var canResetCovers: Bool {
        libraryVisible && libraryTileSize != LibraryLayoutSetting.defaultSize
    }
    func commitCoverSize() { libraryLayout.commitTileSize() }
    func growCovers() { stepCovers(by: 1) }
    func shrinkCovers() { stepCovers(by: -1) }
    func resetCovers() { libraryLayout.resetTileSize() }

    /// +1 is bigger: one column fewer.
    private func stepCovers(by delta: Int) {
        guard let size = coverSize(columnDelta: -delta) else { return }
        libraryTileSize = size
        commitCoverSize()
    }

    /// The texture filter, persisted, and handed over exactly like
    /// `ditherMode`.
    private var textureFilterSetting = TextureFilterSetting()

    public var textureFilter: TextureFilter {
        get { textureFilterSetting.filter }
        set {
            textureFilterSetting.set(newValue)
            pushSettings()
        }
    }

    /// The sprite texture filter, persisted, and handed over like
    /// `textureFilter`.
    private var spriteFilterSetting = SpriteFilterSetting()

    public var spriteFilter: TextureFilter {
        get { spriteFilterSetting.filter }
        set {
            spriteFilterSetting.set(newValue)
            pushSettings()
        }
    }

    /// PGXP geometry correction, persisted: the same computed seam over a
    /// stored struct as `internalScale` above. Every change hands the
    /// session every setting in one `setSettings`.
    private var pgxpSetting = PgxpSetting()

    public var pgxpEnabled: Bool {
        get { pgxpSetting.enabled }
        set {
            let before = pgxpSetting.enabled
            pgxpSetting.set(newValue)
            pushSettings()
            if pgxpSetting.enabled != before {
                settingNotice(NoticeIcon.pgxp, pgxpSetting.enabled ? "PGXP on" : "PGXP off")
            }
        }
    }

    /// The six sub-settings, each the same computed seam over the same stored
    /// struct.
    public var pgxpCpu: Bool {
        get { pgxpSetting.cpu }
        set {
            pgxpSetting.setCpu(newValue)
            pushSettings()
        }
    }

    public var pgxpCulling: Bool {
        get { pgxpSetting.culling }
        set {
            pgxpSetting.setCulling(newValue)
            pushSettings()
        }
    }

    public var pgxpVertexCache: Bool {
        get { pgxpSetting.vertexCache }
        set {
            pgxpSetting.setVertexCache(newValue)
            pushSettings()
        }
    }

    public var pgxpTolerance: Float {
        get { pgxpSetting.tolerance }
        set {
            pgxpSetting.setTolerance(newValue)
            pushSettings()
        }
    }

    public var pgxpTextureCorrection: Bool {
        get { pgxpSetting.textureCorrection }
        set {
            pgxpSetting.setTextureCorrection(newValue)
            pushSettings()
        }
    }

    public var pgxpColorCorrection: Bool {
        get { pgxpSetting.colorCorrection }
        set {
            pgxpSetting.setColorCorrection(newValue)
            pushSettings()
        }
    }

    /// The PGXP depth buffer and its two dependents. The depth buffer has no
    /// setter of its own: it travels in `setPgxp`, and the session rebuilds
    /// its renderer when the EFFECTIVE value changes.
    public var pgxpDepthBuffer: Bool {
        get { pgxpSetting.depthBuffer }
        set {
            pgxpSetting.setDepthBuffer(newValue)
            pushSettings()
        }
    }

    public var pgxpTransparentDepth: Bool {
        get { pgxpSetting.transparentDepth }
        set {
            pgxpSetting.setTransparentDepth(newValue)
            pushSettings()
        }
    }

    public var pgxpDisable2d: Bool {
        get { pgxpSetting.disable2d }
        set {
            pgxpSetting.setDisable2d(newValue)
            pushSettings()
        }
    }

    public var pgxpPreserveProjection: Bool {
        get { pgxpSetting.preserveProjection }
        set {
            pgxpSetting.setPreserveProjection(newValue)
            pushSettings()
        }
    }

    /// Settings ▸ Enhancements ▸ Restore Defaults: all eleven, master included.
    func restoreDefaultPgxp() {
        pgxpSetting.restoreDefaults()
        pushSettings()
    }

    /// Settings ▸ Enhancements ▸ Per-Game Fixes.
    public var pgxpUsePresets: Bool {
        get { pgxpSetting.usePresets }
        set {
            pgxpSetting.setUsePresets(newValue)
            pushSettings()
        }
    }

    /// The running disc's preset, whatever the switch says. Nil with no game
    /// running, or for a game the table does not list.
    var discPgxpPreset: PgxpPreset? { game?.discPgxpPreset }

    /// The preset in force: nil while Per-Game Fixes is off.
    var pgxpPreset: PgxpPreset? { pgxpSetting.usePresets ? discPgxpPreset : nil }

    /// Whether the running game's preset decides `field`. Its control is
    /// disabled then, since a change to it would do nothing.
    func pgxpPresetDecides<T>(_ field: KeyPath<PgxpPreset, T?>) -> Bool {
        pgxpPreset?[keyPath: field] != nil
    }

    /// PGXP as the core runs it, preset included.
    var pgxpEffectivelyEnabled: Bool { pgxpPreset?.enabled ?? pgxpSetting.enabled }

    /// The depth buffer as the core runs it, which is what the session's
    /// renderer is built for.
    var pgxpEffectiveDepthBuffer: Bool {
        (pgxpPreset?.depthBuffer ?? pgxpSetting.depthBuffer) && pgxpEffectivelyEnabled
    }

    /// The player's PGXP values. The session folds the disc's preset over
    /// them itself.
    private var playerPgxp: PgxpSettings {
        let s = pgxpSetting
        return PgxpSettings(enabled: s.enabled, cpu: s.cpu, culling: s.culling,
                            vertexCache: s.vertexCache,
                            textureCorrection: s.textureCorrection,
                            colorCorrection: s.colorCorrection, depthBuffer: s.depthBuffer,
                            transparentDepth: s.transparentDepth, disable2d: s.disable2d,
                            preserveProjection: s.preserveProjection,
                            tolerance: s.tolerance < 0 ? nil : s.tolerance)
    }

    /// Whether Restore Defaults has anything to do.
    var pgxpIsDefault: Bool { pgxpSetting.isDefault }

    /// The CPU engine: persisted, applied by the session between frames.
    private var cpuEngineSetting = CpuEngineSetting()

    public var cpuEngine: CpuEngine {
        get { cpuEngineSetting.engine }
        set {
            cpuEngineSetting.set(newValue)
            pushSettings()
        }
    }

    /// Per-game VRAM readbacks: persisted by serial and sent to the session,
    /// which folds the core's table in, at boot, with a swap and on every
    /// change.
    private var vramReadbacksSetting: VramReadbacksSetting

    /// The running disc's serial: what the per-game choice is filed under.
    var discSerial: String? { game?.discSerial }

    /// The readbacks choice filed under `serial`.
    func readbacksChoice(serial: String?) -> VramReadbacks {
        vramReadbacksSetting.choice(serial: serial)
    }

    /// Video ▸ Accurate VRAM Readbacks, for the running disc.
    var vramReadbacks: VramReadbacks {
        get { vramReadbacksSetting.choice(serial: discSerial) }
        set {
            guard let discSerial else { return }
            vramReadbacksSetting.set(newValue, serial: discSerial)
            pushSettings()
        }
    }

    /// A game is running and its disc has a serial to file the choice under.
    var vramReadbacksAvailable: Bool { game?.session != nil && discSerial != nil }

    /// A choice's title in the Video menu and the Settings pane: Automatic
    /// names what it resolved to for the running game.
    func vramReadbacksTitle(_ choice: VramReadbacks) -> String {
        guard choice == .automatic, vramReadbacksAvailable else { return choice.title }
        return "\(choice.title) (\(Ps1Core.gameNeedsDualVram(serial: discSerial) ? "On" : "Off"))"
    }

    /// Every setting as one session takes them: the player's values and the
    /// running disc's readbacks choice. The session folds both tables.
    private var sessionSettings: SessionSettings {
        SessionSettings(gain: volumeSetting.gain, cpuEngine: cpuEngine,
                        runaheadFrames: runaheadSetting.frames,
                        rewindBudget: rewindSetting.budgetBytes, scale: internalScale,
                        dither: ditherMode, textureFilter: textureFilter,
                        spriteFilter: spriteFilter, pgxp: playerPgxp,
                        pgxpUsePresets: pgxpUsePresets,
                        vramReadbacks: vramReadbacks)
    }

    /// The one hand-over of every setting to the session.
    /// To every open game: a background game comes forward already set.
    func pushSettings() {
        for game in games { game.session?.setSettings(sessionSettings(for: game)) }
    }

    /// The settings `game` runs under: the player's, and its own disc's
    /// readbacks choice.
    private func sessionSettings(for game: OpenGame) -> SessionSettings {
        var settings = sessionSettings
        settings.vramReadbacks = readbacksChoice(serial: game.discSerial)
        return settings
    }

    /// Runahead: persisted, pushed to the session, carried by a new one's config.
    private var runaheadSetting = RunaheadSetting()

    var runaheadFrames: Int {
        get { runaheadSetting.frames }
        set {
            runaheadSetting.set(newValue)
            pushSettings()
        }
    }

    /// Rewind: persisted, pushed to the session as a budget, carried by a new
    /// one's config because the session is rebuilt per game.
    private var rewindSetting: RewindSetting

    var rewindEnabled: Bool {
        get { rewindSetting.enabled }
        set {
            rewindSetting.setEnabled(newValue)
            pushSettings()
            if !newValue { game?.releaseRewind() }
        }
    }

    var rewindMemoryMB: Int {
        get { rewindSetting.memoryMB }
        set {
            rewindSetting.setMemoryMB(newValue)
            pushSettings()
        }
    }

    var rewindPadButton: RewindSetting.PadButton {
        get { rewindSetting.padButton }
        set {
            rewindSetting.setPadButton(newValue)
            game?.rewindPadButtonChanged()
        }
    }

    /// Whether a multi-disc game shows as one tile: the same computed seam
    /// over a stored struct as `internalScale` above, so `@Observable`
    /// instruments it and the grid re-folds on a change.
    private var multiDiscSetting = MultiDiscSetting()

    public var mergeMultiDisc: Bool {
        get { multiDiscSetting.merging }
        set { multiDiscSetting.set(newValue) }
    }

    /// What the grid renders. Folded on demand rather than stored: the inputs
    /// are `library.entries` and the setting, both observable, so a stored copy
    /// would be a third thing to keep in step with them.
    var groups: [GameGroup] {
        DiscGrouping.group(library.entries, merging: mergeMultiDisc)
    }

    /// The toolbar's tabs: Multi-Disc only while some game has discs to merge.
    var libraryTabs: [LibraryTab] { LibraryCollection.tabs(groups) }

    /// The tab actually open: `libraryTab`, or All Games once the tab it
    /// names is no longer offered.
    var libraryTabShown: LibraryTab { LibraryCollection.effective(libraryTab, groups: groups) }

    /// What the library shows: `groups` in the open tab, narrowed by the
    /// toolbar search.
    var visibleGroups: [GameGroup] {
        let keys = LibraryCollection.statsKeys(library.entries)
        let stats = { LibraryCollection.stats(for: $0, keys: keys, stats: self.playStats.all) }
        var shown = LibraryCollection.filter(groups, tab: libraryTabShown) { stats($0)?.lastPlayed }
        if libraryTabShown != .recent {
            shown = LibraryCollection.sorted(shown, by: libraryOrder, stats: stats)
        }
        return LibrarySearch.filter(shown, query: librarySearch)
    }

    /// Whether Sort By applies: not to Recently Played, whose order is the tab.
    var librarySortApplies: Bool { libraryTabShown != .recent }

    /// When each game was last played, by group id, for the tiles' second line.
    var lastPlayedByGroup: [GameGroup.ID: Date] {
        let keys = LibraryCollection.statsKeys(library.entries)
        var dates: [GameGroup.ID: Date] = [:]
        for group in groups {
            dates[group.id] = LibraryCollection.stats(for: group, keys: keys, stats: playStats.all)?.lastPlayed
        }
        return dates
    }

    /// The toolbar's Continue capsule: the game played last.
    var continueGroup: GameGroup? {
        let dates = lastPlayedByGroup
        return LibraryCollection.continueGroup(groups) { dates[$0.id] }
    }

    /// Output volume, 0...1 plus a mute flag, persisted: the same computed
    /// seam over a stored struct as `internalScale` above, for the same
    /// reason: `@Observable` instruments the stored `volumeSetting`, so the
    /// HUD's slider and speaker icon both track it.
    ///
    /// The gain is pushed into the session on every change AND carried by
    /// the config `load(disc:)` builds one with, because the session is
    /// rebuilt per game while the setting outlives every disc.
    private var volumeSetting = VolumeSetting()

    var volume: Double {
        get { volumeSetting.level }
        set {
            volumeSetting.set(newValue)
            pushSettings()
        }
    }

    var isMuted: Bool { volumeSetting.isMuted }

    func toggleMute() {
        volumeSetting.toggleMute()
        pushSettings()
    }

    /// Machine ▸ Mute. The HUD's speaker shows its own change; a shortcut
    /// shows nothing else, so it says so in the badge stack.
    func toggleMuteFromMenu() {
        toggleMute()
        settingNotice(isMuted ? NoticeIcon.muted : NoticeIcon.volume, isMuted ? "Muted" : "Unmuted")
    }

    static let volumeStep = 0.1

    /// Machine ▸ Increase and Decrease Volume: to the next tenth up or down,
    /// so a level the slider left between two tenths lands on one. Unmutes,
    /// as the slider does.
    func stepVolume(by steps: Int) {
        let tenths = volume / Self.volumeStep
        let from = steps > 0 ? (tenths + 1e-6).rounded(.down) : (tenths - 1e-6).rounded(.up)
        volume = (from + Double(steps)) * Self.volumeStep
        settingNotice(NoticeIcon.volume, "Volume \(Int((volume * 100).rounded()))%")
    }

    /// Emulation speed, persisted, plus the session-only held fast-forward:
    /// the same computed seam over a stored struct as `volume` above. Pushed
    /// into the session, whose audio paces it, and re-applied in
    /// `load(disc:)` because the session is rebuilt per game while the
    /// setting outlives every disc.
    private var speedSetting = SpeedSetting()

    var speed: Int {
        get { speedSetting.base }
        set {
            speedSetting.setBase(newValue)
            applySpeed()
        }
    }

    var fastForwardSpeed: Int {
        get { speedSetting.turbo }
        set {
            speedSetting.setTurbo(newValue)
            applySpeed()
        }
    }

    var isFastForwarding: Bool { speedSetting.isFastForwarding }

    /// What the game is actually running at right now.
    var effectiveSpeed: Int { speedSetting.effective }

    func cycleSpeed() {
        speedSetting.cycleBase()
        applySpeed()
    }

    /// A setting changed by a key or the menu bar, which shows nothing else
    /// in a game.
    private func settingNotice(_ icon: String, _ text: String) {
        game?.settingNotice(icon, text)
    }

    func setFastForwarding(_ held: Bool) {
        guard held != speedSetting.isFastForwarding else { return }
        speedSetting.isFastForwarding = held
        applySpeed()
    }

    private func applySpeed() {
        game?.session?.setSpeed(speedSetting.effective)
    }

    var hasBIOSFolder: Bool { bios.folderURL != nil }
    var biosFolderName: String? { bios.folderURL?.lastPathComponent }
    var gamesFolderName: String? { library.folderURL?.lastPathComponent }
    var biosFolderURL: URL? { bios.folderURL }
    var gamesFolderURL: URL? { library.folderURL }

    public func chooseBIOSFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your SCPH-*.bin BIOS files"
        ) else { return }
        setBIOSFolder(url)
    }

    /// Also onboarding's drop target, so a folder dragged from Finder is the
    /// same choice as one picked in the panel.
    func setBIOSFolder(_ url: URL) {
        defer { surveyBios() }
        do {
            try bios.setFolder(url)
        } catch {
            showLibraryError("This BIOS folder works for now, but could not be remembered. Choose it again next time you open Substation.")
        }
    }

    public func chooseGamesFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your games. Subfolders are scanned too."
        ) else { return }
        setGamesFolder(url)
    }

    func setGamesFolder(_ url: URL) {
        do {
            try library.setFolder(url)
        } catch {
            showLibraryError("This games folder works for now, but could not be remembered. Choose it again next time you open Substation.")
        }
    }

    /// Forwards to `library.rescan()`. `GameLibrary` itself is `internal`, so
    /// this is the one seam File ▸ Refresh Library calls; `public` follows the
    /// same app-facing-surface convention as `isPaused`, not a module
    /// boundary: `Sources/PS1App` compiles into this same `PS1` module.
    public func rescanLibrary() { library.rescan() }

    /// What onboarding found in the BIOS folder. Read only there: a game
    /// asks `BiosLibrary` for its region's image at boot.
    private(set) var biosFound: [FoundBios] = []
    private(set) var isSurveyingBios = false
    private var biosSurveyGeneration = 0

    /// `GameLibrary.rescan`'s generation rule: a slow survey of a folder
    /// since replaced must not publish over the new one.
    func surveyBios() {
        biosSurveyGeneration += 1
        let generation = biosSurveyGeneration
        guard bios.folderURL != nil else {
            biosFound = []
            isSurveyingBios = false
            return
        }
        isSurveyingBios = true
        Task { [weak self, bios] in
            let found = await bios.survey()
            guard let self, generation == self.biosSurveyGeneration else { return }
            self.biosFound = found
            self.isSurveyingBios = false
        }
    }

    /// The region this disc needs a BIOS for, when the BIOS folder holds
    /// none it boots from by the rule `BiosLibrary` applies at boot; nil
    /// when it can start.
    func missingBios(for disc: GameEntry) -> BiosRegion? {
        let region = BiosRegion.forDisc(disc.identity, named: disc.url.lastPathComponent)
        return biosFound.contains { $0.serves(region) } ? nil : region
    }

    /// Both folders chosen, both scans finished, and a BIOS image among the
    /// files: a folder with none in it would open a library where nothing
    /// boots.
    var onboardingReady: Bool {
        !biosFound.isEmpty && library.folderURL != nil
            && !isSurveyingBios && !library.isScanning
    }

    /// Onboarding's Open Library. Guarded rather than trusted: the button is
    /// disabled until `onboardingReady`, but the stage is the thing the rest
    /// of the app branches on, so it checks for itself.
    func finishOnboarding() {
        guard onboardingReady else { return }
        stage = .library
    }

    func play(_ entry: GameEntry) {
        launchFromOutside = false
        launchInGameWindow = false
        launch(entry.url)
    }

    /// The Continue capsule: straight back into the game's resume state,
    /// with no sheet, since carrying on is the whole request. A game with
    /// no usable resume (only slots, or its resume disc gone) opens as a
    /// tile does, so the sheet can say why.
    func continuePlaying(_ group: GameGroup) {
        launchFromOutside = false
        launchInGameWindow = false
        resumeOrLaunch(group)
    }

    private func resumeOrLaunch(_ group: GameGroup) {
        let entry = group.first
        if let open = openGame(holding: entry.url) { return bringForward(open) }
        let siblings = Self.siblingDiscs(of: entry.url, entries: library.entries)
        guard let offer = ResumeOffer.make(launching: entry, siblings: siblings, store: saveStates),
              offer.info != nil, offer.resumeDisc != nil
        else { return launch(entry.url) }
        resume(from: .resume, offer: offer)
    }

    /// Opens a game, offering its resume state first when it has one.
    func launch(_ url: URL) {
        // Two machines of one game would share its resume state and stats.
        if let open = openGame(holding: url) { return bringForward(open) }
        // The launching disc's WHOLE group, itself included: the offer maps
        // the state's serial onto one of these, and an empty list would
        // disable Resume for every game.
        let siblings = Self.siblingDiscs(of: url, entries: library.entries)
        let launching = siblings.first { Self.canonicalPath($0.url) == Self.canonicalPath(url) }
            ?? Self.discEntry(for: url)
        if let offer = ResumeOffer.make(launching: launching, siblings: siblings, store: saveStates) {
            resumeOffer = offer
        } else {
            load(disc: url)
        }
    }

    /// The open game this disc belongs to: any disc of its set, so a disc
    /// not in the tray still finds it. The player swaps from inside it.
    private func openGame(holding url: URL) -> OpenGame? {
        let path = Self.canonicalPath(url)
        return games.first { $0.currentDiscs.contains { Self.canonicalPath($0.url) == path } }
    }

    private func bringForward(_ game: OpenGame) {
        if game.inOwnWindow { requestWindow(.game(game.id)) } else { libraryRequests += 1 }
    }

    func chooseResume(_ choice: ResumeChoice) {
        guard let offer = resumeOffer else { return }
        resumeOffer = nil
        switch choice {
        case .resume:
            resume(from: .resume, offer: offer)
        case .load(let source):
            resume(from: source, offer: offer)
        case .freshBoot:
            load(disc: offer.launching.url)
        case .cancel:
            leaveForLibrary()
        }
    }

    /// A tile's delete, confirmed by the sheet. The sheet stays up, with
    /// Start Fresh alone once the last state is gone: a delete never boots.
    func deleteOfferedState(_ source: StateSource) {
        guard let key = resumeOffer?.key else { return }
        saveStates.remove(source, key: key)
        resumeOffer?.remove(source)
    }

    private func resume(from source: StateSource, offer: ResumeOffer) {
        guard let state = saveStates.load(source, key: offer.key) else {
            resumeFailure = ResumeFailure(message: Self.resumeMessage(Ps1Error.stateCorrupt),
                                          freshBoot: offer.launching.url)
            return
        }
        let siblings = Self.siblingDiscs(of: offer.launching.url, entries: library.entries)
        guard let disc = ResumeOffer.disc(for: state, launching: offer.launching, siblings: siblings) else {
            resumeFailure = ResumeFailure(message: Self.resumeMessage(Ps1Error.stateDisc),
                                          freshBoot: offer.launching.url)
            return
        }
        load(disc: disc.url, resume: state, freshBoot: offer.launching.url)
    }

    /// Cancel on the "Could not resume" alert.
    func cancelResumeFailure() {
        resumeFailure = nil
        leaveForLibrary()
    }

    /// Cancel on the launch sheet or its failure alert goes back to the
    /// library. A game is still installed under them only when the sheet came
    /// from Open Disc over a running game: that exit was already confirmed
    /// (and saved), so it is finished here rather than left paused.
    private func leaveForLibrary() {
        if gameWindowMode == .libraryWindow, let libraryGame { ejectNow(libraryGame) }
    }

    /// A refusal of the resume state itself, as opposed to the disc or the
    /// BIOS it was loaded beside.
    static func refusesState(_ error: Ps1Error) -> Bool {
        switch error {
        case .stateBadMagic, .stateVersion, .stateBIOS, .stateDisc, .stateCorrupt, .statePatch: true
        default: false
        }
    }

    static func resumeMessage(_ error: Error) -> String {
        switch error as? Ps1Error {
        case .stateVersion: "This state was saved by a newer version of Substation."
        case .stateBIOS: "This state was saved with a different BIOS."
        case .stateDisc: "This state belongs to a different disc."
        case .statePatch: "This state was saved with a different .ppf patch beside the disc, or with none."
        default: "The saved state is damaged."
        }
    }

    func coverURL(for entry: GameEntry) -> URL? {
        _ = coverRevision      // read it so SwiftUI re-runs this on a change
        return covers.coverURL(for: entry)
    }

    func chooseCover(for entry: GameEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover image for \(entry.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try covers.setCover(from: url, for: entry)
            coverRevision += 1
        } catch {
            showLibraryError("That image could not be read.")
        }
    }

    func removeCover(for entry: GameEntry) {
        try? covers.removeCover(for: entry)
        coverRevision += 1
    }

    // MARK: - Downloading covers

    /// Set while a download is in flight, so the menu item can disable itself
    /// rather than letting a second sweep race the first into `CoverStore`.
    private(set) var isDownloadingCovers = false

    /// Set when the style changes during a download: a sweep in flight is
    /// fetching the old style, so the restyle runs once it has landed.
    private var restylePending = false

    /// A new style fetches itself for the whole library, when downloading
    /// automatically is on: a style that applied only to covers fetched from
    /// then on would leave the grid a mix of the two.
    var coverSource: CoverSource {
        get { coverSourceSetting.source }
        set {
            guard newValue != coverSourceSetting.source else { return }
            coverSourceSetting.set(newValue)
            if autoCoverSetting.enabled { restyleCovers() }
        }
    }

    private func restyleCovers() {
        guard !isDownloadingCovers else { restylePending = true; return }
        let wanted = sweepPolicy.restyle(from: library.entries, isPicked: { covers.isPicked($0) })
        sweepPolicy.record(wanted)
        download(for: wanted)
    }

    var autoDownloadCovers: Bool {
        get { autoCoverSetting.enabled }
        set { autoCoverSetting.set(newValue) }
    }

    /// Only discs with no cover yet, so running it twice is cheap and a
    /// hand-picked cover is never overwritten by a downloaded one.
    func downloadMissingCovers() {
        sweep(automatic: false)
    }

    /// Runs itself after every scan that finds discs without covers. Skips
    /// serials this session has already been told the collection lacks, so a
    /// ⇧⌘R does not re-ask for the same misses each time; the manual command
    /// does not skip them, because asking again IS the retry.
    private func autoDownloadCoversIfEnabled() {
        guard autoCoverSetting.enabled else { return }
        sweep(automatic: true)
    }

    private func sweep(automatic: Bool) {
        let wanted = sweepPolicy.discs(from: library.entries,
                                       hasCover: { covers.coverURL(for: $0) != nil },
                                       automatic: automatic)
        sweepPolicy.record(wanted)
        download(for: wanted, quiet: automatic)
    }

    /// One disc, replacing whatever it has: this one is reached from the
    /// tile's own menu, where the request is explicit.
    func downloadCover(for entry: GameEntry) {
        download(for: [entry])
    }

    /// `quiet` suppresses the summary: an automatic sweep the player did not
    /// ask for should leave covers behind, not a status line reporting on work
    /// they never requested. Failures still surface.
    private func download(for entries: [GameEntry], quiet: Bool = false) {
        guard !isDownloadingCovers, !entries.isEmpty else { return }
        isDownloadingCovers = true

        let downloader = CoverDownloader(fetcher: HTTPCoverFetcher(), source: coverSource)
        Task { [weak self] in
            let (fetched, summary) = await downloader.fetchCovers(for: entries)

            // Back on the main actor: `CoverStore` writes files and
            // `coverRevision` drives the grid, so neither belongs in the
            // concurrent fetch above.
            guard let self else { return }
            var stored = 0
            for cover in fetched where (try? self.covers.setCover(from: cover.data,
                                                                  for: cover.entry)) != nil {
                stored += 1
            }
            self.coverRevision += 1
            self.isDownloadingCovers = false
            if !quiet || summary.failed > 0 { self.report(summary, stored: stored) }
            if self.restylePending {
                self.restylePending = false
                self.restyleCovers()
            }
        }
    }

    /// A count, not an alert per disc: a library sweep legitimately finds
    /// dozens of discs the collection has no cover for, and that is not an
    /// error worth interrupting anyone over.
    private func report(_ summary: CoverDownloader.Summary, stored: Int) {
        if stored == 0 && summary.missing == 0 && summary.failed > 0 {
            showLibraryError("No covers could be downloaded. Check your network connection.")
            return
        }
        var parts = ["Downloaded \(stored) cover\(stored == 1 ? "" : "s")"]
        if summary.missing > 0 { parts.append("\(summary.missing) not in the collection") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) with no serial") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        showCoverDownloadSummary(parts.joined(separator: ", ") + ".")
    }

    /// Shown in the library, not as a modal: the result of a sweep is
    /// information, and the grid has already redrawn with the new covers.
    /// It clears itself after `summaryLifetime`; a newer summary restarts
    /// the clock rather than being cleared by the older one's.
    private(set) var coverDownloadSummary: String?
    private var summaryDismissal: Task<Void, Never>?
    static let summaryLifetime: Duration = .seconds(4)

    private func showCoverDownloadSummary(_ text: String) {
        coverDownloadSummary = text
        summaryDismissal?.cancel()
        summaryDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.summaryLifetime)
            guard !Task.isCancelled else { return }
            self?.coverDownloadSummary = nil
        }
    }

    private static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    public func openDisc() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Open a disc image (.cue, .chd or .bin) or a PlayStation executable (.exe, .psx, .cpe or .elf)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// A disc handed to the app from outside: Open Disc, or Finder opening a
    /// `.cue` with Substation. A running game is asked about first, as for
    /// every other way of leaving it.
    public func open(_ url: URL) {
        if requestExit(.open(url)) == .proceed { launchOpened(url) }
    }

    private func launchOpened(_ url: URL) {
        launchFromOutside = true
        launchInGameWindow = gameWindowMode == .newWindow
        launch(url)
    }

    // MARK: Open Recent and the Dock menu

    /// AppKit's list; a test swaps in one of its own.
    @ObservationIgnored var recents: RecentDiscs = .current {
        didSet { refreshRecentDiscs() }
    }

    /// File ▸ Open Recent, newest first. A mirror of AppKit's list, which is
    /// not observable, without the discs no longer on disk.
    private(set) var recentDiscs: [URL] = RecentDiscs.current.urls().filter(EmulatorViewModel.discExists)

    func clearRecentDiscs() {
        recents.clear()
        refreshRecentDiscs()
    }

    private func refreshRecentDiscs() {
        recentDiscs = recents.urls().filter(Self.discExists)
    }

    private nonisolated static func discExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The Dock menu's Resume: the Continue capsule's game, offered only from
    /// the library, since in a game it is the game already running.
    var dockResumeGroup: GameGroup? {
        stage == .library ? continueGroup : nil
    }

    // MARK: App Intents

    /// Bumped by Open Library; every window's `GameWindowOpener` opens the
    /// library on it, since the library window may be closed.
    private(set) var libraryRequests = 0

    /// Where the library's games go for Spotlight and Siri; a test counts
    /// them instead.
    @ObservationIgnored var publishEntities: @MainActor ([GameEntity]) async -> Void = { entities in
        if publishesToSystem { await EmulatorViewModel.indexInSpotlight(entities) }
    }

    /// False in the hosted test app, which scans the developer's real
    /// library every time a test builds a model and must not write their
    /// Spotlight index each time.
    static let publishesToSystem = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    /// Replaces Spotlight's copy of the library, the App Shortcuts'
    /// parameters and the thumbnail index: after a scan, a play and a cover
    /// change. A second after the last request, and never two writes at
    /// once, so a download sweep's burst is one write and an older set
    /// cannot land after a newer one.
    func publishGamesToSystem() {
        let previous = publishTask
        previous?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            let games = GameCatalog.games(self.library.entries)
            await self.publishEntities(games.map { self.entity($0, in: games) })
            self.publishThumbnails(ThumbnailIndex.make(games, cover: self.covers.coverURL))
        }
    }

    /// Where Finder's thumbnails find each disc's cover; a test reads the
    /// index instead.
    @ObservationIgnored var publishThumbnails: @MainActor ([String: String]) -> Void = { index in
        guard publishesToSystem else { return }
        do { try ThumbnailIndex.write(index) } catch {
            NSLog("Substation: thumbnail index failed to write: \(error)")
        }
    }

    /// The games an intent may name, once the library has been scanned.
    func intentGames() async throws(IntentFailure) -> [GameGroup] {
        guard stage != .onboarding else { throw .notSetUp }
        return GameCatalog.games(await library.scanned())
    }

    /// Play Game: exactly Finder opening the game's first disc. A prompt
    /// already up refuses it, and Siri says so rather than "done".
    func playFromIntent(_ game: GameGroup) throws(IntentFailure) {
        let url = game.first.url
        if try Self.intentDecision(requestExit(.open(url))) { launchOpened(url) }
    }

    /// Resume Game: the Continue capsule's rule, entered from outside, so a
    /// running game is asked about first.
    func resumeFromIntent(_ game: GameGroup) throws(IntentFailure) {
        if try Self.intentDecision(requestExit(.resume(game))) { resumeOpened(game) }
    }

    /// Whether to go ahead now; `.prompted` goes ahead after the sheet.
    private static func intentDecision(_ decision: ExitDecision) throws(IntentFailure) -> Bool {
        switch decision {
        case .proceed: true
        case .prompted: false
        case .busy: throw .busy
        }
    }

    private func resumeOpened(_ game: GameGroup) {
        launchFromOutside = true
        launchInGameWindow = gameWindowMode == .newWindow
        resumeOrLaunch(game)
    }

    /// A game playing in the library window stays as it is: the window is
    /// the game.
    func openLibraryFromIntent() {
        libraryRequests += 1
        NSApp.activate()
    }

    /// The one spelling of a path that two different producers agree on.
    ///
    /// `GameScanner`'s URLs come out of `FileManager`'s enumerator; a disc
    /// opened through `NSOpenPanel` does not. On macOS `/tmp` and `/var` are
    /// symlinks into `/private`, so the two name the same file differently and
    /// matching on `GameEntry.id` (which is the raw path) silently finds
    /// nothing. `GameEntry.id` itself is left alone: it is the cover-art key,
    /// and changing it would orphan every cover already on disk.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Every disc of the game `url` belongs to, in disc order. The library's
    /// complete scan lets catalogued sets cross arbitrary renamed folders;
    /// standalone callers retain the local filename-based fallback.
    static func siblingDiscs(of url: URL, entries: [GameEntry]? = nil) -> [GameEntry] {
        // The SCOPE directory, not the disc's own: Final Fantasy VII puts each
        // disc in its own subfolder, so scanning that folder finds exactly one
        // disc and Change Disc would offer nothing to change to.
        let entries = entries ?? GameScanner.scan(root: DiscGrouping.scopeDirectory(of: url))
        let target = canonicalPath(url)

        let group = DiscGrouping.group(entries, merging: true)
            .first { $0.discs.contains { canonicalPath($0.url) == target } }
        return group?.discs ?? [discEntry(for: url)]
    }

    /// An entry for a disc that is not in the library, IDENTIFIED as the
    /// scanner identifies one: without its serial, its resume key would be a
    /// path hash and no state header could ever name it.
    static func discEntry(for url: URL) -> GameEntry {
        let identity = DiscKind(url) == .exe ? DiscIdentity.identify(exe: url) : DiscIdentity.identify(disc: url)
        return GameEntry(url: url, identity: identity ?? .unknown)
    }

    func load(disc url: URL, resume: Data? = nil, freshBoot: URL? = nil,
              resumeRefused: ((Error) -> Void)? = nil) {
        // Set the instant the new game is installed: the point past which a
        // failure can no longer leave the open games untouched, only the new
        // one half-built. See the catch block below.
        var installed: OpenGame?
        do {
            let kind = DiscKind(url)
            let binData: Data
            let cueData: Data?
            if kind == .cue {
                let image = try Self.discImage(forCue: url)
                binData = image.bin
                cueData = image.cue
            } else {
                binData = try Data(contentsOf: url)
                cueData = nil
            }
            // Identified from the bytes already in hand rather than by
            // mapping the file a second time. The filename is still passed:
            // it is the fallback for a disc that names no region at all.
            let identity: DiscIdentity
            if kind == .exe {
                guard let exeIdentity = DiscIdentity.identify(exeImage: binData) else { throw Ps1Error.badExe }
                identity = exeIdentity
            } else {
                identity = DiscIdentity.identify(image: binData)
            }
            let biosData = try bios.biosData(forDisc: url.lastPathComponent,
                                             identity: identity)

            let bootedBios = BiosIdentity.identify(biosData)
            let host = SessionHostView()
            // The running disc's serial is still the outgoing game's here.
            var settings = sessionSettings
            settings.vramReadbacks = vramReadbacksSetting.choice(serial: identity.serial)
            let config = SessionConfig(
                bios: biosData,
                disc: kind == .exe ? nil : DiscBytes(bin: binData, cue: cueData, sbi: Self.sidecar(forDisc: url),
                                                     ppf: Self.patch(forDisc: url)),
                exe: kind == .exe ? ExeBytes(exe: binData, libps: Self.libps(forExe: url)) : nil,
                resumeState: resume, cardDirectory: cards.directory, view: host,
                // In the config rather than set after: the resume state
                // restores the I-cache as the saving machine held it, and a
                // later switch would flush it.
                settings: settings, fastBoot: fastBoot)
            let session: any GameSession
            do throws(Ps1Error) {
                session = try makeSession(config)
            } catch {
                guard resume != nil, Self.refusesState(error) else { throw error }
                // In a running game the refusal is a notice: the launch
                // alert's Cancel would eject the game still playing.
                if let resumeRefused { resumeRefused(error); return }
                resumeFailure = ResumeFailure(message: Self.resumeMessage(error),
                                              freshBoot: freshBoot ?? url)
                return
            }

            // The new session is fully built and starts nothing yet. Only NOW
            // is it safe to replace the game in the library's window: opening
            // a disc that fails to load (bad cue, missing BIOS, unreadable
            // bin) must leave the current game untouched, not kill it out
            // from under the player and then show an error on top.
            //
            // And BEFORE `start()`, never after: freeing the outgoing session
            // is what writes its cards, and `start()` is what reads them, so
            // the other order would load stale bytes and then write them back
            // over the save it was about to make. A game left running in
            // another window hands its cards over instead (`install`).
            let game = OpenGame(app: self, session: session, hostView: host,
                                inOwnWindow: gameWindowMode == .newWindow,
                                fullScreen: gameWindowFullScreen)
            install(game)
            installed = game
            game.biosImage = bootedBios
            host.onGeometry = { [weak session] points, backingScale in
                session?.setSize(points: points, backingScale: backingScale)
            }

            // The config carried every setting. The preset is set only now,
            // past the teardown, so a disc that fails to load leaves the
            // running game's preset alone.
            game.discPgxpPreset = PgxpPreset.lookup(serial: identity.serial)
            game.discSerial = identity.serial
            applySpeed()
            session.setBandShown(game.hudVisible && !game.isOpen(.pauseMenu))
            try session.start()
            game.startAutoSave()

            game.discTitle = identity.title ?? url.deletingPathExtension().lastPathComponent
            game.currentDiscs = Self.siblingDiscs(of: url, entries: library.entries)
            game.currentDiscIndex = game.currentDiscs.firstIndex {
                Self.canonicalPath($0.url) == Self.canonicalPath(url)
            }
            let resumeKey = SaveStateStore.key(for: game.currentDiscs.first ?? Self.discEntry(for: url))
            game.resumeKey = resumeKey
            playStats.markPlayed(resumeKey, at: Date())
            publishGamesToSystem()
            recents.note(url)
            refreshRecentDiscs()
            game.updatePlayClock()
            // A raw .bin cannot represent audio tracks, so a CD-DA title opened
            // this way is silent, which looks like a bug unless we say so.
            showRawBinWarning = kind == .bin
        } catch {
            if let installed {
                // `start()` refused (no audio output) with the new session
                // already installed: tear it down so the failure lands on a
                // coherent stage rather than a game that never runs under a
                // plain error alert. That game, never the running one: a
                // hand-over in flight leaves the new game still waiting.
                ejectNow(installed)
            }
            errorMessage = Self.describe(error)
        }
    }

    /// Puts `new` among the open games. In the library's window it replaces
    /// the game there; in a window of its own it opens beside the rest. A
    /// game that opens while another runs starts paused, and comes in through
    /// the card hand-over once that game's cards are on disk.
    private func install(_ new: OpenGame) {
        if !new.inOwnWindow, let old = libraryGame { remove(old) }
        games.append(new)
        stage = .playing
        if game != nil {
            new.setBackgrounded(true)
            requestSwitch(to: new.id)
        } else {
            game = new
            gameSwitch.adopt(new.id)
        }
        if new.inOwnWindow { requestWindow(.game(new.id)) }
    }

    /// Stops `old` and forgets it. No other game resumes: the next window
    /// to come forward decides that.
    private func remove(_ old: OpenGame) {
        let wasRunning = game === old
        old.teardown()
        games.removeAll { $0 === old }
        if promptGame === old { promptGame = nil }
        if queuedSwitch == old.id { queuedSwitch = nil }
        let steps = gameSwitch.removed(old.id)
        game = gameSwitch.running.flatMap(game(with:))
        if wasRunning {
            haptics.release()
            // A held fast-forward key's release would never arrive, and the
            // next game would start fast-forwarding.
            speedSetting.isFastForwarding = false
        }
        // Only steps of its own: a hand-over in flight is not this one's to
        // finish, and finishing it would let a second one start beside it.
        if !steps.isEmpty { run(steps[...]) }
    }

    /// A game's window, or the library's window holding its game, became
    /// the key window: that game runs.
    func gameWindowBecameKey(_ id: UUID) {
        requestSwitch(to: id)
    }

    func libraryWindowBecameKey() {
        if let libraryGame { requestSwitch(to: libraryGame.id) }
    }

    private func requestSwitch(to id: UUID) {
        guard game(with: id) != nil else { return }
        if switchInFlight {
            queuedSwitch = id
            return
        }
        let steps = gameSwitch.request(to: id, outgoingSaving: game?.savingToMemoryCard ?? false)
        game = gameSwitch.running.flatMap(game(with:))
        run(steps[...])
    }

    /// A game's card write has settled: a switch waiting on it lands.
    func cardWritesSettled(_ settled: OpenGame) {
        guard gameSwitch.deferred?.from == settled.id else { return }
        run(gameSwitch.outgoingSettled()[...])
    }

    /// Carries a switch's steps out in order, each card request's answer
    /// starting the next. A game gone by then is skipped: its session wrote
    /// its cards as it stopped.
    private func run(_ steps: ArraySlice<GameSwitch.Step>) {
        guard let step = steps.first else { return finishSwitch() }
        let rest = steps.dropFirst()
        switch step {
        case .background(let id):
            game(with: id)?.setBackgrounded(true)
            run(rest)
        case .flushCards(let id), .reinstallCards(let id):
            guard let session = game(with: id)?.session else { return run(rest) }
            switchInFlight = true
            let next: @MainActor (Ps1Error?) -> Void = { [weak self] _ in self?.run(rest) }
            if case .flushCards = step { session.requestFlushCards(next) } else { session.requestReinstallCards(next) }
        case .foreground(let id):
            // A newer switch is waiting: this game is not the one to run.
            if let queued = queuedSwitch, queued != id { return finishSwitch() }
            queuedSwitch = nil
            game(with: id)?.setBackgrounded(false)
            applySpeed()
            driveHaptics()
            run(rest)
        }
    }

    private func finishSwitch() {
        switchInFlight = false
        guard let queued = queuedSwitch else { return }
        queuedSwitch = nil
        requestSwitch(to: queued)
    }

    /// Quit Game, from the Machine menu (the running game) or a game's own
    /// pause menu.
    func eject(_ target: OpenGame? = nil) {
        let target = target ?? game
        if requestExit(.eject, for: target) == .proceed { ejectNow(target) }
    }

    /// A game window's close button and ⌘W: Eject for that game, sheet and
    /// all. The window closes now only when nothing was asked; otherwise it
    /// closes itself once its game has ended.
    func closeGameWindow(_ content: GameWindowContent) -> Bool {
        guard case .game(let id) = content, let target = game(with: id) else {
            dismissLaunchDialogs()
            return true
        }
        eject(target)
        return game(with: id) == nil
    }

    /// The library window's close button and ⌘W. With no game in it, it
    /// closes and any game in a window of its own plays on. Otherwise closing
    /// it quits, through the exit sheet.
    func closeLibraryWindow() -> Bool {
        if libraryGame == nil && gameWindowShown { return true }
        return requestExit(.closeWindow) == .proceed
    }

    /// An alert about the library itself, which belongs in the library's
    /// window even after a launch put the last one in the game's.
    private func showLibraryError(_ message: String) {
        launchInGameWindow = false
        errorMessage = message
    }

    /// Closing the game window while it holds only a launch's sheet or alert
    /// answers it as Cancel or OK would.
    private func dismissLaunchDialogs() {
        if resumeOffer != nil { chooseResume(.cancel) }
        if resumeFailure != nil { cancelResumeFailure() }
        errorMessage = nil
        showRawBinWarning = false
    }

    private func ejectNow(_ target: OpenGame?) {
        if let target { remove(target) }
        if games.isEmpty { stage = .library }
    }

    /// The exit or resume dialog is on screen (see `ModalDialog`).
    var isDialogShown: Bool { exitPrompt != nil || resumeOffer != nil }

    /// The game an exit asks about when the caller names none: Quit Game
    /// leaves the running game; opening a disc leaves only the game it
    /// replaces, the one in the library's window, and in New Window mode
    /// none at all.
    private func exitTarget(for intent: ExitIntent) -> OpenGame? {
        switch intent {
        case .eject: game
        case .open, .resume: gameWindowMode == .libraryWindow ? libraryGame : nil
        case .quit, .closeWindow: game ?? games.first
        }
    }

    /// Every way of leaving a game comes through here. `.prompted` pauses
    /// the game and raises the sheet on it; the caller then waits.
    func requestExit(_ intent: ExitIntent, for target: OpenGame? = nil) -> ExitDecision {
        // Another sheet or alert is up, or an exit is already finishing: a
        // second prompt on top of it could be dropped, leaving ⌘Q unanswered.
        // A sheet on any game counts, not only one on the game asked about.
        if finishingExit || resumeOffer != nil || resumeFailure != nil || exitGate.pending != nil {
            return .busy
        }
        // Quitting leaves every game: each is asked about in turn, the
        // running one first.
        if target == nil && (intent == .quit || intent == .closeWindow) {
            let open = games.filter { $0.session != nil }
            quitQueue = open.filter { $0 === game } + open.filter { $0 !== game }
            guard !quitQueue.isEmpty else { return exitGate.request(intent, playing: false) }
            return ask(intent, about: quitQueue.removeFirst())
        }
        let target = target ?? exitTarget(for: intent)
        guard let target, target.session != nil else { return exitGate.request(intent, playing: false) }
        return ask(intent, about: target)
    }

    /// Raises the exit sheet on `target`.
    private func ask(_ intent: ExitIntent, about target: OpenGame) -> ExitDecision {
        let decision = exitGate.request(intent, playing: true)
        guard decision == .prompted else { return decision }
        // Before the pause is read: the sheet restores the game's own, not
        // the one the menu was holding.
        target.closeAllSurfaces()
        target.pausedBeforePrompt = target.isPaused
        target.isPaused = true
        target.exitPrompt = intent
        promptGame = target
        // The sheet sits on the game, so its window comes forward.
        if target.inOwnWindow { requestWindow(.game(target.id)) }
        return decision
    }

    func cancelExit() {
        let intent = exitGate.cancel()
        if let promptGame {
            promptGame.exitPrompt = nil
            promptGame.isPaused = promptGame.pausedBeforePrompt
        }
        promptGame = nil
        // The games already answered stay ejected: their saves are written.
        quitQueue = []
        if intent == .quit { replyToTerminate(false) }
    }

    func confirmExit() {
        guard let intent = exitGate.take() else { return }
        let target = promptGame
        target?.exitPrompt = nil
        promptGame = nil
        finishingExit = true
        let finish = ExitCompletion { [weak self] in self?.finishExit(intent, target: target) }
        guard saveStateOnExit, let session = target?.session, let key = target?.resumeKey else {
            return finish.fire()
        }

        // The completion runs on the main actor, a turn after the session
        // answered (or at once, refused). The write itself runs off the main
        // actor, as the auto-save's does: compression, and the store's queue
        // an auto-save may hold, would stall the UI.
        let store = saveStates
        session.requestSave { result in
            Task { @MainActor in
                finish.noteAnswered()
                await Task.detached {
                    switch result {
                    case .success(let snap):
                        do { try store.saveResume(state: snap.state, thumbnail: snap.thumbnail, key: key) }
                        catch { NSLog("Substation: resume state failed to write: \(error)") }
                    case .failure(let error):
                        NSLog("Substation: resume state failed to save: \(error)")
                    }
                }.value
                finish.fire()
            }
        }
        // A save the session never answers must not hold the exit hostage.
        // Three seconds is a hundred-odd frames.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            finish.fireFallback()
        }
    }

    private func finishExit(_ intent: ExitIntent, target: OpenGame?) {
        finishingExit = false
        // A quit with games still to ask about: this one has been answered
        // and saved, so it goes, and the next one asks.
        quitQueue.removeAll { $0.session == nil }
        if intent == .quit || intent == .closeWindow, !quitQueue.isEmpty {
            ejectNow(target)
            _ = ask(intent, about: quitQueue.removeFirst())
            return
        }
        switch intent {
        case .quit:
            replyToTerminate(true)
        case .closeWindow:
            exitConfirmed = true
            NSApp.terminate(nil)
        case .eject:
            ejectNow(target)
        case .open(let url):
            launchOpened(url)
        case .resume(let game):
            resumeOpened(game)
        }
    }

    private func replyToTerminate(_ yes: Bool) {
        if yes { exitConfirmed = true }
        terminateReply?(yes)
        terminateReply = nil
    }

    /// ⌘Q's last step: every game stops, which writes its cards.
    private func teardownAllGames() {
        for game in games { remove(game) }
    }

    func driveHaptics() {
        haptics.drive(MotorDrive(status: game?.lastPadStatus ?? .idle, allowed: rumbleAllowed))
    }

    /// Re-drives the motors whenever `rumbleAllowed` changes. Observation
    /// reports a change before it lands, so the drive hops to the main queue
    /// and re-arms from there.
    private func observeRumbleGate() {
        withObservationTracking {
            _ = rumbleAllowed
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.driveHaptics()
                    self.observeRumbleGate()
                }
            }
        }
    }

    // MARK: Testing seams
    //
    // Reaching `.playing` for real needs a BIOS folder and a disc image on
    // disk, which the test suite deliberately does not depend on for
    // determinism. These two exist ONLY so a test can drive the eject()
    // reset path without one; production code never calls either.
    //
    // `test.sh` builds `swift test` in the default (debug) configuration and
    // `build.sh` builds `-c release`, so `#if DEBUG` keeps both members out
    // of the shipped binary at zero cost to the suite.

    #if DEBUG
    var hapticsDriveForTesting: MotorDrive { haptics.driveForTesting }
    /// The hosted test app is not the active app, so a test sets it.
    func simulateAppActiveForTesting(_ active: Bool) {
        appActive = active
        game?.updatePlayClock()
    }
    func simulateControllerInputForTesting(_ id: ObjectIdentifier) { haptics.noteInput(from: id) }
    func simulateControllerDisconnectForTesting(_ id: ObjectIdentifier?) { controllerDisconnected(id) }
    func simulateControllerConnectForTesting() { controllerConnected() }

    func simulateOnboardingForTesting() { stage = .onboarding }

    /// A game with no session, in the window the test names.
    func simulatePlayingForTesting(ownWindow: Bool = false) {
        install(OpenGame(app: self, session: nil, hostView: nil, inOwnWindow: ownWindow, fullScreen: false))
    }

    /// A game on `s`, which answers only what the test tells it to, opened
    /// as `load(disc:)` opens one.
    func installSessionForTesting(_ s: any GameSession, resumeKey: String?, ownWindow: Bool = false) {
        let game = OpenGame(app: self, session: s, hostView: nil, inOwnWindow: ownWindow, fullScreen: false)
        game.resumeKey = resumeKey
        install(game)
    }

    func ejectNowForTesting(_ target: OpenGame? = nil) { ejectNow(target ?? game) }
    func ejectAllForTesting() { for game in games { ejectNow(game) } }

    func simulateDiscsForTesting(_ discs: [GameEntry], inserted: Int, bios: BiosImage?) {
        if game == nil { simulatePlayingForTesting() }
        game?.currentDiscs = discs
        game?.currentDiscIndex = inserted
        game?.biosImage = bios
    }

    /// Drives the exact code path `bind(_:)`'s `valueChangedHandler` drives,
    /// without needing a real `GCExtendedGamepad`; see `applyPadInput`.
    func simulatePadInputForTesting(_ snapshot: InputMap) { applyPadInput(snapshot) }
    #endif

    // MARK: Input

    /// Tab: held for fast-forward, the key DuckStation uses. Not in
    /// `KeyBindings`, because it is not a pad button, and reserved there so
    /// no button can take it.
    static let fastForwardKey: UInt16 = 48

    /// The keyboard layout, persisted. The Controls pane rebinds it.
    private(set) var keyBindings = KeyBindings()

    /// The control whose row in the Controls pane is waiting for a key, if
    /// any. The next key-down in the Settings window binds to it; a click
    /// anywhere, Escape, or a ⌘ shortcut cancels.
    private(set) var capturing: PadControl?

    /// Watches for the click that cancels a capture. Installed only while one
    /// is in progress, so it costs nothing the rest of the time.
    private var captureMouseMonitor: Any?

    func beginCapture(_ control: PadControl) {
        capturing = control
        guard captureMouseMonitor == nil else { return }
        captureMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            // The click still goes through: on another row it starts that
            // row's capture, which is what the player meant.
            MainActor.assumeIsolated { [weak self] in self?.cancelCapture() }
            return event
        }
    }

    func cancelCapture() {
        capturing = nil
        if let m = captureMouseMonitor { NSEvent.removeMonitor(m) }
        captureMouseMonitor = nil
    }

    /// A key-down while a row is waiting. Returns true when it was consumed.
    /// ⌘ combinations are shortcuts, not keys, so they cancel and pass on
    /// (⌘W still closes the window); Escape cancels; a reserved key is
    /// refused and the row keeps waiting.
    func captureKey(_ keyCode: UInt16, command: Bool) -> Bool {
        guard let control = capturing else { return false }
        if command {
            cancelCapture()
            return false
        }
        if keyCode == UInt16(kVK_Escape) {
            cancelCapture()
            return true
        }
        if keyBindings.assign(keyCode, to: control) {
            cancelCapture()
            releaseAllKeys()
        }
        return true
    }

    func restoreDefaultKeyBindings() {
        cancelCapture()
        keyBindings.restoreDefaults()
        releaseAllKeys()
    }

    /// A key held across a rebind would be released through its NEW button
    /// and leave the old one stuck down.
    private func releaseAllKeys() {
        game?.releaseAllKeys()
    }

    /// A key-down for the running game; false with none.
    func keyDown(_ keyCode: UInt16, isRepeat: Bool = false) -> Bool {
        game?.keyDown(keyCode, isRepeat: isRepeat) ?? false
    }

    /// The keys a HUD surface answers to: the arrows, Return, keypad Enter
    /// and Space, and Esc to go back.
    static func menuMove(forKey keyCode: UInt16) -> MenuMove? {
        switch Int(keyCode) {
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: .confirm
        case kVK_Escape: .back
        default: nil
        }
    }

    /// A release reaches every open game: a key held as its game went to
    /// the background was let go there already, and releasing twice is
    /// harmless.
    func keyUp(_ keyCode: UInt16) -> Bool {
        games.reduce(false) { $1.keyUp(keyCode) || $0 }
    }

    /// Whether a key-down from this window is the running game's: from its
    /// own window, or, for the game in the library's window, from any window
    /// that is not another game's.
    private func windowHoldsRunningGame(_ windowNumber: Int) -> Bool {
        guard let game else { return false }
        let owner = GameWindow.content(owningWindowNumber: windowNumber)
        return game.inOwnWindow ? owner == .game(game.id) : owner == nil
    }

    /// A connect notification is used only as a TRIGGER to rescan, never as a
    /// carrier: `Notification` and `GCExtendedGamepad` are both non-Sendable,
    /// so pulling the pad out of the notification and handing it to the main
    /// actor is a data race the Swift 6 compiler rejects outright. Rescanning
    /// also collapses the connect path and the launch path into one.
    /// Keyboard comes through an NSEvent monitor rather than SwiftUI's
    /// `onKeyPress`, because that hands back a `KeyEquivalent` (a Character)
    /// and `KeyBindings` is keyed on macOS VIRTUAL KEY CODES,
    /// which are layout-independent, so the D-pad stays on the same physical
    /// keys on an AZERTY or Dvorak layout.
    /// ⌃⌘F, by key code like every other key here, and with no other
    /// modifier: ⌃⌥⌘F is not the shortcut.
    nonisolated static func isFullScreenShortcut(_ keyCode: UInt16,
                                                 _ flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == UInt16(kVK_ANSI_F)
            && flags.intersection([.command, .control, .option, .shift]) == [.command, .control]
    }

    private func observeKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Only the code crosses the boundary; NSEvent is not Sendable.
            let code = event.keyCode
            let isDown = event.type == .keyDown
            let isRepeat = event.type == .keyDown && event.isARepeat
            let windowNumber = event.windowNumber
            let command = event.modifierFlags.contains(.command)
            let fullScreenShortcut = Self.isFullScreenShortcut(code, event.modifierFlags)
            let handled = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self else { return false }
                // The Settings window's keys are its own: arrows and Return
                // there move through its controls, not the pad. A RELEASE is
                // still applied (a button or Tab held while ⌘, opened it
                // would otherwise stay down), but the event is never eaten.
                // The one key-down it takes is the key a Controls row is
                // waiting for.
                if SettingsWindow.owns(windowNumber: windowNumber) {
                    if isDown { return self.captureKey(code, command: command) }
                    _ = self.keyUp(code)
                    return false
                }
                // The About window takes no game input either.
                if AboutWindow.owns(windowNumber: windowNumber) {
                    if !isDown { _ = self.keyUp(code) }
                    return false
                }
                // ⌃⌘F, which every AppKit app answers: the View menu SwiftUI
                // builds binds Enter Full Screen to fn-F alone, and no item
                // matches ⌃⌘F, so it did nothing.
                if isDown && !isRepeat && fullScreenShortcut,
                   let window = [LibraryWindow.current,
                                 GameWindow.content(owningWindowNumber: windowNumber).flatMap(GameWindow.window(for:))]
                       .compactMap({ $0 }).first(where: { $0.windowNumber == windowNumber }) {
                    window.toggleFullScreen(nil)
                    return true
                }
                // A surface on screen takes every key-down, from whichever
                // window: the Save States panel is a popover, a window of
                // its own. A ⌘ shortcut still reaches the menu bar.
                if isDown && !command && self.game?.surfacePausesGame == true {
                    return self.keyDown(code, isRepeat: isRepeat)
                }
                // The same for every window but the running game's: the
                // library's arrows and Return belong to the grid, and another
                // game's window is coming forward to run its own game.
                if !self.windowHoldsRunningGame(windowNumber) {
                    if !isDown { _ = self.keyUp(code) }
                    return false
                }
                // The app is unsandboxed, so this monitor sees events bound
                // for an NSOpenPanel's own sheet too; its sidebar, its text
                // field. Declining to handle anything while one is up lets
                // those events fall through to the panel instead of being
                // eaten as game input (arrows dead in the sidebar, Return not
                // confirming, typed letters silently dropped).
                guard NSApp.modalWindow == nil else { return false }
                // A ⌘ combination is a menu command, never the pad: Q and W
                // are L1 and R1 by default, and eating them made ⌘Q and ⌘W
                // do nothing in a game. A key-up still releases.
                if isDown && command { return false }
                // Return is the pad's Start: while an exit or resume dialog
                // is up, a key-down goes to its buttons instead. Key-ups
                // still reach the pad, so a button held as the dialog opened
                // is released rather than stuck.
                if isDown && self.isDialogShown { return false }
                return isDown ? self.keyDown(code, isRepeat: isRepeat) : self.keyUp(code)
            }
            // Swallowing the event stops the system beep on an unhandled key.
            return handled ? nil : event
        }
    }

    private func observeControllers() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllerConnected() }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            let departed = (note.object as? GCController).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.controllerDisconnected(departed) }
        }
        bindConnectedControllers()
    }

    /// A disconnected pad sends no release, so its last deflection would hold.
    /// The input is the last pad's whole snapshot, so it is centred and
    /// released when the pad that sent it leaves, whether or not another
    /// remains; an idle pad leaving changes nothing.
    private func controllerDisconnected(_ departed: ObjectIdentifier?) {
        if haptics.controllerDisconnected(departed) { releaseAllKeys() }
        game?.showNotice(NoticeIcon.controller, "Controller disconnected")
    }

    private func controllerConnected() {
        bindConnectedControllers()
        game?.showNotice(NoticeIcon.controller, "Controller connected")
    }

    private func bindConnectedControllers() {
        for c in GCController.controllers() {
            if let pad = c.extendedGamepad { bind(pad) }
        }
    }

    private func bind(_ pad: GCExtendedGamepad) {
        pad.valueChangedHandler = { [weak self] pad, _ in
            // Read the pad on the handler's own queue and send only the
            // resulting mask across: InputMap is a UInt16 in a struct, so it
            // crosses freely where the pad itself cannot.
            var m = InputMap()
            if pad.dpad.up.isPressed    { m.press(.up) }
            if pad.dpad.down.isPressed  { m.press(.down) }
            if pad.dpad.left.isPressed  { m.press(.left) }
            if pad.dpad.right.isPressed { m.press(.right) }
            if pad.buttonA.isPressed    { m.press(.cross) }
            if pad.buttonB.isPressed    { m.press(.circle) }
            if pad.buttonX.isPressed    { m.press(.square) }
            if pad.buttonY.isPressed    { m.press(.triangle) }
            if pad.leftShoulder.isPressed  { m.press(.l1) }
            if pad.rightShoulder.isPressed { m.press(.r1) }
            if pad.leftTrigger.isPressed   { m.press(.l2) }
            if pad.rightTrigger.isPressed  { m.press(.r2) }
            if pad.buttonMenu.isPressed    { m.press(.start) }
            if pad.buttonOptions?.isPressed == true { m.press(.select) }
            if pad.leftThumbstickButton?.isPressed == true  { m.press(.l3) }
            if pad.rightThumbstickButton?.isPressed == true { m.press(.r3) }
            m.sticks = Sticks(leftX: pad.leftThumbstick.xAxis.value,
                              leftY: pad.leftThumbstick.yAxis.value,
                              rightX: pad.rightThumbstick.xAxis.value,
                              rightY: pad.rightThumbstick.yAxis.value)

            let snapshot = m
            let source = pad.controller.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                self?.applyPadInput(snapshot)
                if let source { self?.haptics.noteInput(from: source) }
            }
        }
        // Home opens the pause menu, as the PS button opens a console's;
        // Analog is in its Quick Settings. The system takes Home for its own
        // overlay unless told not to.
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.game?.homePressed() }
            }
        }
    }

    /// Shared by the real `GCExtendedGamepad` handler above and, in DEBUG
    /// only, `simulatePadInputForTesting` below: a real gamepad can't be
    /// synthesised in a test, so the seam calls this exact method to keep the
    /// stage gate itself under test.
    ///
    /// The gate mirrors `keyDown`/`keyUp`: without it, a button held on a pad
    /// across an eject survives; `teardownRunningMachine()` resets `input`,
    /// but the handler still fires on every value change, so the next report
    /// of the still-held button overwrites `input` again before the next game
    /// even starts.
    private func applyPadInput(_ snapshot: InputMap) {
        game?.applyPadInput(snapshot)
    }

    // MARK: Helpers

    /// Reads the images a cue references, in cue order, as the single slice the
    /// core takes, plus the cue text that says where they were joined.
    ///
    /// Most rips are one `FILE`, but a per-track rip is not (Tekken 3 has 3,
    /// Castlevania 2, Rayman 51), and `Disc` holds ONE data slice. The images
    /// are therefore concatenated and a `REM FILESIZE <bytes>` line emitted
    /// before each `FILE`: that size is all `initFromCue` has left to recover
    /// the boundary the concatenation erased. Without it every FILE stacks at
    /// the same base LBA, so `ps1_load_disc` refuses the cue outright.
    ///
    /// Sizes come from the bytes actually read rather than from a separate
    /// stat, so the cue cannot describe a layout the slice does not have.
    /// Internal rather than private so the layout is reachable from a test.
    static func discImage(forCue cue: URL) throws -> (bin: Data, cue: Data) {
        let text = try String(contentsOf: cue, encoding: .utf8)
        let directory = cue.deletingLastPathComponent()

        var images: [Data] = []
        var augmented = ""
        for raw in CueSheet.lines(of: text) {
            if let name = CueSheet.imageName(inLine: raw) {
                // Mapped: a per-track rip of a full disc is read in its
                // entirety here, and the copy into `bin` below is the only
                // one that has to be resident.
                let image = try Data(contentsOf: directory.appendingPathComponent(name),
                                     options: .mappedIfSafe)
                images.append(image)
                augmented += "REM FILESIZE \(image.count)\n"
            }
            augmented += raw
            augmented += "\n"
        }
        guard !images.isEmpty else { throw Ps1Error.badCue }

        var bin = Data(capacity: images.reduce(0) { $0 + $1.count })
        for image in images { bin.append(image) }
        return (bin, Data(augmented.utf8))
    }

    /// The LibCrypt sidecar sitting beside `disc` under the same stem, or nil
    /// when the disc has none.
    ///
    /// Much of Sony Europe's own PAL catalogue (Final Fantasy IX among it)
    /// hides a key in the subchannel Q of a few dozen sectors. No .bin or .cue
    /// can carry it, so without the sidecar the protection check never passes
    /// and the game sits behind a black screen sweeping those sectors forever.
    ///
    /// Matched on the stem alone, never on "the only .sbi in the directory":
    /// FF9's four discs share a folder and each sidecar names sectors of its
    /// own image, so the wrong one is worth exactly as much as no sidecar.
    /// A missing one is the ordinary case and is not an error: the sidecar is
    /// only checked once the core has it, where a corrupt file is refused.
    /// Internal rather than private so the rule is reachable from a test.
    static func sidecar(forDisc disc: URL) -> Data? {
        beside(disc, ext: "sbi")
    }

    /// The PPF patch sitting beside `disc` under the same stem, or nil when
    /// the disc has none: a fan translation or fix kept next to an untouched
    /// rip. Matched on the stem for the sidecar's reason, since a patch names
    /// byte offsets of one image. The core validates it on load.
    static func patch(forDisc disc: URL) -> Data? {
        beside(disc, ext: "ppf")
    }

    /// The `libps.exe` in an executable's folder, or nil: the library some
    /// PS-X EXE programs expect in RAM before they start. Not the
    /// program's own file, should it be named that.
    static func libps(forExe exe: URL) -> Data? {
        let lib = exe.deletingLastPathComponent().appendingPathComponent(GameScanner.libpsName)
        guard exe.lastPathComponent.lowercased() != GameScanner.libpsName else { return nil }
        return try? Data(contentsOf: lib)
    }

    private static func beside(_ disc: URL, ext: String) -> Data? {
        try? Data(contentsOf: disc.deletingPathExtension().appendingPathExtension(ext))
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case Ps1Error.badBIOSSize:    return "That BIOS file is not 512 KB. PlayStation BIOS images are exactly 524,288 bytes."
        case Ps1Error.multiFileCue:   return "This cue sheet splits its tracks across several files, and the sizes needed to lay them out are missing. The rip may be incomplete."
        case Ps1Error.badCue:         return "That cue sheet could not be parsed."
        case Ps1Error.badCHD:         return "This CHD was made by an old chdman or depends on a parent image. Re-create it with chdman createcd."
        case Ps1Error.badSBI:         return "The .sbi file beside this disc is not a LibCrypt sidecar. Remove it, or replace it with the one that shipped with this rip. The game will not get past its copy protection without a valid one."
        case Ps1Error.badPPF:         return "The .ppf file beside this disc is not a PPF patch Substation can read. Remove it to play the game unpatched."
        case Ps1Error.ppfMismatch:    return "The .ppf patch beside this disc was made for a different version of the game. Find the patch for this rip, or remove it to play unpatched."
        case Ps1Error.outOfMemory:    return "Out of memory."
        case Ps1Error.createFailed:   return "Could not start the emulator core."
        case Ps1Error.noMetal:        return "This Mac has no Metal GPU to draw the game with."
        case Ps1Error.audio:          return "The sound output could not start."
        case Ps1Error.badExe:         return "This file is not a PlayStation executable Substation can run. It must be a PS-X EXE, a CPE or a MIPS ELF that fits in the console's memory."
        case Ps1Error.settingsSize:   return "This copy of Substation and its emulator engine do not match. Reinstall the app."
        case BiosError.noFolderSelected: return "Choose a BIOS folder first."
        case BiosError.noMatchingBIOS(let r): return "No \(r.rawValue) BIOS found in your BIOS folder. This disc needs it."
        case BiosError.wrongSize(let n):  return "That BIOS file is \(n) bytes; it must be exactly 524,288."
        case BiosError.unreadable:    return "That BIOS file could not be read."
        default: return String(describing: error)
        }
    }
}

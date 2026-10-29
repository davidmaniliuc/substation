import AppKit
import Carbon.HIToolbox
import SwiftUI
import GameController
import UniformTypeIdentifiers

@MainActor
@Observable
public final class EmulatorViewModel {
    enum Stage { case onboarding, library, playing }

    private(set) var stage: Stage = .onboarding
    /// The running game is in a window of its own, with the library left
    /// open in the main one. Taken from `gameWindowMode` as each game loads,
    /// so changing the setting mid-game moves nothing.
    private(set) var gameInOwnWindow = false
    /// The main window shows the library: always outside a game, and during
    /// one that has its own window.
    var libraryVisible: Bool { stage == .library || (stage == .playing && gameInOwnWindow) }
    /// The game's own window should be open: for its game, or for the
    /// alerts of a launch that belongs there. Not for its resume sheet,
    /// which floats on its own (`resumeInPanel`).
    var gameWindowShown: Bool {
        (stage == .playing && gameInOwnWindow) || (launchInGameWindow && launchAlertShown)
    }
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
        !launchInGameWindow && (stage == .playing || launchAlertShown)
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
    /// The game window should go into full screen as it next shows its game.
    /// Snapshotted per load with `gameInOwnWindow`, and taken by the window.
    private(set) var gameWindowFullScreenPending = false

    /// What the game window holds. A change brings it forward, from
    /// whichever window sees it (`GameWindowOpener`).
    enum GameWindowContent: Hashable {
        case launch
        case game(ObjectIdentifier)
    }

    var gameWindowContent: GameWindowContent? {
        guard gameWindowShown else { return nil }
        if stage == .playing && gameInOwnWindow, let session { return .game(ObjectIdentifier(session)) }
        return .launch
    }

    /// One of a launch's alerts is up (the ones `LaunchDialogs` presents).
    var launchAlertShown: Bool { resumeFailure != nil || errorMessage != nil || showRawBinWarning }
    private(set) var discTitle: String = ""
    /// The discs of the game that is running, and which one is in the drive.
    /// Derived from the launched disc's own DIRECTORY rather than from the
    /// tile that was clicked, so Change Disc also works for a game opened
    /// through File ▸ Open Disc… that was never in the library folder.
    ///
    /// Deliberately independent of `mergeMultiDisc`: that setting decides how
    /// the grid looks, and a player who prefers separate tiles has not asked
    /// to lose disc swapping. DuckStation's Change Disc is independent of its
    /// game-list setting for the same reason.
    private(set) var currentDiscs: [GameEntry] = []
    private(set) var currentDiscIndex: Int?
    /// The BIOS the running game booted, for About This Game; nil for an
    /// image the table does not know.
    private(set) var biosImage: BiosImage?
    var errorMessage: String?
    var showRawBinWarning = false

    /// HUD auto-hide lives here rather than in a `@State` on the view. `@State`
    /// compiles fine (Xcode 26.6 has been installed since 2026-08-22, and
    /// `libSwiftUIMacros.dylib` ships in its `MacOSX.platform`); living on the
    /// `@Observable` model is now a design choice, not a constraint: this is
    /// where the behaviour belongs regardless of which mechanism holds it.
    private(set) var hudVisible = true
    private var hideTask: Task<Void, Never>?

    /// The speed tab, the Save States panel and the pause menu: which are
    /// open, and the pause the last two own while they are.
    private var surfaces = HudSurfaces()
    private(set) var saveStatesOrigin: SaveStatesOrigin = .bar
    /// The open speed tab's frame in `GameScreen.space`, reported by the
    /// button. Not observed: it is only read against the next hover.
    @ObservationIgnored var speedTabFrame: CGRect?
    /// The pause menu's highlight; reset each time it opens.
    private(set) var menu = PauseMenuNavigation()
    /// The Save States panel's highlight and sheet, while it is open.
    private(set) var saveStatesNav: SaveStatesNavigation?
    /// Fed every controller report, so a button held as a surface opens does
    /// not fire on the surface's first report.
    private var padEdges = PadEdges()
    /// The Analog mode Quick Settings asked for, pressed when the menu
    /// closes: the pad acts on its Analog button only while the game runs,
    /// and two presses queued while paused would read as one.
    private var pendingAnalog: Bool?

    /// The last pointer position the view reported. `nil` until the mouse has
    /// been over the window at all, so the very first hover counts as a move.
    private var lastHoverPoint: CGPoint?

    /// Emulated frames per second, or `nil` before the session's first
    /// frame-rate event and whenever no game is loaded. The HUD reads it;
    /// nothing else does.
    private(set) var fps: Double?
    /// How long a reading stands with no newer one. The session sends one
    /// twice a second whenever it is not paused, so silence past this means
    /// its thread is blocked: a frozen "60 FPS" would hide the stall.
    static let fpsStaleAfter = 1.0
    private var fpsStaleTask: Task<Void, Never>?

    /// A status shown for a moment in the badge stack: the Analog notice
    /// when the pad's mode changes, the save-state notices (saved, loaded,
    /// undone, auto-saved, or why a load was refused) and a disc swap.
    private(set) var notice: Notice?
    private var noticeTask: Task<Void, Never>?
    /// The mode last seen, so only a CHANGE shows the notice. Each new
    /// session starts from a digital pad.
    private var lastPadAnalog = false

    /// True while the game is writing to a memory card, and for a moment
    /// after its last block: long enough to outlast the session's one-second
    /// debounce, so the pill goes down after the save has reached disk.
    private(set) var savingToMemoryCard = false
    private var cardSavingTask: Task<Void, Never>?
    /// The session's write count last sent. Each new session restarts at zero.
    private var lastCardWrites: UInt64 = 0
    /// The debounce `ps1-session/src/cards.zig`'s `FlushPolicy` waits out
    /// before it writes a card, which is the policy that writes: this copy
    /// only times the pill.
    private static let cardSettleDelay = 1.0

    /// The running game, below the user interface. Every action on it is a
    /// setter or a request; nothing here touches its machine.
    private(set) var session: (any GameSession)?
    /// The view the session draws into, one per session.
    private(set) var hostView: SessionHostView?
    /// Builds every session `load(disc:)` starts. A test replaces it.
    @ObservationIgnored var makeSession: @MainActor (SessionConfig) throws(Ps1Error) -> any GameSession = {
        config throws(Ps1Error) in try Session(config)
    }
    private let bios: BiosLibrary

    let library = GameLibrary()
    let covers = CoverStore()
    /// Last played and active play time per game. Outlives every disc, like
    /// `covers`.
    let playStats = PlayStatsStore()
    private var playClock = PlayClock()
    /// Active play banked since the running game loaded; the title strip's
    /// "Playing for". A disc swap keeps it: it is still the same sitting.
    private var sessionBanked: TimeInterval = 0
    private var autoSaveClock = AutoSaveClock()
    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveInFlight = false
    /// The machine as it was before the last in-game load, one deep. Undo
    /// loads it, which keeps the machine IT replaced, so a second Undo
    /// returns to the loaded state. Cleared with the game and on a disc swap.
    private(set) var undoState: Data?
    /// Bumped by every disc swap. A load captures it when queued: a swap
    /// requested after it (possible while paused) leaves the load's answer
    /// with the other disc in its tray, so it is no undo.
    private var discSwapGeneration = 0
    /// Bumped after every state write so the menus re-read their timestamps.
    private(set) var stateRevision = 0
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
    private var pausedBeforePrompt = false
    /// True from Yes until the exit actually finishes: up to the 3 s save
    /// fallback. The gate has already handed its intent back by then, so this
    /// is what keeps a second leave-request (and a second exit save) out of
    /// that window.
    private var finishingExit = false
    /// The key the running game saves under: its first disc's.
    private var resumeKey: String?

    private(set) var exitPrompt: ExitIntent?
    var resumeOffer: ResumeOffer?
    var resumeFailure: ResumeFailure?
    /// Set by the app delegate while ⌘Q waits on the sheet.
    var terminateReply: ((Bool) -> Void)?

    /// Set once an exit has been confirmed, so the `terminate` that follows
    /// is not asked again.
    private(set) var exitConfirmed = false

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
    /// The pad's status as last sent, which the rumble gate re-drives on its
    /// own: once frames stop the pad sends nothing, and a pause must still
    /// still the motors.
    private var lastPadStatus = PadStatus.idle

    /// Kept by the resign/become-active observers in `init`, so the rumble
    /// gate and the play clock read one value.
    private var appActive = NSApp?.isActive ?? true

    private var rumbleAllowed: Bool {
        vibration && stage == .playing && !isPaused && !isDialogShown && appActive
    }

    struct ResumeFailure: Identifiable {
        let id = UUID()
        let message: String
        let freshBoot: URL
    }

    /// Bumped whenever a cover is added or removed. The grid keys off it: the
    /// covers live on disk rather than in observable state, so nothing else
    /// would tell SwiftUI that a tile's picture changed.
    private(set) var coverRevision = 0

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
         vramReadbacks: VramReadbacksSetting = VramReadbacksSetting()) {
        self.saveStates = saveStates
        self.autoSave = autoSave
        self.rewindSetting = rewind
        self.vramReadbacksSetting = vramReadbacks
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
        library.didFinishScan = { [weak self] in self?.autoDownloadCoversIfEnabled() }

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
            MainActor.assumeIsolated { self?.teardownRunningMachine() }
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
                self?.releaseRewind()
                self?.haptics.stop()
                self?.updatePlayClock()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appActive = true
                self?.updatePlayClock()
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


    /// The pause as last handed to the session, which every new session
    /// starts without.
    private var paused = false

    /// False with no game running, whatever was last set.
    public var isPaused: Bool {
        get { session != nil && paused }
        set {
            paused = newValue
            session?.setPaused(newValue)
            updatePlayClock()
        }
    }

    /// The single place the play clock learns anything: every change to
    /// running, paused or app-active calls this, and whatever stretch it ends
    /// is banked under the running game's key. Called BEFORE `resumeKey` is
    /// cleared on teardown, so the last stretch lands on the game it belongs to.
    private func updatePlayClock() {
        let now = ProcessInfo.processInfo.systemUptime
        let banked = playClock.update(running: session != nil, paused: isPaused,
                                      active: appActive, at: now)
        if let key = resumeKey { playStats.add(banked, to: key) }
        sessionBanked += banked
        autoSaveClock.update(counting: session != nil && !isPaused && appActive, at: now)
    }

    /// Active play since this game loaded, as of `now` (a `systemUptime`).
    func sessionPlayed(at now: TimeInterval) -> TimeInterval {
        sessionBanked + playClock.elapsed(at: now)
    }

    /// The disc in the drive.
    var currentDisc: GameEntry? {
        guard let index = currentDiscIndex, currentDiscs.indices.contains(index) else { return nil }
        return currentDiscs[index]
    }

    /// The pause menu's About This Game, for the disc in the drive.
    /// `identityInHeader` is whether the menu's header shows the serial.
    func gameInfo(identityInHeader: Bool) -> [GameInfoRow] {
        guard let index = currentDiscIndex, let disc = currentDisc else { return [] }
        let stats = resumeKey.flatMap { playStats.stats(for: $0) }
        let played = (stats?.seconds ?? 0) + playClock.elapsed(at: ProcessInfo.processInfo.systemUptime)
        return GameInfo.rows(disc: disc, index: index, count: currentDiscs.count,
                             bios: biosImage, played: played, identityInHeader: identityInHeader)
    }

    /// The pause menu's cover: the game's, which is its first disc's.
    var currentCoverURL: URL? { currentDiscs.first.flatMap(covers.coverURL(for:)) }

    /// The Save States row's subtitle: how many states the panel holds and
    /// when the newest was written.
    var saveStatesSummary: String {
        let dates = ([StateSource.resume] + StateSource.slots.map { StateSource.slot($0) })
            .compactMap { stateInfo($0)?.savedAt }
        return SaveStatesSummary.text(count: dates.count, newest: dates.max())
    }

    /// Resolution's subtitle: the picture's size at the internal scale, as a
    /// screenshot takes it, from the game's own display mode. Nil while the
    /// display is off.
    var outputSize: Screenshot.Size? {
        guard let display = session?.newestDisplay, display.enabled != 0, display.height > 0 else {
            return nil
        }
        return Screenshot.size(displayHeight: Int(display.height), scale: internalScale, enabled: true)
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
            resolution.set(newValue)
            pushSettings()
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

    private var gameWindowSetting = GameWindowSetting()

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
            pgxpSetting.set(newValue)
            pushSettings()
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
    private(set) var discPgxpPreset: PgxpPreset?

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
    private(set) var discSerial: String?

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
    var vramReadbacksAvailable: Bool { session != nil && discSerial != nil }

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
    private func pushSettings() {
        session?.setSettings(sessionSettings)
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
            if !newValue { releaseRewind() }
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
            rewindHeldByPad = false
            updateRewinding()
        }
    }

    /// Held from the keyboard and from a controller separately, so letting
    /// go of one while the other still holds keeps rewinding.
    private var rewindHeldByKey = false
    private var rewindHeldByPad = false
    /// Whether the game is rewinding right now, for the HUD.
    private(set) var isRewinding = false
    /// Seconds of history left, shown while rewinding.
    private(set) var rewindSecondsLeft: Double = 0
    /// The session's last rewind event, kept while not rewinding: it sends a
    /// value only when it changes, so a new hold over the same history gets
    /// no repeat and starts from this.
    private var lastRewindSeconds: Double = 0

    private func updateRewinding() {
        let held = rewindSetting.enabled && stage == .playing && (rewindHeldByKey || rewindHeldByPad)
        guard held != isRewinding else { return }
        isRewinding = held
        session?.setRewinding(held)
        rewindSecondsLeft = held ? lastRewindSeconds : 0
    }

    private func releaseRewind() {
        rewindHeldByKey = false
        rewindHeldByPad = false
        updateRewinding()
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

    private func setFastForwarding(_ held: Bool) {
        guard held != speedSetting.isFastForwarding else { return }
        speedSetting.isFastForwarding = held
        applySpeed()
    }

    private func applySpeed() {
        session?.setSpeed(speedSetting.effective)
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
        let entry = group.first
        let siblings = Self.siblingDiscs(of: entry.url, entries: library.entries)
        guard let offer = ResumeOffer.make(launching: entry, siblings: siblings, store: saveStates),
              offer.info != nil, offer.resumeDisc != nil
        else { return launch(entry.url) }
        resume(from: .resume, offer: offer)
    }

    /// Opens a game, offering its resume state first when it has one.
    func launch(_ url: URL) {
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
        if session != nil { ejectNow() }
    }

    /// A refusal of the resume state itself, as opposed to the disc or the
    /// BIOS it was loaded beside.
    private static func refusesState(_ error: Ps1Error) -> Bool {
        switch error {
        case .stateBadMagic, .stateVersion, .stateBIOS, .stateDisc, .stateCorrupt, .statePatch: true
        default: false
        }
    }

    private static func resumeMessage(_ error: Error) -> String {
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
        panel.message = "Open a .cue (preferred), a .chd, or a raw .bin"
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
        GameEntry(url: url, identity: DiscIdentity.identify(disc: url) ?? .unknown)
    }

    /// Puts a different disc of the running game in the drive.
    ///
    /// Everything that can fail is done BEFORE the request is queued, so a
    /// bad rip leaves the running game alone rather than opening the tray on
    /// a machine that has nothing to close it on.
    func changeDisc(to entry: GameEntry) {
        guard let session else { return }
        do {
            let kind = DiscKind(entry.url)
            let binData: Data
            let cueData: Data?
            if kind == .cue {
                let image = try Self.discImage(forCue: entry.url)
                binData = image.bin
                cueData = image.cue
            } else {
                binData = try Data(contentsOf: entry.url)
                cueData = nil
            }
            let disc = DiscBytes(bin: binData, cue: cueData, sbi: Self.sidecar(forDisc: entry.url),
                                 ppf: Self.patch(forDisc: entry.url))
            let serial = entry.identity.serial
            session.requestSwap(disc, readbacks: vramReadbacksSetting.choice(serial: serial)) {
                [weak self] error in
                // An answer after an eject or another game is not this game's.
                guard let self, self.session === session else { return }
                guard let error else {
                    // The disc is in: its serial and preset are the running
                    // ones now. The session already holds this choice, so
                    // the push changes nothing there.
                    self.discPgxpPreset = PgxpPreset.lookup(serial: serial)
                    self.discSerial = serial
                    self.pushSettings()
                    return
                }
                // A newer swap replaced this one, which is no failure.
                guard error != .superseded else { return }
                self.errorMessage = Self.describe(error)
            }
            closeAllSurfaces()
            // The undo machine had the other disc in its tray.
            undoState = nil
            discSwapGeneration += 1
            currentDiscIndex = currentDiscs.firstIndex { $0.id == entry.id }
            discTitle = entry.title
            if let index = currentDiscIndex { showNotice(NoticeIcon.disc, "Disc \(index + 1) inserted") }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func load(disc url: URL, resume: Data? = nil, freshBoot: URL? = nil,
              resumeRefused: ((Error) -> Void)? = nil) {
        // Set the instant the outgoing machine is torn down and the new one
        // is installed: the point past which a failure can no longer leave
        // the OLD game untouched, only the new one half-built. See the catch
        // block below.
        var installedReplacement = false
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
            let identity = DiscIdentity.identify(image: binData)
            let biosData = try bios.biosData(forDisc: url.lastPathComponent,
                                             identity: identity)

            let bootedBios = BiosIdentity.identify(biosData)
            let host = SessionHostView()
            // The running disc's serial is still the outgoing game's here.
            var settings = sessionSettings
            settings.vramReadbacks = vramReadbacksSetting.choice(serial: identity.serial)
            let config = SessionConfig(
                bios: biosData,
                disc: DiscBytes(bin: binData, cue: cueData, sbi: Self.sidecar(forDisc: url),
                                ppf: Self.patch(forDisc: url)),
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
            // is it safe to tear down whatever was already running: opening
            // a disc that fails to load (bad cue, missing BIOS, unreadable
            // bin) must leave the current game untouched, not kill it out
            // from under the player and then show an error on top.
            //
            // And BEFORE `start()`, never after: freeing the outgoing session
            // is what writes its cards, and `start()` is what reads them, so
            // the other order would load stale bytes and then write them back
            // over the save it was about to make.
            teardownRunningMachine()

            self.session = session
            bindEvents(session)
            hostView = host
            paused = false
            biosImage = bootedBios
            installedReplacement = true
            host.onGeometry = { [weak session] points, backingScale in
                session?.setSize(points: points, backingScale: backingScale)
            }

            // The config carried every setting. The preset is set only now,
            // past the teardown, so a disc that fails to load leaves the
            // running game's preset alone.
            discPgxpPreset = PgxpPreset.lookup(serial: identity.serial)
            discSerial = identity.serial
            applySpeed()
            session.setBandShown(hudVisible && !isOpen(.pauseMenu))
            try session.start()
            startAutoSave()

            discTitle = identity.title ?? url.deletingPathExtension().lastPathComponent
            currentDiscs = Self.siblingDiscs(of: url, entries: library.entries)
            currentDiscIndex = currentDiscs.firstIndex {
                Self.canonicalPath($0.url) == Self.canonicalPath(url)
            }
            resumeKey = SaveStateStore.key(for: currentDiscs.first ?? Self.discEntry(for: url))
            gameInOwnWindow = gameWindowMode == .newWindow
            gameWindowFullScreenPending = gameInOwnWindow && gameWindowFullScreen
            stage = .playing
            if let resumeKey { playStats.markPlayed(resumeKey, at: Date()) }
            updatePlayClock()
            // A raw .bin cannot represent audio tracks, so a CD-DA title opened
            // this way is silent, which looks like a bug unless we say so.
            showRawBinWarning = kind == .bin
        } catch {
            if installedReplacement {
                // `start()` refused (no audio output) with the new session
                // already installed: tear it down so the failure lands on a
                // coherent, idle stage rather than a game that never runs
                // under a plain error alert.
                teardownRunningMachine()
                stage = .library
            }
            errorMessage = Self.describe(error)
        }
    }

    /// Through the session, never the machine: the emulator thread may be
    /// mid-frame, and under the recompiler the reset frees the code it is
    /// executing. The session resets between frames.
    public func reset() {
        isPaused = false
        session?.requestReset { _ in }
    }

    public func eject() {
        if requestExit(.eject) == .proceed { ejectNow() }
    }

    /// The game window's close button and ⌘W: Eject, sheet and all. The
    /// window closes now only when nothing was asked; otherwise it closes
    /// itself once the game has ended.
    func closeGameWindow() -> Bool {
        guard stage == .playing else {
            dismissLaunchDialogs()
            return true
        }
        eject()
        return stage != .playing
    }

    /// The library window's close button and ⌘W. With the game in a window
    /// of its own the two are independent: the library closes and the game
    /// plays on. Otherwise closing it quits, through the exit sheet.
    func closeLibraryWindow() -> Bool {
        if gameWindowShown { return true }
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

    /// The game window took its full screen (or found it already taken).
    func gameWindowEnteredFullScreen() {
        gameWindowFullScreenPending = false
    }

    private func ejectNow() {
        teardownRunningMachine()
        currentDiscs = []
        currentDiscIndex = nil
        stage = .library
    }

    /// The exit or resume dialog is on screen (see `ModalDialog`).
    var isDialogShown: Bool { exitPrompt != nil || resumeOffer != nil }

    /// A game is running and nothing is in the way of a save or a load.
    var canUseStates: Bool {
        stage == .playing && session != nil && !isDialogShown && !finishingExit && resumeFailure == nil
    }

    /// Saves the picture on screen to `~/Pictures/Substation/`, and says
    /// where with a notice that reveals the file.
    func takeScreenshot() {
        guard stage == .playing, let session else { return }
        let title = discTitle
        session.requestScreenshot { [weak self] png in
            // Answered after an eject or another game: not this game's.
            guard let self, self.session === session else { return }
            Task.detached { [weak self] in
                var saved: URL?
                if let png {
                    do { saved = try Screenshot.write(png, title: title, at: .now) }
                    catch { NSLog("Substation: screenshot failed to write: \(error)") }
                }
                await MainActor.run {
                    guard let self else { return }
                    if let saved {
                        self.showNotice(NoticeIcon.screenshot, "Screenshot saved", reveal: saved)
                    } else {
                        self.showFailure("Could not save the screenshot")
                    }
                }
            }
        }
    }

    func stateInfo(_ source: StateSource) -> SaveStateStore.Info? {
        _ = stateRevision      // read it so SwiftUI re-runs this on a change
        guard let resumeKey else { return nil }
        return saveStates.info(source, key: resumeKey)
    }

    func saveState(toSlot n: Int) {
        guard canUseStates, let session, let key = resumeKey else { return }
        let store = saveStates
        session.requestSave { [weak self] result in
            // Answered after an eject or another game: not this game's.
            guard let self, self.session === session else { return }
            // Off the main actor: compression of a multi-megabyte state would
            // otherwise stall the UI for the length of it.
            Task.detached { [weak self] in
                var notice = Notice(icon: NoticeIcon.failure, text: "Could not save to Slot \(n)")
                var written = false
                if case .success(let snap) = result {
                    do {
                        try store.saveSlot(n, state: snap.state, thumbnail: snap.thumbnail, key: key)
                        notice = Notice(icon: NoticeIcon.saved, text: "Saved to Slot \(n)")
                        written = true
                    } catch {
                        NSLog("Substation: slot \(n) failed to write: \(error)")
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.stateRevision += 1
                    // Ejected while the slot was being written.
                    guard self.session === session else { return }
                    self.showNotice(notice)
                    // The panel may still be up, showing the slot it saved to.
                    if written { self.saveStatesNav?.saved(n) }
                }
            }
        }
    }

    /// The 1 s tick's body. A write says so in the badge stack, so a player
    /// can tell their resume has moved on; a failure is only logged.
    func autoSaveIfDue(at now: TimeInterval) {
        guard let interval = autoSave.interval,
              autoSaveClock.elapsed(at: now) >= interval,
              canUseStates, !autoSaveInFlight,
              let session, let key = resumeKey else { return }
        autoSaveInFlight = true
        autoSaveClock.restart(at: now)
        let store = saveStates
        session.requestSave { [weak self] result in
            // Answered after an eject: the next game's save may be in flight,
            // and this one's resume is the exit's to write.
            guard let self, self.session === session else { return }
            Task.detached { [weak self] in
                var wrote = false
                switch result {
                case .success(let snap):
                    do {
                        try store.saveResume(state: snap.state, thumbnail: snap.thumbnail, key: key)
                        wrote = true
                    } catch { NSLog("Substation: auto-save failed to write: \(error)") }
                case .failure(let error):
                    NSLog("Substation: auto-save failed: \(error)")
                }
                await MainActor.run {
                    guard let self else { return }
                    // Ejected while the resume was being written.
                    if self.session === session {
                        self.autoSaveInFlight = false
                        if wrote { self.showNotice(NoticeIcon.autoSaved, "Auto-saved") }
                    }
                    self.stateRevision += 1
                }
            }
        }
    }

    private func startAutoSave() {
        autoSaveTask?.cancel()
        autoSaveClock = AutoSaveClock()
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.autoSaveIfDue(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    func loadState(_ source: StateSource) {
        guard canUseStates, let key = resumeKey else { return }
        let damaged = Self.resumeMessage(Ps1Error.stateCorrupt)
        guard let data = saveStates.load(source, key: key) else { return showFailure(damaged) }
        let serial: String?
        do { serial = try Ps1Core.peekStateSerial(data) } catch { return showFailure(Self.resumeMessage(error)) }

        // Saved on another disc of this game: rebuild on that disc, as a
        // launch-time resume does. No undo across that rebuild.
        let inTray = currentDiscIndex.map { currentDiscs[$0] }
        if let serial, serial != inTray?.serial {
            guard let disc = ResumeOffer.disc(forSerial: serial, in: currentDiscs) else {
                return showFailure(Self.resumeMessage(Ps1Error.stateDisc))
            }
            load(disc: disc.url, resume: data, freshBoot: nil) { [weak self] error in
                self?.showFailure(Self.resumeMessage(error))
            }
            return
        }
        request(load: data, done: Notice(icon: NoticeIcon.loaded, text: "Loaded \(source.title)"))
    }

    func undoLoadState() {
        guard canUseStates, let undoState else { return }
        request(load: undoState, done: Notice(icon: NoticeIcon.undone, text: "Load undone"))
    }

    private func request(load data: Data, done: Notice) {
        guard let session else { return }
        let generation = discSwapGeneration
        session.requestLoad(data) { [weak self] result in
            // Answered after an eject or another game: not this game's.
            guard let self, self.session === session else { return }
            switch result {
            case .success(let replaced):
                if self.discSwapGeneration == generation { self.undoState = replaced }
                self.autoSaveClock.restart(at: ProcessInfo.processInfo.systemUptime)
                self.showNotice(done)
            case .failure(let error):
                self.showFailure(Self.resumeMessage(error))
            }
        }
    }

    /// Every way of leaving a running game comes through here. `.prompted`
    /// pauses the game and raises the sheet; the caller then waits.
    func requestExit(_ intent: ExitIntent) -> ExitDecision {
        // Another sheet or alert is up, or an exit is already finishing: a
        // second prompt on top of it could be dropped, leaving ⌘Q unanswered.
        if finishingExit || resumeOffer != nil || resumeFailure != nil { return .busy }
        let decision = exitGate.request(intent, playing: stage == .playing && session != nil)
        if decision == .prompted {
            // Before the pause is read: the sheet restores the game's own,
            // not the one the menu was holding.
            closeAllSurfaces()
            pausedBeforePrompt = isPaused
            isPaused = true
            exitPrompt = intent
        }
        return decision
    }

    func cancelExit() {
        let intent = exitGate.cancel()
        exitPrompt = nil
        isPaused = pausedBeforePrompt
        if intent == .quit { replyToTerminate(false) }
    }

    func confirmExit() {
        guard let intent = exitGate.take() else { return }
        exitPrompt = nil
        finishingExit = true
        let finish = ExitCompletion { [weak self] in self?.finishExit(intent) }
        guard saveStateOnExit, let session, let key = resumeKey else { return finish.fire() }

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

    private func finishExit(_ intent: ExitIntent) {
        finishingExit = false
        switch intent {
        case .quit:
            replyToTerminate(true)
        case .closeWindow:
            exitConfirmed = true
            NSApp.terminate(nil)
        case .eject:
            ejectNow()
        case .open(let url):
            launchOpened(url)
        }
    }

    private func replyToTerminate(_ yes: Bool) {
        if yes { exitConfirmed = true }
        terminateReply?(yes)
        terminateReply = nil
    }

    /// Stops whatever session is currently installed and releases it, but
    /// does not touch `stage`: `eject()` sets it to `.library` afterwards, and
    /// `load(disc:)` sets it to `.playing` once the replacement is installed,
    /// so this is shared by both without either one fighting the other's
    /// stage transition.
    ///
    /// `free()` is called explicitly, never left to `deinit`: a completion
    /// still waiting holds the session, so dropping the last reference here
    /// would not stop it. The session is uninstalled FIRST, so an answer
    /// `free()` delivers (`.sessionStopped`) meets the identity guards as an
    /// answer from a game that has gone.
    private func teardownRunningMachine() {
        // Its pause is the outgoing game's, and goes with it.
        _ = surfaces.closeAll()
        saveStatesNav = nil
        pendingAnalog = nil
        // Banks the session under the outgoing game before anything below
        // clears the session and the key it is filed under.
        isPaused = true
        fpsStaleTask?.cancel()
        fpsStaleTask = nil
        fps = nil
        lastPadAnalog = false
        lastPadStatus = .idle
        lastCardWrites = 0
        lastRewindSeconds = 0
        autoSaveTask?.cancel()
        autoSaveTask = nil
        autoSaveInFlight = false
        undoState = nil
        haptics.release()
        noticeTask?.cancel()
        notice = nil
        cardSavingTask?.cancel()
        savingToMemoryCard = false
        let outgoing = session
        session = nil
        hostView = nil
        outgoing?.free()
        resumeKey = nil
        biosImage = nil
        // After the pause above banked the last stretch into it.
        sessionBanked = 0
        discTitle = ""
        discPgxpPreset = nil
        discSerial = nil
        // A key held across the transition would otherwise survive it: the
        // stage gate on keyUp (below) stops a release from reaching a game
        // that no longer exists, so without this the bit it set stays
        // latched into the NEXT game's first setButtons call.
        input.reset()
        // The same trap for the fast-forward key: its release would never
        // arrive, and the next game would start fast-forwarding.
        speedSetting.isFastForwarding = false
        rewindHeldByKey = false
        rewindHeldByPad = false
        isRewinding = false
    }

    /// Every event of `session`, while it is the running one: an outgoing
    /// session's event already on its way to the main actor is dropped.
    private func bindEvents(_ session: any GameSession) {
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.session === session else { return }
            self.sessionEvent(event)
        }
    }

    private func sessionEvent(_ event: SessionEvent) {
        switch event {
        case .pad(let s): padStatusChanged(s)
        case .cardWrites(let n): memoryCardWritesChanged(n)
        case .rewindSeconds(let seconds):
            lastRewindSeconds = seconds
            if isRewinding { rewindSecondsLeft = seconds }
        case .frameRate(let rate): frameRateArrived(rate)
        }
    }

    private func frameRateArrived(_ rate: Double) {
        fps = rate
        fpsStaleTask?.cancel()
        fpsStaleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fpsStaleAfter))
            guard !Task.isCancelled else { return }
            self?.fps = nil
        }
    }

    private func padStatusChanged(_ s: PadStatus) {
        if s.analog != lastPadAnalog {
            lastPadAnalog = s.analog
            showNotice(NoticeIcon.analog, s.analog ? "Analog on" : "Analog off")
        }
        lastPadStatus = s
        driveHaptics()
    }

    private func driveHaptics() {
        haptics.drive(MotorDrive(status: lastPadStatus, allowed: rumbleAllowed))
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

    private func memoryCardWritesChanged(_ writes: UInt64) {
        guard writes != lastCardWrites else { return }
        lastCardWrites = writes
        savingToMemoryCard = true
        cardSavingTask?.cancel()
        cardSavingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.cardSettleDelay + 0.5))
            guard !Task.isCancelled else { return }
            self?.savingToMemoryCard = false
        }
    }

    private func showNotice(_ icon: String, _ text: String, reveal: URL? = nil) {
        showNotice(Notice(icon: icon, text: text, reveal: reveal))
    }

    private func showFailure(_ text: String) { showNotice(NoticeIcon.failure, text) }

    private func showNotice(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func isOpen(_ surface: HudSurface) -> Bool { surfaces.open.contains(surface) }

    /// Opens or closes a HUD surface. One that pauses releases every held
    /// key, button and rewind first, so nothing stays down through the menu.
    func setSurface(_ surface: HudSurface, open: Bool) {
        guard isOpen(surface) != open else { return }
        if surface == .pauseMenu && open {
            menu.open(discCount: currentDiscs.count, insertedDisc: currentDiscIndex ?? 0,
                      pgxpLocked: pgxpPresetDecides(\.enabled))
        }
        if surface == .saveStates && !open { saveStatesNav = nil }
        let pause = surfaces.set(surface, open: open, paused: isPaused)
        if pause == true {
            releaseAllKeys()
            // The surface takes the controller, so a rewind button let go
            // under it would never be seen released.
            releaseRewind()
        }
        apply(pause)
        if surface == .pauseMenu && !open { pressPendingAnalog() }
        if surfaces.holdsHUD {
            hideTask?.cancel()
            hudVisible = true
        } else {
            showHUDThenHide()
        }
    }

    func openSaveStates(from origin: SaveStatesOrigin) {
        saveStatesOrigin = origin
        let tiles = [StateSource.resume] + StateSource.slots.map { StateSource.slot($0) }
        let filled = tiles.enumerated().filter { stateInfo($0.element) != nil }.map(\.offset)
        saveStatesNav = SaveStatesNavigation(filled: Set(filled))
        setSurface(.saveStates, open: true)
    }

    /// ⌘P and the bar's play button. While the menu or the panel holds the
    /// game paused, the request is Resume: they close, and the game runs
    /// whatever the pause before them was.
    func togglePause() {
        guard surfaces.pausesGame else { return isPaused.toggle() }
        closeStateSurfaces()
        isPaused = false
    }

    /// For an eject, a disc swap or an exit prompt: every surface goes, and
    /// with them the pause they held.
    private func closeAllSurfaces() {
        saveStatesNav = nil
        pendingAnalog = nil
        apply(surfaces.closeAll())
    }

    /// One key or controller move to whichever surface is on top.
    func surfaceMove(_ move: MenuMove) {
        if isOpen(.saveStates), var nav = saveStatesNav {
            let action = nav.handle(move)
            saveStatesNav = nav
            perform(action)
        } else if isOpen(.pauseMenu) {
            perform(menu.handle(move))
        }
    }

    /// The pause menu's highlight, for the pointer.
    func pointMenu(at item: PauseMenuItem) { menu.point(at: item) }
    func leaveMenu(_ item: PauseMenuItem) { menu.leave(item) }

    /// The panel's rows, bar and confirmation, for the mouse.
    func selectRow(_ row: Int) { saveStatesNav?.select(row) }
    func activateRow(_ row: Int) { updateNav { $0.activate(row) } }
    func pressButton(_ button: StateButton) { updateNav { $0.press(button) } }
    func pressSheet(_ button: SlotSheetButton) { updateNav { $0.answer(button) } }

    private func updateNav(_ change: (inout SaveStatesNavigation) -> SaveStatesAction) {
        guard var nav = saveStatesNav else { return }
        let action = change(&nav)
        saveStatesNav = nav
        perform(action)
    }

    func perform(_ action: PauseMenuAction) {
        switch action {
        case .none: break
        case .close: setSurface(.pauseMenu, open: false)
        case .saveStates: openSaveStates(from: .menu)
        case .reset:
            setSurface(.pauseMenu, open: false)
            reset()
        case .quitGame:
            setSurface(.pauseMenu, open: false)
            eject()
        case .adjust(let setting, let delta): adjust(setting, by: delta)
        case .toggle(.volume): toggleMute()
        case .toggle(.pgxp): pgxpEnabled.toggle()
        case .toggle(.analog): pendingAnalog = !analogShown
        case .toggle(.speed), .toggle(.resolution): break
        case .insertDisc(let index):
            setSurface(.pauseMenu, open: false)
            if currentDiscs.indices.contains(index) { changeDisc(to: currentDiscs[index]) }
        }
    }

    /// A load ends the visit: the panel and the menu under it close. A save
    /// and a delete keep the panel up, the row changing in place, which is
    /// what tells the player it worked.
    func perform(_ action: SaveStatesAction) {
        switch action {
        case .none: break
        case .close: setSurface(.saveStates, open: false)
        case .load(let source):
            closeStateSurfaces()
            loadState(source)
        case .save(let slot):
            saveState(toSlot: slot)
        case .delete(let source):
            guard let key = resumeKey else { return }
            saveStates.remove(source, key: key)
            saveStatesNav?.removed(SaveStatesNavigation.row(source))
        }
    }

    private func closeStateSurfaces() {
        setSurface(.saveStates, open: false)
        setSurface(.pauseMenu, open: false)
    }

    /// The controller's Home: the pause menu, as the PS button opens a
    /// console's. The panel on top of it closes first.
    func homePressed() {
        guard stage == .playing, session != nil else { return }
        if isOpen(.saveStates) {
            setSurface(.saveStates, open: false)
        } else if isOpen(.pauseMenu) {
            setSurface(.pauseMenu, open: false)
        } else if !isDialogShown {
            setSurface(.pauseMenu, open: true)
        }
    }

    /// What the menu's Analog switch shows: the mode asked for while the
    /// menu is up, else the pad's own.
    var analogShown: Bool { pendingAnalog ?? lastPadAnalog }

    /// ← and → on the menu's settings. Left is down or Off, right is up or
    /// On; none of them wraps.
    private func adjust(_ setting: QuickSetting, by delta: Int) {
        switch setting {
        case .speed:
            speed = min(max(speed + delta, SpeedSetting.choices.lowerBound), SpeedSetting.choices.upperBound)
        case .resolution:
            internalScale = min(max(internalScale + delta, InternalResolution.range.lowerBound),
                                InternalResolution.range.upperBound)
        case .pgxp:
            pgxpEnabled = delta > 0
        case .analog:
            pendingAnalog = delta > 0
        case .volume:
            volume = ((volume * 10).rounded() + Double(delta)) / 10
        }
    }

    private func pressPendingAnalog() {
        defer { pendingAnalog = nil }
        guard let wanted = pendingAnalog, wanted != lastPadAnalog else { return }
        session?.pressAnalog()
    }

    private func apply(_ pause: Bool?) {
        if let pause, session != nil { isPaused = pause }
    }

    /// Shows the HUD and schedules it to fade back out. Called on launch and
    /// on every mouse movement over the window. An open surface holds it up.
    func showHUDThenHide() {
        hudVisible = true
        hideTask?.cancel()
        guard !surfaces.holdsHUD else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.hudVisible = false
        }
    }

    /// A click on the picture takes the OSD down at once rather than waiting
    /// out the idle timer.
    func hideHUDNow() {
        setSurface(.speedTab, open: false)
        setSurface(.volume, open: false)
        guard !surfaces.holdsHUD else { return }
        hideTask?.cancel()
        hideTask = nil
        hudVisible = false
    }

    /// `onContinuousHover` reports the pointer for a click as well as for a
    /// move, so re-showing on every callback would undo `hideHUDNow` in the
    /// same runloop turn and the OSD would never go down. Only an actual
    /// change of position counts as a move, which is also the exact rule the
    /// hidden cursor comes back under (`NSCursor.setHiddenUntilMouseMoves`),
    /// so the two stay in step without either one driving the other.
    func hoverMoved(to point: CGPoint) {
        guard point != lastHoverPoint else { return }
        lastHoverPoint = point
        // The speed tab closes when the pointer strays well beyond it,
        // not the moment it leaves: overshooting a value is aiming.
        if isOpen(.speedTab), let tab = speedTabFrame,
           !tab.insetBy(dx: -SpeedPick.tolerance, dy: -SpeedPick.tolerance).contains(point) {
            setSurface(.speedTab, open: false)
        }
        showHUDThenHide()
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
    /// Whether the idle timer will hide the HUD, without waiting it out.
    var hidePendingForTesting: Bool { hideTask.map { !$0.isCancelled } ?? false }
    func simulateSessionEventForTesting(_ e: SessionEvent) { sessionEvent(e) }
    var cardSavingTaskForTesting: Task<Void, Never>? { cardSavingTask }
    var hapticsDriveForTesting: MotorDrive { haptics.driveForTesting }
    /// The hosted test app is not the active app, so a test sets it.
    func simulateAppActiveForTesting(_ active: Bool) {
        appActive = active
        updatePlayClock()
    }
    func simulateControllerInputForTesting(_ id: ObjectIdentifier) { haptics.noteInput(from: id) }
    func simulateControllerDisconnectForTesting(_ id: ObjectIdentifier?) { controllerDisconnected(id) }

    func simulatePlayingForTesting(ownWindow: Bool = false) {
        gameInOwnWindow = ownWindow
        stage = .playing
    }

    /// A game "running" on `s`, which answers only what the test tells it to.
    func installSessionForTesting(_ s: any GameSession, resumeKey: String?) {
        session = s
        bindEvents(s)
        paused = false
        self.resumeKey = resumeKey
        stage = .playing
    }

    func ejectNowForTesting() { ejectNow() }

    func simulateDiscsForTesting(_ discs: [GameEntry], inserted: Int, bios: BiosImage?) {
        currentDiscs = discs
        currentDiscIndex = inserted
        biosImage = bios
    }

    var inputMaskForTesting: UInt16 { input.mask }

    /// Drives the exact code path `bind(_:)`'s `valueChangedHandler` drives,
    /// without needing a real `GCExtendedGamepad`; see `applyPadInput`.
    func simulatePadInputForTesting(_ snapshot: InputMap) { applyPadInput(snapshot) }
    var sticksForTesting: Sticks { input.sticks }
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
        input.reset()
        session?.setButtons(input.mask)
        session?.setSticks(input.sticks)
    }

    /// `isRepeat` is the system's key repeat: Analog is an event, not a held
    /// state, so a repeat must not toggle it again. Buttons press idempotently.
    func keyDown(_ keyCode: UInt16, isRepeat: Bool = false) -> Bool {
        if stage == .playing && surfaces.pausesGame {
            // Every key is the surface's: nothing reaches the paused game.
            if let move = Self.menuMove(forKey: keyCode) { surfaceMove(move) }
            return true
        }
        if stage == .playing && keyCode == UInt16(kVK_Escape) && session != nil {
            setSurface(.pauseMenu, open: true)
            return true
        }
        if stage == .playing && keyCode == Self.fastForwardKey {
            setFastForwarding(true)
            return true
        }
        guard stage == .playing, let c = keyBindings.control(forKey: keyCode) else { return false }
        switch c {
        case .button(let b):
            input.press(b)
            session?.setButtons(input.mask)
        case .analog:
            if !isRepeat { toggleAnalog() }
        case .rewind:
            rewindHeldByKey = true
            updateRewinding()
        }
        return true
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

    func keyUp(_ keyCode: UInt16) -> Bool {
        if stage == .playing && keyCode == Self.fastForwardKey {
            setFastForwarding(false)
            return true
        }
        guard stage == .playing, let c = keyBindings.control(forKey: keyCode) else { return false }
        switch c {
        case .button(let b):
            input.release(b)
            session?.setButtons(input.mask)
        case .analog:
            break   // the press is the event
        case .rewind:
            rewindHeldByKey = false
            updateRewinding()
        }
        return true
    }

    /// The pad's Analog button: from a bound key or
    /// Machine ▸ Toggle Analog. The pad decides whether it takes effect.
    func toggleAnalog() {
        guard stage == .playing, !isPaused, !isDialogShown else { return }
        session?.pressAnalog()
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
                   let window = [LibraryWindow.current, GameWindow.current]
                       .compactMap({ $0 }).first(where: { $0.windowNumber == windowNumber }) {
                    window.toggleFullScreen(nil)
                    return true
                }
                // A surface on screen takes every key-down, from whichever
                // window: the Save States panel is a popover, a window of
                // its own. A ⌘ shortcut still reaches the menu bar.
                if isDown && !command && self.stage == .playing && self.surfaces.pausesGame {
                    return self.keyDown(code, isRepeat: isRepeat)
                }
                // The same for the library while the game has a window of its
                // own: there the arrows and Return belong to the grid.
                if self.gameInOwnWindow && !GameWindow.owns(windowNumber: windowNumber) {
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
            MainActor.assumeIsolated { self?.bindConnectedControllers() }
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
                MainActor.assumeIsolated { self?.homePressed() }
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
        guard stage == .playing else { return }
        let moves = padEdges.moves(for: snapshot)
        if surfaces.pausesGame {
            // The surface has the controller; the paused game sees it let go.
            for move in moves { surfaceMove(move) }
            input = InputMap()
            session?.setButtons(input.mask)
            session?.setSticks(input.sticks)
            return
        }
        let pad = rewindSetting.padButton
        let held = pad.claims(snapshot)
        if held != rewindHeldByPad {
            rewindHeldByPad = held
            updateRewinding()
        }
        // The rewind button never reaches the game.
        let game = pad.withheld(from: snapshot)
        input = game
        session?.setButtons(game.mask)
        session?.setSticks(game.sticks)
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

    private static func beside(_ disc: URL, ext: String) -> Data? {
        try? Data(contentsOf: disc.deletingPathExtension().appendingPathExtension(ext))
    }

    private static func describe(_ error: Error) -> String {
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
        case Ps1Error.settingsSize:   return "This copy of Substation and its emulator engine do not match. Reinstall the app."
        case BiosError.noFolderSelected: return "Choose a BIOS folder first."
        case BiosError.noMatchingBIOS(let r): return "No \(r.rawValue) BIOS found in your BIOS folder. This disc needs it."
        case BiosError.wrongSize(let n):  return "That BIOS file is \(n) bytes; it must be exactly 524,288."
        case BiosError.unreadable:    return "That BIOS file could not be read."
        default: return String(describing: error)
        }
    }
}

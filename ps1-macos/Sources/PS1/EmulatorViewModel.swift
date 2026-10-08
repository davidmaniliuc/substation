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
    /// The game's own window should be open.
    var gameWindowShown: Bool { stage == .playing && gameInOwnWindow }
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
    var errorMessage: String?
    var showRawBinWarning = false

    /// HUD auto-hide lives here rather than in a `@State` on the view. `@State`
    /// compiles fine (Xcode 26.6 has been installed since 2026-08-22, and
    /// `libSwiftUIMacros.dylib` ships in its `MacOSX.platform`); living on the
    /// `@Observable` model is now a design choice, not a constraint: this is
    /// where the behaviour belongs regardless of which mechanism holds it.
    private(set) var hudVisible = true
    private var hideTask: Task<Void, Never>?

    /// The last pointer position the view reported. `nil` until the mouse has
    /// been over the window at all, so the very first hover counts as a move.
    private var lastHoverPoint: CGPoint?

    /// Emulated frames per second, or `nil` before the first window has closed
    /// and whenever no game is loaded. The HUD reads it; nothing else does.
    private(set) var fps: Double?
    private var fpsCounter = FpsCounter()
    private var fpsTask: Task<Void, Never>?

    /// A one-line status shown for a moment: the Analog notice when the
    /// pad's mode changes, and the save-state notices (saved, loaded, undone,
    /// or why a load was refused).
    private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    private var padTask: Task<Void, Never>?
    /// The mode last seen, so only a CHANGE shows the notice. Each new
    /// runner starts from a digital pad.
    private var lastPadAnalog = false

    /// True while the game is writing to a memory card, and for a moment
    /// after its last block: long enough to outlast the runner's one-second
    /// debounce, so the pill goes down after the save has reached disk.
    private(set) var savingToMemoryCard = false
    private var cardSavingTask: Task<Void, Never>?
    /// The runner's write count last seen. Each new runner restarts at zero.
    private var lastCardWrites: UInt64 = 0

    private(set) var runner: EmulatorRunner?
    private var core: Ps1Core?
    private var ring: AudioRing?
    private var audio: AudioOutput?
    private let bios = BiosLibrary()

    let library = GameLibrary()
    let covers = CoverStore()
    /// Last played and active play time per game. Outlives every disc, like
    /// `covers`.
    let playStats = PlayStatsStore()
    private var playClock = PlayClock()
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
    /// like `covers` and unlike `runner`.
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
    /// is what keeps a second leave-request (and a second save request, which
    /// would replace the runner's pending one) out of that window.
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

    init(saveStates: SaveStateStore, autoSave: AutoSaveSetting) {
        self.saveStates = saveStates
        self.autoSave = autoSave
        stage = (bios.folderURL != nil && library.folderURL != nil) ? .library : .onboarding
        observeControllers()
        observeKeyboard()

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


    public var isPaused: Bool {
        get { runner?.isPaused ?? false }
        set {
            runner?.isPaused = newValue
            updatePlayClock()
        }
    }

    /// The single place the play clock learns anything: every change to
    /// running, paused or app-active calls this, and whatever stretch it ends
    /// is banked under the running game's key. Called BEFORE `resumeKey` is
    /// cleared on teardown, so the last stretch lands on the game it belongs to.
    private func updatePlayClock() {
        let now = ProcessInfo.processInfo.systemUptime
        let banked = playClock.update(running: runner != nil, paused: isPaused,
                                      active: appActive, at: now)
        if let key = resumeKey { playStats.add(banked, to: key) }
        autoSaveClock.update(counting: runner != nil && !isPaused && appActive, at: now)
    }

    /// Internal resolution, 1...8, persisted. `public` to match the app-facing
    /// seams beside it (`isPaused`, `rescanLibrary()`) rather than because a
    /// module boundary requires it: `Sources/PS1App` is a directory inside the
    /// single `PS1` module, not a second target.
    ///
    /// A computed seam over a stored struct: `@Observable` instruments the
    /// stored `resolution`, so mutating it through here notifies observers and
    /// `ContentView` re-keys the display view on the new scale.
    private var resolution = InternalResolution()

    public var internalScale: Int {
        get { resolution.scale }
        set { resolution.set(newValue) }
    }

    /// Where the dither pattern is sampled, persisted: the same computed seam
    /// over a stored struct as `internalScale` above.
    ///
    /// Unlike a scale change this needs no `.id()` rebuild: it is a runtime
    /// uniform on a pipeline that is already built, so `MetalDisplayView`
    /// carries it down to the live renderer on the ordinary update path.
    private var ditherSetting = DitherSetting()

    public var ditherMode: DitherMode {
        get { ditherSetting.mode }
        set { ditherSetting.set(newValue) }
    }

    private var libraryLayout = LibraryLayoutSetting()

    /// Grid or list. The toolbar and Library ▸ as Grid / as List both bind here.
    var libraryViewMode: LibraryViewMode {
        get { libraryLayout.viewMode }
        set { libraryLayout.setViewMode(newValue) }
    }

    /// The grid's LIVE tile width in points, clamped by the setting and
    /// fitted to the grid's size, so it never lays out fewer than
    /// `LibraryLayoutSetting.fewestColumns`. The slider binds here and
    /// nothing it sets is persisted; it calls `commitCoverSize()` when a drag
    /// ends.
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

    /// The list's sort, for the session only: a sort is a question asked
    /// now, so it is never persisted. Held here rather than in the table so
    /// a Grid→List switch or a return from a game does not reset it.
    var librarySortOrder = [KeyPathComparator(\LibraryRow.title)]

    /// The toolbar search, for the session only, as the sort is.
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
    /// grid in front of the player: in the list or in a game they would move
    /// a size nobody can see.
    private func coverSize(columnDelta: Int) -> Double? {
        guard libraryVisible, libraryViewMode == .grid else { return nil }
        let width = Double(libraryGridWidth)
        let columns = libraryColumns + columnDelta
        guard columns >= LibraryLayoutSetting.fewestColumns(
            width: width, height: Double(libraryGridHeight)) else { return nil }
        return LibraryLayoutSetting.size(forColumns: columns, width: width)
    }

    var canGrowCovers: Bool { coverSize(columnDelta: -1) != nil }
    var canShrinkCovers: Bool { coverSize(columnDelta: 1) != nil }
    var canResetCovers: Bool {
        libraryVisible && libraryViewMode == .grid
            && libraryTileSize != LibraryLayoutSetting.defaultSize
    }
    /// A slider drag: the size snaps to a column step at the grid's width.
    func dragCovers(to value: Double) {
        libraryTileSize = LibraryLayoutSetting.snapped(value, width: Double(libraryGridWidth),
                                                       height: Double(libraryGridHeight))
    }
    func commitCoverSize() { libraryLayout.commitTileSize() }
    func growCovers() { stepCovers(columnDelta: -1) }
    func shrinkCovers() { stepCovers(columnDelta: 1) }
    func resetCovers() { libraryLayout.resetTileSize() }

    private func stepCovers(columnDelta: Int) {
        guard let size = coverSize(columnDelta: columnDelta) else { return }
        libraryTileSize = size
        commitCoverSize()
    }

    /// The texture filter, persisted: a runtime uniform exactly like
    /// `ditherMode`, so no `.id()` rebuild.
    private var textureFilterSetting = TextureFilterSetting()

    public var textureFilter: TextureFilter {
        get { textureFilterSetting.filter }
        set { textureFilterSetting.set(newValue) }
    }

    /// The sprite texture filter, persisted: a runtime uniform like
    /// `textureFilter`, so no `.id()` rebuild.
    private var spriteFilterSetting = SpriteFilterSetting()

    public var spriteFilter: TextureFilter {
        get { spriteFilterSetting.filter }
        set { spriteFilterSetting.set(newValue) }
    }

    /// PGXP geometry correction, persisted: the same computed seam over a
    /// stored struct as `internalScale` above.
    ///
    /// Unlike a scale change this needs no `.id()` rebuild of the display
    /// coordinator: PGXP changes the CONTENTS of the command stream, not the
    /// size or format of any texture, so the existing renderer consumes it
    /// from the next frame onward.
    private var pgxpSetting = PgxpSetting()

    public var pgxpEnabled: Bool {
        get { pgxpSetting.enabled }
        set {
            pgxpSetting.set(newValue)
            pushPgxp()
        }
    }

    /// The six sub-settings, each the same computed seam over the same stored
    /// struct. They need no `.id()` rebuild either, and for the same reason:
    /// all six change the CONTENTS of the command stream, never the size or
    /// format of a texture.
    public var pgxpCpu: Bool {
        get { pgxpSetting.cpu }
        set {
            pgxpSetting.setCpu(newValue)
            pushPgxp()
        }
    }

    public var pgxpCulling: Bool {
        get { pgxpSetting.culling }
        set {
            pgxpSetting.setCulling(newValue)
            pushPgxp()
        }
    }

    public var pgxpVertexCache: Bool {
        get { pgxpSetting.vertexCache }
        set {
            pgxpSetting.setVertexCache(newValue)
            pushPgxp()
        }
    }

    public var pgxpTolerance: Float {
        get { pgxpSetting.tolerance }
        set {
            pgxpSetting.setTolerance(newValue)
            pushPgxp()
        }
    }

    public var pgxpTextureCorrection: Bool {
        get { pgxpSetting.textureCorrection }
        set {
            pgxpSetting.setTextureCorrection(newValue)
            pushPgxp()
        }
    }

    public var pgxpColorCorrection: Bool {
        get { pgxpSetting.colorCorrection }
        set {
            pgxpSetting.setColorCorrection(newValue)
            pushPgxp()
        }
    }

    /// The PGXP depth buffer and its two dependents. Unlike the six sub-
    /// settings above, `pgxpDepthBuffer` DOES need a rebuild: see
    /// `ContentView`'s `DisplayIdentity`, which reads this through its
    /// EFFECTIVE value (`pgxpDepthBuffer && pgxpEnabled`) rather than reading
    /// it directly, since `MetalVram` allocates its depth texture `.private`
    /// or `.memoryless` depending on it.
    public var pgxpDepthBuffer: Bool {
        get { pgxpSetting.depthBuffer }
        set {
            pgxpSetting.setDepthBuffer(newValue)
            pushPgxp()
        }
    }

    public var pgxpTransparentDepth: Bool {
        get { pgxpSetting.transparentDepth }
        set {
            pgxpSetting.setTransparentDepth(newValue)
            pushPgxp()
        }
    }

    public var pgxpDisable2d: Bool {
        get { pgxpSetting.disable2d }
        set {
            pgxpSetting.setDisable2d(newValue)
            pushPgxp()
        }
    }

    public var pgxpPreserveProjection: Bool {
        get { pgxpSetting.preserveProjection }
        set {
            pgxpSetting.setPreserveProjection(newValue)
            pushPgxp()
        }
    }

    /// Settings ▸ Enhancements ▸ Restore Defaults: all eleven, master included.
    func restoreDefaultPgxp() {
        pgxpSetting.restoreDefaults()
        pushPgxp()
    }

    /// Settings ▸ Enhancements ▸ Per-Game Fixes.
    public var pgxpUsePresets: Bool {
        get { pgxpSetting.usePresets }
        set {
            pgxpSetting.setUsePresets(newValue)
            pushPgxp()
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

    /// The depth buffer as the core runs it, which is what `MetalVram`'s depth
    /// texture must be built for.
    var pgxpEffectiveDepthBuffer: Bool {
        (pgxpPreset?.depthBuffer ?? pgxpSetting.depthBuffer) && pgxpEffectivelyEnabled
    }

    private func pushPgxp() {
        if let runner { applyPgxp(to: runner) }
    }

    /// Hands every PGXP setting to a runner: one rebuilt per disc, while the
    /// settings outlive them all, so re-applying only the master would leave a
    /// player's sub-settings behind on disc two. Each value is the preset's
    /// where it has one, the player's elsewhere.
    private func applyPgxp(to runner: EmulatorRunner) {
        let p = pgxpPreset
        let s = pgxpSetting
        runner.setPgxp(p?.enabled ?? s.enabled)
        runner.setPgxpCpu(p?.cpu ?? s.cpu)
        runner.setPgxpCulling(p?.culling ?? s.culling)
        runner.setPgxpVertexCache(p?.vertexCache ?? s.vertexCache)
        runner.setPgxpTolerance(p?.tolerance ?? s.tolerance)
        runner.setPgxpTextureCorrection(p?.textureCorrection ?? s.textureCorrection)
        runner.setPgxpColorCorrection(p?.colorCorrection ?? s.colorCorrection)
        runner.setPgxpDepthBuffer(p?.depthBuffer ?? s.depthBuffer)
        runner.setPgxpTransparentDepth(s.transparentDepth)
        runner.setPgxpDisable2d(p?.disable2d ?? s.disable2d)
        runner.setPgxpPreserveProjection(p?.preserveProjection ?? s.preserveProjection)
    }

    /// Whether Restore Defaults has anything to do.
    var pgxpIsDefault: Bool { pgxpSetting.isDefault }

    /// The CPU engine: persisted, applied by the runner between frames.
    private var cpuEngineSetting = CpuEngineSetting()

    public var cpuEngine: CpuEngine {
        get { cpuEngineSetting.engine }
        set {
            cpuEngineSetting.set(newValue)
            runner?.setCpuEngine(cpuEngineSetting.engine)
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

    /// What the library shows: `groups` narrowed by the toolbar search.
    var visibleGroups: [GameGroup] {
        LibrarySearch.filter(groups, query: librarySearch)
    }

    /// Output volume, 0...1 plus a mute flag, persisted: the same computed
    /// seam over a stored struct as `internalScale` above, for the same
    /// reason: `@Observable` instruments the stored `volumeSetting`, so the
    /// HUD's slider and speaker icon both track it.
    ///
    /// The gain is pushed into `AudioOutput` on every change AND re-applied
    /// when one is built in `play()`, because audio is rebuilt per game while
    /// the setting outlives every disc.
    private var volumeSetting = VolumeSetting()

    var volume: Double {
        get { volumeSetting.level }
        set {
            volumeSetting.set(newValue)
            audio?.setGain(volumeSetting.gain)
        }
    }

    var isMuted: Bool { volumeSetting.isMuted }

    func toggleMute() {
        volumeSetting.toggleMute()
        audio?.setGain(volumeSetting.gain)
    }

    /// Emulation speed, persisted, plus the session-only held fast-forward:
    /// the same computed seam over a stored struct as `volume` above. Pushed
    /// into BOTH the audio path, which paces it, and the runner, whose ring
    /// water marks scale with it; and re-applied in `play()` because both are
    /// rebuilt per game while the setting outlives every disc.
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
        runner?.setSpeed(speedSetting.effective)
        audio?.setSpeed(speedSetting.effective)
    }

    var hasBIOSFolder: Bool { bios.folderURL != nil }
    var biosFolderName: String? { bios.folderURL?.lastPathComponent }
    var gamesFolderName: String? { library.folderURL?.lastPathComponent }

    public func chooseBIOSFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your SCPH-*.bin BIOS files"
        ) else { return }
        do {
            try bios.setFolder(url)
        } catch {
            errorMessage = "This BIOS folder works for now, but could not be remembered. Choose it again next time you open Substation."
        }
    }

    public func chooseGamesFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your games. Subfolders are scanned too."
        ) else { return }
        do {
            try library.setFolder(url)
        } catch {
            errorMessage = "This games folder works for now, but could not be remembered. Choose it again next time you open Substation."
        }
    }

    /// Forwards to `library.rescan()`. `GameLibrary` itself is `internal`, so
    /// this is the one seam File ▸ Refresh Library calls; `public` follows the
    /// same app-facing-surface convention as `isPaused`, not a module
    /// boundary: `Sources/PS1App` compiles into this same `PS1` module.
    public func rescanLibrary() { library.rescan() }

    /// Onboarding's Continue. Guarded rather than trusted: the button is
    /// disabled until both folders are set, but the stage is the thing the
    /// rest of the app branches on, so it checks for itself.
    func finishOnboarding() {
        guard hasBIOSFolder, library.folderURL != nil else { return }
        stage = .library
    }

    func play(_ entry: GameEntry) {
        launch(entry.url)
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
        case .deleteAndBoot:
            saveStates.removeResume(offer.key)
            load(disc: offer.launching.url)
        case .cancel:
            leaveForLibrary()
        }
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
        if runner != nil { ejectNow() }
    }

    private static func resumeMessage(_ error: Error) -> String {
        switch error as? Ps1Error {
        case .stateVersion: "This state was saved by a newer version of Substation."
        case .stateBIOS: "This state was saved with a different BIOS."
        case .stateDisc: "This state belongs to a different disc."
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
            errorMessage = "That image could not be read."
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
            errorMessage = "No covers could be downloaded. Check your network connection."
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
        if requestExit(.open(url)) == .proceed { launch(url) }
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
        guard let runner else { return }
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
            runner.requestDiscSwap(bin: binData, cue: cueData,
                                   sbi: Self.sidecar(forDisc: entry.url))
            // The undo machine had the other disc in its tray.
            undoState = nil
            discSwapGeneration += 1
            currentDiscIndex = currentDiscs.firstIndex { $0.id == entry.id }
            discTitle = entry.title
            // Each disc has its own serial and its own row in the table.
            discPgxpPreset = PgxpPreset.lookup(serial: entry.identity.serial)
            pushPgxp()
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

            let core = try Ps1Core()
            // On the core before a resume state loads: the load restores the
            // I-cache as the saving machine held it, and a later switch
            // would flush it. No runner owns this core yet.
            try? core.setCpuEngine(cpuEngine)
            core.setFastBoot(fastBoot)
            try core.loadBIOS(biosData)
            try core.loadDisc(bin: binData, cue: cueData, sbi: Self.sidecar(forDisc: url))
            if let resume {
                // No explicit resync: the new runner's display view claims its
                // fresh queue, which adopts this (restored) VRAM.
                do {
                    try core.loadState(resume)
                } catch {
                    // In a running game the refusal is a notice: the launch
                    // alert's Cancel would eject the game still playing.
                    if let resumeRefused { resumeRefused(error); return }
                    resumeFailure = ResumeFailure(message: Self.resumeMessage(error),
                                                  freshBoot: freshBoot ?? url)
                    return
                }
            }

            let ring = AudioRing(capacity: EmulatorRunner.ringCapacity)
            let runner = EmulatorRunner(core: core, ring: ring, cards: cards)
            let audio = try AudioOutput(ring: ring, runner: runner)

            // Every throwing step above has already succeeded, so the new
            // machine is fully built and ready to take over. Only NOW is it
            // safe to tear down whatever was already running: opening a
            // disc that fails to load (bad cue, missing BIOS, unreadable
            // bin) must leave the current game untouched, not kill it out
            // from under the player and then show an error on top.
            teardownRunningMachine()

            self.core = core
            self.ring = ring
            self.runner = runner
            self.audio = audio
            installedReplacement = true

            // AFTER teardownRunningMachine(), never before. Everything else
            // here is built ahead of the teardown so that a disc which fails
            // to load leaves the running game alone, but the card cannot
            // follow that order: teardown is what FLUSHES the outgoing game's
            // card, and reading the file before it would load stale bytes and
            // then write them back over the save it was about to make.
            //
            // A failure is non-fatal: a missing or unreadable card file is a
            // blank card, which the BIOS reports as unformatted and offers to
            // format, exactly as a new card does on hardware.
            for slot in 0..<MemoryCardStore.slots {
                guard let image = cards.load(slot: slot) else { continue }
                try? core.loadMemcard(image, slot: slot)
            }

            audio.setGain(volumeSetting.gain)
            applySpeed()
            // Re-applied per game for the same reason the gain is: the runner
            // is rebuilt with every disc while the setting outlives them all.
            // The preset is set only now, past the teardown, so a disc that
            // fails to load leaves the running game's preset alone.
            discPgxpPreset = PgxpPreset.lookup(serial: identity.serial)
            applyPgxp(to: runner)
            runner.setCpuEngine(cpuEngine)
            runner.start()
            try audio.start()
            startSamplingFps()
            startWatchingPad()
            startAutoSave()

            discTitle = identity.title ?? url.deletingPathExtension().lastPathComponent
            currentDiscs = Self.siblingDiscs(of: url, entries: library.entries)
            currentDiscIndex = currentDiscs.firstIndex {
                Self.canonicalPath($0.url) == Self.canonicalPath(url)
            }
            resumeKey = SaveStateStore.key(for: currentDiscs.first ?? Self.discEntry(for: url))
            gameInOwnWindow = gameWindowMode == .newWindow
            stage = .playing
            if let resumeKey { playStats.markPlayed(resumeKey, at: Date()) }
            updatePlayClock()
            // A raw .bin cannot represent audio tracks, so a CD-DA title opened
            // this way is silent, which looks like a bug unless we say so.
            showRawBinWarning = kind == .bin
        } catch {
            if installedReplacement {
                // `runner.start()` (and possibly `audio.start()`) already ran
                // against the new machine, so leaving it installed here strands
                // a half-built instance nothing drains: with no audio callback
                // pulling from the ring, EmulatorRunner.runLoop parks on
                // `ring.filled > highWater` forever, an orphan thread under a
                // plain error alert. Tear it down so the failure lands on a
                // coherent, idle stage instead.
                teardownRunningMachine()
                stage = .library
            }
            errorMessage = Self.describe(error)
        }
    }

    /// Through the runner, never `core.reset()` here: the emulator thread
    /// may be mid-frame, and under the recompiler the reset frees the code
    /// it is executing. The runner resets between frames and resyncs.
    public func reset() {
        isPaused = false
        runner?.requestReset()
    }

    public func eject() {
        if requestExit(.eject) == .proceed { ejectNow() }
    }

    /// The game window's close button and ⌘W: Eject, sheet and all. The
    /// window closes now only when nothing was asked; otherwise it closes
    /// itself once the game has ended.
    func closeGameWindow() -> Bool {
        eject()
        return stage != .playing
    }

    private func ejectNow() {
        teardownRunningMachine()
        currentDiscs = []
        currentDiscIndex = nil
        stage = .library
    }

    /// The exit or resume dialog is on screen (see `GlassDialog`).
    var isDialogShown: Bool { exitPrompt != nil || resumeOffer != nil }

    /// A game is running and nothing is in the way of a save or a load.
    var canUseStates: Bool {
        stage == .playing && runner != nil && !isDialogShown && !finishingExit && resumeFailure == nil
    }

    func stateInfo(_ source: StateSource) -> SaveStateStore.Info? {
        _ = stateRevision      // read it so SwiftUI re-runs this on a change
        guard let resumeKey else { return nil }
        return saveStates.info(source, key: resumeKey)
    }

    func saveState(toSlot n: Int) {
        guard canUseStates, let runner, let key = resumeKey else { return }
        let store = saveStates
        runner.requestSaveState { [weak self] result in
            // Off the main actor: compression of a multi-megabyte state would
            // otherwise stall the UI for the length of it.
            Task.detached {
                var message = "Could not save to Slot \(n)"
                if case .success(let snap) = result {
                    do {
                        try store.saveSlot(n, state: snap.state, thumbnail: snap.thumbnail, key: key)
                        message = "Saved to Slot \(n)"
                    } catch {
                        NSLog("Substation: slot \(n) failed to write: \(error)")
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.stateRevision += 1
                    // Answered after an eject or another game: not this game's.
                    if self.runner === runner { self.showNotice(message) }
                }
            }
        }
    }

    /// The 1 s tick's body. Silent: a status line about work the player did
    /// not ask for is noise, and a failure is logged.
    func autoSaveIfDue(at now: TimeInterval) {
        guard let interval = autoSave.interval,
              autoSaveClock.elapsed(at: now) >= interval,
              canUseStates, !autoSaveInFlight,
              let runner, let key = resumeKey else { return }
        autoSaveInFlight = true
        autoSaveClock.restart(at: now)
        let store = saveStates
        runner.requestSaveState { [weak self] result in
            Task.detached {
                switch result {
                case .success(let snap):
                    do { try store.saveResume(state: snap.state, thumbnail: snap.thumbnail, key: key) }
                    catch { NSLog("Substation: auto-save failed to write: \(error)") }
                case .failure(let error):
                    NSLog("Substation: auto-save failed: \(error)")
                }
                await MainActor.run {
                    guard let self else { return }
                    // Answered after an eject: the next game's save may be in flight.
                    if self.runner === runner { self.autoSaveInFlight = false }
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
        guard let data = saveStates.load(source, key: key) else { return showNotice(damaged) }
        let serial: String?
        do { serial = try Ps1Core.peekStateSerial(data) } catch { return showNotice(Self.resumeMessage(error)) }

        // Saved on another disc of this game: rebuild on that disc, as a
        // launch-time resume does. No undo across that rebuild.
        let inTray = currentDiscIndex.map { currentDiscs[$0] }
        if let serial, serial != inTray?.serial {
            guard let disc = ResumeOffer.disc(forSerial: serial, in: currentDiscs) else {
                return showNotice(Self.resumeMessage(Ps1Error.stateDisc))
            }
            load(disc: disc.url, resume: data, freshBoot: nil) { [weak self] error in
                self?.showNotice(Self.resumeMessage(error))
            }
            return
        }
        request(load: data, done: "Loaded \(source.title)")
    }

    func undoLoadState() {
        guard canUseStates, let undoState else { return }
        request(load: undoState, done: "Load undone")
    }

    private func request(load data: Data, done: String) {
        guard let runner else { return }
        let generation = discSwapGeneration
        runner.requestLoadState(data) { [weak self] result in
            Task { @MainActor in
                // Answered after an eject or another game: not this game's.
                guard let self, self.runner === runner else { return }
                switch result {
                case .success(let replaced):
                    if self.discSwapGeneration == generation { self.undoState = replaced }
                    self.autoSaveClock.restart(at: ProcessInfo.processInfo.systemUptime)
                    self.showNotice(done)
                case .failure(let error):
                    self.showNotice(Self.resumeMessage(error))
                }
            }
        }
    }

    /// Every way of leaving a running game comes through here. `.prompted`
    /// pauses the game and raises the sheet; the caller then waits.
    func requestExit(_ intent: ExitIntent) -> ExitDecision {
        // Another sheet or alert is up, or an exit is already finishing: a
        // second prompt on top of it could be dropped, leaving ⌘Q unanswered.
        if finishingExit || resumeOffer != nil || resumeFailure != nil { return .busy }
        let decision = exitGate.request(intent, playing: stage == .playing && runner != nil)
        if decision == .prompted {
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
        guard saveStateOnExit, let runner, let key = resumeKey else { return finish.fire() }

        // The completion runs on the emulator thread, or on whichever thread
        // calls `stop()`. Hop to main ASYNC only: main may be blocked in
        // `stop()`'s join, and a sync hop would stall it. The write itself
        // runs off the main actor, as the auto-save's does: compression, and
        // the store's queue an auto-save may hold, would stall the UI.
        let store = saveStates
        runner.requestSaveState { result in
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
        // A save the emulator thread never services must not hold the exit
        // hostage. Three seconds is a hundred-odd frames.
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
            launch(url)
        }
    }

    private func replyToTerminate(_ yes: Bool) {
        if yes { exitConfirmed = true }
        terminateReply?(yes)
        terminateReply = nil
    }

    /// Stops whatever emulator instance is currently installed and releases
    /// its resources, but does not touch `stage`: `eject()` sets it to
    /// `.library` afterwards, and `load(disc:)` sets it to `.playing` once
    /// the replacement is installed, so this is shared by both without
    /// either one fighting the other's stage transition.
    ///
    /// `audio.stop()` runs BEFORE `runner.stop()` on purpose: `AudioOutput`
    /// holds an `unowned` (non-retaining) reference to its `EmulatorRunner`,
    /// so its real-time render callback must stop touching the runner before
    /// `runner.stop()` joins the emulator thread and drops the runner's last
    /// strong reference; reversing the order risks the callback firing into
    /// a runner that is mid-teardown.
    private func teardownRunningMachine() {
        // Banks the session under the outgoing game before anything below
        // clears the runner and the key it is filed under.
        isPaused = true
        fpsTask?.cancel()
        fpsTask = nil
        fps = nil
        padTask?.cancel()
        padTask = nil
        autoSaveTask?.cancel()
        autoSaveTask = nil
        autoSaveInFlight = false
        undoState = nil
        haptics.release()
        noticeTask?.cancel()
        notice = nil
        cardSavingTask?.cancel()
        savingToMemoryCard = false
        audio?.stop()
        runner?.stop()
        audio = nil
        runner = nil
        core = nil
        ring = nil
        resumeKey = nil
        discTitle = ""
        discPgxpPreset = nil
        // A key held across the transition would otherwise survive it: the
        // stage gate on keyUp (below) stops a release from reaching a game
        // that no longer exists, so without this the bit it set stays
        // latched into the NEXT game's first setButtons call.
        input.reset()
        // The same trap for the fast-forward key: its release would never
        // arrive, and the next game would start fast-forwarding.
        speedSetting.isFastForwarding = false
    }

    /// Polls the runner's cumulative frame count on a fixed cadence, rather
    /// than being driven from the emulator thread: the count is an atomic, so
    /// a poll costs a load, and nothing on the audio-paced thread has to reach
    /// the main actor once a frame just to move a number on screen.
    ///
    /// It samples whether or not the OSD is showing. Two wakeups a second is
    /// not worth coupling the sampler to `hudVisible`, and a counter started
    /// only when the OSD appears would have nothing to report for the first
    /// half-second it is visible, which is most of the time anyone looks at it.
    private func startSamplingFps() {
        fpsTask?.cancel()
        fpsCounter = FpsCounter()
        fps = nil
        fpsTask = Task { [weak self] in
            // Sample BEFORE the first sleep so the window that produces the
            // first reading is the one that has already begun.
            while !Task.isCancelled {
                guard let self, let runner = self.runner else { return }
                self.fpsCounter.sample(frames: runner.totalFramesProduced,
                                       at: ProcessInfo.processInfo.systemUptime)
                self.fps = self.fpsCounter.value
                try? await Task.sleep(for: .seconds(FpsCounter.window))
            }
        }
    }

    /// Polls the pad's mode and motors at the display's rate, and the memory
    /// card's write count beside them. Both are atomics on the runner, so a
    /// poll costs two loads; the rumble it feeds must start within a frame of
    /// the game asking for it.
    private func startWatchingPad() {
        padTask?.cancel()
        lastPadAnalog = false
        lastCardWrites = 0
        padTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let runner = self.runner else { return }
                self.padStatusChanged(runner.padStatus)
                self.memoryCardWritesChanged(runner.memoryCardWrites)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func padStatusChanged(_ s: PadStatus) {
        if s.analog != lastPadAnalog {
            lastPadAnalog = s.analog
            showNotice(s.analog ? "Analog on" : "Analog off")
        }
        haptics.drive(MotorDrive(status: s, allowed: rumbleAllowed))
    }

    private func memoryCardWritesChanged(_ writes: UInt64) {
        guard writes != lastCardWrites else { return }
        lastCardWrites = writes
        savingToMemoryCard = true
        cardSavingTask?.cancel()
        cardSavingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MemoryCardFlushPolicy.settleDelay + 0.5))
            guard !Task.isCancelled else { return }
            self?.savingToMemoryCard = false
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Shows the HUD and schedules it to fade back out. Called on launch and
    /// on every mouse movement over the window.
    func showHUDThenHide() {
        hudVisible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.hudVisible = false
        }
    }

    /// A click on the picture takes the OSD down at once rather than waiting
    /// out the idle timer.
    func hideHUDNow() {
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
    func simulatePadStatusForTesting(_ s: PadStatus) { padStatusChanged(s) }
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

    /// A game "running" on `runner` (never started, so it services nothing).
    func installRunnerForTesting(_ runner: EmulatorRunner, resumeKey: String?) {
        self.runner = runner
        self.resumeKey = resumeKey
        stage = .playing
    }

    func ejectNowForTesting() { ejectNow() }

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
        runner?.setButtons(input.mask)
        runner?.setSticks(input.sticks)
    }

    /// `isRepeat` is the system's key repeat: Analog is an event, not a held
    /// state, so a repeat must not toggle it again. Buttons press idempotently.
    func keyDown(_ keyCode: UInt16, isRepeat: Bool = false) -> Bool {
        if stage == .playing && keyCode == Self.fastForwardKey {
            setFastForwarding(true)
            return true
        }
        guard stage == .playing, let c = keyBindings.control(forKey: keyCode) else { return false }
        switch c {
        case .button(let b):
            input.press(b)
            runner?.setButtons(input.mask)
        case .analog:
            if !isRepeat { toggleAnalog() }
        }
        return true
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
            runner?.setButtons(input.mask)
        case .analog:
            break   // the press is the event
        }
        return true
    }

    /// The pad's Analog button: from the Home button, a bound key or
    /// Machine ▸ Toggle Analog. The pad decides whether it takes effect.
    func toggleAnalog() {
        guard stage == .playing, !isPaused, !isDialogShown else { return }
        runner?.pressAnalogButton()
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
    private func observeKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Only the code crosses the boundary; NSEvent is not Sendable.
            let code = event.keyCode
            let isDown = event.type == .keyDown
            let isRepeat = event.type == .keyDown && event.isARepeat
            let windowNumber = event.windowNumber
            let command = event.modifierFlags.contains(.command)
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
        // Home is the Analog button. The system takes it for its own
        // overlay unless told not to.
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            home.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.toggleAnalog() }
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
        input = snapshot
        runner?.setButtons(snapshot.mask)
        runner?.setSticks(snapshot.sticks)
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
        let url = disc.deletingPathExtension().appendingPathExtension("sbi")
        return try? Data(contentsOf: url)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Ps1Error.badBIOSSize:    return "That BIOS file is not 512 KB. PlayStation BIOS images are exactly 524,288 bytes."
        case Ps1Error.multiFileCue:   return "This cue sheet splits its tracks across several files, and the sizes needed to lay them out are missing. The rip may be incomplete."
        case Ps1Error.badCue:         return "That cue sheet could not be parsed."
        case Ps1Error.badCHD:         return "This CHD was made by an old chdman or depends on a parent image. Re-create it with chdman createcd."
        case Ps1Error.badSBI:         return "The .sbi file beside this disc is not a LibCrypt sidecar. Remove it, or replace it with the one that shipped with this rip. The game will not get past its copy protection without a valid one."
        case Ps1Error.outOfMemory:    return "Out of memory."
        case Ps1Error.createFailed:   return "Could not start the emulator core."
        case BiosError.noFolderSelected: return "Choose a BIOS folder first."
        case BiosError.noMatchingBIOS(let r): return "No \(r.rawValue) BIOS found in your BIOS folder. This disc needs it."
        case BiosError.wrongSize(let n):  return "That BIOS file is \(n) bytes; it must be exactly 524,288."
        case BiosError.unreadable:    return "That BIOS file could not be read."
        default: return String(describing: error)
        }
    }
}

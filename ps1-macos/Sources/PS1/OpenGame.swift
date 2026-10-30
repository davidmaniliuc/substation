import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One open game: the session it runs in and everything that dies with it,
/// the HUD and its surfaces, the pause, the notices, the play and auto-save
/// clocks, Undo Load State, the rewind holds and the pad as this game sees
/// it. The app model (`EmulatorViewModel`) keeps what outlives every game:
/// the library, the settings, the stores, the launch flow and the exit gate.
@MainActor
@Observable
final class OpenGame: Identifiable {
    /// Its window's key (`GameWindowContent.game`), minted per load: a new
    /// game is a new window, while a disc swap keeps it.
    let id = UUID()
    @ObservationIgnored unowned let app: EmulatorViewModel
    /// The game plays in a window of its own rather than the library's.
    /// Taken from `gameWindowMode` as it loads, so changing the setting
    /// mid-game moves nothing.
    let inOwnWindow: Bool
    /// Its window should go into full screen as it next shows the game.
    /// Taken with `inOwnWindow`, and taken by the window.
    private(set) var fullScreenPending: Bool

    /// The game, below the user interface. Every action on it is a setter or
    /// a request; nothing here touches its machine. Nil once torn down.
    private(set) var session: (any GameSession)?
    /// The view the session draws into, one per session.
    private(set) var hostView: SessionHostView?

    // Set by the app's load once the session has started.
    var discTitle: String = ""
    /// The discs of the game, and which one is in the drive. Derived from the
    /// launched disc's own DIRECTORY rather than from the tile that was
    /// clicked, so Change Disc also works for a game opened through File ▸
    /// Open Disc… that was never in the library folder.
    ///
    /// Deliberately independent of `mergeMultiDisc`: that setting decides how
    /// the grid looks, and a player who prefers separate tiles has not asked
    /// to lose disc swapping. DuckStation's Change Disc is independent of its
    /// game-list setting for the same reason.
    var currentDiscs: [GameEntry] = []
    var currentDiscIndex: Int?
    /// The BIOS the game booted, for About This Game; nil for an image the
    /// table does not know.
    var biosImage: BiosImage?
    /// The key the game saves under: its first disc's.
    var resumeKey: String?
    /// The disc's serial: what the per-game readbacks choice is filed under.
    var discSerial: String?
    /// The disc's preset, whatever the switch says. Nil for a game the table
    /// does not list.
    var discPgxpPreset: PgxpPreset?

    /// HUD auto-hide lives here rather than in a `@State` on the view: this
    /// is where the behaviour belongs.
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
    /// frame-rate event. The HUD reads it; nothing else does.
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
    /// The pad's status as last sent, which the rumble gate re-drives on its
    /// own: once frames stop the pad sends nothing, and a pause must still
    /// still the motors.
    private(set) var lastPadStatus = PadStatus.idle

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
    static let cardSettleDelay = 1.0

    private var playClock = PlayClock()
    /// Active play banked since the game loaded; the title strip's "Playing
    /// for". A disc swap keeps it: it is still the same sitting.
    private var sessionBanked: TimeInterval = 0
    private var autoSaveClock = AutoSaveClock()
    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveInFlight = false
    /// The machine as it was before the last in-game load, one deep. Undo
    /// loads it, which keeps the machine IT replaced, so a second Undo
    /// returns to the loaded state. Cleared on a disc swap.
    private(set) var undoState: Data?
    /// Bumped by every disc swap. A load captures it when queued: a swap
    /// requested after it (possible while paused) leaves the load's answer
    /// with the other disc in its tray, so it is no undo.
    private var discSwapGeneration = 0

    /// The sheet the app's exit gate raised over this game, and the pause it
    /// hands back on Cancel. Set by the gate.
    var exitPrompt: ExitIntent?
    var pausedBeforePrompt = false

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

    /// The pad as this game sees it, keyboard and controller together.
    private var input = InputMap()

    init(app: EmulatorViewModel, session: (any GameSession)?, hostView: SessionHostView?,
         inOwnWindow: Bool, fullScreen: Bool) {
        self.app = app
        self.session = session
        self.hostView = hostView
        self.inOwnWindow = inOwnWindow
        self.fullScreenPending = inOwnWindow && fullScreen
        if let session { bindEvents(session) }
    }

    // MARK: Pause and the clocks

    /// The pause as last handed to the session, which every new session
    /// starts without.
    private var paused = false

    /// The PLAYER's pause (or a surface's or a sheet's on their behalf).
    /// False once torn down, whatever was last set.
    var isPaused: Bool {
        get { session != nil && paused }
        set {
            paused = newValue
            session?.setPaused(paused || backgrounded)
            updatePlayClock()
        }
    }

    /// Another game's window is in front, so this one sits paused, silent
    /// and deaf. A separate reason from the player's pause, which it never
    /// overwrites: coming forward hands back the pause the game had.
    private(set) var backgrounded = false

    /// What the picture says: paused by the player or waiting in the
    /// background. Either way the big play button is up.
    var showsPaused: Bool { isPaused || (session != nil && backgrounded) }

    /// The play button: clears the player's pause and, for a game waiting
    /// in the background, brings it in the way its window coming forward
    /// does.
    func resume() {
        isPaused = false
        if backgrounded { app.gameWindowBecameKey(id) }
    }

    func setBackgrounded(_ b: Bool) {
        guard b != backgrounded else { return }
        backgrounded = b
        if b {
            // Nothing held stays down behind another game's window.
            releaseAllKeys()
            releaseRewind()
        }
        session?.setPaused(paused || backgrounded)
        updatePlayClock()
    }

    /// The single place the play clock learns anything: every change to
    /// running, paused or app-active calls this, and whatever stretch it ends
    /// is banked under the game's key. Called BEFORE the session goes on
    /// teardown, so the last stretch lands on the game it belongs to.
    func updatePlayClock() {
        let now = ProcessInfo.processInfo.systemUptime
        let banked = playClock.update(running: session != nil, paused: isPaused || backgrounded,
                                      active: app.appActive, at: now)
        if let key = resumeKey { app.playStats.add(banked, to: key) }
        sessionBanked += banked
        autoSaveClock.update(counting: session != nil && !isPaused && !backgrounded && app.appActive,
                             at: now)
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
        let stats = resumeKey.flatMap { app.playStats.stats(for: $0) }
        let played = (stats?.seconds ?? 0) + playClock.elapsed(at: ProcessInfo.processInfo.systemUptime)
        return GameInfo.rows(disc: disc, index: index, count: currentDiscs.count,
                             bios: biosImage, played: played, identityInHeader: identityInHeader)
    }

    /// The pause menu's cover: the game's, which is its first disc's.
    var currentCoverURL: URL? { currentDiscs.first.flatMap(app.covers.coverURL(for:)) }

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
        return Screenshot.size(displayHeight: Int(display.height), scale: app.internalScale, enabled: true)
    }

    /// The window took its full screen (or found it already taken).
    func enteredFullScreen() {
        fullScreenPending = false
    }

    // MARK: Rewind

    func updateRewinding() {
        let held = app.rewindEnabled && (rewindHeldByKey || rewindHeldByPad)
        guard held != isRewinding else { return }
        isRewinding = held
        session?.setRewinding(held)
        rewindSecondsLeft = held ? lastRewindSeconds : 0
    }

    func releaseRewind() {
        rewindHeldByKey = false
        rewindHeldByPad = false
        updateRewinding()
    }

    /// The rewind button moved to another control: the old one's hold goes.
    func rewindPadButtonChanged() {
        rewindHeldByPad = false
        updateRewinding()
    }

    // MARK: Machine actions

    /// Puts a different disc of the game in the drive.
    ///
    /// Everything that can fail is done BEFORE the request is queued, so a
    /// bad rip leaves the game alone rather than opening the tray on a
    /// machine that has nothing to close it on.
    func changeDisc(to entry: GameEntry) {
        guard let session else { return }
        do {
            let kind = DiscKind(entry.url)
            let binData: Data
            let cueData: Data?
            if kind == .cue {
                let image = try EmulatorViewModel.discImage(forCue: entry.url)
                binData = image.bin
                cueData = image.cue
            } else {
                binData = try Data(contentsOf: entry.url)
                cueData = nil
            }
            let disc = DiscBytes(bin: binData, cue: cueData,
                                 sbi: EmulatorViewModel.sidecar(forDisc: entry.url),
                                 ppf: EmulatorViewModel.patch(forDisc: entry.url))
            let serial = entry.identity.serial
            session.requestSwap(disc, readbacks: app.readbacksChoice(serial: serial)) {
                [weak self] error in
                // An answer after an eject is not this game's.
                guard let self, self.session === session else { return }
                guard let error else {
                    // The disc is in: its serial and preset are the running
                    // ones now. The session already holds this choice, so
                    // the push changes nothing there.
                    self.discPgxpPreset = PgxpPreset.lookup(serial: serial)
                    self.discSerial = serial
                    self.app.pushSettings()
                    return
                }
                // A newer swap replaced this one, which is no failure.
                guard error != .superseded else { return }
                self.app.errorMessage = EmulatorViewModel.describe(error)
            }
            closeAllSurfaces()
            // The undo machine had the other disc in its tray.
            undoState = nil
            discSwapGeneration += 1
            currentDiscIndex = currentDiscs.firstIndex { $0.id == entry.id }
            discTitle = entry.title
            if let index = currentDiscIndex { showNotice(NoticeIcon.disc, "Disc \(index + 1) inserted") }
        } catch {
            app.errorMessage = EmulatorViewModel.describe(error)
        }
    }

    /// Through the session, never the machine: the emulator thread may be
    /// mid-frame, and under the recompiler the reset frees the code it is
    /// executing. The session resets between frames.
    func reset() {
        isPaused = false
        guard let session else { return }
        session.requestReset { [weak self] error in
            guard let self, self.session === session, error == nil else { return }
            self.showNotice(NoticeIcon.reset, "Game reset")
        }
    }

    /// A game is running and nothing is in the way of a save or a load.
    var canUseStates: Bool {
        session != nil && !app.isDialogShown && !app.finishingExit && app.resumeFailure == nil
    }

    /// Saves the picture on screen to `~/Pictures/Substation/`, and says
    /// where with a notice that reveals the file.
    func takeScreenshot() {
        guard let session else { return }
        let title = discTitle
        session.requestScreenshot { [weak self] png in
            // Answered after an eject: not this game's.
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

    // MARK: Save states

    func stateInfo(_ source: StateSource) -> SaveStateStore.Info? {
        _ = app.stateRevision      // read it so SwiftUI re-runs this on a change
        guard let resumeKey else { return nil }
        return app.saveStates.info(source, key: resumeKey)
    }

    func saveState(toSlot n: Int) {
        guard canUseStates, let session, let key = resumeKey else { return }
        let store = app.saveStates
        session.requestSave { [weak self] result in
            // Answered after an eject: not this game's.
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
                    self.app.stateWritten()
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
        guard let interval = app.autoSaveInterval,
              autoSaveClock.elapsed(at: now) >= interval,
              canUseStates, !autoSaveInFlight,
              let session, let key = resumeKey else { return }
        autoSaveInFlight = true
        autoSaveClock.restart(at: now)
        let store = app.saveStates
        session.requestSave { [weak self] result in
            // Answered after an eject: this one's resume is the exit's to write.
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
                    self.app.stateWritten()
                }
            }
        }
    }

    func startAutoSave() {
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
        let damaged = EmulatorViewModel.resumeMessage(Ps1Error.stateCorrupt)
        guard let data = app.saveStates.load(source, key: key) else { return showFailure(damaged) }
        let serial: String?
        do { serial = try Ps1Core.peekStateSerial(data) } catch {
            return showFailure(EmulatorViewModel.resumeMessage(error))
        }

        // Saved on another disc of this game: rebuild on that disc, as a
        // launch-time resume does. No undo across that rebuild.
        let inTray = currentDiscIndex.map { currentDiscs[$0] }
        if let serial, serial != inTray?.serial {
            guard let disc = ResumeOffer.disc(forSerial: serial, in: currentDiscs) else {
                return showFailure(EmulatorViewModel.resumeMessage(Ps1Error.stateDisc))
            }
            app.load(disc: disc.url, resume: data, freshBoot: nil) { [weak self] error in
                self?.showFailure(EmulatorViewModel.resumeMessage(error))
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
            // Answered after an eject: not this game's.
            guard let self, self.session === session else { return }
            switch result {
            case .success(let replaced):
                if self.discSwapGeneration == generation { self.undoState = replaced }
                self.autoSaveClock.restart(at: ProcessInfo.processInfo.systemUptime)
                self.showNotice(done)
            case .failure(let error):
                self.showFailure(EmulatorViewModel.resumeMessage(error))
            }
        }
    }

    // MARK: Teardown

    /// Stops the session and releases it.
    ///
    /// `free()` is called explicitly, never left to `deinit`: a completion
    /// still waiting holds the session, so dropping the last reference here
    /// would not stop it. The session is uninstalled FIRST, so an answer
    /// `free()` delivers (`.sessionStopped`) meets the identity guards as an
    /// answer from a game that has gone.
    func teardown() {
        // Its pause goes with it.
        _ = surfaces.closeAll()
        saveStatesNav = nil
        pendingAnalog = nil
        // Banks the session under this game before the session goes.
        isPaused = true
        hideTask?.cancel()
        fpsStaleTask?.cancel()
        fpsStaleTask = nil
        fps = nil
        autoSaveTask?.cancel()
        autoSaveTask = nil
        noticeTask?.cancel()
        notice = nil
        cardSavingTask?.cancel()
        savingToMemoryCard = false
        undoState = nil
        let outgoing = session
        session = nil
        hostView = nil
        outgoing?.free()
        // After the pause above banked the last stretch into the stats.
        sessionBanked = 0
        input.reset()
        rewindHeldByKey = false
        rewindHeldByPad = false
        isRewinding = false
    }

    // MARK: Session events

    /// Every event of the session, while it is this game's: one already on
    /// its way to the main actor after a teardown is dropped.
    private func bindEvents(_ session: any GameSession) {
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.session === session else { return }
            self.sessionEvent(event)
        }
    }

    func sessionEvent(_ event: SessionEvent) {
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
        app.driveHaptics()
    }

    private func memoryCardWritesChanged(_ writes: UInt64) {
        guard writes != lastCardWrites else { return }
        lastCardWrites = writes
        savingToMemoryCard = true
        cardSavingTask?.cancel()
        cardSavingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.cardSettleDelay + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.savingToMemoryCard = false
            self.app.cardWritesSettled(self)
        }
    }

    // MARK: Notices

    func showNotice(_ icon: String, _ text: String, reveal: URL? = nil) {
        showNotice(Notice(icon: icon, text: text, reveal: reveal))
    }

    func showFailure(_ text: String) { showNotice(NoticeIcon.failure, text) }

    /// A setting changed in a game by a key or the menu bar, which shows
    /// nothing else. The pause menu's own row already shows the new value.
    func settingNotice(_ icon: String, _ text: String) {
        guard !isOpen(.pauseMenu) else { return }
        showNotice(icon, text)
    }

    private func showNotice(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: HUD surfaces

    func isOpen(_ surface: HudSurface) -> Bool { surfaces.open.contains(surface) }

    /// Whether a surface holds the game paused: every key and button is then
    /// the surface's.
    var surfacePausesGame: Bool { surfaces.pausesGame }

    /// Opens or closes a HUD surface. One that pauses releases every held
    /// key, button and rewind first, so nothing stays down through the menu.
    func setSurface(_ surface: HudSurface, open: Bool) {
        guard isOpen(surface) != open else { return }
        if surface == .pauseMenu && open {
            menu.open(discCount: currentDiscs.count, insertedDisc: currentDiscIndex ?? 0,
                      pgxpLocked: app.pgxpPresetDecides(\.enabled))
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
        // A game in the background reads as paused, so the press is Play.
        if backgrounded { return resume() }
        guard surfaces.pausesGame else { return isPaused.toggle() }
        closeStateSurfaces()
        isPaused = false
    }

    /// For an eject, a disc swap or an exit prompt: every surface goes, and
    /// with them the pause they held.
    func closeAllSurfaces() {
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
            app.eject(self)
        case .adjust(let setting, let delta): adjust(setting, by: delta)
        case .toggle(.volume): app.toggleMute()
        case .toggle(.pgxp): app.pgxpEnabled.toggle()
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
            app.saveStates.remove(source, key: key)
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
        guard session != nil else { return }
        if isOpen(.saveStates) {
            setSurface(.saveStates, open: false)
        } else if isOpen(.pauseMenu) {
            setSurface(.pauseMenu, open: false)
        } else if !app.isDialogShown {
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
            app.speed = min(max(app.speed + delta, SpeedSetting.choices.lowerBound),
                            SpeedSetting.choices.upperBound)
        case .resolution:
            app.internalScale = min(max(app.internalScale + delta, InternalResolution.range.lowerBound),
                                    InternalResolution.range.upperBound)
        case .pgxp:
            app.pgxpEnabled = delta > 0
        case .analog:
            pendingAnalog = delta > 0
        case .volume:
            app.volume = ((app.volume * 10).rounded() + Double(delta)) / 10
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

    // MARK: Input

    /// A key held across a rebind would be released through its NEW button
    /// and leave the old one stuck down.
    func releaseAllKeys() {
        input.reset()
        session?.setButtons(input.mask)
        session?.setSticks(input.sticks)
    }

    /// `isRepeat` is the system's key repeat: Analog is an event, not a held
    /// state, so a repeat must not toggle it again. Buttons press idempotently.
    func keyDown(_ keyCode: UInt16, isRepeat: Bool = false) -> Bool {
        if surfaces.pausesGame {
            // Every key is the surface's: nothing reaches the paused game.
            if let move = EmulatorViewModel.menuMove(forKey: keyCode) { surfaceMove(move) }
            return true
        }
        if keyCode == UInt16(kVK_Escape) && session != nil {
            setSurface(.pauseMenu, open: true)
            return true
        }
        if keyCode == EmulatorViewModel.fastForwardKey {
            app.setFastForwarding(true)
            return true
        }
        guard let c = app.keyBindings.control(forKey: keyCode) else { return false }
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

    func keyUp(_ keyCode: UInt16) -> Bool {
        if keyCode == EmulatorViewModel.fastForwardKey {
            app.setFastForwarding(false)
            return true
        }
        guard let c = app.keyBindings.control(forKey: keyCode) else { return false }
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
        guard !isPaused, !app.isDialogShown else { return }
        session?.pressAnalog()
    }

    /// One controller report. While a surface holds the game paused, the
    /// report drives the surface by its edges and the game sees the pad let
    /// go; otherwise it is the game's, minus the rewind button.
    func applyPadInput(_ snapshot: InputMap) {
        let moves = padEdges.moves(for: snapshot)
        if surfaces.pausesGame {
            for move in moves { surfaceMove(move) }
            input = InputMap()
            session?.setButtons(input.mask)
            session?.setSticks(input.sticks)
            return
        }
        let pad = app.rewindPadButton
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

    #if DEBUG
    /// Whether the idle timer will hide the HUD, without waiting it out.
    var hidePendingForTesting: Bool { hideTask.map { !$0.isCancelled } ?? false }
    var cardSavingTaskForTesting: Task<Void, Never>? { cardSavingTask }
    var inputMaskForTesting: UInt16 { input.mask }
    var sticksForTesting: Sticks { input.sticks }
    #endif
}

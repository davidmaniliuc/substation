import AppKit
import SwiftUI
import GameController
import UniformTypeIdentifiers

@MainActor
@Observable
public final class EmulatorViewModel {
    enum Stage { case onboarding, library, playing }

    private(set) var stage: Stage = .onboarding
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
    /// `@Observable` model is now a design choice, not a constraint — this is
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

    private(set) var runner: EmulatorRunner?
    private var core: Ps1Core?
    private var ring: AudioRing?
    private var audio: AudioOutput?
    private let bios = BiosLibrary()

    let library = GameLibrary()
    let covers = CoverStore()
    private var coverSourceSetting = CoverSourceSetting()
    private var autoCoverSetting = AutoCoverSetting()
    private var sweepPolicy = CoverSweepPolicy()

    /// One shared pair of cards for the whole library. Outlives every disc,
    /// like `covers` and unlike `runner`.
    let cards = MemoryCardStore()

    /// Bumped whenever a cover is added or removed. The grid keys off it: the
    /// covers live on disk rather than in observable state, so nothing else
    /// would tell SwiftUI that a tile's picture changed.
    private(set) var coverRevision = 0

    private var input = InputMap()

    /// Retained so a future teardown can remove it. It is deliberately NOT
    /// removed in `deinit`: `deinit` on a @MainActor class is nonisolated and
    /// cannot touch isolated state, and the alternatives (`nonisolated` — which
    /// a mutable stored property rejects — or `nonisolated(unsafe)`) buy
    /// nothing here, because this model lives for the whole process.
    private var keyMonitor: Any?

    public init() {
        stage = (bios.folderURL != nil && library.folderURL != nil) ? .library : .onboarding
        observeControllers()
        observeKeyboard()

        // Set here rather than at the declaration because it captures self.
        // `GameLibrary.init` may already have started a scan, but that scan
        // publishes from inside a Task and so cannot have finished before this
        // initializer returns — the first scan is covered.
        library.didFinishScan = { [weak self] in self?.autoDownloadCoversIfEnabled() }

        // ⌘Q does not go through eject(), so the pending write would be lost
        // with the process. Tearing the machine down is what flushes it, and
        // it is synchronous — a Task here would not be scheduled before exit.
        //
        // `queue: nil` is DOCUMENTED to run the block synchronously on the
        // posting thread, which is the guarantee this needs and what
        // `MainActor.assumeIsolated` below presumes. `queue: .main` looked
        // equivalent — NotificationCenter runs the block inline for a non-nil
        // queue when it equals `OperationQueue.current`, which holds today
        // because the notification is posted from the main run loop — but
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
    }


    public var isPaused: Bool {
        get { runner?.isPaused ?? false }
        set { runner?.isPaused = newValue }
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

    /// Where the dither pattern is sampled, persisted — the same computed seam
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

    /// PGXP geometry correction, persisted — the same computed seam over a
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
            runner?.setPgxp(newValue)
        }
    }

    /// The four sub-settings, each the same computed seam over the same stored
    /// struct. They need no `.id()` rebuild either, and for the same reason:
    /// all four change the CONTENTS of the command stream, never the size or
    /// format of a texture.
    public var pgxpCpu: Bool {
        get { pgxpSetting.cpu }
        set {
            pgxpSetting.setCpu(newValue)
            runner?.setPgxpCpu(newValue)
        }
    }

    public var pgxpCulling: Bool {
        get { pgxpSetting.culling }
        set {
            pgxpSetting.setCulling(newValue)
            runner?.setPgxpCulling(newValue)
        }
    }

    public var pgxpVertexCache: Bool {
        get { pgxpSetting.vertexCache }
        set {
            pgxpSetting.setVertexCache(newValue)
            runner?.setPgxpVertexCache(newValue)
        }
    }

    public var pgxpTolerance: Float {
        get { pgxpSetting.tolerance }
        set {
            pgxpSetting.setTolerance(newValue)
            runner?.setPgxpTolerance(newValue)
        }
    }

    /// Whether a multi-disc game shows as one tile — the same computed seam
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

    /// Output volume, 0...1 plus a mute flag, persisted — the same computed
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
            errorMessage = "This BIOS folder works for now, but could not be remembered — choose it again next launch."
        }
    }

    public func chooseGamesFolder() {
        guard let url = Self.chooseFolder(
            message: "Choose the folder holding your games. Subfolders are scanned too."
        ) else { return }
        do {
            try library.setFolder(url)
        } catch {
            errorMessage = "This games folder works for now, but could not be remembered — choose it again next launch."
        }
    }

    /// Forwards to `library.rescan()`. `GameLibrary` itself is `internal`, so
    /// this is the one seam File ▸ Refresh Library calls; `public` follows the
    /// same app-facing-surface convention as `isPaused`, not a module
    /// boundary — `Sources/PS1App` compiles into this same `PS1` module.
    public func rescanLibrary() { library.rescan() }

    /// Onboarding's Continue. Guarded rather than trusted: the button is
    /// disabled until both folders are set, but the stage is the thing the
    /// rest of the app branches on, so it checks for itself.
    func finishOnboarding() {
        guard hasBIOSFolder, library.folderURL != nil else { return }
        stage = .library
    }

    func play(_ entry: GameEntry) {
        load(disc: entry.url)
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

    var coverSource: CoverSource {
        get { coverSourceSetting.source }
        set { coverSourceSetting.set(newValue) }
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
        coverDownloadSummary = parts.joined(separator: ", ") + "."
    }

    /// Shown in the library, not as a modal: the result of a sweep is
    /// information, and the grid has already redrawn with the new covers.
    var coverDownloadSummary: String?

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
        panel.message = "Open a .cue (preferred) or a raw .bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(disc: url)
    }

    /// The one spelling of a path that two different producers agree on.
    ///
    /// `GameScanner`'s URLs come out of `FileManager`'s enumerator; a disc
    /// opened through `NSOpenPanel` does not. On macOS `/tmp` and `/var` are
    /// symlinks into `/private`, so the two name the same file differently and
    /// matching on `GameEntry.id` — which is the raw path — silently finds
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
        return group?.discs
            ?? [GameEntry(url: url, isCue: url.pathExtension.lowercased() == "cue")]
    }

    /// Puts a different disc of the running game in the drive.
    ///
    /// Everything that can fail is done BEFORE the request is queued, so a
    /// bad rip leaves the running game alone rather than opening the tray on
    /// a machine that has nothing to close it on.
    func changeDisc(to entry: GameEntry) {
        guard let runner else { return }
        do {
            let isCue = entry.url.pathExtension.lowercased() == "cue"
            let binData: Data
            let cueData: Data?
            if isCue {
                let image = try Self.discImage(forCue: entry.url)
                binData = image.bin
                cueData = image.cue
            } else {
                binData = try Data(contentsOf: entry.url)
                cueData = nil
            }
            runner.requestDiscSwap(bin: binData, cue: cueData,
                                   sbi: Self.sidecar(forDisc: entry.url))
            currentDiscIndex = currentDiscs.firstIndex { $0.id == entry.id }
            discTitle = entry.title
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func load(disc url: URL) {
        // Set the instant the outgoing machine is torn down and the new one
        // is installed — the point past which a failure can no longer leave
        // the OLD game untouched, only the new one half-built. See the catch
        // block below.
        var installedReplacement = false
        do {
            let isCue = url.pathExtension.lowercased() == "cue"
            let binData: Data
            let cueData: Data?
            if isCue {
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
            let biosData = try bios.biosData(forDisc: url.lastPathComponent,
                                             identity: DiscIdentity.identify(image: binData))

            let core = try Ps1Core()
            try core.loadBIOS(biosData)
            try core.loadDisc(bin: binData, cue: cueData, sbi: Self.sidecar(forDisc: url))

            let ring = AudioRing(capacity: 1 << 15)
            let runner = EmulatorRunner(core: core, ring: ring, cards: cards)
            let audio = try AudioOutput(ring: ring, runner: runner)

            // Every throwing step above has already succeeded, so the new
            // machine is fully built and ready to take over. Only NOW is it
            // safe to tear down whatever was already running — opening a
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
            // to load leaves the running game alone — but the card cannot
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
            // Re-applied per game for the same reason the gain is: the runner
            // is rebuilt with every disc while the setting outlives them all.
            runner.setPgxp(pgxpSetting.enabled)
            // All five, for the same reason: the runner is rebuilt with every
            // disc while the settings outlive them all. Re-applying only the
            // master would leave a player's sub-settings behind on disc two.
            runner.setPgxpCpu(pgxpSetting.cpu)
            runner.setPgxpCulling(pgxpSetting.culling)
            runner.setPgxpVertexCache(pgxpSetting.vertexCache)
            runner.setPgxpTolerance(pgxpSetting.tolerance)
            runner.start()
            try audio.start()
            startSamplingFps()

            discTitle = url.deletingPathExtension().lastPathComponent
            currentDiscs = Self.siblingDiscs(of: url, entries: library.entries)
            currentDiscIndex = currentDiscs.firstIndex {
                Self.canonicalPath($0.url) == Self.canonicalPath(url)
            }
            stage = .playing
            // A raw .bin cannot represent audio tracks, so a CD-DA title opened
            // this way is silent — which looks like a bug unless we say so.
            showRawBinWarning = !isCue
        } catch {
            if installedReplacement {
                // `runner.start()` — and possibly `audio.start()` — already ran
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

    public func reset() {
        runner?.isPaused = false
        core?.reset()
        // ps1_reset rebuilds Bus, clearing software VRAM, while the GPU
        // texture still holds the old picture. Nothing is queued at this
        // instant, so the flag is the only thing that carries the news.
        //
        // NOTE: core.reset() is called from the main actor while the emulator
        // thread may be mid-frame. That race predates this phase and is not
        // widened here; routing the reset itself through the runner is where
        // it gets closed. It is also no longer safe to reason about a PAUSED
        // emulator thread as one that leaves the core alone: since
        // `EmulatorRunner.serviceMemoryCards()` sits above `runLoop`'s paused
        // early-out, that thread now calls into the core on every paused
        // iteration (~20 Hz) to poll for a dirty card, where a paused loop
        // used to touch the core not at all.
        runner?.requestResync()
    }

    public func eject() {
        teardownRunningMachine()
        currentDiscs = []
        currentDiscIndex = nil
        stage = .library
    }

    /// Stops whatever emulator instance is currently installed and releases
    /// its resources, but does not touch `stage` — `eject()` sets it to
    /// `.library` afterwards, and `load(disc:)` sets it to `.playing` once
    /// the replacement is installed, so this is shared by both without
    /// either one fighting the other's stage transition.
    ///
    /// `audio.stop()` runs BEFORE `runner.stop()` on purpose: `AudioOutput`
    /// holds an `unowned` (non-retaining) reference to its `EmulatorRunner`,
    /// so its real-time render callback must stop touching the runner before
    /// `runner.stop()` joins the emulator thread and drops the runner's last
    /// strong reference — reversing the order risks the callback firing into
    /// a runner that is mid-teardown.
    private func teardownRunningMachine() {
        fpsTask?.cancel()
        fpsTask = nil
        fps = nil
        audio?.stop()
        runner?.stop()
        audio = nil
        runner = nil
        core = nil
        ring = nil
        discTitle = ""
        // A key held across the transition would otherwise survive it: the
        // stage gate on keyUp (below) stops a release from reaching a game
        // that no longer exists, so without this the bit it set stays
        // latched into the NEXT game's first setButtons call.
        input.reset()
    }

    /// Polls the runner's cumulative frame count on a fixed cadence, rather
    /// than being driven from the emulator thread: the count is an atomic, so
    /// a poll costs a load, and nothing on the audio-paced thread has to reach
    /// the main actor once a frame just to move a number on screen.
    ///
    /// It samples whether or not the OSD is showing. Two wakeups a second is
    /// not worth coupling the sampler to `hudVisible` — and a counter started
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
    /// change of position counts as a move — which is also the exact rule the
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
    func simulatePlayingForTesting() { stage = .playing }

    var inputMaskForTesting: UInt16 { input.mask }

    /// Drives the exact code path `bind(_:)`'s `valueChangedHandler` drives,
    /// without needing a real `GCExtendedGamepad` — see `applyPadInput`.
    func simulatePadInputForTesting(_ snapshot: InputMap) { applyPadInput(snapshot) }
    #endif

    // MARK: Input

    func keyDown(_ keyCode: UInt16) -> Bool {
        guard stage == .playing, let b = InputMap.button(forKey: keyCode) else { return false }
        input.press(b)
        runner?.setButtons(input.mask)
        return true
    }

    func keyUp(_ keyCode: UInt16) -> Bool {
        guard stage == .playing, let b = InputMap.button(forKey: keyCode) else { return false }
        input.release(b)
        runner?.setButtons(input.mask)
        return true
    }

    /// A connect notification is used only as a TRIGGER to rescan, never as a
    /// carrier: `Notification` and `GCExtendedGamepad` are both non-Sendable,
    /// so pulling the pad out of the notification and handing it to the main
    /// actor is a data race the Swift 6 compiler rejects outright. Rescanning
    /// also collapses the connect path and the launch path into one.
    /// Keyboard comes through an NSEvent monitor rather than SwiftUI's
    /// `onKeyPress`, because that hands back a `KeyEquivalent` (a Character)
    /// and `InputMap.button(forKey:)` is keyed on macOS VIRTUAL KEY CODES —
    /// which are layout-independent, so the D-pad stays on the same physical
    /// keys on an AZERTY or Dvorak layout.
    private func observeKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Only the code crosses the boundary; NSEvent is not Sendable.
            let code = event.keyCode
            let isDown = event.type == .keyDown
            let handled = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self else { return false }
                // The app is unsandboxed, so this monitor sees events bound
                // for an NSOpenPanel's own sheet too — its sidebar, its text
                // field. Declining to handle anything while one is up lets
                // those events fall through to the panel instead of being
                // eaten as game input (arrows dead in the sidebar, Return not
                // confirming, typed letters silently dropped).
                guard NSApp.modalWindow == nil else { return false }
                return isDown ? self.keyDown(code) : self.keyUp(code)
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
        bindConnectedControllers()
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

            let snapshot = m
            MainActor.assumeIsolated {
                self?.applyPadInput(snapshot)
            }
        }
    }

    /// Shared by the real `GCExtendedGamepad` handler above and, in DEBUG
    /// only, `simulatePadInputForTesting` below — a real gamepad can't be
    /// synthesised in a test, so the seam calls this exact method to keep the
    /// stage gate itself under test.
    ///
    /// The gate mirrors `keyDown`/`keyUp`: without it, a button held on a pad
    /// across an eject survives — `teardownRunningMachine()` resets `input`,
    /// but the handler still fires on every value change, so the next report
    /// of the still-held button overwrites `input` again before the next game
    /// even starts.
    private func applyPadInput(_ snapshot: InputMap) {
        guard stage == .playing else { return }
        input = snapshot
        runner?.setButtons(snapshot.mask)
    }

    // MARK: Helpers

    /// Reads the images a cue references, in cue order, as the single slice the
    /// core takes — plus the cue text that says where they were joined.
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
    /// Much of Sony Europe's own PAL catalogue — Final Fantasy IX among it —
    /// hides a key in the subchannel Q of a few dozen sectors. No .bin or .cue
    /// can carry it, so without the sidecar the protection check never passes
    /// and the game sits behind a black screen sweeping those sectors forever.
    ///
    /// Matched on the stem alone, never on "the only .sbi in the directory":
    /// FF9's four discs share a folder and each sidecar names sectors of its
    /// own image, so the wrong one is worth exactly as much as no sidecar.
    /// A missing one is the ordinary case and is not an error — the sidecar is
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
        case Ps1Error.badSBI:         return "The .sbi file beside this disc is not a LibCrypt sidecar. Remove it, or replace it with the one that shipped with this rip — the game will not get past its copy protection without a valid one."
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

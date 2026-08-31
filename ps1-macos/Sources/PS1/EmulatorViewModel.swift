import SwiftUI
import GameController
import UniformTypeIdentifiers

@MainActor
@Observable
public final class EmulatorViewModel {
    enum Stage { case onboarding, library, playing }

    private(set) var stage: Stage = .onboarding
    private(set) var discTitle: String = ""
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
            let biosData = try bios.biosData(forDisc: url.lastPathComponent)

            let core = try Ps1Core()
            try core.loadBIOS(biosData)
            try core.loadDisc(bin: binData, cue: cueData)

            let ring = AudioRing(capacity: 1 << 15)
            let runner = EmulatorRunner(core: core, ring: ring)
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

            audio.setGain(volumeSetting.gain)
            // Re-applied per game for the same reason the gain is: the runner
            // is rebuilt with every disc while the setting outlives them all.
            runner.setPgxp(pgxpSetting.enabled)
            runner.start()
            try audio.start()
            startSamplingFps()

            discTitle = url.deletingPathExtension().lastPathComponent
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
        // it gets closed.
        runner?.requestResync()
    }

    public func eject() {
        teardownRunningMachine()
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
        // Split on `isNewline`, NOT on "\n": every cue a ripper writes is CRLF,
        // and Swift folds "\r\n" into ONE Character that does not equal "\n" —
        // so splitting on the scalar returns the whole file as a single line.
        // The FILE match then still succeeds against it, and `lastIndex(of:)`
        // picks the closing quote of the LAST FILE in the sheet, which is a
        // filename for nothing. A one-FILE cue holds exactly two quotes and so
        // survived it by accident; a per-track rip did not.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.uppercased().hasPrefix("FILE "),
               let open = line.firstIndex(of: "\""),
               let close = line.lastIndex(of: "\""), open < close {
                let name = String(line[line.index(after: open)..<close])
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

    private static func describe(_ error: Error) -> String {
        switch error {
        case Ps1Error.badBIOSSize:    return "That BIOS file is not 512 KB. PlayStation BIOS images are exactly 524,288 bytes."
        case Ps1Error.multiFileCue:   return "This cue sheet splits its tracks across several files, and the sizes needed to lay them out are missing. The rip may be incomplete."
        case Ps1Error.badCue:         return "That cue sheet could not be parsed."
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

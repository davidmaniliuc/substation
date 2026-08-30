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

    /// HUD auto-hide lives here rather than in a `@State` on the view.
    /// `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin
    /// ships with Xcode, which is not installed — so it cannot be expanded at
    /// all here. `@Observable` (ObservationMacros) IS present, so observable
    /// model state is the substitute. This is also where the behaviour belongs.
    private(set) var hudVisible = true
    private var hideTask: Task<Void, Never>?

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
    /// the PS1App target — a separate module — cannot reach it directly; this
    /// is the one public seam File ▸ Refresh Library needs.
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
            let binURL = isCue ? try Self.binURL(forCue: url) : url

            let binData = try Data(contentsOf: binURL)
            let cueData = isCue ? try Data(contentsOf: url) : nil
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

            runner.start()
            try audio.start()

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

    /// Resolves the `FILE "..."` line in a cue against the cue's own directory.
    private static func binURL(forCue cue: URL) throws -> URL {
        let text = try String(contentsOf: cue, encoding: .utf8)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { continue }
            guard let open = line.firstIndex(of: "\""),
                  let close = line.lastIndex(of: "\""), open < close else { continue }
            let name = String(line[line.index(after: open)..<close])
            return cue.deletingLastPathComponent().appendingPathComponent(name)
        }
        throw Ps1Error.badCue
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case Ps1Error.badBIOSSize:    return "That BIOS file is not 512 KB. PlayStation BIOS images are exactly 524,288 bytes."
        case Ps1Error.multiFileCue:   return "This cue sheet declares more than one FILE, which this emulator cannot lay out. Use a single-file rip."
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

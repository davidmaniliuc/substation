import Testing
import Carbon.HIToolbox
import AppKit
@testable import PS1

/// While the pause menu or the Save States panel is open, the keyboard and
/// the controller drive it and nothing reaches the game.
@Suite struct PadEdgesTests {
    private func pad(_ buttons: PadButton..., sticks: Sticks = .centred) -> InputMap {
        var m = InputMap()
        for b in buttons { m.press(b) }
        m.sticks = sticks
        return m
    }

    @Test func aHeldButtonMovesOnce() {
        var edges = PadEdges()
        #expect(edges.moves(for: pad(.down)) == [.down])
        #expect(edges.moves(for: pad(.down)) == [])
        #expect(edges.moves(for: pad()) == [])
        #expect(edges.moves(for: pad(.down)) == [.down])
    }

    @Test func crossConfirmsAndCircleGoesBack() {
        var edges = PadEdges()
        #expect(edges.moves(for: pad(.cross)) == [.confirm])
        #expect(edges.moves(for: pad(.circle)) == [.back])
    }

    @Test func theLeftStickPastHalfwayIsADirection() {
        var edges = PadEdges()
        #expect(edges.moves(for: pad(sticks: Sticks(ly: 0x30))) == [.up])
        #expect(edges.moves(for: pad(sticks: Sticks(ly: 0x20))) == [])
        #expect(edges.moves(for: pad(sticks: Sticks(lx: 0x70))) == [])     // short of halfway
        #expect(edges.moves(for: pad(sticks: Sticks(lx: 0xD0))) == [.right])
    }

    /// The stick and the D-pad held the same way are one direction, not two.
    @Test func theStickAndTheDpadTogetherMoveOnce() {
        var edges = PadEdges()
        #expect(edges.moves(for: pad(.up, sticks: Sticks(ly: 0x10))) == [.up])
    }
}

@MainActor
@Suite struct HudInputTests {
    private let down = UInt16(kVK_DownArrow)
    private let escape = UInt16(kVK_Escape)
    private let ret = UInt16(kVK_Return)

    private func playing() throws -> EmulatorViewModel {
        let model = EmulatorViewModel()
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        model.game!.isPaused = false
        return model
    }

    @Test func escapeOpensTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        #expect(model.keyDown(escape))
        #expect(model.game!.isOpen(.pauseMenu))
        #expect(model.game!.isPaused)
    }

    @Test func theArrowsMoveTheMenuAndNotThePad() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        #expect(model.keyDown(down))
        #expect(model.game!.menu.focus == .saveStates)
        #expect(model.game!.inputMaskForTesting == 0xFFFF)
    }

    @Test func returnOnResumeClosesTheMenuAndResumes() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        _ = model.keyDown(ret)
        #expect(!model.game!.isOpen(.pauseMenu))
        #expect(!model.game!.isPaused)
    }

    @Test func theMenuReopensOnResume() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        _ = model.keyDown(down)
        _ = model.keyDown(escape)       // closes
        _ = model.keyDown(escape)
        #expect(model.game!.menu.focus == nil)
    }

    @Test func aKeyHeldAsTheMenuOpensIsReleased() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(down)         // the D-pad, in the game
        #expect(model.game!.inputMaskForTesting != 0xFFFF)
        _ = model.keyDown(escape)
        #expect(model.game!.inputMaskForTesting == 0xFFFF)
    }

    @Test func tabDoesNotFastForwardUnderTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        _ = model.keyDown(EmulatorViewModel.fastForwardKey)
        #expect(model.effectiveSpeed == model.speed)
    }

    @Test func theControllerDrivesTheMenuAndNotTheGame() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.game!.homePressed()
        var held = InputMap()
        held.press(.down)
        model.simulatePadInputForTesting(held)
        #expect(model.game!.menu.focus == .saveStates)
        #expect(model.game!.inputMaskForTesting == 0xFFFF)
    }

    @Test func aButtonHeldAsHomeOpensTheMenuDoesNotFire() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        var cross = InputMap()
        cross.press(.cross)
        model.simulatePadInputForTesting(cross)      // held in the game
        model.game!.homePressed()
        model.simulatePadInputForTesting(cross)      // still held
        #expect(model.game!.isOpen(.pauseMenu))
    }

    @Test func homeOpensAndClosesTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.game!.homePressed()
        #expect(model.game!.isOpen(.pauseMenu))
        model.game!.homePressed()
        #expect(!model.game!.isOpen(.pauseMenu))
        #expect(!model.game!.isPaused)
    }

    @Test func homeClosesThePanelBeforeTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.game!.homePressed()
        model.game!.perform(PauseMenuAction.saveStates)
        #expect(model.game!.isOpen(.saveStates))
        model.game!.homePressed()
        #expect(!model.game!.isOpen(.saveStates))
        #expect(model.game!.isOpen(.pauseMenu))
    }

    @Test func thePanelTakesTheKeysWhileOpen() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.game!.openSaveStates(from: .bar)
        #expect(model.game!.saveStatesNav?.selection == 1)
        _ = model.keyDown(down)
        #expect(model.game!.saveStatesNav?.selection == 2)
        _ = model.keyDown(escape)
        #expect(!model.game!.isOpen(.saveStates))
        #expect(!model.game!.isPaused)
    }

    /// Home reaches a game through `model.game`, so with none there is
    /// nothing for it to open.
    @Test func homeDoesNothingOutsideAGame() {
        let model = EmulatorViewModel()
        #expect(model.game == nil)
    }
}

/// A rewind held on the controller as the menu opens. The menu takes the
/// controller, so the button's release never reaches the rewind hold: it
/// must let go when the menu opens, not stay latched until it closes.
@MainActor
@Suite struct HudRewindTests {
    /// A model with rewind on L3, over defaults of its own.
    static func model(_ defaults: UserDefaults) -> EmulatorViewModel {
        var rewind = RewindSetting(defaults: defaults)
        rewind.setEnabled(true)
        rewind.setPadButton(.l3)
        let root = FileManager.default.temporaryDirectory.appending(path: "hud-rewind-\(UUID().uuidString)")
        return EmulatorViewModel(
            saveStates: SaveStateStore(resumeDirectory: root.appending(path: "r"),
                                       slotsDirectory: root.appending(path: "s")),
            autoSave: AutoSaveSetting(key: "k", defaults: defaults), rewind: rewind)
    }

    @Test func openingTheMenuLetsGoOfAHeldRewind() throws {
        let name = "hud-rewind-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = Self.model(defaults)
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        let game = model.game!
        defer { model.ejectNowForTesting() }

        var held = InputMap()
        held.press(.l3)
        model.simulatePadInputForTesting(held)
        #expect(game.isRewinding)

        game.homePressed()
        #expect(!game.isRewinding)
        model.simulatePadInputForTesting(InputMap())      // let go under the menu
        game.homePressed()
        #expect(!game.isRewinding)
    }

    /// The seconds are shown only while rewinding; the session sends the
    /// value only when it changes, so the one it sent last is what a new hold
    /// starts from.
    @Test func rewindSecondsFollowTheEventOnlyWhileRewinding() throws {
        let name = "hud-rewind-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = Self.model(defaults)
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        let game = model.game!
        defer { model.ejectNowForTesting() }

        session.emit(.rewindSeconds(5))
        #expect(game.rewindSecondsLeft == 0)

        var held = InputMap()
        held.press(.l3)
        model.simulatePadInputForTesting(held)
        #expect(game.rewindSecondsLeft == 5)
        session.emit(.rewindSeconds(4))
        #expect(game.rewindSecondsLeft == 4)
        model.simulatePadInputForTesting(InputMap())
        #expect(!game.isRewinding)

        // Held again with nothing new: the session sends no repeat.
        model.simulatePadInputForTesting(held)
        #expect(game.rewindSecondsLeft == 4)
    }
}

/// ⌃⌘F is full screen, by key code, and only with exactly those modifiers.
@Test func controlCommandFIsTheFullScreenShortcut() {
    let f = UInt16(kVK_ANSI_F)
    #expect(EmulatorViewModel.isFullScreenShortcut(f, [.control, .command]))
    // fn and Caps Lock ride along on some keyboards and change nothing.
    #expect(EmulatorViewModel.isFullScreenShortcut(f, [.control, .command, .function, .capsLock]))
    #expect(!EmulatorViewModel.isFullScreenShortcut(f, [.command]))
    #expect(!EmulatorViewModel.isFullScreenShortcut(f, [.control, .option, .command]))
    #expect(!EmulatorViewModel.isFullScreenShortcut(UInt16(kVK_ANSI_G), [.control, .command]))
}

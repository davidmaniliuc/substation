import Testing
import Carbon.HIToolbox
import Foundation
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
        let core = try Ps1Core()
        try core.loadBIOS(Data(repeating: 0, count: 524288))
        model.installRunnerForTesting(
            EmulatorRunner(core: core, ring: AudioRing(capacity: EmulatorRunner.ringCapacity),
                           cards: MemoryCardStore(directory: FileManager.default.temporaryDirectory
                               .appendingPathComponent("hud-input-\(UUID().uuidString)"))),
            resumeKey: nil)
        model.isPaused = false
        return model
    }

    @Test func escapeOpensTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        #expect(model.keyDown(escape))
        #expect(model.isOpen(.pauseMenu))
        #expect(model.isPaused)
    }

    @Test func theArrowsMoveTheMenuAndNotThePad() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        #expect(model.keyDown(down))
        #expect(model.menu.selection == 1)
        #expect(model.inputMaskForTesting == 0xFFFF)
    }

    @Test func returnOnResumeClosesTheMenuAndResumes() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        _ = model.keyDown(ret)
        #expect(!model.isOpen(.pauseMenu))
        #expect(!model.isPaused)
    }

    @Test func theMenuReopensOnResume() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(escape)
        _ = model.keyDown(down)
        _ = model.keyDown(escape)       // back at the root closes
        _ = model.keyDown(escape)
        #expect(model.menu.selection == 0)
    }

    @Test func aKeyHeldAsTheMenuOpensIsReleased() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        _ = model.keyDown(down)         // the D-pad, in the game
        #expect(model.inputMaskForTesting != 0xFFFF)
        _ = model.keyDown(escape)
        #expect(model.inputMaskForTesting == 0xFFFF)
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
        model.homePressed()
        var held = InputMap()
        held.press(.down)
        model.simulatePadInputForTesting(held)
        #expect(model.menu.selection == 1)
        #expect(model.inputMaskForTesting == 0xFFFF)
    }

    @Test func aButtonHeldAsHomeOpensTheMenuDoesNotFire() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        var cross = InputMap()
        cross.press(.cross)
        model.simulatePadInputForTesting(cross)      // held in the game
        model.homePressed()
        model.simulatePadInputForTesting(cross)      // still held
        #expect(model.isOpen(.pauseMenu))
    }

    @Test func homeOpensAndClosesTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.homePressed()
        #expect(model.isOpen(.pauseMenu))
        model.homePressed()
        #expect(!model.isOpen(.pauseMenu))
        #expect(!model.isPaused)
    }

    @Test func homeClosesThePanelBeforeTheMenu() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.homePressed()
        model.perform(PauseMenuAction.saveStates(.menuLoad))
        #expect(model.isOpen(.saveStates))
        model.homePressed()
        #expect(!model.isOpen(.saveStates))
        #expect(model.isOpen(.pauseMenu))
    }

    @Test func thePanelTakesTheKeysWhileOpen() throws {
        let model = try playing()
        defer { model.ejectNowForTesting() }
        model.openSaveStates(from: .bar)
        #expect(model.saveStatesNav?.selection == 1)
        _ = model.keyDown(down)
        #expect(model.saveStatesNav?.selection == 4)
        _ = model.keyDown(escape)
        #expect(!model.isOpen(.saveStates))
        #expect(!model.isPaused)
    }

    @Test func homeDoesNothingOutsideAGame() {
        let model = EmulatorViewModel()
        model.homePressed()
        #expect(!model.isOpen(.pauseMenu))
    }
}

import Carbon.HIToolbox
import Foundation
import Testing
@testable import PS1

@MainActor
@Suite struct Port2AndGamepadTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "port2-gamepad-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    private func makeModel(defaults: UserDefaults, rewindEnabled: Bool = false) -> EmulatorViewModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "port2-test-\(UUID().uuidString)")
        var rewind = RewindSetting(defaults: defaults)
        rewind.setEnabled(rewindEnabled)
        rewind.setPadButton(.none)
        return EmulatorViewModel(
            saveStates: SaveStateStore(resumeDirectory: root.appending(path: "r"),
                                       slotsDirectory: root.appending(path: "s")),
            autoSave: AutoSaveSetting(key: "auto", defaults: defaults),
            rewind: rewind,
            gameWindow: GameWindowSetting(key: "gw", defaults: defaults),
            gamepadBindings: GamepadBindings(storageKey: "gp", defaults: defaults),
            controllerAssignment: ControllerAssignment(defaults: defaults))
    }

    private func controllers(_ count: Int) -> [ConnectedController] {
        ConnectedController.list(from: (1...count).map { ("c\($0)", "DualSense") })
    }

    @Test func port2ConnectsAndDisconnectsInSessionWithControllerRouting() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults)
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        defer { model.ejectNowForTesting() }

        #expect(!model.port2Connected)
        #expect(!session.calls.contains("setPortConnected(1, true)"))

        // Plugging in a second controller connects Port 2 automatically.
        model.simulateConnectedControllersForTesting(controllers(2))
        #expect(model.port2Connected)
        #expect(session.calls.contains("setPortConnected(1, true)"))

        // Explicitly disabling Port 2 unplugs it.
        model.port2ControllerChoice = .off
        #expect(!model.port2Connected)
        #expect(session.calls.contains("setPortConnected(1, false)"))

        // Re-enabling Automatic with Keyboard Only on Port 1 and 1 controller connects Port 2.
        model.port2ControllerChoice = .automatic
        model.simulateConnectedControllersForTesting(controllers(1))
        #expect(!model.port2Connected)
        model.port1ControllerChoice = .keyboardOnly
        #expect(model.port2Connected)
        #expect(session.calls.filter { $0 == "setPortConnected(1, true)" }.count == 2)
    }

    @Test func twoControllersRouteIndependentlyToPort1AndPort2() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults)
        let session = ScriptedSession()
        model.simulateConnectedControllersForTesting(controllers(2))
        model.installSessionForTesting(session, resumeKey: nil)
        defer { model.ejectNowForTesting() }

        // Port 2 was already connected before launch, so install notifies the session.
        #expect(session.calls.contains("setPortConnected(1, true)"))

        let p1Snap = GamepadSnapshot(pressed: [.buttonA], sticks: Sticks(lx: 0x10, ly: 0x20, rx: 0x80, ry: 0x80))
        let p2Snap = GamepadSnapshot(pressed: [.buttonB, .leftShoulder],
                                     sticks: Sticks(lx: 0xD0, ly: 0xE0, rx: 0x40, ry: 0x50))

        model.simulateGamepadSnapshotForTesting(p1Snap, from: "c1")
        model.simulateGamepadSnapshotForTesting(p2Snap, from: "c2")

        let game = model.game!
        #expect(game.inputMaskForTesting(port: 0) == (0xFFFF & ~PadButton.cross.rawValue))
        #expect(game.sticksForTesting(port: 0) == p1Snap.sticks)

        let expectedP2Mask: UInt16 = 0xFFFF & ~(PadButton.circle.rawValue | PadButton.l1.rawValue)
        #expect(game.inputMaskForTesting(port: 1) == expectedP2Mask)
        #expect(game.sticksForTesting(port: 1) == p2Snap.sticks)
        #expect(session.calls.contains("setPortButtons(1, \(expectedP2Mask))"))
        #expect(session.calls.contains("setPortSticks(1, 208, 224, 64, 80)"))
    }

    @Test func pinningPort1ToControllerStopsKeyboardDrivingPort1() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults)
        model.simulateConnectedControllersForTesting(controllers(1))
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        defer { model.ejectNowForTesting() }

        // Default Automatic: keyboard drives Port 1.
        #expect(model.keyDown(UInt16(kVK_UpArrow)))
        #expect(model.game!.inputMaskForTesting(port: 0) & PadButton.up.rawValue == 0)

        // Pinning Port 1 to the controller releases the held key and stops keyboard pad input.
        model.port1ControllerChoice = .controller("c1")
        #expect(model.game!.inputMaskForTesting(port: 0) == 0xFFFF)
        #expect(!model.keyDown(UInt16(kVK_UpArrow)))
        #expect(model.game!.inputMaskForTesting(port: 0) == 0xFFFF)
    }

    @Test func port2PadEventsRaisePort2NoticeAndDriveHapticsIndependently() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults)
        let wasVibration = model.vibration
        defer { model.vibration = wasVibration }
        model.vibration = true
        model.simulateAppActiveForTesting(true)
        model.simulateConnectedControllersForTesting(controllers(2))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        defer { model.ejectNowForTesting() }

        session.emit(.pad(PadStatus(analog: false, small: 0, large: 0x80)))
        session.emit(.pad2(PadStatus(analog: true, small: 255, large: 0xFF)))

        #expect(model.game!.notice?.text == "Port 2: Analog on")
        #expect(model.hapticsDriveForTesting(port: 0) == MotorDrive(large: Float(0x80) / 255, small: false))
        #expect(model.hapticsDriveForTesting(port: 1) == MotorDrive(large: 1, small: true))

        session.emit(.pad2(PadStatus(analog: false, small: 0, large: 0xFF)))
        #expect(model.game!.notice?.text == "Port 2: Analog off")

        // Disconnecting Port 2 stills Port 2's motors while keeping Port 1's active.
        model.port2ControllerChoice = .off
        #expect(model.hapticsDriveForTesting(port: 1) == .stopped)
        #expect(model.hapticsDriveForTesting(port: 0) == MotorDrive(large: Float(0x80) / 255, small: false))
    }

    @Test func remappedGamepadButtonsAnalogAndRewindWorkLive() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults, rewindEnabled: true)
        model.simulateConnectedControllersForTesting(controllers(2))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        defer { model.ejectNowForTesting() }

        // Remap Cross to buttonY, Analog to rightThumbstickButton, Rewind to buttonOptions.
        model.beginGamepadCapture(.button(.cross))
        #expect(model.captureGamepadInput(.buttonY))
        model.beginGamepadCapture(.analog)
        #expect(model.captureGamepadInput(.rightThumbstickButton))
        model.beginGamepadCapture(.rewind)
        #expect(model.captureGamepadInput(.buttonOptions))

        // Port 1 presses Y (mapped to Cross) + R3 (mapped to Analog) + Options (mapped to Rewind).
        let snap1 = GamepadSnapshot(pressed: [.buttonY, .rightThumbstickButton, .buttonOptions])
        model.simulateGamepadSnapshotForTesting(snap1, from: "c1")
        #expect(model.game!.inputMaskForTesting(port: 0) == (0xFFFF & ~PadButton.cross.rawValue))
        #expect(model.game!.isRewinding)
        #expect(session.calls.filter { $0 == "pressAnalog()" }.count == 1)

        // Holding R3 across a second report must NOT fire Analog again.
        model.simulateGamepadSnapshotForTesting(snap1, from: "c1")
        #expect(session.calls.filter { $0 == "pressAnalog()" }.count == 1)

        // Port 2 pressing R3 fires Port 2 Analog once on rising edge.
        let snap2 = GamepadSnapshot(pressed: [.rightThumbstickButton])
        model.simulateGamepadSnapshotForTesting(snap2, from: "c2")
        model.simulateGamepadSnapshotForTesting(snap2, from: "c2")
        #expect(session.calls.filter { $0 == "pressPortAnalog(1)" }.count == 1)
    }

    @Test func interactiveGamepadCaptureBindsClearsAndCancels() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults)
        model.simulateConnectedControllersForTesting(controllers(1))
        model.installSessionForTesting(ScriptedSession(), resumeKey: nil)
        defer { model.ejectNowForTesting() }

        // Starting capture swallows controller input from the running game and binds on rising edge.
        model.beginGamepadCapture(.button(.triangle))
        #expect(model.capturingGamepad == .button(.triangle))
        model.simulateGamepadSnapshotForTesting(GamepadSnapshot(pressed: [.leftTrigger]), from: "c1")
        #expect(model.capturingGamepad == nil)
        #expect(model.gamepadBindings.input(for: .button(.triangle)) == .leftTrigger)
        #expect(model.game!.inputMaskForTesting(port: 0) == 0xFFFF)

        // Escape cancels capture without changing bindings.
        model.beginGamepadCapture(.button(.square))
        #expect(model.captureKey(UInt16(kVK_Escape), command: false))
        #expect(model.capturingGamepad == nil)
        #expect(model.gamepadBindings.input(for: .button(.square)) == .buttonX)

        // Delete clears the binding.
        model.beginGamepadCapture(.button(.square))
        #expect(model.captureKey(UInt16(kVK_Delete), command: false))
        #expect(model.capturingGamepad == nil)
        #expect(model.gamepadBindings.input(for: .button(.square)) == nil)

        // Command shortcut cancels and passes through.
        model.beginGamepadCapture(.button(.circle))
        #expect(!model.captureKey(UInt16(kVK_ANSI_W), command: true))
        #expect(model.capturingGamepad == nil)
    }

    @Test func pauseMenuShowsPort2AnalogOnlyWhenPort2IsConnected() throws {
        var single = PauseMenuNavigation()
        single.open(discCount: 1, insertedDisc: 0, pgxpLocked: false, port2Connected: false)
        #expect(!single.isShown(.analog2))
        single.point(at: .analog)
        _ = single.handle(.down)
        #expect(single.focus == .reset)

        var dual = PauseMenuNavigation()
        dual.open(discCount: 1, insertedDisc: 0, pgxpLocked: false, port2Connected: true)
        #expect(dual.isShown(.analog2))
        dual.point(at: .analog)
        _ = dual.handle(.down)
        #expect(dual.focus == .analog2)
        #expect(dual.handle(.right) == .adjust(.analog2, 1))
        #expect(dual.handle(.confirm) == .toggle(.analog2))

        // OpenGame queues pressPortAnalog(1) when Port 2 Analog is toggled in the pause menu.
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = makeModel(defaults: defaults)
        model.simulateConnectedControllersForTesting(controllers(2))
        let session = ScriptedSession()
        model.installSessionForTesting(session, resumeKey: nil)
        defer { model.ejectNowForTesting() }

        model.game!.setSurface(.pauseMenu, open: true)
        #expect(model.game!.menu.isShown(.analog2))
        model.game!.perform(.toggle(.analog2))
        #expect(model.game!.analogShown(port: 1))
        model.game!.setSurface(.pauseMenu, open: false)
        #expect(session.calls.contains("pressPortAnalog(1)"))
    }
}

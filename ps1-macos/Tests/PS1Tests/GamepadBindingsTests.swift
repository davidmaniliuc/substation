import Foundation
import Testing
@testable import PS1

private func freshDefaults() -> UserDefaults {
    let name = "GamepadBindingsTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

struct GamepadBindingsTests {
    @Test func absentKeyMeansPlayStationDefaults() {
        let b = GamepadBindings(defaults: freshDefaults())
        #expect(b.isDefault)
        #expect(b.control(for: .dpadUp) == .button(.up))
        #expect(b.control(for: .buttonA) == .button(.cross))
        #expect(b.control(for: .buttonB) == .button(.circle))
        #expect(b.control(for: .buttonX) == .button(.square))
        #expect(b.control(for: .buttonY) == .button(.triangle))
        #expect(b.control(for: .leftShoulder) == .button(.l1))
        #expect(b.control(for: .rightShoulder) == .button(.r1))
        #expect(b.control(for: .leftTrigger) == .button(.l2))
        #expect(b.control(for: .rightTrigger) == .button(.r2))
        #expect(b.control(for: .leftThumbstickButton) == .button(.l3))
        #expect(b.control(for: .rightThumbstickButton) == .button(.r3))
        #expect(b.control(for: .buttonMenu) == .button(.start))
        #expect(b.control(for: .buttonOptions) == .button(.select))
        #expect(b.input(for: .analog) == nil)
        #expect(b.input(for: .rewind) == nil)
    }

    @Test func everyPadButtonHasAUniqueDefault() {
        let buttons = PadButton.allCases.map(PadControl.button)
        let inputs = buttons.compactMap { GamepadBindings.defaults[$0] }
        #expect(inputs.count == PadButton.allCases.count)
        #expect(Set(inputs).count == inputs.count)
        #expect(Set(GamepadBindings.defaults.keys) == Set(buttons))
    }

    @Test func assigningMovesInputAndUnbindsPreviousControl() {
        var b = GamepadBindings(defaults: freshDefaults())
        b.assign(.buttonB, to: .button(.cross))
        #expect(b.input(for: .button(.cross)) == .buttonB)
        #expect(b.control(for: .buttonB) == .button(.cross))
        #expect(b.input(for: .button(.circle)) == nil)
        #expect(b.control(for: .buttonA) == nil)
        #expect(!b.isDefault)
    }

    @Test func assigningToAnalogOrRewindUnbindsItsOldButton() {
        var b = GamepadBindings(defaults: freshDefaults())
        b.assign(.rightThumbstickButton, to: .analog)
        b.assign(.leftThumbstickButton, to: .rewind)
        #expect(b.input(for: .analog) == .rightThumbstickButton)
        #expect(b.input(for: .rewind) == .leftThumbstickButton)
        #expect(b.input(for: .button(.r3)) == nil)
        #expect(b.input(for: .button(.l3)) == nil)
    }

    @Test func unbindingPersistsAcrossReload() {
        let d = freshDefaults()
        var b = GamepadBindings(defaults: d)
        b.unbind(.button(.l3))
        #expect(b.input(for: .button(.l3)) == nil)
        let reloaded = GamepadBindings(defaults: d)
        #expect(reloaded == b)
        #expect(reloaded.input(for: .button(.l3)) == nil)
        #expect(reloaded.input(for: .button(.cross)) == .buttonA)
    }

    @Test func bindingsPersistAndRestoreDefaultsClearsStorage() {
        let d = freshDefaults()
        var b = GamepadBindings(defaults: d)
        b.assign(.buttonB, to: .button(.cross))
        b.assign(.buttonA, to: .button(.circle))
        b.assign(.rightThumbstickButton, to: .analog)

        let reloaded = GamepadBindings(defaults: d)
        #expect(reloaded == b)
        #expect(reloaded.input(for: .button(.cross)) == .buttonB)
        #expect(reloaded.input(for: .button(.circle)) == .buttonA)
        #expect(reloaded.input(for: .analog) == .rightThumbstickButton)

        b.restoreDefaults()
        #expect(b.isDefault)
        #expect(GamepadBindings(defaults: d).isDefault)
    }

    @Test func mapTranslatesPhysicalButtonsSticksAnalogAndRewind() {
        var b = GamepadBindings(defaults: freshDefaults())
        b.assign(.buttonB, to: .button(.cross))
        b.assign(.buttonA, to: .button(.circle))
        b.assign(.leftThumbstickButton, to: .rewind)
        b.assign(.rightThumbstickButton, to: .analog)

        let snap = GamepadSnapshot(
            pressed: [.buttonB, .dpadUp, .leftThumbstickButton, .rightThumbstickButton],
            sticks: Sticks(lx: 0x10, ly: 0x20, rx: 0x30, ry: 0x40))
        let mapped = b.map(snap)

        #expect(mapped.input.isPressed(.cross))
        #expect(mapped.input.isPressed(.up))
        #expect(!mapped.input.isPressed(.circle))
        #expect(!mapped.input.isPressed(.l3))
        #expect(!mapped.input.isPressed(.r3))
        #expect(mapped.input.sticks == Sticks(lx: 0x10, ly: 0x20, rx: 0x30, ry: 0x40))
        #expect(mapped.analogPressed)
        #expect(mapped.rewindPressed)
    }
}

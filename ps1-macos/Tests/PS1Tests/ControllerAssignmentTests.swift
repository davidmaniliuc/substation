import Foundation
import Testing
@testable import PS1

private func freshDefaults() -> UserDefaults {
    let name = "ControllerAssignmentTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

struct ControllerAssignmentTests {
    private let onePad = ConnectedController.list(from: [("c1", "DualSense")])
    private let twoPads = ConnectedController.list(from: [("c1", "DualSense"), ("c2", "DualSense")])
    private let threePads = ConnectedController.list(from: [("c1", "DualSense"), ("c2", "Xbox"), ("c3", "Pro")])

    @Test func duplicateNamesAreDisambiguatedAndEmptyFallsBack() {
        let list = ConnectedController.list(from: [
            ("a", "DualSense"),
            ("b", "Xbox"),
            ("c", "DualSense"),
            ("d", "   "),
        ])
        #expect(list.map(\.displayName) == ["DualSense (1)", "Xbox", "DualSense (2)", "Controller"])
    }

    @Test func singlePlayerSetupsLeavePort2Disconnected() {
        let a = ControllerAssignment(defaults: freshDefaults())

        let none = a.resolve(connected: [])
        #expect(none == ResolvedControllerRouting(port1Keyboard: true, port1Controller: nil, port2Controller: nil))
        #expect(!none.port2Connected)

        let one = a.resolve(connected: onePad)
        #expect(one == ResolvedControllerRouting(port1Keyboard: true, port1Controller: "c1", port2Controller: nil))
        #expect(!one.port2Connected)
        #expect(one.port(for: "c1") == 0)
    }

    @Test func pluggingASecondControllerEnablesPort2Automatically() {
        let a = ControllerAssignment(defaults: freshDefaults())
        let two = a.resolve(connected: twoPads)
        #expect(two == ResolvedControllerRouting(port1Keyboard: true, port1Controller: "c1", port2Controller: "c2"))
        #expect(two.port2Connected)
        #expect(two.port(for: "c1") == 0)
        #expect(two.port(for: "c2") == 1)
    }

    @Test func keyboardOnlyPort1HandsTheFirstControllerToPort2() {
        var a = ControllerAssignment(defaults: freshDefaults())
        a.setPort1(.keyboardOnly)
        let r = a.resolve(connected: onePad)
        #expect(r == ResolvedControllerRouting(port1Keyboard: true, port1Controller: nil, port2Controller: "c1"))
        #expect(r.port2Connected)
        #expect(r.port(for: "c1") == 1)
    }

    @Test func port2OffKeepsPort2DisconnectedEvenWithTwoControllers() {
        var a = ControllerAssignment(defaults: freshDefaults())
        a.setPort2(.off)
        let r = a.resolve(connected: twoPads)
        #expect(r == ResolvedControllerRouting(port1Keyboard: true, port1Controller: "c1", port2Controller: nil))
        #expect(!r.port2Connected)
        #expect(r.port(for: "c2") == nil)
    }

    @Test func pinningPort2MovesAutomaticPort1ToOtherControllerOrKeyboard() {
        var a = ControllerAssignment(defaults: freshDefaults())
        a.setPort2(.controller("c1"))

        let withTwo = a.resolve(connected: twoPads)
        #expect(withTwo == ResolvedControllerRouting(port1Keyboard: true, port1Controller: "c2", port2Controller: "c1"))

        let withOne = a.resolve(connected: onePad)
        #expect(withOne == ResolvedControllerRouting(port1Keyboard: true, port1Controller: nil, port2Controller: "c1"))
        #expect(withOne.port2Connected)
    }

    @Test func pinningTheSameControllerToBothPortsClearsTheOtherPin() {
        var a = ControllerAssignment(defaults: freshDefaults())
        a.setPort1(.controller("c1"))
        a.setPort2(.controller("c1"))
        #expect(a.port1 == .automatic)
        #expect(a.port2 == .controller("c1"))

        a.setPort1(.controller("c1"))
        #expect(a.port1 == .controller("c1"))
        #expect(a.port2 == .automatic)
    }

    @Test func thirdControllerIsIgnoredUnderAutomatic() {
        let a = ControllerAssignment(defaults: freshDefaults())
        let r = a.resolve(connected: threePads)
        #expect(r.port1Controller == "c1")
        #expect(r.port2Controller == "c2")
        #expect(r.port(for: "c3") == nil)
    }

    @Test func pruneDisconnectedResetsMissingPinnedController() {
        var a = ControllerAssignment(defaults: freshDefaults())
        a.setPort1(.controller("c1"))
        a.setPort2(.controller("c2"))
        a.pruneDisconnected(connected: onePad)
        #expect(a.port1 == .controller("c1"))
        #expect(a.port2 == .automatic)
    }

    @Test func durableModesPersistAcrossRelaunchWhileControllerPinsDoNot() {
        let d = freshDefaults()
        var a = ControllerAssignment(defaults: d)
        a.setPort1(.keyboardOnly)
        a.setPort2(.off)
        let reloaded = ControllerAssignment(defaults: d)
        #expect(reloaded.port1 == .keyboardOnly)
        #expect(reloaded.port2 == .off)

        a.setPort1(.controller("c1"))
        a.setPort2(.controller("c2"))
        let relaunched = ControllerAssignment(defaults: d)
        #expect(relaunched.port1 == .automatic)
        #expect(relaunched.port2 == .automatic)
    }

    @Test func automaticTitlesDescribeLiveResolution() {
        var a = ControllerAssignment(defaults: freshDefaults())
        #expect(a.port1AutomaticTitle(connected: []) == "Automatic (Keyboard)")
        #expect(a.port2AutomaticTitle(connected: []) == "Automatic (Disconnected)")
        #expect(a.port1AutomaticTitle(connected: onePad) == "Automatic (DualSense)")
        #expect(a.port2AutomaticTitle(connected: onePad) == "Automatic (Disconnected)")
        #expect(a.port1AutomaticTitle(connected: twoPads) == "Automatic (DualSense (1))")
        #expect(a.port2AutomaticTitle(connected: twoPads) == "Automatic (DualSense (2))")

        a.setPort1(.keyboardOnly)
        #expect(a.port2AutomaticTitle(connected: onePad) == "Automatic (DualSense)")
    }
}

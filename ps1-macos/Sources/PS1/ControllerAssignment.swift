import Foundation
import GameController

/// One connected extended game controller, represented as a pure value type so
/// controller routing is testable without `GCController` hardware.
struct ConnectedController: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    /// Disambiguated for menus when two identical controllers are connected
    /// (e.g. "DualSense Wireless Controller (1)", "DualSense Wireless Controller (2)").
    let displayName: String

    /// Builds a disambiguated list from raw `(id, name)` pairs in connection order.
    static func list(from raw: [(id: String, name: String)]) -> [ConnectedController] {
        let cleaned = raw.map { pair -> (id: String, name: String) in
            let trimmed = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (pair.id, trimmed.isEmpty ? "Controller" : trimmed)
        }
        var totals: [String: Int] = [:]
        for item in cleaned { totals[item.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return cleaned.map { item in
            let display: String
            if totals[item.name, default: 0] > 1 {
                let index = seen[item.name, default: 0] + 1
                seen[item.name] = index
                display = "\(item.name) (\(index))"
            } else {
                display = item.name
            }
            return ConnectedController(id: item.id, name: item.name, displayName: display)
        }
    }

    static func id(for controller: GCController) -> String {
        id(for: ObjectIdentifier(controller))
    }

    static func id(for objectID: ObjectIdentifier) -> String {
        String(UInt(bitPattern: objectID))
    }

    /// Snapshot of currently connected extended gamepads.
    @MainActor
    static func live() -> [ConnectedController] {
        let raw = GCController.controllers().compactMap { controller -> (String, String)? in
            guard controller.extendedGamepad != nil else { return nil }
            return (id(for: controller), controller.vendorName ?? "Controller")
        }
        return list(from: raw)
    }
}

/// Player's preference for Controller Port 1.
enum Port1Choice: Hashable, Sendable {
    /// Keyboard plus the first available connected controller.
    case automatic
    /// Keyboard only; frees the first controller for Port 2.
    case keyboardOnly
    /// A specific connected controller for this session.
    case controller(String)
}

/// Player's preference for Controller Port 2.
enum Port2Choice: Hashable, Sendable {
    /// Second connected controller, or the first when Port 1 is Keyboard Only;
    /// disconnected when no controller is available.
    case automatic
    /// Explicitly unplugged even when a second controller is connected.
    case off
    /// A specific connected controller for this session.
    case controller(String)
}

/// The live routing computed from `ControllerAssignment` and connected devices.
struct ResolvedControllerRouting: Equatable, Sendable {
    /// Whether the keyboard drives Port 1's pad buttons and Analog key.
    var port1Keyboard: Bool
    /// The controller ID driving Port 1, or nil.
    var port1Controller: String?
    /// The controller ID driving Port 2, or nil.
    var port2Controller: String?

    /// Port 2 is plugged into the console whenever it has an assigned input source.
    var port2Connected: Bool { port2Controller != nil }

    /// Which console port (0 or 1) receives input from `controllerID`, or nil
    /// when the controller is unassigned.
    func port(for controllerID: String) -> Int? {
        if controllerID == port1Controller { return 0 }
        if controllerID == port2Controller { return 1 }
        return nil
    }
}

/// Port 1 and Port 2 controller assignment, persisted across launches for
/// durable modes (`.automatic`, `.keyboardOnly`, `.off`). Specific connected
/// controller picks last for the session and return to `.automatic` if that
/// controller disconnects or on relaunch.
struct ControllerAssignment: Equatable {
    static let port1Key = "port1Controller"
    static let port2Key = "port2Controller"

    private static let automaticValue = "automatic"
    private static let keyboardOnlyValue = "keyboardOnly"
    private static let offValue = "off"

    private(set) var port1: Port1Choice
    private(set) var port2: Port2Choice

    private let store: UserDefaults

    init(defaults store: UserDefaults = .standard) {
        self.store = store
        switch store.string(forKey: Self.port1Key) {
        case Self.keyboardOnlyValue: self.port1 = .keyboardOnly
        default: self.port1 = .automatic
        }
        switch store.string(forKey: Self.port2Key) {
        case Self.offValue: self.port2 = .off
        default: self.port2 = .automatic
        }
    }

    static func == (a: ControllerAssignment, b: ControllerAssignment) -> Bool {
        a.port1 == b.port1 && a.port2 == b.port2
    }

    mutating func setPort1(_ choice: Port1Choice) {
        port1 = choice
        // One controller drives at most one port.
        if case .controller(let id) = choice, port2 == .controller(id) {
            port2 = .automatic
            savePort2()
        }
        savePort1()
    }

    mutating func setPort2(_ choice: Port2Choice) {
        port2 = choice
        if case .controller(let id) = choice, port1 == .controller(id) {
            port1 = .automatic
            savePort1()
        }
        savePort2()
    }

    /// Drops any pinned controller that is no longer connected back to `.automatic`.
    mutating func pruneDisconnected(connected: [ConnectedController]) {
        let ids = Set(connected.map(\.id))
        if case .controller(let id) = port1, !ids.contains(id) {
            port1 = .automatic
            savePort1()
        }
        if case .controller(let id) = port2, !ids.contains(id) {
            port2 = .automatic
            savePort2()
        }
    }

    func resolve(connected: [ConnectedController]) -> ResolvedControllerRouting {
        let ids = connected.map(\.id)
        let explicit1: String? = if case .controller(let id) = port1, ids.contains(id) { id } else { nil }
        let explicit2: String? = if case .controller(let id) = port2, ids.contains(id), id != explicit1 { id } else { nil }

        let p1Keyboard: Bool
        let p1Controller: String?
        switch port1 {
        case .keyboardOnly:
            p1Keyboard = true
            p1Controller = nil
        case .controller:
            if let c1 = explicit1 {
                p1Keyboard = false
                p1Controller = c1
            } else {
                p1Keyboard = true
                p1Controller = ids.first { $0 != explicit2 }
            }
        case .automatic:
            p1Keyboard = true
            p1Controller = ids.first { $0 != explicit2 }
        }

        let p2Controller: String?
        switch port2 {
        case .off:
            p2Controller = nil
        case .controller:
            p2Controller = explicit2
        case .automatic:
            p2Controller = ids.first { $0 != p1Controller }
        }

        return ResolvedControllerRouting(
            port1Keyboard: p1Keyboard,
            port1Controller: p1Controller,
            port2Controller: p2Controller)
    }

    /// Menu title for Port 1's Automatic option, showing what it resolves to.
    func port1AutomaticTitle(connected: [ConnectedController]) -> String {
        var probe = self
        probe.port1 = .automatic
        let resolved = probe.resolve(connected: connected)
        if let id = resolved.port1Controller,
           let controller = connected.first(where: { $0.id == id }) {
            return "Automatic (\(controller.displayName))"
        }
        return "Automatic (Keyboard)"
    }

    /// Menu title for Port 2's Automatic option, showing what it resolves to.
    func port2AutomaticTitle(connected: [ConnectedController]) -> String {
        var probe = self
        probe.port2 = .automatic
        let resolved = probe.resolve(connected: connected)
        if let id = resolved.port2Controller,
           let controller = connected.first(where: { $0.id == id }) {
            return "Automatic (\(controller.displayName))"
        }
        return "Automatic (Disconnected)"
    }

    private func savePort1() {
        switch port1 {
        case .keyboardOnly: store.set(Self.keyboardOnlyValue, forKey: Self.port1Key)
        case .automatic, .controller: store.set(Self.automaticValue, forKey: Self.port1Key)
        }
    }

    private func savePort2() {
        switch port2 {
        case .off: store.set(Self.offValue, forKey: Self.port2Key)
        case .automatic, .controller: store.set(Self.automaticValue, forKey: Self.port2Key)
        }
    }
}

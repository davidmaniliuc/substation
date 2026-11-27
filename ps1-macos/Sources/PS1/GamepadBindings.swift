import Foundation
import GameController

/// A physical button on a `GCExtendedGamepad`. Home is omitted because it is
/// reserved for the pause menu, just as Escape and Tab are reserved on the
/// keyboard.
enum GamepadInput: String, CaseIterable, Hashable, Sendable {
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
    case leftThumbstickButton
    case rightThumbstickButton
    case buttonMenu
    case buttonOptions

    /// Short cap label for the Settings window, recognisable on PlayStation
    /// and Xbox layouts alike.
    var title: String {
        switch self {
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .buttonA: return "A / ✕"
        case .buttonB: return "B / ○"
        case .buttonX: return "X / □"
        case .buttonY: return "Y / △"
        case .leftShoulder: return "L1 / LB"
        case .rightShoulder: return "R1 / RB"
        case .leftTrigger: return "L2 / LT"
        case .rightTrigger: return "R2 / RT"
        case .leftThumbstickButton: return "L3"
        case .rightThumbstickButton: return "R3"
        case .buttonMenu: return "Menu"
        case .buttonOptions: return "Options"
        }
    }
}

/// One physical controller report, independent of `GCExtendedGamepad` so
/// remapping and button capture are testable without hardware.
struct GamepadSnapshot: Equatable, Sendable {
    var pressed: Set<GamepadInput>
    var sticks: Sticks

    init(pressed: Set<GamepadInput> = [], sticks: Sticks = .centred) {
        self.pressed = pressed
        self.sticks = sticks
    }

    init(gamepad pad: GCExtendedGamepad) {
        var pressed: Set<GamepadInput> = []
        if pad.dpad.up.isPressed { pressed.insert(.dpadUp) }
        if pad.dpad.down.isPressed { pressed.insert(.dpadDown) }
        if pad.dpad.left.isPressed { pressed.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { pressed.insert(.dpadRight) }
        if pad.buttonA.isPressed { pressed.insert(.buttonA) }
        if pad.buttonB.isPressed { pressed.insert(.buttonB) }
        if pad.buttonX.isPressed { pressed.insert(.buttonX) }
        if pad.buttonY.isPressed { pressed.insert(.buttonY) }
        if pad.leftShoulder.isPressed { pressed.insert(.leftShoulder) }
        if pad.rightShoulder.isPressed { pressed.insert(.rightShoulder) }
        if pad.leftTrigger.isPressed { pressed.insert(.leftTrigger) }
        if pad.rightTrigger.isPressed { pressed.insert(.rightTrigger) }
        if pad.buttonMenu.isPressed { pressed.insert(.buttonMenu) }
        if pad.buttonOptions?.isPressed == true { pressed.insert(.buttonOptions) }
        if pad.leftThumbstickButton?.isPressed == true { pressed.insert(.leftThumbstickButton) }
        if pad.rightThumbstickButton?.isPressed == true { pressed.insert(.rightThumbstickButton) }
        self.pressed = pressed
        self.sticks = Sticks(
            leftX: pad.leftThumbstick.xAxis.value,
            leftY: pad.leftThumbstick.yAxis.value,
            rightX: pad.rightThumbstick.xAxis.value,
            rightY: pad.rightThumbstick.yAxis.value)
    }
}

/// The PS1 pad state and host controls produced by applying `GamepadBindings`
/// to a physical `GamepadSnapshot`.
struct MappedGamepadInput: Equatable, Sendable {
    var input: InputMap
    var analogPressed: Bool
    var rewindPressed: Bool
}

/// Which physical gamepad button drives each PS1 control, and where that
/// choice is stored.
///
/// Mirrors `KeyBindings`: `init` resolves from `UserDefaults`, every change
/// persists, and one physical button drives at most one control (moving a
/// button leaves its old control unbound).
struct GamepadBindings: Equatable {
    static let storageKey = "gamepadBindings"

    /// PlayStation-standard defaults matching Apple's extended gamepad layout.
    static let buttonDefaults: [PadButton: GamepadInput] = [
        .up: .dpadUp,
        .down: .dpadDown,
        .left: .dpadLeft,
        .right: .dpadRight,
        .cross: .buttonA,
        .circle: .buttonB,
        .square: .buttonX,
        .triangle: .buttonY,
        .l1: .leftShoulder,
        .r1: .rightShoulder,
        .l2: .leftTrigger,
        .r2: .rightTrigger,
        .l3: .leftThumbstickButton,
        .r3: .rightThumbstickButton,
        .start: .buttonMenu,
        .select: .buttonOptions,
    ]

    static let defaults: [PadControl: GamepadInput] =
        Dictionary(uniqueKeysWithValues: buttonDefaults.map { (PadControl.button($0.key), $0.value) })

    /// The order shown in Settings ▸ Controls: D-pad, face buttons, shoulders,
    /// stick clicks, Start/Select, then Analog and Hold to Rewind.
    static let controls: [PadControl] = ([
        .up, .down, .left, .right,
        .cross, .square, .circle, .triangle,
        .l1, .r1, .l2, .r2,
        .l3, .r3,
        .start, .select,
    ] as [PadButton]).map(PadControl.button) + [.analog, .rewind]

    private static let analogName = "analog"
    private static let rewindName = "rewind"

    private(set) var bindings: [PadControl: GamepadInput]

    private let store: UserDefaults
    private let storeName: String

    init(storageKey: String = GamepadBindings.storageKey, defaults store: UserDefaults = .standard) {
        self.store = store
        self.storeName = storageKey
        // An absent key means the defaults; a present one is the whole map,
        // so a control missing from it is one the player left unbound.
        if let saved = store.dictionary(forKey: storageKey) as? [String: String] {
            var loaded: [PadControl: GamepadInput] = [:]
            var usedInputs: Set<GamepadInput> = []
            for control in Self.controls {
                let key = Self.name(of: control)
                if let raw = saved[key], let input = GamepadInput(rawValue: raw),
                   !usedInputs.contains(input) {
                    loaded[control] = input
                    usedInputs.insert(input)
                }
            }
            self.bindings = loaded
        } else {
            self.bindings = Self.defaults
        }
    }

    static func == (a: GamepadBindings, b: GamepadBindings) -> Bool { a.bindings == b.bindings }

    private static func name(of c: PadControl) -> String {
        switch c {
        case .button(let b): return String(b.rawValue)
        case .analog: return analogName
        case .rewind: return rewindName
        }
    }

    func input(for control: PadControl) -> GamepadInput? { bindings[control] }

    func control(for input: GamepadInput) -> PadControl? {
        bindings.first { $0.value == input }?.key
    }

    var isDefault: Bool { bindings == Self.defaults }

    /// Binds `input` to `control`, unbinding whichever control held it.
    mutating func assign(_ input: GamepadInput, to control: PadControl) {
        if let holder = self.control(for: input) { bindings[holder] = nil }
        bindings[control] = input
        save()
    }

    /// Leaves `control` unbound and persists the whole map.
    mutating func unbind(_ control: PadControl) {
        bindings[control] = nil
        save()
    }

    mutating func restoreDefaults() {
        bindings = Self.defaults
        store.removeObject(forKey: storeName)
    }

    /// Translates a physical controller snapshot into PS1 buttons, sticks and
    /// host controls using the current bindings.
    func map(_ snapshot: GamepadSnapshot) -> MappedGamepadInput {
        var input = InputMap()
        input.sticks = snapshot.sticks
        var analogPressed = false
        var rewindPressed = false
        for physical in snapshot.pressed {
            guard let control = self.control(for: physical) else { continue }
            switch control {
            case .button(let b): input.press(b)
            case .analog: analogPressed = true
            case .rewind: rewindPressed = true
            }
        }
        return MappedGamepadInput(input: input, analogPressed: analogPressed, rewindPressed: rewindPressed)
    }

    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: bindings.map { (Self.name(of: $0.key), $0.value.rawValue) })
        store.set(saved, forKey: storeName)
    }
}

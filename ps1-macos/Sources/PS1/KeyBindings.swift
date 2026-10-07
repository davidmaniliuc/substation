import Foundation
import Carbon.HIToolbox

/// Which keyboard key drives each pad button, and where that choice is stored.
///
/// Shaped after `SpeedSetting`: `init` resolves from `UserDefaults`, every
/// change persists, and the rules live in the type so they are reachable from
/// a test without a window. Keys are macOS VIRTUAL KEY CODES, which are
/// layout-independent, so a binding stays on the same physical key on AZERTY
/// or Dvorak.
///
/// **One key drives at most one control.** Assigning a key that another control
/// holds takes it away from that control, which is left unbound: two controls
/// on one key would press both at once, and nothing on screen would say why.
struct KeyBindings: Equatable {
    static let storageKey = "keyBindings"

    /// WASD is deliberately absent: the D-pad is on the arrows and the face
    /// buttons are on the right hand. Analog is unbound: the keyboard has no
    /// sticks for analog mode to read.
    static let buttonDefaults: [PadButton: UInt16] = [
        .up: 126, .down: 125, .left: 123, .right: 124,
        .cross: 6, .square: 7, .circle: 8, .triangle: 9,   // Z X C V
        .l1: 12, .r1: 13, .l2: 0, .r2: 1,                  // Q W A S
        .start: 36, .select: 49,                           // Return, Space
    ]

    static let defaults: [PadControl: UInt16] =
        Dictionary(uniqueKeysWithValues: buttonDefaults.map { (PadControl.button($0.key), $0.value) })

    /// The order a player reads a pad: D-pad, face buttons, shoulders,
    /// Start/Select, then Analog. L3/R3 are absent: they need a stick to press.
    static let controls: [PadControl] = ([
        .up, .down, .left, .right,
        .cross, .square, .circle, .triangle,
        .l1, .r1, .l2, .r2,
        .start, .select,
    ] as [PadButton]).map(PadControl.button) + [.analog]

    /// The stored name of Analog. Buttons are stored as their raw value, so a
    /// map saved before Analog existed simply has no entry for it.
    private static let analogName = "analog"

    /// Keys a control can never take. Tab is fast-forward and Escape cancels a
    /// capture, so binding either would leave the other job unreachable.
    static let reserved: Set<UInt16> = [UInt16(kVK_Tab), UInt16(kVK_Escape)]

    private(set) var keys: [PadControl: UInt16]

    private let store: UserDefaults
    private let storeName: String

    init(storageKey: String = KeyBindings.storageKey, defaults store: UserDefaults = .standard) {
        self.store = store
        self.storeName = storageKey
        // An absent key means the defaults; a present one is the whole map,
        // so a button missing from it is one the player left unbound.
        if let saved = store.dictionary(forKey: storageKey) as? [String: Int] {
            var keys: [PadControl: UInt16] = [:]
            for (name, code) in saved {
                if let c = Self.control(named: name), let code = UInt16(exactly: code) {
                    keys[c] = code
                }
            }
            self.keys = keys
        } else {
            self.keys = Self.defaults
        }
    }

    static func == (a: KeyBindings, b: KeyBindings) -> Bool { a.keys == b.keys }

    private static func control(named name: String) -> PadControl? {
        if name == analogName { return .analog }
        guard let raw = UInt16(name), let b = PadButton(rawValue: raw) else { return nil }
        return .button(b)
    }

    private static func name(of c: PadControl) -> String {
        switch c {
        case .button(let b): return String(b.rawValue)
        case .analog: return analogName
        }
    }

    func key(for control: PadControl) -> UInt16? { keys[control] }

    func control(forKey keyCode: UInt16) -> PadControl? {
        keys.first { $0.value == keyCode }?.key
    }

    var isDefault: Bool { keys == Self.defaults }

    /// Binds `keyCode` to `control`, unbinding whichever control held it.
    /// Returns false, changing nothing, for a reserved key.
    @discardableResult
    mutating func assign(_ keyCode: UInt16, to control: PadControl) -> Bool {
        guard !Self.reserved.contains(keyCode) else { return false }
        if let holder = self.control(forKey: keyCode) { keys[holder] = nil }
        keys[control] = keyCode
        save()
        return true
    }

    mutating func restoreDefaults() {
        keys = Self.defaults
        store.removeObject(forKey: storeName)
    }

    private func save() {
        let saved = Dictionary(uniqueKeysWithValues: keys.map { (Self.name(of: $0.key), Int($0.value)) })
        store.set(saved, forKey: storeName)
    }
}

/// The printable name of a virtual key code, for the Settings window.
enum KeyName {
    private static let special: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Space: "Space",
        kVK_Tab: "Tab", kVK_Escape: "Esc", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_ANSI_Keypad0: "Num 0", kVK_ANSI_Keypad1: "Num 1", kVK_ANSI_Keypad2: "Num 2",
        kVK_ANSI_Keypad3: "Num 3", kVK_ANSI_Keypad4: "Num 4", kVK_ANSI_Keypad5: "Num 5",
        kVK_ANSI_Keypad6: "Num 6", kVK_ANSI_Keypad7: "Num 7", kVK_ANSI_Keypad8: "Num 8",
        kVK_ANSI_Keypad9: "Num 9", kVK_ANSI_KeypadDecimal: "Num .",
        kVK_ANSI_KeypadPlus: "Num +", kVK_ANSI_KeypadMinus: "Num -",
        kVK_ANSI_KeypadMultiply: "Num *", kVK_ANSI_KeypadDivide: "Num /",
        kVK_ANSI_KeypadEquals: "Num =", kVK_ANSI_KeypadClear: "Clear",
    ]

    /// What the key prints on the CURRENT layout, so a player on AZERTY sees
    /// the letter on their own keycap rather than the US one.
    static func of(_ keyCode: UInt16) -> String {
        if let name = special[Int(keyCode)] { return name }
        return typed(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static func typed(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { layout in
            UCKeyTranslate(
                layout.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}

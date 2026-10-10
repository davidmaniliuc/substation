/// Turns a controller's reports into menu moves while a HUD surface is open.
///
/// A report is the pad's whole state, sent on every change, so a held
/// button arrives again and again; only the PRESS is a move. The D-pad and
/// the left stick past halfway are one direction each, ✕ confirms and ○
/// goes back. It is fed every report, menu open or not, so a button already
/// held when the menu opens does not fire on the menu's first report.
struct PadEdges {
    private var held: Set<MenuMove> = []

    /// Halfway from centre on the 0-255 stick bytes.
    private static let low: UInt8 = 0x40
    private static let high: UInt8 = 0xC0

    mutating func moves(for pad: InputMap) -> [MenuMove] {
        let now = Self.directions(of: pad)
        defer { held = now }
        // A fixed order, so two presses in one report come out the same way.
        return [MenuMove.up, .down, .left, .right, .confirm, .back]
            .filter { now.contains($0) && !held.contains($0) }
    }

    private static func directions(of pad: InputMap) -> Set<MenuMove> {
        var on: Set<MenuMove> = []
        let s = pad.sticks
        if pad.isPressed(.up) || s.ly < low { on.insert(.up) }
        if pad.isPressed(.down) || s.ly > high { on.insert(.down) }
        if pad.isPressed(.left) || s.lx < low { on.insert(.left) }
        if pad.isPressed(.right) || s.lx > high { on.insert(.right) }
        if pad.isPressed(.cross) { on.insert(.confirm) }
        if pad.isPressed(.circle) { on.insert(.back) }
        return on
    }
}

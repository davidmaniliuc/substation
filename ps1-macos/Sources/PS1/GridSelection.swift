import CoreGraphics
import SwiftUI

/// Arrow-key movement over the library grid, in plain indices so the rule is
/// testable without a window.
///
/// `LazyVGrid` never says how many columns it laid out, so `columns(width:)`
/// recomputes the count the `.adaptive` item arrives at; up and down need it.
enum GridSelection {
    /// Where an arrow press moves the selection, or nil for an empty grid.
    /// Nothing selected starts at the first tile whatever the arrow, and every
    /// edge clamps rather than wraps.
    static func move(from index: Int?, _ direction: MoveCommandDirection,
                     count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        @unknown default: step = 0
        }
        let target = index + step
        if target < 0 { return index }
        // Down into a short last row lands on its last tile, as Finder does;
        // down from the last row itself goes nowhere.
        if target >= count {
            return direction == .down && index / columns < (count - 1) / columns
                ? count - 1 : index
        }
        return target
    }

    /// As many `minimum`-wide tracks as fit with `spacing` between them, and
    /// never fewer than one.
    static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }
}

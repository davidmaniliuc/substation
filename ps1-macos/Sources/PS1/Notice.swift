import Foundation

/// A status shown for a moment in the badge stack: an icon and a line. A
/// notice with `reveal` is the one badge that takes a click, which shows that
/// file in Finder.
struct Notice: Equatable {
    let icon: String
    let text: String
    var reveal: URL? = nil
}

/// One symbol per kind of notice, so the same event always looks the same.
enum NoticeIcon {
    static let analog = "gamecontroller.fill"
    static let saved = "square.and.arrow.down.fill"
    static let loaded = "clock.arrow.circlepath"
    static let undone = "arrow.uturn.backward"
    static let failure = "exclamationmark.triangle.fill"
    static let disc = "circle.circle"
    static let screenshot = "camera.fill"
    static let autoSaved = "clock.badge.checkmark.fill"
}

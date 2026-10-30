import Foundation

/// The title strip's "Playing for" duration: "42 min", then "1 h 05 min" past
/// the hour. Minutes only: the strip refreshes every 30 s, and a seconds
/// count would be wrong between refreshes.
enum PlayingFor {
    static func format(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    /// The title strip's line: `60 FPS · Playing for 42 min`, or the rate
    /// alone inside the first minute, the pause menu's rule.
    static func status(rate: String, played seconds: TimeInterval) -> String {
        seconds < 60 ? rate : "\(rate) · Playing for \(format(seconds))"
    }

    /// The pause menu's line: "Paused after 42 min", or "Paused" alone
    /// inside the first minute, where "after 0 min" says nothing.
    static func pausedAfter(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "Paused" : "Paused after \(format(seconds))"
    }
}

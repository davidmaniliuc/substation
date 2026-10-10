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
}

import AppIntents

/// The phrases Siri and Spotlight offer with no setup. Every one names the
/// app, as App Shortcuts require.
struct SubstationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayGameIntent(), phrases: [
            "Play \(\.$target) in \(.applicationName)",
            "Open \(\.$target) in \(.applicationName)",
        ], shortTitle: "Play Game", systemImageName: "play.fill")
        AppShortcut(intent: ResumeGameIntent(), phrases: [
            "Resume \(\.$game) in \(.applicationName)",
            "Resume \(.applicationName)",
            "Continue playing in \(.applicationName)",
        ], shortTitle: "Resume Game", systemImageName: "arrow.clockwise")
        AppShortcut(intent: OpenLibraryIntent(), phrases: [
            "Open the \(.applicationName) library",
            "Show my \(.applicationName) library",
        ], shortTitle: "Open Library", systemImageName: "square.grid.2x2")
    }
}

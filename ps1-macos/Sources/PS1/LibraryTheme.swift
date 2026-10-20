import AppKit
import SwiftUI

/// How the library looks: the system's own window colours and native table
/// chrome, light or dark, as Finder draws them. The game's picture is black
/// under every theme; a theme reaches the library, its toolbar and the
/// Settings window, nothing else.
///
/// The raw values are persisted, so a new theme takes the next free number
/// and no case is ever renumbered; the declaration order is the pickers'.
/// Retired, never reused, and loading as System: 0 (Black), 4 (Substation)
/// and 5 (Graphite).
enum LibraryTheme: Int, CaseIterable {
    /// Dark or Light as macOS is set. Declared first so the pickers list it
    /// first; its raw value was the next free one when it was added.
    case system = 3
    case dark = 1
    case light = 2

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    /// The theme's scheme: Dark and Light are choices, and System is
    /// whatever macOS is set to now.
    ///
    /// System resolves to a scheme rather than to nil: `preferredColorScheme`
    /// read nil as "keep what the window has", so going from Dark or Light
    /// to System left the window dark or light whatever macOS was set to.
    @MainActor var colorScheme: ColorScheme {
        switch self {
        case .system: SystemAppearance.shared.scheme
        case .dark: .dark
        case .light: .light
        }
    }
}

/// macOS's own light or dark setting, observed: the app's appearance, which
/// a window's forced scheme does not change, so it always reads the system.
@MainActor @Observable final class SystemAppearance {
    static let shared = SystemAppearance()

    private(set) var scheme: ColorScheme = .dark
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        scheme = Self.scheme(of: NSApp.effectiveAppearance)
        observation = NSApp.observe(\.effectiveAppearance) { app, _ in
            MainActor.assumeIsolated {
                SystemAppearance.shared.scheme = Self.scheme(of: app.effectiveAppearance)
            }
        }
    }

    private static func scheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

/// The persisted theme. Shaped after `DitherSetting`: `init` resolves, `set`
/// persists, and the load is `PersistedChoice`'s rejecting one, so a raw
/// value this build has no theme for loads as the default.
struct LibraryThemeSetting {
    static let defaultsKey = "libraryTheme"
    static let defaultTheme = LibraryTheme.system

    private var choice: PersistedChoice<LibraryTheme>
    var theme: LibraryTheme { choice.value }

    init(key: String = LibraryThemeSetting.defaultsKey, defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultTheme)
    }

    mutating func set(_ value: LibraryTheme) { choice.set(value) }
}

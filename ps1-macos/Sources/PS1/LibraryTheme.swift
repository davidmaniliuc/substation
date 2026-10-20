import AppKit
import SwiftUI

/// How the library looks. Every theme draws a slow backdrop behind the
/// library; the game's picture is black under all of them. A theme reaches
/// the library and its toolbar, nothing else: Settings keeps the system's
/// appearance whatever the theme.
///
/// The raw values are persisted, so a new theme takes the next free number
/// and no case is ever renumbered; the declaration order is the pickers'.
/// Retired, never reused, and loading as System: 0 (Black) and 5 (Graphite,
/// which became Dark).
enum LibraryTheme: Int, CaseIterable {
    /// Dark or Light as macOS is set. Declared first so the pickers list it
    /// first; its raw value is the next free one when it was added.
    case system = 3
    /// The near-grey Graphite backdrop.
    case dark = 1
    /// Graphite's pale variant.
    case light = 2
    /// The selected game's cover colours, muted, drifting behind the library.
    case substation = 4

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        case .substation: "Substation"
        }
    }
}

/// Everything a library surface takes from its theme. Every value lives
/// here, and the views ask for it rather than switching on the case, so
/// two themes cannot drift apart surface by surface; a new theme is one case
/// and its answers below.
extension LibraryTheme {
    /// What the library is drawn over. `cover` is the selected game's:
    /// Substation takes its colours from it, and from the console's own
    /// where there is none (onboarding, a library before any selection).
    @MainActor @ViewBuilder func backdrop(cover: URL? = nil) -> some View {
        switch self {
        case .substation:
            LibraryBackdrop(palette: cover.flatMap { BackdropPalette.fromCover(at: $0) } ?? .substation)
        case .system, .dark, .light: GraphiteBackdrop()
        }
    }

    /// The theme's scheme: Dark and Light are choices, Substation's backdrop
    /// is dark, and System is whatever macOS is set to now.
    ///
    /// System resolves to a scheme rather than to nil: `preferredColorScheme`
    /// read nil as "keep what the window has", so going from Dark or Light
    /// to System left the window dark or light whatever macOS was set to.
    @MainActor var colorScheme: ColorScheme {
        switch self {
        case .system: SystemAppearance.shared.scheme
        case .dark, .substation: .dark
        case .light: .light
        }
    }

    /// The hairline between the list's rows, drawn in place of the table's
    /// own stripes. Those cannot stay: with the background hidden so the
    /// backdrop shows, a content row still fills itself with the system's
    /// opaque stripe colour (measured at 16% white). A few percent of the
    /// scheme's text colour: anything stronger reads as a rule.
    static let rowSeparator = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)
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

/// Graphite, dark or pale as the window's scheme is: Dark and Light force
/// the scheme, and System follows macOS, so one view serves all three.
private struct GraphiteBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            LibraryBackdrop(palette: .graphite)
        } else {
            LibraryBackdrop(palette: .graphiteLight, dim: 0)
        }
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

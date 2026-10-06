import AppKit
import SwiftUI

/// How the library looks. The game's picture is black under every theme: a
/// theme reaches the library, its toolbar and the Settings window, nothing
/// else.
///
/// The raw values are persisted, so a new theme takes the next free number
/// and no case is ever renumbered.
enum LibraryTheme: Int, CaseIterable {
    /// The system's appearance, light or dark as macOS is set: Dark or Light
    /// below, decided by the system rather than the player. Declared first
    /// so the pickers list it first; its raw value is the next free one.
    case system = 3
    /// Pure black, for an OLED panel: Finder's layout and density without
    /// its gray.
    case black = 0
    /// The system's dark window colour and native table chrome, as Finder
    /// draws them.
    case dark = 1
    /// Finder's light look: the system's light window colour and native
    /// table chrome.
    case light = 2

    var title: String {
        switch self {
        case .system: "System"
        case .black: "Black"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

/// Everything a library surface takes from its theme. Every value lives
/// here, and the views ask for it rather than switching on the case, so
/// two themes cannot drift apart surface by surface; a new theme is one case
/// and its answers below.
extension LibraryTheme {
    /// What the library is drawn over. A view rather than a colour, so a
    /// theme can bring a backdrop of its own.
    @ViewBuilder var backdrop: some View {
        switch self {
        case .black: Color.black
        case .system, .dark, .light: Color(nsColor: .windowBackgroundColor)
        }
    }

    /// The theme's own scheme, whatever the system's: a Light system
    /// appearance must not put black text on the black theme, and Dark and
    /// Light are choices, not "follow the system". Nil is the system's,
    /// which `preferredColorScheme` reads as no preference.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .black, .dark: .dark
        case .light: .light
        }
    }

    /// The Settings window's own background: hidden where the theme paints
    /// its backdrop under the panes instead, so a Black library does not open
    /// a gray Settings window. The form's grouped rows keep their fill.
    var settingsBackground: Visibility {
        switch self {
        case .black: .hidden
        case .system, .dark, .light: .automatic
        }
    }

    /// The hairline between rows, or nil where the table keeps its own
    /// background, header and row stripes. White at a few percent: on black
    /// anything stronger reads as a gray rule.
    ///
    /// Black cannot keep the native stripes: with the background hidden, a
    /// content row still fills itself with the system's opaque stripe colour
    /// (measured at 16% white), so it turns them off and draws this instead.
    var rowSeparator: NSColor? {
        switch self {
        case .black: NSColor(white: 1, alpha: 0.07)
        case .system, .dark, .light: nil
        }
    }

    /// The table's own background, derived from `rowSeparator` so the two
    /// cannot disagree: hidden exactly where the theme draws its own rows.
    var tableBackground: Visibility { rowSeparator == nil ? .automatic : .hidden }

    /// The table's own row stripes, derived the same way.
    var tableStripes: AlternatingRowBackgroundBehavior {
        rowSeparator == nil ? .enabled : .disabled
    }
}

/// The persisted theme. Shaped after `DitherSetting`: `init` resolves, `set`
/// persists, and the load is `PersistedChoice`'s rejecting one, because 0 is
/// a valid theme (`.black`).
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

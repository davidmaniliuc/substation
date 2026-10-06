import AppKit
import SwiftUI

/// How the library looks. The game's picture is black under every theme: a
/// theme reaches the library and its toolbar, nothing else.
///
/// The raw values are persisted, so a new theme takes the next free number
/// and no case is ever renumbered.
enum LibraryTheme: Int, CaseIterable {
    /// Pure black, for an OLED panel: Finder's layout and density without
    /// its gray.
    case black = 0
    /// The system's dark window colour and native table chrome, as Finder
    /// draws them.
    case dark = 1

    var title: String {
        switch self {
        case .black: "Black"
        case .dark: "Dark"
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
        case .dark: Color(nsColor: .windowBackgroundColor)
        }
    }

    /// Both themes are dark. Without it a light system appearance would put
    /// black text on the black theme.
    var colorScheme: ColorScheme { .dark }

    /// The toolbar's own material. On black it reads as a gray band above
    /// the covers, so it goes, and the glass capsules float on the backdrop.
    var toolbarBackground: Visibility {
        switch self {
        case .black: .hidden
        case .dark: .automatic
        }
    }

    /// Whether the table paints its native background and row stripes.
    /// On black it cannot: with the background hidden, a content row still
    /// fills itself with the system's opaque stripe colour (measured at 16%
    /// white), so the theme turns the stripes off and draws `rowSeparator`
    /// instead.
    var nativeTableChrome: Bool {
        switch self {
        case .black: false
        case .dark: true
        }
    }

    /// The hairline between rows, or nil for the table's own chrome. White
    /// at a few percent: on black anything stronger reads as a gray rule.
    var rowSeparator: NSColor? {
        switch self {
        case .black: NSColor(white: 1, alpha: 0.07)
        case .dark: nil
        }
    }
}

/// The persisted theme. Shaped after `DitherSetting`: `init` resolves, `set`
/// persists, and the load is `PersistedChoice`'s rejecting one, because 0 is
/// a valid theme (`.black`, the default).
struct LibraryThemeSetting {
    static let defaultsKey = "libraryTheme"
    static let defaultTheme = LibraryTheme.black

    private var choice: PersistedChoice<LibraryTheme>
    var theme: LibraryTheme { choice.value }

    init(key: String = LibraryThemeSetting.defaultsKey, defaults: UserDefaults = .standard) {
        choice = PersistedChoice(key: key, defaults: defaults, fallback: Self.defaultTheme)
    }

    mutating func set(_ value: LibraryTheme) { choice.set(value) }
}

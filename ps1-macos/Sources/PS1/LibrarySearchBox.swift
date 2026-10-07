import SwiftUI

/// When the toolbar's search is a field and when it folds into a round
/// button, as Finder's does. A rule on the window's width rather than
/// AppKit's own: SwiftUI's `.searchable` toolbar field stretches across
/// every free point of a wide window, pushing the other controls off the
/// trailing edge, and never folds at all.
enum LibrarySearchLayout {
    static let fieldWidth: CGFloat = 200
    /// What the rest of the toolbar takes: the traffic lights, the title and
    /// the view switcher, plus the cover-size slider in grid view.
    private static let chrome: CGFloat = 430
    private static let slider: CGFloat = 180

    static func folds(width: CGFloat, viewMode: LibraryViewMode) -> Bool {
        width < chrome + (viewMode == .grid ? slider : 0) + fieldWidth
    }
}

/// The library's search: a field at the trailing edge, or a magnifying glass
/// that opens into one when the window is too narrow for it. An opened field
/// folds back as soon as it loses focus (a click elsewhere, or Esc), search
/// and all; the glass is then tinted, so a filtered library still says so.
struct LibrarySearchBox: View {
    @Binding var text: String
    let folds: Bool
    /// Library ▸ Find (⌘F): each change opens the field and focuses it.
    let focusRequest: Int

    @State private var opened = false
    @FocusState private var focused: Bool

    private var showsField: Bool { !folds || opened }

    var body: some View {
        Group {
            if showsField {
                field
            } else {
                Button {
                    open()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(text.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                }
                .help(text.isEmpty ? "Search" : "Search: \(text)")
            }
        }
        .onChange(of: focusRequest) { open() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { opened = false }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: LibrarySearchLayout.fieldWidth)
    }

    private func open() {
        opened = true
        // A turn later: the field must exist before it can take focus.
        DispatchQueue.main.async { focused = true }
    }
}

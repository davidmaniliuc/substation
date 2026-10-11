import SwiftUI

/// When the toolbar's search is a field and when it is a round magnifying
/// glass, as Finder's is: a glass at rest at every window width, a field
/// from a click (or ⌘F) until it loses focus with nothing typed. A search
/// in force keeps its field, so the query stays readable; Esc clears it and
/// folds at once.
enum LibrarySearchFold {
    static let fieldWidth: CGFloat = 200

    /// Whether the field stays open once focus has gone elsewhere.
    static func staysOpen(withQuery text: String) -> Bool {
        !text.allSatisfy(\.isWhitespace)
    }
}

/// The library's search. Our own toolbar item, not `.searchable`: SwiftUI's
/// toolbar search field stretches across every free point of a wide window
/// and has no folded form on macOS (`.minimize` is iOS-only).
struct LibrarySearchBox: View {
    @Binding var text: String
    /// Library ▸ Find (⌘F): each change opens the field and focuses it.
    let focusRequest: Int

    @State private var opened = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if opened {
                field
            } else {
                Button(action: open) {
                    Label("Search", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .help("Search")
            }
        }
        .onAppear { opened = LibrarySearchFold.staysOpen(withQuery: text) }
        .onChange(of: focusRequest) { open() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && !LibrarySearchFold.staysOpen(withQuery: text) { fold() }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand {
                    text = ""
                    fold()
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: LibrarySearchFold.fieldWidth)
    }

    private func open() {
        withAnimation(.snappy) { opened = true }
        // A turn later: the field must exist before it can take focus.
        DispatchQueue.main.async { focused = true }
    }

    private func fold() {
        focused = false
        withAnimation(.snappy) { opened = false }
    }
}

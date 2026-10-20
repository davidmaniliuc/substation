import AppKit
import SwiftUI

/// When the toolbar's search is a field and when it folds into a round
/// magnifying glass, as Finder's does: a field whenever the window has room
/// for one, the glass only when it has not. A folded glass opens into the
/// field on a click (or ⌘F) and folds back when focus leaves it with
/// nothing typed; a search in force keeps its field, so the query stays
/// readable, and Esc clears it and folds at once.
enum LibrarySearchLayout {
    static let fieldWidth: CGFloat = 200
    /// What the rest of the toolbar takes: the traffic lights, the title and
    /// the section tabs with their titles.
    private static let chrome: CGFloat = 640

    static func folds(width: CGFloat) -> Bool {
        width < chrome + fieldWidth
    }

    /// Whether an opened field stays open once focus has gone elsewhere.
    static func staysOpen(withQuery text: String) -> Bool {
        !text.allSatisfy(\.isWhitespace)
    }
}

/// The library's search. Our own toolbar item, not `.searchable`: SwiftUI's
/// toolbar search field stretches across every free point of a wide window
/// and has no folded form on macOS (`.minimize` is iOS-only).
struct LibrarySearchBox: View {
    @Binding var text: String
    let folds: Bool
    /// Library ▸ Find (⌘F): each change opens the field and focuses it.
    let focusRequest: Int

    /// The folded glass was clicked open.
    @State private var opened = false

    var body: some View {
        Group {
            if !folds || opened {
                // Opened from the glass, it takes focus as it appears; a
                // field that is simply there in a wide window waits for a
                // click or ⌘F.
                SearchField(text: $text, focusRequest: focusRequest,
                            focusesOnAppear: folds, endEditing: endEditing)
                    .frame(width: LibrarySearchLayout.fieldWidth)
            } else {
                Button {
                    withAnimation(.snappy) { opened = true }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .help("Search")
            }
        }
        .onAppear { opened = LibrarySearchLayout.staysOpen(withQuery: text) }
        .onChange(of: focusRequest) { withAnimation(.snappy) { opened = true } }
    }

    private func endEditing() {
        guard !LibrarySearchLayout.staysOpen(withQuery: text) else { return }
        withAnimation(.snappy) { opened = false }
    }
}

/// AppKit's search field, for its bezel, its focus ring and its clear
/// button. It takes focus when opened from the glass and on every ⌘F. A click
/// anywhere else in the window ends the editing, as Finder's does: AppKit
/// alone keeps the field editor through a click on anything that cannot
/// take focus itself, such as the gaps between covers or the toolbar.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let focusesOnAppear: Bool
    /// Focus left the field: the box decides whether it folds.
    let endEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        if focusesOnAppear { context.coordinator.focus(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            coordinator.focus(field)
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.stopWatchingClicks()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var focusRequest: Int
        private var clickMonitor: Any?

        init(_ parent: SearchField) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        /// A turn later: the field is not in a window when it is made.
        func focus(_ field: NSSearchField) {
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard clickMonitor == nil, let field = note.object as? NSSearchField else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak field] event in
                if let field, let window = field.window, event.window === window,
                   !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) {
            stopWatchingClicks()
            parent.endEditing()
        }

        /// Esc clears the search and ends the editing, which folds a
        /// field opened from the glass; AppKit's own cancel only clears.
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.text = ""
            control.window?.makeFirstResponder(nil)
            return true
        }

        func stopWatchingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }
}

import SwiftUI

/// A tile's controls over its screenshot, shown under the pointer: Load and
/// Save on the leading side, Delete alone on the trailing one, as the
/// in-game Save States panel's tiles show them.
struct TileCorners: View {
    let title: String
    let width: CGFloat
    var load: (() -> Void)?
    /// Overwrites this tile's state, after asking.
    var save: (() -> Void)?
    var delete: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let load { CornerButton(symbol: "play.fill", help: "Load \(title)", action: load) }
            if let save {
                CornerButton(symbol: "square.and.arrow.down",
                             help: "Overwrite \(title)…", action: save)
            }
            Spacer()
            if let delete {
                CornerButton(symbol: "trash", help: "Delete \(title)…", destructive: true, action: delete)
            }
        }
        .padding(8)
        .frame(width: width, height: width * 3 / 4, alignment: .bottom)
        .transition(.opacity)
    }
}

/// A control over the screenshot: clear Liquid Glass, the HIG's variant for
/// controls over media, on the tile's dimming. The destructive one fills red
/// only under the pointer.
private struct CornerButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(destructive && hover ? Color.red : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressDim())
        .glassEffect(.clear.interactive(), in: Circle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// Every custom button needs a press state (HIG Buttons).
private struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

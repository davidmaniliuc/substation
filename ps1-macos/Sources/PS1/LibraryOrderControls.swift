import SwiftUI

/// The sort's menu: the orders, then the open order's two directions named
/// for what they mean. One view for the header's pill and Library ▸ Sort By,
/// so the two cannot drift.
struct LibraryOrderMenu: View {
    @Binding var order: LibraryOrder

    var body: some View {
        Picker("Sort By", selection: Binding(get: { order.sort }, set: { order.pick($0) })) {
            ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)

        Picker("Direction", selection: $order.reversed) {
            Text(order.sort.direction(reversed: false)).tag(false)
            Text(order.sort.direction(reversed: true)).tag(true)
        }
        .pickerStyle(.inline)
    }
}

/// The header's sort: the order's name opens the menu, and the arrow beside
/// it flips the direction in one click. One quiet pill, so it reads as a
/// single control; each half answers hover and press on its own.
struct LibraryOrderPill: View {
    @Binding var order: LibraryOrder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                LibraryOrderMenu(order: $order)
            } label: {
                HStack(spacing: Design.Spacing.xs) {
                    Text(order.sort.title)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .imageScale(.small)
                }
                .padding(.leading, Design.Spacing.m)
                .padding(.trailing, Design.Spacing.s)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PillSegmentStyle())
            .fixedSize()
            .help("Sort By")
            .accessibilityLabel("Sort By")
            .accessibilityValue(order.sort.title)

            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: Design.Spacing.m)

            Button {
                withAnimation(reduceMotion ? nil : .snappy) { order.reversed.toggle() }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(order.reversed ? 180 : 0))
                    .frame(width: Self.height)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(PillSegmentStyle())
            .help(order.direction)
            .accessibilityLabel("Direction")
            .accessibilityValue(order.direction)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: Self.height)
        .background(.fill.quaternary, in: .capsule)
        .clipShape(.capsule)
    }
}

/// One half of the sort pill: a soft fill on hover, a firmer one while
/// pressed, clipped to the pill's capsule by its parent.
private struct PillSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Segment(configuration: configuration)
    }

    private struct Segment: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    if configuration.isPressed {
                        Rectangle().fill(.fill.secondary)
                    } else if hovering {
                        Rectangle().fill(.fill.tertiary)
                    }
                }
                .onHover { hovering = $0 }
        }
    }
}

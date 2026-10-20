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
/// single control.
struct LibraryOrderPill: View {
    @Binding var order: LibraryOrder

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                LibraryOrderMenu(order: $order)
            } label: {
                HStack(spacing: 5) {
                    Text(order.sort.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.leading, 11)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Sort By")

            Rectangle()
                .fill(.primary.opacity(0.15))
                .frame(width: 1, height: 12)

            Button {
                withAnimation(.snappy) { order.reversed.toggle() }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(order.reversed ? 180 : 0))
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(order.direction)
            .accessibilityLabel("Direction")
            .accessibilityValue(order.direction)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .background(.primary.opacity(0.07), in: .capsule)
    }
}

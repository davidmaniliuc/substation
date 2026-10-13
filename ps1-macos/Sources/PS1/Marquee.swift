import SwiftUI

/// One line that scrolls sideways when it does not fit, as Music's
/// now-playing title does: it rests, scrolls one length plus a gap, and rests
/// again on the same text. A line that fits never moves; under Reduce Motion
/// it truncates instead. A new text starts again from rest.
struct Marquee: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var start = Date()

    private let gap: CGFloat = 32
    /// Points per second.
    private let speed: CGFloat = 30
    /// Seconds still at the start of each pass.
    private let rest: Double = 2.5
    private let fade: CGFloat = 12

    private var overflows: Bool { textWidth > boxWidth + 0.5 }

    var body: some View {
        // The plain line sets the height and reports the box's width.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                if overflows && !reduceMotion {
                    scrolling
                } else {
                    Text(text).font(font).lineLimit(1).truncationMode(.tail)
                }
            }
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onChange(of: text) { start = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    /// At rest only the trailing edge fades, so the first letters read
    /// clean; while it moves, both edges do.
    private var scrolling: some View {
        TimelineView(.animation) { context in
            let x = offset(at: context.date)
            HStack(spacing: gap) {
                Text(text).font(font).fixedSize()
                Text(text).font(font).fixedSize()
            }
            .offset(x: x)
            .frame(width: boxWidth, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [x < 0 ? .clear : .black, .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade)
                }
            }
        }
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = textWidth + gap
        let travel = Double(distance / speed)
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: rest + travel)
        guard t > rest else { return 0 }
        return -CGFloat(t - rest) * speed
    }
}

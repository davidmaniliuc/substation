import SwiftUI

/// The volume slider: a capsule track with a solid fill and no thumb, which is
/// the shape Apple Music uses. A thumb would be the only round element in a
/// HUD made entirely of capsules, and at this size it would cover most of the
/// fill it is meant to mark.
struct VolumeSlider: View {
    @Binding var level: Double
    let isMuted: Bool

    /// Reports the drag so the control can stay open while the pointer strays
    /// off the pill mid-adjustment.
    var onAdjusting: (Bool) -> Void = { _ in }

    /// A little wider than Apple Music's: wide enough to aim at, short
    /// enough that the pill covers little of the bar.
    static let width: CGFloat = 72
    private let trackHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18))
                Capsule()
                    .fill(Color.primary.opacity(isMuted ? 0.3 : 0.95))
                    // Clamped here as well as in `VolumeSetting`: this is a
                    // width, and a negative one is a layout error rather than
                    // a quiet clamp.
                    .frame(width: min(max(level, 0), 1) * width)
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            // The whole height takes the drag, not just the 10pt track, and
            // `minimumDistance: 0` makes a plain click jump to the position
            // under the pointer rather than needing a drag to register.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged {
                        onAdjusting(true)
                        level = min(max($0.location.x / width, 0), 1)
                    }
                    .onEnded { _ in onAdjusting(false) }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: level = min(level + 0.05, 1)
            case .decrement: level = max(level - 0.05, 0)
            @unknown default: break
            }
        }
    }
}

/// The speaker icon. Same 28x28 frame as every other HUD button.
struct VolumeButton: View {
    let level: Double
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SpeakerGlyph(waves: VolumeIcon.waves(level: level, isMuted: isMuted),
                         isSlashed: VolumeIcon.isSlashed(level: level, isMuted: isMuted))
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute" : "Volume")
        .accessibilityLabel(isMuted ? "Unmute" : "Volume")
    }
}

/// The speaker drawn the way Apple Music animates it: the speaker never
/// moves, each wave fades on its own, and a slash draws across for mute.
/// Swapping SF Symbols cannot do this. Even Magic Replace treats the speaker
/// as a different shape in `speaker.slash.fill` (the slash cuts a gap in
/// it) and in each wave symbol, so it shrinks and regrows on every change,
/// including every wave step while the slider is dragged.
struct SpeakerGlyph: View {
    let waves: Int
    let isSlashed: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // The sizer: every layer is leading-aligned in the three-wave
            // symbol's frame, so the speaker sits where it does with all
            // three waves, and the waves of each symbol land on each other.
            Image(systemName: "speaker.wave.3.fill").hidden()
            Image(systemName: "speaker.fill")
            ForEach(1...3, id: \.self) { n in
                arc(n).opacity(n <= waves ? 1 : 0)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .frame(width: 28, height: 28)
        .mask {
            Rectangle()
                .overlay(Slash(progress: isSlashed ? 1 : 0)
                    .stroke(.black, style: StrokeStyle(lineWidth: Slash.gap, lineCap: .round))
                    .blendMode(.destinationOut))
                .compositingGroup()
        }
        .overlay(Slash(progress: isSlashed ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: Slash.width, lineCap: .round)))
        .animation(.easeInOut(duration: 0.2), value: waves)
        .animation(.easeInOut(duration: 0.3), value: isSlashed)
    }

    /// Wave `n` alone: its symbol less the symbol one wave smaller.
    private func arc(_ n: Int) -> some View {
        Image(systemName: "speaker.wave.\(n).fill")
            .mask(alignment: .leading) {
                Rectangle()
                    .overlay(alignment: .leading) {
                        Image(systemName: n == 1 ? "speaker.fill" : "speaker.wave.\(n - 1).fill")
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
    }
}

/// The mute slash, drawn from its top-left end as `progress` goes to 1.
/// Measured off `speaker.slash.fill` at 15pt medium, in the 28x28 frame with
/// the speaker placed as `SpeakerGlyph` places it.
private struct Slash: Shape {
    var progress: CGFloat
    static let width: CGFloat = 1.2
    /// The cut the slash makes in the speaker, edge to edge.
    static let gap: CGFloat = 3.0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0.001 else { return Path() }
        let from = CGPoint(x: 3.25, y: 7.75), to = CGPoint(x: 15.4, y: 20.8)
        var path = Path()
        path.move(to: from)
        path.addLine(to: CGPoint(x: from.x + (to.x - from.x) * progress,
                                 y: from.y + (to.y - from.y) * progress))
        return path
    }
}

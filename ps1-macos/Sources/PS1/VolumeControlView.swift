import SwiftUI

/// The volume slider: a capsule track with a solid fill and no thumb, which is
/// the shape Apple Music uses. A thumb would be the only round element in a
/// HUD made entirely of capsules, and at this size it would cover most of the
/// fill it is meant to mark.
struct VolumeSlider: View {
    @Binding var level: Double
    let isMuted: Bool

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
            // The whole height takes the drag, not just the 10pt track — and
            // `minimumDistance: 0` makes a plain click jump to the position
            // under the pointer rather than needing a drag to register.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { level = min(max($0.location.x / width, 0), 1) }
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

/// The speaker icon. Same 28x28 frame as every other HUD button, so the bar
/// does not resize as the symbol changes between one, two and three waves.
struct VolumeButton: View {
    let level: Double
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: VolumeIcon.symbol(level: level, isMuted: isMuted))
                .font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute" : "Volume")
        .accessibilityLabel(isMuted ? "Unmute" : "Volume")
    }
}

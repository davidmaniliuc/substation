/// What a click on the speaker icon does, which depends on whether the slider
/// is already open.
///
/// A type of its own rather than a `@State` boolean plus an `if` inside the
/// view, so the two-stage rule is testable without a window — the same reason
/// the OSD's show/hide policy lives on `EmulatorViewModel` rather than in
/// `ContentView`.
enum VolumeIconAction: Equatable { case expand, toggleMute }

struct VolumeControlState {
    private(set) var isExpanded = false

    /// The first click opens the slider; every click after it mutes and
    /// unmutes. The control stays open across a mute because the icon is the
    /// only thing that shows one, and collapsing would hide the feedback for
    /// the very click that caused it.
    mutating func iconTapped() -> VolumeIconAction {
        guard isExpanded else {
            isExpanded = true
            return .expand
        }
        return .toggleMute
    }

    mutating func collapse() {
        isExpanded = false
        isAdjusting = false
        strayed = false
    }

    /// The pointer left the control. Closing on that is what makes the bar
    /// return to icon-only without a second click.
    ///
    /// A drag in progress holds it open: the slider's track is 10pt inside a
    /// 36pt pill, so a drag that leaves by a few pixels is ordinary aiming and
    /// not a decision to close. The stray is remembered instead and acted on
    /// when the drag ends.
    mutating func pointerExited() {
        guard isExpanded else { return }
        if isAdjusting { strayed = true } else { collapse() }
    }

    /// Idempotent: `DragGesture.onChanged` fires for every movement, including
    /// the ones outside the pill, and a began that reset `strayed` on each of
    /// them would lose the stray it is there to remember.
    mutating func adjustingBegan() {
        guard !isAdjusting else { return }
        isAdjusting = true
        strayed = false
    }

    mutating func adjustingEnded() {
        isAdjusting = false
        if strayed { collapse() }
        strayed = false
    }

    private var isAdjusting = false
    private var strayed = false
}

/// Which speaker symbol the icon shows.
///
/// Kept out of the view so it is checkable without a running HUD, and because
/// the mute case is the one that is easy to get wrong: mute is a flag over an
/// untouched level, so a muted control at full volume must still read as muted.
enum VolumeIcon {
    static func symbol(level: Double, isMuted: Bool) -> String {
        if isMuted { return "speaker.slash.fill" }
        switch level {
        case ..<0.001: return "speaker.fill"
        case ..<(1.0 / 3): return "speaker.wave.1.fill"
        case ..<(2.0 / 3): return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

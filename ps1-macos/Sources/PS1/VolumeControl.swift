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

    mutating func collapse() { isExpanded = false }
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

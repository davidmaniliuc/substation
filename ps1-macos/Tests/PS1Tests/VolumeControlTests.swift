import Testing
@testable import PS1

/// The two-stage click policy, driven directly rather than through a view —
/// the same reason `HudVisibilityTests` drives the OSD on the model.

@Test func theFirstTapOnTheIconOpensTheSliderRatherThanMuting() {
    var state = VolumeControlState()
    #expect(state.isExpanded == false)

    #expect(state.iconTapped() == .expand)
    #expect(state.isExpanded)
}

@Test func aSecondTapMutesAndLeavesTheSliderOpen() {
    var state = VolumeControlState()
    _ = state.iconTapped()

    #expect(state.iconTapped() == .toggleMute)
    // Staying open is the point: the icon is the only thing that shows the
    // mute, so collapsing on the same click would hide the feedback for it.
    #expect(state.isExpanded)
}

@Test func aCollapsedControlOpensAgainInsteadOfMuting() {
    var state = VolumeControlState()
    _ = state.iconTapped()
    state.collapse()
    #expect(state.isExpanded == false)

    #expect(state.iconTapped() == .expand)
}

/// Which speaker the icon shows. Pure, so it is checked here rather than by
/// looking at a running HUD.

@Test func aMutedControlShowsTheSlashedSpeakerWhateverTheLevel() {
    // The tell that mute is a flag over an untouched level: a full-volume
    // mute still reads as muted.
    #expect(VolumeIcon.symbol(level: 1, isMuted: true) == "speaker.slash.fill")
    #expect(VolumeIcon.symbol(level: 0, isMuted: true) == "speaker.slash.fill")
}

@Test func aLevelOfZeroShowsASpeakerWithNoWaves() {
    #expect(VolumeIcon.symbol(level: 0, isMuted: false) == "speaker.fill")
}

@Test func theWaveCountRisesWithTheLevel() {
    #expect(VolumeIcon.symbol(level: 0.2, isMuted: false) == "speaker.wave.1.fill")
    #expect(VolumeIcon.symbol(level: 0.5, isMuted: false) == "speaker.wave.2.fill")
    #expect(VolumeIcon.symbol(level: 1, isMuted: false) == "speaker.wave.3.fill")
}

/// Collapsing on mouse-out, and the one case that must not collapse.

@Test func movingThePointerOutOfTheControlCollapsesIt() {
    var state = VolumeControlState()
    _ = state.iconTapped()

    state.pointerExited()
    #expect(state.isExpanded == false)
}

@Test func aDragInProgressHoldsTheControlOpenWhenThePointerStrays() {
    var state = VolumeControlState()
    _ = state.iconTapped()

    // The slider is 10pt tall inside a 36pt pill: a drag that leaves the pill
    // by a few pixels is ordinary aiming, not a decision to close it.
    state.adjustingBegan()
    state.pointerExited()
    #expect(state.isExpanded)
}

@Test func aDragThatStrayedOutsideCollapsesWhenItEnds() {
    var state = VolumeControlState()
    _ = state.iconTapped()

    state.adjustingBegan()
    state.pointerExited()
    state.adjustingEnded()
    #expect(state.isExpanded == false)
}

@Test func aDragThatStaysInsideLeavesTheControlOpen() {
    var state = VolumeControlState()
    _ = state.iconTapped()

    state.adjustingBegan()
    state.adjustingEnded()
    #expect(state.isExpanded)
}

@Test func aStrayFromAnEarlierDragDoesNotCollapseTheNextOne() {
    var state = VolumeControlState()
    _ = state.iconTapped()

    state.adjustingBegan()
    state.pointerExited()
    state.adjustingEnded()

    // Re-opened, dragged, and this time never left: the pending collapse from
    // the previous drag must not survive into it.
    _ = state.iconTapped()
    state.adjustingBegan()
    state.adjustingEnded()
    #expect(state.isExpanded)
}

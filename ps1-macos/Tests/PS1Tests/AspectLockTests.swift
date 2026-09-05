import Testing
import AppKit
@testable import PS1

/// When the 4:3 window lock may be applied.
///
/// The lock coming off for fullscreen was always the rule; what these pin is
/// that `styleMask` is not the thing that answers it. Measured on a real exit
/// (Crash Bandicoot: Warped, internal resolution 8, 1440x900 screen):
///
///     30.580  willExitFullScreen   fsMask=Y  frame=1440x900
///     32.997  applyAspect          fsMask=n  frame=1440x900   -> SNAP 1160x870
///     70.351  didExitFullScreen
///
/// AppKit had already cleared `.fullScreen` from the mask 2.4 s into an exit
/// that otherwise takes 0.6 s, while the window was still fullscreen-sized and
/// still on the fullscreen space. Re-locking there resized that window inside
/// the space — AppKit centres a ratio-locked window on a black desktop — and
/// the exit then did not complete for 37 s. Disabling the lock entirely took
/// the same transition to 0.58 s, which is what identified it.

/// The load-bearing case: the exact state measured at 32.997 above.
@Test func theAspectLockStaysOffWhileAFullscreenExitIsStillInFlight() {
    let wanted = WindowConfigurator.wantedAspect(
        lockAspect: true, styleMaskIsFullScreen: false, transitioning: true)
    #expect(wanted == .zero)
}

/// The other half, so the fix cannot be "never lock again": once the
/// transition has closed, the window goes back to 4:3 — otherwise the picture
/// is letterboxed in windowed mode for the rest of the session.
@Test func theAspectLockComesBackOnceTheExitHasCompleted() {
    let wanted = WindowConfigurator.wantedAspect(
        lockAspect: true, styleMaskIsFullScreen: false, transitioning: false)
    #expect(wanted == WindowConfigurator.aspect)
}

/// Entering is covered by the same flag rather than a second mechanism: the
/// mask does not carry `.fullScreen` yet at `willEnterFullScreen`, which is
/// precisely why that hook existed in the first place.
@Test func theAspectLockIsOffWhileEnteringFullscreenBeforeTheMaskSaysSo() {
    let wanted = WindowConfigurator.wantedAspect(
        lockAspect: true, styleMaskIsFullScreen: false, transitioning: true)
    #expect(wanted == .zero)
}

/// Settled fullscreen, no transition in flight — the mask alone is enough here,
/// and this is the case it was always right about.
@Test func theAspectLockIsOffWhileSettledInFullscreen() {
    let wanted = WindowConfigurator.wantedAspect(
        lockAspect: true, styleMaskIsFullScreen: true, transitioning: false)
    #expect(wanted == .zero)
}

/// Outside a game there is no lock to apply at all, whatever the window is
/// doing — the library and onboarding are ordinary resizable views.
@Test func theAspectLockIsOffWhenNotPlaying() {
    for mask in [true, false] {
        for transitioning in [true, false] {
            let wanted = WindowConfigurator.wantedAspect(
                lockAspect: false, styleMaskIsFullScreen: mask,
                transitioning: transitioning)
            #expect(wanted == .zero)
        }
    }
}

/// The `Probe` is what supplies `transitioning`, so its bookkeeping is pinned
/// too: a WILL opens the window and only the matching DID closes it.
@MainActor
@Test func theProbeReportsATransitionBetweenWillAndDid() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    let probe = WindowConfigurator.Probe()
    window.contentView?.addSubview(probe)

    #expect(probe.inFullScreenTransition == false)

    let center = NotificationCenter.default
    center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    #expect(probe.inFullScreenTransition)

    center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    #expect(probe.inFullScreenTransition == false)

    // The half that was missing, and the one the bug lived in.
    center.post(name: NSWindow.willExitFullScreenNotification, object: window)
    #expect(probe.inFullScreenTransition)

    center.post(name: NSWindow.didExitFullScreenNotification, object: window)
    #expect(probe.inFullScreenTransition == false)
}

/// Clearing the lock must go through `contentResizeIncrements`.
///
/// Assigning `.zero` to `contentAspectRatio` reads back the same and looks
/// equivalent, which is why it survived — but it leaves AppKit in ratio mode
/// with a zero ratio, and the fullscreen-exit restore then divides by it:
///
///     NSInternalInconsistencyException: Invalid parameter not satisfying:
///     CGRectContainsRect(...)  frame={{722, 331}, {713, nan}}
///
/// thrown out of `-[_NSExitFullScreenTransitionController
/// setupWindowForAfterFullScreenExit]`, uncaught, aborting the process. Eleven
/// consecutive fullscreen round trips survive with the increments form and the
/// second one crashed without it.
@MainActor
@Test func clearingTheAspectLockResetsTheResizeIncrements() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)

    window.contentAspectRatio = WindowConfigurator.aspect
    #expect(window.contentAspectRatio == WindowConfigurator.aspect)

    WindowConfigurator.clearAspectLock(on: window)

    // The lock is off...
    #expect(window.contentAspectRatio == .zero)
    // ...and off the way AppKit's own restore path can cope with.
    #expect(window.contentResizeIncrements == NSSize(width: 1, height: 1))
}

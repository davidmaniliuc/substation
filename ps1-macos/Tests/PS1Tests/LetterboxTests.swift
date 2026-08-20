import Testing
@testable import PS1

/// The letterbox scale is the reason a wrongly-shaped window shows black bars
/// rather than a stretched picture — and the reason it used to show a smeared
/// copy of the last texel column on the right, which is what these pin.
@Test func letterboxIsIdentityOnAFourThreeDrawable() {
    let s = letterboxScale(width: 1280, height: 960)
    #expect(s.x == 1)
    #expect(s.y == 1)
}

@Test func letterboxPillarboxesAWideDrawable() {
    // 16:9 — the picture keeps full height and loses width.
    let s = letterboxScale(width: 640, height: 360)
    #expect(abs(s.x - 0.75) < 1e-6)
    #expect(s.y == 1)
}

@Test func letterboxLetterboxesATallDrawable() {
    // 4:5 — the picture keeps full width and loses height.
    let s = letterboxScale(width: 480, height: 600)
    #expect(s.x == 1)
    #expect(abs(s.y - 0.6) < 1e-6)
}

/// The window is aspect-locked, so the ratio lands a hair off 4:3 rather than
/// exactly on it. Without the snap, a scale of 0.99999 blacks out the outermost
/// pixel column for nothing.
@Test func letterboxSnapsToIdentityWithinHalfAPixel() {
    let s = letterboxScale(width: 1280.3, height: 960)
    #expect(s.x == 1)
    #expect(s.y == 1)
}

/// The shader DIVIDES by these, so a zero must not propagate: it would hand the
/// vertex stage a NaN uv, which fails every bounds test and reads garbage.
@Test func letterboxRejectsADegenerateDrawable() {
    #expect(letterboxScale(width: 0, height: 480) == (1, 1))
    #expect(letterboxScale(width: 640, height: 0) == (1, 1))
    #expect(letterboxScale(width: 0, height: 0) == (1, 1))
}

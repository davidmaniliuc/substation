import Testing
import Foundation
@testable import PS1

/// A screenshot is what is on screen: the picture at the internal
/// resolution, in the 4:3 shape the player sees, with no letterbox.
@Suite struct ScreenshotTests {
    @Test func theHeightIsTheDisplayedLinesAtTheScale() {
        #expect(Screenshot.size(displayHeight: 240, scale: 4, enabled: true) == .init(width: 1280, height: 960))
        #expect(Screenshot.size(displayHeight: 480, scale: 2, enabled: true) == .init(width: 1280, height: 960))
        #expect(Screenshot.size(displayHeight: 224, scale: 3, enabled: true) == .init(width: 896, height: 672))
    }

    @Test func aDisabledDisplayIsAPlainBlackFrame() {
        #expect(Screenshot.size(displayHeight: 0, scale: 4, enabled: false) == .init(width: 640, height: 480))
        #expect(Screenshot.size(displayHeight: 0, scale: 4, enabled: true) == .init(width: 640, height: 480))
    }

    @Test func theFileIsNamedForTheGameAndTheMoment() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 10
        parts.hour = 14; parts.minute = 3; parts.second = 22
        let date = Calendar.current.date(from: parts)!
        #expect(Screenshot.fileName(title: "Crash: Warped", at: date)
                == "Crash Warped 2026-10-10 at 14.03.22.png")
        #expect(Screenshot.fileName(title: "AC/DC", at: date) == "AC-DC 2026-10-10 at 14.03.22.png")
    }
}

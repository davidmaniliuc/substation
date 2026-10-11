import Testing
@testable import PS1

/// The Settings window's house style, held for every string it shows.
struct SettingsCopyTests {
    /// No em dash, no en dash, and no double hyphen standing in for either.
    @Test func noLongDashes() {
        for text in SettingsCopy.allText {
            #expect(!text.contains("\u{2014}"), "em dash in: \(text)")
            #expect(!text.contains("\u{2013}"), "en dash in: \(text)")
            #expect(!text.contains("--"), "double hyphen in: \(text)")
        }
    }

    /// Descriptions are full sentences: they end with a full stop.
    @Test func everySentenceIsFinished() {
        for info in SettingsCopy.allInfo {
            if let text = info.description {
                #expect(text.hasSuffix("."), "unfinished sentence in \(info.title): \(text)")
            }
        }
    }

    @Test func titlesAreUnique() {
        let titles = SettingsCopy.allInfo.map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}

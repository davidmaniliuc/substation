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

    /// Summaries and detail are full sentences: they end with a full stop.
    @Test func everySentenceIsFinished() {
        for info in SettingsCopy.allInfo {
            for text in [info.summary, info.details, info.helps, info.caution].compactMap({ $0 }) {
                #expect(text.hasSuffix("."), "unfinished sentence in \(info.title): \(text)")
            }
        }
    }

    /// Every PGXP setting says what it does, where it helps and where it goes
    /// wrong. These are the settings a new player cannot judge by eye.
    @Test func everyPgxpSettingExplainsItsTradeOff() {
        let pgxp = [
            SettingsCopy.pgxp, SettingsCopy.textureCorrection, SettingsCopy.colorCorrection,
            SettingsCopy.culling, SettingsCopy.disable2d, SettingsCopy.depthBuffer,
            SettingsCopy.transparentDepth, SettingsCopy.cpuMode,
            SettingsCopy.preserveProjection, SettingsCopy.vertexCache, SettingsCopy.tolerance,
        ]
        for info in pgxp {
            #expect(info.details != nil, "\(info.title) has no details")
            #expect(info.helps != nil, "\(info.title) does not say where it helps")
            #expect(info.caution != nil, "\(info.title) does not say what to watch for")
        }
    }

    @Test func titlesAreUnique() {
        let titles = SettingsCopy.allInfo.map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}

import Foundation

/// A screenshot is what is on screen: the display pass the window draws,
/// rendered once more into a texture of its own at the internal resolution,
/// in the 4:3 shape the player sees and with no letterbox. The session renders
/// and encodes it (`ps1-metal/src/screenshot.zig`); this names the PNG and
/// saves it in `~/Pictures/Substation/`.
enum Screenshot {
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    /// The displayed lines at the internal scale, and the width that makes
    /// it 4:3, the shape the window shows whatever the horizontal resolution.
    /// A display that is off, or shows no lines, is a black VGA frame.
    static func size(displayHeight: Int, scale: Int, enabled: Bool) -> Size {
        guard enabled, displayHeight > 0 else { return Size(width: 640, height: 480) }
        let height = displayHeight * scale
        return Size(width: Int((Double(height) * 4 / 3).rounded()), height: height)
    }

    /// "Crash Warped 2026-10-10 at 14.03.22.png": the title made safe for a
    /// filename (no `/`, no `:`, which Finder shows as `/`), then the moment.
    static func fileName(title: String, at date: Date) -> String {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(safe.isEmpty ? "Substation" : safe) \(format.string(from: date)).png"
    }

    static var folder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures")
        return pictures.appending(path: "Substation", directoryHint: .isDirectory)
    }

    /// Writes into `folder`, creating it on demand. Two shots in the same
    /// second get " 2", " 3" rather than one replacing the other.
    static func write(_ png: Data, title: String, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName(title: title, at: date)
        var url = folder.appending(path: name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: name.replacingOccurrences(of: ".png", with: " \(n).png"))
            n += 1
        }
        try png.write(to: url, options: .withoutOverwriting)
        return url
    }
}

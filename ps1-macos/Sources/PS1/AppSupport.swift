import Foundation

/// Where the app keeps its own files, and the one-time move out of the folder
/// it wrote to when it was called PS1.
///
/// The path has never depended on the bundle identifier — it is a hardcoded
/// component — so renaming the app does not move it, and that is exactly why
/// a migration is needed rather than nothing at all: left alone, the renamed
/// build would find an empty `Substation/` and every save and every cover
/// would read to the player as lost.
enum AppSupport {
    static let folder = "Substation"
    static let legacyFolder = "PS1"

    /// `<Application Support>/Substation/<component>`, migrated on the way.
    static func directory(_ component: String) -> URL {
        directory(component, in: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    /// The `root` parameter is what makes this testable at all: the real one
    /// is the user's own Application Support folder, which a test must not
    /// touch.
    static func directory(_ component: String, in root: URL) -> URL {
        migrate(component, in: root)
        return root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }

    /// Moves `PS1/<component>` to `Substation/<component>`, once.
    ///
    /// A move rather than a copy: a rename is atomic, so there is no window in
    /// which a half-written second copy of a card is the one a crash leaves
    /// behind, and no moment where the library exists twice.
    ///
    /// A destination that already exists is the live data and is never merged
    /// into or written over — the old folder is left intact instead, since
    /// nothing in the filesystem says which of two `card1.mcd`s is the newer
    /// save, and stranding one is recoverable where overwriting it is not.
    @discardableResult
    static func migrate(_ component: String, in root: URL) -> Bool {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(legacyFolder, isDirectory: true)
        let source = legacy.appendingPathComponent(component, isDirectory: true)
        let destination = root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)

        guard fm.fileExists(atPath: source.path),
              !fm.fileExists(atPath: destination.path)
        else { return false }

        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
        } catch {
            // Nothing to report to: this runs while a store is being built,
            // long before there is a window to put an alert in. A failed move
            // leaves both folders as they were, so the next launch tries again.
            return false
        }

        // The emptied shell goes too, but only once it IS empty — the other
        // store may not have migrated yet, and removing the folder around its
        // data would strand it where nothing looks any more. A stray
        // `.DS_Store` legitimately leaves the empty folder behind.
        if let rest = try? fm.contentsOfDirectory(atPath: legacy.path), rest.isEmpty {
            try? fm.removeItem(at: legacy)
        }
        return true
    }
}

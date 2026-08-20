import Foundation

/// A remembered folder (or file), stored as a security-scoped bookmark rather
/// than a path.
///
/// The app is not sandboxed today, so a path would work. Bookmarks are used
/// anyway because they also survive the user moving or renaming the folder,
/// and because turning sandboxing on later then becomes a settings change
/// rather than a rewrite of every call site.
struct ScopedBookmark: Sendable {
    private let key: String
    private(set) var url: URL?

    init(key: String) {
        self.key = key
        self.url = Self.resolve(key: key)
    }

    mutating func set(_ url: URL) {
        self.url = url
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Runs `body` inside the bookmark's access scope. Returns nil — rather
    /// than throwing — when nothing is remembered, so "not chosen yet" stays a
    /// value the caller can branch on instead of an error path.
    func withAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    /// `.withoutMounting` / `.withoutUI` keep this synchronous on the main
    /// thread: `EmulatorViewModel.init` resolves bookmarks before first paint,
    /// and without them an unreachable network volume makes resolution try to
    /// mount it and hang for the mount timeout instead of returning nil into
    /// onboarding.
    private static func resolve(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutMounting, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
    }
}

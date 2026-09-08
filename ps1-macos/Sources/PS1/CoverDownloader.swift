import Foundation

/// Fetches one URL. A protocol so the download rules are testable without a
/// network: the suite must not depend on GitHub being reachable, and a test
/// that silently passes when offline is worse than no test.
protocol CoverFetching: Sendable {
    /// `nil` means the server said the file is not there — a disc the
    /// collection has no cover for, which is an ordinary outcome and not an
    /// error. Throwing means the fetch itself failed.
    func fetch(_ url: URL) async throws -> Data?
}

struct HTTPCoverFetcher: CoverFetching {
    let session: URLSession = .shared

    func fetch(_ url: URL) async throws -> Data? {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return nil }
        // 404 is the collection not having this serial; anything else in the
        // 400s and 500s is a real failure worth counting separately.
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Downloads covers keyed on the disc's SERIAL.
///
/// The serial is why this is a lookup rather than a fuzzy title match: the
/// collection is named `SLUS-00530.jpg`, and `DiscIdentity` reads exactly that
/// off the disc. A rip named `disc1.cue` finds its cover; a rip named after
/// the wrong game does not find the wrong one.
struct CoverDownloader: Sendable {
    /// Enough to saturate a home connection without opening a socket per game
    /// in a 200-disc library.
    static let maxConcurrent = 4

    let fetcher: CoverFetching
    let source: CoverSource

    struct Summary: Equatable, Sendable {
        var downloaded = 0
        /// Had a cover already, or names no serial to look one up by.
        var skipped = 0
        /// The collection has no cover for this serial.
        var missing = 0
        var failed = 0
    }

    struct Fetched: Sendable {
        let entry: GameEntry
        let data: Data
    }

    /// Returns the images rather than storing them: writing is the caller's,
    /// which keeps this free of `CoverStore`, of the main actor, and of any
    /// notion of what a cover file looks like on disk.
    func fetchCovers(for entries: [GameEntry]) async -> (covers: [Fetched], summary: Summary) {
        var summary = Summary()
        var wanted: [(GameEntry, URL)] = []

        for entry in entries {
            guard let serial = entry.serial, let url = source.url(forSerial: serial) else {
                summary.skipped += 1
                continue
            }
            wanted.append((entry, url))
        }

        var covers: [Fetched] = []
        var next = 0

        // A window of `maxConcurrent` rather than one task per entry: a large
        // library would otherwise open hundreds of connections at once, which
        // GitHub answers with rate limiting rather than covers.
        await withTaskGroup(of: (GameEntry, Result<Data?, any Error>).self) { group in
            func addTask() {
                guard next < wanted.count else { return }
                let (entry, url) = wanted[next]
                next += 1
                group.addTask {
                    do { return (entry, .success(try await fetcher.fetch(url))) }
                    catch { return (entry, .failure(error)) }
                }
            }

            for _ in 0..<Self.maxConcurrent { addTask() }

            while let (entry, result) = await group.next() {
                switch result {
                case .success(let data?): covers.append(Fetched(entry: entry, data: data))
                                          summary.downloaded += 1
                case .success(nil):       summary.missing += 1
                case .failure:            summary.failed += 1
                }
                addTask()
            }
        }

        return (covers, summary)
    }
}

import Foundation

/// The little of a cue sheet this app has to understand: which image files it
/// names, and in what order.
///
/// One place knows the syntax, because two places need it — the disc image
/// concatenated for the core, and the track-1 image handed to identification —
/// and the newline rule below is the kind of thing that must not be reasoned
/// out twice.
enum CueSheet {
    /// Split on `isNewline`, NOT on "\n": every cue a ripper writes is CRLF,
    /// and Swift folds "\r\n" into ONE Character that does not equal "\n" — so
    /// splitting on the scalar returns the whole sheet as a single line. The
    /// FILE match then still succeeds against it and `lastIndex(of:)` picks
    /// the closing quote of the LAST FILE in the sheet, which names nothing. A
    /// one-FILE cue holds exactly two quotes and so survived that by accident;
    /// a per-track rip did not.
    static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// The quoted image name a `FILE` line carries, or nil for any other line.
    static func imageName(inLine raw: Substring) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.uppercased().hasPrefix("FILE "),
              let open = line.firstIndex(of: "\""),
              let close = line.lastIndex(of: "\""),
              open < close
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    /// The first image the sheet names — track 1, and the only track that
    /// carries a filesystem to identify.
    static func firstImageName(in text: String) -> String? {
        for line in lines(of: text) {
            if let name = imageName(inLine: line) { return name }
        }
        return nil
    }
}

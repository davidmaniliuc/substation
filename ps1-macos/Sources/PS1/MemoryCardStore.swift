import Foundation

/// The two memory cards, on disk.
///
/// ONE shared pair for the whole library, like a console with two cards in it,
/// rather than a card per game. A multi-disc game then finds its own save on
/// disc 2 because it is the same card (which is also what happens on
/// hardware), and a sequel finds its predecessor's for the same reason. The
/// cost is that 15 blocks is a hard cap, managed through the BIOS card
/// manager, which is why the second slot exists. DuckStation defaults to
/// per-game cards instead: unlimited capacity, neither of those behaviours.
///
/// The format is a raw 131072-byte image per slot, the `.mcd` layout
/// DuckStation and the PCSX line read, so a save can be carried in or out.
final class MemoryCardStore: Sendable {
    static let bytes = 128 * 1024
    static let slots = 2

    /// Where the two `.mcd` files live, which a session is handed to read
    /// and write them.
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? AppSupport.directory("MemoryCards")
    }
}

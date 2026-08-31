import Foundation

/// The two memory cards, on disk.
///
/// ONE shared pair for the whole library, like a console with two cards in it,
/// rather than a card per game. A multi-disc game then finds its own save on
/// disc 2 because it is the same card — which is also what happens on
/// hardware — and a sequel finds its predecessor's for the same reason. The
/// cost is that 15 blocks is a hard cap, managed through the BIOS card
/// manager, which is why the second slot exists. DuckStation defaults to
/// per-game cards instead: unlimited capacity, neither of those behaviours.
///
/// The format is a raw 131072-byte image per slot, the `.mcd` layout
/// DuckStation and the PCSX line read, so a save can be carried in or out.
final class MemoryCardStore: Sendable {
    static let bytes = 128 * 1024
    static let slots = 2

    private let directory: URL

    /// Every access, read and write, goes through one queue. The write is
    /// debounced onto the emulator thread while the read happens on the main
    /// actor as a game is installed, and a card is the one piece of state
    /// those two share.
    private let queue = DispatchQueue(label: "PS1.MemoryCardStore")

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PS1/MemoryCards", isDirectory: true)
    }

    /// `nil` for a card that has never been written, and for a file that is
    /// not exactly one card long — see the test for why it is not padded.
    func load(slot: Int) -> Data? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(slot: slot)),
                  data.count == Self.bytes
            else { return nil }
            return data
        }
    }

    /// Synchronous on purpose. Both callers want it that way: the debounce
    /// runs on the emulator thread between frames, where a 128 KB write is
    /// nothing beside the frame it sits next to, and the flush on eject and
    /// quit must not outlive the process that started it.
    func write(_ data: Data, slot: Int) {
        guard data.count == Self.bytes else { return }
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL(slot: slot), options: .atomic)
            } catch {
                // Silent loss here is the one failure this whole feature exists to prevent.
                NSLog("PS1: memory card slot \(slot + 1) failed to write: \(error)")
            }
        }
    }

    private func fileURL(slot: Int) -> URL {
        directory.appendingPathComponent("card\(slot + 1).mcd")
    }
}

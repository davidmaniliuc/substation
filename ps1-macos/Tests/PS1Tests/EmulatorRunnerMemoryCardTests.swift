import Testing
import Foundation
@testable import PS1

/// Coverage for the piece nothing else touches: the runner composing the
/// policy, the store and the ABI drain into "a save reaches disk".
/// `MemoryCardFlushPolicy` is tested alone, `MemoryCardStore` is tested alone,
/// and the ABI drain (`ps1_take_memcard`) is tested in Zig — but until now
/// nothing constructed an `EmulatorRunner` with a `cards:` store at all, so
/// the branch where `core.takeMemcard` returns non-nil had never executed in
/// any Swift test.
///
/// `ps1_load_memcard` clears the dirty flag by design (loading an image is
/// not a write BY the machine), so there is no way to stage a dirty card from
/// Swift without actually running a game through the BIOS card driver — which
/// needs a disc and is exactly what this suite is built to avoid depending
/// on. These tests therefore cover what IS reachable without that: that a
/// flush with nothing pending writes no file, and that `writePendingCards`
/// — staged directly, bypassing the ABI drain it would otherwise come from —
/// puts the right bytes in the right slot file. The one span still
/// uncovered by any automated test is `takeCards()` itself actually seeing a
/// non-nil image back from `core.takeMemcard`.

private func makeStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("memcards-runner-\(UUID().uuidString)")
}

private func makeImage(_ fill: UInt8) -> Data {
    Data(repeating: fill, count: MemoryCardStore.bytes)
}

@Test func flushingWithNothingPendingWritesNoFile() throws {
    let directory = makeStoreDirectory()
    let store = MemoryCardStore(directory: directory)
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192),
                                cards: store)

    // No game has run, so the core has never dirtied a card: `takeCards()`
    // inside `flushMemoryCards()` finds nothing for either slot.
    runner.flushMemoryCards()

    #expect(store.load(slot: 0) == nil)
    #expect(store.load(slot: 1) == nil)
    // The write path only creates the directory once it actually has bytes
    // to put there — a flush that finds nothing pending must not conjure one.
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func writePendingCardsPutsTheRightBytesInTheRightSlotFile() throws {
    let directory = makeStoreDirectory()
    let store = MemoryCardStore(directory: directory)
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192),
                                cards: store)

    // Staged directly rather than through the ABI drain — see the file
    // comment for why that half cannot be reached from a Swift test.
    runner.pendingCards[1] = makeImage(0x5A)
    runner.writePendingCards(to: store)

    #expect(store.load(slot: 1) == makeImage(0x5A))
    // Slot 0 was never staged and must be untouched.
    #expect(store.load(slot: 0) == nil)
    // The backlog is cleared once written, same as a real flush leaves it.
    #expect(runner.pendingCards.isEmpty)
}

@Test func writePendingCardsWritesEverySlotThatWasStaged() throws {
    let directory = makeStoreDirectory()
    let store = MemoryCardStore(directory: directory)
    let runner = EmulatorRunner(core: try Ps1Core(), ring: AudioRing(capacity: 8192),
                                cards: store)

    runner.pendingCards[0] = makeImage(0x11)
    runner.pendingCards[1] = makeImage(0x22)
    runner.writePendingCards(to: store)

    #expect(store.load(slot: 0) == makeImage(0x11))
    #expect(store.load(slot: 1) == makeImage(0x22))
}

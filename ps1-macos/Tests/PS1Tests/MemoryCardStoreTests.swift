import Testing
import Foundation
@testable import PS1

private func makeStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("memcards-\(UUID().uuidString)")
}

private func makeImage(_ fill: UInt8) -> Data {
    Data(repeating: fill, count: MemoryCardStore.bytes)
}

@Test func aCardThatWasNeverWrittenLoadsAsNil() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    #expect(store.load(slot: 0) == nil)
    #expect(store.load(slot: 1) == nil)
}

@Test func aCardReadsBackByteForByte() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(makeImage(0x5A), slot: 0)

    let loaded = store.load(slot: 0)
    #expect(loaded == makeImage(0x5A))
}

@Test func theTwoSlotsAreSeparateFiles() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(makeImage(0x11), slot: 0)
    store.write(makeImage(0x22), slot: 1)

    #expect(store.load(slot: 0) == makeImage(0x11))
    #expect(store.load(slot: 1) == makeImage(0x22))
}

@Test func aFileOfTheWrongSizeIsRefusedRatherThanPadded() throws {
    // A short file is far more likely a botched copy than a card worth
    // salvaging, and refusing it presents as "unformatted" — which the BIOS
    // offers to fix — instead of as corrupt save data.
    let directory = makeStoreDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 0xFF, count: 4096)
        .write(to: directory.appendingPathComponent("card1.mcd"))

    let store = MemoryCardStore(directory: directory)
    #expect(store.load(slot: 0) == nil)
}

@Test func writingRefusesAnImageOfTheWrongSize() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(Data(repeating: 0x01, count: 100), slot: 0)
    #expect(store.load(slot: 0) == nil)
}

@Test func aSecondWriteReplacesTheFirst() {
    let store = MemoryCardStore(directory: makeStoreDirectory())
    store.write(makeImage(0x01), slot: 0)
    store.write(makeImage(0x02), slot: 0)
    #expect(store.load(slot: 0) == makeImage(0x02))
}

@Test func theFileNamesAreTheOnesOtherEmulatorsRead() {
    // Raw 131072-byte .mcd, one file per slot, so a save can be carried in
    // from or out to DuckStation and the PCSX line.
    let directory = makeStoreDirectory()
    let store = MemoryCardStore(directory: directory)
    store.write(makeImage(0x33), slot: 1)

    let url = directory.appendingPathComponent("card2.mcd")
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try! Data(contentsOf: url).count == MemoryCardStore.bytes)
}

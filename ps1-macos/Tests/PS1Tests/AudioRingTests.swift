import Testing
@testable import PS1

private func write(_ ring: AudioRing, _ values: [Float]) -> Int {
    var v = values
    return v.withUnsafeMutableBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
}

private func read(_ ring: AudioRing, _ count: Int) -> [Float] {
    var out = [Float](repeating: .nan, count: count)
    let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
    return Array(out.prefix(n))
}

@Test func startsEmpty() {
    let ring = AudioRing(capacity: 8)
    #expect(ring.filled == 0)
    #expect(ring.freeSpace == 8)
}

@Test func writeThenReadRoundTrips() {
    let ring = AudioRing(capacity: 8)
    #expect(write(ring, [1, 2, 3, 4]) == 4)
    #expect(ring.filled == 4)
    #expect(read(ring, 4) == [1, 2, 3, 4])
    #expect(ring.filled == 0)
}

@Test func readOfAnEmptyRingReturnsNothing() {
    let ring = AudioRing(capacity: 8)
    #expect(read(ring, 4).isEmpty)
}

@Test func partialReadLeavesTheRemainder() {
    let ring = AudioRing(capacity: 8)
    _ = write(ring, [1, 2, 3, 4])
    #expect(read(ring, 2) == [1, 2])
    #expect(ring.filled == 2)
    #expect(read(ring, 2) == [3, 4])
}

@Test func writeIsCappedByFreeSpaceAndNeverOverwrites() {
    let ring = AudioRing(capacity: 8)
    // Capacity 8 holds at most 8 samples; a full ring accepts no more.
    #expect(write(ring, [1, 2, 3, 4, 5, 6, 7, 8]) == 8)
    #expect(ring.freeSpace == 0)
    #expect(write(ring, [9, 10]) == 0)
    #expect(read(ring, 8) == [1, 2, 3, 4, 5, 6, 7, 8])
}

@Test func wrapsAroundWithoutLosingSamples() {
    let ring = AudioRing(capacity: 8)
    _ = write(ring, [1, 2, 3, 4, 5, 6])
    #expect(read(ring, 4) == [1, 2, 3, 4])   // read index now at 4
    #expect(write(ring, [7, 8, 9, 10]) == 4) // writes wrap past the end
    #expect(read(ring, 6) == [5, 6, 7, 8, 9, 10])
    #expect(ring.filled == 0)
}

@Test func underrunReadReturnsOnlyWhatIsThere() {
    let ring = AudioRing(capacity: 8)
    _ = write(ring, [1, 2])
    let got = read(ring, 6)
    #expect(got == [1, 2])
}

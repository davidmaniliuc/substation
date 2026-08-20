import Testing
@testable import PS1

@Test func idleMaskIsAllOnesBecauseZeroMeansPressed() {
    let map = InputMap()
    #expect(map.mask == 0xFFFF)
}

@Test func pressingClearsExactlyOneBit() {
    var map = InputMap()
    map.press(.cross)
    #expect(map.mask == 0xFFFF & ~PadButton.cross.rawValue)
    #expect(map.mask != 0xFFFF)
}

@Test func releasingRestoresTheBit() {
    var map = InputMap()
    map.press(.start)
    map.release(.start)
    #expect(map.mask == 0xFFFF)
}

@Test func simultaneousPressesClearAllTheirBits() {
    var map = InputMap()
    map.press(.up)
    map.press(.cross)
    map.press(.r1)
    let expected = 0xFFFF & ~(PadButton.up.rawValue | PadButton.cross.rawValue | PadButton.r1.rawValue)
    #expect(map.mask == expected)
}

@Test func releasingOneOfSeveralLeavesTheOthersPressed() {
    var map = InputMap()
    map.press(.up)
    map.press(.cross)
    map.release(.up)
    #expect(map.mask == 0xFFFF & ~PadButton.cross.rawValue)
}

@Test func repeatedPressIsIdempotent() {
    var map = InputMap()
    map.press(.square)
    let once = map.mask
    map.press(.square)
    #expect(map.mask == once)
}

@Test func resetReturnsToIdle() {
    var map = InputMap()
    map.press(.up)
    map.press(.circle)
    map.reset()
    #expect(map.mask == 0xFFFF)
}

@Test func everyButtonOwnsADistinctBit() {
    var seen: UInt16 = 0
    for b in PadButton.allCases {
        #expect(b.rawValue.nonzeroBitCount == 1)
        #expect(seen & b.rawValue == 0)
        seen |= b.rawValue
    }
    #expect(seen == 0xFFFF)
}

/// The three bits ps1-trace's autostart driver pokes directly. If these ever
/// disagree, the core and this map have drifted apart.
@Test func bitPositionsMatchTheOnesPs1TraceUses() {
    #expect(PadButton.start.rawValue == 1 << 3)
    #expect(PadButton.circle.rawValue == 1 << 13)
    #expect(PadButton.cross.rawValue == 1 << 14)
}

@Test func arrowKeysMapToTheDPad() {
    #expect(InputMap.button(forKey: 126) == .up)
    #expect(InputMap.button(forKey: 125) == .down)
    #expect(InputMap.button(forKey: 123) == .left)
    #expect(InputMap.button(forKey: 124) == .right)
}

@Test func unmappedKeyReturnsNil() {
    #expect(InputMap.button(forKey: 999) == nil)
}

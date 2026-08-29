import Testing
@testable import PS1

@Test func aHorizontalLineIsOnePixelPerColumnInclusive() {
    let r = LineExpander.walk(x0: 10, y0: 5, x1: 14, y1: 5)!
    #expect(r.total == 4)
    #expect(r.steps.map { ($0.x, $0.y, $0.k) }.map { "\($0.0),\($0.1),\($0.2)" }
            == ["10,5,0", "11,5,1", "12,5,2", "13,5,3", "14,5,4"])
}

@Test func aZeroLengthLineIsExactlyOnePixel() {
    // `steps == 0`, and the shaded path must not divide by it.
    let r = LineExpander.walk(x0: 3, y0: 3, x1: 3, y1: 3)!
    #expect(r.total == 0)
    #expect(r.steps.count == 1)
    #expect(r.steps[0].x == 3 && r.steps[0].y == 3 && r.steps[0].k == 0)
}

@Test func allEightOctantsEndOnTheirEndpoint() {
    // A swapped dx/dy or a dropped sign shows up as a line that stops short or
    // walks the wrong way; nothing else in the suite would notice.
    for (dx, dy) in [(9, 2), (2, 9), (-2, 9), (-9, 2), (-9, -2), (-2, -9), (2, -9), (9, -2)] {
        let r = LineExpander.walk(x0: 50, y0: 50, x1: 50 + dx, y1: 50 + dy)!
        #expect(r.steps.last!.x == 50 + dx, "octant \(dx),\(dy)")
        #expect(r.steps.last!.y == 50 + dy, "octant \(dx),\(dy)")
        #expect(r.total == max(abs(dx), abs(dy)))
        #expect(r.steps.count == r.total + 1)
        #expect(r.steps.last!.k == r.total)
    }
}

@Test func anOversizedLineIsDroppedNotClipped() {
    // The same 1023x511 refusal the triangle path applies.
    #expect(LineExpander.walk(x0: 0, y0: 0, x1: 1024, y1: 0) == nil)
    #expect(LineExpander.walk(x0: 0, y0: 0, x1: 0, y1: 512) == nil)
    #expect(LineExpander.walk(x0: 0, y0: 0, x1: 1023, y1: 511) != nil)
}

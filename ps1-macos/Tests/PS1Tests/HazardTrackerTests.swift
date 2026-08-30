import Testing
import CPs1
@testable import PS1

@Test func aDrawThatSamplesNothingNeverBreaksThePass() {
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 0, x1: 100, y1: 100))
    #expect(h.needsBreak(sampling: []) == false)
}

@Test func samplingOutsideTheDirtyRectDoesNotBreakThePass() {
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 0, x1: 63, y1: 63))
    #expect(h.needsBreak(sampling: [VramRect(x0: 256, y0: 0, x1: 319, y1: 63)]) == false)
}

@Test func samplingWhatThisPassWroteBreaksIt() {
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 0, x1: 63, y1: 63))
    #expect(h.needsBreak(sampling: [VramRect(x0: 60, y0: 60, x1: 200, y1: 200)]) == true)
    // Breaking RESETS the dirty rect: the new pass has written nothing yet,
    // so the very next draw must not break again for the same reason.
    #expect(h.needsBreak(sampling: [VramRect(x0: 60, y0: 60, x1: 200, y1: 200)]) == false)
}

@Test func theClutRowIsCheckedSeparatelyFromTheTexturePage() {
    // A CLUT is one row, usually far from the page. Folding the two into one
    // bounding rect would span everything between them and split passes that
    // do not need splitting — which is a performance bug, not a correctness
    // one, and therefore invisible to every hash gate.
    var h = HazardTracker()
    h.markWritten(VramRect(x0: 0, y0: 480, x1: 255, y1: 480))   // a CLUT row
    let page = VramRect(x0: 512, y0: 0, x1: 575, y1: 255)
    let clut = VramRect(x0: 0, y0: 480, x1: 255, y1: 480)
    #expect(h.needsBreak(sampling: [page]) == false)
    h.markWritten(VramRect(x0: 0, y0: 480, x1: 255, y1: 480))
    #expect(h.needsBreak(sampling: [page, clut]) == true)
}

@Test func aTexturedTriangleReportsItsPageAndClutAtTheRightDepth() {
    var inst = Ps1PrimInstance()
    inst.kind = Int32(PS1_PRIM_TEXTURED_TRI)
    inst.tex_depth = 0          // 4bpp: u/4, so 64 words wide
    inst.tpage_x = 320
    inst.tpage_y = 256
    inst.clut_x = 640
    inst.clut_y = 300
    let rects = PrimBuilder.sampledRects(of: inst)
    #expect(rects.count == 2)
    #expect(rects[0] == VramRect(x0: 320, y0: 256, x1: 383, y1: 511))
    #expect(rects[1] == VramRect(x0: 640, y0: 300, x1: 655, y1: 300))

    inst.tex_depth = 1          // 8bpp: 128 words
    #expect(PrimBuilder.sampledRects(of: inst)[0].x1 == 447)
    inst.tex_depth = 2          // 16bpp: 256 words, and no CLUT read at all
    #expect(PrimBuilder.sampledRects(of: inst)[0].x1 == 575)
    #expect(PrimBuilder.sampledRects(of: inst).count == 1)
}

@Test func aPageOnVramsLastRowWrapsToRowZeroNotRow512() {
    // tpage_y is only ever 0 or 256 (applyTexture), so a page's last row is
    // only ever 255 or 511 — never anything that could extend to a real
    // "next row" past 511. ps1_vram_read masks the linear index with
    // `& 0x7FFFF` over the WHOLE 1024x512 space (0x7FFFF+1 == 524288 ==
    // 1024*512), so row 511's overflow wraps to row 0, not to a nonexistent
    // row 512.
    var inst = Ps1PrimInstance()
    inst.kind = Int32(PS1_PRIM_TEXTURED_TRI)
    inst.tex_depth = 2          // 16bpp, 256 words wide, no CLUT
    inst.tpage_x = 960          // 960 + 255 = 1215 >= 1024: this page wraps
    inst.tpage_y = 256          // last sampled row is 256 + 255 = 511
    let rects = PrimBuilder.sampledRects(of: inst)
    #expect(rects.count == 2)
    #expect(rects[0] == VramRect(x0: 0, y0: 256, x1: 1023, y1: 511))
    #expect(rects[1] == VramRect(x0: 0, y0: 0, x1: 1023, y1: 0))

    // The exact worked address: u = 255 at tpage_x = 960 is column 1215 in
    // row 511. lin = 511*1024 + 1215 = 524479; & 0x7FFFF = 191, i.e. row 0,
    // column 191 — inside rects[1], nowhere near rects[0].
    let wrapped = VramRect(x0: 191, y0: 0, x1: 191, y1: 0)
    #expect(rects[1].intersects(wrapped))
    #expect(!rects[0].intersects(wrapped))
}

@Test func aClutOnVramsLastRowWrapsToRowZeroNotRow512() {
    // clut_y is a 9-bit field, so 511 (VRAM's last row) is a legal CLUT
    // position — same wraparound rule as the page case above, just with a
    // 1-row-tall span instead of a 256-row one.
    var inst = Ps1PrimInstance()
    inst.kind = Int32(PS1_PRIM_TEXTURED_TRI)
    inst.tex_depth = 1          // 8bpp: 256-entry CLUT row
    inst.tpage_x = 0
    inst.tpage_y = 0            // the page itself does not wrap
    inst.clut_x = 784           // 784 + 255 = 1039 >= 1024: this CLUT wraps
    inst.clut_y = 511
    let rects = PrimBuilder.sampledRects(of: inst)
    #expect(rects.count == 3)   // 1 page rect + 2 CLUT rects
    #expect(rects[1] == VramRect(x0: 0, y0: 511, x1: 1023, y1: 511))
    #expect(rects[2] == VramRect(x0: 0, y0: 0, x1: 1023, y1: 0))

    // 784..1023 (240 columns) stays in row 511; the remaining 16 entries
    // (784+240 .. 784+255, i.e. columns 1024..1039) wrap: lin = 511*1024 +
    // 1024 = 524288, & 0x7FFFF = 0, i.e. row 0 column 0, counting up to
    // column 15 for the last entry — inside rects[2], nowhere near rects[1].
    let wrapped = VramRect(x0: 0, y0: 0, x1: 15, y1: 0)
    #expect(rects[2].intersects(wrapped))
    #expect(!rects[1].intersects(wrapped))
}

@Test func writingWhatThisPassSampledBreaksItToo() {
    // The mirror of `samplingWhatThisPassWroteBreaksIt`, and the half that was
    // missing until 2026-08-30. A read during a pass resolves against device
    // memory; a write during the same pass reaches device memory only when its
    // tile is stored. The two land in different tiles here — the sampled page
    // and the drawn box are far apart — so which one wins is decided by tile
    // scheduling, and it presents as a RACE, not as a stable wrong pixel.
    var h = HazardTracker()
    h.markRead([VramRect(x0: 256, y0: 256, x1: 319, y1: 511)])
    h.markWritten(VramRect(x0: 300, y0: 20, x1: 380, y1: 90))

    // A write that misses every sampled rect is free.
    #expect(h.needsBreak(writing: VramRect(x0: 0, y0: 0, x1: 63, y1: 63)) == false)
    // One that lands inside the sampled page is not.
    #expect(h.needsBreak(writing: VramRect(x0: 256, y0: 256, x1: 287, y1: 287)) == true)
    // Breaking clears the read set, exactly as it clears the dirty rect: the
    // new pass has sampled nothing yet.
    #expect(h.needsBreak(writing: VramRect(x0: 256, y0: 256, x1: 287, y1: 287)) == false)
}

@Test func readRectsAreKeptAsAListRatherThanUnionedTogether() {
    // Two pages that sit apart: their union spans everything between them, and
    // a write landing in that gap would break a pass it need not. Measured,
    // that difference is 13,767 passes against 266 over silent-hill-usa.
    var h = HazardTracker()
    h.markRead([VramRect(x0: 0, y0: 0, x1: 63, y1: 255)])
    h.markRead([VramRect(x0: 896, y0: 0, x1: 959, y1: 255)])
    #expect(h.needsBreak(writing: VramRect(x0: 400, y0: 100, x1: 500, y1: 150)) == false)
    #expect(h.needsBreak(writing: VramRect(x0: 900, y0: 100, x1: 910, y1: 150)) == true)
}

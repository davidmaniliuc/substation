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

import Testing
import CPs1
@testable import PS1

private func env(_ cmds: [(UInt8, UInt32)]) -> DrawEnv {
    var e = DrawEnv()
    for (op, v) in cmds {
        var c = Ps1GpuCommand()
        c.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
        c.opcode = op
        c.value = v
        e.apply(c)
    }
    return e
}

@Test func theSixRegistersLandWhereRegistersZigPutsThem() {
    let e = env([(0xE1, 0x0000_02A5), (0xE2, 0x1234), (0xE3, 0x0004_0005),
                 (0xE4, 0x0008_0009), (0xE5, 0x00AB), (0xE6, 3)])
    #expect(e.drawMode == 0x0000_02A5)
    #expect(e.texWindow == 0x1234)
    #expect(e.areaTopLeft == 0x0004_0005)
    #expect(e.areaBotRight == 0x0008_0009)
    #expect(e.offset == 0x00AB)
    #expect(e.maskBit == 3)
    #expect(e.maskSet && e.maskCheck)
    #expect(e.ditherEnabled)              // bit 9 of 0x2A5
    #expect(e.blendMode == 1)             // bits 5-6 of 0x2A5
}

@Test func gp1_09GatesTheTextureDisableBit() {
    // Until the BIOS enables it, E1 bit 11 is forced to 0 wherever it would
    // otherwise be written. This is a real boot-order behaviour, not a
    // formality: a fixture's env-sync prologue replays
    // set_texture_disable_allowed FIRST for exactly this reason.
    var e = DrawEnv()
    var e1 = Ps1GpuCommand()
    e1.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    e1.opcode = 0xE1
    e1.value = 1 << 11
    e.apply(e1)
    #expect(e.drawMode == 0)

    var allow = Ps1GpuCommand()
    allow.kind = UInt8(PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED.rawValue)
    allow.value = 1
    e.apply(allow)
    e.apply(e1)
    #expect(e.drawMode == 1 << 11)
}

@Test func latchPolygonTexpageWritesOnlyTheNineMaskedBits() {
    // A textured POLYGON copies its texpage attribute into E1 so a later
    // GPUSTAT read sees it. Rectangles do NOT — they use the current texpage
    // instead of carrying one. The mask is 0b0000_1001_1111_1111: texpage x/y,
    // the semi-transparency mode, the colour depth, and texture-disable.
    var e = env([(0xE1, 0xFFFF_FFFF)])
    let before = e.drawMode
    var latch = Ps1GpuCommand()
    latch.kind = UInt8(PS1_GPU_LATCH_TEXPAGE.rawValue)
    latch.tpage = 0x0044        // page x 4, blend mode 2
    e.apply(latch)

    #expect(e.drawMode & 0b0000_1001_1111_1111 == 0x0044)
    #expect(e.drawMode & ~UInt32(0b0000_1001_1111_1111) == before & ~UInt32(0b0000_1001_1111_1111))
    // Bit 11 stays clear because textureDisableAllowed is still false, which
    // is also why the 0xFFFFFFFF E1 write above never set it either.
    #expect(e.drawMode & (1 << 11) == 0)
}

@Test func theDrawingOffsetIsTwoElevenBitSignedFields() {
    // 0x7FF is -1, not 2047. Getting this wrong shifts every primitive in
    // every game by up to 2048 pixels, which reads as "nothing is drawn".
    #expect(env([(0xE5, 0x0000_0000)]).offsetX == 0)
    #expect(env([(0xE5, 0x0000_07FF)]).offsetX == -1)
    #expect(env([(0xE5, 0x0000_0400)]).offsetX == -1024)
    #expect(env([(0xE5, 0x0000_03FF)]).offsetX == 1023)
    #expect(env([(0xE5, 0x07FF << 11)]).offsetY == -1)
    #expect(env([(0xE5, 0x03FF << 11)]).offsetY == 1023)
    #expect(env([(0xE5, (0x400 << 11) | 0x400)]).offsetY == -1024)
}

@Test func theClipRectIsTwoTenBitFieldsAndIsInclusive() {
    let e = env([(0xE3, (7 << 10) | 3), (0xE4, (200 << 10) | 150)])
    #expect(e.clip.x0 == 3)
    #expect(e.clip.y0 == 7)
    #expect(e.clip.x1 == 150)
    #expect(e.clip.y1 == 200)
}

@Test func resetReturnsEveryRegisterToItsDefault() {
    var e = env([(0xE1, 0xFFFF), (0xE3, 0x1234), (0xE6, 3)])
    var allow = Ps1GpuCommand()
    allow.kind = UInt8(PS1_GPU_SET_TEXTURE_DISABLE_ALLOWED.rawValue)
    allow.value = 1
    e.apply(allow)

    var reset = Ps1GpuCommand()
    reset.kind = UInt8(PS1_GPU_RESET_DRAW_ENV.rawValue)
    e.apply(reset)

    #expect(e.drawMode == 0 && e.areaTopLeft == 0 && e.maskBit == 0)
    #expect(e.textureDisableAllowed == false)
    // The default clip rect is DEGENERATE — area_bot_right is 0, so nothing
    // draws until E3/E4 are programmed. That is why a fixture's window has to
    // carry an env-sync prologue.
    #expect(e.clip.x1 == 0 && e.clip.y1 == 0)
}

import CPs1
import Testing
@testable import PS1

/// `SessionSettings` as it crosses `ps1_session_set_settings`.
struct SessionSettingsTests {
    @Test func theHeaderAgreesOnTheSize() {
        #expect(MemoryLayout<Ps1SessionSettings>.size == 64)
    }

    @Test func aSettingsValueCrossesFieldForField() {
        let pgxp = PgxpSettings(enabled: true, cpu: true, culling: true, vertexCache: true,
                                textureCorrection: true, colorCorrection: true, depthBuffer: true,
                                transparentDepth: true, disable2d: true, preserveProjection: true,
                                tolerance: 2)
        let s = SessionSettings(gain: 0.5, cpuEngine: .recompiler, runaheadFrames: 2,
                                rewindBudget: 256 << 20, scale: 4, dither: .native,
                                textureFilter: .bilinear, spriteFilter: .bilinear, pgxp: pgxp,
                                pgxpUsePresets: true, vramReadbacks: .off)
        let c = s.c
        #expect(c.size == 64)
        #expect(c.gain == 0.5)
        #expect(c.cpu_engine == 2)
        #expect(c.runahead == 2)
        #expect(c.rewind_budget == 256 << 20)
        #expect(c.scale == 4)
        #expect(c.dither == 1)
        #expect(c.texture_filter == 1)
        #expect(c.sprite_filter == 1)
        #expect(c.pgxp.enabled == 1)
        #expect(c.pgxp.cpu == 1)
        #expect(c.pgxp.culling == 1)
        #expect(c.pgxp.vertex_cache == 1)
        #expect(c.pgxp.texture_correction == 1)
        #expect(c.pgxp.color_correction == 1)
        #expect(c.pgxp.depth_buffer == 1)
        #expect(c.pgxp.transparent_depth == 1)
        #expect(c.pgxp.disable_2d == 1)
        #expect(c.pgxp.preserve_projection == 1)
        #expect(c.pgxp.tolerance == 2)
        #expect(c.pgxp_use_presets == 1)
        #expect(c.vram_readbacks == 2)
    }
}

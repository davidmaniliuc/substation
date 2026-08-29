import Foundation
import CPs1

/// Turns one recorded drawing command into instance records.
///
/// Split from `MetalRasterizer` so neither file grows past readable size: the
/// encoder owns passes and resources, this owns the per-primitive geometry
/// that mirrors `gpu/renderer.zig`'s CPU-side setup — the offset, the
/// oversized-primitive refusal, and the bounding box.
enum PrimBuilder {
    /// Everything a primitive inherits from the drawing environment.
    static func base(_ env: DrawEnv) -> Ps1PrimInstance {
        var inst = Ps1PrimInstance()
        let clip = env.clip
        (inst.clip_x0, inst.clip_y0, inst.clip_x1, inst.clip_y1) =
            (Int32(clip.x0), Int32(clip.y0), Int32(clip.x1), Int32(clip.y1))
        inst.blend_mode = env.blendMode
        inst.tex_window = env.texWindow
        inst.flags = (env.maskSet ? PS1_PRIM_SET_MASK : 0)
            | (env.maskCheck ? PS1_PRIM_CHECK_MASK : 0)
            | (env.ditherEnabled ? PS1_PRIM_DITHER : 0)
        return inst
    }

    /// One triangle. A record always carries exactly one — `gp0.zig` already
    /// decomposes quads into two `draw_triangle`/`draw_shaded_triangle`
    /// records — so the oversized refusal is judged per triangle, each half of
    /// a quad separately, exactly as `renderer.zig:123-124` does, without this
    /// function having to know about quads at all.
    ///
    /// Returns nil for every case the software rasterizer refuses outright: an
    /// oversized span, a degenerate area, or an empty box after clipping.
    static func triangle(_ cmd: Ps1GpuCommand, env: DrawEnv, kind: Int32) -> Ps1PrimInstance? {
        let verts = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
            let p = raw.bindMemory(to: Ps1GpuVertex.self)
            return [p[0], p[1], p[2]]
        }
        let ox = env.offsetX, oy = env.offsetY
        let vx = verts.map { Int($0.x) + ox }
        let vy = verts.map { Int($0.y) + oy }

        // Hardware refuses any primitive whose vertices span 1024 or more
        // horizontally, or 512 or more vertically — it is not clipped, it is
        // DROPPED. Games lean on that: geometry crossing the near plane
        // projects to saturated screen coordinates, and the drop is what keeps
        // it off the screen.
        guard vx.max()! - vx.min()! < 1024, vy.max()! - vy.min()! < 512 else { return nil }

        // Twice the signed area; zero means degenerate and nothing is drawn.
        let area = (vx[1] - vx[0]) * (vy[2] - vy[0]) - (vy[1] - vy[0]) * (vx[2] - vx[0])
        guard area != 0 else { return nil }

        let clip = env.clip
        let x0 = max(clip.x0, max(0, vx.min()!))
        let x1 = min(clip.x1, min(MetalVram.width - 1, vx.max()!))
        let y0 = max(clip.y0, max(0, vy.min()!))
        let y1 = min(clip.y1, min(MetalVram.height - 1, vy.max()!))
        guard x0 <= x1, y0 <= y1 else { return nil }

        var inst = base(env)
        inst.kind = kind
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(x0), Int32(y0), Int32(x1), Int32(y1))
        (inst.x0, inst.y0) = (Int32(vx[0]), Int32(vy[0]))
        (inst.x1, inst.y1) = (Int32(vx[1]), Int32(vy[1]))
        (inst.x2, inst.y2) = (Int32(vx[2]), Int32(vy[2]))
        (inst.u0, inst.v0) = (Int32(verts[0].u), Int32(verts[0].v))
        (inst.u1, inst.v1) = (Int32(verts[1].u), Int32(verts[1].v))
        (inst.u2, inst.v2) = (Int32(verts[2].u), Int32(verts[2].v))
        (inst.c0, inst.c1, inst.c2) = (verts[0].color, verts[1].color, verts[2].color)
        inst.color = cmd.value & 0xFFFF
        if cmd.transparent != 0 { inst.flags |= PS1_PRIM_TRANSPARENT }
        return inst
    }

    /// `clut` and `tpage` decoded exactly as `renderer.zig:455-459` does.
    /// `tpage & 0xF` is the page X in 64-pixel units; bit 4 is page Y (0 or
    /// 256); bits 7-8 the colour depth. The clut row is 9 bits — it can reach
    /// row 511 — and `clut_x` is in 16-pixel units.
    static func applyTexture(_ cmd: Ps1GpuCommand, to inst: inout Ps1PrimInstance) {
        inst.tex_depth = UInt32((cmd.tpage >> 7) & 3)
        inst.tpage_x = UInt32(cmd.tpage & 0xF) * 64
        inst.tpage_y = (cmd.tpage & 0x10) != 0 ? 256 : 0
        inst.clut_x = UInt32(cmd.clut & 0x3F) * 16
        inst.clut_y = UInt32((cmd.clut >> 6) & 0x1FF)
        // Opcode bit 0 CLEAR means modulate; set means raw.
        if (cmd.opcode & 1) == 0 { inst.flags |= PS1_PRIM_MODULATE }
    }
}

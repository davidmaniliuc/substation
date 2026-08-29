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
        let x1 = min(clip.x1, min(MetalVram.nativeWidth - 1, vx.max()!))
        let y0 = max(clip.y0, max(0, vy.min()!))
        let y1 = min(clip.y1, min(MetalVram.nativeHeight - 1, vy.max()!))
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

    /// A rectangle's box is clamped to VRAM ONLY — the drawing-area clip stays
    /// in the shader, because `renderer.zig:280-281` does the VRAM bounds
    /// check itself and then lets `putPixel` apply the clip.
    static func rectangle(_ cmd: Ps1GpuCommand, env: DrawEnv, kind: Int32) -> Ps1PrimInstance? {
        let w = Int(cmd.w), h = Int(cmd.h)
        // The same refusal the polygon and line paths apply: 1024 or more
        // wide, or 512 or more tall, is DROPPED rather than clipped. The GP0
        // size field is 16 bits, so nothing else bounds it.
        guard w > 0, h > 0, w < 1024, h < 512 else { return nil }

        let ox = Int(cmd.x) + env.offsetX
        let oy = Int(cmd.y) + env.offsetY
        let x0 = max(ox, 0), y0 = max(oy, 0)
        let x1 = min(ox + w - 1, MetalVram.nativeWidth - 1)
        let y1 = min(oy + h - 1, MetalVram.nativeHeight - 1)
        guard x0 <= x1, y0 <= y1 else { return nil }

        var inst = base(env)
        inst.kind = kind
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(x0), Int32(y0), Int32(x1), Int32(y1))
        (inst.x0, inst.y0) = (Int32(ox), Int32(oy))
        (inst.w, inst.h) = (Int32(w), Int32(h))
        inst.color = cmd.value & 0xFFFF
        let v0 = withUnsafeBytes(of: cmd.v) { $0.bindMemory(to: Ps1GpuVertex.self)[0] }
        (inst.u0, inst.v0) = (Int32(v0.u), Int32(v0.v))
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

    /// One read span as a conservative superset of VRAM rects. `ps1_vram_read`
    /// (`Ps1Color.h`) does NOT clamp `x` to the row — it linearizes
    /// `y*1024+x` and masks the result with `& 0x7FFFF`. `0x7FFFF + 1 ==
    /// 524288 == 1024*512`, VRAM's total pixel count exactly, so that mask is
    /// wraparound over the WHOLE linear space, not per row: an `x` past 1023
    /// lands at the START of row `y+1`, faithful software-rasterizer
    /// behaviour — UNLESS row `y+1` doesn't exist because `y` was already
    /// VRAM's last row (511), in which case the same mask wraps the address
    /// all the way back to row 0.
    ///
    /// A row in the middle of a span wrapping to the row below it needs no
    /// special handling: that row is still inside the span (a page is 256
    /// rows starting at `y0`, a CLUT is 1), and widening every row in
    /// `[y0, lastRow]` to the full VRAM width already covers whatever landed
    /// there. Only the SPAN'S OWN last row is at risk of overflowing past a
    /// row that doesn't exist, so exactly two cases follow: extend by one row
    /// when there is a next row to extend into, or — when the span's last row
    /// IS VRAM's last row — add a second rect for the row-0 wrap target
    /// instead. One extra row/rect is always enough: the overflowing column
    /// count is `(x0 + width - 1) - 1023`, and `x0 < 1024` with `width <=
    /// 256` bounds that below 1024, so the wrapped tail always fits within a
    /// single row and never wraps a second time.
    private static func conservativeRect(x0: Int, y0: Int, width: Int, height: Int) -> [VramRect] {
        guard x0 + width - 1 >= MetalVram.nativeWidth else {
            return [VramRect(x0: x0, y0: y0,
                             x1: min(x0 + width - 1, MetalVram.nativeWidth - 1),
                             y1: min(y0 + height - 1, MetalVram.nativeHeight - 1))]
        }
        let lastRow = y0 + height - 1
        let span = VramRect(x0: 0, y0: y0, x1: MetalVram.nativeWidth - 1, y1: lastRow)
        if lastRow == MetalVram.nativeHeight - 1 {
            return [span, VramRect(x0: 0, y0: 0, x1: MetalVram.nativeWidth - 1, y1: 0)]
        }
        var extended = span
        extended.y1 = lastRow + 1
        return [extended]
    }

    /// What a primitive reads, as up to four rectangles: its texture page,
    /// possibly split by the row-511 wrap above, and — at 4bpp/8bpp — its
    /// CLUT row, same split possible.
    ///
    /// Two rectangles (page, CLUT) rather than one bounding box on purpose,
    /// before either can split further. A CLUT usually sits far from the page
    /// it serves, and a box spanning both would cover most of VRAM —
    /// splitting passes that need no split. That costs throughput without
    /// moving a single pixel, so no hash gate would ever notice.
    ///
    /// Conservative on the page: v is an 8-bit field, so a page is 256 rows
    /// tall, and its width in VRAM words is 64 / 128 / 256 by depth.
    static func sampledRects(of inst: Ps1PrimInstance) -> [VramRect] {
        guard inst.kind == Int32(PS1_PRIM_TEXTURED_TRI) || inst.kind == Int32(PS1_PRIM_TEXTURED_RECT) else {
            return []
        }
        let words = [64, 128, 256][min(Int(inst.tex_depth), 2)]
        let px = Int(inst.tpage_x), py = Int(inst.tpage_y)
        var out = conservativeRect(x0: px, y0: py, width: words, height: 256)
        if inst.tex_depth < 2 {
            let cx = Int(inst.clut_x), cy = Int(inst.clut_y)
            let entries = inst.tex_depth == 0 ? 16 : 256
            out.append(contentsOf: conservativeRect(x0: cx, y0: cy, width: entries, height: 1))
        }
        return out
    }
}

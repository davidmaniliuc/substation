import Foundation
import CPs1

/// Record -> instance encoding for the primitives whose per-pixel geometry
/// doesn't fit `PrimBuilder`'s one-instance-per-record shape: lines (which
/// expand into one 1x1 instance per Bresenham step) and the three memory
/// movers (fill, copy, upload), which also bracket themselves with a pass
/// break since a mover both starts and ends a render pass.
///
/// Split out of `MetalRasterizer` so that file stays pass/resource management
/// only (the `Step`/`DrawKind` storage, `beginFrame`/`endFrame`, the
/// pipelines, `appendPrim`, `breakPass`). `appendPrim`/`breakPass` themselves
/// stay in `MetalRasterizer.swift`, not here, because Task 11's hazard
/// detection patches them by name in that file.
extension MetalRasterizer {
    /// One 1x1 instance per Bresenham step. The pixel itself is the box, so
    /// coverage is trivially true; the drawing-area clip and the mask still run
    /// in the shader's putPixel tail, exactly as `drawLine` calls `putPixel`.
    func encodeLine(_ cmd: Ps1GpuCommand) {
        let shaded = cmd.commandKind == PS1_GPU_DRAW_SHADED_LINE
        let v = withUnsafeBytes(of: cmd.v) { raw -> [Ps1GpuVertex] in
            let p = raw.bindMemory(to: Ps1GpuVertex.self)
            return [p[0], p[1]]
        }
        let ox = env.offsetX, oy = env.offsetY
        guard let walk = LineExpander.walk(x0: Int(v[0].x) + ox, y0: Int(v[0].y) + oy,
                                           x1: Int(v[1].x) + ox, y1: Int(v[1].y) + oy)
        else { return }

        var proto = PrimBuilder.base(env)
        proto.kind = Int32(shaded ? PS1_PRIM_SHADED_LINE_PIXEL : PS1_PRIM_LINE_PIXEL)
        proto.color = cmd.value & 0xFFFF
        proto.c0 = v[0].color
        proto.c1 = v[1].color
        proto.steps = Int32(walk.total)
        if cmd.transparent != 0 { proto.flags |= PS1_PRIM_TRANSPARENT }
        // A mono line never dithers; drawLine has no dither branch.
        if !shaded { proto.flags &= ~PS1_PRIM_DITHER }

        for step in walk.steps {
            // Outside VRAM the software path's putPixel returns immediately, so
            // skipping the instance is equivalent and saves the box clamp.
            guard step.x >= 0, step.x < MetalVram.width,
                  step.y >= 0, step.y < MetalVram.height else { continue }
            var inst = proto
            (inst.box_x0, inst.box_x1) = (Int32(step.x), Int32(step.x))
            (inst.box_y0, inst.box_y1) = (Int32(step.y), Int32(step.y))
            (inst.x0, inst.y0) = (Int32(step.x), Int32(step.y))
            inst.k = Int32(step.k)
            appendPrim(inst)
        }
    }

    private func maskFlags() -> UInt32 {
        (env.maskSet ? PS1_PRIM_SET_MASK : 0) | (env.maskCheck ? PS1_PRIM_CHECK_MASK : 0)
    }

    /// Clamps an inclusive box to VRAM. Returns nil when nothing is left, which
    /// is the encoder's equivalent of the software path's `continue`.
    private func clampBox(x0: Int, y0: Int, x1: Int, y1: Int) -> (Int, Int, Int, Int)? {
        let cx0 = max(x0, 0), cy0 = max(y0, 0)
        let cx1 = min(x1, MetalVram.width - 1), cy1 = min(y1, MetalVram.height - 1)
        guard cx0 <= cx1, cy0 <= cy1 else { return nil }
        return (cx0, cy0, cx1, cy1)
    }

    /// A wrapping run on one axis, as at most two non-wrapping ranges.
    private func wrapRanges(origin: Int, extent: Int, axis: Int) -> [(Int, Int)] {
        if extent >= axis { return [(0, axis - 1)] }
        let o = ((origin % axis) + axis) % axis
        if o + extent <= axis { return [(o, o + extent - 1)] }
        return [(o, axis - 1), (0, o + extent - axis - 1)]
    }

    func encodeFill(_ cmd: Ps1GpuCommand) {
        let x = Int(cmd.x), y = Int(cmd.y), w = Int(cmd.w), h = Int(cmd.h)
        guard w > 0, h > 0,
              let box = clampBox(x0: x, y0: y, x1: x + w - 1, y1: y + h - 1) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = Int32(PS1_PRIM_FILL)
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        inst.color = cmd.value & 0xFFFF
        let first = instances.count
        instances.append(inst)
        breakPass()
        steps.append(.draw(kind: .fill, range: first..<instances.count))
        breakPass()
    }

    func encodeCopy(_ cmd: Ps1GpuCommand) {
        let w = VramTransfer.axisExtent(Int(cmd.w), MetalVram.width)
        let h = VramTransfer.axisExtent(Int(cmd.h), MetalVram.height)
        guard w > 0, h > 0 else { return }

        var base = Ps1PrimInstance()
        base.kind = Int32(PS1_PRIM_COPY)
        base.x0 = Int32(Int(cmd.x2) & 0x3FF)
        base.y0 = Int32(Int(cmd.y2) & 0x1FF)
        base.src_x = Int32(Int(cmd.x) & 0x3FF)
        base.src_y = Int32(Int(cmd.y) & 0x1FF)
        base.w = Int32(w)
        base.h = Int32(h)
        base.flags = maskFlags()

        let first = instances.count
        for (bx0, bx1) in wrapRanges(origin: Int(base.x0), extent: w, axis: MetalVram.width) {
            for (by0, by1) in wrapRanges(origin: Int(base.y0), extent: h, axis: MetalVram.height) {
                var inst = base
                (inst.box_x0, inst.box_x1) = (Int32(bx0), Int32(bx1))
                (inst.box_y0, inst.box_y1) = (Int32(by0), Int32(by1))
                instances.append(inst)
            }
        }
        breakPass()
        steps.append(.snapshot)
        steps.append(.draw(kind: .copy, range: first..<instances.count))
        breakPass()
    }

    func encodeUpload(_ cmd: Ps1GpuCommand) {
        // Mirrors ShadowVram.apply's PS1_GPU_VRAM_WRITE_DATA arm: FixtureFile
        // validates a FRAME's payload slice against the file totals but never
        // a RECORD's offsets within it, so a malformed off/len pair reaches
        // both consumers unchecked. The shadow's guard makes that a no-op;
        // without the same guard here, word_base + (pix >> 1) in
        // ps1_upload_fragment would index past payloadBuffer's real
        // allocation — an out-of-bounds device-buffer read, not merely a
        // wrong pixel.
        let off = Int(cmd.x), len = Int(cmd.y)
        guard off >= 0, len >= 0, off + len <= payloadCount else { return }
        var wordCursor = off
        var remaining = len
        let first = instances.count
        while remaining > 0, transfer.active, let run = transfer.plan(words: remaining) {
            appendUploadInstance(bufferWordOffset: wordCursor, run: run)
            wordCursor += run.consumed
            remaining -= run.consumed
        }
        guard instances.count > first else { return }
        breakPass()
        steps.append(.draw(kind: .upload, range: first..<instances.count))
        breakPass()
    }

    private func appendUploadInstance(bufferWordOffset: Int,
                                      run: (first: Int, last: Int, consumed: Int)) {
        let w = transfer.w
        let rowFirst = run.first / w, rowLast = run.last / w
        guard let box = clampBox(x0: transfer.x, y0: transfer.y + rowFirst,
                                 x1: transfer.x + w - 1, y1: transfer.y + rowLast) else { return }
        var inst = Ps1PrimInstance()
        inst.kind = Int32(PS1_PRIM_UPLOAD)
        (inst.box_x0, inst.box_y0, inst.box_x1, inst.box_y1) =
            (Int32(box.0), Int32(box.1), Int32(box.2), Int32(box.3))
        inst.x0 = Int32(transfer.x)
        inst.y0 = Int32(transfer.y)
        inst.w = Int32(w)
        inst.h = Int32(transfer.h)
        // A run always starts on an EVEN pixel index, so this bias is exact.
        inst.word_base = Int32(bufferWordOffset - run.first / 2)
        inst.pixel_first = Int32(run.first)
        inst.pixel_last = Int32(run.last)
        inst.flags = maskFlags()
        instances.append(inst)
    }
}

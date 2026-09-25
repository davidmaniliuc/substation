import CPs1

extension Ps1GpuVertex {
    /// A vertex with no sub-pixel, which is what GP0 decode produces whenever
    /// PGXP has nothing to say about it: `px == x << 16`, `py == y << 16`.
    ///
    /// It exists so the two dozen hand-built commands in this target keep
    /// reading as screen coordinates rather than restating the same shift at
    /// every call. A test that is ABOUT the sub-pixel calls the full
    /// memberwise initializer instead.
    init(x: Int16, y: Int16, u: UInt8, v: UInt8, _pad: UInt16, color: UInt32) {
        self.init(x: x, y: y, u: u, v: v, _pad: _pad, color: color,
                  px: Int32(x) << 16, py: Int32(y) << 16, rw: 0, iz: 0)
    }
}

/// A flat triangle whose three vertices sit at `xs` on rows 10/50/90 with the
/// given absolute depths, carrying both depth bits.
func depthTestedTriangle(color: UInt32, xs: [Int16], izs: [Int32]) -> Ps1GpuCommand {
    var c = Ps1GpuCommand()
    c.kind = UInt8(PS1_GPU_DRAW_TRIANGLE.rawValue)
    c.value = color
    c.flags = UInt8(PS1_GPU_FLAG_DEPTH_TEST | PS1_GPU_FLAG_DEPTH_WRITE)
    let ys: [Int16] = [10, 50, 90]
    var v = [Ps1GpuVertex](repeating: Ps1GpuVertex(), count: 3)
    for i in 0..<3 {
        v[i].x = xs[i]; v[i].y = ys[i]
        v[i].px = Int32(xs[i]) << 16; v[i].py = Int32(ys[i]) << 16
        v[i].iz = izs[i]
    }
    c.v = (v[0], v[1], v[2])
    return c
}

/// GP0(E4) = (1023, 511): with E3's default of (0, 0), the whole of VRAM.
func fullDrawingAreaCommand() -> Ps1GpuCommand {
    var area = Ps1GpuCommand()
    area.kind = UInt8(PS1_GPU_SET_DRAW_ENV.rawValue)
    area.opcode = 0xE4
    area.value = (511 << 10) | 1023
    return area
}

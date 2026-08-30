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
                  px: Int32(x) << 16, py: Int32(y) << 16)
    }
}

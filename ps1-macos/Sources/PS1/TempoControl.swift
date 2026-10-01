/// The stretch rate above 1×: the target speed when the core keeps up, and
/// the speed it actually sustains when it does not.
///
/// A fixed rate of N pulls N seconds of game audio per second; a core that
/// manages less drains the ring, and the time-pitch unit then stretches
/// silence into the gaps — audio that stutters while the picture runs at
/// whatever the core reached anyway. Reading the rate off the ring's fill
/// instead settles where consumption equals production: a ring the core
/// keeps above the target's low-water mark plays at the full target, a ring
/// drained to 1×'s low-water mark plays at real time, which the core always
/// sustains and so is where the fill recovers from.
///
/// A value type for the reason `FpsCounter` is one: the rule is then
/// reachable from a test with synthetic fills, and the render thread holds
/// it in a plain stored property with no lock.
struct TempoControl {
    /// The fraction of the gap closed per render callback (~10 ms). Slow
    /// enough that the runner's high/low-water sawtooth does not reach the
    /// ear as a warble, fast enough to settle within a second.
    static let smoothing: Float = 0.02

    private(set) var current: Float = 1

    static func rate(target: Int, fill: Int) -> Float {
        let floor = EmulatorRunner.waterMarks(speed: 1).low
        let ceiling = EmulatorRunner.waterMarks(speed: target).low
        guard target > 1, ceiling > floor else { return 1 }
        let t = Float(fill - floor) / Float(ceiling - floor)
        return 1 + Float(target - 1) * min(max(t, 0), 1)
    }

    mutating func reset(to rate: Float) { current = rate }

    mutating func step(toward rate: Float) -> Float {
        current += (rate - current) * Self.smoothing
        return current
    }
}

import Foundation

/// Emulated frames per second, measured over a fixed window.
///
/// Fed a CUMULATIVE frame count and a monotonic timestamp rather than being
/// called once per frame, because the thing producing frames is the emulator
/// thread and the thing displaying the number is the main actor — a counter
/// that had to be ticked would have to be ticked across that boundary.
/// Sampling a total instead means the reader sets its own cadence and a
/// missed poll costs accuracy, never a frame.
///
/// A type of its own, like `InternalResolution`, so the windowing rule is
/// reachable from a test with synthetic timestamps — no runner, no wall clock.
struct FpsCounter {
    /// Long enough that one late frame does not swing the reading, short
    /// enough that a stall shows up while it is still happening.
    static let window = 0.5

    private var lastFrames: UInt64?
    private var lastTime = 0.0

    /// `nil` until the first window has closed. Not 0: a zero reading means
    /// "producing nothing", which is what a paused emulator looks like, and
    /// showing it for the first half-second of every game would be a lie.
    private(set) var value: Double?

    mutating func sample(frames: UInt64, at time: Double) {
        guard let baseline = lastFrames else {
            lastFrames = frames
            lastTime = time
            return
        }

        // Closing on elapsed time rather than on a call count: an early sample
        // is ignored outright, and the frames it saw still count towards the
        // window it fell inside.
        let elapsed = time - lastTime
        guard elapsed >= Self.window else { return }

        // `eject()` installs a new runner, whose count starts at zero again —
        // subtracting the old baseline would not merely be meaningless, it
        // would underflow `UInt64`.
        let produced = frames >= baseline ? frames - baseline : 0
        value = Double(produced) / elapsed
        lastFrames = frames
        lastTime = time
    }
}

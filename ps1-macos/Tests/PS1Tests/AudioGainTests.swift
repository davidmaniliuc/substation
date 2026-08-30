import Testing
@testable import PS1

/// The one piece of the volume path that touches real-time code. The gain is
/// written on the main thread and read in the CoreAudio render callback, so it
/// is held as a bit pattern in an atomic — and that encoding is exactly the
/// kind of plumbing that can be wrong in a way no listening test would localise.

@Test func aGainSetOnOneSideIsReadBackOnTheOther() {
    let gain = AudioGain(1)
    gain.value = 0.375
    #expect(gain.value == 0.375)
}

@Test func aGainOfZeroSilencesTheBuffer() {
    var samples: [Float] = [1, -1, 0.5, -0.25]
    let gain = AudioGain(0)
    samples.withUnsafeMutableBufferPointer { gain.apply(to: $0.baseAddress!, count: $0.count) }
    #expect(samples == [0, 0, 0, 0])
}

@Test func aFractionalGainScalesEverySample() {
    var samples: [Float] = [1, -1, 0.5, -0.25]
    let gain = AudioGain(0.5)
    samples.withUnsafeMutableBufferPointer { gain.apply(to: $0.baseAddress!, count: $0.count) }
    #expect(samples == [0.5, -0.5, 0.25, -0.125])
}

@Test func unityGainLeavesTheSamplesUntouched() {
    var samples: [Float] = [1, -1, 0.5, -0.25]
    let gain = AudioGain(1)
    samples.withUnsafeMutableBufferPointer { gain.apply(to: $0.baseAddress!, count: $0.count) }
    #expect(samples == [1, -1, 0.5, -0.25])
}

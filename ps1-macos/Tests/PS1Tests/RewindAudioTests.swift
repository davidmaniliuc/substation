import Testing
@testable import PS1

@Test func rewindAudioReversesStereoFramesAndKeepsEachChannelOnItsSide() {
    var samples: [Float] = [1, -1, 2, -2, 3, -3]
    RewindAudio.reverse(&samples)
    #expect(samples == [3, -3, 2, -2, 1, -1])

    var even: [Float] = [1, -1, 2, -2]
    RewindAudio.reverse(&even)
    #expect(even == [2, -2, 1, -1])

    var empty: [Float] = []
    RewindAudio.reverse(&empty)
    #expect(empty.isEmpty)
}

/// The sound of a held rewind: the audio of the stretch a step went back
/// over, played backwards, so a run of steps plays the game's audio in
/// reverse.
enum RewindAudio {
    /// Reverses interleaved stereo samples by FRAME, never by sample: a
    /// plain reverse would also swap the left and right channels.
    static func reverse(_ samples: inout [Float]) {
        var front = 0
        var back = samples.count / 2 - 1
        while front < back {
            samples.swapAt(2 * front, 2 * back)
            samples.swapAt(2 * front + 1, 2 * back + 1)
            front += 1
            back -= 1
        }
    }
}

//! Runahead's speculation: N frames past the real one, recorded into a
//! group, and the machine put back.

const std = @import("std");
const StreamQueue = @import("ps1_metal").stream_queue.StreamQueue;

/// Runs `frames` frames past real frame `after` into a speculative group and
/// returns the machine to where it was. Their audio is read and dropped: it
/// is a future the real frames will play themselves. The pad status is not
/// touched, so it stays the real frame's. The caller has drained the real
/// frame's audio already: the mark snapshots the SPU's ring, so what is read
/// here is exactly the speculative frames'.
pub fn speculate(m: anytype, frames: u32, after: u64, queue: *StreamQueue, audio_scratch: []f32) void {
    m.snapshotMark() catch return;
    queue.beginSpeculativeGroup(after);
    for (0..frames) |_| {
        m.runFrame();
        _ = m.readAudio(audio_scratch);
        // Once per frame, unconditionally: the recorder is a drain. An
        // incomplete stream is appended as one, which spoils the group.
        queue.appendSpeculative(m.takeFrameStream());
    }
    queue.commitSpeculativeGroup(m.display());
    // A refused return (the mark was forgotten) leaves the machine in the
    // future; nothing the emulator thread does between mark and return
    // forgets it.
    m.snapshotReturn() catch {};
}

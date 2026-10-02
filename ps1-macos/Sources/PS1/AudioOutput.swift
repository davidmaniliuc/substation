import Foundation
import AudioToolbox
import AVFoundation
import Synchronization

/// The output gain, shared between the main thread that sets it and the
/// CoreAudio render callback that applies it.
///
/// A `Float` held as its bit pattern in an atomic: `Synchronization.Atomic` has
/// no `Float` conformance, and the callback may not take a lock. A type of its
/// own so that encoding (the kind of plumbing a listening test would never
/// localise) is covered by a unit test.
final class AudioGain: @unchecked Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float = 1) { bits = Atomic(value.bitPattern) }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Real-time safe: one atomic load, then a multiply per sample. Unity is
    /// the shipped default and skips the loop entirely.
    func apply(to samples: UnsafeMutablePointer<Float>, count: Int) {
        let g = value
        guard g != 1 else { return }
        for i in 0..<count { samples[i] *= g }
    }
}

/// The default output AudioUnit, pulling from the ring: straight at 1×, and
/// through Apple's time-pitch unit above it.
///
/// **Speed is paced from here, not from the emulator thread.** At N× the
/// time-pitch unit pulls up to N times as many samples as it plays, at the
/// original pitch, so the ring drains that much faster and the runner (which
/// only ever fills the ring back to its high-water mark) produces that many
/// more frames. No second clock exists to keep in step with the audio one.
/// "Up to", because the rate follows what the core sustains (`TempoControl`):
/// measured, that is 1.7-2× on this machine, short of the 4× on offer.
///
/// At 1× the stretch unit is not in the chain at all, rather than running at a
/// rate of one: normal play stays bit-identical to the samples the core wrote,
/// with none of the unit's latency or phase smearing.
///
/// The render callback NEVER blocks and NEVER allocates. On underrun it writes
/// silence for that callback and returns: the alternative, waiting for the
/// emulator, would glitch the whole device.
final class AudioOutput {
    private var unit: AudioUnit?
    private var stretch: AudioUnit?
    private let ring: AudioRing
    private unowned let runner: EmulatorRunner

    /// Applied in the render callback rather than through
    /// `kHALOutputParam_Volume`: on a default-output unit that parameter
    /// reaches toward the device, and this stays inside our own stream.
    private let gain = AudioGain()

    /// Set from the main thread, acted on by the render thread, which is the
    /// only one that touches the stretch unit once it is running.
    private let speed = Atomic<Int>(1)
    /// Render thread only: the speed the last callback rendered at, so a
    /// stretch re-entered from 1× starts from a reset unit instead of the
    /// tail of the last fast-forward.
    private var renderedSpeed = 1
    /// Render thread only: the stretch rate, following the ring's fill.
    private var tempo = TempoControl()

    /// The ring is interleaved and both units take planar audio, so every
    /// pull is deinterleaved through this.
    private static let scratchFrames = 4096
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioOutput.scratchFrames * 2)

    static let sampleRate: Double = 44100

    init(ring: AudioRing, runner: EmulatorRunner) throws {
        self.ring = ring
        self.runner = runner
        try setup()
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    private func setup() throws {
        let au = try makeUnit(type: kAudioUnitType_Output, subType: kAudioUnitSubType_DefaultOutput)
        self.unit = au
        let st = try makeUnit(type: kAudioUnitType_FormatConverter, subType: kAudioUnitSubType_NewTimePitch)
        self.stretch = st

        // Planar stereo float32: the time-pitch unit's canonical format, and
        // the output unit takes the same so the stretch can render straight
        // into the device's buffers.
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatSize = UInt32(MemoryLayout.size(ofValue: format))
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &format, formatSize))
        try check(AudioUnitSetProperty(st, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &format, formatSize))
        try check(AudioUnitSetProperty(st, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 0, &format, formatSize))
        // The most a default output asks for in one callback (it rises from
        // ~512 to 4096 frames while the screen is locked); a slice larger
        // than the unit was initialised for is an error, not a resize.
        var maxFrames = UInt32(Self.scratchFrames)
        try check(AudioUnitSetProperty(st, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0,
                                       &maxFrames, UInt32(MemoryLayout.size(ofValue: maxFrames))))

        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var output = AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0,
                                       &output, UInt32(MemoryLayout.size(ofValue: output))))
        var input = AURenderCallbackStruct(inputProc: stretchInputCallback, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(st, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0,
                                       &input, UInt32(MemoryLayout.size(ofValue: input))))

        try check(AudioUnitInitialize(st))
        try check(AudioUnitInitialize(au))
    }

    private func makeUnit(type: OSType, subType: OSType) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioError.noComponent
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au))
        guard let au else { throw AudioError.noComponent }
        return au
    }

    func start() throws {
        guard let unit else { throw AudioError.noComponent }
        try check(AudioOutputUnitStart(unit))
    }

    /// Safe from any thread, and safe before `start()`: the gain is read by
    /// the callback, never latched at setup.
    func setGain(_ value: Float) { gain.value = value }

    /// Safe from any thread, and safe before `start()`, for the same reason.
    func setSpeed(_ n: Int) { speed.store(n, ordering: .relaxed) }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        if let stretch {
            AudioUnitUninitialize(stretch)
            AudioComponentInstanceDispose(stretch)
            self.stretch = nil
        }
    }

    /// Real-time thread. No locks, no allocation, no Swift runtime calls that
    /// could take one.
    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            frames: UInt32,
                            buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard abl.count == 2,
              let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let right = abl[1].mData?.assumingMemoryBound(to: Float.self),
              let stretch else { return noErr }

        let n = speed.load(ordering: .relaxed)
        if n == 1 {
            pull(frames: Int(frames), left: left, right: right)
        } else {
            if renderedSpeed == 1 {
                AudioUnitReset(stretch, kAudioUnitScope_Global, 0)
                tempo.reset(to: 1)
            }
            // "Up to N×": the rate the core can actually feed, not the one
            // asked for; see `TempoControl`.
            let rate = tempo.step(toward: TempoControl.rate(target: n, fill: ring.filled))
            AudioUnitSetParameter(stretch, kNewTimePitchParam_Rate,
                                  kAudioUnitScope_Global, 0, rate, 0)
            if AudioUnitRender(stretch, flags, timestamp, 0, frames, buffers) != noErr {
                memset(left, 0, Int(frames) * MemoryLayout<Float>.size)
                memset(right, 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        renderedSpeed = n

        gain.apply(to: left, count: Int(frames))
        gain.apply(to: right, count: Int(frames))
        return noErr
    }

    /// Real-time thread: the stretch unit asking for its input, from inside
    /// the `AudioUnitRender` above.
    fileprivate func pull(buffers: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard abl.count == 2,
              let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        pull(frames: Int(frames), left: left, right: right)
        return noErr
    }

    /// Takes `frames` stereo frames out of the ring and deinterleaves them.
    /// On underrun the remainder is silence: for this pull only.
    private func pull(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < frames {
            let chunk = min(frames - done, Self.scratchFrames)
            let got = ring.read(into: scratch, count: chunk * 2) / 2
            for i in 0..<got {
                left[done + i] = scratch[2 * i]
                right[done + i] = scratch[2 * i + 1]
            }
            done += got
            if got < chunk {
                let rest = (frames - done) * MemoryLayout<Float>.size
                memset(left + done, 0, rest)
                memset(right + done, 0, rest)
                break
            }
        }
        runner.signalAudioDrained()
    }

    enum AudioError: Error { case noComponent, osStatus(OSStatus) }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw AudioError.osStatus(status) }
    }
}

private func outputCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    let output = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    return output.render(flags: flags, timestamp: timestamp, frames: frames, buffers: data)
}

private func stretchInputCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    let output = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    return output.pull(buffers: data, frames: frames)
}

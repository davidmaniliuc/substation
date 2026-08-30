import Foundation
import AudioToolbox
import AVFoundation
import Synchronization

/// The output gain, shared between the main thread that sets it and the
/// CoreAudio render callback that applies it.
///
/// A `Float` held as its bit pattern in an atomic: `Synchronization.Atomic` has
/// no `Float` conformance, and the callback may not take a lock. A type of its
/// own so that encoding — the kind of plumbing a listening test would never
/// localise — is covered by a unit test.
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

/// The default output AudioUnit, pulling straight from the ring.
///
/// The render callback NEVER blocks and NEVER allocates. On underrun it writes
/// silence for that callback and returns — the alternative, waiting for the
/// emulator, would glitch the whole device.
final class AudioOutput {
    private var unit: AudioUnit?
    private let ring: AudioRing
    private unowned let runner: EmulatorRunner

    /// Applied in the render callback rather than through
    /// `kHALOutputParam_Volume`: on a default-output unit that parameter
    /// reaches toward the device, and this stays inside our own stream.
    private let gain = AudioGain()

    static let sampleRate: Double = 44100

    init(ring: AudioRing, runner: EmulatorRunner) throws {
        self.ring = ring
        self.runner = runner
        try setup()
    }

    deinit { stop() }

    private func setup() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
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
        self.unit = au

        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,   // interleaved stereo float32
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout.size(ofValue: format))))

        var callback = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout.size(ofValue: callback))))

        try check(AudioUnitInitialize(au))
    }

    func start() throws {
        guard let unit else { throw AudioError.noComponent }
        try check(AudioOutputUnitStart(unit))
    }

    /// Safe from any thread, and safe before `start()`: the gain is read by
    /// the callback, never latched at setup.
    func setGain(_ value: Float) { gain.value = value }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    /// Real-time thread. No locks, no allocation, no Swift runtime calls that
    /// could take one.
    fileprivate func render(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard let out = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        let wanted = Int(frames) * 2
        let got = ring.read(into: out, count: wanted)
        // Only what was actually read — the underrun tail below is already
        // silence, and scaling it would be a multiply per sample for nothing.
        gain.apply(to: out, count: got)
        if got < wanted {
            // Underrun: silence for the remainder of this callback only.
            memset(out + got, 0, (wanted - got) * MemoryLayout<Float>.size)
        }
        runner.signalAudioDrained()
        return noErr
    }

    enum AudioError: Error { case noComponent, osStatus(OSStatus) }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw AudioError.osStatus(status) }
    }
}

private func renderCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    busNumber: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let data else { return noErr }
    let output = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    return output.render(frames: frames, buffers: data)
}

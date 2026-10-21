//! The default output AudioUnit pulling from the mixer: straight at 1x, and
//! through Apple's time-pitch unit above it. AudioToolbox is a plain C API,
//! so nothing here goes through `objc`.
//!
//! Both callbacks are real-time code. They call the mixer and the stretch
//! unit and touch nothing else: no lock, no allocation, no wait.

const std = @import("std");
const Mixer = @import("mixer.zig").Mixer;
const mixer = @import("mixer.zig");

const log = std.log.scoped(.audio);

const OSStatus = i32;
const no_err: OSStatus = 0;
const AudioComponent = *opaque {};
const AudioUnit = *opaque {};
const AudioTimeStamp = opaque {};

// Every constant once, pinned to its SDK header line.
// AUComponent.h:22: kAudioUnitType_Output = 'auou'.
const type_output = fourCC("auou");
// AUComponent.h:321: kAudioUnitSubType_DefaultOutput = 'def '.
const subtype_default_output = fourCC("def ");
// AUComponent.h:25: kAudioUnitType_FormatConverter = 'aufc'.
const type_format_converter = fourCC("aufc");
// AUComponent.h:415: kAudioUnitSubType_NewTimePitch = 'nutp'.
const subtype_new_time_pitch = fourCC("nutp");
// AUComponent.h:277: kAudioUnitManufacturer_Apple = 'appl'.
const manufacturer_apple = fourCC("appl");
// CoreAudioBaseTypes.h:393: kAudioFormatLinearPCM = 'lpcm'.
const format_linear_pcm = fourCC("lpcm");
// CoreAudioBaseTypes.h:524, 527, 529: IsFloat 1 << 0, IsPacked 1 << 3,
// IsNonInterleaved 1 << 5.
const flag_is_float: u32 = 1 << 0;
const flag_is_packed: u32 = 1 << 3;
const flag_is_non_interleaved: u32 = 1 << 5;
// AudioUnitProperties.h:900, 904, 910.
const property_stream_format: u32 = 8;
const property_maximum_frames_per_slice: u32 = 14;
const property_set_render_callback: u32 = 23;
// AudioUnitProperties.h:103-105.
const scope_global: u32 = 0;
const scope_input: u32 = 1;
const scope_output: u32 = 2;
// AudioUnitParameters.h:341: kNewTimePitchParam_Rate = 0.
const param_new_time_pitch_rate: u32 = 0;

fn fourCC(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) << 24 | @as(u32, s[1]) << 16 | @as(u32, s[2]) << 8 | s[3];
}

const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
};

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

/// Planar stereo: two buffers, declared as the C header's variable-length
/// tail of two.
const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [2]AudioBuffer,
};

const RenderCallback = *const fn (ref: ?*anyopaque, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus;
const AURenderCallbackStruct = extern struct { inputProc: RenderCallback, inputProcRefCon: ?*anyopaque };

extern "c" fn AudioComponentFindNext(after: ?AudioComponent, desc: *const AudioComponentDescription) ?AudioComponent;
extern "c" fn AudioComponentInstanceNew(comp: AudioComponent, out: *?AudioUnit) OSStatus;
extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *const anyopaque, size: u32) OSStatus;
extern "c" fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStart(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStop(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitReset(unit: AudioUnit, scope: u32, element: u32) OSStatus;
extern "c" fn AudioUnitSetParameter(unit: AudioUnit, id: u32, scope: u32, element: u32, value: f32, offset: u32) OSStatus;
extern "c" fn AudioUnitRender(unit: AudioUnit, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: *AudioBufferList) OSStatus;

pub const sample_rate = 44_100;

pub const Error = error{ NoComponent, OsStatus };

/// Lives where it was initialised: both callbacks carry a pointer to it.
pub const Output = struct {
    unit: ?AudioUnit = null,
    stretch: ?AudioUnit = null,
    mixer: *Mixer = undefined,
    /// The `OSStatus` behind the last `error.OsStatus`, for the log.
    last_status: OSStatus = 0,
    /// The output callback's arguments, for the stretch's `render` to pass on
    /// to `AudioUnitRender`. Render thread only.
    flags: *u32 = undefined,
    timestamp: *const AudioTimeStamp = undefined,
    buffers: *AudioBufferList = undefined,

    /// Both units, the format and both callbacks, as `AudioOutput.setup`
    /// built them. Starts nothing.
    pub fn init(self: *Output, m: *Mixer) Error!void {
        self.* = .{ .mixer = m };
        errdefer self.stop();
        const out = try self.makeUnit(type_output, subtype_default_output);
        self.unit = out;
        const st = try self.makeUnit(type_format_converter, subtype_new_time_pitch);
        self.stretch = st;

        // Planar stereo float32: the time-pitch unit's canonical format, and
        // the output unit takes the same so the stretch can render straight
        // into the device's buffers.
        const format: AudioStreamBasicDescription = .{
            .mSampleRate = sample_rate,
            .mFormatID = format_linear_pcm,
            .mFormatFlags = flag_is_float | flag_is_packed | flag_is_non_interleaved,
            .mBytesPerPacket = 4,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 4,
            .mChannelsPerFrame = 2,
            .mBitsPerChannel = 32,
        };
        try self.set(out, property_stream_format, scope_input, &format);
        try self.set(st, property_stream_format, scope_input, &format);
        try self.set(st, property_stream_format, scope_output, &format);
        // The most a default output asks for in one callback; a slice larger
        // than the unit was initialised for is an error, not a resize.
        const max_frames: u32 = mixer.scratch_frames;
        try self.set(st, property_maximum_frames_per_slice, scope_global, &max_frames);
        const output_cb: AURenderCallbackStruct = .{ .inputProc = outputCallback, .inputProcRefCon = self };
        try self.set(out, property_set_render_callback, scope_input, &output_cb);
        const input_cb: AURenderCallbackStruct = .{ .inputProc = stretchInputCallback, .inputProcRefCon = self };
        try self.set(st, property_set_render_callback, scope_input, &input_cb);
        try self.check(AudioUnitInitialize(st));
        try self.check(AudioUnitInitialize(out));
    }

    pub fn start(self: *Output) Error!void {
        const out = self.unit orelse return error.NoComponent;
        try self.check(AudioOutputUnitStart(out));
    }

    /// Stops, uninitialises and disposes both units. Idempotent.
    pub fn stop(self: *Output) void {
        if (self.unit) |out| {
            _ = AudioOutputUnitStop(out);
            _ = AudioUnitUninitialize(out);
            _ = AudioComponentInstanceDispose(out);
            self.unit = null;
        }
        if (self.stretch) |st| {
            _ = AudioUnitUninitialize(st);
            _ = AudioComponentInstanceDispose(st);
            self.stretch = null;
        }
    }

    fn makeUnit(self: *Output, kind: u32, sub: u32) Error!AudioUnit {
        const desc: AudioComponentDescription = .{ .componentType = kind, .componentSubType = sub, .componentManufacturer = manufacturer_apple };
        const comp = AudioComponentFindNext(null, &desc) orelse return error.NoComponent;
        var unit: ?AudioUnit = null;
        try self.check(AudioComponentInstanceNew(comp, &unit));
        return unit orelse error.NoComponent;
    }

    fn set(self: *Output, unit: AudioUnit, id: u32, scope: u32, value: anytype) Error!void {
        try self.check(AudioUnitSetProperty(unit, id, scope, 0, value, @sizeOf(@TypeOf(value.*))));
    }

    fn check(self: *Output, status: OSStatus) Error!void {
        if (status == no_err) return;
        self.last_status = status;
        log.warn("audio output: OSStatus {d}", .{status});
        return error.OsStatus;
    }

    fn stretchUnit(self: *Output) mixer.Stretch {
        return .{ .ctx = self, .reset = resetStretch, .set_rate = setRate, .render = renderStretch };
    }

    fn resetStretch(ctx: *anyopaque) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        _ = AudioUnitReset(self.stretch.?, scope_global, 0);
    }

    fn setRate(ctx: *anyopaque, rate: f32) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        _ = AudioUnitSetParameter(self.stretch.?, param_new_time_pitch_rate, scope_global, 0, rate, 0);
    }

    fn renderStretch(ctx: *anyopaque, left: []f32, right: []f32) bool {
        _ = left;
        _ = right;
        const self: *Output = @ptrCast(@alignCast(ctx));
        const frames: u32 = self.buffers.mBuffers[0].mDataByteSize / 4;
        return AudioUnitRender(self.stretch.?, self.flags, self.timestamp, 0, frames, self.buffers) == no_err;
    }
};

/// The two planar channels of a buffer list, or null if it is not one.
fn planar(data: ?*AudioBufferList, frames: u32) ?struct { []f32, []f32 } {
    const abl = data orelse return null;
    if (abl.mNumberBuffers != 2) return null;
    const l: [*]f32 = @ptrCast(@alignCast(abl.mBuffers[0].mData orelse return null));
    const r: [*]f32 = @ptrCast(@alignCast(abl.mBuffers[1].mData orelse return null));
    return .{ l[0..frames], r[0..frames] };
}

fn outputCallback(ref: ?*anyopaque, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
    _ = bus;
    const self: *Output = @ptrCast(@alignCast(ref.?));
    const lr = planar(data, frames) orelse return no_err;
    self.flags = flags;
    self.timestamp = ts;
    self.buffers = data.?;
    self.mixer.render(lr[0], lr[1], self.stretchUnit());
    return no_err;
}

/// The time-pitch unit asking for its input, from inside `AudioUnitRender`.
fn stretchInputCallback(ref: ?*anyopaque, flags: *u32, ts: *const AudioTimeStamp, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
    _ = flags;
    _ = ts;
    _ = bus;
    const self: *Output = @ptrCast(@alignCast(ref.?));
    const lr = planar(data, frames) orelse return no_err;
    self.mixer.pull(lr[0], lr[1]);
    return no_err;
}

/// No device: for the tests and a headless session. Nothing drains the ring
/// until a test calls `Mixer.pull` itself.
pub const NullOutput = struct {
    pub fn init(self: *NullOutput, m: *Mixer) Error!void {
        _ = self;
        _ = m;
    }

    pub fn start(self: *NullOutput) Error!void {
        _ = self;
    }

    pub fn stop(self: *NullOutput) void {
        _ = self;
    }
};

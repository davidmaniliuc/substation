//! CoreFoundation's run loop, as far as the render thread needs it: its own
//! CFRunLoop, a version-0 source the emulator thread signals, and a timer.
//! Plain C, so nothing here goes through `objc`.

pub const CFTypeRef = *anyopaque;
pub const RunLoop = *opaque {};
pub const RunLoopSource = *opaque {};
pub const RunLoopTimer = *opaque {};
pub const CFString = *opaque {};
pub const AbsoluteTime = f64;
pub const Dictionary = *opaque {};
pub const Boolean = *opaque {};

/// CFString.h's kCFStringEncodingUTF8.
pub const string_encoding_utf8: u32 = 0x08000100;

/// CFRunLoop.h's version-0 source context. `perform` runs on the loop's
/// thread once the source is signalled and the loop woken.
pub const RunLoopSourceContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque = null,
    retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.c) void = null,
    copyDescription: ?*const fn (?*const anyopaque) callconv(.c) ?CFString = null,
    equal: ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) u8 = null,
    hash: ?*const fn (?*const anyopaque) callconv(.c) usize = null,
    schedule: ?*const fn (?*anyopaque, RunLoop, CFString) callconv(.c) void = null,
    cancel: ?*const fn (?*anyopaque, RunLoop, CFString) callconv(.c) void = null,
    perform: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub const RunLoopTimerContext = extern struct {
    version: isize = 0,
    info: ?*anyopaque = null,
    retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.c) void = null,
    copyDescription: ?*const fn (?*const anyopaque) callconv(.c) ?CFString = null,
};

pub const TimerCallback = *const fn (RunLoopTimer, ?*anyopaque) callconv(.c) void;

pub extern "c" const kCFRunLoopDefaultMode: CFString;
pub extern "c" const kCFRunLoopCommonModes: CFString;

pub extern "c" fn CFRetain(cf: CFTypeRef) CFTypeRef;
pub extern "c" fn CFRelease(cf: CFTypeRef) void;
pub extern "c" fn CFRunLoopGetCurrent() RunLoop;
pub extern "c" fn CFRunLoopRun() void;
pub extern "c" fn CFRunLoopStop(rl: RunLoop) void;
pub extern "c" fn CFRunLoopWakeUp(rl: RunLoop) void;
pub extern "c" fn CFRunLoopSourceCreate(alloc: ?CFTypeRef, order: isize, ctx: *RunLoopSourceContext) ?RunLoopSource;
pub extern "c" fn CFRunLoopAddSource(rl: RunLoop, source: RunLoopSource, mode: CFString) void;
pub extern "c" fn CFRunLoopSourceSignal(source: RunLoopSource) void;
pub extern "c" fn CFRunLoopSourceInvalidate(source: RunLoopSource) void;
pub extern "c" fn CFRunLoopTimerCreate(alloc: ?CFTypeRef, fire_date: AbsoluteTime, interval: f64, flags: usize, order: isize, callout: TimerCallback, ctx: *RunLoopTimerContext) ?RunLoopTimer;
pub extern "c" fn CFRunLoopAddTimer(rl: RunLoop, timer: RunLoopTimer, mode: CFString) void;
pub extern "c" fn CFRunLoopTimerInvalidate(timer: RunLoopTimer) void;
pub extern "c" fn CFAbsoluteTimeGetCurrent() AbsoluteTime;
pub extern "c" fn CFStringCreateWithCString(alloc: ?CFTypeRef, str: [*:0]const u8, encoding: u32) ?CFString;
pub extern "c" fn CFDictionaryGetValue(dict: Dictionary, key: *const anyopaque) ?*const anyopaque;
pub extern "c" fn CFBooleanGetValue(b: Boolean) u8;
pub extern "c" fn CFGetTypeID(cf: CFTypeRef) usize;
pub extern "c" fn CFBooleanGetTypeID() usize;
/// CoreGraphics, not CoreFoundation, but plain C all the same. Owned; null
/// when the process has no window-server session.
pub extern "c" fn CGSessionCopyCurrentDictionary() ?Dictionary;

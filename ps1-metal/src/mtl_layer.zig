//! The QuartzCore and AppKit objects the render thread presents through: a
//! CAMetalLayer and its drawables, the NSView the frontend hands over, the
//! view's display link, and (for the tests) a borderless window to put a
//! view on screen. Same ownership rules as `mtl.zig`.

const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const enums = @import("mtl_enums.zig");
const cf = @import("cf.zig");

const msg = objc.msg;

const CGSize = extern struct { width: f64, height: f64 };
const CGPoint = extern struct { x: f64, y: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

fn alloc(comptime class: [:0]const u8) objc.Id {
    return msg(objc.Id, objc.class(class), "alloc", .{});
}

pub const MetalLayer = struct {
    id: objc.Id,

    /// Owned.
    pub fn new() MetalLayer {
        return .{ .id = msg(objc.Id, alloc("CAMetalLayer"), "init", .{}) };
    }

    pub fn release(self: MetalLayer) void {
        objc.release(self.id);
    }

    pub fn setDevice(self: MetalLayer, device: mtl.Device) void {
        msg(void, self, "setDevice:", .{device.id});
    }

    pub fn setPixelFormat(self: MetalLayer, format: enums.PixelFormat) void {
        msg(void, self, "setPixelFormat:", .{@backingInt(format)});
    }

    pub fn setFramebufferOnly(self: MetalLayer, on: bool) void {
        msg(void, self, "setFramebufferOnly:", .{on});
    }

    /// NO: presenting needs no main-thread transaction.
    pub fn setPresentsWithTransaction(self: MetalLayer, on: bool) void {
        msg(void, self, "setPresentsWithTransaction:", .{on});
    }

    /// In pixels.
    pub fn setDrawableSize(self: MetalLayer, width: f64, height: f64) void {
        msg(void, self, "setDrawableSize:", .{CGSize{ .width = width, .height = height }});
    }

    pub fn setContentsScale(self: MetalLayer, scale: f64) void {
        msg(void, self, "setContentsScale:", .{scale});
    }

    /// Autoreleased; null when none is free in time.
    pub fn nextDrawable(self: MetalLayer) ?Drawable {
        return mtl.owned(Drawable, msg(?objc.Id, self, "nextDrawable", .{}));
    }
};

pub const Drawable = struct {
    id: objc.Id,

    /// Borrowed from the drawable.
    pub fn texture(self: Drawable) mtl.Texture {
        return .{ .id = msg(objc.Id, self, "texture", .{}) };
    }
};

pub const View = struct {
    id: objc.Id,

    pub fn setWantsLayer(self: View, on: bool) void {
        msg(void, self, "setWantsLayer:", .{on});
    }

    pub fn setLayer(self: View, l: MetalLayer) void {
        msg(void, self, "setLayer:", .{l.id});
    }

    /// Main thread only, as every NSView call is.
    pub fn removeLayer(self: View) void {
        msg(void, self, "setLayer:", .{@as(?objc.Id, null)});
    }

    /// Owned. `-[NSView displayLinkWithTarget:selector:]` (macOS 14+): it
    /// follows the screen the view is on, so a 120 Hz panel fires at 120 Hz.
    /// The link retains `target`.
    pub fn displayLink(self: View, target: objc.Id, comptime selector: [:0]const u8) DisplayLink {
        const link = msg(objc.Id, self, "displayLinkWithTarget:selector:", .{ target, objc.sel(selector) });
        return .{ .id = objc.retain(link) };
    }
};

pub const DisplayLink = struct {
    id: objc.Id,

    pub fn release(self: DisplayLink) void {
        objc.release(self.id);
    }

    /// To the calling thread's run loop, in the common modes: the link then
    /// fires on that thread.
    pub fn addToCurrentRunLoop(self: DisplayLink) void {
        const rl = msg(objc.Id, objc.class("NSRunLoop"), "currentRunLoop", .{});
        // kCFRunLoopCommonModes is toll-free bridged to NSRunLoopCommonModes.
        const modes: objc.Id = @ptrCast(cf.kCFRunLoopCommonModes);
        msg(void, self, "addToRunLoop:forMode:", .{ rl, modes });
    }

    pub fn setPaused(self: DisplayLink, paused: bool) void {
        msg(void, self, "setPaused:", .{paused});
    }

    /// Removes it from every run loop; it never fires again.
    pub fn invalidate(self: DisplayLink) void {
        msg(void, self, "invalidate", .{});
    }
};

pub fn onMainThread() bool {
    return msg(bool, objc.class("NSThread"), "isMainThread", .{});
}

/// AppKit's application object, which a window needs before it can be shown.
pub fn sharedApplication() void {
    _ = msg(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
}

pub fn hasScreen() bool {
    return msg(?objc.Id, objc.class("NSScreen"), "mainScreen", .{}) != null;
}

/// Whether the login session's screen is locked, when no display link
/// fires. False without a session.
pub fn screenLocked() bool {
    const dict = cf.CGSessionCopyCurrentDictionary() orelse return false;
    defer cf.CFRelease(dict);
    const key = cf.CFStringCreateWithCString(null, "CGSSessionScreenIsLocked", cf.string_encoding_utf8) orelse return false;
    defer cf.CFRelease(key);
    const value = cf.CFDictionaryGetValue(dict, key) orelse return false;
    const obj: cf.CFTypeRef = @constCast(value);
    if (cf.CFGetTypeID(obj) != cf.CFBooleanGetTypeID()) return false;
    return cf.CFBooleanGetValue(@ptrCast(obj)) != 0;
}

/// A borderless window holding one view: the tests' way to put a view on a
/// screen. Main thread only, as all of AppKit's window calls are.
pub const Window = struct {
    id: objc.Id,

    // NSWindow.h: NSWindowStyleMaskBorderless = 0; NSGraphics.h:
    // NSBackingStoreBuffered = 2.
    const borderless: usize = 0;
    const backing_buffered: usize = 2;

    pub fn new(width: f64, height: f64) Window {
        const rect: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } };
        const w = msg(objc.Id, alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{ rect, borderless, backing_buffered, false });
        msg(void, w, "setReleasedWhenClosed:", .{false});
        return .{ .id = w };
    }

    /// Borrowed from the window.
    pub fn view(self: Window) View {
        return .{ .id = msg(objc.Id, self, "contentView", .{}) };
    }

    pub fn orderFront(self: Window) void {
        msg(void, self, "orderFront:", .{@as(?objc.Id, null)});
    }

    pub fn close(self: Window) void {
        msg(void, self, "close", .{});
        objc.release(self.id);
    }
};

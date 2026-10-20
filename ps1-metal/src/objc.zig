//! The Objective-C runtime, as far as the Metal wrappers need it: classes,
//! selectors, one typed message send, retain/release, autorelease pools and
//! a block literal.
//!
//! arm64 only. Every send goes through `objc_msgSend` with the C calling
//! convention: arm64 has no `_stret`/`_fpret` variants, and a struct
//! argument is passed by value as the `extern struct` it is declared as.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64 or !builtin.os.tag.isDarwin()) {
        @compileError("objc.zig casts objc_msgSend directly, which is only right on arm64 Darwin");
    }
}

/// Any Objective-C object.
pub const Id = *opaque {};
pub const Class = *opaque {};
pub const Sel = *opaque {};

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_retain(o: Id) Id;
extern "c" fn objc_release(o: Id) void;
extern "c" fn objc_autoreleasePoolPush() *anyopaque;
extern "c" fn objc_autoreleasePoolPop(token: *anyopaque) void;
extern "c" var _NSConcreteStackBlock: opaque {};

/// One slot per (kind, name). A container's identity is where it is declared
/// and the comptime values it captures, so the slot must capture `name`: a
/// struct that references nothing is ONE struct for every selector, and every
/// send then goes to whichever selector was looked up first.
fn Cache(comptime T: type, comptime name: [:0]const u8) type {
    return struct {
        comptime {
            _ = name;
        }
        var value: ?T = null;
    };
}

/// Cached per name. A missing class is a link-time fact (a framework not
/// linked, a name misspelt), so it panics naming the class.
pub fn class(comptime name: [:0]const u8) Class {
    const cache = Cache(Class, name);
    if (@atomicLoad(?Class, &cache.value, .monotonic)) |c| return c;
    const c = objc_getClass(name) orelse std.debug.panic("Objective-C class {s} not found", .{name});
    @atomicStore(?Class, &cache.value, c, .monotonic);
    return c;
}

/// Cached per selector.
pub fn sel(comptime name: [:0]const u8) Sel {
    const cache = Cache(Sel, name);
    if (@atomicLoad(?Sel, &cache.value, .monotonic)) |s| return s;
    const s = sel_registerName(name);
    @atomicStore(?Sel, &cache.value, s, .monotonic);
    return s;
}

/// The receiver as the runtime sees it: an `Id`, a `Class`, or a wrapper
/// carrying its object in `.id`.
fn receiver(target: anytype) *anyopaque {
    const T = @TypeOf(target);
    if (T == Id or T == Class) return target;
    if (@typeInfo(T) == .@"struct" and @hasField(T, "id")) return target.id;
    @compileError("not a message receiver: " ++ @typeName(T));
}

/// `objc_msgSend` cast to `fn (receiver, Sel, args...) callconv(.c) R` and
/// called. The fn type is built with `@Fn` from the tuple type of `args`,
/// so every argument must have a concrete type: a bare integer literal has
/// none, and is refused rather than guessed at.
pub fn msg(comptime R: type, target: anytype, comptime selector: [:0]const u8, args: anytype) R {
    const Args = @TypeOf(args);
    const info = @typeInfo(Args).@"struct";
    comptime var params: [info.field_types.len + 2]type = undefined;
    params[0] = *anyopaque;
    params[1] = Sel;
    inline for (info.field_types, 0..) |T, i| {
        if (T == comptime_int or T == comptime_float) {
            @compileError("msg(" ++ selector ++ "): argument " ++ std.fmt.comptimePrint("{d}", .{i}) ++
                " has no concrete type; give it one with @as");
        }
        params[i + 2] = T;
    }
    const Fn = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .c });
    const send: *const Fn = @ptrCast(&objc_msgSend);
    return @call(.auto, send, .{ receiver(target), sel(selector) } ++ args);
}

pub fn retain(o: Id) Id {
    return objc_retain(o);
}

pub fn release(o: Id) void {
    objc_release(o);
}

/// Autoreleased: valid until the enclosing `Pool` pops.
pub fn nsString(s: [:0]const u8) Id {
    return msg(Id, class("NSString"), "stringWithUTF8String:", .{s.ptr});
}

/// An NSString's bytes, borrowed from the string: valid as long as it is.
pub fn utf8(string: Id) [*:0]const u8 {
    return msg([*:0]const u8, string, "UTF8String", .{});
}

/// What an `NSError` says about itself, for an error log.
pub fn describe(err: Id) [*:0]const u8 {
    return utf8(msg(Id, err, "localizedDescription", .{}));
}

pub const Pool = struct {
    token: *anyopaque,

    pub fn push() Pool {
        return .{ .token = objc_autoreleasePoolPush() };
    }

    pub fn pop(self: Pool) void {
        objc_autoreleasePoolPop(self.token);
    }
};

/// A block taking one object, such as MTLCommandBuffer's completed handler.
///
/// A stack literal (`_NSConcreteStackBlock`, flags 0, no copy helpers) that
/// carries `*Ctx`. A callee that keeps the block `Block_copy`s it, which
/// moves the literal (and with it the `ctx` pointer) to the heap; the
/// literal itself is valid only for the call it is passed to, while `ctx`
/// must outlive every invocation.
pub fn Block(comptime Ctx: type, comptime invoke: fn (*Ctx, Id) void) type {
    return extern struct {
        const Self = @This();

        const Descriptor = extern struct {
            reserved: c_ulong = 0,
            size: c_ulong,
        };
        const block_descriptor: Descriptor = .{ .size = @sizeOf(Self) };

        isa: *anyopaque,
        flags: c_int = 0,
        reserved: c_int = 0,
        invoke: *const fn (*Self, Id) callconv(.c) void,
        descriptor: *const Descriptor,
        ctx: *Ctx,

        pub fn init(ctx: *Ctx) Self {
            return .{
                .isa = @ptrCast(&_NSConcreteStackBlock),
                .invoke = trampoline,
                .descriptor = &block_descriptor,
                .ctx = ctx,
            };
        }

        /// The block as an Objective-C argument.
        pub fn ptr(self: *Self) *anyopaque {
            return self;
        }

        fn trampoline(self: *Self, arg: Id) callconv(.c) void {
            invoke(self.ctx, arg);
        }
    };
}

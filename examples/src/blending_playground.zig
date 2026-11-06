//! Blend modes and Porter-Duff compositing operators, exposed to the web playground.

const std = @import("std");
const builtin = @import("builtin");

const zignal = @import("zignal");
const Image = zignal.Image;
const Blending = zignal.Blending;
const Compositing = zignal.Compositing;
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.target.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = if (builtin.mode == .debug) .debug else .info,
};

comptime {
    _ = js.alloc;
    _ = js.free;
}

pub fn panic(msg: []const u8, st: ?*std.lang.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

/// Space-separated tag names in enum order, NUL-terminated.
fn joinedNames(comptime E: type) [*:0]const u8 {
    comptime var joined: [:0]const u8 = "";
    inline for (comptime std.meta.fieldNames(E), 0..) |name, i| {
        joined = joined ++ (if (i == 0) "" else " ") ++ name;
    }
    const final = joined;
    return final.ptr;
}

pub export fn blendModeNames() [*:0]const u8 {
    return joinedNames(Blending);
}

pub export fn compositingNames() [*:0]const u8 {
    return joinedNames(Compositing);
}

/// Writes `base` blended with `overlay` into `out` (all `rows * cols` RGBA pixels).
pub export fn blend(base: [*]const Rgba, overlay: [*]Rgba, out: [*]Rgba, rows: u32, cols: u32, mode: u32) void {
    const result = copyBase(base, out, rows, cols);
    result.blend(.initFromSlice(rows, cols, overlay[0..result.data.len]), @fromBackingInt(@intCast(mode)));
}

/// Writes `overlay` composited onto `base` into `out` (all `rows * cols` RGBA pixels).
pub export fn composite(base: [*]const Rgba, overlay: [*]Rgba, out: [*]Rgba, rows: u32, cols: u32, op: u32) void {
    const result = copyBase(base, out, rows, cols);
    result.composite(.initFromSlice(rows, cols, overlay[0..result.data.len]), @fromBackingInt(@intCast(op)));
}

/// The blend function B(Cb, Cs) for opaque 0xRRGGBB colors: with both opaque, blending returns B.
pub export fn blendValue(base: u32, overlay: u32, mode: u32) u32 {
    return Rgb.initHex(@truncate(base)).blend(Rgb.initHex(@truncate(overlay)).withAlpha(255), @fromBackingInt(@intCast(mode))).hex();
}

/// Fills `out` (`size * size`) with B on opaque grays: base grows left to right, overlay bottom to top.
pub export fn blendMap(out: [*]Rgba, size: u32, mode: u32) void {
    const blending: Blending = @fromBackingInt(@intCast(mode));
    const last: f32 = @floatFromInt(size - 1);
    for (0..size) |row| {
        const s: u8 = @round(255 * (last - @as(f32, @floatFromInt(row))) / last);
        for (0..size) |col| {
            const b: u8 = @round(255 * @as(f32, @floatFromInt(col)) / last);
            const base: Rgba = .{ .r = b, .g = b, .b = b, .a = 255 };
            out[row * size + col] = base.blend(.{ .r = s, .g = s, .b = s, .a = 255 }, blending);
        }
    }
}

fn copyBase(base: [*]const Rgba, out: [*]Rgba, rows: u32, cols: u32) Image(Rgba) {
    const len = @as(usize, rows) * cols;
    @memcpy(out[0..len], base[0..len]);
    return .initFromSlice(rows, cols, out[0..len]);
}

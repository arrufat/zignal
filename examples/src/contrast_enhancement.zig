const std = @import("std");
const builtin = @import("builtin");
const zignal = @import("zignal");

const Image = zignal.Image;
const Rgba = zignal.Rgba;
const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = .info,
};

pub const alloc = js.alloc;
pub const free = js.free;

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

fn imageFromPtr(rgba_ptr: [*]Rgba, rows: usize, cols: usize) Image(Rgba) {
    const total_pixels = std.math.mul(usize, rows, cols) catch @panic("contrast_enhancement: image too large");
    return Image(Rgba).initFromSlice(rows, cols, rgba_ptr[0..total_pixels]);
}

pub export fn autocontrast_inplace(rgba_ptr: [*]Rgba, rows: usize, cols: usize, cutoff: f32) void {
    const sanitized_cutoff = std.math.clamp(cutoff, 0.0, 0.49);
    const image = imageFromPtr(rgba_ptr, rows, cols);
    image.autocontrast(sanitized_cutoff) catch |err| {
        std.log.err("autocontrast failed: {s}", .{@errorName(err)});
    };
}

pub export fn equalize_inplace(rgba_ptr: [*]Rgba, rows: usize, cols: usize) void {
    const image = imageFromPtr(rgba_ptr, rows, cols);
    image.equalize();
}

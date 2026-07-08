const std = @import("std");
const builtin = @import("builtin");

const zignal = @import("zignal");
const Image = zignal.Image;
const qrcode = zignal.qrcode;

const Rgba = zignal.Rgba(u8);

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

comptime {
    _ = js.alloc;
    _ = js.free;
}

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

const allocator = if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

/// Encodes text into a QR symbol rendered as RGBA at one pixel per module
/// with a 4-module quiet zone (scale it up losslessly on the canvas side).
/// Returns the square image side length in pixels, 0 when the text does not
/// fit any version, or -1 on error / insufficient out_capacity.
pub export fn qr_encode(
    text_ptr: [*]const u8,
    text_len: usize,
    ec_level: u32,
    out_ptr: [*]Rgba,
    out_capacity: usize,
) i32 {
    var image = qrcode.encodeImage(allocator, text_ptr[0..text_len], .{
        .ec_level = @enumFromInt(@min(ec_level, 3)),
        .module_size = 1,
    }) catch |err| switch (err) {
        error.DataTooLarge => return 0,
        else => {
            std.log.err("qr_encode: {s}", .{@errorName(err)});
            return -1;
        },
    };
    defer image.deinit(allocator);

    const size = @as(usize, image.rows) * image.cols;
    if (size > out_capacity) return -1;
    image.convertInto(Rgba, .initFromSlice(image.rows, image.cols, out_ptr[0..size]));
    return @intCast(image.rows);
}

/// Decodes a QR code from an RGBA image. On success writes the decoded text
/// into out_ptr and the four symbol corners into corners_ptr as x, y pairs
/// (top-left, top-right, bottom-left, bottom-right). Returns the text length,
/// 0 when no code is found, or -1 on error / insufficient out_capacity.
pub export fn qr_decode(
    rgba_ptr: [*]Rgba,
    rows: u32,
    cols: u32,
    out_ptr: [*]u8,
    out_capacity: usize,
    corners_ptr: [*]f32,
) i32 {
    const size = @as(usize, rows) * cols;
    const rgba: Image(Rgba) = .initFromSlice(rows, cols, rgba_ptr[0..size]);

    var result = (qrcode.decode(allocator, rgba) catch |err| {
        std.log.err("qr_decode: {s}", .{@errorName(err)});
        return -1;
    }) orelse return 0;
    defer result.deinit(allocator);

    if (result.data.len > out_capacity) return -1;
    @memcpy(out_ptr[0..result.data.len], result.data);
    const corners = result.corners orelse return @intCast(result.data.len);
    for (corners, 0..) |corner, i| {
        corners_ptr[2 * i] = corner.x();
        corners_ptr[2 * i + 1] = corner.y();
    }
    return @intCast(result.data.len);
}

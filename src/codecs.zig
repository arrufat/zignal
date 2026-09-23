//! Image codec aggregator. Re-exports the codec modules so that
//! `src/root.zig` and other in-tree consumers have a single import point,
//! and so the build's per-format tests share `src/` as their module root
//! (codec internals reach `../color.zig` etc., which would fall outside
//! the module path if each codec file were a test root on its own).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb(u8);
const Rgba = @import("color.zig").Rgba(u8);

pub const bmp = @import("codecs/bmp.zig");
pub const gif = @import("codecs/gif.zig");
pub const jpeg = @import("codecs/jpeg.zig");
pub const jxl = @import("codecs/jxl.zig");
pub const png = @import("codecs/png.zig");
pub const webp = @import("codecs/webp.zig");

/// A decoded image in the pixel type closest to how the file stores it.
pub const NativeImage = union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),

    pub fn deinit(self: *NativeImage, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*img| img.deinit(allocator),
        }
    }

    /// Hands over the image as `Image(T)`, converting (and freeing the original) only when
    /// the pixel types differ.
    pub fn into(self: *NativeImage, comptime T: type, io: Io, allocator: Allocator) !Image(T) {
        switch (self.*) {
            inline else => |*img| {
                if (@TypeOf(img.*) == Image(T)) return img.*;
                defer self.deinit(allocator);
                return img.convert(io, allocator, T);
            },
        }
    }
};

/// Default cap on encoded input, shared by every codec's `DecodeLimits` and the
/// format-detecting loaders.
pub const max_file_size: usize = 100 * 1024 * 1024;

/// Whether `value` is over `limit`; a zero limit disables the check.
pub inline fn exceeds(limit: u64, value: u64) bool {
    return limit != 0 and value > limit;
}

/// Adds `addend` to a running total, failing with `limit_error` on overflow or past `limit`
/// (0 disables the cap).
pub fn accumulateWithLimit(current: *usize, addend: usize, limit: usize, limit_error: anyerror) !void {
    const new_total = std.math.add(usize, current.*, addend) catch return limit_error;
    if (exceeds(limit, new_total)) return limit_error;
    current.* = new_total;
}

/// Reads a whole file for decoding; `max_bytes == 0` means no cap.
pub fn readFile(io: Io, allocator: Allocator, file_path: []const u8, max_bytes: usize) ![]u8 {
    const limit: Io.Limit = if (max_bytes == 0) .unlimited else .limited(max_bytes);
    return Io.Dir.cwd().readFileAlloc(io, file_path, allocator, limit);
}

/// Creates (or truncates) `file_path` and writes `data` to it.
pub fn writeFile(io: Io, file_path: []const u8, data: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

test {
    _ = bmp;
    _ = gif;
    _ = jpeg;
    _ = jxl;
    _ = png;
    _ = webp;
    _ = @import("codecs/dynlib.zig");
}

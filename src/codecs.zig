//! Image codec aggregator. Re-exports the codec modules so that
//! `src/root.zig` and other in-tree consumers have a single import point,
//! and so the build's per-format tests share `src/` as their module root
//! (codec internals reach `../color.zig` etc., which would fall outside
//! the module path if each codec file were a test root on its own).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const bmp = @import("codecs/bmp.zig");
pub const gif = @import("codecs/gif.zig");
pub const jpeg = @import("codecs/jpeg.zig");
pub const jxl = @import("codecs/jxl.zig");
pub const png = @import("codecs/png.zig");
pub const webp = @import("codecs/webp.zig");

/// Whether `value` is over `limit`.
pub inline fn exceeds(limit: Io.Limit, value: u64) bool {
    return if (limit.toInt()) |max| value > max else false;
}

/// Adds `addend` to a running total, failing with `limit_error` on overflow or past `limit`.
pub fn accumulateWithLimit(current: *usize, addend: usize, limit: Io.Limit, limit_error: anyerror) !void {
    const new_total = std.math.add(usize, current.*, addend) catch return limit_error;
    if (exceeds(limit, new_total)) return limit_error;
    current.* = new_total;
}

/// Returns `read(before ++ .{reader} ++ after)` on `file_path`, surfacing the file's own error.
pub fn readFile(io: Io, file_path: []const u8, comptime read: anytype, before: anytype, after: anytype) !Payload(read) {
    const file = try Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return @call(.auto, read, before ++ .{&file_reader.interface} ++ after) catch |err| return file_reader.err orelse err;
}

fn Payload(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.payload;
}

/// An allocating writer only fails when out of memory: `WriteFailed` becomes `OutOfMemory`.
pub fn allocatingError(err: anytype) (@TypeOf(err) || error{OutOfMemory}) {
    if (@as(anyerror, err) == error.WriteFailed) return error.OutOfMemory;
    return err;
}

/// Returns the bytes `write(before ++ .{writer} ++ after)` writes. Caller owns them.
pub fn encodeWith(allocator: Allocator, comptime write: anytype, before: anytype, after: anytype) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    @call(.auto, write, before ++ .{&aw.writer} ++ after) catch |err| return allocatingError(err);
    return aw.toOwnedSlice();
}

/// Streams `write(before ++ .{writer} ++ after)` into `file_path`, surfacing the file's own error.
pub fn writeFile(io: Io, file_path: []const u8, comptime write: anytype, before: anytype, after: anytype) !void {
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    var buffer: [32 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    @call(.auto, write, before ++ .{&file_writer.interface} ++ after) catch |err| return file_writer.err orelse err;
    file_writer.interface.flush() catch return file_writer.err.?;
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

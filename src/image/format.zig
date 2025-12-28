//! Image format detection and identification

const std = @import("std");
const Allocator = std.mem.Allocator;
const png = @import("../png.zig");
const jpeg = @import("../jpeg.zig");

/// Supported image formats for automatic detection and loading
pub const ImageFormat = enum {
    png,
    jpeg,

    /// Detect image format from the first few bytes of data
    pub fn detectFromBytes(data: []const u8) ?ImageFormat {
        // PNG signature
        if (data.len >= 8) {
            if (std.mem.eql(u8, data[0..8], &png.signature)) {
                return .png;
            }
        }

        // JPEG signature
        if (data.len >= 2) {
            if (std.mem.eql(u8, data[0..2], &jpeg.signature)) {
                return .jpeg;
            }
        }

        return null;
    }

    /// Detect image format from file path by reading the first few bytes
    pub fn detectFromPath(io: std.Io, _: Allocator, file_path: []const u8) !?ImageFormat {
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        var header: [8]u8 = undefined;
        var iov = [_][]u8{header[0..]};
        const bytes_read = try file.readStreaming(io, &iov);

        return detectFromBytes(header[0..bytes_read]);
    }
};

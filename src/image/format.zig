//! Image format detection and identification

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bmp = @import("../bmp.zig");
const gif = @import("../gif.zig");
const jpeg = @import("../jpeg.zig");
const png = @import("../png.zig");

/// Supported image formats for automatic detection and loading
pub const ImageFormat = enum {
    png,
    jpeg,
    bmp,
    gif,

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

        // BMP signature
        if (data.len >= 2) {
            if (std.mem.eql(u8, data[0..2], &bmp.signature)) {
                return .bmp;
            }
        }

        // GIF signature: "GIF87a" or "GIF89a" (6 bytes)
        if (data.len >= 6 and std.mem.eql(u8, data[0..3], &gif.signature)) {
            if (std.mem.eql(u8, data[3..6], "87a") or std.mem.eql(u8, data[3..6], "89a")) {
                return .gif;
            }
        }

        return null;
    }

    /// Detect image format from file path by reading the first few bytes
    pub fn detectFromPath(io: Io, _: Allocator, file_path: []const u8) !?ImageFormat {
        const file = try Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        var header: [8]u8 = undefined;
        var iov = [_][]u8{header[0..]};
        const bytes_read = try file.readStreaming(io, &iov);

        return detectFromBytes(header[0..bytes_read]);
    }

    /// Map a file path's extension to a format. Used by `save`, where the file
    /// doesn't yet exist so signature sniffing isn't an option. Comparison is
    /// case-insensitive.
    pub fn fromExtension(file_path: []const u8) ?ImageFormat {
        const matches = struct {
            fn check(path: []const u8, ext: []const u8) bool {
                return std.ascii.endsWithIgnoreCase(path, ext);
            }
        }.check;

        if (matches(file_path, ".png")) return .png;
        if (matches(file_path, ".jpg") or matches(file_path, ".jpeg")) return .jpeg;
        if (matches(file_path, ".bmp")) return .bmp;
        if (matches(file_path, ".gif")) return .gif;
        return null;
    }
};

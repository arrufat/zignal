//! Font system for zignal
//!
//! This module provides bitmap font rendering capabilities including:
//! - Default 8x8 bitmap font
//! - BDF font loading with Unicode support
//! - Variable-width font support
//!
//! The font system is organized into subdirectories for better modularity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Io = std.Io;

/// Maximum file size for font files (50MB)
/// This limit prevents DoS attacks and accidental memory exhaustion
/// while being large enough for all known font files
pub const max_file_size = 50 * 1024 * 1024;

// Core font types
pub const BitmapFont = @import("font/BitmapFont.zig");

/// Font loading filter
pub const LoadFilter = union(enum) {
    /// Load all characters in the font
    all,
    /// Load only specified Unicode ranges
    ranges: []const unicode.Range,

    /// Returns true if `codepoint` is included by this filter
    pub fn matches(self: LoadFilter, codepoint: u32) bool {
        switch (self) {
            .all => return true,
            .ranges => |ranges| {
                for (ranges) |range| {
                    if (codepoint >= range.start and codepoint <= range.end) return true;
                }
                return false;
            },
        }
    }
};

/// Returns true if `path` names a gzip-compressed file
pub fn isGzipPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".gz");
}

/// Reads a font file into memory, transparently decompressing gzip (`.gz`) files.
/// Caller owns the returned slice.
pub fn readFileMaybeGzip(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size));
    if (!isGzipPath(path)) return raw;
    defer gpa.free(raw);

    var reader: Io.Reader = .fixed(raw);

    const buffer = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(buffer);

    var decompressor: flate.Decompress = .init(&reader, .gzip, buffer);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var remaining = Io.Limit.limited(max_file_size);
    while (remaining.nonzero()) {
        const n = decompressor.reader.stream(&aw.writer, remaining) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.InvalidCompression,
            else => return err,
        };
        remaining = remaining.subtract(n).?;
    } else {
        // Reject streams that would exceed max_file_size by probing for one more byte
        var one_byte_buf: [1]u8 = undefined;
        var dummy_writer = Io.Writer.fixed(&one_byte_buf);
        if (decompressor.reader.stream(&dummy_writer, .limited(1))) |n| {
            if (n > 0) return error.InvalidCompression;
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => return error.InvalidCompression,
            else => return err,
        }
    }

    return aw.toOwnedSlice();
}

/// Writes `bytes` to `path`, gzip-compressing when the path ends in `.gz`.
pub fn writeFileMaybeGzip(io: Io, gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    const file = if (Io.Dir.path.isAbsolute(path))
        try Io.Dir.createFileAbsolute(io, path, .{})
    else
        try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    if (!isGzipPath(path)) {
        return file.writeStreamingAll(io, bytes);
    }

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.ensureTotalCapacity(bytes.len / 2 + 64);

    const buffer = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(buffer);

    var compressor: flate.Compress = try .init(&aw.writer, buffer, .gzip, .level_1);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();

    const compressed = try aw.toOwnedSlice();
    defer gpa.free(compressed);
    try file.writeStreamingAll(io, compressed);
}

// font8x8 - 8x8 monospace bitmap font
pub const font8x8 = @import("font/font8x8.zig");

// Unicode utilities
pub const unicode = @import("font/unicode.zig");

// Format detection
pub const FontFormat = @import("font/format.zig").FontFormat;

// BDF font support
pub const bdf = @import("font/bdf.zig");

// PCF font support
pub const pcf = @import("font/pcf.zig");

test {
    _ = font8x8;
    _ = bdf;
    _ = pcf;
}

//! Font system for zignal
//!
//! This module provides font rendering capabilities including:
//! - Default 8x8 bitmap font
//! - BDF and PCF bitmap font loading with Unicode support
//! - TrueType (`.ttf`), CFF OpenType (`.otf`) and collection (`.ttc`) vector fonts with kerning
//! - Variable-width font support
//!
//! The font system is organized into subdirectories for better modularity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Io = std.Io;

const Rectangle = @import("geometry.zig").Rectangle;

/// Maximum file size for font files (50MB)
/// This limit prevents DoS attacks and accidental memory exhaustion
/// while being large enough for all known font files
pub const max_file_size = 50 * 1024 * 1024;

// Core font types
pub const BitmapFont = @import("font/BitmapFont.zig");
pub const VectorFont = @import("font/VectorFont.zig");
pub const Outline = @import("font/Outline.zig");
pub const truetype = @import("font/truetype.zig");

/// A font of either kind, so text APIs can take one transparently. `size` is always
/// the pixel size: the em height for vector fonts, the character height for bitmap fonts.
pub const Font = union(enum) {
    bitmap: BitmapFont,
    vector: VectorFont,

    /// Size a vector font is drawn at when none is given; bitmap fonts use their own.
    pub const default_vector_size: f32 = 16;

    /// Loads any supported format by sniffing the file; bitmap fonts load all characters
    /// and collections yield their first face.
    pub fn load(io: Io, gpa: Allocator, path: []const u8) !Font {
        return loadFace(io, gpa, path, 0);
    }

    /// `load` for face `face` of a `.ttc` collection. Only face 0 exists otherwise.
    pub fn loadFace(io: Io, gpa: Allocator, path: []const u8, face: u32) !Font {
        const format = try FontFormat.detectFromPath(io, path) orelse return error.UnsupportedFontFormat;
        return switch (format) {
            .bdf, .pcf => if (face == 0) .{ .bitmap = try BitmapFont.load(io, gpa, path, .all) } else error.InvalidFormat,
            .ttf, .otf, .ttc => .{ .vector = try VectorFont.loadFace(io, gpa, path, face) },
        };
    }

    pub fn deinit(self: *Font, gpa: Allocator) void {
        switch (self.*) {
            .bitmap => |*b| b.deinit(gpa),
            .vector => |*v| v.deinit(gpa),
        }
    }

    /// The size used when a caller gives none: a bitmap font's character height (1:1
    /// pixels), `default_vector_size` for vector fonts.
    pub fn defaultSize(self: Font) f32 {
        return switch (self) {
            .bitmap => |b| @floatFromInt(b.char_height),
            .vector => default_vector_size,
        };
    }

    /// Distance from the top of a line to its baseline, in pixels.
    pub fn ascent(self: Font, size: f32) f32 {
        return switch (self) {
            .bitmap => |b| @as(f32, @floatFromInt(b.ascent())) * b.scaleFor(size),
            .vector => |v| @as(f32, @floatFromInt(v.ascent)) * v.scaleFor(size),
        };
    }

    /// Baseline-to-baseline distance, in pixels.
    pub fn lineHeight(self: Font, size: f32) f32 {
        return switch (self) {
            .bitmap => size,
            .vector => |v| v.lineHeight(size),
        };
    }

    pub fn hasGlyph(self: Font, codepoint: u21) bool {
        return switch (self) {
            .bitmap => |b| b.getGlyph(codepoint) != null,
            .vector => |v| v.glyphIndex(codepoint) != 0,
        };
    }

    /// Box occupied by `text` relative to its top-left corner.
    pub fn getTextBounds(self: Font, text: []const u8, size: f32) Rectangle(f32) {
        return switch (self) {
            .bitmap => |b| b.getTextBounds(text, b.scaleFor(size)),
            .vector => |v| v.getTextBounds(text, size),
        };
    }

    /// Box of the inked pixels of `text` relative to its top-left corner.
    pub fn getTextBoundsTight(self: Font, text: []const u8, size: f32) Rectangle(f32) {
        return switch (self) {
            .bitmap => |b| b.getTextBoundsTight(text, b.scaleFor(size)),
            .vector => |v| v.getTextBoundsTight(text, size),
        };
    }
};

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
    _ = VectorFont;
    _ = Outline;
    _ = truetype;
}

test "Font.load dispatches on the format" {
    const synthetic = @import("font/truetype/synthetic.zig");
    var buf: [synthetic.buffer_size]u8 = undefined;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "synth.ttf", .data = synthetic.build(&buf, .{}) });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "synth.ttf", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var font: Font = try .load(std.testing.io, std.testing.allocator, path);
    defer font.deinit(std.testing.allocator);
    try std.testing.expect(font == .vector);
    try std.testing.expect(font.hasGlyph('A'));
    try std.testing.expect(!font.hasGlyph('Z'));
    try std.testing.expectEqual(@as(f32, 45), font.ascent(50));
    try std.testing.expectEqual(@as(f32, 57.5), font.lineHeight(50));
    try std.testing.expectError(error.UnsupportedFontFormat, BitmapFont.load(std.testing.io, std.testing.allocator, path, .all));

    try std.testing.expectEqual(@as(f32, 16), font.defaultSize());
    const bitmap: Font = .{ .bitmap = font8x8.basic };
    try std.testing.expectEqual(@as(f32, 8), bitmap.defaultSize());
    try std.testing.expectEqual(@as(f32, 24), font8x8.basic.getTextBounds("abc", 1).r);
    try std.testing.expectEqual(@as(f32, 48), bitmap.getTextBounds("abc", 16).r);
    try std.testing.expectEqual(@as(f32, 16), bitmap.lineHeight(16));
    try std.testing.expect(bitmap.hasGlyph('a'));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "synth.otf", .data = synthetic.build(&buf, .{ .cff = true }) });
    const otf_path = try tmp.dir.realPathFileAlloc(std.testing.io, "synth.otf", std.testing.allocator);
    defer std.testing.allocator.free(otf_path);
    var otf: Font = try .load(std.testing.io, std.testing.allocator, otf_path);
    defer otf.deinit(std.testing.allocator);
    try std.testing.expect(otf == .vector and otf.vector.tables.outlines == .cff);
    try std.testing.expect(otf.hasGlyph('C'));
    try std.testing.expectError(error.UnsupportedFontFormat, BitmapFont.load(std.testing.io, std.testing.allocator, otf_path, .all));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "synth.ttc", .data = synthetic.build(&buf, .{ .collection = true }) });
    const ttc_path = try tmp.dir.realPathFileAlloc(std.testing.io, "synth.ttc", std.testing.allocator);
    defer std.testing.allocator.free(ttc_path);
    var face: Font = try .loadFace(std.testing.io, std.testing.allocator, ttc_path, 1);
    defer face.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, face.vector.num_faces);
    try std.testing.expectError(error.InvalidFormat, Font.loadFace(std.testing.io, std.testing.allocator, ttc_path, 2));
    try std.testing.expectError(error.InvalidFormat, Font.loadFace(std.testing.io, std.testing.allocator, path, 1));
}

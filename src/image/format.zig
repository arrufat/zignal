//! Image format detection and identification.

const std = @import("std");

const codecs = @import("../codecs.zig");
const bmp = codecs.bmp;
const gif = codecs.gif;
const jpeg = codecs.jpeg;
const jxl = codecs.jxl;
const webp = codecs.webp;
const png = codecs.png;

/// Supported image formats for automatic detection and loading. Each tag names its module in
/// `codecs.zig`.
pub const Format = enum {
    png,
    jpeg,
    bmp,
    gif,
    jxl,
    webp,

    /// Bytes `detectFromBytes` needs to tell every format apart (the JPEG XL container and
    /// `RIFF....WEBP` headers are the longest).
    pub const signature_len = 12;

    /// Detects image format from the first few bytes of file data.
    /// The format named by the signature at the start of `reader`, without consuming it.
    pub fn peek(reader: *std.Io.Reader) !Format {
        // Files shorter than a signature can still match a shorter one.
        const head = reader.peekGreedy(signature_len) catch |err| switch (err) {
            error.EndOfStream => reader.buffered(),
            else => |e| return e,
        };
        return detectFromBytes(head) orelse error.UnsupportedImageFormat;
    }

    pub fn detectFromBytes(data: []const u8) ?Format {
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

        if (jxl.hasSignature(data)) return .jxl;
        if (webp.hasSignature(data)) return .webp;

        return null;
    }

    /// Map a file path's extension to a format. Used by `save`, where the file
    /// doesn't yet exist so signature sniffing isn't an option. Comparison is
    /// case-insensitive.
    pub fn fromExtension(file_path: []const u8) ?Format {
        const matches = std.ascii.endsWithIgnoreCase;
        if (matches(file_path, ".png")) return .png;
        if (matches(file_path, ".jpg") or matches(file_path, ".jpeg")) return .jpeg;
        if (matches(file_path, ".bmp")) return .bmp;
        if (matches(file_path, ".gif")) return .gif;
        if (matches(file_path, ".jxl")) return .jxl;
        if (matches(file_path, ".webp")) return .webp;
        return null;
    }

    /// The system library a runtime-loaded codec needs (see `dynlib.zig`), or null
    /// for the native codecs.
    pub fn runtimeLibrary(self: Format) ?[]const u8 {
        return switch (self) {
            .png, .jpeg, .bmp, .gif => null,
            .jxl => "libjxl",
            .webp => "libwebp",
        };
    }
};

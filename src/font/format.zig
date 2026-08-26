//! Font format detection and identification

const std = @import("std");
const Io = std.Io;

const isGzipPath = @import("../font.zig").isGzipPath;

/// Supported font formats for automatic detection and loading
pub const FontFormat = enum {
    bdf, // Bitmap Distribution Format
    pcf, // Portable Compiled Format (X11)
    ttf, // TrueType (sfnt with glyf outlines)
    otf, // OpenType (sfnt with CFF outlines)
    ttc, // TrueType/OpenType collection (`ttcf`)

    /// BDF format signature
    const bdf_signature = "STARTFONT";

    /// PCF format signature
    const pcf_signature = "\x01fcp";

    /// sfnt version tags
    const ttf_signature = "\x00\x01\x00\x00";
    const ttf_apple_signature = "true";
    const otf_signature = "OTTO";
    const ttc_signature = "ttcf";

    /// Detect font format from the first few bytes of data
    pub fn detectFromBytes(data: []const u8) ?FontFormat {
        if (std.mem.startsWith(u8, data, bdf_signature)) return .bdf;
        if (std.mem.startsWith(u8, data, pcf_signature)) return .pcf;
        if (std.mem.startsWith(u8, data, ttf_signature)) return .ttf;
        if (std.mem.startsWith(u8, data, ttf_apple_signature)) return .ttf;
        if (std.mem.startsWith(u8, data, otf_signature)) return .otf;
        if (std.mem.startsWith(u8, data, ttc_signature)) return .ttc;
        return null;
    }

    /// Detect font format from the file extension, ignoring a trailing `.gz`
    pub fn detectFromExtension(path: []const u8) ?FontFormat {
        const stem = if (isGzipPath(path)) path[0 .. path.len - 3] else path;
        if (std.ascii.endsWithIgnoreCase(stem, ".bdf")) return .bdf;
        if (std.ascii.endsWithIgnoreCase(stem, ".pcf")) return .pcf;
        if (std.ascii.endsWithIgnoreCase(stem, ".ttf")) return .ttf;
        if (std.ascii.endsWithIgnoreCase(stem, ".otf")) return .otf;
        if (std.ascii.endsWithIgnoreCase(stem, ".ttc") or std.ascii.endsWithIgnoreCase(stem, ".otc")) return .ttc;
        return null;
    }

    /// Detect font format from file path by reading the first few bytes
    pub fn detectFromPath(io: Io, file_path: []const u8) !?FontFormat {
        // Compressed files can't be sniffed, so trust the extension
        if (isGzipPath(file_path)) return detectFromExtension(file_path);

        const file = try Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        var header: [16]u8 = undefined;
        var iov = [_][]u8{header[0..]};
        const bytes_read = try file.readStreaming(io, &iov);

        return detectFromBytes(header[0..bytes_read]);
    }
};

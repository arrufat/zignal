//! Font format detection and identification

const std = @import("std");
const Io = std.Io;

/// Supported font formats for automatic detection and loading
pub const FontFormat = enum {
    bdf, // Bitmap Distribution Format
    pcf, // Portable Compiled Format (X11)

    /// BDF format signature
    const bdf_signature = "STARTFONT";

    /// PCF format signature
    const pcf_signature = "\x01fcp";

    /// Detect font format from the first few bytes of data
    pub fn detectFromBytes(data: []const u8) ?FontFormat {
        if (std.mem.startsWith(u8, data, bdf_signature)) return .bdf;
        if (std.mem.startsWith(u8, data, pcf_signature)) return .pcf;
        return null;
    }

    /// Detect font format from the file extension, ignoring a trailing `.gz`
    pub fn detectFromExtension(path: []const u8) ?FontFormat {
        const stem = if (std.ascii.endsWithIgnoreCase(path, ".gz")) path[0 .. path.len - 3] else path;
        if (std.ascii.endsWithIgnoreCase(stem, ".bdf")) return .bdf;
        if (std.ascii.endsWithIgnoreCase(stem, ".pcf")) return .pcf;
        return null;
    }

    /// Detect font format from file path by reading the first few bytes
    pub fn detectFromPath(io: Io, file_path: []const u8) !?FontFormat {
        // Compressed files can't be sniffed, so trust the extension
        if (std.ascii.endsWithIgnoreCase(file_path, ".gz")) {
            return detectFromExtension(file_path);
        }

        const file = try Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        var header: [16]u8 = undefined;
        var iov = [_][]u8{header[0..]};
        const bytes_read = try file.readStreaming(io, &iov);

        return detectFromBytes(header[0..bytes_read]);
    }
};

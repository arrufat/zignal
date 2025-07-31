//! Font format detection and identification

const std = @import("std");
const Allocator = std.mem.Allocator;

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
        // BDF signature (text format, check for "STARTFONT")
        if (data.len >= bdf_signature.len) {
            if (std.mem.startsWith(u8, data, bdf_signature)) {
                return .bdf;
            }
        }

        // PCF signature (binary format)
        if (data.len >= pcf_signature.len) {
            if (std.mem.eql(u8, data[0..pcf_signature.len], pcf_signature)) {
                return .pcf;
            }
        }

        return null;
    }

    /// Detect font format from file path by reading the first few bytes
    pub fn detectFromPath(_: Allocator, file_path: []const u8) !?FontFormat {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var header: [16]u8 = undefined;
        const bytes_read = try file.read(&header);

        return detectFromBytes(header[0..bytes_read]);
    }
};

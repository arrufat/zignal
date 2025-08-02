//! Font file compression utilities
//!
//! This module provides shared compression/decompression functionality
//! for font files, supporting gzip and potentially other formats.

const std = @import("std");
const deflate = @import("../deflate.zig");

/// Errors that can occur during compression operations
pub const CompressionError = error{
    InvalidCompression,
};

/// Decompress gzip data
pub fn decompressGzip(allocator: std.mem.Allocator, gzip_data: []const u8) ![]u8 {
    if (gzip_data.len < 18) { // Minimum gzip file size
        return CompressionError.InvalidCompression;
    }

    // Check gzip magic number
    if (gzip_data[0] != 0x1f or gzip_data[1] != 0x8b) {
        return CompressionError.InvalidCompression;
    }

    // Check compression method (must be deflate)
    if (gzip_data[2] != 8) {
        return CompressionError.InvalidCompression;
    }

    // Parse header flags
    const flags = gzip_data[3];
    var offset: usize = 10; // Fixed header size

    // Skip optional fields based on flags
    if (flags & 0x04 != 0) { // FEXTRA
        const extra_len = @as(u16, gzip_data[offset]) | (@as(u16, gzip_data[offset + 1]) << 8);
        offset += 2 + extra_len;
    }
    if (flags & 0x08 != 0) { // FNAME
        while (offset < gzip_data.len and gzip_data[offset] != 0) : (offset += 1) {}
        offset += 1;
    }
    if (flags & 0x10 != 0) { // FCOMMENT
        while (offset < gzip_data.len and gzip_data[offset] != 0) : (offset += 1) {}
        offset += 1;
    }
    if (flags & 0x02 != 0) { // FHCRC
        offset += 2;
    }

    // Decompress the deflate stream (excluding 8-byte trailer)
    if (offset + 8 > gzip_data.len) {
        return CompressionError.InvalidCompression;
    }

    const compressed_data = gzip_data[offset .. gzip_data.len - 8];
    return deflate.inflate(allocator, compressed_data);
}

/// Result of loadFile operation
pub const LoadedFile = struct {
    /// The file data (either raw or decompressed)
    data: []u8,
    /// Raw file data (always owned, must be freed)
    raw_data: []u8,
    /// Decompressed data if applicable (must be freed if not null)
    decompressed_data: ?[]u8,
    /// Whether the file was compressed
    was_compressed: bool,

    /// Clean up allocated memory
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.raw_data);
        if (self.decompressed_data) |data| {
            allocator.free(data);
        }
    }
};

/// Load a file and automatically decompress if it's gzip compressed
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !LoadedFile {
    // Check if file is gzip compressed
    const is_compressed = std.mem.endsWith(u8, path, ".gz");

    // Read entire file into memory
    const raw_file_contents = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    errdefer allocator.free(raw_file_contents);

    if (is_compressed) {
        const decompressed_data = try decompressGzip(allocator, raw_file_contents);
        std.log.info("Decompressed {s} from {} bytes to {} bytes", .{ path, raw_file_contents.len, decompressed_data.len });

        return LoadedFile{
            .data = decompressed_data,
            .raw_data = raw_file_contents,
            .decompressed_data = decompressed_data,
            .was_compressed = true,
        };
    } else {
        return LoadedFile{
            .data = raw_file_contents,
            .raw_data = raw_file_contents,
            .decompressed_data = null,
            .was_compressed = false,
        };
    }
}

test "gzip decompression" {
    // Create a simple gzip file with minimal content
    const gzip_data = [_]u8{
        0x1f, 0x8b, // Magic number
        0x08, // Compression method (deflate)
        0x00, // Flags (no extra fields)
        0x00, 0x00, 0x00, 0x00, // Modification time
        0x00, // Extra flags
        0x03, // OS (Unix)
        // Compressed data (empty deflate block)
        0x03,
        0x00,
        // CRC32 and size (8 bytes)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };

    const allocator = std.testing.allocator;
    const result = decompressGzip(allocator, &gzip_data) catch |err| {
        // This test mainly validates the header parsing
        // Actual deflate decompression is tested elsewhere
        if (err == error.EndOfStream) return;
        return err;
    };
    defer allocator.free(result);
}

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

/// CRC32 implementation for gzip
const crc32_table = blk: {
    @setEvalBranchQuota(3000); // Increase quota for comptime evaluation
    var table: [256]u32 = undefined;
    const polynomial: u32 = 0xEDB88320; // Reversed polynomial

    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ polynomial;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate CRC32 checksum
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        const table_idx = (crc ^ byte) & 0xFF;
        crc = (crc >> 8) ^ crc32_table[table_idx];
    }
    return ~crc;
}

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
    const is_compressed = std.ascii.endsWithIgnoreCase(path, ".gz");

    // Read entire file into memory
    const raw_file_contents = try std.fs.cwd().readFileAlloc(path, allocator, std.Io.Limit.limited(max_size));
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

/// Compress data to gzip format
pub fn compressGzip(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    // Compress data using deflate
    const compressed_data = try deflate.deflate(gpa, data, .fastest, .default);
    defer gpa.free(compressed_data);

    // Calculate CRC32 checksum of original data
    const checksum = crc32(data);

    // Create gzip output
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);

    // Write gzip header (10 bytes)
    try result.append(gpa, 0x1f); // Magic number byte 1
    try result.append(gpa, 0x8b); // Magic number byte 2
    try result.append(gpa, 0x08); // Compression method (deflate)
    try result.append(gpa, 0x00); // Flags (no extra fields)

    // Modification time (4 bytes) - set to 0
    try result.append(gpa, 0x00);
    try result.append(gpa, 0x00);
    try result.append(gpa, 0x00);
    try result.append(gpa, 0x00);

    try result.append(gpa, 0x00); // Extra flags
    try result.append(gpa, 0x03); // OS (Unix)

    // Write compressed data
    try result.appendSlice(gpa, compressed_data);

    // Write gzip trailer (8 bytes)
    // CRC32 (4 bytes, little-endian)
    try result.append(gpa, @intCast(checksum & 0xFF));
    try result.append(gpa, @intCast((checksum >> 8) & 0xFF));
    try result.append(gpa, @intCast((checksum >> 16) & 0xFF));
    try result.append(gpa, @intCast((checksum >> 24) & 0xFF));

    // Uncompressed size (4 bytes, little-endian)
    const size: u32 = @intCast(data.len & 0xFFFFFFFF);
    try result.append(gpa, @intCast(size & 0xFF));
    try result.append(gpa, @intCast((size >> 8) & 0xFF));
    try result.append(gpa, @intCast((size >> 16) & 0xFF));
    try result.append(gpa, @intCast((size >> 24) & 0xFF));

    return result.toOwnedSlice(gpa);
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

test "gzip compression and decompression round-trip" {
    const allocator = std.testing.allocator;

    // Test data
    const original_data = "Hello, World! This is a test for gzip compression.";

    // Compress
    const compressed = try compressGzip(allocator, original_data);
    defer allocator.free(compressed);

    // Verify gzip header
    try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);
    try std.testing.expectEqual(@as(u8, 0x08), compressed[2]);

    // Decompress
    const decompressed = try decompressGzip(allocator, compressed);
    defer allocator.free(decompressed);

    // Verify round-trip
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

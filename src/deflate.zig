//! DEFLATE compression algorithm (RFC 1951) and zlib wrapper (RFC 1950).
//!
//! This module provides compression and decompression using the DEFLATE algorithm,
//! which combines LZ77 compression with Huffman coding. It supports multiple
//! compression levels and strategies for different data types.
//!
//! ## Basic Usage
//!
//! ```zig
//! const allocator = std.heap.page_allocator;
//!
//! // Compress data
//! const compressed = try deflate(allocator, "Hello, World!", .default, .default);
//! defer allocator.free(compressed);
//!
//! // Decompress data
//! const decompressed = try inflate(allocator, compressed);
//! defer allocator.free(decompressed);
//! ```
//!
//! ## Compression Levels
//!
//! - `.none` - Store only, no compression
//! - `.fastest` - Minimal compression, maximum speed
//! - `.fast` - Fast compression
//! - `.default` - Balanced compression/speed (recommended)
//! - `.best` - Maximum compression, slower
//!
//! ## Compression Strategies
//!
//! - `.default` - Standard compression for general data
//! - `.filtered` - For filtered data (e.g., small values with limited range)
//! - `.huffman_only` - Huffman coding only, no LZ77 matching
//! - `.rle` - Run-length encoding, good for data with many runs
//!
//! Public façade for DEFLATE and zlib

const std = @import("std");
const def_impl = @import("deflate/deflate_impl.zig");
const z = @import("zlib.zig");

pub const CompressionLevel = def_impl.CompressionLevel;
pub const CompressionStrategy = def_impl.CompressionStrategy;

pub const DeflateEncoder = def_impl.DeflateEncoder;
pub const DeflateDecoder = def_impl.DeflateDecoder;

pub const inflate = def_impl.inflate;
pub const deflate = def_impl.deflate;

pub const zlibCompress = z.zlibCompress;
pub const zlibDecompress = z.zlibDecompress;

test "deflate decompression empty" {
    const allocator = std.testing.allocator;
    const empty_data = [_]u8{};
    const result = inflate(allocator, &empty_data);
    try std.testing.expectError(error.UnexpectedEndOfData, result);
}

test "deflate round-trip uncompressed" {
    const allocator = std.testing.allocator;
    const original_data = "Hello, World! This is a test string for deflate compression.";
    const compressed = try deflate(allocator, original_data, .none, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

test "deflate uncompressed header endianness" {
    const allocator = std.testing.allocator;
    const test_data = "Test";
    const compressed = try deflate(allocator, test_data, .none, .default);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= 5);
    try std.testing.expectEqual(@as(u8, 0x01), compressed[0]);
    const len = compressed[1] | (@as(u16, compressed[2]) << 8);
    const nlen = compressed[3] | (@as(u16, compressed[4]) << 8);
    try std.testing.expectEqual(@as(u16, 4), len);
    try std.testing.expectEqual(@as(u16, 0xFFFB), nlen);
}

test "methods comparison static vs none" {
    const allocator = std.testing.allocator;
    const test_data = "Hello World! Hello World! Hello World! This is a test string for compression.";
    const uncompressed = try deflate(allocator, test_data, .none, .default);
    defer allocator.free(uncompressed);
    const static_huffman = try deflate(allocator, test_data, .fastest, .default);
    defer allocator.free(static_huffman);
    const d1 = try inflate(allocator, uncompressed);
    defer allocator.free(d1);
    try std.testing.expectEqualSlices(u8, test_data, d1);
    const d2 = try inflate(allocator, static_huffman);
    defer allocator.free(d2);
    try std.testing.expectEqualSlices(u8, test_data, d2);
}

test "zlib static huffman round trip" {
    const allocator = std.testing.allocator;
    const test_data = "Test data for static Huffman compression";
    const compressed = try zlibCompress(allocator, test_data, .fastest, .default);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, test_data, decompressed);
}

test "zlib pattern data" {
    const allocator = std.testing.allocator;
    var test_data: [256]u8 = undefined;
    for (0..256) |i| test_data[i] = @intCast(i % 256);
    const compressed = try zlibCompress(allocator, &test_data, .fastest, .default);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "static huffman end-of-stream edge" {
    const allocator = std.testing.allocator;
    const test_data = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    const compressed = try deflate(allocator, &test_data, .fastest, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "high byte values" {
    const allocator = std.testing.allocator;
    const test_data = [_]u8{ 250, 251, 252, 253, 254, 255, 255, 254, 253, 252, 251, 250 };
    const compressed = try deflate(allocator, &test_data, .fastest, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "debug grayscale-like pattern" {
    const allocator = std.testing.allocator;
    var test_data: [64]u8 = undefined;
    for (0..8) |y| {
        test_data[y * 8] = 0;
        for (1..8) |x| {
            if ((x / 4 + y / 4) % 2 == 0) test_data[y * 8 + x] = @intCast((x * y * 255) / 49) else test_data[y * 8 + x] = @intCast(255 - (x * y * 255) / 49);
        }
    }
    const compressed = try deflate(allocator, &test_data, .fastest, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &test_data, decompressed);
}

test "zlib round trip" {
    const allocator = std.testing.allocator;
    const original_data = "Hello, zlib compression test for PNG!";
    const compressed = try zlibCompress(allocator, original_data, .none, .default);
    defer allocator.free(compressed);
    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

test "zlib header validation" {
    const allocator = std.testing.allocator;
    const test_data = "Test";
    const compressed = try zlibCompress(allocator, test_data, .none, .default);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= 6);
    const cmf = compressed[0];
    try std.testing.expectEqual(@as(u8, 8), cmf & 0x0F);
    const header_check = (@as(u16, compressed[0]) << 8) | compressed[1];
    try std.testing.expectEqual(@as(u16, 0), header_check % 31);
}

test "compression levels progression" {
    const allocator = std.testing.allocator;
    const test_data = "The quick brown fox jumps over the lazy dog. " ** 10;
    const levels = [_]CompressionLevel{ .none, .fastest, .fast, .default, .best };
    var sizes: [levels.len]usize = undefined;
    for (levels, 0..) |level, i| {
        const compressed = try zlibCompress(allocator, test_data, level, .default);
        defer allocator.free(compressed);
        sizes[i] = compressed.len;
        const decomp = try zlibDecompress(allocator, compressed);
        defer allocator.free(decomp);
        try std.testing.expectEqualSlices(u8, test_data, decomp);
    }
    try std.testing.expect(sizes[0] > sizes[1]);
    try std.testing.expect(sizes[1] >= sizes[2]);
    try std.testing.expect(sizes[2] >= sizes[3]);
}

test "compression strategies round-trip" {
    const allocator = std.testing.allocator;
    const strategies = [_]CompressionStrategy{ .default, .filtered, .huffman_only, .rle };
    const test_data = "AAAAAABBBBBBCCCCCCDDDDDD" ** 5;
    for (strategies) |strategy| {
        const compressed = try zlibCompress(allocator, test_data, .default, strategy);
        defer allocator.free(compressed);
        const decomp = try zlibDecompress(allocator, compressed);
        defer allocator.free(decomp);
        try std.testing.expectEqualSlices(u8, test_data, decomp);
    }
}

test "hash table improves compression" {
    const allocator = std.testing.allocator;
    const repetitive_data = "AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDD" ** 50;
    const fast = try zlibCompress(allocator, repetitive_data, .fastest, .default);
    defer allocator.free(fast);
    const best = try zlibCompress(allocator, repetitive_data, .best, .default);
    defer allocator.free(best);
    try std.testing.expect(best.len <= fast.len);
    const d1 = try zlibDecompress(allocator, fast);
    defer allocator.free(d1);
    const d2 = try zlibDecompress(allocator, best);
    defer allocator.free(d2);
    try std.testing.expectEqualSlices(u8, repetitive_data, d1);
    try std.testing.expectEqualSlices(u8, repetitive_data, d2);
}

test "dynamic huffman zlib round-trip with png-like scanlines" {
    const allocator = std.testing.allocator;

    // Construct PNG-like filtered scanlines: each row starts with a filter byte
    const width: usize = 512;
    const height: usize = 96;
    const scanline_bytes: usize = width; // pretend 1 byte/pixel for stress
    const total: usize = height * (scanline_bytes + 1);

    var data = try allocator.alloc(u8, total);
    defer allocator.free(data);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_start = y * (scanline_bytes + 1);
        data[row_start] = 0; // filter type: none

        const row = data[row_start + 1 .. row_start + 1 + scanline_bytes];
        var x: usize = 0;
        while (x < scanline_bytes) : (x += 1) {
            // Alternating pattern with some repetition to exercise LZ and Huffman
            const v: u8 = if ((y & 1) == 0)
                @intCast((x * 3 + y) % 256)
            else blk: {
                // Compute (255 - x + y*7) mod 256 without overflow
                const xv: u32 = @intCast(x % 256);
                const yv: u32 = @intCast((y * 7) % 256);
                break :blk @intCast(((255 + yv + 256 - xv) & 0xFF));
            };
            row[x] = v;
            if ((x % 32) == 0) {
                // Sprinkle small runs
                const end = @min(scanline_bytes, x + 8);
                for (x..end) |i| row[i] = v;
                x = end;
            }
        }
    }

    // Compress with zlib using default (dynamic) settings
    const compressed = try zlibCompress(allocator, data, .default, .filtered);
    defer allocator.free(compressed);

    // Verify first block is dynamic Huffman (BTYPE=10), LSB-first => first 3 bits are 101
    try std.testing.expect(compressed.len >= 3);
    const first_deflate_byte = compressed[2]; // after zlib header (2 bytes)
    const bfinal: u1 = @intCast(first_deflate_byte & 0x01);
    const btype: u2 = @intCast((first_deflate_byte >> 1) & 0x03);
    try std.testing.expectEqual(@as(u1, 1), bfinal); // final block
    try std.testing.expectEqual(@as(u2, 2), btype); // dynamic Huffman

    // Decompress and verify round-trip
    const decompressed = try zlibDecompress(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, data, decompressed);
}

test "deflate handles corrupted compressed data" {
    const allocator = std.testing.allocator;
    const original = "Hello, this is test data for corruption testing!";
    const compressed = try deflate(allocator, original, .default, .default);
    defer allocator.free(compressed);

    // Create corrupted version
    var corrupted = try allocator.dupe(u8, compressed);
    defer allocator.free(corrupted);

    // Corrupt multiple bytes to ensure we break the stream
    // Corrupting just one byte might not always cause an error
    if (corrupted.len > 20) {
        corrupted[10] ^= 0xFF;
        corrupted[11] ^= 0xFF;
        corrupted[12] ^= 0xFF;
    }

    // Attempt to decompress corrupted data
    if (inflate(allocator, corrupted)) |decompressed| {
        // If it somehow succeeds, it shouldn't match the original
        defer allocator.free(decompressed);
        try std.testing.expect(!std.mem.eql(u8, original, decompressed));
    } else |_| {
        // Any error is acceptable for corrupted data
    }
}

test "deflate handles truncated compressed data" {
    const allocator = std.testing.allocator;
    const original = "This is a longer test string that will be compressed and then truncated";
    const compressed = try deflate(allocator, original, .default, .default);
    defer allocator.free(compressed);

    // Truncate the compressed data
    const truncated = compressed[0 .. compressed.len / 2];

    // Attempt to decompress truncated data
    if (inflate(allocator, truncated)) |decompressed| {
        // If it somehow succeeds (unlikely), clean up
        defer allocator.free(decompressed);
        try std.testing.expect(false); // Should not succeed
    } else |err| {
        // Any of these errors are acceptable for truncated data
        try std.testing.expect(err == error.UnexpectedEndOfData or
            err == error.InvalidDeflateHuffmanCode or
            err == error.InvalidDeflateSymbol);
    }
}

test "deflate handles files larger than 64KB" {
    const allocator = std.testing.allocator;

    // Create data larger than max uncompressed block size (65535 bytes)
    const large_size = 100_000;
    const large_data = try allocator.alloc(u8, large_size);
    defer allocator.free(large_data);

    // Fill with a pattern
    for (large_data, 0..) |*byte, i| {
        byte.* = @truncate(i % 256);
    }

    // Compress and decompress
    const compressed = try deflate(allocator, large_data, .default, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, large_data, decompressed);
}

test "deflate handles maximum distance references" {
    const allocator = std.testing.allocator;

    // Create data with pattern at beginning and at maximum distance
    const window_size = 32768;
    var data: [window_size + 100]u8 = undefined;

    // Place pattern at start
    const pattern = "UNIQUE_PATTERN_123";
    @memcpy(data[0..pattern.len], pattern);

    // Fill middle with different data
    for (data[pattern.len..window_size]) |*byte| {
        byte.* = 0xAA;
    }

    // Place same pattern at maximum distance
    @memcpy(data[window_size .. window_size + pattern.len], pattern);

    // Compress with best level to ensure LZ77 matching
    const compressed = try deflate(allocator, &data, .best, .default);
    defer allocator.free(compressed);
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &data, decompressed);
}

test "deflate explicit dynamic Huffman usage" {
    const allocator = std.testing.allocator;

    // Create data that should trigger dynamic Huffman:
    // - Size >= 512 bytes
    // - Limited unique symbols (between 20-200)
    // - High frequency variance
    var data: [1024]u8 = undefined;

    // Use only 30 unique symbols with varying frequencies
    const symbols = "abcdefghijklmnopqrstuvwxyz0123";
    for (&data, 0..) |*byte, i| {
        // Create frequency distribution that favors dynamic Huffman
        const symbol_index = if (i % 100 < 50)
            0 // 'a' appears 50% of the time
        else if (i % 100 < 70)
            1 // 'b' appears 20% of the time
        else
            2 + (i % 28); // Other symbols share remaining 30%
        byte.* = symbols[symbol_index];
    }

    // Compress with .best to trigger dynamic Huffman
    const compressed = try deflate(allocator, &data, .best, .default);
    defer allocator.free(compressed);

    // Verify it compresses and decompresses correctly
    const decompressed = try inflate(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &data, decompressed);

    // Dynamic Huffman should compress better than static for this data
    const static_compressed = try deflate(allocator, &data, .fastest, .default);
    defer allocator.free(static_compressed);
    try std.testing.expect(compressed.len < static_compressed.len);
}

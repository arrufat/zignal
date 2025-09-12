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

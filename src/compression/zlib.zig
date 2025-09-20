//! zlib (RFC 1950) wrapper around DEFLATE

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const def = @import("deflate.zig");

fn adler32(data: []const u8) u32 {
    const MOD_ADLER: u32 = 65521;
    const NMAX = 5552; // Largest n such that 255n(n+1)/2 + (n+1)(MOD_ADLER-1) <= 2^32-1

    var a: u32 = 1;
    var b: u32 = 0;
    var i: usize = 0;

    // Process blocks to avoid overflow
    while (i < data.len) {
        const block_len = @min(NMAX, data.len - i);
        const end = i + block_len;

        // Use @Vector for SIMD optimization when block is large enough
        if (block_len >= 16) {
            // Process 16 bytes at a time using SIMD
            const vec_end = i + (block_len & ~@as(usize, 15));
            while (i < vec_end) : (i += 16) {
                // Load 16 bytes
                const vec: @Vector(16, u8) = data[i..][0..16].*;

                // Sum all bytes for 'a' calculation
                inline for (0..16) |j| {
                    a += vec[j];
                    b += a;
                }
            }
        }

        // Process remaining bytes
        while (i < end) : (i += 1) {
            a += data[i];
            b += a;
        }

        // Apply modulo to prevent overflow
        a %= MOD_ADLER;
        b %= MOD_ADLER;
    }

    return (b << 16) | a;
}

pub fn compress(gpa: Allocator, data: []const u8, level: def.CompressionLevel, strategy: def.CompressionStrategy) ![]u8 {
    const deflate_data = try def.deflate(gpa, data, level, strategy);
    defer gpa.free(deflate_data);
    const checksum = adler32(data);
    var result: ArrayList(u8) = .empty;
    defer result.deinit(gpa);
    const cmf: u8 = 0x78; // 32K window, deflate
    const flevel: u2 = switch (level) {
        .level_0, .level_1 => 0,
        .level_2, .level_3 => 1,
        .level_4, .level_5, .level_6 => 2,
        .level_7, .level_8, .level_9 => 3,
    };
    var flg: u8 = @as(u8, flevel) << 6;
    const header_base = (@as(u16, cmf) << 8) | flg;
    const fcheck = 31 - (header_base % 31);
    if (fcheck < 31) flg |= @intCast(fcheck);
    try result.append(gpa, cmf);
    try result.append(gpa, flg);
    try result.appendSlice(gpa, deflate_data);
    try result.append(gpa, @intCast((checksum >> 24) & 0xFF));
    try result.append(gpa, @intCast((checksum >> 16) & 0xFF));
    try result.append(gpa, @intCast((checksum >> 8) & 0xFF));
    try result.append(gpa, @intCast(checksum & 0xFF));
    return result.toOwnedSlice(gpa);
}

pub fn decompress(gpa: Allocator, zlib_data: []const u8) ![]u8 {
    if (zlib_data.len < 6) return error.InvalidZlibData;
    const cmf = zlib_data[0];
    const flg = zlib_data[1];
    const header_check = (@as(u16, cmf) << 8) | flg;
    if ((cmf & 0x0F) != 8) return error.UnsupportedCompressionMethod;
    if ((header_check % 31) != 0) return error.InvalidZlibHeader;
    if ((flg & 0x20) != 0) return error.PresetDictionaryNotSupported;
    const deflate_data = zlib_data[2 .. zlib_data.len - 4];
    const decompressed = try def.inflate(gpa, deflate_data);
    const expected_checksum = std.mem.readInt(u32, zlib_data[zlib_data.len - 4 ..][0..4], .big);
    const actual_checksum = adler32(decompressed);
    if (actual_checksum != expected_checksum) {
        gpa.free(decompressed);
        return error.ChecksumMismatch;
    }
    return decompressed;
}

test "zlib round trip" {
    const allocator = std.testing.allocator;
    const original_data = "Hello, zlib compression test for PNG!";
    const compressed = try compress(allocator, original_data, .level_0, .default);
    defer allocator.free(compressed);
    const decompressed = try decompress(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original_data, decompressed);
}

test "zlib header validation" {
    const allocator = std.testing.allocator;
    const test_data = "Test";
    const compressed = try compress(allocator, test_data, .level_0, .default);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len >= 6);
    const cmf = compressed[0];
    try std.testing.expectEqual(@as(u8, 8), cmf & 0x0F);
    const header_check = (@as(u16, compressed[0]) << 8) | compressed[1];
    try std.testing.expectEqual(@as(u16, 0), header_check % 31);
}

test "zlib compression levels" {
    const allocator = std.testing.allocator;
    const base = "The quick brown fox jumps over the lazy dog. ";
    const test_data = blk: {
        var data: ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        for (0..10) |_| {
            try data.appendSlice(allocator, base);
        }
        break :blk try data.toOwnedSlice(allocator);
    };
    defer allocator.free(test_data);
    const levels = [_]def.CompressionLevel{ .level_0, .level_1, .level_3, .level_6, .level_9 };
    var sizes: [levels.len]usize = undefined;
    for (levels, 0..) |level, i| {
        const compressed = try compress(allocator, test_data, level, .default);
        defer allocator.free(compressed);
        sizes[i] = compressed.len;
        const decomp = try decompress(allocator, compressed);
        defer allocator.free(decomp);
        try std.testing.expectEqualSlices(u8, test_data, decomp);
    }
    // Level 0 (no compression) should be largest
    try std.testing.expect(sizes[0] > sizes[1]);
    // Note: For small inputs, dynamic Huffman header overhead can outweigh gains,
    // so monotonic size ordering across levels is not guaranteed. Round-trip
    // correctness is asserted above; this test intentionally avoids brittle
    // cross-level size comparisons.
}

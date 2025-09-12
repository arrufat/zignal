//! LZ4 compression format
//!
//! LZ4 is a fast compression algorithm focused on speed rather than compression ratio.
//! It uses a simple LZ77-style algorithm with no entropy encoding.
//!
//! Format specification: https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_Format.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// LZ4 block format constants
const MIN_MATCH = 4;
const MAX_DISTANCE = 65535;
const ML_BITS = 4; // Match length bits
const ML_MASK = (1 << ML_BITS) - 1;
const RUN_BITS = 8 - ML_BITS;
const RUN_MASK = (1 << RUN_BITS) - 1;
const LAST_LITERALS = 5;
const MFLIMIT = 12; // Min buffer for optimal compression

/// Hash table for finding matches
const HashTable = struct {
    const HASH_SIZE = 1 << 16;
    table: [HASH_SIZE]u32,

    fn init() HashTable {
        return .{ .table = @splat(0) };
    }

    fn hash(data: []const u8) u32 {
        if (data.len < 4) return 0;
        const v = std.mem.readInt(u32, data[0..4], .little);
        return (v *% 2654435761) >> 16;
    }

    fn get(self: *const HashTable, h: u32) u32 {
        return self.table[h & (HASH_SIZE - 1)];
    }

    fn set(self: *HashTable, h: u32, pos: u32) void {
        self.table[h & (HASH_SIZE - 1)] = pos;
    }
};

/// Compress data using LZ4 block format
pub fn compressBlock(allocator: Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return try allocator.alloc(u8, 0);

    // Worst case: no compression + overhead
    var output: ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.ensureUnusedCapacity(allocator, input.len + input.len / 255 + 16);

    var hash_table = HashTable.init();
    var ip: usize = 0;
    var anchor: usize = 0;

    // Process input
    while (ip < input.len - MFLIMIT) {
        // Find a match
        const h = HashTable.hash(input[ip..]);
        const ref = hash_table.get(h);
        hash_table.set(h, @intCast(ip));

        // Check if we have a valid match
        var match_found = false;
        var match_pos: usize = 0;
        var match_len: usize = 0;

        if (ref > 0 and ref < ip) {
            match_pos = ref;
            const distance = ip - match_pos;
            if (distance < MAX_DISTANCE) {
                // Verify match (at least MIN_MATCH bytes)
                if (ip + MIN_MATCH <= input.len and
                    match_pos + MIN_MATCH <= input.len and
                    std.mem.eql(u8, input[match_pos..][0..MIN_MATCH], input[ip..][0..MIN_MATCH]))
                {
                    match_found = true;
                    match_len = MIN_MATCH;

                    // Extend match
                    while (ip + match_len < input.len and
                        match_pos + match_len < input.len and
                        input[ip + match_len] == input[match_pos + match_len])
                    {
                        match_len += 1;
                    }
                }
            }
        }

        if (!match_found) {
            ip += 1;
            continue;
        }

        // We have a match, emit literals + match
        const literal_len = ip - anchor;
        const offset = ip - match_pos;

        // Token
        var token: u8 = 0;

        // Encode literal length
        if (literal_len < 15) {
            token = @intCast(literal_len << ML_BITS);
        } else {
            token = 0xF0;
        }

        // Encode match length
        const adjusted_match_len = match_len - MIN_MATCH;
        if (adjusted_match_len < 15) {
            token |= @intCast(adjusted_match_len);
        } else {
            token |= 0x0F;
        }

        try output.append(allocator, token);

        // Additional literal length bytes if needed
        if (literal_len >= 15) {
            var len = literal_len - 15;
            while (len >= 255) {
                try output.append(allocator, 255);
                len -= 255;
            }
            try output.append(allocator, @intCast(len));
        }

        // Copy literals
        try output.appendSlice(allocator, input[anchor..ip]);

        // Offset (little-endian)
        try output.append(allocator, @intCast(offset & 0xFF));
        try output.append(allocator, @intCast((offset >> 8) & 0xFF));

        // Additional match length bytes if needed
        if (adjusted_match_len >= 15) {
            var len = adjusted_match_len - 15;
            while (len >= 255) {
                try output.append(allocator, 255);
                len -= 255;
            }
            try output.append(allocator, @intCast(len));
        }

        // Update position
        ip += match_len;
        anchor = ip;

        // Hash the next positions
        if (ip < input.len - MFLIMIT) {
            hash_table.set(HashTable.hash(input[ip - 2 ..]), @intCast(ip - 2));
        }
    }

    // Last literals
    const last_literal_len = input.len - anchor;
    if (last_literal_len > 0) {
        var token: u8 = 0;
        if (last_literal_len < 15) {
            token = @intCast(last_literal_len << ML_BITS);
        } else {
            token = 0xF0;
        }
        try output.append(allocator, token);

        if (last_literal_len >= 15) {
            var len = last_literal_len - 15;
            while (len >= 255) {
                try output.append(allocator, 255);
                len -= 255;
            }
            try output.append(allocator, @intCast(len));
        }

        try output.appendSlice(allocator, input[anchor..]);
    }

    return output.toOwnedSlice(allocator);
}

/// Decompress LZ4 block format data
pub fn decompressBlock(allocator: Allocator, input: []const u8, max_output_size: ?usize) ![]u8 {
    if (input.len == 0) return try allocator.alloc(u8, 0);

    var output: ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var ip: usize = 0;

    while (ip < input.len) {
        // Read token
        const token = input[ip];
        ip += 1;

        // Decode literal length
        var literal_len: usize = token >> ML_BITS;
        if (literal_len == 15) {
            while (ip < input.len) {
                const b = input[ip];
                ip += 1;
                literal_len += b;
                if (b != 255) break;
            }
        }

        // Check bounds and copy literals
        if (ip + literal_len > input.len) return error.CorruptedData;
        try output.appendSlice(allocator, input[ip..][0..literal_len]);
        ip += literal_len;

        // Check if we're done (last literals)
        if (ip >= input.len) break;

        // Read offset
        if (ip + 2 > input.len) return error.CorruptedData;
        const offset = @as(u16, input[ip]) | (@as(u16, input[ip + 1]) << 8);
        ip += 2;
        if (offset == 0) return error.InvalidOffset;

        // Decode match length
        var match_len: usize = (token & ML_MASK) + MIN_MATCH;
        if ((token & ML_MASK) == 15) {
            while (ip < input.len) {
                const b = input[ip];
                ip += 1;
                match_len += b;
                if (b != 255) break;
            }
        }

        // Copy match
        if (output.items.len < offset) return error.InvalidOffset;
        const match_start = output.items.len - offset;

        // Check max output size if specified
        if (max_output_size) |max_size| {
            if (output.items.len + match_len > max_size) return error.OutputTooLarge;
        }

        // Copy match (handle overlapping copies)
        for (0..match_len) |_| {
            try output.append(allocator, output.items[match_start + (output.items.len - match_start - offset)]);
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Frame format magic number
const FRAME_MAGIC = 0x184D2204;

/// Compress data with LZ4 frame format
pub fn compress(allocator: Allocator, input: []const u8) ![]u8 {
    var output: ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Write frame header
    // Magic number
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, FRAME_MAGIC)));

    // Frame descriptor
    const version = 0b01;
    const block_independence = 1;
    const block_checksum = 0;
    const content_size = 0;
    const content_checksum = 1;
    const dict_id = 0;
    const max_block_size = 0b101; // 256KB

    const flg: u8 = (version << 6) | (block_independence << 5) |
        (block_checksum << 4) | (content_size << 3) |
        (content_checksum << 2) | dict_id;
    const bd: u8 = (max_block_size << 4);

    try output.append(allocator, flg);
    try output.append(allocator, bd);

    // Header checksum (XXH32 of frame descriptor, second byte)
    const header_checksum = @as(u8, @truncate((xxhash32(&[_]u8{ flg, bd }) >> 8) & 0xFF));
    try output.append(allocator, header_checksum);

    // Compress blocks
    const compressed_block = try compressBlock(allocator, input);
    defer allocator.free(compressed_block);

    // Write block
    const block_size = compressed_block.len;
    const block_header = std.mem.nativeToLittle(u32, @intCast(block_size & 0x7FFFFFFF));
    try output.appendSlice(allocator, &std.mem.toBytes(block_header));
    try output.appendSlice(allocator, compressed_block);

    // End mark
    try output.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });

    // Content checksum (XXH32)
    const checksum = xxhash32(input);
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, checksum)));

    return output.toOwnedSlice(allocator);
}

/// Decompress LZ4 frame format data
pub fn decompress(allocator: Allocator, input: []const u8) ![]u8 {
    if (input.len < 11) return error.InvalidFrame;

    var ip: usize = 0;

    // Check magic number
    const magic = std.mem.readInt(u32, input[ip..][0..4], .little);
    if (magic != FRAME_MAGIC) return error.InvalidMagic;
    ip += 4;

    // Read frame descriptor
    const flg = input[ip];
    _ = input[ip + 1]; // bd unused for now
    ip += 3; // Skip header checksum

    const has_content_checksum = (flg & 0x04) != 0;
    const has_content_size = (flg & 0x08) != 0;
    const has_dict_id = (flg & 0x01) != 0;

    // Skip optional fields
    if (has_content_size) ip += 8;
    if (has_dict_id) ip += 4;

    var output: ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Read blocks
    while (ip + 4 <= input.len) {
        const block_header = std.mem.readInt(u32, input[ip..][0..4], .little);
        ip += 4;

        if (block_header == 0) break; // End mark

        const block_size = block_header & 0x7FFFFFFF;
        const uncompressed = (block_header & 0x80000000) != 0;

        if (ip + block_size > input.len) return error.InvalidBlock;

        if (uncompressed) {
            try output.appendSlice(allocator, input[ip..][0..block_size]);
        } else {
            const decompressed = try decompressBlock(allocator, input[ip..][0..block_size], null);
            defer allocator.free(decompressed);
            try output.appendSlice(allocator, decompressed);
        }

        ip += block_size;
    }

    // Verify content checksum if present
    if (has_content_checksum) {
        if (ip + 4 > input.len) return error.MissingChecksum;
        const expected = std.mem.readInt(u32, input[ip..][0..4], .little);
        const actual = xxhash32(output.items);
        if (actual != expected) return error.ChecksumMismatch;
    }

    return output.toOwnedSlice(allocator);
}

/// Simple XXH32 implementation for checksums
fn xxhash32(data: []const u8) u32 {
    const PRIME32_1: u32 = 2654435761;
    const PRIME32_2: u32 = 2246822519;
    const PRIME32_3: u32 = 3266489917;
    const PRIME32_4: u32 = 668265263;
    const PRIME32_5: u32 = 374761393;

    var h32: u32 = 0;

    if (data.len >= 16) {
        var v1: u32 = PRIME32_1 +% PRIME32_2;
        var v2: u32 = PRIME32_2;
        var v3: u32 = 0;
        var v4: u32 = 0 -% PRIME32_1;

        var i: usize = 0;
        while (i + 16 <= data.len) : (i += 16) {
            v1 = rotl32(v1 +% std.mem.readInt(u32, data[i..][0..4], .little) *% PRIME32_2, 13) *% PRIME32_1;
            v2 = rotl32(v2 +% std.mem.readInt(u32, data[i + 4 ..][0..4], .little) *% PRIME32_2, 13) *% PRIME32_1;
            v3 = rotl32(v3 +% std.mem.readInt(u32, data[i + 8 ..][0..4], .little) *% PRIME32_2, 13) *% PRIME32_1;
            v4 = rotl32(v4 +% std.mem.readInt(u32, data[i + 12 ..][0..4], .little) *% PRIME32_2, 13) *% PRIME32_1;
        }

        h32 = rotl32(v1, 1) +% rotl32(v2, 7) +% rotl32(v3, 12) +% rotl32(v4, 18);
    } else {
        h32 = PRIME32_5;
    }

    h32 +%= @intCast(data.len);

    // Process remaining bytes
    var i = data.len & ~@as(usize, 15);
    while (i + 4 <= data.len) : (i += 4) {
        h32 +%= std.mem.readInt(u32, data[i..][0..4], .little) *% PRIME32_3;
        h32 = rotl32(h32, 17) *% PRIME32_4;
    }

    while (i < data.len) : (i += 1) {
        h32 +%= data[i] *% PRIME32_5;
        h32 = rotl32(h32, 11) *% PRIME32_1;
    }

    // Final mix
    h32 ^= h32 >> 15;
    h32 *%= PRIME32_2;
    h32 ^= h32 >> 13;
    h32 *%= PRIME32_3;
    h32 ^= h32 >> 16;

    return h32;
}

fn rotl32(x: u32, r: u5) u32 {
    return (x << r) | (x >> @as(u5, @intCast(32 - @as(u32, r))));
}

test "LZ4 block compression and decompression" {
    const allocator = std.testing.allocator;

    const test_cases = [_][]const u8{
        "Hello, World!",
        "The quick brown fox jumps over the lazy dog",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "abcdefghijklmnopqrstuvwxyz0123456789",
    };

    for (test_cases) |input| {
        const compressed = try compressBlock(allocator, input);
        defer allocator.free(compressed);

        const decompressed = try decompressBlock(allocator, compressed, null);
        defer allocator.free(decompressed);

        try std.testing.expectEqualSlices(u8, input, decompressed);
    }
}

test "LZ4 frame format" {
    const allocator = std.testing.allocator;

    const input = blk: {
        var data: ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        const base = "The quick brown fox jumps over the lazy dog. ";
        for (0..10) |_| {
            try data.appendSlice(allocator, base);
        }
        break :blk try data.toOwnedSlice(allocator);
    };
    defer allocator.free(input);

    const compressed = try compress(allocator, input);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "LZ4 compression ratio" {
    const allocator = std.testing.allocator;

    // Highly compressible data
    const repetitive = blk: {
        var data: ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        for (0..1000) |_| {
            try data.append(allocator, 'A');
        }
        break :blk try data.toOwnedSlice(allocator);
    };
    defer allocator.free(repetitive);
    const compressed = try compressBlock(allocator, repetitive);
    defer allocator.free(compressed);

    // Should achieve significant compression
    try std.testing.expect(compressed.len < repetitive.len / 10);
}

test "LZ4 empty input" {
    const allocator = std.testing.allocator;

    const compressed = try compressBlock(allocator, "");
    defer allocator.free(compressed);

    const decompressed = try decompressBlock(allocator, compressed, null);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, "", decompressed);
}

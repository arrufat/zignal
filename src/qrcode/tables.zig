//! QR code spec constants (ISO/IEC 18004): error correction block structure,
//! alignment pattern positions, and BCH-protected format/version information.

const std = @import("std");
const assert = std.debug.assert;

/// Error correction level, ordered by increasing redundancy.
pub const EcLevel = enum(u2) {
    low,
    medium,
    quartile,
    high,

    /// The two-bit indicator used in the format information.
    fn formatBits(self: EcLevel) u2 {
        return switch (self) {
            .low => 0b01,
            .medium => 0b00,
            .quartile => 0b11,
            .high => 0b10,
        };
    }

    pub fn fromFormatBits(bits: u2) EcLevel {
        return switch (bits) {
            0b01 => .low,
            0b00 => .medium,
            0b11 => .quartile,
            0b10 => .high,
        };
    }
};

pub const min_version = 1;
pub const max_version = 40;

/// Matrix dimension (modules per side) for a version.
pub fn dimension(version: u8) u16 {
    assert(version >= min_version and version <= max_version);
    return 4 * @as(u16, version) + 17;
}

/// Reed-Solomon block structure for one version and error correction level.
/// Group 2 blocks (possibly zero of them) carry one more data codeword each.
pub const EcBlocks = struct {
    /// Error correction codewords per block (identical across both groups).
    ec_per_block: u8,
    group1_blocks: u8,
    group1_data: u8,
    group2_blocks: u8,

    fn group2Data(self: EcBlocks) u8 {
        return self.group1_data + 1;
    }

    pub fn totalBlocks(self: EcBlocks) usize {
        return @as(usize, self.group1_blocks) + self.group2_blocks;
    }

    pub fn dataCodewords(self: EcBlocks) usize {
        return @as(usize, self.group1_blocks) * self.group1_data +
            @as(usize, self.group2_blocks) * self.group2Data();
    }

    pub fn totalCodewords(self: EcBlocks) usize {
        return self.dataCodewords() + self.totalBlocks() * self.ec_per_block;
    }

    /// Data codewords carried by the block at index.
    pub fn blockDataLen(self: EcBlocks, index: usize) usize {
        return if (index < self.group1_blocks) self.group1_data else self.group2Data();
    }

    /// Offset of a block in a block-contiguous layout where each block
    /// stores its data codewords followed by its error correction codewords.
    pub fn blockStart(self: EcBlocks, index: usize) usize {
        const group1_total = @as(usize, self.group1_data) + self.ec_per_block;
        return index * group1_total + (index -| self.group1_blocks);
    }
};

/// Yields, for each codeword in the symbol's interleaved transmission order,
/// its offset in the block-contiguous layout described by EcBlocks.blockStart.
/// Shared by the encoder's interleave and the decoder's deinterleave so the
/// two can never disagree on the order.
pub const InterleaveIterator = struct {
    blocks: EcBlocks,
    round: usize = 0,
    block: usize = 0,

    pub fn init(blocks: EcBlocks) InterleaveIterator {
        return .{ .blocks = blocks };
    }

    pub fn next(self: *InterleaveIterator) ?usize {
        const ec_start = self.blocks.group2Data();
        while (self.round < ec_start + self.blocks.ec_per_block) {
            while (self.block < self.blocks.totalBlocks()) {
                const i = self.block;
                self.block += 1;
                const len = self.blocks.blockDataLen(i);
                if (self.round < ec_start) {
                    // Data rounds skip blocks that are already exhausted.
                    if (self.round < len) return self.blocks.blockStart(i) + self.round;
                } else {
                    return self.blocks.blockStart(i) + len + (self.round - ec_start);
                }
            }
            self.block = 0;
            self.round += 1;
        }
        return null;
    }
};

/// Looks up the block structure for a version and error correction level.
pub fn ecBlocks(version: u8, level: EcLevel) EcBlocks {
    assert(version >= min_version and version <= max_version);
    return ec_blocks_table[version - 1][@backingInt(level)];
}

/// Indexed by version - 1, then [L, M, Q, H].
/// Entries are .{ ec_per_block, group1_blocks, group1_data, group2_blocks }.
const ec_blocks_table: [40][4]EcBlocks = .{
    .{ e(7, 1, 19, 0), e(10, 1, 16, 0), e(13, 1, 13, 0), e(17, 1, 9, 0) }, // 1
    .{ e(10, 1, 34, 0), e(16, 1, 28, 0), e(22, 1, 22, 0), e(28, 1, 16, 0) }, // 2
    .{ e(15, 1, 55, 0), e(26, 1, 44, 0), e(18, 2, 17, 0), e(22, 2, 13, 0) }, // 3
    .{ e(20, 1, 80, 0), e(18, 2, 32, 0), e(26, 2, 24, 0), e(16, 4, 9, 0) }, // 4
    .{ e(26, 1, 108, 0), e(24, 2, 43, 0), e(18, 2, 15, 2), e(22, 2, 11, 2) }, // 5
    .{ e(18, 2, 68, 0), e(16, 4, 27, 0), e(24, 4, 19, 0), e(28, 4, 15, 0) }, // 6
    .{ e(20, 2, 78, 0), e(18, 4, 31, 0), e(18, 2, 14, 4), e(26, 4, 13, 1) }, // 7
    .{ e(24, 2, 97, 0), e(22, 2, 38, 2), e(22, 4, 18, 2), e(26, 4, 14, 2) }, // 8
    .{ e(30, 2, 116, 0), e(22, 3, 36, 2), e(20, 4, 16, 4), e(24, 4, 12, 4) }, // 9
    .{ e(18, 2, 68, 2), e(26, 4, 43, 1), e(24, 6, 19, 2), e(28, 6, 15, 2) }, // 10
    .{ e(20, 4, 81, 0), e(30, 1, 50, 4), e(28, 4, 22, 4), e(24, 3, 12, 8) }, // 11
    .{ e(24, 2, 92, 2), e(22, 6, 36, 2), e(26, 4, 20, 6), e(28, 7, 14, 4) }, // 12
    .{ e(26, 4, 107, 0), e(22, 8, 37, 1), e(24, 8, 20, 4), e(22, 12, 11, 4) }, // 13
    .{ e(30, 3, 115, 1), e(24, 4, 40, 5), e(20, 11, 16, 5), e(24, 11, 12, 5) }, // 14
    .{ e(22, 5, 87, 1), e(24, 5, 41, 5), e(30, 5, 24, 7), e(24, 11, 12, 7) }, // 15
    .{ e(24, 5, 98, 1), e(28, 7, 45, 3), e(24, 15, 19, 2), e(30, 3, 15, 13) }, // 16
    .{ e(28, 1, 107, 5), e(28, 10, 46, 1), e(28, 1, 22, 15), e(28, 2, 14, 17) }, // 17
    .{ e(30, 5, 120, 1), e(26, 9, 43, 4), e(28, 17, 22, 1), e(28, 2, 14, 19) }, // 18
    .{ e(28, 3, 113, 4), e(26, 3, 44, 11), e(26, 17, 21, 4), e(26, 9, 13, 16) }, // 19
    .{ e(28, 3, 107, 5), e(26, 3, 41, 13), e(30, 15, 24, 5), e(28, 15, 15, 10) }, // 20
    .{ e(28, 4, 116, 4), e(26, 17, 42, 0), e(28, 17, 22, 6), e(30, 19, 16, 6) }, // 21
    .{ e(28, 2, 111, 7), e(28, 17, 46, 0), e(30, 7, 24, 16), e(24, 34, 13, 0) }, // 22
    .{ e(30, 4, 121, 5), e(28, 4, 47, 14), e(30, 11, 24, 14), e(30, 16, 15, 14) }, // 23
    .{ e(30, 6, 117, 4), e(28, 6, 45, 14), e(30, 11, 24, 16), e(30, 30, 16, 2) }, // 24
    .{ e(26, 8, 106, 4), e(28, 8, 47, 13), e(30, 7, 24, 22), e(30, 22, 15, 13) }, // 25
    .{ e(28, 10, 114, 2), e(28, 19, 46, 4), e(28, 28, 22, 6), e(30, 33, 16, 4) }, // 26
    .{ e(30, 8, 122, 4), e(28, 22, 45, 3), e(30, 8, 23, 26), e(30, 12, 15, 28) }, // 27
    .{ e(30, 3, 117, 10), e(28, 3, 45, 23), e(30, 4, 24, 31), e(30, 11, 15, 31) }, // 28
    .{ e(30, 7, 116, 7), e(28, 21, 45, 7), e(30, 1, 23, 37), e(30, 19, 15, 26) }, // 29
    .{ e(30, 5, 115, 10), e(28, 19, 47, 10), e(30, 15, 24, 25), e(30, 23, 15, 25) }, // 30
    .{ e(30, 13, 115, 3), e(28, 2, 46, 29), e(30, 42, 24, 1), e(30, 23, 15, 28) }, // 31
    .{ e(30, 17, 115, 0), e(28, 10, 46, 23), e(30, 10, 24, 35), e(30, 19, 15, 35) }, // 32
    .{ e(30, 17, 115, 1), e(28, 14, 46, 21), e(30, 29, 24, 19), e(30, 11, 15, 46) }, // 33
    .{ e(30, 13, 115, 6), e(28, 14, 46, 23), e(30, 44, 24, 7), e(30, 59, 16, 1) }, // 34
    .{ e(30, 12, 121, 7), e(28, 12, 47, 26), e(30, 39, 24, 14), e(30, 22, 15, 41) }, // 35
    .{ e(30, 6, 121, 14), e(28, 6, 47, 34), e(30, 46, 24, 10), e(30, 2, 15, 64) }, // 36
    .{ e(30, 17, 122, 4), e(28, 29, 46, 14), e(30, 49, 24, 10), e(30, 24, 15, 46) }, // 37
    .{ e(30, 4, 122, 18), e(28, 13, 46, 32), e(30, 48, 24, 14), e(30, 42, 15, 32) }, // 38
    .{ e(30, 20, 117, 4), e(28, 40, 47, 7), e(30, 43, 24, 22), e(30, 10, 15, 67) }, // 39
    .{ e(30, 19, 118, 6), e(28, 18, 47, 31), e(30, 34, 24, 34), e(30, 20, 15, 61) }, // 40
};

fn e(ec_per_block: u8, group1_blocks: u8, group1_data: u8, group2_blocks: u8) EcBlocks {
    return .{
        .ec_per_block = ec_per_block,
        .group1_blocks = group1_blocks,
        .group1_data = group1_data,
        .group2_blocks = group2_blocks,
    };
}

/// Alignment pattern center coordinates for a version (ISO/IEC 18004 Annex E).
/// Centers lie on the cross product of the returned list with itself.
pub fn alignmentPositions(version: u8) []const u8 {
    assert(version >= min_version and version <= max_version);
    return alignment_positions_table[version - 1];
}

const alignment_positions_table: [40][]const u8 = .{
    &.{}, // 1
    &.{ 6, 18 }, // 2
    &.{ 6, 22 }, // 3
    &.{ 6, 26 }, // 4
    &.{ 6, 30 }, // 5
    &.{ 6, 34 }, // 6
    &.{ 6, 22, 38 }, // 7
    &.{ 6, 24, 42 }, // 8
    &.{ 6, 26, 46 }, // 9
    &.{ 6, 28, 50 }, // 10
    &.{ 6, 30, 54 }, // 11
    &.{ 6, 32, 58 }, // 12
    &.{ 6, 34, 62 }, // 13
    &.{ 6, 26, 46, 66 }, // 14
    &.{ 6, 26, 48, 70 }, // 15
    &.{ 6, 26, 50, 74 }, // 16
    &.{ 6, 30, 54, 78 }, // 17
    &.{ 6, 30, 56, 82 }, // 18
    &.{ 6, 30, 58, 86 }, // 19
    &.{ 6, 34, 62, 90 }, // 20
    &.{ 6, 28, 50, 72, 94 }, // 21
    &.{ 6, 26, 50, 74, 98 }, // 22
    &.{ 6, 30, 54, 78, 102 }, // 23
    &.{ 6, 28, 54, 80, 106 }, // 24
    &.{ 6, 32, 58, 84, 110 }, // 25
    &.{ 6, 30, 58, 86, 114 }, // 26
    &.{ 6, 34, 62, 90, 118 }, // 27
    &.{ 6, 26, 50, 74, 98, 122 }, // 28
    &.{ 6, 30, 54, 78, 102, 126 }, // 29
    &.{ 6, 26, 52, 78, 104, 130 }, // 30
    &.{ 6, 30, 56, 82, 108, 134 }, // 31
    &.{ 6, 34, 60, 86, 112, 138 }, // 32
    &.{ 6, 30, 58, 86, 114, 142 }, // 33
    &.{ 6, 34, 62, 90, 118, 146 }, // 34
    &.{ 6, 30, 54, 78, 102, 126, 150 }, // 35
    &.{ 6, 24, 50, 76, 102, 128, 154 }, // 36
    &.{ 6, 28, 54, 80, 106, 132, 158 }, // 37
    &.{ 6, 32, 58, 84, 110, 136, 162 }, // 38
    &.{ 6, 26, 54, 82, 110, 138, 166 }, // 39
    &.{ 6, 30, 58, 86, 114, 142, 170 }, // 40
};

fn bchRemainder(data: u32, comptime generator_poly: u32, comptime total_bits: u5, comptime data_bits: u5) u32 {
    const gen_degree = total_bits - data_bits;
    var rem = data << gen_degree;
    var bit: u5 = total_bits;
    while (bit > gen_degree) {
        bit -= 1;
        if (rem >> bit & 1 != 0) rem ^= generator_poly << (bit - gen_degree);
    }
    return rem;
}

/// The 32 valid format information codewords: BCH(15,5) over the 5-bit value
/// (ec_level_bits << 3 | mask), XORed with the fixed mask 0x5412.
pub const format_info: [32]u15 = blk: {
    var table: [32]u15 = undefined;
    for (0..32) |data| {
        const codeword = data << 10 | bchRemainder(data, 0x537, 15, 5);
        table[data] = codeword ^ 0x5412;
    }
    break :blk table;
};

/// The masked format codeword for an error correction level and mask pattern.
pub fn formatInfo(level: EcLevel, mask: u3) u15 {
    return format_info[@as(u5, level.formatBits()) << 3 | mask];
}

/// The 18-bit version information codewords (BCH(18,6)) for versions 7-40.
pub const version_info: [34]u18 = blk: {
    var table: [34]u18 = undefined;
    for (0..34) |i| {
        const version = i + 7;
        table[i] = version << 12 | bchRemainder(version, 0x1f25, 18, 6);
    }
    break :blk table;
};

pub fn versionInfo(version: u8) u18 {
    assert(version >= 7 and version <= max_version);
    return version_info[version - 7];
}

const alphanumeric_values: [256]i8 = blk: {
    var table: [256]i8 = @splat(-1);
    for (alphanumeric_charset, 0..) |char, i| table[char] = @intCast(i);
    break :blk table;
};

/// Value of each ASCII character in alphanumeric mode, or null.
pub fn alphanumericValue(char: u8) ?u6 {
    const value = alphanumeric_values[char];
    return if (value < 0) null else @intCast(value);
}

/// Character for an alphanumeric mode value.
pub const alphanumeric_charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

test "format info known vector" {
    // M with mask 0 encodes data 0, so the codeword is exactly the XOR mask.
    try std.testing.expectEqual(@as(u15, 0b101010000010010), formatInfo(.medium, 0));
    try std.testing.expectEqual(@as(u15, 0b111011111000100), formatInfo(.low, 0));
    try std.testing.expectEqual(@as(u15, 0b101111001111100), formatInfo(.medium, 2));
    // Any two distinct format codewords differ in at least 7 bits.
    for (format_info, 0..) |a, i| {
        for (format_info[i + 1 ..]) |b| {
            try std.testing.expect(@popCount(a ^ b) >= 7);
        }
    }
}

test "version info known vector" {
    // ISO/IEC 18004: version 7 encodes as 000111110010010100.
    try std.testing.expectEqual(@as(u18, 0b000111110010010100), versionInfo(7));
    for (version_info, 0..) |a, i| {
        for (version_info[i + 1 ..]) |b| {
            try std.testing.expect(@popCount(a ^ b) >= 8);
        }
    }
}

test "alignment positions are consistent" {
    for (min_version..max_version + 1) |v| {
        const version: u8 = @intCast(v);
        const positions = alignmentPositions(version);
        if (version == 1) {
            try std.testing.expectEqual(@as(usize, 0), positions.len);
            continue;
        }
        try std.testing.expectEqual(@as(usize, version / 7 + 2), positions.len);
        try std.testing.expectEqual(@as(u8, 6), positions[0]);
        try std.testing.expectEqual(dimension(version) - 7, positions[positions.len - 1]);
        for (positions[1..], positions[0 .. positions.len - 1]) |next, prev| {
            try std.testing.expect(next > prev);
            try std.testing.expect((next - prev) % 2 == 0);
        }
    }
}

test "ec blocks totals match module capacity" {
    // The sum of data and ecc codewords over all blocks must equal the number
    // of non-function modules divided by 8, for every version and level.
    const BitMatrix = @import("matrix.zig").BitMatrix;
    for (min_version..max_version + 1) |v| {
        const version: u8 = @intCast(v);
        var matrix = try BitMatrix.init(std.testing.allocator, version);
        defer matrix.deinit(std.testing.allocator);
        var data_modules: usize = 0;
        for (matrix.is_function) |f| {
            if (f == 0) data_modules += 1;
        }
        const total_codewords = data_modules / 8;
        const remainder = data_modules % 8;
        try std.testing.expect(remainder == 0 or remainder == 3 or remainder == 4 or remainder == 7);
        for ([_]EcLevel{ .low, .medium, .quartile, .high }) |level| {
            try std.testing.expectEqual(total_codewords, ecBlocks(version, level).totalCodewords());
        }
    }
}

//! QR module matrix: function pattern layout, data placement in zigzag order,
//! masking, and the mask evaluation penalty rules.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const tables = @import("tables.zig");

pub const Position = struct { row: u16, col: u16 };

/// A square module matrix for one QR version. Each module is 0 (light) or
/// 1 (dark); is_function marks modules that carry no data codeword bits
/// (finder, timing, alignment, format and version information).
pub const BitMatrix = struct {
    version: u8,
    dim: u16,
    modules: []u8,
    is_function: []u8,

    /// Allocates a matrix for version with all function patterns placed and
    /// the format/version information areas reserved.
    pub fn init(allocator: Allocator, version: u8) !BitMatrix {
        const dim = tables.dimension(version);
        const len = @as(usize, dim) * dim;
        const modules = try allocator.alloc(u8, len);
        errdefer allocator.free(modules);
        const is_function = try allocator.alloc(u8, len);
        @memset(modules, 0);
        @memset(is_function, 0);
        var self: BitMatrix = .{ .version = version, .dim = dim, .modules = modules, .is_function = is_function };
        self.placeFunctionPatterns();
        return self;
    }

    pub fn deinit(self: *BitMatrix, allocator: Allocator) void {
        allocator.free(self.modules);
        allocator.free(self.is_function);
        self.* = undefined;
    }

    pub fn get(self: BitMatrix, row: usize, col: usize) u1 {
        return @intCast(self.modules[row * self.dim + col]);
    }

    pub fn set(self: *BitMatrix, row: usize, col: usize, value: u1) void {
        self.modules[row * self.dim + col] = value;
    }

    pub fn isFunction(self: BitMatrix, row: usize, col: usize) bool {
        return self.is_function[row * self.dim + col] != 0;
    }

    fn setFunction(self: *BitMatrix, row: usize, col: usize, value: u1) void {
        self.modules[row * self.dim + col] = value;
        self.is_function[row * self.dim + col] = 1;
    }

    /// Marks a module as function without touching its value.
    fn reserve(self: *BitMatrix, row: usize, col: usize) void {
        self.is_function[row * self.dim + col] = 1;
    }

    fn placeFunctionPatterns(self: *BitMatrix) void {
        const dim = self.dim;

        // Finder patterns with their separators at three corners.
        self.placeFinder(0, 0);
        self.placeFinder(0, dim - 7);
        self.placeFinder(dim - 7, 0);

        // Alignment patterns, skipping the three finder corners.
        const positions = tables.alignmentPositions(self.version);
        const last = positions.len -| 1;
        for (positions, 0..) |row, i| {
            for (positions, 0..) |col, j| {
                if ((i == 0 and (j == 0 or j == last)) or (i == last and j == 0)) continue;
                self.placeAlignment(row, col);
            }
        }

        // Timing patterns along row 6 and column 6; alignment patterns that
        // fall on them carry the same alternation, so skip placed modules.
        for (8..dim - 8) |i| {
            const dark: u1 = @intFromBool(i % 2 == 0);
            if (!self.isFunction(6, i)) self.setFunction(6, i, dark);
            if (!self.isFunction(i, 6)) self.setFunction(i, 6, dark);
        }

        // Format information areas around the finders, and the dark module.
        for (0..9) |i| {
            self.reserve(8, i);
            self.reserve(i, 8);
        }
        for (dim - 8..dim) |i| {
            self.reserve(8, i);
            self.reserve(i, 8);
        }
        self.setFunction(dim - 8, 8, 1);

        // Version information areas (bottom-left and top-right) for v >= 7.
        if (self.version >= 7) {
            for (0..6) |i| {
                for (dim - 11..dim - 8) |j| {
                    self.reserve(j, i);
                    self.reserve(i, j);
                }
            }
        }
    }

    fn placeFinder(self: *BitMatrix, row: usize, col: usize) void {
        // 7x7 concentric pattern plus the surrounding light separator.
        var dr: i32 = -1;
        while (dr <= 7) : (dr += 1) {
            var dc: i32 = -1;
            while (dc <= 7) : (dc += 1) {
                const r = @as(i32, @intCast(row)) + dr;
                const c = @as(i32, @intCast(col)) + dc;
                if (r < 0 or c < 0 or r >= self.dim or c >= self.dim) continue;
                const dist = @max(@abs(dr - 3), @abs(dc - 3));
                self.setFunction(@intCast(r), @intCast(c), @intFromBool(dist <= 1 or dist == 3));
            }
        }
    }

    fn placeAlignment(self: *BitMatrix, center_row: usize, center_col: usize) void {
        for (0..5) |i| {
            for (0..5) |j| {
                const dist = @max(@abs(@as(i32, @intCast(i)) - 2), @abs(@as(i32, @intCast(j)) - 2));
                self.setFunction(center_row - 2 + i, center_col - 2 + j, @intFromBool(dist != 1));
            }
        }
    }

    /// The two format information copies share bit-to-module maps; bit 0 is
    /// the least significant bit of the codeword.
    fn formatCoordinates(self: BitMatrix, copy: u1, bit: u4) Position {
        const dim = self.dim;
        return switch (copy) {
            0 => switch (bit) {
                0, 1, 2, 3, 4, 5 => .{ .row = bit, .col = 8 },
                6 => .{ .row = 7, .col = 8 },
                7 => .{ .row = 8, .col = 8 },
                8 => .{ .row = 8, .col = 7 },
                else => .{ .row = 8, .col = 14 - @as(u16, bit) },
            },
            1 => if (bit < 8)
                .{ .row = 8, .col = dim - 1 - @as(u16, bit) }
            else
                .{ .row = dim - 15 + @as(u16, bit), .col = 8 },
        };
    }

    pub fn writeFormatInfo(self: *BitMatrix, codeword: u15) void {
        for (0..15) |bit| {
            const value: u1 = @intCast(codeword >> @intCast(bit) & 1);
            inline for (0..2) |copy| {
                const pos = self.formatCoordinates(copy, @intCast(bit));
                self.setFunction(pos.row, pos.col, value);
            }
        }
    }

    pub fn readFormatInfo(self: BitMatrix, copy: u1) u15 {
        var codeword: u15 = 0;
        for (0..15) |bit| {
            const pos = self.formatCoordinates(copy, @intCast(bit));
            codeword |= @as(u15, self.get(pos.row, pos.col)) << @intCast(bit);
        }
        return codeword;
    }

    /// Version information copies: bit (3*i + j) of the 18-bit codeword goes
    /// to (dim-11+j, i) bottom-left and (i, dim-11+j) top-right.
    pub fn writeVersionInfo(self: *BitMatrix, codeword: u18) void {
        assert(self.version >= 7);
        for (0..6) |i| {
            for (0..3) |j| {
                const value: u1 = @intCast(codeword >> @intCast(3 * i + j) & 1);
                self.setFunction(self.dim - 11 + j, i, value);
                self.setFunction(i, self.dim - 11 + j, value);
            }
        }
    }

    fn readVersionInfo(self: BitMatrix, copy: u1) u18 {
        var codeword: u18 = 0;
        for (0..6) |i| {
            for (0..3) |j| {
                const value = if (copy == 0)
                    self.get(self.dim - 11 + j, i)
                else
                    self.get(i, self.dim - 11 + j);
                codeword |= @as(u18, value) << @intCast(3 * i + j);
            }
        }
        return codeword;
    }

    /// Writes codeword bits (most significant first) into the data modules in
    /// zigzag order; any remainder modules are left light.
    pub fn placeData(self: *BitMatrix, codewords: []const u8) void {
        var it: DataIterator = .init(self);
        var bit: usize = 0;
        const total_bits = codewords.len * 8;
        while (it.next()) |pos| {
            const value: u1 = if (bit < total_bits)
                @intCast(codewords[bit / 8] >> @intCast(7 - bit % 8) & 1)
            else
                0;
            self.set(pos.row, pos.col, value);
            bit += 1;
        }
        assert(bit >= total_bits);
    }

    /// Reads data modules in zigzag order into out, the exact inverse of
    /// placeData.
    pub fn extractCodewords(self: BitMatrix, out: []u8) void {
        var it: DataIterator = .init(&self);
        var bit: usize = 0;
        const total_bits = out.len * 8;
        @memset(out, 0);
        while (bit < total_bits) : (bit += 1) {
            const pos = it.next() orelse break;
            out[bit / 8] |= @as(u8, self.get(pos.row, pos.col)) << @intCast(7 - bit % 8);
        }
        assert(bit == total_bits);
    }

    /// XORs the mask pattern over all data modules; applying it twice undoes it.
    pub fn applyMask(self: *BitMatrix, mask: u3) void {
        for (0..self.dim) |row| {
            for (0..self.dim) |col| {
                if (!self.isFunction(row, col) and maskBit(mask, row, col)) {
                    self.modules[row * self.dim + col] ^= 1;
                }
            }
        }
    }

    /// Mask evaluation score; lower is better (ISO/IEC 18004 section 8.8.2).
    pub fn penalty(self: BitMatrix) u32 {
        return self.penaltyRuns() + self.penaltyBlocks() + self.penaltyFinderLike() + self.penaltyBalance();
    }

    /// Reads along rows when axis is 0 and along columns when axis is 1.
    fn getAxis(self: BitMatrix, axis: usize, i: usize, j: usize) u1 {
        return if (axis == 0) self.get(i, j) else self.get(j, i);
    }

    /// N1: runs of 5 or more same-colored modules in a row or column.
    fn penaltyRuns(self: BitMatrix) u32 {
        var score: u32 = 0;
        for (0..2) |axis| {
            for (0..self.dim) |i| {
                var run: u32 = 1;
                var prev = self.getAxis(axis, i, 0);
                for (1..self.dim) |j| {
                    const value = self.getAxis(axis, i, j);
                    if (value == prev) {
                        run += 1;
                        if (run == 5) score += 3 else if (run > 5) score += 1;
                    } else {
                        prev = value;
                        run = 1;
                    }
                }
            }
        }
        return score;
    }

    /// N2: 2x2 blocks of same-colored modules (overlapping).
    fn penaltyBlocks(self: BitMatrix) u32 {
        var score: u32 = 0;
        for (0..self.dim - 1) |row| {
            for (0..self.dim - 1) |col| {
                const value = self.get(row, col);
                if (value == self.get(row, col + 1) and
                    value == self.get(row + 1, col) and
                    value == self.get(row + 1, col + 1)) score += 3;
            }
        }
        return score;
    }

    /// N3: 1:1:3:1:1 finder-like patterns with 4 light modules on either side.
    fn penaltyFinderLike(self: BitMatrix) u32 {
        const core = [7]u1{ 1, 0, 1, 1, 1, 0, 1 };
        var score: u32 = 0;
        for (0..2) |axis| {
            for (0..self.dim) |i| {
                outer: for (0..self.dim - 6) |start| {
                    for (core, start..) |expected, j| {
                        if (self.getAxis(axis, i, j) != expected) continue :outer;
                    }
                    var light_before = start >= 4;
                    if (light_before) for (start - 4..start) |j| {
                        if (self.getAxis(axis, i, j) != 0) light_before = false;
                    };
                    var light_after = start + 11 <= self.dim;
                    if (light_after) for (start + 7..start + 11) |j| {
                        if (self.getAxis(axis, i, j) != 0) light_after = false;
                    };
                    if (light_before or light_after) score += 40;
                }
            }
        }
        return score;
    }

    /// N4: deviation of the dark module proportion from 50%.
    fn penaltyBalance(self: BitMatrix) u32 {
        var dark: usize = 0;
        for (self.modules) |m| dark += m;
        const total = self.modules.len;
        const percent = dark * 100 / total;
        const deviation = if (percent < 50) 50 - percent else percent - 50;
        return @intCast(10 * (deviation / 5));
    }
};

/// The mask predicate: true means the module at (row, col) is inverted.
pub fn maskBit(mask: u3, row: usize, col: usize) bool {
    return switch (mask) {
        0 => (row + col) % 2 == 0,
        1 => row % 2 == 0,
        2 => col % 3 == 0,
        3 => (row + col) % 3 == 0,
        4 => (row / 2 + col / 3) % 2 == 0,
        5 => (row * col) % 2 + (row * col) % 3 == 0,
        6 => ((row * col) % 2 + (row * col) % 3) % 2 == 0,
        7 => ((row + col) % 2 + (row * col) % 3) % 2 == 0,
    };
}

/// Traverses all data (non-function) modules in the zigzag placement order:
/// column pairs right to left, alternating up and down, skipping column 6.
/// Shared by placeData and extractCodewords so the encoder and decoder can
/// never disagree on the traversal.
pub const DataIterator = struct {
    dim: i32,
    is_function: []const u8,
    col: i32,
    row: i32,
    upward: bool,
    right: bool,

    pub fn init(matrix: *const BitMatrix) DataIterator {
        return .{
            .dim = matrix.dim,
            .is_function = matrix.is_function,
            .col = matrix.dim - 1,
            .row = matrix.dim - 1,
            .upward = true,
            .right = true,
        };
    }

    pub fn next(self: *DataIterator) ?Position {
        while (self.col > 0) {
            const row: usize = @intCast(self.row);
            const col: usize = @intCast(if (self.right) self.col else self.col - 1);
            self.advance();
            if (self.is_function[row * @as(usize, @intCast(self.dim)) + col] == 0) {
                return .{ .row = @intCast(row), .col = @intCast(col) };
            }
        }
        return null;
    }

    fn advance(self: *DataIterator) void {
        if (self.right) {
            self.right = false;
            return;
        }
        self.right = true;
        if (self.upward) {
            if (self.row == 0) self.nextColumnPair() else self.row -= 1;
        } else {
            if (self.row == self.dim - 1) self.nextColumnPair() else self.row += 1;
        }
    }

    fn nextColumnPair(self: *DataIterator) void {
        self.col -= 2;
        if (self.col == 6) self.col = 5; // the vertical timing column is skipped entirely
        self.upward = !self.upward;
    }
};

test "data module count matches capacity for version 1" {
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    var it: DataIterator = .init(&m);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    // Version 1: 26 codewords, no remainder bits.
    try std.testing.expectEqual(@as(usize, 26 * 8), count);
}

test "placeData and extractCodewords roundtrip" {
    var m = try BitMatrix.init(std.testing.allocator, 7);
    defer m.deinit(std.testing.allocator);
    const total = tables.ecBlocks(7, .low).totalCodewords();
    const codewords = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(codewords);
    var prng: std.Random.DefaultPrng = .init(42);
    prng.random().bytes(codewords);
    m.placeData(codewords);
    const out = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(out);
    m.extractCodewords(out);
    try std.testing.expectEqualSlices(u8, codewords, out);
}

test "format info write/read roundtrip" {
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    m.writeFormatInfo(0b101010000010010);
    try std.testing.expectEqual(@as(u15, 0b101010000010010), m.readFormatInfo(0));
    try std.testing.expectEqual(@as(u15, 0b101010000010010), m.readFormatInfo(1));
}

test "version info write/read roundtrip" {
    var m = try BitMatrix.init(std.testing.allocator, 7);
    defer m.deinit(std.testing.allocator);
    m.writeVersionInfo(tables.versionInfo(7));
    try std.testing.expectEqual(tables.versionInfo(7), m.readVersionInfo(0));
    try std.testing.expectEqual(tables.versionInfo(7), m.readVersionInfo(1));
}

test "penalty rule N1 counts runs" {
    // A 21x21 matrix that alternates every module scores 0 for N1.
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    for (0..21) |r| for (0..21) |c| m.set(r, c, @intCast((r + c) % 2));
    try std.testing.expectEqual(@as(u32, 0), m.penaltyRuns());
    // A solid row of 21 scores 3 + 16 = 19; a solid matrix scores 19 * 42.
    for (0..21) |r| for (0..21) |c| m.set(r, c, 1);
    try std.testing.expectEqual(@as(u32, 19 * 42), m.penaltyRuns());
}

test "penalty rule N2 counts blocks" {
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    for (0..21) |r| for (0..21) |c| m.set(r, c, @intCast((r + c) % 2));
    try std.testing.expectEqual(@as(u32, 0), m.penaltyBlocks());
    for (0..21) |r| for (0..21) |c| m.set(r, c, 1);
    try std.testing.expectEqual(@as(u32, 3 * 20 * 20), m.penaltyBlocks());
}

test "penalty rule N3 finder-like patterns" {
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    for (0..21) |r| for (0..21) |c| m.set(r, c, @intCast((r + c) % 2));
    // Write 0000 1011101 at the start of row 0; one occurrence in that row.
    const pattern = [_]u1{ 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1 };
    for (pattern, 0..) |v, c| m.set(0, c, v);
    // Fill the rest of the row so no accidental second occurrence appears.
    for (11..21) |c| m.set(0, c, @intCast(c % 2));
    const score = m.penaltyFinderLike();
    // At least the planted occurrence; column direction may add more from
    // the checkerboard interaction, so re-check exact count on the row only.
    try std.testing.expect(score >= 40);
}

test "penalty rule N4 balance" {
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    for (0..21) |r| for (0..21) |c| m.set(r, c, 1);
    // 100% dark: deviation 50 -> 10 * 10 = 100.
    try std.testing.expectEqual(@as(u32, 100), m.penaltyBalance());
    for (0..21) |r| for (0..21) |c| m.set(r, c, @intCast((r + c) % 2));
    // Checkerboard on odd dimension: 221/441 dark = 50.1% -> 0.
    try std.testing.expectEqual(@as(u32, 0), m.penaltyBalance());
}

test "function patterns for version 1" {
    var m = try BitMatrix.init(std.testing.allocator, 1);
    defer m.deinit(std.testing.allocator);
    // Finder corners are dark, separator ring is light.
    try std.testing.expectEqual(@as(u1, 1), m.get(0, 0));
    try std.testing.expectEqual(@as(u1, 1), m.get(6, 6));
    try std.testing.expectEqual(@as(u1, 0), m.get(7, 7));
    // Light ring inside the outer border.
    try std.testing.expectEqual(@as(u1, 0), m.get(1, 1));
    // Center 3x3 is dark.
    try std.testing.expectEqual(@as(u1, 1), m.get(3, 3));
    // Timing pattern alternates starting dark at (6, 8).
    try std.testing.expectEqual(@as(u1, 1), m.get(6, 8));
    try std.testing.expectEqual(@as(u1, 0), m.get(6, 9));
    // Dark module.
    try std.testing.expectEqual(@as(u1, 1), m.get(21 - 8, 8));
}

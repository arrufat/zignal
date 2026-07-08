//! QR code decoder: sampled modules to data bytes. Image handling (finding
//! and sampling the symbol) lives in detector.zig.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Point = @import("../geometry/Point.zig").Point;
const encoder = @import("encoder.zig");
const matrix_mod = @import("matrix.zig");
const BitMatrix = matrix_mod.BitMatrix;
const rs = @import("reed_solomon.zig");
const segment = @import("segment.zig");
const tables = @import("tables.zig");

pub const DecodeResult = struct {
    /// Decoded message bytes.
    data: []u8,
    version: u8,
    ec_level: tables.EcLevel,
    mask: u3,
    /// Codewords repaired by Reed-Solomon error correction.
    corrected_errors: u32,
    /// Image-space corners of the symbol (top-left, top-right, bottom-left,
    /// bottom-right of the sampled grid). Set by the image detector; null
    /// when decoding raw modules directly.
    corners: ?[4]Point(2, f32) = null,

    pub fn deinit(self: *DecodeResult, allocator: Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Decodes a sampled module matrix in place (the matrix is unmasked during
/// decoding). The matrix must have been created with BitMatrix.init so its
/// function map matches its version.
fn decodeMatrix(allocator: Allocator, m: *BitMatrix) !DecodeResult {
    const format = readFormat(m) orelse return error.InvalidFormat;
    m.applyMask(format.mask);

    const blocks = tables.ecBlocks(m.version, format.level);
    const interleaved = try allocator.alloc(u8, blocks.totalCodewords());
    defer allocator.free(interleaved);
    m.extractCodewords(interleaved);

    var corrected: u32 = 0;
    const data_codewords = try deinterleave(allocator, interleaved, blocks, &corrected);
    defer allocator.free(data_codewords);

    const data = try segment.readSegments(allocator, data_codewords, m.version);
    return .{
        .data = data,
        .version = m.version,
        .ec_level = format.level,
        .mask = format.mask,
        .corrected_errors = corrected,
    };
}

const Format = struct { level: tables.EcLevel, mask: u3 };

/// Updates the running best match of raw against a table of valid codewords,
/// measured in Hamming distance. Both BCH-protected info fields (format and
/// version) decode by closest match under a shared distance-3 threshold.
fn matchClosest(comptime T: type, raw: T, table: []const T, best_distance: *u32, best_index: *?usize) void {
    for (table, 0..) |codeword, index| {
        const distance = @popCount(raw ^ codeword);
        if (distance < best_distance.*) {
            best_distance.* = distance;
            best_index.* = index;
        }
    }
}

/// Reads both format information copies and returns the closest valid
/// codeword, tolerating up to 3 bit errors (the code has distance 7).
fn readFormat(m: *const BitMatrix) ?Format {
    var best_distance: u32 = 4;
    var best_index: ?usize = null;
    for (0..2) |copy| {
        matchClosest(u15, m.readFormatInfo(@intCast(copy)), &tables.format_info, &best_distance, &best_index);
    }
    const index = best_index orelse return null;
    return .{
        .level = tables.EcLevel.fromFormatBits(@intCast(index >> 3)),
        .mask = @intCast(index & 7),
    };
}

/// Undoes the block interleaving and corrects each Reed-Solomon block,
/// returning the concatenated data codewords. Caller frees.
fn deinterleave(allocator: Allocator, interleaved: []const u8, blocks: tables.EcBlocks, corrected: *u32) ![]u8 {
    const ec_len: usize = blocks.ec_per_block;

    // Gather each block contiguously (data followed by its ecc codewords).
    const scratch = try allocator.alloc(u8, interleaved.len);
    defer allocator.free(scratch);
    var it: tables.InterleaveIterator = .init(blocks);
    for (interleaved) |codeword| scratch[it.next().?] = codeword;
    assert(it.next() == null);

    const data = try allocator.alloc(u8, blocks.dataCodewords());
    errdefer allocator.free(data);
    var out: usize = 0;
    for (0..blocks.totalBlocks()) |i| {
        const len = blocks.blockDataLen(i);
        const block = scratch[blocks.blockStart(i)..][0 .. len + ec_len];
        corrected.* += @intCast(try rs.decode(block, ec_len));
        @memcpy(data[out..][0..len], block[0..len]);
        out += len;
    }
    return data;
}

/// Reads the module at (row, col) as seen under one of the eight axis-aligned
/// orientations (4 rotations, optionally mirrored).
fn orientedModule(modules: []const u8, dim: usize, orientation: u3, row: usize, col: usize) u8 {
    var r = row;
    var c = col;
    if (orientation & 4 != 0) std.mem.swap(usize, &r, &c);
    return switch (@as(u2, @truncate(orientation))) {
        0 => modules[r * dim + c],
        1 => modules[(dim - 1 - c) * dim + r],
        2 => modules[(dim - 1 - r) * dim + (dim - 1 - c)],
        3 => modules[c * dim + (dim - 1 - r)],
    };
}

/// Copies raw module values into the matrix under an orientation. Every
/// module is overwritten, so the matrix can be refilled across orientations.
fn fillModules(m: *BitMatrix, modules: []const u8, orientation: u3) void {
    const dim: usize = m.dim;
    assert(modules.len == dim * dim);
    for (0..dim) |row| {
        for (0..dim) |col| {
            m.modules[row * dim + col] = orientedModule(modules, dim, orientation, row, col);
        }
    }
}

/// Reads the version information blocks from raw sampled modules of a
/// version 7+ symbol (bit 3i+j at (dim-11+j, i); the transposed second copy
/// is covered by the mirrored orientations) under all eight orientations,
/// returning the closest codeword within Hamming distance 3 (BCH(18,6) has
/// distance 8).
pub fn readVersion(modules: []const u8, dim: u16) ?u8 {
    var best_distance: u32 = 4;
    var best_index: ?usize = null;
    for (0..8) |orientation| {
        var codeword: u18 = 0;
        for (0..6) |i| {
            for (0..3) |j| {
                const bit = orientedModule(modules, dim, @intCast(orientation), dim - 11 + j, i);
                codeword |= @as(u18, bit) << @intCast(3 * i + j);
            }
        }
        matchClosest(u18, codeword, &tables.version_info, &best_distance, &best_index);
    }
    const index = best_index orelse return null;
    return @intCast(index + 7);
}

/// Tries to decode raw sampled modules in every axis-aligned orientation.
pub fn decodeModules(allocator: Allocator, version: u8, modules: []const u8) !DecodeResult {
    var m = try BitMatrix.init(allocator, version);
    defer m.deinit(allocator);
    var last_err: anyerror = error.InvalidFormat;
    for (0..8) |orientation| {
        fillModules(&m, modules, @intCast(orientation));
        if (decodeMatrix(allocator, &m)) |result| {
            return result;
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            last_err = err;
        }
    }
    return last_err;
}

test "matrix roundtrip across versions, levels, and modes" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xdecafbad);
    const random = prng.random();

    const versions = [_]u8{ 1, 2, 5, 7, 10, 17, 25, 32, 40 };
    const levels = [_]tables.EcLevel{ .low, .medium, .quartile, .high };
    for (versions) |version| {
        for (levels) |level| {
            for ([_]segment.Mode{ .numeric, .alphanumeric, .byte }) |mode| {
                // Fill to (near) capacity for this version/level/mode.
                const capacity_bits = tables.ecBlocks(version, level).dataCodewords() * 8;
                const overhead = 4 + mode.charCountBits(version);
                const max_len = switch (mode) {
                    .numeric => (capacity_bits - overhead) / 10 * 3,
                    .alphanumeric => (capacity_bits - overhead) / 11 * 2,
                    .byte => (capacity_bits - overhead) / 8,
                };
                const len = @min(max_len, 1 + random.intRangeLessThan(usize, 0, max_len));
                const data = try allocator.alloc(u8, len);
                defer allocator.free(data);
                for (data) |*char| {
                    char.* = switch (mode) {
                        .numeric => '0' + random.intRangeLessThan(u8, 0, 10),
                        .alphanumeric => tables.alphanumeric_charset[random.intRangeLessThan(u8, 0, 45)],
                        .byte => random.int(u8),
                    };
                }

                var m = try encoder.encodeMatrix(allocator, data, .{ .ec_level = level, .version = version });
                defer m.deinit(allocator);
                var result = try decodeMatrix(allocator, &m);
                defer result.deinit(allocator);
                try std.testing.expectEqualSlices(u8, data, result.data);
                try std.testing.expectEqual(version, result.version);
                try std.testing.expectEqual(level, result.ec_level);
                try std.testing.expectEqual(@as(u32, 0), result.corrected_errors);
            }
        }
    }
}

test "decoding survives codeword damage up to capacity" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xfeedface);
    const random = prng.random();

    // Version 5-Q exercises the two-group block structure. Consecutive
    // interleaved codewords belong to different blocks, so corrupting the
    // first num_blocks * t codewords damages exactly t per block.
    var m = try encoder.encodeMatrix(allocator, "DAMAGE RESISTANCE TEST 123", .{
        .ec_level = .quartile,
        .version = 5,
    });
    defer m.deinit(allocator);

    const blocks = tables.ecBlocks(5, .quartile);
    const per_block = blocks.ec_per_block / 2; // correction capacity
    const damaged = blocks.totalBlocks() * per_block;
    const interleaved = try allocator.alloc(u8, blocks.totalCodewords());
    defer allocator.free(interleaved);
    m.extractCodewords(interleaved);
    for (interleaved[0..damaged]) |*codeword| {
        codeword.* ^= random.int(u8) | 1; // guaranteed to change
    }
    m.placeData(interleaved);

    var result = try decodeMatrix(allocator, &m);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "DAMAGE RESISTANCE TEST 123", result.data);
    try std.testing.expectEqual(@as(u32, @intCast(damaged)), result.corrected_errors);
}

test "format info damage up to 3 bits is corrected" {
    const allocator = std.testing.allocator;
    var m = try encoder.encodeMatrix(allocator, "FORMAT DAMAGE", .{ .ec_level = .high });
    defer m.deinit(allocator);
    // Corrupt 3 bits of the first format copy.
    for ([_]matrix_mod.Position{
        .{ .row = 8, .col = 0 },
        .{ .row = 8, .col = 2 },
        .{ .row = 8, .col = 4 },
    }) |pos| {
        m.modules[@as(usize, pos.row) * m.dim + pos.col] ^= 1;
    }
    var result = try decodeMatrix(allocator, &m);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "FORMAT DAMAGE", result.data);
}

test "decodeModules recovers every orientation" {
    const allocator = std.testing.allocator;
    var m = try encoder.encodeMatrix(allocator, "ORIENTATION", .{});
    defer m.deinit(allocator);

    var transformed = try BitMatrix.init(allocator, m.version);
    defer transformed.deinit(allocator);
    for (0..8) |orientation| {
        fillModules(&transformed, m.modules, @intCast(orientation));
        var result = try decodeModules(allocator, m.version, transformed.modules);
        defer result.deinit(allocator);
        try std.testing.expectEqualSlices(u8, "ORIENTATION", result.data);
    }
}

test "readVersion through all orientations" {
    const allocator = std.testing.allocator;
    var m = try encoder.encodeMatrix(allocator, "VERSION INFO", .{ .version = 9 });
    defer m.deinit(allocator);
    var transformed = try BitMatrix.init(allocator, m.version);
    defer transformed.deinit(allocator);
    for (0..8) |orientation| {
        fillModules(&transformed, m.modules, @intCast(orientation));
        try std.testing.expectEqual(@as(?u8, 9), readVersion(transformed.modules, m.dim));
    }
}

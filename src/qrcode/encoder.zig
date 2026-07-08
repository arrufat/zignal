//! QR code encoder: data segments to Reed-Solomon protected codewords to a
//! masked module matrix, optionally rendered as an image.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const BitMatrix = @import("matrix.zig").BitMatrix;
const rs = @import("reed_solomon.zig");
const segment = @import("segment.zig");
const tables = @import("tables.zig");

pub const EncodeOptions = struct {
    ec_level: tables.EcLevel = .medium,
    /// QR version (1-40); null selects the smallest version that fits.
    version: ?u8 = null,
    /// Mask pattern; null selects the best-scoring one.
    mask: ?u3 = null,
    /// Pixels per module when rendering to an image.
    module_size: u32 = 8,
    /// Light border around the symbol, in modules. The spec requires 4.
    quiet_zone: u32 = 4,

    pub const default: EncodeOptions = .{};
};

/// Encodes data into a QR module matrix. Caller owns the returned matrix.
pub fn encode(allocator: Allocator, data: []const u8, options: EncodeOptions) !BitMatrix {
    const mode = segment.detectMode(data);
    const level = options.ec_level;
    const version = options.version orelse try segment.fitVersion(mode, level, data.len);
    if (version < tables.min_version or version > tables.max_version) return error.InvalidVersion;

    const blocks = tables.ecBlocks(version, level);
    if (segment.segmentBits(mode, version, data.len) > blocks.dataCodewords() * 8) {
        return error.DataTooLarge;
    }

    const data_codewords = try segment.buildCodewords(allocator, data, mode, version, level);
    defer allocator.free(data_codewords);
    const interleaved = try interleave(allocator, data_codewords, blocks);
    defer allocator.free(interleaved);

    var m = try BitMatrix.init(allocator, version);
    errdefer m.deinit(allocator);
    if (version >= 7) m.writeVersionInfo(tables.versionInfo(version));
    m.placeData(interleaved);

    const mask = options.mask orelse blk: {
        var best_mask: u3 = 0;
        var best_score: u32 = std.math.maxInt(u32);
        for (0..8) |i| {
            const candidate: u3 = @intCast(i);
            m.applyMask(candidate);
            m.writeFormatInfo(tables.formatInfo(level, candidate));
            const score = m.penalty();
            m.applyMask(candidate); // applying the mask again undoes it
            if (score < best_score) {
                best_score = score;
                best_mask = candidate;
            }
        }
        break :blk best_mask;
    };
    m.applyMask(mask);
    m.writeFormatInfo(tables.formatInfo(level, mask));
    return m;
}

/// Splits the data codewords into Reed-Solomon blocks, computes the error
/// correction codewords, and interleaves both as they appear in the symbol.
fn interleave(allocator: Allocator, data: []const u8, blocks: tables.EcBlocks) ![]u8 {
    assert(data.len == blocks.dataCodewords());
    const ec_len: usize = blocks.ec_per_block;

    // Lay the blocks out contiguously, each block's data followed by its ecc.
    const scratch = try allocator.alloc(u8, blocks.totalCodewords());
    defer allocator.free(scratch);
    var offset: usize = 0;
    for (0..blocks.totalBlocks()) |i| {
        const len = blocks.blockDataLen(i);
        const block = scratch[blocks.blockStart(i)..];
        @memcpy(block[0..len], data[offset..][0..len]);
        rs.encode(block[0..len], block[len..][0..ec_len]);
        offset += len;
    }

    const out = try allocator.alloc(u8, blocks.totalCodewords());
    var it: tables.InterleaveIterator = .init(blocks);
    for (out) |*codeword| codeword.* = scratch[it.next().?];
    assert(it.next() == null);
    return out;
}

/// Renders a module matrix as a grayscale image (dark modules are 0).
pub fn toImage(allocator: Allocator, m: BitMatrix, module_size: u32, quiet_zone: u32) !Image(u8) {
    if (module_size == 0) return error.InvalidModuleSize;
    const size = (@as(u32, m.dim) + 2 * quiet_zone) * module_size;
    var image = try Image(u8).init(allocator, size, size);
    image.fill(255);
    for (0..m.dim) |row| {
        for (0..m.dim) |col| {
            if (m.get(row, col) == 0) continue;
            const top = (quiet_zone + row) * module_size;
            const left = (quiet_zone + col) * module_size;
            for (0..module_size) |dr| {
                const start = (top + dr) * image.stride + left;
                @memset(image.data[start .. start + module_size], 0);
            }
        }
    }
    return image;
}

/// Encodes data straight to a grayscale image. Caller owns the image.
pub fn encodeImage(allocator: Allocator, data: []const u8, options: EncodeOptions) !Image(u8) {
    var m = try encode(allocator, data, options);
    defer m.deinit(allocator);
    return toImage(allocator, m, options.module_size, options.quiet_zone);
}

test "interleaving is the identity for a single block" {
    const blocks = tables.ecBlocks(1, .medium);
    const data = [_]u8{ 0x10, 0x20, 0x0c, 0x56, 0x61, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11 };
    const out = try interleave(std.testing.allocator, &data, blocks);
    defer std.testing.allocator.free(out);
    const expected_ecc = [_]u8{ 0xa5, 0x24, 0xd4, 0xc1, 0xed, 0x36, 0xc7, 0x87, 0x2c, 0x55 };
    try std.testing.expectEqualSlices(u8, &data, out[0..16]);
    try std.testing.expectEqualSlices(u8, &expected_ecc, out[16..]);
}

test "interleaving order with two groups" {
    // Version 5-Q: 2 blocks of 15 data + 2 blocks of 16 data codewords.
    const blocks = tables.ecBlocks(5, .quartile);
    const data_len = blocks.dataCodewords();
    const data = try std.testing.allocator.alloc(u8, data_len);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*d, i| d.* = @intCast(i);
    const out = try interleave(std.testing.allocator, data, blocks);
    defer std.testing.allocator.free(out);
    // Block starts: 0, 15, 30, 46. First interleaved codewords cycle through
    // the blocks; codeword 15 of the group-2 blocks appears at the end.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 15, 30, 46, 1, 16, 31, 47 }, out[0..8]);
    const data_part = out[0..data_len];
    try std.testing.expectEqual(@as(u8, 45), data_part[data_len - 2]); // last of block 3
    try std.testing.expectEqual(@as(u8, 61), data_part[data_len - 1]); // last of block 4
}

test "encode produces a valid version 1 matrix" {
    var m = try encode(std.testing.allocator, "HELLO WORLD", .{ .ec_level = .quartile });
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), m.version);
    try std.testing.expectEqual(@as(u16, 21), m.dim);
}

test "encodeImage dimensions" {
    var image = try encodeImage(std.testing.allocator, "hello", .{ .module_size = 2, .quiet_zone = 4 });
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, (21 + 8) * 2), image.rows);
    try std.testing.expectEqual(image.rows, image.cols);
}

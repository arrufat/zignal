//! QR code decoder: module matrix to data bytes, and a detector for clean,
//! axis-aligned images (generated codes and screenshots; photos with
//! perspective distortion are out of scope).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
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

    pub fn deinit(self: *DecodeResult, allocator: Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Decodes a sampled module matrix in place (the matrix is unmasked during
/// decoding). The matrix must have been created with BitMatrix.init so its
/// function map matches its version.
pub fn decodeMatrix(allocator: Allocator, m: *BitMatrix) !DecodeResult {
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

/// Reads both format information copies and returns the closest valid
/// codeword, tolerating up to 3 bit errors (the code has distance 7).
fn readFormat(m: *const BitMatrix) ?Format {
    var best_distance: u32 = 4;
    var best_index: ?u5 = null;
    for (0..2) |copy| {
        const raw = m.readFormatInfo(@intCast(copy));
        for (tables.format_info, 0..) |codeword, index| {
            const distance = @popCount(raw ^ codeword);
            if (distance < best_distance) {
                best_distance = distance;
                best_index = @intCast(index);
            }
        }
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

/// Copies raw module values into the matrix, applying one of the eight
/// axis-aligned orientations (4 rotations, optionally mirrored). Every module
/// is overwritten, so the matrix can be refilled across orientations.
fn fillModules(m: *BitMatrix, modules: []const u8, orientation: u3) void {
    const dim: usize = m.dim;
    assert(modules.len == dim * dim);
    for (0..dim) |row| {
        for (0..dim) |col| {
            var r = row;
            var c = col;
            if (orientation & 4 != 0) std.mem.swap(usize, &r, &c);
            const source = switch (@as(u2, @truncate(orientation))) {
                0 => modules[r * dim + c],
                1 => modules[(dim - 1 - c) * dim + r],
                2 => modules[(dim - 1 - r) * dim + (dim - 1 - c)],
                3 => modules[c * dim + (dim - 1 - r)],
            };
            m.modules[row * dim + col] = source;
        }
    }
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

const FinderPattern = struct {
    row: f32,
    col: f32,
    module_size: f32,
    hits: f32,
};

/// Locates a QR code in a clean grayscale image and decodes it. Returns null
/// when no decodable QR code is found. Caller owns result.data.
pub fn decode(allocator: Allocator, image: Image(u8)) !?DecodeResult {
    if (image.rows < 21 or image.cols < 21) return null;

    var binary = try Image(u8).initLike(allocator, image);
    defer binary.deinit(allocator);
    _ = image.thresholdOtsu(binary, allocator) catch return null;

    var finders_buf: [16]FinderPattern = undefined;
    const finders = findFinderPatterns(binary, &finders_buf);
    if (finders.len < 3) return null;

    const triple = pickFinderTriple(finders) orelse return null;
    return sampleAndDecode(allocator, binary, triple) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

fn isDark(binary: Image(u8), row: usize, col: usize) bool {
    return binary.at(row, col).* == 0;
}

/// Scans rows for the 1:1:3:1:1 finder ratio and cross-checks each candidate
/// vertically. Duplicate detections of the same pattern are merged.
fn findFinderPatterns(binary: Image(u8), buf: []FinderPattern) []FinderPattern {
    var count: usize = 0;
    for (0..binary.rows) |row| {
        var runs: [5]usize = @splat(0);
        var run_start: [5]usize = @splat(0);
        var run_value = isDark(binary, row, 0);
        var run_len: usize = 0;
        var col: usize = 0;
        while (col <= binary.cols) : (col += 1) {
            const value = if (col < binary.cols) isDark(binary, row, col) else !run_value;
            if (value == run_value) {
                run_len += 1;
                continue;
            }
            // A run just ended; shift it into the 5-run window.
            std.mem.copyForwards(usize, runs[0..4], runs[1..5]);
            std.mem.copyForwards(usize, run_start[0..4], run_start[1..5]);
            runs[4] = run_len;
            run_start[4] = col - run_len;
            // The window matches when it ends on a light run (the run that
            // just started is light means runs[4] was dark: pattern is
            // dark-light-dark-light-dark, so check when a dark run ends.
            if (run_value and checkRatio(runs)) {
                const center_col: f32 = @floatFromInt(run_start[2]);
                const half_mid: f32 = @floatFromInt(runs[2]);
                if (confirmCandidate(binary, row, center_col + half_mid / 2, runs)) |pattern| {
                    addCandidate(buf, &count, pattern);
                }
            }
            run_value = value;
            run_len = 1;
        }
    }
    return buf[0..count];
}

fn checkRatio(runs: [5]usize) bool {
    var total: usize = 0;
    for (runs) |r| {
        if (r == 0) return false;
        total += r;
    }
    if (total < 7) return false;
    const module: f32 = @floatFromInt(total);
    const unit = module / 7.0;
    const tolerance = unit / 2.0;
    for (runs, [5]f32{ 1, 1, 3, 1, 1 }) |run, expected| {
        const width: f32 = @floatFromInt(run);
        if (@abs(width - expected * unit) > expected * tolerance) return false;
    }
    return true;
}

/// Traces the dark-light-dark run sequence along a column starting at
/// start_row and walking by step. Returns the run lengths from the starting
/// (dark) run outward, or null if the outer runs are missing.
fn traceRuns(binary: Image(u8), col: usize, start_row: i64, step: i64) ?[3]usize {
    var runs: [3]usize = @splat(0);
    var state: usize = 0;
    var r = start_row;
    while (r >= 0 and r < binary.rows) : (r += step) {
        const dark = isDark(binary, @intCast(r), col);
        const expect_dark = state != 1;
        if (dark != expect_dark) {
            if (state == 2) break;
            state += 1;
            r -= step; // re-examine this row as part of the next run
            continue;
        }
        runs[state] += 1;
    }
    if (runs[1] == 0 or runs[2] == 0) return null;
    return runs;
}

/// Walks the vertical run through (row, col) and re-checks the ratio,
/// returning the refined pattern center.
fn confirmCandidate(binary: Image(u8), row: usize, center_col: f32, row_runs: [5]usize) ?FinderPattern {
    const col: usize = @intFromFloat(center_col);
    if (!isDark(binary, row, col)) return null;

    // Trace the five vertical runs outward from the center row.
    const up = traceRuns(binary, col, @intCast(row), -1) orelse return null;
    const down = traceRuns(binary, col, @as(i64, @intCast(row)) + 1, 1) orelse return null;

    const vertical: [5]usize = .{ up[2], up[1], up[0] + down[0], down[1], down[2] };
    if (!checkRatio(vertical)) return null;

    var total: usize = 0;
    for (vertical) |v| total += v;
    const bottom = row + 1 + down[0] + down[1] + down[2];
    const center_row = @as(f32, @floatFromInt(bottom)) - @as(f32, @floatFromInt(total)) / 2.0;

    var row_total: usize = 0;
    for (row_runs) |v| row_total += v;
    const module_size = (@as(f32, @floatFromInt(total)) + @as(f32, @floatFromInt(row_total))) / 14.0;
    return .{ .row = center_row, .col = center_col, .module_size = module_size, .hits = 1 };
}

fn addCandidate(buf: []FinderPattern, count: *usize, pattern: FinderPattern) void {
    for (buf[0..count.*]) |*existing| {
        const near = 2 * existing.module_size;
        if (@abs(existing.row - pattern.row) < near and @abs(existing.col - pattern.col) < near) {
            // Merge as a running average weighted by prior hits.
            const w = existing.hits;
            existing.row = (existing.row * w + pattern.row) / (w + 1);
            existing.col = (existing.col * w + pattern.col) / (w + 1);
            existing.module_size = (existing.module_size * w + pattern.module_size) / (w + 1);
            existing.hits += 1;
            return;
        }
    }
    if (count.* < buf.len) {
        buf[count.*] = pattern;
        count.* += 1;
    }
}

const FinderTriple = struct {
    top_left: FinderPattern,
    top_right: FinderPattern,
    bottom_left: FinderPattern,
};

/// Chooses the three patterns forming the best axis-aligned right angle with
/// consistent module sizes, and labels the corners.
fn pickFinderTriple(finders: []const FinderPattern) ?FinderTriple {
    var best_score: f32 = std.math.floatMax(f32);
    var best: ?FinderTriple = null;
    for (finders, 0..) |a, i| {
        for (finders[i + 1 ..], i + 1..) |b, j| {
            for (finders[j + 1 ..]) |c| {
                const triple = labelCorners(a, b, c) orelse continue;
                const ms = (a.module_size + b.module_size + c.module_size) / 3;
                const ms_spread = @max(a.module_size, @max(b.module_size, c.module_size)) -
                    @min(a.module_size, @min(b.module_size, c.module_size));
                const width = @abs(triple.top_right.col - triple.top_left.col);
                const height = @abs(triple.bottom_left.row - triple.top_left.row);
                if (width < 10 * ms or height < 10 * ms) continue;
                const score = ms_spread / ms + @abs(width - height) / @max(width, height);
                if (score < best_score) {
                    best_score = score;
                    best = triple;
                }
            }
        }
    }
    return best;
}

/// Labels three finder centers assuming an axis-aligned symbol in any of the
/// four rotations: two centers share a row, two share a column.
fn labelCorners(a: FinderPattern, b: FinderPattern, c: FinderPattern) ?FinderTriple {
    const patterns = [3]FinderPattern{ a, b, c };
    const ms = (a.module_size + b.module_size + c.module_size) / 3;
    // The corner pattern is the one aligned with both others.
    for (patterns, 0..) |corner, i| {
        const other1 = patterns[(i + 1) % 3];
        const other2 = patterns[(i + 2) % 3];
        for ([2][2]FinderPattern{ .{ other1, other2 }, .{ other2, other1 } }) |pair| {
            const row_mate = pair[0]; // shares the corner's row
            const col_mate = pair[1]; // shares the corner's column
            if (@abs(row_mate.row - corner.row) < 3 * ms and
                @abs(col_mate.col - corner.col) < 3 * ms)
            {
                return .{ .top_left = corner, .top_right = row_mate, .bottom_left = col_mate };
            }
        }
    }
    return null;
}

/// Samples the module grid implied by the finder triple and decodes it,
/// retrying neighboring versions when the timing pattern disagrees.
fn sampleAndDecode(allocator: Allocator, binary: Image(u8), triple: FinderTriple) !DecodeResult {
    const width = @abs(triple.top_right.col - triple.top_left.col);
    const height = @abs(triple.bottom_left.row - triple.top_left.row);
    const ms_finder = (triple.top_left.module_size + triple.top_right.module_size +
        triple.bottom_left.module_size) / 3;
    const side = (width + height) / 2;
    const dim_est = side / ms_finder + 7;

    // Snap to the nearest valid dimension (17 + 4 * version).
    var version_est: i32 = @intFromFloat(@round((dim_est - 17) / 4));
    version_est = std.math.clamp(version_est, tables.min_version, tables.max_version);

    var last_err: anyerror = error.InvalidFormat;
    for ([_]i32{ 0, -1, 1 }) |delta| {
        const version_try = version_est + delta;
        if (version_try < tables.min_version or version_try > tables.max_version) continue;
        const version: u8 = @intCast(version_try);
        const dim = tables.dimension(version);

        const modules = try allocator.alloc(u8, @as(usize, dim) * dim);
        defer allocator.free(modules);
        if (!sampleGrid(binary, triple, dim, modules)) continue;
        if (decodeModules(allocator, version, modules)) |result| {
            return result;
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            last_err = err;
        }
    }
    return last_err;
}

/// Reads module centers on an axis-aligned grid anchored at the finder
/// centers. Returns false if the timing patterns don't alternate plausibly.
fn sampleGrid(binary: Image(u8), triple: FinderTriple, dim: u16, out: []u8) bool {
    const span: f32 = @floatFromInt(dim - 7); // between finder centers
    const left = @min(triple.top_left.col, triple.top_right.col);
    const top = @min(triple.top_left.row, triple.bottom_left.row);
    const ms_col = @abs(triple.top_right.col - triple.top_left.col) / span;
    const ms_row = @abs(triple.bottom_left.row - triple.top_left.row) / span;
    const origin_col = left - 3.5 * ms_col;
    const origin_row = top - 3.5 * ms_row;

    for (0..dim) |row| {
        const y = origin_row + (@as(f32, @floatFromInt(row)) + 0.5) * ms_row;
        if (y < 0) return false;
        const py: usize = @intFromFloat(y);
        if (py >= binary.rows) return false;
        for (0..dim) |col| {
            const x = origin_col + (@as(f32, @floatFromInt(col)) + 0.5) * ms_col;
            if (x < 0) return false;
            const px: usize = @intFromFloat(x);
            if (px >= binary.cols) return false;
            out[row * dim + col] = @intFromBool(isDark(binary, py, px));
        }
    }

    // Timing pattern check. Depending on the symbol's orientation the two
    // timing lines land on row 6 or dim-7 and column 6 or dim-7; alternation
    // parity is preserved either way because dim is odd.
    var row_ok = [2]bool{ true, true };
    var col_ok = [2]bool{ true, true };
    const lines = [2]usize{ 6, dim - 7 };
    for (8..dim - 8) |i| {
        const expected: u8 = @intFromBool(i % 2 == 0);
        for (lines, 0..) |line, which| {
            if (out[line * dim + i] != expected) row_ok[which] = false;
            if (out[i * dim + line] != expected) col_ok[which] = false;
        }
    }
    return (row_ok[0] or row_ok[1]) and (col_ok[0] or col_ok[1]);
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

                var m = try encoder.encode(allocator, data, .{ .ec_level = level, .version = version });
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
    var m = try encoder.encode(allocator, "DAMAGE RESISTANCE TEST 123", .{
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
    var m = try encoder.encode(allocator, "FORMAT DAMAGE", .{ .ec_level = .high });
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
    var m = try encoder.encode(allocator, "ORIENTATION", .{});
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

test "image roundtrip across module sizes and quiet zones" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { module_size: u32, quiet_zone: u32 }{
        .{ .module_size = 1, .quiet_zone = 4 },
        .{ .module_size = 3, .quiet_zone = 4 },
        .{ .module_size = 8, .quiet_zone = 0 },
    };
    for (cases) |c| {
        var image = try encoder.encodeImage(allocator, "https://github.com/arrufat/zignal", .{
            .module_size = c.module_size,
            .quiet_zone = c.quiet_zone,
        });
        defer image.deinit(allocator);
        var result = (try decode(allocator, image)) orelse return error.TestUnexpectedResult;
        defer result.deinit(allocator);
        try std.testing.expectEqualSlices(u8, "https://github.com/arrufat/zignal", result.data);
    }
}

test "decode returns null on blank and noise images" {
    const allocator = std.testing.allocator;
    var blank = try Image(u8).init(allocator, 64, 64);
    defer blank.deinit(allocator);
    blank.fill(255);
    try std.testing.expectEqual(@as(?DecodeResult, null), try decode(allocator, blank));

    var prng: std.Random.DefaultPrng = .init(1);
    prng.random().bytes(blank.data);
    if (try decode(allocator, blank)) |result| {
        var r = result;
        r.deinit(allocator);
        return error.TestUnexpectedResult;
    }
}

//! Sliding-window box blur and unsharp sharpen with O(1) cost per pixel.
//!
//! Replaces the previous summed-area-table approach for these two filters: exact
//! u32/f64 column sums avoid the f32 SAT's precision loss on large images, and the
//! working state is one row of column sums instead of full-image float planes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const channel_ops = @import("channel_ops.zig");
const meta = @import("../meta.zig");

const Mode = enum { blur, sharpen };

pub fn boxBlur(comptime T: type, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    try apply(T, .blur, image, out, allocator, radius);
}

/// Unsharp sharpen: `2 * original - box_blur(original)`, saturating.
pub fn sharpen(comptime T: type, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    try apply(T, .sharpen, image, out, allocator, radius);
}

fn apply(comptime T: type, comptime mode: Mode, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    if (image.rows == 0 or image.cols == 0) return;
    if (radius == 0) {
        image.copy(out);
        return;
    }

    switch (@typeInfo(T)) {
        .int, .float => {
            if (out.data.ptr == image.data.ptr) {
                var temp = try Image(T).initLike(allocator, image);
                defer temp.deinit(allocator);
                try plane(T, mode, image, temp, allocator, radius);
                temp.copy(out);
            } else {
                try plane(T, mode, image, out, allocator, radius);
            }
        },
        .@"struct" => {
            if (comptime meta.allFieldsAreU8(T)) {
                // All channels share the same pixel window, so the filter runs directly
                // on the interleaved bytes — no channel split/merge passes.
                if (out.data.ptr == image.data.ptr) {
                    var temp = try Image(T).initLike(allocator, image);
                    defer temp.deinit(allocator);
                    try interleavedU8(T, mode, image, temp, allocator, radius);
                    temp.copy(out);
                } else {
                    try interleavedU8(T, mode, image, out, allocator, radius);
                }
            } else {
                const num_channels = comptime Image(T).channels();
                const planes = try channel_ops.splitChannels(T, image, allocator);
                defer inline for (planes) |p| allocator.free(p);
                const P = std.meta.Child(@TypeOf(planes[0]));

                const plane_size = @as(usize, image.rows) * image.cols;
                var dst_planes: [num_channels][]P = undefined;
                var allocated: usize = 0;
                defer for (dst_planes[0..allocated]) |p| allocator.free(p);
                inline for (&dst_planes) |*p| {
                    p.* = try allocator.alloc(P, plane_size);
                    allocated += 1;
                }

                inline for (planes, dst_planes) |src_data, dst_data| {
                    const src_plane = Image(P).initFromSlice(image.rows, image.cols, src_data);
                    const dst_plane = Image(P).initFromSlice(image.rows, image.cols, dst_data);
                    try plane(P, mode, src_plane, dst_plane, allocator, radius);
                }

                var final: [num_channels][]const P = undefined;
                inline for (&final, dst_planes) |*f, d| f.* = d;
                channel_ops.mergeChannels(T, final, out);
            }
        },
        else => @compileError("boxBlur/sharpen do not support " ++ @typeName(T)),
    }
}

/// One scalar plane. Column sums slide down the rows; a horizontal running sum
/// slides across each row. Borders use the clamped window renormalized by its
/// actual area (same geometry as the previous implementation); the division is
/// two reciprocal multiplies since heights are row-invariant and widths are
/// column-invariant.
fn plane(comptime P: type, comptime mode: Mode, src: Image(P), dst: Image(P), allocator: Allocator, radius: usize) !void {
    if (P != u8 and P != f32) @compileError("box filters support u8 and f32 planes");
    const rows: usize = src.rows;
    const cols: usize = src.cols;
    const SumT = if (P == u8) u32 else f64;
    const InvT = if (P == u8) f32 else f64;

    const col_sums = try allocator.alloc(SumT, cols);
    defer allocator.free(col_sums);
    @memset(col_sums, 0);

    const inv_widths = try allocator.alloc(InvT, cols);
    defer allocator.free(inv_widths);
    for (inv_widths, 0..) |*w, c| {
        const c2 = @min(c + radius, cols - 1);
        w.* = 1.0 / @as(InvT, @floatFromInt(c2 - (c -| radius) + 1));
    }

    for (0..@min(radius + 1, rows)) |rr| {
        const row = src.data[rr * src.stride ..][0..cols];
        for (col_sums, row) |*s, v| s.* += v;
    }

    for (0..rows) |r| {
        if (r > 0) {
            if (r + radius < rows) {
                const row = src.data[(r + radius) * src.stride ..][0..cols];
                for (col_sums, row) |*s, v| s.* += v;
            }
            if (r >= radius + 1) {
                const row = src.data[(r - radius - 1) * src.stride ..][0..cols];
                for (col_sums, row) |*s, v| s.* -= v;
            }
        }

        const r2 = @min(r + radius, rows - 1);
        const height = r2 - (r -| radius) + 1;
        const inv_h = 1.0 / @as(InvT, @floatFromInt(height));

        const src_row = src.data[r * src.stride ..][0..cols];
        const dst_row = dst.data[r * dst.stride ..][0..cols];

        var hsum: SumT = 0;
        for (col_sums[0..@min(radius + 1, cols)]) |v| hsum += v;

        var c: usize = 0;
        while (c < @min(radius, cols)) : (c += 1) {
            emitAndSlide(P, mode, src_row, dst_row, col_sums, inv_widths, inv_h, radius, c, &hsum);
        }

        // Interior columns have a full window: the serial running sum vectorizes as an
        // exclusive prefix sum of window deltas (exact integers, so results are identical
        // to the scalar loop). u8 only; f32 planes stay scalar in f64.
        if (P == u8 and cols > 2 * radius) {
            const vec_len = std.simd.suggestVectorLength(i32) orelse 1;
            const inv_area: f32 = inv_h * inv_widths[@min(radius, cols - 1)];

            // The last slide delta reads col_sums[c + vec_len + radius], hence the bound.
            while (c + vec_len + radius + 1 <= cols) : (c += vec_len) {
                const hi: @Vector(vec_len, i32) = @intCast(@as(@Vector(vec_len, u32), col_sums[c + radius + 1 ..][0..vec_len].*));
                const lo: @Vector(vec_len, i32) = @intCast(@as(@Vector(vec_len, u32), col_sums[c - radius ..][0..vec_len].*));
                var deltas = hi - lo;
                // Inclusive prefix sum in log2 steps.
                deltas += std.simd.shiftElementsRight(deltas, 1, 0);
                deltas += std.simd.shiftElementsRight(deltas, 2, 0);
                if (vec_len >= 8) deltas += std.simd.shiftElementsRight(deltas, 4, 0);
                if (vec_len >= 16) deltas += std.simd.shiftElementsRight(deltas, 8, 0);

                const base: i32 = @intCast(hsum);
                const hsums = @as(@Vector(vec_len, i32), @splat(base)) + std.simd.shiftElementsRight(deltas, 1, 0);
                const blurred = @as(@Vector(vec_len, f32), @floatFromInt(hsums)) * @as(@Vector(vec_len, f32), @splat(inv_area));

                const value = switch (mode) {
                    .blur => blurred,
                    .sharpen => blk: {
                        const orig: @Vector(vec_len, u8) = src_row[c..][0..vec_len].*;
                        const orig_f: @Vector(vec_len, f32) = @floatFromInt(orig);
                        break :blk orig_f + orig_f - blurred;
                    },
                };
                const zero: @Vector(vec_len, f32) = @splat(0);
                const max: @Vector(vec_len, f32) = @splat(255);
                const rounded: @Vector(vec_len, u8) = @round(@max(zero, @min(max, value)));
                dst_row[c..][0..vec_len].* = rounded;

                hsum = @intCast(base + deltas[vec_len - 1]);
            }
        }

        while (c < cols) : (c += 1) {
            emitAndSlide(P, mode, src_row, dst_row, col_sums, inv_widths, inv_h, radius, c, &hsum);
        }
    }
}

inline fn emitAndSlide(
    comptime P: type,
    comptime mode: Mode,
    src_row: []const P,
    dst_row: []P,
    col_sums: []const (if (P == u8) u32 else f64),
    inv_widths: []const (if (P == u8) f32 else f64),
    inv_h: if (P == u8) f32 else f64,
    radius: usize,
    c: usize,
    hsum: *(if (P == u8) u32 else f64),
) void {
    const hsum_f: @TypeOf(inv_h) = if (P == u8) @floatFromInt(hsum.*) else hsum.*;
    const blurred = hsum_f * inv_h * inv_widths[c];
    dst_row[c] = storeResult(P, mode, src_row[c], blurred);
    if (c + radius + 1 < dst_row.len) hsum.* += col_sums[c + radius + 1];
    if (c >= radius) hsum.* -= col_sums[c - radius];
}

/// Interleaved struct-of-u8 path: element-space column sums slide down the rows, and one
/// N-lane vector window sum slides across each row (all channels of a pixel at once).
/// Segmentation mirrors `plane` exactly — one reciprocal multiply where its SIMD interior
/// ran, two elsewhere — so outputs match the plane-split path bit for bit.
fn interleavedU8(comptime T: type, comptime mode: Mode, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    const n = comptime Image(T).channels();
    const rows: usize = image.rows;
    const cols: usize = image.cols;
    const width_e = cols * n;
    const Lane = @Vector(n, u32);

    const col_sums = try allocator.alloc(u32, width_e);
    defer allocator.free(col_sums);
    @memset(col_sums, 0);

    const inv_widths = try allocator.alloc(f32, cols);
    defer allocator.free(inv_widths);
    for (inv_widths, 0..) |*w, c| {
        const c2 = @min(c + radius, cols - 1);
        w.* = 1.0 / @as(f32, @floatFromInt(c2 - (c -| radius) + 1));
    }

    for (0..@min(radius + 1, rows)) |rr| {
        const row = std.mem.sliceAsBytes(image.data[rr * image.stride ..][0..cols]);
        for (col_sums, row) |*s, v| s.* += v;
    }

    // Element-space block: px_block pixels = B lanes. px_block matches `plane`'s SIMD
    // width so both paths run one-multiply rounding over the exact same pixel range.
    const px_block = std.simd.suggestVectorLength(i32) orelse 1;
    const B = px_block * n;
    const repeat_mask = comptime blk: {
        var m: [B]i32 = undefined;
        for (&m, 0..) |*e, j| e.* = @intCast(j % n);
        break :blk m;
    };
    const tail_mask = comptime blk: {
        var m: [n]i32 = undefined;
        for (&m, 0..) |*e, t| e.* = @intCast(B - n + t);
        break :blk m;
    };

    for (0..rows) |r| {
        if (r > 0) {
            if (r + radius < rows) {
                const row = std.mem.sliceAsBytes(image.data[(r + radius) * image.stride ..][0..cols]);
                for (col_sums, row) |*s, v| s.* += v;
            }
            if (r >= radius + 1) {
                const row = std.mem.sliceAsBytes(image.data[(r - radius - 1) * image.stride ..][0..cols]);
                for (col_sums, row) |*s, v| s.* -= v;
            }
        }

        const r2 = @min(r + radius, rows - 1);
        const height = r2 - (r -| radius) + 1;
        const inv_h = 1.0 / @as(f32, @floatFromInt(height));
        const inv_area: f32 = inv_h * inv_widths[@min(radius, cols - 1)];

        const src_row = std.mem.sliceAsBytes(image.data[r * image.stride ..][0..cols]);
        const dst_row = std.mem.sliceAsBytes(out.data[r * out.stride ..][0..cols]);

        var hsum: Lane = @splat(0);
        for (0..@min(radius + 1, cols)) |p| {
            hsum += @as(Lane, col_sums[p * n ..][0..n].*);
        }

        var c: usize = 0;
        while (c < @min(radius, cols)) : (c += 1) {
            emitPixel(n, mode, src_row, dst_row, inv_h, inv_widths[c], hsum, c);
            slidePixel(n, col_sums, cols, radius, c, &hsum);
        }

        if (cols > 2 * radius) {
            // Interior blocks: per-channel window sums follow a stride-n prefix sum of
            // window deltas (exact integers -> bit-identical to the pixel loop).
            while (c + px_block + radius + 1 <= cols) : (c += px_block) {
                const hi: @Vector(B, i32) = @intCast(@as(@Vector(B, u32), col_sums[(c + radius + 1) * n ..][0..B].*));
                const lo: @Vector(B, i32) = @intCast(@as(@Vector(B, u32), col_sums[(c - radius) * n ..][0..B].*));
                var deltas = hi - lo;
                comptime var step = n;
                inline while (step < B) : (step *= 2) {
                    deltas += std.simd.shiftElementsRight(deltas, step, 0);
                }

                const base_small: @Vector(n, i32) = @intCast(hsum);
                const base = @shuffle(i32, base_small, undefined, repeat_mask);
                const wsums = base + std.simd.shiftElementsRight(deltas, n, 0);
                const blurred = @as(@Vector(B, f32), @floatFromInt(wsums)) * @as(@Vector(B, f32), @splat(inv_area));

                const value = switch (mode) {
                    .blur => blurred,
                    .sharpen => blk: {
                        const orig: @Vector(B, u8) = src_row[c * n ..][0..B].*;
                        const orig_f: @Vector(B, f32) = @floatFromInt(orig);
                        break :blk orig_f + orig_f - blurred;
                    },
                };
                const zero: @Vector(B, f32) = @splat(0);
                const max: @Vector(B, f32) = @splat(255);
                const rounded: @Vector(B, u8) = @round(@max(zero, @min(max, value)));
                dst_row[c * n ..][0..B].* = rounded;

                hsum = @intCast(base_small + @shuffle(i32, deltas, undefined, tail_mask));
            }
        }

        while (c < cols) : (c += 1) {
            emitPixel(n, mode, src_row, dst_row, inv_h, inv_widths[c], hsum, c);
            slidePixel(n, col_sums, cols, radius, c, &hsum);
        }
    }
}

inline fn emitPixel(comptime n: usize, comptime mode: Mode, src_row: []const u8, dst_row: []u8, inv_h: f32, inv_w: f32, hsum: @Vector(n, u32), c: usize) void {
    const hf: @Vector(n, f32) = @floatFromInt(hsum);
    // Two multiplies on the value, matching the scalar plane path's border rounding.
    const blurred = hf * @as(@Vector(n, f32), @splat(inv_h)) * @as(@Vector(n, f32), @splat(inv_w));
    const value = switch (mode) {
        .blur => blurred,
        .sharpen => blk: {
            const orig: @Vector(n, u8) = src_row[c * n ..][0..n].*;
            const orig_f: @Vector(n, f32) = @floatFromInt(orig);
            break :blk orig_f + orig_f - blurred;
        },
    };
    const zero: @Vector(n, f32) = @splat(0);
    const max: @Vector(n, f32) = @splat(255);
    const rounded: @Vector(n, u8) = @round(@max(zero, @min(max, value)));
    dst_row[c * n ..][0..n].* = rounded;
}

inline fn slidePixel(comptime n: usize, col_sums: []const u32, cols: usize, radius: usize, c: usize, hsum: *@Vector(n, u32)) void {
    if (c + radius + 1 < cols) hsum.* += @as(@Vector(n, u32), col_sums[(c + radius + 1) * n ..][0..n].*);
    if (c >= radius) hsum.* -= @as(@Vector(n, u32), col_sums[(c - radius) * n ..][0..n].*);
}

inline fn storeResult(comptime P: type, comptime mode: Mode, orig: P, blurred: anytype) P {
    const F = @TypeOf(blurred);
    const value = switch (mode) {
        .blur => blurred,
        .sharpen => 2 * @as(F, orig) - blurred,
    };
    return if (P == u8)
        @round(std.math.clamp(value, 0, 255))
    else
        @floatCast(value);
}

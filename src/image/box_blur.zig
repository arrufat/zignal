//! Sliding-window box blur and unsharp sharpen with O(1) cost per pixel.
//!
//! Column sums (exact u32 for u8 planes, f64 for f32) slide down the image and a
//! running window sum slides across each row; the only working state is one row of
//! column sums, and borders use the clamped window renormalized by its actual area.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Image = @import("../image.zig").Image;
const channel_ops = @import("channel_ops.zig");
const meta = @import("../meta.zig");
const parallel = @import("../parallel.zig");

const Mode = enum { blur, sharpen };

pub fn boxBlur(comptime T: type, io: Io, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    try apply(T, .blur, io, image, out, allocator, radius);
}

/// Unsharp sharpen: `2 * original - box_blur(original)`, saturating.
pub fn sharpen(comptime T: type, io: Io, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    try apply(T, .sharpen, io, image, out, allocator, radius);
}

fn apply(comptime T: type, comptime mode: Mode, io: Io, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    if (image.rows == 0 or image.cols == 0) return;
    if (radius == 0) {
        image.copy(out);
        return;
    }

    // The sliding-window passes read source rows ahead of the write cursor, so
    // in-place calls run through a temp image.
    if (out.data.ptr == image.data.ptr) {
        var temp = try Image(T).initLike(allocator, image);
        defer temp.deinit(allocator);
        try applyInto(T, mode, io, image, temp, allocator, radius);
        temp.copy(out);
        return;
    }
    try applyInto(T, mode, io, image, out, allocator, radius);
}

fn applyInto(comptime T: type, comptime mode: Mode, io: Io, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    switch (@typeInfo(T)) {
        .int, .float => try plane(T, mode, io, image, out, allocator, radius),
        .@"struct" => {
            if (comptime meta.allFieldsAreU8(T)) {
                // All channels share the same pixel window, so the filter runs directly
                // on the interleaved bytes — no channel split/merge passes.
                try interleavedU8(T, mode, io, image, out, allocator, radius);
            } else {
                const num_channels = comptime Image(T).channels();
                const P = channel_ops.FieldTypeOf(T);
                const planes = try channel_ops.splitChannels(T, io, image, allocator);
                defer inline for (planes) |p| allocator.free(p);

                const plane_size = @as(usize, image.rows) * image.cols;
                const dst_planes = try channel_ops.allocPlanes(P, num_channels, allocator, plane_size);
                defer for (dst_planes) |p| allocator.free(p);

                inline for (planes, dst_planes) |src_data, dst_data| {
                    const src_plane = Image(P).initFromSlice(image.rows, image.cols, src_data);
                    const dst_plane = Image(P).initFromSlice(image.rows, image.cols, dst_data);
                    try plane(P, mode, io, src_plane, dst_plane, allocator, radius);
                }

                channel_ops.mergeChannels(T, io, dst_planes, out);
            }
        },
        else => @compileError("boxBlur/sharpen do not support " ++ @typeName(T)),
    }
}

/// Reciprocals of the clamped horizontal window widths (column-invariant across rows).
fn invWidthTable(comptime F: type, allocator: Allocator, cols: usize, radius: usize) ![]F {
    const inv_widths = try allocator.alloc(F, cols);
    for (inv_widths, 0..) |*w, c| {
        const c2 = @min(c + radius, cols - 1);
        w.* = 1.0 / @as(F, @floatFromInt(c2 - (c -| radius) + 1));
    }
    return inv_widths;
}

/// Clamp-round epilogue shared by every u8 emit site; `offset` is the element offset of
/// the pixel block in `src_row` (sharpen loads the original pixels from there).
inline fn finishU8(comptime len: usize, comptime mode: Mode, src_row: []const u8, offset: usize, blurred: @Vector(len, f32)) @Vector(len, u8) {
    const value = switch (mode) {
        .blur => blurred,
        .sharpen => blk: {
            const orig: @Vector(len, u8) = src_row[offset..][0..len].*;
            const orig_f: @Vector(len, f32) = @floatFromInt(orig);
            break :blk orig_f + orig_f - blurred;
        },
    };
    return meta.roundToBytes(value);
}

/// Accumulator type: exact u32 sums for u8 planes, f64 for f32.
fn SumT(comptime P: type) type {
    return if (P == u8) u32 else f64;
}

/// Reciprocal-multiply type.
fn InvT(comptime P: type) type {
    return if (P == u8) f32 else f64;
}

/// One scalar plane. Column sums slide down the rows; a horizontal running sum
/// slides across each row. The per-pixel division is two reciprocal multiplies,
/// since window heights are row-invariant and widths are column-invariant.
fn plane(comptime P: type, comptime mode: Mode, io: Io, src: Image(P), dst: Image(P), allocator: Allocator, radius: usize) !void {
    if (P != u8 and P != f32) @compileError("box filters support u8 and f32 planes");
    const rows: usize = src.rows;
    const cols: usize = src.cols;

    // Integer sums are exact, so bands seeded mid-image match one sweep; f32 planes (f64 sums) stay one band.
    // Each band re-seeds `2·radius + 1` rows, hence four windows tall.
    const bands = if (@typeInfo(SumT(P)) == .int) parallel.bandCountFor(rows, cols, 4 * (2 * radius + 1)) else 1;
    const ctx: BandContext(P, mode, false) = .{
        .src = src,
        .dst = dst,
        .radius = radius,
        .width = cols,
        .col_sums = try allocator.alloc(SumT(P), bands * cols),
        .inv_widths = try invWidthTable(InvT(P), allocator, cols, radius),
    };
    defer allocator.free(ctx.col_sums);
    defer allocator.free(ctx.inv_widths);
    parallel.forRowBands(io, rows, bands, &ctx, @TypeOf(ctx).rowBand);
}

/// Read-only state shared by the row bands; `width` is the element count of one row of
/// column sums (`cols`, or `cols * channels` when `interleaved`).
fn BandContext(comptime P: type, comptime mode: Mode, comptime interleaved: bool) type {
    return struct {
        src: Image(P),
        dst: Image(P),
        radius: usize,
        width: usize,
        col_sums: []if (interleaved) u32 else SumT(P),
        inv_widths: []const if (interleaved) f32 else InvT(P),

        fn rowBand(ctx: *const @This(), band: usize, r0: usize, r1: usize) void {
            const sums = ctx.col_sums[band * ctx.width ..][0..ctx.width];
            if (interleaved) {
                interleavedRows(P, mode, ctx.src, ctx.dst, sums, ctx.inv_widths, ctx.radius, r0, r1);
            } else {
                planeRows(P, mode, ctx.src, ctx.dst, sums, ctx.inv_widths, ctx.radius, r0, r1);
            }
        }
    };
}

/// Rows `[r_start, r_end)` of one plane; `col_sums` is seeded for `r_start` here.
fn planeRows(comptime P: type, comptime mode: Mode, src: Image(P), dst: Image(P), col_sums: []SumT(P), inv_widths: []const InvT(P), radius: usize, r_start: usize, r_end: usize) void {
    const rows: usize = src.rows;
    const cols: usize = src.cols;

    @memset(col_sums, 0);
    for (r_start -| radius..@min(r_start + radius + 1, rows)) |rr| {
        const row = src.data[rr * src.stride ..][0..cols];
        for (col_sums, row) |*s, v| s.* += v;
    }

    for (r_start..r_end) |r| {
        if (r > r_start) {
            const has_add = r + radius < rows;
            const has_sub = r >= radius + 1;
            if (has_add and has_sub) {
                // One fused pass; add-then-subtract order keeps the sums bit-identical.
                const add_row = src.data[(r + radius) * src.stride ..][0..cols];
                const sub_row = src.data[(r - radius - 1) * src.stride ..][0..cols];
                for (col_sums, add_row, sub_row) |*s, a, b| s.* = s.* + a - b;
            } else if (has_add) {
                const row = src.data[(r + radius) * src.stride ..][0..cols];
                for (col_sums, row) |*s, v| s.* += v;
            } else if (has_sub) {
                const row = src.data[(r - radius - 1) * src.stride ..][0..cols];
                for (col_sums, row) |*s, v| s.* -= v;
            }
        }

        const r2 = @min(r + radius, rows - 1);
        const height = r2 - (r -| radius) + 1;
        const inv_h = 1.0 / @as(InvT(P), @floatFromInt(height));

        const src_row = src.data[r * src.stride ..][0..cols];
        const dst_row = dst.data[r * dst.stride ..][0..cols];

        var hsum: SumT(P) = 0;
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
                const deltas = std.simd.prefixScan(.Add, 1, hi - lo);
                const base: i32 = @intCast(hsum);
                const hsums = @as(@Vector(vec_len, i32), @splat(base)) + std.simd.shiftElementsRight(deltas, 1, 0);
                const blurred = @as(@Vector(vec_len, f32), @floatFromInt(hsums)) * @as(@Vector(vec_len, f32), @splat(inv_area));
                dst_row[c..][0..vec_len].* = finishU8(vec_len, mode, src_row, c, blurred);

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
    col_sums: []const SumT(P),
    inv_widths: []const InvT(P),
    inv_h: InvT(P),
    radius: usize,
    c: usize,
    hsum: *SumT(P),
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
fn interleavedU8(comptime T: type, comptime mode: Mode, io: Io, image: Image(T), out: Image(T), allocator: Allocator, radius: usize) !void {
    const width_e = @as(usize, image.cols) * comptime Image(T).channels();
    const bands = parallel.bandCountFor(image.rows, image.cols, 4 * (2 * radius + 1));
    const ctx: BandContext(T, mode, true) = .{
        .src = image,
        .dst = out,
        .radius = radius,
        .width = width_e,
        .col_sums = try allocator.alloc(u32, bands * width_e),
        .inv_widths = try invWidthTable(f32, allocator, image.cols, radius),
    };
    defer allocator.free(ctx.col_sums);
    defer allocator.free(ctx.inv_widths);
    parallel.forRowBands(io, image.rows, bands, &ctx, @TypeOf(ctx).rowBand);
}

/// Rows `[r_start, r_end)` of the interleaved path; `col_sums` is seeded for `r_start` here.
fn interleavedRows(comptime T: type, comptime mode: Mode, image: Image(T), out: Image(T), col_sums: []u32, inv_widths: []const f32, radius: usize, r_start: usize, r_end: usize) void {
    const n = comptime Image(T).channels();
    const rows: usize = image.rows;
    const cols: usize = image.cols;
    const Lane = @Vector(n, u32);

    @memset(col_sums, 0);
    for (r_start -| radius..@min(r_start + radius + 1, rows)) |rr| {
        const row = std.mem.sliceAsBytes(image.data[rr * image.stride ..][0..cols]);
        for (col_sums, row) |*s, v| s.* += v;
    }

    // Element-space block: px_block pixels = B lanes. px_block matches `plane`'s SIMD
    // width so both paths run one-multiply rounding over the exact same pixel range.
    const px_block = std.simd.suggestVectorLength(i32) orelse 1;
    const B = px_block * n;
    const repeat_mask = meta.StrideMasks(B, n).repeat;
    const tail_mask = meta.StrideMasks(B, n).tail;

    for (r_start..r_end) |r| {
        if (r > r_start) {
            const has_add = r + radius < rows;
            const has_sub = r >= radius + 1;
            if (has_add and has_sub) {
                // One fused pass; add-then-subtract order keeps the sums bit-identical.
                const add_row = std.mem.sliceAsBytes(image.data[(r + radius) * image.stride ..][0..cols]);
                const sub_row = std.mem.sliceAsBytes(image.data[(r - radius - 1) * image.stride ..][0..cols]);
                for (col_sums, add_row, sub_row) |*s, a, b| s.* = s.* + a - b;
            } else if (has_add) {
                const row = std.mem.sliceAsBytes(image.data[(r + radius) * image.stride ..][0..cols]);
                for (col_sums, row) |*s, v| s.* += v;
            } else if (has_sub) {
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
                const deltas = std.simd.prefixScan(.Add, n, hi - lo);
                const base_small: @Vector(n, i32) = @intCast(hsum);
                const base = @shuffle(i32, base_small, undefined, repeat_mask);
                const wsums = base + std.simd.shiftElementsRight(deltas, n, 0);
                const blurred = @as(@Vector(B, f32), @floatFromInt(wsums)) * @as(@Vector(B, f32), @splat(inv_area));
                dst_row[c * n ..][0..B].* = finishU8(B, mode, src_row, c * n, blurred);

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
    dst_row[c * n ..][0..n].* = finishU8(n, mode, src_row, c * n, blurred);
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
    return if (P == u8) meta.clamp(u8, value) else @floatCast(value);
}

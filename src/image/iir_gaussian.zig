//! Recursive (IIR) Gaussian blur: Young & van Vliet's third-order filter run forward and
//! backward along each axis, so the cost per pixel does not depend on sigma. Borders are
//! replicated: the recursion starts from the edge value's steady state, and the backward
//! pass is primed over a replicated tail so its state has converged when it re-enters the
//! image. Within a few 8-bit units of the exact kernel from `min_sigma` up (0.25 mean from
//! sigma 2); meant for large sigma.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const BorderMode = @import("border.zig").BorderMode;
const convolution = @import("convolution.zig");
const parallel = @import("parallel.zig");

/// Below this the fit is visibly off the exact kernel (mean error ~2 units at sigma 0.5).
pub const min_sigma: f32 = 1;
/// Measured crossover: from here the recursive filter is faster than the exact kernel on a
/// multi-core pool (and ~2x faster on one core).
pub const auto_sigma: f32 = 4;

const vec_len = std.simd.suggestVectorLength(f32) orelse 4;
/// Lanes per loop: a recursion is a latency chain, so two vectors' worth of independent
/// lanes keep two chains in flight.
const lanes = 2 * vec_len;

/// y[n] = b·x[n] + a1·y[n-1] + a2·y[n-2] + a3·y[n-3], one pass per direction.
pub const Coefficients = struct {
    b: f32,
    a1: f32,
    a2: f32,
    a3: f32,
    /// Replicated samples the forward recursion runs past the far edge before the backward
    /// pass starts; the poles have decayed by then.
    pad: usize,

    /// Young & van Vliet (1995) fit; valid for `sigma >= 0.5`.
    pub fn init(sigma: f32) Coefficients {
        std.debug.assert(sigma >= 0.5);
        const q: f32 = if (sigma >= 2.5) 0.98711 * sigma - 0.96330 else 3.97156 - 4.14554 * @sqrt(1 - 0.26891 * sigma);
        const q2 = q * q;
        const q3 = q2 * q;
        const b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3;
        const a1 = (2.44413 * q + 2.85619 * q2 + 1.26661 * q3) / b0;
        const a2 = -(1.4281 * q2 + 1.26661 * q3) / b0;
        const a3 = 0.422205 * q3 / b0;
        const tail: usize = @ceil(6 * sigma);
        return .{ .b = 1 - (a1 + a2 + a3), .a1 = a1, .a2 = a2, .a3 = a3, .pad = tail + 8 };
    }
};

/// Blurs `src` into `dst` (same shape, distinct buffers) for u8, f32 and struct-of-u8 pixels.
pub fn blur(comptime T: type, io: Io, src: Image(T), dst: Image(T), allocator: Allocator, sigma: f32) !void {
    const coeffs: Coefficients = .init(sigma);
    switch (T) {
        u8, f32 => try blurPlane(T, io, src, dst, allocator, coeffs, null),
        else => {
            const PlaneCtx = struct {
                allocator: Allocator,
                coeffs: Coefficients,
                temp: []f32 = &.{},

                pub fn convolvePlane(ctx: *@This(), plane_io: Io, plane_src: Image(u8), plane_dst: Image(u8), _: BorderMode) !void {
                    try blurPlane(u8, plane_io, plane_src, plane_dst, ctx.allocator, ctx.coeffs, &ctx.temp);
                }
            };
            var ctx: PlaneCtx = .{ .allocator = allocator, .coeffs = coeffs };
            defer allocator.free(ctx.temp);
            // Unit kernel sum: uniform channels pass straight through the plane split.
            try convolution.convolvePlanes(T, io, src, dst, allocator, 1, 1, .replicate, &ctx);
        },
    }
}

/// Rows into an f32 temp plane, then columns from the temp plane into `dst`. f32 planes use
/// `dst` itself as the temp; `cached_temp` lets struct-pixel callers share one across planes.
fn blurPlane(comptime T: type, io: Io, src: Image(T), dst: Image(T), allocator: Allocator, coeffs: Coefficients, cached_temp: ?*[]f32) !void {
    const rows: usize = src.rows;
    const cols: usize = src.cols;
    if (rows == 0 or cols == 0) return;

    var owned: []f32 = &.{};
    defer allocator.free(owned);
    const temp: Image(f32) = if (T == f32) dst else blk: {
        const slot = cached_temp orelse &owned;
        if (slot.len == 0) slot.* = try allocator.alloc(f32, rows * cols);
        break :blk .initFromSlice(src.rows, src.cols, slot.*);
    };

    // Column tiles of `lanes` columns are the unit of vertical work.
    const tiles = (cols + lanes - 1) / lanes;
    const row_bands = parallel.bandCount(rows, cols);
    const col_bands = parallel.bandCount(tiles, rows * lanes);
    const ctx: Pass(T) = .{
        .src = src,
        .temp = temp,
        .dst = dst,
        .coeffs = coeffs,
        .pads = try allocator.alloc(f32, @max(row_bands, col_bands) * coeffs.pad * lanes),
    };
    defer allocator.free(ctx.pads);
    parallel.forRowBands(io, rows, row_bands, &ctx, Pass(T).rowBand);
    parallel.forRowBands(io, tiles, col_bands, &ctx, Pass(T).columnBand);
}

fn Pass(comptime T: type) type {
    return struct {
        src: Image(T),
        temp: Image(f32),
        dst: Image(T),
        coeffs: Coefficients,
        /// `pad * lanes` floats per band.
        pads: []f32,

        fn bandPad(ctx: *const @This(), band: usize, comptime width: usize) []f32 {
            return ctx.pads[band * ctx.coeffs.pad * lanes ..][0 .. ctx.coeffs.pad * width];
        }

        fn rowBand(ctx: *const @This(), band: usize, r0: usize, r1: usize) void {
            var r = r0;
            while (r + lanes <= r1) : (r += lanes) {
                filterRowBlock(T, ctx.src, ctx.temp, r, ctx.coeffs, ctx.bandPad(band, lanes));
            }
            while (r < r1) : (r += 1) {
                filterLine(1, RowLanes(T, 1){ .src = ctx.src, .temp = ctx.temp, .r0 = r }, ctx.src.cols, ctx.coeffs, ctx.bandPad(band, 1));
            }
        }

        fn columnBand(ctx: *const @This(), band: usize, t0: usize, t1: usize) void {
            const cols = ctx.src.cols;
            for (t0..t1) |tile| {
                const c0 = tile * lanes;
                if (c0 + lanes <= cols) {
                    filterLine(lanes, ColumnLanes(T, lanes){ .temp = ctx.temp, .dst = ctx.dst, .c0 = c0 }, ctx.src.rows, ctx.coeffs, ctx.bandPad(band, lanes));
                } else {
                    for (c0..cols) |c| filterLine(1, ColumnLanes(T, 1){ .temp = ctx.temp, .dst = ctx.dst, .c0 = c }, ctx.src.rows, ctx.coeffs, ctx.bandPad(band, 1));
                }
            }
        }
    };
}

/// Third-order recursion state for `W` independent lanes.
fn Recursion(comptime W: usize) type {
    return struct {
        const V = @Vector(W, f32);

        b: V,
        a1: V,
        a2: V,
        a3: V,
        y1: V,
        y2: V,
        y3: V,

        fn init(c: Coefficients, steady: V) @This() {
            return .{ .b = @splat(c.b), .a1 = @splat(c.a1), .a2 = @splat(c.a2), .a3 = @splat(c.a3), .y1 = steady, .y2 = steady, .y3 = steady };
        }

        inline fn step(s: *@This(), x: V) V {
            const y = s.b * x + s.a1 * s.y1 + s.a2 * s.y2 + s.a3 * s.y3;
            s.y3 = s.y2;
            s.y2 = s.y1;
            s.y1 = y;
            return y;
        }

        /// Runs the forward recursion over `pad` copies of `last`, then primes the backward
        /// recursion over them from its steady state (b = 1 - a1 - a2 - a3, so a converged
        /// forward output is also the backward fixed point).
        fn turnAround(s: *@This(), last: V, pad: []f32) void {
            const n = pad.len / W;
            for (0..n) |k| pad[k * W ..][0..W].* = s.step(last);
            s.y2 = s.y1;
            s.y3 = s.y1;
            var k = n;
            while (k > 0) {
                k -= 1;
                _ = s.step(pad[k * W ..][0..W].*);
            }
        }
    };
}

/// One line of `len` samples through the forward and backward passes. `acc` provides the
/// source loads, the intermediate (forward) stores and loads, and the final stores.
fn filterLine(comptime W: usize, acc: anytype, len: usize, c: Coefficients, pad: []f32) void {
    const first = acc.loadSrc(0);
    // Read before the forward pass in case the intermediate aliases the source.
    const last = acc.loadSrc(len - 1);
    var rec: Recursion(W) = .init(c, first);
    for (0..len) |i| acc.storeMid(i, rec.step(acc.loadSrc(i)));
    rec.turnAround(last, pad);
    var i = len;
    while (i > 0) {
        i -= 1;
        acc.storeDst(i, rec.step(acc.loadMid(i)));
    }
}

/// `lanes` consecutive rows from `r0` through both passes. Columns go `lanes` at a time: a
/// square block is loaded as row vectors, transposed in registers so each vector holds one
/// column across the rows, stepped, and transposed back for row stores. The last partial
/// block uses per-lane loads.
fn filterRowBlock(comptime T: type, src: Image(T), temp: Image(f32), r0: usize, c: Coefficients, pad: []f32) void {
    const W = lanes;
    const V = @Vector(W, f32);
    const cols = src.cols;
    const full = cols / W * W;
    const tail = RowLanes(T, W){ .src = src, .temp = temp, .r0 = r0 };

    const first = tail.loadSrc(0);
    const last = tail.loadSrc(cols - 1);
    var rec: Recursion(W) = .init(c, first);

    var n0: usize = 0;
    while (n0 < full) : (n0 += W) {
        var block: [W]V = undefined;
        inline for (0..W) |i| block[i] = loadRowVec(T, W, src, r0 + i, n0);
        var by_col = transpose(W, block);
        inline for (0..W) |j| by_col[j] = rec.step(by_col[j]);
        const by_row = transpose(W, by_col);
        inline for (0..W) |i| temp.data[(r0 + i) * temp.stride + n0 ..][0..W].* = by_row[i];
    }
    for (full..cols) |n| tail.storeMid(n, rec.step(tail.loadSrc(n)));

    rec.turnAround(last, pad);

    var n = cols;
    while (n > full) {
        n -= 1;
        tail.storeDst(n, rec.step(tail.loadMid(n)));
    }
    n0 = full;
    while (n0 > 0) {
        n0 -= W;
        var block: [W]V = undefined;
        inline for (0..W) |i| block[i] = temp.data[(r0 + i) * temp.stride + n0 ..][0..W].*;
        var by_col = transpose(W, block);
        inline for (0..W) |jj| {
            const j = W - 1 - jj;
            by_col[j] = rec.step(by_col[j]);
        }
        const by_row = transpose(W, by_col);
        inline for (0..W) |i| temp.data[(r0 + i) * temp.stride + n0 ..][0..W].* = by_row[i];
    }
}

inline fn loadRowVec(comptime T: type, comptime W: usize, img: Image(T), row: usize, col: usize) @Vector(W, f32) {
    const v: @Vector(W, T) = img.data[row * img.stride + col ..][0..W].*;
    return if (T == f32) v else @floatFromInt(v);
}

/// In-register transpose of a `W`×`W` block (`W` a power of two): `log2(W)` rounds of
/// pairwise shuffles that swap `s`-wide sub-blocks between rows `i` and `i + s`.
fn transpose(comptime W: usize, m: [W]@Vector(W, f32)) [W]@Vector(W, f32) {
    comptime std.debug.assert(std.math.isPowerOfTwo(W));
    var rows = m;
    comptime var s: usize = 1;
    inline while (s < W) : (s *= 2) {
        const lo, const hi = comptime blockMasks(W, s);
        comptime var i: usize = 0;
        inline while (i < W) : (i += 1) {
            if (i & s == 0) {
                const a = rows[i];
                const b = rows[i + s];
                rows[i] = @shuffle(f32, a, b, lo);
                rows[i + s] = @shuffle(f32, a, b, hi);
            }
        }
    }
    return rows;
}

/// Shuffle masks for one transpose round: `lo` keeps the lower `s`-wide half of every `2s`
/// block from `a` and takes the corresponding half from `b`; `hi` does the upper halves.
fn blockMasks(comptime W: usize, comptime s: usize) struct { @Vector(W, i32), @Vector(W, i32) } {
    var lo: [W]i32 = undefined;
    var hi: [W]i32 = undefined;
    for (0..W) |k| {
        const block = k / (2 * s) * (2 * s);
        const t = k % (2 * s);
        if (t < s) {
            lo[k] = @intCast(block + t);
            hi[k] = @intCast(block + s + t);
        } else {
            lo[k] = ~@as(i32, @intCast(block + t - s));
            hi[k] = ~@as(i32, @intCast(block + t));
        }
    }
    return .{ lo, hi };
}

/// `W` consecutive rows from `r0` as lanes, indexed by column; intermediate and final stores
/// both land in `temp`.
fn RowLanes(comptime T: type, comptime W: usize) type {
    return struct {
        const V = @Vector(W, f32);
        src: Image(T),
        temp: Image(f32),
        r0: usize,

        inline fn gather(img: anytype, r0: usize, col: usize) V {
            var v: [W]f32 = undefined;
            inline for (0..W) |i| v[i] = img.data[(r0 + i) * img.stride + col];
            return v;
        }

        inline fn loadSrc(a: @This(), col: usize) V {
            return gather(a.src, a.r0, col);
        }

        inline fn loadMid(a: @This(), col: usize) V {
            return gather(a.temp, a.r0, col);
        }

        inline fn storeMid(a: @This(), col: usize, v: V) void {
            const arr: [W]f32 = v;
            inline for (0..W) |i| a.temp.data[(a.r0 + i) * a.temp.stride + col] = arr[i];
        }

        inline fn storeDst(a: @This(), col: usize, v: V) void {
            a.storeMid(col, v);
        }
    };
}

/// `W` adjacent columns from `c0`, indexed by row; the forward pass rewrites `temp` in place
/// and the backward pass stores into `dst`.
fn ColumnLanes(comptime T: type, comptime W: usize) type {
    return struct {
        const V = @Vector(W, f32);
        temp: Image(f32),
        dst: Image(T),
        c0: usize,

        inline fn loadSrc(a: @This(), row: usize) V {
            return a.temp.data[row * a.temp.stride + a.c0 ..][0..W].*;
        }

        inline fn loadMid(a: @This(), row: usize) V {
            return a.loadSrc(row);
        }

        inline fn storeMid(a: @This(), row: usize, v: V) void {
            a.temp.data[row * a.temp.stride + a.c0 ..][0..W].* = v;
        }

        inline fn storeDst(a: @This(), row: usize, v: V) void {
            const out = a.dst.data[row * a.dst.stride + a.c0 ..][0..W];
            if (T == f32) {
                out.* = v;
            } else {
                const zero: V = @splat(0);
                const max: V = @splat(255);
                const rounded: @Vector(W, u8) = @round(@max(zero, @min(max, v)));
                out.* = rounded;
            }
        }
    };
}

test "register transpose" {
    var m: [lanes]@Vector(lanes, f32) = undefined;
    for (&m, 0..) |*row, i| {
        var v: [lanes]f32 = undefined;
        for (&v, 0..) |*x, j| x.* = @floatFromInt(i * lanes + j);
        row.* = v;
    }
    const t = transpose(lanes, m);
    for (0..lanes) |i| {
        const row: [lanes]f32 = m[i];
        for (0..lanes) |j| {
            const col: [lanes]f32 = t[j];
            try std.testing.expectEqual(row[j], col[i]);
        }
    }
}

test "iir gaussian approximates the exact kernel" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const meta = @import("../meta.zig");
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();

    var src: Image(u8) = try .init(allocator, 180, 200);
    defer src.deinit(allocator);
    for (0..src.rows) |r| {
        for (0..src.cols) |c| {
            // Smooth ramp plus noise, so both the DC gain and the response shape are tested.
            const ramp: i32 = @intCast(60 + (r * 120) / src.rows + (c * 60) / src.cols);
            src.at(r, c).* = meta.clamp(u8, ramp + random.intRangeAtMost(i32, -40, 40));
        }
    }
    var exact: Image(u8) = try .initLike(allocator, src);
    defer exact.deinit(allocator);
    var approx: Image(u8) = try .initLike(allocator, src);
    defer approx.deinit(allocator);

    for ([_]f32{ 1, 2, 4, 8, 16 }) |sigma| {
        const kernel = try convolution.gaussianKernel(allocator, sigma);
        defer allocator.free(kernel);
        try convolution.convolveSeparable(u8, io, src, exact, allocator, kernel, kernel, .replicate);
        try blur(u8, io, src, approx, allocator, sigma);

        var max_err: u32 = 0;
        var sum_err: u64 = 0;
        for (exact.data, approx.data) |e, a| {
            const err: u32 = @abs(@as(i32, e) - @as(i32, a));
            max_err = @max(max_err, err);
            sum_err += err;
        }
        const mean_err = @as(f64, @floatFromInt(sum_err)) / @as(f64, @floatFromInt(exact.data.len));
        // The fit degrades below sigma 2 (sigma 1: max 5, mean 0.9 on this image).
        const limits: struct { max: u32, mean: f64 } = if (sigma < 2) .{ .max = 6, .mean = 1.0 } else .{ .max = 3, .mean = 0.4 };
        try std.testing.expect(max_err <= limits.max);
        try std.testing.expect(mean_err <= limits.mean);
    }
}

test "auto method picks the filter by sigma" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const Options = @import("../image.zig").GaussianBlurOptions;
    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    var src: Image(u8) = try .init(allocator, 48, 64);
    defer src.deinit(allocator);
    for (src.data) |*px| px.* = random.int(u8);
    var auto_out: Image(u8) = try .initLike(allocator, src);
    defer auto_out.deinit(allocator);
    var expected: Image(u8) = try .initLike(allocator, src);
    defer expected.deinit(allocator);

    const cases = [_]struct { sigma: f32, method: @TypeOf(Options.default.method) }{
        .{ .sigma = auto_sigma / 2, .method = .fir },
        .{ .sigma = auto_sigma, .method = .iir },
        .{ .sigma = 2 * auto_sigma, .method = .iir },
    };
    for (cases) |case| {
        try src.gaussianBlur(io, allocator, auto_out, case.sigma, .{ .method = .auto });
        try src.gaussianBlur(io, allocator, expected, case.sigma, .{ .method = case.method });
        try std.testing.expectEqualSlices(u8, expected.data, auto_out.data);
    }
}

test "iir gaussian struct pixels match per-plane u8" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const Rgb = @import("../color.zig").Rgb(u8);
    var prng = std.Random.DefaultPrng.init(9);
    const random = prng.random();

    var rgb: Image(Rgb) = try .init(allocator, 37, 53);
    defer rgb.deinit(allocator);
    var green: Image(u8) = try .init(allocator, 37, 53);
    defer green.deinit(allocator);
    for (rgb.data, green.data) |*px, *g| {
        px.* = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) };
        g.* = px.g;
    }
    var rgb_out: Image(Rgb) = try .initLike(allocator, rgb);
    defer rgb_out.deinit(allocator);
    var green_out: Image(u8) = try .initLike(allocator, green);
    defer green_out.deinit(allocator);

    try blur(Rgb, io, rgb, rgb_out, allocator, 3);
    try blur(u8, io, green, green_out, allocator, 3);
    for (rgb_out.data, green_out.data) |px, g| try std.testing.expectEqual(g, px.g);

    // f32 planes take the same path (in place, no temp) without the rounding store.
    var f: Image(f32) = try .init(allocator, 37, 53);
    defer f.deinit(allocator);
    for (f.data, green.data) |*v, g| v.* = @as(f32, g);
    var f_out: Image(f32) = try .initLike(allocator, f);
    defer f_out.deinit(allocator);
    try blur(f32, io, f, f_out, allocator, 3);
    for (f_out.data, green_out.data) |v, g| try std.testing.expect(@abs(v - @as(f32, g)) <= 0.5);
}

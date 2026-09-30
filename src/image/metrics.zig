//! Image quality metrics (PSNR and SSIM).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const meta = @import("../meta.zig");
const parallel = @import("../parallel.zig");
const convolution = @import("convolution.zig");
const color = @import("../color.zig");

const Image = @import("../image.zig").Image;

/// PSNR in dB over every component; `inf` for identical images. Rows run in bands on `io`.
pub fn psnr(comptime T: type, io: Io, image_a: Image(T), image_b: Image(T)) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }
    const a = componentView(T, image_a);
    const count = a.rows * a.cols;
    if (count == 0) return error.ImageTooSmall;

    const mse = meta.as(f64, sumRows(io, a, componentView(T, image_b), .squared)) / @as(f64, @floatFromInt(count));
    if (mse == 0.0) return std.math.inf(f64);
    return 20.0 * std.math.log10(componentMaxValue(T)) - 10.0 * std.math.log10(mse);
}

pub const ssim_window = 11;
/// Normalized 1D Gaussian (σ = 1.5); the 11×11 window of Wang et al. is its outer product.
pub const ssim_kernel: [ssim_window]f64 = blk: {
    var k: [ssim_window]f64 = undefined;
    convolution.fillGaussianKernel(f64, &k, 1.5);
    break :blk k;
};

/// `x` in every lane of `V`, which may also be plain `f64`.
inline fn splat(comptime V: type, x: f64) V {
    return if (V == f64) x else @splat(x);
}

/// SSIM of one window from its weighted moments E[x], E[y], E[x²], E[y²], E[xy].
pub inline fn ssimTerm(comptime T: type, comptime V: type, mu_x: V, mu_y: V, mu_xx: V, mu_yy: V, mu_xy: V) V {
    const l = componentMaxValue(T);
    const c1 = splat(V, (0.01 * l) * (0.01 * l));
    const c2 = splat(V, (0.03 * l) * (0.03 * l));
    const two = splat(V, 2);
    const zero = splat(V, 0);
    const sigma_x_sq = @max(zero, mu_xx - mu_x * mu_x);
    const sigma_y_sq = @max(zero, mu_yy - mu_y * mu_y);
    const sigma_xy = mu_xy - mu_x * mu_y;
    return (two * mu_x * mu_y + c1) * (two * sigma_xy + c2) / ((mu_x * mu_x + mu_y * mu_y + c1) * (sigma_x_sq + sigma_y_sq + c2));
}

/// Mean SSIM over every 11×11 window that fits (no padding), as separable vertical and
/// horizontal taps. Per-row sums are added in order, so the band count never changes the result.
pub fn ssim(comptime T: type, io: Io, allocator: Allocator, image_a: Image(T), image_b: Image(T)) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }
    if (image_a.rows < ssim_window or image_a.cols < ssim_window) {
        return error.ImageTooSmall;
    }

    const cols = image_a.cols;
    const out_rows = image_a.rows - (ssim_window - 1);
    const out_cols = cols - (ssim_window - 1);
    // Each band reloads the 10 rows above its first window.
    const bands = parallel.bandCountFor(out_rows, cols, 4 * ssim_window);
    // Per band: a luma ring per image, then the five vertical moment rows.
    const scratch = try allocator.alloc(f64, out_rows + bands * (2 * ssim_window + 5) * cols);
    defer allocator.free(scratch);

    const Ctx = struct {
        a: Image(T),
        b: Image(T),
        row_sums: []f64,
        scratch: []f64,

        const lanes = std.simd.suggestVectorLength(f64) orelse 1;
        const V = @Vector(lanes, f64);

        fn band(c: *const @This(), index: usize, first: usize, last: usize) void {
            const n = c.a.cols;
            const buf = c.scratch[index * (2 * ssim_window + 5) * n ..];
            const xs = buf[0 .. ssim_window * n];
            const ys = buf[ssim_window * n ..][0 .. ssim_window * n];
            const m = buf[2 * ssim_window * n ..][0 .. 5 * n];

            for (first..first + ssim_window - 1) |r| c.loadRow(xs, ys, r);
            for (first..last) |o| {
                c.loadRow(xs, ys, o + ssim_window - 1);
                var slots: [ssim_window]usize = undefined;
                for (&slots, 0..) |*slot, dy| slot.* = ((o + dy) % ssim_window) * n;

                var col: usize = 0;
                while (col + lanes <= n) : (col += lanes) verticalTaps(V, xs, ys, m, n, slots, col);
                while (col < n) : (col += 1) verticalTaps(f64, xs, ys, m, n, slots, col);

                const windows = n - (ssim_window - 1);
                var acc: V = @splat(0);
                col = 0;
                while (col + lanes <= windows) : (col += lanes) acc += horizontalTaps(V, m, n, col);
                var sum = @reduce(.Add, acc);
                while (col < windows) : (col += 1) sum += horizontalTaps(f64, m, n, col);
                c.row_sums[o] = sum;
            }
        }

        fn load(comptime W: type, s: []const f64, i: usize) W {
            return if (W == f64) s[i] else s[i..][0..lanes].*;
        }

        fn store(comptime W: type, s: []f64, i: usize, v: W) void {
            if (W == f64) s[i] = v else s[i..][0..lanes].* = v;
        }

        inline fn verticalTaps(comptime W: type, xs: []const f64, ys: []const f64, m: []f64, n: usize, slots: [ssim_window]usize, col: usize) void {
            var sx = splat(W, 0);
            var sy = splat(W, 0);
            var sxx = splat(W, 0);
            var syy = splat(W, 0);
            var sxy = splat(W, 0);
            inline for (ssim_kernel, slots) |w, slot| {
                const x = load(W, xs, slot + col);
                const y = load(W, ys, slot + col);
                const wx = splat(W, w) * x;
                const wy = splat(W, w) * y;
                sx += wx;
                sy += wy;
                sxx += wx * x;
                syy += wy * y;
                sxy += wx * y;
            }
            store(W, m, col, sx);
            store(W, m, n + col, sy);
            store(W, m, 2 * n + col, sxx);
            store(W, m, 3 * n + col, syy);
            store(W, m, 4 * n + col, sxy);
        }

        inline fn horizontalTaps(comptime W: type, m: []const f64, n: usize, col: usize) W {
            var mu: [5]W = @splat(splat(W, 0));
            inline for (ssim_kernel, 0..) |w, dx| {
                inline for (&mu, 0..) |*acc, k| acc.* += splat(W, w) * load(W, m, k * n + col + dx);
            }
            return ssimTerm(T, W, mu[0], mu[1], mu[2], mu[3], mu[4]);
        }

        /// Luma of source row `r` into its ring slot.
        fn loadRow(c: *const @This(), xs: []f64, ys: []f64, r: usize) void {
            const n = c.a.cols;
            const slot = (r % ssim_window) * n;
            const row_a = c.a.data[r * c.a.stride ..][0..n];
            const row_b = c.b.data[r * c.b.stride ..][0..n];
            for (xs[slot..][0..n], ys[slot..][0..n], row_a, row_b) |*x, *y, pa, pb| {
                x.* = getPixelScalar(T, pa);
                y.* = getPixelScalar(T, pb);
            }
        }
    };
    const ctx: Ctx = .{ .a = image_a, .b = image_b, .row_sums = scratch[0..out_rows], .scratch = scratch[out_rows..] };
    parallel.forRowBands(io, out_rows, bands, &ctx, Ctx.band);

    var total: f64 = 0;
    for (ctx.row_sums) |s| total += s;
    return total / @as(f64, @floatFromInt(out_rows * out_cols));
}

/// Mean absolute component difference over the component range, in [0, 1]. Rows run in
/// bands on `io`.
pub fn meanPixelError(comptime T: type, io: Io, image_a: Image(T), image_b: Image(T)) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }
    const a = componentView(T, image_a);
    const count = a.rows * a.cols;
    if (count == 0) return 0.0;

    const total = meta.as(f64, sumRows(io, a, componentView(T, image_b), .absolute));
    return total / @as(f64, @floatFromInt(count)) / componentMaxValue(T);
}

/// `image` as a plane of its components, each pixel's fields or elements as consecutive
/// columns. Pixels must be made of one component type without padding.
fn componentView(comptime T: type, image: Image(T)) Image(componentType(T)) {
    const C = componentType(T);
    if (C == T) return image;
    const n = @sizeOf(T) / @sizeOf(C);
    comptime switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_types) |F| {
            if (F != C) @compileError("image metrics need one component type, got " ++ @typeName(T));
        },
        .array => {},
        else => @compileError("unsupported pixel type for image metrics: " ++ @typeName(T)),
    };
    comptime std.debug.assert(n * @sizeOf(C) == @sizeOf(T));
    return .{
        .rows = image.rows,
        .cols = image.cols * n,
        .stride = image.stride * n,
        .data = @as([*]C, @ptrCast(image.data.ptr))[0 .. image.data.len * n],
    };
}

const Difference = enum { squared, absolute };

/// Row chunks of `sumRows`: fixed, so float sums do not depend on the band count.
const sum_chunks = 64;

/// Sum over all components of the squared or absolute difference of `a` and `b`: exact in
/// u64 for integer components, f64 in a fixed order for floats.
fn sumRows(io: Io, a: anytype, b: @TypeOf(a), comptime diff: Difference) SumType(@TypeOf(a.data[0])) {
    const C = @TypeOf(a.data[0]);
    const Sum = SumType(C);
    const chunks = @min(sum_chunks, a.rows);
    var sums: [sum_chunks]Sum = @splat(0);

    const Ctx = struct {
        a: @TypeOf(a),
        b: @TypeOf(a),
        chunks: usize,
        sums: *[sum_chunks]Sum,

        const lanes = std.simd.suggestVectorLength(C) orelse 1;
        /// u8 terms fit u32 lanes for `block` vectors; wider components accumulate in u64.
        const Lane = if (@typeInfo(C) == .float) f64 else if (@bitSizeOf(C) <= 8) u32 else u64;
        const block = if (Lane == u32) lanes * 65536 else std.math.maxInt(usize);

        fn band(c: *const @This(), _: usize, first: usize, last: usize) void {
            for (first..last) |k| {
                var sum: Sum = 0;
                for (c.a.rows * k / c.chunks..c.a.rows * (k + 1) / c.chunks) |r| {
                    sum += row(c.a.data[r * c.a.stride ..][0..c.a.cols], c.b.data[r * c.b.stride ..][0..c.a.cols]);
                }
                c.sums[k] = sum;
            }
        }

        fn row(xs: []const C, ys: []const C) Sum {
            var sum: Sum = 0;
            var i: usize = 0;
            while (i + lanes <= xs.len) {
                const end = i + @min(block, (xs.len - i) / lanes * lanes);
                var acc: @Vector(lanes, Lane) = @splat(0);
                while (i < end) : (i += lanes) {
                    acc += term(@Vector(lanes, Lane), xs[i..][0..lanes].*, ys[i..][0..lanes].*);
                }
                sum += @reduce(.Add, acc);
            }
            while (i < xs.len) : (i += 1) sum += term(Sum, xs[i], ys[i]);
            return sum;
        }

        inline fn term(comptime W: type, x_in: anytype, y_in: anytype) W {
            const Elem = if (@TypeOf(x_in) == C) C else @Vector(lanes, C);
            const x: Elem = x_in;
            const y: Elem = y_in;
            if (@typeInfo(C) == .int) {
                // |x - y| on the unsigned components, widened only for the square.
                const d: W = @max(x, y) - @min(x, y);
                return if (diff == .squared) d * d else d;
            }
            const d = @as(W, x) - @as(W, y);
            return if (diff == .squared) d * d else @abs(d);
        }
    };
    const ctx: Ctx = .{ .a = a, .b = b, .chunks = chunks, .sums = &sums };
    parallel.forRowBands(io, chunks, @min(chunks, parallel.bandCount(a.rows, a.cols)), &ctx, Ctx.band);

    var total: Sum = 0;
    for (sums[0..chunks]) |s| total += s;
    return total;
}

fn SumType(comptime C: type) type {
    return switch (@typeInfo(C)) {
        .int => |info| if (info.signedness == .unsigned) u64 else @compileError("signed components are not supported for image metrics"),
        .float => f64,
        else => @compileError("unsupported component type for image metrics: " ++ @typeName(C)),
    };
}

inline fn componentType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int, .float => T,
        .@"struct" => |info| info.field_types[0],
        .array => |info| info.child,
        else => T,
    };
}

inline fn componentMaxValue(comptime T: type) f64 {
    return switch (@typeInfo(componentType(T))) {
        .int => |info| if (info.signedness == .unsigned)
            @floatFromInt(std.math.maxInt(componentType(T)))
        else
            @compileError("Signed integers not supported for image metrics"),
        .float => 1.0,
        else => unreachable,
    };
}

pub inline fn getPixelScalar(comptime PixelType: type, pixel: PixelType) f64 {
    switch (@typeInfo(PixelType)) {
        .int, .float => return meta.as(f64, pixel),
        .@"struct" => {
            if (comptime meta.isRgb(PixelType)) {
                const max_val = componentMaxValue(PixelType);
                return color.rgbLuma(pixel.r, pixel.g, pixel.b) * max_val;
            }
            var sum: f64 = 0.0;
            var count: usize = 0;
            inline for (comptime meta.structFields(PixelType)) |field| {
                sum += meta.as(f64, @field(pixel, field.name));
                count += 1;
            }
            return sum / @as(f64, @floatFromInt(count));
        },
        .array => |info| {
            if (info.len == 3 or info.len == 4) {
                const r: u8 = convertChannelToU8(info.child, pixel[0]);
                const g: u8 = convertChannelToU8(info.child, pixel[1]);
                const b: u8 = convertChannelToU8(info.child, pixel[2]);
                const max_val = componentMaxValue(PixelType);
                return color.rgbLuma(r, g, b) * max_val;
            }
            var sum: f64 = 0.0;
            inline for (0..info.len) |i| {
                sum += meta.as(f64, pixel[i]);
            }
            return sum / @as(f64, @floatFromInt(info.len));
        },
        else => return 0.0,
    }
}

inline fn convertChannelToU8(comptime ChannelType: type, value: ChannelType) u8 {
    return switch (@typeInfo(ChannelType)) {
        .int => meta.clamp(u8, value),
        .float => meta.clamp(u8, value * 255.0),
        else => 0,
    };
}

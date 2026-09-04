const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const parallel = @import("../parallel.zig");

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const border = @import("border.zig");

const BorderMode = border.BorderMode;
const channel_ops = @import("channel_ops.zig");

/// Fixed-point scale used to represent fractional u8 kernel weights as integers.
const fixed_point_scale: comptime_int = 256;
/// Squared scale for two-pass (separable) u8 convolutions.
const fixed_point_scale_sq: comptime_int = fixed_point_scale * fixed_point_scale;

/// Symmetric-rounding divide by the power-of-two `scale` followed by clamp to u8.
/// `(accum + half) >> shift` is bit-identical to the symmetric `@divTrunc` form after
/// clamping: for accum >= 0 both are floor((accum + half) / scale); for accum < 0 the two
/// may differ by one but are both <= 0, so the clamp maps them to 0 either way.
inline fn divClampU8(comptime scale: comptime_int, accum: anytype) u8 {
    const T = @TypeOf(accum);
    const shift: std.math.Log2Int(T) = comptime std.math.log2_int(u32, scale);
    return @intCast(std.math.clamp((accum + (scale / 2)) >> shift, 0, 255));
}

/// SIMD variant of `divClampU8`.
inline fn divClampU8Vec(
    comptime scale: comptime_int,
    accum: anytype,
) @Vector(@typeInfo(@TypeOf(accum)).vector.len, u8) {
    const N = @typeInfo(@TypeOf(accum)).vector.len;
    const T = @typeInfo(@TypeOf(accum)).vector.child;
    const half_vec: @Vector(N, T) = @splat(scale / 2);
    const shift_vec: @Vector(N, std.math.Log2Int(T)) = @splat(comptime std.math.log2_int(u32, scale));
    const zero_vec: @Vector(N, T) = @splat(0);
    const max_vec: @Vector(N, T) = @splat(255);
    const shifted = (accum + half_vec) >> shift_vec;
    return meta.narrowToBytes(@max(zero_vec, @min(max_vec, shifted)));
}

/// Quantizes f32 weights to `fixed_point_scale` fixed-point taps, then corrects the
/// independently-rounded taps so their sum matches the f32 kernel's intended gain: the
/// residual lands on the largest-magnitude tap (relative error <= 1/|k_max|). Without
/// this, correlated rounding drifts the overall gain — a uniform 1/30 kernel quantizes
/// to 30*9 = 270/256, brightening by +5.5% and clipping highlights.
/// For all-equal taps the strict `>` puts the residual on tap 0 — `isUniformBody`
/// relies on that shape to detect uniform kernels after quantization.
fn quantizeKernel(taps: []i32, weights: []const f32) void {
    if (taps.len == 0) return;
    var weight_sum: f64 = 0;
    var sum: i64 = 0;
    var largest: usize = 0;
    for (taps, weights, 0..) |*t, w, i| {
        t.* = @round(w * fixed_point_scale);
        weight_sum += w;
        sum += t.*;
        if (@abs(t.*) > @abs(taps[largest])) largest = i;
    }
    const target: i64 = @round(fixed_point_scale * weight_sum);
    taps[largest] += @intCast(target - sum);
}

/// Sum of quantized taps in `fixed_point_scale` units.
fn sumTaps(taps: []const i32) i64 {
    var sum: i64 = 0;
    for (taps) |k| sum += k;
    return sum;
}

fn ConvolutionKernel(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    if (T != u8 and T != f32) {
        @compileError("Unsupported kernel type: " ++ @typeName(T) ++ ". Only u8 and f32 are supported");
    }

    return struct {
        const size = rows * cols;
        const half_h = rows / 2;
        const half_w = cols / 2;
        /// Small kernels unroll both axes at comptime; larger ones keep the column axis
        /// unrolled and loop over rows at runtime, which stays within the comptime branch
        /// quota and keeps code size linear in the kernel width.
        const unroll_rows = rows <= 7;

        /// Load/store policy shared with the single separable pass (same src/dst type).
        const Pixels = SeparablePass(T, T, i32, 1);
        /// Taps and accumulators share one scalar: i32 fixed-point for u8 (|accum| <= 255 *
        /// sum|k| fits for kernel magnitude sums up to ~32k in weight units), f32 otherwise.
        const Scalar = Pixels.AccumT;
        const vec_len = Pixels.vec_len;

        /// Flattens a 2D kernel into a 1D array; for `u8` images, values are scaled by
        /// `fixed_point_scale`, rounded, and sum-corrected to preserve the kernel's gain.
        fn flatten(kernel: anytype) [size]Scalar {
            var weights: [size]f32 = undefined;
            for (0..rows) |kr| {
                for (0..cols) |kx| {
                    weights[kr * cols + kx] = as(f32, kernel[kr][kx]);
                }
            }
            if (T == f32) return weights;
            var result: [size]i32 = undefined;
            quantizeKernel(&result, &weights);
            return result;
        }

        /// Resolved source columns of one border column's taps; null = zero (.zero border).
        const ColTaps = [cols]?usize;

        fn colTaps(c: usize, src_cols: usize, border_mode: BorderMode) ColTaps {
            var taps: ColTaps = undefined;
            for (&taps, 0..) |*tap, kx| {
                tap.* = border.resolveIndex(@as(isize, @intCast(c)) + @as(isize, @intCast(kx)) - half_w, @intCast(src_cols), border_mode);
            }
            return taps;
        }

        /// One border-column pixel from pre-resolved row offsets and column taps.
        fn convolveBorderPixel(comptime n: usize, src: Image(T), dsts: [n]Image(T), row_offsets: RowOffsets(true), col_taps: ColTaps, kernels: [n][size]Scalar, r: usize, c: usize) void {
            var results: [n]Scalar = @splat(0);
            if (unroll_rows) {
                inline for (0..rows) |ky| borderRowTaps(n, src, row_offsets, col_taps, kernels, ky, &results);
            } else {
                for (0..rows) |ky| borderRowTaps(n, src, row_offsets, col_taps, kernels, ky, &results);
            }
            inline for (0..n) |i| {
                dsts[i].data[r * dsts[i].stride + c] = Pixels.store(results[i]);
            }
        }

        inline fn borderRowTaps(comptime n: usize, src: Image(T), row_offsets: RowOffsets(true), col_taps: ColTaps, kernels: [n][size]Scalar, ky: usize, results: *[n]Scalar) void {
            const base = row_offsets[ky] orelse return;
            inline for (0..cols) |kx| {
                if (col_taps[kx]) |sc| {
                    const pixel_val = Pixels.promote(src.data[base + sc]);
                    inline for (0..n) |i| {
                        results[i] += pixel_val * kernels[i][ky * cols + kx];
                    }
                }
            }
        }

        /// Per-tap source-row base offsets for one output row; null = row of zeros (.zero border).
        fn RowOffsets(comptime maybe_zero: bool) type {
            return [rows](if (maybe_zero) ?usize else usize);
        }

        /// Convolves columns [c_start, c_end) of one output row from precomputed row offsets,
        /// applying all `n` kernels per loaded pixel.
        /// Columns in the span are horizontally in-bounds; when `maybe_zero` is false the
        /// null checks fold away and this is exactly the interior fast path.
        inline fn convolveRowSpan(
            comptime n: usize,
            comptime maybe_zero: bool,
            src: Image(T),
            dsts: [n]Image(T),
            row_offsets: RowOffsets(maybe_zero),
            kernels: [n][size]Scalar,
            kernel_vecs: *const [n][size]@Vector(vec_len, Scalar),
            r: usize,
            c_start: usize,
            c_end: usize,
        ) void {
            var c = c_start;

            while (c + vec_len <= c_end) : (c += vec_len) {
                var result_vecs: [n]@Vector(vec_len, Scalar) = @splat(@splat(0));
                if (unroll_rows) {
                    inline for (0..rows) |ky| rowTapsVec(n, maybe_zero, src, row_offsets, kernel_vecs, ky, c, &result_vecs);
                } else {
                    for (0..rows) |ky| rowTapsVec(n, maybe_zero, src, row_offsets, kernel_vecs, ky, c, &result_vecs);
                }
                inline for (0..n) |i| {
                    Pixels.storeVec(result_vecs[i], dsts[i].data[r * dsts[i].stride + c ..].ptr);
                }
            }

            while (c < c_end) : (c += 1) {
                var results: [n]Scalar = @splat(0);
                if (unroll_rows) {
                    inline for (0..rows) |ky| rowTaps(n, maybe_zero, src, row_offsets, kernels, ky, c, &results);
                } else {
                    for (0..rows) |ky| rowTaps(n, maybe_zero, src, row_offsets, kernels, ky, c, &results);
                }
                inline for (0..n) |i| {
                    dsts[i].data[r * dsts[i].stride + c] = Pixels.store(results[i]);
                }
            }
        }

        /// One kernel row's taps for `vec_len` output columns starting at `c`. The `maybe_zero`
        /// check folds away at comptime on the interior path.
        inline fn rowTapsVec(comptime n: usize, comptime maybe_zero: bool, src: Image(T), row_offsets: RowOffsets(maybe_zero), kernel_vecs: *const [n][size]@Vector(vec_len, Scalar), ky: usize, c: usize, result_vecs: *[n]@Vector(vec_len, Scalar)) void {
            if (maybe_zero and row_offsets[ky] == null) return;
            const base = if (maybe_zero) row_offsets[ky].? else row_offsets[ky];
            inline for (0..cols) |kx| {
                const pixel_vec = Pixels.loadVec(src.data[base + c + kx - half_w ..].ptr);
                inline for (0..n) |i| {
                    result_vecs[i] += pixel_vec * kernel_vecs[i][ky * cols + kx];
                }
            }
        }

        inline fn rowTaps(comptime n: usize, comptime maybe_zero: bool, src: Image(T), row_offsets: RowOffsets(maybe_zero), kernels: [n][size]Scalar, ky: usize, c: usize, results: *[n]Scalar) void {
            if (maybe_zero and row_offsets[ky] == null) return;
            const base = if (maybe_zero) row_offsets[ky].? else row_offsets[ky];
            inline for (0..cols) |kx| {
                const pixel_val = Pixels.promote(src.data[base + c + kx - half_w]);
                inline for (0..n) |i| {
                    results[i] += pixel_val * kernels[i][ky * cols + kx];
                }
            }
        }

        /// Applies `n` same-shaped kernels in a single pass over `src`; each source pixel is
        /// loaded once and feeds every kernel's accumulator.
        fn convolveMulti(comptime n: usize, io: Io, src: Image(T), dsts: [n]Image(T), kernels: [n][size]Scalar, border_mode: BorderMode) void {
            // Border columns [0, low_end) and [high_start, cols) resolve the same taps on every
            // row, so they are resolved once per call; table ordinal = low positions first.
            const low_end = @min(half_w, src.cols);
            const high_start = if (src.cols > 2 * half_w) src.cols - half_w else low_end;
            var ctx: MultiContext(n) = .{
                .src = src,
                .dsts = dsts,
                .kernels = kernels,
                .kernel_vecs = undefined,
                .border_mode = border_mode,
                .low_end = low_end,
                .high_start = high_start,
                .col_taps = undefined,
            };
            inline for (0..n) |i| {
                for (0..size) |j| ctx.kernel_vecs[i][j] = @splat(kernels[i][j]);
            }
            for (0..low_end) |c| ctx.col_taps[c] = colTaps(c, src.cols, border_mode);
            for (high_start..src.cols) |c| ctx.col_taps[low_end + c - high_start] = colTaps(c, src.cols, border_mode);

            parallel.forRowBands(io, src.rows, parallel.bandCount(src.rows, src.cols), &ctx, MultiContext(n).rowBand);
        }

        /// Read-only state shared by the row bands of `convolveMulti`.
        fn MultiContext(comptime n: usize) type {
            return struct {
                src: Image(T),
                dsts: [n]Image(T),
                kernels: [n][size]Scalar,
                kernel_vecs: [n][size]@Vector(vec_len, Scalar),
                border_mode: BorderMode,
                low_end: usize,
                high_start: usize,
                col_taps: [2 * half_w]ColTaps,

                fn rowBand(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
                    const src = ctx.src;
                    for (r0..r1) |r| {
                        const ir: isize = @intCast(r);
                        var offs: RowOffsets(true) = undefined;
                        for (&offs, 0..) |*off, ky| {
                            const resolved = border.resolveIndex(ir + @as(isize, @intCast(ky)) - half_h, @intCast(src.rows), ctx.border_mode);
                            off.* = if (resolved) |sr| sr * src.stride else null;
                        }

                        for (0..ctx.low_end) |c| {
                            convolveBorderPixel(n, src, ctx.dsts, offs, ctx.col_taps[c], ctx.kernels, r, c);
                        }
                        if (r >= half_h and r + half_h < src.rows) {
                            var in_band: RowOffsets(false) = undefined;
                            for (&in_band, offs) |*dst_off, off| dst_off.* = off.?;
                            convolveRowSpan(n, false, src, ctx.dsts, in_band, ctx.kernels, &ctx.kernel_vecs, r, ctx.low_end, ctx.high_start);
                        } else {
                            convolveRowSpan(n, true, src, ctx.dsts, offs, ctx.kernels, &ctx.kernel_vecs, r, ctx.low_end, ctx.high_start);
                        }
                        for (ctx.high_start..src.cols) |c| {
                            convolveBorderPixel(n, src, ctx.dsts, offs, ctx.col_taps[ctx.low_end + c - ctx.high_start], ctx.kernels, r, c);
                        }
                    }
                }
            };
        }
    };
}

/// Normalized 1-D Gaussian with radius `ceil(3·sigma)`; `sigma` must be positive.
pub fn gaussianKernel(allocator: Allocator, sigma: f32) ![]f32 {
    const radius: usize = @ceil(3.0 * sigma);
    const kernel = try allocator.alloc(f32, 2 * radius + 1);
    var sum: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        k.* = @exp(-(x * x) / (2.0 * sigma * sigma));
        sum += k.*;
    }
    for (kernel) |*k| k.* /= sum;
    return kernel;
}

/// Comptime {height, width} of a 2D array kernel type.
fn kernelDims(comptime K: type) [2]usize {
    const info = @typeInfo(K);
    if (info != .array) @compileError("Kernel must be a 2D array");
    if (@typeInfo(info.array.child) != .array) @compileError("Kernel must be a 2D array");
    return .{ info.array.len, @typeInfo(info.array.child).array.len };
}

/// Applies two same-shaped 2D kernels in a single pass over `self`, writing into `out_a` and
/// `out_b`; each source pixel is loaded once. Supports u8 and f32 planes only.
pub fn convolvePair(
    comptime T: type,
    io: Io,
    self: Image(T),
    out_a: Image(T),
    out_b: Image(T),
    kernel_a: anytype,
    kernel_b: anytype,
    border_mode: BorderMode,
) void {
    if (T != u8 and T != f32) @compileError("convolvePair supports u8 and f32 planes only");
    const dims_a = comptime kernelDims(@TypeOf(kernel_a));
    const dims_b = comptime kernelDims(@TypeOf(kernel_b));
    if (dims_a[0] != dims_b[0] or dims_a[1] != dims_b[1]) @compileError("convolvePair kernels must have identical dimensions");

    const Kernel = ConvolutionKernel(T, dims_a[0], dims_a[1]);
    Kernel.convolveMulti(2, io, self, .{ out_a, out_b }, .{ Kernel.flatten(kernel_a), Kernel.flatten(kernel_b) }, border_mode);
}

/// Applies a 2D convolution with the given kernel, writing into `out`.
pub fn convolve(comptime T: type, io: Io, self: Image(T), out: Image(T), allocator: Allocator, kernel: anytype, border_mode: BorderMode) !void {
    const dims = comptime kernelDims(@TypeOf(kernel));
    const kernel_height = dims[0];
    const kernel_width = dims[1];

    switch (T) {
        u8, f32 => {
            const Kernel = ConvolutionKernel(T, kernel_height, kernel_width);
            Kernel.convolveMulti(1, io, self, .{out}, .{Kernel.flatten(kernel)}, border_mode);
        },
        else => switch (@typeInfo(T)) {
            .@"struct" => {
                if (comptime meta.allFieldsAreU8(T)) {
                    const Kernel = ConvolutionKernel(u8, kernel_height, kernel_width);
                    const kernel_int = Kernel.flatten(kernel);
                    const PlaneCtx = struct {
                        kernel: [Kernel.size]i32,

                        fn convolvePlane(ctx: @This(), plane_io: Io, src: Image(u8), dst: Image(u8), mode: BorderMode) !void {
                            Kernel.convolveMulti(1, plane_io, src, .{dst}, .{ctx.kernel}, mode);
                        }
                    };
                    try convolvePlanes(T, io, self, out, allocator, sumTaps(&kernel_int), fixed_point_scale, border_mode, PlaneCtx{ .kernel = kernel_int });
                } else {
                    @compileError("Convolution only supports structs where all fields are u8. Type " ++ @typeName(T) ++ " is not supported.");
                }
            },
            else => @compileError("Convolution only supports u8, f32, and structs with all u8 fields. Type " ++ @typeName(T) ++ " is not supported."),
        },
    }
}

const ChannelStrategy = enum { normalized, scaled, non_uniform };

/// Shared struct-pixel path: splits `image` into u8 planes, shortcuts uniform channels
/// (`kernel_sum` is in `scale` fixed-point units), convolves the rest via `ctx.convolvePlane`,
/// and merges the results into `out`.
pub fn convolvePlanes(
    comptime T: type,
    io: Io,
    image: Image(T),
    out: Image(T),
    allocator: Allocator,
    kernel_sum: i64,
    comptime scale: comptime_int,
    border_mode: BorderMode,
    ctx: anytype,
) !void {
    const plane_size = image.rows * image.cols;

    const split = try channel_ops.splitChannelsWithUniform(T, io, image, allocator);
    const channels = split.channels;
    const uniforms = split.uniforms;
    defer for (channels) |channel| allocator.free(channel);

    // .zero border injects zeros at the edges, breaking uniform-region shortcuts.
    const is_safe_border = border_mode.preservesUniform();
    var strategies: [channels.len]ChannelStrategy = undefined;
    inline for (uniforms, 0..) |uniform_value, i| {
        strategies[i] = if (uniform_value != null and is_safe_border)
            (if (kernel_sum == scale) .normalized else .scaled)
        else
            .non_uniform;
    }

    var num_alloc_channels: usize = 0;
    inline for (strategies) |strategy| {
        if (strategy != .normalized) num_alloc_channels += 1;
    }

    const contiguous_buffer = try allocator.alloc(u8, try std.math.mul(usize, num_alloc_channels, plane_size));
    defer allocator.free(contiguous_buffer);

    var final_channels: [channels.len][]const u8 = undefined;
    var alloc_offset: usize = 0;
    inline for (strategies, uniforms, channels, 0..) |strategy, uniform_value, src_data, i| {
        if (strategy == .normalized) {
            final_channels[i] = src_data;
        } else {
            const dst_data = contiguous_buffer[alloc_offset..][0..plane_size];
            alloc_offset += plane_size;
            final_channels[i] = dst_data;
            if (strategy == .scaled) {
                const value = uniform_value orelse unreachable;
                @memset(dst_data, divClampU8(scale, @as(i64, value) * kernel_sum));
            } else {
                const src_plane = Image(u8).initFromSlice(image.rows, image.cols, src_data);
                const dst_plane = Image(u8).initFromSlice(image.rows, image.cols, dst_data);
                try ctx.convolvePlane(io, src_plane, dst_plane, border_mode);
            }
        }
    }
    channel_ops.mergeChannels(T, io, final_channels, out);
}

fn scaleKernelToInt(allocator: Allocator, kernel: []const f32) ![]i32 {
    const result = try allocator.alloc(i32, kernel.len);
    quantizeKernel(result, kernel);
    return result;
}

/// A 1-tap identity kernel makes its whole pass a copy. In quantized units the identity
/// tap is exactly `fixed_point_scale` (1.0 quantizes to it with no residual).
inline fn isIdentityKernel(kernel: anytype) bool {
    const one = if (@TypeOf(kernel[0]) == i32) fixed_point_scale else 1;
    return kernel.len == 1 and kernel[0] == one;
}

/// True when all taps except possibly the first are equal — the shape of a quantized
/// uniform kernel after `quantizeKernel` parks the rounding residual on tap 0.
/// Such kernels (axis-aligned motion blur) collapse to an O(1)/pixel running sum.
fn isUniformBody(kernel: []const i32) bool {
    return kernel.len >= 2 and channel_ops.findUniformValue(i32, kernel[1..]) != null;
}

/// True when i32 accumulators cannot overflow for these quantized kernels: the horizontal
/// pass is bounded by 255*sum|kx| and the vertical pass by 255*sum|kx|*sum|ky|, with
/// `fixed_point_scale_sq` of margin for the rounding half added before the final divide.
/// Any normalized blur kernel passes by a factor of >100.
fn narrowAccumFits(kernel_x: []const i32, kernel_y: []const i32) bool {
    var sx: i64 = 0;
    for (kernel_x) |k| sx += @abs(k);
    var sy: i64 = 0;
    for (kernel_y) |k| sy += @abs(k);
    const limit = std.math.maxInt(i32) - fixed_point_scale_sq;
    return 255 * sx <= limit and 255 * sx * sy <= limit;
}

/// Selects the accumulator width (i32 unless the kernels could overflow it) and runs the
/// plane driver. `channels` > 1 means `src`/`dst` are interleaved struct pixels viewed as
/// elements (see `elementView`).
fn convolveSeparableAuto(
    comptime PixelT: type,
    comptime TempT: type,
    comptime channels: usize,
    io: Io,
    src: Image(PixelT),
    dst: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    // i32 accumulators run 8 real SIMD lanes; i64 halves throughput on AVX2 (emulated
    // multiplies), so it is kept only as the overflow fallback for pathological kernels.
    if (TempT == i32 and !narrowAccumFits(kernel_x, kernel_y)) {
        return convolveSeparableAutoImpl(PixelT, TempT, i64, channels, io, src, dst, allocator, kernel_x, kernel_y, border_mode);
    }
    return convolveSeparableAutoImpl(PixelT, TempT, i32, channels, io, src, dst, allocator, kernel_x, kernel_y, border_mode);
}

/// Separable driver owning the strategy choice: identity axes skip their pass entirely,
/// uniform-body kernels take the O(1)/pixel running-sum box passes, large planes take
/// the fused ring path, and everything else runs the standard two-pass over a temp plane.
fn convolveSeparableAutoImpl(
    comptime PixelT: type,
    comptime TempT: type,
    comptime AccumIntT: type,
    comptime channels: usize,
    io: Io,
    src: Image(PixelT),
    dst: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    const identity_x = isIdentityKernel(kernel_x);
    const identity_y = isIdentityKernel(kernel_y);
    const SinglePass = SeparablePass(PixelT, PixelT, AccumIntT, channels);

    if (identity_x and identity_y) {
        src.copy(dst);
    } else if (identity_y) {
        if (TempT == i32 and isUniformBody(kernel_x)) {
            try SinglePass.horizontalBox(io, src, dst, allocator, kernel_x, border_mode);
        } else {
            try SinglePass.horizontal(io, src, dst, allocator, kernel_x, border_mode);
        }
    } else if (identity_x) {
        if (TempT == i32 and isUniformBody(kernel_y)) {
            try SinglePass.verticalBox(io, src, dst, allocator, kernel_y, border_mode);
        } else {
            try SinglePass.vertical(io, src, dst, allocator, kernel_y, border_mode);
        }
    } else if (useFusedSeparable(TempT, src.rows, src.cols, kernel_y.len, border_mode)) {
        // Each band re-runs the horizontal pass over `kernel_y.len` halo rows.
        const bands = parallel.bandCountFor(src.rows, src.cols, 4 * kernel_y.len);
        try convolveSeparablePlaneFused(PixelT, TempT, AccumIntT, channels, io, bands, src, dst, allocator, kernel_x, kernel_y, border_mode);
    } else {
        var temp: Image(TempT) = try .init(allocator, src.rows, src.cols);
        defer temp.deinit(allocator);
        try convolveSeparablePlane(PixelT, TempT, AccumIntT, channels, io, src, dst, temp, allocator, kernel_x, kernel_y, border_mode);
    }
}

/// `image`'s bytes as a `cols * channels` wide u8 image: every channel of a pixel is a
/// column, so the separable passes run over interleaved struct pixels without a split.
pub fn elementView(comptime T: type, image: Image(T)) Image(u8) {
    const n = comptime Image(T).channels();
    return .{
        .rows = image.rows,
        .cols = image.cols * n,
        .stride = image.stride * n,
        .data = std.mem.sliceAsBytes(image.data),
    };
}

/// Separable convolution: applies two 1D kernels (horizontal then vertical).
/// Much faster than `convolve` for separable filters like Gaussian blur.
pub fn convolveSeparable(
    comptime T: type,
    io: Io,
    image: Image(T),
    out: Image(T),
    allocator: Allocator,
    kernel_x: []const f32,
    kernel_y: []const f32,
    border_mode: BorderMode,
) !void {
    comptime if (T != u8 and T != f32 and !(@typeInfo(T) == .@"struct" and meta.allFieldsAreU8(T))) {
        @compileError("Separable convolution only supports u8, f32, and structs with all u8 fields. Type " ++ @typeName(T) ++ " is not supported.");
    };

    if (isIdentityKernel(kernel_x) and isIdentityKernel(kernel_y)) {
        image.copy(out);
    } else if (T == f32) {
        try convolveSeparableAuto(f32, f32, 1, io, image, out, allocator, kernel_x, kernel_y, border_mode);
    } else {
        // u8 planes, bare or struct fields, run on quantized kernels.
        const kernel_x_int = try scaleKernelToInt(allocator, kernel_x);
        defer allocator.free(kernel_x_int);
        const kernel_y_int = try scaleKernelToInt(allocator, kernel_y);
        defer allocator.free(kernel_y_int);

        if (T == u8) {
            try convolveSeparableAuto(u8, i32, 1, io, image, out, allocator, kernel_x_int, kernel_y_int, border_mode);
        } else {
            // Struct pixels run interleaved: every byte is a lane, so no channel split/merge.
            const n = comptime Image(T).channels();
            try convolveSeparableAuto(u8, i32, n, io, elementView(T, image), elementView(T, out), allocator, kernel_x_int, kernel_y_int, border_mode);
        }
    }
}

/// Resolved 1-D source indices for the border positions of one separable pass.
/// Border resolution is 1-D per axis (the other coordinate is always in bounds), and the
/// resolved indices are identical across that other axis — so they are computed once per
/// pass instead of per pixel. `indices[ordinal * kernel_len + tap]` is an in-bounds index,
/// or `zero_sentinel` when the tap reads a zero value (.zero mode or empty axis).
const BorderIndexTable = struct {
    const zero_sentinel: usize = std.math.maxInt(usize);

    indices: []usize,
    kernel_len: usize,
    /// Border positions are [0, low_end) and [high_start, axis_len).
    low_end: usize,
    high_start: usize,

    fn init(allocator: Allocator, axis_len: usize, kernel_len: usize, border_mode: BorderMode) !BorderIndexTable {
        const half = kernel_len / 2;
        const low_end = @min(half, axis_len);
        const high_start = if (axis_len > 2 * half) axis_len - half else low_end;

        const n_positions = low_end + (axis_len - high_start);
        const indices = try allocator.alloc(usize, n_positions * kernel_len);
        var w: usize = 0;
        for ([_][2]usize{ .{ 0, low_end }, .{ high_start, axis_len } }) |range| {
            for (range[0]..range[1]) |pos| {
                for (0..kernel_len) |tap| {
                    const idx = @as(isize, @intCast(pos + tap)) - @as(isize, @intCast(half));
                    indices[w] = border.resolveIndex(idx, @intCast(axis_len), border_mode) orelse zero_sentinel;
                    w += 1;
                }
            }
        }
        return .{ .indices = indices, .kernel_len = kernel_len, .low_end = low_end, .high_start = high_start };
    }

    fn deinit(self: BorderIndexTable, allocator: Allocator) void {
        allocator.free(self.indices);
    }

    /// Table ordinal of a border position (low positions first, high positions after).
    inline fn ordinalOf(self: BorderIndexTable, pos: usize) usize {
        return if (pos < self.low_end) pos else self.low_end + (pos - self.high_start);
    }

    inline fn taps(self: BorderIndexTable, ordinal: usize) []const usize {
        return self.indices[ordinal * self.kernel_len ..][0..self.kernel_len];
    }
};

/// One direction of a separable convolution with load/store policies derived from the
/// source and destination scalar types. `AccumIntT` selects the integer accumulator
/// width (i32 when `narrowAccumFits`, else i64); ignored for f32 passes. `channels` > 1
/// means the rows are interleaved struct pixels seen as elements (`cols * channels` wide):
/// the horizontal taps step by `channels` and border positions are pixel columns, while
/// the vertical passes are channel-agnostic.
fn SeparablePass(comptime SrcT: type, comptime DstT: type, comptime AccumIntT: type, comptime channels: usize) type {
    if (AccumIntT != i32 and AccumIntT != i64) {
        @compileError("AccumIntT must be i32 or i64");
    }

    return struct {
        const KernelT = if (SrcT == f32 or DstT == f32) f32 else i32;
        const AccumT = if (KernelT == f32) f32 else AccumIntT;
        const vec_len = std.simd.suggestVectorLength(KernelT) orelse 1;
        /// Fixed-point divisor when storing to u8: one `fixed_point_scale` per quantized pass
        /// (u8 -> u8 single pass carries one, i32 -> u8 second pass carries two). A single
        /// pass is exact because divTrunc(256*S ± 32768, 65536) == divTrunc(S ± 128, 256).
        const dst_scale = if (DstT != u8) 1 else if (SrcT == u8) fixed_point_scale else fixed_point_scale_sq;

        /// With `dense` the per-tap skip branch is compiled out: for kernels without
        /// negligible taps (every gaussian) it measured 1.10-1.26x across the passes.
        inline fn isNegligible(comptime dense: bool, k: KernelT) bool {
            return !dense and (if (KernelT == f32) @abs(k) < 1e-10 else k == 0);
        }

        fn isDense(kernel: []const KernelT) bool {
            for (kernel) |k| if (isNegligible(false, k)) return false;
            return true;
        }

        /// Odd, mirror-symmetric kernels (every gaussian) can fold mirrored taps:
        /// (a + b) * k halves the multiplies. Integer-exact by distributivity, so the
        /// folded loops are used for i32 kernels only (f32 would change summation order).
        fn isSymmetric(kernel: []const KernelT) bool {
            // Folding measured slower past ~32 taps (two opposing load streams); the
            // dense multiply win only holds for short-to-medium kernels.
            if (KernelT != i32 or kernel.len % 2 == 0 or kernel.len > 32) return false;
            for (kernel[0 .. kernel.len / 2], 0..) |k, i| {
                if (k != kernel[kernel.len - 1 - i]) return false;
            }
            return true;
        }

        inline fn promote(v: anytype) if (@typeInfo(@TypeOf(v)) == .vector) @Vector(vec_len, AccumT) else AccumT {
            return if (AccumT == f32) v else @intCast(v);
        }

        inline fn loadVec(ptr: [*]const SrcT) @Vector(vec_len, AccumT) {
            const v: @Vector(vec_len, SrcT) = ptr[0..vec_len].*;
            return promote(v);
        }

        inline fn splatK(k: KernelT) @Vector(vec_len, AccumT) {
            return @splat(promote(k));
        }

        inline fn store(val: AccumT) DstT {
            return switch (DstT) {
                // The narrow accumulator is in i32 range by the narrowAccumFits guard.
                u8 => divClampU8(dst_scale, val),
                i32 => if (AccumT == i32) val else meta.clamp(i32, val),
                f32 => val,
                else => unreachable,
            };
        }

        inline fn storeVec(val: anytype, ptr: [*]DstT) void {
            const N = @typeInfo(@TypeOf(val)).vector.len;
            switch (DstT) {
                u8 => ptr[0..N].* = divClampU8Vec(dst_scale, val),
                i32 => if (AccumT == i32) {
                    ptr[0..N].* = val;
                } else {
                    const min_vec: @Vector(N, i64) = @splat(std.math.minInt(i32));
                    const max_vec: @Vector(N, i64) = @splat(std.math.maxInt(i32));
                    const narrowed: @Vector(N, i32) = @intCast(@max(min_vec, @min(max_vec, val)));
                    ptr[0..N].* = narrowed;
                },
                f32 => ptr[0..N].* = val,
                else => unreachable,
            }
        }

        /// Full-kernel accumulation for one border element from pre-resolved column indices
        /// (full kernel, zero adds included, to keep f32 accumulation order). `src_offset`
        /// selects the row and, for interleaved rows, the channel.
        inline fn borderPixelResolved(src: Image(SrcT), kernel: []const KernelT, tap_idx: []const usize, src_offset: usize) AccumT {
            var result: AccumT = 0;
            for (kernel, tap_idx) |k, idx| {
                const pv: SrcT = if (idx == BorderIndexTable.zero_sentinel) 0 else src.data[src_offset + idx * channels];
                result += promote(pv) * promote(k);
            }
            return result;
        }

        /// Border pixel columns `[c0, c1)` of one row, every channel.
        inline fn borderColumns(src: Image(SrcT), dst_row: []DstT, kernel: []const KernelT, table: BorderIndexTable, src_offset: usize, c0: usize, c1: usize) void {
            for (c0..c1) |c| {
                inline for (0..channels) |ch| {
                    dst_row[c * channels + ch] = store(borderPixelResolved(src, kernel, table.taps(table.ordinalOf(c)), src_offset + ch));
                }
            }
        }

        /// One row of the horizontal pass into a caller-provided contiguous row buffer.
        /// Interior work is per element with taps `channels` apart, so interleaved rows
        /// vectorize exactly like planes. Kept out of line: inlined into the fused driver
        /// it measured 4-8% slower.
        noinline fn horizontalRow(comptime dense: bool, src: Image(SrcT), dst_row: []DstT, r: usize, kernel: []const KernelT, table: BorderIndexTable, folded: bool) void {
            const half = kernel.len / 2;
            const cols = src.cols / channels;
            const src_offset = r * src.stride;
            const tap = half * channels;

            borderColumns(src, dst_row, kernel, table, src_offset, 0, table.low_end);

            if (cols > 2 * half) {
                var e = table.low_end * channels;
                const e_end = (cols - half) * channels;

                if (folded) {
                    while (e + vec_len <= e_end) : (e += vec_len) {
                        const base = src_offset + e - tap;
                        var acc: @Vector(vec_len, AccumT) = @splat(0);
                        for (kernel[0..half], 0..) |k, i| {
                            if (!isNegligible(dense, k)) {
                                const a = loadVec(src.data[base + i * channels ..].ptr);
                                const b = loadVec(src.data[base + (kernel.len - 1 - i) * channels ..].ptr);
                                acc += (a + b) * splatK(k);
                            }
                        }
                        if (!isNegligible(dense, kernel[half])) {
                            acc += loadVec(src.data[base + tap ..].ptr) * splatK(kernel[half]);
                        }
                        storeVec(acc, dst_row[e..].ptr);
                    }
                } else {
                    while (e + vec_len <= e_end) : (e += vec_len) {
                        var acc: @Vector(vec_len, AccumT) = @splat(0);
                        for (kernel, 0..) |k, ki| {
                            if (!isNegligible(dense, k)) {
                                acc += loadVec(src.data[src_offset + e + ki * channels - tap ..].ptr) * splatK(k);
                            }
                        }
                        storeVec(acc, dst_row[e..].ptr);
                    }
                }

                while (e < e_end) : (e += 1) {
                    var result: AccumT = 0;
                    const e0 = e - tap;
                    for (kernel, 0..) |k, i| {
                        if (!isNegligible(dense, k)) {
                            result += promote(src.data[src_offset + e0 + i * channels]) * promote(k);
                        }
                    }
                    dst_row[e] = store(result);
                }
            }

            borderColumns(src, dst_row, kernel, table, src_offset, table.high_start, cols);
        }

        /// Row-major 1D pass along columns (src -> dst).
        fn horizontal(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const table: BorderIndexTable = try .init(allocator, src.cols / channels, kernel.len, border_mode);
            defer table.deinit(allocator);
            const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel, .table = table };
            parallel.forRowBands(io, src.rows, parallel.bandCount(src.rows, src.cols), &ctx, BandContext.horizontalBand);
        }

        /// Read-only state shared by the row bands of the 1-D passes. `table` resolves the
        /// border positions of the pass axis (columns for horizontal, rows for vertical);
        /// the vertical passes also get `kernel.len` tap base offsets per band in `bases`.
        const BandContext = struct {
            src: Image(SrcT),
            dst: Image(DstT),
            kernel: []const KernelT,
            table: BorderIndexTable,
            bases: []usize = &.{},

            fn horizontalBand(ctx: *const BandContext, _: usize, r0: usize, r1: usize) void {
                const folded = isSymmetric(ctx.kernel);
                const dense = isDense(ctx.kernel);
                for (r0..r1) |r| {
                    const dst_row = ctx.dst.data[r * ctx.dst.stride ..][0..ctx.src.cols];
                    if (dense) horizontalRow(true, ctx.src, dst_row, r, ctx.kernel, ctx.table, folded) else horizontalRow(false, ctx.src, dst_row, r, ctx.kernel, ctx.table, folded);
                }
            }

            fn verticalBand(ctx: *const BandContext, band: usize, r0: usize, r1: usize) void {
                const folded = isSymmetric(ctx.kernel);
                const dense = isDense(ctx.kernel);
                ctx.verticalBorderRows(band, r0, @min(r1, ctx.table.low_end));
                const inner0 = @max(r0, ctx.table.low_end);
                const inner1 = @min(r1, ctx.table.high_start);
                if (inner0 < inner1) {
                    if (dense) verticalTiles(true, ctx.src, ctx.dst, ctx.kernel, folded, inner0, inner1) else verticalTiles(false, ctx.src, ctx.dst, ctx.kernel, folded, inner0, inner1);
                }
                ctx.verticalBorderRows(band, @max(r0, ctx.table.high_start), r1);
            }

            fn horizontalBoxBand(ctx: *const BandContext, _: usize, r0: usize, r1: usize) void {
                horizontalBoxRows(ctx.src, ctx.dst, ctx.kernel, ctx.table, r0, r1);
            }

            fn verticalBoxBand(ctx: *const BandContext, band: usize, r0: usize, r1: usize) void {
                ctx.verticalBorderRows(band, r0, @min(r1, ctx.table.low_end));
                const inner0 = @max(r0, ctx.table.low_end);
                const inner1 = @min(r1, ctx.table.high_start);
                if (inner0 < inner1) verticalBoxRows(ctx.src, ctx.dst, ctx.kernel, inner0, inner1);
                ctx.verticalBorderRows(band, @max(r0, ctx.table.high_start), r1);
            }

            /// Top/bottom border rows `[r0, r1)` from the row-resolved table; shared by the
            /// dense and box vertical passes.
            fn verticalBorderRows(ctx: *const BandContext, band: usize, r0: usize, r1: usize) void {
                if (r0 >= r1) return;
                const klen = ctx.kernel.len;
                const bases = ctx.bases[band * klen ..][0..klen];
                for (r0..r1) |r| {
                    for (bases, ctx.table.taps(ctx.table.ordinalOf(r))) |*b, idx| {
                        b.* = if (idx == BorderIndexTable.zero_sentinel) idx else idx * ctx.src.stride;
                    }
                    verticalRowFromBases(true, false, ctx.src.data, bases, ctx.dst, r, ctx.kernel, false);
                }
            }
        };

        /// One vertical-pass output row combined from per-tap source row base offsets
        /// (`BorderIndexTable.zero_sentinel` = row of zeros). Border rows keep the full
        /// kernel with explicit zero adds; interior rows skip negligible taps — both
        /// matching the standard vertical pass per pixel. Out of line for the same reason
        /// as `horizontalRow`.
        noinline fn verticalRowFromBases(comptime border_row: bool, comptime dense: bool, src_data: []const SrcT, bases: []const usize, dst: Image(DstT), r: usize, kernel: []const KernelT, folded: bool) void {
            const cols = dst.cols;
            const dst_offset = r * dst.stride;
            const half = kernel.len / 2;
            std.debug.assert(!(border_row and folded));
            var c: usize = 0;

            while (c + vec_len <= cols) : (c += vec_len) {
                var acc: @Vector(vec_len, AccumT) = @splat(0);
                if (folded) {
                    for (kernel[0..half], 0..) |k, i| {
                        if (!isNegligible(dense, k)) {
                            const a = loadVec(src_data[bases[i] + c ..].ptr);
                            const b = loadVec(src_data[bases[kernel.len - 1 - i] + c ..].ptr);
                            acc += (a + b) * splatK(k);
                        }
                    }
                    if (!isNegligible(dense, kernel[half])) {
                        acc += loadVec(src_data[bases[half] + c ..].ptr) * splatK(kernel[half]);
                    }
                } else {
                    for (kernel, bases) |k, base| {
                        if (border_row) {
                            const vec: @Vector(vec_len, AccumT) = if (base == BorderIndexTable.zero_sentinel)
                                @splat(0)
                            else
                                loadVec(src_data[base + c ..].ptr);
                            acc += vec * splatK(k);
                        } else if (!isNegligible(dense, k)) {
                            acc += loadVec(src_data[base + c ..].ptr) * splatK(k);
                        }
                    }
                }
                storeVec(acc, dst.data[dst_offset + c ..].ptr);
            }

            while (c < cols) : (c += 1) {
                var result: AccumT = 0;
                for (kernel, bases) |k, base| {
                    if (border_row) {
                        const pv: SrcT = if (base == BorderIndexTable.zero_sentinel) 0 else src_data[base + c];
                        result += promote(pv) * promote(k);
                    } else if (!isNegligible(dense, k)) {
                        result += promote(src_data[base + c]) * promote(k);
                    }
                }
                dst.data[dst_offset + c] = store(result);
            }
        }

        /// Column-tiled 1D pass along rows (src -> dst); tiling keeps the working set cache-resident
        /// and, unlike per-row bases, lets LLVM hoist the tap offsets (row-major measured 0.9x on f32).
        fn vertical(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            try verticalPass(io, src, dst, allocator, kernel, border_mode, BandContext.verticalBand);
        }

        /// Bands cover every row; each band emits its border rows from the row table and its
        /// interior rows through `band_fn`'s fast path, so no rows wait on the caller thread.
        fn verticalPass(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode, comptime band_fn: anytype) !void {
            const table: BorderIndexTable = try .init(allocator, src.rows, kernel.len, border_mode);
            defer table.deinit(allocator);
            const bands = parallel.bandCount(src.rows, src.cols);
            const bases = try allocator.alloc(usize, bands * kernel.len);
            defer allocator.free(bases);
            const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel, .table = table, .bases = bases };
            parallel.forRowBands(io, src.rows, bands, &ctx, band_fn);
        }

        /// Column-tiled interior rows `[r_start, r_end)`; tiling keeps the working set
        /// cache-resident and, unlike per-row bases, lets LLVM hoist the tap offsets
        /// (row-major measured 0.9x on f32).
        fn verticalTiles(comptime dense: bool, src: Image(SrcT), dst: Image(DstT), kernel: []const KernelT, folded: bool, r_start: usize, r_end: usize) void {
            const half = kernel.len / 2;
            const cols = src.cols;
            const tile_width = @max(vec_len, 16);

            var tile_c: usize = 0;
            while (tile_c < cols) : (tile_c += tile_width) {
                const tile_end = @min(tile_c + tile_width, cols);
                var c: usize = tile_c;

                while (c + vec_len <= tile_end) : (c += vec_len) {
                    for (r_start..r_end) |r| {
                        const base = (r - half) * src.stride + c;
                        var acc: @Vector(vec_len, AccumT) = @splat(0);
                        if (folded) {
                            for (kernel[0..half], 0..) |k, i| {
                                if (!isNegligible(dense, k)) {
                                    const a = loadVec(src.data[base + i * src.stride ..].ptr);
                                    const b = loadVec(src.data[base + (kernel.len - 1 - i) * src.stride ..].ptr);
                                    acc += (a + b) * splatK(k);
                                }
                            }
                            if (!isNegligible(dense, kernel[half])) {
                                acc += loadVec(src.data[base + half * src.stride ..].ptr) * splatK(kernel[half]);
                            }
                        } else {
                            for (kernel, 0..) |k, ki| {
                                if (!isNegligible(dense, k)) {
                                    acc += loadVec(src.data[base + ki * src.stride ..].ptr) * splatK(k);
                                }
                            }
                        }
                        storeVec(acc, dst.data[r * dst.stride + c ..].ptr);
                    }
                }

                while (c < tile_end) : (c += 1) {
                    for (r_start..r_end) |r| {
                        var result: AccumT = 0;
                        const r0 = r - half;
                        for (kernel, 0..) |k, i| {
                            if (isNegligible(dense, k)) continue;
                            result += promote(src.data[(r0 + i) * src.stride + c]) * promote(k);
                        }
                        dst.data[r * dst.stride + c] = store(result);
                    }
                }
            }
        }

        /// O(1)-per-pixel horizontal pass for uniform-body kernels (see `isUniformBody`):
        /// out = k*S + r*window_first with a running window sum S. Integer-exact vs the
        /// dense pass, so only used for integer kernels. Borders fall back to the dense
        /// table-resolved accumulation.
        fn horizontalBox(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const table: BorderIndexTable = try .init(allocator, src.cols / channels, kernel.len, border_mode);
            defer table.deinit(allocator);
            const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel, .table = table };
            parallel.forRowBands(io, src.rows, parallel.bandCount(src.rows, src.cols), &ctx, BandContext.horizontalBoxBand);
        }

        fn horizontalBoxRows(src: Image(SrcT), dst: Image(DstT), kernel: []const KernelT, table: BorderIndexTable, r_start: usize, r_end: usize) void {
            const half = kernel.len / 2;
            const len = kernel.len;
            const cols = src.cols / channels;
            const tap = half * channels;
            const window = len * channels;
            // Element-space block: one SIMD width of pixels, every channel of each.
            const B = vec_len * channels;
            const Lane = @Vector(channels, AccumT);

            const k = promote(kernel[1]);
            const residual = promote(kernel[0]) - k;

            for (r_start..r_end) |r| {
                const src_offset = r * src.stride;
                const dst_offset = r * dst.stride;
                const dst_row = dst.data[dst_offset..][0 .. cols * channels];

                borderColumns(src, dst_row, kernel, table, src_offset, 0, table.low_end);

                if (cols > 2 * half) {
                    var e = table.low_end * channels;
                    const e_end = (cols - half) * channels;
                    // Per-channel window sums.
                    var sum: Lane = @splat(0);
                    for (0..len) |i| {
                        const px: @Vector(channels, SrcT) = src.data[src_offset + e - tap + i * channels ..][0..channels].*;
                        sum += if (AccumT == f32) px else @intCast(px);
                    }

                    if (AccumT == i32 and SrcT == u8) {
                        // The running sum as a stride-`channels` prefix sum of window deltas; exact integers, so identical to the scalar loop.
                        const k_vec: @Vector(B, AccumT) = @splat(k);
                        const r_vec: @Vector(B, AccumT) = @splat(residual);
                        const repeat_mask = comptime blk: {
                            var m: [B]i32 = undefined;
                            for (&m, 0..) |*m_e, j| m_e.* = @intCast(j % channels);
                            break :blk m;
                        };
                        const tail_mask = comptime blk: {
                            var m: [channels]i32 = undefined;
                            for (&m, 0..) |*m_e, t| m_e.* = @intCast(B - channels + t);
                            break :blk m;
                        };
                        // The last slide delta reads one pixel past the block, hence `+ channels`.
                        while (e + B + channels <= e_end) : (e += B) {
                            const firsts: @Vector(B, AccumT) = @intCast(@as(@Vector(B, SrcT), src.data[src_offset + e - tap ..][0..B].*));
                            const highs: @Vector(B, AccumT) = @intCast(@as(@Vector(B, SrcT), src.data[src_offset + e - tap + window ..][0..B].*));
                            const deltas = std.simd.prefixScan(.Add, channels, highs - firsts);
                            const w_vec = @shuffle(AccumT, sum, undefined, repeat_mask) +
                                std.simd.shiftElementsRight(deltas, channels, 0);
                            storeVec(k_vec * w_vec + r_vec * firsts, dst_row[e..].ptr);
                            sum += @shuffle(AccumT, deltas, undefined, tail_mask);
                        }
                    }

                    while (e < e_end) : (e += channels) {
                        const first: Lane = blk: {
                            const px: @Vector(channels, SrcT) = src.data[src_offset + e - tap ..][0..channels].*;
                            break :blk if (AccumT == f32) px else @intCast(px);
                        };
                        const out: Lane = @as(Lane, @splat(k)) * sum + @as(Lane, @splat(residual)) * first;
                        inline for (0..channels) |ch| dst_row[e + ch] = store(out[ch]);
                        if (e + channels < e_end) {
                            const next: @Vector(channels, SrcT) = src.data[src_offset + e - tap + window ..][0..channels].*;
                            sum += @as(Lane, if (AccumT == f32) next else @intCast(next)) - first;
                        }
                    }
                }

                borderColumns(src, dst_row, kernel, table, src_offset, table.high_start, cols);
            }
        }

        /// O(1)-per-pixel vertical pass for uniform-body kernels: SIMD column sums slide
        /// down the rows. Same exactness contract as `horizontalBox`.
        fn verticalBox(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            try verticalPass(io, src, dst, allocator, kernel, border_mode, BandContext.verticalBoxBand);
        }

        /// Interior rows `[r_start, r_end)` of the vertical box pass; the column sums are
        /// seeded at `r_start` (integer-exact, so bands match a single sweep).
        fn verticalBoxRows(src: Image(SrcT), dst: Image(DstT), kernel: []const KernelT, r_start: usize, r_end: usize) void {
            const half = kernel.len / 2;
            const len = kernel.len;
            const cols = src.cols;
            const seed_row = r_start - half;

            const k = promote(kernel[1]);
            const residual = promote(kernel[0]) - k;
            const k_vec: @Vector(vec_len, AccumT) = @splat(k);
            const r_vec: @Vector(vec_len, AccumT) = @splat(residual);
            var c: usize = 0;

            while (c + vec_len <= cols) : (c += vec_len) {
                var sum: @Vector(vec_len, AccumT) = @splat(0);
                for (0..len) |i| sum += loadVec(src.data[(seed_row + i) * src.stride + c ..].ptr);

                for (r_start..r_end) |r| {
                    const first = loadVec(src.data[(r - half) * src.stride + c ..].ptr);
                    storeVec(k_vec * sum + r_vec * first, dst.data[r * dst.stride + c ..].ptr);
                    if (r + 1 < r_end) {
                        sum += loadVec(src.data[(r - half + len) * src.stride + c ..].ptr) - first;
                    }
                }
            }

            while (c < cols) : (c += 1) {
                var sum: AccumT = 0;
                for (0..len) |i| sum += promote(src.data[(seed_row + i) * src.stride + c]);

                for (r_start..r_end) |r| {
                    const first = promote(src.data[(r - half) * src.stride + c]);
                    dst.data[r * dst.stride + c] = store(k * sum + residual * first);
                    if (r + 1 < r_end) {
                        sum += promote(src.data[(r - half + len) * src.stride + c]) - first;
                    }
                }
            }
        }
    };
}

/// Cache thresholds for the fused (ring-buffer) separable path: fuse only when the full
/// temp plane would clearly exceed cache but the ring of kernel rows stays resident.
const fused_min_temp_bytes: usize = 1 << 20;
const fused_max_ring_bytes: usize = 1 << 20;

fn useFusedSeparable(comptime TempT: type, rows: usize, cols: usize, kernel_y_len: usize, border_mode: BorderMode) bool {
    // .wrap needs far-end temp rows for the top border rows, which a sliding window lacks.
    if (border_mode == .wrap) return false;
    if (rows <= 2 * (kernel_y_len / 2)) return false;
    const temp_bytes = rows * cols * @sizeOf(TempT);
    const ring_bytes = kernel_y_len * cols * @sizeOf(TempT);
    return temp_bytes > fused_min_temp_bytes and ring_bytes <= fused_max_ring_bytes;
}

/// Separable convolution with the horizontal producer and vertical consumer fused over a
/// ring of `kernel_y.len` temp rows, avoiding the full-plane temp round-trip to DRAM.
/// Bit-exact with `convolveSeparablePlane` for the border modes the gate admits.
fn convolveSeparablePlaneFused(
    comptime PixelT: type,
    comptime TempT: type,
    comptime AccumIntT: type,
    comptime channels: usize,
    io: Io,
    bands: usize,
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    const Fused = FusedSeparable(PixelT, TempT, AccumIntT, channels);
    const rows = src_img.rows;
    const cols = src_img.cols;
    const klen_y = kernel_y.len;

    const h_table: BorderIndexTable = try .init(allocator, cols / channels, kernel_x.len, border_mode);
    defer h_table.deinit(allocator);
    const v_table: BorderIndexTable = try .init(allocator, rows, klen_y, border_mode);
    defer v_table.deinit(allocator);
    // Each band owns a ring of `klen_y` temp rows plus its tap base offsets.
    const rings = try allocator.alloc(TempT, bands * klen_y * cols);
    defer allocator.free(rings);
    const bases = try allocator.alloc(usize, bands * klen_y);
    defer allocator.free(bases);

    const ctx: Fused = .{
        .src = src_img,
        .dst = dst_img,
        .kernel_x = kernel_x,
        .kernel_y = kernel_y,
        .h_table = h_table,
        .v_table = v_table,
        .rings = rings,
        .bases = bases,
    };
    parallel.forRowBands(io, rows, bands, &ctx, Fused.rowBand);
}

/// Shared state of the fused separable bands; see `convolveSeparablePlaneFused`.
fn FusedSeparable(comptime PixelT: type, comptime TempT: type, comptime AccumIntT: type, comptime channels: usize) type {
    return struct {
        const HPass = SeparablePass(PixelT, TempT, AccumIntT, channels);
        const VPass = SeparablePass(TempT, PixelT, AccumIntT, channels);

        src: Image(PixelT),
        dst: Image(PixelT),
        kernel_x: []const TempT,
        kernel_y: []const TempT,
        h_table: BorderIndexTable,
        v_table: BorderIndexTable,
        rings: []TempT,
        bases: []usize,

        /// Output rows `[r0, r1)` from a ring of temp rows produced on demand. Temp row `tr`
        /// always lives in ring slot `tr % klen_y`.
        fn rowBand(ctx: *const @This(), band: usize, r0: usize, r1: usize) void {
            const rows = ctx.src.rows;
            const cols = ctx.src.cols;
            const kernel_x = ctx.kernel_x;
            const kernel_y = ctx.kernel_y;
            const klen_y = kernel_y.len;
            const half_y = klen_y / 2;
            const ring = ctx.rings[band * klen_y * cols ..][0 .. klen_y * cols];
            const bases = ctx.bases[band * klen_y ..][0..klen_y];
            const h_folded = HPass.isSymmetric(kernel_x);
            const v_folded = VPass.isSymmetric(kernel_y);
            const h_dense = HPass.isDense(kernel_x);
            const v_dense = VPass.isDense(kernel_y);

            // Interior rows start at r - half_y; bottom border rows tap the final window, so a late band seeds from there.
            var produced: usize = @min(r0 -| half_y, rows -| klen_y);
            for (r0..r1) |r| {
                // Interior rows need up to klen_y - 1 - half_y below r; border rows the initial or final window.
                const need = @min(rows - 1, @max(klen_y - 1, r + klen_y - 1 - half_y));
                while (produced <= need) : (produced += 1) {
                    const temp_row = ring[(produced % klen_y) * cols ..][0..cols];
                    if (h_dense) HPass.horizontalRow(true, ctx.src, temp_row, produced, kernel_x, ctx.h_table, h_folded) else HPass.horizontalRow(false, ctx.src, temp_row, produced, kernel_x, ctx.h_table, h_folded);
                }
                if (r >= half_y and r + half_y < rows) {
                    // Consecutive temp rows occupy consecutive ring slots, wrapping at most once.
                    var slot = (r - half_y) % klen_y;
                    for (bases) |*b| {
                        b.* = slot * cols;
                        slot = if (slot + 1 == klen_y) 0 else slot + 1;
                    }
                    if (v_dense) VPass.verticalRowFromBases(false, true, ring, bases, ctx.dst, r, kernel_y, v_folded) else VPass.verticalRowFromBases(false, false, ring, bases, ctx.dst, r, kernel_y, v_folded);
                } else {
                    for (bases, ctx.v_table.taps(ctx.v_table.ordinalOf(r))) |*b, resolved| {
                        b.* = if (resolved == BorderIndexTable.zero_sentinel)
                            BorderIndexTable.zero_sentinel
                        else
                            (resolved % klen_y) * cols;
                    }
                    VPass.verticalRowFromBases(true, false, ring, bases, ctx.dst, r, kernel_y, false);
                }
            }
        }
    };
}

/// Standard two-pass separable convolution through a full-size temp plane.
fn convolveSeparablePlane(
    comptime PixelT: type,
    comptime TempT: type,
    comptime AccumIntT: type,
    comptime channels: usize,
    io: Io,
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    temp_img: Image(TempT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    try SeparablePass(PixelT, TempT, AccumIntT, channels).horizontal(io, src_img, temp_img, allocator, kernel_x, border_mode);
    try SeparablePass(TempT, PixelT, AccumIntT, channels).vertical(io, temp_img, dst_img, allocator, kernel_y, border_mode);
}

test "fused separable matches standard path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    inline for ([_]type{ u8, f32 }) |T| {
        const TempT = if (T == u8) i32 else f32;
        const kernels = [_][]const f32{
            &.{ 0.1, 0.2, 0.4, 0.2, 0.1 },
            &.{ 0.25, 0.25, 0.25, 0.25 },
        };
        for (kernels) |kernel_f32| {
            for ([_]BorderMode{ .zero, .replicate, .mirror }) |mode| {
                var src: Image(T) = try .init(allocator, 40, 33);
                defer src.deinit(allocator);
                for (src.data) |*px| px.* = if (T == u8) random.int(u8) else 255 * random.float(f32);

                var expected: Image(T) = try .initLike(allocator, src);
                defer expected.deinit(allocator);
                var actual: Image(T) = try .initLike(allocator, src);
                defer actual.deinit(allocator);

                const kernel = if (T == u8) try scaleKernelToInt(allocator, kernel_f32) else kernel_f32;
                defer if (T == u8) allocator.free(kernel);

                var temp: Image(TempT) = try .initLike(allocator, src);
                defer temp.deinit(allocator);
                inline for ([_]type{ i32, i64 }) |AccumIntT| {
                    try convolveSeparablePlane(T, TempT, AccumIntT, 1, io, src, expected, temp, allocator, kernel, kernel, mode);
                    // 13 bands of 3 rows are shorter than the kernel, so late bands seed from the final window.
                    for ([_]usize{ 1, 5, 13 }) |bands| {
                        try convolveSeparablePlaneFused(T, TempT, AccumIntT, 1, io, bands, src, actual, allocator, kernel, kernel, mode);
                        try testing.expectEqualSlices(T, expected.data, actual.data);
                    }
                }
            }
        }
    }
}

// Every interleaved strategy must match the same kernels run per channel as a plane.
test "interleaved separable matches per-channel planes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const Rgb = @import("../color.zig").Rgb(u8);
    const Rgba = @import("../color.zig").Rgba(u8);

    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    const gaussian_5 = [_]f32{ 0.1, 0.2, 0.4, 0.2, 0.1 };
    const uniform_5 = [_]f32{ 0.2, 0.2, 0.2, 0.2, 0.2 };
    const identity = [_]f32{1};
    const wide_11 = [_]f32{ 0.02, 0.04, 0.08, 0.12, 0.16, 0.16, 0.16, 0.12, 0.08, 0.04, 0.02 };
    const kernels = [_][2][]const f32{
        .{ &gaussian_5, &gaussian_5 },
        .{ &uniform_5, &identity },
        .{ &identity, &uniform_5 },
        .{ &uniform_5, &gaussian_5 },
        .{ &wide_11, &wide_11 },
    };

    inline for ([_]type{ Rgb, Rgba }) |T| {
        const n = comptime Image(T).channels();
        // 37 columns leave a vector tail; the fused path is driven explicitly below its size threshold.
        var src: Image(T) = try .init(allocator, 41, 37);
        defer src.deinit(allocator);
        for (std.mem.sliceAsBytes(src.data)) |*b| b.* = random.int(u8);

        var expected: Image(T) = try .initLike(allocator, src);
        defer expected.deinit(allocator);
        var actual: Image(T) = try .initLike(allocator, src);
        defer actual.deinit(allocator);
        var plane_src: Image(u8) = try .init(allocator, src.rows, src.cols);
        defer plane_src.deinit(allocator);
        var plane_dst: Image(u8) = try .init(allocator, src.rows, src.cols);
        defer plane_dst.deinit(allocator);

        for (kernels) |pair| {
            for ([_]BorderMode{ .zero, .replicate, .mirror, .wrap }) |mode| {
                // Reference: each channel through the u8 path.
                for (0..n) |ch| {
                    for (plane_src.data, 0..) |*px, i| px.* = std.mem.sliceAsBytes(src.data)[i * n + ch];
                    try convolveSeparable(u8, io, plane_src, plane_dst, allocator, pair[0], pair[1], mode);
                    for (plane_dst.data, 0..) |px, i| std.mem.sliceAsBytes(expected.data)[i * n + ch] = px;
                }

                try convolveSeparable(T, io, src, actual, allocator, pair[0], pair[1], mode);
                try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.data), std.mem.sliceAsBytes(actual.data));

                if (mode != .wrap and !isIdentityKernel(pair[0]) and !isIdentityKernel(pair[1])) {
                    const kx = try scaleKernelToInt(allocator, pair[0]);
                    defer allocator.free(kx);
                    const ky = try scaleKernelToInt(allocator, pair[1]);
                    defer allocator.free(ky);
                    for ([_]usize{ 1, 4 }) |bands| {
                        try convolveSeparablePlaneFused(u8, i32, i32, n, io, bands, elementView(T, src), elementView(T, actual), allocator, kx, ky, mode);
                        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.data), std.mem.sliceAsBytes(actual.data));
                    }
                }
            }
        }
    }
}

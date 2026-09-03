const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const parallel = @import("parallel.zig");

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
    return @intCast(@max(zero_vec, @min(max_vec, shifted)));
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

        /// Load/store policy shared with the single separable pass (same src/dst type).
        const Pixels = SeparablePass(T, T, i32);
        /// Taps and accumulators share one scalar: i32 fixed-point for u8 (|accum| <= 255 *
        /// sum|k| fits for kernel magnitude sums up to ~32k in weight units), f32 otherwise.
        const Scalar = Pixels.AccumT;
        const vec_len = Pixels.vec_len;

        /// Flattens a 2D kernel into a 1D array; for `u8` images, values are scaled by
        /// `fixed_point_scale`, rounded, and sum-corrected to preserve the kernel's gain.
        fn flatten(kernel: anytype) [size]Scalar {
            var weights: [size]f32 = undefined;
            inline for (0..rows) |kr| {
                inline for (0..cols) |kx| {
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
            inline for (0..cols) |kx| {
                taps[kx] = border.resolveIndex(@as(isize, @intCast(c)) + @as(isize, kx) - half_w, @intCast(src_cols), border_mode);
            }
            return taps;
        }

        /// One border-column pixel from pre-resolved row offsets and column taps.
        fn convolveBorderPixel(comptime n: usize, src: Image(T), dsts: [n]Image(T), row_offsets: RowOffsets(true), col_taps: ColTaps, kernels: [n][size]Scalar, r: usize, c: usize) void {
            var results: [n]Scalar = @splat(0);
            inline for (0..rows) |ky| {
                if (row_offsets[ky]) |base| {
                    inline for (0..cols) |kx| {
                        if (col_taps[kx]) |sc| {
                            const pixel_val = Pixels.promote(src.data[base + sc]);
                            inline for (0..n) |i| {
                                results[i] += pixel_val * kernels[i][ky * cols + kx];
                            }
                        }
                    }
                }
            }
            inline for (0..n) |i| {
                dsts[i].data[r * dsts[i].stride + c] = Pixels.store(results[i]);
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
                inline for (0..rows) |ky| {
                    // Runtime `continue` is not allowed in an inline for; the wrapping
                    // `if` folds away at comptime when `maybe_zero` is false.
                    if (if (maybe_zero) row_offsets[ky] != null else true) {
                        const base = if (maybe_zero) row_offsets[ky].? else row_offsets[ky];
                        inline for (0..cols) |kx| {
                            const pixel_vec = Pixels.loadVec(src.data[base + c + kx - half_w ..].ptr);
                            inline for (0..n) |i| {
                                result_vecs[i] += pixel_vec * kernel_vecs[i][ky * cols + kx];
                            }
                        }
                    }
                }
                inline for (0..n) |i| {
                    Pixels.storeVec(result_vecs[i], dsts[i].data[r * dsts[i].stride + c ..].ptr);
                }
            }

            while (c < c_end) : (c += 1) {
                var results: [n]Scalar = @splat(0);
                inline for (0..rows) |ky| {
                    if (if (maybe_zero) row_offsets[ky] != null else true) {
                        const base = if (maybe_zero) row_offsets[ky].? else row_offsets[ky];
                        inline for (0..cols) |kx| {
                            const pixel_val = Pixels.promote(src.data[base + c + kx - half_w]);
                            inline for (0..n) |i| {
                                results[i] += pixel_val * kernels[i][ky * cols + kx];
                            }
                        }
                    }
                }
                inline for (0..n) |i| {
                    dsts[i].data[r * dsts[i].stride + c] = Pixels.store(results[i]);
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
                inline for (0..size) |j| {
                    ctx.kernel_vecs[i][j] = @splat(kernels[i][j]);
                }
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
                        inline for (0..rows) |ky| {
                            const resolved = border.resolveIndex(ir + @as(isize, ky) - half_h, @intCast(src.rows), ctx.border_mode);
                            offs[ky] = if (resolved) |sr| sr * src.stride else null;
                        }

                        for (0..ctx.low_end) |c| {
                            convolveBorderPixel(n, src, ctx.dsts, offs, ctx.col_taps[c], ctx.kernels, r, c);
                        }
                        if (r >= half_h and r + half_h < src.rows) {
                            var in_band: RowOffsets(false) = undefined;
                            inline for (0..rows) |ky| in_band[ky] = offs[ky].?;
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
                        io: Io,
                        kernel: [Kernel.size]i32,

                        fn convolvePlane(ctx: @This(), src: Image(u8), dst: Image(u8), mode: BorderMode) !void {
                            Kernel.convolveMulti(1, ctx.io, src, .{dst}, .{ctx.kernel}, mode);
                        }
                    };
                    try convolvePlanes(T, self, out, allocator, sumTaps(&kernel_int), fixed_point_scale, border_mode, PlaneCtx{ .io = io, .kernel = kernel_int });
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
fn convolvePlanes(
    comptime T: type,
    image: Image(T),
    out: Image(T),
    allocator: Allocator,
    kernel_sum: i64,
    comptime scale: comptime_int,
    border_mode: BorderMode,
    ctx: anytype,
) !void {
    const plane_size = image.rows * image.cols;

    const split = try channel_ops.splitChannelsWithUniform(T, image, allocator);
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
                try ctx.convolvePlane(src_plane, dst_plane, border_mode);
            }
        }
    }
    channel_ops.mergeChannels(T, final_channels, out);
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
/// per-plane driver.
fn convolveSeparableAuto(
    comptime PixelT: type,
    comptime TempT: type,
    io: Io,
    src: Image(PixelT),
    dst: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
    cached_temp: ?*[]TempT,
) !void {
    // i32 accumulators run 8 real SIMD lanes; i64 halves throughput on AVX2 (emulated
    // multiplies), so it is kept only as the overflow fallback for pathological kernels.
    if (TempT == i32 and !narrowAccumFits(kernel_x, kernel_y)) {
        return convolveSeparableAutoImpl(PixelT, TempT, i64, io, src, dst, allocator, kernel_x, kernel_y, border_mode, cached_temp);
    }
    return convolveSeparableAutoImpl(PixelT, TempT, i32, io, src, dst, allocator, kernel_x, kernel_y, border_mode, cached_temp);
}

/// Per-plane separable driver owning the strategy choice: identity axes skip their pass
/// entirely, uniform-body kernels take the O(1)/pixel running-sum box passes, large
/// planes take the fused ring path, and everything else runs the standard two-pass over
/// a temp plane.
/// `cached_temp` lets struct-pixel callers reuse one temp allocation across planes.
fn convolveSeparableAutoImpl(
    comptime PixelT: type,
    comptime TempT: type,
    comptime AccumIntT: type,
    io: Io,
    src: Image(PixelT),
    dst: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
    cached_temp: ?*[]TempT,
) !void {
    const identity_x = isIdentityKernel(kernel_x);
    const identity_y = isIdentityKernel(kernel_y);
    const SinglePass = SeparablePass(PixelT, PixelT, AccumIntT);

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
        // Each band re-runs the horizontal pass over `kernel_y.len` halo rows, so bands stay at
        // least four kernel heights tall.
        const bands = @max(1, @min(parallel.bandCount(src.rows, src.cols), src.rows / (4 * kernel_y.len)));
        try convolveSeparablePlaneFused(PixelT, TempT, AccumIntT, io, bands, src, dst, allocator, kernel_x, kernel_y, border_mode);
    } else {
        var owned: []TempT = &.{};
        defer allocator.free(owned);
        const temp_slot = cached_temp orelse &owned;
        if (temp_slot.len == 0) temp_slot.* = try allocator.alloc(TempT, @as(usize, src.rows) * src.cols);
        const temp = Image(TempT).initFromSlice(src.rows, src.cols, temp_slot.*);
        try convolveSeparablePlane(PixelT, TempT, AccumIntT, io, src, dst, temp, allocator, kernel_x, kernel_y, border_mode);
    }
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
        try convolveSeparableAuto(f32, f32, io, image, out, allocator, kernel_x, kernel_y, border_mode, null);
    } else {
        // u8 planes, bare or struct fields, run on quantized kernels.
        const kernel_x_int = try scaleKernelToInt(allocator, kernel_x);
        defer allocator.free(kernel_x_int);
        const kernel_y_int = try scaleKernelToInt(allocator, kernel_y);
        defer allocator.free(kernel_y_int);

        if (T == u8) {
            try convolveSeparableAuto(u8, i32, io, image, out, allocator, kernel_x_int, kernel_y_int, border_mode, null);
        } else {
            const PlaneCtx = struct {
                io: Io,
                allocator: Allocator,
                kernel_x: []const i32,
                kernel_y: []const i32,
                temp: []i32 = &.{},

                fn convolvePlane(ctx: *@This(), src: Image(u8), dst: Image(u8), mode: BorderMode) !void {
                    try convolveSeparableAuto(u8, i32, ctx.io, src, dst, ctx.allocator, ctx.kernel_x, ctx.kernel_y, mode, &ctx.temp);
                }
            };
            var ctx: PlaneCtx = .{ .io = io, .allocator = allocator, .kernel_x = kernel_x_int, .kernel_y = kernel_y_int };
            defer allocator.free(ctx.temp);
            // The separable kernel sum is the product of the 1D sums, one `fixed_point_scale` each.
            const kernel_sum = sumTaps(kernel_x_int) * sumTaps(kernel_y_int);
            try convolvePlanes(T, image, out, allocator, kernel_sum, fixed_point_scale_sq, border_mode, &ctx);
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
/// width (i32 when `narrowAccumFits`, else i64); ignored for f32 passes.
fn SeparablePass(comptime SrcT: type, comptime DstT: type, comptime AccumIntT: type) type {
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

        inline fn storeVec(val: @Vector(vec_len, AccumT), ptr: [*]DstT) void {
            switch (DstT) {
                u8 => ptr[0..vec_len].* = divClampU8Vec(dst_scale, val),
                i32 => if (AccumT == i32) {
                    ptr[0..vec_len].* = val;
                } else {
                    const min_vec: @Vector(vec_len, i64) = @splat(std.math.minInt(i32));
                    const max_vec: @Vector(vec_len, i64) = @splat(std.math.maxInt(i32));
                    const narrowed: @Vector(vec_len, i32) = @intCast(@max(min_vec, @min(max_vec, val)));
                    ptr[0..vec_len].* = narrowed;
                },
                f32 => ptr[0..vec_len].* = val,
                else => unreachable,
            }
        }

        /// Full-kernel accumulation for one border pixel from pre-resolved column indices
        /// (full kernel, zero adds included, to keep f32 accumulation order).
        inline fn borderPixelResolved(src: Image(SrcT), kernel: []const KernelT, tap_idx: []const usize, src_offset: usize) AccumT {
            var result: AccumT = 0;
            for (kernel, tap_idx) |k, idx| {
                const pv: SrcT = if (idx == BorderIndexTable.zero_sentinel) 0 else src.data[src_offset + idx];
                result += promote(pv) * promote(k);
            }
            return result;
        }

        /// One row of the horizontal pass into a caller-provided contiguous row buffer.
        /// Kept out of line: inlined into the fused driver it measured 4-8% slower.
        noinline fn horizontalRow(comptime dense: bool, src: Image(SrcT), dst_row: []DstT, r: usize, kernel: []const KernelT, table: BorderIndexTable, folded: bool) void {
            const half = kernel.len / 2;
            const cols = src.cols;
            const src_offset = r * src.stride;
            var c: usize = 0;

            while (c < table.low_end) : (c += 1) {
                dst_row[c] = store(borderPixelResolved(src, kernel, table.taps(c), src_offset));
            }

            if (cols > 2 * half) {
                const interior_end = cols - half;

                if (folded) {
                    while (c + vec_len <= interior_end) : (c += vec_len) {
                        const base = src_offset + c - half;
                        var acc: @Vector(vec_len, AccumT) = @splat(0);
                        for (kernel[0..half], 0..) |k, i| {
                            if (!isNegligible(dense, k)) {
                                const a = loadVec(src.data[base + i ..].ptr);
                                const b = loadVec(src.data[base + (kernel.len - 1 - i) ..].ptr);
                                acc += (a + b) * splatK(k);
                            }
                        }
                        if (!isNegligible(dense, kernel[half])) {
                            acc += loadVec(src.data[base + half ..].ptr) * splatK(kernel[half]);
                        }
                        storeVec(acc, dst_row[c..].ptr);
                    }
                } else {
                    while (c + vec_len <= interior_end) : (c += vec_len) {
                        var acc: @Vector(vec_len, AccumT) = @splat(0);
                        for (kernel, 0..) |k, ki| {
                            if (!isNegligible(dense, k)) {
                                acc += loadVec(src.data[src_offset + c + ki - half ..].ptr) * splatK(k);
                            }
                        }
                        storeVec(acc, dst_row[c..].ptr);
                    }
                }

                while (c < interior_end) : (c += 1) {
                    var result: AccumT = 0;
                    const c0 = c - half;
                    for (kernel, 0..) |k, i| {
                        if (!isNegligible(dense, k)) {
                            result += promote(src.data[src_offset + c0 + i]) * promote(k);
                        }
                    }
                    dst_row[c] = store(result);
                }
            }

            while (c < cols) : (c += 1) {
                dst_row[c] = store(borderPixelResolved(src, kernel, table.taps(table.ordinalOf(c)), src_offset));
            }
        }

        /// Row-major 1D pass along columns (src -> dst).
        fn horizontal(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const table: BorderIndexTable = try .init(allocator, src.cols, kernel.len, border_mode);
            defer table.deinit(allocator);
            const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel, .table = table };
            parallel.forRowBands(io, src.rows, parallel.bandCount(src.rows, src.cols), &ctx, BandContext.horizontalBand);
        }

        /// Read-only state shared by the row bands of the 1-D passes; `table` resolves the
        /// border columns and is only needed by the horizontal passes.
        const BandContext = struct {
            src: Image(SrcT),
            dst: Image(DstT),
            kernel: []const KernelT,
            table: ?BorderIndexTable = null,

            fn horizontalBand(ctx: *const BandContext, _: usize, r0: usize, r1: usize) void {
                const folded = isSymmetric(ctx.kernel);
                const dense = isDense(ctx.kernel);
                for (r0..r1) |r| {
                    const dst_row = ctx.dst.data[r * ctx.dst.stride ..][0..ctx.src.cols];
                    if (dense) horizontalRow(true, ctx.src, dst_row, r, ctx.kernel, ctx.table.?, folded) else horizontalRow(false, ctx.src, dst_row, r, ctx.kernel, ctx.table.?, folded);
                }
            }

            /// Bands cover the interior rows `[half, rows - half)`, offset here.
            fn verticalBand(ctx: *const BandContext, _: usize, r0: usize, r1: usize) void {
                const half = ctx.kernel.len / 2;
                const folded = isSymmetric(ctx.kernel);
                if (isDense(ctx.kernel)) {
                    verticalTiles(true, ctx.src, ctx.dst, ctx.kernel, folded, half + r0, half + r1);
                } else {
                    verticalTiles(false, ctx.src, ctx.dst, ctx.kernel, folded, half + r0, half + r1);
                }
            }

            fn horizontalBoxBand(ctx: *const BandContext, _: usize, r0: usize, r1: usize) void {
                horizontalBoxRows(ctx.src, ctx.dst, ctx.kernel, ctx.table.?, r0, r1);
            }

            fn verticalBoxBand(ctx: *const BandContext, _: usize, r0: usize, r1: usize) void {
                const half = ctx.kernel.len / 2;
                verticalBoxRows(ctx.src, ctx.dst, ctx.kernel, half + r0, half + r1);
            }
        };

        /// Emits the top/bottom border rows from a row-resolved table; shared by the
        /// dense and box vertical passes.
        fn verticalBorderRows(src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const table: BorderIndexTable = try .init(allocator, src.rows, kernel.len, border_mode);
            defer table.deinit(allocator);
            const bases = try allocator.alloc(usize, kernel.len);
            defer allocator.free(bases);

            const border_rows = [_][2]usize{
                .{ 0, table.low_end },
                .{ table.high_start, src.rows },
            };
            for (border_rows) |range| {
                for (range[0]..range[1]) |r| {
                    for (bases, table.taps(table.ordinalOf(r))) |*b, idx| {
                        b.* = if (idx == BorderIndexTable.zero_sentinel) idx else idx * src.stride;
                    }
                    verticalRowFromBases(true, false, src.data, bases, dst, r, kernel, false);
                }
            }
        }

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
            const half = kernel.len / 2;
            if (src.rows > 2 * half) {
                // Interior rows [half, rows - half) in bands; each band tiles its columns.
                const interior = src.rows - 2 * half;
                const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel };
                parallel.forRowBands(io, interior, parallel.bandCount(interior, src.cols), &ctx, BandContext.verticalBand);
            }
            try verticalBorderRows(src, dst, allocator, kernel, border_mode);
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
            const table: BorderIndexTable = try .init(allocator, src.cols, kernel.len, border_mode);
            defer table.deinit(allocator);
            const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel, .table = table };
            parallel.forRowBands(io, src.rows, parallel.bandCount(src.rows, src.cols), &ctx, BandContext.horizontalBoxBand);
        }

        fn horizontalBoxRows(src: Image(SrcT), dst: Image(DstT), kernel: []const KernelT, table: BorderIndexTable, r_start: usize, r_end: usize) void {
            const half = kernel.len / 2;
            const len = kernel.len;
            const cols = src.cols;

            const k = promote(kernel[1]);
            const residual = promote(kernel[0]) - k;

            for (r_start..r_end) |r| {
                const src_offset = r * src.stride;
                const dst_offset = r * dst.stride;
                var c: usize = 0;

                while (c < table.low_end) : (c += 1) {
                    dst.data[dst_offset + c] = store(borderPixelResolved(src, kernel, table.taps(c), src_offset));
                }

                if (cols > 2 * half) {
                    const interior_end = cols - half;
                    var sum: AccumT = 0;
                    for (0..len) |i| sum += promote(src.data[src_offset + c - half + i]);

                    if (AccumT == i32 and SrcT == u8) {
                        // The serial running sum vectorizes as an exclusive prefix sum of
                        // window deltas (exact integers -> identical to the scalar loop).
                        const k_vec: @Vector(vec_len, AccumT) = @splat(k);
                        const r_vec: @Vector(vec_len, AccumT) = @splat(residual);
                        // The last slide delta reads src[c + vec_len - 1 - half + len],
                        // hence the +1 in the bound.
                        while (c + vec_len + 1 <= interior_end) : (c += vec_len) {
                            const firsts = loadVec(src.data[src_offset + c - half ..].ptr);
                            const highs = loadVec(src.data[src_offset + c - half + len ..].ptr);
                            const deltas = std.simd.prefixScan(.Add, 1, highs - firsts);
                            const w_vec = @as(@Vector(vec_len, AccumT), @splat(sum)) +
                                std.simd.shiftElementsRight(deltas, 1, 0);
                            storeVec(k_vec * w_vec + r_vec * firsts, dst.data[dst_offset + c ..].ptr);
                            sum += deltas[vec_len - 1];
                        }
                    }

                    while (c < interior_end) : (c += 1) {
                        const first = promote(src.data[src_offset + c - half]);
                        dst.data[dst_offset + c] = store(k * sum + residual * first);
                        if (c + 1 < interior_end) {
                            sum += promote(src.data[src_offset + c - half + len]) - first;
                        }
                    }
                }

                while (c < cols) : (c += 1) {
                    dst.data[dst_offset + c] = store(borderPixelResolved(src, kernel, table.taps(table.ordinalOf(c)), src_offset));
                }
            }
        }

        /// O(1)-per-pixel vertical pass for uniform-body kernels: SIMD column sums slide
        /// down the rows. Same exactness contract as `horizontalBox`.
        fn verticalBox(io: Io, src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const half = kernel.len / 2;
            if (src.rows > 2 * half) {
                const interior = src.rows - 2 * half;
                const ctx: BandContext = .{ .src = src, .dst = dst, .kernel = kernel };
                parallel.forRowBands(io, interior, parallel.bandCount(interior, src.cols), &ctx, BandContext.verticalBoxBand);
            }
            try verticalBorderRows(src, dst, allocator, kernel, border_mode);
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
    io: Io,
    bands: usize,
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    const Fused = FusedSeparable(PixelT, TempT, AccumIntT);
    const rows = src_img.rows;
    const cols = src_img.cols;
    const klen_y = kernel_y.len;

    const h_table: BorderIndexTable = try .init(allocator, cols, kernel_x.len, border_mode);
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
fn FusedSeparable(comptime PixelT: type, comptime TempT: type, comptime AccumIntT: type) type {
    return struct {
        const HPass = SeparablePass(PixelT, TempT, AccumIntT);
        const VPass = SeparablePass(TempT, PixelT, AccumIntT);

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

            // Interior rows tap temp rows from r - half_y; bottom border rows tap the final
            // window [rows - klen_y, rows), so a band starting late still produces from there.
            var produced: usize = @min(r0 -| half_y, rows -| klen_y);
            for (r0..r1) |r| {
                // Interior rows tap temp rows up to klen_y - 1 - half_y below r; top border rows tap
                // the initial window and bottom border rows the final one.
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
    io: Io,
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    temp_img: Image(TempT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    try SeparablePass(PixelT, TempT, AccumIntT).horizontal(io, src_img, temp_img, allocator, kernel_x, border_mode);
    try SeparablePass(TempT, PixelT, AccumIntT).vertical(io, temp_img, dst_img, allocator, kernel_y, border_mode);
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
                    try convolveSeparablePlane(T, TempT, AccumIntT, io, src, expected, temp, allocator, kernel, kernel, mode);
                    // 13 bands of 3 rows are shorter than the kernel, so late bands must seed
                    // their ring from the final window.
                    for ([_]usize{ 1, 5, 13 }) |bands| {
                        try convolveSeparablePlaneFused(T, TempT, AccumIntT, io, bands, src, actual, allocator, kernel, kernel, mode);
                        try testing.expectEqualSlices(T, expected.data, actual.data);
                    }
                }
            }
        }
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;

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

/// Quantizes an f32 kernel weight to `fixed_point_scale` fixed-point.
inline fn quantizeWeight(weight: f32) i32 {
    return @round(weight * fixed_point_scale);
}

/// Corrects independently-rounded taps so their sum matches the f32 kernel's intended
/// gain: the residual lands on the largest-magnitude tap (relative error <= 1/|k_max|).
/// Without this, correlated rounding drifts the overall gain — a uniform 1/30 kernel
/// quantizes to 30*9 = 270/256, brightening by +5.5% and clipping highlights.
/// For all-equal taps the strict `>` puts the residual on tap 0 — `isUniformBody`
/// relies on that shape to detect uniform kernels after quantization.
fn renormalizeQuantized(taps: []i32, weight_sum: f64) void {
    if (taps.len == 0) return;
    const target: i64 = @round(fixed_point_scale * weight_sum);
    var sum: i64 = 0;
    var largest: usize = 0;
    for (taps, 0..) |k, i| {
        sum += k;
        if (@abs(k) > @abs(taps[largest])) largest = i;
    }
    taps[largest] += @intCast(target - sum);
}

fn PixelIO(comptime T: type, comptime vec_len: usize, comptime scale: comptime_int) type {
    if (T != u8 and T != f32) {
        @compileError("PixelIO only supports u8 and f32 types");
    }

    return struct {
        // i32 is safe for any u8 2D kernel: |accum| <= 255 * sum|k| stays within i32 for
        // kernel magnitude sums up to ~8.4M fixed-point units (~32k in weight units).
        const Scalar = if (T == u8) i32 else f32;

        inline fn load(value: T) Scalar {
            return value;
        }

        inline fn loadVec(src: []const T, offset: usize) @Vector(vec_len, Scalar) {
            if (T == u8) {
                const u8_vec: @Vector(vec_len, u8) = src[offset..][0..vec_len].*;
                return @intCast(u8_vec);
            } else {
                return src[offset..][0..vec_len].*;
            }
        }

        inline fn store(accum: Scalar) T {
            return if (T == u8) divClampU8(scale, accum) else accum;
        }

        inline fn storeVec(accum_vec: @Vector(vec_len, Scalar), dst: []T, offset: usize) void {
            if (T == u8) {
                dst[offset..][0..vec_len].* = divClampU8Vec(scale, accum_vec);
            } else {
                dst[offset..][0..vec_len].* = accum_vec;
            }
        }
    };
}

fn ConvolutionKernel(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    if (T != u8 and T != f32) {
        @compileError("Unsupported kernel type: " ++ @typeName(T) ++ ". Only u8 and f32 are supported");
    }

    return struct {
        const size = rows * cols;
        const half_h = rows / 2;
        const half_w = cols / 2;

        const KernelScalar = if (T == u8) i32 else f32;
        const AccumScalar = if (T == u8) i32 else f32;

        const vec_len = std.simd.suggestVectorLength(AccumScalar) orelse 1;

        const Pixels = PixelIO(T, vec_len, fixed_point_scale);

        /// Flattens a 2D kernel into a 1D array; for `u8` images, values are scaled by
        /// `fixed_point_scale`, rounded, and sum-corrected to preserve the kernel's gain.
        fn flatten(kernel: anytype) [size]KernelScalar {
            var result: [size]KernelScalar = undefined;
            var weight_sum: f64 = 0;
            var idx: usize = 0;
            inline for (0..rows) |kr| {
                inline for (0..cols) |kx| {
                    const val = as(f32, kernel[kr][kx]);
                    result[idx] = if (T == u8) quantizeWeight(val) else val;
                    weight_sum += val;
                    idx += 1;
                }
            }
            if (T == u8) {
                renormalizeQuantized(&result, weight_sum);
            }
            return result;
        }

        fn convolvePixelWithBorder(comptime n: usize, src: Image(T), dsts: [n]Image(T), r: usize, c: usize, kernels: [n][size]KernelScalar, border_mode: BorderMode) void {
            const ir: isize = @intCast(r);
            const ic: isize = @intCast(c);
            var results: [n]AccumScalar = @splat(0);
            inline for (0..rows) |ky| {
                inline for (0..cols) |kx| {
                    const iry = ir + @as(isize, ky) - half_h;
                    const icx = ic + @as(isize, kx) - half_w;
                    const pixel_val: AccumScalar = border.getPixel(T, src, iry, icx, border_mode);
                    inline for (0..n) |i| {
                        const k_val: AccumScalar = kernels[i][ky * cols + kx];
                        results[i] += pixel_val * k_val;
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
            kernels: [n][size]KernelScalar,
            kernel_vecs: *const [n][size]@Vector(vec_len, AccumScalar),
            r: usize,
            c_start: usize,
            c_end: usize,
        ) void {
            var c = c_start;

            if (src.cols >= vec_len + 2 * half_w) {
                while (c + vec_len <= c_end) : (c += vec_len) {
                    var result_vecs: [n]@Vector(vec_len, AccumScalar) = @splat(@splat(0));
                    inline for (0..rows) |ky| {
                        // Runtime `continue` is not allowed in an inline for; the wrapping
                        // `if` folds away at comptime when `maybe_zero` is false.
                        if (if (maybe_zero) row_offsets[ky] != null else true) {
                            const base = if (maybe_zero) row_offsets[ky].? else row_offsets[ky];
                            inline for (0..cols) |kx| {
                                const pixel_vec = Pixels.loadVec(src.data, base + c + kx - half_w);
                                inline for (0..n) |i| {
                                    result_vecs[i] += pixel_vec * kernel_vecs[i][ky * cols + kx];
                                }
                            }
                        }
                    }
                    inline for (0..n) |i| {
                        Pixels.storeVec(result_vecs[i], dsts[i].data, r * dsts[i].stride + c);
                    }
                }
            }

            while (c < c_end) : (c += 1) {
                var results: [n]AccumScalar = @splat(0);
                inline for (0..rows) |ky| {
                    if (if (maybe_zero) row_offsets[ky] != null else true) {
                        const base = if (maybe_zero) row_offsets[ky].? else row_offsets[ky];
                        inline for (0..cols) |kx| {
                            const pixel_val = Pixels.load(src.data[base + c + kx - half_w]);
                            inline for (0..n) |i| {
                                const k_val: AccumScalar = kernels[i][ky * cols + kx];
                                results[i] += pixel_val * k_val;
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
        fn convolveMulti(comptime n: usize, src: Image(T), dsts: [n]Image(T), kernels: [n][size]KernelScalar, border_mode: BorderMode) void {
            var kernel_vecs: [n][size]@Vector(vec_len, AccumScalar) = undefined;
            inline for (0..n) |i| {
                inline for (0..size) |j| {
                    const k_val: AccumScalar = kernels[i][j];
                    kernel_vecs[i][j] = @splat(k_val);
                }
            }

            for (0..src.rows) |r| {
                var c: usize = 0;
                while (c < @min(half_w, src.cols)) : (c += 1) {
                    convolvePixelWithBorder(n, src, dsts, r, c, kernels, border_mode);
                }

                const safe_end = src.cols -| half_w;
                const row_in_band = r >= half_h and r + half_h < src.rows;
                if (row_in_band) {
                    var offs: RowOffsets(false) = undefined;
                    inline for (0..rows) |ky| {
                        offs[ky] = (r + ky - half_h) * src.stride;
                    }
                    convolveRowSpan(n, false, src, dsts, offs, kernels, &kernel_vecs, r, c, safe_end);
                } else {
                    const ir: isize = @intCast(r);
                    var offs: RowOffsets(true) = undefined;
                    inline for (0..rows) |ky| {
                        const resolved = border.resolveIndex(ir + @as(isize, ky) - half_h, @intCast(src.rows), border_mode);
                        offs[ky] = if (resolved) |sr| sr * src.stride else null;
                    }
                    convolveRowSpan(n, true, src, dsts, offs, kernels, &kernel_vecs, r, c, safe_end);
                }

                c = @max(c, safe_end);
                while (c < src.cols) : (c += 1) {
                    convolvePixelWithBorder(n, src, dsts, r, c, kernels, border_mode);
                }
            }
        }

        fn convolve(src: Image(T), dst: Image(T), kernel: [size]KernelScalar, border_mode: BorderMode) void {
            convolveMulti(1, src, .{dst}, .{kernel}, border_mode);
        }
    };
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
    Kernel.convolveMulti(2, self, .{ out_a, out_b }, .{ Kernel.flatten(kernel_a), Kernel.flatten(kernel_b) }, border_mode);
}

/// Applies a 2D convolution with the given kernel, writing into `out`.
pub fn convolve(comptime T: type, self: Image(T), out: Image(T), allocator: Allocator, kernel: anytype, border_mode: BorderMode) !void {
    const dims = comptime kernelDims(@TypeOf(kernel));
    const kernel_height = dims[0];
    const kernel_width = dims[1];

    switch (T) {
        u8, f32 => {
            const Kernel = ConvolutionKernel(T, kernel_height, kernel_width);
            const flat_kernel = Kernel.flatten(kernel);
            Kernel.convolve(self, out, flat_kernel, border_mode);
        },
        else => switch (@typeInfo(T)) {
            .@"struct" => {
                if (comptime meta.allFieldsAreU8(T)) {
                    const Kernel = ConvolutionKernel(u8, kernel_height, kernel_width);
                    const kernel_int = Kernel.flatten(kernel);
                    var kernel_sum: i64 = 0;
                    inline for (kernel_int) |weight| {
                        kernel_sum += weight;
                    }

                    const PlaneCtx = struct {
                        kernel: [Kernel.size]Kernel.KernelScalar,

                        fn convolvePlane(ctx: @This(), src: Image(u8), dst: Image(u8), mode: BorderMode) !void {
                            Kernel.convolve(src, dst, ctx.kernel, mode);
                        }
                    };
                    try convolvePlanes(T, self, out, allocator, kernel_sum, fixed_point_scale, border_mode, PlaneCtx{ .kernel = kernel_int });
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
    var weight_sum: f64 = 0;
    for (result, kernel) |*r, k| {
        r.* = quantizeWeight(k);
        weight_sum += k;
    }
    renormalizeQuantized(result, weight_sum);
    return result;
}

/// A 1-tap identity kernel makes its whole pass a copy; detected on the raw f32 kernel so
/// the check is shared by every pixel-type arm.
inline fn isIdentityKernel(kernel: []const f32) bool {
    return kernel.len == 1 and kernel[0] == 1;
}

/// True when all taps except possibly the first are equal — the shape of a quantized
/// uniform kernel after `renormalizeQuantized` parks the rounding residual on tap 0.
/// Such kernels (axis-aligned motion blur) collapse to an O(1)/pixel running sum.
fn isUniformBody(kernel: anytype) bool {
    if (kernel.len < 2) return false;
    const k = kernel[1];
    for (kernel[2..]) |tap| {
        if (tap != k) return false;
    }
    return true;
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
        return convolveSeparableAutoImpl(PixelT, TempT, i64, src, dst, allocator, kernel_x, kernel_y, border_mode, cached_temp);
    }
    return convolveSeparableAutoImpl(PixelT, TempT, i32, src, dst, allocator, kernel_x, kernel_y, border_mode, cached_temp);
}

/// Per-plane separable driver owning the strategy choice: identity axes skip their pass
/// entirely (a u8 single pass carries one `fixed_point_scale`, exact because
/// divTrunc(256*S ± 32768, 65536) == divTrunc(S ± 128, 256)), uniform-body kernels take
/// the O(1)/pixel running-sum box passes, large planes take the fused ring path, and
/// everything else runs the standard two-pass over a temp plane.
/// `cached_temp` lets struct-pixel callers reuse one temp allocation across planes.
fn convolveSeparableAutoImpl(
    comptime PixelT: type,
    comptime TempT: type,
    comptime AccumIntT: type,
    src: Image(PixelT),
    dst: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
    cached_temp: ?*[]TempT,
) !void {
    // In TempT units a 1-tap identity is exactly `one` (1.0 quantizes to fixed_point_scale).
    const one: TempT = if (TempT == i32) fixed_point_scale else 1;
    const identity_x = kernel_x.len == 1 and kernel_x[0] == one;
    const identity_y = kernel_y.len == 1 and kernel_y[0] == one;
    const SinglePass = SeparablePass(PixelT, PixelT, if (PixelT == u8) fixed_point_scale else 1, AccumIntT);

    if (identity_x and identity_y) {
        src.copy(dst);
    } else if (identity_y) {
        if (TempT == i32 and isUniformBody(kernel_x)) {
            try SinglePass.horizontalBox(src, dst, allocator, kernel_x, border_mode);
        } else {
            try SinglePass.horizontal(src, dst, allocator, kernel_x, border_mode);
        }
    } else if (identity_x) {
        if (TempT == i32 and isUniformBody(kernel_y)) {
            try SinglePass.verticalBox(src, dst, allocator, kernel_y, border_mode);
        } else {
            try SinglePass.vertical(src, dst, allocator, kernel_y, border_mode);
        }
    } else if (useFusedSeparable(TempT, src.rows, src.cols, kernel_y.len, border_mode)) {
        try convolveSeparablePlaneFused(PixelT, TempT, AccumIntT, src, dst, allocator, kernel_x, kernel_y, border_mode);
    } else if (cached_temp) |temp_slot| {
        if (temp_slot.len == 0) temp_slot.* = try allocator.alloc(TempT, @as(usize, src.rows) * src.cols);
        const temp = Image(TempT).initFromSlice(src.rows, src.cols, temp_slot.*);
        try convolveSeparablePlane(PixelT, TempT, AccumIntT, src, dst, temp, allocator, kernel_x, kernel_y, border_mode);
    } else {
        var temp = try Image(TempT).initLike(allocator, src);
        defer temp.deinit(allocator);
        try convolveSeparablePlane(PixelT, TempT, AccumIntT, src, dst, temp, allocator, kernel_x, kernel_y, border_mode);
    }
}

/// Separable convolution: applies two 1D kernels (horizontal then vertical).
/// Much faster than `convolve` for separable filters like Gaussian blur.
pub fn convolveSeparable(
    comptime T: type,
    image: Image(T),
    out: Image(T),
    allocator: Allocator,
    kernel_x: []const f32,
    kernel_y: []const f32,
    border_mode: BorderMode,
) !void {
    if (isIdentityKernel(kernel_x) and isIdentityKernel(kernel_y)) {
        image.copy(out);
        return;
    }

    switch (T) {
        u8 => {
            const kernel_x_int = try scaleKernelToInt(allocator, kernel_x);
            defer allocator.free(kernel_x_int);
            const kernel_y_int = try scaleKernelToInt(allocator, kernel_y);
            defer allocator.free(kernel_y_int);

            try convolveSeparableAuto(u8, i32, image, out, allocator, kernel_x_int, kernel_y_int, border_mode, null);
        },
        f32 => try convolveSeparableAuto(f32, f32, image, out, allocator, kernel_x, kernel_y, border_mode, null),
        else => switch (@typeInfo(T)) {
            .@"struct" => {
                if (comptime meta.allFieldsAreU8(T)) {
                    const kernel_x_int = try scaleKernelToInt(allocator, kernel_x);
                    defer allocator.free(kernel_x_int);
                    const kernel_y_int = try scaleKernelToInt(allocator, kernel_y);
                    defer allocator.free(kernel_y_int);

                    // Separable kernel sum is the product of 1D sums; each 1D sum is scaled by fixed_point_scale.
                    var kx_sum: i64 = 0;
                    for (kernel_x_int) |w| kx_sum += w;
                    var ky_sum: i64 = 0;
                    for (kernel_y_int) |w| ky_sum += w;

                    const PlaneCtx = struct {
                        allocator: Allocator,
                        kernel_x: []const i32,
                        kernel_y: []const i32,
                        temp: []i32 = &.{},

                        fn convolvePlane(ctx: *@This(), src: Image(u8), dst: Image(u8), mode: BorderMode) !void {
                            try convolveSeparableAuto(u8, i32, src, dst, ctx.allocator, ctx.kernel_x, ctx.kernel_y, mode, &ctx.temp);
                        }
                    };
                    var ctx: PlaneCtx = .{ .allocator = allocator, .kernel_x = kernel_x_int, .kernel_y = kernel_y_int };
                    defer allocator.free(ctx.temp);
                    try convolvePlanes(T, image, out, allocator, kx_sum * ky_sum, fixed_point_scale_sq, border_mode, &ctx);
                } else {
                    @compileError("Separable convolution only supports structs where all fields are u8. Type " ++ @typeName(T) ++ " is not supported.");
                }
            },
            else => @compileError("Separable convolution only supports u8, f32, and structs with all u8 fields. Type " ++ @typeName(T) ++ " is not supported."),
        },
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
        for (0..low_end) |pos| {
            for (0..kernel_len) |i| {
                indices[w] = resolveTap(pos, i, half, axis_len, border_mode);
                w += 1;
            }
        }
        for (high_start..axis_len) |pos| {
            for (0..kernel_len) |i| {
                indices[w] = resolveTap(pos, i, half, axis_len, border_mode);
                w += 1;
            }
        }
        return .{ .indices = indices, .kernel_len = kernel_len, .low_end = low_end, .high_start = high_start };
    }

    fn resolveTap(pos: usize, tap: usize, half: usize, axis_len: usize, border_mode: BorderMode) usize {
        const idx: isize = @as(isize, @intCast(pos)) + @as(isize, @intCast(tap)) - @as(isize, @intCast(half));
        return border.resolveIndex(idx, @intCast(axis_len), border_mode) orelse zero_sentinel;
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
/// source and destination scalar types. `dst_scale` is the fixed-point divisor applied
/// when storing to u8; pass 1 for i32/f32 destinations. `AccumIntT` selects the integer
/// accumulator width (i32 when `narrowAccumFits`, else i64); ignored for f32 passes.
fn SeparablePass(comptime SrcT: type, comptime DstT: type, comptime dst_scale: comptime_int, comptime AccumIntT: type) type {
    if (DstT != u8 and dst_scale != 1) {
        @compileError("dst_scale only applies to u8 destinations");
    }
    if (AccumIntT != i32 and AccumIntT != i64) {
        @compileError("AccumIntT must be i32 or i64");
    }

    return struct {
        const KernelT = if (SrcT == f32 or DstT == f32) f32 else i32;
        const AccumT = if (KernelT == f32) f32 else AccumIntT;
        const vec_len = std.simd.suggestVectorLength(KernelT) orelse 1;

        inline fn isNegligible(k: KernelT) bool {
            return if (KernelT == f32) @abs(k) < 1e-10 else k == 0;
        }

        /// Odd, mirror-symmetric kernels (every gaussian) can fold mirrored taps:
        /// (a + b) * k halves the multiplies. Integer-exact by distributivity, so the
        /// folded loops are used for i32 kernels only (f32 would change summation order).
        fn isSymmetric(kernel: []const KernelT) bool {
            // Folding measured slower past ~32 taps (two opposing load streams); the
            // dense multiply win only holds for short-to-medium kernels.
            if (kernel.len % 2 == 0 or kernel.len > 32) return false;
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
        fn horizontalRow(src: Image(SrcT), dst_row: []DstT, r: usize, kernel: []const KernelT, table: BorderIndexTable, folded: bool) void {
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
                            if (!isNegligible(k)) {
                                const a = loadVec(src.data[base + i ..].ptr);
                                const b = loadVec(src.data[base + (kernel.len - 1 - i) ..].ptr);
                                const k_vec: @Vector(vec_len, AccumT) = @splat(promote(k));
                                acc += (a + b) * k_vec;
                            }
                        }
                        if (!isNegligible(kernel[half])) {
                            const k_vec: @Vector(vec_len, AccumT) = @splat(promote(kernel[half]));
                            acc += loadVec(src.data[base + half ..].ptr) * k_vec;
                        }
                        storeVec(acc, dst_row[c..].ptr);
                    }
                } else {
                    while (c + vec_len <= interior_end) : (c += vec_len) {
                        var acc: @Vector(vec_len, AccumT) = @splat(0);
                        for (kernel, 0..) |k, ki| {
                            if (!isNegligible(k)) {
                                const vec = loadVec(src.data[src_offset + c + ki - half ..].ptr);
                                const k_vec: @Vector(vec_len, AccumT) = @splat(promote(k));
                                acc += vec * k_vec;
                            }
                        }
                        storeVec(acc, dst_row[c..].ptr);
                    }
                }

                while (c < interior_end) : (c += 1) {
                    var result: AccumT = 0;
                    const c0 = c - half;
                    for (kernel, 0..) |k, i| {
                        if (!isNegligible(k)) {
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
        fn horizontal(src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const cols = src.cols;
            const table: BorderIndexTable = try .init(allocator, cols, kernel.len, border_mode);
            defer table.deinit(allocator);
            const folded = KernelT == i32 and isSymmetric(kernel);

            for (0..src.rows) |r| {
                horizontalRow(src, dst.data[r * dst.stride ..][0..cols], r, kernel, table, folded);
            }
        }

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
                    verticalRowFromBases(true, src.data, bases, dst, r, kernel, false);
                }
            }
        }

        /// One vertical-pass output row combined from per-tap source row base offsets
        /// (`BorderIndexTable.zero_sentinel` = row of zeros). Border rows keep the full
        /// kernel with explicit zero adds; interior rows skip negligible taps — both
        /// matching the standard vertical pass per pixel.
        fn verticalRowFromBases(comptime border_row: bool, src_data: []const SrcT, bases: []const usize, dst: Image(DstT), r: usize, kernel: []const KernelT, folded: bool) void {
            const cols = dst.cols;
            const dst_offset = r * dst.stride;
            const half = kernel.len / 2;
            std.debug.assert(!(border_row and folded));
            var c: usize = 0;

            while (c + vec_len <= cols) : (c += vec_len) {
                var acc: @Vector(vec_len, AccumT) = @splat(0);
                if (folded) {
                    for (kernel[0..half], 0..) |k, i| {
                        if (!isNegligible(k)) {
                            const a = loadVec(src_data[bases[i] + c ..].ptr);
                            const b = loadVec(src_data[bases[kernel.len - 1 - i] + c ..].ptr);
                            const k_vec: @Vector(vec_len, AccumT) = @splat(promote(k));
                            acc += (a + b) * k_vec;
                        }
                    }
                    if (!isNegligible(kernel[half])) {
                        const k_vec: @Vector(vec_len, AccumT) = @splat(promote(kernel[half]));
                        acc += loadVec(src_data[bases[half] + c ..].ptr) * k_vec;
                    }
                } else {
                    for (kernel, bases) |k, base| {
                        if (border_row) {
                            const vec: @Vector(vec_len, AccumT) = if (base == BorderIndexTable.zero_sentinel)
                                @splat(0)
                            else
                                loadVec(src_data[base + c ..].ptr);
                            const k_vec: @Vector(vec_len, AccumT) = @splat(promote(k));
                            acc += vec * k_vec;
                        } else if (!isNegligible(k)) {
                            const vec = loadVec(src_data[base + c ..].ptr);
                            const k_vec: @Vector(vec_len, AccumT) = @splat(promote(k));
                            acc += vec * k_vec;
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
                    } else if (!isNegligible(k)) {
                        result += promote(src_data[base + c]) * promote(k);
                    }
                }
                dst.data[dst_offset + c] = store(result);
            }
        }

        /// Column-tiled 1D pass along rows (src -> dst); tiling keeps the working set cache-resident.
        fn vertical(src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const half = kernel.len / 2;
            const rows = src.rows;
            const cols = src.cols;
            const tile_width = @max(vec_len, 16);

            if (rows > 2 * half) {
                const safe_end_r = rows - half;

                var tile_c: usize = 0;
                while (tile_c < cols) : (tile_c += tile_width) {
                    const tile_end = @min(tile_c + tile_width, cols);
                    var c: usize = tile_c;

                    while (c + vec_len <= tile_end) : (c += vec_len) {
                        for (half..safe_end_r) |r| {
                            var acc: @Vector(vec_len, AccumT) = @splat(0);
                            for (kernel, 0..) |k, ki| {
                                if (!isNegligible(k)) {
                                    const vec = loadVec(src.data[(r + ki - half) * src.stride + c ..].ptr);
                                    const k_vec: @Vector(vec_len, AccumT) = @splat(promote(k));
                                    acc += vec * k_vec;
                                }
                            }
                            storeVec(acc, dst.data[r * dst.stride + c ..].ptr);
                        }
                    }

                    while (c < tile_end) : (c += 1) {
                        for (half..safe_end_r) |r| {
                            var result: AccumT = 0;
                            const r0 = r - half;
                            for (kernel, 0..) |k, i| {
                                if (isNegligible(k)) continue;
                                result += promote(src.data[(r0 + i) * src.stride + c]) * promote(k);
                            }
                            dst.data[r * dst.stride + c] = store(result);
                        }
                    }
                }
            }

            try verticalBorderRows(src, dst, allocator, kernel, border_mode);
        }

        /// O(1)-per-pixel horizontal pass for uniform-body kernels (see `isUniformBody`):
        /// out = k*S + r*window_first with a running window sum S. Integer-exact vs the
        /// dense pass, so only used for integer kernels. Borders fall back to the dense
        /// table-resolved accumulation.
        fn horizontalBox(src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const half = kernel.len / 2;
            const len = kernel.len;
            const cols = src.cols;
            const table: BorderIndexTable = try .init(allocator, cols, len, border_mode);
            defer table.deinit(allocator);

            const k = promote(kernel[1]);
            const residual = promote(kernel[0]) - k;

            for (0..src.rows) |r| {
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
        fn verticalBox(src: Image(SrcT), dst: Image(DstT), allocator: Allocator, kernel: []const KernelT, border_mode: BorderMode) !void {
            const half = kernel.len / 2;
            const len = kernel.len;
            const rows = src.rows;
            const cols = src.cols;

            const k = promote(kernel[1]);
            const residual = promote(kernel[0]) - k;

            if (rows > 2 * half) {
                const safe_end = rows - half;
                const k_vec: @Vector(vec_len, AccumT) = @splat(k);
                const r_vec: @Vector(vec_len, AccumT) = @splat(residual);
                var c: usize = 0;

                while (c + vec_len <= cols) : (c += vec_len) {
                    var sum: @Vector(vec_len, AccumT) = @splat(0);
                    for (0..len) |i| sum += loadVec(src.data[i * src.stride + c ..].ptr);

                    for (half..safe_end) |r| {
                        const first = loadVec(src.data[(r - half) * src.stride + c ..].ptr);
                        storeVec(k_vec * sum + r_vec * first, dst.data[r * dst.stride + c ..].ptr);
                        if (r + 1 < safe_end) {
                            sum += loadVec(src.data[(r - half + len) * src.stride + c ..].ptr) - first;
                        }
                    }
                }

                while (c < cols) : (c += 1) {
                    var sum: AccumT = 0;
                    for (0..len) |i| sum += promote(src.data[i * src.stride + c]);

                    for (half..safe_end) |r| {
                        const first = promote(src.data[(r - half) * src.stride + c]);
                        dst.data[r * dst.stride + c] = store(k * sum + residual * first);
                        if (r + 1 < safe_end) {
                            sum += promote(src.data[(r - half + len) * src.stride + c]) - first;
                        }
                    }
                }
            }

            try verticalBorderRows(src, dst, allocator, kernel, border_mode);
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
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    const HPass = SeparablePass(PixelT, TempT, 1, AccumIntT);
    const VPass = SeparablePass(TempT, PixelT, if (PixelT == u8) fixed_point_scale_sq else 1, AccumIntT);

    const rows = src_img.rows;
    const cols = src_img.cols;
    const klen_y = kernel_y.len;
    const half_y = klen_y / 2;

    const h_table: BorderIndexTable = try .init(allocator, cols, kernel_x.len, border_mode);
    defer h_table.deinit(allocator);
    const v_table: BorderIndexTable = try .init(allocator, rows, klen_y, border_mode);
    defer v_table.deinit(allocator);

    const h_folded = HPass.KernelT == i32 and HPass.isSymmetric(kernel_x);
    const v_folded = VPass.KernelT == i32 and VPass.isSymmetric(kernel_y);

    // Temp row `tr` always lives in ring slot `tr % klen_y`.
    const ring = try allocator.alloc(TempT, klen_y * cols);
    defer allocator.free(ring);
    const bases = try allocator.alloc(usize, klen_y);
    defer allocator.free(bases);

    var produced: usize = @min(klen_y, rows);
    for (0..produced) |tr| {
        HPass.horizontalRow(src_img, ring[(tr % klen_y) * cols ..][0..cols], tr, kernel_x, h_table, h_folded);
    }

    for (0..rows) |r| {
        if (r >= half_y and r + half_y < rows) {
            // Highest temp row this output row taps (klen_y - 1 - half_y above r).
            const need = r + klen_y - 1 - half_y;
            while (produced <= need) : (produced += 1) {
                HPass.horizontalRow(src_img, ring[(produced % klen_y) * cols ..][0..cols], produced, kernel_x, h_table, h_folded);
            }
            for (bases, 0..) |*b, i| b.* = ((r + i - half_y) % klen_y) * cols;
            VPass.verticalRowFromBases(false, ring, bases, dst_img, r, kernel_y, v_folded);
        } else {
            // Bottom border rows read the final window; make sure it is complete. Top
            // border rows only tap the initial window, which prefill already produced.
            if (r >= v_table.high_start) {
                while (produced < rows) : (produced += 1) {
                    HPass.horizontalRow(src_img, ring[(produced % klen_y) * cols ..][0..cols], produced, kernel_x, h_table, h_folded);
                }
            }
            for (bases, v_table.taps(v_table.ordinalOf(r))) |*b, resolved| {
                b.* = if (resolved == BorderIndexTable.zero_sentinel)
                    BorderIndexTable.zero_sentinel
                else
                    (resolved % klen_y) * cols;
            }
            VPass.verticalRowFromBases(true, ring, bases, dst_img, r, kernel_y, false);
        }
    }
}

/// Standard two-pass separable convolution through a full-size temp plane.
fn convolveSeparablePlane(
    comptime PixelT: type,
    comptime TempT: type,
    comptime AccumIntT: type,
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    temp_img: Image(TempT),
    allocator: Allocator,
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) !void {
    try SeparablePass(PixelT, TempT, 1, AccumIntT).horizontal(src_img, temp_img, allocator, kernel_x, border_mode);
    try SeparablePass(TempT, PixelT, if (PixelT == u8) fixed_point_scale_sq else 1, AccumIntT).vertical(temp_img, dst_img, allocator, kernel_y, border_mode);
}

test "fused separable matches standard path" {
    const testing = std.testing;
    const allocator = testing.allocator;

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
                    try convolveSeparablePlane(T, TempT, AccumIntT, src, expected, temp, allocator, kernel, kernel, mode);
                    try convolveSeparablePlaneFused(T, TempT, AccumIntT, src, actual, allocator, kernel, kernel, mode);
                    try testing.expectEqualSlices(T, expected.data, actual.data);
                }
            }
        }
    }
}

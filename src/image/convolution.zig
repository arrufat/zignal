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

/// Symmetric-rounding divide by `scale` followed by clamp to u8.
inline fn divClampU8(comptime scale: comptime_int, accum: i64) u8 {
    const half: i64 = scale / 2;
    const rounded = @divTrunc(accum + (if (accum >= 0) half else -half), scale);
    return meta.clamp(u8, rounded);
}

/// SIMD variant of `divClampU8`.
inline fn divClampU8Vec(
    comptime scale: comptime_int,
    comptime N: usize,
    accum: @Vector(N, i64),
) @Vector(N, u8) {
    const half_vec: @Vector(N, i64) = @splat(scale / 2);
    const neg_half_vec: @Vector(N, i64) = @splat(-scale / 2);
    const zero_vec: @Vector(N, i64) = @splat(0);
    const scale_vec: @Vector(N, i64) = @splat(scale);
    const max_vec: @Vector(N, i64) = @splat(255);
    const rounding = @select(i64, accum >= zero_vec, half_vec, neg_half_vec);
    const rounded = @divTrunc(accum + rounding, scale_vec);
    return @intCast(@max(zero_vec, @min(max_vec, rounded)));
}

fn PixelIO(comptime T: type, comptime vec_len: usize, comptime scale: comptime_int) type {
    if (T != u8 and T != f32) {
        @compileError("PixelIO only supports u8 and f32 types");
    }

    return struct {
        const Scalar = if (T == u8) i64 else f32;

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
                dst[offset..][0..vec_len].* = divClampU8Vec(scale, vec_len, accum_vec);
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
        const AccumScalar = if (T == u8) i64 else f32;

        const vec_len = std.simd.suggestVectorLength(AccumScalar) orelse 1;

        const Pixels = PixelIO(T, vec_len, fixed_point_scale);

        /// Flattens a 2D kernel into a 1D array; for `u8` images, values are scaled by `fixed_point_scale` and rounded.
        fn flatten(kernel: anytype) [size]KernelScalar {
            var result: [size]KernelScalar = undefined;
            var idx: usize = 0;
            inline for (0..rows) |kr| {
                inline for (0..cols) |kx| {
                    const val = as(f32, kernel[kr][kx]);
                    result[idx] = if (T == u8)
                        @round(val * fixed_point_scale)
                    else
                        val;
                    idx += 1;
                }
            }
            return result;
        }

        fn convolvePixelWithBorder(src: Image(T), dst: Image(T), r: usize, c: usize, kernel: [size]KernelScalar, border_mode: BorderMode) void {
            const ir: isize = @intCast(r);
            const ic: isize = @intCast(c);
            var result: AccumScalar = 0;
            inline for (0..rows) |ky| {
                inline for (0..cols) |kx| {
                    const iry = ir + @as(isize, ky) - half_h;
                    const icx = ic + @as(isize, kx) - half_w;
                    const pixel_val: AccumScalar = getPixel(T, src, iry, icx, border_mode);
                    const k_val: AccumScalar = kernel[ky * cols + kx];
                    result += pixel_val * k_val;
                }
            }
            dst.data[r * dst.stride + c] = Pixels.store(result);
        }

        fn convolve(src: Image(T), dst: Image(T), kernel: [size]KernelScalar, border_mode: BorderMode) void {
            var kernel_vecs: [size]@Vector(vec_len, AccumScalar) = undefined;
            inline for (0..size) |i| {
                const k_val: AccumScalar = kernel[i];
                kernel_vecs[i] = @splat(k_val);
            }

            for (0..src.rows) |r| {
                const row_in_band = r >= half_h and r + half_h < src.rows;

                if (!row_in_band) {
                    for (0..src.cols) |c| {
                        convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                    }
                    continue;
                }

                var c: usize = 0;

                while (c < @min(half_w, src.cols)) : (c += 1) {
                    convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                }

                const safe_end = src.cols -| half_w;

                if (src.cols >= vec_len + 2 * half_w) {
                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var result_vec: @Vector(vec_len, AccumScalar) = @splat(0);

                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const kid = ky * cols + kx;
                                const kernel_vec = kernel_vecs[kid];

                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                const src_idx = src_r * src.stride + src_c;
                                const pixel_vec = Pixels.loadVec(src.data, src_idx);
                                result_vec += pixel_vec * kernel_vec;
                            }
                        }

                        Pixels.storeVec(result_vec, dst.data, r * dst.stride + c);
                    }
                }

                while (c < safe_end) : (c += 1) {
                    var result: AccumScalar = 0;
                    inline for (0..rows) |ky| {
                        inline for (0..cols) |kx| {
                            const src_r = r + ky - half_h;
                            const src_c = c + kx - half_w;
                            const pixel_val = Pixels.load(src.data[src_r * src.stride + src_c]);
                            const k_val: AccumScalar = kernel[ky * cols + kx];
                            result += pixel_val * k_val;
                        }
                    }
                    dst.data[r * dst.stride + c] = Pixels.store(result);
                }

                while (c < src.cols) : (c += 1) {
                    convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                }
            }
        }
    };
}

/// Applies a 2D convolution with the given kernel, writing into `out`.
pub fn convolve(comptime T: type, self: Image(T), out: Image(T), allocator: Allocator, kernel: anytype, border_mode: BorderMode) !void {
    const kernel_info = @typeInfo(@TypeOf(kernel));
    if (kernel_info != .array) @compileError("Kernel must be a 2D array");
    const outer_array = kernel_info.array;
    if (@typeInfo(outer_array.child) != .array) @compileError("Kernel must be a 2D array");
    const kernel_height = outer_array.len;
    const kernel_width = @typeInfo(outer_array.child).array.len;

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

fn scaleKernelToInt(allocator: Allocator, kernel: []const f32, scale: comptime_int) ![]i32 {
    const result = try allocator.alloc(i32, kernel.len);
    for (kernel, 0..) |k, i| {
        result[i] = @round(k * scale);
    }
    return result;
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
    switch (T) {
        u8 => {
            var temp = try Image(i32).initLike(allocator, image);
            defer temp.deinit(allocator);

            const kernel_x_int = try scaleKernelToInt(allocator, kernel_x, fixed_point_scale);
            defer allocator.free(kernel_x_int);
            const kernel_y_int = try scaleKernelToInt(allocator, kernel_y, fixed_point_scale);
            defer allocator.free(kernel_y_int);

            convolveSeparablePlane(u8, i32, image, out, temp, kernel_x_int, kernel_y_int, border_mode);
        },
        f32 => {
            var temp = try Image(T).initLike(allocator, image);
            defer temp.deinit(allocator);

            convolveSeparablePlane(f32, f32, image, out, temp, kernel_x, kernel_y, border_mode);
        },
        else => switch (@typeInfo(T)) {
            .@"struct" => {
                if (comptime meta.allFieldsAreU8(T)) {
                    const kernel_x_int = try scaleKernelToInt(allocator, kernel_x, fixed_point_scale);
                    defer allocator.free(kernel_x_int);
                    const kernel_y_int = try scaleKernelToInt(allocator, kernel_y, fixed_point_scale);
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
                            if (ctx.temp.len == 0) ctx.temp = try ctx.allocator.alloc(i32, src.rows * src.cols);
                            const temp = Image(i32).initFromSlice(src.rows, src.cols, ctx.temp);
                            convolveSeparablePlane(u8, i32, src, dst, temp, ctx.kernel_x, ctx.kernel_y, mode);
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

/// Uses i64 accumulators for i32 intermediates to prevent overflow during the second pass.
fn convolveSeparablePlane(
    comptime PixelT: type,
    comptime TempT: type,
    src_img: Image(PixelT),
    dst_img: Image(PixelT),
    temp_img: Image(TempT),
    kernel_x: []const TempT,
    kernel_y: []const TempT,
    border_mode: BorderMode,
) void {
    const half_x = kernel_x.len / 2;
    const half_y = kernel_y.len / 2;
    const rows = src_img.rows;
    const cols = src_img.cols;

    const AccumT = if (TempT == i32) i64 else TempT;
    const vec_len = std.simd.suggestVectorLength(TempT) orelse 1;

    const isNegligible = struct {
        inline fn check(k: TempT) bool {
            if (TempT == f32) {
                return @abs(k) < 1e-10;
            } else {
                return k == 0;
            }
        }
    }.check;

    // Two-pass results carry a squared fixed-point scale.
    const DstIO = PixelIO(PixelT, vec_len, fixed_point_scale_sq);

    const Ops = struct {
        inline fn promote(v: anytype) if (@typeInfo(@TypeOf(v)) == .vector) @Vector(vec_len, AccumT) else AccumT {
            return if (AccumT == i64) @intCast(v) else v;
        }

        inline fn loadSrcVec(ptr: [*]const PixelT) @Vector(vec_len, TempT) {
            if (PixelT == u8 and TempT == i32) {
                const v: @Vector(vec_len, u8) = ptr[0..vec_len].*;
                return @intCast(v);
            } else {
                return ptr[0..vec_len].*;
            }
        }

        inline fn storeTempVec(val: @Vector(vec_len, AccumT), ptr: [*]TempT) void {
            if (TempT == i32 and AccumT == i64) {
                const min_vec: @Vector(vec_len, i64) = @splat(std.math.minInt(i32));
                const max_vec: @Vector(vec_len, i64) = @splat(std.math.maxInt(i32));
                const clamped = @max(min_vec, @min(max_vec, val));
                const narrowed: @Vector(vec_len, i32) = @intCast(clamped);
                ptr[0..vec_len].* = narrowed;
            } else {
                ptr[0..vec_len].* = val;
            }
        }

        inline fn storeTempScalar(val: AccumT) TempT {
            if (TempT == i32 and AccumT == i64) {
                return @intCast(meta.clamp(i32, val));
            } else {
                return val;
            }
        }
    };

    // Shared by the left and right border-column loops of the horizontal pass.
    const hBorderPixel = struct {
        inline fn accum(img: Image(PixelT), kernel: []const TempT, half: usize, r: usize, c: usize, mode: BorderMode) AccumT {
            var result: AccumT = 0;
            const ic: isize = @intCast(c);
            for (kernel, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half));
                result += Ops.promote(getPixel(PixelT, img, @intCast(r), icx, mode)) * Ops.promote(k);
            }
            return result;
        }
    }.accum;

    // Horizontal pass (src -> temp)
    for (0..rows) |r| {
        const row_offset = r * src_img.stride;
        const temp_offset = r * temp_img.stride;
        var c: usize = 0;

        const left_border_end = @min(half_x, cols);
        while (c < left_border_end) : (c += 1) {
            temp_img.data[temp_offset + c] = Ops.storeTempScalar(hBorderPixel(src_img, kernel_x, half_x, r, c, border_mode));
        }

        if (cols > 2 * half_x) {
            const interior_end = cols - half_x;

            while (c + vec_len <= interior_end) : (c += vec_len) {
                var acc: @Vector(vec_len, AccumT) = @splat(0);

                for (kernel_x, 0..) |k, ki| {
                    if (!isNegligible(k)) {
                        const src_idx = row_offset + c + ki - half_x;
                        const src_vec = Ops.loadSrcVec(src_img.data[src_idx..].ptr);

                        const src_vec_acc = Ops.promote(src_vec);
                        const k_vec: @Vector(vec_len, AccumT) = @splat(Ops.promote(k));
                        acc += src_vec_acc * k_vec;
                    }
                }
                Ops.storeTempVec(acc, temp_img.data[temp_offset + c ..].ptr);
            }

            while (c < interior_end) : (c += 1) {
                var result: AccumT = 0;
                const c0 = c - half_x;
                for (kernel_x, 0..) |k, i| {
                    if (!isNegligible(k)) {
                        const src_val = src_img.data[row_offset + c0 + i];
                        result += Ops.promote(src_val) * Ops.promote(k);
                    }
                }
                temp_img.data[temp_offset + c] = Ops.storeTempScalar(result);
            }
        }

        while (c < cols) : (c += 1) {
            temp_img.data[temp_offset + c] = Ops.storeTempScalar(hBorderPixel(src_img, kernel_x, half_x, r, c, border_mode));
        }
    }

    // Vertical pass (temp -> dst) with loop tiling for cache locality
    const tile_width = @max(vec_len, 16);

    if (rows > 2 * half_y) {
        const safe_end_r = rows - half_y;

        var tile_c: usize = 0;
        while (tile_c < cols) : (tile_c += tile_width) {
            const tile_end = @min(tile_c + tile_width, cols);
            var c: usize = tile_c;

            while (c + vec_len <= tile_end) : (c += vec_len) {
                for (half_y..safe_end_r) |r| {
                    var acc: @Vector(vec_len, AccumT) = @splat(0);

                    for (kernel_y, 0..) |k, ki| {
                        if (!isNegligible(k)) {
                            const src_row = r + ki - half_y;
                            const src_off = src_row * temp_img.stride;
                            const src_vec: @Vector(vec_len, TempT) = temp_img.data[src_off + c ..][0..vec_len].*;

                            const src_vec_acc = Ops.promote(src_vec);
                            const k_vec: @Vector(vec_len, AccumT) = @splat(Ops.promote(k));
                            acc += src_vec_acc * k_vec;
                        }
                    }

                    DstIO.storeVec(acc, dst_img.data, r * dst_img.stride + c);
                }
            }

            while (c < tile_end) : (c += 1) {
                for (half_y..safe_end_r) |r| {
                    var result: AccumT = 0;
                    const r0 = r - half_y;
                    for (kernel_y, 0..) |k, i| {
                        if (isNegligible(k)) continue;
                        const rr = r0 + i;
                        const src_val = temp_img.data[rr * temp_img.stride + c];
                        result += Ops.promote(src_val) * Ops.promote(k);
                    }
                    dst_img.data[r * dst_img.stride + c] = DstIO.store(result);
                }
            }
        }
    }

    // Top and bottom border rows require getPixel for out-of-bounds vertical access
    const top_end = @min(half_y, rows);
    const bottom_start = if (rows > half_y) @max(top_end, rows - half_y) else rows;
    const border_rows = [_][2]usize{
        .{ 0, top_end },
        .{ bottom_start, rows },
    };

    for (border_rows) |range| {
        for (range[0]..range[1]) |r| {
            for (0..cols) |c| {
                var result: AccumT = 0;
                const ir: isize = @intCast(r);
                for (kernel_y, 0..) |k, i| {
                    const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                    const pixel_val = getPixel(TempT, temp_img, iry, @intCast(c), border_mode);
                    result += Ops.promote(pixel_val) * Ops.promote(k);
                }
                dst_img.data[r * dst_img.stride + c] = DstIO.store(result);
            }
        }
    }
}

/// Widens the result so callers can accumulate in i64/f32 without an extra cast at every callsite.
fn getPixel(comptime T: type, img: Image(T), row: isize, col: isize, border_mode: BorderMode) if (T == f32) f32 else i32 {
    if (T != u8 and T != f32 and T != i32) @compileError("getPixel only works with u8, i32 and f32 types");
    const coords = border.computeCoords(row, col, @intCast(img.rows), @intCast(img.cols), border_mode);
    return if (coords) |c| img.at(c.row, c.col).* else 0;
}

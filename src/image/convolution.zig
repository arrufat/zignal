const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const border = @import("border.zig");

pub const BorderMode = border.BorderMode;
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

fn PixelIO(comptime T: type, comptime vec_len: usize) type {
    if (T != u8 and T != f32) {
        @compileError("PixelIO only supports u8 and f32 types");
    }

    return struct {
        const Scalar = if (T == u8) i64 else f32;
        const scale = if (T == u8) fixed_point_scale else 1;

        inline fn load(value: T) Scalar {
            return if (T == u8) @as(Scalar, value) else value;
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

        const Pixels = PixelIO(T, vec_len);

        /// Flattens a 2D kernel into a 1D array; for `u8` images, values are scaled by `fixed_point_scale` and rounded.
        pub fn flatten(kernel: anytype) [size]KernelScalar {
            const kernel_info = @typeInfo(@TypeOf(kernel));
            const kernel_height = kernel_info.array.len;
            const kernel_width = @typeInfo(kernel_info.array.child).array.len;
            var result: [size]KernelScalar = undefined;
            var idx: usize = 0;
            inline for (0..kernel_height) |kr| {
                inline for (0..kernel_width) |kx| {
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
            const ir = @as(isize, @intCast(r));
            const ic = @as(isize, @intCast(c));
            var result: AccumScalar = 0;
            inline for (0..rows) |ky| {
                inline for (0..cols) |kx| {
                    const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                    const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                    const pixel_val = @as(AccumScalar, getPixel(T, src, iry, icx, border_mode));
                    const k_val = @as(AccumScalar, kernel[ky * cols + kx]);
                    result += pixel_val * k_val;
                }
            }
            dst.data[r * dst.stride + c] = Pixels.store(result);
        }

        fn convolve(src: Image(T), dst: Image(T), kernel: [size]KernelScalar, border_mode: BorderMode) void {
            var kernel_vecs: [size]@Vector(vec_len, AccumScalar) = undefined;
            inline for (0..size) |i| {
                const k_val = @as(AccumScalar, kernel[i]);
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

                if (src.cols >= vec_len + 2 * half_w) {
                    while (c < half_w) : (c += 1) {
                        convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                    }

                    const safe_end = src.cols - half_w;

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

                while (c < src.cols) : (c += 1) {
                    if (c >= half_w and c + half_w < src.cols) {
                        var result: AccumScalar = 0;
                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                const pixel_val = Pixels.load(src.data[src_r * src.stride + src_c]);
                                const k_val = @as(AccumScalar, kernel[ky * cols + kx]);
                                result += pixel_val * k_val;
                            }
                        }
                        dst.data[r * dst.stride + c] = Pixels.store(result);
                    } else {
                        convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                    }
                }
            }
        }
    };
}

/// Applies a 2D convolution with the given kernel, writing into `out`.
pub fn convolve(comptime T: type, self: Image(T), allocator: Allocator, kernel: anytype, border_mode: BorderMode, out: Image(T)) !void {
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
                    var kernel_sum: Kernel.KernelScalar = 0;
                    inline for (kernel_int) |weight| {
                        kernel_sum += weight;
                    }
                    const plane_size = self.rows * self.cols;
                    const Pixel = PixelIO(u8, 1);

                    const split = try channel_ops.splitChannelsWithUniform(T, self, allocator);
                    const channels = split.channels;
                    const uniforms = split.uniforms;
                    defer for (channels) |channel| allocator.free(channel);

                    const ChannelStrategy = enum { normalized, scaled, non_uniform };
                    var strategies: [channels.len]ChannelStrategy = undefined;

                    // Only use .normalized or .scaled optimization if the border mode
                    // preserves uniform regions (not .zero which introduces 0 at edges).
                    const is_safe_border = border_mode.preservesUniform();

                    inline for (uniforms, 0..) |uniform_value, i| {
                        if (uniform_value) |_| {
                            if (is_safe_border) {
                                strategies[i] = if (kernel_sum == Pixel.scale) .normalized else .scaled;
                            } else {
                                strategies[i] = .non_uniform;
                            }
                        } else {
                            strategies[i] = .non_uniform;
                        }
                    }

                    var num_alloc_channels: usize = 0;
                    inline for (strategies) |strategy| {
                        if (strategy != .normalized) num_alloc_channels += 1;
                    }

                    const total_alloc_size = try std.math.mul(usize, num_alloc_channels, plane_size);
                    var contiguous_buffer: []u8 = if (total_alloc_size > 0)
                        try allocator.alloc(u8, total_alloc_size)
                    else
                        &.{};
                    defer if (contiguous_buffer.len > 0) allocator.free(contiguous_buffer);

                    var out_channels: [channels.len][]u8 = undefined;
                    var alloc_offset: usize = 0;
                    inline for (&out_channels, strategies, uniforms) |*out_ch, strategy, uniform_value| {
                        switch (strategy) {
                            .normalized => out_ch.* = &.{},
                            .scaled, .non_uniform => {
                                out_ch.* = contiguous_buffer[alloc_offset..][0..plane_size];
                                alloc_offset += plane_size;
                            },
                        }
                        if (strategy == .scaled) {
                            const value = uniform_value orelse unreachable;
                            const accum = @as(i64, @intCast(value)) * @as(i64, kernel_sum);
                            const stored = Pixel.store(accum);
                            @memset(out_ch.*, stored);
                        }
                    }

                    inline for (channels, out_channels, strategies) |src_data, dst_data, strategy| {
                        if (strategy == .non_uniform) {
                            const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                            const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                            Kernel.convolve(src_plane, dst_plane, kernel_int, border_mode);
                        }
                    }

                    var final_channels: [channels.len][]const u8 = undefined;
                    inline for (strategies, out_channels, channels, 0..) |strategy, out_ch, src_ch, i| {
                        switch (strategy) {
                            .normalized => final_channels[i] = src_ch,
                            .scaled, .non_uniform => final_channels[i] = out_ch,
                        }
                    }
                    channel_ops.mergeChannels(T, final_channels, out);
                } else {
                    @compileError("Convolution only supports structs where all fields are u8. Type " ++ @typeName(T) ++ " is not supported.");
                }
            },
            else => @compileError("Convolution only supports u8, f32, and structs with all u8 fields. Type " ++ @typeName(T) ++ " is not supported."),
        },
    }
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
    allocator: Allocator,
    kernel_x: []const f32,
    kernel_y: []const f32,
    border_mode: BorderMode,
    out: Image(T),
) !void {
    switch (T) {
        u8 => {
            var temp = try Image(i32).init(allocator, image.rows, image.cols);
            defer temp.deinit(allocator);

            const kernel_x_int = try scaleKernelToInt(allocator, kernel_x, fixed_point_scale);
            defer allocator.free(kernel_x_int);
            const kernel_y_int = try scaleKernelToInt(allocator, kernel_y, fixed_point_scale);
            defer allocator.free(kernel_y_int);

            convolveSeparablePlane(u8, i32, image, out, temp, kernel_x_int, kernel_y_int, border_mode);
        },
        f32 => {
            var temp = try Image(T).init(allocator, image.rows, image.cols);
            defer temp.deinit(allocator);

            convolveSeparablePlane(f32, f32, image, out, temp, kernel_x, kernel_y, border_mode);
        },
        else => switch (@typeInfo(T)) {
            .@"struct" => {
                if (comptime meta.allFieldsAreU8(T)) {
                    const plane_size = image.rows * image.cols;

                    const kernel_x_int = try scaleKernelToInt(allocator, kernel_x, fixed_point_scale);
                    defer allocator.free(kernel_x_int);
                    const kernel_y_int = try scaleKernelToInt(allocator, kernel_y, fixed_point_scale);
                    defer allocator.free(kernel_y_int);

                    // Separable kernel sum is the product of 1D sums; each 1D sum is scaled by fixed_point_scale.
                    var kx_sum: i64 = 0;
                    for (kernel_x_int) |w| kx_sum += w;
                    var ky_sum: i64 = 0;
                    for (kernel_y_int) |w| ky_sum += w;
                    const kernel_sum = kx_sum * ky_sum;
                    const scale_sq: i64 = fixed_point_scale_sq;

                    const split = try channel_ops.splitChannelsWithUniform(T, image, allocator);
                    const channels = split.channels;
                    const uniforms = split.uniforms;
                    defer for (channels) |channel| allocator.free(channel);

                    const ChannelStrategy = enum { normalized, scaled, non_uniform };
                    var strategies: [channels.len]ChannelStrategy = undefined;
                    const is_safe_border = border_mode.preservesUniform();

                    inline for (uniforms, 0..) |uniform_value, i| {
                        if (uniform_value) |_| {
                            if (is_safe_border) {
                                strategies[i] = if (kernel_sum == scale_sq) .normalized else .scaled;
                            } else {
                                strategies[i] = .non_uniform;
                            }
                        } else {
                            strategies[i] = .non_uniform;
                        }
                    }

                    var num_alloc_channels: usize = 0;
                    inline for (strategies) |strategy| {
                        if (strategy != .normalized) num_alloc_channels += 1;
                    }

                    const total_u8_size = try std.math.mul(usize, num_alloc_channels, plane_size);
                    var contiguous_u8_buffer: []u8 = if (total_u8_size > 0)
                        try allocator.alloc(u8, total_u8_size)
                    else
                        &.{};
                    defer if (contiguous_u8_buffer.len > 0) allocator.free(contiguous_u8_buffer);

                    const temp_plane_data: []i32 = if (num_alloc_channels > 0)
                        try allocator.alloc(i32, plane_size)
                    else
                        &.{};
                    defer if (temp_plane_data.len > 0) allocator.free(temp_plane_data);

                    var out_channels: [channels.len][]u8 = undefined;
                    var alloc_offset: usize = 0;
                    inline for (&out_channels, strategies, uniforms) |*out_ch, strategy, uniform_value| {
                        switch (strategy) {
                            .normalized => out_ch.* = &.{},
                            .scaled, .non_uniform => {
                                out_ch.* = contiguous_u8_buffer[alloc_offset..][0..plane_size];
                                alloc_offset += plane_size;
                            },
                        }
                        if (strategy == .scaled) {
                            const value = uniform_value orelse unreachable;
                            const accum = @as(i64, @intCast(value)) * kernel_sum;
                            @memset(out_ch.*, divClampU8(fixed_point_scale_sq, accum));
                        }
                    }

                    inline for (channels, out_channels, strategies) |src_data, dst_data, strategy| {
                        if (strategy == .non_uniform) {
                            const src_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = src_data };
                            const dst_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = dst_data };
                            const tmp_plane: Image(i32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = temp_plane_data };
                            convolveSeparablePlane(u8, i32, src_plane, dst_plane, tmp_plane, kernel_x_int, kernel_y_int, border_mode);
                        }
                    }

                    var final_channels: [channels.len][]const u8 = undefined;
                    inline for (strategies, out_channels, channels, 0..) |strategy, out_ch, src_ch, i| {
                        switch (strategy) {
                            .normalized => final_channels[i] = src_ch,
                            .scaled, .non_uniform => final_channels[i] = out_ch,
                        }
                    }
                    channel_ops.mergeChannels(T, final_channels, out);
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

        inline fn storeDstVec(val: @Vector(vec_len, AccumT), ptr: [*]PixelT) void {
            if (PixelT == u8 and AccumT == i64) {
                ptr[0..vec_len].* = divClampU8Vec(fixed_point_scale_sq, vec_len, val);
            } else {
                ptr[0..vec_len].* = val;
            }
        }

        inline fn storeDstScalar(val: AccumT) PixelT {
            return if (PixelT == u8 and AccumT == i64) divClampU8(fixed_point_scale_sq, val) else val;
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

    // Horizontal pass (src -> temp)
    for (0..rows) |r| {
        const row_offset = r * src_img.stride;
        const temp_offset = r * temp_img.stride;
        var c: usize = 0;

        const left_border_end = @min(half_x, cols);
        while (c < left_border_end) : (c += 1) {
            var result: AccumT = 0;
            const ic: isize = @intCast(c);
            for (kernel_x, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val = getPixel(PixelT, src_img, @intCast(r), icx, border_mode);
                result += Ops.promote(pixel_val) * Ops.promote(k);
            }
            temp_img.data[temp_offset + c] = Ops.storeTempScalar(result);
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
            var result: AccumT = 0;
            const ic: isize = @intCast(c);
            for (kernel_x, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val = getPixel(PixelT, src_img, @intCast(r), icx, border_mode);
                result += Ops.promote(pixel_val) * Ops.promote(k);
            }
            temp_img.data[temp_offset + c] = Ops.storeTempScalar(result);
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

                    Ops.storeDstVec(acc, dst_img.data[r * dst_img.stride + c ..].ptr);
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
                    dst_img.data[r * dst_img.stride + c] = Ops.storeDstScalar(result);
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
                dst_img.data[r * dst_img.stride + c] = Ops.storeDstScalar(result);
            }
        }
    }
}

/// Widens the result so callers can accumulate in i64/f32 without an extra cast at every callsite.
fn getPixel(comptime T: type, img: Image(T), row: isize, col: isize, border_mode: BorderMode) if (T == f32) f32 else i32 {
    if (T != u8 and T != f32 and T != i32) @compileError("getPixel only works with u8, i32 and f32 types");
    const coords = border.computeCoords(row, col, @intCast(img.rows), @intCast(img.cols), border_mode);
    const pixel = if (coords) |c| img.at(c.row, c.col).* else 0;
    return if (T == u8) @as(i32, pixel) else pixel;
}

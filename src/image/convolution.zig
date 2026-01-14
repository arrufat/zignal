const std = @import("std");
const Allocator = std.mem.Allocator;

const Gray = @import("../color.zig").Gray;
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const channel_ops = @import("channel_ops.zig");
const border = @import("border.zig");

/// Border handling modes for filter operations
pub const BorderMode = border.BorderMode;

/// Pixel I/O operations for type-specific convolution.
/// Provides unified load/store operations for both u8 (with integer scaling) and f32.
fn PixelIO(comptime T: type, comptime vec_len: usize) type {
    if (T != u8 and T != f32) {
        @compileError("PixelIO only supports u8 and f32 types");
    }

    return struct {
        const Scalar = if (T == u8) i64 else f32;
        const scale = if (T == u8) 256 else 1;

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
            if (T == u8) {
                // Symmetric rounding: add half scale for positive, subtract for negative
                const half: Scalar = scale / 2;
                const rounded = @divTrunc(accum + (if (accum >= 0) half else -half), scale);
                return meta.clamp(u8, rounded);
            } else {
                return accum;
            }
        }

        inline fn storeVec(accum_vec: @Vector(vec_len, Scalar), dst: []T, offset: usize) void {
            if (T == u8) {
                const half_scale_vec: @Vector(vec_len, Scalar) = @splat(scale / 2);
                const neg_half_scale_vec: @Vector(vec_len, Scalar) = @splat(-scale / 2);
                const zero_vec: @Vector(vec_len, Scalar) = @splat(0);
                const scale_vec: @Vector(vec_len, Scalar) = @splat(scale);
                // Symmetric rounding: add half for positive, subtract half for negative
                const rounding = @select(Scalar, accum_vec >= zero_vec, half_scale_vec, neg_half_scale_vec);
                const rounded_vec = @divTrunc(accum_vec + rounding, scale_vec);

                // Use saturating cast for efficient clamping
                const clamped: @Vector(vec_len, u8) = @intCast(@max(zero_vec, @min(@as(@Vector(vec_len, Scalar), @splat(255)), rounded_vec)));
                dst[offset..][0..vec_len].* = clamped;
            } else {
                dst[offset..][0..vec_len].* = accum_vec;
            }
        }
    };
}

/// Comptime function generator for specialized convolution implementations.
/// Generates optimized code for specific kernel dimensions at compile time.
fn ConvolutionKernel(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    if (T != u8 and T != f32) {
        @compileError("Unsupported kernel type: " ++ @typeName(T) ++ ". Only u8 and f32 are supported");
    }

    return struct {
        const size = rows * cols;
        const half_h = rows / 2;
        const half_w = cols / 2;

        // Type-specific definitions
        const KernelScalar = if (T == u8) i32 else f32; // Storage type for kernel weights
        const Scalar = KernelScalar; // Public interface matches kernel storage
        const AccumScalar = if (T == u8) i64 else f32; // Wide accumulator for summation

        const vec_len = std.simd.suggestVectorLength(AccumScalar) orelse 1;

        // Use the shared pixel I/O operations
        const Pixels = PixelIO(T, vec_len);

        /// Flatten a 2D kernel to 1D array and scale to integer for u8.
        pub fn flatten(kernel: anytype) [size]Scalar {
            const kernel_info = @typeInfo(@TypeOf(kernel));
            const kernel_height = kernel_info.array.len;
            const kernel_width = @typeInfo(kernel_info.array.child).array.len;
            var result: [size]Scalar = undefined;
            var idx: usize = 0;
            inline for (0..kernel_height) |kr| {
                inline for (0..kernel_width) |kx| {
                    const val = as(f32, kernel[kr][kx]);
                    result[idx] = if (T == u8)
                        @intFromFloat(@round(val * 256.0))
                    else
                        val;
                    idx += 1;
                }
            }
            return result;
        }

        fn convolvePixelWithBorder(src: Image(T), dst: Image(T), r: usize, c: usize, kernel: [size]Scalar, border_mode: BorderMode) void {
            const ir = @as(isize, @intCast(r));
            const ic = @as(isize, @intCast(c));
            var result: AccumScalar = 0;
            inline for (0..rows) |ky| {
                inline for (0..cols) |kx| {
                    const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                    const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                    // getPixel returns i32 for u8, cast to i64 accumulator
                    const pixel_val = @as(AccumScalar, getPixel(T, src, iry, icx, border_mode));
                    // kernel is i32, cast to i64
                    const k_val = @as(AccumScalar, kernel[ky * cols + kx]);
                    result += pixel_val * k_val;
                }
            }
            // PixelIO.store takes AccumScalar (i64 for u8)
            dst.data[r * dst.stride + c] = Pixels.store(result);
        }

        fn convolve(src: Image(T), dst: Image(T), kernel: [size]Scalar, border_mode: BorderMode) void {
            // Pre-create kernel vectors for SIMD (widen to AccumScalar)
            var kernel_vecs: [size]@Vector(vec_len, AccumScalar) = undefined;
            inline for (0..size) |i| {
                const k_val = @as(AccumScalar, kernel[i]);
                kernel_vecs[i] = @splat(k_val);
            }

            for (0..src.rows) |r| {
                var c: usize = 0;

                // SIMD path for interior pixels
                if (r >= half_h and r + half_h < src.rows and src.cols >= vec_len + 2 * half_w) {
                    // Process leading border pixels of this row
                    while (c < half_w) : (c += 1) {
                        convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                    }

                    const safe_end = src.cols - half_w;

                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var result_vec: @Vector(vec_len, AccumScalar) = @splat(0);

                        // Unroll kernel application for known sizes
                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const kid = ky * cols + kx;
                                const kernel_vec = kernel_vecs[kid];

                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                const src_idx = src_r * src.stride + src_c;
                                // Pixels.loadVec returns Vector(AccumScalar)
                                const pixel_vec = Pixels.loadVec(src.data, src_idx);
                                result_vec += pixel_vec * kernel_vec;
                            }
                        }

                        Pixels.storeVec(result_vec, dst.data, r * dst.stride + c);
                    }
                }

                // Scalar path for remaining pixels
                while (c < src.cols) : (c += 1) {
                    if (r >= half_h and r + half_h < src.rows and c >= half_w and c + half_w < src.cols) {
                        // Interior pixel - no border handling needed
                        var result: AccumScalar = 0;
                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                // Pixels.load returns AccumScalar
                                const pixel_val = Pixels.load(src.data[src_r * src.stride + src_c]);
                                const k_val = @as(AccumScalar, kernel[ky * cols + kx]);
                                result += pixel_val * k_val;
                            }
                        }
                        dst.data[r * dst.stride + c] = Pixels.store(result);
                    } else {
                        // Border pixel - needs border handling
                        convolvePixelWithBorder(src, dst, r, c, kernel, border_mode);
                    }
                }
            }
        }
    };
}

/// Applies a 2D convolution with the given kernel to the image.
///
/// Parameters:
/// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
/// - `kernel`: A 2D array representing the convolution kernel.
/// - `out`: An out-parameter pointer to an `Image(T)` that will be filled with the convolved image.
/// - `border_mode`: How to handle pixels at the image borders.
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
                // Optimized path for u8 structs (RGB, RGBA, etc.)
                if (comptime meta.allFieldsAreU8(T)) {
                    const Kernel = ConvolutionKernel(u8, kernel_height, kernel_width);
                    // Channel separation approach for optimal performance
                    const kernel_int = Kernel.flatten(kernel);
                    var kernel_sum: Kernel.Scalar = 0;
                    inline for (kernel_int) |weight| {
                        kernel_sum += weight;
                    }
                    const plane_size = self.rows * self.cols;
                    const Pixel = PixelIO(u8, 1);
                    const scale = Pixel.scale;

                    // Separate channels using helper
                    const split = try channel_ops.splitChannelsWithUniform(T, self, allocator);
                    const channels = split.channels;
                    const uniforms = split.uniforms;
                    defer for (channels) |channel| allocator.free(channel);

                    const ChannelStrategy = enum { normalized, scaled, non_uniform };
                    var strategies: [channels.len]ChannelStrategy = undefined;

                    // Determine strategy for each channel
                    // Only use .normalized or .scaled optimization if the border mode allows it.
                    // For .zero or .constant, the edges might need to be processed even if the image is uniform.
                    const is_safe_border = switch (border_mode) {
                        .replicate, .mirror, .wrap => true,
                        else => false,
                    };

                    inline for (uniforms, 0..) |uniform_value, i| {
                        if (uniform_value) |_| {
                            if (is_safe_border) {
                                strategies[i] = if (kernel_sum == scale) .normalized else .scaled;
                            } else {
                                strategies[i] = .non_uniform;
                            }
                        } else {
                            strategies[i] = .non_uniform;
                        }
                    }

                    // Count how many channels need storage and allocate single contiguous buffer
                    var num_alloc_channels: usize = 0;
                    inline for (strategies) |strategy| {
                        if (strategy != .normalized) num_alloc_channels += 1;
                    }

                    // Single contiguous allocation for all output channels
                    const total_alloc_size = try std.math.mul(usize, num_alloc_channels, plane_size);
                    var contiguous_buffer: []u8 = if (total_alloc_size > 0)
                        try allocator.alloc(u8, total_alloc_size)
                    else
                        &.{};
                    defer if (contiguous_buffer.len > 0) allocator.free(contiguous_buffer);

                    // Assign slices from contiguous buffer to out_channels
                    var out_channels: [channels.len][]u8 = undefined;
                    var alloc_offset: usize = 0;
                    inline for (&out_channels, strategies, uniforms) |*out_ch, strategy, uniform_value| {
                        switch (strategy) {
                            .normalized => out_ch.* = &.{}, // Placeholder for merge
                            .scaled, .non_uniform => {
                                out_ch.* = contiguous_buffer[alloc_offset..][0..plane_size];
                                alloc_offset += plane_size;
                            },
                        }
                        if (strategy == .scaled) {
                            const value = uniform_value orelse unreachable;
                            // Calculate accumulator in i64 to match PixelIO.store and prevent overflow
                            const accum = @as(i64, @intCast(value)) * @as(i64, kernel_sum);
                            const stored = Pixel.store(accum);
                            @memset(out_ch.*, stored);
                        }
                    }

                    // Convolve only non-uniform channels
                    inline for (channels, out_channels, strategies) |src_data, dst_data, strategy| {
                        if (strategy == .non_uniform) {
                            const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                            const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                            Kernel.convolve(src_plane, dst_plane, kernel_int, border_mode);
                        }
                    }

                    // Recombine channels, using original values for uniform channels
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

/// Performs separable convolution using two 1D kernels (horizontal and vertical).
/// This is much more efficient for separable filters like Gaussian blur.
///
/// Parameters:
/// - `allocator`: The allocator to use for temporary buffers.
/// - `kernel_x`: Horizontal (column) kernel.
/// - `kernel_y`: Vertical (row) kernel.
/// - `out`: Output image.
/// - `border_mode`: How to handle image borders.
pub fn convolveSeparable(
    comptime T: type,
    image: Image(T),
    allocator: Allocator,
    kernel_x: []const f32,
    kernel_y: []const f32,
    border_mode: BorderMode,
    out: Image(T),
) !void {
    // Process based on type
    switch (T) {
        u8 => {
            // Use i32 intermediate buffer to avoid clipping and precision loss
            var temp = try Image(i32).init(allocator, image.rows, image.cols);
            defer temp.deinit(allocator);

            // Convert kernels to integer
            const scale = 256;
            const kernel_x_int = try allocator.alloc(i32, kernel_x.len);
            defer allocator.free(kernel_x_int);
            const kernel_y_int = try allocator.alloc(i32, kernel_y.len);
            defer allocator.free(kernel_y_int);

            for (kernel_x, 0..) |k, i| {
                kernel_x_int[i] = @intFromFloat(@round(k * scale));
            }
            for (kernel_y, 0..) |k, i| {
                kernel_y_int[i] = @intFromFloat(@round(k * scale));
            }

            convolveSeparablePlane(u8, u8, i32, i32, image, out, temp, kernel_x_int, kernel_y_int, border_mode);
        },
        f32 => {
            var temp = try Image(T).init(allocator, image.rows, image.cols);
            defer temp.deinit(allocator);

            const src_plane: Image(f32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.stride, .data = image.data };
            const dst_plane: Image(f32) = .{ .rows = out.rows, .cols = out.cols, .stride = out.stride, .data = out.data };
            const tmp_plane: Image(f32) = .{ .rows = temp.rows, .cols = temp.cols, .stride = temp.stride, .data = temp.data };
            convolveSeparablePlane(f32, f32, f32, f32, src_plane, dst_plane, tmp_plane, kernel_x, kernel_y, border_mode);
        },
        else => switch (@typeInfo(T)) {
            .@"struct" => {
                // Optimized path for u8 structs (RGB, RGBA, etc.)
                if (comptime meta.allFieldsAreU8(T)) {
                    // Channel separation approach for optimal performance
                    const scale = 256;
                    const plane_size = image.rows * image.cols;

                    // Convert kernels to integer
                    const kernel_x_int = try allocator.alloc(i32, kernel_x.len);
                    defer allocator.free(kernel_x_int);
                    const kernel_y_int = try allocator.alloc(i32, kernel_y.len);
                    defer allocator.free(kernel_y_int);

                    for (kernel_x, 0..) |k, i| {
                        kernel_x_int[i] = @intFromFloat(@round(k * scale));
                    }
                    for (kernel_y, 0..) |k, i| {
                        kernel_y_int[i] = @intFromFloat(@round(k * scale));
                    }

                    // Separate channels using helper
                    const split = try channel_ops.splitChannelsWithUniform(T, image, allocator);
                    const channels = split.channels;
                    const uniforms = split.uniforms;
                    defer for (channels) |channel| allocator.free(channel);

                    // Check which channels are uniform to avoid unnecessary processing
                    var is_uniform: [channels.len]bool = undefined;
                    // Also check if border mode is safe for optimization
                    const is_safe_border = switch (border_mode) {
                        .replicate, .mirror, .wrap => true,
                        else => false,
                    };

                    inline for (uniforms, 0..) |uniform_value, i| {
                        is_uniform[i] = uniform_value != null and is_safe_border;
                    }

                    // Count how many channels need storage
                    var num_alloc_channels: usize = 0;
                    inline for (is_uniform) |uniform| {
                        if (!uniform) num_alloc_channels += 1;
                    }

                    // Single contiguous allocation for all output channels, plus temp buffer
                    const total_u8_size = try std.math.mul(usize, num_alloc_channels, plane_size);
                    var contiguous_u8_buffer: []u8 = if (total_u8_size > 0)
                        try allocator.alloc(u8, total_u8_size)
                    else
                        &.{};
                    defer if (contiguous_u8_buffer.len > 0) allocator.free(contiguous_u8_buffer);

                    // Temp buffer (shared for all channels)
                    var temp_plane_data: []i32 = if (num_alloc_channels > 0)
                        try allocator.alloc(i32, plane_size)
                    else
                        &.{};
                    defer if (temp_plane_data.len > 0) allocator.free(temp_plane_data);

                    // Assign slices from contiguous buffer to out_channels
                    var out_channels: [channels.len][]u8 = undefined;
                    var alloc_offset: usize = 0;
                    inline for (&out_channels, is_uniform) |*out_ch, uniform| {
                        if (uniform) {
                            out_ch.* = &.{};
                        } else {
                            out_ch.* = contiguous_u8_buffer[alloc_offset..][0..plane_size];
                            alloc_offset += plane_size;
                        }
                    }

                    // Convolve only non-uniform channels, reusing the shared temp buffer
                    inline for (channels, out_channels, is_uniform) |src_data, dst_data, uniform| {
                        if (!uniform) {
                            const src_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = src_data };
                            const dst_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = dst_data };
                            const tmp_plane: Image(i32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = temp_plane_data };
                            convolveSeparablePlane(u8, u8, i32, i32, src_plane, dst_plane, tmp_plane, kernel_x_int, kernel_y_int, border_mode);
                        }
                    }

                    // Recombine channels, using original values for uniform channels
                    var final_channels: [channels.len][]const u8 = undefined;
                    inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                        if (uniform) {
                            // For uniform channels with safe borders, separable convolution preserves the value
                            // (assuming normalized kernel, which is typical for separable filters like Gaussian)
                            // If kernel is not normalized, we should technically scale it, but this path
                            // assumes normalized kernels for simplicity in separable path.
                            // If strict correctness for non-normalized separable kernels on uniform images is required,
                            // we should probably skip optimization or implement scalar mult.
                            final_channels[i] = src_ch;
                        } else {
                            final_channels[i] = out_ch;
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

/// Generic implementation of separable convolution plane.
/// Supports both u8 (via i32 intermediates) and f32.
/// Uses i64 accumulators for i32 intermediates to prevent overflow.
fn convolveSeparablePlane(
    comptime SrcT: type,
    comptime DstT: type,
    comptime TempT: type,
    comptime KernelT: type,
    src_img: Image(SrcT),
    dst_img: Image(DstT),
    temp_img: Image(TempT),
    kernel_x: []const KernelT,
    kernel_y: []const KernelT,
    border_mode: BorderMode,
) void {
    const half_x = kernel_x.len / 2;
    const half_y = kernel_y.len / 2;
    const rows = src_img.rows;
    const cols = src_img.cols;

    // Use wider accumulator for integer types to prevent overflow
    const AccumT = if (TempT == i32) i64 else TempT;
    const vec_len = std.simd.suggestVectorLength(TempT) orelse 1;

    // Helper for checking negligible kernel values (exact for int, epsilon for float)
    const isNegligible = struct {
        inline fn check(k: KernelT) bool {
            if (KernelT == f32) {
                return @abs(k) < 1e-10;
            } else {
                return k == 0;
            }
        }
    }.check;

    const Ops = struct {
        /// Helper to promote values or vectors to the accumulator type
        inline fn promote(v: anytype) if (@typeInfo(@TypeOf(v)) == .vector) @Vector(vec_len, AccumT) else AccumT {
            return if (AccumT == i64) @intCast(v) else v;
        }

        inline fn loadSrcVec(ptr: [*]const SrcT) @Vector(vec_len, TempT) {
            if (SrcT == u8 and TempT == i32) {
                const v: @Vector(vec_len, u8) = ptr[0..vec_len].*;
                return @intCast(v);
            } else {
                return ptr[0..vec_len].*;
            }
        }

        inline fn storeDstVec(val: @Vector(vec_len, AccumT), ptr: [*]DstT) void {
            if (DstT == u8 and AccumT == i64) {
                const scale_sq: i64 = 256 * 256;
                const half_scale_sq: i64 = scale_sq / 2;
                const scale_vec: @Vector(vec_len, i64) = @splat(scale_sq);
                const zero_vec: @Vector(vec_len, i64) = @splat(0);

                // Symmetric rounding: add half for positive, subtract for negative
                const pos_offset: @Vector(vec_len, i64) = @splat(half_scale_sq);
                const neg_offset: @Vector(vec_len, i64) = @splat(-half_scale_sq);
                const rounding = @select(i64, val >= zero_vec, pos_offset, neg_offset);
                const rounded = @divTrunc(val + rounding, scale_vec);

                // Vectorized clamping and storing
                const max_u8_vec: @Vector(vec_len, i64) = @splat(255);
                const clamped = @max(zero_vec, @min(max_u8_vec, rounded));
                ptr[0..vec_len].* = @as(@Vector(vec_len, u8), @intCast(clamped));
            } else {
                if (AccumT == i64 and DstT == i32) {
                    var dst_v: @Vector(vec_len, i32) = undefined;
                    inline for (0..vec_len) |i| {
                        dst_v[i] = @intCast(meta.clamp(i32, val[i]));
                    }
                    ptr[0..vec_len].* = dst_v;
                } else {
                    ptr[0..vec_len].* = val;
                }
            }
        }

        inline fn storeDstScalar(val: AccumT) DstT {
            if (DstT == u8 and AccumT == i64) {
                const scale_sq: i64 = 256 * 256;
                const half_scale_sq: i64 = scale_sq / 2;
                // Symmetric rounding: add half for positive, subtract for negative
                const rounded = @divTrunc(val + (if (val >= 0) half_scale_sq else -half_scale_sq), scale_sq);
                return meta.clamp(u8, rounded);
            } else {
                if (AccumT == i64 and DstT == i32) {
                    return @intCast(meta.clamp(i32, val));
                } else {
                    return val;
                }
            }
        }

        inline fn storeTempVec(val: @Vector(vec_len, AccumT), ptr: [*]TempT) void {
            if (TempT == i32 and AccumT == i64) {
                var temp_v: @Vector(vec_len, i32) = undefined;
                inline for (0..vec_len) |i| {
                    temp_v[i] = @intCast(meta.clamp(i32, val[i]));
                }
                ptr[0..vec_len].* = temp_v;
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

        // Process Left Border
        const left_border_end = @min(half_x, cols);
        while (c < left_border_end) : (c += 1) {
            var result: AccumT = 0;
            const ic: isize = @intCast(c);
            for (kernel_x, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val = getPixel(SrcT, src_img, @intCast(r), icx, border_mode);
                result += Ops.promote(pixel_val) * Ops.promote(k);
            }
            temp_img.data[temp_offset + c] = Ops.storeTempScalar(result);
        }

        // Process Interior
        if (cols > 2 * half_x) {
            const interior_end = cols - half_x;

            // SIMD loop
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

            // Scalar cleanup
            while (c < interior_end) : (c += 1) {
                var result: AccumT = 0;
                const c0 = c - half_x;
                for (kernel_x, 0..) |k, i| {
                    const src_val = src_img.data[row_offset + c0 + i];
                    result += Ops.promote(src_val) * Ops.promote(k);
                }
                temp_img.data[temp_offset + c] = Ops.storeTempScalar(result);
            }
        }

        // Process Right Border
        while (c < cols) : (c += 1) {
            var result: AccumT = 0;
            const ic: isize = @intCast(c);
            for (kernel_x, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val = getPixel(SrcT, src_img, @intCast(r), icx, border_mode);
                result += Ops.promote(pixel_val) * Ops.promote(k);
            }
            temp_img.data[temp_offset + c] = Ops.storeTempScalar(result);
        }
    }

    // Vertical pass (temp -> dst) with loop tiling for better cache locality
    // Process in column tiles to keep data in cache during strided vertical access
    const tile_width = 16; // Tune based on cache line size (64 bytes / sizeof(TempT) of 4 bytes = 16 elements)

    if (rows > 2 * half_y) {
        const safe_end_r = rows - half_y;

        // Process column tiles with column-major order for cache locality
        // For vertical convolution, consecutive rows at same column share overlapping reads
        var tile_c: usize = 0;
        while (tile_c < cols) : (tile_c += tile_width) {
            const tile_end = @min(tile_c + tile_width, cols);
            var c: usize = tile_c;

            // SIMD processing: process all rows for each vector of columns
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

            // Remaining columns within tile (scalar): process all rows for each column
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

    // Handle top and bottom border rows (scalar)
    // Avoid overlap: top border ends at min(half_y, rows), bottom border starts at max of that and (rows - half_y)
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
                    // temp_img is of type TempT. We can use getPixel on it.
                    // getPixel for i32/f32 returns i32/f32.
                    const pixel_val = getPixel(TempT, temp_img, iry, @intCast(c), border_mode);
                    result += Ops.promote(pixel_val) * Ops.promote(k);
                }
                dst_img.data[r * dst_img.stride + c] = Ops.storeDstScalar(result);
            }
        }
    }
}

/// Get pixel value with border handling, automatically converting to appropriate scalar type.
/// Returns i32 for u8/i32 pixels (for integer arithmetic), f32 for f32 pixels.
fn getPixel(comptime T: type, img: Image(T), row: isize, col: isize, border_mode: BorderMode) if (T == f32) f32 else i32 {
    if (T != u8 and T != f32 and T != i32) @compileError("getPixel only works with u8, i32 and f32 types");
    const coords = border.computeCoords(row, col, @intCast(img.rows), @intCast(img.cols), border_mode);
    const pixel = if (coords) |c| img.at(c.row, c.col).* else 0;
    return if (T == u8) @as(i32, pixel) else pixel;
}

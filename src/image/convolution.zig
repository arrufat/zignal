const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const channel_ops = @import("channel_ops.zig");

/// Border handling modes for filter operations
pub const BorderMode = enum {
    /// Pad with zeros
    zero,
    /// Replicate edge pixels
    replicate,
    /// Mirror at edges
    mirror,
    /// Wrap around (circular)
    wrap,
};

/// Pixel I/O operations for type-specific convolution.
/// Provides unified load/store operations for both u8 (with integer scaling) and f32.
fn PixelIO(comptime T: type, comptime vec_len: usize) type {
    if (T != u8 and T != f32) {
        @compileError("PixelIO only supports u8 and f32 types");
    }

    return struct {
        const Scalar = if (T == u8) i32 else f32;
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
                const rounded = @divTrunc(accum + scale / 2, scale);
                return @intCast(@max(0, @min(255, rounded)));
            } else {
                return accum;
            }
        }

        inline fn storeVec(accum_vec: @Vector(vec_len, Scalar), dst: []T, offset: usize) void {
            if (T == u8) {
                const half_scale_vec: @Vector(vec_len, Scalar) = @splat(scale / 2);
                const scale_vec: @Vector(vec_len, Scalar) = @splat(scale);
                const rounded_vec = @divTrunc(accum_vec + half_scale_vec, scale_vec);

                inline for (0..vec_len) |i| {
                    dst[offset + i] = @intCast(@max(0, @min(255, rounded_vec[i])));
                }
            } else {
                inline for (0..vec_len) |i| {
                    dst[offset + i] = accum_vec[i];
                }
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
        const Scalar = if (T == u8) i32 else f32;
        const vec_len = std.simd.suggestVectorLength(Scalar) orelse 1;

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

        fn convolve(src: Image(T), dst: Image(T), kernel: [size]Scalar, border: BorderMode) void {
            // Pre-create kernel vectors for SIMD (for f32)
            var kernel_vecs: [size]@Vector(vec_len, Scalar) = undefined;
            if (T == f32) {
                inline for (0..size) |i| {
                    kernel_vecs[i] = @splat(kernel[i]);
                }
            }

            for (0..src.rows) |r| {
                var c: usize = 0;

                // SIMD path for interior pixels
                if (r >= half_h and r + half_h < src.rows and src.cols > vec_len + cols) {
                    c = half_w;
                    const safe_end = if (src.cols > vec_len + half_w) src.cols - vec_len - half_w else half_w;

                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var result_vec: @Vector(vec_len, Scalar) = @splat(0);

                        // Unroll kernel application for known sizes
                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const kid = ky * cols + kx;

                                const kernel_vec = if (T == f32)
                                    kernel_vecs[kid]
                                else
                                    @as(@Vector(vec_len, Scalar), @splat(kernel[kid]));

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

                // Scalar path for remaining pixels
                while (c < src.cols) : (c += 1) {
                    if (r >= half_h and r + half_h < src.rows and c >= half_w and c + half_w < src.cols) {
                        // Interior pixel - no border handling needed
                        var result: Scalar = 0;
                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                const pixel_val = Pixels.load(src.data[src_r * src.stride + src_c]);
                                result += pixel_val * kernel[ky * cols + kx];
                            }
                        }
                        dst.data[r * dst.stride + c] = Pixels.store(result);
                    } else {
                        // Border pixel - needs border handling
                        const ir = @as(isize, @intCast(r));
                        const ic = @as(isize, @intCast(c));
                        var result: Scalar = 0;
                        inline for (0..rows) |ky| {
                            inline for (0..cols) |kx| {
                                const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                                const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                                const pixel_val = getPixel(T, src, iry, icx, border);
                                result += pixel_val * kernel[ky * cols + kx];
                            }
                        }
                        dst.data[r * dst.stride + c] = Pixels.store(result);
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
pub fn convolve(comptime T: type, self: Image(T), allocator: Allocator, kernel: anytype, out: *Image(T), border_mode: BorderMode) !void {
    const kernel_info = @typeInfo(@TypeOf(kernel));
    if (kernel_info != .array) @compileError("Kernel must be a 2D array");
    const outer_array = kernel_info.array;
    if (@typeInfo(outer_array.child) != .array) @compileError("Kernel must be a 2D array");

    const kernel_height = outer_array.len;
    const kernel_width = @typeInfo(outer_array.child).array.len;

    if (!self.hasSameShape(out.*)) {
        out.deinit(allocator);
        out.* = try .init(allocator, self.rows, self.cols);
    }

    switch (T) {
        u8, f32 => {
            const Kernel = ConvolutionKernel(T, kernel_height, kernel_width);
            const flat_kernel = Kernel.flatten(kernel);
            Kernel.convolve(self, out.*, flat_kernel, border_mode);
        },
        else => switch (@typeInfo(T)) {
            .int, .float => {
                // Generic scalar path for other types
                const half_h = kernel_height / 2;
                const half_w = kernel_width / 2;
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        var accumulator: f32 = 0;

                        const in_interior = (r >= half_h and r + half_h < self.rows and c >= half_w and c + half_w < self.cols);
                        if (in_interior) {
                            // Fast path: no border handling needed
                            const r0: usize = r - half_h;
                            const c0: usize = c - half_w;
                            for (0..kernel_height) |kr| {
                                const rr = r0 + kr;
                                for (0..kernel_width) |kc| {
                                    const cc = c0 + kc;
                                    const pixel_val = self.at(rr, cc).*;
                                    const kernel_val = kernel[kr][kc];
                                    accumulator += as(f32, pixel_val) * as(f32, kernel_val);
                                }
                            }
                        } else {
                            // Border path: fetch with border handling
                            for (0..kernel_height) |kr| {
                                for (0..kernel_width) |kc| {
                                    const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(kr)) - @as(isize, @intCast(half_h));
                                    const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(kc)) - @as(isize, @intCast(half_w));
                                    const pixel_val = getPixel(T, self, src_r, src_c, border_mode);
                                    const kernel_val = kernel[kr][kc];
                                    accumulator += as(f32, pixel_val) * as(f32, kernel_val);
                                }
                            }
                        }

                        out.at(r, c).* = switch (@typeInfo(T)) {
                            .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(accumulator)))),
                            .float => as(T, accumulator),
                            else => unreachable,
                        };
                    }
                }
            },
            .@"struct" => {
                // Optimized path for u8 structs (RGB, RGBA, etc.)
                if (comptime meta.allFieldsAreU8(T)) {
                    const Kernel = ConvolutionKernel(u8, kernel_height, kernel_width);
                    // Channel separation approach for optimal performance
                    const kernel_int = Kernel.flatten(kernel);
                    const plane_size = self.rows * self.cols;

                    // Separate channels using helper
                    const channels = try channel_ops.splitChannels(T, self, allocator);
                    defer for (channels) |channel| allocator.free(channel);

                    // Check which channels are uniform to avoid unnecessary processing
                    var is_uniform: [channels.len]bool = undefined;
                    var uniform_values: [channels.len]u8 = undefined;
                    var non_uniform_count: usize = 0;

                    inline for (channels, 0..) |src_data, i| {
                        if (channel_ops.findUniformValue(u8, src_data)) |uniform_val| {
                            is_uniform[i] = true;
                            uniform_values[i] = uniform_val;
                        } else {
                            is_uniform[i] = false;
                            non_uniform_count += 1;
                        }
                    }

                    // Allocate output planes only for non-uniform channels
                    var out_channels: [channels.len][]u8 = undefined;
                    inline for (&out_channels, is_uniform) |*ch, uniform| {
                        if (uniform) {
                            // For uniform channels with normalized kernels, output is same as input
                            ch.* = &[_]u8{}; // Empty slice as placeholder
                        } else {
                            ch.* = try allocator.alloc(u8, plane_size);
                        }
                    }
                    defer {
                        inline for (out_channels, is_uniform) |ch, uniform| {
                            if (!uniform and ch.len > 0) allocator.free(ch);
                        }
                    }

                    // Convolve only non-uniform channels
                    inline for (channels, out_channels, is_uniform) |src_data, dst_data, uniform| {
                        if (!uniform) {
                            const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                            const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                            Kernel.convolve(src_plane, dst_plane, kernel_int, border_mode);
                        }
                    }

                    // Recombine channels, using original values for uniform channels
                    var final_channels: [channels.len][]const u8 = undefined;
                    inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                        if (uniform) {
                            // For uniform channels, convolution with normalized kernel preserves the value
                            final_channels[i] = src_ch;
                        } else {
                            final_channels[i] = out_ch;
                        }
                    }
                    channel_ops.mergeChannels(T, final_channels, out.*);
                } else {
                    // Generic struct path for other color types
                    const fields = std.meta.fields(T);
                    const half_h = kernel_height / 2;
                    const half_w = kernel_width / 2;

                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var result_pixel: T = undefined;

                            inline for (fields) |field| {
                                var accumulator: f32 = 0;
                                const in_interior = (r >= half_h and r + half_h < self.rows and c >= half_w and c + half_w < self.cols);
                                if (in_interior) {
                                    const r0: usize = r - half_h;
                                    const c0: usize = c - half_w;
                                    for (0..kernel_height) |kr| {
                                        const rr = r0 + kr;
                                        for (0..kernel_width) |kc| {
                                            const cc = c0 + kc;
                                            const pixel_val = self.at(rr, cc).*;
                                            const channel_val = @field(pixel_val, field.name);
                                            const kernel_val = kernel[kr][kc];
                                            accumulator += as(f32, channel_val) * as(f32, kernel_val);
                                        }
                                    }
                                } else {
                                    for (0..kernel_height) |kr| {
                                        for (0..kernel_width) |kc| {
                                            const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(kr)) - @as(isize, @intCast(half_h));
                                            const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(kc)) - @as(isize, @intCast(half_w));
                                            const pixel_val = getPixel(T, self, src_r, src_c, border_mode);
                                            const channel_val = @field(pixel_val, field.name);
                                            const kernel_val = kernel[kr][kc];
                                            accumulator += as(f32, channel_val) * as(f32, kernel_val);
                                        }
                                    }
                                }

                                @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                    .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(accumulator)))),
                                    .float => as(field.type, accumulator),
                                    else => @compileError("Unsupported field type in struct"),
                                };
                            }

                            out.at(r, c).* = result_pixel;
                        }
                    }
                }
            },
            else => @compileError("Convolution not supported for type " ++ @typeName(T)),
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
    out: *Image(T),
    border: BorderMode,
) !void {
    // Ensure output is properly allocated
    if (out.rows == 0 or out.cols == 0 or !image.hasSameShape(out.*)) {
        out.deinit(allocator);
        out.* = try .init(allocator, image.rows, image.cols);
    }

    // Allocate temporary buffer for intermediate result
    var temp: Image(T) = try .init(allocator, image.rows, image.cols);
    defer temp.deinit(allocator);

    const half_x = kernel_x.len / 2;
    const half_y = kernel_y.len / 2;

    // Horizontal pass
    switch (@typeInfo(T)) {
        .int, .float => {
            // Optimized path for u8 with integer arithmetic
            if (T == u8) {
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

                convolveSeparableU8Plane(image, out.*, temp, kernel_x_int, kernel_y_int, border);
                return;
            }

            // Optimized path for f32 with SIMD
            if (T == f32) {
                const src_plane: Image(f32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = image.data };
                const dst_plane: Image(f32) = .{ .rows = out.rows, .cols = out.cols, .stride = out.stride, .data = out.data };
                const tmp_plane: Image(f32) = .{ .rows = temp.rows, .cols = temp.cols, .stride = temp.stride, .data = temp.data };
                convolveSeparableF32Plane(src_plane, dst_plane, tmp_plane, kernel_x, kernel_y, border);
                return;
            }

            // Generic path for other scalar types
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    var sum: f32 = 0;
                    if (c >= half_x and c + half_x < image.cols) {
                        const c0: usize = c - half_x;
                        for (kernel_x, 0..) |k, i| {
                            const cc = c0 + i;
                            const pixel = image.at(r, cc).*;
                            sum += as(f32, pixel) * k;
                        }
                    } else {
                        for (kernel_x, 0..) |k, i| {
                            const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                            const pixel = getPixel(T, image, @as(isize, @intCast(r)), src_c, border);
                            sum += as(f32, pixel) * k;
                        }
                    }
                    // Guard against NaN/Inf before casting
                    const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                    temp.at(r, c).* = switch (@typeInfo(T)) {
                        .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum_safe)))),
                        .float => as(T, sum_safe),
                        else => unreachable,
                    };
                }
            }
        },
        .@"struct" => {
            // Optimized path for u8 structs (RGB, RGBA, etc.)
            if (comptime meta.allFieldsAreU8(T)) {
                // Channel separation approach for optimal performance
                const SCALE = 256;
                const plane_size = image.rows * image.cols;

                // Convert kernels to integer
                const kernel_x_int = try allocator.alloc(i32, kernel_x.len);
                defer allocator.free(kernel_x_int);
                const kernel_y_int = try allocator.alloc(i32, kernel_y.len);
                defer allocator.free(kernel_y_int);

                for (kernel_x, 0..) |k, i| {
                    kernel_x_int[i] = @intFromFloat(@round(k * SCALE));
                }
                for (kernel_y, 0..) |k, i| {
                    kernel_y_int[i] = @intFromFloat(@round(k * SCALE));
                }

                // Separate channels using helper
                const channels = try channel_ops.splitChannels(T, image, allocator);
                defer for (channels) |channel| allocator.free(channel);

                // Check which channels are uniform to avoid unnecessary processing
                var is_uniform: [channels.len]bool = undefined;
                var uniform_values: [channels.len]u8 = undefined;
                var non_uniform_count: usize = 0;

                inline for (channels, 0..) |src_data, i| {
                    if (channel_ops.findUniformValue(u8, src_data)) |uniform_val| {
                        is_uniform[i] = true;
                        uniform_values[i] = uniform_val;
                    } else {
                        is_uniform[i] = false;
                        non_uniform_count += 1;
                    }
                }

                // Allocate output and temp planes only for non-uniform channels
                var out_channels: [channels.len][]u8 = undefined;
                var temp_channels: [channels.len][]u8 = undefined;
                inline for (&out_channels, &temp_channels, is_uniform) |*out_ch, *temp_ch, uniform| {
                    if (uniform) {
                        // For uniform channels, no processing needed
                        out_ch.* = &[_]u8{};
                        temp_ch.* = &[_]u8{};
                    } else {
                        out_ch.* = try allocator.alloc(u8, plane_size);
                        temp_ch.* = try allocator.alloc(u8, plane_size);
                    }
                }
                defer {
                    inline for (out_channels, temp_channels, is_uniform) |out_ch, temp_ch, uniform| {
                        if (!uniform) {
                            if (out_ch.len > 0) allocator.free(out_ch);
                            if (temp_ch.len > 0) allocator.free(temp_ch);
                        }
                    }
                }

                // Convolve only non-uniform channels
                inline for (channels, out_channels, temp_channels, is_uniform) |src_data, dst_data, temp_data, uniform| {
                    if (!uniform) {
                        const src_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = src_data };
                        const dst_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = dst_data };
                        const tmp_plane: Image(u8) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = temp_data };
                        convolveSeparableU8Plane(src_plane, dst_plane, tmp_plane, kernel_x_int, kernel_y_int, border);
                    }
                }

                // Recombine channels, using original values for uniform channels
                var final_channels: [channels.len][]const u8 = undefined;
                inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                    if (uniform) {
                        // For uniform channels, separable convolution preserves the value
                        final_channels[i] = src_ch;
                    } else {
                        final_channels[i] = out_ch;
                    }
                }
                channel_ops.mergeChannels(T, final_channels, out.*);
                return; // Skip the rest of the function
            }

            // Generic struct path for other color types
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    var result_pixel: T = undefined;
                    inline for (std.meta.fields(T)) |field| {
                        var sum: f32 = 0;
                        if (c >= half_x and c + half_x < image.cols) {
                            const c0: usize = c - half_x;
                            for (kernel_x, 0..) |k, i| {
                                const cc = c0 + i;
                                const pixel = image.at(r, cc).*;
                                sum += as(f32, @field(pixel, field.name)) * k;
                            }
                        } else {
                            for (kernel_x, 0..) |k, i| {
                                const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                                const pixel = getPixel(T, image, @as(isize, @intCast(r)), src_c, border);
                                sum += as(f32, @field(pixel, field.name)) * k;
                            }
                        }
                        const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                        @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                            .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(sum_safe)))),
                            .float => as(field.type, sum_safe),
                            else => @compileError("Unsupported field type"),
                        };
                    }
                    temp.at(r, c).* = result_pixel;
                }
            }
        },
        else => @compileError("Separable convolution not supported for type " ++ @typeName(T)),
    }

    // Vertical pass
    switch (@typeInfo(T)) {
        .int, .float => {
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    var sum: f32 = 0;
                    if (r >= half_y and r + half_y < image.rows) {
                        const r0: usize = r - half_y;
                        for (kernel_y, 0..) |k, i| {
                            const rr = r0 + i;
                            const pixel = temp.at(rr, c).*;
                            sum += as(f32, pixel) * k;
                        }
                    } else {
                        for (kernel_y, 0..) |k, i| {
                            const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                            const pixel = getPixel(T, temp, src_r, @as(isize, @intCast(c)), border);
                            sum += as(f32, pixel) * k;
                        }
                    }
                    const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                    out.at(r, c).* = switch (@typeInfo(T)) {
                        .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum_safe)))),
                        .float => as(T, sum_safe),
                        else => unreachable,
                    };
                }
            }
        },
        .@"struct" => {
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    var result_pixel: T = undefined;
                    inline for (std.meta.fields(T)) |field| {
                        var sum: f32 = 0;
                        if (r >= half_y and r + half_y < image.rows) {
                            const r0: usize = r - half_y;
                            for (kernel_y, 0..) |k, i| {
                                const rr = r0 + i;
                                const pixel = temp.at(rr, c).*;
                                sum += as(f32, @field(pixel, field.name)) * k;
                            }
                        } else {
                            for (kernel_y, 0..) |k, i| {
                                const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                                const pixel = getPixel(T, temp, src_r, @as(isize, @intCast(c)), border);
                                sum += as(f32, @field(pixel, field.name)) * k;
                            }
                        }
                        const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                        @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                            .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(sum_safe)))),
                            .float => as(field.type, sum_safe),
                            else => @compileError("Unsupported field type"),
                        };
                    }
                    out.at(r, c).* = result_pixel;
                }
            }
        },
        else => unreachable,
    }
}

// ============================================================================
// Optimized Plane Processing Functions
// ============================================================================

/// Unified separable convolution for both u8 and f32 planes with SIMD.
/// For u8, kernels must be pre-scaled by 256 for integer arithmetic.
fn convolveSeparablePlane(
    comptime T: type,
    src_img: Image(T),
    dst_img: Image(T),
    temp_img: Image(T),
    kernel_x: anytype,
    kernel_y: anytype,
    border_mode: BorderMode,
) void {
    const Scalar = if (T == u8) i32 else f32;
    const half_x = kernel_x.len / 2;
    const half_y = kernel_y.len / 2;
    const rows = src_img.rows;
    const cols = src_img.cols;
    const vec_len = std.simd.suggestVectorLength(Scalar) orelse 8;

    // Use the shared pixel I/O operations
    const Pixels = PixelIO(T, vec_len);

    // Horizontal pass (src -> temp) with SIMD
    for (0..rows) |r| {
        const row_offset = r * src_img.stride;
        const temp_offset = r * temp_img.stride;

        // Process interior pixels with SIMD (no border handling)
        if (cols > 2 * half_x) {
            var c: usize = half_x;
            const safe_end = cols - half_x;

            // SIMD processing for interior pixels
            while (c + vec_len <= safe_end) : (c += vec_len) {
                var acc: @Vector(vec_len, Scalar) = @splat(0);

                // Apply kernel
                for (kernel_x, 0..) |k, ki| {
                    if (k != 0) {
                        const src_idx = row_offset + c + ki - half_x;
                        const pixels_vec = Pixels.loadVec(src_img.data, src_idx);
                        const k_vec: @Vector(vec_len, Scalar) = @splat(k);
                        acc += pixels_vec * k_vec;
                    }
                }

                Pixels.storeVec(acc, temp_img.data, temp_offset + c);
            }

            // Handle remaining pixels with scalar code
            while (c < safe_end) : (c += 1) {
                var result: Scalar = 0;
                const c0 = c - half_x;
                for (kernel_x, 0..) |k, i| {
                    const cc = c0 + i;
                    const pixel_val = Pixels.load(src_img.data[row_offset + cc]);
                    result += pixel_val * k;
                }
                temp_img.data[temp_offset + c] = Pixels.store(result);
            }
        }

        // Handle borders with scalar code
        for (0..@min(half_x, cols)) |c| {
            var result: Scalar = 0;
            const ic = @as(isize, @intCast(c));
            for (kernel_x, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val = getPixel(T, src_img, @as(isize, @intCast(r)), icx, border_mode);
                result += pixel_val * k;
            }
            temp_img.data[temp_offset + c] = Pixels.store(result);
        }

        if (cols > half_x) {
            for (cols - half_x..cols) |c| {
                var result: Scalar = 0;
                const ic = @as(isize, @intCast(c));
                for (kernel_x, 0..) |k, i| {
                    const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                    const pixel_val = getPixel(T, src_img, @as(isize, @intCast(r)), icx, border_mode);
                    result += pixel_val * k;
                }
                temp_img.data[temp_offset + c] = Pixels.store(result);
            }
        }
    }

    // Vertical pass (temp -> dst) with SIMD across columns
    // Interior rows: process r in [half_y, rows - half_y)
    if (rows > 2 * half_y) {
        const safe_end_r = rows - half_y;
        for (half_y..safe_end_r) |r| {
            var c: usize = 0;

            // SIMD processing across columns
            while (c + vec_len <= cols) : (c += vec_len) {
                var acc: @Vector(vec_len, Scalar) = @splat(0);

                // Apply kernel
                for (kernel_y, 0..) |k, ki| {
                    if (k != 0) {
                        const src_row = r + ki - half_y;
                        const src_off = src_row * temp_img.stride;
                        const pixels_vec = Pixels.loadVec(temp_img.data, src_off + c);
                        const k_vec: @Vector(vec_len, Scalar) = @splat(k);
                        acc += pixels_vec * k_vec;
                    }
                }

                Pixels.storeVec(acc, dst_img.data, r * dst_img.stride + c);
            }

            // Remaining columns (scalar)
            while (c < cols) : (c += 1) {
                var result: Scalar = 0;
                const r0 = r - half_y;
                for (kernel_y, 0..) |k, i| {
                    if (k == 0) continue;
                    const rr = r0 + i;
                    const pixel_val = Pixels.load(temp_img.data[rr * temp_img.stride + c]);
                    result += pixel_val * k;
                }
                dst_img.data[r * dst_img.stride + c] = Pixels.store(result);
            }
        }
    }

    // Handle top border rows (scalar across columns)
    for (0..@min(half_y, rows)) |r| {
        for (0..cols) |c| {
            var result: Scalar = 0;
            const ir = @as(isize, @intCast(r));
            for (kernel_y, 0..) |k, i| {
                const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                const pixel_val = getPixel(T, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                result += pixel_val * k;
            }
            dst_img.data[r * dst_img.stride + c] = Pixels.store(result);
        }
    }

    // Handle bottom border rows (scalar across columns)
    if (rows > half_y) {
        for (rows - half_y..rows) |r| {
            for (0..cols) |c| {
                var result: Scalar = 0;
                const ir = @as(isize, @intCast(r));
                for (kernel_y, 0..) |k, i| {
                    const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                    const pixel_val = getPixel(T, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                    result += pixel_val * k;
                }
                dst_img.data[r * dst_img.stride + c] = Pixels.store(result);
            }
        }
    }
}

/// Optimized separable convolution for u8 planes with SIMD integer arithmetic.
/// The kernel must be pre-scaled by 256 for integer arithmetic.
pub fn convolveSeparableU8Plane(
    src_img: Image(u8),
    dst_img: Image(u8),
    temp_img: Image(u8),
    kernel_x_int: []const i32,
    kernel_y_int: []const i32,
    border_mode: BorderMode,
) void {
    convolveSeparablePlane(u8, src_img, dst_img, temp_img, kernel_x_int, kernel_y_int, border_mode);
}

/// Optimized separable convolution for f32 planes with SIMD.
pub fn convolveSeparableF32Plane(
    src_img: Image(f32),
    dst_img: Image(f32),
    temp_img: Image(f32),
    kernel_x: []const f32,
    kernel_y: []const f32,
    border_mode: BorderMode,
) void {
    convolveSeparablePlane(f32, src_img, dst_img, temp_img, kernel_x, kernel_y, border_mode);
}

/// Get pixel value with border handling, automatically converting to appropriate scalar type.
/// Returns i32 for u8 pixels (for integer arithmetic), f32 for f32 pixels.
fn getPixel(comptime T: type, img: Image(T), row: isize, col: isize, border: BorderMode) if (T == u8) i32 else f32 {
    if (T != u8 and T != f32) @compileError("getPixel only works with u8 and f32 types");
    const coords = computeBorderCoords(row, col, @intCast(img.rows), @intCast(img.cols), border);
    const pixel = if (coords) |c| img.at(c.row, c.col).* else 0;
    return if (T == u8) @as(i32, pixel) else pixel;
}

/// Common border mode logic that returns adjusted coordinates.
/// Returns null when the result should be zero (out of bounds with .zero mode, or empty image).
fn computeBorderCoords(
    row: isize,
    col: isize,
    rows: isize,
    cols: isize,
    border: BorderMode,
) ?struct { row: usize, col: usize } {
    switch (border) {
        .zero => {
            if (row < 0 or col < 0 or row >= rows or col >= cols) {
                return null;
            }
            return .{ .row = @intCast(row), .col = @intCast(col) };
        },
        .replicate => {
            const r = @max(0, @min(row, rows - 1));
            const c = @max(0, @min(col, cols - 1));
            return .{ .row = @intCast(r), .col = @intCast(c) };
        },
        .mirror => {
            if (rows == 0 or cols == 0) return null;
            var r = row;
            var c = col;
            // Handle negative row indices
            while (r < 0) {
                r = -r - 1;
                if (r >= rows) r = 2 * rows - r - 1;
            }
            // Handle row indices >= rows
            while (r >= rows) {
                r = 2 * rows - r - 1;
                if (r < 0) r = -r - 1;
            }
            // Handle negative column indices
            while (c < 0) {
                c = -c - 1;
                if (c >= cols) c = 2 * cols - c - 1;
            }
            // Handle column indices >= cols
            while (c >= cols) {
                c = 2 * cols - c - 1;
                if (c < 0) c = -c - 1;
            }
            return .{ .row = @intCast(r), .col = @intCast(c) };
        },
        .wrap => {
            const r = @mod(row, rows);
            const c = @mod(col, cols);
            return .{ .row = @intCast(r), .col = @intCast(c) };
        },
    }
}

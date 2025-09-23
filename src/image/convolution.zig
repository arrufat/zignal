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

/// Comptime function generator for specialized convolution implementations.
/// Generates optimized code for specific kernel dimensions at compile time.
fn ConvolveKernel(comptime height: usize, comptime width: usize) type {
    return struct {
        const kernel_size = height * width;
        const half_h = height / 2;
        const half_w = width / 2;

        /// Optimized convolution for u8 planes with integer arithmetic.
        fn convolveU8Plane(
            src_img: Image(u8),
            dst_img: Image(u8),
            kernel: [kernel_size]i32,
            border_mode: BorderMode,
        ) void {
            const SCALE = 256;
            const vec_len = comptime std.simd.suggestVectorLength(i32) orelse 8;
            const rows = src_img.rows;
            const cols = src_img.cols;

            for (0..rows) |r| {
                var c: usize = 0;

                // SIMD path for interior pixels
                if (r >= half_h and r + half_h < rows and cols > vec_len + width) {
                    c = half_w;
                    const safe_end = if (cols > vec_len + half_w) cols - vec_len - half_w else half_w;

                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var result_vec: @Vector(vec_len, i32) = @splat(0);

                        // Unroll kernel application for known sizes
                        inline for (0..height) |ky| {
                            inline for (0..width) |kx| {
                                const kernel_val = kernel[ky * width + kx];
                                const kernel_vec: @Vector(vec_len, i32) = @splat(kernel_val);

                                var pixel_vec: @Vector(vec_len, i32) = undefined;
                                inline for (0..vec_len) |i| {
                                    const src_r = r + ky - half_h;
                                    const src_c = c + i + kx - half_w;
                                    pixel_vec[i] = src_img.data[src_r * src_img.stride + src_c];
                                }

                                result_vec += pixel_vec * kernel_vec;
                            }
                        }

                        const half_scale_vec: @Vector(vec_len, i32) = @splat(SCALE / 2);
                        const scale_vec: @Vector(vec_len, i32) = @splat(SCALE);
                        const rounded_vec = @divTrunc(result_vec + half_scale_vec, scale_vec);

                        inline for (0..vec_len) |i| {
                            dst_img.data[r * dst_img.stride + c + i] = @intCast(@max(0, @min(255, rounded_vec[i])));
                        }
                    }
                }

                while (c < cols) : (c += 1) {
                    if (r >= half_h and r + half_h < rows and c >= half_w and c + half_w < cols) {
                        var result: i32 = 0;
                        inline for (0..height) |ky| {
                            inline for (0..width) |kx| {
                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                const pixel_val = @as(i32, src_img.data[src_r * src_img.stride + src_c]);
                                result += pixel_val * kernel[ky * width + kx];
                            }
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                    } else {
                        const ir = @as(isize, @intCast(r));
                        const ic = @as(isize, @intCast(c));
                        var result: i32 = 0;
                        inline for (0..height) |ky| {
                            inline for (0..width) |kx| {
                                const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                                const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                                const pixel_val: i32 = getPixel(u8, src_img, iry, icx, border_mode);
                                result += pixel_val * kernel[ky * width + kx];
                            }
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }
            }
        }

        /// Optimized convolution for f32 planes with SIMD.
        fn convolveF32Plane(
            src_img: Image(f32),
            dst_img: Image(f32),
            kernel: [kernel_size]f32,
            border_mode: BorderMode,
        ) void {
            const vec_len = comptime std.simd.suggestVectorLength(f32) orelse 8;
            const rows = src_img.rows;
            const cols = src_img.cols;

            // Pre-create kernel vectors for SIMD
            var kernel_vecs: [kernel_size]@Vector(vec_len, f32) = undefined;
            inline for (0..kernel_size) |i| {
                kernel_vecs[i] = @splat(kernel[i]);
            }

            for (0..rows) |r| {
                var c: usize = 0;

                // SIMD path for interior pixels
                if (r >= half_h and r + half_h < rows and cols > vec_len + width) {
                    c = half_w;
                    const safe_end = if (cols > vec_len + half_w) cols - vec_len - half_w else half_w;

                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var result_vec: @Vector(vec_len, f32) = @splat(0);

                        inline for (0..height) |ky| {
                            inline for (0..width) |kx| {
                                const kid = ky * width + kx;
                                const kernel_vec = kernel_vecs[kid];

                                var pixel_vec: @Vector(vec_len, f32) = undefined;
                                inline for (0..vec_len) |i| {
                                    const src_r = r + ky - half_h;
                                    const src_c = c + i + kx - half_w;
                                    pixel_vec[i] = src_img.data[src_r * src_img.stride + src_c];
                                }

                                result_vec += pixel_vec * kernel_vec;
                            }
                        }

                        inline for (0..vec_len) |i| {
                            dst_img.data[r * dst_img.stride + c + i] = result_vec[i];
                        }
                    }
                }

                while (c < cols) : (c += 1) {
                    if (r >= half_h and r + half_h < rows and c >= half_w and c + half_w < cols) {
                        var result: f32 = 0;
                        inline for (0..height) |ky| {
                            inline for (0..width) |kx| {
                                const src_r = r + ky - half_h;
                                const src_c = c + kx - half_w;
                                result += src_img.data[src_r * src_img.stride + src_c] * kernel[ky * width + kx];
                            }
                        }
                        dst_img.data[r * dst_img.stride + c] = result;
                    } else {
                        const ir = @as(isize, @intCast(r));
                        const ic = @as(isize, @intCast(c));
                        var result: f32 = 0;
                        inline for (0..height) |ky| {
                            inline for (0..width) |kx| {
                                const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                                const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                                const pixel_val = getPixel(f32, src_img, iry, icx, border_mode);
                                result += pixel_val * kernel[ky * width + kx];
                            }
                        }
                        dst_img.data[r * dst_img.stride + c] = result;
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
        out.* = try .init(allocator, self.rows, self.cols);
    }

    // Generate specialized implementation for this kernel size
    const Kernel = ConvolveKernel(kernel_height, kernel_width);

    switch (@typeInfo(T)) {
        .int, .float => {
            // Optimized path for u8 with integer arithmetic
            if (T == u8) {
                // Convert floating-point kernel to integer
                const SCALE = 256;
                const kernel_int = flattenKernel(i32, Kernel.kernel_size, kernel, SCALE);

                Kernel.convolveU8Plane(self, out.*, kernel_int, border_mode);
            } else if (T == f32) {
                // Optimized path for f32 with SIMD
                const kernel_flat = flattenKernel(f32, Kernel.kernel_size, kernel, null);
                Kernel.convolveF32Plane(self, out.*, kernel_flat, border_mode);
            } else {
                // Generic scalar path for other types
                const half_h = Kernel.half_h;
                const half_w = Kernel.half_w;
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
            }
        },
        .@"struct" => {
            // Optimized path for u8 structs (RGB, RGBA, etc.)

            if (comptime meta.allFieldsAreU8(T)) {
                // Channel separation approach for optimal performance
                const SCALE = 256;
                const kernel_int = flattenKernel(i32, Kernel.kernel_size, kernel, SCALE);
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
                        Kernel.convolveU8Plane(src_plane, dst_plane, kernel_int, border_mode);
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
                const half_h = Kernel.half_h;
                const half_w = Kernel.half_w;

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
    border_mode: BorderMode,
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
                const SCALE = 256;
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
                // Enforce symmetry and exact sum preservation
                symmetrizeKernelI32(kernel_x_int, SCALE);
                symmetrizeKernelI32(kernel_y_int, SCALE);

                convolveSeparableU8Plane(image, out.*, temp, kernel_x_int, kernel_y_int, border_mode);
                return; // Skip the rest of the function
            }

            // Optimized path for f32 with SIMD
            if (T == f32) {
                const src_plane: Image(f32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = image.data };
                const dst_plane: Image(f32) = .{ .rows = out.rows, .cols = out.cols, .stride = out.stride, .data = out.data };
                const tmp_plane: Image(f32) = .{ .rows = temp.rows, .cols = temp.cols, .stride = temp.stride, .data = temp.data };
                convolveSeparableF32Plane(src_plane, dst_plane, tmp_plane, kernel_x, kernel_y, border_mode);
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
                            const pixel = getPixel(T, image, @as(isize, @intCast(r)), src_c, border_mode);
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
                        convolveSeparableU8Plane(src_plane, dst_plane, tmp_plane, kernel_x_int, kernel_y_int, border_mode);
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
                                const pixel = getPixel(T, image, @as(isize, @intCast(r)), src_c, border_mode);
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
                            const pixel = getPixel(T, temp, src_r, @as(isize, @intCast(c)), border_mode);
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
                                const pixel = getPixel(T, temp, src_r, @as(isize, @intCast(c)), border_mode);
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
    const SCALE = 256;
    const half_x = kernel_x_int.len / 2;
    const half_y = kernel_y_int.len / 2;
    const rows = src_img.rows;
    const cols = src_img.cols;
    const vec_len = std.simd.suggestVectorLength(i32) orelse 8;

    // Horizontal pass (src -> temp) with SIMD
    for (0..rows) |r| {
        const row_offset = r * src_img.stride;
        const temp_offset = r * temp_img.stride;

        // Process interior pixels with SIMD (no border handling)
        if (cols > 2 * half_x) {
            var c: usize = half_x;
            const safe_end = cols - half_x;

            // SIMD processing for interior pixels (symmetric kernel pairs)
            while (c + vec_len <= safe_end) : (c += vec_len) {
                var acc: @Vector(vec_len, i32) = @splat(0);

                // Center tap
                const k_center = kernel_x_int[half_x];
                if (k_center != 0) {
                    const center_u8: @Vector(vec_len, u8) = src_img.data[row_offset + c ..][0..vec_len].*;
                    const center_i32: @Vector(vec_len, i32) = @intCast(center_u8);
                    acc += center_i32 * @as(@Vector(vec_len, i32), @splat(k_center));
                }

                // Paired taps
                var di: usize = 1;
                while (di <= half_x) : (di += 1) {
                    const k = kernel_x_int[half_x + di];
                    if (k != 0) {
                        const left_u8: @Vector(vec_len, u8) = src_img.data[row_offset + c - di ..][0..vec_len].*;
                        const right_u8: @Vector(vec_len, u8) = src_img.data[row_offset + c + di ..][0..vec_len].*;
                        const left_i32: @Vector(vec_len, i32) = @intCast(left_u8);
                        const right_i32: @Vector(vec_len, i32) = @intCast(right_u8);
                        const pair_sum: @Vector(vec_len, i32) = left_i32 + right_i32;
                        acc += pair_sum * @as(@Vector(vec_len, i32), @splat(k));
                    }
                }

                // Vectorized rounding, clamp, and store
                var rounded_vec: @Vector(vec_len, i32) = (acc + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                const zero_vec: @Vector(vec_len, i32) = @splat(0);
                const max_vec: @Vector(vec_len, i32) = @splat(255);
                rounded_vec = @select(i32, rounded_vec < zero_vec, zero_vec, rounded_vec);
                rounded_vec = @select(i32, rounded_vec > max_vec, max_vec, rounded_vec);
                const out_vec: @Vector(vec_len, u8) = @intCast(rounded_vec);
                temp_img.data[temp_offset + c ..][0..vec_len].* = out_vec;
            }

            // Handle remaining pixels with scalar code
            while (c < safe_end) : (c += 1) {
                var result: i32 = 0;
                const c0 = c - half_x;
                for (kernel_x_int, 0..) |k, i| {
                    const cc = c0 + i;
                    const pixel_val = @as(i32, src_img.data[row_offset + cc]);
                    result += pixel_val * k;
                }
                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
            }
        }

        // Handle borders with scalar code
        for (0..@min(half_x, cols)) |c| {
            var result: i32 = 0;
            const ic = @as(isize, @intCast(c));
            for (kernel_x_int, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                result += pixel_val * k;
            }
            const rounded = @divTrunc(result + SCALE / 2, SCALE);
            temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
        }

        if (cols > half_x) {
            for (cols - half_x..cols) |c| {
                var result: i32 = 0;
                const ic = @as(isize, @intCast(c));
                for (kernel_x_int, 0..) |k, i| {
                    const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                    const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                    result += pixel_val * k;
                }
                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
            }
        }
    }

    // Vertical pass (temp -> dst) with SIMD across columns
    const vec_len_y = vec_len;

    // Interior rows: process r in [half_y, rows - half_y)
    if (rows > 2 * half_y) {
        const safe_end_r = rows - half_y;
        for (half_y..safe_end_r) |r| {
            var c: usize = 0;

            // SIMD processing across columns (symmetric kernel pairs)
            while (c + vec_len_y <= cols) : (c += vec_len_y) {
                var acc: @Vector(vec_len_y, i32) = @splat(0);

                // Center tap
                const k_center = kernel_y_int[half_y];
                if (k_center != 0) {
                    const center_off = r * temp_img.stride;
                    const center_u8: @Vector(vec_len_y, u8) = temp_img.data[center_off + c ..][0..vec_len_y].*;
                    const center_i32: @Vector(vec_len_y, i32) = @intCast(center_u8);
                    acc += center_i32 * @as(@Vector(vec_len_y, i32), @splat(k_center));
                }

                // Row pairs
                var di: usize = 1;
                while (di <= half_y) : (di += 1) {
                    const k = kernel_y_int[half_y + di];
                    if (k != 0) {
                        const top_off = (r - di) * temp_img.stride;
                        const bot_off = (r + di) * temp_img.stride;
                        const top_u8: @Vector(vec_len_y, u8) = temp_img.data[top_off + c ..][0..vec_len_y].*;
                        const bot_u8: @Vector(vec_len_y, u8) = temp_img.data[bot_off + c ..][0..vec_len_y].*;
                        const top_i32: @Vector(vec_len_y, i32) = @intCast(top_u8);
                        const bot_i32: @Vector(vec_len_y, i32) = @intCast(bot_u8);
                        const pair_sum: @Vector(vec_len_y, i32) = top_i32 + bot_i32;
                        acc += pair_sum * @as(@Vector(vec_len_y, i32), @splat(k));
                    }
                }

                var rounded: @Vector(vec_len_y, i32) = (acc + @as(@Vector(vec_len_y, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len_y, i32), @splat(SCALE));
                const zero_vec: @Vector(vec_len_y, i32) = @splat(0);
                const max_vec: @Vector(vec_len_y, i32) = @splat(255);
                const below = rounded < zero_vec;
                rounded = @select(i32, below, zero_vec, rounded);
                const above = rounded > max_vec;
                rounded = @select(i32, above, max_vec, rounded);
                // TODO(zig-upgrade): Once verified fixed, enable vector store branch below.
                if (comptime false) {
                    const out_vec: @Vector(vec_len_y, u8) = @intCast(rounded);
                    dst_img.data[r * dst_img.stride + c ..][0..vec_len_y].* = out_vec;
                } else {
                    // Work around vector cast/codegen bug:
                    // casting @Vector(N,i32) -> @Vector(N,u8) and storing caused upper lanes
                    // to mirror lower lanes in tests (gaussianBlur). Store lane-by-lane instead.
                    inline for (0..vec_len_y) |lane| {
                        const v: i32 = rounded[lane];
                        dst_img.data[r * dst_img.stride + c + lane] = @intCast(@max(0, @min(255, v)));
                    }
                }
            }

            // Remaining columns (scalar)
            while (c < cols) : (c += 1) {
                var result: i32 = 0;
                const r0 = r - half_y;
                for (kernel_y_int, 0..) |k, i| {
                    if (k == 0) continue;
                    const rr = r0 + i;
                    const pixel_val = @as(i32, temp_img.data[rr * temp_img.stride + c]);
                    result += pixel_val * k;
                }
                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
            }
        }
    }

    // Handle top border rows (scalar across columns)
    for (0..@min(half_y, rows)) |r| {
        for (0..cols) |c| {
            var result: i32 = 0;
            const ir = @as(isize, @intCast(r));
            for (kernel_y_int, 0..) |k, i| {
                const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                const pixel_val: i32 = getPixel(u8, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                result += pixel_val * k;
            }
            const rounded = @divTrunc(result + SCALE / 2, SCALE);
            dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
        }
    }

    // Handle bottom border rows (scalar across columns)
    if (rows > half_y) {
        for (rows - half_y..rows) |r| {
            for (0..cols) |c| {
                var result: i32 = 0;
                const ir = @as(isize, @intCast(r));
                for (kernel_y_int, 0..) |k, i| {
                    const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                    const pixel_val: i32 = getPixel(u8, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                    result += pixel_val * k;
                }
                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
            }
        }
    }
}

/// Helper for scalar convolution at a single pixel
inline fn convolveScalarHorizontal(
    src_img: Image(f32),
    row: usize,
    col: usize,
    kernel: []const f32,
    half_k: usize,
    border_mode: BorderMode,
) f32 {
    var sum: f32 = 0;
    const ir: isize = @intCast(row);
    const ic: isize = @intCast(col);
    for (kernel, 0..) |k, i| {
        const src_c = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_k));
        sum += getPixel(f32, src_img, ir, src_c, border_mode) * k;
    }
    return sum;
}

inline fn convolveScalarVertical(
    temp_img: Image(f32),
    row: usize,
    col: usize,
    kernel: []const f32,
    half_k: usize,
    border_mode: BorderMode,
) f32 {
    var sum: f32 = 0;
    const ir: isize = @intCast(row);
    const ic: isize = @intCast(col);
    for (kernel, 0..) |k, i| {
        const src_r = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_k));
        sum += getPixel(f32, temp_img, src_r, ic, border_mode) * k;
    }
    return sum;
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
    const rows = src_img.rows;
    const cols = src_img.cols;
    const half_x = kernel_x.len / 2;
    const half_y = kernel_y.len / 2;
    const vec_len = std.simd.suggestVectorLength(f32) orelse 8;

    // Horizontal pass (src -> temp)
    for (0..rows) |r| {
        var c: usize = 0;
        const row_offset = r * src_img.stride;
        const temp_offset = r * temp_img.stride;

        // Left border (scalar, needs border handling)
        const left_border_end = @min(half_x, cols);
        while (c < left_border_end) : (c += 1) {
            temp_img.data[temp_offset + c] = convolveScalarHorizontal(src_img, r, c, kernel_x, half_x, border_mode);
        }

        // SIMD interior - only if there's enough space
        if (cols > 2 * half_x + vec_len) {
            // Safe bounds: ensure we don't underflow and have room for vectors
            const safe_start = half_x;
            const safe_end = cols - half_x;
            c = safe_start;

            // Process full vectors
            while (c + vec_len <= safe_end) : (c += vec_len) {
                var acc: @Vector(vec_len, f32) = @splat(0);

                // Optimized memory access pattern - load contiguous data
                for (kernel_x, 0..) |k, kx| {
                    if (k == 0) continue; // Skip zero coefficients
                    const kv: @Vector(vec_len, f32) = @splat(k);
                    const src_idx = row_offset + c + kx - half_x;
                    // Load contiguous memory as vector
                    const pix: @Vector(vec_len, f32) = src_img.data[src_idx..][0..vec_len].*;
                    acc += pix * kv;
                }

                // Store results as vector
                temp_img.data[temp_offset + c ..][0..vec_len].* = acc;
            }

            // Process remaining elements in safe region with scalar
            while (c < safe_end) : (c += 1) {
                var sum: f32 = 0;
                const c0 = c - half_x;
                for (kernel_x, 0..) |k, i| {
                    sum += src_img.data[row_offset + c0 + i] * k;
                }
                temp_img.data[temp_offset + c] = sum;
            }
        }

        // Right border (scalar with border handling)
        while (c < cols) : (c += 1) {
            temp_img.data[temp_offset + c] = convolveScalarHorizontal(src_img, r, c, kernel_x, half_x, border_mode);
        }
    }

    // Vertical pass (temp -> dst)
    // Process in column blocks for better cache usage
    const block_size = 64; // Process columns in blocks for cache efficiency
    var col_block: usize = 0;

    while (col_block < cols) : (col_block += block_size) {
        const block_end = @min(col_block + block_size, cols);

        for (0..rows) |r| {
            const dst_offset = r * dst_img.stride;

            // Check if we can use SIMD for this row
            if (r >= half_y and r + half_y < rows) {
                // Safe region - can use direct memory access
                var c = col_block;
                const block_width = block_end - col_block;

                // Process vectors if block is wide enough
                if (block_width >= vec_len) {
                    const vec_end = col_block + (block_width / vec_len) * vec_len;

                    while (c < vec_end) : (c += vec_len) {
                        var acc: @Vector(vec_len, f32) = @splat(0);

                        // More efficient vertical access pattern
                        for (kernel_y, 0..) |k, ky| {
                            if (k == 0) continue; // Skip zero coefficients
                            const kv: @Vector(vec_len, f32) = @splat(k);
                            const src_row = r + ky - half_y;
                            const src_idx = src_row * temp_img.stride + c;
                            const pix: @Vector(vec_len, f32) = temp_img.data[src_idx..][0..vec_len].*;
                            acc += pix * kv;
                        }

                        dst_img.data[dst_offset + c ..][0..vec_len].* = acc;
                    }
                }

                // Process remaining scalar elements in safe region
                while (c < block_end) : (c += 1) {
                    var sum: f32 = 0;
                    const r0 = r - half_y;
                    for (kernel_y, 0..) |k, i| {
                        sum += temp_img.data[(r0 + i) * temp_img.stride + c] * k;
                    }
                    dst_img.data[dst_offset + c] = sum;
                }
            } else {
                // Border region - need boundary checks
                var c = col_block;
                while (c < block_end) : (c += 1) {
                    dst_img.data[dst_offset + c] = convolveScalarVertical(temp_img, r, c, kernel_y, half_y, border_mode);
                }
            }
        }
    }
}

/// Horizontal-only separable convolution for u8 plane (integer SIMD).
pub fn convolveHorizontalU8Plane(
    src_img: Image(u8),
    temp_img: Image(u8),
    kernel_x_int: []const i32,
    border_mode: BorderMode,
) void {
    const SCALE = 256;
    const half_x = kernel_x_int.len / 2;
    const rows = src_img.rows;
    const cols = src_img.cols;
    const vec_len = std.simd.suggestVectorLength(i32) orelse 8;

    for (0..rows) |r| {
        const row_offset = r * src_img.stride;
        const temp_offset = r * temp_img.stride;

        if (cols > 2 * half_x) {
            var c: usize = half_x;
            const safe_end = cols - half_x;

            while (c + vec_len <= safe_end) : (c += vec_len) {
                var results: @Vector(vec_len, i32) = @splat(0);
                for (kernel_x_int, 0..) |k, ki| {
                    if (k == 0) continue;
                    const k_vec: @Vector(vec_len, i32) = @splat(k);
                    const src_idx = row_offset + c - half_x + ki;
                    const pix_u8: @Vector(vec_len, u8) = src_img.data[src_idx..][0..vec_len].*;
                    const pix_i32: @Vector(vec_len, i32) = @intCast(pix_u8);
                    results += pix_i32 * k_vec;
                }
                var rounded: @Vector(vec_len, i32) = (results + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                const zero_vec: @Vector(vec_len, i32) = @splat(0);
                const max_vec: @Vector(vec_len, i32) = @splat(255);
                rounded = @select(i32, rounded < zero_vec, zero_vec, rounded);
                rounded = @select(i32, rounded > max_vec, max_vec, rounded);
                // TODO(zig-upgrade): Once verified fixed, enable vector store branch below.
                if (comptime false) {
                    const out_vec: @Vector(vec_len, u8) = @intCast(rounded);
                    temp_img.data[temp_offset + c ..][0..vec_len].* = out_vec;
                } else {
                    // Same workaround as above: avoid vector @intCast store due to Zig dev bug.
                    inline for (0..vec_len) |lane| {
                        const v: i32 = rounded[lane];
                        temp_img.data[temp_offset + c + lane] = @intCast(@max(0, @min(255, v)));
                    }
                }
            }

            while (c < safe_end) : (c += 1) {
                var result: i32 = 0;
                const c0 = c - half_x;
                for (kernel_x_int, 0..) |k, i| {
                    const cc = c0 + i;
                    result += @as(i32, src_img.data[row_offset + cc]) * k;
                }
                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
            }
        }

        // Left border
        for (0..@min(half_x, cols)) |c| {
            var result: i32 = 0;
            const ic = @as(isize, @intCast(c));
            for (kernel_x_int, 0..) |k, i| {
                const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                result += pixel_val * k;
            }
            const rounded = @divTrunc(result + SCALE / 2, SCALE);
            temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
        }

        // Right border
        if (cols > half_x) {
            for (cols - half_x..cols) |c| {
                var result: i32 = 0;
                const ic = @as(isize, @intCast(c));
                for (kernel_x_int, 0..) |k, i| {
                    const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                    const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                    result += pixel_val * k;
                }
                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
            }
        }
    }
}

/// Vertical dual-kernel pass: consumes two horizontal temps and writes DoG (blur1 - blur2).
pub fn convolveVerticalU8PlaneDual(
    temp1: Image(u8),
    temp2: Image(u8),
    dst_img: Image(u8),
    kernel_y1_int: []const i32,
    kernel_y2_int: []const i32,
    border_mode: BorderMode,
    offset_u8: u8,
) void {
    const SCALE = 256;
    const OFFSET: i32 = @intCast(offset_u8); // configurable offset
    const half_y1 = kernel_y1_int.len / 2;
    const half_y2 = kernel_y2_int.len / 2;
    const rows = dst_img.rows;
    const cols = dst_img.cols;
    const vec_len = std.simd.suggestVectorLength(i32) orelse 8;

    const half_y = @max(half_y1, half_y2);
    if (rows > 2 * half_y) {
        const safe_end_r = rows - half_y;
        for (half_y..safe_end_r) |r| {
            var c: usize = 0;
            while (c + vec_len <= cols) : (c += vec_len) {
                var acc1: @Vector(vec_len, i32) = @splat(0);
                var acc2: @Vector(vec_len, i32) = @splat(0);

                // Centers
                const k1_center = kernel_y1_int[half_y1];
                if (k1_center != 0) {
                    const center1_off = r * temp1.stride;
                    const v1_u8: @Vector(vec_len, u8) = temp1.data[center1_off + c ..][0..vec_len].*;
                    const v1_i32: @Vector(vec_len, i32) = @intCast(v1_u8);
                    acc1 += v1_i32 * @as(@Vector(vec_len, i32), @splat(k1_center));
                }
                const k2_center = kernel_y2_int[half_y2];
                if (k2_center != 0) {
                    const center2_off = r * temp2.stride;
                    const v2_u8: @Vector(vec_len, u8) = temp2.data[center2_off + c ..][0..vec_len].*;
                    const v2_i32: @Vector(vec_len, i32) = @intCast(v2_u8);
                    acc2 += v2_i32 * @as(@Vector(vec_len, i32), @splat(k2_center));
                }

                // Pairs for kernel1
                var di1: usize = 1;
                while (di1 <= half_y1) : (di1 += 1) {
                    const k = kernel_y1_int[half_y1 + di1];
                    if (k != 0) {
                        const top_off = (r - di1) * temp1.stride;
                        const bot_off = (r + di1) * temp1.stride;
                        const top_u8: @Vector(vec_len, u8) = temp1.data[top_off + c ..][0..vec_len].*;
                        const bot_u8: @Vector(vec_len, u8) = temp1.data[bot_off + c ..][0..vec_len].*;
                        const top_i32: @Vector(vec_len, i32) = @intCast(top_u8);
                        const bot_i32: @Vector(vec_len, i32) = @intCast(bot_u8);
                        acc1 += (top_i32 + bot_i32) * @as(@Vector(vec_len, i32), @splat(k));
                    }
                }
                // Pairs for kernel2
                var di2: usize = 1;
                while (di2 <= half_y2) : (di2 += 1) {
                    const k = kernel_y2_int[half_y2 + di2];
                    if (k != 0) {
                        const top_off = (r - di2) * temp2.stride;
                        const bot_off = (r + di2) * temp2.stride;
                        const top_u8: @Vector(vec_len, u8) = temp2.data[top_off + c ..][0..vec_len].*;
                        const bot_u8: @Vector(vec_len, u8) = temp2.data[bot_off + c ..][0..vec_len].*;
                        const top_i32: @Vector(vec_len, i32) = @intCast(top_u8);
                        const bot_i32: @Vector(vec_len, i32) = @intCast(bot_u8);
                        acc2 += (top_i32 + bot_i32) * @as(@Vector(vec_len, i32), @splat(k));
                    }
                }

                const r1: @Vector(vec_len, i32) = (acc1 + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                const r2: @Vector(vec_len, i32) = (acc2 + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                var diff: @Vector(vec_len, i32) = r1 - r2 + @as(@Vector(vec_len, i32), @splat(OFFSET));
                const zero_vec: @Vector(vec_len, i32) = @splat(0);
                const max_vec: @Vector(vec_len, i32) = @splat(255);
                diff = @select(i32, diff < zero_vec, zero_vec, diff);
                diff = @select(i32, diff > max_vec, max_vec, diff);
                const out_vec: @Vector(vec_len, u8) = @intCast(diff);
                dst_img.data[r * dst_img.stride + c ..][0..vec_len].* = out_vec;
            }

            // Scalar tail
            while (c < cols) : (c += 1) {
                var s1: i32 = 0;
                var s2: i32 = 0;
                const r01 = r - half_y1;
                const r02 = r - half_y2;
                for (kernel_y1_int, 0..) |k, i| {
                    if (k == 0) continue;
                    const rr = r01 + i;
                    s1 += @as(i32, temp1.data[rr * temp1.stride + c]) * k;
                }
                for (kernel_y2_int, 0..) |k, i| {
                    if (k == 0) continue;
                    const rr = r02 + i;
                    s2 += @as(i32, temp2.data[rr * temp2.stride + c]) * k;
                }
                const rounded1 = @divTrunc(s1 + SCALE / 2, SCALE);
                const rounded2 = @divTrunc(s2 + SCALE / 2, SCALE);
                const d = rounded1 - rounded2 + OFFSET;
                dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, d)));
            }
        }
    }

    // Top border rows
    for (0..@min(half_y, rows)) |r| {
        for (0..cols) |c| {
            var s1: i32 = 0;
            var s2: i32 = 0;
            const ir = @as(isize, @intCast(r));
            for (kernel_y1_int, 0..) |k, i| {
                const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y1));
                s1 += getPixel(u8, temp1, iry, @as(isize, @intCast(c)), border_mode) * k;
            }
            for (kernel_y2_int, 0..) |k, i| {
                const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y2));
                s2 += getPixel(u8, temp2, iry, @as(isize, @intCast(c)), border_mode) * k;
            }
            const d = @divTrunc(s1 + SCALE / 2, SCALE) - @divTrunc(s2 + SCALE / 2, SCALE) + OFFSET;
            dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, d)));
        }
    }

    // Bottom border rows
    if (rows > half_y) {
        for (rows - half_y..rows) |r| {
            for (0..cols) |c| {
                var s1: i32 = 0;
                var s2: i32 = 0;
                const ir = @as(isize, @intCast(r));
                for (kernel_y1_int, 0..) |k, i| {
                    const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y1));
                    s1 += getPixel(u8, temp1, iry, @as(isize, @intCast(c)), border_mode) * k;
                }
                for (kernel_y2_int, 0..) |k, i| {
                    const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y2));
                    s2 += getPixel(u8, temp2, iry, @as(isize, @intCast(c)), border_mode) * k;
                }
                const d = @divTrunc(s1 + SCALE / 2, SCALE) - @divTrunc(s2 + SCALE / 2, SCALE) + OFFSET;
                dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, d)));
            }
        }
    }
}

/// Get pixel value with border handling.
fn getPixel(comptime PixelType: type, img: Image(PixelType), row: isize, col: isize, border_mode: BorderMode) PixelType {
    const coords = computeBorderCoords(row, col, @intCast(img.rows), @intCast(img.cols), border_mode);
    return if (coords.is_zero)
        std.mem.zeroes(PixelType)
    else
        img.at(@intCast(coords.row), @intCast(coords.col)).*;
}

/// Common border mode logic that returns adjusted coordinates.
fn computeBorderCoords(row: isize, col: isize, rows: isize, cols: isize, border_mode: BorderMode) struct { row: isize, col: isize, is_zero: bool } {
    switch (border_mode) {
        .zero => {
            if (row < 0 or col < 0 or row >= rows or col >= cols) {
                return .{ .row = 0, .col = 0, .is_zero = true };
            }
            return .{ .row = row, .col = col, .is_zero = false };
        },
        .replicate => {
            const r = @max(0, @min(row, rows - 1));
            const c = @max(0, @min(col, cols - 1));
            return .{ .row = r, .col = c, .is_zero = false };
        },
        .mirror => {
            if (rows == 0 or cols == 0) return .{ .row = 0, .col = 0, .is_zero = true };
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
            return .{ .row = r, .col = c, .is_zero = false };
        },
        .wrap => {
            const r = @mod(row, rows);
            const c = @mod(col, cols);
            return .{ .row = r, .col = c, .is_zero = false };
        },
    }
}

/// Flatten a 2D kernel to 1D array and optionally scale to integer.
inline fn flattenKernel(comptime OutType: type, comptime size: usize, kernel: anytype, scale: ?i32) [size]OutType {
    const kernel_info = @typeInfo(@TypeOf(kernel));
    const kernel_height = kernel_info.array.len;
    const kernel_width = @typeInfo(kernel_info.array.child).array.len;
    var result: [size]OutType = undefined;
    var idx: usize = 0;
    inline for (0..kernel_height) |kr| {
        inline for (0..kernel_width) |kc| {
            const val = as(f32, kernel[kr][kc]);
            result[idx] = if (OutType == i32 and scale != null)
                @intFromFloat(@round(val * @as(f32, @floatFromInt(scale.?))))
            else if (OutType == f32)
                val
            else
                @compileError("Unsupported kernel output type");
            idx += 1;
        }
    }
    return result;
}

/// Make a 1D integer kernel symmetric and adjust the center tap so the sum equals `scale`.
pub inline fn symmetrizeKernelI32(k: []i32, scale: i32) void {
    const n = k.len;
    if (n == 0 or (n & 1) == 0) return; // only handle odd-length kernels
    const half = n / 2;

    var new_sum: i32 = 0;
    // Symmetrize pairs
    var i: usize = 0;
    while (i < half) : (i += 1) {
        const j = n - 1 - i;
        const avg = @divTrunc(k[i] + k[j], 2);
        k[i] = avg;
        k[j] = avg;
        new_sum += 2 * avg;
    }
    // Add center
    new_sum += k[half];
    // Adjust center to match target scale exactly
    const delta = scale - new_sum;
    k[half] += delta;
}

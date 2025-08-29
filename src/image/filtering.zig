//! Image filtering and convolution operations

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const convertColor = @import("../color.zig").convertColor;
const meta = @import("../meta.zig");
const as = meta.as;
const isScalar = meta.isScalar;
const Image = @import("../image.zig").Image;
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

/// Filter operations for Image(T)
pub fn Filter(comptime T: type) type {
    return struct {
        const Self = Image(T);

        // ============================================================================
        // Public API - Main filtering functions
        // ============================================================================

        /// Computes a blurred version of `self` using a box blur algorithm, efficiently implemented
        /// using an integral image. The `radius` parameter determines the size of the box window.
        /// This function is optimized using SIMD instructions for performance where applicable.
        pub fn boxBlur(self: Self, allocator: std.mem.Allocator, blurred: *Self, radius: usize) !void {
            if (!self.hasSameShape(blurred.*)) {
                blurred.* = try .init(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                self.copy(blurred.*);
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Build integral image
                    const plane_size = self.rows * self.cols;
                    const integral_buf = try allocator.alloc(f32, plane_size);
                    defer allocator.free(integral_buf);
                    const integral_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = integral_buf };

                    // Use optimized paths for u8 and f32, generic path for others
                    if (T == u8) {
                        integralPlane(u8, self, integral_img);
                        boxBlurPlane(u8, integral_img, blurred.*, radius);
                    } else if (T == f32) {
                        integralPlane(f32, self, integral_img);
                        boxBlurPlane(f32, integral_img, blurred.*, radius);
                    } else {
                        // Generic path: convert to f32 for processing
                        const src_f32 = try allocator.alloc(f32, plane_size);
                        defer allocator.free(src_f32);
                        // Gather source respecting stride into packed image
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                src_f32[r * self.cols + c] = meta.as(f32, self.at(r, c).*);
                            }
                        }
                        const src_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_f32 };
                        integralPlane(f32, src_img, integral_img);

                        const dst_f32 = try allocator.alloc(f32, plane_size);
                        defer allocator.free(dst_f32);
                        const dst_img_packed: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_f32 };
                        boxBlurPlane(f32, integral_img, dst_img_packed, radius);

                        // Convert back to target type
                        for (0..self.rows) |r| {
                            const dst_row_packed = r * self.cols;
                            const dst_row = r * blurred.stride;
                            for (0..self.cols) |c| {
                                const v = dst_f32[dst_row_packed + c];
                                blurred.data[dst_row + c] = if (@typeInfo(T) == .int)
                                    @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(v))))
                                else
                                    meta.as(T, v);
                            }
                        }
                    }
                },
                .@"struct" => {
                    const fields = std.meta.fields(T);

                    // Check if all fields are u8
                    const all_u8 = comptime blk: {
                        for (fields) |field| {
                            if (field.type != u8) break :blk false;
                        }
                        break :blk true;
                    };

                    if (all_u8) {
                        // Optimized path for u8 types
                        const plane_size = self.rows * self.cols;

                        // Separate channels
                        const channels = try channel_ops.splitChannels(T, self, allocator);
                        defer for (channels) |channel| allocator.free(channel);

                        // Check which channels are uniform to avoid unnecessary allocations
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

                        // Allocate output channels
                        var out_channels: [channels.len][]u8 = undefined;
                        inline for (&out_channels, is_uniform) |*ch, uniform| {
                            if (uniform) {
                                // For uniform channels, we'll just use the source directly
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

                        // Only allocate integral buffer if we have non-uniform channels
                        if (non_uniform_count > 0) {
                            const integral_buf = try allocator.alloc(f32, plane_size);
                            defer allocator.free(integral_buf);
                            const integral_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = integral_buf };

                            // Process only non-uniform channels
                            inline for (channels, out_channels, is_uniform) |src_data, dst_data, uniform| {
                                if (!uniform) {
                                    const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                                    const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                                    integralPlane(u8, src_plane, integral_img);
                                    boxBlurPlane(u8, integral_img, dst_plane, radius);
                                }
                            }
                        }

                        // Recombine channels, using uniform values where applicable
                        var final_channels: [channels.len][]const u8 = undefined;
                        inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                            if (uniform) {
                                // For uniform channels, use the source (which has the uniform value)
                                final_channels[i] = src_ch;
                            } else {
                                final_channels[i] = out_ch;
                            }
                        }
                        channel_ops.mergeChannels(T, final_channels, blurred.*);
                    } else {
                        // Generic struct path for other color types
                        var sat: Image([Self.channels()]f32) = undefined;
                        try self.integral(allocator, &sat);
                        defer sat.deinit(allocator);

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const r1 = r -| radius;
                                const c1 = c -| radius;
                                const r2 = @min(r + radius, self.rows - 1);
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                                inline for (fields, 0..) |f, i| {
                                    // Use correct integral image indices
                                    const sum = computeIntegralSumMultiChannel(sat, r1, c1, r2, c2, i);

                                    @field(blurred.at(r, c).*, f.name) = switch (@typeInfo(f.type)) {
                                        .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sum / area)))),
                                        .float => as(f.type, sum / area),
                                        else => @compileError("Can't compute the boxBlur image with struct fields of type " ++ @typeName(f.type) ++ "."),
                                    };
                                }
                            }
                        }
                    }
                },
                else => @compileError("Can't compute the boxBlur image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Computes a sharpened version of `self` by enhancing edges.
        /// It uses the formula `sharpened = 2 * original - blurred`, where `blurred` is a box-blurred
        /// version of the original image (calculated efficiently using an integral image).
        /// The `radius` parameter controls the size of the blur. This operation effectively
        /// increases the contrast at edges. SIMD optimizations are used for performance where applicable.
        pub fn sharpen(self: Self, allocator: std.mem.Allocator, sharpened: *Self, radius: usize) !void {
            if (!self.hasSameShape(sharpened.*)) {
                sharpened.* = try .init(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                self.copy(sharpened.*);
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    const plane_size = self.rows * self.cols;
                    const integral_buf = try allocator.alloc(f32, plane_size);
                    defer allocator.free(integral_buf);
                    const integral_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = integral_buf };

                    // Use optimized paths for u8 and f32, generic path for others
                    if (T == u8) {
                        integralPlane(u8, self, integral_img);
                        sharpenPlane(u8, self, integral_img, sharpened.*, radius);
                    } else if (T == f32) {
                        integralPlane(f32, self, integral_img);
                        sharpenPlane(f32, self, integral_img, sharpened.*, radius);
                    } else {
                        // Generic path: convert to f32 for processing
                        const src_f32 = try allocator.alloc(f32, plane_size);
                        defer allocator.free(src_f32);
                        // Gather respecting stride into packed plane
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                src_f32[r * self.cols + c] = meta.as(f32, self.at(r, c).*);
                            }
                        }
                        const src_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_f32 };
                        integralPlane(f32, src_img, integral_img);

                        const dst_f32 = try allocator.alloc(f32, plane_size);
                        defer allocator.free(dst_f32);
                        const src_packed: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_f32 };
                        const dst_packed: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_f32 };
                        sharpenPlane(f32, src_packed, integral_img, dst_packed, radius);

                        // Convert back to target type
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const v = dst_f32[r * self.cols + c];
                                sharpened.at(r, c).* = if (@typeInfo(T) == .int)
                                    @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(v))))
                                else
                                    meta.as(T, v);
                            }
                        }
                    }
                },
                .@"struct" => {
                    const fields = std.meta.fields(T);

                    // Check if all fields are u8
                    const all_u8 = comptime blk: {
                        for (fields) |field| {
                            if (field.type != u8) break :blk false;
                        }
                        break :blk true;
                    };

                    if (all_u8) {
                        // Optimized path for u8 types
                        const plane_size = self.rows * self.cols;

                        // Separate channels
                        const channels = try channel_ops.splitChannels(T, self, allocator);
                        defer for (channels) |channel| allocator.free(channel);

                        // Check which channels are uniform to avoid unnecessary allocations
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

                        // Allocate output channels only for non-uniform channels
                        var out_channels: [channels.len][]u8 = undefined;
                        inline for (&out_channels, is_uniform) |*ch, uniform| {
                            if (uniform) {
                                // For uniform channels, sharpening doesn't change the value
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

                        // Only allocate integral buffer if we have non-uniform channels
                        if (non_uniform_count > 0) {
                            const integral_buf = try allocator.alloc(f32, plane_size);
                            defer allocator.free(integral_buf);
                            const integral_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = integral_buf };

                            // Process only non-uniform channels
                            inline for (channels, out_channels, is_uniform) |src_data, dst_data, uniform| {
                                if (!uniform) {
                                    const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                                    const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                                    integralPlane(u8, src_plane, integral_img);
                                    sharpenPlane(u8, src_plane, integral_img, dst_plane, radius);
                                }
                            }
                        }

                        // Recombine channels, using uniform values where applicable
                        var final_channels: [channels.len][]const u8 = undefined;
                        inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                            if (uniform) {
                                // For uniform channels, sharpen result is same as input (2*v - v = v)
                                final_channels[i] = src_ch;
                            } else {
                                final_channels[i] = out_ch;
                            }
                        }
                        channel_ops.mergeChannels(T, final_channels, sharpened.*);
                    } else {
                        // Generic struct path for other color types
                        var sat: Image([Self.channels()]f32) = undefined;
                        try self.integral(allocator, &sat);
                        defer sat.deinit(allocator);

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const r1 = r -| radius;
                                const c1 = c -| radius;
                                const r2 = @min(r + radius, self.rows - 1);
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                                inline for (fields, 0..) |f, i| {
                                    const sum = computeIntegralSumMultiChannel(sat, r1, c1, r2, c2, i);

                                    const blurred = sum / area;
                                    const original = @field(self.at(r, c).*, f.name);
                                    @field(sharpened.at(r, c).*, f.name) = switch (@typeInfo(f.type)) {
                                        .int => blk: {
                                            const sharpened_val = 2 * as(f32, original) - blurred;
                                            break :blk @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sharpened_val))));
                                        },
                                        .float => as(f.type, 2 * as(f32, original) - blurred),
                                        else => @compileError("Can't compute the sharpen image with struct fields of type " ++ @typeName(f.type) ++ "."),
                                    };
                                }
                            }
                        }
                    }
                },
                else => @compileError("Can't compute the sharpen image of " ++ @typeName(T) ++ "."),
            }
        }

        // ============================================================================
        // Convolution Kernel Specialization
        // ============================================================================

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
                                        for (0..vec_len) |i| {
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

                                for (0..vec_len) |i| {
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
                                        for (0..vec_len) |i| {
                                            const src_r = r + ky - half_h;
                                            const src_c = c + i + kx - half_w;
                                            pixel_vec[i] = src_img.data[src_r * src_img.stride + src_c];
                                        }

                                        result_vec += pixel_vec * kernel_vec;
                                    }
                                }

                                for (0..vec_len) |i| {
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
        pub fn convolve(self: Self, allocator: Allocator, kernel: anytype, out: *Self, border_mode: BorderMode) !void {
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
                    const fields = std.meta.fields(T);
                    const all_u8 = comptime blk: {
                        for (fields) |field| {
                            if (field.type != u8) break :blk false;
                        }
                        break :blk true;
                    };

                    if (all_u8) {
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

        // ============================================================================
        // Optimized Plane Processing Functions
        // ============================================================================

        /// Optimized separable convolution for u8 planes with integer arithmetic.
        /// The kernel must be pre-scaled by 256 for integer arithmetic.
        fn convolveSeparableU8Plane(
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

            // Horizontal pass (src -> temp)
            for (0..rows) |r| {
                for (0..cols) |c| {
                    var result: i32 = 0;
                    if (c >= half_x and c + half_x < cols) {
                        // Fast path: no border handling needed
                        const c0 = c - half_x;
                        for (kernel_x_int, 0..) |k, i| {
                            const cc = c0 + i;
                            const pixel_val = @as(i32, src_img.data[r * src_img.stride + cc]);
                            result += pixel_val * k;
                        }
                    } else {
                        // Border handling
                        const ic = @as(isize, @intCast(c));
                        for (kernel_x_int, 0..) |k, i| {
                            const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                            const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                            result += pixel_val * k;
                        }
                    }
                    const rounded = @divTrunc(result + SCALE / 2, SCALE);
                    temp_img.data[r * temp_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                }
            }

            // Vertical pass (temp -> dst)
            for (0..rows) |r| {
                for (0..cols) |c| {
                    var result: i32 = 0;
                    if (r >= half_y and r + half_y < rows) {
                        // Fast path: no border handling needed
                        const r0 = r - half_y;
                        for (kernel_y_int, 0..) |k, i| {
                            const rr = r0 + i;
                            const pixel_val = @as(i32, temp_img.data[rr * temp_img.stride + c]);
                            result += pixel_val * k;
                        }
                    } else {
                        // Border handling
                        const ir = @as(isize, @intCast(r));
                        for (kernel_y_int, 0..) |k, i| {
                            const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                            const pixel_val: i32 = getPixel(u8, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                            result += pixel_val * k;
                        }
                    }
                    const rounded = @divTrunc(result + SCALE / 2, SCALE);
                    dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                }
            }
        }

        /// Optimized convolution for scalar types (int/float) with SIMD.
        /// Build integral image from any scalar type plane into f32 plane with SIMD optimization.
        /// The output integral image allows O(1) computation of rectangular region sums.
        fn integralPlane(comptime SrcT: type, src_img: Image(SrcT), dst_img: Image(f32)) void {
            assert(src_img.rows == dst_img.rows and src_img.cols == dst_img.cols);

            const rows = src_img.rows;
            const cols = src_img.cols;
            const simd_len = std.simd.suggestVectorLength(f32) orelse 1;

            // First pass: compute row-wise cumulative sums
            for (0..rows) |r| {
                var tmp: f32 = 0;
                const src_row_offset = r * src_img.stride;
                const dst_row_offset = r * dst_img.stride; // equals cols
                for (0..cols) |c| {
                    tmp += meta.as(f32, src_img.data[src_row_offset + c]);
                    dst_img.data[dst_row_offset + c] = tmp;
                }
            }

            // Second pass: add column-wise cumulative sums using SIMD over packed dst
            for (1..rows) |r| {
                const prev_row_offset = (r - 1) * dst_img.stride;
                const curr_row_offset = r * dst_img.stride;
                var c: usize = 0;

                // Process SIMD-width chunks
                while (c + simd_len <= cols) : (c += simd_len) {
                    const prev_vals: @Vector(simd_len, f32) = dst_img.data[prev_row_offset + c ..][0..simd_len].*;
                    const curr_vals: @Vector(simd_len, f32) = dst_img.data[curr_row_offset + c ..][0..simd_len].*;
                    dst_img.data[curr_row_offset + c ..][0..simd_len].* = prev_vals + curr_vals;
                }

                // Handle remaining columns
                while (c < cols) : (c += 1) {
                    dst_img.data[curr_row_offset + c] += dst_img.data[prev_row_offset + c];
                }
            }
        }

        /// Box blur for any plane type using integral image with SIMD optimization.
        fn boxBlurPlane(comptime PlaneType: type, sat: Image(f32), dst: Image(PlaneType), radius: usize) void {
            assert(sat.rows == dst.rows and sat.cols == dst.cols);
            const rows = sat.rows;
            const cols = sat.cols;
            const simd_len = std.simd.suggestVectorLength(f32) orelse 1;

            for (0..rows) |r| {
                const r1 = r -| radius;
                const r2 = @min(r + radius, rows - 1);
                const r2_offset = r2 * sat.stride;

                var c: usize = 0;

                // SIMD processing for safe regions
                const row_safe = r >= radius and r + radius < rows;
                if (simd_len > 1 and cols > 2 * radius + simd_len and row_safe) {
                    // Handle left border (including the column where c1 would be 0)
                    while (c <= radius) : (c += 1) {
                        const c1 = c -| radius;
                        const c2 = @min(c + radius, cols - 1);
                        const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                        const sum = computeIntegralSum(sat, r1, c1, r2, c2);

                        const val = sum / area;
                        dst.data[r * dst.stride + c] = if (PlaneType == u8)
                            @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(val))))))
                        else
                            @as(PlaneType, val);
                    }

                    // SIMD middle section - only in completely safe region
                    const safe_end = cols - radius;
                    if (c < safe_end) {
                        const const_area: f32 = @floatFromInt((2 * radius + 1) * (2 * radius + 1));
                        const area_vec: @Vector(simd_len, f32) = @splat(const_area);

                        while (c + simd_len <= safe_end) : (c += simd_len) {
                            const c1 = c - radius;
                            const c2 = c + radius;

                            const r1_offset = if (r1 > 0) (r1 - 1) * sat.stride else 0;
                            const int11: @Vector(simd_len, f32) = if (r1 > 0) sat.data[r1_offset + (c1 - 1) ..][0..simd_len].* else @splat(0);
                            const int12: @Vector(simd_len, f32) = if (r1 > 0) sat.data[r1_offset + c2 ..][0..simd_len].* else @splat(0);
                            const int21: @Vector(simd_len, f32) = sat.data[r2_offset + (c1 - 1) ..][0..simd_len].*;
                            const int22: @Vector(simd_len, f32) = sat.data[r2_offset + c2 ..][0..simd_len].*;

                            const sums = int22 - int21 - int12 + int11;
                            const vals = sums / area_vec;

                            if (PlaneType == u8) {
                                for (0..simd_len) |i| {
                                    dst.data[r * dst.stride + c + i] = @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(vals[i]))))));
                                }
                            } else {
                                dst.data[r * dst.stride + c ..][0..simd_len].* = vals;
                            }
                        }
                    }
                }

                while (c < cols) : (c += 1) {
                    const c1 = c -| radius;
                    const c2 = @min(c + radius, cols - 1);
                    const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                    // Correct integral image access with boundary checks
                    const sum = computeIntegralSum(sat, r1, c1, r2, c2);

                    dst.data[r * dst.stride + c] = if (PlaneType == u8)
                        @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(sum / area))))))
                    else
                        sum / area;
                }
            }
        }

        /// Sharpen plane using integral image (sharpened = 2*original - blurred).
        fn sharpenPlane(
            comptime PlaneType: type,
            src: Image(PlaneType),
            sat: Image(f32),
            dst: Image(PlaneType),
            radius: usize,
        ) void {
            assert(src.rows == dst.rows and src.cols == dst.cols);
            assert(sat.rows == src.rows and sat.cols == src.cols);
            const rows = src.rows;
            const cols = src.cols;
            const simd_len = std.simd.suggestVectorLength(f32) orelse 1;

            for (0..rows) |r| {
                const r1 = r -| radius;
                const r2 = @min(r + radius, rows - 1);
                const r2_offset = r2 * sat.stride;

                var c: usize = 0;

                // SIMD processing for safe regions
                const row_safe = r >= radius and r + radius < rows;
                if (simd_len > 1 and cols > 2 * radius + simd_len and row_safe) {
                    // Handle left border (including the column where c1 would be 0)
                    while (c <= radius) : (c += 1) {
                        const c1 = c -| radius;
                        const c2 = @min(c + radius, cols - 1);
                        const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                        const sum = computeIntegralSum(sat, r1, c1, r2, c2);

                        const blurred = sum / area;
                        const original = meta.as(f32, src.data[r * src.stride + c]);
                        const sharpened = 2 * original - blurred;
                        dst.data[r * dst.stride + c] = if (PlaneType == u8)
                            @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(sharpened))))))
                        else
                            sharpened;
                    }

                    // SIMD middle section - only in completely safe region
                    const safe_end = cols - radius;
                    if (c < safe_end) {
                        const const_area: f32 = @floatFromInt((2 * radius + 1) * (2 * radius + 1));
                        const area_vec: @Vector(simd_len, f32) = @splat(const_area);

                        while (c + simd_len <= safe_end) : (c += simd_len) {
                            const c1 = c - radius;
                            const c2 = c + radius;

                            const r1_offset = if (r1 > 0) (r1 - 1) * sat.stride else 0;
                            const int11: @Vector(simd_len, f32) = if (r1 > 0) sat.data[r1_offset + (c1 - 1) ..][0..simd_len].* else @splat(0);
                            const int12: @Vector(simd_len, f32) = if (r1 > 0) sat.data[r1_offset + c2 ..][0..simd_len].* else @splat(0);
                            const int21: @Vector(simd_len, f32) = sat.data[r2_offset + (c1 - 1) ..][0..simd_len].*;
                            const int22: @Vector(simd_len, f32) = sat.data[r2_offset + c2 ..][0..simd_len].*;

                            const sums = int22 - int21 - int12 + int11;
                            const blurred_vals = sums / area_vec;

                            if (PlaneType == u8) {
                                for (0..simd_len) |i| {
                                    const original = meta.as(f32, src.data[r * src.stride + c + i]);
                                    dst.data[r * dst.stride + c + i] = @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(2 * original - blurred_vals[i]))))));
                                }
                            } else {
                                const two_vec: @Vector(simd_len, f32) = @splat(2.0);
                                var original_vals: @Vector(simd_len, f32) = undefined;
                                for (0..simd_len) |i| {
                                    original_vals[i] = meta.as(f32, src.data[r * src.stride + c + i]);
                                }
                                dst.data[r * dst.stride + c ..][0..simd_len].* = two_vec * original_vals - blurred_vals;
                            }
                        }
                    }
                }

                while (c < cols) : (c += 1) {
                    const c1 = c -| radius;
                    const c2 = @min(c + radius, cols - 1);
                    const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                    // Correct integral image access with boundary checks
                    const sum = computeIntegralSum(sat, r1, c1, r2, c2);

                    const blurred = sum / area;
                    const original = meta.as(f32, src.data[r * src.stride + c]);
                    const sharpened = 2 * original - blurred;
                    dst.data[r * dst.stride + c] = if (PlaneType == u8)
                        @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(sharpened))))))
                    else
                        sharpened;
                }
            }
        }

        /// Build integral image (summed area table) from the source image.
        /// Uses channel separation and SIMD optimization for performance.
        pub fn integral(
            self: Self,
            allocator: Allocator,
            sat: *Image(if (meta.isScalar(T)) f32 else [Self.channels()]f32),
        ) !void {
            if (!self.hasSameShape(sat.*)) {
                sat.* = try .init(allocator, self.rows, self.cols);
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Use generic integral plane function for all scalar types
                    integralPlane(T, self, sat.*);
                },
                .@"struct" => {
                    // Channel separation for struct types
                    const fields = std.meta.fields(T);

                    // Create temporary buffers for each channel
                    const src_plane = try allocator.alloc(f32, self.rows * self.cols);
                    defer allocator.free(src_plane);
                    const dst_plane = try allocator.alloc(f32, self.rows * self.cols);
                    defer allocator.free(dst_plane);

                    // Process each channel separately
                    inline for (fields, 0..) |field, ch| {
                        // Extract channel to packed src_plane respecting stride
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const pix = self.at(r, c).*;
                                const val = @field(pix, field.name);
                                src_plane[r * self.cols + c] = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(val),
                                    .float => @floatCast(val),
                                    else => 0,
                                };
                            }
                        }

                        const src_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_plane };
                        const dst_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_plane };

                        // Compute integral for this channel from packed src_plane into packed dst_plane
                        integralPlane(f32, src_img, dst_img);

                        // Store result in output channel (packed to packed)
                        for (0..self.rows * self.cols) |i| {
                            sat.data[i][ch] = dst_plane[i];
                        }
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
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
        pub fn convolveSeparable(self: Self, allocator: Allocator, kernel_x: []const f32, kernel_y: []const f32, out: *Self, border_mode: BorderMode) !void {
            // Ensure output is properly allocated
            if (out.rows == 0 or out.cols == 0 or !self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // Allocate temporary buffer for intermediate result
            var temp = try Self.init(allocator, self.rows, self.cols);
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

                        convolveSeparableU8Plane(self, out.*, temp, kernel_x_int, kernel_y_int, border_mode);
                        return; // Skip the rest of the function
                    }

                    // Generic path for other scalar types
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var sum: f32 = 0;
                            if (c >= half_x and c + half_x < self.cols) {
                                const c0: usize = c - half_x;
                                for (kernel_x, 0..) |k, i| {
                                    const cc = c0 + i;
                                    const pixel = self.at(r, cc).*;
                                    sum += as(f32, pixel) * k;
                                }
                            } else {
                                for (kernel_x, 0..) |k, i| {
                                    const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                                    const pixel = getPixel(T, self, @as(isize, @intCast(r)), src_c, border_mode);
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
                    const fields = std.meta.fields(T);
                    const all_u8 = comptime blk: {
                        for (fields) |field| {
                            if (field.type != u8) break :blk false;
                        }
                        break :blk true;
                    };

                    if (all_u8) {
                        // Channel separation approach for optimal performance
                        const SCALE = 256;
                        const plane_size = self.rows * self.cols;

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
                                const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                                const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                                const tmp_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = temp_data };
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
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var result_pixel: T = undefined;
                            inline for (std.meta.fields(T)) |field| {
                                var sum: f32 = 0;
                                if (c >= half_x and c + half_x < self.cols) {
                                    const c0: usize = c - half_x;
                                    for (kernel_x, 0..) |k, i| {
                                        const cc = c0 + i;
                                        const pixel = self.at(r, cc).*;
                                        sum += as(f32, @field(pixel, field.name)) * k;
                                    }
                                } else {
                                    for (kernel_x, 0..) |k, i| {
                                        const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                                        const pixel = getPixel(T, self, @as(isize, @intCast(r)), src_c, border_mode);
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
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var sum: f32 = 0;
                            if (r >= half_y and r + half_y < self.rows) {
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
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var result_pixel: T = undefined;
                            inline for (std.meta.fields(T)) |field| {
                                var sum: f32 = 0;
                                if (r >= half_y and r + half_y < self.rows) {
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

        /// Applies Gaussian blur to the image using separable convolution.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma`: Standard deviation of the Gaussian kernel.
        /// - `out`: Output blurred image.
        pub fn gaussianBlur(self: Self, allocator: Allocator, sigma: f32, out: *Self) !void {
            if (sigma <= 0) return error.InvalidSigma;

            // Calculate kernel size (3 sigma on each side)
            const radius = @as(usize, @intFromFloat(@ceil(3.0 * sigma)));
            const kernel_size = 2 * radius + 1;

            // Generate 1D Gaussian kernel
            var kernel = try allocator.alloc(f32, kernel_size);
            defer allocator.free(kernel);

            var sum: f32 = 0;
            for (0..kernel_size) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
                kernel[i] = @exp(-(x * x) / (2.0 * sigma * sigma));
                sum += kernel[i];
            }

            // Normalize kernel
            for (kernel) |*k| {
                k.* /= sum;
            }

            // Apply separable convolution
            try convolveSeparable(self, allocator, kernel, kernel, out, .mirror);
        }

        /// Applies Difference of Gaussians (DoG) band-pass filter to the image.
        /// This efficiently computes the difference between two Gaussian blurs with different sigmas,
        /// which acts as a band-pass filter and is commonly used for edge detection and feature enhancement.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma1`: Standard deviation of the first (typically smaller) Gaussian kernel.
        /// - `sigma2`: Standard deviation of the second (typically larger) Gaussian kernel.
        /// - `out`: Output image containing the difference.
        ///
        /// The result is computed as: gaussian_blur(sigma1) - gaussian_blur(sigma2)
        /// For edge detection, typically sigma2 ≈ 1.6 * sigma1
        pub fn differenceOfGaussians(self: Self, allocator: Allocator, sigma1: f32, sigma2: f32, out: *Self) !void {
            if (sigma1 <= 0 or sigma2 <= 0) return error.InvalidSigma;
            if (sigma1 == sigma2) return error.SigmasMustDiffer;

            // Ensure output is allocated
            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // Calculate kernel sizes for both sigmas
            const radius1 = @as(usize, @intFromFloat(@ceil(3.0 * sigma1)));
            const kernel_size1 = 2 * radius1 + 1;
            const radius2 = @as(usize, @intFromFloat(@ceil(3.0 * sigma2)));
            const kernel_size2 = 2 * radius2 + 1;

            // Generate both 1D Gaussian kernels
            var kernel1 = try allocator.alloc(f32, kernel_size1);
            defer allocator.free(kernel1);
            var kernel2 = try allocator.alloc(f32, kernel_size2);
            defer allocator.free(kernel2);

            // Generate first kernel
            var sum1: f32 = 0;
            for (0..kernel_size1) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius1));
                kernel1[i] = @exp(-(x * x) / (2.0 * sigma1 * sigma1));
                sum1 += kernel1[i];
            }
            for (kernel1) |*k| {
                k.* /= sum1;
            }

            // Generate second kernel
            var sum2: f32 = 0;
            for (0..kernel_size2) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius2));
                kernel2[i] = @exp(-(x * x) / (2.0 * sigma2 * sigma2));
                sum2 += kernel2[i];
            }
            for (kernel2) |*k| {
                k.* /= sum2;
            }

            // Allocate temporary buffers for the two blurred results
            var blur1 = try Self.init(allocator, self.rows, self.cols);
            defer blur1.deinit(allocator);
            var blur2 = try Self.init(allocator, self.rows, self.cols);
            defer blur2.deinit(allocator);

            // Apply both Gaussian blurs using separable convolution
            try convolveSeparable(self, allocator, kernel1, kernel1, &blur1, .mirror);
            try convolveSeparable(self, allocator, kernel2, kernel2, &blur2, .mirror);

            // Compute the difference: blur1 - blur2
            switch (@typeInfo(T)) {
                .int => {
                    // For integer types, handle underflow/overflow carefully
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            const val1 = as(f32, blur1.at(r, c).*);
                            const val2 = as(f32, blur2.at(r, c).*);
                            const diff = val1 - val2;

                            // For visualization, you might want to add an offset and scale
                            // For now, we'll clamp to the valid range
                            out.at(r, c).* = @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(diff))));
                        }
                    }
                },
                .float => {
                    // For float types, direct subtraction
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            out.at(r, c).* = blur1.at(r, c).* - blur2.at(r, c).*;
                        }
                    }
                },
                .@"struct" => {
                    // For struct types (RGB, RGBA, etc.), process each channel
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var result_pixel: T = undefined;
                            const pixel1 = blur1.at(r, c).*;
                            const pixel2 = blur2.at(r, c).*;

                            inline for (std.meta.fields(T)) |field| {
                                const val1 = as(f32, @field(pixel1, field.name));
                                const val2 = as(f32, @field(pixel2, field.name));
                                const diff = val1 - val2;

                                @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                    .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(diff)))),
                                    .float => as(field.type, diff),
                                    else => @compileError("Unsupported field type in struct"),
                                };
                            }
                            out.at(r, c).* = result_pixel;
                        }
                    }
                },
                else => @compileError("Difference of Gaussians not supported for type " ++ @typeName(T)),
            }
        }

        /// Applies linear motion blur to simulate camera or object movement in a straight line.
        /// The blur is created by averaging pixels along a line at the specified angle and distance.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `angle`: Direction of motion in radians (0 = horizontal, π/2 = vertical).
        /// - `distance`: Length of the blur effect in pixels.
        /// - `out`: Output image containing the motion blurred result.
        pub fn linearMotionBlur(self: Self, allocator: Allocator, angle: f32, distance: usize, out: *Self) !void {
            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            if (distance == 0) {
                self.copy(out.*);
                return;
            }

            // Calculate motion vector components
            const cos_angle = @cos(angle);
            const sin_angle = @sin(angle);
            const half_dist = @as(f32, @floatFromInt(distance)) / 2.0;

            // For purely horizontal or vertical motion, use optimized separable approach
            const epsilon = 0.001;
            const is_horizontal = @abs(sin_angle) < epsilon;
            const is_vertical = @abs(cos_angle) < epsilon;

            if (is_horizontal) {
                // Use separable convolution for horizontal motion blur
                const kernel_size = distance;
                const kernel = try allocator.alloc(f32, kernel_size);
                defer allocator.free(kernel);

                // Create uniform kernel
                const weight = 1.0 / @as(f32, @floatFromInt(kernel_size));
                for (kernel) |*k| {
                    k.* = weight;
                }

                // Identity kernel for vertical (no blur)
                const identity = [_]f32{1.0};

                // Apply separable convolution (horizontal blur only)
                try self.convolveSeparable(allocator, kernel, &identity, out, .replicate);
            } else if (is_vertical) {
                // Use separable convolution for vertical motion blur
                const kernel_size = distance;
                const kernel = try allocator.alloc(f32, kernel_size);
                defer allocator.free(kernel);

                // Create uniform kernel
                const weight = 1.0 / @as(f32, @floatFromInt(kernel_size));
                for (kernel) |*k| {
                    k.* = weight;
                }

                // Identity kernel for horizontal (no blur)
                const identity = [_]f32{1.0};

                // Apply separable convolution (vertical blur only)
                try self.convolveSeparable(allocator, &identity, kernel, out, .replicate);
            } else {
                // General diagonal motion blur
                switch (@typeInfo(T)) {
                    .int, .float => {
                        // Process scalar types directly
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                var sum: f32 = 0;
                                var count: f32 = 0;

                                // Sample along the motion line
                                const num_samples = distance;
                                for (0..num_samples) |i| {
                                    const t = (@as(f32, @floatFromInt(i)) - half_dist + 0.5) / half_dist;
                                    const dx = t * half_dist * cos_angle;
                                    const dy = t * half_dist * sin_angle;

                                    const src_x = @as(f32, @floatFromInt(c)) + dx;
                                    const src_y = @as(f32, @floatFromInt(r)) + dy;

                                    // Check bounds
                                    if (src_x >= 0 and src_x < @as(f32, @floatFromInt(self.cols)) and
                                        src_y >= 0 and src_y < @as(f32, @floatFromInt(self.rows)))
                                    {

                                        // Bilinear interpolation for smooth sampling
                                        const x0 = @as(usize, @intFromFloat(@floor(src_x)));
                                        const y0 = @as(usize, @intFromFloat(@floor(src_y)));
                                        const x1 = @min(x0 + 1, self.cols - 1);
                                        const y1 = @min(y0 + 1, self.rows - 1);

                                        const fx = src_x - @as(f32, @floatFromInt(x0));
                                        const fy = src_y - @as(f32, @floatFromInt(y0));

                                        const p00 = as(f32, self.at(y0, x0).*);
                                        const p01 = as(f32, self.at(y0, x1).*);
                                        const p10 = as(f32, self.at(y1, x0).*);
                                        const p11 = as(f32, self.at(y1, x1).*);

                                        const value = (1 - fx) * (1 - fy) * p00 +
                                            fx * (1 - fy) * p01 +
                                            (1 - fx) * fy * p10 +
                                            fx * fy * p11;

                                        sum += value;
                                        count += 1;
                                    }
                                }

                                if (count > 0) {
                                    const result = sum / count;
                                    out.at(r, c).* = switch (@typeInfo(T)) {
                                        .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(result)))),
                                        .float => as(T, result),
                                        else => unreachable,
                                    };
                                } else {
                                    out.at(r, c).* = self.at(r, c).*;
                                }
                            }
                        }
                    },
                    .@"struct" => {
                        // Check if all fields are u8 for optimized integer path
                        const fields = std.meta.fields(T);
                        const all_u8 = comptime blk: {
                            for (fields) |field| {
                                if (field.type != u8) break :blk false;
                            }
                            break :blk true;
                        };

                        if (all_u8) {
                            // Optimized integer arithmetic path for u8 types
                            const SCALE = 256;

                            // Separate channels using helper
                            const channels = try channel_ops.splitChannels(T, self, allocator);
                            defer for (channels) |channel| allocator.free(channel);

                            // Allocate output channels
                            var out_channels: [Self.channels()][]u8 = undefined;
                            for (&out_channels) |*ch| {
                                ch.* = try allocator.alloc(u8, self.rows * self.cols);
                            }
                            defer for (out_channels) |ch| allocator.free(ch);

                            // Process each channel independently with integer arithmetic
                            for (channels, out_channels) |src_channel, dst_channel| {
                                for (0..self.rows) |r| {
                                    for (0..self.cols) |c| {
                                        var sum: i32 = 0;
                                        var weight_sum: i32 = 0;

                                        // Sample along the motion line
                                        const num_samples = distance;
                                        for (0..num_samples) |i| {
                                            const t = (@as(f32, @floatFromInt(i)) - half_dist + 0.5) / half_dist;
                                            const dx = t * half_dist * cos_angle;
                                            const dy = t * half_dist * sin_angle;

                                            const src_x = @as(f32, @floatFromInt(c)) + dx;
                                            const src_y = @as(f32, @floatFromInt(r)) + dy;

                                            // Check bounds
                                            if (src_x >= 0 and src_x < @as(f32, @floatFromInt(self.cols)) and
                                                src_y >= 0 and src_y < @as(f32, @floatFromInt(self.rows)))
                                            {
                                                // Bilinear interpolation with integer arithmetic
                                                const x0 = @as(usize, @intFromFloat(@floor(src_x)));
                                                const y0 = @as(usize, @intFromFloat(@floor(src_y)));
                                                const x1 = @min(x0 + 1, self.cols - 1);
                                                const y1 = @min(y0 + 1, self.rows - 1);

                                                // Convert fractional parts to integer weights
                                                const fx = @as(i32, @intFromFloat(SCALE * (src_x - @as(f32, @floatFromInt(x0)))));
                                                const fy = @as(i32, @intFromFloat(SCALE * (src_y - @as(f32, @floatFromInt(y0)))));
                                                const fx_inv = SCALE - fx;
                                                const fy_inv = SCALE - fy;

                                                const p00 = @as(i32, src_channel[y0 * self.cols + x0]);
                                                const p01 = @as(i32, src_channel[y0 * self.cols + x1]);
                                                const p10 = @as(i32, src_channel[y1 * self.cols + x0]);
                                                const p11 = @as(i32, src_channel[y1 * self.cols + x1]);

                                                // Bilinear interpolation: ((1-fx)*(1-fy)*p00 + fx*(1-fy)*p01 + (1-fx)*fy*p10 + fx*fy*p11)
                                                // The interpolation result has SCALE^2 factor that we need to remove
                                                const value = @divTrunc(fx_inv * fy_inv * p00 +
                                                    fx * fy_inv * p01 +
                                                    fx_inv * fy * p10 +
                                                    fx * fy * p11, SCALE * SCALE);

                                                sum += value;
                                                weight_sum += 1; // Simple count of samples
                                            }
                                        }

                                        // Store result with rounding
                                        // Now sum is already in pixel value range, weight_sum is just a count
                                        const result = if (weight_sum > 0)
                                            @as(u8, @intCast(@min(255, @max(0, @divTrunc(sum + @divTrunc(weight_sum, 2), weight_sum)))))
                                        else
                                            src_channel[r * self.cols + c];
                                        dst_channel[r * self.cols + c] = result;
                                    }
                                }
                            }

                            // Merge channels back
                            channel_ops.mergeChannels(T, out_channels, out.*);
                        } else {
                            // Generic path for non-u8 types - process per pixel
                            for (0..self.rows) |r| {
                                for (0..self.cols) |c| {
                                    var result_pixel: T = undefined;

                                    inline for (fields) |field| {
                                        var sum: f32 = 0;
                                        var count: f32 = 0;

                                        // Sample along the motion line
                                        const num_samples = distance;
                                        for (0..num_samples) |i| {
                                            const t = (@as(f32, @floatFromInt(i)) - half_dist + 0.5) / half_dist;
                                            const dx = t * half_dist * cos_angle;
                                            const dy = t * half_dist * sin_angle;

                                            const src_x = @as(f32, @floatFromInt(c)) + dx;
                                            const src_y = @as(f32, @floatFromInt(r)) + dy;

                                            // Check bounds
                                            if (src_x >= 0 and src_x < @as(f32, @floatFromInt(self.cols)) and
                                                src_y >= 0 and src_y < @as(f32, @floatFromInt(self.rows)))
                                            {
                                                // Bilinear interpolation
                                                const x0 = @as(usize, @intFromFloat(@floor(src_x)));
                                                const y0 = @as(usize, @intFromFloat(@floor(src_y)));
                                                const x1 = @min(x0 + 1, self.cols - 1);
                                                const y1 = @min(y0 + 1, self.rows - 1);

                                                const fx = src_x - @as(f32, @floatFromInt(x0));
                                                const fy = src_y - @as(f32, @floatFromInt(y0));

                                                const p00 = as(f32, @field(self.at(y0, x0).*, field.name));
                                                const p01 = as(f32, @field(self.at(y0, x1).*, field.name));
                                                const p10 = as(f32, @field(self.at(y1, x0).*, field.name));
                                                const p11 = as(f32, @field(self.at(y1, x1).*, field.name));

                                                const value = (1 - fx) * (1 - fy) * p00 +
                                                    fx * (1 - fy) * p01 +
                                                    (1 - fx) * fy * p10 +
                                                    fx * fy * p11;

                                                sum += value;
                                                count += 1;
                                            }
                                        }

                                        const channel_result = if (count > 0) sum / count else as(f32, @field(self.at(r, c).*, field.name));
                                        @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                            .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(channel_result)))),
                                            .float => as(field.type, channel_result),
                                            else => @compileError("Unsupported field type"),
                                        };
                                    }

                                    out.at(r, c).* = result_pixel;
                                }
                            }
                        }
                    },
                    else => @compileError("Linear motion blur not supported for type " ++ @typeName(T)),
                }
            }
        }

        /// Applies radial motion blur to simulate rotational or zoom motion from a center point.
        /// Creates a blur effect that radiates outward from or spirals around the specified center.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `center_x`: X coordinate of the blur center (0.0 to 1.0, normalized).
        /// - `center_y`: Y coordinate of the blur center (0.0 to 1.0, normalized).
        /// - `strength`: Intensity of the blur effect (0.0 to 1.0, where 0 = no blur, 1 = maximum blur).
        /// - `blur_type`: Type of radial blur - .zoom for zoom blur, .spin for rotational blur.
        /// - `out`: Output image containing the radial motion blurred result.
        pub const RadialBlurType = enum { zoom, spin };

        pub fn radialMotionBlur(self: Self, allocator: Allocator, center_x: f32, center_y: f32, strength: f32, blur_type: RadialBlurType, out: *Self) !void {
            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            if (strength <= 0) {
                self.copy(out.*);
                return;
            }

            // Convert normalized center to pixel coordinates
            const cx = center_x * @as(f32, @floatFromInt(self.cols));
            const cy = center_y * @as(f32, @floatFromInt(self.rows));

            // Clamp strength to reasonable range
            const clamped_strength = @min(1.0, @max(0.0, strength));

            switch (@typeInfo(T)) {
                .int, .float => {
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            const x = @as(f32, @floatFromInt(c));
                            const y = @as(f32, @floatFromInt(r));

                            // Calculate distance and angle from center
                            const dx = x - cx;
                            const dy = y - cy;
                            const distance = @sqrt(dx * dx + dy * dy);
                            const angle = std.math.atan2(dy, dx);

                            var sum: f32 = 0;
                            var count: f32 = 0;

                            // Number of samples based on distance and strength
                            const max_samples = 20;
                            const num_samples = @as(usize, @intFromFloat(@max(1, @min(@as(f32, max_samples), distance * clamped_strength * 0.1))));

                            for (0..num_samples) |i| {
                                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_samples));
                                var sample_x: f32 = undefined;
                                var sample_y: f32 = undefined;

                                switch (blur_type) {
                                    .zoom => {
                                        // Sample along the radial line from center
                                        const scale = 1.0 - (t * clamped_strength * 0.1);
                                        sample_x = cx + dx * scale;
                                        sample_y = cy + dy * scale;
                                    },
                                    .spin => {
                                        // Sample along a circular arc
                                        const angle_offset = (t - 0.5) * clamped_strength * 0.2;
                                        const new_angle = angle + angle_offset;
                                        sample_x = cx + distance * @cos(new_angle);
                                        sample_y = cy + distance * @sin(new_angle);
                                    },
                                }

                                // Check bounds and sample with bilinear interpolation
                                if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(self.cols)) and
                                    sample_y >= 0 and sample_y < @as(f32, @floatFromInt(self.rows)))
                                {
                                    const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                    const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                    const x1 = @min(x0 + 1, self.cols - 1);
                                    const y1 = @min(y0 + 1, self.rows - 1);

                                    const fx = sample_x - @as(f32, @floatFromInt(x0));
                                    const fy = sample_y - @as(f32, @floatFromInt(y0));

                                    const p00 = as(f32, self.at(y0, x0).*);
                                    const p01 = as(f32, self.at(y0, x1).*);
                                    const p10 = as(f32, self.at(y1, x0).*);
                                    const p11 = as(f32, self.at(y1, x1).*);

                                    const value = (1 - fx) * (1 - fy) * p00 +
                                        fx * (1 - fy) * p01 +
                                        (1 - fx) * fy * p10 +
                                        fx * fy * p11;

                                    sum += value;
                                    count += 1;
                                }
                            }

                            const result = if (count > 0) sum / count else as(f32, self.at(r, c).*);
                            out.at(r, c).* = switch (@typeInfo(T)) {
                                .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(result)))),
                                .float => as(T, result),
                                else => unreachable,
                            };
                        }
                    }
                },
                .@"struct" => {
                    // Check if all fields are u8 for optimized integer path
                    const fields = std.meta.fields(T);
                    const all_u8 = comptime blk: {
                        for (fields) |field| {
                            if (field.type != u8) break :blk false;
                        }
                        break :blk true;
                    };

                    if (all_u8) {
                        // Optimized integer arithmetic path for u8 types
                        const SCALE = 256;

                        // Separate channels using helper
                        const channels = try channel_ops.splitChannels(T, self, allocator);
                        defer for (channels) |channel| allocator.free(channel);

                        // Allocate output channels
                        var out_channels: [Self.channels()][]u8 = undefined;
                        for (&out_channels) |*ch| {
                            ch.* = try allocator.alloc(u8, self.rows * self.cols);
                        }
                        defer for (out_channels) |ch| allocator.free(ch);

                        // Process each channel independently with integer arithmetic
                        for (channels, out_channels) |src_channel, dst_channel| {
                            for (0..self.rows) |r| {
                                for (0..self.cols) |c| {
                                    const x = @as(f32, @floatFromInt(c));
                                    const y = @as(f32, @floatFromInt(r));

                                    // Calculate distance and angle from center
                                    const dx = x - cx;
                                    const dy = y - cy;
                                    const distance = @sqrt(dx * dx + dy * dy);
                                    const angle = std.math.atan2(dy, dx);

                                    var sum: i32 = 0;
                                    var weight_sum: i32 = 0;

                                    // Number of samples based on distance and strength
                                    const max_samples = 20;
                                    const num_samples = @as(usize, @intFromFloat(@max(1, @min(@as(f32, max_samples), distance * clamped_strength * 0.1))));

                                    for (0..num_samples) |i| {
                                        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_samples));
                                        var sample_x: f32 = undefined;
                                        var sample_y: f32 = undefined;

                                        switch (blur_type) {
                                            .zoom => {
                                                const scale = 1.0 - (t * clamped_strength * 0.1);
                                                sample_x = cx + dx * scale;
                                                sample_y = cy + dy * scale;
                                            },
                                            .spin => {
                                                const angle_offset = (t - 0.5) * clamped_strength * 0.2;
                                                const new_angle = angle + angle_offset;
                                                sample_x = cx + distance * @cos(new_angle);
                                                sample_y = cy + distance * @sin(new_angle);
                                            },
                                        }

                                        if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(self.cols)) and
                                            sample_y >= 0 and sample_y < @as(f32, @floatFromInt(self.rows)))
                                        {
                                            const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                            const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                            const x1 = @min(x0 + 1, self.cols - 1);
                                            const y1 = @min(y0 + 1, self.rows - 1);

                                            // Convert fractional parts to integer weights
                                            const fx = @as(i32, @intFromFloat(SCALE * (sample_x - @as(f32, @floatFromInt(x0)))));
                                            const fy = @as(i32, @intFromFloat(SCALE * (sample_y - @as(f32, @floatFromInt(y0)))));
                                            const fx_inv = SCALE - fx;
                                            const fy_inv = SCALE - fy;

                                            const p00 = @as(i32, src_channel[y0 * self.cols + x0]);
                                            const p01 = @as(i32, src_channel[y0 * self.cols + x1]);
                                            const p10 = @as(i32, src_channel[y1 * self.cols + x0]);
                                            const p11 = @as(i32, src_channel[y1 * self.cols + x1]);

                                            // Bilinear interpolation with integer arithmetic
                                            // The interpolation result has SCALE^2 factor that we need to remove
                                            const value = @divTrunc(fx_inv * fy_inv * p00 +
                                                fx * fy_inv * p01 +
                                                fx_inv * fy * p10 +
                                                fx * fy * p11, SCALE * SCALE);

                                            sum += value;
                                            weight_sum += 1; // Simple count of samples
                                        }
                                    }

                                    // Store result with rounding
                                    // Now sum is already in pixel value range, weight_sum is just a count
                                    const result = if (weight_sum > 0)
                                        @as(u8, @intCast(@min(255, @max(0, @divTrunc(sum + @divTrunc(weight_sum, 2), weight_sum)))))
                                    else
                                        src_channel[r * self.cols + c];
                                    dst_channel[r * self.cols + c] = result;
                                }
                            }
                        }

                        // Merge channels back
                        channel_ops.mergeChannels(T, out_channels, out.*);
                    } else {
                        // Generic path for non-u8 types - process per pixel
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const x = @as(f32, @floatFromInt(c));
                                const y = @as(f32, @floatFromInt(r));

                                // Calculate distance and angle from center
                                const dx = x - cx;
                                const dy = y - cy;
                                const distance = @sqrt(dx * dx + dy * dy);
                                const angle = std.math.atan2(dy, dx);

                                var result_pixel: T = undefined;

                                inline for (fields) |field| {
                                    var sum: f32 = 0;
                                    var count: f32 = 0;

                                    // Number of samples based on distance and strength
                                    const max_samples = 20;
                                    const num_samples = @as(usize, @intFromFloat(@max(1, @min(@as(f32, max_samples), distance * clamped_strength * 0.1))));

                                    for (0..num_samples) |i| {
                                        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_samples));
                                        var sample_x: f32 = undefined;
                                        var sample_y: f32 = undefined;

                                        switch (blur_type) {
                                            .zoom => {
                                                const scale = 1.0 - (t * clamped_strength * 0.1);
                                                sample_x = cx + dx * scale;
                                                sample_y = cy + dy * scale;
                                            },
                                            .spin => {
                                                const angle_offset = (t - 0.5) * clamped_strength * 0.2;
                                                const new_angle = angle + angle_offset;
                                                sample_x = cx + distance * @cos(new_angle);
                                                sample_y = cy + distance * @sin(new_angle);
                                            },
                                        }

                                        if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(self.cols)) and
                                            sample_y >= 0 and sample_y < @as(f32, @floatFromInt(self.rows)))
                                        {
                                            const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                            const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                            const x1 = @min(x0 + 1, self.cols - 1);
                                            const y1 = @min(y0 + 1, self.rows - 1);

                                            const fx = sample_x - @as(f32, @floatFromInt(x0));
                                            const fy = sample_y - @as(f32, @floatFromInt(y0));

                                            const p00 = as(f32, @field(self.at(y0, x0).*, field.name));
                                            const p01 = as(f32, @field(self.at(y0, x1).*, field.name));
                                            const p10 = as(f32, @field(self.at(y1, x0).*, field.name));
                                            const p11 = as(f32, @field(self.at(y1, x1).*, field.name));

                                            const value = (1 - fx) * (1 - fy) * p00 +
                                                fx * (1 - fy) * p01 +
                                                (1 - fx) * fy * p10 +
                                                fx * fy * p11;

                                            sum += value;
                                            count += 1;
                                        }
                                    }

                                    const channel_result = if (count > 0) sum / count else as(f32, @field(self.at(r, c).*, field.name));
                                    @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                        .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(channel_result)))),
                                        .float => as(field.type, channel_result),
                                        else => @compileError("Unsupported field type"),
                                    };
                                }

                                out.at(r, c).* = result_pixel;
                            }
                        }
                    }
                },
                else => @compileError("Radial motion blur not supported for type " ++ @typeName(T)),
            }
        }

        /// Applies the Sobel filter to `self` to perform edge detection.
        /// The output is a grayscale image representing the magnitude of gradients at each pixel.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
        /// - `out`: An out-parameter pointer to an `Image(u8)` that will be filled with the Sobel magnitude image.
        pub fn sobel(self: Self, allocator: Allocator, out: *Image(u8)) !void {
            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // For now, use float path for all types to ensure correctness
            {
                // Original float path for other types
                const sobel_x = [3][3]f32{
                    .{ -1, 0, 1 },
                    .{ -2, 0, 2 },
                    .{ -1, 0, 1 },
                };
                const sobel_y = [3][3]f32{
                    .{ -1, -2, -1 },
                    .{ 0, 0, 0 },
                    .{ 1, 2, 1 },
                };

                // Convert input to grayscale float if needed
                var gray_float: Image(f32) = undefined;
                const needs_conversion = !isScalar(T) or @typeInfo(T) != .float;
                if (needs_conversion) {
                    gray_float = try .init(allocator, self.rows, self.cols);
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            gray_float.at(r, c).* = as(f32, convertColor(u8, self.at(r, c).*));
                        }
                    }
                } else {
                    gray_float = self;
                }
                defer if (needs_conversion) gray_float.deinit(allocator);

                // Apply Sobel X and Y filters
                var grad_x = Image(f32).empty;
                var grad_y = Image(f32).empty;
                defer grad_x.deinit(allocator);
                defer grad_y.deinit(allocator);

                const GrayFilter = Filter(f32);
                try GrayFilter.convolve(gray_float, allocator, sobel_x, &grad_x, .replicate);
                try GrayFilter.convolve(gray_float, allocator, sobel_y, &grad_y, .replicate);

                // Compute gradient magnitude
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        const gx = grad_x.at(r, c).*;
                        const gy = grad_y.at(r, c).*;
                        const magnitude = @sqrt(gx * gx + gy * gy);
                        // Scale by 1/4 to match typical Sobel output range
                        // Max theoretical magnitude is ~1442, so /4 maps to ~360 max
                        const scaled = magnitude / 4.0;
                        out.at(r, c).* = @intFromFloat(@max(0, @min(255, scaled)));
                    }
                }
            }
        }

        // ============================================================================
        // Helper Functions - Border handling, kernel processing, utilities
        // ============================================================================

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

        /// Get pixel value with border handling.
        fn getPixel(comptime PixelType: type, img: Image(PixelType), row: isize, col: isize, border_mode: BorderMode) PixelType {
            const coords = computeBorderCoords(row, col, @intCast(img.rows), @intCast(img.cols), border_mode);
            return if (coords.is_zero)
                std.mem.zeroes(PixelType)
            else
                img.at(@intCast(coords.row), @intCast(coords.col)).*;
        }

        /// Compute integral image sum with boundary checks.
        fn computeIntegralSum(sat: Image(f32), r1: usize, c1: usize, r2: usize, c2: usize) f32 {
            return sat.data[r2 * sat.stride + c2] -
                (if (c1 > 0) sat.data[r2 * sat.stride + (c1 - 1)] else 0) -
                (if (r1 > 0) sat.data[(r1 - 1) * sat.stride + c2] else 0) +
                (if (r1 > 0 and c1 > 0) sat.data[(r1 - 1) * sat.stride + (c1 - 1)] else 0);
        }

        /// Compute integral image sum for multi-channel images.
        fn computeIntegralSumMultiChannel(sat: anytype, r1: usize, c1: usize, r2: usize, c2: usize, channel: usize) f32 {
            return (if (r2 < sat.rows and c2 < sat.cols) sat.at(r2, c2)[channel] else 0) -
                (if (r2 < sat.rows and c1 > 0) sat.at(r2, c1 - 1)[channel] else 0) -
                (if (r1 > 0 and c2 < sat.cols) sat.at(r1 - 1, c2)[channel] else 0) +
                (if (r1 > 0 and c1 > 0) sat.at(r1 - 1, c1 - 1)[channel] else 0);
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
    };
}

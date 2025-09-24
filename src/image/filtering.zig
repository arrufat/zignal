//! Image filtering and convolution operations

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const isScalar = meta.isScalar;
const channel_ops = @import("channel_ops.zig");
const convolve = @import("convolution.zig").convolve;
const convolveSeparable = @import("convolution.zig").convolveSeparable;
pub const BorderMode = @import("convolution.zig").BorderMode;
const Integral = @import("integral.zig").Integral;

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
                        Integral(u8).plane(self, integral_img);
                        boxBlurPlane(u8, integral_img, blurred.*, radius);
                    } else if (T == f32) {
                        Integral(f32).plane(self, integral_img);
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
                        Integral(f32).plane(src_img, integral_img);

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
                    if (comptime meta.allFieldsAreU8(T)) {
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
                                    Integral(u8).plane(src_plane, integral_img);
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
                        const fields = std.meta.fields(T);
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
                                    const sum = Integral(f32).sumChannel(sat, r1, c1, r2, c2, i);

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
                    if (T == u8 or T == f32) {
                        Integral(T).plane(self, integral_img);
                        sharpenPlane(T, self, integral_img, sharpened.*, radius);
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
                        Integral(f32).plane(src_img, integral_img);

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
                    if (comptime meta.allFieldsAreU8(T)) {
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
                                    Integral(u8).plane(src_plane, integral_img);
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
                        const fields = std.meta.fields(T);
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
                                    const sum = Integral(f32).sumChannel(sat, r1, c1, r2, c2, i);

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

                        const sum = Integral(u8).sum(sat, r1, c1, r2, c2);

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
                                inline for (0..simd_len) |i| {
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
                    const sum = Integral(u8).sum(sat, r1, c1, r2, c2);

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

                        const sum = Integral(u8).sum(sat, r1, c1, r2, c2);

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
                                inline for (0..simd_len) |i| {
                                    const original = meta.as(f32, src.data[r * src.stride + c + i]);
                                    dst.data[r * dst.stride + c + i] = @intCast(@max(0, @min(255, @as(i32, @intFromFloat(@round(2 * original - blurred_vals[i]))))));
                                }
                            } else {
                                const two_vec: @Vector(simd_len, f32) = @splat(2.0);
                                var original_vals: @Vector(simd_len, f32) = undefined;
                                inline for (0..simd_len) |i| {
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
                    const sum = Integral(u8).sum(sat, r1, c1, r2, c2);

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

        /// Applies Gaussian blur to the image using separable convolution.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma`: Standard deviation of the Gaussian kernel.
        /// - `out`: Output blurred image.
        pub fn gaussianBlur(self: Self, allocator: Allocator, sigma: f32, out: *Self) !void {
            // sigma == 0 means no blur; just copy input to output
            if (sigma == 0) {
                if (!self.hasSameShape(out.*)) {
                    out.* = try .init(allocator, self.rows, self.cols);
                }
                self.copy(out.*);
                return;
            }
            if (sigma < 0) return error.InvalidSigma;

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
            try convolveSeparable(T, self, allocator, kernel, kernel, out, .mirror);
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
                        if (comptime meta.allFieldsAreU8(T)) {
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
                            const vec_len = comptime std.simd.suggestVectorLength(i32) orelse 8;

                            // Cache common conversions
                            const fcols: f32 = @floatFromInt(self.cols);
                            const frows: f32 = @floatFromInt(self.rows);

                            for (channels, out_channels) |src_channel, dst_channel| {
                                for (0..self.rows) |r| {
                                    var c: usize = 0;

                                    // SIMD path: process vec_len pixels at once with true vectorization
                                    while (c + vec_len <= self.cols) : (c += vec_len) {
                                        var sum_vec: @Vector(vec_len, i32) = @splat(0);
                                        var weight_vec: @Vector(vec_len, i32) = @splat(0);

                                        // Build coordinate vector for current pixels
                                        var col_indices: @Vector(vec_len, f32) = undefined;
                                        inline for (0..vec_len) |j| {
                                            col_indices[j] = @as(f32, @floatFromInt(c + j));
                                        }
                                        const row_f32 = @as(f32, @floatFromInt(r));
                                        const row_vec: @Vector(vec_len, f32) = @splat(row_f32);

                                        // Prepare constants for vectorized operations
                                        const scale_vec: @Vector(vec_len, i32) = @splat(SCALE);
                                        const scale_f32_vec: @Vector(vec_len, f32) = @splat(@as(f32, SCALE));
                                        const scale_sq_vec: @Vector(vec_len, i32) = @splat(SCALE * SCALE);
                                        const zero_f32_vec: @Vector(vec_len, f32) = @splat(0);
                                        const cols_f32_vec: @Vector(vec_len, f32) = @splat(fcols);
                                        const rows_f32_vec: @Vector(vec_len, f32) = @splat(frows);

                                        // Sample along the motion line
                                        const num_samples = distance;
                                        for (0..num_samples) |i| {
                                            const t = (@as(f32, @floatFromInt(i)) - half_dist + 0.5) / half_dist;
                                            const dx = t * half_dist * cos_angle;
                                            const dy = t * half_dist * sin_angle;

                                            // Calculate source coordinates for all pixels in vector
                                            const dx_vec: @Vector(vec_len, f32) = @splat(dx);
                                            const dy_vec: @Vector(vec_len, f32) = @splat(dy);
                                            const src_x_vec = col_indices + dx_vec;
                                            const src_y_vec = row_vec + dy_vec;

                                            // Vectorized bounds checking
                                            const in_bounds_x = (src_x_vec >= zero_f32_vec) & (src_x_vec < cols_f32_vec);
                                            const in_bounds_y = (src_y_vec >= zero_f32_vec) & (src_y_vec < rows_f32_vec);
                                            const in_bounds = in_bounds_x & in_bounds_y;

                                            // Skip if all pixels are out of bounds
                                            if (!@reduce(.Or, in_bounds)) continue;

                                            // Vectorized floor operations for coordinates
                                            const x0_f32_vec = @floor(src_x_vec);
                                            const y0_f32_vec = @floor(src_y_vec);

                                            // Vectorized fractional parts (scaled to integer)
                                            const fx_vec = @as(@Vector(vec_len, i32), @intFromFloat(scale_f32_vec * (src_x_vec - x0_f32_vec)));
                                            const fy_vec = @as(@Vector(vec_len, i32), @intFromFloat(scale_f32_vec * (src_y_vec - y0_f32_vec)));
                                            const fx_inv_vec = scale_vec - fx_vec;
                                            const fy_inv_vec = scale_vec - fy_vec;

                                            // Convert to integer coordinates
                                            const x0_ivec = @as(@Vector(vec_len, i32), @intFromFloat(x0_f32_vec));
                                            const y0_ivec = @as(@Vector(vec_len, i32), @intFromFloat(y0_f32_vec));

                                            // Gather pixels for bilinear interpolation
                                            // Note: This is still a bottleneck without hardware gather support
                                            var p00_vec: @Vector(vec_len, i32) = @splat(0);
                                            var p01_vec: @Vector(vec_len, i32) = @splat(0);
                                            var p10_vec: @Vector(vec_len, i32) = @splat(0);
                                            var p11_vec: @Vector(vec_len, i32) = @splat(0);

                                            inline for (0..vec_len) |j| {
                                                if (in_bounds[j]) {
                                                    const x0 = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(self.cols - 1)), x0_ivec[j]))));
                                                    const y0 = @as(usize, @intCast(@max(0, @min(@as(i32, @intCast(self.rows - 1)), y0_ivec[j]))));
                                                    const x1 = @min(x0 + 1, self.cols - 1);
                                                    const y1 = @min(y0 + 1, self.rows - 1);

                                                    p00_vec[j] = @as(i32, src_channel[y0 * self.cols + x0]);
                                                    p01_vec[j] = @as(i32, src_channel[y0 * self.cols + x1]);
                                                    p10_vec[j] = @as(i32, src_channel[y1 * self.cols + x0]);
                                                    p11_vec[j] = @as(i32, src_channel[y1 * self.cols + x1]);
                                                }
                                            }

                                            // Fully vectorized bilinear interpolation
                                            const interp_vec = @divTrunc(fx_inv_vec * fy_inv_vec * p00_vec +
                                                fx_vec * fy_inv_vec * p01_vec +
                                                fx_inv_vec * fy_vec * p10_vec +
                                                fx_vec * fy_vec * p11_vec, scale_sq_vec);

                                            // Masked accumulation based on bounds
                                            const in_bounds_mask = @select(i32, in_bounds, @as(@Vector(vec_len, i32), @splat(1)), @as(@Vector(vec_len, i32), @splat(0)));
                                            sum_vec += interp_vec * in_bounds_mask;
                                            weight_vec += in_bounds_mask;
                                        }

                                        // Vectorized averaging with safe division
                                        const zero_weight_mask = weight_vec == @as(@Vector(vec_len, i32), @splat(0));
                                        const safe_weights = @select(i32, zero_weight_mask, @as(@Vector(vec_len, i32), @splat(1)), weight_vec);

                                        // Vectorized rounding division
                                        const half_weights = @divTrunc(safe_weights, @as(@Vector(vec_len, i32), @splat(2)));
                                        const averaged = @divTrunc(sum_vec + half_weights, safe_weights);

                                        // Vectorized clamping to u8 range
                                        const clamped = @min(@as(@Vector(vec_len, i32), @splat(255)), @max(@as(@Vector(vec_len, i32), @splat(0)), averaged));

                                        // Store results with fallback for zero weights
                                        inline for (0..vec_len) |j| {
                                            dst_channel[r * self.cols + c + j] = if (zero_weight_mask[j])
                                                src_channel[r * self.cols + c + j]
                                            else
                                                @as(u8, @intCast(clamped[j]));
                                        }
                                    }

                                    // Scalar fallback for remaining pixels
                                    while (c < self.cols) : (c += 1) {
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

                                            if (src_x >= 0 and src_x < fcols and
                                                src_y >= 0 and src_y < frows)
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

                                                // Bilinear interpolation
                                                const value = @divTrunc(fx_inv * fy_inv * p00 +
                                                    fx * fy_inv * p01 +
                                                    fx_inv * fy * p10 +
                                                    fx * fy * p11, SCALE * SCALE);

                                                sum += value;
                                                weight_sum += 1;
                                            }
                                        }

                                        // Store result with rounding
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
                            const fields = std.meta.fields(T);
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

            // Cache common conversions
            const fcols: f32 = @floatFromInt(self.cols);
            const frows: f32 = @floatFromInt(self.rows);

            // Precompute trigonometric values for spin blur
            const max_samples = 20;
            var cos_table: [max_samples]f32 = undefined;
            var sin_table: [max_samples]f32 = undefined;
            if (blur_type == .spin) {
                for (0..max_samples) |i| {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(max_samples));
                    const angle_offset = (t - 0.5) * clamped_strength * 0.2;
                    cos_table[i] = @cos(angle_offset);
                    sin_table[i] = @sin(angle_offset);
                }
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    for (0..self.rows) |r| {
                        const y = @as(f32, @floatFromInt(r));
                        const dy_from_center = y - cy; // Constant for this row

                        for (0..self.cols) |c| {
                            const x = @as(f32, @floatFromInt(c));
                            const dx = x - cx;
                            const dy = dy_from_center; // Use precomputed value

                            // Calculate distance for both zoom and spin blur
                            const dist_sq = dx * dx + dy * dy;
                            const distance = @sqrt(dist_sq);

                            var sum: f32 = 0;
                            var count: f32 = 0;

                            // Number of samples based on strength (and distance for spin)
                            const num_samples = if (blur_type == .zoom)
                                @as(usize, @intFromFloat(@max(2, @min(@as(f32, max_samples), clamped_strength * @as(f32, max_samples)))))
                            else
                                @as(usize, @intFromFloat(@max(1, @min(@as(f32, max_samples), distance * clamped_strength * 0.1))));

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
                                        // Use precomputed trig values to rotate the point
                                        const idx = (i * max_samples) / num_samples; // Map to precomputed table
                                        const cos_angle = cos_table[idx];
                                        const sin_angle = sin_table[idx];
                                        // Rotate (dx, dy) by the angle offset
                                        sample_x = cx + dx * cos_angle - dy * sin_angle;
                                        sample_y = cy + dx * sin_angle + dy * cos_angle;
                                    },
                                }

                                // Check bounds and sample with bilinear interpolation
                                if (sample_x >= 0 and sample_x < fcols and
                                    sample_y >= 0 and sample_y < frows)
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
                    if (comptime meta.allFieldsAreU8(T)) {
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
                                const y = @as(f32, @floatFromInt(r));
                                const dy_from_center = y - cy; // Constant for this row

                                for (0..self.cols) |c| {
                                    const x = @as(f32, @floatFromInt(c));
                                    const dx = x - cx;
                                    const dy = dy_from_center; // Use precomputed value

                                    // Calculate distance for both zoom and spin blur
                                    const dist_sq = dx * dx + dy * dy;
                                    const distance = @sqrt(dist_sq);

                                    var sum: i32 = 0;
                                    var weight_sum: i32 = 0;

                                    // Number of samples based on strength (and distance for spin)
                                    const num_samples = if (blur_type == .zoom)
                                        @as(usize, @intFromFloat(@max(2, @min(@as(f32, max_samples), clamped_strength * @as(f32, max_samples)))))
                                    else
                                        @as(usize, @intFromFloat(@max(1, @min(@as(f32, max_samples), distance * clamped_strength * 0.1))));

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
                                                // Use precomputed trig values to rotate the point
                                                const idx = (i * max_samples) / num_samples; // Map to precomputed table
                                                const cos_angle = cos_table[idx];
                                                const sin_angle = sin_table[idx];
                                                // Rotate (dx, dy) by the angle offset
                                                sample_x = cx + dx * cos_angle - dy * sin_angle;
                                                sample_y = cy + dx * sin_angle + dy * cos_angle;
                                            },
                                        }

                                        if (sample_x >= 0 and sample_x < fcols and
                                            sample_y >= 0 and sample_y < frows)
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
                        const fields = std.meta.fields(T);
                        for (0..self.rows) |r| {
                            const y = @as(f32, @floatFromInt(r));
                            const dy_from_center = y - cy; // Constant for this row

                            for (0..self.cols) |c| {
                                const x = @as(f32, @floatFromInt(c));
                                const dx = x - cx;
                                const dy = dy_from_center; // Use precomputed value

                                // For zoom blur, we don't need angle; for spin we need distance
                                const dist_sq = dx * dx + dy * dy;
                                const distance = if (blur_type == .spin or dist_sq == 0) @sqrt(dist_sq) else 0;

                                var result_pixel: T = undefined;

                                inline for (fields) |field| {
                                    var sum: f32 = 0;
                                    var count: f32 = 0;

                                    // Number of samples based on distance and strength
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
                                                // Use precomputed trig values to rotate the point
                                                const idx = (i * max_samples) / num_samples; // Map to precomputed table
                                                const cos_angle = cos_table[idx];
                                                const sin_angle = sin_table[idx];
                                                // Rotate (dx, dy) by the angle offset
                                                sample_x = cx + dx * cos_angle - dy * sin_angle;
                                                sample_y = cy + dx * sin_angle + dy * cos_angle;
                                            },
                                        }

                                        if (sample_x >= 0 and sample_x < fcols and
                                            sample_y >= 0 and sample_y < frows)
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
    };
}

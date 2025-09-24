//! Image blur operations

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const channel_ops = @import("channel_ops.zig");
const convolveSeparable = @import("convolution.zig").convolveSeparable;
pub const BorderMode = @import("convolution.zig").BorderMode;
const Integral = @import("integral.zig").Integral;

/// Blur operations for Image(T)
pub fn Blur(comptime T: type) type {
    return struct {
        const Self = Image(T);

        /// Computes a blurred version of `self` using a box blur algorithm, efficiently implemented
        /// using an integral image. The `radius` parameter determines the size of the box window.
        /// This function is optimized using SIMD instructions for performance where applicable.
        pub fn box(self: Self, allocator: std.mem.Allocator, blurred: *Self, radius: usize) !void {
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

        /// Applies Gaussian blur to the image using separable convolution.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma`: Standard deviation of the Gaussian kernel.
        /// - `out`: Output blurred image.
        pub fn gaussian(self: Self, allocator: Allocator, sigma: f32, out: *Self) !void {
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
    };
}

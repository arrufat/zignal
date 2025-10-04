const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const isScalar = meta.isScalar;

/// Integral image operations for fast box filtering and region sums.
pub fn Integral(comptime T: type) type {
    return struct {
        /// Computes the integral image (summed-area table) from a source image.
        /// The integral image allows O(1) computation of rectangular region sums.
        ///
        /// After building the integral image:
        /// - sat[r,c] = sum of all pixels in rectangle from (0,0) to (r,c) inclusive
        /// - Rectangle sum from (r1,c1) to (r2,c2) = sat[r2,c2] - sat[r1-1,c2] - sat[r2,c1-1] + sat[r1-1,c1-1]
        ///
        /// Uses SIMD optimization for the column-wise accumulation pass.
        pub fn plane(src_img: Image(T), dst_img: Image(f32)) void {
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
                    tmp += as(f32, src_img.data[src_row_offset + c]);
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
                    const prev_vec: @Vector(simd_len, f32) = dst_img.data[prev_row_offset + c ..][0..simd_len].*;
                    const curr_vec: @Vector(simd_len, f32) = dst_img.data[curr_row_offset + c ..][0..simd_len].*;
                    const sum_vec = prev_vec + curr_vec;
                    dst_img.data[curr_row_offset + c ..][0..simd_len].* = sum_vec;
                }

                // Process remaining elements
                while (c < cols) : (c += 1) {
                    dst_img.data[curr_row_offset + c] += dst_img.data[prev_row_offset + c];
                }
            }
        }

        /// Computes the sum of pixels in a rectangular region using the integral image.
        /// The rectangle is defined by (r1, c1) as top-left and (r2, c2) as bottom-right, inclusive.
        ///
        /// Formula: sum = sat[r2,c2] - sat[r1-1,c2] - sat[r2,c1-1] + sat[r1-1,c1-1]
        /// Handles boundary conditions when r1=0 or c1=0.
        pub fn sum(sat: Image(f32), r1: usize, c1: usize, r2: usize, c2: usize) f32 {
            return sat.data[r2 * sat.stride + c2] -
                (if (c1 > 0) sat.data[r2 * sat.stride + (c1 - 1)] else 0) -
                (if (r1 > 0) sat.data[(r1 - 1) * sat.stride + c2] else 0) +
                (if (r1 > 0 and c1 > 0) sat.data[(r1 - 1) * sat.stride + (c1 - 1)] else 0);
        }

        /// Computes the sum of pixels in a rectangular region for multi-channel images.
        /// Similar to computeSum but operates on a specific channel of a multi-channel integral image.
        pub fn sumChannel(sat: anytype, r1: usize, c1: usize, r2: usize, c2: usize, channel: usize) f32 {
            return (if (r2 < sat.rows and c2 < sat.cols) sat.at(r2, c2)[channel] else 0) -
                (if (r2 < sat.rows and c1 > 0) sat.at(r2, c1 - 1)[channel] else 0) -
                (if (r1 > 0 and c2 < sat.cols) sat.at(r1 - 1, c2)[channel] else 0) +
                (if (r1 > 0 and c1 > 0) sat.at(r1 - 1, c1 - 1)[channel] else 0);
        }

        /// Build integral image (summed area table) from the source image.
        /// Uses channel separation and SIMD optimization for performance.
        pub fn compute(
            image: Image(T),
            allocator: Allocator,
            sat: *Image(if (isScalar(T)) f32 else [Image(T).channels()]f32),
        ) !void {
            // Always reinitialize if not matching shape (handles undefined case safely)
            if (!image.hasSameShape(sat.*)) {
                sat.* = try Image(if (isScalar(T)) f32 else [Image(T).channels()]f32).init(allocator, image.rows, image.cols);
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Use generic integral plane function for all scalar types
                    plane(image, sat.*);
                },
                .@"struct" => {
                    // Channel separation for struct types
                    const fields = std.meta.fields(T);

                    // Create temporary buffers for each channel
                    const src_plane = try allocator.alloc(f32, image.rows * image.cols);
                    defer allocator.free(src_plane);
                    const dst_plane = try allocator.alloc(f32, image.rows * image.cols);
                    defer allocator.free(dst_plane);

                    // Process each channel separately
                    inline for (fields, 0..) |field, ch| {
                        // Extract channel to packed src_plane respecting stride
                        for (0..image.rows) |r| {
                            for (0..image.cols) |c| {
                                const pix = image.at(r, c).*;
                                const val = @field(pix, field.name);
                                src_plane[r * image.cols + c] = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(val),
                                    .float => @floatCast(val),
                                    else => 0,
                                };
                            }
                        }

                        const src_img: Image(f32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = src_plane };
                        const dst_img: Image(f32) = .{ .rows = image.rows, .cols = image.cols, .stride = image.cols, .data = dst_plane };

                        // Compute integral for this channel from packed src_plane into packed dst_plane
                        Integral(f32).plane(src_img, dst_img);

                        // Store result in output channel (packed to packed)
                        for (0..image.rows * image.cols) |i| {
                            sat.data[i][ch] = dst_plane[i];
                        }
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Applies box blur using a pre-computed integral image.
        /// This allows efficient reuse of the integral image for multiple blur operations.
        pub fn boxBlur(
            sat: anytype,
            src: Image(T),
            dst: Image(T),
            radius: usize,
        ) void {
            if (radius == 0) {
                src.copy(dst);
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Single channel blur
                    boxBlurPlane(T, sat, dst, radius);
                },
                .@"struct" => {
                    // Multi-channel blur
                    const fields = std.meta.fields(T);
                    for (0..src.rows) |r| {
                        for (0..src.cols) |c| {
                            const r1 = r -| radius;
                            const c1 = c -| radius;
                            const r2 = @min(r + radius, src.rows - 1);
                            const c2 = @min(c + radius, src.cols - 1);
                            const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                            inline for (fields, 0..) |f, i| {
                                const channel_sum = sumChannel(sat, r1, c1, r2, c2, i);
                                @field(dst.at(r, c).*, f.name) = switch (@typeInfo(f.type)) {
                                    .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(channel_sum / area)))),
                                    .float => as(f.type, channel_sum / area),
                                    else => @compileError("Can't compute box blur with struct fields of type " ++ @typeName(f.type) ++ "."),
                                };
                            }
                        }
                    }
                },
                else => @compileError("Can't compute box blur of " ++ @typeName(T) ++ "."),
            }
        }

        /// Box blur for scalar plane types using integral image with SIMD optimization.
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
                    // Handle left border
                    while (c <= radius) : (c += 1) {
                        const c1 = c -| radius;
                        const c2 = @min(c + radius, cols - 1);
                        const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                        const s = sum(sat, r1, c1, r2, c2);
                        const val = s / area;
                        dst.data[r * dst.stride + c] = meta.clamp(PlaneType, val);
                    }

                    // SIMD middle section
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
                                    dst.data[r * dst.stride + c + i] = meta.clamp(u8, vals[i]);
                                }
                            } else if (@typeInfo(PlaneType) == .int) {
                                inline for (0..simd_len) |i| {
                                    dst.data[r * dst.stride + c + i] = meta.clamp(PlaneType, vals[i]);
                                }
                            } else {
                                dst.data[r * dst.stride + c ..][0..simd_len].* = vals;
                            }
                        }
                    }
                }

                // Handle remaining pixels
                while (c < cols) : (c += 1) {
                    const c1 = c -| radius;
                    const c2 = @min(c + radius, cols - 1);
                    const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                    const s = sum(sat, r1, c1, r2, c2);
                    const val = s / area;
                    dst.data[r * dst.stride + c] = if (PlaneType == u8)
                        meta.clamp(u8, val)
                    else
                        meta.clamp(PlaneType, val);
                }
            }
        }

        /// Applies sharpening using a pre-computed integral image.
        /// Uses the formula: sharpened = 2 * original - blurred
        pub fn sharpen(
            sat: anytype,
            src: Image(T),
            dst: Image(T),
            radius: usize,
        ) void {
            if (radius == 0) {
                src.copy(dst);
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Single channel sharpen
                    sharpenPlane(T, src, sat, dst, radius);
                },
                .@"struct" => {
                    // Multi-channel sharpen
                    const fields = std.meta.fields(T);
                    for (0..src.rows) |r| {
                        for (0..src.cols) |c| {
                            const r1 = r -| radius;
                            const c1 = c -| radius;
                            const r2 = @min(r + radius, src.rows - 1);
                            const c2 = @min(c + radius, src.cols - 1);
                            const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                            inline for (fields, 0..) |f, i| {
                                const channel_sum = sumChannel(sat, r1, c1, r2, c2, i);
                                const blurred = channel_sum / area;
                                const original = @field(src.at(r, c).*, f.name);
                                @field(dst.at(r, c).*, f.name) = switch (@typeInfo(f.type)) {
                                    .int => blk: {
                                        const sharpened_val = 2 * as(f32, original) - blurred;
                                        break :blk @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sharpened_val))));
                                    },
                                    .float => as(f.type, 2 * as(f32, original) - blurred),
                                    else => @compileError("Can't compute sharpen with struct fields of type " ++ @typeName(f.type) ++ "."),
                                };
                            }
                        }
                    }
                },
                else => @compileError("Can't compute sharpen of " ++ @typeName(T) ++ "."),
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
            assert(sat.rows == dst.rows and sat.cols == dst.cols);
            assert(src.rows == dst.rows and src.cols == dst.cols);
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
                    // Handle left border
                    while (c <= radius) : (c += 1) {
                        const c1 = c -| radius;
                        const c2 = @min(c + radius, cols - 1);
                        const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                        const s = sum(sat, r1, c1, r2, c2);
                        const blurred = s / area;
                        const original = as(f32, src.data[r * src.stride + c]);
                        const sharpened = 2 * original - blurred;
                        dst.data[r * dst.stride + c] = if (PlaneType == u8)
                            meta.clamp(u8, sharpened)
                        else
                            meta.clamp(PlaneType, sharpened);
                    }

                    // SIMD middle section
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
                            const blurred_vec = sums / area_vec;

                            // Load original values as vector
                            var orig_vec: @Vector(simd_len, f32) = undefined;
                            inline for (0..simd_len) |i| {
                                orig_vec[i] = as(f32, src.data[r * src.stride + c + i]);
                            }

                            const sharpened_vec = @as(@Vector(simd_len, f32), @splat(2)) * orig_vec - blurred_vec;

                            if (PlaneType == u8) {
                                inline for (0..simd_len) |i| {
                                    dst.data[r * dst.stride + c + i] = meta.clamp(u8, sharpened_vec[i]);
                                }
                            } else if (@typeInfo(PlaneType) == .int) {
                                inline for (0..simd_len) |i| {
                                    dst.data[r * dst.stride + c + i] = meta.clamp(PlaneType, sharpened_vec[i]);
                                }
                            } else {
                                dst.data[r * dst.stride + c ..][0..simd_len].* = sharpened_vec;
                            }
                        }
                    }
                }

                // Handle remaining pixels
                while (c < cols) : (c += 1) {
                    const c1 = c -| radius;
                    const c2 = @min(c + radius, cols - 1);
                    const area: f32 = @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1));

                    const s = sum(sat, r1, c1, r2, c2);
                    const blurred = s / area;
                    const original = as(f32, src.data[r * src.stride + c]);
                    const sharpened = 2 * original - blurred;
                    dst.data[r * dst.stride + c] = if (PlaneType == u8)
                        meta.clamp(u8, sharpened)
                    else
                        meta.clamp(PlaneType, sharpened);
                }
            }
        }
    };
}

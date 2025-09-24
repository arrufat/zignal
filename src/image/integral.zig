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
            img: Image(T),
            allocator: Allocator,
            sat: *Image(if (isScalar(T)) f32 else [Image(T).channels()]f32),
        ) !void {
            if (!img.hasSameShape(sat.*)) {
                sat.* = try Image(if (isScalar(T)) f32 else [Image(T).channels()]f32).init(allocator, img.rows, img.cols);
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Use generic integral plane function for all scalar types
                    plane(img, sat.*);
                },
                .@"struct" => {
                    // Channel separation for struct types
                    const fields = std.meta.fields(T);

                    // Create temporary buffers for each channel
                    const src_plane = try allocator.alloc(f32, img.rows * img.cols);
                    defer allocator.free(src_plane);
                    const dst_plane = try allocator.alloc(f32, img.rows * img.cols);
                    defer allocator.free(dst_plane);

                    // Process each channel separately
                    inline for (fields, 0..) |field, ch| {
                        // Extract channel to packed src_plane respecting stride
                        for (0..img.rows) |r| {
                            for (0..img.cols) |c| {
                                const pix = img.at(r, c).*;
                                const val = @field(pix, field.name);
                                src_plane[r * img.cols + c] = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(val),
                                    .float => @floatCast(val),
                                    else => 0,
                                };
                            }
                        }

                        const src_img: Image(f32) = .{ .rows = img.rows, .cols = img.cols, .stride = img.cols, .data = src_plane };
                        const dst_img: Image(f32) = .{ .rows = img.rows, .cols = img.cols, .stride = img.cols, .data = dst_plane };

                        // Compute integral for this channel from packed src_plane into packed dst_plane
                        Integral(f32).plane(src_img, dst_img);

                        // Store result in output channel (packed to packed)
                        for (0..img.rows * img.cols) |i| {
                            sat.data[i][ch] = dst_plane[i];
                        }
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
            }
        }
    };
}

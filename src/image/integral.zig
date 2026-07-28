const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;

/// Summed-area tables (integral images) for O(1) rectangular region sums.
pub fn Integral(comptime T: type) type {
    return struct {
        const channel_count = Image(T).channels();

        /// Holds one summed-area table (integral image) per channel. Scalar image types
        /// only populate `planes[0]`; struct-based pixels keep a dedicated plane per channel.
        pub const Planes = struct {
            planes: [channel_count]Image(f32),

            pub fn init() Planes {
                var init_planes: [channel_count]Image(f32) = undefined;
                inline for (0..channel_count) |i| {
                    init_planes[i] = Image(f32).empty;
                }
                return .{ .planes = init_planes };
            }

            pub fn deinit(self: *Planes, allocator: Allocator) void {
                inline for (0..channel_count) |i| {
                    self.planes[i].deinit(allocator);
                    self.planes[i] = Image(f32).empty;
                }
            }
        };

        /// Computes the integral image (summed-area table) from a source image.
        /// The integral image allows O(1) computation of rectangular region sums.
        ///
        /// After building the integral image:
        /// - sat[r,c] = sum of all pixels in rectangle from (0,0) to (r,c) inclusive
        /// - Rectangle sum from (r1,c1) to (r2,c2) = sat[r2,c2] - sat[r1-1,c2] - sat[r2,c1-1] + sat[r1-1,c1-1]
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

        /// Build integral planes (summed-area tables) from the source image.
        /// A single plane is produced for scalar images, while struct images receive
        /// one plane per channel.
        pub fn compute(
            image: Image(T),
            allocator: Allocator,
            planes: *Planes,
        ) !void {
            if (image.rows * image.cols == 0) return;
            inline for (0..channel_count) |i| {
                if (planes.planes[i].rows != image.rows or planes.planes[i].cols != image.cols) {
                    planes.planes[i].deinit(allocator);
                    planes.planes[i] = try Image(f32).init(allocator, image.rows, image.cols);
                }
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    plane(image, planes.planes[0]);
                },
                .@"struct" => {
                    const fields = comptime meta.structFields(T);
                    const plane_len = try std.math.mul(usize, image.rows, image.cols);
                    const src_plane = try allocator.alloc(f32, plane_len);
                    defer allocator.free(src_plane);

                    const src_img = Image(f32){
                        .rows = image.rows,
                        .cols = image.cols,
                        .stride = image.cols,
                        .data = src_plane,
                    };

                    inline for (fields, 0..) |field, ch| {
                        for (0..image.rows) |r| {
                            for (0..image.cols) |c| {
                                const pix = image.at(r, c).*;
                                const channel_val = @field(pix, field.name);
                                src_plane[r * image.cols + c] = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(channel_val),
                                    .float => @floatCast(channel_val),
                                    else => @compileError("Unsupported channel type in Integral.compute: " ++ @typeName(field.type)),
                                };
                            }
                        }

                        Integral(f32).plane(src_img, planes.planes[ch]);
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
            }
        }
    };
}

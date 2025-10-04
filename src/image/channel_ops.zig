//! Channel separation and combination operations for image processing
//!
//! This module provides utilities for separating multi-channel images into
//! individual planes and recombining them. This enables optimized single-channel
//! processing using SIMD and integer arithmetic.

const std = @import("std");
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");

/// Find the uniform value of a channel if all values are the same.
/// Returns the uniform value if all elements are identical, null otherwise.
pub fn findUniformValue(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;
    const first = data[0];

    // Use SIMD for faster checking on larger arrays
    const vec_len = std.simd.suggestVectorLength(T) orelse 1;
    if (vec_len > 1 and data.len >= vec_len * 4) {
        // SIMD path for faster uniformity check
        const first_vec: @Vector(vec_len, T) = @splat(first);
        var i: usize = 0;
        while (i + vec_len <= data.len) : (i += vec_len) {
            const vec: @Vector(vec_len, T) = data[i..][0..vec_len].*;
            if (@reduce(.Or, vec != first_vec)) return null;
        }
        // Check remaining elements
        while (i < data.len) : (i += 1) {
            if (data[i] != first) return null;
        }
    } else {
        // Scalar path for small arrays or non-SIMD types
        for (data[1..]) |val| {
            if (val != first) return null;
        }
    }
    return first;
}

/// Get the common type of all fields in a struct, or compile error if not uniform
fn FieldTypeOf(comptime T: type) type {
    const fields = std.meta.fields(T);
    if (fields.len == 0) @compileError("Type " ++ @typeName(T) ++ " has no fields");

    const first_type = fields[0].type;
    inline for (fields[1..]) |field| {
        if (field.type != first_type) {
            @compileError("Fields of " ++ @typeName(T) ++ " are not all the same type");
        }
    }
    return first_type;
}

/// Separate all channels from a struct image into individual planes.
/// Allocates and fills channel planes for all fields.
/// The caller is responsible for freeing the returned slices.
pub fn splitChannels(comptime T: type, image: Image(T), allocator: std.mem.Allocator) ![Image(T).channels()][]FieldTypeOf(T) {
    const num_channels = comptime Image(T).channels();
    const fields = std.meta.fields(T);
    const FieldType = FieldTypeOf(T);
    const plane_size = image.rows * image.cols;

    var channels: [num_channels][]FieldType = undefined;

    // Allocate each channel with proper error handling
    var allocated_count: usize = 0;
    errdefer {
        for (0..allocated_count) |i| {
            allocator.free(channels[i]);
        }
    }

    inline for (&channels) |*channel| {
        channel.* = try allocator.alloc(FieldType, plane_size);
        allocated_count += 1;
    }

    // Split in single pass for cache efficiency
    var idx: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const pixel = image.at(r, c).*;
            inline for (fields, 0..) |field, i| {
                channels[i][idx] = @field(pixel, field.name);
            }
            idx += 1;
        }
    }

    return channels;
}

/// Combine channels back into struct image.
pub fn mergeChannels(comptime T: type, channels: [Image(T).channels()][]const FieldTypeOf(T), out: Image(T)) void {
    const fields = std.meta.fields(T);

    var idx: usize = 0;
    for (0..out.rows) |r| {
        for (0..out.cols) |c| {
            var result_pixel: T = undefined;
            inline for (fields, 0..) |field, i| {
                @field(result_pixel, field.name) = channels[i][idx];
            }
            out.at(r, c).* = result_pixel;
            idx += 1;
        }
    }
}

// ============================================================================
// Optimized Plane Resize Functions
// ============================================================================

/// Optimized bilinear resize for u8 planes using integer arithmetic.
/// Uses fixed-point arithmetic (scaled by 256) for performance.
pub fn resizePlaneBilinearU8(
    src: []const u8,
    dst: []u8,
    src_rows: usize,
    src_cols: usize,
    dst_rows: usize,
    dst_cols: usize,
) void {
    const SCALE = 256;

    // Calculate scaling ratios in fixed-point
    const x_ratio = if (dst_cols > 1)
        ((src_cols - 1) * SCALE) / (dst_cols - 1)
    else
        0;
    const y_ratio = if (dst_rows > 1)
        ((src_rows - 1) * SCALE) / (dst_rows - 1)
    else
        0;

    // Process each output pixel
    for (0..dst_rows) |r| {
        const src_y = (r * y_ratio) / SCALE;
        const src_y_next = @min(src_y + 1, src_rows - 1);
        const fy = (r * y_ratio) % SCALE; // Fractional part

        for (0..dst_cols) |c| {
            const src_x = (c * x_ratio) / SCALE;
            const src_x_next = @min(src_x + 1, src_cols - 1);
            const fx = (c * x_ratio) % SCALE; // Fractional part

            // Get the 4 neighboring pixels
            const tl = @as(i32, src[src_y * src_cols + src_x]);
            const tr = @as(i32, src[src_y * src_cols + src_x_next]);
            const bl = @as(i32, src[src_y_next * src_cols + src_x]);
            const br = @as(i32, src[src_y_next * src_cols + src_x_next]);

            // Bilinear interpolation using integer arithmetic
            const top = tl * (SCALE - @as(i32, @intCast(fx))) + tr * @as(i32, @intCast(fx));
            const bottom = bl * (SCALE - @as(i32, @intCast(fx))) + br * @as(i32, @intCast(fx));
            const result = @divTrunc(top * (SCALE - @as(i32, @intCast(fy))) + bottom * @as(i32, @intCast(fy)), SCALE * SCALE);

            dst[r * dst_cols + c] = meta.clamp(u8, result);
        }
    }
}

/// Optimized nearest neighbor resize for u8 planes.
pub fn resizePlaneNearestU8(
    src: []const u8,
    dst: []u8,
    src_rows: usize,
    src_cols: usize,
    dst_rows: usize,
    dst_cols: usize,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y = @min(src_rows - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(r)) * y_ratio))));
        for (0..dst_cols) |c| {
            const src_x = @min(src_cols - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(c)) * x_ratio))));
            dst[r * dst_cols + c] = src[src_y * src_cols + src_x];
        }
    }
}

/// Optimized bicubic resize for u8 planes using integer arithmetic.
pub fn resizePlaneBicubicU8(
    src: []const u8,
    dst: []u8,
    src_rows: usize,
    src_cols: usize,
    dst_rows: usize,
    dst_cols: usize,
) void {
    const SCALE = 256;

    // Bicubic kernel function (a = -0.5)
    const cubicKernel = struct {
        fn eval(t: i32) i32 {
            const at: i32 = @intCast(@abs(t));
            if (at <= SCALE) {
                // 1 - 2*t^2 + |t|^3
                const t2 = @divTrunc(at * at, SCALE);
                const t3 = @divTrunc(t2 * at, SCALE);
                return SCALE - 2 * t2 + t3;
            } else if (at <= 2 * SCALE) {
                // 4 - 8*|t| + 5*t^2 - |t|^3
                const t2 = @divTrunc(at * at, SCALE);
                const t3 = @divTrunc(t2 * at, SCALE);
                return 4 * SCALE - 8 * at + 5 * t2 - t3;
            }
            return 0;
        }
    }.eval;

    const x_ratio = if (dst_cols > 1)
        @as(f32, @floatFromInt(src_cols - 1)) / @as(f32, @floatFromInt(dst_cols - 1))
    else
        0;
    const y_ratio = if (dst_rows > 1)
        @as(f32, @floatFromInt(src_rows - 1)) / @as(f32, @floatFromInt(dst_rows - 1))
    else
        0;

    for (0..dst_rows) |r| {
        const src_y_f = @as(f32, @floatFromInt(r)) * y_ratio;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = @as(i32, @intFromFloat((src_y_f - @floor(src_y_f)) * SCALE));

        for (0..dst_cols) |c| {
            const src_x_f = @as(f32, @floatFromInt(c)) * x_ratio;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = @as(i32, @intFromFloat((src_x_f - @floor(src_x_f)) * SCALE));

            var sum: i32 = 0;
            var weight_sum: i32 = 0;

            // 4x4 kernel
            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                if (y_idx < 0 or y_idx >= src_rows) continue;

                const wy = cubicKernel(@as(i32, @intCast(ky)) * SCALE - SCALE - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    if (x_idx < 0 or x_idx >= src_cols) continue;

                    const wx = cubicKernel(@as(i32, @intCast(kx)) * SCALE - SCALE - fx);
                    const w = @divTrunc(wx * wy, SCALE);

                    const pixel_val = @as(i32, src[@as(usize, @intCast(y_idx)) * src_cols + @as(usize, @intCast(x_idx))]);
                    sum += pixel_val * w;
                    weight_sum += w;
                }
            }

            const result = if (weight_sum != 0)
                @divTrunc(sum, weight_sum)
            else
                0;

            dst[r * dst_cols + c] = meta.clamp(u8, result);
        }
    }
}

/// Optimized Catmull-Rom resize for u8 planes using integer arithmetic.
pub fn resizePlaneCatmullRomU8(
    src: []const u8,
    dst: []u8,
    src_rows: usize,
    src_cols: usize,
    dst_rows: usize,
    dst_cols: usize,
) void {
    const SCALE = 256;

    // Catmull-Rom kernel function
    const catmullRomKernel = struct {
        fn eval(t: i32) i32 {
            const at: i32 = @intCast(@abs(t));
            if (at <= SCALE) {
                // 1.5*|t|^3 - 2.5*|t|^2 + 1
                const t2 = @divTrunc(at * at, SCALE);
                const t3 = @divTrunc(t2 * at, SCALE);
                return SCALE - @divTrunc(5 * t2, 2) + @divTrunc(3 * t3, 2);
            } else if (at <= 2 * SCALE) {
                // -0.5*|t|^3 + 2.5*|t|^2 - 4*|t| + 2
                const t2 = @divTrunc(at * at, SCALE);
                const t3 = @divTrunc(t2 * at, SCALE);
                return 2 * SCALE - 4 * at + @divTrunc(5 * t2, 2) - @divTrunc(t3, 2);
            }
            return 0;
        }
    }.eval;

    const x_ratio = if (dst_cols > 1)
        @as(f32, @floatFromInt(src_cols - 1)) / @as(f32, @floatFromInt(dst_cols - 1))
    else
        0;
    const y_ratio = if (dst_rows > 1)
        @as(f32, @floatFromInt(src_rows - 1)) / @as(f32, @floatFromInt(dst_rows - 1))
    else
        0;

    for (0..dst_rows) |r| {
        const src_y_f = @as(f32, @floatFromInt(r)) * y_ratio;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = @as(i32, @intFromFloat((src_y_f - @floor(src_y_f)) * SCALE));

        for (0..dst_cols) |c| {
            const src_x_f = @as(f32, @floatFromInt(c)) * x_ratio;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = @as(i32, @intFromFloat((src_x_f - @floor(src_x_f)) * SCALE));

            var sum: i32 = 0;
            var weight_sum: i32 = 0;

            // 4x4 kernel
            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                if (y_idx < 0 or y_idx >= src_rows) continue;

                const wy = catmullRomKernel(@as(i32, @intCast(ky)) * SCALE - SCALE - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    if (x_idx < 0 or x_idx >= src_cols) continue;

                    const wx = catmullRomKernel(@as(i32, @intCast(kx)) * SCALE - SCALE - fx);
                    const w = @divTrunc(wx * wy, SCALE);

                    const pixel_val = @as(i32, src[@as(usize, @intCast(y_idx)) * src_cols + @as(usize, @intCast(x_idx))]);
                    sum += pixel_val * w;
                    weight_sum += w;
                }
            }

            const result = if (weight_sum != 0)
                @divTrunc(sum, weight_sum)
            else
                0;

            dst[r * dst_cols + c] = meta.clamp(u8, result);
        }
    }
}

/// Generic f32 plane resize with SIMD optimization.
pub fn resizePlaneF32(
    src: []const f32,
    dst: []f32,
    src_rows: usize,
    src_cols: usize,
    dst_rows: usize,
    dst_cols: usize,
    method: enum { nearest, bilinear, bicubic },
) void {
    switch (method) {
        .nearest => {
            const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
            const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

            for (0..dst_rows) |r| {
                const src_y = @min(src_rows - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(r)) * y_ratio))));
                for (0..dst_cols) |c| {
                    const src_x = @min(src_cols - 1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(c)) * x_ratio))));
                    dst[r * dst_cols + c] = src[src_y * src_cols + src_x];
                }
            }
        },
        .bilinear => {
            const x_ratio = if (dst_cols > 1)
                @as(f32, @floatFromInt(src_cols - 1)) / @as(f32, @floatFromInt(dst_cols - 1))
            else
                0;
            const y_ratio = if (dst_rows > 1)
                @as(f32, @floatFromInt(src_rows - 1)) / @as(f32, @floatFromInt(dst_rows - 1))
            else
                0;

            for (0..dst_rows) |r| {
                const src_y_f = @as(f32, @floatFromInt(r)) * y_ratio;
                const src_y = @as(usize, @intFromFloat(@floor(src_y_f)));
                const src_y_next = @min(src_y + 1, src_rows - 1);
                const fy = src_y_f - @floor(src_y_f);

                for (0..dst_cols) |c| {
                    const src_x_f = @as(f32, @floatFromInt(c)) * x_ratio;
                    const src_x = @as(usize, @intFromFloat(@floor(src_x_f)));
                    const src_x_next = @min(src_x + 1, src_cols - 1);
                    const fx = src_x_f - @floor(src_x_f);

                    const tl = src[src_y * src_cols + src_x];
                    const tr = src[src_y * src_cols + src_x_next];
                    const bl = src[src_y_next * src_cols + src_x];
                    const br = src[src_y_next * src_cols + src_x_next];

                    const top = tl * (1 - fx) + tr * fx;
                    const bottom = bl * (1 - fx) + br * fx;
                    dst[r * dst_cols + c] = top * (1 - fy) + bottom * fy;
                }
            }
        },
        .bicubic => {
            // Simplified bicubic for f32 - could be optimized further
            resizePlaneBicubicF32(src, dst, src_rows, src_cols, dst_rows, dst_cols);
        },
    }
}

// Helper for f32 bicubic
fn resizePlaneBicubicF32(
    src: []const f32,
    dst: []f32,
    src_rows: usize,
    src_cols: usize,
    dst_rows: usize,
    dst_cols: usize,
) void {
    const cubicKernel = struct {
        fn eval(t: f32) f32 {
            const at = @abs(t);
            if (at <= 1) {
                return 1 - 2 * at * at + at * at * at;
            } else if (at <= 2) {
                return 4 - 8 * at + 5 * at * at - at * at * at;
            }
            return 0;
        }
    }.eval;

    const x_ratio = if (dst_cols > 1)
        @as(f32, @floatFromInt(src_cols - 1)) / @as(f32, @floatFromInt(dst_cols - 1))
    else
        0;
    const y_ratio = if (dst_rows > 1)
        @as(f32, @floatFromInt(src_rows - 1)) / @as(f32, @floatFromInt(dst_rows - 1))
    else
        0;

    for (0..dst_rows) |r| {
        const src_y_f = @as(f32, @floatFromInt(r)) * y_ratio;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = src_y_f - @floor(src_y_f);

        for (0..dst_cols) |c| {
            const src_x_f = @as(f32, @floatFromInt(c)) * x_ratio;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = src_x_f - @floor(src_x_f);

            var sum: f32 = 0;
            var weight_sum: f32 = 0;

            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                if (y_idx < 0 or y_idx >= src_rows) continue;

                const wy = cubicKernel(@as(f32, @floatFromInt(@as(isize, @intCast(ky)) - 1)) - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    if (x_idx < 0 or x_idx >= src_cols) continue;

                    const wx = cubicKernel(@as(f32, @floatFromInt(@as(isize, @intCast(kx)) - 1)) - fx);
                    const w = wx * wy;

                    sum += src[@as(usize, @intCast(y_idx)) * src_cols + @as(usize, @intCast(x_idx))] * w;
                    weight_sum += w;
                }
            }

            dst[r * dst_cols + c] = if (weight_sum != 0) sum / weight_sum else 0;
        }
    }
}

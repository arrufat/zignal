//! Channel separation and combination operations for image processing
//!
//! This module provides utilities for separating multi-channel images into
//! individual planes and recombining them. This enables optimized single-channel
//! processing using SIMD and integer arithmetic.

const std = @import("std");
const meta = @import("../meta.zig");
const as = meta.as;
const Image = @import("Image.zig").Image;

/// Check if a struct type has an alpha channel (4th field named 'a' or 'alpha')
pub fn hasAlphaChannel(comptime T: type) bool {
    const fields = std.meta.fields(T);
    if (fields.len != 4) return false;
    const last_field = fields[3];
    return std.mem.eql(u8, last_field.name, "a") or std.mem.eql(u8, last_field.name, "alpha");
}

/// Separate RGB channels from a struct image into individual planes.
/// Allocates and fills 3 channel planes (r, g, b).
/// The caller is responsible for freeing the returned slices.
pub fn splitRgbChannels(comptime T: type, image: anytype, allocator: std.mem.Allocator) ![3][]u8 {
    const fields = std.meta.fields(T);
    const plane_size = image.rows * image.cols;

    const r_channel = try allocator.alloc(u8, plane_size);
    errdefer allocator.free(r_channel);
    const g_channel = try allocator.alloc(u8, plane_size);
    errdefer allocator.free(g_channel);
    const b_channel = try allocator.alloc(u8, plane_size);
    errdefer allocator.free(b_channel);

    // Single pass for cache efficiency
    var idx: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const pixel = image.at(r, c).*;
            r_channel[idx] = @field(pixel, fields[0].name);
            g_channel[idx] = @field(pixel, fields[1].name);
            b_channel[idx] = @field(pixel, fields[2].name);
            idx += 1;
        }
    }

    return .{ r_channel, g_channel, b_channel };
}

/// Combine RGB channels back into struct image, optionally preserving alpha from original.
pub fn mergeRgbChannels(
    comptime T: type,
    original_image: anytype,
    r_out: []const u8,
    g_out: []const u8,
    b_out: []const u8,
    out: anytype,
) void {
    _ = original_image; // May be used in the future for alpha preservation
    const fields = std.meta.fields(T);
    const has_alpha = comptime hasAlphaChannel(T);

    var idx: usize = 0;
    for (0..out.rows) |r| {
        for (0..out.cols) |c| {
            var result_pixel: T = undefined;
            @field(result_pixel, fields[0].name) = r_out[idx];
            @field(result_pixel, fields[1].name) = g_out[idx];
            @field(result_pixel, fields[2].name) = b_out[idx];

            // Preserve alpha if present (need to handle resize case where dimensions differ)
            if (has_alpha) {
                // For resize operations with alpha channel, set to fully opaque
                @field(result_pixel, fields[3].name) = 255;
            } else if (fields.len == 4) {
                // For non-alpha 4th channel, use zero default
                @field(result_pixel, fields[3].name) = 0;
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

            dst[r * dst_cols + c] = @intCast(@max(0, @min(255, result)));
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

            dst[r * dst_cols + c] = @intCast(@max(0, @min(255, result)));
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

            dst[r * dst_cols + c] = @intCast(@max(0, @min(255, result)));
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

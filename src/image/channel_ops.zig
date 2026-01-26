//! Channel separation and combination operations for image processing
//!
//! This module provides utilities for separating multi-channel images into
//! individual planes and recombining them. This enables optimized single-channel
//! processing using SIMD and integer arithmetic.

const std = @import("std");
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const resolveIndex = @import("border.zig").resolveIndex;

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
        var i: u32 = 0;
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

/// Separate all channels from a struct image into individual planes while tracking uniform channels.
pub fn splitChannelsWithUniform(comptime T: type, image: Image(T), allocator: std.mem.Allocator) !struct {
    channels: [Image(T).channels()][]FieldTypeOf(T),
    uniforms: [Image(T).channels()]?FieldTypeOf(T),
} {
    const num_channels = comptime Image(T).channels();
    const fields = std.meta.fields(T);
    const FieldType = FieldTypeOf(T);
    const plane_size = image.rows * image.cols;

    var channels: [num_channels][]FieldType = undefined;
    var has_value: [num_channels]bool = @splat(false);
    var is_uniform: [num_channels]bool = @splat(true);
    var uniform_values: [num_channels]FieldType = undefined;

    // Allocate each channel with proper error handling
    var allocated_count: u32 = 0;
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
    var idx: u32 = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const pixel = image.at(r, c).*;
            inline for (fields, 0..) |field, i| {
                const value: FieldType = @field(pixel, field.name);
                channels[i][idx] = value;

                if (!has_value[i]) {
                    uniform_values[i] = value;
                    has_value[i] = true;
                } else if (is_uniform[i] and value != uniform_values[i]) {
                    is_uniform[i] = false;
                }
            }
            idx += 1;
        }
    }

    var uniforms: [num_channels]?FieldType = undefined;
    inline for (&uniforms, has_value, is_uniform, uniform_values) |*slot, have, uni, value| {
        slot.* = if (have and uni) value else null;
    }

    return .{
        .channels = channels,
        .uniforms = uniforms,
    };
}

/// Separate all channels from a struct image into individual planes.
/// Allocates and fills channel planes for all fields.
/// The caller is responsible for freeing the returned slices.
pub fn splitChannels(comptime T: type, image: Image(T), allocator: std.mem.Allocator) ![Image(T).channels()][]FieldTypeOf(T) {
    return (try splitChannelsWithUniform(T, image, allocator)).channels;
}

/// Combine channels back into struct image.
pub fn mergeChannels(comptime T: type, channels: [Image(T).channels()][]const FieldTypeOf(T), out: Image(T)) void {
    const fields = std.meta.fields(T);

    var idx: u32 = 0;
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
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
) void {
    const s = 256;
    const sf: f32 = s;

    // Calculate scaling ratios
    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    // Process each output pixel
    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y_i = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = @as(i32, @intFromFloat((src_y_f - @floor(src_y_f)) * sf));

        const y0 = resolveIndex(src_y_i, @intCast(src_rows), .mirror).?;
        const y1 = resolveIndex(src_y_i + 1, @intCast(src_rows), .mirror).?;

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x_i = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = @as(i32, @intFromFloat((src_x_f - @floor(src_x_f)) * sf));

            const x0 = resolveIndex(src_x_i, @intCast(src_cols), .mirror).?;
            const x1 = resolveIndex(src_x_i + 1, @intCast(src_cols), .mirror).?;

            // Get the 4 neighboring pixels
            const tl = @as(i32, src[y0 * src_cols + x0]);
            const tr = @as(i32, src[y0 * src_cols + x1]);
            const bl = @as(i32, src[y1 * src_cols + x0]);
            const br = @as(i32, src[y1 * src_cols + x1]);

            // Bilinear interpolation using integer arithmetic
            const top = tl * (s - @as(i32, @intCast(fx))) + tr * @as(i32, @intCast(fx));
            const bottom = bl * (s - @as(i32, @intCast(fx))) + br * @as(i32, @intCast(fx));
            const result = @divTrunc(top * (s - @as(i32, @intCast(fy))) + bottom * @as(i32, @intCast(fy)), s * s);

            dst[r * dst_cols + c] = meta.clamp(u8, result);
        }
    }
}

/// Optimized nearest neighbor resize for u8 planes.
pub fn resizePlaneNearestU8(
    src: []const u8,
    dst: []u8,
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @max(0, @min(src_rows - 1, @as(u32, @intFromFloat(@round(src_y_f)))));

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @max(0, @min(src_cols - 1, @as(u32, @intFromFloat(@round(src_x_f)))));
            dst[r * dst_cols + c] = src[@as(usize, src_y) * src_cols + src_x];
        }
    }
}

/// Optimized bicubic resize for u8 planes using integer arithmetic.
pub fn resizePlaneBicubicU8(
    src: []const u8,
    dst: []u8,
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
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

    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = @as(i32, @intFromFloat((src_y_f - @floor(src_y_f)) * SCALE));

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = @as(i32, @intFromFloat((src_x_f - @floor(src_x_f)) * SCALE));

            var sum: i32 = 0;
            var weight_sum: i32 = 0;

            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                const pixel_y = resolveIndex(y_idx, @intCast(src_rows), .mirror).?;

                const wy = cubicKernel(@as(i32, @intCast(ky)) * SCALE - SCALE - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    const pixel_x = resolveIndex(x_idx, @intCast(src_cols), .mirror).?;

                    const wx = cubicKernel(@as(i32, @intCast(kx)) * SCALE - SCALE - fx);
                    const w = @divTrunc(wx * wy, SCALE);

                    const pixel_val = @as(i32, src[pixel_y * src_cols + pixel_x]);
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
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
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

    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = @as(i32, @intFromFloat((src_y_f - @floor(src_y_f)) * SCALE));

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = @as(i32, @intFromFloat((src_x_f - @floor(src_x_f)) * SCALE));

            var sum: i32 = 0;
            var weight_sum: i32 = 0;

            // 4x4 kernel
            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                const pixel_y = resolveIndex(y_idx, @intCast(src_rows), .mirror).?;

                const wy = catmullRomKernel(@as(i32, @intCast(ky)) * SCALE - SCALE - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    const pixel_x = resolveIndex(x_idx, @intCast(src_cols), .mirror).?;

                    const wx = catmullRomKernel(@as(i32, @intCast(kx)) * SCALE - SCALE - fx);
                    const w = @divTrunc(wx * wy, SCALE);

                    const pixel_val = @as(i32, src[pixel_y * src_cols + pixel_x]);
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

/// Optimized Mitchell-Netravali resize for u8 planes using integer arithmetic.
pub fn resizePlaneMitchellU8(
    src: []const u8,
    dst: []u8,
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
) void {
    const s = 256;
    // Mitchell-Netravali kernel function (b=1/3, c=1/3)
    const mitchellKernel = struct {
        fn eval(t: i32) i32 {
            const at: i64 = @intCast(@abs(t));
            const s2 = s * s;
            const s3 = s2 * s;

            if (at < s) {
                const at2 = at * at;
                const at3 = at2 * at;
                return @intCast(@divTrunc(21 * at3 - 36 * at2 * s + 16 * s3, 18 * s2));
            } else if (at < 2 * s) {
                const at2 = at * at;
                const at3 = at2 * at;
                return @intCast(@divTrunc(-7 * at3 + 36 * at2 * s - 60 * at * s2 + 32 * s3, 18 * s2));
            }
            return 0;
        }
    }.eval;

    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = @as(i32, @intFromFloat((src_y_f - @floor(src_y_f)) * s));

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = @as(i32, @intFromFloat((src_x_f - @floor(src_x_f)) * s));

            var sum: i32 = 0;
            var weight_sum: i32 = 0;

            // 4x4 kernel
            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                const pixel_y = resolveIndex(y_idx, @intCast(src_rows), .mirror).?;
                const wy = mitchellKernel(@as(i32, @intCast(ky)) * s - s - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    const pixel_x = resolveIndex(x_idx, @intCast(src_cols), .mirror).?;
                    const wx = mitchellKernel(@as(i32, @intCast(kx)) * s - s - fx);
                    const w = @divTrunc(wx * wy, s);

                    const pixel_val = @as(i32, src[pixel_y * src_cols + pixel_x]);
                    sum += pixel_val * w;
                    weight_sum += w;
                }
            }

            const result = if (weight_sum != 0) @divTrunc(sum, weight_sum) else 0;
            dst[r * dst_cols + c] = meta.clamp(u8, result);
        }
    }
}

/// Optimized Lanczos3 resize for u8 planes using float arithmetic for kernel.
/// Although it uses float for the weights (due to sin), it processes planes efficiently.
pub fn resizePlaneLanczosU8(
    src: []const u8,
    dst: []u8,
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
) void {
    const lanczosKernel = struct {
        fn eval(x: f32) f32 {
            if (x == 0) return 1.0;
            const a = 3.0;
            if (@abs(x) >= a) return 0.0;
            const pi_x = std.math.pi * x;
            return (a * @sin(pi_x) * @sin(pi_x / a)) / (pi_x * pi_x);
        }
    }.eval;

    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = src_y_f - @floor(src_y_f);

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = src_x_f - @floor(src_x_f);

            var sum: f32 = 0;
            var weight_sum: f32 = 0;

            // 6x6 kernel for Lanczos3
            for (0..6) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 2;
                const pixel_y = resolveIndex(y_idx, @intCast(src_rows), .mirror).?;
                const wy = lanczosKernel(@as(f32, @floatFromInt(@as(isize, @intCast(ky)) - 2)) - fy);

                for (0..6) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 2;
                    const pixel_x = resolveIndex(x_idx, @intCast(src_cols), .mirror).?;
                    const wx = lanczosKernel(@as(f32, @floatFromInt(@as(isize, @intCast(kx)) - 2)) - fx);
                    const w = wx * wy;

                    sum += @as(f32, @floatFromInt(src[pixel_y * src_cols + pixel_x])) * w;
                    weight_sum += w;
                }
            }

            const result = if (weight_sum != 0) sum / weight_sum else 0;
            dst[r * dst_cols + c] = meta.clamp(u8, result);
        }
    }
}

/// Generic f32 plane resize with SIMD optimization.
pub fn resizePlaneF32(
    src: []const f32,
    dst: []f32,
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
    method: enum { nearest, bilinear, bicubic },
) void {
    switch (method) {
        .nearest => {
            const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
            const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

            for (0..dst_rows) |r| {
                const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
                const src_y = @max(0, @min(src_rows - 1, @as(u32, @intFromFloat(@round(src_y_f)))));

                for (0..dst_cols) |c| {
                    const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
                    const src_x = @max(0, @min(src_cols - 1, @as(u32, @intFromFloat(@round(src_x_f)))));
                    dst[r * dst_cols + c] = src[@as(usize, src_y) * src_cols + src_x];
                }
            }
        },
        .bilinear => {
            const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
            const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

            for (0..dst_rows) |r| {
                const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
                const src_y = @as(u32, @intFromFloat(@floor(src_y_f)));
                const src_y_next = resolveIndex(@intCast(src_y + 1), @intCast(src_rows), .mirror).?;
                const fy = src_y_f - @floor(src_y_f);

                for (0..dst_cols) |c| {
                    const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
                    const src_x = @as(u32, @intFromFloat(@floor(src_x_f)));
                    const src_x_next = resolveIndex(@intCast(src_x + 1), @intCast(src_cols), .mirror).?;
                    const fx = src_x_f - @floor(src_x_f);

                    const tl = src[@as(usize, src_y) * src_cols + src_x];
                    const tr = src[@as(usize, src_y) * src_cols + src_x_next];
                    const bl = src[@as(usize, src_y_next) * src_cols + src_x];
                    const br = src[@as(usize, src_y_next) * src_cols + src_x_next];

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
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
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

    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (0..dst_rows) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @as(isize, @intFromFloat(@floor(src_y_f)));
        const fy = src_y_f - @floor(src_y_f);

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @as(isize, @intFromFloat(@floor(src_x_f)));
            const fx = src_x_f - @floor(src_x_f);

            var sum: f32 = 0;
            var weight_sum: f32 = 0;

            for (0..4) |ky| {
                const y_idx = src_y + @as(isize, @intCast(ky)) - 1;
                const pixel_y = resolveIndex(y_idx, @intCast(src_rows), .mirror).?;

                const wy = cubicKernel(@as(f32, @floatFromInt(@as(isize, @intCast(ky)) - 1)) - fy);

                for (0..4) |kx| {
                    const x_idx = src_x + @as(isize, @intCast(kx)) - 1;
                    const pixel_x = resolveIndex(x_idx, @intCast(src_cols), .mirror).?;

                    const wx = cubicKernel(@as(f32, @floatFromInt(@as(isize, @intCast(kx)) - 1)) - fx);
                    const w = wx * wy;

                    sum += src[pixel_y * src_cols + pixel_x] * w;
                    weight_sum += w;
                }
            }

            dst[r * dst_cols + c] = if (weight_sum != 0) sum / weight_sum else 0;
        }
    }
}

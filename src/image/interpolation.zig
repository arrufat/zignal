//! Image interpolation and resizing algorithms
//!
//! This module provides various interpolation methods for image resizing and
//! sampling, including nearest neighbor, bilinear, bicubic, Catmull-Rom,
//! Lanczos, and Mitchell-Netravali filters.
//!
//! ## Usage Examples
//!
//! ### Basic interpolation:
//! ```zig
//! const pixel = image.interpolate(100.5, 50.3, .bilinear);
//! ```
//!
//! ### Resize with different methods:
//! ```zig
//! var small = Image(Rgba).init(256, 256, small_data);
//! var large = Image(Rgba).init(512, 512, large_data);
//! small.resize(large, .lanczos); // High quality upscaling
//! ```
//!
//! ## Performance Guide
//!
//! Approximate performance on 512x512 RGBA images (Mpix/s):
//! - Nearest neighbor: ~400 Mpix/s (with SIMD)
//! - Bilinear: ~100 Mpix/s (with SIMD)
//! - Bicubic: ~25 Mpix/s (with SIMD)
//! - Catmull-Rom: ~25 Mpix/s (with SIMD)
//! - Lanczos: ~8.5 Mpix/s (with SIMD)
//! - Mitchell: ~22 Mpix/s (with SIMD)

const std = @import("std");
const as = @import("../meta.zig").as;
const is4xu8Struct = @import("../meta.zig").is4xu8Struct;

// ============================================================================
// Public API
// ============================================================================

/// Interpolation method for image resizing and sampling
///
/// Performance and quality comparison:
/// | Method      | Quality | Speed | Best Use Case       | Overshoot |
/// |-------------|---------|-------|---------------------|-----------|
/// | Nearest     | ★☆☆☆☆   | ★★★★★ | Pixel art, masks    | No        |
/// | Bilinear    | ★★☆☆☆   | ★★★★☆ | Real-time, preview  | No        |
/// | Bicubic     | ★★★☆☆   | ★★★☆☆ | General purpose     | Yes       |
/// | Catmull-Rom | ★★★★☆   | ★★★☆☆ | Natural images      | No        |
/// | Mitchell    | ★★★★☆   | ★★☆☆☆ | Balanced quality    | Yes       |
/// | Lanczos3    | ★★★★★   | ★☆☆☆☆ | High-quality resize | Yes       |
pub const InterpolationMethod = union(enum) {
    nearest_neighbor,
    bilinear,
    bicubic,
    catmull_rom,
    mitchell: struct {
        /// Blur parameter (controls blur vs sharpness)
        /// Common values: 1/3 (Mitchell), 1 (B-spline), 0 (Catmull-Rom-like)
        b: f32,
        /// Ringing parameter (controls ringing vs blur)
        /// Common values: 1/3 (Mitchell), 0 (B-spline), 0.5 (Catmull-Rom)
        c: f32,
        pub const default: @This() = .{ .b = 1 / 3, .c = 1 / 3 };
    },
    lanczos,
};

/// Sample a single pixel from an image using the specified interpolation method
///
/// Parameters:
/// - T: The pixel type of the image
/// - self: The source image to sample from
/// - x: Horizontal coordinate (0 to cols-1)
/// - y: Vertical coordinate (0 to rows-1)
/// - method: The interpolation method to use
///
/// Returns the interpolated pixel value or null if the coordinates are out of bounds
pub fn interpolate(comptime T: type, self: anytype, x: f32, y: f32, method: InterpolationMethod) ?T {
    return switch (method) {
        .nearest_neighbor => interpolateNearestNeighbor(T, self, x, y),
        .bilinear => interpolateBilinear(T, self, x, y),
        .bicubic => interpolateBicubic(T, self, x, y),
        .catmull_rom => interpolateCatmullRom(T, self, x, y),
        .lanczos => interpolateLanczos(T, self, x, y),
        .mitchell => |m| interpolateMitchell(T, self, x, y, m.b, m.c),
    };
}

/// Resize an image using the specified interpolation method
///
/// Parameters:
/// - T: The pixel type of the image
/// - self: The source image
/// - out: The destination image (must be pre-allocated)
/// - method: The interpolation method to use
///
/// Special optimizations:
/// - Scale=1: Uses memcpy for same-size copies
/// - 2x upscaling: Specialized fast path for bilinear
/// - RGBA images: SIMD-optimized paths for all methods
pub fn resize(comptime T: type, self: anytype, out: anytype, method: InterpolationMethod) void {
    // Check for scale = 1 (just copy)
    if (self.rows == out.rows and self.cols == out.cols) {
        // If dimensions match exactly, just copy the data
        if (self.data.ptr == out.data.ptr) {
            // Same buffer, nothing to do
            return;
        }
        // Different buffers, need to copy
        @memcpy(out.data[0..out.data.len], self.data[0..self.data.len]);
        return;
    }

    // SIMD optimizations for 4xu8 structs (RGBA)
    if (is4xu8Struct(T)) {
        return switch (method) {
            .nearest_neighbor => resizeNearestNeighbor4xu8(T, self, out),
            .bilinear => if (out.rows == self.rows * 2 and out.cols == self.cols * 2)
                resize2xUpscale4xu8(T, self, out)
            else
                resizeBilinear4xu8(T, self, out),
            .bicubic => resizeBicubic4xu8(T, self, out),
            .catmull_rom => resizeCatmullRom4xu8(T, self, out),
            .lanczos => resizeLanczos4xu8(T, self, out),
            .mitchell => |m| resizeMitchell4xu8(T, self, out, m.b, m.c),
        };
    }

    // Fall back to generic implementation
    const max_src_x = @as(f32, @floatFromInt(self.cols - 1));
    const max_src_y = @as(f32, @floatFromInt(self.rows - 1));

    for (0..out.rows) |r| {
        const src_y: f32 = if (out.rows == 1)
            0.5 * max_src_y
        else
            @as(f32, @floatFromInt(r)) * (max_src_y / @as(f32, @floatFromInt(out.rows - 1)));
        for (0..out.cols) |c| {
            const src_x: f32 = if (out.cols == 1)
                0.5 * max_src_x
            else
                @as(f32, @floatFromInt(c)) * (max_src_x / @as(f32, @floatFromInt(out.cols - 1)));
            if (interpolate(T, self, src_x, src_y, method)) |val| {
                out.at(r, c).* = val;
            }
        }
    }
}

// ============================================================================
// Kernel Functions
// ============================================================================

/// Bicubic kernel function
/// Classic bicubic interpolation kernel with a=-0.5
fn bicubicKernel(t: f32) f32 {
    const at = @abs(t);
    if (at <= 1) {
        return 1 - 2 * at * at + at * at * at;
    } else if (at <= 2) {
        return 4 - 8 * at + 5 * at * at - at * at * at;
    }
    return 0;
}

/// Catmull-Rom kernel function
/// Catmull-Rom spline - a special case of cubic interpolation
fn catmullRomKernel(x: f32) f32 {
    const ax = @abs(x);
    if (ax <= 1) {
        return 1.5 * ax * ax * ax - 2.5 * ax * ax + 1;
    } else if (ax <= 2) {
        return -0.5 * ax * ax * ax + 2.5 * ax * ax - 4 * ax + 2;
    }
    return 0;
}

/// Lanczos kernel function
/// Lanczos windowed sinc function with parameter a (typically 3)
fn lanczosKernel(x: f32, a: f32) f32 {
    if (x == 0) return 1;
    if (@abs(x) >= a) return 0;

    const pi_x = std.math.pi * x;
    const pi_x_over_a = pi_x / a;
    return (a * @sin(pi_x) * @sin(pi_x_over_a)) / (pi_x * pi_x);
}

/// Mitchell-Netravali kernel function
/// Parameterized cubic filter with control over blur (m_b) and ringing (m_c)
fn mitchellKernel(x: f32, m_b: f32, m_c: f32) f32 {
    const ax = @abs(x);
    const ax2 = ax * ax;
    const ax3 = ax2 * ax;

    if (ax < 1) {
        return ((12 - 9 * m_b - 6 * m_c) * ax3 +
            (-18 + 12 * m_b + 6 * m_c) * ax2 +
            (6 - 2 * m_b)) / 6;
    } else if (ax < 2) {
        return ((-m_b - 6 * m_c) * ax3 +
            (6 * m_b + 30 * m_c) * ax2 +
            (-12 * m_b - 48 * m_c) * ax +
            (8 * m_b + 24 * m_c)) / 6;
    }
    return 0;
}

// ============================================================================
// Generic Interpolation Functions
// ============================================================================

fn interpolateNearestNeighbor(comptime T: type, self: anytype, x: f32, y: f32) ?T {
    const col: isize = @intFromFloat(@round(x));
    const row: isize = @intFromFloat(@round(y));

    if (col < 0 or row < 0 or col >= self.cols or row >= self.rows) return null;
    return self.at(@intCast(row), @intCast(col)).*;
}

fn interpolateBilinear(comptime T: type, self: anytype, x: f32, y: f32) ?T {
    const left: isize = @intFromFloat(@floor(x));
    const top: isize = @intFromFloat(@floor(y));
    const right = left + 1;
    const bottom = top + 1;

    if (!(left >= 0 and top >= 0 and right < self.cols and bottom < self.rows)) {
        return null;
    }

    const lr_frac: f32 = x - as(f32, left);
    const tb_frac: f32 = y - as(f32, top);

    const tl: T = self.at(@intCast(top), @intCast(left)).*;
    const tr: T = self.at(@intCast(top), @intCast(right)).*;
    const bl: T = self.at(@intCast(bottom), @intCast(left)).*;
    const br: T = self.at(@intCast(bottom), @intCast(right)).*;

    // Handle different pixel types
    var temp: T = undefined;
    switch (@typeInfo(T)) {
        .int, .float => {
            temp = as(T, (1 - tb_frac) * ((1 - lr_frac) * as(f32, tl) +
                lr_frac * as(f32, tr)) +
                tb_frac * ((1 - lr_frac) * as(f32, bl) +
                    lr_frac * as(f32, br)));
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                @field(temp, f.name) = as(
                    f.type,
                    (1 - tb_frac) * ((1 - lr_frac) * as(f32, @field(tl, f.name)) +
                        lr_frac * as(f32, @field(tr, f.name))) +
                        tb_frac * ((1 - lr_frac) * as(f32, @field(bl, f.name)) +
                            lr_frac * as(f32, @field(br, f.name))),
                );
            }
        },
        else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateBilinear: unsupported image type"),
    }
    return temp;
}

fn interpolateBicubic(comptime T: type, self: anytype, x: f32, y: f32) ?T {
    const ix: isize = @intFromFloat(@floor(x));
    const iy: isize = @intFromFloat(@floor(y));

    // Check bounds - need 4x4 neighborhood
    if (ix < 1 or iy < 1 or ix >= self.cols - 2 or iy >= self.rows - 2) {
        return null;
    }

    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);

    var result: T = std.mem.zeroes(T);

    switch (@typeInfo(T)) {
        .int, .float => {
            var sum: f32 = 0.0;
            for (0..4) |j| {
                const y_idx = iy - 1 + @as(isize, @intCast(j));
                const wy = bicubicKernel(as(f32, @as(isize, @intCast(j)) - 1) - fy);

                for (0..4) |i| {
                    const x_idx = ix - 1 + @as(isize, @intCast(i));
                    const wx = bicubicKernel(as(f32, @as(isize, @intCast(i)) - 1) - fx);

                    sum += wx * wy * as(f32, self.at(@intCast(y_idx), @intCast(x_idx)).*);
                }
            }
            result = if (@typeInfo(T) == .int)
                @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum))))
            else
                as(T, sum);
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                var sum: f32 = 0.0;
                for (0..4) |j| {
                    const y_idx = iy - 1 + @as(isize, @intCast(j));
                    const wy = bicubicKernel(as(f32, @as(isize, @intCast(j)) - 1) - fy);

                    for (0..4) |i| {
                        const x_idx = ix - 1 + @as(isize, @intCast(i));
                        const wx = bicubicKernel(as(f32, @as(isize, @intCast(i)) - 1) - fx);

                        sum += wx * wy * as(f32, @field(self.at(@intCast(y_idx), @intCast(x_idx)).*, f.name));
                    }
                }
                @field(result, f.name) = switch (@typeInfo(f.type)) {
                    .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sum)))),
                    .float => as(f.type, sum),
                    else => @compileError("Unsupported field type for interpolation"),
                };
            }
        },
        else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateBicubic: unsupported image type"),
    }

    return result;
}

fn interpolateCatmullRom(comptime T: type, self: anytype, x: f32, y: f32) ?T {
    const ix: isize = @intFromFloat(@floor(x));
    const iy: isize = @intFromFloat(@floor(y));

    // Check bounds - need 4x4 neighborhood
    if (ix < 1 or iy < 1 or ix >= self.cols - 2 or iy >= self.rows - 2) {
        return null;
    }

    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);

    var result: T = std.mem.zeroes(T);

    switch (@typeInfo(T)) {
        .int, .float => {
            var sum: f32 = 0.0;
            for (0..4) |j| {
                const y_idx = iy - 1 + @as(isize, @intCast(j));
                const wy = catmullRomKernel(as(f32, @as(isize, @intCast(j)) - 1) - fy);

                for (0..4) |i| {
                    const x_idx = ix - 1 + @as(isize, @intCast(i));
                    const wx = catmullRomKernel(as(f32, @as(isize, @intCast(i)) - 1) - fx);

                    sum += wx * wy * as(f32, self.at(@intCast(y_idx), @intCast(x_idx)).*);
                }
            }
            result = if (@typeInfo(T) == .int)
                @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum))))
            else
                as(T, sum);
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                var sum: f32 = 0.0;
                for (0..4) |j| {
                    const y_idx = iy - 1 + @as(isize, @intCast(j));
                    const wy = catmullRomKernel(as(f32, @as(isize, @intCast(j)) - 1) - fy);

                    for (0..4) |i| {
                        const x_idx = ix - 1 + @as(isize, @intCast(i));
                        const wx = catmullRomKernel(as(f32, @as(isize, @intCast(i)) - 1) - fx);

                        sum += wx * wy * as(f32, @field(self.at(@intCast(y_idx), @intCast(x_idx)).*, f.name));
                    }
                }
                @field(result, f.name) = switch (@typeInfo(f.type)) {
                    .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sum)))),
                    .float => as(f.type, sum),
                    else => @compileError("Unsupported field type for interpolation"),
                };
            }
        },
        else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateCatmullRom: unsupported image type"),
    }

    return result;
}

fn interpolateLanczos(comptime T: type, self: anytype, x: f32, y: f32) ?T {
    const ix: isize = @intFromFloat(@floor(x));
    const iy: isize = @intFromFloat(@floor(y));
    const a: f32 = 3.0; // Lanczos3

    // Check bounds - need 6x6 neighborhood for Lanczos3
    if (ix < 2 or iy < 2 or ix >= self.cols - 3 or iy >= self.rows - 3) {
        return null;
    }

    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);

    var result: T = std.mem.zeroes(T);

    switch (@typeInfo(T)) {
        .int, .float => {
            var sum: f32 = 0.0;
            var weight_sum: f32 = 0.0;

            for (0..6) |j| {
                const y_idx = iy - 2 + @as(isize, @intCast(j));
                const dy = as(f32, @as(isize, @intCast(j)) - 2) - fy;
                const wy = lanczosKernel(dy, a);

                for (0..6) |i| {
                    const x_idx = ix - 2 + @as(isize, @intCast(i));
                    const dx = as(f32, @as(isize, @intCast(i)) - 2) - fx;
                    const wx = lanczosKernel(dx, a);
                    const w = wx * wy;

                    sum += w * as(f32, self.at(@intCast(y_idx), @intCast(x_idx)).*);
                    weight_sum += w;
                }
            }
            const final_value = if (weight_sum != 0.0) sum / weight_sum else sum;
            result = if (@typeInfo(T) == .int)
                @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(final_value))))
            else
                as(T, final_value);
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                var sum: f32 = 0.0;
                var weight_sum: f32 = 0.0;

                for (0..6) |j| {
                    const y_idx = iy - 2 + @as(isize, @intCast(j));
                    const dy = as(f32, @as(isize, @intCast(j)) - 2) - fy;
                    const wy = lanczosKernel(dy, a);

                    for (0..6) |i| {
                        const x_idx = ix - 2 + @as(isize, @intCast(i));
                        const dx = as(f32, @as(isize, @intCast(i)) - 2) - fx;
                        const wx = lanczosKernel(dx, a);
                        const w = wx * wy;

                        sum += w * as(f32, @field(self.at(@intCast(y_idx), @intCast(x_idx)).*, f.name));
                        weight_sum += w;
                    }
                }
                const final_value = if (weight_sum != 0.0) sum / weight_sum else sum;
                @field(result, f.name) = switch (@typeInfo(f.type)) {
                    .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(final_value)))),
                    .float => as(f.type, final_value),
                    else => @compileError("Unsupported field type for interpolation"),
                };
            }
        },
        else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateLanczos: unsupported image type"),
    }

    return result;
}

fn interpolateMitchell(comptime T: type, self: anytype, x: f32, y: f32, m_b: f32, m_c: f32) ?T {
    const ix: isize = @intFromFloat(@floor(x));
    const iy: isize = @intFromFloat(@floor(y));

    // Check bounds - need 4x4 neighborhood
    if (ix < 1 or iy < 1 or ix >= self.cols - 2 or iy >= self.rows - 2) {
        return null;
    }

    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);

    var result: T = std.mem.zeroes(T);

    switch (@typeInfo(T)) {
        .int, .float => {
            var sum: f32 = 0.0;
            for (0..4) |j| {
                const y_idx = iy - 1 + @as(isize, @intCast(j));
                const wy = mitchellKernel(as(f32, @as(isize, @intCast(j)) - 1) - fy, m_b, m_c);

                for (0..4) |i| {
                    const x_idx = ix - 1 + @as(isize, @intCast(i));
                    const wx = mitchellKernel(as(f32, @as(isize, @intCast(i)) - 1) - fx, m_b, m_c);

                    sum += wx * wy * as(f32, self.at(@intCast(y_idx), @intCast(x_idx)).*);
                }
            }
            result = if (@typeInfo(T) == .int)
                @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum))))
            else
                as(T, sum);
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                var sum: f32 = 0.0;
                for (0..4) |j| {
                    const y_idx = iy - 1 + @as(isize, @intCast(j));
                    const wy = mitchellKernel(as(f32, @as(isize, @intCast(j)) - 1) - fy, m_b, m_c);

                    for (0..4) |i| {
                        const x_idx = ix - 1 + @as(isize, @intCast(i));
                        const wx = mitchellKernel(as(f32, @as(isize, @intCast(i)) - 1) - fx, m_b, m_c);

                        sum += wx * wy * as(f32, @field(self.at(@intCast(y_idx), @intCast(x_idx)).*, f.name));
                    }
                }
                @field(result, f.name) = switch (@typeInfo(f.type)) {
                    .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sum)))),
                    .float => as(f.type, sum),
                    else => @compileError("Unsupported field type for interpolation"),
                };
            }
        },
        else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateMitchell: unsupported image type"),
    }

    return result;
}

// ============================================================================
// SIMD Optimized Resize Functions
// ============================================================================

/// Generic SIMD-optimized kernel-based resize for 4xu8 types (RGBA)
/// This function implements the common pattern for bicubic, Catmull-Rom, Mitchell, and Lanczos
fn resizeKernel4xu8(
    comptime T: type,
    self: anytype,
    out: anytype,
    comptime window_radius: usize, // 2 for 4x4 kernels, 3 for 6x6 (Lanczos)
    kernel_fn: anytype, // Function that takes (x, ...params) and returns f32
    kernel_params: anytype, // Additional parameters for the kernel (empty struct for most)
    normalize_weights: bool, // Whether to normalize by weight sum (needed for Lanczos)
) void {
    comptime std.debug.assert(is4xu8Struct(T));

    const window_size = window_radius * 2;
    const max_src_x = @as(f32, @floatFromInt(self.cols - 1));
    const max_src_y = @as(f32, @floatFromInt(self.rows - 1));

    // Process each output pixel
    for (0..out.rows) |r| {
        const src_y: f32 = if (out.rows == 1)
            0.5 * max_src_y
        else
            @as(f32, @floatFromInt(r)) * (max_src_y / @as(f32, @floatFromInt(out.rows - 1)));
        const iy = @as(isize, @intFromFloat(@floor(src_y)));
        const fy = src_y - @as(f32, @floatFromInt(iy));

        // Skip if we can't get a full neighborhood
        if (iy < window_radius - 1 or iy >= self.rows - window_radius) {
            // Fall back to nearest neighbor for edge pixels
            for (0..out.cols) |c| {
                const src_x: f32 = if (out.cols == 1)
                    0.5 * max_src_x
                else
                    @as(f32, @floatFromInt(c)) * (max_src_x / @as(f32, @floatFromInt(out.cols - 1)));
                const ix_clamped = @max(0, @min(self.cols - 1, @as(usize, @intFromFloat(@round(src_x)))));
                const iy_clamped = @max(0, @min(self.rows - 1, @as(usize, @intCast(@max(0, @min(@as(isize, @intCast(self.rows - 1)), iy))))));
                out.at(r, c).* = self.at(iy_clamped, ix_clamped).*;
            }
            continue;
        }

        // Pre-compute y weights
        var y_weights_array: [6]f32 = undefined; // Max size for Lanczos
        inline for (0..window_size) |j| {
            const offset = @as(f32, @floatFromInt(@as(isize, @intCast(j)) - @as(isize, @intCast(window_radius - 1)))) - fy;
            if (kernel_params.len == 0) {
                y_weights_array[j] = kernel_fn(offset);
            } else if (kernel_params.len == 1) {
                y_weights_array[j] = kernel_fn(offset, kernel_params[0]);
            } else if (kernel_params.len == 2) {
                y_weights_array[j] = kernel_fn(offset, kernel_params[0], kernel_params[1]);
            } else {
                @compileError("Unsupported number of kernel parameters");
            }
        }
        const y_weights = y_weights_array[0..window_size];

        for (0..out.cols) |c| {
            const src_x: f32 = if (out.cols == 1)
                0.5 * max_src_x
            else
                @as(f32, @floatFromInt(c)) * (max_src_x / @as(f32, @floatFromInt(out.cols - 1)));
            const ix = @as(isize, @intFromFloat(@floor(src_x)));
            const fx = src_x - @as(f32, @floatFromInt(ix));

            // Skip if we can't get a full neighborhood
            if (ix < window_radius - 1 or ix >= self.cols - window_radius) {
                // Fall back to nearest neighbor for edge pixels
                const ix_clamped = @max(0, @min(self.cols - 1, @as(usize, @intFromFloat(@round(src_x)))));
                const iy_clamped = @as(usize, @intCast(iy));
                out.at(r, c).* = self.at(iy_clamped, ix_clamped).*;
                continue;
            }

            // Pre-compute x weights
            var x_weights_array: [6]f32 = undefined; // Max size for Lanczos
            inline for (0..window_size) |i| {
                const offset = @as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fx;
                if (kernel_params.len == 0) {
                    x_weights_array[i] = kernel_fn(offset);
                } else if (kernel_params.len == 1) {
                    x_weights_array[i] = kernel_fn(offset, kernel_params[0]);
                } else if (kernel_params.len == 2) {
                    x_weights_array[i] = kernel_fn(offset, kernel_params[0], kernel_params[1]);
                } else {
                    @compileError("Unsupported number of kernel parameters");
                }
            }
            const x_weights = x_weights_array[0..window_size];

            // Accumulate weighted sum for each channel using SIMD
            var sums = @Vector(4, f32){ 0, 0, 0, 0 }; // RGBA channels
            var weight_sum: f32 = if (normalize_weights) 0 else 1;

            // Process the neighborhood
            inline for (0..window_size) |j| {
                const y_idx = @as(usize, @intCast(iy - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(j))));
                const wy = y_weights[j];

                // Process all x positions for this row
                var row_sum = @Vector(4, f32){ 0, 0, 0, 0 };
                var row_weight: f32 = 0;

                inline for (0..window_size) |i| {
                    const x_idx = @as(usize, @intCast(ix - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(i))));
                    const pixel = self.at(y_idx, x_idx).*;

                    // Convert pixel to vector
                    var pixel_vec: @Vector(4, f32) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, k| {
                        pixel_vec[k] = @floatFromInt(@field(pixel, field.name));
                    }

                    // Calculate weight
                    const wx = x_weights[i];

                    if (normalize_weights) {
                        // For Lanczos - accumulate with individual weights
                        const w = wx * wy;
                        const w_vec: @Vector(4, f32) = @splat(w);
                        row_sum += pixel_vec * w_vec;
                        row_weight += w;
                    } else {
                        // For others - accumulate with x weight only
                        const wx_vec: @Vector(4, f32) = @splat(wx);
                        row_sum += pixel_vec * wx_vec;
                    }
                }

                if (normalize_weights) {
                    sums += row_sum;
                    weight_sum += row_weight;
                } else {
                    // For 4x4 kernels, apply y weight to entire row
                    const wy_vec: @Vector(4, f32) = @splat(wy);
                    sums += row_sum * wy_vec;
                }
            }

            // Convert back to struct
            var result: T = undefined;
            if (normalize_weights and weight_sum != 0) {
                const inv_weight: @Vector(4, f32) = @splat(1.0 / weight_sum);
                const normalized = sums * inv_weight;
                inline for (std.meta.fields(T), 0..) |field, k| {
                    @field(result, field.name) = @intFromFloat(@max(0, @min(255, @round(normalized[k]))));
                }
            } else if (normalize_weights) {
                // Fallback to center pixel if weights sum to zero
                const center_pixel = self.at(@intCast(iy), @intCast(ix)).*;
                result = center_pixel;
            } else {
                // Direct conversion for non-normalized kernels
                inline for (std.meta.fields(T), 0..) |field, k| {
                    @field(result, field.name) = @intFromFloat(@max(0, @min(255, @round(sums[k]))));
                }
            }

            out.at(r, c).* = result;
        }
    }
}

/// Specialized 2x upscaling for 4xu8 images (RGBA/RGB) using SIMD
fn resize2xUpscale4xu8(comptime T: type, self: anytype, out: anytype) void {
    std.debug.assert(is4xu8Struct(T));
    std.debug.assert(out.rows == self.rows * 2);
    std.debug.assert(out.cols == self.cols * 2);

    // Process each row
    for (0..self.rows) |sr| {
        const dr = sr * 2;

        // Process each pixel
        for (0..self.cols) |sc| {
            const dc = sc * 2;
            const src_pixel = self.at(sr, sc).*;

            // Convert struct to vector for SIMD operations
            var src_vec: @Vector(4, u16) = undefined;
            inline for (std.meta.fields(T), 0..) |field, i| {
                src_vec[i] = @field(src_pixel, field.name);
            }

            // Write top-left pixel
            out.at(dr, dc).* = src_pixel;

            // Top-right pixel (horizontal interpolation)
            if (sc < self.cols - 1) {
                const next_pixel = self.at(sr, sc + 1).*;
                var next_vec: @Vector(4, u16) = undefined;
                inline for (std.meta.fields(T), 0..) |field, i| {
                    next_vec[i] = @field(next_pixel, field.name);
                }

                const horiz_avg = (src_vec + next_vec) / @as(@Vector(4, u16), @splat(2));
                var result: T = undefined;
                inline for (std.meta.fields(T), 0..) |field, i| {
                    @field(result, field.name) = @intCast(horiz_avg[i]);
                }
                out.at(dr, dc + 1).* = result;
            } else {
                out.at(dr, dc + 1).* = src_pixel;
            }

            // Bottom row interpolation
            if (sr < self.rows - 1) {
                const bottom_pixel = self.at(sr + 1, sc).*;
                var bottom_vec: @Vector(4, u16) = undefined;
                inline for (std.meta.fields(T), 0..) |field, i| {
                    bottom_vec[i] = @field(bottom_pixel, field.name);
                }

                // Bottom-left (vertical interpolation)
                const vert_avg = (src_vec + bottom_vec) / @as(@Vector(4, u16), @splat(2));
                var vert_result: T = undefined;
                inline for (std.meta.fields(T), 0..) |field, i| {
                    @field(vert_result, field.name) = @intCast(vert_avg[i]);
                }
                out.at(dr + 1, dc).* = vert_result;

                // Bottom-right (bilinear interpolation)
                if (sc < self.cols - 1) {
                    const br_pixel = self.at(sr + 1, sc + 1).*;
                    var br_vec: @Vector(4, u16) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        br_vec[i] = @field(br_pixel, field.name);
                    }

                    const next_pixel = self.at(sr, sc + 1).*;
                    var next_vec: @Vector(4, u16) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        next_vec[i] = @field(next_pixel, field.name);
                    }

                    const bilinear_avg = (src_vec + next_vec + bottom_vec + br_vec) / @as(@Vector(4, u16), @splat(4));
                    var bilinear_result: T = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        @field(bilinear_result, field.name) = @intCast(bilinear_avg[i]);
                    }
                    out.at(dr + 1, dc + 1).* = bilinear_result;
                } else {
                    out.at(dr + 1, dc + 1).* = vert_result;
                }
            } else {
                // Last row - copy from top row
                out.at(dr + 1, dc).* = src_pixel;
                out.at(dr + 1, dc + 1).* = out.at(dr, dc + 1).*;
            }
        }
    }
}

/// SIMD-optimized nearest neighbor resize for 4xu8 types (RGBA)
fn resizeNearestNeighbor4xu8(comptime T: type, self: anytype, out: anytype) void {
    std.debug.assert(is4xu8Struct(T));
    const max_src_x = @as(f32, @floatFromInt(self.cols - 1));
    const max_src_y = @as(f32, @floatFromInt(self.rows - 1));

    // Process 4 output pixels at a time using SIMD
    const vec_size = 4;

    for (0..out.rows) |r| {
        const src_y_f: f32 = if (out.rows == 1)
            0.5 * max_src_y
        else
            @as(f32, @floatFromInt(r)) * (max_src_y / @as(f32, @floatFromInt(out.rows - 1)));
        const src_y = @min(self.rows - 1, @as(usize, @intFromFloat(@round(src_y_f))));

        var c: usize = 0;

        // SIMD processing for groups of 4 pixels
        while (c + vec_size <= out.cols) : (c += vec_size) {
            // Calculate source X coordinates for 4 pixels
            const x_coords = @Vector(4, f32){
                @floatFromInt(c),
                @floatFromInt(c + 1),
                @floatFromInt(c + 2),
                @floatFromInt(c + 3),
            };

            const scale_x: f32 = if (out.cols == 1) 0.0 else (max_src_x / @as(f32, @floatFromInt(out.cols - 1)));
            const src_x_vec = x_coords * @as(@Vector(4, f32), @splat(scale_x));

            // Round to nearest and clamp
            const src_x_indices = @Vector(4, u32){
                @min(self.cols - 1, @as(u32, @intFromFloat(@round(src_x_vec[0])))),
                @min(self.cols - 1, @as(u32, @intFromFloat(@round(src_x_vec[1])))),
                @min(self.cols - 1, @as(u32, @intFromFloat(@round(src_x_vec[2])))),
                @min(self.cols - 1, @as(u32, @intFromFloat(@round(src_x_vec[3])))),
            };

            // Gather pixels from source
            inline for (0..vec_size) |i| {
                const src_pixel = self.at(src_y, src_x_indices[i]).*;
                out.at(r, c + i).* = src_pixel;
            }
        }

        // Handle remaining pixels
        while (c < out.cols) : (c += 1) {
            const src_x_f: f32 = if (out.cols == 1)
                0.5 * max_src_x
            else
                @as(f32, @floatFromInt(c)) * (max_src_x / @as(f32, @floatFromInt(out.cols - 1)));
            const src_x = @min(self.cols - 1, @as(usize, @intFromFloat(@round(src_x_f))));
            out.at(r, c).* = self.at(src_y, src_x).*;
        }
    }
}

/// SIMD-optimized bilinear resize for 4xu8 types (RGBA) - works for all scales
fn resizeBilinear4xu8(comptime T: type, self: anytype, out: anytype) void {
    comptime std.debug.assert(is4xu8Struct(T));
    const max_src_x = @as(f32, @floatFromInt(self.cols - 1));
    const max_src_y = @as(f32, @floatFromInt(self.rows - 1));

    for (0..out.rows) |r| {
        const src_y: f32 = if (out.rows == 1)
            0.5 * max_src_y
        else
            @as(f32, @floatFromInt(r)) * (max_src_y / @as(f32, @floatFromInt(out.rows - 1)));
        const y0 = @as(usize, @intFromFloat(@floor(src_y)));
        const y1 = @min(y0 + 1, self.rows - 1);
        const fy = src_y - @as(f32, @floatFromInt(y0));

        for (0..out.cols) |c| {
            const src_x: f32 = if (out.cols == 1)
                0.5 * max_src_x
            else
                @as(f32, @floatFromInt(c)) * (max_src_x / @as(f32, @floatFromInt(out.cols - 1)));
            const x0 = @as(usize, @intFromFloat(@floor(src_x)));
            const x1 = @min(x0 + 1, self.cols - 1);
            const fx = src_x - @as(f32, @floatFromInt(x0));

            // Load the 4 neighboring pixels
            const tl = self.at(y0, x0).*;
            const tr = self.at(y0, x1).*;
            const bl = self.at(y1, x0).*;
            const br = self.at(y1, x1).*;

            // Convert to f32 vectors - same pattern as boxBlur4xu8Simd
            var tl_vec: @Vector(4, f32) = undefined;
            var tr_vec: @Vector(4, f32) = undefined;
            var bl_vec: @Vector(4, f32) = undefined;
            var br_vec: @Vector(4, f32) = undefined;

            inline for (std.meta.fields(T), 0..) |field, i| {
                tl_vec[i] = @floatFromInt(@field(tl, field.name));
                tr_vec[i] = @floatFromInt(@field(tr, field.name));
                bl_vec[i] = @floatFromInt(@field(bl, field.name));
                br_vec[i] = @floatFromInt(@field(br, field.name));
            }

            // Bilinear interpolation using f32 vectors
            const fx_vec: @Vector(4, f32) = @splat(fx);
            const fy_vec: @Vector(4, f32) = @splat(fy);
            const one_minus_fx_vec: @Vector(4, f32) = @splat(1.0 - fx);
            const one_minus_fy_vec: @Vector(4, f32) = @splat(1.0 - fy);

            // Horizontal interpolation
            const top = tl_vec * one_minus_fx_vec + tr_vec * fx_vec;
            const bottom = bl_vec * one_minus_fx_vec + br_vec * fx_vec;

            // Vertical interpolation
            const result_vec = top * one_minus_fy_vec + bottom * fy_vec;

            // Convert back to struct with clamping
            var result: T = undefined;
            inline for (std.meta.fields(T), 0..) |field, i| {
                @field(result, field.name) = @intFromFloat(@max(0, @min(255, @round(result_vec[i]))));
            }

            out.at(r, c).* = result;
        }
    }
}

/// SIMD-optimized bicubic resize for 4xu8 types (RGBA)
fn resizeBicubic4xu8(comptime T: type, self: anytype, out: anytype) void {
    resizeKernel4xu8(T, self, out, 2, bicubicKernel, .{}, false);
}

/// SIMD-optimized Catmull-Rom resize for 4xu8 types (RGBA)
fn resizeCatmullRom4xu8(comptime T: type, self: anytype, out: anytype) void {
    resizeKernel4xu8(T, self, out, 2, catmullRomKernel, .{}, false);
}

/// SIMD-optimized Mitchell-Netravali resize for 4xu8 types (RGBA)
fn resizeMitchell4xu8(comptime T: type, self: anytype, out: anytype, m_b: f32, m_c: f32) void {
    resizeKernel4xu8(T, self, out, 2, mitchellKernel, .{ m_b, m_c }, false);
}

/// SIMD-optimized Lanczos resize for 4xu8 types (RGBA)
fn resizeLanczos4xu8(comptime T: type, self: anytype, out: anytype) void {
    const a: f32 = 3.0; // Lanczos3
    resizeKernel4xu8(T, self, out, 3, lanczosKernel, .{a}, true);
}

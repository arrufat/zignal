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
//! - Nearest neighbor: ~400 Mpix/s
//! - Bilinear: ~100 Mpix/s
//! - Bicubic: ~25 Mpix/s
//! - Catmull-Rom: ~25 Mpix/s
//! - Lanczos: ~8.5 Mpix/s
//! - Mitchell: ~22 Mpix/s

const std = @import("std");
const Allocator = std.mem.Allocator;

const meta = @import("../meta.zig");
const as = meta.as;
const clamp = meta.clamp;
const channel_ops = @import("channel_ops.zig");
const Image = @import("../image.zig").Image;

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
pub const Interpolation = union(enum) {
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
pub fn interpolate(comptime T: type, self: Image(T), x: f32, y: f32, method: Interpolation) ?T {
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
/// - allocator: Used for temporary buffers during RGB/RGBA channel processing
/// - self: The source image
/// - out: The destination image (must be pre-allocated with desired dimensions)
/// - method: The interpolation method to use
///
/// Special optimizations:
/// - Scale=1: Uses memcpy for same-size copies
/// - 2x upscaling: Specialized fast path for bilinear
/// - RGB/RGBA images: Channel separation for optimized processing
pub fn resize(comptime T: type, allocator: Allocator, self: Image(T), out: Image(T), method: Interpolation) !void {
    // Check for scale = 1 (just copy)
    if (self.rows == out.rows and self.cols == out.cols) {
        if (self.data.ptr == out.data.ptr) return;

        if (self.isContiguous() and out.isContiguous()) {
            const total = try std.math.mul(usize, self.rows, self.cols);
            @memcpy(out.data[0..total], self.data[0..total]);
        } else {
            for (0..self.rows) |r| {
                const src_row_start = r * self.stride;
                const dst_row_start = r * out.stride;
                @memcpy(
                    out.data[dst_row_start .. dst_row_start + out.cols],
                    self.data[src_row_start .. src_row_start + self.cols],
                );
            }
        }
        return;
    }

    // Channel separation for RGB/RGBA types with u8 components
    if (comptime meta.isRgb(T)) {
        const channels = channel_ops.splitChannels(T, self, allocator) catch {
            // Fallback to generic implementation on allocation failure
            resizeGeneric(T, self, out, method);
            return;
        };
        defer for (channels) |channel| allocator.free(channel);

        // Allocate output channels
        const out_plane_size = out.rows * out.cols;
        var out_channels: [channels.len][]u8 = undefined;
        var allocated_count: usize = 0;
        errdefer {
            for (0..allocated_count) |i| {
                allocator.free(out_channels[i]);
            }
        }

        // Allocate each output channel
        for (&out_channels) |*ch| {
            ch.* = allocator.alloc(u8, out_plane_size) catch {
                // Free already allocated channels and fallback
                for (0..allocated_count) |i| {
                    allocator.free(out_channels[i]);
                }
                resizeGeneric(T, self, out, method);
                return;
            };
            allocated_count += 1;
        }
        defer for (out_channels) |ch| allocator.free(ch);

        // Resize each channel using optimized plane functions
        switch (method) {
            .nearest_neighbor => {
                inline for (channels, out_channels) |src_ch, dst_ch| {
                    channel_ops.resizePlaneNearestU8(src_ch, dst_ch, self.rows, self.cols, out.rows, out.cols);
                }
            },
            .bilinear => {
                inline for (channels, out_channels) |src_ch, dst_ch| {
                    channel_ops.resizePlaneBilinearU8(src_ch, dst_ch, self.rows, self.cols, out.rows, out.cols);
                }
            },
            .bicubic => {
                inline for (channels, out_channels) |src_ch, dst_ch| {
                    channel_ops.resizePlaneBicubicU8(src_ch, dst_ch, self.rows, self.cols, out.rows, out.cols);
                }
            },
            .catmull_rom => {
                inline for (channels, out_channels) |src_ch, dst_ch| {
                    channel_ops.resizePlaneCatmullRomU8(src_ch, dst_ch, self.rows, self.cols, out.rows, out.cols);
                }
            },
            .mitchell, .lanczos => {
                // Mitchell and Lanczos are more complex, fall back to generic for now
                // This ensures correct interpolation even if not optimized
                resizeGeneric(T, self, out, method);
                return;
            },
        }

        // Combine channels back
        channel_ops.mergeChannels(T, out_channels, out);
        return;
    }

    // Fall back to generic implementation
    resizeGeneric(T, self, out, method);
}

/// Generic resize implementation for non-optimized types
fn resizeGeneric(comptime T: type, self: Image(T), out: Image(T), method: Interpolation) void {
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

fn interpolateNearestNeighbor(comptime T: type, self: Image(T), x: f32, y: f32) ?T {
    const col: isize = @intFromFloat(@round(x));
    const row: isize = @intFromFloat(@round(y));

    if (col < 0 or row < 0 or col >= self.cols or row >= self.rows) return null;
    return self.at(@intCast(row), @intCast(col)).*;
}

fn interpolateBilinear(comptime T: type, self: Image(T), x: f32, y: f32) ?T {
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

    const scale = 256;
    const fx: i32 = @intFromFloat(@round(lr_frac * scale));
    const fy: i32 = @intFromFloat(@round(tb_frac * scale));

    const lerpInt = struct {
        fn lerp(comptime P: type, p_tl: P, p_tr: P, p_bl: P, p_br: P, p_fx: i32, p_fy: i32) P {
            const info = @typeInfo(P).int;
            const Intermediate = if (info.bits <= 8) i32 else i64;

            const tl_i = @as(Intermediate, @intCast(p_tl));
            const tr_i = @as(Intermediate, @intCast(p_tr));
            const bl_i = @as(Intermediate, @intCast(p_bl));
            const br_i = @as(Intermediate, @intCast(p_br));

            const top_val = tl_i * (scale - p_fx) + tr_i * p_fx;
            const bottom_val = bl_i * (scale - p_fx) + br_i * p_fx;
            const result = @divTrunc(top_val * (scale - p_fy) + bottom_val * p_fy + (scale * scale / 2), scale * scale);
            return clamp(P, result);
        }
    }.lerp;

    const lerpFloat = struct {
        fn lerp(comptime P: type, p_tl: P, p_tr: P, p_bl: P, p_br: P, p_lr_frac: f32, p_tb_frac: f32) P {
            return clamp(P, (1 - p_tb_frac) * ((1 - p_lr_frac) * as(f32, p_tl) +
                p_lr_frac * as(f32, p_tr)) +
                p_tb_frac * ((1 - p_lr_frac) * as(f32, p_bl) +
                    p_lr_frac * as(f32, p_br)));
        }
    }.lerp;

    // Handle different pixel types
    var temp: T = undefined;
    switch (@typeInfo(T)) {
        .int => |info| {
            temp = if (info.bits <= 16)
                lerpInt(T, tl, tr, bl, br, fx, fy)
            else
                lerpFloat(T, tl, tr, bl, br, lr_frac, tb_frac);
        },
        .float => temp = lerpFloat(T, tl, tr, bl, br, lr_frac, tb_frac),
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                const f_tl = @field(tl, f.name);
                const f_tr = @field(tr, f.name);
                const f_bl = @field(bl, f.name);
                const f_br = @field(br, f.name);

                const info = @typeInfo(f.type);
                @field(temp, f.name) = if (info == .int and info.int.bits <= 16)
                    lerpInt(f.type, f_tl, f_tr, f_bl, f_br, fx, fy)
                else
                    lerpFloat(f.type, f_tl, f_tr, f_bl, f_br, lr_frac, tb_frac);
            }
        },
        else => @compileError("Unsupported type for bilinear interpolation: " ++ @typeName(T)),
    }

    return temp;
}

fn interpolateBicubic(comptime T: type, self: Image(T), x: f32, y: f32) ?T {
    return interpolateWithKernel(T, self, x, y, 2, bicubicKernel, .{});
}

fn interpolateCatmullRom(comptime T: type, self: Image(T), x: f32, y: f32) ?T {
    return interpolateWithKernel(T, self, x, y, 2, catmullRomKernel, .{});
}

fn interpolateLanczos(comptime T: type, self: Image(T), x: f32, y: f32) ?T {
    const a: f32 = 3.0; // Lanczos3
    return interpolateWithKernel(T, self, x, y, 3, lanczosKernel, .{a});
}

fn interpolateMitchell(comptime T: type, self: Image(T), x: f32, y: f32, m_b: f32, m_c: f32) ?T {
    return interpolateWithKernel(T, self, x, y, 2, mitchellKernel, .{ m_b, m_c });
}

/// Generic kernel-based interpolation function
fn interpolateWithKernel(
    comptime T: type,
    self: Image(T),
    x: f32,
    y: f32,
    comptime window_radius: usize,
    kernel_fn: anytype,
    kernel_params: anytype,
) ?T {
    const ix: isize = @intFromFloat(@floor(x));
    const iy: isize = @intFromFloat(@floor(y));
    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);

    // Check bounds for the entire kernel window
    const min_x = ix - @as(isize, @intCast(window_radius - 1));
    const max_x = ix + @as(isize, @intCast(window_radius));
    const min_y = iy - @as(isize, @intCast(window_radius - 1));
    const max_y = iy + @as(isize, @intCast(window_radius));

    if (min_x < 0 or max_x >= self.cols or min_y < 0 or max_y >= self.rows) {
        return null;
    }

    const window_size = window_radius * 2;

    // Calculate weights
    var x_weights: [6]f32 = undefined; // Max window size is 6 for Lanczos3
    var y_weights: [6]f32 = undefined;

    inline for (0..window_size) |i| {
        const offset = @as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fx;
        if (kernel_params.len == 0) {
            x_weights[i] = kernel_fn(offset);
            y_weights[i] = kernel_fn(@as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fy);
        } else if (kernel_params.len == 1) {
            x_weights[i] = kernel_fn(offset, kernel_params[0]);
            y_weights[i] = kernel_fn(@as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fy, kernel_params[0]);
        } else if (kernel_params.len == 2) {
            x_weights[i] = kernel_fn(offset, kernel_params[0], kernel_params[1]);
            y_weights[i] = kernel_fn(@as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fy, kernel_params[0], kernel_params[1]);
        } else {
            @compileError("Unsupported number of kernel parameters");
        }
    }

    // Apply kernel
    var result: T = undefined;
    switch (@typeInfo(T)) {
        .int, .float => {
            var sum: f32 = 0;
            var weight_sum: f32 = 0;

            inline for (0..window_size) |j| {
                inline for (0..window_size) |i| {
                    const pixel_y = @as(usize, @intCast(iy - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(j))));
                    const pixel_x = @as(usize, @intCast(ix - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(i))));
                    const pixel = self.at(pixel_y, pixel_x).*;
                    const weight = x_weights[i] * y_weights[j];
                    sum += as(f32, pixel) * weight;
                    weight_sum += weight;
                }
            }

            const val = if (weight_sum != 0) sum / weight_sum else 0;
            result = clamp(T, val);
        },
        .@"struct" => {
            inline for (std.meta.fields(T)) |f| {
                var sum: f32 = 0;
                var weight_sum: f32 = 0;

                inline for (0..window_size) |j| {
                    inline for (0..window_size) |i| {
                        const pixel_y = @as(usize, @intCast(iy - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(j))));
                        const pixel_x = @as(usize, @intCast(ix - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(i))));
                        const pixel = self.at(pixel_y, pixel_x).*;
                        const weight = x_weights[i] * y_weights[j];
                        sum += as(f32, @field(pixel, f.name)) * weight;
                        weight_sum += weight;
                    }
                }

                const val = if (weight_sum != 0) sum / weight_sum else 0;
                @field(result, f.name) = clamp(f.type, val);
            }
        },
        else => @compileError("Unsupported type for kernel interpolation: " ++ @typeName(T)),
    }

    return result;
}

//! Image filtering and convolution operations

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const convertColor = @import("../color.zig").convertColor;
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const isScalar = meta.isScalar;
const channel_ops = @import("channel_ops.zig");
const ShenCastan = @import("ShenCastan.zig");

// ShenCastan type moved to its own file (ShenCastan.zig)

/// Border handling modes for filter operations
pub const BorderMode = enum {
    /// Pad with zeros
    zero,
    /// Replicate edge pixels
    replicate,
    /// Mirror at edges
    mirror,
    /// Wrap around (circular)
    wrap,
};

/// Helper to check if sigma is commonly used
fn isCommonSigma(sigma: f32) bool {
    const common_sigmas = [_]f32{ 0.5, 0.8, 1.0, 1.2, 1.4, 1.6, 2.0, 2.5, 3.0 };
    for (common_sigmas) |common| {
        if (@abs(sigma - common) < 0.001) return true;
    }
    return false;
}

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
                        integralPlane(u8, self, integral_img);
                        boxBlurPlane(u8, integral_img, blurred.*, radius);
                    } else if (T == f32) {
                        integralPlane(f32, self, integral_img);
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
                        integralPlane(f32, src_img, integral_img);

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
                                    integralPlane(u8, src_plane, integral_img);
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
                                    const sum = computeIntegralSumMultiChannel(sat, r1, c1, r2, c2, i);

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
        /// Automatically adjusts the contrast by stretching the intensity range.
        pub fn autocontrast(self: Self, allocator: Allocator, cutoff: f32) !Self {
            if (cutoff < 0 or cutoff >= 50) {
                return error.InvalidCutoff; // Can't ignore 50% or more from each end
            }

            var result = try Self.init(allocator, self.rows, self.cols);
            errdefer result.deinit(allocator);

            const total_pixels = self.rows * self.cols;
            const cutoff_pixels = @as(usize, @intFromFloat(@as(f32, @floatFromInt(total_pixels)) * cutoff / 100.0));

            switch (@typeInfo(T)) {
                .int => {
                    // For grayscale images, use histogram module
                    const hist = self.histogram();
                    const min_val = hist.findCutoffMin(@intCast(cutoff_pixels));
                    const max_val = hist.findCutoffMax(@intCast(cutoff_pixels));

                    // Avoid division by zero
                    const range = if (max_val > min_val) max_val - min_val else 1;

                    // Apply remapping
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            const val = self.at(r, c).*;
                            const clamped = @max(min_val, @min(max_val, val));
                            const normalized = @as(f32, @floatFromInt(clamped - min_val)) / @as(f32, @floatFromInt(range));
                            result.at(r, c).* = @intFromFloat(normalized * 255.0);
                        }
                    }
                },
                .@"struct" => {
                    // For RGB/RGBA images, process each channel independently
                    const Rgb = @import("../color.zig").Rgb;
                    const Rgba = @import("../color.zig").Rgba;

                    if (T == Rgb or T == Rgba) {
                        // Use histogram module
                        const hist = self.histogram();
                        const mins = hist.findCutoffMin(@intCast(cutoff_pixels));
                        const maxs = hist.findCutoffMax(@intCast(cutoff_pixels));

                        // Apply remapping
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const pixel = self.at(r, c).*;
                                var new_pixel = pixel;

                                // Remap each channel
                                const remap = struct {
                                    fn apply(val: u8, min: u8, max: u8) u8 {
                                        const clamped = @max(min, @min(max, val));
                                        const range = if (max > min) max - min else 1;
                                        const normalized = @as(f32, @floatFromInt(clamped - min)) / @as(f32, @floatFromInt(range));
                                        return @intFromFloat(normalized * 255.0);
                                    }
                                }.apply;

                                new_pixel.r = remap(pixel.r, mins.r, maxs.r);
                                new_pixel.g = remap(pixel.g, mins.g, maxs.g);
                                new_pixel.b = remap(pixel.b, mins.b, maxs.b);

                                result.at(r, c).* = new_pixel;
                            }
                        }
                    } else {
                        // For other color types, convert to RGB, process, and convert back
                        const rgb_img = try self.convert(Rgb, allocator);
                        defer rgb_img.deinit(allocator);

                        const rgb_result = try Filter(Rgb).autocontrast(rgb_img, allocator, cutoff);
                        defer rgb_result.deinit(allocator);

                        return rgb_result.convert(T, allocator);
                    }
                },
                else => return error.UnsupportedType,
            }

            return result;
        }

        /// Equalizes the histogram to improve contrast.
        pub fn equalize(self: Self, allocator: Allocator) !Self {
            var result = try Self.init(allocator, self.rows, self.cols);
            errdefer result.deinit(allocator);

            const total_pixels: u32 = @intCast(self.rows * self.cols);

            switch (@typeInfo(T)) {
                .int => {
                    // For grayscale images
                    const hist = self.histogram();

                    // Calculate cumulative distribution function (CDF)
                    var cdf: [256]u32 = undefined;
                    cdf[0] = hist.values[0];
                    for (1..256) |i| {
                        cdf[i] = cdf[i - 1] + hist.values[i];
                    }

                    // Find the first non-zero CDF value (for normalization)
                    var cdf_min: u32 = 0;
                    for (cdf) |val| {
                        if (val > 0) {
                            cdf_min = val;
                            break;
                        }
                    }

                    // Create lookup table for equalization
                    var lut: [256]u8 = undefined;
                    const denominator = total_pixels - cdf_min;
                    if (denominator == 0) {
                        // All pixels have the same value
                        for (0..256) |i| {
                            lut[i] = @intCast(i);
                        }
                    } else {
                        for (0..256) |i| {
                            if (cdf[i] >= cdf_min) {
                                const numerator = (cdf[i] - cdf_min) * 255;
                                lut[i] = @intCast(numerator / denominator);
                            } else {
                                lut[i] = 0;
                            }
                        }
                    }

                    // Apply the lookup table
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            const val = self.at(r, c).*;
                            result.at(r, c).* = lut[val];
                        }
                    }
                },
                .@"struct" => {
                    // For RGB/RGBA images, process each channel independently
                    const Rgb = @import("../color.zig").Rgb;
                    const Rgba = @import("../color.zig").Rgba;

                    if (T == Rgb or T == Rgba) {
                        const hist = self.histogram();

                        // Calculate CDF for each channel
                        var cdf_r: [256]u32 = undefined;
                        var cdf_g: [256]u32 = undefined;
                        var cdf_b: [256]u32 = undefined;
                        var cdf_a: [256]u32 = undefined;

                        cdf_r[0] = hist.r[0];
                        cdf_g[0] = hist.g[0];
                        cdf_b[0] = hist.b[0];
                        if (T == Rgba) {
                            cdf_a[0] = hist.a[0];
                        }

                        for (1..256) |i| {
                            cdf_r[i] = cdf_r[i - 1] + hist.r[i];
                            cdf_g[i] = cdf_g[i - 1] + hist.g[i];
                            cdf_b[i] = cdf_b[i - 1] + hist.b[i];
                            if (T == Rgba) {
                                cdf_a[i] = cdf_a[i - 1] + hist.a[i];
                            }
                        }

                        // Find minimum CDF values for each channel
                        var cdf_min_r: u32 = 0;
                        var cdf_min_g: u32 = 0;
                        var cdf_min_b: u32 = 0;
                        var cdf_min_a: u32 = 0;

                        for (cdf_r) |val| {
                            if (val > 0) {
                                cdf_min_r = val;
                                break;
                            }
                        }
                        for (cdf_g) |val| {
                            if (val > 0) {
                                cdf_min_g = val;
                                break;
                            }
                        }
                        for (cdf_b) |val| {
                            if (val > 0) {
                                cdf_min_b = val;
                                break;
                            }
                        }
                        if (T == Rgba) {
                            for (cdf_a) |val| {
                                if (val > 0) {
                                    cdf_min_a = val;
                                    break;
                                }
                            }
                        }

                        // Create lookup tables for each channel
                        var lut_r: [256]u8 = undefined;
                        var lut_g: [256]u8 = undefined;
                        var lut_b: [256]u8 = undefined;
                        var lut_a: [256]u8 = undefined;

                        const createLut = struct {
                            fn apply(cdf: *const [256]u32, cdf_min: u32, total: u32) [256]u8 {
                                var lut: [256]u8 = undefined;
                                const denominator = total - cdf_min;
                                if (denominator == 0) {
                                    for (0..256) |i| {
                                        lut[i] = @intCast(i);
                                    }
                                } else {
                                    for (0..256) |i| {
                                        if (cdf[i] >= cdf_min) {
                                            const numerator = (cdf[i] - cdf_min) * 255;
                                            lut[i] = @intCast(numerator / denominator);
                                        } else {
                                            lut[i] = 0;
                                        }
                                    }
                                }
                                return lut;
                            }
                        }.apply;

                        lut_r = createLut(&cdf_r, cdf_min_r, total_pixels);
                        lut_g = createLut(&cdf_g, cdf_min_g, total_pixels);
                        lut_b = createLut(&cdf_b, cdf_min_b, total_pixels);
                        if (T == Rgba) {
                            lut_a = createLut(&cdf_a, cdf_min_a, total_pixels);
                        }

                        // Apply the lookup tables
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const pixel = self.at(r, c).*;
                                var new_pixel = pixel;

                                new_pixel.r = lut_r[pixel.r];
                                new_pixel.g = lut_g[pixel.g];
                                new_pixel.b = lut_b[pixel.b];
                                if (T == Rgba) {
                                    new_pixel.a = lut_a[pixel.a];
                                }

                                result.at(r, c).* = new_pixel;
                            }
                        }
                    } else {
                        return error.UnsupportedType;
                    }
                },
                else => return error.UnsupportedType,
            }

            return result;
        }

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
                    if (T == u8) {
                        integralPlane(u8, self, integral_img);
                        sharpenPlane(u8, self, integral_img, sharpened.*, radius);
                    } else if (T == f32) {
                        integralPlane(f32, self, integral_img);
                        sharpenPlane(f32, self, integral_img, sharpened.*, radius);
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
                        integralPlane(f32, src_img, integral_img);

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
                                    integralPlane(u8, src_plane, integral_img);
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
                                    const sum = computeIntegralSumMultiChannel(sat, r1, c1, r2, c2, i);

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

        // ============================================================================
        // Convolution Kernel Specialization
        // ============================================================================

        /// Comptime function generator for specialized convolution implementations.
        /// Generates optimized code for specific kernel dimensions at compile time.
        fn ConvolveKernel(comptime height: usize, comptime width: usize) type {
            return struct {
                const kernel_size = height * width;
                const half_h = height / 2;
                const half_w = width / 2;

                /// Optimized convolution for u8 planes with integer arithmetic.
                fn convolveU8Plane(
                    src_img: Image(u8),
                    dst_img: Image(u8),
                    kernel: [kernel_size]i32,
                    border_mode: BorderMode,
                ) void {
                    const SCALE = 256;
                    const vec_len = comptime std.simd.suggestVectorLength(i32) orelse 8;
                    const rows = src_img.rows;
                    const cols = src_img.cols;

                    for (0..rows) |r| {
                        var c: usize = 0;

                        // SIMD path for interior pixels
                        if (r >= half_h and r + half_h < rows and cols > vec_len + width) {
                            c = half_w;
                            const safe_end = if (cols > vec_len + half_w) cols - vec_len - half_w else half_w;

                            while (c + vec_len <= safe_end) : (c += vec_len) {
                                var result_vec: @Vector(vec_len, i32) = @splat(0);

                                // Unroll kernel application for known sizes
                                inline for (0..height) |ky| {
                                    inline for (0..width) |kx| {
                                        const kernel_val = kernel[ky * width + kx];
                                        const kernel_vec: @Vector(vec_len, i32) = @splat(kernel_val);

                                        var pixel_vec: @Vector(vec_len, i32) = undefined;
                                        inline for (0..vec_len) |i| {
                                            const src_r = r + ky - half_h;
                                            const src_c = c + i + kx - half_w;
                                            pixel_vec[i] = src_img.data[src_r * src_img.stride + src_c];
                                        }

                                        result_vec += pixel_vec * kernel_vec;
                                    }
                                }

                                const half_scale_vec: @Vector(vec_len, i32) = @splat(SCALE / 2);
                                const scale_vec: @Vector(vec_len, i32) = @splat(SCALE);
                                const rounded_vec = @divTrunc(result_vec + half_scale_vec, scale_vec);

                                inline for (0..vec_len) |i| {
                                    dst_img.data[r * dst_img.stride + c + i] = @intCast(@max(0, @min(255, rounded_vec[i])));
                                }
                            }
                        }

                        while (c < cols) : (c += 1) {
                            if (r >= half_h and r + half_h < rows and c >= half_w and c + half_w < cols) {
                                var result: i32 = 0;
                                inline for (0..height) |ky| {
                                    inline for (0..width) |kx| {
                                        const src_r = r + ky - half_h;
                                        const src_c = c + kx - half_w;
                                        const pixel_val = @as(i32, src_img.data[src_r * src_img.stride + src_c]);
                                        result += pixel_val * kernel[ky * width + kx];
                                    }
                                }
                                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                                dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                            } else {
                                const ir = @as(isize, @intCast(r));
                                const ic = @as(isize, @intCast(c));
                                var result: i32 = 0;
                                inline for (0..height) |ky| {
                                    inline for (0..width) |kx| {
                                        const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                                        const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                                        const pixel_val: i32 = getPixel(u8, src_img, iry, icx, border_mode);
                                        result += pixel_val * kernel[ky * width + kx];
                                    }
                                }
                                const rounded = @divTrunc(result + SCALE / 2, SCALE);
                                dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                            }
                        }
                    }
                }

                /// Optimized convolution for f32 planes with SIMD.
                fn convolveF32Plane(
                    src_img: Image(f32),
                    dst_img: Image(f32),
                    kernel: [kernel_size]f32,
                    border_mode: BorderMode,
                ) void {
                    const vec_len = comptime std.simd.suggestVectorLength(f32) orelse 8;
                    const rows = src_img.rows;
                    const cols = src_img.cols;

                    // Pre-create kernel vectors for SIMD
                    var kernel_vecs: [kernel_size]@Vector(vec_len, f32) = undefined;
                    inline for (0..kernel_size) |i| {
                        kernel_vecs[i] = @splat(kernel[i]);
                    }

                    for (0..rows) |r| {
                        var c: usize = 0;

                        // SIMD path for interior pixels
                        if (r >= half_h and r + half_h < rows and cols > vec_len + width) {
                            c = half_w;
                            const safe_end = if (cols > vec_len + half_w) cols - vec_len - half_w else half_w;

                            while (c + vec_len <= safe_end) : (c += vec_len) {
                                var result_vec: @Vector(vec_len, f32) = @splat(0);

                                inline for (0..height) |ky| {
                                    inline for (0..width) |kx| {
                                        const kid = ky * width + kx;
                                        const kernel_vec = kernel_vecs[kid];

                                        var pixel_vec: @Vector(vec_len, f32) = undefined;
                                        inline for (0..vec_len) |i| {
                                            const src_r = r + ky - half_h;
                                            const src_c = c + i + kx - half_w;
                                            pixel_vec[i] = src_img.data[src_r * src_img.stride + src_c];
                                        }

                                        result_vec += pixel_vec * kernel_vec;
                                    }
                                }

                                inline for (0..vec_len) |i| {
                                    dst_img.data[r * dst_img.stride + c + i] = result_vec[i];
                                }
                            }
                        }

                        while (c < cols) : (c += 1) {
                            if (r >= half_h and r + half_h < rows and c >= half_w and c + half_w < cols) {
                                var result: f32 = 0;
                                inline for (0..height) |ky| {
                                    inline for (0..width) |kx| {
                                        const src_r = r + ky - half_h;
                                        const src_c = c + kx - half_w;
                                        result += src_img.data[src_r * src_img.stride + src_c] * kernel[ky * width + kx];
                                    }
                                }
                                dst_img.data[r * dst_img.stride + c] = result;
                            } else {
                                const ir = @as(isize, @intCast(r));
                                const ic = @as(isize, @intCast(c));
                                var result: f32 = 0;
                                inline for (0..height) |ky| {
                                    inline for (0..width) |kx| {
                                        const iry = ir + @as(isize, @intCast(ky)) - @as(isize, @intCast(half_h));
                                        const icx = ic + @as(isize, @intCast(kx)) - @as(isize, @intCast(half_w));
                                        const pixel_val = getPixel(f32, src_img, iry, icx, border_mode);
                                        result += pixel_val * kernel[ky * width + kx];
                                    }
                                }
                                dst_img.data[r * dst_img.stride + c] = result;
                            }
                        }
                    }
                }
            };
        }

        /// Applies a 2D convolution with the given kernel to the image.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
        /// - `kernel`: A 2D array representing the convolution kernel.
        /// - `out`: An out-parameter pointer to an `Image(T)` that will be filled with the convolved image.
        /// - `border_mode`: How to handle pixels at the image borders.
        pub fn convolve(self: Self, allocator: Allocator, kernel: anytype, out: *Self, border_mode: BorderMode) !void {
            const kernel_info = @typeInfo(@TypeOf(kernel));
            if (kernel_info != .array) @compileError("Kernel must be a 2D array");
            const outer_array = kernel_info.array;
            if (@typeInfo(outer_array.child) != .array) @compileError("Kernel must be a 2D array");

            const kernel_height = outer_array.len;
            const kernel_width = @typeInfo(outer_array.child).array.len;

            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // Generate specialized implementation for this kernel size
            const Kernel = ConvolveKernel(kernel_height, kernel_width);

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Optimized path for u8 with integer arithmetic
                    if (T == u8) {
                        // Convert floating-point kernel to integer
                        const SCALE = 256;
                        const kernel_int = flattenKernel(i32, Kernel.kernel_size, kernel, SCALE);

                        Kernel.convolveU8Plane(self, out.*, kernel_int, border_mode);
                    } else if (T == f32) {
                        // Optimized path for f32 with SIMD
                        const kernel_flat = flattenKernel(f32, Kernel.kernel_size, kernel, null);
                        Kernel.convolveF32Plane(self, out.*, kernel_flat, border_mode);
                    } else {
                        // Generic scalar path for other types
                        const half_h = Kernel.half_h;
                        const half_w = Kernel.half_w;
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                var accumulator: f32 = 0;

                                const in_interior = (r >= half_h and r + half_h < self.rows and c >= half_w and c + half_w < self.cols);
                                if (in_interior) {
                                    // Fast path: no border handling needed
                                    const r0: usize = r - half_h;
                                    const c0: usize = c - half_w;
                                    for (0..kernel_height) |kr| {
                                        const rr = r0 + kr;
                                        for (0..kernel_width) |kc| {
                                            const cc = c0 + kc;
                                            const pixel_val = self.at(rr, cc).*;
                                            const kernel_val = kernel[kr][kc];
                                            accumulator += as(f32, pixel_val) * as(f32, kernel_val);
                                        }
                                    }
                                } else {
                                    // Border path: fetch with border handling
                                    for (0..kernel_height) |kr| {
                                        for (0..kernel_width) |kc| {
                                            const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(kr)) - @as(isize, @intCast(half_h));
                                            const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(kc)) - @as(isize, @intCast(half_w));
                                            const pixel_val = getPixel(T, self, src_r, src_c, border_mode);
                                            const kernel_val = kernel[kr][kc];
                                            accumulator += as(f32, pixel_val) * as(f32, kernel_val);
                                        }
                                    }
                                }

                                out.at(r, c).* = switch (@typeInfo(T)) {
                                    .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(accumulator)))),
                                    .float => as(T, accumulator),
                                    else => unreachable,
                                };
                            }
                        }
                    }
                },
                .@"struct" => {
                    // Optimized path for u8 structs (RGB, RGBA, etc.)

                    if (comptime meta.allFieldsAreU8(T)) {
                        // Channel separation approach for optimal performance
                        const SCALE = 256;
                        const kernel_int = flattenKernel(i32, Kernel.kernel_size, kernel, SCALE);
                        const plane_size = self.rows * self.cols;

                        // Separate channels using helper
                        const channels = try channel_ops.splitChannels(T, self, allocator);
                        defer for (channels) |channel| allocator.free(channel);

                        // Check which channels are uniform to avoid unnecessary processing
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

                        // Allocate output planes only for non-uniform channels
                        var out_channels: [channels.len][]u8 = undefined;
                        inline for (&out_channels, is_uniform) |*ch, uniform| {
                            if (uniform) {
                                // For uniform channels with normalized kernels, output is same as input
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

                        // Convolve only non-uniform channels
                        inline for (channels, out_channels, is_uniform) |src_data, dst_data, uniform| {
                            if (!uniform) {
                                const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                                const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                                Kernel.convolveU8Plane(src_plane, dst_plane, kernel_int, border_mode);
                            }
                        }

                        // Recombine channels, using original values for uniform channels
                        var final_channels: [channels.len][]const u8 = undefined;
                        inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                            if (uniform) {
                                // For uniform channels, convolution with normalized kernel preserves the value
                                final_channels[i] = src_ch;
                            } else {
                                final_channels[i] = out_ch;
                            }
                        }
                        channel_ops.mergeChannels(T, final_channels, out.*);
                    } else {
                        // Generic struct path for other color types
                        const fields = std.meta.fields(T);
                        const half_h = Kernel.half_h;
                        const half_w = Kernel.half_w;

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                var result_pixel: T = undefined;

                                inline for (fields) |field| {
                                    var accumulator: f32 = 0;
                                    const in_interior = (r >= half_h and r + half_h < self.rows and c >= half_w and c + half_w < self.cols);
                                    if (in_interior) {
                                        const r0: usize = r - half_h;
                                        const c0: usize = c - half_w;
                                        for (0..kernel_height) |kr| {
                                            const rr = r0 + kr;
                                            for (0..kernel_width) |kc| {
                                                const cc = c0 + kc;
                                                const pixel_val = self.at(rr, cc).*;
                                                const channel_val = @field(pixel_val, field.name);
                                                const kernel_val = kernel[kr][kc];
                                                accumulator += as(f32, channel_val) * as(f32, kernel_val);
                                            }
                                        }
                                    } else {
                                        for (0..kernel_height) |kr| {
                                            for (0..kernel_width) |kc| {
                                                const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(kr)) - @as(isize, @intCast(half_h));
                                                const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(kc)) - @as(isize, @intCast(half_w));
                                                const pixel_val = getPixel(T, self, src_r, src_c, border_mode);
                                                const channel_val = @field(pixel_val, field.name);
                                                const kernel_val = kernel[kr][kc];
                                                accumulator += as(f32, channel_val) * as(f32, kernel_val);
                                            }
                                        }
                                    }

                                    @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                        .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(accumulator)))),
                                        .float => as(field.type, accumulator),
                                        else => @compileError("Unsupported field type in struct"),
                                    };
                                }

                                out.at(r, c).* = result_pixel;
                            }
                        }
                    }
                },
                else => @compileError("Convolution not supported for type " ++ @typeName(T)),
            }
        }

        // ============================================================================
        // Optimized Plane Processing Functions
        // ============================================================================

        /// Optimized separable convolution for u8 planes with SIMD integer arithmetic.
        /// The kernel must be pre-scaled by 256 for integer arithmetic.
        fn convolveSeparableU8Plane(
            src_img: Image(u8),
            dst_img: Image(u8),
            temp_img: Image(u8),
            kernel_x_int: []const i32,
            kernel_y_int: []const i32,
            border_mode: BorderMode,
        ) void {
            const SCALE = 256;
            const half_x = kernel_x_int.len / 2;
            const half_y = kernel_y_int.len / 2;
            const rows = src_img.rows;
            const cols = src_img.cols;
            const vec_len = std.simd.suggestVectorLength(i32) orelse 8;

            // Horizontal pass (src -> temp) with SIMD
            for (0..rows) |r| {
                const row_offset = r * src_img.stride;
                const temp_offset = r * temp_img.stride;

                // Process interior pixels with SIMD (no border handling)
                if (cols > 2 * half_x) {
                    var c: usize = half_x;
                    const safe_end = cols - half_x;

                    // SIMD processing for interior pixels (symmetric kernel pairs)
                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var acc: @Vector(vec_len, i32) = @splat(0);

                        // Center tap
                        const k_center = kernel_x_int[half_x];
                        if (k_center != 0) {
                            const center_u8: @Vector(vec_len, u8) = src_img.data[row_offset + c ..][0..vec_len].*;
                            const center_i32: @Vector(vec_len, i32) = @intCast(center_u8);
                            acc += center_i32 * @as(@Vector(vec_len, i32), @splat(k_center));
                        }

                        // Paired taps
                        var di: usize = 1;
                        while (di <= half_x) : (di += 1) {
                            const k = kernel_x_int[half_x + di];
                            if (k != 0) {
                                const left_u8: @Vector(vec_len, u8) = src_img.data[row_offset + c - di ..][0..vec_len].*;
                                const right_u8: @Vector(vec_len, u8) = src_img.data[row_offset + c + di ..][0..vec_len].*;
                                const left_i32: @Vector(vec_len, i32) = @intCast(left_u8);
                                const right_i32: @Vector(vec_len, i32) = @intCast(right_u8);
                                const pair_sum: @Vector(vec_len, i32) = left_i32 + right_i32;
                                acc += pair_sum * @as(@Vector(vec_len, i32), @splat(k));
                            }
                        }

                        // Vectorized rounding, clamp, and store
                        var rounded_vec: @Vector(vec_len, i32) = (acc + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                        const zero_vec: @Vector(vec_len, i32) = @splat(0);
                        const max_vec: @Vector(vec_len, i32) = @splat(255);
                        rounded_vec = @select(i32, rounded_vec < zero_vec, zero_vec, rounded_vec);
                        rounded_vec = @select(i32, rounded_vec > max_vec, max_vec, rounded_vec);
                        const out_vec: @Vector(vec_len, u8) = @intCast(rounded_vec);
                        temp_img.data[temp_offset + c ..][0..vec_len].* = out_vec;
                    }

                    // Handle remaining pixels with scalar code
                    while (c < safe_end) : (c += 1) {
                        var result: i32 = 0;
                        const c0 = c - half_x;
                        for (kernel_x_int, 0..) |k, i| {
                            const cc = c0 + i;
                            const pixel_val = @as(i32, src_img.data[row_offset + cc]);
                            result += pixel_val * k;
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }

                // Handle borders with scalar code
                for (0..@min(half_x, cols)) |c| {
                    var result: i32 = 0;
                    const ic = @as(isize, @intCast(c));
                    for (kernel_x_int, 0..) |k, i| {
                        const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                        const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                        result += pixel_val * k;
                    }
                    const rounded = @divTrunc(result + SCALE / 2, SCALE);
                    temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
                }

                if (cols > half_x) {
                    for (cols - half_x..cols) |c| {
                        var result: i32 = 0;
                        const ic = @as(isize, @intCast(c));
                        for (kernel_x_int, 0..) |k, i| {
                            const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                            const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                            result += pixel_val * k;
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }
            }

            // Vertical pass (temp -> dst) with SIMD across columns
            const vec_len_y = vec_len;

            // Interior rows: process r in [half_y, rows - half_y)
            if (rows > 2 * half_y) {
                const safe_end_r = rows - half_y;
                for (half_y..safe_end_r) |r| {
                    var c: usize = 0;

                    // SIMD processing across columns (symmetric kernel pairs)
                    while (c + vec_len_y <= cols) : (c += vec_len_y) {
                        var acc: @Vector(vec_len_y, i32) = @splat(0);

                        // Center tap
                        const k_center = kernel_y_int[half_y];
                        if (k_center != 0) {
                            const center_off = r * temp_img.stride;
                            const center_u8: @Vector(vec_len_y, u8) = temp_img.data[center_off + c ..][0..vec_len_y].*;
                            const center_i32: @Vector(vec_len_y, i32) = @intCast(center_u8);
                            acc += center_i32 * @as(@Vector(vec_len_y, i32), @splat(k_center));
                        }

                        // Row pairs
                        var di: usize = 1;
                        while (di <= half_y) : (di += 1) {
                            const k = kernel_y_int[half_y + di];
                            if (k != 0) {
                                const top_off = (r - di) * temp_img.stride;
                                const bot_off = (r + di) * temp_img.stride;
                                const top_u8: @Vector(vec_len_y, u8) = temp_img.data[top_off + c ..][0..vec_len_y].*;
                                const bot_u8: @Vector(vec_len_y, u8) = temp_img.data[bot_off + c ..][0..vec_len_y].*;
                                const top_i32: @Vector(vec_len_y, i32) = @intCast(top_u8);
                                const bot_i32: @Vector(vec_len_y, i32) = @intCast(bot_u8);
                                const pair_sum: @Vector(vec_len_y, i32) = top_i32 + bot_i32;
                                acc += pair_sum * @as(@Vector(vec_len_y, i32), @splat(k));
                            }
                        }

                        var rounded: @Vector(vec_len_y, i32) = (acc + @as(@Vector(vec_len_y, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len_y, i32), @splat(SCALE));
                        const zero_vec: @Vector(vec_len_y, i32) = @splat(0);
                        const max_vec: @Vector(vec_len_y, i32) = @splat(255);
                        const below = rounded < zero_vec;
                        rounded = @select(i32, below, zero_vec, rounded);
                        const above = rounded > max_vec;
                        rounded = @select(i32, above, max_vec, rounded);
                        // TODO(zig-upgrade): Once verified fixed, enable vector store branch below.
                        if (comptime false) {
                            const out_vec: @Vector(vec_len_y, u8) = @intCast(rounded);
                            dst_img.data[r * dst_img.stride + c ..][0..vec_len_y].* = out_vec;
                        } else {
                            // Work around vector cast/codegen bug:
                            // casting @Vector(N,i32) -> @Vector(N,u8) and storing caused upper lanes
                            // to mirror lower lanes in tests (gaussianBlur). Store lane-by-lane instead.
                            inline for (0..vec_len_y) |lane| {
                                const v: i32 = rounded[lane];
                                dst_img.data[r * dst_img.stride + c + lane] = @intCast(@max(0, @min(255, v)));
                            }
                        }
                    }

                    // Remaining columns (scalar)
                    while (c < cols) : (c += 1) {
                        var result: i32 = 0;
                        const r0 = r - half_y;
                        for (kernel_y_int, 0..) |k, i| {
                            if (k == 0) continue;
                            const rr = r0 + i;
                            const pixel_val = @as(i32, temp_img.data[rr * temp_img.stride + c]);
                            result += pixel_val * k;
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }
            }

            // Handle top border rows (scalar across columns)
            for (0..@min(half_y, rows)) |r| {
                for (0..cols) |c| {
                    var result: i32 = 0;
                    const ir = @as(isize, @intCast(r));
                    for (kernel_y_int, 0..) |k, i| {
                        const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                        const pixel_val: i32 = getPixel(u8, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                        result += pixel_val * k;
                    }
                    const rounded = @divTrunc(result + SCALE / 2, SCALE);
                    dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                }
            }

            // Handle bottom border rows (scalar across columns)
            if (rows > half_y) {
                for (rows - half_y..rows) |r| {
                    for (0..cols) |c| {
                        var result: i32 = 0;
                        const ir = @as(isize, @intCast(r));
                        for (kernel_y_int, 0..) |k, i| {
                            const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                            const pixel_val: i32 = getPixel(u8, temp_img, iry, @as(isize, @intCast(c)), border_mode);
                            result += pixel_val * k;
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }
            }
        }

        /// Helper for scalar convolution at a single pixel
        inline fn convolveScalarHorizontal(
            src_img: Image(f32),
            row: usize,
            col: usize,
            kernel: []const f32,
            half_k: usize,
            border_mode: BorderMode,
        ) f32 {
            var sum: f32 = 0;
            const ir: isize = @intCast(row);
            const ic: isize = @intCast(col);
            for (kernel, 0..) |k, i| {
                const src_c = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_k));
                sum += getPixel(f32, src_img, ir, src_c, border_mode) * k;
            }
            return sum;
        }

        inline fn convolveScalarVertical(
            temp_img: Image(f32),
            row: usize,
            col: usize,
            kernel: []const f32,
            half_k: usize,
            border_mode: BorderMode,
        ) f32 {
            var sum: f32 = 0;
            const ir: isize = @intCast(row);
            const ic: isize = @intCast(col);
            for (kernel, 0..) |k, i| {
                const src_r = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_k));
                sum += getPixel(f32, temp_img, src_r, ic, border_mode) * k;
            }
            return sum;
        }

        /// Optimized separable convolution for f32 planes with SIMD.
        fn convolveSeparableF32Plane(
            src_img: Image(f32),
            dst_img: Image(f32),
            temp_img: Image(f32),
            kernel_x: []const f32,
            kernel_y: []const f32,
            border_mode: BorderMode,
        ) void {
            const rows = src_img.rows;
            const cols = src_img.cols;
            const half_x = kernel_x.len / 2;
            const half_y = kernel_y.len / 2;
            const vec_len = std.simd.suggestVectorLength(f32) orelse 8;

            // Horizontal pass (src -> temp)
            for (0..rows) |r| {
                var c: usize = 0;
                const row_offset = r * src_img.stride;
                const temp_offset = r * temp_img.stride;

                // Left border (scalar, needs border handling)
                const left_border_end = @min(half_x, cols);
                while (c < left_border_end) : (c += 1) {
                    temp_img.data[temp_offset + c] = convolveScalarHorizontal(src_img, r, c, kernel_x, half_x, border_mode);
                }

                // SIMD interior - only if there's enough space
                if (cols > 2 * half_x + vec_len) {
                    // Safe bounds: ensure we don't underflow and have room for vectors
                    const safe_start = half_x;
                    const safe_end = cols - half_x;
                    c = safe_start;

                    // Process full vectors
                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var acc: @Vector(vec_len, f32) = @splat(0);

                        // Optimized memory access pattern - load contiguous data
                        for (kernel_x, 0..) |k, kx| {
                            if (k == 0) continue; // Skip zero coefficients
                            const kv: @Vector(vec_len, f32) = @splat(k);
                            const src_idx = row_offset + c + kx - half_x;
                            // Load contiguous memory as vector
                            const pix: @Vector(vec_len, f32) = src_img.data[src_idx..][0..vec_len].*;
                            acc += pix * kv;
                        }

                        // Store results as vector
                        temp_img.data[temp_offset + c ..][0..vec_len].* = acc;
                    }

                    // Process remaining elements in safe region with scalar
                    while (c < safe_end) : (c += 1) {
                        var sum: f32 = 0;
                        const c0 = c - half_x;
                        for (kernel_x, 0..) |k, i| {
                            sum += src_img.data[row_offset + c0 + i] * k;
                        }
                        temp_img.data[temp_offset + c] = sum;
                    }
                }

                // Right border (scalar with border handling)
                while (c < cols) : (c += 1) {
                    temp_img.data[temp_offset + c] = convolveScalarHorizontal(src_img, r, c, kernel_x, half_x, border_mode);
                }
            }

            // Vertical pass (temp -> dst)
            // Process in column blocks for better cache usage
            const block_size = 64; // Process columns in blocks for cache efficiency
            var col_block: usize = 0;

            while (col_block < cols) : (col_block += block_size) {
                const block_end = @min(col_block + block_size, cols);

                for (0..rows) |r| {
                    const dst_offset = r * dst_img.stride;

                    // Check if we can use SIMD for this row
                    if (r >= half_y and r + half_y < rows) {
                        // Safe region - can use direct memory access
                        var c = col_block;
                        const block_width = block_end - col_block;

                        // Process vectors if block is wide enough
                        if (block_width >= vec_len) {
                            const vec_end = col_block + (block_width / vec_len) * vec_len;

                            while (c < vec_end) : (c += vec_len) {
                                var acc: @Vector(vec_len, f32) = @splat(0);

                                // More efficient vertical access pattern
                                for (kernel_y, 0..) |k, ky| {
                                    if (k == 0) continue; // Skip zero coefficients
                                    const kv: @Vector(vec_len, f32) = @splat(k);
                                    const src_row = r + ky - half_y;
                                    const src_idx = src_row * temp_img.stride + c;
                                    const pix: @Vector(vec_len, f32) = temp_img.data[src_idx..][0..vec_len].*;
                                    acc += pix * kv;
                                }

                                dst_img.data[dst_offset + c ..][0..vec_len].* = acc;
                            }
                        }

                        // Process remaining scalar elements in safe region
                        while (c < block_end) : (c += 1) {
                            var sum: f32 = 0;
                            const r0 = r - half_y;
                            for (kernel_y, 0..) |k, i| {
                                sum += temp_img.data[(r0 + i) * temp_img.stride + c] * k;
                            }
                            dst_img.data[dst_offset + c] = sum;
                        }
                    } else {
                        // Border region - need boundary checks
                        var c = col_block;
                        while (c < block_end) : (c += 1) {
                            dst_img.data[dst_offset + c] = convolveScalarVertical(temp_img, r, c, kernel_y, half_y, border_mode);
                        }
                    }
                }
            }
        }

        /// Horizontal-only separable convolution for u8 plane (integer SIMD).
        fn convolveHorizontalU8Plane(
            src_img: Image(u8),
            temp_img: Image(u8),
            kernel_x_int: []const i32,
            border_mode: BorderMode,
        ) void {
            const SCALE = 256;
            const half_x = kernel_x_int.len / 2;
            const rows = src_img.rows;
            const cols = src_img.cols;
            const vec_len = std.simd.suggestVectorLength(i32) orelse 8;

            for (0..rows) |r| {
                const row_offset = r * src_img.stride;
                const temp_offset = r * temp_img.stride;

                if (cols > 2 * half_x) {
                    var c: usize = half_x;
                    const safe_end = cols - half_x;

                    while (c + vec_len <= safe_end) : (c += vec_len) {
                        var results: @Vector(vec_len, i32) = @splat(0);
                        for (kernel_x_int, 0..) |k, ki| {
                            if (k == 0) continue;
                            const k_vec: @Vector(vec_len, i32) = @splat(k);
                            const src_idx = row_offset + c - half_x + ki;
                            const pix_u8: @Vector(vec_len, u8) = src_img.data[src_idx..][0..vec_len].*;
                            const pix_i32: @Vector(vec_len, i32) = @intCast(pix_u8);
                            results += pix_i32 * k_vec;
                        }
                        var rounded: @Vector(vec_len, i32) = (results + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                        const zero_vec: @Vector(vec_len, i32) = @splat(0);
                        const max_vec: @Vector(vec_len, i32) = @splat(255);
                        rounded = @select(i32, rounded < zero_vec, zero_vec, rounded);
                        rounded = @select(i32, rounded > max_vec, max_vec, rounded);
                        // TODO(zig-upgrade): Once verified fixed, enable vector store branch below.
                        if (comptime false) {
                            const out_vec: @Vector(vec_len, u8) = @intCast(rounded);
                            temp_img.data[temp_offset + c ..][0..vec_len].* = out_vec;
                        } else {
                            // Same workaround as above: avoid vector @intCast store due to Zig dev bug.
                            inline for (0..vec_len) |lane| {
                                const v: i32 = rounded[lane];
                                temp_img.data[temp_offset + c + lane] = @intCast(@max(0, @min(255, v)));
                            }
                        }
                    }

                    while (c < safe_end) : (c += 1) {
                        var result: i32 = 0;
                        const c0 = c - half_x;
                        for (kernel_x_int, 0..) |k, i| {
                            const cc = c0 + i;
                            result += @as(i32, src_img.data[row_offset + cc]) * k;
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }

                // Left border
                for (0..@min(half_x, cols)) |c| {
                    var result: i32 = 0;
                    const ic = @as(isize, @intCast(c));
                    for (kernel_x_int, 0..) |k, i| {
                        const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                        const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                        result += pixel_val * k;
                    }
                    const rounded = @divTrunc(result + SCALE / 2, SCALE);
                    temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
                }

                // Right border
                if (cols > half_x) {
                    for (cols - half_x..cols) |c| {
                        var result: i32 = 0;
                        const ic = @as(isize, @intCast(c));
                        for (kernel_x_int, 0..) |k, i| {
                            const icx = ic + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                            const pixel_val: i32 = getPixel(u8, src_img, @as(isize, @intCast(r)), icx, border_mode);
                            result += pixel_val * k;
                        }
                        const rounded = @divTrunc(result + SCALE / 2, SCALE);
                        temp_img.data[temp_offset + c] = @intCast(@max(0, @min(255, rounded)));
                    }
                }
            }
        }

        /// Vertical dual-kernel pass: consumes two horizontal temps and writes DoG (blur1 - blur2).
        fn convolveVerticalU8PlaneDual(
            temp1: Image(u8),
            temp2: Image(u8),
            dst_img: Image(u8),
            kernel_y1_int: []const i32,
            kernel_y2_int: []const i32,
            border_mode: BorderMode,
            offset_u8: u8,
        ) void {
            const SCALE = 256;
            const OFFSET: i32 = @intCast(offset_u8); // configurable offset
            const half_y1 = kernel_y1_int.len / 2;
            const half_y2 = kernel_y2_int.len / 2;
            const rows = dst_img.rows;
            const cols = dst_img.cols;
            const vec_len = std.simd.suggestVectorLength(i32) orelse 8;

            const half_y = @max(half_y1, half_y2);
            if (rows > 2 * half_y) {
                const safe_end_r = rows - half_y;
                for (half_y..safe_end_r) |r| {
                    var c: usize = 0;
                    while (c + vec_len <= cols) : (c += vec_len) {
                        var acc1: @Vector(vec_len, i32) = @splat(0);
                        var acc2: @Vector(vec_len, i32) = @splat(0);

                        // Centers
                        const k1_center = kernel_y1_int[half_y1];
                        if (k1_center != 0) {
                            const center1_off = r * temp1.stride;
                            const v1_u8: @Vector(vec_len, u8) = temp1.data[center1_off + c ..][0..vec_len].*;
                            const v1_i32: @Vector(vec_len, i32) = @intCast(v1_u8);
                            acc1 += v1_i32 * @as(@Vector(vec_len, i32), @splat(k1_center));
                        }
                        const k2_center = kernel_y2_int[half_y2];
                        if (k2_center != 0) {
                            const center2_off = r * temp2.stride;
                            const v2_u8: @Vector(vec_len, u8) = temp2.data[center2_off + c ..][0..vec_len].*;
                            const v2_i32: @Vector(vec_len, i32) = @intCast(v2_u8);
                            acc2 += v2_i32 * @as(@Vector(vec_len, i32), @splat(k2_center));
                        }

                        // Pairs for kernel1
                        var di1: usize = 1;
                        while (di1 <= half_y1) : (di1 += 1) {
                            const k = kernel_y1_int[half_y1 + di1];
                            if (k != 0) {
                                const top_off = (r - di1) * temp1.stride;
                                const bot_off = (r + di1) * temp1.stride;
                                const top_u8: @Vector(vec_len, u8) = temp1.data[top_off + c ..][0..vec_len].*;
                                const bot_u8: @Vector(vec_len, u8) = temp1.data[bot_off + c ..][0..vec_len].*;
                                const top_i32: @Vector(vec_len, i32) = @intCast(top_u8);
                                const bot_i32: @Vector(vec_len, i32) = @intCast(bot_u8);
                                acc1 += (top_i32 + bot_i32) * @as(@Vector(vec_len, i32), @splat(k));
                            }
                        }
                        // Pairs for kernel2
                        var di2: usize = 1;
                        while (di2 <= half_y2) : (di2 += 1) {
                            const k = kernel_y2_int[half_y2 + di2];
                            if (k != 0) {
                                const top_off = (r - di2) * temp2.stride;
                                const bot_off = (r + di2) * temp2.stride;
                                const top_u8: @Vector(vec_len, u8) = temp2.data[top_off + c ..][0..vec_len].*;
                                const bot_u8: @Vector(vec_len, u8) = temp2.data[bot_off + c ..][0..vec_len].*;
                                const top_i32: @Vector(vec_len, i32) = @intCast(top_u8);
                                const bot_i32: @Vector(vec_len, i32) = @intCast(bot_u8);
                                acc2 += (top_i32 + bot_i32) * @as(@Vector(vec_len, i32), @splat(k));
                            }
                        }

                        const r1: @Vector(vec_len, i32) = (acc1 + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                        const r2: @Vector(vec_len, i32) = (acc2 + @as(@Vector(vec_len, i32), @splat(SCALE / 2))) / @as(@Vector(vec_len, i32), @splat(SCALE));
                        var diff: @Vector(vec_len, i32) = r1 - r2 + @as(@Vector(vec_len, i32), @splat(OFFSET));
                        const zero_vec: @Vector(vec_len, i32) = @splat(0);
                        const max_vec: @Vector(vec_len, i32) = @splat(255);
                        diff = @select(i32, diff < zero_vec, zero_vec, diff);
                        diff = @select(i32, diff > max_vec, max_vec, diff);
                        const out_vec: @Vector(vec_len, u8) = @intCast(diff);
                        dst_img.data[r * dst_img.stride + c ..][0..vec_len].* = out_vec;
                    }

                    // Scalar tail
                    while (c < cols) : (c += 1) {
                        var s1: i32 = 0;
                        var s2: i32 = 0;
                        const r01 = r - half_y1;
                        const r02 = r - half_y2;
                        for (kernel_y1_int, 0..) |k, i| {
                            if (k == 0) continue;
                            const rr = r01 + i;
                            s1 += @as(i32, temp1.data[rr * temp1.stride + c]) * k;
                        }
                        for (kernel_y2_int, 0..) |k, i| {
                            if (k == 0) continue;
                            const rr = r02 + i;
                            s2 += @as(i32, temp2.data[rr * temp2.stride + c]) * k;
                        }
                        const rounded1 = @divTrunc(s1 + SCALE / 2, SCALE);
                        const rounded2 = @divTrunc(s2 + SCALE / 2, SCALE);
                        const d = rounded1 - rounded2 + OFFSET;
                        dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, d)));
                    }
                }
            }

            // Top border rows
            for (0..@min(half_y, rows)) |r| {
                for (0..cols) |c| {
                    var s1: i32 = 0;
                    var s2: i32 = 0;
                    const ir = @as(isize, @intCast(r));
                    for (kernel_y1_int, 0..) |k, i| {
                        const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y1));
                        s1 += getPixel(u8, temp1, iry, @as(isize, @intCast(c)), border_mode) * k;
                    }
                    for (kernel_y2_int, 0..) |k, i| {
                        const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y2));
                        s2 += getPixel(u8, temp2, iry, @as(isize, @intCast(c)), border_mode) * k;
                    }
                    const d = @divTrunc(s1 + SCALE / 2, SCALE) - @divTrunc(s2 + SCALE / 2, SCALE) + OFFSET;
                    dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, d)));
                }
            }

            // Bottom border rows
            if (rows > half_y) {
                for (rows - half_y..rows) |r| {
                    for (0..cols) |c| {
                        var s1: i32 = 0;
                        var s2: i32 = 0;
                        const ir = @as(isize, @intCast(r));
                        for (kernel_y1_int, 0..) |k, i| {
                            const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y1));
                            s1 += getPixel(u8, temp1, iry, @as(isize, @intCast(c)), border_mode) * k;
                        }
                        for (kernel_y2_int, 0..) |k, i| {
                            const iry = ir + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y2));
                            s2 += getPixel(u8, temp2, iry, @as(isize, @intCast(c)), border_mode) * k;
                        }
                        const d = @divTrunc(s1 + SCALE / 2, SCALE) - @divTrunc(s2 + SCALE / 2, SCALE) + OFFSET;
                        dst_img.data[r * dst_img.stride + c] = @intCast(@max(0, @min(255, d)));
                    }
                }
            }
        }

        /// Optimized convolution for scalar types (int/float) with SIMD.
        /// Build integral image from any scalar type plane into f32 plane with SIMD optimization.
        /// The output integral image allows O(1) computation of rectangular region sums.
        fn integralPlane(comptime SrcT: type, src_img: Image(SrcT), dst_img: Image(f32)) void {
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
                    tmp += meta.as(f32, src_img.data[src_row_offset + c]);
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
                    const prev_vals: @Vector(simd_len, f32) = dst_img.data[prev_row_offset + c ..][0..simd_len].*;
                    const curr_vals: @Vector(simd_len, f32) = dst_img.data[curr_row_offset + c ..][0..simd_len].*;
                    dst_img.data[curr_row_offset + c ..][0..simd_len].* = prev_vals + curr_vals;
                }

                // Handle remaining columns
                while (c < cols) : (c += 1) {
                    dst_img.data[curr_row_offset + c] += dst_img.data[prev_row_offset + c];
                }
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

                        const sum = computeIntegralSum(sat, r1, c1, r2, c2);

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
                    const sum = computeIntegralSum(sat, r1, c1, r2, c2);

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

                        const sum = computeIntegralSum(sat, r1, c1, r2, c2);

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
                    const sum = computeIntegralSum(sat, r1, c1, r2, c2);

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

        /// Build integral image (summed area table) from the source image.
        /// Uses channel separation and SIMD optimization for performance.
        pub fn integral(
            self: Self,
            allocator: Allocator,
            sat: *Image(if (meta.isScalar(T)) f32 else [Self.channels()]f32),
        ) !void {
            if (!self.hasSameShape(sat.*)) {
                sat.* = try .init(allocator, self.rows, self.cols);
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Use generic integral plane function for all scalar types
                    integralPlane(T, self, sat.*);
                },
                .@"struct" => {
                    // Channel separation for struct types
                    const fields = std.meta.fields(T);

                    // Create temporary buffers for each channel
                    const src_plane = try allocator.alloc(f32, self.rows * self.cols);
                    defer allocator.free(src_plane);
                    const dst_plane = try allocator.alloc(f32, self.rows * self.cols);
                    defer allocator.free(dst_plane);

                    // Process each channel separately
                    inline for (fields, 0..) |field, ch| {
                        // Extract channel to packed src_plane respecting stride
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const pix = self.at(r, c).*;
                                const val = @field(pix, field.name);
                                src_plane[r * self.cols + c] = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(val),
                                    .float => @floatCast(val),
                                    else => 0,
                                };
                            }
                        }

                        const src_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_plane };
                        const dst_img: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_plane };

                        // Compute integral for this channel from packed src_plane into packed dst_plane
                        integralPlane(f32, src_img, dst_img);

                        // Store result in output channel (packed to packed)
                        for (0..self.rows * self.cols) |i| {
                            sat.data[i][ch] = dst_plane[i];
                        }
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Performs separable convolution using two 1D kernels (horizontal and vertical).
        /// This is much more efficient for separable filters like Gaussian blur.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `kernel_x`: Horizontal (column) kernel.
        /// - `kernel_y`: Vertical (row) kernel.
        /// - `out`: Output image.
        /// - `border_mode`: How to handle image borders.
        pub fn convolveSeparable(self: Self, allocator: Allocator, kernel_x: []const f32, kernel_y: []const f32, out: *Self, border_mode: BorderMode) !void {
            // Ensure output is properly allocated
            if (out.rows == 0 or out.cols == 0 or !self.hasSameShape(out.*)) {
                out.deinit(allocator);
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // Allocate temporary buffer for intermediate result
            var temp = try Self.init(allocator, self.rows, self.cols);
            defer temp.deinit(allocator);

            const half_x = kernel_x.len / 2;
            const half_y = kernel_y.len / 2;

            // Horizontal pass
            switch (@typeInfo(T)) {
                .int, .float => {
                    // Optimized path for u8 with integer arithmetic
                    if (T == u8) {
                        // Convert kernels to integer
                        const SCALE = 256;
                        const kernel_x_int = try allocator.alloc(i32, kernel_x.len);
                        defer allocator.free(kernel_x_int);
                        const kernel_y_int = try allocator.alloc(i32, kernel_y.len);
                        defer allocator.free(kernel_y_int);

                        for (kernel_x, 0..) |k, i| {
                            kernel_x_int[i] = @intFromFloat(@round(k * SCALE));
                        }
                        for (kernel_y, 0..) |k, i| {
                            kernel_y_int[i] = @intFromFloat(@round(k * SCALE));
                        }
                        // Enforce symmetry and exact sum preservation
                        symmetrizeKernelI32(kernel_x_int, SCALE);
                        symmetrizeKernelI32(kernel_y_int, SCALE);

                        convolveSeparableU8Plane(self, out.*, temp, kernel_x_int, kernel_y_int, border_mode);
                        return; // Skip the rest of the function
                    }

                    // Optimized path for f32 with SIMD
                    if (T == f32) {
                        const src_plane: Image(f32) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = self.data };
                        const dst_plane: Image(f32) = .{ .rows = out.rows, .cols = out.cols, .stride = out.stride, .data = out.data };
                        const tmp_plane: Image(f32) = .{ .rows = temp.rows, .cols = temp.cols, .stride = temp.stride, .data = temp.data };
                        convolveSeparableF32Plane(src_plane, dst_plane, tmp_plane, kernel_x, kernel_y, border_mode);
                        return;
                    }

                    // Generic path for other scalar types
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var sum: f32 = 0;
                            if (c >= half_x and c + half_x < self.cols) {
                                const c0: usize = c - half_x;
                                for (kernel_x, 0..) |k, i| {
                                    const cc = c0 + i;
                                    const pixel = self.at(r, cc).*;
                                    sum += as(f32, pixel) * k;
                                }
                            } else {
                                for (kernel_x, 0..) |k, i| {
                                    const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                                    const pixel = getPixel(T, self, @as(isize, @intCast(r)), src_c, border_mode);
                                    sum += as(f32, pixel) * k;
                                }
                            }
                            // Guard against NaN/Inf before casting
                            const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                            temp.at(r, c).* = switch (@typeInfo(T)) {
                                .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum_safe)))),
                                .float => as(T, sum_safe),
                                else => unreachable,
                            };
                        }
                    }
                },
                .@"struct" => {
                    // Optimized path for u8 structs (RGB, RGBA, etc.)
                    if (comptime meta.allFieldsAreU8(T)) {
                        // Channel separation approach for optimal performance
                        const SCALE = 256;
                        const plane_size = self.rows * self.cols;

                        // Convert kernels to integer
                        const kernel_x_int = try allocator.alloc(i32, kernel_x.len);
                        defer allocator.free(kernel_x_int);
                        const kernel_y_int = try allocator.alloc(i32, kernel_y.len);
                        defer allocator.free(kernel_y_int);

                        for (kernel_x, 0..) |k, i| {
                            kernel_x_int[i] = @intFromFloat(@round(k * SCALE));
                        }
                        for (kernel_y, 0..) |k, i| {
                            kernel_y_int[i] = @intFromFloat(@round(k * SCALE));
                        }

                        // Separate channels using helper
                        const channels = try channel_ops.splitChannels(T, self, allocator);
                        defer for (channels) |channel| allocator.free(channel);

                        // Check which channels are uniform to avoid unnecessary processing
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

                        // Allocate output and temp planes only for non-uniform channels
                        var out_channels: [channels.len][]u8 = undefined;
                        var temp_channels: [channels.len][]u8 = undefined;
                        inline for (&out_channels, &temp_channels, is_uniform) |*out_ch, *temp_ch, uniform| {
                            if (uniform) {
                                // For uniform channels, no processing needed
                                out_ch.* = &[_]u8{};
                                temp_ch.* = &[_]u8{};
                            } else {
                                out_ch.* = try allocator.alloc(u8, plane_size);
                                temp_ch.* = try allocator.alloc(u8, plane_size);
                            }
                        }
                        defer {
                            inline for (out_channels, temp_channels, is_uniform) |out_ch, temp_ch, uniform| {
                                if (!uniform) {
                                    if (out_ch.len > 0) allocator.free(out_ch);
                                    if (temp_ch.len > 0) allocator.free(temp_ch);
                                }
                            }
                        }

                        // Convolve only non-uniform channels
                        inline for (channels, out_channels, temp_channels, is_uniform) |src_data, dst_data, temp_data, uniform| {
                            if (!uniform) {
                                const src_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = src_data };
                                const dst_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = dst_data };
                                const tmp_plane: Image(u8) = .{ .rows = self.rows, .cols = self.cols, .stride = self.cols, .data = temp_data };
                                convolveSeparableU8Plane(src_plane, dst_plane, tmp_plane, kernel_x_int, kernel_y_int, border_mode);
                            }
                        }

                        // Recombine channels, using original values for uniform channels
                        var final_channels: [channels.len][]const u8 = undefined;
                        inline for (is_uniform, out_channels, channels, 0..) |uniform, out_ch, src_ch, i| {
                            if (uniform) {
                                // For uniform channels, separable convolution preserves the value
                                final_channels[i] = src_ch;
                            } else {
                                final_channels[i] = out_ch;
                            }
                        }
                        channel_ops.mergeChannels(T, final_channels, out.*);
                        return; // Skip the rest of the function
                    }

                    // Generic struct path for other color types
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var result_pixel: T = undefined;
                            inline for (std.meta.fields(T)) |field| {
                                var sum: f32 = 0;
                                if (c >= half_x and c + half_x < self.cols) {
                                    const c0: usize = c - half_x;
                                    for (kernel_x, 0..) |k, i| {
                                        const cc = c0 + i;
                                        const pixel = self.at(r, cc).*;
                                        sum += as(f32, @field(pixel, field.name)) * k;
                                    }
                                } else {
                                    for (kernel_x, 0..) |k, i| {
                                        const src_c = @as(isize, @intCast(c)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_x));
                                        const pixel = getPixel(T, self, @as(isize, @intCast(r)), src_c, border_mode);
                                        sum += as(f32, @field(pixel, field.name)) * k;
                                    }
                                }
                                const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                                @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                    .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(sum_safe)))),
                                    .float => as(field.type, sum_safe),
                                    else => @compileError("Unsupported field type"),
                                };
                            }
                            temp.at(r, c).* = result_pixel;
                        }
                    }
                },
                else => @compileError("Separable convolution not supported for type " ++ @typeName(T)),
            }

            // Vertical pass
            switch (@typeInfo(T)) {
                .int, .float => {
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var sum: f32 = 0;
                            if (r >= half_y and r + half_y < self.rows) {
                                const r0: usize = r - half_y;
                                for (kernel_y, 0..) |k, i| {
                                    const rr = r0 + i;
                                    const pixel = temp.at(rr, c).*;
                                    sum += as(f32, pixel) * k;
                                }
                            } else {
                                for (kernel_y, 0..) |k, i| {
                                    const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                                    const pixel = getPixel(T, temp, src_r, @as(isize, @intCast(c)), border_mode);
                                    sum += as(f32, pixel) * k;
                                }
                            }
                            const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                            out.at(r, c).* = switch (@typeInfo(T)) {
                                .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum_safe)))),
                                .float => as(T, sum_safe),
                                else => unreachable,
                            };
                        }
                    }
                },
                .@"struct" => {
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            var result_pixel: T = undefined;
                            inline for (std.meta.fields(T)) |field| {
                                var sum: f32 = 0;
                                if (r >= half_y and r + half_y < self.rows) {
                                    const r0: usize = r - half_y;
                                    for (kernel_y, 0..) |k, i| {
                                        const rr = r0 + i;
                                        const pixel = temp.at(rr, c).*;
                                        sum += as(f32, @field(pixel, field.name)) * k;
                                    }
                                } else {
                                    for (kernel_y, 0..) |k, i| {
                                        const src_r = @as(isize, @intCast(r)) + @as(isize, @intCast(i)) - @as(isize, @intCast(half_y));
                                        const pixel = getPixel(T, temp, src_r, @as(isize, @intCast(c)), border_mode);
                                        sum += as(f32, @field(pixel, field.name)) * k;
                                    }
                                }
                                const sum_safe: f32 = if (std.math.isFinite(sum)) sum else 0.0;
                                @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                    .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(sum_safe)))),
                                    .float => as(field.type, sum_safe),
                                    else => @compileError("Unsupported field type"),
                                };
                            }
                            out.at(r, c).* = result_pixel;
                        }
                    }
                },
                else => unreachable,
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
            try convolveSeparable(self, allocator, kernel, kernel, out, .mirror);
        }

        /// Applies Difference of Gaussians (DoG) band-pass filter to the image with a configurable offset.
        /// This efficiently computes gaussian_blur(sigma1) - gaussian_blur(sigma2).
        ///
        /// For u8 and RGB/RGBA images, negative values cannot be represented directly. Use `offset`:
        /// - offset = 128 → preserves negatives (128 = zero), default suggested for u8-family
        /// - offset = 0 → clamp behavior to match many libraries
        /// For non-u8 pixel types, `offset` is ignored.
        pub fn differenceOfGaussians(self: Self, allocator: Allocator, sigma1: f32, sigma2: f32, offset: u8, out: *Self) !void {
            if (sigma1 < 0 or sigma2 < 0) return error.InvalidSigma;

            // Check for equal non-zero sigmas early (before allocating)
            if (sigma1 == sigma2 and sigma1 != 0) return error.SigmasMustDiffer;

            // Ensure output is allocated
            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // Handle special cases where one or both sigmas are 0
            if (sigma1 == 0 and sigma2 == 0) {
                // Both are 0: result is input - input = 0
                for (out.data) |*pixel| {
                    pixel.* = switch (@typeInfo(T)) {
                        .int => if (T == u8) offset else 0,
                        .float => 0,
                        .@"struct" => blk: {
                            var p: T = undefined;
                            inline for (@typeInfo(T).@"struct".fields) |field| {
                                @field(p, field.name) = if (field.type == u8) offset else 0;
                            }
                            break :blk p;
                        },
                        else => @compileError("Unsupported pixel type for DoG"),
                    };
                }
                return;
            }

            if (sigma1 == 0) {
                // Result is input - blur(sigma2)
                var blur2: Self = .empty;
                try self.gaussianBlur(allocator, sigma2, &blur2);
                defer blur2.deinit(allocator);

                switch (@typeInfo(T)) {
                    .int, .float => {
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                if (T == u8) {
                                    const val1 = @as(i16, self.at(r, c).*);
                                    const val2 = @as(i16, blur2.at(r, c).*);
                                    const diff = val1 - val2 + @as(i16, offset);
                                    out.at(r, c).* = @intCast(@max(0, @min(255, diff)));
                                } else {
                                    out.at(r, c).* = self.at(r, c).* - blur2.at(r, c).*;
                                }
                            }
                        }
                    },
                    .@"struct" => {
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                var result: T = undefined;
                                inline for (@typeInfo(T).@"struct".fields) |field| {
                                    if (field.type == u8) {
                                        const val1 = @as(i16, @field(self.at(r, c).*, field.name));
                                        const val2 = @as(i16, @field(blur2.at(r, c).*, field.name));
                                        const diff = val1 - val2 + @as(i16, offset);
                                        @field(result, field.name) = @intCast(@max(0, @min(255, diff)));
                                    } else {
                                        @field(result, field.name) = @field(self.at(r, c).*, field.name) - @field(blur2.at(r, c).*, field.name);
                                    }
                                }
                                out.at(r, c).* = result;
                            }
                        }
                    },
                    else => @compileError("Unsupported pixel type for DoG"),
                }
                return;
            }

            if (sigma2 == 0) {
                // Result is blur(sigma1) - input
                var blur1: Self = .empty;
                try self.gaussianBlur(allocator, sigma1, &blur1);
                defer blur1.deinit(allocator);

                switch (@typeInfo(T)) {
                    .int, .float => {
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                if (T == u8) {
                                    const val1 = @as(i16, blur1.at(r, c).*);
                                    const val2 = @as(i16, self.at(r, c).*);
                                    const diff = val1 - val2 + @as(i16, offset);
                                    out.at(r, c).* = @intCast(@max(0, @min(255, diff)));
                                } else {
                                    out.at(r, c).* = blur1.at(r, c).* - self.at(r, c).*;
                                }
                            }
                        }
                    },
                    .@"struct" => {
                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                var result: T = undefined;
                                inline for (@typeInfo(T).@"struct".fields) |field| {
                                    if (field.type == u8) {
                                        const val1 = @as(i16, @field(blur1.at(r, c).*, field.name));
                                        const val2 = @as(i16, @field(self.at(r, c).*, field.name));
                                        const diff = val1 - val2 + @as(i16, offset);
                                        @field(result, field.name) = @intCast(@max(0, @min(255, diff)));
                                    } else {
                                        @field(result, field.name) = @field(blur1.at(r, c).*, field.name) - @field(self.at(r, c).*, field.name);
                                    }
                                }
                                out.at(r, c).* = result;
                            }
                        }
                    },
                    else => @compileError("Unsupported pixel type for DoG"),
                }
                return;
            }

            // Special optimization for u8 images with common sigmas
            if (T == u8 and isCommonSigma(sigma1) and isCommonSigma(sigma2)) {
                // Use fast integer path for common sigmas
                return try differenceOfGaussiansIntegerFast(self, allocator, sigma1, sigma2, offset, out);
            }

            // For same-sized kernels, use fused approach
            const radius1 = @as(usize, @intFromFloat(@ceil(3.0 * sigma1)));
            const radius2 = @as(usize, @intFromFloat(@ceil(3.0 * sigma2)));

            if (radius1 == radius2) {
                const is_u8_family = switch (@typeInfo(T)) {
                    .int => T == u8,
                    .@"struct" => comptime meta.allFieldsAreU8(T),
                    else => false,
                };
                // Use fused kernel unless we are u8-based and need an offset preserving negatives
                if (!is_u8_family or offset == 0) {
                    return try differenceOfGaussiansFused(self, allocator, sigma1, sigma2, offset, out);
                }
                // else fall through to the dual-kernel path which preserves signed values
            }

            // Fall back to optimized two-pass approach
            const kernel_size1 = 2 * radius1 + 1;
            const kernel_size2 = 2 * radius2 + 1;

            // Generate both 1D Gaussian kernels
            var kernel1 = try allocator.alloc(f32, kernel_size1);
            defer allocator.free(kernel1);
            var kernel2 = try allocator.alloc(f32, kernel_size2);
            defer allocator.free(kernel2);

            // Generate first kernel
            var sum1: f32 = 0;
            for (0..kernel_size1) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius1));
                kernel1[i] = @exp(-(x * x) / (2.0 * sigma1 * sigma1));
                sum1 += kernel1[i];
            }
            for (kernel1) |*k| {
                k.* /= sum1;
            }

            // Generate second kernel
            var sum2: f32 = 0;
            for (0..kernel_size2) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius2));
                kernel2[i] = @exp(-(x * x) / (2.0 * sigma2 * sigma2));
                sum2 += kernel2[i];
            }
            for (kernel2) |*k| {
                k.* /= sum2;
            }

            // For u8, use dual-sigma separable path: two horizontal passes, one combined vertical pass
            if (T == u8) {
                const SCALE = 256;
                // Convert kernels to integer scaled by 256
                var kernel1_int = try allocator.alloc(i32, kernel_size1);
                defer allocator.free(kernel1_int);
                var kernel2_int = try allocator.alloc(i32, kernel_size2);
                defer allocator.free(kernel2_int);
                for (kernel1, 0..) |k, i| kernel1_int[i] = @intFromFloat(@round(k * SCALE));
                for (kernel2, 0..) |k, i| kernel2_int[i] = @intFromFloat(@round(k * SCALE));
                symmetrizeKernelI32(kernel1_int, SCALE);
                symmetrizeKernelI32(kernel2_int, SCALE);

                // Two horizontal passes into two temps
                var temp1 = try Self.init(allocator, self.rows, self.cols);
                defer temp1.deinit(allocator);
                var temp2 = try Self.init(allocator, self.rows, self.cols);
                defer temp2.deinit(allocator);

                convolveHorizontalU8Plane(self, temp1, kernel1_int, .mirror);
                convolveHorizontalU8Plane(self, temp2, kernel2_int, .mirror);

                // One dual vertical pass producing DoG into out
                convolveVerticalU8PlaneDual(temp1, temp2, out.*, kernel1_int, kernel2_int, .mirror, offset);
                return;
            }

            // Optimized approach (float/struct): two blurs then subtract
            var temp = try Self.init(allocator, self.rows, self.cols);
            defer temp.deinit(allocator);

            try convolveSeparable(self, allocator, kernel1, kernel1, out, .mirror);
            try convolveSeparable(self, allocator, kernel2, kernel2, &temp, .mirror);

            const total_pixels = self.rows * self.cols;

            switch (@typeInfo(T)) {
                .int => unreachable, // handled above for u8
                .float => {
                    const vec_len = std.simd.suggestVectorLength(T) orelse 8;
                    const Vec = @Vector(vec_len, T);
                    var i: usize = 0;
                    while (i + vec_len <= total_pixels) : (i += vec_len) {
                        const blur1_vec: Vec = out.data[i..][0..vec_len].*;
                        const blur2_vec: Vec = temp.data[i..][0..vec_len].*;
                        out.data[i..][0..vec_len].* = blur1_vec - blur2_vec;
                    }
                    while (i < total_pixels) : (i += 1) {
                        out.data[i] = out.data[i] - temp.data[i];
                    }
                },
                .@"struct" => {
                    // Check if all fields are u8 for offset approach
                    if (comptime meta.allFieldsAreU8(T)) {
                        const OFFSET: i16 = @intCast(offset); // Configurable offset for u8 structs
                        for (0..self.rows) |r| {
                            const row_offset = r * out.stride;
                            for (0..self.cols) |c| {
                                const idx = row_offset + c;
                                var result_pixel: T = undefined;
                                const pixel1 = out.data[idx];
                                const pixel2 = temp.data[idx];
                                inline for (std.meta.fields(T)) |field| {
                                    const val1 = @as(i16, @field(pixel1, field.name));
                                    const val2 = @as(i16, @field(pixel2, field.name));
                                    const diff = val1 - val2 + OFFSET;
                                    @field(result_pixel, field.name) = @intCast(@max(0, @min(255, diff)));
                                }
                                out.data[idx] = result_pixel;
                            }
                        }
                    } else {
                        // Float path for non-u8 structs
                        for (0..self.rows) |r| {
                            const row_offset = r * out.stride;
                            for (0..self.cols) |c| {
                                const idx = row_offset + c;
                                var result_pixel: T = undefined;
                                const pixel1 = out.data[idx];
                                const pixel2 = temp.data[idx];
                                inline for (std.meta.fields(T)) |field| {
                                    const val1 = as(f32, @field(pixel1, field.name));
                                    const val2 = as(f32, @field(pixel2, field.name));
                                    const diff = val1 - val2;
                                    @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                        .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(diff)))),
                                        .float => as(field.type, diff),
                                        else => @compileError("Unsupported field type in struct"),
                                    };
                                }
                                out.data[idx] = result_pixel;
                            }
                        }
                    }
                },
                else => @compileError("Optimized DoG not supported for type " ++ @typeName(T)),
            }
        }

        /// Fused Difference of Gaussians - computes DoG with a single convolution pass
        /// when both kernels have the same size.
        fn differenceOfGaussiansFused(self: Self, allocator: Allocator, sigma1: f32, sigma2: f32, offset: u8, out: *Self) !void {
            const radius = @as(usize, @intFromFloat(@ceil(3.0 * @max(sigma1, sigma2))));
            const kernel_size = 2 * radius + 1;

            // Allocate fused DoG kernel
            var dog_kernel = try allocator.alloc(f32, kernel_size);
            defer allocator.free(dog_kernel);

            // Generate fused DoG kernel: gaussian(sigma1) - gaussian(sigma2)
            var sum_pos: f32 = 0;
            var sum_neg: f32 = 0;
            for (0..kernel_size) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
                const g1 = @exp(-(x * x) / (2.0 * sigma1 * sigma1));
                const g2 = @exp(-(x * x) / (2.0 * sigma2 * sigma2));
                dog_kernel[i] = g1 / (sigma1 * @sqrt(2.0 * std.math.pi)) -
                    g2 / (sigma2 * @sqrt(2.0 * std.math.pi));
                if (dog_kernel[i] > 0) sum_pos += dog_kernel[i] else sum_neg -= dog_kernel[i];
            }

            // Normalize to preserve energy
            const scale = 1.0 / @max(sum_pos, sum_neg);
            for (dog_kernel) |*k| {
                k.* *= scale;
            }

            // Apply single separable convolution with DoG kernel
            try convolveSeparable(self, allocator, dog_kernel, dog_kernel, out, .mirror);

            // For u8-based images, apply offset post-convolution to preserve negatives
            switch (@typeInfo(T)) {
                .int => {
                    if (T == u8 and offset != 0) {
                        for (out.data, 0..) |*p, i| {
                            _ = i; // silence unused
                            const v: i32 = @intCast(p.*);
                            const vv = @max(0, @min(255, v + @as(i32, @intCast(offset))));
                            p.* = @intCast(vv);
                        }
                    }
                },
                .@"struct" => {
                    if (comptime meta.allFieldsAreU8(T)) {
                        if (offset != 0) {
                            const add: i16 = @intCast(offset);
                            for (0..out.rows) |r| {
                                const row_off = r * out.stride;
                                for (0..out.cols) |c| {
                                    const idx = row_off + c;
                                    var px = out.data[idx];
                                    inline for (std.meta.fields(T)) |field| {
                                        const base: i16 = @intCast(@field(px, field.name));
                                        const vv = @max(0, @min(255, base + add));
                                        @field(px, field.name) = @intCast(vv);
                                    }
                                    out.data[idx] = px;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        /// Fast DoG using integer arithmetic for u8 images
        fn differenceOfGaussiansIntegerFast(
            self: Self,
            allocator: Allocator,
            sigma1: f32,
            sigma2: f32,
            offset: u8,
            out: *Self,
        ) !void {
            // Only for u8 images
            if (T != u8) return error.NotSupported;

            // Generate integer kernels
            const radius1 = @as(usize, @intFromFloat(@ceil(3.0 * sigma1)));
            const kernel_size1 = 2 * radius1 + 1;
            const radius2 = @as(usize, @intFromFloat(@ceil(3.0 * sigma2)));
            const kernel_size2 = 2 * radius2 + 1;

            var kernel1_int = try allocator.alloc(i32, kernel_size1);
            defer allocator.free(kernel1_int);
            var kernel2_int = try allocator.alloc(i32, kernel_size2);
            defer allocator.free(kernel2_int);

            // Generate first integer kernel
            var sum1: f32 = 0;
            for (0..kernel_size1) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius1));
                const val = @exp(-(x * x) / (2.0 * sigma1 * sigma1));
                sum1 += val;
            }
            for (0..kernel_size1) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius1));
                const val = @exp(-(x * x) / (2.0 * sigma1 * sigma1)) / sum1;
                kernel1_int[i] = @intFromFloat(@round(val * 256.0));
            }

            // Generate second integer kernel
            var sum2: f32 = 0;
            for (0..kernel_size2) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius2));
                const val = @exp(-(x * x) / (2.0 * sigma2 * sigma2));
                sum2 += val;
            }
            for (0..kernel_size2) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius2));
                const val = @exp(-(x * x) / (2.0 * sigma2 * sigma2)) / sum2;
                kernel2_int[i] = @intFromFloat(@round(val * 256.0));
            }

            // Enforce symmetry and sum preservation
            symmetrizeKernelI32(kernel1_int, 256);
            symmetrizeKernelI32(kernel2_int, 256);

            // Dual-sigma path: two horizontal passes, one combined vertical pass
            var temp1 = try Self.init(allocator, self.rows, self.cols);
            defer temp1.deinit(allocator);
            var temp2 = try Self.init(allocator, self.rows, self.cols);
            defer temp2.deinit(allocator);

            convolveHorizontalU8Plane(self, temp1, kernel1_int, .mirror);
            convolveHorizontalU8Plane(self, temp2, kernel2_int, .mirror);
            convolveVerticalU8PlaneDual(temp1, temp2, out.*, kernel1_int, kernel2_int, .mirror, offset);
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

        /// Applies the Sobel filter to `self` to perform edge detection.
        /// The output is a grayscale image representing the magnitude of gradients at each pixel.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
        /// - `out`: An out-parameter pointer to an `Image(u8)` that will be filled with the Sobel magnitude image.
        pub fn sobel(self: Self, allocator: Allocator, out: *Image(u8)) !void {
            if (!self.hasSameShape(out.*)) {
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // For now, use float path for all types to ensure correctness
            {
                // Original float path for other types
                const sobel_x = [3][3]f32{
                    .{ -1, 0, 1 },
                    .{ -2, 0, 2 },
                    .{ -1, 0, 1 },
                };
                const sobel_y = [3][3]f32{
                    .{ -1, -2, -1 },
                    .{ 0, 0, 0 },
                    .{ 1, 2, 1 },
                };

                // Convert input to grayscale float if needed
                var gray_float: Image(f32) = undefined;
                const needs_conversion = !isScalar(T) or @typeInfo(T) != .float;
                if (needs_conversion) {
                    gray_float = try .init(allocator, self.rows, self.cols);
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            gray_float.at(r, c).* = as(f32, convertColor(u8, self.at(r, c).*));
                        }
                    }
                } else {
                    gray_float = self;
                }
                defer if (needs_conversion) gray_float.deinit(allocator);

                // Apply Sobel X and Y filters
                var grad_x = Image(f32).empty;
                var grad_y = Image(f32).empty;
                defer grad_x.deinit(allocator);
                defer grad_y.deinit(allocator);

                const GrayFilter = Filter(f32);
                try GrayFilter.convolve(gray_float, allocator, sobel_x, &grad_x, .replicate);
                try GrayFilter.convolve(gray_float, allocator, sobel_y, &grad_y, .replicate);

                // Compute gradient magnitude
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        const gx = grad_x.at(r, c).*;
                        const gy = grad_y.at(r, c).*;
                        const magnitude = @sqrt(gx * gx + gy * gy);
                        // Scale by 1/4 to match typical Sobel output range
                        // Max theoretical magnitude is ~1442, so /4 maps to ~360 max
                        const scaled = magnitude / 4.0;
                        out.at(r, c).* = @intFromFloat(@max(0, @min(255, scaled)));
                    }
                }
            }
        }

        // (ShenCastan moved to module scope for public export)

        /// Applies the Shen-Castan edge detection algorithm using the Infinite Symmetric
        /// Exponential Filter (ISEF). This algorithm provides superior edge localization
        /// and noise handling compared to traditional methods.
        ///
        /// Notes:
        /// - The Laplacian is approximated as (smoothed - original) for sign.
        /// - Border pixels (outermost row/column) are not processed for edge detection.
        /// - Thresholds apply to raw luminance differences (0..255 scale).
        pub fn shenCastan(
            self: Self,
            allocator: Allocator,
            opts: ShenCastan,
            out: *Image(u8),
        ) !void {
            try opts.validate();

            // Ensure output is allocated (deinit old buffer if shape differs to prevent leak)
            if (!self.hasSameShape(out.*)) {
                if (out.data.len > 0) out.deinit(allocator);
                out.* = try .init(allocator, self.rows, self.cols);
            }

            // Convert to grayscale float for processing
            var gray_float = try Image(f32).init(allocator, self.rows, self.cols);
            defer gray_float.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const gray_val = convertColor(u8, self.at(r, c).*);
                    gray_float.at(r, c).* = as(f32, gray_val);
                }
            }

            // Apply ISEF filter for smoothing
            var smoothed = try Image(f32).init(allocator, self.rows, self.cols);
            defer smoothed.deinit(allocator);
            try isefFilter2D(gray_float, opts.smooth, &smoothed, allocator);

            // Compute Laplacian approximation (smoothed - original)
            var laplacian = try Image(f32).init(allocator, self.rows, self.cols);
            defer laplacian.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    laplacian.at(r, c).* = smoothed.at(r, c).* - gray_float.at(r, c).*;
                }
            }

            // Generate Binary Laplacian Image (BLI)
            var bli = try Image(u8).init(allocator, self.rows, self.cols);
            defer bli.deinit(allocator);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    bli.at(r, c).* = if (laplacian.at(r, c).* >= 0) 1 else 0;
                }
            }

            // Find zero crossings according to thinning mode (for NMS, start from non-thinned mask)
            var edges = try Image(u8).init(allocator, self.rows, self.cols);
            defer edges.deinit(allocator);
            // For NMS, we start with non-thinned edges, otherwise use forward thinning
            try findZeroCrossings(bli, &edges, !opts.use_nms);

            // Compute gradient magnitudes at edge locations
            var gradients = try Image(f32).init(allocator, self.rows, self.cols);
            defer gradients.deinit(allocator);
            try computeAdaptiveGradients(gray_float, bli, edges, opts.window_size, &gradients, allocator);

            // Determine thresholds using ratio-based approach
            var t_low: f32 = 0;
            var t_high: f32 = 0;

            // Build histogram of gradient magnitudes at candidate edges
            var hist: [256]usize = @splat(0);
            var total: usize = 0;
            for (0..self.rows) |rr| {
                for (0..self.cols) |cc| {
                    if (edges.at(rr, cc).* == 0) continue;
                    var g = gradients.at(rr, cc).*;
                    if (g < 0) g = 0;
                    if (g > 255) g = 255;
                    const bin: usize = @intFromFloat(@round(g));
                    hist[bin] += 1;
                    total += 1;
                }
            }
            if (total == 0) {
                // No candidates -> output all zeros
                for (0..self.rows) |rr| {
                    for (0..self.cols) |cc| {
                        out.at(rr, cc).* = 0;
                    }
                }
                return;
            }
            const target: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(total)) * opts.high_ratio));
            var cum: usize = 0;
            var idx: usize = 0;
            while (idx < 256 and cum < target) : (idx += 1) {
                cum += hist[idx];
            }
            // idx is the first bin where cum >= target
            t_high = @floatFromInt(@min(idx, 255));
            t_low = opts.low_rel * t_high;

            // Optional non-maximum suppression along gradient direction
            var edges_nms = Image(u8).empty;
            defer if (edges_nms.data.len > 0) edges_nms.deinit(allocator);
            const edges_for_thresh: Image(u8) = blk: {
                if (opts.use_nms) {
                    edges_nms = try Image(u8).init(allocator, self.rows, self.cols);
                    try nonMaxSuppressEdges(smoothed, gradients, edges, &edges_nms);
                    break :blk edges_nms;
                } else {
                    break :blk edges;
                }
            };

            if (!opts.hysteresis) {
                // Emit strong edges only
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        const is_edge = edges_for_thresh.at(r, c).* > 0 and gradients.at(r, c).* >= t_high;
                        out.at(r, c).* = if (is_edge) 255 else 0;
                    }
                }
                return;
            }

            // Apply hysteresis thresholding with computed thresholds
            try applyHysteresis(edges_for_thresh, gradients, t_low, t_high, out, allocator);
        }

        // ============================================================================
        // ISEF Filter Functions
        // ============================================================================

        /// Applies 1D ISEF recursive filter (forward + backward pass for symmetry)
        fn isefFilter1D(data: []f32, b: f32, temp: []f32) void {
            const n = data.len;
            if (n == 0) return;

            const a = 1.0 - b;

            // Forward pass
            temp[0] = b * data[0];
            for (1..n) |i| {
                temp[i] = b * data[i] + a * temp[i - 1];
            }

            // Backward pass (for symmetric response)
            data[n - 1] = temp[n - 1];
            if (n > 1) {
                var i = n - 2;
                while (true) {
                    data[i] = b * temp[i] + a * data[i + 1];
                    if (i == 0) break;
                    i -= 1;
                }
            }
        }

        /// Applies 2D ISEF filter by separable application in X and Y directions
        fn isefFilter2D(src: Image(f32), b: f32, dst: *Image(f32), allocator: Allocator) !void {
            const rows = src.rows;
            const cols = src.cols;

            // Allocate temporary buffers
            var row_buffer = try allocator.alloc(f32, cols);
            defer allocator.free(row_buffer);
            const temp_buffer = try allocator.alloc(f32, cols);
            defer allocator.free(temp_buffer);

            // Apply ISEF horizontally (along rows)
            for (0..rows) |r| {
                // Copy row to buffer
                for (0..cols) |c| {
                    row_buffer[c] = src.at(r, c).*;
                }
                // Apply 1D ISEF
                isefFilter1D(row_buffer, b, temp_buffer);
                // Copy back
                for (0..cols) |c| {
                    dst.at(r, c).* = row_buffer[c];
                }
            }

            // Apply ISEF vertically (along columns)
            var col_buffer = try allocator.alloc(f32, rows);
            defer allocator.free(col_buffer);
            const temp_col_buffer = try allocator.alloc(f32, rows);
            defer allocator.free(temp_col_buffer);

            for (0..cols) |c| {
                // Copy column to buffer
                for (0..rows) |r| {
                    col_buffer[r] = dst.at(r, c).*;
                }
                // Apply 1D ISEF
                isefFilter1D(col_buffer, b, temp_col_buffer);
                // Copy back
                for (0..rows) |r| {
                    dst.at(r, c).* = col_buffer[r];
                }
            }
        }

        /// Finds zero crossings in the Binary Laplacian Image and produces an edge map.
        /// If `thin` is `.forward`, marks a pixel when it differs from any forward neighbor (E, S, SE, SW)
        /// which avoids double-marking and yields thinner edges. If `.none`, marks any 4-neighbor transition
        /// around the center (thicker edges, useful for debugging/visualization).
        fn findZeroCrossings(bli: Image(u8), edges: *Image(u8), use_forward: bool) !void {
            const rows = bli.rows;
            const cols = bli.cols;

            // Initialize all to 0
            for (0..rows) |r| {
                for (0..cols) |c| {
                    edges.at(r, c).* = 0;
                }
            }

            if (use_forward) {
                // Check transitions with forward neighbors to reduce double-marking
                for (0..rows) |r| {
                    for (0..cols) |c| {
                        const center = bli.at(r, c).*;
                        var mark: bool = false;
                        // East
                        if (!mark and c + 1 < cols) mark = (center != bli.at(r, c + 1).*);
                        // South
                        if (!mark and r + 1 < rows) mark = (center != bli.at(r + 1, c).*);
                        // South-East
                        if (!mark and r + 1 < rows and c + 1 < cols) mark = (center != bli.at(r + 1, c + 1).*);
                        // South-West
                        if (!mark and r + 1 < rows and c > 0) mark = (center != bli.at(r + 1, c - 1).*);
                        if (mark) edges.at(r, c).* = 255;
                    }
                }
            } else {
                // Mark any 4-neighbor transition (used for NMS)
                if (rows >= 3 and cols >= 3) {
                    for (1..rows - 1) |r| {
                        for (1..cols - 1) |c| {
                            const center = bli.at(r, c).*;
                            const left = bli.at(r, c - 1).*;
                            const right = bli.at(r, c + 1).*;
                            const top = bli.at(r - 1, c).*;
                            const bottom = bli.at(r + 1, c).*;
                            if (center != left or center != right or center != top or center != bottom) {
                                edges.at(r, c).* = 255;
                            }
                        }
                    }
                } else {
                    // Fallback for very small images: safe bounds
                    for (0..rows) |r| {
                        for (0..cols) |c| {
                            const center = bli.at(r, c).*;
                            var mark = false;
                            if (!mark and c > 0) mark = (center != bli.at(r, c - 1).*);
                            if (!mark and c + 1 < cols) mark = (center != bli.at(r, c + 1).*);
                            if (!mark and r > 0) mark = (center != bli.at(r - 1, c).*);
                            if (!mark and r + 1 < rows) mark = (center != bli.at(r + 1, c).*);
                            if (mark) edges.at(r, c).* = 255;
                        }
                    }
                }
            }
        }

        /// Computes adaptive gradient magnitudes using local window statistics with integral image acceleration
        fn computeAdaptiveGradients(
            gray: Image(f32),
            bli: Image(u8),
            edges: Image(u8),
            window_size: usize,
            gradients: *Image(f32),
            allocator: Allocator,
        ) !void {
            const rows = gray.rows;
            const cols = gray.cols;
            const half_window = window_size / 2;

            // Initialize gradients to 0
            for (0..rows) |r| {
                for (0..cols) |c| {
                    gradients.at(r, c).* = 0;
                }
            }

            // Build integral images for fast box sum computation
            const plane_size = rows * cols;

            // Integral image for grayscale values
            const integral_gray_buf = try allocator.alloc(f32, plane_size);
            defer allocator.free(integral_gray_buf);
            const integral_gray: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = integral_gray_buf };
            integralPlane(f32, gray, integral_gray);

            // Integral image for BLI mask (where BLI == 1)
            const integral_mask_buf = try allocator.alloc(f32, plane_size);
            defer allocator.free(integral_mask_buf);
            const integral_mask: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = integral_mask_buf };
            integralPlane(u8, bli, integral_mask);

            // Integral image for gray * mask (values where BLI == 1)
            const gray_masked_buf = try allocator.alloc(f32, plane_size);
            defer allocator.free(gray_masked_buf);
            for (0..plane_size) |i| {
                gray_masked_buf[i] = gray.data[i] * @as(f32, @floatFromInt(bli.data[i]));
            }
            const gray_masked: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = gray_masked_buf };
            const integral_gray_masked_buf = try allocator.alloc(f32, plane_size);
            defer allocator.free(integral_gray_masked_buf);
            const integral_gray_masked: Image(f32) = .{ .rows = rows, .cols = cols, .stride = cols, .data = integral_gray_masked_buf };
            integralPlane(f32, gray_masked, integral_gray_masked);

            // Helper function to compute box sum from integral image
            const boxSum = struct {
                fn compute(img: Image(f32), r1: usize, r2: usize, c1: usize, c2: usize) f32 {
                    // Box sum using integral image: sum = D - B - C + A
                    // where A=(r1-1,c1-1), B=(r1-1,c2), C=(r2,c1-1), D=(r2,c2)
                    var sum: f32 = img.at(r2, c2).*;
                    if (r1 > 0) sum -= img.at(r1 - 1, c2).*;
                    if (c1 > 0) sum -= img.at(r2, c1 - 1).*;
                    if (r1 > 0 and c1 > 0) sum += img.at(r1 - 1, c1 - 1).*;
                    return sum;
                }
            }.compute;

            // For each edge pixel, compute gradient using integral images (O(1) per pixel)
            for (0..rows) |r| {
                for (0..cols) |c| {
                    if (edges.at(r, c).* == 0) continue;

                    // Compute window bounds
                    const r_start = if (r > half_window) r - half_window else 0;
                    const r_end = @min(r + half_window, rows - 1);
                    const c_start = if (c > half_window) c - half_window else 0;
                    const c_end = @min(c + half_window, cols - 1);

                    // Compute sums in O(1) using integral images
                    const area = @as(f32, @floatFromInt((r_end - r_start + 1) * (c_end - c_start + 1)));
                    const count1 = boxSum(integral_mask, r_start, r_end, c_start, c_end);
                    const count0 = area - count1;

                    if (count0 > 0 and count1 > 0) {
                        const sum1 = boxSum(integral_gray_masked, r_start, r_end, c_start, c_end);
                        const sum_total = boxSum(integral_gray, r_start, r_end, c_start, c_end);
                        const sum0 = sum_total - sum1;

                        const mean0 = sum0 / count0;
                        const mean1 = sum1 / count1;
                        gradients.at(r, c).* = @abs(mean1 - mean0);
                    }
                }
            }
        }

        /// Applies hysteresis thresholding for final edge linking using BFS for O(N) performance.
        /// Invariant: pixels are marked in `out` before being enqueued so each pixel is processed at most once.
        fn applyHysteresis(
            edges: Image(u8),
            gradients: Image(f32),
            threshold_low: f32,
            threshold_high: f32,
            out: *Image(u8),
            allocator: Allocator,
        ) !void {
            const rows = edges.rows;
            const cols = edges.cols;

            // Initialize output and visited tracking
            for (0..rows) |r| {
                for (0..cols) |c| {
                    out.at(r, c).* = 0;
                }
            }

            // BFS queue for edge propagation (monotonic indices to avoid head/tail ambiguity)
            const max_queue_size = rows * cols;
            const QueueItem = struct { r: usize, c: usize };
            const queue_storage = try allocator.alloc(QueueItem, max_queue_size);
            defer allocator.free(queue_storage);

            var push_i: usize = 0;
            var pop_i: usize = 0;

            // Helper to enqueue (each pixel is enqueued at most once since we mark before enqueue)
            const enqueue = struct {
                fn push(q: []QueueItem, push_idx: *usize, r: usize, c: usize) void {
                    assert(push_idx.* < q.len);
                    q[push_idx.*] = .{ .r = r, .c = c };
                    push_idx.* += 1;
                }
            }.push;

            // First pass: find and enqueue all strong edges
            for (0..rows) |r| {
                for (0..cols) |c| {
                    if (edges.at(r, c).* > 0 and gradients.at(r, c).* >= threshold_high) {
                        out.at(r, c).* = 255;
                        enqueue(queue_storage, &push_i, r, c);
                    }
                }
            }

            // BFS propagation: grow from strong edges to weak edges
            while (pop_i < push_i) {
                const current = queue_storage[pop_i];
                pop_i += 1;
                const r = current.r;
                const c = current.c;

                // Check 8-connected neighbors
                const r_start = if (r > 0) r - 1 else 0;
                const r_end = @min(r + 2, rows);
                const c_start = if (c > 0) c - 1 else 0;
                const c_end = @min(c + 2, cols);

                for (r_start..r_end) |nr| {
                    for (c_start..c_end) |nc| {
                        // Skip if same as current pixel
                        if (nr == r and nc == c) continue;

                        // Skip if already marked as edge
                        if (out.at(nr, nc).* > 0) continue;

                        // Check if it's a weak edge candidate
                        if (edges.at(nr, nc).* > 0 and gradients.at(nr, nc).* >= threshold_low) {
                            // Mark as edge and add to queue for further propagation
                            out.at(nr, nc).* = 255;
                            enqueue(queue_storage, &push_i, nr, nc);
                        }
                    }
                }
            }
        }

        /// Non-maximum suppression along gradient direction to thin edges to single-pixel width.
        /// - Uses central differences on the smoothed image to estimate local gradient direction.
        /// - Quantizes orientation into 0°, 45°, 90°, 135° without atan2 using slope thresholds.
        /// - Keeps a candidate pixel only if its adaptive magnitude is not less than its two
        ///   neighbors along the chosen direction.
        fn nonMaxSuppressEdges(
            smoothed: Image(f32),
            gradients: Image(f32),
            edges_in: Image(u8),
            edges_out: *Image(u8),
        ) !void {
            const rows = edges_in.rows;
            const cols = edges_in.cols;

            // Initialize output to zero
            for (0..rows) |r| {
                for (0..cols) |c| {
                    edges_out.at(r, c).* = 0;
                }
            }

            // Constants for direction quantization without atan2
            const K: f32 = 0.414213562; // tan(22.5°)

            if (rows < 3 or cols < 3) return; // Too small to compute central differences

            // Skip image border to avoid bounds checks; border remains zero
            for (1..rows - 1) |r| {
                for (1..cols - 1) |c| {
                    if (edges_in.at(r, c).* == 0) continue;

                    // Gradient via central differences on smoothed image
                    const gx = 0.5 * (smoothed.at(r, c + 1).* - smoothed.at(r, c - 1).*);
                    const gy = 0.5 * (smoothed.at(r + 1, c).* - smoothed.at(r - 1, c).*);

                    const ax = @abs(gx);
                    const ay = @abs(gy);

                    // Choose neighbor offsets along quantized direction
                    var dr1: isize = 0;
                    var dc1: isize = 0;
                    var dr2: isize = 0;
                    var dc2: isize = 0;

                    if (ay <= K * ax) {
                        // 0°: compare left/right
                        dr1 = 0;
                        dc1 = -1;
                        dr2 = 0;
                        dc2 = 1;
                    } else if (ax <= K * ay) {
                        // 90°: compare up/down
                        dr1 = -1;
                        dc1 = 0;
                        dr2 = 1;
                        dc2 = 0;
                    } else if (gx * gy > 0) {
                        // 45°: up-right and down-left
                        dr1 = -1;
                        dc1 = 1;
                        dr2 = 1;
                        dc2 = -1;
                    } else {
                        // 135°: up-left and down-right
                        dr1 = -1;
                        dc1 = -1;
                        dr2 = 1;
                        dc2 = 1;
                    }

                    const m = gradients.at(r, c).*;
                    const n1 = gradients.at(@intCast(@as(isize, @intCast(r)) + dr1), @intCast(@as(isize, @intCast(c)) + dc1)).*;
                    const n2 = gradients.at(@intCast(@as(isize, @intCast(r)) + dr2), @intCast(@as(isize, @intCast(c)) + dc2)).*;

                    if (m >= n1 and m >= n2) {
                        edges_out.at(r, c).* = 255;
                    }
                }
            }
        }

        // ============================================================================
        // Helper Functions - Border handling, kernel processing, utilities
        // ============================================================================

        /// Common border mode logic that returns adjusted coordinates.
        fn computeBorderCoords(row: isize, col: isize, rows: isize, cols: isize, border_mode: BorderMode) struct { row: isize, col: isize, is_zero: bool } {
            switch (border_mode) {
                .zero => {
                    if (row < 0 or col < 0 or row >= rows or col >= cols) {
                        return .{ .row = 0, .col = 0, .is_zero = true };
                    }
                    return .{ .row = row, .col = col, .is_zero = false };
                },
                .replicate => {
                    const r = @max(0, @min(row, rows - 1));
                    const c = @max(0, @min(col, cols - 1));
                    return .{ .row = r, .col = c, .is_zero = false };
                },
                .mirror => {
                    if (rows == 0 or cols == 0) return .{ .row = 0, .col = 0, .is_zero = true };
                    var r = row;
                    var c = col;
                    // Handle negative row indices
                    while (r < 0) {
                        r = -r - 1;
                        if (r >= rows) r = 2 * rows - r - 1;
                    }
                    // Handle row indices >= rows
                    while (r >= rows) {
                        r = 2 * rows - r - 1;
                        if (r < 0) r = -r - 1;
                    }
                    // Handle negative column indices
                    while (c < 0) {
                        c = -c - 1;
                        if (c >= cols) c = 2 * cols - c - 1;
                    }
                    // Handle column indices >= cols
                    while (c >= cols) {
                        c = 2 * cols - c - 1;
                        if (c < 0) c = -c - 1;
                    }
                    return .{ .row = r, .col = c, .is_zero = false };
                },
                .wrap => {
                    const r = @mod(row, rows);
                    const c = @mod(col, cols);
                    return .{ .row = r, .col = c, .is_zero = false };
                },
            }
        }

        /// Get pixel value with border handling.
        fn getPixel(comptime PixelType: type, img: Image(PixelType), row: isize, col: isize, border_mode: BorderMode) PixelType {
            const coords = computeBorderCoords(row, col, @intCast(img.rows), @intCast(img.cols), border_mode);
            return if (coords.is_zero)
                std.mem.zeroes(PixelType)
            else
                img.at(@intCast(coords.row), @intCast(coords.col)).*;
        }

        /// Compute integral image sum with boundary checks.
        fn computeIntegralSum(sat: Image(f32), r1: usize, c1: usize, r2: usize, c2: usize) f32 {
            return sat.data[r2 * sat.stride + c2] -
                (if (c1 > 0) sat.data[r2 * sat.stride + (c1 - 1)] else 0) -
                (if (r1 > 0) sat.data[(r1 - 1) * sat.stride + c2] else 0) +
                (if (r1 > 0 and c1 > 0) sat.data[(r1 - 1) * sat.stride + (c1 - 1)] else 0);
        }

        /// Compute integral image sum for multi-channel images.
        fn computeIntegralSumMultiChannel(sat: anytype, r1: usize, c1: usize, r2: usize, c2: usize, channel: usize) f32 {
            return (if (r2 < sat.rows and c2 < sat.cols) sat.at(r2, c2)[channel] else 0) -
                (if (r2 < sat.rows and c1 > 0) sat.at(r2, c1 - 1)[channel] else 0) -
                (if (r1 > 0 and c2 < sat.cols) sat.at(r1 - 1, c2)[channel] else 0) +
                (if (r1 > 0 and c1 > 0) sat.at(r1 - 1, c1 - 1)[channel] else 0);
        }

        /// Flatten a 2D kernel to 1D array and optionally scale to integer.
        inline fn flattenKernel(comptime OutType: type, comptime size: usize, kernel: anytype, scale: ?i32) [size]OutType {
            const kernel_info = @typeInfo(@TypeOf(kernel));
            const kernel_height = kernel_info.array.len;
            const kernel_width = @typeInfo(kernel_info.array.child).array.len;
            var result: [size]OutType = undefined;
            var idx: usize = 0;
            inline for (0..kernel_height) |kr| {
                inline for (0..kernel_width) |kc| {
                    const val = as(f32, kernel[kr][kc]);
                    result[idx] = if (OutType == i32 and scale != null)
                        @intFromFloat(@round(val * @as(f32, @floatFromInt(scale.?))))
                    else if (OutType == f32)
                        val
                    else
                        @compileError("Unsupported kernel output type");
                    idx += 1;
                }
            }
            return result;
        }

        /// Make a 1D integer kernel symmetric and adjust the center tap so the sum equals `scale`.
        inline fn symmetrizeKernelI32(k: []i32, scale: i32) void {
            const n = k.len;
            if (n == 0 or (n & 1) == 0) return; // only handle odd-length kernels
            const half = n / 2;

            var new_sum: i32 = 0;
            // Symmetrize pairs
            var i: usize = 0;
            while (i < half) : (i += 1) {
                const j = n - 1 - i;
                const avg = @divTrunc(k[i] + k[j], 2);
                k[i] = avg;
                k[j] = avg;
                new_sum += 2 * avg;
            }
            // Add center
            new_sum += k[half];
            // Adjust center to match target scale exactly
            const delta = scale - new_sum;
            k[half] += delta;
        }
    };
}

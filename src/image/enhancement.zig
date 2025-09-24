const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const Rgb = @import("../color.zig").Rgb;
const Rgba = @import("../color.zig").Rgba;
const meta = @import("../meta.zig");
const as = meta.as;
const channel_ops = @import("channel_ops.zig");
const Integral = @import("integral.zig").Integral;

/// Histogram-based image enhancement operations.
/// Provides functions for adjusting contrast and equalizing histograms.
pub fn Enhancement(comptime T: type) type {
    return struct {
        /// Automatically adjusts the contrast by stretching the intensity range.
        /// Modifies the image in-place.
        ///
        /// Parameters:
        /// - `cutoff`: Fraction of pixels to ignore from each end (0.0 to 0.5)
        pub fn autocontrast(self: Image(T), allocator: Allocator, cutoff: f32) !void {
            if (cutoff < 0 or cutoff >= 0.5) {
                return error.InvalidCutoff; // Can't ignore 50% or more from each end
            }

            const total_pixels = self.rows * self.cols;
            const cutoff_pixels = @as(usize, @intFromFloat(@as(f32, @floatFromInt(total_pixels)) * cutoff));

            switch (@typeInfo(T)) {
                .int => {
                    // For grayscale images, use histogram module
                    const hist = self.histogram();
                    const min_val = hist.findCutoffMin(@intCast(cutoff_pixels));
                    const max_val = hist.findCutoffMax(@intCast(cutoff_pixels));

                    // Avoid division by zero
                    const range = if (max_val > min_val) max_val - min_val else 1;

                    // Apply remapping in-place
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            const val = self.at(r, c).*;
                            const clamped = @max(min_val, @min(max_val, val));
                            const normalized = @as(f32, @floatFromInt(clamped - min_val)) / @as(f32, @floatFromInt(range));
                            self.at(r, c).* = @intFromFloat(normalized * 255.0);
                        }
                    }
                },
                .@"struct" => {
                    // For RGB/RGBA images, process each channel independently
                    if (T == Rgb or T == Rgba) {
                        // Use histogram module
                        const hist = self.histogram();
                        const mins = hist.findCutoffMin(@intCast(cutoff_pixels));
                        const maxs = hist.findCutoffMax(@intCast(cutoff_pixels));

                        // Apply remapping in-place
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

                                self.at(r, c).* = new_pixel;
                            }
                        }
                    } else {
                        // For other color types, convert to RGB, process, and convert back
                        var rgb_img = try self.convert(Rgb, allocator);
                        defer rgb_img.deinit(allocator);

                        try Enhancement(Rgb).autocontrast(&rgb_img, allocator, cutoff);

                        const converted_back = try rgb_img.convert(T, allocator);
                        defer converted_back.deinit(allocator);

                        // Copy the result back to self
                        @memcpy(self.data[0..self.data.len], converted_back.data[0..converted_back.data.len]);
                    }
                },
                else => return error.UnsupportedType,
            }
        }

        /// Equalizes the histogram to improve contrast.
        /// Modifies the image in-place.
        pub fn equalize(self: Image(T), allocator: Allocator) !void {
            _ = allocator; // Will be used for other color type conversions
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

                    // Apply the lookup table in-place
                    for (0..self.rows) |r| {
                        for (0..self.cols) |c| {
                            const val = self.at(r, c).*;
                            self.at(r, c).* = lut[val];
                        }
                    }
                },
                .@"struct" => {
                    // For RGB/RGBA images, process each channel independently
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

                        // Apply the lookup tables in-place
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

                                self.at(r, c).* = new_pixel;
                            }
                        }
                    } else {
                        return error.UnsupportedType;
                    }
                },
                else => return error.UnsupportedType,
            }
        }

        /// Computes a sharpened version of `self` by enhancing edges.
        /// It uses the formula `sharpened = 2 * original - blurred`, where `blurred` is a box-blurred
        /// version of the original image (calculated efficiently using an integral image).
        /// The `radius` parameter controls the size of the blur. This operation effectively
        /// increases the contrast at edges. SIMD optimizations are used for performance where applicable.
        pub fn sharpen(self: Image(T), allocator: std.mem.Allocator, sharpened: *Image(T), radius: usize) !void {
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
                    if (T == u8 or T == f32) {
                        Integral(T).plane(self, integral_img);
                        sharpenPlane(T, self, integral_img, sharpened.*, radius);
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
                        Integral(f32).plane(src_img, integral_img);

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
                                    Integral(u8).plane(src_plane, integral_img);
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
                        var sat: Image([Image(T).channels()]f32) = undefined;
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
                                    const sum = Integral(f32).sumChannel(sat, r1, c1, r2, c2, i);

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

                        const sum = Integral(u8).sum(sat, r1, c1, r2, c2);

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
                    const sum = Integral(u8).sum(sat, r1, c1, r2, c2);

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
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const Rgb = @import("../color.zig").Rgb;
const Rgba = @import("../color.zig").Rgba;

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
    };
}

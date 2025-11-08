//! Histogram computation for images
//!
//! This module provides histogram functionality for grayscale and color images.
//! Supports u8, Rgb, and Rgba pixel types.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Rgb = @import("../color.zig").Rgb;
const Rgba = @import("../color.zig").Rgba;
const Image = @import("../image.zig").Image;

/// Generic histogram type that adapts its structure based on the pixel type.
/// For u8: single channel histogram
/// For Rgb: three channel histogram (r, g, b)
/// For Rgba: four channel histogram (r, g, b, a)
pub fn Histogram(comptime T: type) type {
    return switch (T) {
        u8 => struct {
            values: [256]u32 = @splat(0),

            const Self = @This();

            /// Initialize a new histogram with all bins set to zero
            pub fn init() Self {
                return .{};
            }

            /// Find the maximum count across all bins
            pub fn max(self: Self) u32 {
                return stats.max(&self.values);
            }

            /// Reset all counts to zero.
            pub fn clear(self: *Self) void {
                @memset(&self.values, 0);
            }

            /// Calculate the mean value from the histogram
            pub fn mean(self: Self) u8 {
                const mean_val = stats.mean(&self.values);
                return @intFromFloat(@round(mean_val));
            }

            /// Calculate the median value from the histogram
            pub fn median(self: Self) u8 {
                return stats.median(&self.values);
            }

            /// Calculate percentile from the histogram
            pub fn percentile(self: Self, p: f64) u8 {
                return stats.percentile(&self.values, p);
            }

            /// Calculate percentile from a fraction in the range [0, 1].
            pub fn percentileFraction(self: Self, fraction: f64) u8 {
                std.debug.assert(fraction >= 0.0 and fraction <= 1.0);
                return stats.percentile(&self.values, fraction);
            }

            /// Return the smallest intensity with a non-zero count, or null if empty.
            pub fn firstNonZero(self: Self) ?u8 {
                for (self.values, 0..) |count, value| {
                    if (count > 0) return @intCast(value);
                }
                return null;
            }

            /// Return the largest intensity with a non-zero count, or null if empty.
            pub fn lastNonZero(self: Self) ?u8 {
                var idx: usize = self.values.len;
                while (idx > 0) : (idx -= 1) {
                    const count = self.values[idx - 1];
                    if (count > 0) return @intCast(idx - 1);
                }
                return null;
            }

            /// Increment the count for a single value.
            pub fn addValue(self: *Self, value: u8) void {
                self.values[value] += 1;
            }

            /// Decrement the count for a single value.
            pub fn removeValue(self: *Self, value: u8) void {
                std.debug.assert(self.values[value] > 0);
                self.values[value] -= 1;
            }

            /// Add counts from another histogram into this one.
            pub fn addCounts(self: *Self, other: Self) void {
                inline for (&self.values, 0..) |*count, i| {
                    count.* += other.values[i];
                }
            }

            /// Subtract counts from another histogram out of this one.
            pub fn subtractCounts(self: *Self, other: Self) void {
                inline for (&self.values, 0..) |*count, i| {
                    std.debug.assert(count.* >= other.values[i]);
                    count.* -= other.values[i];
                }
            }

            /// Calculate the variance from the histogram
            pub fn variance(self: Self) f64 {
                return stats.variance(&self.values);
            }

            /// Calculate the standard deviation from the histogram
            pub fn stdDev(self: Self) f64 {
                return stats.stdDev(&self.values);
            }

            /// Find the mode (most frequent value)
            pub fn mode(self: Self) u8 {
                return stats.mode(&self.values);
            }

            /// Find the minimum value after excluding cutoff pixels
            pub fn findCutoffMin(self: Self, cutoff_pixels: u32) u8 {
                if (cutoff_pixels == 0) {
                    // Find first non-zero bin
                    for (self.values, 0..) |count, i| {
                        if (count > 0) return @intCast(i);
                    }
                    return 0;
                }

                var cumulative: u32 = 0;
                for (self.values, 0..) |count, i| {
                    cumulative += count;
                    if (cumulative > cutoff_pixels) {
                        return @intCast(i);
                    }
                }
                return 255;
            }

            /// Find the maximum value after excluding cutoff pixels
            pub fn findCutoffMax(self: Self, cutoff_pixels: u32) u8 {
                if (cutoff_pixels == 0) {
                    // Find last non-zero bin
                    var i: usize = 255;
                    while (i > 0) : (i -= 1) {
                        if (self.values[i] > 0) return @intCast(i);
                    }
                    return 0;
                }

                var cumulative: u32 = 0;
                var i: usize = 255;
                while (i > 0) : (i -= 1) {
                    cumulative += self.values[i];
                    if (cumulative > cutoff_pixels) {
                        return @intCast(i);
                    }
                }
                return 0;
            }

            /// Get the total number of pixels counted
            pub fn totalPixels(self: Self) u32 {
                var total: u32 = 0;
                for (self.values) |count| {
                    total += count;
                }
                return total;
            }
        },
        Rgb => struct {
            r: [256]u32 = @splat(0),
            g: [256]u32 = @splat(0),
            b: [256]u32 = @splat(0),

            const Self = @This();

            /// Initialize a new histogram with all bins set to zero
            pub fn init() Self {
                return .{};
            }

            /// Find the maximum count across all bins and channels
            pub fn max(self: Self) u32 {
                var max_count = stats.max(&self.r);
                max_count = @max(max_count, stats.max(&self.g));
                max_count = @max(max_count, stats.max(&self.b));
                return max_count;
            }

            /// Calculate the mean value for each channel
            pub fn mean(self: Self) Rgb {
                return .{
                    .r = @intFromFloat(@round(stats.mean(&self.r))),
                    .g = @intFromFloat(@round(stats.mean(&self.g))),
                    .b = @intFromFloat(@round(stats.mean(&self.b))),
                };
            }

            /// Calculate the median value for each channel
            pub fn median(self: Self) Rgb {
                return .{
                    .r = stats.median(&self.r),
                    .g = stats.median(&self.g),
                    .b = stats.median(&self.b),
                };
            }

            /// Calculate the variance for each channel
            pub fn variance(self: Self) struct { r: f64, g: f64, b: f64 } {
                return .{
                    .r = stats.variance(&self.r),
                    .g = stats.variance(&self.g),
                    .b = stats.variance(&self.b),
                };
            }

            /// Calculate the standard deviation for each channel
            pub fn stdDev(self: Self) struct { r: f64, g: f64, b: f64 } {
                return .{
                    .r = stats.stdDev(&self.r),
                    .g = stats.stdDev(&self.g),
                    .b = stats.stdDev(&self.b),
                };
            }

            /// Find the mode for each channel
            pub fn mode(self: Self) Rgb {
                return .{
                    .r = stats.mode(&self.r),
                    .g = stats.mode(&self.g),
                    .b = stats.mode(&self.b),
                };
            }

            /// Calculate percentile for each channel
            pub fn percentile(self: Self, p: f64) struct { r: u8, g: u8, b: u8 } {
                return .{
                    .r = stats.percentile(&self.r, p),
                    .g = stats.percentile(&self.g, p),
                    .b = stats.percentile(&self.b, p),
                };
            }

            /// Find minimum values for each channel after excluding cutoff pixels
            pub fn findCutoffMin(self: Self, cutoff_pixels: u32) struct { r: u8, g: u8, b: u8 } {
                const findMin = struct {
                    fn find(bins: *const [256]u32, cutoff: u32) u8 {
                        if (cutoff == 0) {
                            for (bins, 0..) |count, i| {
                                if (count > 0) return @intCast(i);
                            }
                            return 0;
                        }
                        var cumulative: u32 = 0;
                        for (bins, 0..) |count, i| {
                            cumulative += count;
                            if (cumulative > cutoff) {
                                return @intCast(i);
                            }
                        }
                        return 255;
                    }
                }.find;

                return .{
                    .r = findMin(&self.r, cutoff_pixels),
                    .g = findMin(&self.g, cutoff_pixels),
                    .b = findMin(&self.b, cutoff_pixels),
                };
            }

            /// Find maximum values for each channel after excluding cutoff pixels
            pub fn findCutoffMax(self: Self, cutoff_pixels: u32) struct { r: u8, g: u8, b: u8 } {
                const findMax = struct {
                    fn find(bins: *const [256]u32, cutoff: u32) u8 {
                        if (cutoff == 0) {
                            var i: usize = 255;
                            while (i > 0) : (i -= 1) {
                                if (bins[i] > 0) return @intCast(i);
                            }
                            return 0;
                        }
                        var cumulative: u32 = 0;
                        var i: usize = 255;
                        while (i > 0) : (i -= 1) {
                            cumulative += bins[i];
                            if (cumulative > cutoff) {
                                return @intCast(i);
                            }
                        }
                        return 0;
                    }
                }.find;

                return .{
                    .r = findMax(&self.r, cutoff_pixels),
                    .g = findMax(&self.g, cutoff_pixels),
                    .b = findMax(&self.b, cutoff_pixels),
                };
            }

            /// Get the total number of pixels counted
            pub fn totalPixels(self: Self) u32 {
                var total: u32 = 0;
                for (self.r) |count| {
                    total += count;
                }
                return total;
            }
        },
        Rgba => struct {
            r: [256]u32 = @splat(0),
            g: [256]u32 = @splat(0),
            b: [256]u32 = @splat(0),
            a: [256]u32 = @splat(0),

            const Self = @This();

            /// Initialize a new histogram with all bins set to zero
            pub fn init() Self {
                return .{};
            }

            /// Find the maximum count across all bins and channels
            pub fn max(self: Self) u32 {
                var max_count = stats.max(&self.r);
                max_count = @max(max_count, stats.max(&self.g));
                max_count = @max(max_count, stats.max(&self.b));
                max_count = @max(max_count, stats.max(&self.a));
                return max_count;
            }

            /// Calculate the mean value for each channel
            pub fn mean(self: Self) Rgba {
                return .{
                    .r = @intFromFloat(@round(stats.mean(&self.r))),
                    .g = @intFromFloat(@round(stats.mean(&self.g))),
                    .b = @intFromFloat(@round(stats.mean(&self.b))),
                    .a = @intFromFloat(@round(stats.mean(&self.a))),
                };
            }

            /// Calculate the median value for each channel
            pub fn median(self: Self) Rgba {
                return .{
                    .r = stats.median(&self.r),
                    .g = stats.median(&self.g),
                    .b = stats.median(&self.b),
                    .a = stats.median(&self.a),
                };
            }

            /// Calculate the variance for each channel
            pub fn variance(self: Self) struct { r: f64, g: f64, b: f64, a: f64 } {
                return .{
                    .r = stats.variance(&self.r),
                    .g = stats.variance(&self.g),
                    .b = stats.variance(&self.b),
                    .a = stats.variance(&self.a),
                };
            }

            /// Calculate the standard deviation for each channel
            pub fn stdDev(self: Self) struct { r: f64, g: f64, b: f64, a: f64 } {
                return .{
                    .r = stats.stdDev(&self.r),
                    .g = stats.stdDev(&self.g),
                    .b = stats.stdDev(&self.b),
                    .a = stats.stdDev(&self.a),
                };
            }

            /// Find the mode for each channel
            pub fn mode(self: Self) Rgba {
                return .{
                    .r = stats.mode(&self.r),
                    .g = stats.mode(&self.g),
                    .b = stats.mode(&self.b),
                    .a = stats.mode(&self.a),
                };
            }

            /// Calculate percentile for each channel
            pub fn percentile(self: Self, p: f64) struct { r: u8, g: u8, b: u8, a: u8 } {
                return .{
                    .r = stats.percentile(&self.r, p),
                    .g = stats.percentile(&self.g, p),
                    .b = stats.percentile(&self.b, p),
                    .a = stats.percentile(&self.a, p),
                };
            }

            /// Find minimum values for each channel after excluding cutoff pixels
            pub fn findCutoffMin(self: Self, cutoff_pixels: u32) struct { r: u8, g: u8, b: u8, a: u8 } {
                const findMin = struct {
                    fn find(bins: *const [256]u32, cutoff: u32) u8 {
                        if (cutoff == 0) {
                            for (bins, 0..) |count, i| {
                                if (count > 0) return @intCast(i);
                            }
                            return 0;
                        }
                        var cumulative: u32 = 0;
                        for (bins, 0..) |count, i| {
                            cumulative += count;
                            if (cumulative > cutoff) {
                                return @intCast(i);
                            }
                        }
                        return 255;
                    }
                }.find;

                return .{
                    .r = findMin(&self.r, cutoff_pixels),
                    .g = findMin(&self.g, cutoff_pixels),
                    .b = findMin(&self.b, cutoff_pixels),
                    .a = findMin(&self.a, cutoff_pixels),
                };
            }

            /// Find maximum values for each channel after excluding cutoff pixels
            pub fn findCutoffMax(self: Self, cutoff_pixels: u32) struct { r: u8, g: u8, b: u8, a: u8 } {
                const findMax = struct {
                    fn find(bins: *const [256]u32, cutoff: u32) u8 {
                        if (cutoff == 0) {
                            var i: usize = 255;
                            while (i > 0) : (i -= 1) {
                                if (bins[i] > 0) return @intCast(i);
                            }
                            return 0;
                        }
                        var cumulative: u32 = 0;
                        var i: usize = 255;
                        while (i > 0) : (i -= 1) {
                            cumulative += bins[i];
                            if (cumulative > cutoff) {
                                return @intCast(i);
                            }
                        }
                        return 0;
                    }
                }.find;

                return .{
                    .r = findMax(&self.r, cutoff_pixels),
                    .g = findMax(&self.g, cutoff_pixels),
                    .b = findMax(&self.b, cutoff_pixels),
                    .a = findMax(&self.a, cutoff_pixels),
                };
            }

            /// Get the total number of pixels counted
            pub fn totalPixels(self: Self) u32 {
                var total: u32 = 0;
                for (self.r) |count| {
                    total += count;
                }
                return total;
            }
        },
        else => @compileError("Histogram only supports u8, Rgb, and Rgba types. Got: " ++ @typeName(T)),
    };
}

/// Statistics functions for histogram data (discrete distributions)
const stats = struct {
    /// Compute mean from histogram bins
    pub fn mean(bins: []const u32) f64 {
        var sum: u64 = 0;
        var total: u64 = 0;
        for (bins, 0..) |count, value| {
            sum += count * value;
            total += count;
        }
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(total));
    }

    /// Compute median from histogram bins
    pub fn median(bins: []const u32) u8 {
        var total: u32 = 0;
        for (bins) |count| {
            total += count;
        }
        if (total == 0) return 0;

        const half = (total + 1) / 2;
        var cumulative: u32 = 0;
        for (bins, 0..) |count, value| {
            cumulative += count;
            if (cumulative >= half) {
                return @intCast(value);
            }
        }
        return @intCast(bins.len - 1);
    }

    /// Find the mode (most frequent value)
    pub fn mode(bins: []const u32) u8 {
        var max_count: u32 = 0;
        var mode_val: u8 = 0;
        for (bins, 0..) |count, value| {
            if (count > max_count) {
                max_count = count;
                mode_val = @intCast(value);
            }
        }
        return mode_val;
    }

    /// Compute variance from histogram bins
    pub fn variance(bins: []const u32) f64 {
        const mean_val = mean(bins);
        var sum_sq_diff: f64 = 0;
        var total: u64 = 0;

        for (bins, 0..) |count, value| {
            if (count > 0) {
                const diff = @as(f64, @floatFromInt(value)) - mean_val;
                sum_sq_diff += diff * diff * @as(f64, @floatFromInt(count));
                total += count;
            }
        }

        if (total <= 1) return 0;
        return sum_sq_diff / @as(f64, @floatFromInt(total - 1));
    }

    /// Compute standard deviation from histogram bins
    pub fn stdDev(bins: []const u32) f64 {
        return @sqrt(variance(bins));
    }

    /// Compute skewness from histogram bins
    pub fn skewness(bins: []const u32) f64 {
        const mean_val = mean(bins);
        const std_dev = stdDev(bins);
        if (std_dev == 0) return 0;

        var sum_cub_diff: f64 = 0;
        var total: u64 = 0;

        for (bins, 0..) |count, value| {
            if (count > 0) {
                const diff = (@as(f64, @floatFromInt(value)) - mean_val) / std_dev;
                sum_cub_diff += diff * diff * diff * @as(f64, @floatFromInt(count));
                total += count;
            }
        }

        if (total <= 2) return 0;
        const n = @as(f64, @floatFromInt(total));
        return (n / ((n - 1) * (n - 2))) * sum_cub_diff;
    }

    /// Compute excess kurtosis from histogram bins
    pub fn kurtosis(bins: []const u32) f64 {
        const mean_val = mean(bins);
        const std_dev = stdDev(bins);
        if (std_dev == 0) return 0;

        var sum_four_diff: f64 = 0;
        var total: u64 = 0;

        for (bins, 0..) |count, value| {
            if (count > 0) {
                const diff = (@as(f64, @floatFromInt(value)) - mean_val) / std_dev;
                sum_four_diff += diff * diff * diff * diff * @as(f64, @floatFromInt(count));
                total += count;
            }
        }

        if (total <= 3) return 0;
        const n = @as(f64, @floatFromInt(total));
        const n1 = n - 1;

        return ((n * (n + 1)) / (n1 * (n - 2) * (n - 3))) * sum_four_diff -
            (3 * n1 * n1) / ((n - 2) * (n - 3));
    }

    /// Compute percentile from histogram bins
    pub fn percentile(bins: []const u32, p: f64) u8 {
        assert(p >= 0 and p <= 1);

        var total: usize = 0;
        for (bins) |count| {
            total += count;
        }
        if (total == 0) return 0;

        const total_minus_one = total - 1;
        const rank_f = p * @as(f64, @floatFromInt(total_minus_one));
        const rank_floor = std.math.floor(rank_f + 1e-12);
        const rank = std.math.clamp(@as(usize, @intFromFloat(rank_floor)), 0, total_minus_one);

        var cumulative: usize = 0;

        for (bins, 0..) |count, value| {
            if (count == 0) continue;
            cumulative += count;
            if (cumulative > rank) {
                return @intCast(value);
            }
        }
        return @intCast(bins.len - 1);
    }

    /// Find maximum bin count
    pub fn max(bins: []const u32) u32 {
        var max_count: u32 = 0;
        for (bins) |count| {
            if (count > max_count) {
                max_count = count;
            }
        }
        return max_count;
    }

    /// Find minimum bin count (excluding zeros)
    pub fn min(bins: []const u32) u32 {
        var min_count: u32 = std.math.maxInt(u32);
        var found_nonzero = false;

        for (bins) |count| {
            if (count > 0 and count < min_count) {
                min_count = count;
                found_nonzero = true;
            }
        }

        return if (found_nonzero) min_count else 0;
    }

    /// Compute entropy from histogram bins
    pub fn entropy(bins: []const u32) f64 {
        var total: u64 = 0;
        for (bins) |count| {
            total += count;
        }
        if (total == 0) return 0;

        var ent: f64 = 0;
        const total_f = @as(f64, @floatFromInt(total));

        for (bins) |count| {
            if (count > 0) {
                const p = @as(f64, @floatFromInt(count)) / total_f;
                ent -= p * std.math.log2(p);
            }
        }

        return ent;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "Histogram: u8 grayscale basic" {
    const allocator = testing.allocator;

    // Create a simple 3x3 grayscale image
    var img = try Image(u8).init(allocator, 3, 3);
    defer img.deinit(allocator);

    // Fill with known values
    img.data[0] = 0; // Black
    img.data[1] = 128; // Mid gray
    img.data[2] = 255; // White
    img.data[3] = 128; // Mid gray
    img.data[4] = 128; // Mid gray
    img.data[5] = 255; // White
    img.data[6] = 0; // Black
    img.data[7] = 0; // Black
    img.data[8] = 255; // White

    const hist = img.histogram();

    // Check counts
    try testing.expectEqual(@as(u32, 3), hist.values[0]); // 3 black pixels
    try testing.expectEqual(@as(u32, 3), hist.values[128]); // 3 mid gray pixels
    try testing.expectEqual(@as(u32, 3), hist.values[255]); // 3 white pixels

    // Check all other bins are zero
    var sum: u32 = 0;
    for (hist.values) |count| {
        sum += count;
    }
    try testing.expectEqual(@as(u32, 9), sum); // Total should be 9 pixels

    // Test utility methods
    try testing.expectEqual(@as(u32, 3), hist.max());
    try testing.expectEqual(@as(u32, 9), hist.totalPixels());

    // Mean should be approximately (0*3 + 128*3 + 255*3) / 9 ≈ 127.67, rounded to 128
    try testing.expectEqual(@as(u8, 128), hist.mean());

    // Median should be 128 (middle value when sorted)
    try testing.expectEqual(@as(u8, 128), hist.median());
}

test "Histogram: Rgb color" {
    const allocator = testing.allocator;

    // Create a 2x2 RGB image
    var img = try Image(Rgb).init(allocator, 2, 2);
    defer img.deinit(allocator);

    // Fill with distinct colors
    img.data[0] = Rgb{ .r = 255, .g = 0, .b = 0 }; // Red
    img.data[1] = Rgb{ .r = 0, .g = 255, .b = 0 }; // Green
    img.data[2] = Rgb{ .r = 0, .g = 0, .b = 255 }; // Blue
    img.data[3] = Rgb{ .r = 128, .g = 128, .b = 128 }; // Gray

    const hist = img.histogram();

    // Check red channel
    try testing.expectEqual(@as(u32, 2), hist.r[0]); // 2 pixels with r=0
    try testing.expectEqual(@as(u32, 1), hist.r[128]); // 1 pixel with r=128
    try testing.expectEqual(@as(u32, 1), hist.r[255]); // 1 pixel with r=255

    // Check green channel
    try testing.expectEqual(@as(u32, 2), hist.g[0]); // 2 pixels with g=0
    try testing.expectEqual(@as(u32, 1), hist.g[128]); // 1 pixel with g=128
    try testing.expectEqual(@as(u32, 1), hist.g[255]); // 1 pixel with g=255

    // Check blue channel
    try testing.expectEqual(@as(u32, 2), hist.b[0]); // 2 pixels with b=0
    try testing.expectEqual(@as(u32, 1), hist.b[128]); // 1 pixel with b=128
    try testing.expectEqual(@as(u32, 1), hist.b[255]); // 1 pixel with b=255

    try testing.expectEqual(@as(u32, 4), hist.totalPixels());
    try testing.expectEqual(@as(u32, 2), hist.max()); // Maximum count is 2

    const means = hist.mean();
    try testing.expectEqual(@as(u8, 96), means.r); // (0+0+128+255)/4 = 95.75, rounded to 96
    try testing.expectEqual(@as(u8, 96), means.g);
    try testing.expectEqual(@as(u8, 96), means.b);
}

test "Histogram: Rgba with alpha" {
    const allocator = testing.allocator;

    // Create a 2x2 RGBA image
    var img = try Image(Rgba).init(allocator, 2, 2);
    defer img.deinit(allocator);

    // Fill with colors including different alpha values
    img.data[0] = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }; // Opaque red
    img.data[1] = Rgba{ .r = 0, .g = 255, .b = 0, .a = 128 }; // Semi-transparent green
    img.data[2] = Rgba{ .r = 0, .g = 0, .b = 255, .a = 64 }; // More transparent blue
    img.data[3] = Rgba{ .r = 128, .g = 128, .b = 128, .a = 0 }; // Fully transparent gray

    const hist = img.histogram();

    // Check alpha channel
    try testing.expectEqual(@as(u32, 1), hist.a[0]); // 1 pixel with a=0
    try testing.expectEqual(@as(u32, 1), hist.a[64]); // 1 pixel with a=64
    try testing.expectEqual(@as(u32, 1), hist.a[128]); // 1 pixel with a=128
    try testing.expectEqual(@as(u32, 1), hist.a[255]); // 1 pixel with a=255

    try testing.expectEqual(@as(u32, 4), hist.totalPixels());

    const means = hist.mean();
    try testing.expectEqual(@as(u8, 112), means.a); // (0+64+128+255)/4 = 111.75, rounded to 112
}

test "Histogram: empty image" {
    const allocator = testing.allocator;

    // Create an empty image
    var img = try Image(u8).init(allocator, 0, 0);
    defer img.deinit(allocator);

    const hist = img.histogram();

    // All bins should be zero
    for (hist.values) |count| {
        try testing.expectEqual(@as(u32, 0), count);
    }

    try testing.expectEqual(@as(u32, 0), hist.max());
    try testing.expectEqual(@as(u32, 0), hist.totalPixels());
    try testing.expectEqual(@as(u8, 0), hist.mean());
    try testing.expectEqual(@as(u8, 0), hist.median());
}

test "Histogram: single pixel" {
    const allocator = testing.allocator;

    var img = try Image(u8).init(allocator, 1, 1);
    defer img.deinit(allocator);

    img.data[0] = 42;

    const hist = img.histogram();

    try testing.expectEqual(@as(u32, 1), hist.values[42]);
    try testing.expectEqual(@as(u32, 1), hist.totalPixels());
    try testing.expectEqual(@as(u8, 42), hist.mean());
    try testing.expectEqual(@as(u8, 42), hist.median());
}

test "Histogram: uniform color" {
    const allocator = testing.allocator;

    var img = try Image(Rgb).init(allocator, 10, 10);
    defer img.deinit(allocator);

    // Fill with uniform gray
    const gray = Rgb{ .r = 100, .g = 100, .b = 100 };
    img.fill(gray);

    const hist = img.histogram();

    try testing.expectEqual(@as(u32, 100), hist.r[100]);
    try testing.expectEqual(@as(u32, 100), hist.g[100]);
    try testing.expectEqual(@as(u32, 100), hist.b[100]);

    // All other bins should be zero
    for (hist.r, 0..) |count, i| {
        if (i != 100) {
            try testing.expectEqual(@as(u32, 0), count);
        }
    }

    try testing.expectEqual(@as(u32, 100), hist.totalPixels());
    try testing.expectEqual(@as(u32, 100), hist.max());

    const means = hist.mean();
    try testing.expectEqual(@as(u8, 100), means.r);
    try testing.expectEqual(@as(u8, 100), means.g);
    try testing.expectEqual(@as(u8, 100), means.b);

    const medians = hist.median();
    try testing.expectEqual(@as(u8, 100), medians.r);
    try testing.expectEqual(@as(u8, 100), medians.g);
    try testing.expectEqual(@as(u8, 100), medians.b);
}

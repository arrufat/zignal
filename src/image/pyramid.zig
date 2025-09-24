const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const Image = @import("../image.zig").Image;
const Blur = @import("blur.zig").Blur;

/// A multi-scale image pyramid for scale-invariant feature detection.
/// Each level is downsampled from the previous by a scale factor.
pub fn ImagePyramid(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Array of images at different scales
        levels: []Image(T),

        /// Scale factor between adjacent levels (typically 1.2 for ORB)
        scale_factor: f32,

        /// Number of levels in the pyramid
        n_levels: u8,

        /// Sigma for Gaussian blur before downsampling
        blur_sigma: f32,

        /// Allocator used for the pyramid (needed for cleanup)
        allocator: Allocator,

        /// Build an image pyramid from the source image
        pub fn build(
            allocator: Allocator,
            source: Image(T),
            n_levels: u8,
            scale_factor: f32,
            blur_sigma: f32,
        ) !Self {
            assert(n_levels > 0);
            assert(scale_factor > 1.0);
            assert(blur_sigma > 0);

            var levels = try allocator.alloc(Image(T), n_levels);
            errdefer {
                for (levels[0..], 0..) |*level, i| {
                    if (i > 0 and level.rows > 0) {
                        level.deinit(allocator);
                    }
                }
                allocator.free(levels);
            }

            // First level is the original image (no copy, just reference)
            levels[0] = source;

            // Build subsequent levels from original for better quality
            for (1..n_levels) |i| {
                // Calculate dimensions for this level
                const scale = std.math.pow(f32, scale_factor, @as(f32, @floatFromInt(i)));
                const new_rows = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(source.rows)) / scale)));
                const new_cols = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(source.cols)) / scale)));

                // Skip if image becomes too small
                if (new_rows < 8 or new_cols < 8) {
                    // Truncate pyramid here
                    const actual_levels = try allocator.realloc(levels, i);
                    return .{
                        .levels = actual_levels,
                        .scale_factor = scale_factor,
                        .n_levels = @intCast(i),
                        .blur_sigma = blur_sigma,
                        .allocator = allocator,
                    };
                }

                // Apply Gaussian blur to original for anti-aliasing
                // Use adaptive sigma based on scale factor
                const sigma = blur_sigma * @sqrt(scale * scale - 1.0);
                var blurred: Image(T) = .empty;
                defer if (blurred.rows > 0) blurred.deinit(allocator);

                // Only blur if we have gaussianBlur available and sigma > 0.5
                if (sigma > 0.5 and @hasDecl(Blur(T), "gaussian")) {
                    try Blur(T).gaussian(source, allocator, sigma, &blurred);
                } else if (sigma > 0.5) {
                    // Fallback to box blur if Gaussian not available
                    const radius = @as(usize, @intFromFloat(sigma * 2));
                    try Blur(T).box(source, allocator, &blurred, radius);
                }

                // Allocate and resize to create the new level
                levels[i] = try Image(T).init(allocator, new_rows, new_cols);

                // Use bilinear interpolation for downsampling from original or blurred
                const source_to_use = if (blurred.rows > 0) blurred else source;
                try source_to_use.resize(allocator, levels[i], .bilinear);
            }

            return .{
                .levels = levels,
                .scale_factor = scale_factor,
                .n_levels = n_levels,
                .blur_sigma = blur_sigma,
                .allocator = allocator,
            };
        }

        /// Build a pyramid with default ORB parameters
        pub fn buildDefault(allocator: Allocator, source: Image(T)) !Self {
            return build(allocator, source, 8, 1.2, 1.6);
        }

        /// Free all allocated pyramid levels (except the first which is not owned)
        pub fn deinit(self: *Self) void {
            // Skip first level as it's not owned by the pyramid
            for (self.levels[1..]) |*level| {
                level.deinit(self.allocator);
            }
            self.allocator.free(self.levels);
        }

        /// Get the scale factor for a specific level
        pub fn getScale(self: Self, level: u8) f32 {
            assert(level < self.n_levels);
            return std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
        }

        /// Convert coordinates from pyramid level to original image coordinates
        pub fn toOriginalCoords(self: Self, level: u8, x: f32, y: f32) struct { x: f32, y: f32 } {
            const scale = self.getScale(level);
            return .{
                .x = x * scale,
                .y = y * scale,
            };
        }

        /// Convert coordinates from original image to pyramid level coordinates
        pub fn toPyramidCoords(self: Self, level: u8, x: f32, y: f32) struct { x: f32, y: f32 } {
            const scale = self.getScale(level);
            return .{
                .x = x / scale,
                .y = y / scale,
            };
        }

        /// Get the image at a specific pyramid level
        pub fn getLevel(self: Self, level: u8) Image(T) {
            assert(level < self.n_levels);
            return self.levels[level];
        }

        /// Calculate the total number of pixels across all pyramid levels
        pub fn totalPixels(self: Self) usize {
            var total: usize = 0;
            for (self.levels) |level| {
                total += level.rows * level.cols;
            }
            return total;
        }

        /// Calculate memory usage in bytes
        pub fn memoryUsage(self: Self) usize {
            return self.totalPixels() * @sizeOf(T) +
                @sizeOf(Image(T)) * self.n_levels +
                @sizeOf(Self);
        }
    };
}

// Tests
test "ImagePyramid basic construction" {
    const allocator = std.testing.allocator;

    // Create a test image
    var image = try Image(u8).init(allocator, 640, 480);
    defer image.deinit(allocator);

    // Fill with test pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast((r + c) % 256);
        }
    }

    // Build pyramid
    var pyramid = try ImagePyramid(u8).build(allocator, image, 5, 1.5, 1.0);
    defer pyramid.deinit();

    try expectEqual(@as(u8, 5), pyramid.n_levels);
    try expectEqual(@as(f32, 1.5), pyramid.scale_factor);

    // Check first level is original size
    try expectEqual(@as(usize, 640), pyramid.levels[0].rows);
    try expectEqual(@as(usize, 480), pyramid.levels[0].cols);

    // Check subsequent levels are smaller
    for (1..pyramid.n_levels) |i| {
        const level = pyramid.levels[i];
        const prev_level = pyramid.levels[i - 1];

        try expectEqual(true, level.rows < prev_level.rows);
        try expectEqual(true, level.cols < prev_level.cols);

        // Check approximate scaling
        const expected_scale = pyramid.getScale(@intCast(i));
        const actual_row_scale = @as(f32, @floatFromInt(image.rows)) / @as(f32, @floatFromInt(level.rows));
        const actual_col_scale = @as(f32, @floatFromInt(image.cols)) / @as(f32, @floatFromInt(level.cols));

        // Should be approximately correct (within rounding)
        try expectApproxEqAbs(expected_scale, actual_row_scale, 1.0);
        try expectApproxEqAbs(expected_scale, actual_col_scale, 1.0);
    }
}

test "ImagePyramid scale calculations" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 100, 100);
    defer image.deinit(allocator);

    var pyramid = try ImagePyramid(u8).build(allocator, image, 4, 1.2, 1.0);
    defer pyramid.deinit();

    // Test scale factors
    try expectApproxEqAbs(@as(f32, 1.0), pyramid.getScale(0), 0.01);
    try expectApproxEqAbs(@as(f32, 1.2), pyramid.getScale(1), 0.01);
    try expectApproxEqAbs(@as(f32, 1.44), pyramid.getScale(2), 0.01);
    try expectApproxEqAbs(@as(f32, 1.728), pyramid.getScale(3), 0.01);

    // Test coordinate conversions
    const orig = pyramid.toOriginalCoords(2, 10, 20);
    try expectApproxEqAbs(@as(f32, 14.4), orig.x, 0.01);
    try expectApproxEqAbs(@as(f32, 28.8), orig.y, 0.01);

    const pyr = pyramid.toPyramidCoords(2, 14.4, 28.8);
    try expectApproxEqAbs(@as(f32, 10.0), pyr.x, 0.01);
    try expectApproxEqAbs(@as(f32, 20.0), pyr.y, 0.01);
}

test "ImagePyramid truncation for small images" {
    const allocator = std.testing.allocator;

    // Start with a small image
    var image = try Image(u8).init(allocator, 32, 32);
    defer image.deinit(allocator);

    // Request many levels but expect truncation
    var pyramid = try ImagePyramid(u8).build(allocator, image, 10, 2.0, 1.0);
    defer pyramid.deinit();

    // Should have fewer levels due to minimum size constraint
    try expectEqual(true, pyramid.n_levels < 10);

    // Last level should be at least 8x8
    const last_level = pyramid.levels[pyramid.n_levels - 1];
    try expectEqual(true, last_level.rows >= 8);
    try expectEqual(true, last_level.cols >= 8);
}

test "ImagePyramid memory usage" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 256, 256);
    defer image.deinit(allocator);

    var pyramid = try ImagePyramid(u8).build(allocator, image, 4, 1.5, 1.0);
    defer pyramid.deinit();

    const total_pixels = pyramid.totalPixels();
    const memory = pyramid.memoryUsage();

    // First level has 256*256 = 65536 pixels
    // Subsequent levels are progressively smaller
    try expectEqual(true, total_pixels > 65536);
    try expectEqual(true, total_pixels < 65536 * 2); // Should be less than 2x original

    // Memory should be reasonable
    try expectEqual(true, memory > total_pixels); // At least pixel data
    try expectEqual(true, memory < total_pixels * 2); // But not excessive
}

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const Image = @import("../image.zig").Image;

/// A multi-scale image pyramid for scale-invariant feature detection.
/// Each level is downsampled from the previous by a scale factor.
pub fn ImagePyramid(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            /// Levels requested; the pyramid stops early once a level would fall below `min_size`.
            n_levels: u8 = 8,
            /// Scale factor between adjacent levels
            scale_factor: f32 = 1.2,
            /// Base sigma of the anti-aliasing blur applied before downsampling
            blur_sigma: f32 = 1.6,
            /// Smallest allowed level dimension in pixels
            min_size: u32 = 8,

            pub const default: Options = .{};
        };

        /// Level 0 aliases the caller's image and is never freed; the rest are owned.
        levels: []Image(T),

        /// Scale factor between adjacent levels
        scale_factor: f32,

        /// Number of levels actually built
        n_levels: u8,

        /// Allocator used for the pyramid (needed for cleanup)
        allocator: Allocator,

        /// Build an image pyramid from the source image
        pub fn init(io: Io, allocator: Allocator, source: Image(T), options: Options) !Self {
            const n_levels = options.n_levels;
            const scale_factor = options.scale_factor;
            assert(n_levels > 0);
            assert(scale_factor > 1.0);
            assert(options.blur_sigma > 0);

            var levels = try allocator.alloc(Image(T), n_levels);
            @memset(levels, .empty);
            errdefer {
                for (levels) |*level| level.deinit(allocator);
                allocator.free(levels);
            }

            // Full-size blur scratch, allocated on first use and reused across levels.
            var blurred: Image(T) = .empty;
            defer blurred.deinit(allocator);

            // Every level is resampled from the original rather than cascaded, for quality.
            var count: usize = n_levels;
            for (1..n_levels) |i| {
                const scale = std.math.pow(f32, scale_factor, @floatFromInt(i));
                const new_rows: u32 = @trunc(@as(f32, @floatFromInt(source.rows)) / scale);
                const new_cols: u32 = @trunc(@as(f32, @floatFromInt(source.cols)) / scale);
                if (new_rows < options.min_size or new_cols < options.min_size) {
                    count = i;
                    break;
                }

                // Anti-aliasing sigma grows with the downscale ratio.
                const sigma = options.blur_sigma * @sqrt(scale * scale - 1.0);
                const src = if (sigma > 0.5) blk: {
                    if (blurred.rows == 0) blurred = try .initLike(allocator, source);
                    try source.gaussianBlur(io, allocator, blurred, sigma, .default);
                    break :blk blurred;
                } else source;

                levels[i] = try .init(allocator, new_rows, new_cols);
                src.resize(io, allocator, levels[i], .bilinear);
            }
            if (count < n_levels) levels = try allocator.realloc(levels, count);
            levels[0] = source;

            return .{
                .levels = levels,
                .scale_factor = scale_factor,
                .n_levels = @intCast(count),
                .allocator = allocator,
            };
        }

        /// Free all owned pyramid levels
        pub fn deinit(self: *Self) void {
            for (self.levels[1..]) |*level| level.deinit(self.allocator);
            self.allocator.free(self.levels);
        }

        /// Get the scale factor for a specific level
        pub fn getScale(self: Self, level: u8) f32 {
            assert(level < self.n_levels);
            return std.math.pow(f32, self.scale_factor, @floatFromInt(level));
        }

        /// Convert coordinates from pyramid level to original image coordinates
        pub fn toOriginalCoords(self: Self, level: u8, x: f32, y: f32) struct { x: f32, y: f32 } {
            const scale = self.getScale(level);
            return .{ .x = x * scale, .y = y * scale };
        }

        /// Convert coordinates from original image to pyramid level coordinates
        pub fn toPyramidCoords(self: Self, level: u8, x: f32, y: f32) struct { x: f32, y: f32 } {
            const scale = self.getScale(level);
            return .{ .x = x / scale, .y = y / scale };
        }

        /// Get the image at a specific pyramid level
        pub fn getLevel(self: Self, level: u8) Image(T) {
            assert(level < self.n_levels);
            return self.levels[level];
        }

        /// Calculate the total number of pixels across all pyramid levels
        pub fn totalPixels(self: Self) usize {
            var total: usize = 0;
            for (self.levels) |level| total += level.size();
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

const test_io = std.Io.Threaded.global_single_threaded.io();

test "ImagePyramid basic construction" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 640, 480);
    defer image.deinit(allocator);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast((r + c) % 256);
        }
    }

    var pyramid = try ImagePyramid(u8).init(test_io, allocator, image, .{ .n_levels = 5, .scale_factor = 1.5, .blur_sigma = 1.0 });
    defer pyramid.deinit();

    try expectEqual(@as(u8, 5), pyramid.n_levels);
    try expectEqual(@as(f32, 1.5), pyramid.scale_factor);
    try expectEqual(@as(u32, 640), pyramid.levels[0].rows);
    try expectEqual(@as(u32, 480), pyramid.levels[0].cols);

    for (1..pyramid.n_levels) |i| {
        const level = pyramid.levels[i];
        const prev_level = pyramid.levels[i - 1];
        try expect(level.rows < prev_level.rows);
        try expect(level.cols < prev_level.cols);

        // Dimensions are truncated, so the realized scale is only approximate.
        const expected_scale = pyramid.getScale(@intCast(i));
        const actual_row_scale = @as(f32, @floatFromInt(image.rows)) / @as(f32, @floatFromInt(level.rows));
        const actual_col_scale = @as(f32, @floatFromInt(image.cols)) / @as(f32, @floatFromInt(level.cols));
        try expectApproxEqAbs(expected_scale, actual_row_scale, 1.0);
        try expectApproxEqAbs(expected_scale, actual_col_scale, 1.0);
    }
}

test "ImagePyramid scale calculations" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 100, 100);
    defer image.deinit(allocator);

    var pyramid = try ImagePyramid(u8).init(test_io, allocator, image, .{ .n_levels = 4, .scale_factor = 1.2, .blur_sigma = 1.0 });
    defer pyramid.deinit();

    try expectApproxEqAbs(@as(f32, 1.0), pyramid.getScale(0), 0.01);
    try expectApproxEqAbs(@as(f32, 1.2), pyramid.getScale(1), 0.01);
    try expectApproxEqAbs(@as(f32, 1.44), pyramid.getScale(2), 0.01);
    try expectApproxEqAbs(@as(f32, 1.728), pyramid.getScale(3), 0.01);

    const orig = pyramid.toOriginalCoords(2, 10, 20);
    try expectApproxEqAbs(@as(f32, 14.4), orig.x, 0.01);
    try expectApproxEqAbs(@as(f32, 28.8), orig.y, 0.01);

    const pyr = pyramid.toPyramidCoords(2, 14.4, 28.8);
    try expectApproxEqAbs(@as(f32, 10.0), pyr.x, 0.01);
    try expectApproxEqAbs(@as(f32, 20.0), pyr.y, 0.01);
}

test "ImagePyramid truncation for small images" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 32, 32);
    defer image.deinit(allocator);

    // Request more levels than the 8x8 minimum allows.
    var pyramid = try ImagePyramid(u8).init(test_io, allocator, image, .{ .n_levels = 10, .scale_factor = 2.0, .blur_sigma = 1.0 });
    defer pyramid.deinit();

    try expect(pyramid.n_levels < 10);
    const last_level = pyramid.levels[pyramid.n_levels - 1];
    try expect(last_level.rows >= 8);
    try expect(last_level.cols >= 8);
}

test "ImagePyramid memory usage" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 256, 256);
    defer image.deinit(allocator);

    var pyramid = try ImagePyramid(u8).init(test_io, allocator, image, .{ .n_levels = 4, .scale_factor = 1.5, .blur_sigma = 1.0 });
    defer pyramid.deinit();

    const total_pixels = pyramid.totalPixels();
    const memory = pyramid.memoryUsage();

    // Level 0 alone is 65536 pixels; the geometric tail stays under one more copy.
    try expect(total_pixels > 65536);
    try expect(total_pixels < 65536 * 2);
    try expect(memory > total_pixels);
    try expect(memory < total_pixels * 2);
}

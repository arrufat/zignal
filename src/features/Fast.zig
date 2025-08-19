//! FAST (Features from Accelerated Segment Test) corner detector.
//!
//! FAST is a high-speed corner detection algorithm that tests pixels in a
//! Bresenham circle around a candidate point. A corner is detected when a
//! contiguous arc of pixels are significantly brighter or darker than the center.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const KeyPoint = @import("KeyPoint.zig");
const Image = @import("../image.zig").Image;

/// Intensity difference threshold for corner detection
threshold: u8 = 20,

/// Apply non-maximal suppression to reduce redundant corners
nonmax_suppression: bool = true,

/// Minimum number of contiguous pixels that must be brighter/darker
/// Standard FAST uses 9 (FAST-9) or 12 (FAST-12)
min_contiguous: u8 = 9,

const Fast = @This();

/// Bresenham circle pattern: 16 pixels at radius 3
/// Ordered clockwise starting from top (12 o'clock)
const circle_offsets = [16][2]i8{
    .{ 0, -3 }, .{ 1, -3 }, .{ 2, -2 }, .{ 3, -1 }, // Top-right quadrant
    .{ 3, 0 }, .{ 3, 1 }, .{ 2, 2 }, .{ 1, 3 }, // Bottom-right quadrant
    .{ 0, 3 }, .{ -1, 3 }, .{ -2, 2 }, .{ -3, 1 }, // Bottom-left quadrant
    .{ -3, 0 }, .{ -3, -1 }, .{ -2, -2 }, .{ -1, -3 }, // Top-left quadrant
};

/// Detect FAST corners in the image
pub fn detect(self: Fast, image: Image(u8), allocator: Allocator) ![]KeyPoint {
    assert(image.rows > 7 and image.cols > 7); // Need at least 7x7 for radius 3

    var keypoints: ArrayList(KeyPoint) = .{};
    errdefer keypoints.deinit(allocator);

    // Skip border pixels (radius 3)
    const border = 3;

    // First pass: detect corners
    for (border..image.rows - border) |row| {
        for (border..image.cols - border) |col| {
            if (self.isCorner(image, row, col)) {
                const score = self.cornerScore(image, row, col);
                try keypoints.append(allocator, .{
                    .x = @floatFromInt(col),
                    .y = @floatFromInt(row),
                    .size = 7.0, // FAST uses fixed size
                    .angle = -1.0, // Orientation computed later by ORB
                    .response = @floatFromInt(score),
                    .octave = 0,
                });
            }
        }
    }

    // Second pass: non-maximal suppression
    if (self.nonmax_suppression and keypoints.items.len > 0) {
        const suppressed = try self.suppressNonMaximal(keypoints.items, allocator);
        keypoints.deinit(allocator);
        return suppressed;
    }

    return try keypoints.toOwnedSlice(allocator);
}

/// Check if a pixel is a corner using the FAST criterion
fn isCorner(self: Fast, image: Image(u8), row: usize, col: usize) bool {
    const center = image.at(row, col).*;
    const threshold = self.threshold;

    // Quick rejection test: check pixels at 0, 4, 8, 12 (cardinal directions)
    // At least 3 must be either all brighter or all darker
    var bright_count: u8 = 0;
    var dark_count: u8 = 0;

    for ([_]usize{ 0, 4, 8, 12 }) |i| {
        const offset = circle_offsets[i];
        const px_row = @as(isize, @intCast(row)) + offset[1];
        const px_col = @as(isize, @intCast(col)) + offset[0];
        const pixel = image.at(@intCast(px_row), @intCast(px_col)).*;

        if (pixel > center +| threshold) {
            bright_count += 1;
        } else if (pixel < center -| threshold) {
            dark_count += 1;
        }
    }

    // Need at least 3 out of 4 to possibly have 9 contiguous
    if (bright_count < 3 and dark_count < 3) {
        return false;
    }

    // Full test: check for contiguous arc
    var bright_arc: u8 = 0;
    var dark_arc: u8 = 0;
    var max_bright_arc: u8 = 0;
    var max_dark_arc: u8 = 0;

    // Check twice around the circle to handle wraparound
    for (0..32) |ii| {
        const i = ii % 16;
        const offset = circle_offsets[i];
        const px_row = @as(isize, @intCast(row)) + offset[1];
        const px_col = @as(isize, @intCast(col)) + offset[0];
        const pixel = image.at(@intCast(px_row), @intCast(px_col)).*;

        if (pixel > center +| threshold) {
            bright_arc += 1;
            dark_arc = 0;
            max_bright_arc = @max(max_bright_arc, bright_arc);
        } else if (pixel < center -| threshold) {
            dark_arc += 1;
            bright_arc = 0;
            max_dark_arc = @max(max_dark_arc, dark_arc);
        } else {
            bright_arc = 0;
            dark_arc = 0;
        }
    }

    return max_bright_arc >= self.min_contiguous or max_dark_arc >= self.min_contiguous;
}

/// Compute corner score (sum of absolute differences for contiguous pixels)
fn cornerScore(self: Fast, image: Image(u8), row: usize, col: usize) u32 {
    const center = image.at(row, col).*;
    var score: u32 = 0;

    for (circle_offsets) |offset| {
        const px_row = @as(isize, @intCast(row)) + offset[1];
        const px_col = @as(isize, @intCast(col)) + offset[0];
        const pixel = image.at(@intCast(px_row), @intCast(px_col)).*;

        const diff = if (pixel > center) pixel - center else center - pixel;
        if (diff > self.threshold) {
            score += diff;
        }
    }

    return score;
}

/// Apply non-maximal suppression to remove redundant corners
fn suppressNonMaximal(self: Fast, keypoints: []const KeyPoint, allocator: Allocator) ![]KeyPoint {
    _ = self;

    if (keypoints.len == 0) {
        return try allocator.alloc(KeyPoint, 0);
    }

    var suppressed: ArrayList(KeyPoint) = .{};
    errdefer suppressed.deinit(allocator);

    // Create a grid for spatial binning (faster than O(n²) comparison)
    const grid_size = 20; // pixels per grid cell
    const max_row = @as(usize, @intFromFloat(keypoints[0].y));
    const max_col = @as(usize, @intFromFloat(keypoints[0].x));
    var min_row = max_row;
    var min_col = max_col;
    var grid_rows: usize = 0;
    var grid_cols: usize = 0;

    // Find bounds
    for (keypoints) |kp| {
        const r = @as(usize, @intFromFloat(kp.y));
        const c = @as(usize, @intFromFloat(kp.x));
        min_row = @min(min_row, r);
        min_col = @min(min_col, c);
        grid_rows = @max(grid_rows, r);
        grid_cols = @max(grid_cols, c);
    }

    grid_rows = (grid_rows - min_row) / grid_size + 1;
    grid_cols = (grid_cols - min_col) / grid_size + 1;

    // Allocate grid
    const grid_size_total = grid_rows * grid_cols;
    var grid = try allocator.alloc(ArrayList(KeyPoint), grid_size_total);
    defer {
        for (grid) |*cell| {
            cell.deinit(allocator);
        }
        allocator.free(grid);
    }

    for (grid) |*cell| {
        cell.* = .{};
    }

    // Bin keypoints into grid
    for (keypoints) |kp| {
        const r = (@as(usize, @intFromFloat(kp.y)) - min_row) / grid_size;
        const c = (@as(usize, @intFromFloat(kp.x)) - min_col) / grid_size;
        const idx = r * grid_cols + c;
        try grid[idx].append(allocator, kp);
    }

    // Suppress within each cell and neighboring cells
    for (0..grid_rows) |r| {
        for (0..grid_cols) |c| {
            const idx = r * grid_cols + c;
            const cell = &grid[idx];

            if (cell.items.len == 0) continue;

            // Sort by response strength
            std.mem.sort(KeyPoint, cell.items, {}, KeyPoint.compareResponse);

            // Keep only the strongest in local neighborhood
            for (cell.items) |kp| {
                var is_max = true;

                // Check 3x3 neighborhood
                const r_start = if (r > 0) r - 1 else 0;
                const r_end = @min(r + 2, grid_rows);
                const c_start = if (c > 0) c - 1 else 0;
                const c_end = @min(c + 2, grid_cols);

                for (r_start..r_end) |rr| {
                    for (c_start..c_end) |cc| {
                        const neighbor_idx = rr * grid_cols + cc;
                        for (grid[neighbor_idx].items) |other| {
                            if (kp.x == other.x and kp.y == other.y) continue;

                            const dist = kp.distance(other);
                            if (dist < 5.0 and other.response > kp.response) {
                                is_max = false;
                                break;
                            }
                        }
                        if (!is_max) break;
                    }
                    if (!is_max) break;
                }

                if (is_max) {
                    try suppressed.append(allocator, kp);
                }
            }
        }
    }

    return try suppressed.toOwnedSlice(allocator);
}

// Tests
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "FAST detector initialization" {
    const fast = Fast{
        .threshold = 25,
        .nonmax_suppression = false,
        .min_contiguous = 12,
    };

    try expectEqual(@as(u8, 25), fast.threshold);
    try expectEqual(false, fast.nonmax_suppression);
    try expectEqual(@as(u8, 12), fast.min_contiguous);
}

test "FAST detector on synthetic corner" {
    const allocator = std.testing.allocator;

    // Create a simple image with a corner pattern
    var image = try Image(u8).initAlloc(allocator, 20, 20);
    defer image.deinit(allocator);

    // Fill with gray
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = 128;
        }
    }

    // Create a corner pattern at (10, 10)
    // Make top-left quadrant darker
    for (7..10) |r| {
        for (7..10) |c| {
            image.at(r, c).* = 50;
        }
    }

    // Make bottom-right quadrant brighter
    for (11..14) |r| {
        for (11..14) |c| {
            image.at(r, c).* = 200;
        }
    }

    var fast = Fast{
        .threshold = 40,
        .nonmax_suppression = false,
    };

    const keypoints = try fast.detect(image, allocator);
    defer allocator.free(keypoints);

    // Should detect at least one corner near (10, 10)
    var found_corner = false;
    for (keypoints) |kp| {
        const dist = @sqrt((kp.x - 10) * (kp.x - 10) + (kp.y - 10) * (kp.y - 10));
        if (dist < 3.0) {
            found_corner = true;
            break;
        }
    }

    try expectEqual(true, found_corner);
}

test "FAST non-maximal suppression" {
    const allocator = std.testing.allocator;

    // Create a simple image
    var image = try Image(u8).initAlloc(allocator, 50, 50);
    defer image.deinit(allocator);

    // Fill with gradient pattern that will create many corners
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const val = @as(u8, @intCast((r + c) % 256));
            image.at(r, c).* = val;
        }
    }

    // Add some strong corners
    for (20..25) |r| {
        for (20..25) |c| {
            image.at(r, c).* = 255;
        }
    }

    for (30..35) |r| {
        for (30..35) |c| {
            image.at(r, c).* = 0;
        }
    }

    var fast_no_nms = Fast{
        .threshold = 20,
        .nonmax_suppression = false,
    };

    var fast_with_nms = Fast{
        .threshold = 20,
        .nonmax_suppression = true,
    };

    const keypoints_no_nms = try fast_no_nms.detect(image, allocator);
    defer allocator.free(keypoints_no_nms);

    const keypoints_with_nms = try fast_with_nms.detect(image, allocator);
    defer allocator.free(keypoints_with_nms);

    // Non-maximal suppression should reduce the number of keypoints
    try expectEqual(true, keypoints_with_nms.len < keypoints_no_nms.len);
}

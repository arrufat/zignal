const std = @import("std");
const testing = std.testing;
const Image = @import("../../image.zig").Image;
const Edges = @import("../edges.zig").Edges;
const color = @import("../../color.zig");
const Rgb = color.Rgb(u8);
const Gray = color.Gray;

test "Shen-Castan edge detection basic functionality" {
    const allocator = testing.allocator;

    // Create a simple test image with clear edges
    var img = try Image(u8).init(allocator, 50, 50);
    defer img.deinit(allocator);

    // Initialize with a gradient background for more realistic edge detection
    for (0..50) |r| {
        for (0..50) |c| {
            img.at(r, c).* = @intCast(c * 2); // Gradient from 0 to ~100
        }
    }

    // Create a square in the center with different intensity
    for (15..35) |r| {
        for (15..35) |c| {
            img.at(r, c).* = 200; // Bright square on gradient background
        }
    }

    // Apply Shen-Castan edge detection
    var edges = try Image(u8).initLike(allocator, img);
    defer edges.deinit(allocator);

    const filter = Edges(u8);
    var opts = @import("../../root.zig").ShenCastan{};
    opts.smooth = 0.8;
    opts.window_size = 7;
    opts.high_ratio = 0.9; // More sensitive - top 10% instead of top 1%
    opts.low_rel = 0.3; // Lower threshold for hysteresis
    try filter.shenCastan(img, allocator, opts, edges);

    // Check that edges were detected at the square boundaries
    // The exact edge pixels will depend on the algorithm parameters,
    // but we should have edges around row/col 15 and 34
    var edge_count: usize = 0;
    for (0..50) |r| {
        for (0..50) |c| {
            if (edges.at(r, c).* > 0) {
                edge_count += 1;
            }
        }
    }

    // We should have detected edges (the perimeter of the square)
    try testing.expect(edge_count > 0);
    try testing.expect(edge_count < 500); // Should not fill the entire image
}

test "Shen-Castan parameter validation" {
    const allocator = testing.allocator;

    var img = try Image(u8).init(allocator, 10, 10);
    defer img.deinit(allocator);

    var edges = try Image(u8).initLike(allocator, img);
    defer edges.deinit(allocator);

    const filter = Edges(u8);

    // Test invalid b_param (out of range)
    try testing.expectError(error.InvalidBParameter, filter.shenCastan(img, allocator, .{ .smooth = 0.0 }, edges));
    try testing.expectError(error.InvalidBParameter, filter.shenCastan(img, allocator, .{ .smooth = 1.0 }, edges));
    try testing.expectError(error.InvalidBParameter, filter.shenCastan(img, allocator, .{ .smooth = -0.5 }, edges));

    // Test invalid thresholds (ratio-based)
    try testing.expectError(error.InvalidThreshold, filter.shenCastan(img, allocator, .{ .high_ratio = 0.0 }, edges));
    try testing.expectError(error.InvalidThreshold, filter.shenCastan(img, allocator, .{ .high_ratio = 1.0 }, edges));
    try testing.expectError(error.InvalidThreshold, filter.shenCastan(img, allocator, .{ .low_rel = 0.0 }, edges));

    // Test invalid window size (even number)
    try testing.expectError(error.WindowSizeMustBeOdd, filter.shenCastan(img, allocator, .{ .window_size = 6 }, edges));

    // Test window size too small (< 3)
    try testing.expectError(error.WindowSizeTooSmall, filter.shenCastan(img, allocator, .{ .window_size = 1 }, edges));
}

test "Shen-Castan on gradient image" {
    const allocator = testing.allocator;

    // Create a gradient image
    var img = try Image(u8).init(allocator, 50, 50);
    defer img.deinit(allocator);

    // Create a smooth gradient on the left side
    for (0..50) |r| {
        for (0..25) |c| {
            img.at(r, c).* = @intCast(@min(c * 10, 200));
        }
    }

    // Add a contrasting constant region on the right
    for (0..50) |r| {
        for (25..50) |c| {
            img.at(r, c).* = 240; // High contrast from ~200 to 240
        }
    }

    var edges = try Image(u8).initLike(allocator, img);
    defer edges.deinit(allocator);

    const filter = Edges(u8);
    var opts = @import("../../root.zig").ShenCastan{};
    opts.smooth = 0.85;
    opts.window_size = 7;
    opts.high_ratio = 0.8; // Even more sensitive - top 20% of edges
    opts.low_rel = 0.3;
    try filter.shenCastan(img, allocator, opts, edges);

    // Should detect the sharp edge around column 25
    var edge_at_boundary: bool = false;
    for (10..40) |r| { // Check middle rows
        if (edges.at(r, 24).* > 0 or edges.at(r, 25).* > 0 or edges.at(r, 26).* > 0) {
            edge_at_boundary = true;
            break;
        }
    }

    try testing.expect(edge_at_boundary);
}

test "Shen-Castan with different b parameters" {
    const allocator = testing.allocator;

    // Create a noisy test image
    var img = try Image(u8).init(allocator, 40, 40);
    defer img.deinit(allocator);

    // Create a circle
    const center_r = 20;
    const center_c = 20;
    const radius = 10;

    for (0..40) |r| {
        for (0..40) |c| {
            const dr = @as(f32, @floatFromInt(r)) - @as(f32, @floatFromInt(center_r));
            const dc = @as(f32, @floatFromInt(c)) - @as(f32, @floatFromInt(center_c));
            const dist = @sqrt(dr * dr + dc * dc);

            if (dist <= @as(f32, @floatFromInt(radius))) {
                img.at(r, c).* = 200;
            } else {
                // Add slight gradient to background
                img.at(r, c).* = @intCast(50 + (r + c) / 2);
            }
        }
    }

    const filter = Edges(u8);

    // Test with low b (more smoothing)
    var edges_low_b = try Image(u8).initLike(allocator, img);
    defer edges_low_b.deinit(allocator);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.7, .window_size = 7, .high_ratio = 0.9 }, edges_low_b);

    // Test with high b (less smoothing)
    var edges_high_b = try Image(u8).initLike(allocator, img);
    defer edges_high_b.deinit(allocator);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.9, .window_size = 7, .high_ratio = 0.9 }, edges_high_b);

    // Count edges for each
    var count_low_b: usize = 0;
    var count_high_b: usize = 0;

    for (0..40) |r| {
        for (0..40) |c| {
            if (edges_low_b.at(r, c).* > 0) count_low_b += 1;
            if (edges_high_b.at(r, c).* > 0) count_high_b += 1;
        }
    }

    // Both should detect edges
    try testing.expect(count_low_b > 0);
    try testing.expect(count_high_b > 0);
}

test "Shen-Castan on RGB image" {
    const allocator = testing.allocator;

    // Create an RGB image with edges
    var img = try Image(Rgb).init(allocator, 30, 30);
    defer img.deinit(allocator);

    // Fill with gradient blue background
    for (0..30) |r| {
        for (0..30) |c| {
            const intensity: u8 = @intCast(@min(100 + r * 3, 255));
            img.at(r, c).* = .{ .r = 0, .g = 0, .b = intensity };
        }
    }

    // Add a red rectangle with different intensity
    for (10..20) |r| {
        for (10..20) |c| {
            img.at(r, c).* = .{ .r = 200, .g = 50, .b = 50 };
        }
    }

    var edges = try Image(u8).initLike(allocator, img);
    defer edges.deinit(allocator);

    const filter = Edges(Rgb);
    // Use lower thresholds for RGB edge detection
    try filter.shenCastan(img, allocator, .{ .smooth = 0.8, .window_size = 7, .high_ratio = 0.9 }, edges);

    // Should detect edges at the color boundaries
    var edge_count: usize = 0;
    for (0..30) |r| {
        for (0..30) |c| {
            if (edges.at(r, c).* > 0) {
                edge_count += 1;
            }
        }
    }

    // Debug: print edge count if test fails
    if (edge_count == 0) {
        std.debug.print("\nNo edges detected in RGB image test\n", .{});
        std.debug.print("Image size: {}x{}\n", .{ edges.rows, edges.cols });
    }

    try testing.expect(edge_count > 0);
}

test "Shen-Castan threshold monotonicity" {
    const allocator = testing.allocator;

    // Create test image with edges
    var img = try Image(u8).init(allocator, 40, 40);
    defer img.deinit(allocator);

    // Create a diagonal edge
    for (0..40) |i| {
        if (i < 20) {
            for (0..40) |j| {
                img.at(i, j).* = if (j < 20) 255 else 0;
            }
        } else {
            for (0..40) |j| {
                img.at(i, j).* = if (j < 20) 0 else 255;
            }
        }
    }

    const filter = Edges(u8);

    // Test with low thresholds
    var edges_low = try Image(u8).initLike(allocator, img);
    defer edges_low.deinit(allocator);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.8, .window_size = 7, .high_ratio = 0.95, .low_rel = 0.5 }, edges_low);

    // Test with high thresholds
    var edges_high = try Image(u8).initLike(allocator, img);
    defer edges_high.deinit(allocator);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.8, .window_size = 7, .high_ratio = 0.999, .low_rel = 0.5 }, edges_high);

    // Count edges
    var count_low: usize = 0;
    var count_high: usize = 0;
    for (0..40) |r| {
        for (0..40) |c| {
            if (edges_low.at(r, c).* > 0) count_low += 1;
            if (edges_high.at(r, c).* > 0) count_high += 1;
        }
    }

    // Higher thresholds should produce fewer or equal edges
    try testing.expect(count_high <= count_low);
    try testing.expect(count_low > 0);
}

test "Shen-Castan diagonal edge detection" {
    const allocator = testing.allocator;

    // Create image with diagonal edge
    var img = try Image(u8).init(allocator, 30, 30);
    defer img.deinit(allocator);

    // Create diagonal edge with gradient for better detection
    for (0..30) |r| {
        for (0..30) |c| {
            if (r > c + 2) {
                img.at(r, c).* = 200; // Bright region
            } else if (r + 2 < c) {
                img.at(r, c).* = 50; // Dark region
            } else {
                // Transition zone with gradient
                const diff: i32 = @as(i32, @intCast(r)) - @as(i32, @intCast(c));
                const val = @max(50, @min(200, 125 + diff * 10));
                img.at(r, c).* = @intCast(val);
            }
        }
    }

    var edges = try Image(u8).initLike(allocator, img);
    defer edges.deinit(allocator);

    const filter = Edges(u8);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.8, .window_size = 7, .high_ratio = 0.9 }, edges);

    // Check that diagonal edge is detected
    var diagonal_detected = false;
    for (5..25) |i| {
        // Check near the diagonal
        if (edges.at(i, i).* > 0 or
            edges.at(i, i - 1).* > 0 or
            edges.at(i - 1, i).* > 0)
        {
            diagonal_detected = true;
            break;
        }
    }

    try testing.expect(diagonal_detected);
}

test "Shen-Castan window size effect" {
    const allocator = testing.allocator;

    // Create noisy test image
    var img = try Image(u8).init(allocator, 50, 50);
    defer img.deinit(allocator);

    // Add a rectangle with some noise
    for (0..50) |r| {
        for (0..50) |c| {
            const base_val: u8 = if (r >= 15 and r < 35 and c >= 15 and c < 35) 200 else 50;
            // Add small noise
            const noise: u8 = @intCast(@mod(r * 7 + c * 13, 20));
            img.at(r, c).* = base_val + noise;
        }
    }

    const filter = Edges(u8);

    // Test with small window (should be more sensitive to noise)
    var edges_small = try Image(u8).initLike(allocator, img);
    defer edges_small.deinit(allocator);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.8, .window_size = 3, .high_ratio = 0.9 }, edges_small);

    // Test with larger window (should be more robust to noise)
    var edges_large = try Image(u8).initLike(allocator, img);
    defer edges_large.deinit(allocator);
    try filter.shenCastan(img, allocator, .{ .smooth = 0.8, .window_size = 11, .high_ratio = 0.9 }, edges_large);

    // Both should detect some edges
    var count_small: usize = 0;
    var count_large: usize = 0;
    for (0..50) |r| {
        for (0..50) |c| {
            if (edges_small.at(r, c).* > 0) count_small += 1;
            if (edges_large.at(r, c).* > 0) count_large += 1;
        }
    }

    try testing.expect(count_small > 0);
    try testing.expect(count_large > 0);
    // Larger window typically produces cleaner edges
    // But this isn't guaranteed with our simple noise model
}

const std = @import("std");
const zignal = @import("../../root.zig");
const Image = zignal.Image;
const Rectangle = zignal.Rectangle;
const testing = std.testing;

test "extract and insert are inverses with various transformations" {
    const allocator = testing.allocator;

    // Create a test image with a recognizable pattern
    var source = try Image(u8).initAlloc(allocator, 100, 100);
    defer source.deinit(allocator);

    // Fill with a gradient pattern that will show any distortion
    for (0..source.rows) |r| {
        for (0..source.cols) |c| {
            // Create a diagonal gradient pattern
            const val = @as(u8, @intCast((r + c) % 256));
            source.at(r, c).* = val;
        }
    }

    // Test cases with different rectangles, angles, and scales
    const test_cases = [_]struct {
        rect: Rectangle(f32),
        angle: f32,
        out_rows: usize,
        out_cols: usize,
        method: zignal.InterpolationMethod,
    }{
        // No rotation, no scaling
        .{
            .rect = Rectangle(f32).init(20, 20, 60, 60),
            .angle = 0,
            .out_rows = 40,
            .out_cols = 40,
            .method = .bilinear,
        },
        // 45-degree rotation, no scaling
        .{
            .rect = Rectangle(f32).init(30, 30, 70, 70),
            .angle = std.math.pi / 4.0,
            .out_rows = 40,
            .out_cols = 40,
            .method = .bilinear,
        },
        // No rotation, 2x upscaling
        .{
            .rect = Rectangle(f32).init(25, 25, 45, 45),
            .angle = 0,
            .out_rows = 40,
            .out_cols = 40,
            .method = .bicubic,
        },
        // 30-degree rotation, 0.5x downscaling
        .{
            .rect = Rectangle(f32).init(10, 10, 70, 70),
            .angle = std.math.pi / 6.0,
            .out_rows = 30,
            .out_cols = 30,
            .method = .lanczos,
        },
        // 90-degree rotation
        .{
            .rect = Rectangle(f32).init(35, 35, 65, 65),
            .angle = std.math.pi / 2.0,
            .out_rows = 30,
            .out_cols = 30,
            .method = .nearest_neighbor,
        },
        // Arbitrary angle and rectangle
        .{
            .rect = Rectangle(f32).init(15.5, 22.3, 78.7, 84.2),
            .angle = 1.234,
            .out_rows = 50,
            .out_cols = 45,
            .method = .bilinear,
        },
    };

    for (test_cases, 0..) |tc, i| {
        // Extract a patch from the source
        var extracted = try Image(u8).initAlloc(allocator, tc.out_rows, tc.out_cols);
        defer extracted.deinit(allocator);

        source.extract(tc.rect, tc.angle, extracted, tc.method);

        // Create a blank canvas
        var canvas = try Image(u8).initAlloc(allocator, 100, 100);
        defer canvas.deinit(allocator);

        // Fill canvas with zeros
        @memset(canvas.data, 0);

        // Insert the extracted patch back at the same location
        canvas.insert(extracted, tc.rect, tc.angle, tc.method);

        // Check that the pixels within the rectangle match the original
        // We need to be somewhat tolerant due to interpolation errors
        var total_error: f64 = 0;
        var pixel_count: usize = 0;

        // Only check pixels that should have been affected by the insert
        const cx = (tc.rect.l + tc.rect.r) * 0.5;
        const cy = (tc.rect.t + tc.rect.b) * 0.5;
        const half_w = tc.rect.width() * 0.5;
        const half_h = tc.rect.height() * 0.5;

        // Check a smaller region to avoid edge effects
        const check_radius = @min(half_w, half_h) * 0.8;
        const check_rect = Rectangle(f32).initCenter(cx, cy, check_radius * 2, check_radius * 2);

        const start_r = @as(usize, @intFromFloat(@max(0, check_rect.t)));
        const end_r = @as(usize, @intFromFloat(@min(@as(f32, @floatFromInt(source.rows)), check_rect.b)));
        const start_c = @as(usize, @intFromFloat(@max(0, check_rect.l)));
        const end_c = @as(usize, @intFromFloat(@min(@as(f32, @floatFromInt(source.cols)), check_rect.r)));

        for (start_r..end_r) |r| {
            for (start_c..end_c) |c| {
                const orig_val = source.at(r, c).*;
                const reconstructed_val = canvas.at(r, c).*;
                const diff = @abs(@as(i16, orig_val) - @as(i16, reconstructed_val));
                total_error += @as(f64, @floatFromInt(diff));
                pixel_count += 1;
            }
        }

        const avg_error = if (pixel_count > 0) total_error / @as(f64, @floatFromInt(pixel_count)) else 0;

        // For nearest neighbor, we expect exact reconstruction
        // For other methods, allow some interpolation error
        const tolerance: f64 = switch (tc.method) {
            .nearest_neighbor => 15.0, // Some error due to rounding
            .bilinear => 20.0, // Interpolation error
            .bicubic => 25.0, // More error due to overshooting
            .lanczos => 30.0, // Can have ringing artifacts
            .catmull_rom => 25.0, // Similar to bicubic
            .mitchell => 25.0, // Similar to bicubic
        };

        if (avg_error >= tolerance) {
            std.debug.print("Test case {}: avg_error = {d:.2} >= tolerance = {d:.2} (method: {any})\n", .{ i, avg_error, tolerance, tc.method });
        }
        try testing.expect(avg_error < tolerance);

        // Also verify that pixels outside the rectangle remain zero
        var outside_sum: u32 = 0;
        for (0..canvas.rows) |r| {
            for (0..canvas.cols) |c| {
                const fx = @as(f32, @floatFromInt(c));
                const fy = @as(f32, @floatFromInt(r));

                // Check if point is far outside the rectangle (with some margin)
                const dx = fx - cx;
                const dy = fy - cy;
                const dist_sq = dx * dx + dy * dy;
                const max_radius_sq = (half_w + half_h) * (half_w + half_h);

                if (dist_sq > max_radius_sq * 1.5) {
                    outside_sum += canvas.at(r, c).*;
                }
            }
        }

        // Pixels far outside should remain untouched (zero)
        try testing.expectEqual(@as(u32, 0), outside_sum);
    }
}

test "insert with exact inverse of extract parameters" {
    const allocator = testing.allocator;

    // Create a test image
    var img = try Image(u8).initAlloc(allocator, 64, 64);
    defer img.deinit(allocator);

    // Fill with checkerboard pattern
    for (0..img.rows) |r| {
        for (0..img.cols) |c| {
            const val = if ((r / 8 + c / 8) % 2 == 0) @as(u8, 255) else @as(u8, 0);
            img.at(r, c).* = val;
        }
    }

    // Define extraction parameters - simple case first
    const rect = Rectangle(f32).init(16, 16, 48, 48);
    const angle: f32 = 0; // No rotation for simpler test

    // Extract a patch
    var patch = try Image(u8).initAlloc(allocator, 32, 32);
    defer patch.deinit(allocator);
    img.extract(rect, angle, patch, .bilinear);

    // Create a blank canvas and insert the patch
    var canvas = try Image(u8).initAlloc(allocator, 64, 64);
    defer canvas.deinit(allocator);
    @memset(canvas.data, 0);

    canvas.insert(patch, rect, angle, .bilinear);

    // Check the center region where we expect good reconstruction
    var max_diff: u8 = 0;
    var total_diff: u32 = 0;
    var count: u32 = 0;

    for (20..44) |r| {
        for (20..44) |c| {
            const v1 = img.at(r, c).*;
            const v2 = canvas.at(r, c).*;
            const diff = if (v1 > v2) v1 - v2 else v2 - v1;
            max_diff = @max(max_diff, diff);
            total_diff += diff;
            count += 1;
        }
    }

    const avg_diff = @as(f32, @floatFromInt(total_diff)) / @as(f32, @floatFromInt(count));

    // Should be very close for no rotation case
    if (max_diff >= 5 or avg_diff >= 2) {
        std.debug.print("Simple insert test: max_diff = {}, avg_diff = {d:.2}\n", .{ max_diff, avg_diff });
    }
    try testing.expect(max_diff < 5);
    try testing.expect(avg_diff < 2);
}

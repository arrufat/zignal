const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

const Canvas = @import("../Canvas.zig").Canvas;
const Image = @import("../../image.zig").Image;
const Rgb = @import("../../color.zig").Rgb;
const Rgba = @import("../../color.zig").Rgba;
const Point = @import("../../geometry/Point.zig").Point;

test "arc drawing - basic angles" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgb).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgb).init(allocator, img);
    const center: Point(2, f32) = .point(.{ 100, 100 });
    const radius: f32 = 50;

    // Clear to white
    img.fill(Rgb.white);

    // Test quarter arc (0 to π/2)
    try canvas.drawArc(center, radius, 0, std.math.pi / 2.0, Rgb.black, 2, .fast);

    // Verify some pixels are drawn
    var black_count: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0 and pixel.g == 0 and pixel.b == 0) {
            black_count += 1;
        }
    }
    try expect(black_count > 0);

    // Test that the arc is in the correct quadrant (right and below center)
    // Sample a point that should be on the arc at 45 degrees
    const angle_45 = std.math.pi / 4.0;
    const expected_x = center.x() + radius * @cos(angle_45);
    const expected_y = center.y() + radius * @sin(angle_45);

    // Check a small area around the expected point
    var found_pixel = false;
    const check_radius: usize = 3;
    var dy: usize = 0;
    while (dy < check_radius * 2) : (dy += 1) {
        var dx: usize = 0;
        while (dx < check_radius * 2) : (dx += 1) {
            const x = @as(usize, @intFromFloat(@round(expected_x))) + dx - check_radius;
            const y = @as(usize, @intFromFloat(@round(expected_y))) + dy - check_radius;
            if (x < width and y < height) {
                const pixel = img.at(y, x);
                if (pixel.r == 0 and pixel.g == 0 and pixel.b == 0) {
                    found_pixel = true;
                    break;
                }
            }
        }
        if (found_pixel) break;
    }
    try expect(found_pixel);
}

test "arc drawing - full circle optimization" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgb).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgb).init(allocator, img);
    const center: Point(2, f32) = .point(.{ 100, 100 });
    const radius: f32 = 40;

    // Clear to white
    img.fill(Rgb.white);

    // Draw a full circle using arc (should trigger optimization)
    try canvas.drawArc(center, radius, 0, 2 * std.math.pi, Rgb.black, 1, .fast);

    // Count black pixels
    var black_count: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0 and pixel.g == 0 and pixel.b == 0) {
            black_count += 1;
        }
    }

    // Should have approximately 2πr pixels for a circle outline
    const expected = @as(usize, @intFromFloat(2 * std.math.pi * radius));
    try expect(black_count > expected * 3 / 4); // Allow some tolerance
    try expect(black_count < expected * 5 / 4);
}

test "arc drawing - angle wrapping" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img1 = try Image(Rgb).initAlloc(allocator, width, height);
    defer img1.deinit(allocator);
    var img2 = try Image(Rgb).initAlloc(allocator, width, height);
    defer img2.deinit(allocator);

    const canvas1 = Canvas(Rgb).init(allocator, img1);
    const canvas2 = Canvas(Rgb).init(allocator, img2);
    const center: Point(2, f32) = .point(.{ 100, 100 });
    const radius: f32 = 50;

    // Clear both images
    img1.fill(Rgb.white);
    img2.fill(Rgb.white);

    // Draw arc from 3π/2 to π/2 (wraps around 0)
    try canvas1.drawArc(center, radius, 3.0 * std.math.pi / 2.0, std.math.pi / 2.0, Rgb.black, 2, .fast);

    // Draw equivalent arc from -π/2 to π/2
    try canvas2.drawArc(center, radius, -std.math.pi / 2.0, std.math.pi / 2.0, Rgb.black, 2, .fast);

    // Both should produce the same result (approximately)
    var matching_pixels: usize = 0;
    var total_black1: usize = 0;
    var total_black2: usize = 0;

    for (img1.data, img2.data) |p1, p2| {
        const is_black1 = (p1.r == 0 and p1.g == 0 and p1.b == 0);
        const is_black2 = (p2.r == 0 and p2.g == 0 and p2.b == 0);
        if (is_black1) total_black1 += 1;
        if (is_black2) total_black2 += 1;
        if (is_black1 and is_black2) matching_pixels += 1;
    }

    // Should have similar number of black pixels
    const diff = if (total_black1 > total_black2) total_black1 - total_black2 else total_black2 - total_black1;
    try expect(diff < @max(total_black1, total_black2) / 10); // Less than 10% difference
}

test "fillArc - pie slices" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgb).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgb).init(allocator, img);
    const center: Point(2, f32) = .point(.{ 100, 100 });
    const radius: f32 = 50;

    // Clear to white
    img.fill(Rgb.white);

    // Fill a quarter pie slice (0 to π/2)
    try canvas.fillArc(center, radius, 0, std.math.pi / 2.0, Rgb.black, .fast);

    // Count black pixels
    var black_count: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0 and pixel.g == 0 and pixel.b == 0) {
            black_count += 1;
        }
    }

    // Quarter circle area should be approximately πr²/4
    const expected_area = @as(usize, @intFromFloat(std.math.pi * radius * radius / 4));
    try expect(black_count > expected_area * 3 / 4); // Allow tolerance
    try expect(black_count < expected_area * 5 / 4);

    // Verify the filled area is in the correct quadrant
    // Points in the first quadrant (x > center.x, y > center.y) should be filled
    const sample_x = @as(usize, @intFromFloat(center.x() + radius / 2));
    const sample_y = @as(usize, @intFromFloat(center.y() + radius / 2));
    const sample_pixel = img.at(sample_y, sample_x);
    try expect(sample_pixel.r == 0 and sample_pixel.g == 0 and sample_pixel.b == 0);

    // Points in the opposite quadrant should not be filled
    const opposite_x = @as(usize, @intFromFloat(center.x() - radius / 2));
    const opposite_y = @as(usize, @intFromFloat(center.y() - radius / 2));
    const opposite_pixel = img.at(opposite_y, opposite_x);
    try expect(opposite_pixel.r == 255 and opposite_pixel.g == 255 and opposite_pixel.b == 255);
}

test "arc drawing - soft vs fast mode" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img_fast = try Image(Rgba).initAlloc(allocator, width, height);
    defer img_fast.deinit(allocator);
    var img_soft = try Image(Rgba).initAlloc(allocator, width, height);
    defer img_soft.deinit(allocator);

    const canvas_fast = Canvas(Rgba).init(allocator, img_fast);
    const canvas_soft = Canvas(Rgba).init(allocator, img_soft);
    const center: Point(2, f32) = .point(.{ 100, 100 });
    const radius: f32 = 60;
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Clear both images
    for (img_fast.data) |*p| p.* = Rgba.white;
    for (img_soft.data) |*p| p.* = Rgba.white;

    // Draw same arc with different modes
    try canvas_fast.drawArc(center, radius, std.math.pi / 6.0, 5.0 * std.math.pi / 6.0, color, 3, .fast);
    try canvas_soft.drawArc(center, radius, std.math.pi / 6.0, 5.0 * std.math.pi / 6.0, color, 3, .soft);

    // Count pixels with partial transparency (antialiasing)
    var soft_partial_count: usize = 0;
    var fast_partial_count: usize = 0;

    for (img_soft.data) |pixel| {
        if (pixel.r < 255 and pixel.r > 0) {
            soft_partial_count += 1;
        }
    }

    for (img_fast.data) |pixel| {
        if (pixel.r < 255 and pixel.r > 0) {
            fast_partial_count += 1;
        }
    }

    // Soft mode should have antialiased edges (partial transparency)
    try expect(soft_partial_count > 0);
    // Fast mode should have no or very few partially transparent pixels
    try expect(fast_partial_count < soft_partial_count / 2);
}

test "arc drawing - zero and negative radius" {
    const allocator = testing.allocator;
    const width = 100;
    const height = 100;
    var img = try Image(Rgb).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgb).init(allocator, img);
    const center: Point(2, f32) = .point(.{ 50, 50 });

    // Clear to white
    img.fill(Rgb.white);

    // These should not crash and should not draw anything
    try canvas.drawArc(center, 0, 0, std.math.pi, Rgb.black, 1, .fast);
    try canvas.drawArc(center, -10, 0, std.math.pi, Rgb.black, 1, .fast);
    try canvas.fillArc(center, 0, 0, std.math.pi, Rgb.black, .fast);
    try canvas.fillArc(center, -10, 0, std.math.pi, Rgb.black, .fast);

    // Image should still be all white
    for (img.data) |pixel| {
        try expect(pixel.r == 255 and pixel.g == 255 and pixel.b == 255);
    }
}

test "arc drawing - NaN and Inf angles" {
    const allocator = testing.allocator;
    const width = 100;
    const height = 100;
    var img = try Image(Rgb).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgb).init(allocator, img);
    const center: Point(2, f32) = .point(.{ 50, 50 });

    // Clear to white
    img.fill(Rgb.white);

    // These should not crash and should not draw anything
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    try canvas.drawArc(center, 30, nan, std.math.pi, Rgb.black, 2, .fast);
    try canvas.drawArc(center, 30, 0, inf, Rgb.black, 2, .fast);
    try canvas.drawArc(center, 30, -inf, inf, Rgb.black, 2, .fast);
    try canvas.fillArc(center, 30, nan, std.math.pi, Rgb.black, .fast);
    try canvas.fillArc(center, 30, 0, inf, Rgb.black, .fast);
    try canvas.fillArc(center, 30, -inf, nan, Rgb.black, .fast);

    // Image should still be all white (no drawing occurred)
    for (img.data) |pixel| {
        try expect(pixel.r == 255 and pixel.g == 255 and pixel.b == 255);
    }
}

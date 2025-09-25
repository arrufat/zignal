//! Integral image tests

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Image = @import("../../image.zig").Image;
const color = @import("../../color.zig");
const Integral = @import("../integral.zig").Integral;

test "integral image scalar" {
    var image: Image(u8) = try .init(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = 1;
    var integral: Image(f32) = .empty;
    try image.integral(std.testing.allocator, &integral);
    defer integral.deinit(std.testing.allocator);
    try expectEqual(image.rows, integral.rows);
    try expectEqual(image.cols, integral.cols);
    try expectEqual(image.data.len, integral.data.len);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            try expectEqual(area_at_pos, integral.at(r, c).*);
        }
    }
}

test "integral image view scalar" {
    var image: Image(u8) = try .init(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = 1;
    const view = image.view(.{ .l = 2, .t = 3, .r = 8, .b = 10 });
    var integral: Image(f32) = .empty;
    try view.integral(std.testing.allocator, &integral);
    defer integral.deinit(std.testing.allocator);
    try expectEqual(view.rows, integral.rows);
    try expectEqual(view.cols, integral.cols);
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            try expectEqual(area_at_pos, integral.at(r, c).*);
        }
    }
}

test "integral image struct" {
    var image: Image(color.Rgba) = try .init(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    var integral: Image([4]f32) = .empty;
    try image.integral(std.testing.allocator, &integral);

    defer integral.deinit(std.testing.allocator);
    try expectEqual(image.rows, integral.rows);
    try expectEqual(image.cols, integral.cols);
    try expectEqual(image.data.len, integral.data.len);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            for (0..4) |i| {
                try expectEqual(area_at_pos, integral.at(r, c)[i]);
            }
        }
    }
}

test "integral image RGB vs RGBA with full alpha produces same RGB values" {
    const Rgb = color.Rgb;
    const test_size = 10;

    // Create RGB image
    var rgb_img = try Image(Rgb).init(std.testing.allocator, test_size, test_size);
    defer rgb_img.deinit(std.testing.allocator);

    // Create RGBA image
    var rgba_img = try Image(color.Rgba).init(std.testing.allocator, test_size, test_size);
    defer rgba_img.deinit(std.testing.allocator);

    // Fill both with identical RGB values
    var seed: u8 = 0;
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            seed +%= 17;
            const r_val = seed;
            const g_val = seed +% 50;
            const b_val = seed +% 100;

            rgb_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val };
            rgba_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val, .a = 255 };
        }
    }

    // Apply integral to both
    var rgb_integral: Image([3]f32) = .empty;
    try rgb_img.integral(std.testing.allocator, &rgb_integral);
    defer rgb_integral.deinit(std.testing.allocator);

    var rgba_integral: Image([4]f32) = .empty;
    try rgba_img.integral(std.testing.allocator, &rgba_integral);
    defer rgba_integral.deinit(std.testing.allocator);

    // Compare RGB channels - they should be identical
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const rgb = rgb_integral.at(r, c).*;
            const rgba = rgba_integral.at(r, c).*;

            try expectEqual(rgb[0], rgba[0]);
            try expectEqual(rgb[1], rgba[1]);
            try expectEqual(rgb[2], rgba[2]);
        }
    }
}

test "computeIntegralSum function" {
    const allocator = std.testing.allocator;

    // Create a simple 3x3 test image with values 1-9
    var src = try Image(u8).init(allocator, 3, 3);
    defer src.deinit(allocator);

    for (0..3) |r| {
        for (0..3) |c| {
            src.at(r, c).* = @intCast(r * 3 + c + 1);
        }
    }

    // Build integral image using the integralPlane function directly
    var integral_img = try Image(f32).init(allocator, 3, 3);
    defer integral_img.deinit(allocator);

    Integral(u8).plane(src, integral_img);

    // Test box sum computation using computeIntegralSum
    const sum_all = Integral(u8).sum(integral_img, 0, 0, 2, 2);
    try expectEqual(@as(f32, 45), sum_all); // 1+2+3+4+5+6+7+8+9 = 45

    // Test a smaller box (top-left 2x2)
    const sum_2x2 = Integral(u8).sum(integral_img, 0, 0, 1, 1);
    try expectEqual(@as(f32, 12), sum_2x2); // 1+2+4+5 = 12

    // Test bottom-right 2x2
    const sum_br = Integral(f32).sum(integral_img, 1, 1, 2, 2);
    try expectEqual(@as(f32, 28), sum_br); // 5+6+8+9 = 28

    // Test single pixel
    const sum_single = Integral(f32).sum(integral_img, 1, 1, 1, 1);
    try expectEqual(@as(f32, 5), sum_single); // Just the center pixel
}

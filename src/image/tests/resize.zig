//! Tests for image resizing operations including resize, scale, and letterbox functionality

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const color = @import("../../color.zig");
const Image = @import("../Image.zig").Image;

test "letterbox maintains aspect ratio with padding" {
    const allocator = std.testing.allocator;

    // Test 1: Wide image to square - should add vertical padding
    {
        // Create 8x4 image (2:1 aspect ratio)
        var src: Image(u8) = try .init(allocator, 4, 8);
        defer src.deinit(allocator);

        // Fill with gradient to verify content preservation
        for (0..src.rows) |r| {
            for (0..src.cols) |c| {
                src.at(r, c).* = @intCast(r * 20 + c * 10);
            }
        }

        // Letterbox to 6x6 square
        var output: Image(u8) = try .init(allocator, 6, 6);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, .bilinear);

        try expectEqual(@as(usize, 6), rect.width());
        try expectEqual(@as(usize, 3), rect.height());
        try expectEqual(@as(usize, 0), rect.l);
        try expectEqual(@as(usize, 1), rect.t);

        // Verify padding is zeroed
        for (0..rect.t) |r| {
            for (0..output.cols) |c| {
                try expectEqual(@as(u8, 0), output.at(r, c).*);
            }
        }
        for (rect.b..output.rows) |r| {
            for (0..output.cols) |c| {
                try expectEqual(@as(u8, 0), output.at(r, c).*);
            }
        }
    }

    // Test 2: Tall image to wide - should add horizontal padding
    {
        // Create 3x9 image (1:3 aspect ratio)
        var src: Image(color.Rgb) = try .init(allocator, 9, 3);
        defer src.deinit(allocator);

        // Fill with distinct colors
        const red: color.Rgb = .{ .r = 255, .g = 0, .b = 0 };
        const green: color.Rgb = .{ .r = 0, .g = 255, .b = 0 };
        const blue: color.Rgb = .{ .r = 0, .g = 0, .b = 255 };

        // Create vertical stripes
        for (0..src.rows) |r| {
            src.at(r, 0).* = red;
            src.at(r, 1).* = green;
            src.at(r, 2).* = blue;
        }

        // Letterbox to 12x4 (3:1 aspect ratio)
        var output: Image(color.Rgb) = try .init(allocator, 4, 12);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, .nearest_neighbor);

        try expectEqual(@as(usize, 1), rect.width());
        try expectEqual(@as(usize, 4), rect.height());

        // Should be centered horizontally
        const expected_left = (12 - 1) / 2;
        try expectEqual(@as(usize, expected_left), rect.l);

        // Verify horizontal padding is black
        const black: color.Rgb = .{ .r = 0, .g = 0, .b = 0 };
        for (0..output.rows) |r| {
            for (0..rect.l) |c| {
                try expectEqual(black, output.at(r, c).*);
            }
            for (rect.r..output.cols) |c| {
                try expectEqual(black, output.at(r, c).*);
            }
        }
    }
}

test "letterbox edge cases" {
    const allocator = std.testing.allocator;

    // Test zero dimension handling
    {
        var src: Image(u8) = try .init(allocator, 5, 5);
        defer src.deinit(allocator);

        var output: Image(u8) = .initFromSlice(0, 10, &[_]u8{});
        try expectError(error.InvalidDimensions, src.letterbox(allocator, &output, .nearest_neighbor));

        var output2: Image(u8) = .initFromSlice(10, 0, &[_]u8{});
        try expectError(error.InvalidDimensions, src.letterbox(allocator, &output2, .nearest_neighbor));
    }

    // Test same aspect ratio - no padding needed
    {
        var src: Image(f32) = try .init(allocator, 4, 6);
        defer src.deinit(allocator);

        // Fill with test values
        for (0..src.rows) |r| {
            for (0..src.cols) |c| {
                src.at(r, c).* = @as(f32, @floatFromInt(r * 10 + c)) + 1.0;
            }
        }

        // Scale to 8x12 (same 3:2 aspect ratio)
        var output: Image(f32) = try .init(allocator, 8, 12);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, .bicubic);

        // Should fill entire output
        try expectEqual(@as(usize, 12), rect.width());
        try expectEqual(@as(usize, 8), rect.height());
        try expectEqual(@as(usize, 0), rect.l);
        try expectEqual(@as(usize, 0), rect.t);
    }

    // Test 1x1 source image
    {
        var src: Image(u8) = try .init(allocator, 1, 1);
        defer src.deinit(allocator);
        src.at(0, 0).* = 128;

        var output: Image(u8) = try .init(allocator, 10, 10);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, .nearest_neighbor);

        // 1x1 scaled to fit 10x10 = 10x10
        try expectEqual(@as(usize, 10), rect.width());
        try expectEqual(@as(usize, 10), rect.height());

        // All pixels should be 128
        for (0..output.rows) |r| {
            for (0..output.cols) |c| {
                try expectEqual(@as(u8, 128), output.at(r, c).*);
            }
        }
    }
}

test "letterbox interpolation methods comparison" {
    const allocator = std.testing.allocator;

    // Create a gradient pattern to ensure interpolation produces intermediate values
    var src: Image(u8) = try .init(allocator, 3, 3);
    defer src.deinit(allocator);

    // Create gradient from 0 to 255
    src.at(0, 0).* = 0;
    src.at(0, 1).* = 128;
    src.at(0, 2).* = 255;
    src.at(1, 0).* = 64;
    src.at(1, 1).* = 128;
    src.at(1, 2).* = 192;
    src.at(2, 0).* = 128;
    src.at(2, 1).* = 192;
    src.at(2, 2).* = 255;

    // Test different interpolation methods
    const methods = [_]@import("../interpolation.zig").InterpolationMethod{
        .nearest_neighbor,
        .bilinear,
        .bicubic,
        .lanczos,
    };

    for (methods) |method| {
        var output: Image(u8) = try .init(allocator, 10, 10);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, method);

        // Should scale to 10x10 (no padding for square to square)
        try expectEqual(@as(usize, 10), rect.width());
        try expectEqual(@as(usize, 10), rect.height());
    }
}

test "letterbox extreme aspect ratios" {
    const allocator = std.testing.allocator;

    // Test very wide image (16:1)
    {
        var src: Image(u8) = try .init(allocator, 2, 32);
        defer src.deinit(allocator);
        for (0..src.data.len) |i| {
            src.data[i] = 200;
        }

        // Letterbox to square
        var output: Image(u8) = try .init(allocator, 64, 64);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, .bilinear);

        // Should maintain aspect ratio
        const scale = @min(@as(f32, 64.0 / 2.0), @as(f32, 64.0 / 32.0));
        try expectEqual(@as(f32, 2.0), scale);

        // Scaled size: 32*2 x 2*2 = 64x4
        try expectEqual(@as(usize, 64), rect.width());
        try expectEqual(@as(usize, 4), rect.height());

        // Should have significant vertical padding
        try expectEqual(@as(usize, 30), rect.t); // (64-4)/2 = 30
    }

    // Test very tall image (1:16)
    {
        var src: Image(u8) = try .init(allocator, 32, 2);
        defer src.deinit(allocator);
        for (0..src.data.len) |i| {
            src.data[i] = 100;
        }

        // Letterbox to square
        var output: Image(u8) = try .init(allocator, 64, 64);
        defer output.deinit(allocator);

        const rect = try src.letterbox(allocator, &output, .bicubic);

        // Should maintain aspect ratio
        const scale = @min(@as(f32, 64.0 / 32.0), @as(f32, 64.0 / 2.0));
        try expectEqual(@as(f32, 2.0), scale);

        // Scaled size: 2*2 x 32*2 = 4x64
        try expectEqual(@as(usize, 4), rect.width());
        try expectEqual(@as(usize, 64), rect.height());

        // Should have significant horizontal padding
        try expectEqual(@as(usize, 30), rect.l); // (64-4)/2 = 30
    }
}

test "scale image" {
    const allocator = std.testing.allocator;

    // Create a test image
    var img = try Image(u8).init(allocator, 100, 100);
    defer img.deinit(allocator);

    // Fill with some pattern
    for (0..img.rows) |r| {
        for (0..img.cols) |c| {
            img.at(r, c).* = @truncate((r + c) % 256);
        }
    }

    // Test scaling down
    var half = try img.scale(allocator, 0.5, .bilinear);
    defer half.deinit(allocator);
    try expectEqual(@as(usize, 50), half.rows);
    try expectEqual(@as(usize, 50), half.cols);

    // Test scaling up
    var double = try img.scale(allocator, 2.0, .bilinear);
    defer double.deinit(allocator);
    try expectEqual(@as(usize, 200), double.rows);
    try expectEqual(@as(usize, 200), double.cols);

    // Test non-uniform scaling factors
    var custom = try img.scale(allocator, 1.5, .nearest_neighbor);
    defer custom.deinit(allocator);
    try expectEqual(@as(usize, 150), custom.rows);
    try expectEqual(@as(usize, 150), custom.cols);

    // Test edge cases
    try expectError(error.InvalidScaleFactor, img.scale(allocator, 0, .bilinear));
    try expectError(error.InvalidScaleFactor, img.scale(allocator, -1, .bilinear));

    // Test very small scale that would result in 0 dimensions
    var tiny_img = try Image(u8).init(allocator, 2, 2);
    defer tiny_img.deinit(allocator);
    try expectError(error.InvalidDimensions, tiny_img.scale(allocator, 0.1, .bilinear));
}

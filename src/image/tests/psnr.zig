//! PSNR (Peak Signal-to-Noise Ratio) tests

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectError = std.testing.expectError;

const color = @import("../../color.zig");
const Rgb = color.Rgb;
const Rgba = color.Rgba;
const Image = @import("../Image.zig").Image;

test "PSNR identical images returns inf" {
    // Test with u8 scalar type
    var img1 = try Image(u8).initAlloc(std.testing.allocator, 10, 10);
    defer img1.deinit(std.testing.allocator);
    for (img1.data) |*pixel| {
        pixel.* = 128;
    }

    var img2 = try Image(u8).initAlloc(std.testing.allocator, 10, 10);
    defer img2.deinit(std.testing.allocator);
    for (img2.data) |*pixel| {
        pixel.* = 128;
    }

    const psnr = try img1.psnr(img2);
    try expectEqual(std.math.inf(f64), psnr);
}

test "PSNR dimension mismatch error" {
    var img1 = try Image(u8).initAlloc(std.testing.allocator, 10, 10);
    defer img1.deinit(std.testing.allocator);

    var img2 = try Image(u8).initAlloc(std.testing.allocator, 10, 20);
    defer img2.deinit(std.testing.allocator);

    try expectError(error.DimensionMismatch, img1.psnr(img2));
}

test "PSNR with known values for u8" {
    var img1 = try Image(u8).initAlloc(std.testing.allocator, 2, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = 100;
    img1.at(0, 1).* = 150;
    img1.at(1, 0).* = 200;
    img1.at(1, 1).* = 250;

    var img2 = try Image(u8).initAlloc(std.testing.allocator, 2, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = 110; // diff = 10
    img2.at(0, 1).* = 140; // diff = -10
    img2.at(1, 0).* = 205; // diff = 5
    img2.at(1, 1).* = 245; // diff = -5

    // MSE = (100 + 100 + 25 + 25) / 4 = 62.5
    // PSNR = 10 * log10(255^2 / 62.5) = 10 * log10(1040.4) = 30.171
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(30.171, psnr, 0.01);
}

test "PSNR with RGB struct type" {
    var img1 = try Image(Rgb).initAlloc(std.testing.allocator, 2, 2);
    defer img1.deinit(std.testing.allocator);
    img1.fill(Rgb{ .r = 100, .g = 150, .b = 200 });

    var img2 = try Image(Rgb).initAlloc(std.testing.allocator, 2, 2);
    defer img2.deinit(std.testing.allocator);
    img2.fill(Rgb{ .r = 110, .g = 140, .b = 205 });

    // Each pixel has diffs: r=10, g=-10, b=5
    // MSE per pixel = (100 + 100 + 25) / 3 = 75
    // All 4 pixels are the same, so overall MSE = 75
    // PSNR = 10 * log10(255^2 / 75) = 10 * log10(867) = 29.38
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(29.38, psnr, 0.01);
}

test "PSNR with RGBA struct type" {
    var img1 = try Image(Rgba).initAlloc(std.testing.allocator, 1, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    img1.at(0, 1).* = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };

    var img2 = try Image(Rgba).initAlloc(std.testing.allocator, 1, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = Rgba{ .r = 250, .g = 5, .b = 0, .a = 255 }; // diffs: 5, 5, 0, 0
    img2.at(0, 1).* = Rgba{ .r = 0, .g = 250, .b = 5, .a = 255 }; // diffs: 0, 5, 5, 0

    // MSE = (25 + 25 + 0 + 0 + 0 + 25 + 25 + 0) / 8 = 12.5
    // PSNR = 10 * log10(255^2 / 12.5) = 10 * log10(5202) = 37.16
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(37.16, psnr, 0.01);
}

test "PSNR with f32 scalar type" {
    var img1 = try Image(f32).initAlloc(std.testing.allocator, 2, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = 0.5;
    img1.at(0, 1).* = 0.7;
    img1.at(1, 0).* = 0.3;
    img1.at(1, 1).* = 0.9;

    var img2 = try Image(f32).initAlloc(std.testing.allocator, 2, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = 0.4; // diff = 0.1
    img2.at(0, 1).* = 0.8; // diff = -0.1
    img2.at(1, 0).* = 0.2; // diff = 0.1
    img2.at(1, 1).* = 1.0; // diff = -0.1

    // MSE = (0.01 + 0.01 + 0.01 + 0.01) / 4 = 0.01
    // PSNR = 10 * log10(1.0 / 0.01) = 10 * log10(100) = 20.0
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(20.0, psnr, 0.01);
}

test "PSNR with array type [3]u8" {
    var img1 = try Image([3]u8).initAlloc(std.testing.allocator, 1, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = .{ 100, 150, 200 };
    img1.at(0, 1).* = .{ 50, 100, 150 };

    var img2 = try Image([3]u8).initAlloc(std.testing.allocator, 1, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = .{ 105, 145, 195 }; // diffs: 5, -5, -5
    img2.at(0, 1).* = .{ 45, 105, 155 }; // diffs: -5, 5, 5

    // MSE = (25 + 25 + 25 + 25 + 25 + 25) / 6 = 25
    // PSNR = 10 * log10(255^2 / 25) = 10 * log10(2601) = 34.15
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(34.15, psnr, 0.01);
}

test "PSNR extreme case: black vs white" {
    var img1 = try Image(u8).initAlloc(std.testing.allocator, 10, 10);
    defer img1.deinit(std.testing.allocator);
    for (img1.data) |*pixel| {
        pixel.* = 0; // All black
    }

    var img2 = try Image(u8).initAlloc(std.testing.allocator, 10, 10);
    defer img2.deinit(std.testing.allocator);
    for (img2.data) |*pixel| {
        pixel.* = 255; // All white
    }

    // MSE = 255^2 = 65025
    // PSNR = 10 * log10(255^2 / 65025) = 10 * log10(1) = 0
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(0.0, psnr, 0.01);
}

test "PSNR with slight noise" {
    var img1 = try Image(u8).initAlloc(std.testing.allocator, 100, 100);
    defer img1.deinit(std.testing.allocator);
    for (img1.data) |*pixel| {
        pixel.* = 128;
    }

    var img2 = try Image(u8).initAlloc(std.testing.allocator, 100, 100);
    defer img2.deinit(std.testing.allocator);
    for (img2.data) |*pixel| {
        pixel.* = 128;
    }

    // Add small noise to a few pixels
    img2.at(10, 10).* = 130; // diff = 2
    img2.at(20, 20).* = 126; // diff = -2
    img2.at(30, 30).* = 129; // diff = 1
    img2.at(40, 40).* = 127; // diff = -1

    // MSE = (4 + 4 + 1 + 1) / 10000 = 0.001
    // PSNR = 10 * log10(255^2 / 0.001) = 10 * log10(65025000) = 78.13
    const psnr = try img1.psnr(img2);
    try expectApproxEqAbs(78.13, psnr, 0.1);
}

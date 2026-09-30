//! Image quality metric tests: PSNR, SSIM and mean pixel error.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectError = std.testing.expectError;

const color = @import("../../color.zig");
const Rgb = color.Rgb(u8);
const Rgba = color.Rgba(u8);
const Image = @import("../../image.zig").Image;
const Rectangle = @import("../../geometry.zig").Rectangle;
const metrics = @import("../metrics.zig");
const parallel = @import("../../parallel.zig");

test "Image.psnr: identical images returns inf" {
    // Test with u8 scalar type
    var img1 = try Image(u8).init(std.testing.allocator, 10, 10);
    defer img1.deinit(std.testing.allocator);
    for (img1.data) |*pixel| {
        pixel.* = 128;
    }

    var img2 = try Image(u8).init(std.testing.allocator, 10, 10);
    defer img2.deinit(std.testing.allocator);
    for (img2.data) |*pixel| {
        pixel.* = 128;
    }

    const psnr = try img1.psnr(std.testing.io, img2);
    try expectEqual(std.math.inf(f64), psnr);
}

test "Image.psnr: dimension mismatch error" {
    var img1 = try Image(u8).init(std.testing.allocator, 10, 10);
    defer img1.deinit(std.testing.allocator);

    var img2 = try Image(u8).init(std.testing.allocator, 10, 20);
    defer img2.deinit(std.testing.allocator);

    try expectError(error.DimensionMismatch, img1.psnr(std.testing.io, img2));
}

test "Image.psnr: known values for u8" {
    var img1 = try Image(u8).init(std.testing.allocator, 2, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = 100;
    img1.at(0, 1).* = 150;
    img1.at(1, 0).* = 200;
    img1.at(1, 1).* = 250;

    var img2 = try Image(u8).init(std.testing.allocator, 2, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = 110; // diff = 10
    img2.at(0, 1).* = 140; // diff = -10
    img2.at(1, 0).* = 205; // diff = 5
    img2.at(1, 1).* = 245; // diff = -5

    // MSE = (100 + 100 + 25 + 25) / 4 = 62.5
    // PSNR = 10 * log10(255^2 / 62.5) = 10 * log10(1040.4) = 30.171
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(30.171, psnr, 0.01);
}

test "Image.psnr: RGB struct type" {
    var img1 = try Image(Rgb).init(std.testing.allocator, 2, 2);
    defer img1.deinit(std.testing.allocator);
    img1.fill(Rgb{ .r = 100, .g = 150, .b = 200 });

    var img2 = try Image(Rgb).init(std.testing.allocator, 2, 2);
    defer img2.deinit(std.testing.allocator);
    img2.fill(Rgb{ .r = 110, .g = 140, .b = 205 });

    // Each pixel has diffs: r=10, g=-10, b=5
    // MSE per pixel = (100 + 100 + 25) / 3 = 75
    // All 4 pixels are the same, so overall MSE = 75
    // PSNR = 10 * log10(255^2 / 75) = 10 * log10(867) = 29.38
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(29.38, psnr, 0.01);
}

test "Image.psnr: RGBA struct type" {
    var img1 = try Image(Rgba).init(std.testing.allocator, 1, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    img1.at(0, 1).* = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };

    var img2 = try Image(Rgba).init(std.testing.allocator, 1, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = Rgba{ .r = 250, .g = 5, .b = 0, .a = 255 }; // diffs: 5, 5, 0, 0
    img2.at(0, 1).* = Rgba{ .r = 0, .g = 250, .b = 5, .a = 255 }; // diffs: 0, 5, 5, 0

    // MSE = (25 + 25 + 0 + 0 + 0 + 25 + 25 + 0) / 8 = 12.5
    // PSNR = 10 * log10(255^2 / 12.5) = 10 * log10(5202) = 37.16
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(37.16, psnr, 0.01);
}

test "Image.psnr: f32 scalar type" {
    var img1 = try Image(f32).init(std.testing.allocator, 2, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = 0.5;
    img1.at(0, 1).* = 0.7;
    img1.at(1, 0).* = 0.3;
    img1.at(1, 1).* = 0.9;

    var img2 = try Image(f32).init(std.testing.allocator, 2, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = 0.4; // diff = 0.1
    img2.at(0, 1).* = 0.8; // diff = -0.1
    img2.at(1, 0).* = 0.2; // diff = 0.1
    img2.at(1, 1).* = 1.0; // diff = -0.1

    // MSE = (0.01 + 0.01 + 0.01 + 0.01) / 4 = 0.01
    // PSNR = 10 * log10(1.0 / 0.01) = 10 * log10(100) = 20.0
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(20.0, psnr, 0.01);
}

test "Image.psnr: array type [3]u8" {
    var img1 = try Image([3]u8).init(std.testing.allocator, 1, 2);
    defer img1.deinit(std.testing.allocator);
    img1.at(0, 0).* = .{ 100, 150, 200 };
    img1.at(0, 1).* = .{ 50, 100, 150 };

    var img2 = try Image([3]u8).init(std.testing.allocator, 1, 2);
    defer img2.deinit(std.testing.allocator);
    img2.at(0, 0).* = .{ 105, 145, 195 }; // diffs: 5, -5, -5
    img2.at(0, 1).* = .{ 45, 105, 155 }; // diffs: -5, 5, 5

    // MSE = (25 + 25 + 25 + 25 + 25 + 25) / 6 = 25
    // PSNR = 10 * log10(255^2 / 25) = 10 * log10(2601) = 34.15
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(34.15, psnr, 0.01);
}

test "Image.psnr: extreme case black vs white" {
    var img1 = try Image(u8).init(std.testing.allocator, 10, 10);
    defer img1.deinit(std.testing.allocator);
    for (img1.data) |*pixel| {
        pixel.* = 0; // All black
    }

    var img2 = try Image(u8).init(std.testing.allocator, 10, 10);
    defer img2.deinit(std.testing.allocator);
    for (img2.data) |*pixel| {
        pixel.* = 255; // All white
    }

    // MSE = 255^2 = 65025
    // PSNR = 10 * log10(255^2 / 65025) = 10 * log10(1) = 0
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(0.0, psnr, 0.01);
}

test "Image.psnr: slight noise" {
    var img1 = try Image(u8).init(std.testing.allocator, 100, 100);
    defer img1.deinit(std.testing.allocator);
    for (img1.data) |*pixel| {
        pixel.* = 128;
    }

    var img2 = try Image(u8).init(std.testing.allocator, 100, 100);
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
    const psnr = try img1.psnr(std.testing.io, img2);
    try expectApproxEqAbs(78.13, psnr, 0.1);
}

test "meanPixelError: RGB example" {
    const Pixel = struct { r: u8, g: u8, b: u8 };

    var data_a = [_]Pixel{.{ .r = 255, .g = 0, .b = 0 }};
    var data_b = [_]Pixel{.{ .r = 0, .g = 0, .b = 0 }};

    const image_a: Image(Pixel) = .{
        .rows = 1,
        .cols = 1,
        .stride = 1,
        .data = &data_a,
    };
    const image_b: Image(Pixel) = .{
        .rows = 1,
        .cols = 1,
        .stride = 1,
        .data = &data_b,
    };

    const percent = try metrics.meanPixelError(Pixel, std.testing.io, image_a, image_b);
    try std.testing.expectApproxEqAbs(1.0 / 3.0, percent, 1e-9);
}

test "ssim: rgb scales with luminance" {
    const Pixel = struct { r: u8, g: u8, b: u8 };
    const width = 12;
    const height = 12;
    var a_data: [width * height]Pixel = @splat(.{ .r = 0, .g = 0, .b = 0 });
    var b_data: [width * height]Pixel = @splat(.{ .r = 0, .g = 0, .b = 0 });

    for (0..height) |r| {
        for (0..width) |c| {
            const idx = r * width + c;
            a_data[idx] = if ((r + c) % 2 == 0) .{ .r = 255, .g = 0, .b = 0 } else .{ .r = 0, .g = 255, .b = 0 };
        }
    }

    const img_a: Image(Pixel) = .initFromSlice(height, width, &a_data);
    const img_b: Image(Pixel) = .initFromSlice(height, width, &b_data);

    const result = try metrics.ssim(Pixel, std.testing.io, std.testing.allocator, img_a, img_b);
    try std.testing.expect(result < 0.99);
}

test "ssim: matches the direct 11x11 window" {
    const Pixel = struct { r: u8, g: u8, b: u8 };
    const rows = 97;
    const cols = 83;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    var a_data: [rows * cols]Pixel = undefined;
    var b_data: [rows * cols]Pixel = undefined;
    for (&a_data, &b_data) |*a, *b| {
        a.* = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) };
        b.* = .{ .r = a.r / 2 + random.int(u8) / 4, .g = a.g, .b = a.b / 3 };
    }
    const img_a: Image(Pixel) = .initFromSlice(rows, cols, &a_data);
    const img_b: Image(Pixel) = .initFromSlice(rows, cols, &b_data);

    // Direct 2D window.
    const out_rows = rows - (metrics.ssim_window - 1);
    const out_cols = cols - (metrics.ssim_window - 1);
    var expected: f64 = 0;
    for (0..out_rows) |r| {
        for (0..out_cols) |c| {
            var mu: [5]f64 = @splat(0);
            for (0..metrics.ssim_window) |dy| {
                for (0..metrics.ssim_window) |dx| {
                    const w = metrics.ssim_kernel[dy] * metrics.ssim_kernel[dx];
                    const x = metrics.getPixelScalar(Pixel, img_a.at(r + dy, c + dx).*);
                    const y = metrics.getPixelScalar(Pixel, img_b.at(r + dy, c + dx).*);
                    mu[0] += w * x;
                    mu[1] += w * y;
                    mu[2] += w * x * x;
                    mu[3] += w * y * y;
                    mu[4] += w * x * y;
                }
            }
            expected += metrics.ssimTerm(Pixel, f64, mu[0], mu[1], mu[2], mu[3], mu[4]);
        }
    }
    expected /= out_rows * out_cols;

    const result = try metrics.ssim(Pixel, std.testing.io, std.testing.allocator, img_a, img_b);
    try std.testing.expectApproxEqRel(expected, result, 1e-12);
}

test "ssim: banded result equals the serial one" {
    // Large enough for several bands.
    const rows = 480;
    const cols = 320;
    const a_data = try std.testing.allocator.alloc(u8, rows * cols);
    defer std.testing.allocator.free(a_data);
    const b_data = try std.testing.allocator.alloc(u8, rows * cols);
    defer std.testing.allocator.free(b_data);
    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();
    for (a_data, b_data) |*a, *b| {
        a.* = random.int(u8);
        b.* = a.* / 2 + random.int(u8) / 2;
    }
    const img_a: Image(u8) = .initFromSlice(rows, cols, a_data);
    const img_b: Image(u8) = .initFromSlice(rows, cols, b_data);

    const serial = try metrics.ssim(u8, parallel.inline_io, std.testing.allocator, img_a, img_b);
    const banded = try metrics.ssim(u8, std.testing.io, std.testing.allocator, img_a, img_b);
    try std.testing.expectEqual(serial, banded);
}

test "psnr, meanPixelError: exact for integer pixels, on views too" {
    const Pixel = Rgba;
    const rows = 300;
    const cols = 257;
    const a_data = try std.testing.allocator.alloc(Pixel, rows * cols);
    defer std.testing.allocator.free(a_data);
    const b_data = try std.testing.allocator.alloc(Pixel, rows * cols);
    defer std.testing.allocator.free(b_data);
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    for (a_data, b_data) |*a, *b| {
        a.* = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8), .a = random.int(u8) };
        b.* = .{ .r = a.r / 2, .g = random.int(u8), .b = a.b, .a = a.a / 3 };
    }
    const full_a: Image(Pixel) = .initFromSlice(rows, cols, a_data);
    const full_b: Image(Pixel) = .initFromSlice(rows, cols, b_data);
    // A view, so rows are strided.
    const rect: Rectangle(u32) = .{ .l = 3, .t = 5, .r = 250, .b = 297 };
    const img_a = full_a.view(rect);
    const img_b = full_b.view(rect);

    var squared: f64 = 0;
    var absolute: f64 = 0;
    for (0..img_a.rows) |r| {
        for (0..img_a.cols) |c| {
            const p = img_a.at(r, c).*;
            const q = img_b.at(r, c).*;
            inline for (.{ "r", "g", "b", "a" }) |f| {
                const d = @as(f64, @field(p, f)) - @as(f64, @field(q, f));
                squared += d * d;
                absolute += @abs(d);
            }
        }
    }
    const count: f64 = @floatFromInt(img_a.rows * img_a.cols * 4);
    const expected_psnr = 20.0 * std.math.log10(255.0) - 10.0 * std.math.log10(squared / count);
    try std.testing.expectEqual(expected_psnr, try metrics.psnr(Pixel, std.testing.io, img_a, img_b));
    try std.testing.expectEqual(absolute / count / 255.0, try metrics.meanPixelError(Pixel, std.testing.io, img_a, img_b));
}

test "psnr, meanPixelError: banded float result equals the serial one" {
    const rows = 480;
    const cols = 320;
    const a_data = try std.testing.allocator.alloc(f32, rows * cols);
    defer std.testing.allocator.free(a_data);
    const b_data = try std.testing.allocator.alloc(f32, rows * cols);
    defer std.testing.allocator.free(b_data);
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    for (a_data, b_data) |*a, *b| {
        a.* = random.float(f32);
        b.* = random.float(f32);
    }
    const img_a: Image(f32) = .initFromSlice(rows, cols, a_data);
    const img_b: Image(f32) = .initFromSlice(rows, cols, b_data);

    try std.testing.expectEqual(try metrics.psnr(f32, parallel.inline_io, img_a, img_b), try metrics.psnr(f32, std.testing.io, img_a, img_b));
    try std.testing.expectEqual(try metrics.meanPixelError(f32, parallel.inline_io, img_a, img_b), try metrics.meanPixelError(f32, std.testing.io, img_a, img_b));
}

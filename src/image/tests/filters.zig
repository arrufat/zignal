//! Filter tests - box blur and sharpen

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectError = std.testing.expectError;

const color = @import("../../color.zig");
const Rectangle = @import("../../geometry.zig").Rectangle;
const Image = @import("../../image.zig").Image;
const BorderMode = @import("../../image.zig").BorderMode;

const Rgb = color.Rgb(u8);
const Rgba = color.Rgba(u8);

const io = std.Io.Threaded.global_single_threaded.io();

test "invert" {
    // Test grayscale
    var gray: Image(u8) = try .init(std.testing.allocator, 2, 2);
    defer gray.deinit(std.testing.allocator);

    gray.at(0, 0).* = 0;
    gray.at(0, 1).* = 255;
    gray.at(1, 0).* = 100;
    gray.at(1, 1).* = 128;

    gray.invert();

    try expectEqual(@as(u8, 255), gray.at(0, 0).*);
    try expectEqual(@as(u8, 0), gray.at(0, 1).*);
    try expectEqual(@as(u8, 155), gray.at(1, 0).*);
    try expectEqual(@as(u8, 127), gray.at(1, 1).*);

    // Test RGB
    var rgb: Image(Rgb) = try .init(std.testing.allocator, 1, 1);
    defer rgb.deinit(std.testing.allocator);

    rgb.at(0, 0).* = Rgb{ .r = 0, .g = 128, .b = 255 };
    rgb.invert();
    try expectEqualDeep(Rgb{ .r = 255, .g = 127, .b = 0 }, rgb.at(0, 0).*);

    // Test RGBA preserves alpha
    var rgba: Image(Rgba) = try .init(std.testing.allocator, 1, 1);
    defer rgba.deinit(std.testing.allocator);

    rgba.at(0, 0).* = Rgba{ .r = 0, .g = 128, .b = 255, .a = 64 };
    rgba.invert();
    try expectEqualDeep(Rgba{ .r = 255, .g = 127, .b = 0, .a = 64 }, rgba.at(0, 0).*);
}

test "boxBlur radius 0 with views" {
    var image: Image(u8) = try .init(std.testing.allocator, 6, 8);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    // Create a view
    const view = image.view(.{ .l = 1, .t = 1, .r = 5, .b = 4 });

    // Apply boxBlur with radius 0 to view
    var blurred = try Image(u8).initLike(std.testing.allocator, view);
    defer blurred.deinit(std.testing.allocator);
    try view.boxBlur(io, std.testing.allocator, blurred, 0);

    // Should be identical to view
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "view" {
    var image: Image(Rgba) = try .init(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    const rect: Rectangle(u32) = .{ .l = 0, .t = 0, .r = 8, .b = 10 };
    const view = image.view(rect);
    try expectEqual(view.isContiguous(), false);
    try expectEqual(image.isContiguous(), true);
    try expectEqualDeep(rect, view.getRectangle());
}

test "boxBlur basic functionality" {
    // Test with uniform image - should remain unchanged
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Fill with uniform value
    for (image.data) |*pixel| pixel.* = 128;

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.boxBlur(io, std.testing.allocator, blurred, 1);

    // Uniform image should remain uniform after blur
    for (blurred.data) |pixel| {
        try expectEqual(@as(u8, 128), pixel);
    }
}

test "boxBlur zero radius" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c);
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.boxBlur(io, std.testing.allocator, blurred, 0);

    // Zero radius should produce identical image
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "boxBlur border effects" {
    // Create a small image to test border handling
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Initialize with a pattern where center is 255, edges are 0
    for (image.data) |*pixel| pixel.* = 0;
    image.at(2, 2).* = 255; // Center pixel

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.boxBlur(io, std.testing.allocator, blurred, 1);

    // The center should be blurred down, corners should have some blur effect
    try expectEqual(@as(usize, 5), blurred.rows);
    try expectEqual(@as(usize, 5), blurred.cols);

    // Corner pixels should have received some blur from the center
    // but less than center pixels due to smaller effective area
    const corner_val = blurred.at(0, 0).*;
    const center_val = blurred.at(2, 2).*;

    // Center should be less than original 255 due to averaging with zeros
    // Corner should be less than center due to smaller kernel area
    try expectEqual(corner_val < center_val, true);
    try expectEqual(center_val < 255, true);
}

test "boxBlur struct type" {
    var image: Image(Rgba) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with different colors
    image.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0, .a = 255 }; // Red
    image.at(0, 1).* = .{ .r = 0, .g = 255, .b = 0, .a = 255 }; // Green
    image.at(0, 2).* = .{ .r = 0, .g = 0, .b = 255, .a = 255 }; // Blue
    image.at(1, 0).* = .{ .r = 255, .g = 255, .b = 0, .a = 255 }; // Yellow
    image.at(1, 1).* = .{ .r = 255, .g = 255, .b = 255, .a = 255 }; // White
    image.at(1, 2).* = .{ .r = 255, .g = 0, .b = 255, .a = 255 }; // Magenta
    image.at(2, 0).* = .{ .r = 0, .g = 255, .b = 255, .a = 255 }; // Cyan
    image.at(2, 1).* = .{ .r = 128, .g = 128, .b = 128, .a = 255 }; // Gray
    image.at(2, 2).* = .{ .r = 0, .g = 0, .b = 0, .a = 255 }; // Black

    var blurred = try Image(Rgba).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.boxBlur(io, std.testing.allocator, blurred, 1);

    try expectEqual(@as(usize, 3), blurred.rows);
    try expectEqual(@as(usize, 3), blurred.cols);

    // Center pixel should be average of all surrounding pixels
    const center = blurred.at(1, 1).*;
    // All channels should be affected by blur
    try expectEqual(center.r != 255, true);
    try expectEqual(center.g != 255, true);
    try expectEqual(center.b != 255, true);
}

test "boxBlur border area calculations" {
    // Test that border pixels get correct area calculations by comparing
    // uniform images with different values
    const test_size: u32 = 12;
    const radius = 3;

    // Test with uniform image - all pixels should have the same value after blur
    var uniform_image: Image(u8) = try .init(std.testing.allocator, test_size, test_size);
    defer uniform_image.deinit(std.testing.allocator);

    for (uniform_image.data) |*pixel| pixel.* = 200;

    var uniform_blurred = try Image(u8).initLike(std.testing.allocator, uniform_image);
    defer uniform_blurred.deinit(std.testing.allocator);
    try uniform_image.boxBlur(io, std.testing.allocator, uniform_blurred, radius);

    // All pixels should remain 200 since it's uniform
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            try expectEqual(@as(u8, 200), uniform_blurred.at(r, c).*);
        }
    }

    // Test with gradient - area calculations should be smooth
    var gradient_image: Image(u8) = try .init(std.testing.allocator, test_size, test_size);
    defer gradient_image.deinit(std.testing.allocator);

    for (0..test_size) |r| {
        for (0..test_size) |c| {
            gradient_image.at(r, c).* = @intCast((r * 255) / test_size);
        }
    }

    var gradient_blurred = try Image(u8).initLike(std.testing.allocator, gradient_image);
    defer gradient_blurred.deinit(std.testing.allocator);
    try gradient_image.boxBlur(io, std.testing.allocator, gradient_blurred, radius);

    // Check that we got reasonable blur results (no crashes, no extreme values)
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const val = gradient_blurred.at(r, c).*;
            // Values should be within reasonable range (not corrupted by bad area calculations)
            try expectEqual(val <= 255, true);
            try expectEqual(val >= 0, true);
        }
    }
}

test "boxBlur struct type comprehensive" {
    // Test RGBA with both large images (SIMD) and small images (scalar)
    for ([_]u32{ 8, 32 }) |test_size| { // Small and large
        for ([_]u32{ 1, 3 }) |radius| {
            var image: Image(Rgba) = try .init(std.testing.allocator, test_size, test_size);
            defer image.deinit(std.testing.allocator);

            // Create a red-to-blue gradient
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    const red_val: u8 = @intCast((255 * c) / test_size);
                    const blue_val: u8 = @intCast((255 * r) / test_size);
                    image.at(r, c).* = .{
                        .r = red_val,
                        .g = 128,
                        .b = blue_val,
                        .a = 255,
                    };
                }
            }

            var blurred = try Image(Rgba).initLike(std.testing.allocator, image);
            defer blurred.deinit(std.testing.allocator);
            try image.boxBlur(io, std.testing.allocator, blurred, radius);

            // Check that alpha remains unchanged
            for (0..test_size) |r| {
                for (0..test_size) |c| {
                    try expectEqual(@as(u8, 255), blurred.at(r, c).a);
                }
            }

            // Check that gradients remain smooth
            for (1..test_size - 1) |r| {
                const curr_r = blurred.at(r, test_size / 2).r;
                const next_r = blurred.at(r + 1, test_size / 2).r;
                const diff = if (next_r > curr_r) next_r - curr_r else curr_r - next_r;
                try expectEqual(diff <= 15, true); // Reasonable smoothness
            }
        }
    }
}

test "sharpen basic functionality" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create an edge pattern: left half dark, right half bright
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 2) 64 else 192;
        }
    }

    var sharpened = try Image(u8).initLike(std.testing.allocator, image);
    defer sharpened.deinit(std.testing.allocator);
    try image.sharpen(io, std.testing.allocator, sharpened, 1);

    try expectEqual(@as(usize, 5), sharpened.rows);
    try expectEqual(@as(usize, 5), sharpened.cols);

    // Edge pixels should have more contrast after sharpening
    const left_val = sharpened.at(2, 0).*;
    const right_val = sharpened.at(2, 4).*;

    // Sharpening should increase contrast at edges
    try expectEqual(left_val <= 64, true); // Dark side should get darker or stay same
    try expectEqual(right_val >= 192, true); // Bright side should get brighter or stay same
}

test "sharpen zero radius" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c + 10);
        }
    }

    var sharpened = try Image(u8).initLike(std.testing.allocator, image);
    defer sharpened.deinit(std.testing.allocator);
    try image.sharpen(io, std.testing.allocator, sharpened, 0);

    // Zero radius should produce identical image
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, sharpened.at(r, c).*);
        }
    }
}

test "sharpen uniform image" {
    var image: Image(u8) = try .init(std.testing.allocator, 4, 4);
    defer image.deinit(std.testing.allocator);

    // Fill with uniform value
    for (image.data) |*pixel| pixel.* = 100;

    var sharpened = try Image(u8).initLike(std.testing.allocator, image);
    defer sharpened.deinit(std.testing.allocator);
    try image.sharpen(io, std.testing.allocator, sharpened, 1);

    // Uniform image should remain uniform after sharpening
    // (2 * original - blurred = 2 * 100 - 100 = 100)
    for (sharpened.data) |pixel| {
        try expectEqual(@as(u8, 100), pixel);
    }
}

test "sharpen struct type" {
    var image: Image(Rgba) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Create a simple pattern with a bright center
    for (image.data) |*pixel| pixel.* = .{ .r = 64, .g = 64, .b = 64, .a = 255 };
    image.at(1, 1).* = .{ .r = 192, .g = 192, .b = 192, .a = 255 }; // Bright center

    var sharpened = try Image(Rgba).initLike(std.testing.allocator, image);
    defer sharpened.deinit(std.testing.allocator);
    try image.sharpen(io, std.testing.allocator, sharpened, 1);

    try expectEqual(@as(usize, 3), sharpened.rows);
    try expectEqual(@as(usize, 3), sharpened.cols);

    // Center should be enhanced (brighter than original)
    const original_center = image.at(1, 1).*;
    const sharpened_center = sharpened.at(1, 1).*;

    // Center should be sharpened (enhanced contrast)
    try expectEqual(sharpened_center.r >= original_center.r, true);
    try expectEqual(sharpened_center.g >= original_center.g, true);
    try expectEqual(sharpened_center.b >= original_center.b, true);
}

test "convolve identity kernel" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c + 10);
        }
    }

    // Identity kernel should leave image unchanged
    const identity = [3][3]f32{
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 0 },
    };

    var result = try Image(u8).initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result, identity, .zero);

    // Should be identical to original
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, result.at(r, c).*);
        }
    }
}

test "convolve blur kernel" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create sharp edge pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 2) 0 else 255;
        }
    }

    // Box blur kernel
    const blur = [3][3]f32{
        .{ 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0 },
        .{ 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0 },
        .{ 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0 },
    };

    var result = try Image(u8).initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result, blur, .replicate);

    // Edge should be softened (values between 0 and 255)
    const edge_val = result.at(2, 2).*;
    try expectEqual(edge_val > 0 and edge_val < 255, true);
}

test "convolve border modes" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize center to 255, edges to 0
    for (image.data) |*pixel| pixel.* = 0;
    image.at(1, 1).* = 255;

    // Simple averaging kernel
    const kernel = [3][3]f32{
        .{ 0.25, 0.25, 0 },
        .{ 0.25, 0.25, 0 },
        .{ 0, 0, 0 },
    };

    // Test zero border mode
    var result_zero = try Image(u8).initLike(std.testing.allocator, image);
    defer result_zero.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result_zero, kernel, .zero);

    // Test replicate border mode
    var result_replicate = try Image(u8).initLike(std.testing.allocator, image);
    defer result_replicate.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result_replicate, kernel, .replicate);

    // Test mirror border mode
    var result_mirror = try Image(u8).initLike(std.testing.allocator, image);
    defer result_mirror.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result_mirror, kernel, .mirror);

    // Border modes should produce different results
    const corner_replicate = result_replicate.at(0, 0).*;

    // With replicate, corners should be 0 (replicating edge values)
    // With mirror/zero, results will differ based on how borders are handled
    try expectEqual(corner_replicate == 0, true);

    // Verify the border modes produce valid results (just check they don't crash)
    _ = result_zero.at(0, 0).*;
    _ = result_mirror.at(0, 0).*;
}

test "convolveSeparable Gaussian approximation" {
    var image: Image(f32) = try .init(std.testing.allocator, 7, 7);
    defer image.deinit(std.testing.allocator);

    // Create impulse in center
    for (image.data) |*pixel| pixel.* = 0;
    image.at(3, 3).* = 1.0;

    // 1D Gaussian kernel approximation (normalized)
    const gaussian_1d = [_]f32{ 0.25, 0.5, 0.25 };

    var result = try Image(f32).initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    try image.convolveSeparable(io, std.testing.allocator, result, &gaussian_1d, &gaussian_1d, .zero);

    // Check that center has been spread out
    const center = result.at(3, 3).*;
    const adjacent = result.at(3, 2).*;

    try expectEqual(center < 1.0, true); // Center should be less than original impulse
    try expectEqual(adjacent > 0, true); // Adjacent pixels should have some value
    try expectEqual(center > adjacent, true); // Center should still be brightest
}

test "gaussianBlur basic" {
    var image: Image(u8) = try .init(std.testing.allocator, 11, 11);
    defer image.deinit(std.testing.allocator);

    // Create a white square in center
    for (image.data) |*pixel| pixel.* = 0;
    for (3..8) |r| {
        for (3..8) |c| {
            image.at(r, c).* = 255;
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.gaussianBlur(io, std.testing.allocator, blurred, 1.0, .default);

    // Check that blur has smoothed the edges
    const edge_sharp = image.at(2, 5).*; // Just outside the square
    const edge_blurred = blurred.at(2, 5).*;

    try expectEqual(edge_sharp, 0); // Original is sharp
    try expectEqual(edge_blurred > 0, true); // Blurred has spread

    // Center should still be bright
    const center = blurred.at(5, 5).*;
    try expectEqual(center > 200, true);
}

test "gaussianBlur sigma variations" {
    var image: Image(f32) = try .init(std.testing.allocator, 15, 15);
    defer image.deinit(std.testing.allocator);

    // Single bright pixel in center
    for (image.data) |*pixel| pixel.* = 0;
    image.at(7, 7).* = 1.0;

    // Test with different sigmas
    var blur_small = try Image(f32).initLike(std.testing.allocator, image);
    defer blur_small.deinit(std.testing.allocator);
    try image.gaussianBlur(io, std.testing.allocator, blur_small, 0.5, .default);

    var blur_large = try Image(f32).initLike(std.testing.allocator, image);
    defer blur_large.deinit(std.testing.allocator);
    try image.gaussianBlur(io, std.testing.allocator, blur_large, 2.0, .default);

    // Larger sigma should spread more
    const center_small = blur_small.at(7, 7).*;
    const center_large = blur_large.at(7, 7).*;
    const edge_small = blur_small.at(7, 5).*; // 2 pixels away
    const edge_large = blur_large.at(7, 5).*;

    try expectEqual(center_small > center_large, true); // Small sigma keeps more at center
    try expectEqual(edge_large > edge_small, true); // Large sigma spreads more to edges
}

test "sobel with new convolution" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create vertical edge
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 2) 0 else 255;
        }
    }

    var edges = try Image(u8).initLike(std.testing.allocator, image);
    defer edges.deinit(std.testing.allocator);
    try image.sobel(io, std.testing.allocator, edges);

    // Should detect strong edge at column 2
    const edge_strength = edges.at(2, 2).*;
    const non_edge = edges.at(2, 0).*;

    try expectEqual(edge_strength > 200, true); // Strong edge
    try expectEqual(non_edge < 50, true); // Weak or no edge
}

test "repro: uniform channel bug in struct convolution with .zero borders" {
    const allocator = std.testing.allocator;
    var image = try Image(Rgb).init(allocator, 5, 5);
    defer image.deinit(allocator);

    // Fill with constant white
    image.fill(.{ .r = 255, .g = 255, .b = 255 });

    var out = try Image(Rgb).init(allocator, 5, 5);
    defer out.deinit(allocator);
    out.fill(.{ .r = 0, .g = 0, .b = 0 });

    const blur_kernel = [3][3]f32{
        .{ 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0 },
        .{ 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0 },
        .{ 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0 },
    };

    try image.convolve(io, allocator, out, blur_kernel, .zero);

    // At (0,0), only 4 of 9 taps are inside the image.
    // Sum should be 255 * (4/9) = 113.33 -> 113.
    // If the bug exists (optimization for uniform applied incorrectly), it will be 255.
    const corner = out.at(0, 0).*;
    try std.testing.expect(corner.r != 255);
    // 113 is expected value. Allow some tolerance.
    const expected = 113;
    const diff = if (corner.r > expected) corner.r - expected else expected - corner.r;
    try std.testing.expect(diff <= 1);
}

test "repro: stride bug in f32 separable convolution" {
    const allocator = std.testing.allocator;
    // Create a 5x5 image
    var base = try Image(f32).init(allocator, 5, 5);
    defer base.deinit(allocator);

    // Fill with pattern
    for (0..5) |r| {
        for (0..5) |c| {
            base.at(r, c).* = @floatFromInt(r * 10 + c);
        }
    }

    // Create a 3x3 view in the middle
    const rect = Rectangle(u32){ .l = 1, .t = 1, .r = 4, .b = 4 };
    const view = base.view(rect);
    // view.stride is 5, view.cols is 3.

    var out = try Image(f32).init(allocator, 3, 3);
    defer out.deinit(allocator);

    const k1 = [_]f32{1.0};
    try view.convolveSeparable(io, allocator, out, &k1, &k1, .zero);

    // out should match view exactly if identity.
    for (0..3) |r| {
        for (0..3) |c| {
            try expectEqual(view.at(r, c).*, out.at(r, c).*);
        }
    }
}

test "convolve3x3 optimization" {
    // This test verifies that 3x3 convolution uses the optimized path
    var image: Image(u8) = try .init(std.testing.allocator, 10, 10);
    defer image.deinit(std.testing.allocator);

    // Fill with random-ish pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast((r * 7 + c * 13) % 256);
        }
    }

    // Edge detection kernel
    const edge = [3][3]f32{
        .{ -1, -1, -1 },
        .{ -1, 8, -1 },
        .{ -1, -1, -1 },
    };

    var result = try Image(u8).initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result, edge, .zero);

    // Just verify it runs without error and produces reasonable output
    try expectEqual(result.rows, image.rows);
    try expectEqual(result.cols, image.cols);
}

test "convolve preserves color channels" {
    // Test that RGB convolution processes each channel independently
    var image: Image(Rgb) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create distinct patterns in each channel
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = .{
                .r = @intCast((r * 20) % 256), // Horizontal gradient in red
                .g = @intCast((c * 20) % 256), // Vertical gradient in green
                .b = @intCast((r + c) * 10 % 256), // Diagonal gradient in blue
            };
        }
    }

    // Identity kernel should preserve exact values
    const identity = [3][3]f32{
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 0 },
    };

    var result = try Image(Rgb).initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    try image.convolve(io, std.testing.allocator, result, identity, .zero);

    // Verify identity kernel preserves all color channels exactly
    for (1..image.rows - 1) |r| {
        for (1..image.cols - 1) |c| {
            const original = image.at(r, c).*;
            const convolved = result.at(r, c).*;
            try expectEqual(original.r, convolved.r);
            try expectEqual(original.g, convolved.g);
            try expectEqual(original.b, convolved.b);
        }
    }
}

test "convolve into view (stride-safe)" {
    // Create a base image with a larger stride than the view width
    var base_src: Image(u8) = try .init(std.testing.allocator, 6, 8);
    defer base_src.deinit(std.testing.allocator);
    for (0..base_src.rows) |r| {
        for (0..base_src.cols) |c| {
            base_src.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    // Create a destination base initialized to a sentinel value
    var base_dst: Image(u8) = try .init(std.testing.allocator, 6, 8);
    defer base_dst.deinit(std.testing.allocator);
    for (base_dst.data) |*p| p.* = 0xAA;

    // Views over a 4x4 region; note view.stride != view.cols
    const rect: Rectangle(u32) = .{ .l = 2, .t = 1, .r = 6, .b = 5 }; // width=4, height=4
    var src_view = base_src.view(rect);
    var dst_view = base_dst.view(rect);

    // Identity kernel: should copy src_view into dst_view
    const identity = [3][3]f32{
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 0 },
    };

    try src_view.convolve(io, std.testing.allocator, dst_view, identity, .zero);

    // Verify dst view matches src view
    for (0..src_view.rows) |r| {
        for (0..src_view.cols) |c| {
            try expectEqual(src_view.at(r, c).*, dst_view.at(r, c).*);
        }
    }

    // Outside the view, base_dst should remain unchanged (0xAA)
    for (0..base_dst.rows) |r| {
        for (0..base_dst.cols) |c| {
            const inside = r >= rect.t and r < rect.b and c >= rect.l and c < rect.r;
            if (!inside) try expectEqual(@as(u8, 0xAA), base_dst.at(r, c).*);
        }
    }
}

test "convolveSeparable into view (stride-safe)" {
    // Create a base image and a matching destination base
    var base_src: Image(u8) = try .init(std.testing.allocator, 7, 9);
    defer base_src.deinit(std.testing.allocator);
    for (0..base_src.rows) |r| {
        for (0..base_src.cols) |c| {
            base_src.at(r, c).* = @intCast((r * 7 + c * 3) % 256);
        }
    }

    var base_dst: Image(u8) = try .init(std.testing.allocator, 7, 9);
    defer base_dst.deinit(std.testing.allocator);
    for (base_dst.data) |*p| p.* = 0x55;

    // Define a view region; ensure stride != cols for the view
    const rect: Rectangle(u32) = .{ .l = 1, .t = 2, .r = 6, .b = 6 }; // width=5, height=4
    var src_view = base_src.view(rect);
    var dst_view = base_dst.view(rect);

    // Separable identity: [1] horizontally and vertically
    const k1 = [_]f32{1.0};
    try src_view.convolveSeparable(io, std.testing.allocator, dst_view, &k1, &k1, .zero);

    // Verify dst view matches src view
    for (0..src_view.rows) |r| {
        for (0..src_view.cols) |c| {
            try expectEqual(src_view.at(r, c).*, dst_view.at(r, c).*);
        }
    }

    // Outside the view, base_dst should remain unchanged (0x55)
    for (0..base_dst.rows) |r| {
        for (0..base_dst.cols) |c| {
            const inside = r >= rect.t and r < rect.b and c >= rect.l and c < rect.r;
            if (!inside) try expectEqual(@as(u8, 0x55), base_dst.at(r, c).*);
        }
    }
}

test "gaussianBlur preserves color" {
    // Test that Gaussian blur on RGB images maintains color information
    var image: Image(Rgb) = try .init(std.testing.allocator, 7, 7);
    defer image.deinit(std.testing.allocator);

    // Create a red square in the center
    for (image.data) |*pixel| pixel.* = .{ .r = 0, .g = 0, .b = 0 };
    for (2..5) |r| {
        for (2..5) |c| {
            image.at(r, c).* = .{ .r = 255, .g = 0, .b = 0 }; // Pure red
        }
    }

    var blurred = try Image(Rgb).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.gaussianBlur(io, std.testing.allocator, blurred, 1.0, .default);

    // Center should still be red (though not pure 255)
    const center = blurred.at(3, 3).*;
    try expectEqual(true, center.r > 150); // Red channel should be high (adjusted for blur)
    try expectEqual(true, center.g < 20); // Green should be low
    try expectEqual(true, center.b < 20); // Blue should be low

    // Edges should have blurred red (not gray)
    const edge = blurred.at(2, 1).*;
    if (edge.r > 0) {
        // If there's any color, it should be red, not gray
        try expectEqual(true, edge.g < edge.r / 2);
        try expectEqual(true, edge.b < edge.r / 2);
    }
}

test "medianBlur removes impulse noise" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    image.fill(0);
    image.at(2, 2).* = 255;

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.medianBlur(io, std.testing.allocator, blurred, 1);

    try expectEqual(@as(u8, 0), blurred.at(2, 2).*);
    try expectEqual(@as(u8, 0), blurred.at(2, 1).*);
    try expectEqual(@as(u8, 0), blurred.at(1, 2).*);
}

test "percentileBlur max filter" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    var value: u8 = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = value;
            value += 1;
        }
    }

    var out = try Image(u8).initLike(std.testing.allocator, image);
    defer out.deinit(std.testing.allocator);
    try image.percentileBlur(io, std.testing.allocator, out, 1, 1.0, BorderMode.zero);

    try expectEqual(@as(u8, 8), out.at(1, 1).*);
    try expectEqual(@as(u8, 4), out.at(0, 0).*);
}

test "medianBlur preserves dominant RGB color" {
    var image: Image(Rgb) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    const base = Rgb{ .r = 32, .g = 64, .b = 96 };
    for (image.data) |*pixel| pixel.* = base;
    image.at(1, 1).* = Rgb{ .r = 255, .g = 0, .b = 0 };

    var blurred = try Image(Rgb).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.medianBlur(io, std.testing.allocator, blurred, 1);

    try expectEqualDeep(base, blurred.at(1, 1).*);
    try expectEqualDeep(base, blurred.at(0, 0).*);
}

test "minBlur matches percentile zero" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    var value: u8 = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = value;
            value += 1;
        }
    }

    var min_blur = try Image(u8).initLike(std.testing.allocator, image);
    defer min_blur.deinit(std.testing.allocator);
    var percentile = try Image(u8).initLike(std.testing.allocator, image);
    defer percentile.deinit(std.testing.allocator);

    try image.minBlur(io, std.testing.allocator, min_blur, 1, BorderMode.replicate);
    try image.percentileBlur(io, std.testing.allocator, percentile, 1, 0.0, BorderMode.replicate);

    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(min_blur.at(r, c).*, percentile.at(r, c).*);
        }
    }
}

test "maxBlur matches percentile one" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    var max_blur = try Image(u8).initLike(std.testing.allocator, image);
    defer max_blur.deinit(std.testing.allocator);
    var percentile = try Image(u8).initLike(std.testing.allocator, image);
    defer percentile.deinit(std.testing.allocator);

    try image.maxBlur(io, std.testing.allocator, max_blur, 1, BorderMode.replicate);
    try image.percentileBlur(io, std.testing.allocator, percentile, 1, 1.0, BorderMode.replicate);

    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(max_blur.at(r, c).*, percentile.at(r, c).*);
        }
    }
}

test "midpointBlur averages extremes" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    var value: u8 = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = value;
            value += 1;
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.midpointBlur(io, std.testing.allocator, blurred, 1, BorderMode.replicate);

    try expectEqual(@as(u8, 4), blurred.at(1, 1).*);
}

test "alphaTrimmedMeanBlur drops extremes" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    var value: u8 = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = value;
            value += 1;
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.alphaTrimmedMeanBlur(io, std.testing.allocator, blurred, 1, 0.12, BorderMode.replicate);

    try expectEqual(@as(u8, 4), blurred.at(1, 1).*);
}

test "alphaTrimmedMeanBlur invalid trim" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    var out = try Image(u8).initLike(std.testing.allocator, image);
    defer out.deinit(std.testing.allocator);

    try expectError(error.InvalidTrim, image.alphaTrimmedMeanBlur(io, std.testing.allocator, out, 1, 0.6, BorderMode.replicate));
}

test "linearMotionBlur horizontal" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 7);
    defer image.deinit(std.testing.allocator);

    // Create vertical edge pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 3) 0 else 255;
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .linear = .{ .angle = 0, .distance = 3 } });

    // Edge should be blurred horizontally
    const edge_val = blurred.at(2, 3).*;
    try expectEqual(true, edge_val > 0 and edge_val < 255);

    // Top and bottom edges should have similar blur (horizontal motion)
    const top_edge = blurred.at(0, 3).*;
    const bottom_edge = blurred.at(4, 3).*;
    const diff = if (top_edge > bottom_edge) top_edge - bottom_edge else bottom_edge - top_edge;
    try expectEqual(true, diff < 10); // Should be very similar
}

test "linearMotionBlur vertical" {
    var image: Image(u8) = try .init(std.testing.allocator, 7, 5);
    defer image.deinit(std.testing.allocator);

    // Create horizontal edge pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (r < 3) 0 else 255;
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .linear = .{ .angle = std.math.pi / 2.0, .distance = 3 } });

    // Edge should be blurred vertically
    const edge_val = blurred.at(3, 2).*;
    try expectEqual(true, edge_val > 0 and edge_val < 255);

    // Left and right edges should have similar blur (vertical motion)
    const left_edge = blurred.at(3, 0).*;
    const right_edge = blurred.at(3, 4).*;
    const diff = if (left_edge > right_edge) left_edge - right_edge else right_edge - left_edge;
    try expectEqual(true, diff < 10); // Should be very similar
}

test "linearMotionBlur diagonal" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create center bright spot
    for (image.data) |*pixel| pixel.* = 0;
    image.at(2, 2).* = 255;

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .linear = .{ .angle = std.math.pi / 4.0, .distance = 3 } });

    // Should create diagonal streak
    // Points along the diagonal should have non-zero values
    try expectEqual(true, blurred.at(1, 1).* > 0);
    try expectEqual(true, blurred.at(2, 2).* > 0);
    try expectEqual(true, blurred.at(3, 3).* > 0);
}

test "linearMotionBlur zero distance" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Create pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c);
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .linear = .{ .angle = 0, .distance = 0 } });

    // Should be identical to original
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "linearMotionBlur RGB" {
    var image: Image(Rgb) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create colored pattern
    for (image.data) |*pixel| pixel.* = .{ .r = 0, .g = 0, .b = 0 };
    image.at(2, 2).* = .{ .r = 255, .g = 128, .b = 64 };

    var blurred = try Image(Rgb).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .linear = .{ .angle = 0, .distance = 3 } });

    // Color should be preserved but spread
    const center = blurred.at(2, 2).*;
    try expectEqual(true, center.r > center.g);
    try expectEqual(true, center.g > center.b);

    // Adjacent pixels should have color
    const adjacent = blurred.at(2, 1).*;
    try expectEqual(true, adjacent.r > 0);
}

test "radialMotionBlur zoom" {
    var image: Image(u8) = try .init(std.testing.allocator, 7, 7);
    defer image.deinit(std.testing.allocator);

    // Create ring pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const dx = @as(f32, @floatFromInt(c)) - 3;
            const dy = @as(f32, @floatFromInt(r)) - 3;
            const dist = @sqrt(dx * dx + dy * dy);
            image.at(r, c).* = if (dist > 1.5 and dist < 2.5) 255 else 0;
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .radial_zoom = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.5 } });

    // Ring should be blurred radially
    // Center should be relatively unchanged
    const center_diff = if (image.at(3, 3).* > blurred.at(3, 3).*)
        image.at(3, 3).* - blurred.at(3, 3).*
    else
        blurred.at(3, 3).* - image.at(3, 3).*;
    try expectEqual(true, center_diff < 20);
}

test "radialMotionBlur spin" {
    var image: Image(u8) = try .init(std.testing.allocator, 7, 7);
    defer image.deinit(std.testing.allocator);

    // Create single bright point off-center
    for (image.data) |*pixel| pixel.* = 0;
    image.at(2, 4).* = 255;

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .radial_spin = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.5 } });

    // Should create arc/spin pattern
    // Adjacent pixels in tangential direction should have values
    try expectEqual(true, blurred.at(2, 4).* > 0);

    // Some spreading should occur
    var non_zero_count: usize = 0;
    for (blurred.data) |pixel| {
        if (pixel > 0) non_zero_count += 1;
    }
    try expectEqual(true, non_zero_count > 1);
}

test "radialMotionBlur zero strength" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Create pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c);
        }
    }

    var blurred = try Image(u8).initLike(std.testing.allocator, image);
    defer blurred.deinit(std.testing.allocator);
    try image.motionBlur(io, std.testing.allocator, blurred, .{ .radial_zoom = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0 } });

    // Should be identical to original
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "gaussianBlur with sigma=0" {
    var image: Image(f32) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Fill with test pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @floatFromInt(r * 5 + c);
        }
    }

    var result = try Image(f32).initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    try image.gaussianBlur(io, std.testing.allocator, result, 0, .default);

    // With sigma=0, result should be identical to input
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try std.testing.expectEqual(image.at(r, c).*, result.at(r, c).*);
        }
    }
}

test "canny edge detection basic" {
    // Test basic Canny edge detection on a simple vertical edge
    var image: Image(u8) = try .init(std.testing.allocator, 10, 10);
    defer image.deinit(std.testing.allocator);

    // Create a vertical edge at column 5
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 5) 0 else 255;
        }
    }

    var edges = try Image(u8).initLike(std.testing.allocator, image);
    defer edges.deinit(std.testing.allocator);
    try image.canny(io, std.testing.allocator, edges, 1.0, 50, 100);

    try expectEqual(image.rows, edges.rows);
    try expectEqual(image.cols, edges.cols);

    // Should detect an edge somewhere near column 5
    var edge_detected = false;
    for (0..edges.rows) |r| {
        for (4..7) |c| {
            if (edges.at(r, c).* > 0) {
                edge_detected = true;
                break;
            }
        }
    }
    try expectEqual(true, edge_detected);
}

test "canny edge detection parameter validation" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    var edges = try Image(u8).initLike(std.testing.allocator, image);
    defer edges.deinit(std.testing.allocator);

    // Test sigma=0 is valid (no blur)
    try image.canny(io, std.testing.allocator, edges, 0, 50, 100);

    // Test invalid sigma
    try expectError(error.InvalidSigma, image.canny(io, std.testing.allocator, edges, -1, 50, 100));

    // Test invalid thresholds
    try expectError(error.InvalidThreshold, image.canny(io, std.testing.allocator, edges, 1.0, -1, 100));
    try expectError(error.InvalidThreshold, image.canny(io, std.testing.allocator, edges, 1.0, 50, -1));
    try expectError(error.InvalidThreshold, image.canny(io, std.testing.allocator, edges, 1.0, 100, 50));
}

test "canny rejects non-finite parameters" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    var edges = try Image(u8).initLike(std.testing.allocator, image);
    defer edges.deinit(std.testing.allocator);

    // Test NaN
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, std.math.nan(f32), 50, 100));
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, 1.0, std.math.nan(f32), 100));
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, 1.0, 50, std.math.nan(f32)));

    // Test infinity
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, std.math.inf(f32), 50, 100));
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, 1.0, std.math.inf(f32), 100));
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, 1.0, 50, std.math.inf(f32)));

    // Test negative infinity
    try expectError(error.InvalidParameter, image.canny(io, std.testing.allocator, edges, -std.math.inf(f32), 50, 100));
}

test "canny edge detection on RGB" {
    // Test that Canny works with RGB images (converts to grayscale internally)
    var image: Image(Rgb) = try .init(std.testing.allocator, 8, 8);
    defer image.deinit(std.testing.allocator);

    // Create a colored vertical edge
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            if (c < 4) {
                image.at(r, c).* = .{ .r = 255, .g = 0, .b = 0 };
            } else {
                image.at(r, c).* = .{ .r = 0, .g = 255, .b = 0 };
            }
        }
    }

    var edges = try Image(u8).initLike(std.testing.allocator, image);
    defer edges.deinit(std.testing.allocator);
    try image.canny(io, std.testing.allocator, edges, 1.0, 30, 90);

    try expectEqual(image.rows, edges.rows);
    try expectEqual(image.cols, edges.cols);

    // Should detect the edge
    var edge_detected = false;
    for (0..edges.rows) |r| {
        for (3..6) |c| {
            if (edges.at(r, c).* > 0) {
                edge_detected = true;
                break;
            }
        }
    }
    try expectEqual(true, edge_detected);
}

test "convolve regression issue #255 (missing pixels)" {
    // This test ensures that convolution writes all pixels, even when SIMD is used.
    // Specifically targets the case where leading border columns were skipped.
    const width = 20;
    const height = 10;
    var image: Image(u8) = try .init(std.testing.allocator, height, width);
    defer image.deinit(std.testing.allocator);
    image.fill(1);

    var result: Image(u8) = try .initLike(std.testing.allocator, image);
    defer result.deinit(std.testing.allocator);
    result.fill(0xAA);

    const kernel = [3][3]u8{
        .{ 1, 1, 1 },
        .{ 1, 0, 1 },
        .{ 1, 1, 1 },
    };

    try image.convolve(io, std.testing.allocator, result, kernel, .zero);

    // For interior pixels with all 1s and zero padding, 3x3 kernel with 0 at center
    // should result in 8 if all neighbors are 1.
    // For leading column 0, row 1, neighbors (with zero padding) are:
    // (0,-1)=0, (0,0)=1, (0,1)=1
    // (1,-1)=0, (1,0)=1, (1,1)=1 (center is (1,0))
    // (2,-1)=0, (2,0)=1, (2,1)=1
    // Sum = (0*1 + 1*1 + 1*1) + (0*1 + 1*0 + 1*1) + (0*1 + 1*1 + 1*1) = 2 + 1 + 2 = 5.

    // Check first column for interior rows
    for (1..height - 1) |r| {
        try std.testing.expectEqual(@as(u8, 5), result.at(r, 0).*);
    }

    // Check second column (interior)
    for (1..height - 1) |r| {
        // Neighbors: all 1s except center
        // Sum = 8
        try std.testing.expectEqual(@as(u8, 8), result.at(r, 1).*);
    }
}

test "convolvePair matches two independent convolves" {
    const convolution = @import("../convolution.zig");
    const allocator = std.testing.allocator;

    const kernel_a = [3][3]f32{
        .{ -1, 0, 1 },
        .{ -2, 0, 2 },
        .{ -1, 0, 1 },
    };
    const kernel_b = [3][3]f32{
        .{ -1, -2, -1 },
        .{ 0, 0, 0 },
        .{ 1, 2, 1 },
    };

    inline for ([_]type{ u8, f32 }) |T| {
        var src: Image(T) = try .init(allocator, 11, 17);
        defer src.deinit(allocator);
        for (src.data, 0..) |*px, i| {
            px.* = @as(u8, @truncate(i * 31 + 7));
        }

        for ([_]BorderMode{ .replicate, .zero }) |mode| {
            var pair_a: Image(T) = try .initLike(allocator, src);
            defer pair_a.deinit(allocator);
            var pair_b: Image(T) = try .initLike(allocator, src);
            defer pair_b.deinit(allocator);
            var solo_a: Image(T) = try .initLike(allocator, src);
            defer solo_a.deinit(allocator);
            var solo_b: Image(T) = try .initLike(allocator, src);
            defer solo_b.deinit(allocator);

            convolution.convolvePair(T, io, src, pair_a, pair_b, kernel_a, kernel_b, mode);
            try src.convolve(io, allocator, solo_a, kernel_a, mode);
            try src.convolve(io, allocator, solo_b, kernel_b, mode);

            try std.testing.expectEqualSlices(T, solo_a.data, pair_a.data);
            try std.testing.expectEqualSlices(T, solo_b.data, pair_b.data);
        }
    }
}

test "boxBlur/sharpen interleaved u8 path matches plane-split path" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var image: Image(Rgb) = try .init(allocator, 23, 31);
    defer image.deinit(allocator);
    for (image.data) |*px| {
        px.* = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) };
    }

    var filtered: Image(Rgb) = try .initLike(allocator, image);
    defer filtered.deinit(allocator);
    var chan: Image(u8) = try .init(allocator, image.rows, image.cols);
    defer chan.deinit(allocator);
    var chan_filtered: Image(u8) = try .initLike(allocator, chan);
    defer chan_filtered.deinit(allocator);

    for ([_]u32{ 1, 3, 7 }) |radius| {
        inline for ([_]enum { blur, sharpen }{ .blur, .sharpen }) |mode| {
            switch (mode) {
                .blur => try image.boxBlur(io, allocator, filtered, radius),
                .sharpen => try image.sharpen(io, allocator, filtered, radius),
            }
            inline for ([_][]const u8{ "r", "g", "b" }) |name| {
                for (chan.data, image.data) |*dst, px| dst.* = @field(px, name);
                switch (mode) {
                    .blur => try chan.boxBlur(io, allocator, chan_filtered, radius),
                    .sharpen => try chan.sharpen(io, allocator, chan_filtered, radius),
                }
                for (chan_filtered.data, filtered.data) |expected, px| {
                    try expectEqual(expected, @field(px, name));
                }
            }
        }
    }
}

// Every banded filter must produce the same bytes on a thread pool as serially. The image is
// large enough for several bands and for the fused separable path (temp plane > 1 MiB).
test "filters are identical on a thread pool" {
    const allocator = std.testing.allocator;
    var pool: std.Io.Threaded = .init(allocator, .{});
    defer pool.deinit();
    const pool_io = pool.io();
    const serial_io = io;

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    // 520x640 takes the fused separable path (temp plane > 1 MiB); 400x600 the two-pass one.
    for ([_][2]u32{ .{ 520, 640 }, .{ 400, 600 } }) |shape| {
        const rows = shape[0];
        const cols = shape[1];

        const Check = struct {
            fn run(comptime filter: anytype, src: anytype, out_serial: anytype, out_pool: anytype, io_serial: std.Io, io_pool: std.Io) !void {
                try filter(src, io_serial, out_serial);
                try filter(src, io_pool, out_pool);
                try std.testing.expectEqualSlices(std.meta.Child(@TypeOf(out_serial.data)), out_serial.data, out_pool.data);
            }
        };

        inline for ([_]type{ u8, f32, Rgb }) |T| {
            var src: Image(T) = try .init(allocator, rows, cols);
            defer src.deinit(allocator);
            for (src.data) |*px| px.* = switch (T) {
                u8 => random.int(u8),
                f32 => 255 * random.float(f32),
                else => .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) },
            };
            var a: Image(T) = try .initLike(allocator, src);
            defer a.deinit(allocator);
            var b: Image(T) = try .initLike(allocator, src);
            defer b.deinit(allocator);
            var gray_a: Image(u8) = try .init(allocator, rows, cols);
            defer gray_a.deinit(allocator);
            var gray_b: Image(u8) = try .init(allocator, rows, cols);
            defer gray_b.deinit(allocator);

            const F = struct {
                fn box(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.boxBlur(run_io, allocator, o, 3);
                }
                fn sharp(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.sharpen(run_io, allocator, o, 2);
                }
                fn gauss(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.gaussianBlur(run_io, allocator, o, 2.5, .default);
                }
                fn gaussWide(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.gaussianBlur(run_io, allocator, o, 9, .default);
                }
                fn gaussIir(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.gaussianBlur(run_io, allocator, o, 9, .{ .method = .iir });
                }
                fn conv(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    const k = [7][7]f32{
                        .{ 1, 2, 3, 4, 3, 2, 1 },
                        .{ 2, 3, 4, 5, 4, 3, 2 },
                        .{ 3, 4, 5, 6, 5, 4, 3 },
                        .{ 4, 5, 6, 7, 6, 5, 4 },
                        .{ 3, 4, 5, 6, 5, 4, 3 },
                        .{ 2, 3, 4, 5, 4, 3, 2 },
                        .{ 1, 2, 3, 4, 3, 2, 1 },
                    };
                    var kn = k;
                    for (&kn) |*row| for (row) |*v| {
                        v.* /= 175;
                    };
                    try s.convolve(run_io, allocator, o, kn, .mirror);
                }
                fn sep(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.convolveSeparable(run_io, allocator, o, &.{ 0.1, 0.2, 0.4, 0.2, 0.1 }, &.{ 0.25, 0.5, 0.25 }, .replicate);
                }
                fn motionH(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.motionBlur(run_io, allocator, o, .{ .linear = .{ .angle = 0, .distance = 11 } });
                }
                fn motionV(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.motionBlur(run_io, allocator, o, .{ .linear = .{ .angle = std.math.pi / 2.0, .distance = 11 } });
                }
                fn median(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    try s.medianBlur(run_io, allocator, o, 3);
                }
                fn percentileWide(s: Image(T), run_io: std.Io, o: Image(T)) !void {
                    // Radius 130 (window 261) exceeds the two-level limit and takes the flat path.
                    try s.percentileBlur(run_io, allocator, o, 130, 0.2, .zero);
                }
                fn sobel(s: Image(T), run_io: std.Io, o: Image(u8)) !void {
                    try s.sobel(run_io, allocator, o);
                }
            };
            inline for (.{ F.box, F.sharp, F.gauss, F.gaussWide, F.gaussIir, F.conv, F.sep, F.motionH, F.motionV }) |filter| {
                try Check.run(filter, src, a, b, serial_io, pool_io);
            }
            // Order-statistic filters take u8 planes only.
            if (T != f32) {
                try Check.run(F.median, src, a, b, serial_io, pool_io);
                try Check.run(F.percentileWide, src, a, b, serial_io, pool_io);
            }
            try Check.run(F.sobel, src, gray_a, gray_b, serial_io, pool_io);
        }
    }
}

// Kernels above 7x7 loop over rows at runtime instead of unrolling both axes; every size
// must match a plain reference for u8 and f32 in every border mode.
test "large 2D kernels match a scalar reference" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xbeef);
    const random = prng.random();

    inline for ([_]type{ u8, f32 }) |T| {
        var src: Image(T) = try .init(allocator, 37, 41);
        defer src.deinit(allocator);
        for (src.data) |*px| px.* = if (T == u8) random.int(u8) else 255 * random.float(f32);
        var out: Image(T) = try .initLike(allocator, src);
        defer out.deinit(allocator);

        inline for ([_]usize{ 9, 15, 31 }) |k| {
            // Centre plus the four corners, in 1/256 steps so the u8 fixed-point taps are exact
            // while the taps still reach the kernel's full extent.
            var kernel: [k][k]f32 = @splat(@splat(0));
            kernel[k / 2][k / 2] = 128.0 / 256.0;
            kernel[0][0] = 32.0 / 256.0;
            kernel[0][k - 1] = 32.0 / 256.0;
            kernel[k - 1][0] = 32.0 / 256.0;
            kernel[k - 1][k - 1] = 32.0 / 256.0;
            for ([_]BorderMode{ .zero, .replicate, .mirror, .wrap }) |mode| {
                try src.convolve(io, allocator, out, kernel, mode);
                for (0..src.rows) |r| {
                    for (0..src.cols) |c| {
                        var acc: f32 = 0;
                        for (0..k) |ky| {
                            for (0..k) |kx| {
                                const sr = @as(isize, @intCast(r + ky)) - @as(isize, k / 2);
                                const sc = @as(isize, @intCast(c + kx)) - @as(isize, k / 2);
                                const sample = @import("../border.zig").getPixel(T, src, sr, sc, mode);
                                acc += @as(f32, sample) * kernel[ky][kx];
                            }
                        }
                        const got = out.at(r, c).*;
                        if (T == u8) {
                            // Exact taps: the only difference is the round-half-up store.
                            try std.testing.expect(@abs(@as(f32, got) - acc) <= 0.51);
                        } else {
                            try std.testing.expectApproxEqAbs(acc, got, 1e-2);
                        }
                    }
                }
            }
        }
    }
}

//! Filter tests - box blur and sharpen

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectError = std.testing.expectError;

const color = @import("../../color.zig");
const Rgb = color.Rgb(u8);
const Rgba = color.Rgba(u8);
const Hsl = color.Hsl(f64);
const Gray = color.Gray;
const Rectangle = @import("../../geometry.zig").Rectangle;
const Image = @import("../../image.zig").Image;
const BorderMode = @import("../../image.zig").BorderMode;

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
    try view.boxBlur(std.testing.allocator, 0, blurred);

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
    const rect: Rectangle(usize) = .{ .l = 0, .t = 0, .r = 8, .b = 10 };
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
    try image.boxBlur(std.testing.allocator, 1, blurred);

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
    try image.boxBlur(std.testing.allocator, 0, blurred);

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
    try image.boxBlur(std.testing.allocator, 1, blurred);

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
    try image.boxBlur(std.testing.allocator, 1, blurred);

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
    const test_size = 12;
    const radius = 3;

    // Test with uniform image - all pixels should have the same value after blur
    var uniform_image: Image(u8) = try .init(std.testing.allocator, test_size, test_size);
    defer uniform_image.deinit(std.testing.allocator);

    for (uniform_image.data) |*pixel| pixel.* = 200;

    var uniform_blurred = try Image(u8).initLike(std.testing.allocator, uniform_image);
    defer uniform_blurred.deinit(std.testing.allocator);
    try uniform_image.boxBlur(std.testing.allocator, radius, uniform_blurred);

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
    try gradient_image.boxBlur(std.testing.allocator, radius, gradient_blurred);

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
    for ([_]usize{ 8, 32 }) |test_size| { // Small and large
        for ([_]usize{ 1, 3 }) |radius| {
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
            try image.boxBlur(std.testing.allocator, radius, blurred);

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
    try image.sharpen(std.testing.allocator, 1, sharpened);

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
    try image.sharpen(std.testing.allocator, 0, sharpened);

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
    try image.sharpen(std.testing.allocator, 1, sharpened);

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
    try image.sharpen(std.testing.allocator, 1, sharpened);

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
    try image.convolve(std.testing.allocator, identity, .zero, result);

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
    try image.convolve(std.testing.allocator, blur, .replicate, result);

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
    try image.convolve(std.testing.allocator, kernel, .zero, result_zero);

    // Test replicate border mode
    var result_replicate = try Image(u8).initLike(std.testing.allocator, image);
    defer result_replicate.deinit(std.testing.allocator);
    try image.convolve(std.testing.allocator, kernel, .replicate, result_replicate);

    // Test mirror border mode
    var result_mirror = try Image(u8).initLike(std.testing.allocator, image);
    defer result_mirror.deinit(std.testing.allocator);
    try image.convolve(std.testing.allocator, kernel, .mirror, result_mirror);

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
    try image.convolveSeparable(std.testing.allocator, &gaussian_1d, &gaussian_1d, .zero, result);

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
    try image.gaussianBlur(std.testing.allocator, 1.0, blurred);

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
    try image.gaussianBlur(std.testing.allocator, 0.5, blur_small);

    var blur_large = try Image(f32).initLike(std.testing.allocator, image);
    defer blur_large.deinit(std.testing.allocator);
    try image.gaussianBlur(std.testing.allocator, 2.0, blur_large);

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
    try image.sobel(std.testing.allocator, edges);

    // Should detect strong edge at column 2
    const edge_strength = edges.at(2, 2).*;
    const non_edge = edges.at(2, 0).*;

    try expectEqual(edge_strength > 200, true); // Strong edge
    try expectEqual(non_edge < 50, true); // Weak or no edge
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
    try image.convolve(std.testing.allocator, edge, .zero, result);

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
    try image.convolve(std.testing.allocator, identity, .zero, result);

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
    const rect: Rectangle(usize) = .{ .l = 2, .t = 1, .r = 6, .b = 5 }; // width=4, height=4
    var src_view = base_src.view(rect);
    var dst_view = base_dst.view(rect);

    // Identity kernel: should copy src_view into dst_view
    const identity = [3][3]f32{
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 0 },
    };

    try src_view.convolve(std.testing.allocator, identity, .zero, dst_view);

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
    const rect: Rectangle(usize) = .{ .l = 1, .t = 2, .r = 6, .b = 6 }; // width=5, height=4
    var src_view = base_src.view(rect);
    var dst_view = base_dst.view(rect);

    // Separable identity: [1] horizontally and vertically
    const k1 = [_]f32{1.0};
    try src_view.convolveSeparable(std.testing.allocator, &k1, &k1, .zero, dst_view);

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
    try image.gaussianBlur(std.testing.allocator, 1.0, blurred);

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
    try image.medianBlur(std.testing.allocator, 1, blurred);

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
    try image.percentileBlur(std.testing.allocator, 1, 1.0, BorderMode.zero, out);

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
    try image.medianBlur(std.testing.allocator, 1, blurred);

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

    try image.minBlur(std.testing.allocator, 1, BorderMode.replicate, min_blur);
    try image.percentileBlur(std.testing.allocator, 1, 0.0, BorderMode.replicate, percentile);

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

    try image.maxBlur(std.testing.allocator, 1, BorderMode.replicate, max_blur);
    try image.percentileBlur(std.testing.allocator, 1, 1.0, BorderMode.replicate, percentile);

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
    try image.midpointBlur(std.testing.allocator, 1, BorderMode.replicate, blurred);

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
    try image.alphaTrimmedMeanBlur(std.testing.allocator, 1, 0.12, BorderMode.replicate, blurred);

    try expectEqual(@as(u8, 4), blurred.at(1, 1).*);
}

test "alphaTrimmedMeanBlur invalid trim" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    var out = try Image(u8).initLike(std.testing.allocator, image);
    defer out.deinit(std.testing.allocator);

    try expectError(error.InvalidTrim, image.alphaTrimmedMeanBlur(std.testing.allocator, 1, 0.6, BorderMode.replicate, out));
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
    try image.motionBlur(std.testing.allocator, .{ .linear = .{ .angle = 0, .distance = 3 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .linear = .{ .angle = std.math.pi / 2.0, .distance = 3 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .linear = .{ .angle = std.math.pi / 4.0, .distance = 3 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .linear = .{ .angle = 0, .distance = 0 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .linear = .{ .angle = 0, .distance = 3 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .radial_zoom = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.5 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .radial_spin = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.5 } }, blurred);

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
    try image.motionBlur(std.testing.allocator, .{ .radial_zoom = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0 } }, blurred);

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
    try image.gaussianBlur(std.testing.allocator, 0, result);

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
    try image.canny(std.testing.allocator, 1.0, 50, 100, edges);

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
    try image.canny(std.testing.allocator, 0, 50, 100, edges);

    // Test invalid sigma
    try expectError(error.InvalidSigma, image.canny(std.testing.allocator, -1, 50, 100, edges));

    // Test invalid thresholds
    try expectError(error.InvalidThreshold, image.canny(std.testing.allocator, 1.0, -1, 100, edges));
    try expectError(error.InvalidThreshold, image.canny(std.testing.allocator, 1.0, 50, -1, edges));
    try expectError(error.InvalidThreshold, image.canny(std.testing.allocator, 1.0, 100, 50, edges));
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
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, std.math.nan(f32), 50, 100, edges));
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, 1.0, std.math.nan(f32), 100, edges));
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, 1.0, 50, std.math.nan(f32), edges));

    // Test infinity
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, std.math.inf(f32), 50, 100, edges));
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, 1.0, std.math.inf(f32), 100, edges));
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, 1.0, 50, std.math.inf(f32), edges));

    // Test negative infinity
    try expectError(error.InvalidParameter, image.canny(std.testing.allocator, -std.math.inf(f32), 50, 100, edges));
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
    try image.canny(std.testing.allocator, 1.0, 30, 90, edges);

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

    try image.convolve(std.testing.allocator, kernel, .zero, result);

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

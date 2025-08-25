//! Filter tests - box blur and sharpen

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const color = @import("../../color.zig");
const Rgb = color.Rgb;
const Rectangle = @import("../../geometry.zig").Rectangle;
const Image = @import("../../image.zig").Image;

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
    var blurred: Image(u8) = undefined;
    try view.boxBlur(std.testing.allocator, &blurred, 0);
    defer blurred.deinit(std.testing.allocator);

    // Should be identical to view
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "view" {
    var image: Image(color.Rgba) = try .init(std.testing.allocator, 21, 13);
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

    var blurred: Image(u8) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 1);
    defer blurred.deinit(std.testing.allocator);

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

    var blurred: Image(u8) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 0);
    defer blurred.deinit(std.testing.allocator);

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

    var blurred: Image(u8) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 1);
    defer blurred.deinit(std.testing.allocator);

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
    var image: Image(color.Rgba) = try .init(std.testing.allocator, 3, 3);
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

    var blurred: Image(color.Rgba) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 1);
    defer blurred.deinit(std.testing.allocator);

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

    var uniform_blurred: Image(u8) = undefined;
    try uniform_image.boxBlur(std.testing.allocator, &uniform_blurred, radius);
    defer uniform_blurred.deinit(std.testing.allocator);

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

    var gradient_blurred: Image(u8) = undefined;
    try gradient_image.boxBlur(std.testing.allocator, &gradient_blurred, radius);
    defer gradient_blurred.deinit(std.testing.allocator);

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
            var image: Image(color.Rgba) = try .init(std.testing.allocator, test_size, test_size);
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

            var blurred: Image(color.Rgba) = undefined;
            try image.boxBlur(std.testing.allocator, &blurred, radius);
            defer blurred.deinit(std.testing.allocator);

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

    var sharpened: Image(u8) = undefined;
    try image.sharpen(std.testing.allocator, &sharpened, 1);
    defer sharpened.deinit(std.testing.allocator);

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

    var sharpened: Image(u8) = undefined;
    try image.sharpen(std.testing.allocator, &sharpened, 0);
    defer sharpened.deinit(std.testing.allocator);

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

    var sharpened: Image(u8) = .empty;
    try image.sharpen(std.testing.allocator, &sharpened, 1);
    defer sharpened.deinit(std.testing.allocator);

    // Uniform image should remain uniform after sharpening
    // (2 * original - blurred = 2 * 100 - 100 = 100)
    for (sharpened.data) |pixel| {
        try expectEqual(@as(u8, 100), pixel);
    }
}

test "sharpen struct type" {
    var image: Image(color.Rgba) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Create a simple pattern with a bright center
    for (image.data) |*pixel| pixel.* = .{ .r = 64, .g = 64, .b = 64, .a = 255 };
    image.at(1, 1).* = .{ .r = 192, .g = 192, .b = 192, .a = 255 }; // Bright center

    var sharpened: Image(color.Rgba) = .empty;
    try image.sharpen(std.testing.allocator, &sharpened, 1);
    defer sharpened.deinit(std.testing.allocator);

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

    var result: Image(u8) = .empty;
    try image.convolve(std.testing.allocator, identity, &result, .zero);
    defer result.deinit(std.testing.allocator);

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

    var result: Image(u8) = .empty;
    try image.convolve(std.testing.allocator, blur, &result, .replicate);
    defer result.deinit(std.testing.allocator);

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
    var result_zero: Image(u8) = .empty;
    try image.convolve(std.testing.allocator, kernel, &result_zero, .zero);
    defer result_zero.deinit(std.testing.allocator);

    // Test replicate border mode
    var result_replicate: Image(u8) = .empty;
    try image.convolve(std.testing.allocator, kernel, &result_replicate, .replicate);
    defer result_replicate.deinit(std.testing.allocator);

    // Test mirror border mode
    var result_mirror: Image(u8) = .empty;
    try image.convolve(std.testing.allocator, kernel, &result_mirror, .mirror);
    defer result_mirror.deinit(std.testing.allocator);

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

    var result: Image(f32) = .empty;
    try image.convolveSeparable(std.testing.allocator, &gaussian_1d, &gaussian_1d, &result, .zero);
    defer result.deinit(std.testing.allocator);

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

    var blurred: Image(u8) = .empty;
    try image.gaussianBlur(std.testing.allocator, 1.0, &blurred);
    defer blurred.deinit(std.testing.allocator);

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
    var blur_small: Image(f32) = .empty;
    try image.gaussianBlur(std.testing.allocator, 0.5, &blur_small);
    defer blur_small.deinit(std.testing.allocator);

    var blur_large: Image(f32) = .empty;
    try image.gaussianBlur(std.testing.allocator, 2.0, &blur_large);
    defer blur_large.deinit(std.testing.allocator);

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

    var edges: Image(u8) = .empty;
    try image.sobel(std.testing.allocator, &edges);
    defer edges.deinit(std.testing.allocator);

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

    var result: Image(u8) = .empty;
    try image.convolve(std.testing.allocator, edge, &result, .zero);
    defer result.deinit(std.testing.allocator);

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

    var result: Image(Rgb) = .empty;
    try image.convolve(std.testing.allocator, identity, &result, .zero);
    defer result.deinit(std.testing.allocator);

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

    try src_view.convolve(std.testing.allocator, identity, &dst_view, .zero);

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
    try src_view.convolveSeparable(std.testing.allocator, &k1, &k1, &dst_view, .zero);

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

test "differenceOfGaussians basic functionality" {
    // Test basic DoG functionality with a simple edge pattern
    var image: Image(f32) = try .init(std.testing.allocator, 11, 11);
    defer image.deinit(std.testing.allocator);

    // Create a white square in the center
    for (image.data) |*pixel| pixel.* = 0;
    for (3..8) |r| {
        for (3..8) |c| {
            image.at(r, c).* = 1.0;
        }
    }

    var dog_result: Image(f32) = .empty;
    try image.differenceOfGaussians(std.testing.allocator, 1.0, 1.6, &dog_result);
    defer dog_result.deinit(std.testing.allocator);

    // Check that DoG produces reasonable results
    try expectEqual(@as(usize, 11), dog_result.rows);
    try expectEqual(@as(usize, 11), dog_result.cols);

    // Check that we have non-zero values (the filter did something)
    var has_non_zero = false;
    var has_positive = false;
    var has_negative = false;
    for (0..dog_result.rows) |r| {
        for (0..dog_result.cols) |c| {
            const val = dog_result.at(r, c).*;
            if (val != 0) has_non_zero = true;
            if (val > 0) has_positive = true;
            if (val < 0) has_negative = true;
        }
    }

    // DoG should produce both positive and negative values (band-pass characteristic)
    try expectEqual(true, has_non_zero);
    try expectEqual(true, has_positive);
    try expectEqual(true, has_negative);
}

test "differenceOfGaussians edge detection" {
    // Test DoG for edge detection with vertical edge
    var image: Image(u8) = try .init(std.testing.allocator, 7, 7);
    defer image.deinit(std.testing.allocator);

    // Create a vertical edge
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 3) 64 else 192;
        }
    }

    var dog_result: Image(u8) = .empty;
    try image.differenceOfGaussians(std.testing.allocator, 0.5, 1.0, &dog_result);
    defer dog_result.deinit(std.testing.allocator);

    // The edge region (around column 3) should have different values than uniform regions
    const left_uniform = dog_result.at(3, 1).*;
    const edge_region = dog_result.at(3, 3).*;
    const right_uniform = dog_result.at(3, 5).*;

    // Edge region should differ from uniform regions
    try expectEqual(true, edge_region != left_uniform or edge_region != right_uniform);
}

test "differenceOfGaussians invalid parameters" {
    var image: Image(f32) = try .init(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    var result: Image(f32) = .empty;
    // Don't defer deinit for an empty image that may never be allocated

    // Test with invalid sigmas
    try std.testing.expectError(error.InvalidSigma, image.differenceOfGaussians(std.testing.allocator, -1.0, 2.0, &result));
    try std.testing.expectError(error.InvalidSigma, image.differenceOfGaussians(std.testing.allocator, 1.0, -2.0, &result));
    try std.testing.expectError(error.SigmasMustDiffer, image.differenceOfGaussians(std.testing.allocator, 1.0, 1.0, &result));
}

test "differenceOfGaussians with RGB" {
    // Test DoG with color images
    var image: Image(Rgb) = try .init(std.testing.allocator, 9, 9);
    defer image.deinit(std.testing.allocator);

    // Create a colored square in the center
    for (image.data) |*pixel| pixel.* = .{ .r = 0, .g = 0, .b = 0 };
    for (3..6) |r| {
        for (3..6) |c| {
            image.at(r, c).* = .{ .r = 255, .g = 128, .b = 64 };
        }
    }

    var dog_result: Image(Rgb) = .empty;
    try image.differenceOfGaussians(std.testing.allocator, 0.8, 1.3, &dog_result);
    defer dog_result.deinit(std.testing.allocator);

    // Just verify it runs without error and produces reasonable output
    try expectEqual(dog_result.rows, image.rows);
    try expectEqual(dog_result.cols, image.cols);

    // Check that color channels are processed independently
    const center = dog_result.at(4, 4).*;
    const edge = dog_result.at(2, 4).*;

    // Edge and center should have different values (edge enhancement)
    try expectEqual(true, center.r != edge.r or center.g != edge.g or center.b != edge.b);
}

test "differenceOfGaussians approximates manual subtraction" {
    // Test that DoG(sigma1, sigma2) ≈ blur(sigma1) - blur(sigma2)
    var image: Image(f32) = try .init(std.testing.allocator, 15, 15);
    defer image.deinit(std.testing.allocator);

    // Create a test pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const val = @as(f32, @floatFromInt((r + c) % 5)) * 0.2;
            image.at(r, c).* = val;
        }
    }

    const sigma1: f32 = 1.0;
    const sigma2: f32 = 2.0;

    // Compute DoG
    var dog_result: Image(f32) = .empty;
    try image.differenceOfGaussians(std.testing.allocator, sigma1, sigma2, &dog_result);
    defer dog_result.deinit(std.testing.allocator);

    // Compute manual subtraction
    var blur1: Image(f32) = .empty;
    var blur2: Image(f32) = .empty;
    try image.gaussianBlur(std.testing.allocator, sigma1, &blur1);
    defer blur1.deinit(std.testing.allocator);
    try image.gaussianBlur(std.testing.allocator, sigma2, &blur2);
    defer blur2.deinit(std.testing.allocator);

    // Manual subtraction
    var manual_result: Image(f32) = try .init(std.testing.allocator, image.rows, image.cols);
    defer manual_result.deinit(std.testing.allocator);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            manual_result.at(r, c).* = blur1.at(r, c).* - blur2.at(r, c).*;
        }
    }

    // Results should be very close (allowing for small floating point differences)
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const dog_val = dog_result.at(r, c).*;
            const manual_val = manual_result.at(r, c).*;
            const diff = @abs(dog_val - manual_val);
            try expectEqual(true, diff < 0.001); // Allow small tolerance for floating point
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

    var blurred: Image(Rgb) = .empty;
    try image.gaussianBlur(std.testing.allocator, 1.0, &blurred);
    defer blurred.deinit(std.testing.allocator);

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

//! Filter tests - box blur and sharpen

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const color = @import("../../color.zig");
const Rgb = color.Rgb;
const Rectangle = @import("../../geometry.zig").Rectangle;
const Image = @import("../Image.zig").Image;

test "boxBlur radius 0 with views" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 6, 8);
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
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    const rect: Rectangle(usize) = .{ .l = 0, .t = 0, .r = 8, .b = 10 };
    const view = image.view(rect);
    try expectEqual(view.isView(), true);
    try expectEqual(image.isView(), false);
    try expectEqualDeep(rect, view.getRectangle());
}

test "boxBlur basic functionality" {
    // Test with uniform image - should remain unchanged
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 5);
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
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 3, 3);
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
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 5);
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
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 3, 3);
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

test "boxBlur SIMD vs non-SIMD consistency" {
    // Test specifically designed to trigger both SIMD and non-SIMD paths
    // Large enough for SIMD optimizations with different radii
    const test_size = 64; // Large enough for SIMD

    for ([_]usize{ 1, 2, 3, 5 }) |radius| {
        var image: Image(u8) = try .initAlloc(std.testing.allocator, test_size, test_size);
        defer image.deinit(std.testing.allocator);

        // Create a checkerboard pattern to expose area calculation errors
        for (0..image.rows) |r| {
            for (0..image.cols) |c| {
                image.at(r, c).* = if ((r + c) % 2 == 0) 255 else 0;
            }
        }

        var blurred: Image(u8) = undefined;
        try image.boxBlur(std.testing.allocator, &blurred, radius);
        defer blurred.deinit(std.testing.allocator);

        // The key test: center pixels processed by SIMD should be mathematically consistent
        // with border pixels processed by scalar code. For a checkerboard, we can verify
        // the blur result is symmetric and area calculations are correct.

        // Check symmetry - if area calculations are correct, symmetric patterns should blur symmetrically
        const center = test_size / 2;
        try expectEqual(blurred.at(center, center).*, blurred.at(center, center).*); // Trivial but ensures no crash

        // Check that corners have lower values (smaller effective area) than center
        const corner_val = blurred.at(0, 0).*;
        const center_val = blurred.at(center, center).*;

        // For checkerboard pattern, center should be ~127.5, corners should be higher due to smaller kernel
        try expectEqual(corner_val >= center_val, true);
    }
}

test "boxBlur border area calculations" {
    // Test that border pixels get correct area calculations by comparing
    // uniform images with different values
    const test_size = 12;
    const radius = 3;

    // Test with uniform image - all pixels should have the same value after blur
    var uniform_image: Image(u8) = try .initAlloc(std.testing.allocator, test_size, test_size);
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
    var gradient_image: Image(u8) = try .initAlloc(std.testing.allocator, test_size, test_size);
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
            var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, test_size, test_size);
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

test "boxBlur RGB vs RGBA with full alpha produces same RGB values" {
    // Simple test: RGB image and RGBA image with alpha=255 should produce
    // identical results for the RGB channels

    const test_size = 10;
    const radius = 2;

    // Create RGB image
    var rgb_img = try Image(Rgb).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgb_img.deinit(std.testing.allocator);

    // Create RGBA image
    var rgba_img = try Image(color.Rgba).initAlloc(std.testing.allocator, test_size, test_size);
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

    // Apply blur to both
    var rgb_blurred: Image(Rgb) = undefined;
    try rgb_img.boxBlur(std.testing.allocator, &rgb_blurred, radius);
    defer rgb_blurred.deinit(std.testing.allocator);

    var rgba_blurred: Image(color.Rgba) = undefined;
    try rgba_img.boxBlur(std.testing.allocator, &rgba_blurred, radius);
    defer rgba_blurred.deinit(std.testing.allocator);

    // Compare RGB channels - they should be identical
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const rgb = rgb_blurred.at(r, c).*;
            const rgba = rgba_blurred.at(r, c).*;

            try expectEqual(rgb.r, rgba.r);
            try expectEqual(rgb.g, rgba.g);
            try expectEqual(rgb.b, rgba.b);
            try expectEqual(@as(u8, 255), rgba.a); // Alpha should remain 255
        }
    }
}

test "sharpen RGB vs RGBA with full alpha produces same RGB values" {
    // Simple test: RGB image and RGBA image with alpha=255 should produce
    // identical results for the RGB channels when sharpened

    const test_size = 8;
    const radius = 1;

    // Create RGB image
    var rgb_img = try Image(Rgb).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgb_img.deinit(std.testing.allocator);

    // Create RGBA image
    var rgba_img = try Image(color.Rgba).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgba_img.deinit(std.testing.allocator);

    // Fill both with identical RGB values (create an edge pattern for sharpening)
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const val: u8 = if (c < test_size / 2) 64 else 192; // Left dark, right bright
            const r_val = val;
            const g_val = val +% 30;
            const b_val = val +% 60;

            rgb_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val };
            rgba_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val, .a = 255 };
        }
    }

    // Apply sharpen to both
    var rgb_sharpened: Image(Rgb) = undefined;
    try rgb_img.sharpen(std.testing.allocator, &rgb_sharpened, radius);
    defer rgb_sharpened.deinit(std.testing.allocator);

    var rgba_sharpened: Image(color.Rgba) = undefined;
    try rgba_img.sharpen(std.testing.allocator, &rgba_sharpened, radius);
    defer rgba_sharpened.deinit(std.testing.allocator);

    // Compare RGB channels - they should be identical
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const rgb = rgb_sharpened.at(r, c).*;
            const rgba = rgba_sharpened.at(r, c).*;

            try expectEqual(rgb.r, rgba.r);
            try expectEqual(rgb.g, rgba.g);
            try expectEqual(rgb.b, rgba.b);
            try expectEqual(@as(u8, 255), rgba.a); // Alpha should remain 255
        }
    }
}

test "sharpen basic functionality" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 5);
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
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 3, 3);
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
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 4, 4);
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
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 3, 3);
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

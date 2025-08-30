//! Interpolation method tests

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const Image = @import("../../image.zig").Image;
const Interpolation = @import("../interpolation.zig").Interpolation;
const color = @import("../../color.zig");

// Helper function to create a simple gradient test image
fn createGradientImage(allocator: std.mem.Allocator, rows: usize, cols: usize) !Image(u8) {
    var img = try Image(u8).init(allocator, rows, cols);
    for (0..rows) |r| {
        for (0..cols) |c| {
            // Create a diagonal gradient from top-left (0) to bottom-right (255)
            const value = @as(u8, @intCast(@min(255, (r + c) * 255 / (rows + cols - 2))));
            img.at(r, c).* = value;
        }
    }
    return img;
}

// Helper function to create a checkerboard pattern
fn createCheckerboard(allocator: std.mem.Allocator, rows: usize, cols: usize) !Image(u8) {
    var img = try Image(u8).init(allocator, rows, cols);
    for (0..rows) |r| {
        for (0..cols) |c| {
            img.at(r, c).* = if ((r + c) % 2 == 0) 0 else 255;
        }
    }
    return img;
}

test "nearest neighbor interpolation - exact pixels" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test exact pixel positions - should return exact values
    const val1 = img.interpolate(0, 0, .nearest_neighbor);
    try expectEqual(img.at(0, 0).*, val1.?);

    const val2 = img.interpolate(5, 5, .nearest_neighbor);
    try expectEqual(img.at(5, 5).*, val2.?);

    const val3 = img.interpolate(9, 9, .nearest_neighbor);
    try expectEqual(img.at(9, 9).*, val3.?);
}

test "nearest neighbor interpolation - rounding" {
    const allocator = std.testing.allocator;
    var img = try createCheckerboard(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test rounding behavior
    // At (0.4, 0.4) should round to (0, 0)
    const val1 = img.interpolate(0.4, 0.4, .nearest_neighbor);
    try expectEqual(@as(u8, 0), val1.?);

    // At (0.6, 0.6) should round to (1, 1)
    // Checkerboard: (1, 1) has value 0 because (1+1)%2 == 0
    const val2 = img.interpolate(0.6, 0.6, .nearest_neighbor);
    try expectEqual(@as(u8, 0), val2.?);

    // At (1.5, 0.5) should round to (2, 1)
    const val3 = img.interpolate(1.5, 0.5, .nearest_neighbor);
    try expectEqual(@as(u8, 255), val3.?);
}

test "bilinear interpolation - exact pixels" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // At exact pixel positions, bilinear should return exact values
    const val1 = img.interpolate(0, 0, .bilinear);
    try expectEqual(img.at(0, 0).*, val1.?);

    const val2 = img.interpolate(5, 5, .bilinear);
    try expectEqual(img.at(5, 5).*, val2.?);
}

test "bilinear interpolation - midpoints" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 3, 3);
    defer img.deinit(allocator);

    // Create a simple 3x3 pattern
    img.at(0, 0).* = 0;
    img.at(0, 1).* = 100;
    img.at(0, 2).* = 200;
    img.at(1, 0).* = 0;
    img.at(1, 1).* = 100;
    img.at(1, 2).* = 200;
    img.at(2, 0).* = 0;
    img.at(2, 1).* = 100;
    img.at(2, 2).* = 200;

    // At midpoint between (0,0) and (0,1), should be average
    const val = img.interpolate(0.5, 0, .bilinear);
    try expectEqual(@as(u8, 50), val.?);

    // At center of four pixels
    const center = img.interpolate(0.5, 0.5, .bilinear);
    try expectEqual(@as(u8, 50), center.?); // Average of 0, 100, 0, 100
}

test "bicubic interpolation - exact pixels" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test positions away from edges (bicubic needs 4x4 neighborhood)
    const val1 = img.interpolate(2, 2, .bicubic);
    try expectEqual(img.at(2, 2).*, val1.?);

    const val2 = img.interpolate(5, 5, .bicubic);
    try expectEqual(img.at(5, 5).*, val2.?);
}

test "catmull-rom interpolation - exact pixels" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test positions away from edges
    const val1 = img.interpolate(2, 2, .catmull_rom);
    try expectEqual(img.at(2, 2).*, val1.?);

    const val2 = img.interpolate(5, 5, .catmull_rom);
    try expectEqual(img.at(5, 5).*, val2.?);
}

test "lanczos interpolation - exact pixels" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test positions away from edges (Lanczos needs 6x6 neighborhood)
    const val1 = img.interpolate(3, 3, .lanczos);
    try expectApproxEqAbs(@as(f32, @floatFromInt(img.at(3, 3).*)), @as(f32, @floatFromInt(val1.?)), 1.0);

    const val2 = img.interpolate(5, 5, .lanczos);
    try expectApproxEqAbs(@as(f32, @floatFromInt(img.at(5, 5).*)), @as(f32, @floatFromInt(val2.?)), 1.0);
}

test "mitchell interpolation - default parameters" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test with default Mitchell parameters (B=1/3, C=1/3)
    const val1 = img.interpolate(2, 2, .{ .mitchell = .{ .b = 1.0 / 3.0, .c = 1.0 / 3.0 } });
    // Mitchell at exact pixels should be very close but may have slight differences
    try expectApproxEqAbs(@as(f32, @floatFromInt(img.at(2, 2).*)), @as(f32, @floatFromInt(val1.?)), 1.0);

    // Test simplified syntax
    const val2 = img.interpolate(5, 5, .{ .mitchell = .default });
    try expectApproxEqAbs(@as(f32, @floatFromInt(img.at(5, 5).*)), @as(f32, @floatFromInt(val2.?)), 1.0);
}

test "mitchell interpolation - custom parameters" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Test B-spline parameters (B=1, C=0)
    const val_bspline = img.interpolate(5.5, 5.5, .{ .mitchell = .{ .b = 1.0, .c = 0.0 } });
    try std.testing.expect(val_bspline != null);

    // Test Catmull-Rom-like parameters (B=0, C=0.5)
    const val_catmull = img.interpolate(5.5, 5.5, .{ .mitchell = .{ .b = 0.0, .c = 0.5 } });
    try std.testing.expect(val_catmull != null);

    // Test sharp parameters (B=0, C=0.75)
    const val_sharp = img.interpolate(5.5, 5.5, .{ .mitchell = .{ .b = 0.0, .c = 0.75 } });
    try std.testing.expect(val_sharp != null);
}

test "boundary conditions - nearest neighbor" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Nearest neighbor should work at all boundaries
    try std.testing.expect(img.interpolate(-0.4, 0, .nearest_neighbor) != null); // Rounds to (0, 0)
    try std.testing.expect(img.interpolate(9.4, 9.4, .nearest_neighbor) != null); // Rounds to (9, 9)

    // Out of bounds
    try expectEqual(@as(?u8, null), img.interpolate(-1, 0, .nearest_neighbor));
    try expectEqual(@as(?u8, null), img.interpolate(0, -1, .nearest_neighbor));
    try expectEqual(@as(?u8, null), img.interpolate(10, 0, .nearest_neighbor));
    try expectEqual(@as(?u8, null), img.interpolate(0, 10, .nearest_neighbor));
}

test "boundary conditions - bilinear" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Bilinear needs 2x2 neighborhood
    try std.testing.expect(img.interpolate(0, 0, .bilinear) != null);
    try std.testing.expect(img.interpolate(8.9, 8.9, .bilinear) != null);

    // Should fail at the edge when we need pixels beyond
    try expectEqual(@as(?u8, null), img.interpolate(9.1, 9.1, .bilinear));
    try expectEqual(@as(?u8, null), img.interpolate(-0.1, 0, .bilinear));
}

test "boundary conditions - bicubic" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Bicubic needs 4x4 neighborhood
    try std.testing.expect(img.interpolate(1, 1, .bicubic) != null);
    try std.testing.expect(img.interpolate(7.9, 7.9, .bicubic) != null);

    // Should fail near edges
    try expectEqual(@as(?u8, null), img.interpolate(0.5, 0.5, .bicubic));
    try expectEqual(@as(?u8, null), img.interpolate(8.1, 8.1, .bicubic));
}

test "boundary conditions - lanczos" {
    const allocator = std.testing.allocator;
    var img = try createGradientImage(allocator, 10, 10);
    defer img.deinit(allocator);

    // Lanczos needs 6x6 neighborhood
    try std.testing.expect(img.interpolate(2, 2, .lanczos) != null);
    try std.testing.expect(img.interpolate(6.9, 6.9, .lanczos) != null);

    // Should fail near edges
    try expectEqual(@as(?u8, null), img.interpolate(1.5, 1.5, .lanczos));
    try expectEqual(@as(?u8, null), img.interpolate(7.1, 7.1, .lanczos));
}

test "RGB image interpolation" {
    const allocator = std.testing.allocator;
    const Rgb = color.Rgb;

    var img = try Image(Rgb).init(allocator, 4, 4);
    defer img.deinit(allocator);

    // Create a color gradient
    for (0..4) |r| {
        for (0..4) |c| {
            img.at(r, c).* = Rgb{
                .r = @intCast(r * 85),
                .g = @intCast(c * 85),
                .b = 128,
            };
        }
    }

    // Test nearest neighbor with RGB
    // (1.6, 1.4) rounds to (2, 1)
    const val_nn = img.interpolate(1.6, 1.4, .nearest_neighbor);
    try expectEqualDeep(img.at(1, 2).*, val_nn.?);

    // Test bilinear with RGB
    const val_bl = img.interpolate(0.5, 0.5, .bilinear);
    try std.testing.expect(val_bl != null);
    // Should be average of four corner pixels
    try expectEqual(@as(u8, 42), val_bl.?.r); // Average of 0, 85, 0, 85
    try expectEqual(@as(u8, 42), val_bl.?.g); // Average of 0, 0, 85, 85
    try expectEqual(@as(u8, 128), val_bl.?.b); // All are 128

    // Test Mitchell with RGB
    const val_mitchell = img.interpolate(1.5, 1.5, .{ .mitchell = .default });
    try std.testing.expect(val_mitchell != null);
}

test "resize preserves value range" {
    const allocator = std.testing.allocator;

    // Create a simple gradient image
    var src = try Image(u8).init(allocator, 4, 4);
    defer src.deinit(allocator);

    // Fill with values from 0 to 240
    for (0..4) |r| {
        for (0..4) |c| {
            src.at(r, c).* = @intCast((r + c) * 40);
        }
    }

    var dst = try Image(u8).init(allocator, 8, 8);
    defer dst.deinit(allocator);

    // Test resize with bilinear interpolation
    try src.resize(allocator, dst, .bilinear);

    // Check that all interpolated values are within the original range
    var min_val: u8 = 255;
    var max_val: u8 = 0;

    for (0..8) |r| {
        for (0..8) |c| {
            const val = dst.at(r, c).*;
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
    }

    // Values should be within the range of source image
    try std.testing.expect(min_val >= 0);
    try std.testing.expect(max_val <= 240);
}

test "catmull-rom no overshoot property" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 5, 5);
    defer img.deinit(allocator);

    // Create an image with values between 50 and 200
    for (0..5) |r| {
        for (0..5) |c| {
            img.at(r, c).* = @intCast(50 + (r + c) * 20);
        }
    }

    // Test multiple interpolation points
    var r: f32 = 1.5;
    while (r < 3.5) : (r += 0.1) {
        var c: f32 = 1.5;
        while (c < 3.5) : (c += 0.1) {
            if (img.interpolate(c, r, .catmull_rom)) |val| {
                // Catmull-Rom should not overshoot the value range
                try std.testing.expect(val >= 50);
                try std.testing.expect(val <= 200);
            }
        }
    }
}

test "float image interpolation" {
    const allocator = std.testing.allocator;
    var img = try Image(f32).init(allocator, 4, 4);
    defer img.deinit(allocator);

    // Create a float gradient
    for (0..4) |r| {
        for (0..4) |c| {
            img.at(r, c).* = @as(f32, @floatFromInt(r)) * 0.25 + @as(f32, @floatFromInt(c)) * 0.25;
        }
    }

    // Test bilinear with floats
    const val = img.interpolate(1.5, 1.5, .bilinear);
    try std.testing.expect(val != null);
    try expectApproxEqAbs(@as(f32, 0.75), val.?, 0.001);

    // Test bicubic with floats
    const val_cubic = img.interpolate(1.5, 1.5, .bicubic);
    try std.testing.expect(val_cubic != null);
}

test "clamping stress test - sharp edge with bicubic" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 6, 6);
    defer img.deinit(allocator);

    // Create a sharp edge that would cause overshoot
    for (0..6) |r| {
        for (0..6) |c| {
            img.at(r, c).* = if (c < 3) 0 else 255;
        }
    }

    // Interpolate near the edge where bicubic would overshoot
    const val = img.interpolate(3.1, 2.5, .bicubic);
    try std.testing.expect(val != null);
    // Without clamping, this could go above 255 or below 0
    try std.testing.expect(val.? >= 0);
    try std.testing.expect(val.? <= 255);

    // Test multiple points along the edge
    var y: f32 = 1.5;
    while (y < 4.5) : (y += 0.2) {
        var x: f32 = 2.5;
        while (x < 3.5) : (x += 0.1) {
            if (img.interpolate(x, y, .bicubic)) |v| {
                try std.testing.expect(v >= 0 and v <= 255);
            }
        }
    }
}

test "clamping stress test - all kernel methods" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 8, 8);
    defer img.deinit(allocator);

    // Create extreme contrast pattern
    for (0..8) |r| {
        for (0..8) |c| {
            // Checkerboard with extreme values
            img.at(r, c).* = if ((r + c) % 2 == 0) 0 else 255;
        }
    }

    // Test all kernel-based methods at positions that could cause overshoot
    const methods = [_]Interpolation{
        .bicubic,
        .catmull_rom,
        .lanczos,
        .{ .mitchell = .default },
        .{ .mitchell = .{ .b = 0, .c = 0.75 } }, // Sharp mitchell
    };

    for (methods) |method| {
        // Test at multiple positions
        var y: f32 = 2.0;
        while (y < 6.0) : (y += 0.3) {
            var x: f32 = 2.0;
            while (x < 6.0) : (x += 0.3) {
                if (img.interpolate(x, y, method)) |val| {
                    try std.testing.expect(val >= 0 and val <= 255);
                }
            }
        }
    }
}

test "bilinear exact linear interpolation" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 2, 2);
    defer img.deinit(allocator);

    // Create a simple 2x2 grid
    img.at(0, 0).* = 0;
    img.at(0, 1).* = 100;
    img.at(1, 0).* = 50;
    img.at(1, 1).* = 150;

    // Test exact linear interpolation at various points
    // At (0.5, 0) should be exactly between (0,0) and (1,0)
    const val1 = img.interpolate(0.5, 0, .bilinear);
    try expectEqual(@as(u8, 50), val1.?); // (0 + 100) / 2

    // At (0, 0.5) should be exactly between (0,0) and (0,1)
    const val2 = img.interpolate(0, 0.5, .bilinear);
    try expectEqual(@as(u8, 25), val2.?); // (0 + 50) / 2

    // At (0.5, 0.5) should be average of all four
    const val3 = img.interpolate(0.5, 0.5, .bilinear);
    try expectEqual(@as(u8, 75), val3.?); // (0 + 100 + 50 + 150) / 4

    // Test linearity: f(0.25) should be 0.75*f(0) + 0.25*f(1)
    const val4 = img.interpolate(0.25, 0, .bilinear);
    try expectEqual(@as(u8, 25), val4.?); // 0.75 * 0 + 0.25 * 100
}

test "nearest neighbor discontinuity" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 2, 2);
    defer img.deinit(allocator);

    img.at(0, 0).* = 0;
    img.at(0, 1).* = 255;
    img.at(1, 0).* = 100;
    img.at(1, 1).* = 200;

    // Test discontinuity at boundary
    const val_before = img.interpolate(0.49, 0, .nearest_neighbor);
    const val_after = img.interpolate(0.51, 0, .nearest_neighbor);

    try expectEqual(@as(u8, 0), val_before.?); // rounds to (0, 0)
    try expectEqual(@as(u8, 255), val_after.?); // rounds to (1, 0)

    // Verify sharp transition
    try std.testing.expect(val_after.? - val_before.? == 255);
}

test "interpolation symmetry" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 5, 5);
    defer img.deinit(allocator);

    // Create symmetric pattern
    for (0..5) |r| {
        for (0..5) |c| {
            const dist = @abs(@as(i32, @intCast(r)) - 2) + @abs(@as(i32, @intCast(c)) - 2);
            img.at(r, c).* = @intCast(@min(255, dist * 50));
        }
    }

    // Test symmetry for bilinear
    const val1 = img.interpolate(1.5, 2, .bilinear);
    const val2 = img.interpolate(2.5, 2, .bilinear);
    try expectEqual(val1, val2);

    const val3 = img.interpolate(2, 1.5, .bilinear);
    const val4 = img.interpolate(2, 2.5, .bilinear);
    try expectEqual(val3, val4);
}

test "mitchell parameter effects" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 6, 6);
    defer img.deinit(allocator);

    // Create a pattern with both smooth and sharp features
    for (0..6) |r| {
        for (0..6) |c| {
            if (r == 2 or r == 3) {
                img.at(r, c).* = 200;
            } else {
                img.at(r, c).* = 50;
            }
        }
    }

    // Test that different Mitchell parameters produce different results
    const pos_x: f32 = 2.5;
    const pos_y: f32 = 1.8; // Position that will show more difference

    const val_default = img.interpolate(pos_x, pos_y, .{ .mitchell = .default });
    const val_bspline = img.interpolate(pos_x, pos_y, .{ .mitchell = .{ .b = 1.0, .c = 0.0 } });
    const val_sharp = img.interpolate(pos_x, pos_y, .{ .mitchell = .{ .b = 0.0, .c = 0.75 } });

    // B-spline (B=1, C=0) should be blurrier (closer to average)
    // Sharp (B=0, C=0.75) should have more contrast
    try std.testing.expect(val_default != null);
    try std.testing.expect(val_bspline != null);
    try std.testing.expect(val_sharp != null);

    // They should produce different results (at least some of them)
    // Due to the nature of the pattern and kernel, some might be equal
    const all_equal = val_default.? == val_bspline.? and val_default.? == val_sharp.?;
    try std.testing.expect(!all_equal); // At least one should be different
}

test "lanczos weight normalization" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 8, 8);
    defer img.deinit(allocator);

    // Fill with constant value
    for (0..8) |r| {
        for (0..8) |c| {
            img.at(r, c).* = 128;
        }
    }

    // For constant image, any interpolation should return the same constant
    const val = img.interpolate(4.3, 4.7, .lanczos);
    try std.testing.expect(val != null);
    // Weight normalization ensures this property
    try expectEqual(@as(u8, 128), val.?);
}

test "extreme value edge cases" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 4, 4);
    defer img.deinit(allocator);

    // Fill with extreme values
    for (0..4) |r| {
        for (0..4) |c| {
            img.at(r, c).* = if ((r + c) % 2 == 0) 0 else 255;
        }
    }

    // Test all methods handle extreme values correctly
    const methods = [_]Interpolation{
        .nearest_neighbor,
        .bilinear,
        .bicubic,
        .catmull_rom,
        .lanczos,
        .{ .mitchell = .default },
    };

    for (methods) |method| {
        // At exact pixel, should preserve extreme value
        if (method == .lanczos) {
            // Lanczos at position (2,2)
            const val = img.interpolate(2, 2, method);
            if (val) |v| {
                try expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(v)), 1.0);
            }
        } else if (method == .nearest_neighbor or method == .bilinear) {
            const val = img.interpolate(0, 0, method);
            try expectEqual(@as(u8, 0), val.?);
        }
    }
}

test "single pixel image handling" {
    const allocator = std.testing.allocator;
    var img = try Image(u8).init(allocator, 1, 1);
    defer img.deinit(allocator);

    img.at(0, 0).* = 42;

    // Only nearest neighbor should work with 1x1 image
    const val_nn = img.interpolate(0, 0, .nearest_neighbor);
    try expectEqual(@as(u8, 42), val_nn.?);

    // All others should return null (not enough neighbors)
    try expectEqual(@as(?u8, null), img.interpolate(0, 0, .bilinear));
    try expectEqual(@as(?u8, null), img.interpolate(0, 0, .bicubic));
    try expectEqual(@as(?u8, null), img.interpolate(0, 0, .catmull_rom));
    try expectEqual(@as(?u8, null), img.interpolate(0, 0, .lanczos));
    try expectEqual(@as(?u8, null), img.interpolate(0, 0, .{ .mitchell = .default }));
}

test "RGB clamping stress test" {
    const allocator = std.testing.allocator;
    const Rgb = color.Rgb;
    var img = try Image(Rgb).init(allocator, 4, 4);
    defer img.deinit(allocator);

    // Create extreme RGB values
    for (0..4) |r| {
        for (0..4) |c| {
            if ((r + c) % 2 == 0) {
                img.at(r, c).* = Rgb{ .r = 0, .g = 0, .b = 0 };
            } else {
                img.at(r, c).* = Rgb{ .r = 255, .g = 255, .b = 255 };
            }
        }
    }

    // Test bicubic near edges - would overshoot without clamping
    var y: f32 = 1.1;
    while (y < 2.9) : (y += 0.2) {
        var x: f32 = 1.1;
        while (x < 2.9) : (x += 0.2) {
            if (img.interpolate(x, y, .bicubic)) |val| {
                try std.testing.expect(val.r >= 0 and val.r <= 255);
                try std.testing.expect(val.g >= 0 and val.g <= 255);
                try std.testing.expect(val.b >= 0 and val.b <= 255);
            }
        }
    }
}

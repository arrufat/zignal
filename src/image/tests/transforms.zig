//! Transform and geometry tests

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const Image = @import("../../image.zig").Image;
const color = @import("../../color.zig");
const Rectangle = @import("../../geometry.zig").Rectangle;

test "getRectangle" {
    var image: Image(color.Rgba) = try .init(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    const rect = image.getRectangle();
    try expectEqual(rect.width(), image.cols);
    try expectEqual(rect.height(), image.rows);
}

test "copy function with views" {
    var image: Image(u8) = try .init(std.testing.allocator, 5, 7);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    // Create a view
    const view = image.view(.{ .l = 1, .t = 1, .r = 4, .b = 3 });

    // Copy view to new image
    var copied: Image(u8) = try .init(std.testing.allocator, view.rows, view.cols);
    defer copied.deinit(std.testing.allocator);

    view.copy(copied);

    // Verify copied data matches view
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, copied.at(r, c).*);
        }
    }

    // Test copy from regular image to view
    var target: Image(u8) = try .init(std.testing.allocator, 6, 8);
    defer target.deinit(std.testing.allocator);

    // Fill target with different pattern
    for (0..target.rows) |r| {
        for (0..target.cols) |c| {
            target.at(r, c).* = 99;
        }
    }

    // Create view of target
    const target_view = target.view(.{ .l = 2, .t = 2, .r = 5, .b = 4 });

    // Copy original view to target view
    view.copy(target_view);

    // Verify the view area was copied correctly
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, target_view.at(r, c).*);
        }
    }

    // Verify areas outside the view weren't touched
    try expectEqual(@as(u8, 99), target.at(0, 0).*);
    try expectEqual(@as(u8, 99), target.at(5, 7).*);
}

test "copy function in-place behavior" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c);
        }
    }

    // Store original values
    var original_values: [9]u8 = undefined;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            original_values[r * 3 + c] = image.at(r, c).*;
        }
    }

    // In-place copy should be no-op
    image.copy(image);

    // Values should be unchanged
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(original_values[r * 3 + c], image.at(r, c).*);
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
    try expectEqual(view.cols, 8);
    try expectEqual(view.rows, 10);
    try expectEqualDeep(Rectangle(usize){ .l = 0, .t = 0, .r = 8, .b = 10 }, view.getRectangle());
}

test "view with getRectangle returns full image" {
    var image: Image(u8) = try .init(std.testing.allocator, 100, 200);
    defer image.deinit(std.testing.allocator);

    // Fill image with test pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast((r * 7 + c * 3) % 256);
        }
    }

    // Get view of the entire image using getRectangle()
    const full_rect = image.getRectangle();
    const full_view = image.view(full_rect);

    // Verify the view has same dimensions as original
    try expectEqual(image.rows, full_view.rows);
    try expectEqual(image.cols, full_view.cols);

    // When view covers entire image from (0,0), it has same stride as cols
    // so isContiguous() returns true (this is expected behavior)
    try expectEqual(true, full_view.isContiguous());

    // Verify all pixels match
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, full_view.at(r, c).*);
        }
    }

    // Verify modifying the view affects the original
    full_view.at(50, 100).* = 255;
    try expectEqual(@as(u8, 255), image.at(50, 100).*);

    // Verify getRectangle() returns expected bounds
    try expectEqual(@as(usize, 0), full_rect.l);
    try expectEqual(@as(usize, 0), full_rect.t);
    try expectEqual(@as(usize, 200), full_rect.r);
    try expectEqual(@as(usize, 100), full_rect.b);
}

test "rotate orthogonal fast paths" {
    var image: Image(u8) = try .init(std.testing.allocator, 3, 4);
    defer image.deinit(std.testing.allocator);

    // Create a pattern to verify correct rotation
    image.at(0, 0).* = 1;
    image.at(0, 1).* = 2;
    image.at(0, 2).* = 3;
    image.at(0, 3).* = 4;
    image.at(1, 0).* = 5;
    image.at(1, 1).* = 6;
    image.at(1, 2).* = 7;
    image.at(1, 3).* = 8;
    image.at(2, 0).* = 9;
    image.at(2, 1).* = 10;
    image.at(2, 2).* = 11;
    image.at(2, 3).* = 12;

    // Test 0 degree rotation
    var rotated_0: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, 0, .bilinear, &rotated_0);
    defer rotated_0.deinit(std.testing.allocator);
    try expectEqual(@as(u8, 1), rotated_0.at(0, 0).*);

    // Test 90 degree rotation
    var rotated_90: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, std.math.pi / 2.0, .bilinear, &rotated_90);
    defer rotated_90.deinit(std.testing.allocator);
    // After 90° rotation, top-left becomes bottom-left
    // Original (0,0)=1 should be at (2,0) in rotated image (accounting for centering)

    // Test 180 degree rotation
    var rotated_180: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, std.math.pi, .bilinear, &rotated_180);
    defer rotated_180.deinit(std.testing.allocator);

    // Test 270 degree rotation
    var rotated_270: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, 3.0 * std.math.pi / 2.0, .bilinear, &rotated_270);
    defer rotated_270.deinit(std.testing.allocator);

    // Verify dimensions are as expected
    try expectEqual(@as(usize, 3), rotated_0.rows);
    try expectEqual(@as(usize, 4), rotated_0.cols);
    // 90° rotation should have exact swapped dimensions
    try expectEqual(@as(usize, 4), rotated_90.rows);
    try expectEqual(@as(usize, 3), rotated_90.cols);
    // 180° rotation should have same dimensions as original
    try expectEqual(@as(usize, 3), rotated_180.rows);
    try expectEqual(@as(usize, 4), rotated_180.cols);
    // 270° rotation should have exact swapped dimensions
    try expectEqual(@as(usize, 4), rotated_270.rows);
    try expectEqual(@as(usize, 3), rotated_270.cols);
}

test "rotate arbitrary angle" {
    var image: Image(u8) = try .init(std.testing.allocator, 10, 10);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if ((r + c) % 2 == 0) 255 else 0;
        }
    }

    // Test 45 degree rotation
    var rotated: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, std.math.pi / 4.0, .bilinear, &rotated);
    defer rotated.deinit(std.testing.allocator);

    // Should be larger than original to fit rotated content
    try expectEqual(rotated.rows > 10, true);
    try expectEqual(rotated.cols > 10, true);
}

test "extract rotated rectangle basic and 90deg" {
    const allocator = std.testing.allocator;
    var image: Image(u8) = try .init(allocator, 5, 5);
    defer image.deinit(allocator);

    // Fill with simple row*10 + col pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    // Define a 3x3 square from (1,1) to (3,3)
    const rect = Rectangle(f32){ .l = 1, .t = 1, .r = 3, .b = 3 };

    // Output 3x3 buffer
    var out0: Image(u8) = try .init(allocator, 3, 3);
    defer out0.deinit(allocator);

    // Angle 0: should match the submatrix directly
    image.extract(rect, 0.0, out0, .nearest_neighbor);

    try expectEqual(@as(u8, 11), out0.at(0, 0).*);
    try expectEqual(@as(u8, 12), out0.at(0, 1).*);
    try expectEqual(@as(u8, 13), out0.at(0, 2).*);
    try expectEqual(@as(u8, 21), out0.at(1, 0).*);
    try expectEqual(@as(u8, 22), out0.at(1, 1).*);
    try expectEqual(@as(u8, 23), out0.at(1, 2).*);
    try expectEqual(@as(u8, 31), out0.at(2, 0).*);
    try expectEqual(@as(u8, 32), out0.at(2, 1).*);
    try expectEqual(@as(u8, 33), out0.at(2, 2).*);

    // Angle 90 degrees CCW: should be rotated version of the submatrix
    var out90: Image(u8) = try .init(allocator, 3, 3);
    defer out90.deinit(allocator);

    image.extract(rect, std.math.pi / 2.0, out90, .nearest_neighbor);

    try expectEqual(@as(u8, 13), out90.at(0, 0).*);
    try expectEqual(@as(u8, 23), out90.at(0, 1).*);
    try expectEqual(@as(u8, 33), out90.at(0, 2).*);
    try expectEqual(@as(u8, 12), out90.at(1, 0).*);
    try expectEqual(@as(u8, 22), out90.at(1, 1).*);
    try expectEqual(@as(u8, 32), out90.at(1, 2).*);
    try expectEqual(@as(u8, 11), out90.at(2, 0).*);
    try expectEqual(@as(u8, 21), out90.at(2, 1).*);
    try expectEqual(@as(u8, 31), out90.at(2, 2).*);
}

test "extract single-pixel axis handling centers correctly" {
    const allocator = std.testing.allocator;
    var image: Image(u8) = try .init(allocator, 5, 5);
    defer image.deinit(allocator);

    // Fill pattern row*10 + col
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    const rect = Rectangle(f32){ .l = 1, .t = 1, .r = 3, .b = 3 }; // 3x3

    // 1x1 output should sample rectangle center -> source (2,2) => 22
    var out1: Image(u8) = try .init(allocator, 1, 1);
    defer out1.deinit(allocator);
    image.extract(rect, 0.0, out1, .nearest_neighbor);
    try expectEqual(@as(u8, 22), out1.at(0, 0).*);

    // 1x3: rows==1 should sample center row (y=2), cols span left-to-right
    var out_row1: Image(u8) = try .init(allocator, 1, 3);
    defer out_row1.deinit(allocator);
    image.extract(rect, 0.0, out_row1, .nearest_neighbor);
    try expectEqual(@as(u8, 21), out_row1.at(0, 0).*);
    try expectEqual(@as(u8, 22), out_row1.at(0, 1).*);
    try expectEqual(@as(u8, 23), out_row1.at(0, 2).*);

    // 3x1: cols==1 should sample center col (x=2), rows span top-to-bottom
    var out_col1: Image(u8) = try .init(allocator, 3, 1);
    defer out_col1.deinit(allocator);
    image.extract(rect, 0.0, out_col1, .nearest_neighbor);
    try expectEqual(@as(u8, 12), out_col1.at(0, 0).*);
    try expectEqual(@as(u8, 22), out_col1.at(1, 0).*);
    try expectEqual(@as(u8, 32), out_col1.at(2, 0).*);
}

test "insert and extract inverse relationship" {
    const allocator = std.testing.allocator;

    // Create source with gradient pattern
    var source = try Image(u8).init(allocator, 64, 64);
    defer source.deinit(allocator);
    for (0..source.rows) |r| {
        for (0..source.cols) |c| {
            source.at(r, c).* = @intCast((r + c) % 256);
        }
    }

    // Test cases: aligned, rotated, scaled
    const cases = [_]struct {
        rect: Rectangle(f32),
        angle: f32,
        size: usize,
        method: @import("../../root.zig").Interpolation,
    }{
        .{ .rect = Rectangle(f32).init(10, 10, 50, 50), .angle = 0, .size = 40, .method = .bilinear },
        .{ .rect = Rectangle(f32).init(15, 15, 45, 45), .angle = std.math.pi / 4.0, .size = 30, .method = .bilinear },
        .{ .rect = Rectangle(f32).init(20, 20, 40, 40), .angle = 0, .size = 40, .method = .bicubic }, // 2x upscale
    };

    for (cases) |tc| {
        // Extract region
        var extracted = try Image(u8).init(allocator, tc.size, tc.size);
        defer extracted.deinit(allocator);
        source.extract(tc.rect, tc.angle, extracted, tc.method);

        // Insert back into blank canvas
        var canvas = try Image(u8).init(allocator, 64, 64);
        defer canvas.deinit(allocator);
        @memset(canvas.data, 0);
        canvas.insert(extracted, tc.rect, tc.angle, tc.method);

        // Check reconstruction error in center region
        const cx = (tc.rect.l + tc.rect.r) * 0.5;
        const cy = (tc.rect.t + tc.rect.b) * 0.5;
        const check_size = @min(tc.rect.width(), tc.rect.height()) * 0.6;

        var total_error: u32 = 0;
        var pixel_count: u32 = 0;

        const start_r = @as(usize, @intFromFloat(cy - check_size / 2));
        const end_r = @as(usize, @intFromFloat(cy + check_size / 2));
        const start_c = @as(usize, @intFromFloat(cx - check_size / 2));
        const end_c = @as(usize, @intFromFloat(cx + check_size / 2));

        for (start_r..end_r) |r| {
            for (start_c..end_c) |c| {
                const diff = if (source.at(r, c).* > canvas.at(r, c).*)
                    source.at(r, c).* - canvas.at(r, c).*
                else
                    canvas.at(r, c).* - source.at(r, c).*;
                total_error += diff;
                pixel_count += 1;
            }
        }

        const avg_error = @as(f32, @floatFromInt(total_error)) / @as(f32, @floatFromInt(pixel_count));
        const tolerance: f32 = if (tc.method == .nearest_neighbor) 10 else 25;
        try std.testing.expect(avg_error < tolerance);
    }
}

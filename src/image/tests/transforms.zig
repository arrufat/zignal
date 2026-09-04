//! Transform and geometry tests

const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const color = @import("../../color.zig");
const Rectangle = @import("../../geometry.zig").Rectangle;
const Image = @import("../../image.zig").Image;
const Interpolation = @import("../../root.zig").Interpolation;
const parallel = @import("../../parallel.zig");

const Rgb = color.Rgb(u8);
const Rgba = color.Rgba(u8);

test "getRectangle" {
    var image: Image(Rgba) = try .init(std.testing.allocator, 21, 13);
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
    var image: Image(Rgba) = try .init(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    const rect: Rectangle(u32) = .{ .l = 0, .t = 0, .r = 8, .b = 10 };
    const view = image.view(rect);
    try expectEqual(view.isContiguous(), false);
    try expectEqual(image.isContiguous(), true);
    try expectEqual(view.cols, 8);
    try expectEqual(view.rows, 10);
    try expectEqualDeep(Rectangle(u32){ .l = 0, .t = 0, .r = 8, .b = 10 }, view.getRectangle());
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
    try expectEqual(@as(u32, 0), full_rect.l);
    try expectEqual(@as(u32, 0), full_rect.t);
    try expectEqual(@as(u32, 200), full_rect.r);
    try expectEqual(@as(u32, 100), full_rect.b);
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
    var rotated_0 = try image.rotate(io, std.testing.allocator, 0, .bilinear, .mirror);
    defer rotated_0.deinit(std.testing.allocator);
    try expectEqual(@as(u8, 1), rotated_0.at(0, 0).*);

    // Test 90 degree rotation
    var rotated_90 = try image.rotate(io, std.testing.allocator, std.math.pi / 2.0, .bilinear, .mirror);
    defer rotated_90.deinit(std.testing.allocator);
    // After 90° rotation, top-left becomes bottom-left
    // Original (0,0)=1 should be at (2,0) in rotated image (accounting for centering)

    // Test 180 degree rotation
    var rotated_180 = try image.rotate(io, std.testing.allocator, std.math.pi, .bilinear, .mirror);
    defer rotated_180.deinit(std.testing.allocator);

    // Test 270 degree rotation
    var rotated_270 = try image.rotate(io, std.testing.allocator, 3.0 * std.math.pi / 2.0, .bilinear, .mirror);
    defer rotated_270.deinit(std.testing.allocator);

    // Verify dimensions are as expected
    try expectEqual(@as(u32, 3), rotated_0.rows);
    try expectEqual(@as(u32, 4), rotated_0.cols);
    // 90° rotation should have exact swapped dimensions
    try expectEqual(@as(u32, 4), rotated_90.rows);
    try expectEqual(@as(u32, 3), rotated_90.cols);
    // 180° rotation should have same dimensions as original
    try expectEqual(@as(u32, 3), rotated_180.rows);
    try expectEqual(@as(u32, 4), rotated_180.cols);
    // 270° rotation should have exact swapped dimensions
    try expectEqual(@as(u32, 4), rotated_270.rows);
    try expectEqual(@as(u32, 3), rotated_270.cols);
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
    var rotated = try image.rotate(io, std.testing.allocator, std.math.pi / 4.0, .bilinear, .mirror);
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

    // The 3x3 block of pixels 1..3: rects are half-open, so r = b = 4.
    const rect = Rectangle(f32){ .l = 1, .t = 1, .r = 4, .b = 4 };

    // Output 3x3 buffer
    var out0: Image(u8) = try .init(allocator, 3, 3);
    defer out0.deinit(allocator);

    // Angle 0: should match the submatrix directly
    image.extract(io, out0, rect, 0.0, .nearest, .mirror);

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

    image.extract(io, out90, rect, std.math.pi / 2.0, .nearest, .mirror);

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

    const rect = Rectangle(f32){ .l = 1, .t = 1, .r = 4, .b = 4 }; // pixels 1..3

    // 1x1 output should sample rectangle center -> source (2,2) => 22
    var out1: Image(u8) = try .init(allocator, 1, 1);
    defer out1.deinit(allocator);
    image.extract(io, out1, rect, 0.0, .nearest, .mirror);
    try expectEqual(@as(u8, 22), out1.at(0, 0).*);

    // 1x3: rows==1 should sample center row (y=2), cols span left-to-right
    var out_row1: Image(u8) = try .init(allocator, 1, 3);
    defer out_row1.deinit(allocator);
    image.extract(io, out_row1, rect, 0.0, .nearest, .mirror);
    try expectEqual(@as(u8, 21), out_row1.at(0, 0).*);
    try expectEqual(@as(u8, 22), out_row1.at(0, 1).*);
    try expectEqual(@as(u8, 23), out_row1.at(0, 2).*);

    // 3x1: cols==1 should sample center col (x=2), rows span top-to-bottom
    var out_col1: Image(u8) = try .init(allocator, 3, 1);
    defer out_col1.deinit(allocator);
    image.extract(io, out_col1, rect, 0.0, .nearest, .mirror);
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
        size: u32,
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
        source.extract(io, extracted, tc.rect, tc.angle, tc.method, .mirror);

        // Insert back into blank canvas
        var canvas = try Image(u8).init(allocator, 64, 64);
        defer canvas.deinit(allocator);
        @memset(canvas.data, 0);
        canvas.insert(io, extracted, tc.rect, tc.angle, tc.method, color.Blending.none);

        // Check reconstruction error in center region
        const cx = (tc.rect.l + tc.rect.r) * 0.5;
        const cy = (tc.rect.t + tc.rect.b) * 0.5;
        const check_size = @min(tc.rect.width(), tc.rect.height()) * 0.6;

        var total_error: u32 = 0;
        var pixel_count: u32 = 0;
        const start_r: usize = @trunc(cy - check_size / 2);
        const end_r: usize = @trunc(cy + check_size / 2);
        const start_c: usize = @trunc(cx - check_size / 2);
        const end_c: usize = @trunc(cx + check_size / 2);

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
        const tolerance: f32 = if (tc.method == .nearest) 10 else 25;
        try std.testing.expect(avg_error < tolerance);
    }
}

test "insert applies blending when requested" {
    const allocator = std.testing.allocator;

    var dest = try Image(Rgba).init(allocator, 1, 1);
    defer dest.deinit(allocator);
    const base = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    dest.at(0, 0).* = base;

    var source = try Image(Rgba).init(allocator, 1, 1);
    defer source.deinit(allocator);
    const overlay = Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 };
    source.at(0, 0).* = overlay;

    const rect = Rectangle(f32).init(0, 0, 1, 1);

    // Without a blend mode the pixel should be copied directly.
    dest.insert(io, source, rect, 0.0, Interpolation.nearest, color.Blending.none);
    try expectEqualDeep(overlay, dest.at(0, 0).*);

    // Reset destination pixel and apply blending.
    dest.at(0, 0).* = base;
    const expected = base.blend(overlay, color.Blending.normal);
    dest.insert(io, source, rect, 0.0, Interpolation.nearest, color.Blending.normal);
    try expectEqualDeep(expected, dest.at(0, 0).*);
}

test "extract from empty image regression" {
    const allocator = std.testing.allocator;
    var empty = try Image(u8).init(allocator, 0, 0);
    defer empty.deinit(allocator);

    var out = try Image(u8).init(allocator, 2, 2);
    defer out.deinit(allocator);

    const rect = Rectangle(f32).init(0, 0, 2, 2);

    // Should not panic with REPLICATE
    empty.extract(io, out, rect, 0.0, .nearest, .replicate);
    try expectEqual(@as(u8, 0), out.at(0, 0).*);

    // Should not panic with WRAP
    empty.extract(io, out, rect, 0.0, .nearest, .wrap);
    try expectEqual(@as(u8, 0), out.at(0, 0).*);
}

test "flipLeftRight" {
    var data = [_]u8{
        1, 2, 3,
        4, 5, 6,
    };
    var image = Image(u8).initFromSlice(2, 3, &data);

    image.flipLeftRight(io);
    const expected = [_]u8{
        3, 2, 1,
        6, 5, 4,
    };
    try expectEqualDeep(expected, data);
}

test "flipTopBottom" {
    var data = [_]u8{
        1, 2,
        3, 4,
        5, 6,
    };
    var image = Image(u8).initFromSlice(3, 2, &data);
    image.flipTopBottom(io);
    const expected = [_]u8{
        5, 6,
        3, 4,
        1, 2,
    };
    try expectEqualDeep(expected, data);
}

test "insert with a rectangle outside the image or a NaN angle is a no-op" {
    const allocator = std.testing.allocator;
    var dest = try Image(u8).init(allocator, 10, 10);
    defer dest.deinit(allocator);
    dest.fill(0);
    var source = try Image(u8).init(allocator, 4, 4);
    defer source.deinit(allocator);
    source.fill(255);
    dest.insert(io, source, .{ .l = -20, .t = -20, .r = -10, .b = -10 }, 0.3, .bilinear, color.Blending.none);
    dest.insert(io, source, .{ .l = 2, .t = 2, .r = 6, .b = 6 }, std.math.nan(f32), .bilinear, color.Blending.none);
    for (dest.data) |px| try std.testing.expectEqual(@as(u8, 0), px);
}

test "extract, crop and insert agree on the half-open rect" {
    const allocator = std.testing.allocator;
    var image: Image(u8) = try .init(allocator, 6, 7);
    defer image.deinit(allocator);
    for (0..image.rows) |r| for (0..image.cols) |c| {
        image.at(r, c).* = @intCast(r * 10 + c);
    };
    const rect = Rectangle(f32){ .l = 2, .t = 1, .r = 5, .b = 4 }; // pixels 2..4 × 1..3

    var cropped = try image.crop(io, allocator, rect);
    defer cropped.deinit(allocator);
    try expectEqual(@as(u32, 3), cropped.rows);
    try expectEqual(@as(u32, 3), cropped.cols);

    // A hair of rotation forces the resampling path; it must land on the same pixels.
    var extracted: Image(u8) = try .init(allocator, 3, 3);
    defer extracted.deinit(allocator);
    image.extract(io, extracted, rect, 1e-5, .nearest, .zero);
    try std.testing.expectEqualSlices(u8, cropped.data, extracted.data);

    // The whole image through the resampling path is the identity.
    var whole: Image(u8) = try .init(allocator, 6, 7);
    defer whole.deinit(allocator);
    const full: Rectangle(f32) = .{ .l = 0, .t = 0, .r = 7, .b = 6 };
    image.extract(io, whole, full, 1e-5, .nearest, .zero);
    try std.testing.expectEqualSlices(u8, image.data, whole.data);

    // Inserting the crop back through the resampling path touches exactly the rect.
    var dest: Image(u8) = try .init(allocator, 6, 7);
    defer dest.deinit(allocator);
    dest.fill(255);
    dest.insert(io, cropped, rect, 1e-5, .nearest, color.Blending.none);
    for (0..dest.rows) |r| for (0..dest.cols) |c| {
        const inside = r >= 1 and r < 4 and c >= 2 and c < 5;
        try expectEqual(if (inside) image.at(r, c).* else 255, dest.at(r, c).*);
    };
}

// Every banded transform must produce the same bytes on a thread pool as serially.
test "transforms are identical on a thread pool" {
    const allocator = std.testing.allocator;
    var pool: std.Io.Threaded = .init(allocator, .{});
    defer pool.deinit();
    const pool_io = pool.io();
    const SimilarityTransform = @import("../../geometry.zig").SimilarityTransform;
    const Point = @import("../../geometry/Point.zig").Point;

    var prng = std.Random.DefaultPrng.init(0x7ea);
    const random = prng.random();

    // Every output is at least 64 K pixels, the floor for two bands (src/parallel.zig); the smallest
    // is the 200x330 downscale, and the resize row pass bands on (src rows, dst cols).
    try std.testing.expect(parallel.bandCount(200, 330) >= 2);
    try std.testing.expect(parallel.bandCount(300, 330) >= 2);

    inline for ([_]type{ u8, f32, Rgb }) |T| {
        var src: Image(T) = try .init(allocator, 300, 400);
        defer src.deinit(allocator);
        for (src.data) |*px| px.* = switch (T) {
            u8 => random.int(u8),
            f32 => 255 * random.float(f32),
            else => .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) },
        };

        const Check = struct {
            fn same(a: Image(T), b: Image(T)) !void {
                try std.testing.expectEqualSlices(T, a.data, b.data);
            }
        };

        // Resize up and down with every method (Rgb takes the u8 plane path, the rest the generic one).
        const methods = [_]Interpolation{ .nearest, .bilinear, .bicubic, .catmull_rom, .{ .mitchell = .default }, .lanczos };
        for (methods) |method| {
            for ([_][2]u32{ .{ 400, 560 }, .{ 200, 330 } }) |shape| {
                var a: Image(T) = try .init(allocator, shape[0], shape[1]);
                defer a.deinit(allocator);
                var b: Image(T) = try .init(allocator, shape[0], shape[1]);
                defer b.deinit(allocator);
                src.resize(io, allocator, a, method);
                src.resize(pool_io, allocator, b, method);
                try Check.same(a, b);
            }
        }

        var rot_a: Image(T) = try .init(allocator, 300, 400);
        defer rot_a.deinit(allocator);
        var rot_b: Image(T) = try .init(allocator, 300, 400);
        defer rot_b.deinit(allocator);
        src.rotateInto(io, rot_a, 0.5, .bilinear, .mirror);
        src.rotateInto(pool_io, rot_b, 0.5, .bilinear, .mirror);
        try Check.same(rot_a, rot_b);

        const from = [_]Point(2, f32){ .init(.{ 0, 0 }), .init(.{ 100, 0 }), .init(.{ 0, 100 }) };
        const to = [_]Point(2, f32){ .init(.{ 10, 20 }), .init(.{ 90, 35 }), .init(.{ -5, 110 }) };
        const transform = try SimilarityTransform(f32).init(&from, &to);
        var warp_a: Image(T) = try .init(allocator, 300, 400);
        defer warp_a.deinit(allocator);
        var warp_b: Image(T) = try .init(allocator, 300, 400);
        defer warp_b.deinit(allocator);
        src.warp(io, warp_a, transform, .bicubic);
        src.warp(pool_io, warp_b, transform, .bicubic);
        try Check.same(warp_a, warp_b);

        var ext_a: Image(T) = try .init(allocator, 300, 300);
        defer ext_a.deinit(allocator);
        var ext_b: Image(T) = try .init(allocator, 300, 300);
        defer ext_b.deinit(allocator);
        const rect: Rectangle(f32) = .init(50, 40, 350, 300);
        src.extract(io, ext_a, rect, 0.3, .bilinear, .zero);
        src.extract(pool_io, ext_b, rect, 0.3, .bilinear, .zero);
        try Check.same(ext_a, ext_b);

        // Flips: both back to back restore the image, so the pool pass runs on the same bytes.
        var flip_a: Image(T) = try .initLike(allocator, src);
        defer flip_a.deinit(allocator);
        var flip_b: Image(T) = try .initLike(allocator, src);
        defer flip_b.deinit(allocator);
        src.copy(flip_a);
        src.copy(flip_b);
        flip_a.flipLeftRight(io);
        flip_b.flipLeftRight(pool_io);
        try Check.same(flip_a, flip_b);
        flip_a.flipTopBottom(io);
        flip_b.flipTopBottom(pool_io);
        try Check.same(flip_a, flip_b);

        // Insert: the axis-aligned copy path and the rotated resampling path.
        var ins_a: Image(T) = try .init(allocator, 400, 500);
        defer ins_a.deinit(allocator);
        var ins_b: Image(T) = try .init(allocator, 400, 500);
        defer ins_b.deinit(allocator);
        for (ins_a.data, ins_b.data) |*a, *b| {
            a.* = std.mem.zeroes(T);
            b.* = std.mem.zeroes(T);
        }
        ins_a.insert(io, src, .init(30, 20, 430, 320), 0, .nearest, .none);
        ins_b.insert(pool_io, src, .init(30, 20, 430, 320), 0, .nearest, .none);
        try Check.same(ins_a, ins_b);
        ins_a.insert(io, src, .init(60, 50, 360, 270), 0.4, .bilinear, .none);
        ins_b.insert(pool_io, src, .init(60, 50, 360, 270), 0.4, .bilinear, .none);
        try Check.same(ins_a, ins_b);
    }

    // convert: Rgb -> u8 and u8 -> Rgb.
    var rgb: Image(Rgb) = try .init(allocator, 300, 400);
    defer rgb.deinit(allocator);
    random.bytes(std.mem.sliceAsBytes(rgb.data));
    var gray_a: Image(u8) = try .init(allocator, 300, 400);
    defer gray_a.deinit(allocator);
    var gray_b: Image(u8) = try .init(allocator, 300, 400);
    defer gray_b.deinit(allocator);
    rgb.convertInto(io, u8, gray_a);
    rgb.convertInto(pool_io, u8, gray_b);
    try std.testing.expectEqualSlices(u8, gray_a.data, gray_b.data);
    var back_a: Image(Rgb) = try .initLike(allocator, rgb);
    defer back_a.deinit(allocator);
    var back_b: Image(Rgb) = try .initLike(allocator, rgb);
    defer back_b.deinit(allocator);
    gray_a.convertInto(io, Rgb, back_a);
    gray_a.convertInto(pool_io, Rgb, back_b);
    try std.testing.expectEqualSlices(Rgb, back_a.data, back_b.data);
}

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const Rgba = @import("../../color.zig").Rgba;
const Rectangle = @import("../../geometry.zig").Rectangle;
const Point = @import("../../geometry/Point.zig").Point;
const Image = @import("../../image.zig").Image;
const Canvas = @import("../Canvas.zig").Canvas;

test "line endpoints are connected" {
    const allocator = testing.allocator;
    const width = 100;
    const height = 100;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    // Fill with white
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    const canvas: Canvas(Rgba) = .init(allocator, img);
    const color: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test various line directions
    const test_cases = [_]struct { p1: Point(2, f32), p2: Point(2, f32) }{
        .{ .p1 = .init(.{ 10, 10 }), .p2 = .init(.{ 90, 10 }) }, // horizontal
        .{ .p1 = .init(.{ 10, 10 }), .p2 = .init(.{ 10, 90 }) }, // vertical
        .{ .p1 = .init(.{ 10, 10 }), .p2 = .init(.{ 90, 90 }) }, // diagonal
        .{ .p1 = .init(.{ 90, 10 }), .p2 = .init(.{ 10, 90 }) }, // reverse diagonal
    };

    for (test_cases) |tc| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.drawLine(tc.p1, tc.p2, color, 1, .fast);

        // Check that endpoints are set (or very close)
        // At least one pixel near each endpoint should be black
        var p1_found = false;
        var p2_found = false;

        // Check 3x3 area around endpoints
        for (0..3) |dy| {
            for (0..3) |dx| {
                const y1 = @as(i32, @intFromFloat(tc.p1.y())) + @as(i32, @intCast(dy)) - 1;
                const x1 = @as(i32, @intFromFloat(tc.p1.x())) + @as(i32, @intCast(dx)) - 1;
                const y2 = @as(i32, @intFromFloat(tc.p2.y())) + @as(i32, @intCast(dy)) - 1;
                const x2 = @as(i32, @intFromFloat(tc.p2.x())) + @as(i32, @intCast(dx)) - 1;

                if (y1 >= 0 and y1 < height and x1 >= 0 and x1 < width) {
                    const idx1 = @as(usize, @intCast(y1)) * width + @as(usize, @intCast(x1));
                    if (img.data[idx1].r == 0) p1_found = true;
                }

                if (y2 >= 0 and y2 < height and x2 >= 0 and x2 < width) {
                    const idx2 = @as(usize, @intCast(y2)) * width + @as(usize, @intCast(x2));
                    if (img.data[idx2].r == 0) p2_found = true;
                }
            }
        }

        try expect(p1_found);
        try expect(p2_found);
    }
}

test "thick lines have correct width" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    const canvas: Canvas(Rgba) = .init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test different line widths
    const line_widths = [_]usize{ 1, 3, 5, 10, 20 };

    for (line_widths) |line_width| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        // Draw horizontal line in the middle
        const y = @as(f32, @floatFromInt(height / 2));
        canvas.drawLine(.init(.{ 50, y }), .init(.{ 150, y }), color, line_width, .fast);

        // Measure actual width at several points along the line
        var measured_widths: [3]usize = .{ 0, 0, 0 };
        const x_positions = [_]usize{ 75, 100, 125 };

        for (x_positions, 0..) |x, i| {
            var min_y: usize = height;
            var max_y: usize = 0;

            for (0..height) |py| {
                const idx = py * width + x;
                if (img.data[idx].r == 0) {
                    min_y = @min(min_y, py);
                    max_y = @max(max_y, py);
                }
            }

            if (max_y >= min_y) {
                measured_widths[i] = max_y - min_y + 1;
            }
        }

        // Allow for some tolerance due to rounding
        for (measured_widths) |measured| {
            try expect(measured >= line_width - 1 and measured <= line_width + 1);
        }
    }
}

test "filled circle has correct radius" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    const canvas: Canvas(Rgba) = .init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const test_radii = [_]f32{ 5, 10, 20, 30, 40 };
    const center: Point(2, f32) = .init(.{ 100, 100 });

    for (test_radii) |radius| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.fillCircle(center, radius, color, .fast);

        // Check pixels at various distances from center
        var inside_count: usize = 0;
        var outside_count: usize = 0;
        var edge_count: usize = 0;

        for (0..height) |y| {
            for (0..width) |x| {
                const dx = @as(f32, @floatFromInt(x)) - center.x();
                const dy = @as(f32, @floatFromInt(y)) - center.y();
                const dist = @sqrt(dx * dx + dy * dy);
                const idx = y * width + x;
                const is_black = img.data[idx].r == 0;

                if (dist < radius - 1) {
                    // Should be inside
                    if (is_black) inside_count += 1;
                } else if (dist > radius + 1) {
                    // Should be outside
                    if (!is_black) outside_count += 1;
                } else {
                    // Edge region
                    edge_count += 1;
                }
            }
        }

        // Most pixels inside radius should be filled
        const inside_total = @as(usize, @intFromFloat(std.math.pi * (radius - 1) * (radius - 1)));
        // Allow 15% tolerance for small circles due to discretization
        const tolerance_factor: f32 = if (radius <= 10) 0.85 else 0.9;
        const expected_count = @as(usize, @intFromFloat(@as(f32, @floatFromInt(inside_total)) * tolerance_factor));
        try expect(inside_count >= expected_count);
    }
}

test "circle outline has correct thickness" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    const canvas: Canvas(Rgba) = .init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const center: Point(2, f32) = .init(.{ 100, 100 });
    const radius: f32 = 40;
    const line_widths = [_]usize{ 1, 3, 5, 10 };

    for (line_widths) |line_width| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.drawCircle(center, radius, color, line_width, .fast);

        // Sample along several radii to check thickness
        const angles = [_]f32{ 0, std.math.pi / @as(f32, 4), std.math.pi / @as(f32, 2), 3 * std.math.pi / @as(f32, 4) };

        for (angles) |angle| {
            var black_pixels: usize = 0;

            // Count black pixels along this radius
            var r: f32 = 0;
            while (r < radius * 2) : (r += 0.5) {
                const x = center.x() + r * @cos(angle);
                const y = center.y() + r * @sin(angle);

                if (x >= 0 and x < width and y >= 0 and y < height) {
                    const idx = @as(usize, @intFromFloat(y)) * width + @as(usize, @intFromFloat(x));
                    if (img.data[idx].r == 0) {
                        black_pixels += 1;
                    }
                }
            }

            // Should have approximately line_width black pixels
            try expect(black_pixels >= line_width / 2 and black_pixels <= line_width * 3);
        }
    }
}

test "drawImage copies opaque pixels" {
    const allocator = testing.allocator;

    var dest: Image(Rgba) = try .init(allocator, 4, 4);
    defer dest.deinit(allocator);

    // Fill destination with white
    for (dest.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    var src: Image(Rgba) = try .init(allocator, 2, 2);
    defer src.deinit(allocator);
    src.at(0, 0).* = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    src.at(0, 1).* = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    src.at(1, 0).* = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    src.at(1, 1).* = Rgba{ .r = 255, .g = 255, .b = 0, .a = 255 };

    const canvas: Canvas(Rgba) = .init(allocator, dest);
    canvas.drawImage(src, .init(.{ 1, 1 }), null, .normal);

    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, dest.at(1, 1).*);
    try expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, dest.at(1, 2).*);
    try expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, dest.at(2, 1).*);
    try expectEqual(Rgba{ .r = 255, .g = 255, .b = 0, .a = 255 }, dest.at(2, 2).*);

    // Ensure unrelated pixel remains white
    try expectEqual(Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 }, dest.at(0, 0).*);
}

test "drawImage blends alpha" {
    const allocator = testing.allocator;

    var dest: Image(Rgba) = try .init(allocator, 2, 2);
    defer dest.deinit(allocator);

    // Fill destination with blue
    const base = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    for (dest.data) |*pixel| {
        pixel.* = base;
    }

    var src: Image(Rgba) = try .init(allocator, 1, 1);
    defer src.deinit(allocator);
    const overlay = Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 };
    src.at(0, 0).* = overlay;

    const canvas: Canvas(Rgba) = .init(allocator, dest);
    canvas.drawImage(src, .init(.{ 0, 0 }), null, .normal);

    const expected = base.blend(overlay, .normal);
    try expectEqual(expected, dest.at(0, 0).*);
}

test "drawImage supports source rect and clipping" {
    const allocator = testing.allocator;

    var dest: Image(Rgba) = try .init(allocator, 2, 3);
    defer dest.deinit(allocator);
    dest.fill(Rgba.transparent);

    var src: Image(Rgba) = try .init(allocator, 2, 3);
    defer src.deinit(allocator);
    src.at(0, 0).* = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    src.at(0, 1).* = .{ .r = 40, .g = 50, .b = 60, .a = 255 };
    src.at(0, 2).* = .{ .r = 70, .g = 80, .b = 90, .a = 255 };
    src.at(1, 0).* = .{ .r = 110, .g = 120, .b = 130, .a = 255 };
    src.at(1, 1).* = .{ .r = 140, .g = 150, .b = 160, .a = 255 };
    src.at(1, 2).* = .{ .r = 170, .g = 180, .b = 190, .a = 255 };

    const canvas: Canvas(Rgba) = .init(allocator, dest);
    const src_rect: Rectangle(usize) = .init(1, 0, 3, 2);
    canvas.drawImage(src, .init(.{ 0, 0 }), src_rect, .normal);

    try expectEqual(Rgba{ .r = 40, .g = 50, .b = 60, .a = 255 }, dest.at(0, 0).*);
    try expectEqual(Rgba{ .r = 70, .g = 80, .b = 90, .a = 255 }, dest.at(0, 1).*);
    try expectEqual(Rgba{ .r = 140, .g = 150, .b = 160, .a = 255 }, dest.at(1, 0).*);
    try expectEqual(Rgba{ .r = 170, .g = 180, .b = 190, .a = 255 }, dest.at(1, 1).*);

    // Draw partially off-canvas to ensure clipping works
    canvas.drawImage(src, .init(.{ -1, 0 }), null, .normal);
    try expectEqual(Rgba{ .r = 40, .g = 50, .b = 60, .a = 255 }, dest.at(0, 0).*);
}

test "filled rectangle has correct area" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    const canvas: Canvas(Rgba) = .init(allocator, img);

    const rect = Rectangle(f32){ .l = 50, .t = 50, .r = 150, .b = 130 };
    const rect_width = rect.r - rect.l;
    const rect_height = rect.b - rect.t;
    const expected_area = rect_width * rect_height;

    // Clear and draw filled rectangle using polygon fill
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    const corners = [_]Point(2, f32){
        .init(.{ rect.l, rect.t }),
        .init(.{ rect.r, rect.t }),
        .init(.{ rect.r, rect.b }),
        .init(.{ rect.l, rect.b }),
    };
    try canvas.fillPolygon(&corners, Rgba.black, .fast);

    // Count black pixels
    var black_pixels: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0) black_pixels += 1;
    }

    // Should match expected area closely
    const tolerance = expected_area * 0.01; // 1% tolerance
    const diff = @abs(@as(f32, @floatFromInt(black_pixels)) - expected_area);
    try expect(diff <= tolerance);
}

test "polygon fill respects convexity" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    const canvas: Canvas(Rgba) = .init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test convex polygon (triangle)
    const triangle = [_]Point(2, f32){
        .init(.{ 100, 30 }),
        .init(.{ 170, 150 }),
        .init(.{ 30, 150 }),
    };

    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    try canvas.fillPolygon(&triangle, color, .fast);

    // Check that points inside triangle are filled
    const test_points = [_]struct { p: Point(2, f32), inside: bool }{
        .{ .p = .init(.{ 100, 100 }), .inside = true }, // centroid
        .{ .p = .init(.{ 100, 50 }), .inside = true }, // near top
        .{ .p = .init(.{ 50, 140 }), .inside = true }, // near bottom left
        .{ .p = .init(.{ 150, 140 }), .inside = true }, // near bottom right
        .{ .p = .init(.{ 20, 20 }), .inside = false }, // outside
        .{ .p = .init(.{ 180, 180 }), .inside = false }, // outside
    };

    for (test_points) |tp| {
        const x = @as(usize, @intFromFloat(tp.p.x()));
        const y = @as(usize, @intFromFloat(tp.p.y()));
        if (x < width and y < height) {
            const idx = y * width + x;
            const is_black = img.data[idx].r == 0;
            try expectEqual(tp.inside, is_black);
        }
    }
}

test "antialiased vs solid fill coverage" {
    const allocator = testing.allocator;
    const width = 100;
    const height = 100;
    var img_solid: Image(Rgba) = try .init(allocator, width, height);
    defer img_solid.deinit(allocator);
    var img_smooth: Image(Rgba) = try .init(allocator, width, height);
    defer img_smooth.deinit(allocator);

    const canvas_solid: Canvas(Rgba) = .init(allocator, img_solid);
    const canvas_smooth: Canvas(Rgba) = .init(allocator, img_smooth);

    // Clear both images
    for (img_solid.data, img_smooth.data) |*p1, *p2| {
        p1.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        p2.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    // Draw same circle with different modes
    const center: Point(2, f32) = .init(.{ 50, 50 });
    const radius: f32 = 20;

    canvas_solid.fillCircle(center, radius, Rgba.black, .fast);
    canvas_smooth.fillCircle(center, radius, Rgba.black, .soft);

    // Count coverage (sum of darkness)
    var solid_coverage: f32 = 0;
    var smooth_coverage: f32 = 0;

    for (img_solid.data, img_smooth.data) |p1, p2| {
        solid_coverage += @as(f32, @floatFromInt(255 - p1.r));
        smooth_coverage += @as(f32, @floatFromInt(255 - p2.r));
    }

    // Antialiased version should have similar total coverage
    // but slightly less due to edge smoothing
    try expect(smooth_coverage > solid_coverage * 0.9);
    try expect(smooth_coverage <= solid_coverage);
}

test "bezier curve smoothness" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img: Image(Rgba) = try .init(allocator, width, height);
    defer img.deinit(allocator);

    const canvas: Canvas(Rgba) = .init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Clear image
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    // Draw cubic bezier
    const p0: Point(2, f32) = .init(.{ 20, 100 });
    const p1: Point(2, f32) = .init(.{ 60, 20 });
    const p2: Point(2, f32) = .init(.{ 140, 180 });
    const p3: Point(2, f32) = .init(.{ 180, 100 });

    canvas.drawCubicBezier(p0, p1, p2, p3, color, 2, .fast);

    // Verify endpoints are connected
    var p0_found = false;
    var p3_found = false;

    // Check 3x3 area around endpoints
    for (0..3) |dy| {
        for (0..3) |dx| {
            const y0 = @as(i32, @intFromFloat(p0.y())) + @as(i32, @intCast(dy)) - 1;
            const x0 = @as(i32, @intFromFloat(p0.x())) + @as(i32, @intCast(dx)) - 1;
            const y3 = @as(i32, @intFromFloat(p3.y())) + @as(i32, @intCast(dy)) - 1;
            const x3 = @as(i32, @intFromFloat(p3.x())) + @as(i32, @intCast(dx)) - 1;

            if (y0 >= 0 and y0 < height and x0 >= 0 and x0 < width) {
                const idx0 = @as(usize, @intCast(y0)) * width + @as(usize, @intCast(x0));
                if (img.data[idx0].r == 0) p0_found = true;
            }

            if (y3 >= 0 and y3 < height and x3 >= 0 and x3 < width) {
                const idx3 = @as(usize, @intCast(y3)) * width + @as(usize, @intCast(x3));
                if (img.data[idx3].r == 0) p3_found = true;
            }
        }
    }

    try expect(p0_found);
    try expect(p3_found);

    // Verify curve has pixels (not empty)
    var black_pixel_count: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0) black_pixel_count += 1;
    }
    try expect(black_pixel_count > 50); // Should have a reasonable number of pixels
}

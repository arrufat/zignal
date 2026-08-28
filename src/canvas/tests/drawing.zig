const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const Rgba = @import("../../color.zig").Rgba(u8);
const Rectangle = @import("../../geometry.zig").Rectangle;
const Point = @import("../../geometry/Point.zig").Point;
const Image = @import("../../image.zig").Image;
const Canvas = @import("../Canvas.zig").Canvas;
const DrawOptions = @import("../Canvas.zig").DrawOptions;
const FillRule = @import("../Canvas.zig").FillRule;

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
                const y1: i32 = @as(i32, @trunc(tc.p1.y())) + @as(i32, @intCast(dy)) - 1;
                const x1: i32 = @as(i32, @trunc(tc.p1.x())) + @as(i32, @intCast(dx)) - 1;
                const y2: i32 = @as(i32, @trunc(tc.p2.y())) + @as(i32, @intCast(dy)) - 1;
                const x2: i32 = @as(i32, @trunc(tc.p2.x())) + @as(i32, @intCast(dx)) - 1;

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
    const line_widths = [_]u32{ 1, 3, 5, 10, 20 };

    for (line_widths) |line_width| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        // Draw horizontal line in the middle
        const y: f32 = height / 2;
        canvas.drawLine(.init(.{ 50, y }), .init(.{ 150, y }), color, @intCast(line_width), .fast);

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
        const inside_total: usize = @trunc(std.math.pi * (radius - 1) * (radius - 1));
        // Allow 15% tolerance for small circles due to discretization
        const tolerance_factor: f32 = if (radius <= 10) 0.85 else 0.9;
        const expected_count: usize = @trunc(@as(f32, @floatFromInt(inside_total)) * tolerance_factor);
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

        canvas.drawCircle(center, radius, color, @intCast(line_width), .fast);

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
                    const idx: usize = @as(usize, @trunc(y)) * width + @as(usize, @trunc(x));
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
    const src_rect: Rectangle(u32) = .init(1, 0, 3, 2);
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
        const x: usize = @trunc(tp.p.x());
        const y: usize = @trunc(tp.p.y());
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
        solid_coverage += @as(f32, 255 - p1.r);
        smooth_coverage += @as(f32, 255 - p2.r);
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
            const y0: i32 = @as(i32, @trunc(p0.y())) + @as(i32, @intCast(dy)) - 1;
            const x0: i32 = @as(i32, @trunc(p0.x())) + @as(i32, @intCast(dx)) - 1;
            const y3: i32 = @as(i32, @trunc(p3.y())) + @as(i32, @intCast(dy)) - 1;
            const x3: i32 = @as(i32, @trunc(p3.x())) + @as(i32, @intCast(dx)) - 1;

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

test "drawLine with soft mode handles out-of-bounds endpoints" {
    const allocator = testing.allocator;
    var img = try Image(u8).init(allocator, 400, 400);
    defer img.deinit(allocator);
    img.fill(0);

    const canvas = Canvas(u8).init(allocator, img);
    const l: Point(2, f32) = .init(.{ -500, 200 });
    const r: Point(2, f32) = .init(.{ 900, 200 });
    canvas.drawLine(l, r, @as(u8, 255), 5, .soft);

    // Verify that the visible part of the line was drawn.
    try expect(img.at(200, 200).* > 0);

    // Diagonals whose band leaves the image on either side: rows with no columns in reach.
    canvas.drawLine(.init(.{ -200, 0 }), .init(.{ 200, 400 }), @as(u8, 255), 3, .soft);
    canvas.drawLine(.init(.{ 200, 0 }), .init(.{ 600, 400 }), @as(u8, 255), 3, .soft);
    try expect(img.at(300, 100).* > 0);
    try expect(img.at(100, 300).* > 0);
}

test "fillPolygon soft antialiases near-horizontal edges" {
    const allocator = testing.allocator;
    var img: Image(Rgba) = try .init(allocator, 40, 100);
    defer img.deinit(allocator);
    img.fill(Rgba.white);
    const canvas: Canvas(Rgba) = .init(allocator, img);

    // The hypotenuse (5,10)-(95,20) has slope 1/9 and sweeps across pixel row 15 between x≈45 and x≈55.
    const triangle = [_]Point(2, f32){ .init(.{ 5, 10 }), .init(.{ 95, 10 }), .init(.{ 95, 20 }) };
    try canvas.fillPolygon(&triangle, Rgba.black, .soft);

    try expectEqual(img.at(12, 70).*.r, 0);
    try expectEqual(img.at(15, 30).*.r, 255);

    // Coverage along the shallow edge ramps: ~17% at x=47, ~83% at x=53.
    const light = img.at(15, 47).*.r;
    const dark = img.at(15, 53).*.r;
    try expect(light > 190);
    try expect(light < 245);
    try expect(dark > 10);
    try expect(dark < 70);
    var prev: u8 = 255;
    for (44..57) |x| {
        const value = img.at(15, @intCast(x)).*.r;
        try expect(value <= prev);
        prev = value;
    }
}

const Outline = @import("../../font.zig").Outline;
const VectorFont = @import("../../font.zig").VectorFont;
const synthetic = @import("../../font/truetype/synthetic.zig");

fn whiteCanvas(img: Image(Rgba)) Canvas(Rgba) {
    img.fill(Rgba.white);
    return .init(testing.allocator, img);
}

test "fill rules on overlapping contours" {
    var img: Image(Rgba) = try .init(testing.allocator, 100, 100);
    defer img.deinit(testing.allocator);
    const black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const same_winding = [_][]const Point(2, f32){
        &.{ .init(.{ 10, 10 }), .init(.{ 10, 60 }), .init(.{ 60, 60 }), .init(.{ 60, 10 }) },
        &.{ .init(.{ 40, 40 }), .init(.{ 40, 90 }), .init(.{ 90, 90 }), .init(.{ 90, 40 }) },
    };
    const with_hole = [_][]const Point(2, f32){
        &.{ .init(.{ 10, 10 }), .init(.{ 10, 90 }), .init(.{ 90, 90 }), .init(.{ 90, 10 }) },
        &.{ .init(.{ 30, 30 }), .init(.{ 70, 30 }), .init(.{ 70, 70 }), .init(.{ 30, 70 }) },
    };
    for ([_]DrawOptions{ .fast, .soft }) |opts| {
        var canvas = whiteCanvas(img);
        try canvas.fillPolygons(&same_winding, black, .even_odd, opts);
        try expectEqual(@as(u8, 255), canvas.at(50, 50).r); // overlap is a hole
        try expectEqual(@as(u8, 0), canvas.at(20, 20).r);
        try expectEqual(@as(u8, 0), canvas.at(80, 80).r);

        canvas = whiteCanvas(img);
        try canvas.fillPolygons(&same_winding, black, .nonzero, opts);
        try expectEqual(@as(u8, 0), canvas.at(50, 50).r); // overlap is filled
        try expectEqual(@as(u8, 0), canvas.at(20, 20).r);
        try expectEqual(@as(u8, 255), canvas.at(5, 5).r);

        for ([_]FillRule{ .even_odd, .nonzero }) |rule| {
            canvas = whiteCanvas(img);
            try canvas.fillPolygons(&with_hole, black, rule, opts);
            try expectEqual(@as(u8, 255), canvas.at(50, 50).r);
            try expectEqual(@as(u8, 0), canvas.at(20, 50).r);
        }
    }
}

test "fillPolygon is the even-odd single-contour case" {
    var a: Image(Rgba) = try .init(testing.allocator, 64, 64);
    defer a.deinit(testing.allocator);
    var b: Image(Rgba) = try .init(testing.allocator, 64, 64);
    defer b.deinit(testing.allocator);
    const tri = [_]Point(2, f32){ .init(.{ 5.5, 3.2 }), .init(.{ 60.1, 20.7 }), .init(.{ 12.4, 58.9 }) };
    const red: Rgba = .{ .r = 200, .g = 30, .b = 30, .a = 255 };
    for ([_]DrawOptions{ .fast, .soft }) |opts| {
        const ca = whiteCanvas(a);
        const cb = whiteCanvas(b);
        try ca.fillPolygon(&tri, red, opts);
        try cb.fillPolygons(&.{&tri}, red, .even_odd, opts);
        try testing.expectEqualSlices(Rgba, a.data, b.data);
    }
}

test "coverage masks accumulate with max" {
    var buf: [20 * 20]u8 = @splat(0);
    const mask: Canvas(u8) = .init(testing.allocator, .initFromSlice(20, 20, &buf));
    // A square whose left edge sits on a pixel centre: that column is half covered.
    const square = [_]Point(2, f32){ .init(.{ 5, 5 }), .init(.{ 15, 5 }), .init(.{ 15, 15 }), .init(.{ 5, 15 }) };
    try mask.rasterizePolygons(&.{&square}, .nonzero);
    try expectEqual(@as(u8, 255), buf[10 * 20 + 10]);
    try expectEqual(@as(u8, 0), buf[10 * 20 + 2]);
    try expectEqual(@as(u8, 0), buf[2 * 20 + 10]);
    const edge = buf[10 * 20 + 5];
    try expect(edge > 100 and edge < 156);

    var again = buf;
    const mask2: Canvas(u8) = .init(testing.allocator, .initFromSlice(20, 20, &again));
    try mask2.rasterizePolygons(&.{&square}, .nonzero);
    try testing.expectEqualSlices(u8, &buf, &again);

    // Conservation: each interior row sums to the square's width in pixels.
    var row_sum: u32 = 0;
    for (buf[10 * 20 ..][0..20]) |v| row_sum += v;
    try expect(row_sum >= 10 * 255 - 3 and row_sum <= 10 * 255 + 3);
}

test "glyph coverage into a caller-sized mask" {
    var font_buf: [synthetic.buffer_size]u8 = undefined;
    const font: VectorFont = try .loadFromBytes(synthetic.build(&font_buf, .{}));
    var outline = try font.outline(testing.allocator, 1);
    defer outline.deinit(testing.allocator);

    // gid 1 spans 100..700 x 0..700 font units; at 0.05 px/unit that is 30x35 px.
    const scale: f32 = 0.05;
    const bounds = font.glyphBounds(1).?;
    const w: u32 = @ceil(@as(f32, @floatFromInt(bounds.x_max)) * scale + 2);
    const h: u32 = @ceil(@as(f32, @floatFromInt(bounds.y_max - bounds.y_min)) * scale + 2);
    const buf = try testing.allocator.alloc(u8, w * h);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    const mask: Canvas(u8) = .init(testing.allocator, .initFromSlice(h, w, buf));
    const t: Outline.Transform = .{ .scale = scale, .origin = .init(.{ 0, @as(f32, @floatFromInt(h - 1)) }) };
    try mask.rasterizeGlyph(outline, t);

    // Centre of the counter is empty, the frame around it is inked.
    try expectEqual(@as(u8, 0), buf[(h - 1 - 17) * w + 20]);
    try expectEqual(@as(u8, 255), buf[(h - 1 - 5) * w + 20]);
    try expectEqual(@as(u8, 255), buf[(h - 1 - 17) * w + 8]);
    var inked: usize = 0;
    for (buf) |v| inked += @intFromBool(v != 0);
    try expect(inked > 500 and inked < 30 * 35);
}

const Font = @import("../../font.zig").Font;
const TextLayout = @import("../../font.zig").TextLayout;
const as = @import("../../meta.zig").as;
const font8x8 = @import("../../font/font8x8.zig");

fn blankImage(allocator: std.mem.Allocator) !Image(Rgba) {
    const img: Image(Rgba) = try .init(allocator, 60, 100);
    img.fill(Rgba.white);
    return img;
}

fn samePixels(a: Image(Rgba), b: Image(Rgba)) bool {
    return std.mem.eql(u8, std.mem.sliceAsBytes(a.data), std.mem.sliceAsBytes(b.data));
}

fn inkCount(img: Image(Rgba)) usize {
    var count: usize = 0;
    for (img.data) |px| count += @intFromBool(!std.meta.eql(px, Rgba.white));
    return count;
}

fn isWhite(img: Image(Rgba), row: usize, col: usize) bool {
    return std.meta.eql(img.data[row * img.stride + col], Rgba.white);
}

test "drawTextBox places lines where drawText would" {
    const allocator = testing.allocator;
    var expected = try blankImage(allocator);
    defer expected.deinit(allocator);
    var actual = try blankImage(allocator);
    defer actual.deinit(allocator);
    const reference: Canvas(Rgba) = .init(allocator, expected);
    const canvas: Canvas(Rgba) = .init(allocator, actual);

    var buf: [synthetic.buffer_size]u8 = undefined;
    var cached_buf: [synthetic.buffer_size]u8 = undefined;
    var cached = try cachedFont(&cached_buf, .{});
    defer cached.disableCache();
    const fonts = [_]Font{ .{ .bitmap = font8x8.basic }, .{ .vector = synthetic.font(&buf, .{}) }, cached };
    for (fonts) |font| {
        const size: f32 = 10;
        const box: Rectangle(f32) = .{ .l = 10, .t = 10, .r = 90, .b = 50 };
        const width = font.getTextBounds("AB", size).r;
        const height = font.lineHeight(size);
        const Case = struct { layout: TextLayout, x: f32, y: f32 };
        const cases = [_]Case{
            .{ .layout = .default, .x = 10, .y = 10 },
            .{ .layout = .{ .halign = .center, .valign = .middle }, .x = 10 + (80 - width) / 2, .y = 10 + (40 - height) / 2 },
            .{ .layout = .{ .halign = .right, .valign = .bottom }, .x = 90 - width, .y = 50 - height },
        };
        for (cases) |case| {
            expected.fill(Rgba.white);
            actual.fill(Rgba.white);
            try reference.drawText("AB", .init(.{ case.x, case.y }), Rgba.black, font, size, .soft);
            try canvas.drawTextBox("AB", box, Rgba.black, font, size, case.layout, .soft);
            try expect(inkCount(actual) > 0);
            try expect(samePixels(expected, actual));
        }

        // Wrapping breaks like an explicit newline; line spacing scales the advance.
        expected.fill(Rgba.white);
        actual.fill(Rgba.white);
        try reference.drawText("AB", .init(.{ 10, 10 }), Rgba.black, font, size, .soft);
        try reference.drawText("AB", .init(.{ 10, 10 + 1.5 * height }), Rgba.black, font, size, .soft);
        try canvas.drawTextBox("AB AB", .{ .l = 10, .t = 10, .r = 10 + width + 1, .b = 60 }, Rgba.black, font, size, .{ .wrap = true, .line_spacing = 1.5 }, .soft);
        try expect(samePixels(expected, actual));

        // Letter spacing shifts every following glyph.
        expected.fill(Rgba.white);
        actual.fill(Rgba.white);
        const a_width = font.getTextBounds("A", size).r;
        try reference.drawText("A", .init(.{ 10, 10 }), Rgba.black, font, size, .soft);
        try reference.drawText("B", .init(.{ 10 + a_width + 3, 10 }), Rgba.black, font, size, .soft);
        try canvas.drawTextBox("AB", box, Rgba.black, font, size, .{ .letter_spacing = 3 }, .soft);
        // The vector font kerns A→B, which the two-call reference lacks.
        if (font == .bitmap) try expect(samePixels(expected, actual)) else try expect(inkCount(actual) > 0);
    }
}

/// A synthetic vector font with its glyph cache enabled; `disableCache` it when done.
fn cachedFont(buf: *[synthetic.buffer_size]u8, opts: synthetic.Options) !Font {
    var vector = synthetic.font(buf, opts);
    try vector.enableCache(testing.allocator);
    return .{ .vector = vector };
}

fn absDiff(a: usize, b: usize) usize {
    return @max(a, b) - @min(a, b);
}

fn maxChannelDiff(a: Image(Rgba), b: Image(Rgba)) u8 {
    var worst: u8 = 0;
    for (std.mem.sliceAsBytes(a.data), std.mem.sliceAsBytes(b.data)) |x, y| worst = @max(worst, @max(x, y) - @min(x, y));
    return worst;
}

fn inkBox(img: Image(Rgba)) Rectangle(usize) {
    var box: Rectangle(usize) = .{ .l = img.cols, .t = img.rows, .r = 0, .b = 0 };
    for (0..img.rows) |r| for (0..img.cols) |c| if (!isWhite(img, r, c)) {
        box.l = @min(box.l, c);
        box.t = @min(box.t, r);
        box.r = @max(box.r, c + 1);
        box.b = @max(box.b, r + 1);
    };
    return box;
}

test "cached text matches uncached" {
    const allocator = testing.allocator;
    var expected = try blankImage(allocator);
    defer expected.deinit(allocator);
    var actual = try blankImage(allocator);
    defer actual.deinit(allocator);
    const reference: Canvas(Rgba) = .init(allocator, expected);
    const canvas: Canvas(Rgba) = .init(allocator, actual);

    for ([_]synthetic.Options{ .{}, .{ .cff = true } }) |opts| {
        var plain_buf: [synthetic.buffer_size]u8 = undefined;
        const plain: Font = .{ .vector = synthetic.font(&plain_buf, opts) };
        var buf: [synthetic.buffer_size]u8 = undefined;
        var cached = try cachedFont(&buf, opts);
        defer cached.disableCache();
        const cache = cached.vector.cache.?;

        // A glyph at an integer origin differs only by the 8-bit mask rounding: at 40 px the
        // baseline sits at 36 px. (Later glyphs in a string sit at fractional advances, and
        // most sizes at a fractional baseline, so they get the quarter-pixel snap.)
        expected.fill(Rgba.white);
        actual.fill(Rgba.white);
        try reference.drawText("A", .init(.{ 4, 20 }), Rgba.black, plain, 40, .soft);
        try canvas.drawText("A", .init(.{ 4, 20 }), Rgba.black, cached, 40, .soft);
        try expect(inkCount(actual) > 100);
        try expect(maxChannelDiff(expected, actual) <= 2);
        try expect(cache.mask_stats.misses == 1 and cache.mask_stats.hits == 0);

        // A fractional origin is snapped to a quarter pixel: same ink, edges within a phase.
        expected.fill(Rgba.white);
        actual.fill(Rgba.white);
        try reference.drawText("ABCDEF", .init(.{ 4.3, 20.7 }), Rgba.black, plain, 36, .soft);
        try canvas.drawText("ABCDEF", .init(.{ 4.3, 20.7 }), Rgba.black, cached, 36, .soft);
        try expect(maxChannelDiff(expected, actual) <= 128);
        try expect(absDiff(inkCount(expected), inkCount(actual)) <= inkCount(expected) / 20);
        const box_expected = inkBox(expected);
        const box_actual = inkBox(actual);
        inline for (.{ "l", "t", "r", "b" }) |edge| {
            try expect(absDiff(@field(box_expected, edge), @field(box_actual, edge)) <= 1);
        }

        // Masks are deterministic: drawing again reproduces the cached image exactly.
        expected.fill(Rgba.white);
        try reference.drawText("ABCDEF", .init(.{ 4.3, 20.7 }), Rgba.black, cached, 36, .soft);
        try expect(samePixels(expected, actual));

        // Hard-edged and outlined text never use masks and stay byte-identical.
        expected.fill(Rgba.white);
        actual.fill(Rgba.white);
        try reference.drawText("ABC", .init(.{ 4.3, 20.7 }), Rgba.black, plain, 36, .fast);
        try canvas.drawText("ABC", .init(.{ 4.3, 20.7 }), Rgba.black, cached, 36, .fast);
        try expect(inkCount(actual) > 100);
        try expect(samePixels(expected, actual));
        expected.fill(Rgba.white);
        actual.fill(Rgba.white);
        try reference.drawTextOutline("ABC", .init(.{ 4.3, 20.7 }), Rgba.black, plain, 36, 2, .soft);
        try canvas.drawTextOutline("ABC", .init(.{ 4.3, 20.7 }), Rgba.black, cached, 36, 2, .soft);
        try expect(inkCount(actual) > 100);
        try expect(samePixels(expected, actual));
    }
}

test "the cache is hit on the second draw" {
    const allocator = testing.allocator;
    var img = try blankImage(allocator);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);
    var buf: [synthetic.buffer_size]u8 = undefined;
    var font = try cachedFont(&buf, .{});
    defer font.disableCache();
    const cache = font.vector.cache.?;
    const Stats = @import("../../font.zig").GlyphCache.Stats;

    try canvas.drawText("AB", .init(.{ 4, 20 }), Rgba.black, font, 36, .soft);
    try expectEqual(Stats{ .hits = 0, .misses = 2 }, cache.mask_stats);
    try expectEqual(Stats{ .hits = 0, .misses = 2 }, cache.outline_stats);
    try canvas.drawText("AB", .init(.{ 4, 20 }), Rgba.black, font, 36, .soft);
    try expectEqual(Stats{ .hits = 2, .misses = 2 }, cache.mask_stats);
    try expectEqual(Stats{ .hits = 0, .misses = 2 }, cache.outline_stats);
    // A new phase needs new masks, but the outlines are reused.
    try canvas.drawText("AB", .init(.{ 4.5, 20 }), Rgba.black, font, 36, .soft);
    try expectEqual(Stats{ .hits = 2, .misses = 4 }, cache.mask_stats);
    try expectEqual(Stats{ .hits = 2, .misses = 2 }, cache.outline_stats);
    try expectEqual(@as(usize, 4), cache.masks.count());
}

test "mask budget eviction while drawing" {
    const allocator = testing.allocator;
    var img = try blankImage(allocator);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);
    var buf: [synthetic.buffer_size]u8 = undefined;
    var font = try cachedFont(&buf, .{});
    defer font.disableCache();
    const cache = font.vector.cache.?;

    // Sixteen phases of six glyphs at ~700 bytes each overflow a 16 KB budget.
    cache.max_mask_bytes = 16 * 1024;
    for (0..4) |px| for (0..4) |py| {
        try canvas.drawText("ABCDEF", .init(.{ 4 + as(f32, px) / 4, 20 + as(f32, py) / 4 }), Rgba.black, font, 36, .soft);
    };
    try expect(inkCount(img) > 100);
    try expect(cache.evictions >= 1);
    try expect(cache.mask_bytes <= 16 * 1024);
    // A glyph over a sixteenth of the budget (72x84 px here) is drawn directly, not stored.
    const before = cache.masks.count();
    img.fill(Rgba.white);
    try canvas.drawText("A", .init(.{ 0, 0 }), Rgba.black, font, 120, .soft);
    try expect(inkCount(img) > 100);
    try expectEqual(before, cache.masks.count());
}

test "outlined glyphs are hollow, halos dilate bitmaps" {
    const allocator = testing.allocator;
    var img = try blankImage(allocator);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font: Font = .{ .vector = synthetic.font(&buf, .{}) };

    // Glyph A at 50 px: a square from (5, 10) to (35, 45) with a hole from (15, 20) to (25, 35).
    for ([_]DrawOptions{ .soft, .fast }) |opts| {
        img.fill(Rgba.white);
        try canvas.drawTextOutline("A", .init(.{ 0, 0 }), Rgba.black, font, 50, 3, opts);
        try expect(!isWhite(img, 27, 5)); // outer edge
        try expect(!isWhite(img, 27, 15)); // hole edge
        try expect(isWhite(img, 27, 10)); // between the edges
        try expect(isWhite(img, 27, 20)); // inside the hole
        try expect(isWhite(img, 27, 45)); // outside
        const hollow = inkCount(img);
        img.fill(Rgba.white);
        try canvas.drawText("A", .init(.{ 0, 0 }), Rgba.black, font, 50, opts);
        try expect(!isWhite(img, 27, 10));
        try expect(inkCount(img) > hollow);
    }

    // A thicker stroke covers more, and the box variant places it like the fill.
    img.fill(Rgba.white);
    try canvas.drawTextOutline("A", .init(.{ 0, 0 }), Rgba.black, font, 50, 7, .soft);
    const thick = inkCount(img);
    img.fill(Rgba.white);
    try canvas.drawTextOutline("A", .init(.{ 0, 0 }), Rgba.black, font, 50, 3, .soft);
    try expect(thick > inkCount(img));
    var boxed = try blankImage(allocator);
    defer boxed.deinit(allocator);
    const box_canvas: Canvas(Rgba) = .init(allocator, boxed);
    try box_canvas.drawTextBoxOutline("A", .{ .l = 0, .t = 0, .r = 100, .b = 60 }, Rgba.black, font, 50, 3, .default, .soft);
    try expect(samePixels(img, boxed));

    // Bitmap halo: a superset of the glyph's own pixels.
    const bitmap: Font = .{ .bitmap = font8x8.basic };
    img.fill(Rgba.white);
    try canvas.drawText("H", .init(.{ 20, 20 }), Rgba.black, bitmap, null, .fast);
    var plain = try blankImage(allocator);
    defer plain.deinit(allocator);
    img.copy(plain);
    img.fill(Rgba.white);
    try canvas.drawTextOutline("H", .init(.{ 20, 20 }), Rgba.black, bitmap, null, 4, .fast);
    try expect(inkCount(img) > inkCount(plain));
    for (plain.data, img.data) |p, q| if (p.r == 0) try expect(q.r == 0);
}

test "text boxes on a grayscale canvas" {
    const allocator = testing.allocator;
    var img: Image(u8) = try .init(allocator, 40, 80);
    defer img.deinit(allocator);
    @memset(img.data, 0);
    const canvas: Canvas(u8) = .init(allocator, img);
    try canvas.drawTextBox("hi", .{ .l = 0, .t = 0, .r = 80, .b = 40 }, @as(u8, 255), .{ .bitmap = font8x8.basic }, 16, .{ .halign = .center, .valign = .middle }, .soft);
    var lit: usize = 0;
    for (img.data) |px| lit += @intFromBool(px > 0);
    try expect(lit > 0);
}

test "a soft fill is unaffected by the fill before it" {
    // The area accumulator is stack scratch reused across fills; a shape whose interior
    // crosses a block the previous fill deposited into must not read those cells.
    const allocator = testing.allocator;
    var alone: Image(Rgba) = try .init(allocator, 120, 120);
    defer alone.deinit(allocator);
    var after: Image(Rgba) = try .init(allocator, 120, 120);
    defer after.deinit(allocator);
    alone.fill(Rgba.white);
    after.fill(Rgba.white);
    const canvas_alone: Canvas(Rgba) = .init(allocator, alone);
    const canvas_after: Canvas(Rgba) = .init(allocator, after);

    // A tall triangle whose slanted edge sweeps every block of its rows, then a wide quad
    // whose interior spans untouched blocks on the same rows.
    const triangle = [_]Point(2, f32){ .init(.{ 5, 5 }), .init(.{ 110, 8 }), .init(.{ 7, 112 }) };
    const quad = [_]Point(2, f32){ .init(.{ 10, 20 }), .init(.{ 100, 24 }), .init(.{ 104, 96 }), .init(.{ 12, 100 }) };
    try canvas_after.fillPolygons(&.{&triangle}, Rgba.black, .nonzero, .soft);
    after.fill(Rgba.white);
    try canvas_after.fillPolygons(&.{&quad}, Rgba.black, .nonzero, .soft);
    try canvas_alone.fillPolygons(&.{&quad}, Rgba.black, .nonzero, .soft);
    try testing.expectEqualSlices(Rgba, alone.data, after.data);
}

test "shapes off the image or with non-finite input draw nothing" {
    const allocator = testing.allocator;
    var img = try Image(u8).init(allocator, 10, 10);
    defer img.deinit(allocator);
    img.fill(0);
    const canvas = Canvas(u8).init(allocator, img);
    const white: u8 = 255;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const above: []const Point(2, f32) = &.{ .init(.{ 1, -50 }), .init(.{ 8, -50 }), .init(.{ 8, -40 }), .init(.{ 1, -40 }) };
    const nan_poly: []const Point(2, f32) = &.{ .init(.{ 1, nan }), .init(.{ 8, 1 }), .init(.{ 8, 8 }) };
    for ([_]DrawOptions{ .soft, .fast }) |opts| {
        canvas.drawPolygon(above, white, 3, opts);
        try canvas.fillPolygons(&.{above}, white, .nonzero, opts);
        try canvas.fillPolygon(above, white, opts);
        canvas.drawPolygon(nan_poly, white, 3, opts);
        try canvas.fillPolygon(nan_poly, white, opts);
        canvas.drawLine(.init(.{ nan, 0 }), .init(.{ 5, 5 }), white, 1, opts);
        canvas.drawLine(.init(.{ -1e9, -50 }), .init(.{ 1e9, -40 }), white, 1, opts);
        canvas.drawCircle(.init(.{ nan, 5 }), 3, white, 1, opts);
        canvas.fillCircle(.init(.{ 5, 5 }), inf, white, opts);
        canvas.drawRectangle(.{ .l = nan, .t = 0, .r = 5, .b = 5 }, white, 1, opts);
        canvas.fillRectangle(.{ .l = 0, .t = 0, .r = inf, .b = nan }, white, opts);
        try canvas.drawArc(.init(.{ 5, nan }), 3, 0, 1, white, 1, opts);
        try canvas.fillArc(.init(.{ 5, 5 }), nan, 0, 1, white, opts);
    }
    for (img.data) |px| try expect(px == 0);

    // A pixel line that shoots far past the image still draws its visible part.
    canvas.drawLine(.init(.{ -1e9, 5 }), .init(.{ 1e9, 5 }), white, 1, .fast);
    try expectEqual(@as(u8, 255), img.at(5, 5).*);
    canvas.drawLine(.init(.{ 2, -1e9 }), .init(.{ 3, 1e9 }), white, 1, .soft);
    try expect(img.at(0, 2).* > 0 or img.at(0, 3).* > 0);
}

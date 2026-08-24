const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

const Blending = @import("../../blending.zig").Blending;
const Rgba = @import("../../color.zig").Rgba(u8);
const Rectangle = @import("../../geometry.zig").Rectangle;
const Image = @import("../../image.zig").Image;
const Canvas = @import("../Canvas.zig").Canvas;
const DrawOptions = @import("../Canvas.zig").DrawOptions;

const gray: Rgba = .{ .r = 128, .g = 128, .b = 128, .a = 255 };

test "fast mode blends translucent colors with normal blending" {
    const allocator = testing.allocator;
    var img: Image(Rgba) = try .init(allocator, 20, 20);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);

    const translucent_black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 128 };
    const rect: Rectangle(f32) = .{ .l = 5, .t = 5, .r = 15, .b = 15 };

    // Fast mode with explicit .normal blending composites instead of overwriting
    canvas.fill(Rgba.white);
    canvas.fillRectangle(rect, translucent_black, .{ .mode = .fast, .blending = .normal });
    const blended = img.at(10, 10).*;
    try expect(blended.r > 120 and blended.r < 135);
    try expectEqual(blended.a, 255);

    // The .fast preset is a raw overwrite: alpha lands in the buffer verbatim
    canvas.fill(Rgba.white);
    canvas.fillRectangle(rect, translucent_black, .fast);
    const overwritten = img.at(10, 10).*;
    try expectEqual(overwritten.r, 0);
    try expectEqual(overwritten.a, 128);
}

test "multiply blending applies on fast fill paths with opaque colors" {
    const allocator = testing.allocator;
    var img: Image(Rgba) = try .init(allocator, 40, 40);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);

    canvas.fill(gray);
    canvas.fillCircle(.init(.{ 20, 20 }), 10, gray, .{ .mode = .fast, .blending = .multiply });

    // 128/255 * 128/255 * 255 ≈ 64 in the circle interior
    const interior = img.at(20, 20).*;
    try expect(interior.r > 60 and interior.r < 68);
    try expectEqual(img.at(2, 2).*.r, 128);
}

test "multiply blending is coverage-scaled on soft AA edges" {
    const allocator = testing.allocator;
    var img: Image(Rgba) = try .init(allocator, 40, 40);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);

    canvas.fill(gray);
    canvas.fillCircle(.init(.{ 20, 20 }), 10, gray, .{ .mode = .soft, .blending = .multiply });

    const interior = img.at(20, 20).*.r;
    try expect(interior > 60 and interior < 68);
    // Partial coverage at the radius boundary lies strictly between full multiply and base.
    const edge = img.at(20, 30).*.r;
    try expect(edge > interior and edge < 128);
}

test "opaque fast drawing is identical for none and normal blending" {
    const allocator = testing.allocator;
    var img_none: Image(Rgba) = try .init(allocator, 50, 50);
    defer img_none.deinit(allocator);
    var img_normal: Image(Rgba) = try .init(allocator, 50, 50);
    defer img_normal.deinit(allocator);

    const canvas_none: Canvas(Rgba) = .init(allocator, img_none);
    const canvas_normal: Canvas(Rgba) = .init(allocator, img_normal);

    for ([_]Canvas(Rgba){ canvas_none, canvas_normal }, [_]Blending{ .none, .normal }) |canvas, blending| {
        const opts: DrawOptions = .{ .mode = .fast, .blending = blending };
        canvas.fill(Rgba.white);
        canvas.drawLine(.init(.{ 5, 5 }), .init(.{ 45, 30 }), Rgba.red, 3, opts);
        canvas.fillCircle(.init(.{ 25, 25 }), 10, Rgba.red, opts);
        try canvas.fillPolygon(&.{ .init(.{ 5, 40 }), .init(.{ 45, 40 }), .init(.{ 25, 48 }) }, Rgba.red, opts);
    }

    try expectEqualSlices(Rgba, img_none.data, img_normal.data);
}

test "fast Bresenham lines blend translucent colors" {
    const allocator = testing.allocator;
    var img: Image(Rgba) = try .init(allocator, 30, 30);
    defer img.deinit(allocator);
    const canvas: Canvas(Rgba) = .init(allocator, img);
    canvas.fill(Rgba.white);

    const translucent_black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 128 };
    const opts: DrawOptions = .{ .mode = .fast, .blending = .normal };
    // Horizontal, vertical, and diagonal cover all three Bresenham branches
    canvas.drawLine(.init(.{ 2, 5 }), .init(.{ 27, 5 }), translucent_black, 1, opts);
    canvas.drawLine(.init(.{ 5, 2 }), .init(.{ 5, 27 }), translucent_black, 1, opts);
    canvas.drawLine(.init(.{ 8, 8 }), .init(.{ 27, 27 }), translucent_black, 1, opts);

    for ([_][2]u32{ .{ 5, 10 }, .{ 10, 5 }, .{ 15, 15 } }) |rc| {
        const px = img.at(rc[0], rc[1]).*;
        try expect(px.r > 120 and px.r < 135);
        try expectEqual(px.a, 255);
    }
}

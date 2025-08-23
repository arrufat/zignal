const std = @import("std");
const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;

const Rgba = @import("../../color.zig").Rgba;
const Rectangle = @import("../../geometry.zig").Rectangle;
const Point = @import("../../geometry/Point.zig").Point;
const Image = @import("../../image.zig").Image;
const Canvas = @import("../Canvas.zig").Canvas;

const DrawTestCase = struct {
    name: []const u8,
    md5sum: []const u8,
    draw_fn: *const fn (canvas: Canvas(Rgba)) void,
};

// Test drawing helper functions
fn drawLineHorizontal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    canvas.drawLine(.point(.{ 10, 50 }), .point(.{ 90, 50 }), color, 1, .fast);
}

fn drawLineVertical(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    canvas.drawLine(.point(.{ 50, 10 }), .point(.{ 50, 90 }), color, 1, .fast);
}

fn drawLineDiagonal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    canvas.drawLine(.point(.{ 10, 10 }), .point(.{ 90, 90 }), color, 1, .fast);
}

fn drawLineThick(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 0, .a = 255 };
    canvas.drawLine(.point(.{ 20, 20 }), .point(.{ 80, 80 }), color, 5, .soft);
}

fn drawCircleFilledSolid(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 255, .b = 128, .a = 255 };
    canvas.fillCircle(.point(.{ 50, 50 }), 30, color, .fast);
}

fn drawCircleFilledSmooth(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 128, .b = 255, .a = 255 };
    canvas.fillCircle(.point(.{ 50, 50 }), 25, color, .soft);
}

fn drawCircleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 0, .b = 255, .a = 255 };
    canvas.drawCircle(.point(.{ 50, 50 }), 35, color, 3, .soft);
}

fn drawRectangleFilled(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 64, .g = 128, .b = 192, .a = 255 };
    const rect = Rectangle(f32){ .l = 20, .t = 30, .r = 80, .b = 70 };
    canvas.fillRectangle(rect, color, .fast);
}

fn drawRectangleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 64, .b = 128, .a = 255 };
    const rect = Rectangle(f32){ .l = 15, .t = 25, .r = 85, .b = 75 };
    canvas.drawRectangle(rect, color, 2, .fast);
}

fn drawTriangleFilled(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 192, .b = 128, .a = 255 };
    const triangle = [_]Point(2, f32){
        .point(.{ 50, 20 }),
        .point(.{ 80, 70 }),
        .point(.{ 20, 70 }),
    };
    canvas.fillPolygon(&triangle, color, .soft) catch {};
}

fn drawBezierCubic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 192, .b = 192, .a = 255 };
    const p0 = Point(2, f32).point(.{ 10, 50 });
    const p1 = Point(2, f32).point(.{ 30, 10 });
    const p2 = Point(2, f32).point(.{ 70, 90 });
    const p3 = Point(2, f32).point(.{ 90, 50 });
    canvas.drawCubicBezier(p0, p1, p2, p3, color, 2, .soft);
}

fn drawBezierQuadratic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 192, .a = 255 };
    const p0 = Point(2, f32).point(.{ 20, 80 });
    const p1 = Point(2, f32).point(.{ 50, 20 });
    const p2 = Point(2, f32).point(.{ 80, 80 });
    canvas.drawQuadraticBezier(p0, p1, p2, color, 3, .soft);
}

fn drawPolygonComplex(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 255, .b = 128, .a = 255 };
    const polygon = [_]Point(2, f32){
        .point(.{ 50, 10 }),
        .point(.{ 70, 30 }),
        .point(.{ 90, 40 }),
        .point(.{ 70, 60 }),
        .point(.{ 50, 90 }),
        .point(.{ 30, 60 }),
        .point(.{ 10, 40 }),
        .point(.{ 30, 30 }),
    };
    canvas.fillPolygon(&polygon, color, .soft) catch {};
}

fn drawSplinePolygon(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 128, .b = 255, .a = 255 };
    const polygon = [_]Point(2, f32){
        .point(.{ 50, 20 }),
        .point(.{ 80, 35 }),
        .point(.{ 80, 65 }),
        .point(.{ 50, 80 }),
        .point(.{ 20, 65 }),
        .point(.{ 20, 35 }),
    };
    canvas.drawSplinePolygon(&polygon, color, 2, 0.5, .soft);
}

// Arc drawing test functions
fn drawArcQuarter(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 64, .a = 255 };
    const center = Point(2, f32).point(.{ 50, 50 });
    canvas.drawArc(center, 35, 0, std.math.pi / 2.0, color, 2, .fast) catch {};
}

fn drawArcHalf(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 64, .g = 192, .b = 255, .a = 255 };
    const center = Point(2, f32).point(.{ 50, 50 });
    canvas.drawArc(center, 30, 0, std.math.pi, color, 1, .soft) catch {};
}

fn drawArcThick(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 64, .b = 192, .a = 255 };
    const center = Point(2, f32).point(.{ 50, 50 });
    canvas.drawArc(center, 40, std.math.pi / 4.0, 3.0 * std.math.pi / 2.0, color, 5, .fast) catch {};
}

fn fillArcQuarter(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 255, .b = 128, .a = 255 };
    const center = Point(2, f32).point(.{ 50, 50 });
    canvas.fillArc(center, 35, 0, std.math.pi / 2.0, color, .fast) catch {};
}

fn fillArcHalf(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 255, .b = 192, .a = 255 };
    const center = Point(2, f32).point(.{ 50, 50 });
    canvas.fillArc(center, 30, -std.math.pi / 2.0, std.math.pi / 2.0, color, .soft) catch {};
}

fn fillArcFull(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 192, .b = 255, .a = 255 };
    const center = Point(2, f32).point(.{ 50, 50 });
    canvas.fillArc(center, 25, 0, 2.0 * std.math.pi, color, .fast) catch {};
}

const md5_checksums = [_]DrawTestCase{
    .{ .name = "drawLineHorizontal", .md5sum = "96fc75d0d893373c0050e5fe76f5d7ea", .draw_fn = drawLineHorizontal },
    .{ .name = "drawLineVertical", .md5sum = "f7d52e274636af2b20b62172a408b446", .draw_fn = drawLineVertical },
    .{ .name = "drawLineDiagonal", .md5sum = "1aee6bf80fd2e6a849e5520937566478", .draw_fn = drawLineDiagonal },
    .{ .name = "drawLineThick", .md5sum = "d8323d8d6580a34e724873701245f117", .draw_fn = drawLineThick },
    .{ .name = "drawCircleFilledSolid", .md5sum = "7c07494bef879ea27a68b73808d785a7", .draw_fn = drawCircleFilledSolid },
    .{ .name = "drawCircleFilledSmooth", .md5sum = "6b1dbcaf3c4928e8d16c7fc6bfa60e39", .draw_fn = drawCircleFilledSmooth },
    .{ .name = "drawCircleOutline", .md5sum = "16b547f62efe3c4e32a2ee84bfb71521", .draw_fn = drawCircleOutline },
    .{ .name = "drawRectangleFilled", .md5sum = "1112ffbda92473effbd4d44c9722f563", .draw_fn = drawRectangleFilled },
    .{ .name = "drawRectangleOutline", .md5sum = "e8a00365f1d9ba67220af043363c3f0d", .draw_fn = drawRectangleOutline },
    .{ .name = "drawTriangleFilled", .md5sum = "e17bdf311200fe1deb625377d413a064", .draw_fn = drawTriangleFilled },
    .{ .name = "drawBezierCubic", .md5sum = "92d080a680418a3fc14c6c8beff14e01", .draw_fn = drawBezierCubic },
    .{ .name = "drawBezierQuadratic", .md5sum = "c3286e308aaaef5b302129cf67b713c6", .draw_fn = drawBezierQuadratic },
    .{ .name = "drawPolygonComplex", .md5sum = "da9b83426d2118ce99948eabebff91fb", .draw_fn = drawPolygonComplex },
    .{ .name = "drawSplinePolygon", .md5sum = "6bae24f211c7fdd391cb5159dd4e8fd0", .draw_fn = drawSplinePolygon },
    .{ .name = "drawArcQuarter", .md5sum = "028912b02048fa169c8cb808ff669184", .draw_fn = drawArcQuarter },
    .{ .name = "drawArcHalf", .md5sum = "39194cb90d53611a6eb4401e4c28d5bb", .draw_fn = drawArcHalf },
    .{ .name = "drawArcThick", .md5sum = "70595cc2d1252de2e1c10d8debfcea70", .draw_fn = drawArcThick },
    .{ .name = "fillArcQuarter", .md5sum = "acfcff99a739fb974774f392f0c472e2", .draw_fn = fillArcQuarter },
    .{ .name = "fillArcHalf", .md5sum = "7b86da7863384313c943c14f18e30c43", .draw_fn = fillArcHalf },
    .{ .name = "fillArcFull", .md5sum = "3c6832b07c09de096e8ba85712419332", .draw_fn = fillArcFull },
};

test "MD5 checksum regression tests" {
    const allocator = testing.allocator;
    const print_md5sums = @import("build_options").print_md5sums;

    const width = 100;
    const height = 100;

    for (md5_checksums) |test_case| {
        var img = try Image(Rgba).init(allocator, width, height);
        defer img.deinit(allocator);

        // White background
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        const canvas = Canvas(Rgba).init(allocator, img);
        test_case.draw_fn(canvas);

        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(std.mem.sliceAsBytes(img.data));
        var digest: [16]u8 = undefined;
        hasher.final(&digest);

        const computed = std.fmt.bytesToHex(digest, .lower);
        if (print_md5sums) {
            std.debug.print("    .{{ .name = \"{s}\", .md5sum = \"{s}\", .draw_fn = {s} }},\n", .{
                test_case.name,
                computed,
                test_case.name,
            });
        }

        expectEqualStrings(test_case.md5sum, &computed) catch |err| {
            std.debug.print("Test {s} failed: expected {s}, got {s}\n", .{
                test_case.name,
                test_case.md5sum,
                computed,
            });
            return err;
        };
    }
}

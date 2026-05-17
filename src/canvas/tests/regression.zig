const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;

const Rgba = @import("../../color.zig").Rgba(u8);
const Rectangle = @import("../../geometry.zig").Rectangle;
const Point = @import("../../geometry/Point.zig").Point;
const Image = @import("../../image.zig").Image;
const Canvas = @import("../Canvas.zig").Canvas;
const font8x8 = @import("../../font.zig").font8x8;

const DrawTestCase = struct {
    name: []const u8,
    md5sum: []const u8,
    draw_fn: *const fn (canvas: Canvas(Rgba)) void,
};

fn saveDebugImage(allocator: std.mem.Allocator, image: Image(Rgba), name: []const u8) !void {
    const output_dir = "zig-out/test-images";
    const io = Io.Threaded.global_single_threaded.io();
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, output_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ output_dir, name });
    defer allocator.free(path);
    try image.save(io, allocator, path);
}

// Test drawing helper functions
fn drawLineHorizontal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    canvas.drawLine(.init(.{ 10, 50 }), .init(.{ 90, 50 }), color, 1, .fast);
}

fn drawLineVertical(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    canvas.drawLine(.init(.{ 50, 10 }), .init(.{ 50, 90 }), color, 1, .fast);
}

fn drawLineDiagonal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    canvas.drawLine(.init(.{ 10, 10 }), .init(.{ 90, 90 }), color, 1, .fast);
}

fn drawLineThick(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 0, .a = 255 };
    canvas.drawLine(.init(.{ 20, 20 }), .init(.{ 80, 80 }), color, 5, .soft);
}

fn drawCircleFilledSolid(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 255, .b = 128, .a = 255 };
    canvas.fillCircle(.init(.{ 50, 50 }), 30, color, .fast);
}

fn drawCircleFilledSmooth(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 128, .b = 255, .a = 255 };
    canvas.fillCircle(.init(.{ 50, 50 }), 25, color, .soft);
}

fn drawCircleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 0, .b = 255, .a = 255 };
    canvas.drawCircle(.init(.{ 50, 50 }), 35, color, 3, .soft);
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
        .init(.{ 50, 20 }),
        .init(.{ 80, 70 }),
        .init(.{ 20, 70 }),
    };
    canvas.fillPolygon(&triangle, color, .soft) catch {};
}

fn drawBezierCubic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 192, .b = 192, .a = 255 };
    const p0: Point(2, f32) = .init(.{ 10, 50 });
    const p1: Point(2, f32) = .init(.{ 30, 10 });
    const p2: Point(2, f32) = .init(.{ 70, 90 });
    const p3: Point(2, f32) = .init(.{ 90, 50 });
    canvas.drawCubicBezier(p0, p1, p2, p3, color, 2, .soft);
}

fn drawBezierQuadratic(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 255, .g = 128, .b = 192, .a = 255 };
    const p0: Point(2, f32) = .init(.{ 20, 80 });
    const p1: Point(2, f32) = .init(.{ 50, 20 });
    const p2: Point(2, f32) = .init(.{ 80, 80 });
    canvas.drawQuadraticBezier(p0, p1, p2, color, 3, .soft);
}

fn drawPolygonComplex(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 128, .g = 255, .b = 128, .a = 255 };
    const polygon = [_]Point(2, f32){
        .init(.{ 50, 10 }),
        .init(.{ 70, 30 }),
        .init(.{ 90, 40 }),
        .init(.{ 70, 60 }),
        .init(.{ 50, 90 }),
        .init(.{ 30, 60 }),
        .init(.{ 10, 40 }),
        .init(.{ 30, 30 }),
    };
    canvas.fillPolygon(&polygon, color, .soft) catch {};
}

fn drawSplinePolygon(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 192, .g = 128, .b = 255, .a = 255 };
    const polygon = [_]Point(2, f32){
        .init(.{ 50, 20 }),
        .init(.{ 80, 35 }),
        .init(.{ 80, 65 }),
        .init(.{ 50, 80 }),
        .init(.{ 20, 65 }),
        .init(.{ 20, 35 }),
    };
    canvas.drawSplinePolygon(&polygon, color, 2, 0.5, .soft);
}

// Arc drawing test functions
fn drawArcQuarter(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 255, .g = 128, .b = 64, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.drawArc(center, 35, 0, std.math.pi / 2.0, color, 2, .fast) catch {};
}

fn drawArcHalf(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 64, .g = 192, .b = 255, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.drawArc(center, 30, 0, std.math.pi, color, 1, .soft) catch {};
}

fn drawArcThick(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 128, .g = 64, .b = 192, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.drawArc(center, 40, std.math.pi / 4.0, 3.0 * std.math.pi / 2.0, color, 5, .fast) catch {};
}

fn fillArcQuarter(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 255, .g = 255, .b = 128, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.fillArc(center, 35, 0, std.math.pi / 2.0, color, .fast) catch {};
}

fn fillArcHalf(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 192, .g = 255, .b = 192, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.fillArc(center, 30, -std.math.pi / 2.0, std.math.pi / 2.0, color, .soft) catch {};
}

fn fillArcFull(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 128, .g = 192, .b = 255, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.fillArc(center, 25, 0, 2.0 * std.math.pi, color, .fast) catch {};
}

fn drawLineSoftThin(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 0, .g = 192, .b = 64, .a = 255 };
    canvas.drawLine(.init(.{ 15, 25 }), .init(.{ 85, 75 }), color, 1, .soft);
}

fn drawCircleFastThin(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 255, .g = 64, .b = 64, .a = 255 };
    canvas.drawCircle(.init(.{ 50, 50 }), 30, color, 1, .fast);
}

fn drawCircleFastThick(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 64, .g = 64, .b = 255, .a = 255 };
    canvas.drawCircle(.init(.{ 50, 50 }), 30, color, 5, .fast);
}

fn drawArcSoftThick(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 192, .g = 96, .b = 192, .a = 255 };
    const center: Point(2, f32) = .init(.{ 50, 50 });
    canvas.drawArc(center, 35, 0, std.math.pi, color, 4, .soft) catch {};
}

fn drawRectangleSoft(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 96, .g = 160, .b = 96, .a = 255 };
    const rect: Rectangle(f32) = .{ .l = 15, .t = 25, .r = 85, .b = 75 };
    canvas.drawRectangle(rect, color, 2, .soft);
}

fn fillRectangleSoft(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 64, .g = 128, .b = 192, .a = 128 };
    const rect: Rectangle(f32) = .{ .l = 20, .t = 30, .r = 80, .b = 70 };
    canvas.fillRectangle(rect, color, .soft);
}

fn drawPolygonOutline(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 255, .g = 96, .b = 96, .a = 255 };
    const triangle = [_]Point(2, f32){
        .init(.{ 50, 15 }),
        .init(.{ 85, 75 }),
        .init(.{ 15, 75 }),
    };
    canvas.drawPolygon(&triangle, color, 4, .soft);
}

fn fillPolygonFast(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 192, .g = 192, .b = 64, .a = 255 };
    const triangle = [_]Point(2, f32){
        .init(.{ 50, 20 }),
        .init(.{ 80, 70 }),
        .init(.{ 20, 70 }),
    };
    canvas.fillPolygon(&triangle, color, .fast) catch {};
}

fn drawCubicBezierFast(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 0, .g = 96, .b = 192, .a = 255 };
    canvas.drawCubicBezier(
        .init(.{ 10, 50 }),
        .init(.{ 30, 10 }),
        .init(.{ 70, 90 }),
        .init(.{ 90, 50 }),
        color,
        2,
        .fast,
    );
}

fn drawQuadraticBezierFast(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 192, .g = 96, .b = 0, .a = 255 };
    canvas.drawQuadraticBezier(
        .init(.{ 20, 80 }),
        .init(.{ 50, 20 }),
        .init(.{ 80, 80 }),
        color,
        3,
        .fast,
    );
}

fn drawSplinePolygonFast(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 96, .g = 192, .b = 192, .a = 255 };
    const polygon = [_]Point(2, f32){
        .init(.{ 50, 20 }),
        .init(.{ 80, 35 }),
        .init(.{ 80, 65 }),
        .init(.{ 50, 80 }),
        .init(.{ 20, 65 }),
        .init(.{ 20, 35 }),
    };
    canvas.drawSplinePolygon(&polygon, color, 2, 0.5, .fast);
}

fn fillSplinePolygonSoft(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 128, .g = 64, .b = 160, .a = 255 };
    const polygon = [_]Point(2, f32){
        .init(.{ 50, 18 }),
        .init(.{ 82, 35 }),
        .init(.{ 82, 65 }),
        .init(.{ 50, 82 }),
        .init(.{ 18, 65 }),
        .init(.{ 18, 35 }),
    };
    canvas.fillSplinePolygon(&polygon, color, 0.5, .soft) catch {};
}

fn fillSplinePolygonFast(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 64, .g = 128, .b = 96, .a = 255 };
    const polygon = [_]Point(2, f32){
        .init(.{ 50, 18 }),
        .init(.{ 82, 35 }),
        .init(.{ 82, 65 }),
        .init(.{ 50, 82 }),
        .init(.{ 18, 65 }),
        .init(.{ 18, 35 }),
    };
    canvas.fillSplinePolygon(&polygon, color, 0.5, .fast) catch {};
}

fn drawTextScale1(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 32, .g = 32, .b = 32, .a = 255 };
    canvas.drawText("Zignal!", .init(.{ 8, 46 }), color, font8x8.basic, 1.0, .fast);
}

fn drawTextFastScaled(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 192, .g = 32, .b = 32, .a = 255 };
    canvas.drawText("Hi", .init(.{ 12, 30 }), color, font8x8.basic, 3.0, .fast);
}

fn drawTextSoftScaled(canvas: Canvas(Rgba)) void {
    const color: Rgba = .{ .r = 32, .g = 32, .b = 192, .a = 255 };
    canvas.drawText("Hi", .init(.{ 12, 30 }), color, font8x8.basic, 3.0, .soft);
}

const md5_checksums = [_]DrawTestCase{
    .{ .name = "drawLineHorizontal", .md5sum = "96fc75d0d893373c0050e5fe76f5d7ea", .draw_fn = drawLineHorizontal },
    .{ .name = "drawLineVertical", .md5sum = "f7d52e274636af2b20b62172a408b446", .draw_fn = drawLineVertical },
    .{ .name = "drawLineDiagonal", .md5sum = "1aee6bf80fd2e6a849e5520937566478", .draw_fn = drawLineDiagonal },
    .{ .name = "drawLineThick", .md5sum = "6adde03c10662d65adc6b3c2d71d03aa", .draw_fn = drawLineThick },
    .{ .name = "drawCircleFilledSolid", .md5sum = "7c07494bef879ea27a68b73808d785a7", .draw_fn = drawCircleFilledSolid },
    .{ .name = "drawCircleFilledSmooth", .md5sum = "51d871b8f7fda4e0d21a051b6cbdbae7", .draw_fn = drawCircleFilledSmooth },
    .{ .name = "drawCircleOutline", .md5sum = "89eb018d614857888c0dbcc10d4641a0", .draw_fn = drawCircleOutline },
    .{ .name = "drawRectangleFilled", .md5sum = "1112ffbda92473effbd4d44c9722f563", .draw_fn = drawRectangleFilled },
    .{ .name = "drawRectangleOutline", .md5sum = "e8a00365f1d9ba67220af043363c3f0d", .draw_fn = drawRectangleOutline },
    .{ .name = "drawTriangleFilled", .md5sum = "42377f2ec0a954be5bd1cba5458429f6", .draw_fn = drawTriangleFilled },
    .{ .name = "drawBezierCubic", .md5sum = "c03c2dbbdc34740774d8e8261ce651a5", .draw_fn = drawBezierCubic },
    .{ .name = "drawBezierQuadratic", .md5sum = "e920480a3126ba80768883bb4d64a82f", .draw_fn = drawBezierQuadratic },
    .{ .name = "drawPolygonComplex", .md5sum = "00b8f03a23fa31332eef549318fe7c6e", .draw_fn = drawPolygonComplex },
    .{ .name = "drawSplinePolygon", .md5sum = "649a7ed53ed20ac2c6b67f8b3224c62d", .draw_fn = drawSplinePolygon },
    .{ .name = "drawArcQuarter", .md5sum = "028912b02048fa169c8cb808ff669184", .draw_fn = drawArcQuarter },
    .{ .name = "drawArcHalf", .md5sum = "648732ebb62c3929816c2743a199dff5", .draw_fn = drawArcHalf },
    .{ .name = "drawArcThick", .md5sum = "70595cc2d1252de2e1c10d8debfcea70", .draw_fn = drawArcThick },
    .{ .name = "fillArcQuarter", .md5sum = "acfcff99a739fb974774f392f0c472e2", .draw_fn = fillArcQuarter },
    .{ .name = "fillArcHalf", .md5sum = "560df9fb69b25f57670ff5e45c8855e2", .draw_fn = fillArcHalf },
    .{ .name = "fillArcFull", .md5sum = "3c6832b07c09de096e8ba85712419332", .draw_fn = fillArcFull },
    .{ .name = "drawLineSoftThin", .md5sum = "f6653f14018275770481bf65157b6c34", .draw_fn = drawLineSoftThin },
    .{ .name = "drawCircleFastThin", .md5sum = "78b865a2557fb04de1cbff5532804feb", .draw_fn = drawCircleFastThin },
    .{ .name = "drawCircleFastThick", .md5sum = "04ae64801d4ab0fb0e8a31cb85e484c3", .draw_fn = drawCircleFastThick },
    .{ .name = "drawArcSoftThick", .md5sum = "e4884db05497da75ef4409c867c5111a", .draw_fn = drawArcSoftThick },
    .{ .name = "drawRectangleSoft", .md5sum = "82d9da49d1d13bc0e06b655180ddb142", .draw_fn = drawRectangleSoft },
    .{ .name = "fillRectangleSoft", .md5sum = "88b0b952128335c57d2fefebd8902e8e", .draw_fn = fillRectangleSoft },
    .{ .name = "drawPolygonOutline", .md5sum = "36dda03a5d13989699dc34cde7783076", .draw_fn = drawPolygonOutline },
    .{ .name = "fillPolygonFast", .md5sum = "994fbc386a4251c16bea6ac45819519a", .draw_fn = fillPolygonFast },
    .{ .name = "drawCubicBezierFast", .md5sum = "a068d961085015473fabf9d4dff017b3", .draw_fn = drawCubicBezierFast },
    .{ .name = "drawQuadraticBezierFast", .md5sum = "6207212f5f86d3ece46e457704c05349", .draw_fn = drawQuadraticBezierFast },
    .{ .name = "drawSplinePolygonFast", .md5sum = "9395a428cda3d7e50dc5cccb17bc354d", .draw_fn = drawSplinePolygonFast },
    .{ .name = "fillSplinePolygonSoft", .md5sum = "14c830929dedd6daa8924c1326663d3a", .draw_fn = fillSplinePolygonSoft },
    .{ .name = "fillSplinePolygonFast", .md5sum = "85b923cfdd99827965ca9d2404310b4a", .draw_fn = fillSplinePolygonFast },
    .{ .name = "drawTextScale1", .md5sum = "6aae9a7cc19d3c2045118de0c7e21bc9", .draw_fn = drawTextScale1 },
    .{ .name = "drawTextFastScaled", .md5sum = "043ab942f7991837fb4fd63969857587", .draw_fn = drawTextFastScaled },
    .{ .name = "drawTextSoftScaled", .md5sum = "f2bb866800a6a56b4a65a711f047d422", .draw_fn = drawTextSoftScaled },
};

test "MD5 checksum regression tests" {
    const allocator = testing.allocator;
    const build_options = @import("build_options");
    const print_md5sums = build_options.print_md5sums;
    const debug_test_images = build_options.debug_test_images;

    const width = 100;
    const height = 100;

    for (md5_checksums) |test_case| {
        var img: Image(Rgba) = try .init(allocator, width, height);
        defer img.deinit(allocator);

        // White background
        for (img.data) |*pixel| {
            pixel.* = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        const canvas = Canvas(Rgba).init(allocator, img);
        test_case.draw_fn(canvas);

        if (debug_test_images) {
            saveDebugImage(allocator, img, test_case.name) catch |err| {
                std.debug.print("Failed to save debug image {s}: {}\n", .{ test_case.name, err });
                return err;
            };
        }

        var hasher: std.crypto.hash.Md5 = .init(.{});
        hasher.update(std.mem.sliceAsBytes(img.data));
        var digest: [16]u8 = undefined;
        hasher.final(&digest);

        const computed = std.fmt.bytesToHex(digest, .lower);
        if (print_md5sums) {
            // When refreshing fixtures, print every hash and skip assertions so a single run
            // produces a complete list rather than short-circuiting on the first mismatch.
            std.debug.print("    .{{ .name = \"{s}\", .md5sum = \"{s}\", .draw_fn = {s} }},\n", .{
                test_case.name,
                computed,
                test_case.name,
            });
            continue;
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

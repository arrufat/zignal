const std = @import("std");
const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;

const Rgba = @import("../../color.zig").Rgba(u8);
const Rectangle = @import("../../geometry.zig").Rectangle;
const Point = @import("../../geometry/Point.zig").Point;
const Image = @import("../../image.zig").Image;
const Canvas = @import("../Canvas.zig").Canvas;

const DrawTestCase = struct {
    name: []const u8,
    md5sum: []const u8,
    draw_fn: *const fn (canvas: Canvas(Rgba)) void,
};

fn saveDebugImage(allocator: std.mem.Allocator, image: Image(Rgba), name: []const u8) !void {
    const output_dir = "zig-out/test-images";
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    const cwd = std.Io.Dir.cwd();
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

const md5_checksums = [_]DrawTestCase{
    .{ .name = "drawLineHorizontal", .md5sum = "96fc75d0d893373c0050e5fe76f5d7ea", .draw_fn = drawLineHorizontal },
    .{ .name = "drawLineVertical", .md5sum = "f7d52e274636af2b20b62172a408b446", .draw_fn = drawLineVertical },
    .{ .name = "drawLineDiagonal", .md5sum = "1aee6bf80fd2e6a849e5520937566478", .draw_fn = drawLineDiagonal },
    .{ .name = "drawLineThick", .md5sum = "6adde03c10662d65adc6b3c2d71d03aa", .draw_fn = drawLineThick },
    .{ .name = "drawCircleFilledSolid", .md5sum = "7c07494bef879ea27a68b73808d785a7", .draw_fn = drawCircleFilledSolid },
    .{ .name = "drawCircleFilledSmooth", .md5sum = "595154c90d76861894a5c4e9f822e8c0", .draw_fn = drawCircleFilledSmooth },
    .{ .name = "drawCircleOutline", .md5sum = "89eb018d614857888c0dbcc10d4641a0", .draw_fn = drawCircleOutline },
    .{ .name = "drawRectangleFilled", .md5sum = "1112ffbda92473effbd4d44c9722f563", .draw_fn = drawRectangleFilled },
    .{ .name = "drawRectangleOutline", .md5sum = "e8a00365f1d9ba67220af043363c3f0d", .draw_fn = drawRectangleOutline },
    .{ .name = "drawTriangleFilled", .md5sum = "42377f2ec0a954be5bd1cba5458429f6", .draw_fn = drawTriangleFilled },
    .{ .name = "drawBezierCubic", .md5sum = "312f09be1721dd95a4a9fc10dc1ec28e", .draw_fn = drawBezierCubic },
    .{ .name = "drawBezierQuadratic", .md5sum = "139da685433b44b81f5417f8b045d3f4", .draw_fn = drawBezierQuadratic },
    .{ .name = "drawPolygonComplex", .md5sum = "00b8f03a23fa31332eef549318fe7c6e", .draw_fn = drawPolygonComplex },
    .{ .name = "drawSplinePolygon", .md5sum = "02503d0eca878b8a2b1c13fafb0fd445", .draw_fn = drawSplinePolygon },
    .{ .name = "drawArcQuarter", .md5sum = "028912b02048fa169c8cb808ff669184", .draw_fn = drawArcQuarter },
    .{ .name = "drawArcHalf", .md5sum = "648732ebb62c3929816c2743a199dff5", .draw_fn = drawArcHalf },
    .{ .name = "drawArcThick", .md5sum = "70595cc2d1252de2e1c10d8debfcea70", .draw_fn = drawArcThick },
    .{ .name = "fillArcQuarter", .md5sum = "acfcff99a739fb974774f392f0c472e2", .draw_fn = fillArcQuarter },
    .{ .name = "fillArcHalf", .md5sum = "560df9fb69b25f57670ff5e45c8855e2", .draw_fn = fillArcHalf },
    .{ .name = "fillArcFull", .md5sum = "3c6832b07c09de096e8ba85712419332", .draw_fn = fillArcFull },
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

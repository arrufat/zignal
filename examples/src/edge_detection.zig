const std = @import("std");

const zignal = @import("zignal");

const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Canvas = zignal.Canvas;
const p = zignal.Point(2, f32).init;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var image: Image(Rgb) = try .load(gpa, "../assets/liza.jpg");
    defer image.deinit(gpa);
    var canvas: Canvas(u8) = undefined;

    var scaled = try image.scale(gpa, 0.5, .bilinear);
    defer scaled.deinit(gpa);
    std.debug.print("{f}\n", .{scaled.display(.{ .auto = .{} })});

    var edges: Image(u8) = try .init(gpa, scaled.rows, scaled.cols * 3);
    defer edges.deinit(gpa);
    const font = zignal.font.font8x8.basic;

    const sobel = edges.view(.{ .t = 0, .l = 0, .r = scaled.cols, .b = scaled.rows });
    try scaled.sobel(gpa, sobel);
    canvas = .init(gpa, sobel);
    canvas.drawText("Sobel", p(.{ 0, 0 }), @as(u8, 255), font, 3, .fast);

    const shenCastan = edges.view(.{ .t = 0, .l = scaled.cols, .r = 2 * scaled.cols, .b = scaled.rows });
    try scaled.shenCastan(gpa, .heavy_smooth, shenCastan);
    canvas = .init(gpa, shenCastan);
    canvas.drawText("Shen Castan", p(.{ 0, 0 }), @as(u8, 255), font, 3, .fast);

    const canny = edges.view(.{ .t = 0, .l = 2 * scaled.cols, .r = 3 * scaled.cols, .b = scaled.rows });
    try scaled.canny(gpa, 1.4, 75, 150, canny);
    canvas = .init(gpa, canny);
    canvas.drawText("Canny", p(.{ 0, 0 }), @as(u8, 255), font, 3, .fast);

    std.debug.print("{f}\n", .{edges.display(.{ .auto = .{} })});
    try edges.save(gpa, "edges.png");
}

const std = @import("std");

const zignal = @import("zignal");

const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Canvas = zignal.Canvas;
const p = zignal.Point(2, f32).init;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var image: Image(Rgb) = try .load(init.io, init.gpa, if (args.next()) |arg| arg else "../assets/liza.jpg");
    defer image.deinit(init.gpa);
    var canvas: Canvas(u8) = undefined;

    var scaled = try image.scale(init.gpa, 0.5, .bilinear);
    defer scaled.deinit(init.gpa);
    std.debug.print("{f}\n", .{scaled.display(init.io, .{ .auto = .{} })});

    var edges: Image(u8) = try .init(init.gpa, scaled.rows, scaled.cols * 3);
    defer edges.deinit(init.gpa);
    const font = zignal.font.font8x8.basic;

    const sobel = edges.view(.{ .t = 0, .l = 0, .r = scaled.cols, .b = scaled.rows });
    try scaled.sobel(init.gpa, sobel);
    canvas = .init(init.gpa, sobel);
    canvas.drawText("Sobel", p(.{ 0, 0 }), @as(u8, 255), font, 3, .fast);

    const shenCastan = edges.view(.{ .t = 0, .l = scaled.cols, .r = 2 * scaled.cols, .b = scaled.rows });
    try scaled.shenCastan(init.gpa, .heavy_smooth, shenCastan);
    canvas = .init(init.gpa, shenCastan);
    canvas.drawText("Shen Castan", p(.{ 0, 0 }), @as(u8, 255), font, 3, .fast);

    const canny = edges.view(.{ .t = 0, .l = 2 * scaled.cols, .r = 3 * scaled.cols, .b = scaled.rows });
    try scaled.canny(init.gpa, 1.4, 75, 150, canny);
    canvas = .init(init.gpa, canny);
    canvas.drawText("Canny", p(.{ 0, 0 }), @as(u8, 255), font, 3, .fast);

    std.debug.print("{f}\n", .{edges.display(init.io, .{ .auto = .{} })});
    try edges.save(init.io, init.gpa, "edges.png");
}

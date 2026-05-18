const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var image: Image(Rgba) = try .load(init.io, init.gpa, if (args.next()) |arg| arg else "../assets/liza.jpg");
    defer image.deinit(init.gpa);

    var edges: Image(u8) = try .init(init.gpa, image.rows, image.cols);
    defer edges.deinit(init.gpa);

    try image.sobel(edges, init.gpa);
    try edges.save(init.io, init.gpa, "image-demo-sobel.png");

    var blurred: Image(Rgba) = try .init(init.gpa, image.rows, image.cols);
    defer blurred.deinit(init.gpa);
    try image.gaussianBlur(blurred, init.gpa, 5.0);
    try blurred.save(init.io, init.gpa, "image-demo-gaussian.png");

    var resized: Image(Rgba) = try .init(init.gpa, image.rows / 2, image.cols / 2);
    defer resized.deinit(init.gpa);
    image.resize(resized, init.gpa, .nearest);
    try resized.save(init.io, init.gpa, "image-demo-resized-nearest.png");
    image.resize(resized, init.gpa, .bilinear);
    try resized.save(init.io, init.gpa, "image-demo-resized-bilinear.png");
    image.resize(resized, init.gpa, .bicubic);
    try resized.save(init.io, init.gpa, "image-demo-resized-bicubic.png");
    image.resize(resized, init.gpa, .catmull_rom);
    try resized.save(init.io, init.gpa, "image-demo-resized-catmull-rom.png");
    image.resize(resized, init.gpa, .{ .mitchell = .default });
    try resized.save(init.io, init.gpa, "image-demo-resized-mitchell.png");
    image.resize(resized, init.gpa, .lanczos);
    try resized.save(init.io, init.gpa, "image-demo-resized-lanczos.png");
    std.debug.print("{f}\n", .{image});
    std.debug.print("{f}\n", .{image.display(init.io, .{ .auto = .{} })});
}

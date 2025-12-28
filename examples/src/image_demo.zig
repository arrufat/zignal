const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);
const Gray = zignal.Gray(u8);

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = std.Io.Threaded.global_single_threaded.ioBasic();

    var image: Image(Rgba) = try .load(io, gpa, "../assets/liza.jpg");
    defer image.deinit(gpa);

    var edges: Image(u8) = try .init(gpa, image.rows, image.cols);
    defer edges.deinit(gpa);

    try image.sobel(gpa, edges);
    try edges.save(io, gpa, "liza-sobel.png");

    var blurred: Image(Rgba) = try .init(gpa, image.rows, image.cols);
    defer blurred.deinit(gpa);
    try image.gaussianBlur(gpa, 5.0, blurred);
    try blurred.save(io, gpa, "liza-gaussian.png");

    var resized: Image(Rgba) = try .init(gpa, image.rows / 2, image.cols / 2);
    defer resized.deinit(gpa);
    try image.resize(gpa, resized, .nearest_neighbor);
    try resized.save(io, gpa, "liza-resized-nearest.png");
    try image.resize(gpa, resized, .bilinear);
    try resized.save(io, gpa, "liza-resized-bilinear.png");
    try image.resize(gpa, resized, .bicubic);
    try resized.save(io, gpa, "liza-resized-bicubic.png");
    try image.resize(gpa, resized, .catmull_rom);
    try resized.save(io, gpa, "liza-resized-catmull-rom.png");
    try image.resize(gpa, resized, .{ .mitchell = .default });
    try resized.save(io, gpa, "liza-resized-mitchell.png");
    try image.resize(gpa, resized, .lanczos);
    try resized.save(io, gpa, "liza-resized-lanczos.png");
    std.debug.print("{f}\n", .{image});
    std.debug.print("{f}\n", .{image.display(io, .{ .auto = .{} })});
}

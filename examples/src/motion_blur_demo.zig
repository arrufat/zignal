const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var image: Image(Rgb) = try .load(init.io, init.gpa, if (args.next()) |arg| arg else "../assets/liza.jpg");
    defer image.deinit(init.gpa);

    std.debug.print("Loaded image: {}x{}\n", .{ image.cols, image.rows });

    // Create output images for different blur effects
    var horizontal_blur: Image(Rgb) = try .initLike(init.gpa, image);
    defer horizontal_blur.deinit(init.gpa);

    var vertical_blur: Image(Rgb) = try .initLike(init.gpa, image);
    defer vertical_blur.deinit(init.gpa);

    var diagonal_blur: Image(Rgb) = try .initLike(init.gpa, image);
    defer diagonal_blur.deinit(init.gpa);

    var zoom_blur: Image(Rgb) = try .initLike(init.gpa, image);
    defer zoom_blur.deinit(init.gpa);

    var spin_blur: Image(Rgb) = try .initLike(init.gpa, image);
    defer spin_blur.deinit(init.gpa);

    // Apply different motion blur effects using the unified API
    std.debug.print("Applying horizontal motion blur...\n", .{});
    try image.motionBlur(init.gpa, .{ .linear = .{ .angle = 0, .distance = 30 } }, horizontal_blur);
    try horizontal_blur.save(init.io, init.gpa, "motion-blur-horizontal.png");

    std.debug.print("Applying vertical motion blur...\n", .{});
    try image.motionBlur(init.gpa, .{ .linear = .{ .angle = std.math.pi / 2.0, .distance = 30 } }, vertical_blur);
    try vertical_blur.save(init.io, init.gpa, "motion-blur-vertical.png");

    std.debug.print("Applying diagonal motion blur...\n", .{});
    try image.motionBlur(init.gpa, .{ .linear = .{ .angle = std.math.pi / 4.0, .distance = 25 } }, diagonal_blur);
    try diagonal_blur.save(init.io, init.gpa, "motion-blur-diagonal.png");

    std.debug.print("Applying zoom blur...\n", .{});
    try image.motionBlur(init.gpa, .{ .radial_zoom = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.7 } }, zoom_blur);
    try zoom_blur.save(init.io, init.gpa, "motion-blur-zoom.png");

    std.debug.print("Applying spin blur...\n", .{});
    try image.motionBlur(init.gpa, .{ .radial_spin = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.5 } }, spin_blur);
    try spin_blur.save(init.io, init.gpa, "motion-blur-spin.png");

    std.debug.print("Motion blur examples saved successfully!\n", .{});
}

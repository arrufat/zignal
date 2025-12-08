const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load the source image
    var image: Image(Rgb) = try .load(allocator, "../assets/liza.jpg");
    defer image.deinit(allocator);

    std.debug.print("Loaded image: {}x{}\n", .{ image.cols, image.rows });

    // Create output images for different blur effects
    var horizontal_blur: Image(Rgb) = .empty;
    defer horizontal_blur.deinit(allocator);

    var vertical_blur: Image(Rgb) = .empty;
    defer vertical_blur.deinit(allocator);

    var diagonal_blur: Image(Rgb) = .empty;
    defer diagonal_blur.deinit(allocator);

    var zoom_blur: Image(Rgb) = .empty;
    defer zoom_blur.deinit(allocator);

    var spin_blur: Image(Rgb) = .empty;
    defer spin_blur.deinit(allocator);

    // Apply different motion blur effects using the unified API
    std.debug.print("Applying horizontal motion blur...\n", .{});
    try image.motionBlur(allocator, .{ .linear = .{ .angle = 0, .distance = 30 } }, horizontal_blur);
    try horizontal_blur.save(allocator, "motion_blur_horizontal.png");

    std.debug.print("Applying vertical motion blur...\n", .{});
    try image.motionBlur(allocator, .{ .linear = .{ .angle = std.math.pi / 2.0, .distance = 30 } }, vertical_blur);
    try vertical_blur.save(allocator, "motion_blur_vertical.png");

    std.debug.print("Applying diagonal motion blur...\n", .{});
    try image.motionBlur(allocator, .{ .linear = .{ .angle = std.math.pi / 4.0, .distance = 25 } }, diagonal_blur);
    try diagonal_blur.save(allocator, "motion_blur_diagonal.png");

    std.debug.print("Applying zoom blur...\n", .{});
    try image.motionBlur(allocator, .{ .radial_zoom = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.7 } }, zoom_blur);
    try zoom_blur.save(allocator, "motion_blur_zoom.png");

    std.debug.print("Applying spin blur...\n", .{});
    try image.motionBlur(allocator, .{ .radial_spin = .{ .center_x = 0.5, .center_y = 0.5, .strength = 0.5 } }, spin_blur);
    try spin_blur.save(allocator, "motion_blur_spin.png");

    std.debug.print("Motion blur examples saved successfully!\n", .{});
}

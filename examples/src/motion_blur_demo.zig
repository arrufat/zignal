const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb;

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

    // Apply different motion blur effects
    std.debug.print("Applying horizontal motion blur...\n", .{});
    try image.linearMotionBlur(allocator, 0, 30, &horizontal_blur);
    try horizontal_blur.save(allocator, "motion_blur_horizontal.png");

    std.debug.print("Applying vertical motion blur...\n", .{});
    try image.linearMotionBlur(allocator, std.math.pi / 2.0, 30, &vertical_blur);
    try vertical_blur.save(allocator, "motion_blur_vertical.png");

    std.debug.print("Applying diagonal motion blur...\n", .{});
    try image.linearMotionBlur(allocator, std.math.pi / 4.0, 25, &diagonal_blur);
    try diagonal_blur.save(allocator, "motion_blur_diagonal.png");

    std.debug.print("Applying zoom blur...\n", .{});
    const RadialBlurType = @TypeOf(image).RadialBlurType;
    try image.radialMotionBlur(allocator, 0.5, 0.5, 0.7, RadialBlurType.zoom, &zoom_blur);
    try zoom_blur.save(allocator, "motion_blur_zoom.png");

    std.debug.print("Applying spin blur...\n", .{});
    try image.radialMotionBlur(allocator, 0.5, 0.5, 0.5, RadialBlurType.spin, &spin_blur);
    try spin_blur.save(allocator, "motion_blur_spin.png");

    std.debug.print("Motion blur examples saved successfully!\n", .{});
}

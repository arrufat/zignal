const std = @import("std");

const zignal = @import("zignal");
const BruteForceMatcher = zignal.BruteForceMatcher;
const Canvas = zignal.Canvas;
const Image = zignal.Image;
const Orb = zignal.Orb;
const Point = zignal.Point;
const Rgb = zignal.Rgb;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // Load test image (you can change this path)
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const image_path = if (args.next()) |arg| arg else "../assets/liza.jpg";

    // Load image
    var image = try Image(Rgb).load(gpa, image_path);
    defer image.deinit(gpa);

    std.debug.print("Loaded image: {}x{} pixels\n", .{ image.cols, image.rows });

    // Convert to grayscale
    var gray = try image.convert(u8, gpa);
    defer gray.deinit(gpa);

    std.debug.print("Converted to grayscale\n", .{});

    // Create ORB detector
    var orb: Orb = .{
        .n_features = 500,
        .scale_factor = 1.2,
        .n_levels = 8,
        .fast_threshold = 20,
    };

    // Detect and compute features
    const result = try orb.detectAndCompute(gray, gpa);
    defer gpa.free(result.keypoints);
    defer gpa.free(result.descriptors);

    std.debug.print("Detected {} ORB features\n", .{result.keypoints.len});

    // Print first few keypoints
    const n_print = @min(5, result.keypoints.len);
    for (result.keypoints[0..n_print], 0..) |kp, i| {
        std.debug.print("  Keypoint {}: pos=({d:.1}, {d:.1}), size={d:.1}, angle={d:.1}°, octave={}\n", .{ i, kp.x, kp.y, kp.size, kp.angle, kp.octave });
    }

    // Compute some statistics about the descriptors
    if (result.descriptors.len > 0) {
        var total_bits: u32 = 0;
        for (result.descriptors) |desc| {
            total_bits += desc.popCount();
        }
        const avg_bits = @as(f32, @floatFromInt(total_bits)) / @as(f32, @floatFromInt(result.descriptors.len));
        std.debug.print("Average descriptor bits set: {d:.1}/256\n", .{avg_bits});
    }

    // Test matching between two copies (should give perfect matches)
    if (result.descriptors.len > 0) {
        const matcher: BruteForceMatcher = .{
            .max_distance = 64,
            .cross_check = false,
        };

        const matches = try matcher.match(result.descriptors, result.descriptors, gpa);
        defer gpa.free(matches);

        std.debug.print("Self-matching: {} matches found (should equal number of features)\n", .{matches.len});
    }

    // Visualize features on the original image
    var canvas: Canvas(Rgb) = .init(gpa, image);

    // Define colors for different octaves
    const colors = [_]Rgb{
        .{ .r = 255, .g = 0, .b = 0 }, // Red for octave 0
        .{ .r = 0, .g = 255, .b = 0 }, // Green for octave 1
        .{ .r = 0, .g = 0, .b = 255 }, // Blue for octave 2
        .{ .r = 255, .g = 255, .b = 0 }, // Yellow for octave 3
        .{ .r = 255, .g = 0, .b = 255 }, // Magenta for octave 4
        .{ .r = 0, .g = 255, .b = 255 }, // Cyan for octave 5+
        .{ .r = 255, .g = 128, .b = 0 }, // Orange for octave 6+
        .{ .r = 128, .g = 0, .b = 255 }, // Purple for octave 7+
    };

    std.debug.print("Drawing {} features on image...\n", .{result.keypoints.len});
    std.debug.print("Color coding: Red=L0, Green=L1, Blue=L2, Yellow=L3, Magenta=L4, Cyan=L5+\n", .{});

    // Draw each keypoint
    for (result.keypoints) |kp| {
        const color_idx = @min(@as(usize, @intCast(kp.octave)), colors.len - 1);
        const color = colors[color_idx];

        // Draw circle at keypoint location
        const center: Point(2, f32) = .point(.{ kp.x, kp.y });
        // Calculate patch size like OpenCV using ORB's default patch size
        const patch_size = @as(f32, @floatFromInt(Orb.DEFAULT_PATCH_SIZE));
        const scale = std.math.pow(f32, orb.scale_factor, @as(f32, @floatFromInt(kp.octave)));
        const radius = @max(3.0, (patch_size * scale) / 2);
        canvas.drawCircle(center, radius, color, 2, .soft);

        // Draw orientation line
        const angle_rad = std.math.degreesToRadians(kp.angle);
        const line_length = radius * 2;
        const end_x = kp.x + @cos(angle_rad) * line_length;
        const end_y = kp.y + @sin(angle_rad) * line_length;
        const end_point: Point(2, f32) = .point(.{ end_x, end_y });

        canvas.drawLine(center, end_point, color, 1, .soft);
    }

    // Save visualization
    try image.save(gpa, "orb_features.png");
    std.debug.print("Saved visualization to orb_features.png\n", .{});
}

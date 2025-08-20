const std = @import("std");

const zignal = @import("zignal");
const BruteForceMatcher = zignal.BruteForceMatcher;
const Canvas = zignal.Canvas;
const Image = zignal.Image;
const Orb = zignal.Orb;
const Point = zignal.Point;
const Rgb = zignal.Rgb;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get image path from args or use default
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const image_path = if (args.next()) |arg| arg else "../assets/liza.jpg";

    // Load original image
    var original: Image(Rgb) = try .load(allocator, image_path);
    defer original.deinit(allocator);

    std.debug.print("=== ORB Feature Detection and Matching Demo ===\n\n", .{});
    std.debug.print("Loaded image: {}x{} pixels\n", .{ original.cols, original.rows });

    // Part 1: Feature Detection Visualization
    std.debug.print("\n--- Part 1: Feature Detection ---\n", .{});

    // Convert to grayscale
    var gray_original = try original.convert(u8, allocator);
    defer gray_original.deinit(allocator);

    // Create ORB detector
    var orb: Orb = .{
        .n_features = 100,
        .scale_factor = 1.2,
        .n_levels = 8,
        .fast_threshold = 20,
    };

    // Detect and compute features on original
    const original_features = try orb.detectAndCompute(gray_original, allocator);
    defer allocator.free(original_features.keypoints);
    defer allocator.free(original_features.descriptors);

    std.debug.print("Detected {} ORB features\n", .{original_features.keypoints.len});

    // Create a copy for feature visualization
    var feature_viz = try original.dupe(allocator);
    defer feature_viz.deinit(allocator);

    // Visualize features on the copy
    var canvas: Canvas(Rgb) = .init(allocator, feature_viz);

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

    std.debug.print("Drawing {} features with color-coded octaves...\n", .{original_features.keypoints.len});
    std.debug.print("Color coding: Red=L0, Green=L1, Blue=L2, Yellow=L3, Magenta=L4, Cyan=L5+\n", .{});

    // Draw each keypoint
    for (original_features.keypoints) |kp| {
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

    // Save feature detection visualization
    try feature_viz.save(allocator, "orb_features.png");
    std.debug.print("Saved feature visualization to orb_features.png\n", .{});

    // Part 2: Feature Matching Visualization
    std.debug.print("\n--- Part 2: Feature Matching ---\n", .{});

    // Create rotated image for matching demo
    const angle_rad = std.math.degreesToRadians(45.0);
    var rotated: Image(Rgb) = .empty;
    try original.rotate(allocator, angle_rad, .bilinear, &rotated);
    defer rotated.deinit(allocator);

    std.debug.print("Created rotated image (45 degrees): {}x{} pixels\n", .{ rotated.cols, rotated.rows });

    // Convert rotated to grayscale
    var gray_rotated = try rotated.convert(u8, allocator);
    defer gray_rotated.deinit(allocator);

    // Detect features in rotated image
    const rotated_features = try orb.detectAndCompute(gray_rotated, allocator);
    defer allocator.free(rotated_features.keypoints);
    defer allocator.free(rotated_features.descriptors);

    std.debug.print("Rotated image: {} ORB features detected\n", .{rotated_features.keypoints.len});

    // Match features using BruteForceMatcher
    const matcher: BruteForceMatcher = .{
        .max_distance = 80,
        .cross_check = true,
    };

    const matches = try matcher.match(
        original_features.descriptors,
        rotated_features.descriptors,
        allocator,
    );
    defer allocator.free(matches);

    std.debug.print("Found {} matches between images\n", .{matches.len});

    // Create visualization: concatenate images side by side
    const combined_width = original.cols + rotated.cols;
    const combined_height = @max(original.rows, rotated.rows);
    var match_viz = try Image(Rgb).initAlloc(allocator, combined_height, combined_width);
    defer match_viz.deinit(allocator);

    // Fill with black
    for (0..match_viz.rows) |y| {
        for (0..match_viz.cols) |x| {
            match_viz.at(y, x).* = .{ .r = 0, .g = 0, .b = 0 };
        }
    }

    // Copy original image to left side
    for (0..original.rows) |y| {
        for (0..original.cols) |x| {
            match_viz.at(y, x).* = original.at(y, x).*;
        }
    }

    // Copy rotated image to right side
    for (0..rotated.rows) |y| {
        for (0..rotated.cols) |x| {
            match_viz.at(y, x + original.cols).* = rotated.at(y, x).*;
        }
    }

    // Draw matches
    var match_canvas: Canvas(Rgb) = .init(allocator, match_viz);

    // Draw keypoints and matching lines
    for (matches) |match| {
        const kp1 = original_features.keypoints[match.query_idx];
        const kp2 = rotated_features.keypoints[match.train_idx];

        // Points in combined image
        const p1: Point(2, f32) = .point(.{ kp1.x, kp1.y });
        const p2: Point(2, f32) = .point(.{ kp2.x + @as(f32, @floatFromInt(original.cols)), kp2.y });

        // Draw line between matches (green for good matches)
        const color = if (match.distance < 50)
            Rgb{ .r = 0, .g = 255, .b = 0 } // Green for very good matches
        else
            Rgb{ .r = 255, .g = 255, .b = 0 }; // Yellow for okay matches

        match_canvas.drawLine(p1, p2, color, 2, .soft);

        // Draw keypoints
        match_canvas.drawCircle(p1, 3, Rgb{ .r = 255, .g = 0, .b = 0 }, 2, .soft);
        match_canvas.drawCircle(p2, 3, Rgb{ .r = 0, .g = 0, .b = 255 }, 2, .soft);
    }

    // Save matching visualization
    try match_viz.save(allocator, "orb_matches.png");
    std.debug.print("Saved matching visualization to orb_matches.png\n", .{});

    // Print match statistics
    if (matches.len > 0) {
        var total_distance: f32 = 0;
        var min_distance: f32 = std.math.inf(f32);
        var max_distance: f32 = 0;

        for (matches) |match| {
            total_distance += match.distance;
            min_distance = @min(min_distance, match.distance);
            max_distance = @max(max_distance, match.distance);
        }

        const avg_distance = total_distance / @as(f32, @floatFromInt(matches.len));
        std.debug.print("\nMatch statistics:\n", .{});
        std.debug.print("  Average distance: {d:.2}\n", .{avg_distance});
        std.debug.print("  Min distance: {d:.2}\n", .{min_distance});
        std.debug.print("  Max distance: {d:.2}\n", .{max_distance});
    }
}

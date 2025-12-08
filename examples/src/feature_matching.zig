const std = @import("std");
const builtin = @import("builtin");

const zignal = @import("zignal");
const BruteForceMatcher = zignal.BruteForceMatcher;
const Canvas = zignal.Canvas;
const Image = zignal.Image;
const Orb = zignal.Orb;
const Point = zignal.Point;
const Rgba = zignal.Rgba(u8);

// WASM-specific imports
const js = @import("js.zig");
pub const alloc = js.alloc;
pub const free = js.free;

pub const std_options: std.Options = .{
    .logFn = js.logFn,
    .log_level = std.log.default_level,
};

// Shared visualization function that creates a combined image with matches drawn
fn createMatchVisualizationWithParams(
    allocator: std.mem.Allocator,
    img1_rgba: Image(Rgba),
    img2_rgba: Image(Rgba),
    n_features: u16,
    scale_factor: f32,
    n_levels: u8,
    fast_threshold: u8,
    max_distance: u32,
    cross_check: bool,
    ratio_threshold: f32,
) !Image(Rgba) {
    // Convert directly to grayscale for feature detection
    var gray1 = try img1_rgba.convert(u8, allocator);
    defer gray1.deinit(allocator);

    var gray2 = try img2_rgba.convert(u8, allocator);
    defer gray2.deinit(allocator);

    // Create ORB detector with custom parameters
    var orb: Orb = .{
        .n_features = n_features,
        .scale_factor = scale_factor,
        .n_levels = n_levels,
        .fast_threshold = fast_threshold,
    };

    // Detect features in both images
    const features1 = try orb.detectAndCompute(gray1, allocator);
    defer allocator.free(features1.keypoints);
    defer allocator.free(features1.descriptors);

    const features2 = try orb.detectAndCompute(gray2, allocator);
    defer allocator.free(features2.keypoints);
    defer allocator.free(features2.descriptors);

    std.log.info("Image 1: {} features detected", .{features1.keypoints.len});
    std.log.info("Image 2: {} features detected", .{features2.keypoints.len});

    // Match features with custom parameters
    const matcher: BruteForceMatcher = .{
        .max_distance = max_distance,
        .cross_check = cross_check,
        .ratio_threshold = ratio_threshold,
    };

    const matches = try matcher.match(features1.descriptors, features2.descriptors, allocator);
    defer allocator.free(matches);

    std.log.info("Found {} matches between images", .{matches.len});

    // Create visualization: concatenate images side by side
    const gap = 10;
    const combined_width = img1_rgba.cols + gap + img2_rgba.cols;
    const combined_height = @max(img1_rgba.rows, img2_rgba.rows);
    var viz = try Image(Rgba).init(allocator, combined_height, combined_width);
    errdefer viz.deinit(allocator);

    // Fill with dark background
    for (0..viz.rows) |y| {
        for (0..viz.cols) |x| {
            viz.at(y, x).* = .{ .r = 30, .g = 30, .b = 30, .a = 255 };
        }
    }

    // Copy first image to left side
    for (0..img1_rgba.rows) |y| {
        for (0..img1_rgba.cols) |x| {
            viz.at(y, x).* = img1_rgba.at(y, x).*;
        }
    }

    // Copy second image to right side
    const offset_x = img1_rgba.cols + gap;
    for (0..img2_rgba.rows) |y| {
        for (0..img2_rgba.cols) |x| {
            viz.at(y, x + offset_x).* = img2_rgba.at(y, x).*;
        }
    }

    // Draw matches and keypoints
    var canvas: Canvas(Rgba) = .init(allocator, viz);

    // Define colors for different octaves
    const octave_colors = [_]Rgba{
        .{ .r = 255, .g = 0, .b = 0, .a = 255 }, // Red
        .{ .r = 0, .g = 255, .b = 0, .a = 255 }, // Green
        .{ .r = 0, .g = 0, .b = 255, .a = 255 }, // Blue
        .{ .r = 255, .g = 255, .b = 0, .a = 255 }, // Yellow
        .{ .r = 255, .g = 0, .b = 255, .a = 255 }, // Magenta
        .{ .r = 0, .g = 255, .b = 255, .a = 255 }, // Cyan
        .{ .r = 255, .g = 128, .b = 0, .a = 255 }, // Orange
        .{ .r = 128, .g = 0, .b = 255, .a = 255 }, // Purple
    };

    // Draw match lines first (so they appear under keypoints)
    for (matches) |match| {
        const kp1 = features1.keypoints[match.query_idx];
        const kp2 = features2.keypoints[match.train_idx];

        // Points in combined image
        const p1: Point(2, f32) = .init(.{ kp1.x, kp1.y });
        const p2: Point(2, f32) = .init(.{ kp2.x + @as(f32, @floatFromInt(offset_x)), kp2.y });

        // Color based on match quality
        const color = if (match.distance < 30)
            Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 } // Green - excellent
        else if (match.distance < 50)
            Rgba{ .r = 255, .g = 255, .b = 0, .a = 255 } // Yellow - good
        else if (match.distance < 70)
            Rgba{ .r = 255, .g = 128, .b = 0, .a = 255 } // Orange - fair
        else
            Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }; // Red - poor

        canvas.drawLine(p1, p2, color, 2, .soft);
    }

    // Draw keypoints for first image
    for (features1.keypoints) |kp| {
        const color_idx = @min(@as(usize, @intCast(kp.octave)), octave_colors.len - 1);
        const color = octave_colors[color_idx];
        const center: Point(2, f32) = .init(.{ kp.x, kp.y });

        // Draw circle
        const radius = @max(3.0, kp.size / 2);
        canvas.drawCircle(center, radius, color, 2, .soft);

        // Draw orientation line
        const angle_rad = std.math.degreesToRadians(kp.angle);
        const line_length = radius * 2;
        const end_x = kp.x + @cos(angle_rad) * line_length;
        const end_y = kp.y + @sin(angle_rad) * line_length;
        const end_point: Point(2, f32) = .init(.{ end_x, end_y });
        canvas.drawLine(center, end_point, color, 1, .soft);
    }

    // Draw keypoints for second image
    for (features2.keypoints) |kp| {
        const color_idx = @min(@as(usize, @intCast(kp.octave)), octave_colors.len - 1);
        const color = octave_colors[color_idx];
        const center_x = kp.x + @as(f32, @floatFromInt(offset_x));
        const center_y = kp.y;
        const center: Point(2, f32) = .init(.{ center_x, center_y });

        // Draw circle
        const radius = @max(3.0, kp.size / 2);
        canvas.drawCircle(center, radius, color, 2, .soft);

        // Draw orientation line
        const angle_rad = std.math.degreesToRadians(kp.angle);
        const line_length = radius * 2;
        const end_x = center_x + @cos(angle_rad) * line_length;
        const end_y = center_y + @sin(angle_rad) * line_length;
        const end_point: Point(2, f32) = .init(.{ end_x, end_y });
        canvas.drawLine(center, end_point, color, 1, .soft);
    }

    // Log statistics
    if (matches.len > 0) {
        var total_distance: f32 = 0;
        var min_dist: f32 = std.math.inf(f32);
        var max_dist: f32 = 0;

        for (matches) |match| {
            total_distance += match.distance;
            min_dist = @min(min_dist, match.distance);
            max_dist = @max(max_dist, match.distance);
        }

        const avg_distance = total_distance / @as(f32, @floatFromInt(matches.len));
        std.log.info("Match statistics: avg={d:.2}, min={d:.2}, max={d:.2}", .{ avg_distance, min_dist, max_dist });
    }

    return viz;
}

// WASM export function for feature matching - writes directly to output buffer
pub export fn matchAndVisualize(
    image1_ptr: [*]Rgba,
    rows1: usize,
    cols1: usize,
    image2_ptr: [*]Rgba,
    rows2: usize,
    cols2: usize,
    result_ptr: [*]Rgba,
    result_rows: usize,
    result_cols: usize,
    n_features: u16,
    scale_factor: f32,
    n_levels: u8,
    fast_threshold: u8,
    max_distance: u32,
    cross_check: bool,
    ratio_threshold: f32,
) void {
    const allocator = std.heap.wasm_allocator;

    // Create images from input data
    const img1_size = rows1 * cols1;
    const img1: Image(Rgba) = .initFromSlice(rows1, cols1, image1_ptr[0..img1_size]);

    const img2_size = rows2 * cols2;
    const img2: Image(Rgba) = .initFromSlice(rows2, cols2, image2_ptr[0..img2_size]);

    // Use the shared visualization function with custom parameters
    var viz = createMatchVisualizationWithParams(allocator, img1, img2, n_features, scale_factor, n_levels, fast_threshold, max_distance, cross_check, ratio_threshold) catch |err| {
        std.log.err("Failed to create visualization: {}", .{err});
        return;
    };
    defer viz.deinit(allocator);

    // Create output image view
    const result_size = result_rows * result_cols;
    var result: Image(Rgba) = .initFromSlice(result_rows, result_cols, result_ptr[0..result_size]);

    // Copy RGBA visualization to result
    for (0..@min(viz.rows, result_rows)) |y| {
        for (0..@min(viz.cols, result_cols)) |x| {
            result.at(y, x).* = viz.at(y, x).*;
        }
    }
}

// WASM export function to get match statistics
pub export fn getMatchStats(
    image1_ptr: [*]Rgba,
    rows1: usize,
    cols1: usize,
    image2_ptr: [*]Rgba,
    rows2: usize,
    cols2: usize,
    stats_ptr: [*]f32,
    n_features: u16,
    scale_factor: f32,
    n_levels: u8,
    fast_threshold: u8,
    max_distance: u32,
    cross_check: bool,
    ratio_threshold: f32,
) void {
    const allocator = std.heap.wasm_allocator;

    // Create images from input data
    const img1_size = rows1 * cols1;
    const img1: Image(Rgba) = .initFromSlice(rows1, cols1, image1_ptr[0..img1_size]);

    const img2_size = rows2 * cols2;
    const img2: Image(Rgba) = .initFromSlice(rows2, cols2, image2_ptr[0..img2_size]);

    // Convert to grayscale
    var gray1 = img1.convert(u8, allocator) catch {
        for (0..6) |i| stats_ptr[i] = 0;
        return;
    };
    defer gray1.deinit(allocator);

    var gray2 = img2.convert(u8, allocator) catch {
        for (0..6) |i| stats_ptr[i] = 0;
        return;
    };
    defer gray2.deinit(allocator);

    // Detect features with custom parameters
    var orb: Orb = .{
        .n_features = n_features,
        .scale_factor = scale_factor,
        .n_levels = n_levels,
        .fast_threshold = fast_threshold,
    };

    const features1 = orb.detectAndCompute(gray1, allocator) catch {
        for (0..6) |i| stats_ptr[i] = 0;
        return;
    };
    defer allocator.free(features1.keypoints);
    defer allocator.free(features1.descriptors);

    const features2 = orb.detectAndCompute(gray2, allocator) catch {
        stats_ptr[0] = @floatFromInt(features1.keypoints.len);
        for (1..6) |i| stats_ptr[i] = 0;
        return;
    };
    defer allocator.free(features2.keypoints);
    defer allocator.free(features2.descriptors);

    // Match features with custom parameters
    const matcher: BruteForceMatcher = .{
        .max_distance = max_distance,
        .cross_check = cross_check,
        .ratio_threshold = ratio_threshold,
    };

    const matches = matcher.match(features1.descriptors, features2.descriptors, allocator) catch {
        stats_ptr[0] = @floatFromInt(features1.keypoints.len);
        stats_ptr[1] = @floatFromInt(features2.keypoints.len);
        for (2..6) |i| stats_ptr[i] = 0;
        return;
    };
    defer allocator.free(matches);

    // Calculate statistics
    stats_ptr[0] = @floatFromInt(features1.keypoints.len);
    stats_ptr[1] = @floatFromInt(features2.keypoints.len);
    stats_ptr[2] = @floatFromInt(matches.len);

    if (matches.len > 0) {
        var total_distance: f32 = 0;
        var min_dist: f32 = std.math.inf(f32);
        var max_dist: f32 = 0;

        for (matches) |match| {
            total_distance += match.distance;
            min_dist = @min(min_dist, match.distance);
            max_dist = @max(max_dist, match.distance);
        }

        stats_ptr[3] = total_distance / @as(f32, @floatFromInt(matches.len));
        stats_ptr[4] = min_dist;
        stats_ptr[5] = max_dist;
    } else {
        stats_ptr[3] = 0;
        stats_ptr[4] = 0;
        stats_ptr[5] = 0;
    }
}

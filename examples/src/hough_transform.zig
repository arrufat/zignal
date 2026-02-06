const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);
const Canvas = zignal.Canvas;
const Point = zignal.Point;
const HoughTransform = zignal.HoughTransform;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    const input_path = if (args.next()) |arg| arg else "../assets/liza.jpg";
    std.debug.print("Loading {s}...\n", .{input_path});

    var image: Image(Rgba) = try .load(init.io, init.gpa, input_path);
    defer image.deinit(init.gpa);

    // 1. Edge Detection
    std.debug.print("Running edge detection...\n", .{});
    var gray = try image.convert(u8, init.gpa);
    defer gray.deinit(init.gpa);

    var edges = try Image(u8).initLike(init.gpa, gray);
    defer edges.deinit(init.gpa);

    // Use Sobel for edge detection
    try gray.sobel(init.gpa, edges);

    // Threshold edges to make them binary
    try edges.thresholdAdaptiveMean(init.gpa, 15, 5.0, edges);

    // 2. Hough Transform
    const size = @max(image.rows, image.cols);
    std.debug.print("Initializing Hough Transform (size={d})...\n", .{size});

    var hough = try HoughTransform.init(init.gpa, size);
    defer hough.deinit();

    var accumulator = try Image(u32).init(init.gpa, size, size);
    defer accumulator.deinit(init.gpa);
    accumulator.fill(0);

    const box = zignal.Rectangle(u32){ .l = 0, .t = 0, .r = size, .b = size };

    // Resize edges to match hough size if necessary (or just pad/crop logic)
    // For simplicity, let's create a padded edge image of size x size
    var padded_edges = try Image(u8).init(init.gpa, size, size);
    defer padded_edges.deinit(init.gpa);
    padded_edges.fill(0);

    // Copy edges into padded image (centered)
    const offset_r = (size - edges.rows) / 2;
    const offset_c = (size - edges.cols) / 2;

    for (0..edges.rows) |r| {
        for (0..edges.cols) |c| {
            if (edges.at(r, c).* > 0) { // Keep only strong edges
                padded_edges.at(r + offset_r, c + offset_c).* = 255;
            }
        }
    }

    std.debug.print("Computing Hough Transform...\n", .{});
    var timer = try std.time.Timer.start();

    hough.compute(padded_edges, box, accumulator);

    const hough_ns = timer.read();
    std.debug.print("Hough Compute took: {d:.3} ms\n", .{@as(f64, @floatFromInt(hough_ns)) / std.time.ns_per_ms});

    // 3. Find Lines
    std.debug.print("Finding lines...\n", .{});
    // Threshold is somewhat arbitrary, depends on image content
    const threshold = 100;
    const lines = try hough.findLines(accumulator, threshold, 5.0, 5.0, init.gpa);
    defer init.gpa.free(lines);

    std.debug.print("Found {d} lines.\n", .{lines.len});

    // 4. Visualization
    var canvas = Canvas(Rgba).init(init.gpa, image);
    const line_color = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };

    for (lines) |line| {
        // Transform line points back to original image coordinates
        const p1 = Point(2, f32).init(.{ line.p1.x() - @as(f32, @floatFromInt(offset_c)), line.p1.y() - @as(f32, @floatFromInt(offset_r)) });
        const p2 = Point(2, f32).init(.{ line.p2.x() - @as(f32, @floatFromInt(offset_c)), line.p2.y() - @as(f32, @floatFromInt(offset_r)) });

        canvas.drawLine(p1, p2, line_color, 2, .soft);
    }

    try image.save(init.io, init.gpa, "hough_result.png");
    std.debug.print("Saved result to hough_result.png\n", .{});

    // Save accumulator visualization for debug
    var accum_vis = try Image(u8).init(init.gpa, size, size);
    defer accum_vis.deinit(init.gpa);

    // Normalize accumulator for display
    var max_vote: u32 = 0;
    for (0..size) |r| {
        for (0..size) |c| {
            max_vote = @max(max_vote, accumulator.at(r, c).*);
        }
    }

    if (max_vote > 0) {
        for (0..size) |r| {
            for (0..size) |c| {
                const val = accumulator.at(r, c).*;
                const norm = @as(u32, @intFromFloat(@as(f32, @floatFromInt(val)) / @as(f32, @floatFromInt(max_vote)) * 255.0));
                accum_vis.at(r, c).* = @intCast(norm);
            }
        }
    }

    try accum_vis.save(init.io, init.gpa, "hough_accumulator.png");
}

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);
const Canvas = zignal.Canvas;
const Point = zignal.Point;
const HoughTransform = zignal.HoughTransform;
const Rectangle = zignal.Rectangle;

// Helper to rotate a point around a center
fn rotatePoint(center: Point(2, f32), p: Point(2, f32), angle: f32) Point(2, f32) {
    const s = @sin(angle);
    const c = @cos(angle);
    const x = p.x() - center.x();
    const y = p.y() - center.y();
    return Point(2, f32).init(.{
        center.x() + x * c - y * s,
        center.y() + x * s + y * c,
    });
}

// Convert grayscale/heatmap value to Jet colormap RGB
fn jet(v: f32) Rgba {
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;

    if (v < 0.25) {
        r = 0;
        g = 4.0 * v;
        b = 1.0;
    } else if (v < 0.5) {
        r = 0;
        g = 1.0;
        b = 1.0 + 4.0 * (0.25 - v);
    } else if (v < 0.75) {
        r = 4.0 * (v - 0.5);
        g = 1.0;
        b = 0;
    } else {
        r = 1.0;
        g = 1.0 + 4.0 * (0.75 - v);
        b = 0;
    }

    return Rgba{
        .r = @intFromFloat(@max(0, @min(255, r * 255))),
        .g = @intFromFloat(@max(0, @min(255, g * 255))),
        .b = @intFromFloat(@max(0, @min(255, b * 255))),
        .a = 255,
    };
}

pub fn main(init: std.process.Init) !void {
    const size = 400;
    const hough_size = 300;
    const frames = 10; // Generate 10 frames for the example

    var img = try Image(u8).init(init.gpa, size, size);
    defer img.deinit(init.gpa);

    var ht = try HoughTransform.init(init.gpa, hough_size);
    defer ht.deinit();

    var accumulator = try Image(u32).init(init.gpa, hough_size, hough_size);
    defer accumulator.deinit(init.gpa);

    var display_img = try Image(Rgba).init(init.gpa, size, size);
    defer display_img.deinit(init.gpa);

    var acc_img = try Image(Rgba).init(init.gpa, hough_size, hough_size);
    defer acc_img.deinit(init.gpa);

    var angle1: f32 = 0;
    var angle2: f32 = 0;

    const offset_x = 50;
    const offset_y = 50;
    const box = Rectangle(u32){
        .l = offset_x,
        .t = offset_y,
        .r = offset_x + hough_size,
        .b = offset_y + hough_size,
    };

    std.debug.print("Generating {d} frames of Hough Transform animation...\n", .{frames});

    for (0..frames) |i| {
        angle1 += std.math.pi / 13.0; // Faster than dlib example for fewer frames
        angle2 += std.math.pi / 40.0;

        const center_pt = Point(2, f32).init(.{ @as(f32, size) / 2.0, @as(f32, size) / 2.0 });
        const arc = rotatePoint(center_pt, Point(2, f32).init(.{ center_pt.x() + 90.0, center_pt.y() }), angle1);
        const l = rotatePoint(arc, Point(2, f32).init(.{ arc.x() + 500.0, arc.y() }), angle2);
        const r = rotatePoint(arc, Point(2, f32).init(.{ arc.x() - 500.0, arc.y() }), angle2);

        // Clear image
        img.fill(0);

        // Draw input line
        var canvas_gray = Canvas(u8).init(init.gpa, img);
        canvas_gray.drawLine(l, r, @as(u8, 255), 1, .fast);

        // Compute Hough Transform
        accumulator.fill(0);

        // We pass the "box" in absolute image coordinates.
        // The implementation will clip it to the image bounds and process internally.
        ht.compute(img, box, accumulator);

        // Find max point in accumulator
        var max_val: u32 = 0;
        var max_r: usize = 0;
        var max_c: usize = 0;
        for (0..hough_size) |row| {
            for (0..hough_size) |col| {
                const val = accumulator.at(row, col).*;
                if (val > max_val) {
                    max_val = val;
                    max_r = row;
                    max_c = col;
                }
            }
        }

        // Get detected line
        // Note: findLines returns lines in the box's local coordinate system.
        // We simulate `ht.get_line(p)` by manually reconstructing one line from the max peak.
        // In a real usage, we'd use ht.findLines(), but here we want exactly the max one like dlib.
        const lines = try ht.findLines(accumulator, max_val, 0, 0, init.gpa);
        defer init.gpa.free(lines); // Usually only 1 because threshold == max_val

        // Visualization
        img.convertInto(Rgba, display_img); // Copy grayscale to color for drawing
        var canvas = Canvas(Rgba).init(init.gpa, display_img);

        // Draw detected line in red
        // Add offset to coordinates because they are relative to the box
        if (lines.len > 0) {
            const line = lines[0];
            const p1 = Point(2, f32).init(.{ line.p1.x() + offset_x, line.p1.y() + offset_y });
            const p2 = Point(2, f32).init(.{ line.p2.x() + offset_x, line.p2.y() + offset_y });
            canvas.drawLine(p1, p2, Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, 2, .soft);
        }

        // Draw subwindow box in green
        const tl = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.l)), @as(f32, @floatFromInt(box.t)) });
        const tr = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.r)), @as(f32, @floatFromInt(box.t)) });
        const br = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.r)), @as(f32, @floatFromInt(box.b)) });
        const bl = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.l)), @as(f32, @floatFromInt(box.b)) });

        const green = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
        canvas.drawLine(tl, tr, green, 1, .fast);
        canvas.drawLine(tr, br, green, 1, .fast);
        canvas.drawLine(br, bl, green, 1, .fast);
        canvas.drawLine(bl, tl, green, 1, .fast);

        // Save Result Frame
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "hough_frame_{d:03}.png", .{i});
        try display_img.save(init.io, init.gpa, name);

        // Visualize Accumulator (Jet)
        if (max_val > 0) {
            for (0..hough_size) |row| {
                for (0..hough_size) |col| {
                    const norm = @as(f32, @floatFromInt(accumulator.at(row, col).*)) / @as(f32, @floatFromInt(max_val));
                    acc_img.at(row, col).* = jet(norm);
                }
            }
        }
        const acc_name = try std.fmt.bufPrint(&buf, "hough_acc_{d:03}.png", .{i});
        try acc_img.save(init.io, init.gpa, acc_name);
    }
}

const std = @import("std");
const builtin = @import("builtin");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba(u8);
const Canvas = zignal.Canvas;
const Point = zignal.Point;
const HoughTransform = zignal.HoughTransform;
const Rectangle = zignal.Rectangle;

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = .info,
};

comptime {
    _ = js.alloc;
    _ = js.free;
}

// Global state
var hough: HoughTransform = undefined;
var img: Image(u8) = undefined;
var accumulator: Image(u32) = undefined;
var initialized = false;

const size = 400;
const hough_size = 300;

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

pub export fn init() void {
    if (initialized) return;
    const allocator = std.heap.wasm_allocator;

    hough = HoughTransform.init(allocator, hough_size) catch @panic("OOM");
    img = Image(u8).init(allocator, size, size) catch @panic("OOM");
    accumulator = Image(u32).init(allocator, hough_size, hough_size) catch @panic("OOM");
    initialized = true;
    std.log.info("Hough Animation Initialized", .{});
}

pub export fn deinit() void {
    if (!initialized) return;
    const allocator = std.heap.wasm_allocator;
    hough.deinit();
    img.deinit(allocator);
    accumulator.deinit(allocator);
    initialized = false;
}

pub export fn render(img_ptr: [*]Rgba, acc_ptr: [*]Rgba, time_step: f32) void {
    if (!initialized) return;

    // 1. Setup Scene
    const angle1 = time_step * std.math.pi / 13.0;
    const angle2 = time_step * std.math.pi / 40.0;

    const center_pt = Point(2, f32).init(.{ @as(f32, size) / 2.0, @as(f32, size) / 2.0 });
    const arc = rotatePoint(center_pt, Point(2, f32).init(.{ center_pt.x() + 90.0, center_pt.y() }), angle1);
    const l = rotatePoint(arc, Point(2, f32).init(.{ arc.x() + 500.0, arc.y() }), angle2);
    const r = rotatePoint(arc, Point(2, f32).init(.{ arc.x() - 500.0, arc.y() }), angle2);

    // 2. Draw Input
    img.fill(0);
    const allocator = std.heap.wasm_allocator;
    var canvas_gray = Canvas(u8).init(allocator, img);
    canvas_gray.drawLine(l, r, @as(u8, 255), 1, .fast);

    // 3. Compute Hough
    accumulator.fill(0);
    const offset_x = 50;
    const offset_y = 50;
    const box = Rectangle(u32){
        .l = offset_x,
        .t = offset_y,
        .r = offset_x + hough_size,
        .b = offset_y + hough_size,
    };

    hough.compute(img, box, accumulator);

    // 4. Find Max
    var max_val: u32 = 0;
    for (0..hough_size) |row| {
        for (0..hough_size) |col| {
            max_val = @max(max_val, accumulator.at(row, col).*);
        }
    }

    // 5. Output Result Image (Copy input + Draw overlays)
    const result_img = Image(Rgba).initFromSlice(size, size, img_ptr[0 .. size * size]);
    img.convertInto(Rgba, result_img);

    var canvas = Canvas(Rgba).init(allocator, result_img);

    // Draw detected line
    if (max_val > 0) {
        const lines = hough.findLines(accumulator, max_val, 0, 0, allocator) catch &[_]HoughTransform.Line{};
        defer allocator.free(lines);

        if (lines.len > 0) {
            const line = lines[0];
            const p1 = Point(2, f32).init(.{ line.p1.x() + offset_x, line.p1.y() + offset_y });
            const p2 = Point(2, f32).init(.{ line.p2.x() + offset_x, line.p2.y() + offset_y });
            canvas.drawLine(p1, p2, Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, 2, .soft);
        }
    }

    // Draw box
    const tl = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.l)), @as(f32, @floatFromInt(box.t)) });
    const tr = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.r)), @as(f32, @floatFromInt(box.t)) });
    const br = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.r)), @as(f32, @floatFromInt(box.b)) });
    const bl = Point(2, f32).init(.{ @as(f32, @floatFromInt(box.l)), @as(f32, @floatFromInt(box.b)) });

    const green = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    canvas.drawLine(tl, tr, green, 1, .fast);
    canvas.drawLine(tr, br, green, 1, .fast);
    canvas.drawLine(br, bl, green, 1, .fast);
    canvas.drawLine(bl, tl, green, 1, .fast);

    // 6. Output Accumulator Image
    var acc_img = Image(Rgba).initFromSlice(hough_size, hough_size, acc_ptr[0 .. hough_size * hough_size]);
    if (max_val > 0) {
        for (0..hough_size) |row| {
            for (0..hough_size) |col| {
                const norm = @as(f32, @floatFromInt(accumulator.at(row, col).*)) / @as(f32, @floatFromInt(max_val));
                acc_img.at(row, col).* = jet(norm);
            }
        }
    } else {
        acc_img.fill(Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 });
    }
}

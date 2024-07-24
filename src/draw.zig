const std = @import("std");
const as = @import("meta.zig").as;
const Color = @import("color.zig").Color;
const Rgba = @import("color.zig").Rgba;
const Image = @import("image.zig").Image;
const Point2d = @import("point.zig").Point2d(f32);

/// Draws a colored straight of a custom width between p1 and p2 on image.  Moreover, it alpha-blends
/// pixels along diagonal lines.
pub fn drawLine(comptime T: type, image: Image(T), p1: Point2d, p2: Point2d, width: usize, color: T) void {
    // To avoid casting all the time, perform all operations using the underlying type of p1 and p2.
    const Float = @TypeOf(p1.x);
    var x1 = @round(p1.x);
    var y1 = @round(p1.y);
    var x2 = @round(p2.x);
    var y2 = @round(p2.y);
    const rows: Float = @floatFromInt(image.rows);
    const cols: Float = @floatFromInt(image.cols);
    const half_width: Float = @floatFromInt(width / 2);
    const rgba = Color.convert(Rgba, color);

    if (x1 == x2) {
        if (y1 > y2) std.mem.swap(Float, &y1, &y2);
        if (x1 < 0 or x1 >= cols) return;
        var y = y1;
        while (y <= y2) : (y += 1) {
            if (y < 0 or y >= rows) continue;
            var i = -half_width;
            while (i <= half_width) : (i += 1) {
                const px = x1 + i;
                if (px >= 0 and px < cols) {
                    const pos = as(usize, y) * image.cols + as(usize, px);
                    image.data[pos] = color;
                }
            }
        }
    } else if (y1 == y2) {
        if (x1 > x2) std.mem.swap(Float, &x1, &x2);
        if (y1 < 0 or y1 > rows) return;
        var x = x1;
        while (x <= x2) : (x += 1) {
            if (x < 0 or x >= cols) continue;
            var i = -half_width;
            while (i <= half_width) : (i += 1) {
                const py = y1 + i;
                if (py >= 0 and py < rows) {
                    const pos = as(usize, py) * image.cols + as(usize, x);
                    image.data[pos] = color;
                }
            }
        }
    } else {
        // This part is a little more complicated because we are going to perform alpha blending
        // so the diagonal lines look nice.
        var c2 = Color.convert(Rgba, color);
        const max_alpha: Float = @floatFromInt(rgba.a);
        const rise = y2 - y1;
        const run = x2 - x1;
        if (@abs(rise) < @abs(run)) {
            const slope = rise / run;
            const first = if (x1 > x2) @max(x2, 0) else @max(x1, 0);
            const last = if (x1 > x2) @min(x1, cols - 1) else @min(x2, cols - 1);
            var i = first;
            while (i <= last) : (i += 1) {
                const dy = slope * (i - x1) + y1;
                const dx = i;
                const y = @floor(dy);
                const x = @floor(dx);
                if (y >= 0 and y <= rows - 1) {
                    c2.a = @intFromFloat((1 - (dy - y)) * max_alpha);
                    var j = -half_width;
                    while (j <= half_width) : (j += 1) {
                        const py = y + j;
                        const pos = as(usize, py) * image.cols + as(usize, x);
                        if (py >= 0 and py < rows) {
                            if (j == -half_width or j == half_width) {
                                var c1: Rgba = Color.convert(Rgba, image.data[pos]);
                                c1.blend(c2);
                                image.data[pos] = Color.convert(T, c1);
                            } else {
                                image.data[pos] = color;
                            }
                        }
                    }
                }
                if (y + 1 >= 0 and y + 1 <= rows - 1) {
                    c2.a = @intFromFloat((dy - y) * max_alpha);
                    var j = -half_width;
                    while (j <= half_width) : (j += 1) {
                        const py = y + 1 + j;
                        if (py >= 0 and py < rows) {
                            const pos = as(usize, py) * image.cols + as(usize, x);
                            if (j == -half_width or j == half_width) {
                                var c1: Rgba = Color.convert(Rgba, image.data[pos]);
                                c1.blend(c2);
                                image.data[pos] = Color.convert(T, c1);
                            } else {
                                image.data[pos] = color;
                            }
                        }
                    }
                }
            }
        } else {
            const slope = run / rise;
            const first = if (y1 > y2) @max(y2, 0) else @max(y1, 0);
            const last = if (y1 > y2) @min(y1, rows - 1) else @min(y2, rows - 1);
            var i = first;
            while (i <= last) : (i += 1) {
                const dx = slope * (i - y1) + x1;
                const dy = i;
                const y = @floor(dy);
                const x = @floor(dx);
                if (x >= 0 and x <= cols - 1) {
                    c2.a = @intFromFloat((1 - (dx - x)) * max_alpha);
                    var j = -half_width;
                    while (j <= half_width) : (j += 1) {
                        const px = x + j;
                        const pos = as(usize, y) * image.cols + as(usize, px);
                        if (px >= 0 and px < cols) {
                            if (j == -half_width or j == half_width) {
                                var c1: Rgba = Color.convert(Rgba, image.data[pos]);
                                c1.blend(c2);
                                image.data[pos] = Color.convert(T, c1);
                            } else {
                                image.data[pos] = color;
                            }
                        }
                    }
                }
                if (x + 1 >= 0 and x + 1 <= cols - 1) {
                    c2.a = @intFromFloat((dx - x) * max_alpha);
                    var j = -half_width;
                    while (j <= half_width) : (j += 1) {
                        const px = x + 1 + j;
                        const pos = as(usize, y) * image.cols + as(usize, px);
                        if (px >= 0 and px < cols) {
                            if (j == -half_width or j == half_width) {
                                var c1: Rgba = Color.convert(Rgba, image.data[pos]);
                                c1.blend(c2);
                                image.data[pos] = Color.convert(T, c1);
                            } else {
                                image.data[pos] = color;
                            }
                        }
                    }
                }
            }
        }
    }
}
/// Draws a colored straight line of a custom width between p1 and p2 on image, using Bresenham's line algorithm.
pub fn drawLineFast(comptime T: type, image: Image(T), p1: Point2d, p2: Point2d, width: usize, color: T) void {
    var x1: isize = @intFromFloat(p1.x);
    var y1: isize = @intFromFloat(p1.y);
    const x2: isize = @intFromFloat(p2.x);
    const y2: isize = @intFromFloat(p2.y);
    const sx: isize = if (x1 < x2) 1 else -1;
    const sy: isize = if (y1 < y2) 1 else -1;
    const dx: isize = @intCast(@abs(x2 - x1));
    const dy: isize = @intCast(@abs(y2 - y1));
    var err = dx - dy;
    while (x1 != x2 or y1 != y2) {
        const half_width: isize = @intCast(width / 2);
        var i = -half_width;
        while (i <= half_width) : (i += 1) {
            var j = -half_width;
            while (j <= half_width) : (j += 1) {
                const px = x1 + i;
                const py = y1 + j;
                if (px >= 0 and px < image.cols and py >= 0 and py < image.rows) {
                    const pos = @as(usize, @intCast(py)) * image.cols + @as(usize, @intCast(px));
                    image.data[pos] = color;
                }
            }
        }
        const e2 = err * 2;
        if (e2 > -dy) {
            err -= dy;
            x1 += sx;
        }
        if (e2 < dx) {
            err += dx;
            y1 += sy;
        }
    }
}

/// Draws a cross where each side is of length size
pub fn drawCross(comptime T: type, image: Image(T), center: Point2d, size: usize, color: T) void {
    const x: usize = @intFromFloat(@round(@max(0, @min(as(f32, image.cols - 1), center.x))));
    const y: usize = @intFromFloat(@round(@max(0, @min(as(f32, image.rows - 1), center.y))));
    for (0..size) |i| {
        image.data[y * image.cols + x -| i] = color; // max(0, x - i)
        image.data[(y -| i) * image.cols + x] = color;
        image.data[y * image.cols + @min(image.cols - 1, x + i)] = color;
        image.data[@min(image.rows - 1, y + i) * image.cols + x] = color;
    }
}

/// Draws the given polygon defined as an array of points.
pub fn drawPolygon(comptime T: type, image: Image(T), polygon: []const Point2d, width: usize, color: T) void {
    for (0..polygon.len) |i| {
        drawLine(T, image, polygon[i], polygon[@mod(i + 1, polygon.len)], width, color);
    }
}

/// Draws the circle defined by its center and radius.
pub fn drawCircle(comptime T: type, image: Image(T), center: Point2d, radius: f32, color: T) void {
    const frows: f32 = @floatFromInt(image.rows);
    const fcols: f32 = @floatFromInt(image.cols);
    if (center.x - radius < 0 or
        center.x + radius >= fcols or
        center.y - radius < 0 or
        center.y + radius >= frows or
        radius < 1)
    {
        return;
    }

    const first_x: f32 = @round(@max(0, center.x - radius));
    const last_x: f32 = @round(@min(fcols, center.x + radius));
    const rs: f32 = radius * radius;

    var top: f32 = @round(@sqrt(@max(rs - (first_x - center.x - 0.5) * (first_x - center.x - 0.5), 0)));
    top += center.y;
    var last = top;

    // Draw the left half of the circle
    var middle = @min(@round(center.x) - 1, last_x);
    var i: f32 = first_x;
    while (i <= middle) : (i += 1) {
        const a = i - center.x + 0.5;
        top = @round(@sqrt(@max(rs - a * a, 0)));
        top += center.y;
        const temp = top;
        while (top >= last) : (top -= 1) {
            const bottom = @round(center.y - top + center.y);
            drawLine(T, image, .{ .x = i, .y = top }, .{ .x = i, .y = bottom }, 1, color);
        }
        last = temp;
    }

    top = @round(@sqrt(@max(rs - (last_x - center.x + 0.5) * (last_x - center.x + 0.5), 0)));
    top += center.y;
    last = top;

    // Draw the right half of the circle
    middle = @max(@round(center.x), first_x);
    i = last_x;
    while (i >= middle) : (i -= 1) {
        const a = i - center.x - 0.5;
        top = @round(@sqrt(@max(rs - a * a, 0)));
        top += center.y;
        const temp = top;
        while (top >= last) : (top -= 1) {
            const bottom = @round(center.y - top + center.y);
            drawLine(T, image, .{ .x = i, .y = top }, .{ .x = i, .y = bottom }, 1, color);
        }
        last = temp;
    }
}

/// Draws the circle defined by its center and radius using a fast, but less accurate algorithm.
pub fn drawCircleFast(comptime T: type, image: Image(T), center: Point2d, radius: f32, color: T) void {
    const frows: f32 = @floatFromInt(image.rows);
    const fcols: f32 = @floatFromInt(image.cols);
    const left: usize = @intFromFloat(@round(@max(0, center.x - radius)));
    const top: usize = @intFromFloat(@round(@max(0, center.y - radius)));
    const right: usize = @intFromFloat(@round(@min(fcols, center.x + radius)));
    const bottom: usize = @intFromFloat(@round(@min(frows, center.y + radius)));
    for (top..bottom) |r| {
        const y = as(f32, r) - center.y;
        for (left..right) |c| {
            const x = as(f32, c) - center.x;
            if (x * x + y * y <= radius * radius) {
                image.data[r * image.cols + c] = color;
            }
        }
    }
}

export fn draw_circle(rgba_ptr: [*]Rgba, rows: usize, cols: usize, x: f32, y: f32, radius: f32, r: u8, g: u8, b: u8, a: u8) void {
    const image = Image(Rgba).init(rows, cols, rgba_ptr[0 .. rows * cols]);
    if (@import("builtin").os.tag == .freestanding) {
        drawCircle(Rgba, image, .{ .x = x, .y = y }, radius, .{ .r = r, .g = g, .b = b, .a = a });
    } else {
        var timer = std.time.Timer.start() catch unreachable;
        const t_0 = timer.read();
        drawCircle(Rgba, image, .{ .x = x, .y = y }, radius, .{ .r = r, .g = g, .b = b, .a = a });
        const t_1 = timer.read();
        std.log.debug("time: {d} ms\n", .{@as(f32, @floatFromInt(t_1 - t_0)) * 1e-6});
    }
}

/// Fills the given polygon defined as an array of points on image using the scanline algorithm.
pub fn fillPolygon(comptime T: type, image: Image(T), polygon: []const Point2d, color: T) void {
    const rows = image.rows;
    const cols = image.cols;
    var inters: [16]f32 = undefined;
    for (0..rows) |r| {
        const y: f32 = @floatFromInt(r);
        var num_inters: usize = 0;
        const frows: f32 = @floatFromInt(rows);
        for (0..polygon.len) |i| {
            const p1 = &polygon[i];
            const p2 = &polygon[(i + 1) % polygon.len];

            // Skip points above / below the image
            if (p1.y < 0 or p1.y < 0 or p1.y >= frows or p2.y >= frows) {
                continue;
            }

            // Skip horizontal lines
            if (p1.y == p2.y) {
                continue;
            }

            // Skip if there are no intersections at this position
            if ((y <= p1.y and y <= p2.y) or (y > p1.y and y > p2.y)) {
                continue;
            }

            // Add x coordinates of intersecting points
            inters[num_inters] = p1.x + (y - p1.y) * (p2.x - p1.x) / (p2.y - p1.y);
            num_inters += 1;
        }

        std.mem.sort(f32, inters[0..num_inters], {}, std.sort.asc(f32));

        // Paint the inside of the polygon
        var i: usize = 0;
        while (i < num_inters) : (i += 2) {
            var left_x: i32 = @intFromFloat(@ceil(inters[i]));
            var right_x: i32 = @intFromFloat(@floor(inters[i + 1]));
            left_x = @max(0, left_x);
            right_x = @min(as(i32, cols), right_x);
            while (left_x <= right_x) : (left_x += 1) {
                const pos: usize = r * cols + as(usize, left_x);
                if (T == Rgba) {
                    image.data[pos].blend(color);
                } else {
                    image.data[pos] = color;
                }
            }
        }
    }
}

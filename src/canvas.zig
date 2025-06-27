//! This module provides a Canvas for drawing various shapes and lines on images.
const std = @import("std");
const assert = std.debug.assert;

const Rgba = @import("color.zig").Rgba;
const Hsv = @import("color.zig").Hsv;

const as = @import("meta.zig").as;
const convert = @import("color.zig").convert;
const Image = @import("image.zig").Image;
const isColor = @import("color.zig").isColor;
const Point2d = @import("point.zig").Point2d;
const Rectangle = @import("geometry.zig").Rectangle;

/// A drawing context for an image, providing methods to draw shapes and lines.
pub fn Canvas(comptime T: type) type {
    return struct {
        image: Image(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Creates a drawing canvas from an image, with an optional allocator for operations that need it.
        pub fn init(image: Image(T), allocator: std.mem.Allocator) Self {
            return .{ .image = image, .allocator = allocator };
        }

        /// Draws a colored straight line of a custom width between p1 and p2 on an image.
        /// It uses Xiaolin Wu's line algorithm to perform anti-aliasing for diagonal lines.
        /// If the `color` is of Rgba type, it alpha-blends it onto the image.
        pub fn drawLine(self: Self, p1: Point2d(f32), p2: Point2d(f32), width: usize, color: anytype) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;
            // To avoid casting all the time, perform all operations using the underlying type of p1 and p2.
            const Float = @TypeOf(p1.x);
            var x1 = @round(p1.x);
            var y1 = @round(p1.y);
            var x2 = @round(p2.x);
            var y2 = @round(p2.y);
            const rows: Float = @floatFromInt(self.image.rows);
            const cols: Float = @floatFromInt(self.image.cols);
            const half_width: Float = @floatFromInt(width / 2);
            var c2 = convert(Rgba, color);

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
                            const pos = as(usize, y) * self.image.cols + as(usize, px);
                            var c1 = convert(Rgba, self.image.data[pos]);
                            c1.blend(c2);
                            self.image.data[pos] = convert(T, c1);
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
                            const pos = as(usize, py) * self.image.cols + as(usize, x);
                            var c1 = convert(Rgba, self.image.data[pos]);
                            c1.blend(c2);
                            self.image.data[pos] = convert(T, c1);
                        }
                    }
                }
            } else {
                // This part is a little more complicated because we are going to perform alpha blending
                // so the diagonal lines look nice.
                const max_alpha: Float = @floatFromInt(c2.a);
                const rise = y2 - y1;
                const run = x2 - x1;
                if (@abs(rise) < @abs(run)) { // Gentle slope: Iterate over x-coordinates
                    const slope = rise / run;
                    const first = if (x1 > x2) @max(x2, 0) else @max(x1, 0);
                    const last = if (x1 > x2) @min(x1, cols - 1) else @min(x2, cols - 1);
                    var i = first;
                    while (i <= last) : (i += 1) {
                        const dy = slope * (i - x1) + y1;
                        const y = @floor(dy);
                        const x = @floor(i);
                        if (y >= 0 and y <= rows - 1) {
                            var j = -half_width;
                            while (j <= half_width) : (j += 1) {
                                const py = @max(0, y + j);
                                const pos = as(usize, py) * self.image.cols + as(usize, x);
                                if (py >= 0 and py < rows) {
                                    var c1: Rgba = convert(Rgba, self.image.data[pos]);
                                    if (j == -half_width or j == half_width) {
                                        c2.a = @intFromFloat((1 - (dy - y)) * max_alpha);
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    } else {
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    }
                                }
                            }
                        }
                        if (y + 1 >= 0 and y + 1 <= rows - 1) {
                            var j = -half_width;
                            while (j <= half_width) : (j += 1) {
                                const py = @max(0, y + 1 + j);
                                if (py >= 0 and py < rows) {
                                    const pos = as(usize, py) * self.image.cols + as(usize, x);
                                    var c1: Rgba = convert(Rgba, self.image.data[pos]);
                                    if (j == -half_width or j == half_width) {
                                        c2.a = @intFromFloat((dy - y) * max_alpha);
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    } else {
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    }
                                }
                            }
                        }
                    }
                } else { // Steep slope: Iterate over y-coordinates
                    const slope = run / rise;
                    const first = if (y1 > y2) @max(y2, 0) else @max(y1, 0);
                    const last = if (y1 > y2) @min(y1, rows - 1) else @min(y2, rows - 1);
                    var i = first;
                    while (i <= last) : (i += 1) {
                        const dx = slope * (i - y1) + x1;
                        const y = @floor(i);
                        const x = @floor(dx);
                        if (x >= 0 and x <= cols - 1) {
                            var j = -half_width;
                            while (j <= half_width) : (j += 1) {
                                const px = @max(0, x + j);
                                const pos = as(usize, y) * self.image.cols + as(usize, px);
                                if (px >= 0 and px < cols) {
                                    var c1: Rgba = convert(Rgba, self.image.data[pos]);
                                    if (j == -half_width or j == half_width) {
                                        c2.a = @intFromFloat((1 - (dx - x)) * max_alpha);
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    } else {
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    }
                                }
                            }
                        }
                        if (x + 1 >= 0 and x + 1 <= cols - 1) {
                            c2.a = @intFromFloat((dx - x) * max_alpha);
                            var j = -half_width;
                            while (j <= half_width) : (j += 1) {
                                const px = @max(0, x + 1 + j);
                                const pos = as(usize, y) * self.image.cols + as(usize, px);
                                if (px >= 0 and px < cols) {
                                    var c1: Rgba = convert(Rgba, self.image.data[pos]);
                                    if (j == -half_width or j == half_width) {
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    } else {
                                        c1.blend(c2);
                                        self.image.data[pos] = convert(T, c1);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Draws a colored straight line of a custom width between `p1` and `p2` on `image` using Bresenham's line algorithm.
        /// This function is faster than `drawLine` because it does not perform anti-aliasing.
        pub fn drawLineFast(self: Self, p1: Point2d(f32), p2: Point2d(f32), width: usize, color: T) void {
            if (width == 0) return;
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
                        if (px >= 0 and px < self.image.cols and py >= 0 and py < self.image.rows) {
                            const pos = @as(usize, @intCast(py)) * self.image.cols + @as(usize, @intCast(px));
                            self.image.data[pos] = color;
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

        /// Draws a cubic Bézier curve on the given image.
        pub fn drawBezierCurve(self: Self, points: [4]Point2d(f32), step: f32, color: T) void {
            comptime assert(isColor(T));
            assert(step >= 0);
            assert(step <= 1);
            var t: f32 = 0;
            while (t <= 1) : (t += step) {
                const b: Point2d(f32) = .{
                    .x = (1 - t) * (1 - t) * (1 - t) * points[0].x + 3 * (1 - t) * (1 - t) * t * points[1].x + 3 * (1 - t) * t * t * points[2].x + t * t * t * points[3].x,
                    .y = (1 - t) * (1 - t) * (1 - t) * points[0].y + 3 * (1 - t) * (1 - t) * t * points[1].y + 3 * (1 - t) * t * t * points[2].y + t * t * t * points[3].y,
                };
                const row: usize = @intFromFloat(@round(b.y));
                const col: usize = @intFromFloat(@round(b.x));
                if (row < self.image.rows and col < self.image.cols) {
                    self.image.at(row, col).* = color;
                }
            }
        }

        /// Draws a smooth polygon on the given image.
        /// The polygon's edges are rendered as cubic Bézier curves connecting the vertices,
        /// allowing for a curved and smooth appearance.
        pub fn drawSmoothPolygon(self: Self, polygon: []const Point2d(f32), color: T, tension: f32) void {
            assert(tension >= 0);
            assert(tension <= 1);
            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const cp1 = Point2d(f32){
                    .x = p0.x + (p1.x - p0.x) * (1 - tension),
                    .y = p0.y + (p1.y - p0.y) * (1 - tension),
                };
                const cp2 = Point2d(f32){
                    .x = p1.x - (p2.x - p1.x) * (1 - tension),
                    .y = p1.y - (p2.y - p1.y) * (1 - tension),
                };
                self.drawBezierCurve(.{ p0, cp1, cp2, p1 }, 0.01, color);
            }
        }

        /// Fills a smooth polygon on the given image.
        /// The polygon's outline is defined by Bézier curves connecting the vertices (similar to `drawSmoothPolygon`),
        /// and the resulting shape is then filled with the specified color using a scanline algorithm.
        pub fn fillSmoothPolygon(self: Self, polygon: []const Point2d(f32), color: T, tension: f32) !void {
            var points: std.ArrayList(Point2d(f32)) = .init(self.allocator);
            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const cp1 = Point2d(f32){
                    .x = p0.x + (p1.x - p0.x) * (1 - tension),
                    .y = p0.y + (p1.y - p0.y) * (1 - tension),
                };
                const cp2 = Point2d(f32){
                    .x = p1.x - (p2.x - p1.x) * (1 - tension),
                    .y = p1.y - (p2.y - p1.y) * (1 - tension),
                };
                const segment = try self.tessellateCurve(.{ p0, cp1, cp2, p1 }, 10);
                try points.appendSlice(segment);
            }
            try self.fillPolygon(points.items, color);
        }

        /// Draws the outline of a rectangle on the given image.
        pub fn drawRectangle(self: Self, rect: Rectangle(f32), width: usize, color: anytype) void {
            comptime assert(isColor(@TypeOf(color)));
            const points: []const Point2d(f32) = &.{
                .{ .x = rect.l, .y = rect.t },
                .{ .x = rect.r, .y = rect.t },
                .{ .x = rect.r, .y = rect.b },
                .{ .x = rect.l, .y = rect.b },
            };
            self.drawPolygon(points, width, color);
        }

        /// Draws a cross shape (plus sign) on the given image at a specified center point.
        pub fn drawCross(self: Self, center: Point2d(f32), size: usize, color: T) void {
            comptime assert(isColor(T));
            if (size == 0) return;
            const x: usize = @intFromFloat(@round(@max(0, @min(as(f32, self.image.cols - 1), center.x))));
            const y: usize = @intFromFloat(@round(@max(0, @min(as(f32, self.image.rows - 1), center.y))));
            for (0..size) |i| {
                self.image.data[y * self.image.cols + x -| i] = color;
                self.image.data[(y -| i) * self.image.cols + x] = color;
                self.image.data[y * self.image.cols + @min(self.image.cols - 1, x + i)] = color;
                self.image.data[@min(self.image.rows - 1, y + i) * self.image.cols + x] = color;
            }
        }

        /// Draws the outline of a polygon on the given image.
        /// The polygon is defined by a sequence of vertices. Lines are drawn between consecutive
        /// vertices, and a final line is drawn from the last vertex to the first to close the shape.
        pub fn drawPolygon(self: Self, polygon: []const Point2d(f32), width: usize, color: anytype) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;
            for (0..polygon.len) |i| {
                self.drawLine(polygon[i], polygon[@mod(i + 1, polygon.len)], width, color);
            }
        }

        /// Draws the outline of a circle on the given image.
        pub fn drawCircle(self: Self, center: Point2d(f32), radius: f32, color: T) void {
            if (radius <= 0) return;
            const cx = @round(center.x);
            const cy = @round(center.y);
            const r = @round(radius);
            var x: f32 = r;
            var y: f32 = 0;
            var err: f32 = 0;
            while (x >= y) {
                const points = [_]Point2d(f32){
                    .{ .x = cx + x, .y = cy + y },
                    .{ .x = cx - x, .y = cy + y },
                    .{ .x = cx + x, .y = cy - y },
                    .{ .x = cx - x, .y = cy - y },
                    .{ .x = cx + y, .y = cy + x },
                    .{ .x = cx - y, .y = cy + x },
                    .{ .x = cx + y, .y = cy - x },
                    .{ .x = cx - y, .y = cy - x },
                };
                for (points) |p| {
                    const col = @as(usize, @intFromFloat(p.x));
                    const row = @as(usize, @intFromFloat(p.y));
                    if (row < self.image.rows and col < self.image.cols) {
                        self.image.data[row * self.image.cols + col] = color;
                    }
                }
                if (err <= 0) {
                    y += 1;
                    err += 2 * y + 1;
                }
                if (err > 0) {
                    x -= 1;
                    err -= 2 * x + 1;
                }
            }
        }

        /// Fills a circle on the given image.
        pub fn fillCircle(self: Self, center: Point2d(f32), radius: f32, color: T) void {
            if (radius <= 0) return;
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const left: usize = @intFromFloat(@round(@max(0, center.x - radius)));
            const top: usize = @intFromFloat(@round(@max(0, center.y - radius)));
            const right: usize = @intFromFloat(@round(@min(fcols, center.x + radius)));
            const bottom: usize = @intFromFloat(@round(@min(frows, center.y + radius)));
            for (top..bottom) |r| {
                const y = as(f32, r) - center.y;
                for (left..right) |c| {
                    const x = as(f32, c) - center.x;
                    if (x * x + y * y <= radius * radius) {
                        self.image.data[r * self.image.cols + c] = color;
                    }
                }
            }
        }

        /// Fills the given polygon on an image using the scanline algorithm.
        /// The polygon is defined by an array of points (vertices).
        pub fn fillPolygon(self: Self, polygon: []const Point2d(f32), color: T) !void {
            const rows = self.image.rows;
            const cols = self.image.cols;
            var intersections: std.ArrayList(f32) = .init(self.allocator);
            defer intersections.deinit();
            for (0..rows) |r| {
                const y: f32 = @floatFromInt(r);
                intersections.clearRetainingCapacity();
                for (0..polygon.len) |i| {
                    const p1 = &polygon[i];
                    const p2 = &polygon[(i + 1) % polygon.len];
                    if (p1.y == p2.y) {
                        continue;
                    }
                    if ((y <= p1.y and y <= p2.y) or (y > p1.y and y > p2.y)) {
                        continue;
                    }
                    try intersections.append(p1.x + (y - p1.y) * (p2.x - p1.x) / (p2.y - p1.y));
                }
                std.mem.sort(f32, intersections.items, {}, std.sort.asc(f32));
                var i: usize = 1;
                while (i < intersections.items.len) : (i += 2) {
                    var left_x: i32 = @intFromFloat(@ceil(intersections.items[i - 1]));
                    var right_x: i32 = @intFromFloat(@floor(intersections.items[i]));
                    left_x = @max(0, left_x);
                    right_x = @min(as(i32, cols), right_x);
                    while (left_x <= right_x) : (left_x += 1) {
                        const pos: usize = r * cols + as(usize, left_x);
                        if (T == Rgba) {
                            self.image.data[pos].blend(color);
                        } else {
                            self.image.data[pos] = color;
                        }
                    }
                }
            }
        }

        /// Tessellates a cubic Bézier curve into a series of line segments (points).
        fn tessellateCurve(self: Self, p: [4]Point2d(f32), segments: usize) anyerror![]const Point2d(f32) {
            var polygon: std.ArrayList(Point2d(f32)) = .init(self.allocator);
            for (0..segments) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
                const u: f32 = 1 - t;
                const tt: f32 = t * t;
                const uu: f32 = u * u;
                const uuu: f32 = uu * u;
                const ttt: f32 = tt * t;
                try polygon.append(.{
                    .x = uuu * p[0].x + 3 * uu * t * p[1].x + 3 * u * tt * p[2].x + ttt * p[3].x,
                    .y = uuu * p[0].y + 3 * uu * t * p[1].y + 3 * u * tt * p[2].y + ttt * p[3].y,
                });
            }
            return try polygon.toOwnedSlice();
        }
    };
}

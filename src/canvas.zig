//! This module provides a Canvas for drawing various shapes and lines on images.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

const as = @import("meta.zig").as;
const convert = @import("color.zig").convert;
const Hsv = @import("color.zig").Hsv;
const Image = @import("image.zig").Image;
const isColor = @import("color.zig").isColor;
const Point2d = @import("point.zig").Point2d;
const Rectangle = @import("geometry.zig").Rectangle;
const Rgba = @import("color.zig").Rgba;

/// Antialiasing mode for polygon filling operations
pub const FillMode = enum {
    /// No antialiasing - hard edges, fastest performance
    solid,
    /// Antialiased edges - smooth edges, slower performance
    smooth,
};

/// A drawing context for an image, providing methods to draw shapes and lines.
pub fn Canvas(comptime T: type) type {
    return struct {
        image: Image(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Creates a drawing canvas from an image, with an allocator for operations that need it.
        pub fn init(image: Image(T), allocator: std.mem.Allocator) Self {
            return .{ .image = image, .allocator = allocator };
        }

        /// Draws a colored straight line of a custom width between p1 and p2 on an image.
        /// Width=1 lines use fast Bresenham algorithm with no caps for precise pixel placement.
        /// Width>1 lines are rendered as rectangles with rounded caps for smooth appearance.
        /// Use FillMode.smooth for anti-aliased lines or FillMode.solid for fast non-anti-aliased lines.
        /// If the `color` is of Rgba type, it alpha-blends it onto the image.
        pub fn drawLine(self: Self, p1: Point2d(f32), p2: Point2d(f32), color: anytype, width: usize, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            switch (mode) {
                .solid => self.drawLineSolid(p1, p2, width, color),
                .smooth => self.drawLineSmooth(p1, p2, width, color),
            }
        }

        /// Internal function for drawing smooth (anti-aliased) lines.
        fn drawLineSmooth(self: Self, p1: Point2d(f32), p2: Point2d(f32), width: usize, color: anytype) void {
            const Float = @TypeOf(p1.x);
            const rows: Float = @floatFromInt(self.image.rows);
            const cols: Float = @floatFromInt(self.image.cols);
            const half_width: Float = @as(Float, @floatFromInt(width)) / 2.0;
            const c2 = convert(Rgba, color);

            // Calculate line direction vector
            const dx = p2.x - p1.x;
            const dy = p2.y - p1.y;
            const line_length = @sqrt(dx * dx + dy * dy);

            if (line_length == 0) {
                // Single point - draw a small circle
                self.fillCircle(p1, half_width, color, .smooth);
                return;
            }

            // Special case for perfectly horizontal/vertical lines (faster rendering)
            if (@abs(dx) < 0.001) { // Vertical line
                const x1 = @round(p1.x);
                var y1 = @round(p1.y);
                var y2 = @round(p2.y);
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
                // Add rounded caps
                self.fillCircle(p1, half_width, color, .smooth);
                self.fillCircle(p2, half_width, color, .smooth);
                return;
            } else if (@abs(dy) < 0.001) { // Horizontal line
                var x1 = @round(p1.x);
                var x2 = @round(p2.x);
                const y1 = @round(p1.y);
                if (x1 > x2) std.mem.swap(Float, &x1, &x2);
                if (y1 < 0 or y1 >= rows) return;
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
                // Add rounded caps
                self.fillCircle(p1, half_width, color, .smooth);
                self.fillCircle(p2, half_width, color, .smooth);
                return;
            }

            // For diagonal lines, use optimized distance-based anti-aliasing
            // Calculate tighter bounding box
            const line_min_x = @min(p1.x, p2.x) - half_width;
            const line_max_x = @max(p1.x, p2.x) + half_width;
            const line_min_y = @min(p1.y, p2.y) - half_width;
            const line_max_y = @max(p1.y, p2.y) + half_width;

            const min_x = @max(0, @floor(line_min_x));
            const max_x = @min(cols - 1, @ceil(line_max_x));
            const min_y = @max(0, @floor(line_min_y));
            const max_y = @min(rows - 1, @ceil(line_max_y));

            // Precompute for distance calculation optimization
            const dx_sq = dx * dx;
            const dy_sq = dy * dy;
            const length_sq = dx_sq + dy_sq;
            const inv_length_sq = 1.0 / length_sq;

            // Iterate through pixels in bounding box
            var y = @as(i32, @intFromFloat(min_y));
            while (y <= @as(i32, @intFromFloat(max_y))) : (y += 1) {
                const py = @as(Float, @floatFromInt(y));
                var x = @as(i32, @intFromFloat(min_x));
                while (x <= @as(i32, @intFromFloat(max_x))) : (x += 1) {
                    const px = @as(Float, @floatFromInt(x));

                    // Optimized distance calculation
                    const dpx = px - p1.x;
                    const dpy = py - p1.y;
                    const t = @max(0, @min(1, (dpx * dx + dpy * dy) * inv_length_sq));
                    const closest_x = p1.x + t * dx;
                    const closest_y = p1.y + t * dy;
                    const dist_x = px - closest_x;
                    const dist_y = py - closest_y;
                    const dist = @sqrt(dist_x * dist_x + dist_y * dist_y);

                    // Anti-aliased coverage based on distance
                    if (dist <= half_width + 0.5) {
                        var alpha: Float = 1.0;
                        if (dist > half_width - 0.5) {
                            alpha = (half_width + 0.5 - dist);
                        }

                        if (alpha > 0) {
                            const pos = @as(usize, @intCast(y)) * self.image.cols + @as(usize, @intCast(x));
                            var c1 = convert(Rgba, self.image.data[pos]);
                            var c_blend = c2;
                            c_blend.a = @intFromFloat(alpha * @as(Float, @floatFromInt(c2.a)));
                            c1.blend(c_blend);
                            self.image.data[pos] = convert(T, c1);
                        }
                    }
                }
            }
        }

        /// Internal function for drawing solid (non-anti-aliased) lines.
        fn drawLineSolid(self: Self, p1: Point2d(f32), p2: Point2d(f32), width: usize, color: anytype) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            const solid_color = convert(T, color);

            // For width 1, use simple Bresenham
            if (width == 1) {
                var x1: i32 = @intFromFloat(p1.x);
                var y1: i32 = @intFromFloat(p1.y);
                const x2: i32 = @intFromFloat(p2.x);
                const y2: i32 = @intFromFloat(p2.y);

                const dx: i32 = @intCast(@abs(x2 - x1));
                const dy: i32 = @intCast(@abs(y2 - y1));
                const sx: i32 = if (x1 < x2) 1 else -1;
                const sy: i32 = if (y1 < y2) 1 else -1;
                var err = dx - dy;

                while (true) {
                    if (x1 >= 0 and x1 < self.image.cols and y1 >= 0 and y1 < self.image.rows) {
                        const pos = @as(usize, @intCast(y1)) * self.image.cols + @as(usize, @intCast(x1));
                        self.image.data[pos] = solid_color;
                    }

                    if (x1 == x2 and y1 == y2) break;

                    const e2 = 2 * err;
                    if (e2 > -dy) {
                        err -= dy;
                        x1 += sx;
                    }
                    if (e2 < dx) {
                        err += dx;
                        y1 += sy;
                    }
                }
                return;
            }

            // For thick lines, draw as a filled rectangle
            const dx = p2.x - p1.x;
            const dy = p2.y - p1.y;
            const line_length = @sqrt(dx * dx + dy * dy);

            if (line_length == 0) {
                // Single point - draw a filled circle
                const half_width = @as(f32, @floatFromInt(width)) / 2.0;
                self.fillCircle(p1, half_width, color, .solid);
                return;
            }

            // Calculate perpendicular vector for thick line
            const half_width = @as(f32, @floatFromInt(width)) / 2.0;
            const perp_x = -dy / line_length * half_width;
            const perp_y = dx / line_length * half_width;

            // Create rectangle corners
            const corners = [_]Point2d(f32){
                .{ .x = p1.x - perp_x, .y = p1.y - perp_y },
                .{ .x = p1.x + perp_x, .y = p1.y + perp_y },
                .{ .x = p2.x + perp_x, .y = p2.y + perp_y },
                .{ .x = p2.x - perp_x, .y = p2.y - perp_y },
            };

            // Fill rectangle using scanline algorithm (no anti-aliasing)
            self.fillPolygon(&corners, solid_color, .solid) catch return;

            // Add rounded caps using solid circles
            self.fillCircle(p1, half_width, color, .solid);
            self.fillCircle(p2, half_width, color, .solid);
        }

        /// Evaluates a quadratic Bézier curve at parameter t.
        fn evalQuadraticBezier(p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), t: f32) Point2d(f32) {
            const u = 1 - t;
            const uu = u * u;
            const tt = t * t;
            return .{
                .x = uu * p0.x + 2 * u * t * p1.x + tt * p2.x,
                .y = uu * p0.y + 2 * u * t * p1.y + tt * p2.y,
            };
        }

        /// Evaluates a cubic Bézier curve at parameter t.
        fn evalCubicBezier(p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), p3: Point2d(f32), t: f32) Point2d(f32) {
            const u = 1 - t;
            const uu = u * u;
            const uuu = uu * u;
            const tt = t * t;
            const ttt = tt * t;
            return .{
                .x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x,
                .y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y,
            };
        }

        /// Computes the derivative of a cubic Bézier curve at parameter t.
        fn cubicBezierDerivative(p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), p3: Point2d(f32), t: f32) Point2d(f32) {
            const u = 1 - t;
            const uu = u * u;
            const tt = t * t;
            return .{
                .x = 3 * uu * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * tt * (p3.x - p2.x),
                .y = 3 * uu * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * tt * (p3.y - p2.y),
            };
        }

        /// Estimates the length of a cubic Bézier curve segment.
        fn estimateCubicBezierLength(p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), p3: Point2d(f32)) f32 {
            // Use chord + control polygon approximation
            const chord = @sqrt((p3.x - p0.x) * (p3.x - p0.x) + (p3.y - p0.y) * (p3.y - p0.y));
            const control_net = @sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)) +
                @sqrt((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y)) +
                @sqrt((p3.x - p2.x) * (p3.x - p2.x) + (p3.y - p2.y) * (p3.y - p2.y));
            return (chord + control_net) / 2.0;
        }

        /// Draws a quadratic Bézier curve with specified width and fill mode.
        pub fn drawQuadraticBezier(self: Self, p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), color: anytype, width: usize, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            // Estimate number of segments based on curve length
            const chord = @sqrt((p2.x - p0.x) * (p2.x - p0.x) + (p2.y - p0.y) * (p2.y - p0.y));
            const control_net = @sqrt((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)) +
                @sqrt((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y));
            const estimated_length = (chord + control_net) / 2.0;
            const segments = @max(3, @as(usize, @intFromFloat(estimated_length / 2.0)));

            var prev_point = p0;
            var i: usize = 1;
            while (i <= segments) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
                const current_point = evalQuadraticBezier(p0, p1, p2, t);
                self.drawLine(prev_point, current_point, color, width, mode);
                prev_point = current_point;
            }
        }

        /// Draws a cubic Bézier curve with specified width and fill mode.
        /// The curve is adaptively subdivided for optimal quality and performance.
        pub fn drawCubicBezier(self: Self, p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), p3: Point2d(f32), color: anytype, width: usize, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            // Use adaptive subdivision based on estimated length
            const estimated_length = estimateCubicBezierLength(p0, p1, p2, p3);
            const base_segments = @max(4, @as(usize, @intFromFloat(estimated_length / 2.0)));

            // For smooth mode or thick lines, use more segments
            const segments = if (mode == .smooth or width > 2) base_segments * 2 else base_segments;

            var prev_point = p0;
            var i: usize = 1;
            while (i <= segments) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
                const current_point = evalCubicBezier(p0, p1, p2, p3, t);
                self.drawLine(prev_point, current_point, color, width, mode);
                prev_point = current_point;
            }
        }

        /// Calculates spline control points for a vertex in a polygon using tension.
        fn calculateSmoothControlPoints(p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), tension: f32) struct { cp1: Point2d(f32), cp2: Point2d(f32) } {
            const tension_factor = 1 - @max(0, @min(1, tension));
            return .{
                .cp1 = .{
                    .x = p0.x + (p1.x - p0.x) * tension_factor,
                    .y = p0.y + (p1.y - p0.y) * tension_factor,
                },
                .cp2 = .{
                    .x = p1.x - (p2.x - p1.x) * tension_factor,
                    .y = p1.y - (p2.y - p1.y) * tension_factor,
                },
            };
        }

        /// Draws a spline polygon outline with Bézier curves connecting vertices.
        /// The polygon's edges are rendered as cubic Bézier splines for smooth, curved appearance.
        /// Use tension to control curve smoothness: 0=sharp corners, 1=maximum smoothness.
        pub fn drawSplinePolygon(self: Self, polygon: []const Point2d(f32), color: anytype, width: usize, tension: f32, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0 or polygon.len < 3) return;

            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const control_points = calculateSmoothControlPoints(p0, p1, p2, tension);
                self.drawCubicBezier(p0, control_points.cp1, control_points.cp2, p1, color, width, mode);
            }
        }

        /// Fills a spline polygon with Bézier curves connecting vertices.
        /// The polygon's outline is defined by Bézier splines for smooth, curved edges.
        /// Use tension to control curve smoothness: 0=sharp corners, 1=maximum smoothness.
        pub fn fillSplinePolygon(self: Self, polygon: []const Point2d(f32), color: anytype, tension: f32, mode: FillMode) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (polygon.len < 3) return;

            // Stack buffer for common cases (up to 50 segments per curve, 8 curves)
            const max_stack_points = 400;
            var stack_buffer: [max_stack_points]Point2d(f32) = undefined;
            var total_points: usize = 0;

            // First pass: calculate total points needed
            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const control_points = calculateSmoothControlPoints(p0, p1, p2, tension);
                const estimated_length = estimateCubicBezierLength(p0, control_points.cp1, control_points.cp2, p1);
                const segments = @max(4, @min(50, @as(usize, @intFromFloat(estimated_length / 3.0))));
                total_points += segments;
            }

            // Use stack buffer if possible, otherwise allocate
            var points_buffer: []Point2d(f32) = undefined;
            var heap_buffer: ?[]Point2d(f32) = null;
            defer if (heap_buffer) |h| self.allocator.free(h);

            if (total_points <= max_stack_points) {
                points_buffer = stack_buffer[0..total_points];
            } else {
                heap_buffer = try self.allocator.alloc(Point2d(f32), total_points);
                points_buffer = heap_buffer.?;
            }

            // Second pass: tessellate curves into the buffer
            var write_idx: usize = 0;
            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const control_points = calculateSmoothControlPoints(p0, p1, p2, tension);

                const estimated_length = estimateCubicBezierLength(p0, control_points.cp1, control_points.cp2, p1);
                const segments = @max(4, @min(50, @as(usize, @intFromFloat(estimated_length / 3.0))));

                // Tessellate directly into our buffer
                const segment_buffer = points_buffer[write_idx..write_idx + segments];
                self.tessellateCubicBezier(p0, control_points.cp1, control_points.cp2, p1, segment_buffer);
                write_idx += segments;
            }

            try self.fillPolygon(points_buffer, color, mode);
        }

        /// Draws the outline of a rectangle on the given image.
        pub fn drawRectangle(self: Self, rect: Rectangle(f32), color: anytype, width: usize, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            const points: []const Point2d(f32) = &.{
                .{ .x = rect.l, .y = rect.t },
                .{ .x = rect.r, .y = rect.t },
                .{ .x = rect.r, .y = rect.b },
                .{ .x = rect.l, .y = rect.b },
            };
            self.drawPolygon(points, color, width, mode);
        }

        /// Draws the outline of a polygon on the given image.
        /// The polygon is defined by a sequence of vertices. Lines are drawn between consecutive
        /// vertices, and a final line is drawn from the last vertex to the first to close the shape.
        /// Round joints are added at vertices to ensure smooth connections.
        pub fn drawPolygon(self: Self, polygon: []const Point2d(f32), color: anytype, width: usize, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            // Draw all line segments
            for (0..polygon.len) |i| {
                self.drawLine(polygon[i], polygon[@mod(i + 1, polygon.len)], color, width, mode);
            }
        }

        /// Draws the outline of a circle on the given image.
        /// Use FillMode.smooth for anti-aliased edges or FillMode.solid for fast aliased edges.
        pub fn drawCircle(self: Self, center: Point2d(f32), radius: f32, color: anytype, width: usize, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0 or width == 0) return;

            switch (mode) {
                .solid => self.drawCircleSolid(center, radius, width, color),
                .smooth => self.drawCircleSmooth(center, radius, width, color),
            }
        }

        /// Internal function for drawing solid (aliased) circle outlines.
        fn drawCircleSolid(self: Self, center: Point2d(f32), radius: f32, width: usize, color: anytype) void {
            if (width == 1) {
                // Use fast Bresenham for 1-pixel width
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
                            const pos = row * self.image.cols + col;
                            var c1 = convert(Rgba, self.image.data[pos]);
                            const c2 = convert(Rgba, color);
                            c1.blend(c2);
                            self.image.data[pos] = convert(T, c1);
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
            } else {
                // Use ring filling for thick outlines
                const frows: f32 = @floatFromInt(self.image.rows);
                const fcols: f32 = @floatFromInt(self.image.cols);
                const line_width: f32 = @floatFromInt(width);
                const inner_radius = radius - line_width / 2.0;
                const outer_radius = radius + line_width / 2.0;
                const solid_color = convert(T, color);

                // Calculate bounding box
                const left: usize = @intFromFloat(@round(@max(0, center.x - outer_radius - 1)));
                const top: usize = @intFromFloat(@round(@max(0, center.y - outer_radius - 1)));
                const right: usize = @intFromFloat(@round(@min(fcols, center.x + outer_radius + 1)));
                const bottom: usize = @intFromFloat(@round(@min(frows, center.y + outer_radius + 1)));

                for (top..bottom) |r| {
                    const y = @as(f32, @floatFromInt(r)) - center.y;
                    for (left..right) |c| {
                        const x = @as(f32, @floatFromInt(c)) - center.x;
                        const dist_sq = x * x + y * y;
                        const inner_radius_sq = inner_radius * inner_radius;
                        const outer_radius_sq = outer_radius * outer_radius;

                        if (dist_sq >= inner_radius_sq and dist_sq <= outer_radius_sq) {
                            const pos = r * self.image.cols + c;
                            self.image.data[pos] = solid_color;
                        }
                    }
                }
            }
        }

        /// Internal function for drawing smooth (anti-aliased) circle outlines.
        fn drawCircleSmooth(self: Self, center: Point2d(f32), radius: f32, width: usize, color: anytype) void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const line_width: f32 = @floatFromInt(width);
            const inner_radius = radius - line_width / 2.0;
            const outer_radius = radius + line_width / 2.0;

            // Calculate bounding box
            const left: usize = @intFromFloat(@round(@max(0, center.x - outer_radius - 1)));
            const top: usize = @intFromFloat(@round(@max(0, center.y - outer_radius - 1)));
            const right: usize = @intFromFloat(@round(@min(fcols, center.x + outer_radius + 1)));
            const bottom: usize = @intFromFloat(@round(@min(frows, center.y + outer_radius + 1)));

            const c2 = convert(Rgba, color);

            for (top..bottom) |r| {
                const y = @as(f32, @floatFromInt(r)) - center.y;
                for (left..right) |c| {
                    const x = @as(f32, @floatFromInt(c)) - center.x;
                    const dist = @sqrt(x * x + y * y);

                    // Only draw if we're in the ring area
                    if (dist >= inner_radius - 0.5 and dist <= outer_radius + 0.5) {
                        var alpha: f32 = 1.0;

                        // Smooth outer edge
                        if (dist > outer_radius - 0.5) {
                            alpha = @min(alpha, outer_radius + 0.5 - dist);
                        }

                        // Smooth inner edge
                        if (dist < inner_radius + 0.5) {
                            alpha = @min(alpha, dist - (inner_radius - 0.5));
                        }

                        alpha = @max(0, @min(1, alpha));

                        if (alpha > 0) {
                            const pos = r * self.image.cols + c;
                            var c1 = convert(Rgba, self.image.data[pos]);
                            var c_blend = c2;
                            c_blend.a = @intFromFloat(alpha * @as(f32, @floatFromInt(c2.a)));
                            c1.blend(c_blend);
                            self.image.data[pos] = convert(T, c1);
                        }
                    }
                }
            }
        }

        /// Fills a circle on the given image.
        /// Use FillMode.smooth for anti-aliased edges or FillMode.solid for hard edges.
        pub fn fillCircle(self: Self, center: Point2d(f32), radius: f32, color: anytype, mode: FillMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0) return;

            switch (mode) {
                .solid => self.fillCircleSolid(center, radius, color),
                .smooth => self.fillCircleSmooth(center, radius, color),
            }
        }

        /// Internal function for filling smooth (anti-aliased) circles.
        fn fillCircleSmooth(self: Self, center: Point2d(f32), radius: f32, color: anytype) void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const left: usize = @intFromFloat(@round(@max(0, center.x - radius)));
            const top: usize = @intFromFloat(@round(@max(0, center.y - radius)));
            const right: usize = @intFromFloat(@round(@min(fcols, center.x + radius)));
            const bottom: usize = @intFromFloat(@round(@min(frows, center.y + radius)));

            var c2 = convert(Rgba, color);
            const max_alpha: f32 = @floatFromInt(c2.a);

            for (top..bottom) |r| {
                const y = as(f32, r) - center.y;
                for (left..right) |c| {
                    const x = as(f32, c) - center.x;
                    const dist_sq = x * x + y * y;
                    if (dist_sq <= radius * radius) {
                        const pos = r * self.image.cols + c;

                        // Apply antialiasing at the edge
                        const dist = @sqrt(dist_sq);
                        if (dist > radius - 1) {
                            // Edge antialiasing
                            const edge_alpha = radius - dist;
                            var c1 = convert(Rgba, self.image.data[pos]);
                            c2.a = @intFromFloat(edge_alpha * max_alpha);
                            c1.blend(c2);
                            self.image.data[pos] = convert(T, c1);
                        } else {
                            // Full opacity in the center
                            var c1 = convert(Rgba, self.image.data[pos]);
                            c2.a = @intFromFloat(max_alpha);
                            c1.blend(c2);
                            self.image.data[pos] = convert(T, c1);
                        }
                    }
                }
            }
        }

        /// Internal function for filling solid (non-anti-aliased) circles.
        fn fillCircleSolid(self: Self, center: Point2d(f32), radius: f32, color: anytype) void {
            const solid_color = convert(T, color);
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const left: usize = @intFromFloat(@round(@max(0, center.x - radius)));
            const top: usize = @intFromFloat(@round(@max(0, center.y - radius)));
            const right: usize = @intFromFloat(@round(@min(fcols, center.x + radius)));
            const bottom: usize = @intFromFloat(@round(@min(frows, center.y + radius)));

            const radius_sq = radius * radius;

            for (top..bottom) |r| {
                const y = as(f32, r) - center.y;
                for (left..right) |c| {
                    const x = as(f32, c) - center.x;
                    const dist_sq = x * x + y * y;
                    if (dist_sq <= radius_sq) {
                        const pos = r * self.image.cols + c;
                        self.image.data[pos] = solid_color;
                    }
                }
            }
        }

        /// Fills the given polygon on an image using the scanline algorithm.
        /// The polygon is defined by an array of points (vertices).
        /// Use FillMode.solid for hard edges (fastest) or FillMode.smooth for antialiased edges.
        pub fn fillPolygon(self: Self, polygon: []const Point2d(f32), color: anytype, mode: FillMode) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (polygon.len < 3) return;

            const rows = self.image.rows;
            const cols = self.image.cols;

            // Find bounding box for optimization
            var min_y = polygon[0].y;
            var max_y = polygon[0].y;
            for (polygon) |p| {
                min_y = @min(min_y, p.y);
                max_y = @max(max_y, p.y);
            }

            const start_y = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
            const end_y = @min(@as(i32, @intCast(rows)) - 1, @as(i32, @intFromFloat(@ceil(max_y))));

            // Use stack buffer for small polygons, fallback to heap for complex ones
            const stack_buffer_size = 64;
            var stack_intersections: [stack_buffer_size]f32 = undefined;
            var heap_intersections: ?[]f32 = null;
            defer if (heap_intersections) |h| self.allocator.free(h);

            var c2 = convert(Rgba, color);
            const max_alpha: f32 = @floatFromInt(c2.a);

            var y = start_y;
            while (y <= end_y) : (y += 1) {
                const fy: f32 = @floatFromInt(y);
                var intersection_count: usize = 0;

                // Count intersections first
                for (0..polygon.len) |i| {
                    const p1 = polygon[i];
                    const p2 = polygon[(i + 1) % polygon.len];

                    if ((p1.y <= fy and p2.y > fy) or (p2.y <= fy and p1.y > fy)) {
                        intersection_count += 1;
                    }
                }

                // Get appropriate buffer
                var intersections: []f32 = undefined;
                if (intersection_count <= stack_buffer_size) {
                    intersections = stack_intersections[0..intersection_count];
                } else {
                    // Need heap allocation
                    if (heap_intersections == null or heap_intersections.?.len < intersection_count) {
                        if (heap_intersections) |h| self.allocator.free(h);
                        heap_intersections = try self.allocator.alloc(f32, intersection_count);
                    }
                    intersections = heap_intersections.?[0..intersection_count];
                }

                // Find actual intersections
                var idx: usize = 0;
                for (0..polygon.len) |i| {
                    const p1 = polygon[i];
                    const p2 = polygon[(i + 1) % polygon.len];

                    if ((p1.y <= fy and p2.y > fy) or (p2.y <= fy and p1.y > fy)) {
                        const intersection = p1.x + (fy - p1.y) * (p2.x - p1.x) / (p2.y - p1.y);
                        intersections[idx] = intersection;
                        idx += 1;
                    }
                }

                // Get intersection slice
                const intersection_slice = intersections;

                // Sort intersections
                if (intersection_slice.len > 1) {
                    std.mem.sort(f32, intersection_slice, {}, std.sort.asc(f32));
                }

                // Fill between pairs of intersections
                var i: usize = 0;
                while (i + 1 < intersection_slice.len) : (i += 2) {
                    const left_edge = intersection_slice[i];
                    const right_edge = intersection_slice[i + 1];

                    const x_start = @max(0, @as(i32, @intFromFloat(@floor(left_edge))));
                    const x_end = @min(@as(i32, @intCast(cols)) - 1, @as(i32, @intFromFloat(@ceil(right_edge))));

                    var x = x_start;
                    while (x <= x_end) : (x += 1) {
                        const pos = @as(usize, @intCast(y)) * cols + @as(usize, @intCast(x));

                        if (mode == .smooth) {
                            // Apply antialiasing at edges
                            const fx = @as(f32, @floatFromInt(x));
                            var alpha: f32 = 1.0;
                            if (fx < left_edge + 1) {
                                alpha = @min(alpha, fx + 0.5 - left_edge);
                            }
                            if (fx > right_edge - 1) {
                                alpha = @min(alpha, right_edge - (fx - 0.5));
                            }
                            alpha = @max(0, @min(1, alpha));

                            if (alpha > 0) {
                                var c1 = convert(Rgba, self.image.data[pos]);
                                c2.a = @intFromFloat(alpha * max_alpha);
                                c1.blend(c2);
                                self.image.data[pos] = convert(T, c1);
                            }
                        } else {
                            // No antialiasing - direct pixel write
                            self.image.data[pos] = convert(T, c2);
                        }
                    }
                }
            }
        }

        /// Tessellates a cubic Bézier curve into a series of line segments (points).
        /// Writes the points directly into the provided buffer.
        fn tessellateCubicBezier(self: Self, p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), p3: Point2d(f32), buffer: []Point2d(f32)) void {
            _ = self;
            const segments = buffer.len;
            for (0..segments) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments - 1));
                buffer[i] = evalCubicBezier(p0, p1, p2, p3, t);
            }
        }
    };
}

// Property-based tests for drawing functions

// MD5 checksum tests for pixel-perfect stability
//
// These tests ensure that drawing operations produce identical results across releases.
// To update the checksums after intentional changes to drawing algorithms:
//   zig build test -Dprint-md5sums=true
// Then copy the printed checksums into the md5_checksums array below.
const DrawTestCase = struct {
    name: []const u8,
    md5sum: []const u8,
    draw_fn: *const fn (canvas: Canvas(Rgba)) void,
};

// Golden MD5 checksums for drawing operations
const md5_checksums = [_]DrawTestCase{
    .{ .name = "line_horizontal", .md5sum = "96fc75d0d893373c0050e5fe76f5d7ea", .draw_fn = drawLineHorizontal },
    .{ .name = "line_vertical", .md5sum = "f7d52e274636af2b20b62172a408b446", .draw_fn = drawLineVertical },
    .{ .name = "line_diagonal", .md5sum = "1aee6bf80fd2e6a849e5520937566478", .draw_fn = drawLineDiagonal },
    .{ .name = "line_thick", .md5sum = "d8323d8d6580a34e724873701245f117", .draw_fn = drawLineThick },
    .{ .name = "circle_filled_solid", .md5sum = "efe2aa5419c9ffdead0dfddffb3b6a67", .draw_fn = drawCircleFilledSolid },
    .{ .name = "circle_filled_smooth", .md5sum = "4996924718641236276cdb1c166ae515", .draw_fn = drawCircleFilledSmooth },
    .{ .name = "circle_outline", .md5sum = "ae7e973d5644ff7bdde7338296e4ab40", .draw_fn = drawCircleOutline },
    .{ .name = "rectangle_filled", .md5sum = "3783f1119b7d5482b5a333f76c322c92", .draw_fn = drawRectangleFilled },
    .{ .name = "rectangle_outline", .md5sum = "033fdc24b89399af7b1810783e357b5f", .draw_fn = drawRectangleOutline },
    .{ .name = "triangle_filled", .md5sum = "283a9de3dd51dd00794559cc231ff5ac", .draw_fn = drawTriangleFilled },
    .{ .name = "bezier_cubic", .md5sum = "3a2b0d540a2353c817077729ee10007a", .draw_fn = drawBezierCubic },
    .{ .name = "bezier_quadratic", .md5sum = "9bf9d650485c3c5ed002f6766f9783c1", .draw_fn = drawBezierQuadratic },
    .{ .name = "polygon_complex", .md5sum = "da9b83426d2118ce99948eabebff91fb", .draw_fn = drawPolygonComplex },
    .{ .name = "spline_polygon", .md5sum = "61834cc2edc7c6e3398a54a584c8465e", .draw_fn = drawSplinePolygon },
};

// Test drawing functions for MD5 checksums
fn drawLineHorizontal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    canvas.drawLine(.{ .x = 10, .y = 50 }, .{ .x = 90, .y = 50 }, color, 1, .solid);
}

fn drawLineVertical(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    canvas.drawLine(.{ .x = 50, .y = 10 }, .{ .x = 50, .y = 90 }, color, 1, .solid);
}

fn drawLineDiagonal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    canvas.drawLine(.{ .x = 10, .y = 10 }, .{ .x = 90, .y = 90 }, color, 1, .solid);
}

fn drawLineThick(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 0, .a = 255 };
    canvas.drawLine(.{ .x = 20, .y = 20 }, .{ .x = 80, .y = 80 }, color, 5, .smooth);
}

fn drawCircleFilledSolid(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 0, .b = 128, .a = 255 };
    canvas.fillCircle(.{ .x = 50, .y = 50 }, 30, color, .solid);
}

fn drawCircleFilledSmooth(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 128, .b = 128, .a = 255 };
    canvas.fillCircle(.{ .x = 50, .y = 50 }, 25, color, .smooth);
}

fn drawCircleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 255, .b = 0, .a = 255 };
    canvas.drawCircle(.{ .x = 50, .y = 50 }, 35, color, 3, .smooth);
}

fn drawRectangleFilled(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 64, .g = 128, .b = 192, .a = 255 };
    const rect = Rectangle(f32){ .l = 20, .t = 30, .r = 80, .b = 70 };
    const corners = [_]Point2d(f32){
        .{ .x = rect.l, .y = rect.t },
        .{ .x = rect.r, .y = rect.t },
        .{ .x = rect.r, .y = rect.b },
        .{ .x = rect.l, .y = rect.b },
    };
    canvas.fillPolygon(&corners, color, .solid) catch unreachable;
}

fn drawRectangleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 64, .b = 128, .a = 255 };
    const rect = Rectangle(f32){ .l = 15, .t = 25, .r = 85, .b = 75 };
    canvas.drawRectangle(rect, color, 2, .smooth);
}

fn drawTriangleFilled(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 192, .b = 128, .a = 255 };
    const triangle = [_]Point2d(f32){
        .{ .x = 50, .y = 20 },
        .{ .x = 80, .y = 80 },
        .{ .x = 20, .y = 80 },
    };
    canvas.fillPolygon(&triangle, color, .smooth) catch unreachable;
}

fn drawBezierCubic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 192, .b = 255, .a = 255 };
    canvas.drawCubicBezier(
        .{ .x = 10, .y = 50 },
        .{ .x = 30, .y = 10 },
        .{ .x = 70, .y = 90 },
        .{ .x = 90, .y = 50 },
        color,
        2,
        .solid,
    );
}

fn drawBezierQuadratic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 192, .a = 255 };
    canvas.drawQuadraticBezier(
        .{ .x = 20, .y = 80 },
        .{ .x = 50, .y = 20 },
        .{ .x = 80, .y = 80 },
        color,
        3,
        .smooth,
    );
}

fn drawPolygonComplex(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 255, .b = 128, .a = 255 };
    const polygon = [_]Point2d(f32){
        .{ .x = 50, .y = 10 },
        .{ .x = 70, .y = 30 },
        .{ .x = 90, .y = 40 },
        .{ .x = 70, .y = 60 },
        .{ .x = 50, .y = 90 },
        .{ .x = 30, .y = 60 },
        .{ .x = 10, .y = 40 },
        .{ .x = 30, .y = 30 },
    };
    canvas.fillPolygon(&polygon, color, .smooth) catch unreachable;
}

fn drawSplinePolygon(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 128, .b = 255, .a = 255 };
    const polygon = [_]Point2d(f32){
        .{ .x = 50, .y = 20 },
        .{ .x = 80, .y = 35 },
        .{ .x = 80, .y = 65 },
        .{ .x = 50, .y = 80 },
        .{ .x = 20, .y = 65 },
        .{ .x = 20, .y = 35 },
    };
    canvas.drawSplinePolygon(&polygon, color, 2, 0.5, .smooth);
}

test "MD5 checksum regression tests" {
    const allocator = testing.allocator;
    const print_md5sums = @import("build_options").print_md5sums;

    // Fixed size for consistent checksums
    const width = 100;
    const height = 100;

    for (md5_checksums) |test_case| {
        var img = try Image(Rgba).initAlloc(allocator, width, height);
        defer img.deinit(allocator);

        // White background
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        const canvas = Canvas(Rgba).init(img, allocator);
        test_case.draw_fn(canvas);

        // Calculate MD5
        var md5sum: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        std.crypto.hash.Md5.hash(img.asBytes(), &md5sum, .{});
        const hex_bytes = std.fmt.bytesToHex(md5sum, .lower);

        if (print_md5sums) {
            std.debug.print("    .{{ .name = \"{s}\", .md5sum = \"{s}\", .draw_fn = {s} }},\n", .{
                test_case.name,
                &hex_bytes,
                test_case.name,
            });
        } else {
            try expectEqualStrings(&hex_bytes, test_case.md5sum);
        }
    }
}

test "line endpoints are connected" {
    const allocator = testing.allocator;
    const width = 100;
    const height = 100;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    // Fill with white
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test various line directions
    const test_cases = [_]struct { p1: Point2d(f32), p2: Point2d(f32) }{
        .{ .p1 = .{ .x = 10, .y = 10 }, .p2 = .{ .x = 90, .y = 10 } }, // horizontal
        .{ .p1 = .{ .x = 10, .y = 10 }, .p2 = .{ .x = 10, .y = 90 } }, // vertical
        .{ .p1 = .{ .x = 10, .y = 10 }, .p2 = .{ .x = 90, .y = 90 } }, // diagonal
        .{ .p1 = .{ .x = 90, .y = 10 }, .p2 = .{ .x = 10, .y = 90 } }, // reverse diagonal
    };

    for (test_cases) |tc| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.drawLine(tc.p1, tc.p2, color, 1, .solid);

        // Check that endpoints are set (or very close)
        // At least one pixel near each endpoint should be black
        var p1_found = false;
        var p2_found = false;

        // Check 3x3 area around endpoints
        for (0..3) |dy| {
            for (0..3) |dx| {
                const y1 = @as(i32, @intFromFloat(tc.p1.y)) + @as(i32, @intCast(dy)) - 1;
                const x1 = @as(i32, @intFromFloat(tc.p1.x)) + @as(i32, @intCast(dx)) - 1;
                const y2 = @as(i32, @intFromFloat(tc.p2.y)) + @as(i32, @intCast(dy)) - 1;
                const x2 = @as(i32, @intFromFloat(tc.p2.x)) + @as(i32, @intCast(dx)) - 1;

                if (y1 >= 0 and y1 < height and x1 >= 0 and x1 < width) {
                    const idx1 = @as(usize, @intCast(y1)) * width + @as(usize, @intCast(x1));
                    if (img.data[idx1].r == 0) p1_found = true;
                }

                if (y2 >= 0 and y2 < height and x2 >= 0 and x2 < width) {
                    const idx2 = @as(usize, @intCast(y2)) * width + @as(usize, @intCast(x2));
                    if (img.data[idx2].r == 0) p2_found = true;
                }
            }
        }

        try expect(p1_found);
        try expect(p2_found);
    }
}

test "thick lines have correct width" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test different line widths
    const line_widths = [_]usize{ 1, 3, 5, 10, 20 };

    for (line_widths) |line_width| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        // Draw horizontal line in the middle
        const y = @as(f32, @floatFromInt(height / 2));
        canvas.drawLine(.{ .x = 50, .y = y }, .{ .x = 150, .y = y }, color, line_width, .solid);

        // Measure actual width at several points along the line
        var measured_widths: [3]usize = .{ 0, 0, 0 };
        const x_positions = [_]usize{ 75, 100, 125 };

        for (x_positions, 0..) |x, i| {
            var min_y: usize = height;
            var max_y: usize = 0;

            for (0..height) |py| {
                const idx = py * width + x;
                if (img.data[idx].r == 0) {
                    min_y = @min(min_y, py);
                    max_y = @max(max_y, py);
                }
            }

            if (max_y >= min_y) {
                measured_widths[i] = max_y - min_y + 1;
            }
        }

        // Allow for some tolerance due to rounding
        for (measured_widths) |measured| {
            try expect(measured >= line_width - 1 and measured <= line_width + 1);
        }
    }
}

test "filled circle has correct radius" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const test_radii = [_]f32{ 5, 10, 20, 30, 40 };
    const center = Point2d(f32){ .x = 100, .y = 100 };

    for (test_radii) |radius| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.fillCircle(center, radius, color, .solid);

        // Check pixels at various distances from center
        var inside_count: usize = 0;
        var outside_count: usize = 0;
        var edge_count: usize = 0;

        for (0..height) |y| {
            for (0..width) |x| {
                const dx = @as(f32, @floatFromInt(x)) - center.x;
                const dy = @as(f32, @floatFromInt(y)) - center.y;
                const dist = @sqrt(dx * dx + dy * dy);
                const idx = y * width + x;
                const is_black = img.data[idx].r == 0;

                if (dist < radius - 1) {
                    // Should be inside
                    if (is_black) inside_count += 1;
                } else if (dist > radius + 1) {
                    // Should be outside
                    if (!is_black) outside_count += 1;
                } else {
                    // Edge region
                    edge_count += 1;
                }
            }
        }

        // Most pixels inside radius should be filled
        const inside_total = @as(usize, @intFromFloat(std.math.pi * (radius - 1) * (radius - 1)));
        // Allow 15% tolerance for small circles due to discretization
        const tolerance_factor: f32 = if (radius <= 10) 0.85 else 0.9;
        const expected_count = @as(usize, @intFromFloat(@as(f32, @floatFromInt(inside_total)) * tolerance_factor));
        try expect(inside_count >= expected_count);
    }
}

test "circle outline has correct thickness" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const center = Point2d(f32){ .x = 100, .y = 100 };
    const radius: f32 = 40;
    const line_widths = [_]usize{ 1, 3, 5, 10 };

    for (line_widths) |line_width| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.drawCircle(center, radius, color, line_width, .solid);

        // Sample along several radii to check thickness
        const angles = [_]f32{ 0, std.math.pi / @as(f32, 4), std.math.pi / @as(f32, 2), 3 * std.math.pi / @as(f32, 4) };

        for (angles) |angle| {
            var black_pixels: usize = 0;

            // Count black pixels along this radius
            var r: f32 = 0;
            while (r < radius * 2) : (r += 0.5) {
                const x = center.x + r * @cos(angle);
                const y = center.y + r * @sin(angle);

                if (x >= 0 and x < width and y >= 0 and y < height) {
                    const idx = @as(usize, @intFromFloat(y)) * width + @as(usize, @intFromFloat(x));
                    if (img.data[idx].r == 0) {
                        black_pixels += 1;
                    }
                }
            }

            // Should have approximately line_width black pixels
            try expect(black_pixels >= line_width / 2 and black_pixels <= line_width * 3);
        }
    }
}

test "filled rectangle has correct area" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const rect = Rectangle(f32){ .l = 50, .t = 50, .r = 150, .b = 130 };
    const rect_width = rect.r - rect.l;
    const rect_height = rect.b - rect.t;
    const expected_area = rect_width * rect_height;

    // Clear and draw filled rectangle using polygon fill
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    const corners = [_]Point2d(f32){
        .{ .x = rect.l, .y = rect.t },
        .{ .x = rect.r, .y = rect.t },
        .{ .x = rect.r, .y = rect.b },
        .{ .x = rect.l, .y = rect.b },
    };
    try canvas.fillPolygon(&corners, color, .solid);

    // Count black pixels
    var black_pixels: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0) black_pixels += 1;
    }

    // Should match expected area closely
    const tolerance = expected_area * 0.01; // 1% tolerance
    const diff = @abs(@as(f32, @floatFromInt(black_pixels)) - expected_area);
    try expect(diff <= tolerance);
}

test "polygon fill respects convexity" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test convex polygon (triangle)
    const triangle = [_]Point2d(f32){
        .{ .x = 100, .y = 30 },
        .{ .x = 170, .y = 150 },
        .{ .x = 30, .y = 150 },
    };

    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    try canvas.fillPolygon(&triangle, color, .solid);

    // Check that points inside triangle are filled
    const test_points = [_]struct { p: Point2d(f32), inside: bool }{
        .{ .p = .{ .x = 100, .y = 100 }, .inside = true }, // centroid
        .{ .p = .{ .x = 100, .y = 50 }, .inside = true }, // near top
        .{ .p = .{ .x = 50, .y = 140 }, .inside = true }, // near bottom left
        .{ .p = .{ .x = 150, .y = 140 }, .inside = true }, // near bottom right
        .{ .p = .{ .x = 20, .y = 20 }, .inside = false }, // outside
        .{ .p = .{ .x = 180, .y = 180 }, .inside = false }, // outside
    };

    for (test_points) |tp| {
        const x = @as(usize, @intFromFloat(tp.p.x));
        const y = @as(usize, @intFromFloat(tp.p.y));
        if (x < width and y < height) {
            const idx = y * width + x;
            const is_black = img.data[idx].r == 0;
            try expectEqual(tp.inside, is_black);
        }
    }
}

test "antialiased vs solid fill coverage" {
    const allocator = testing.allocator;
    const width = 100;
    const height = 100;
    var img_solid = try Image(Rgba).initAlloc(allocator, width, height);
    defer img_solid.deinit(allocator);
    var img_smooth = try Image(Rgba).initAlloc(allocator, width, height);
    defer img_smooth.deinit(allocator);

    const canvas_solid = Canvas(Rgba).init(img_solid, allocator);
    const canvas_smooth = Canvas(Rgba).init(img_smooth, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Clear both images
    for (img_solid.data, img_smooth.data) |*p1, *p2| {
        p1.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        p2.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    // Draw same circle with different modes
    const center = Point2d(f32){ .x = 50, .y = 50 };
    const radius: f32 = 20;

    canvas_solid.fillCircle(center, radius, color, .solid);
    canvas_smooth.fillCircle(center, radius, color, .smooth);

    // Count coverage (sum of darkness)
    var solid_coverage: f32 = 0;
    var smooth_coverage: f32 = 0;

    for (img_solid.data, img_smooth.data) |p1, p2| {
        solid_coverage += @as(f32, @floatFromInt(255 - p1.r));
        smooth_coverage += @as(f32, @floatFromInt(255 - p2.r));
    }

    // Antialiased version should have similar total coverage
    // but slightly less due to edge smoothing
    try expect(smooth_coverage > solid_coverage * 0.9);
    try expect(smooth_coverage <= solid_coverage);
}

test "bezier curve smoothness" {
    const allocator = testing.allocator;
    const width = 200;
    const height = 200;
    var img = try Image(Rgba).initAlloc(allocator, width, height);
    defer img.deinit(allocator);

    const canvas = Canvas(Rgba).init(img, allocator);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Clear image
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    // Draw cubic bezier
    const p0 = Point2d(f32){ .x = 20, .y = 100 };
    const p1 = Point2d(f32){ .x = 60, .y = 20 };
    const p2 = Point2d(f32){ .x = 140, .y = 180 };
    const p3 = Point2d(f32){ .x = 180, .y = 100 };

    canvas.drawCubicBezier(p0, p1, p2, p3, color, 2, .solid);

    // Verify endpoints are connected
    var p0_found = false;
    var p3_found = false;

    // Check 3x3 area around endpoints
    for (0..3) |dy| {
        for (0..3) |dx| {
            const y0 = @as(i32, @intFromFloat(p0.y)) + @as(i32, @intCast(dy)) - 1;
            const x0 = @as(i32, @intFromFloat(p0.x)) + @as(i32, @intCast(dx)) - 1;
            const y3 = @as(i32, @intFromFloat(p3.y)) + @as(i32, @intCast(dy)) - 1;
            const x3 = @as(i32, @intFromFloat(p3.x)) + @as(i32, @intCast(dx)) - 1;

            if (y0 >= 0 and y0 < height and x0 >= 0 and x0 < width) {
                const idx0 = @as(usize, @intCast(y0)) * width + @as(usize, @intCast(x0));
                if (img.data[idx0].r == 0) p0_found = true;
            }

            if (y3 >= 0 and y3 < height and x3 >= 0 and x3 < width) {
                const idx3 = @as(usize, @intCast(y3)) * width + @as(usize, @intCast(x3));
                if (img.data[idx3].r == 0) p3_found = true;
            }
        }
    }

    try expect(p0_found);
    try expect(p3_found);

    // Verify curve has pixels (not empty)
    var black_pixel_count: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 0) black_pixel_count += 1;
    }
    try expect(black_pixel_count > 50); // Should have a reasonable number of pixels
}

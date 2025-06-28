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

        /// Creates a drawing canvas from an image, with an optional allocator for operations that need it.
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
            
            var points = std.ArrayList(Point2d(f32)).init(self.allocator);
            defer points.deinit();
            
            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const control_points = calculateSmoothControlPoints(p0, p1, p2, tension);
                
                // Use adaptive tessellation based on curve length
                const estimated_length = estimateCubicBezierLength(p0, control_points.cp1, control_points.cp2, p1);
                const segments = @max(4, @min(50, @as(usize, @intFromFloat(estimated_length / 3.0))));
                
                const segment = try self.tessellateCubicBezier(p0, control_points.cp1, control_points.cp2, p1, segments, null);
                defer self.allocator.free(segment);
                try points.appendSlice(segment);
            }
            
            try self.fillPolygon(points.items, color, mode);
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

            // Use fixed array for intersections - 256 should be enough for everyone
            const max_intersections = 256;
            var intersections: [max_intersections]f32 = undefined;

            var c2 = convert(Rgba, color);
            const max_alpha: f32 = @floatFromInt(c2.a);

            var y = start_y;
            while (y <= end_y) : (y += 1) {
                const fy: f32 = @floatFromInt(y);
                var intersection_count: usize = 0;

                // Find intersections with polygon edges
                for (0..polygon.len) |i| {
                    const p1 = polygon[i];
                    const p2 = polygon[(i + 1) % polygon.len];

                    if ((p1.y <= fy and p2.y > fy) or (p2.y <= fy and p1.y > fy)) {
                        const intersection = p1.x + (fy - p1.y) * (p2.x - p1.x) / (p2.y - p1.y);

                        if (intersection_count >= max_intersections) {
                            return error.TooManyIntersections;
                        }

                        intersections[intersection_count] = intersection;
                        intersection_count += 1;
                    }
                }

                // Get intersection slice
                const intersection_slice = intersections[0..intersection_count];

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
        /// If buffer is provided, it will be used instead of allocating new memory.
        fn tessellateCubicBezier(self: Self, p0: Point2d(f32), p1: Point2d(f32), p2: Point2d(f32), p3: Point2d(f32), segments: usize, buffer: ?[]Point2d(f32)) anyerror![]const Point2d(f32) {
            if (buffer) |buf| {
                // Use provided buffer
                const actual_segments = @min(segments, buf.len);
                for (0..actual_segments) |i| {
                    const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(actual_segments - 1));
                    buf[i] = evalCubicBezier(p0, p1, p2, p3, t);
                }
                return buf[0..actual_segments];
            } else {
                // Allocate new memory
                var polygon = try self.allocator.alloc(Point2d(f32), segments);
                for (0..segments) |i| {
                    const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments - 1));
                    polygon[i] = evalCubicBezier(p0, p1, p2, p3, t);
                }
                return polygon;
            }
        }

    };
}

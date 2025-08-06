//! This module provides a Canvas for drawing various shapes and lines on images.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

const as = @import("meta.zig").as;
const BitmapFont = @import("font.zig").BitmapFont;
const convertColor = @import("color.zig").convertColor;
const Point = @import("geometry/Point.zig").Point;
const Image = @import("image.zig").Image;
const isColor = @import("color.zig").isColor;
const Rectangle = @import("geometry.zig").Rectangle;
const Rgba = @import("color.zig").Rgba;

/// Rendering quality mode for drawing operations
pub const DrawMode = enum {
    /// Fast rendering - hard edges, maximum performance
    fast,
    /// Soft rendering - antialiased edges, better quality
    soft,
};

/// A drawing context for an image, providing methods to draw shapes and lines.
pub fn Canvas(comptime T: type) type {
    return struct {
        image: Image(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        // Drawing-related constants
        /// Maximum number of line segments when tessellating Bézier curves for line drawing
        const bezier_max_segments_count = 200;
        /// Maximum number of line segments when tessellating spline polygons
        const spline_max_segments_count = 50;
        /// Minimum number of line segments for spline curves to ensure reasonable quality
        const spline_min_segments_count = 4;
        /// Minimum number of line segments for quadratic Bézier curves
        const quadratic_min_segments_count = 3;
        /// Target pixels per segment for smooth/antialiased rendering (higher quality, more segments)
        const pixels_per_segment_soft = 1.5;
        /// Target pixels per segment for solid/fast rendering (lower quality, fewer segments)
        const pixels_per_segment_fast = 3.0;
        /// Target pixels per segment specifically for quadratic Bézier curves
        const pixels_per_segment_quadratic = 2.0;
        /// Offset for antialiasing edge calculations (0.5 = pixel center alignment)
        const antialias_edge_offset = 0.5;
        /// Threshold for detecting horizontal/vertical lines in line drawing algorithms
        const horizontal_vertical_threshold = 0.001;
        /// Stack buffer size for polygon intersection calculations (avoids allocation for most cases)
        const polygon_intersection_stack_buffer_size = 64;
        /// Stack buffer size for spline polygon tessellation (avoids allocation for typical polygons)
        const spline_polygon_stack_buffer_size = 400;

        /// Creates a drawing canvas from an image.
        pub fn init(allocator: std.mem.Allocator, image: Image(T)) Self {
            return .{ .image = image, .allocator = allocator };
        }

        /// Clamps a floating-point coordinate to image bounds and converts to usize.
        /// Returns the clamped coordinate as a usize index.
        inline fn clampToImageBounds(coord: f32, max_size: usize) usize {
            return @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(max_size)), coord)));
        }

        /// Clamps a rectangle to image bounds and returns integer pixel coordinates.
        /// Returns null if the rectangle is completely outside the image.
        inline fn clampRectToImage(self: Self, rect: Rectangle(f32)) ?Rectangle(usize) {
            const left = clampToImageBounds(rect.l, self.image.cols);
            const top = clampToImageBounds(rect.t, self.image.rows);
            const right = clampToImageBounds(rect.r, self.image.cols);
            const bottom = clampToImageBounds(rect.b, self.image.rows);

            // Check if rectangle is valid after clamping
            if (left >= right or top >= bottom) {
                return null;
            }

            return .{ .l = left, .t = top, .r = right, .b = bottom };
        }

        /// Fills the entire canvas with a solid color using @memset.
        pub fn fill(self: Self, color: anytype) void {
            self.image.fill(color);
        }

        /// Gets a reference to the pixel at the given coordinates.
        /// Panics if coordinates are out of bounds.
        pub inline fn at(self: Self, row: usize, col: usize) *T {
            return self.image.at(row, col);
        }

        /// Gets a reference to the pixel at the given coordinates, or null if out of bounds.
        pub inline fn atOrNull(self: Self, row: isize, col: isize) ?*T {
            return self.image.atOrNull(row, col);
        }

        /// Returns the number of rows (height) in the canvas.
        pub inline fn rows(self: Self) usize {
            return self.image.rows;
        }

        /// Returns the number of columns (width) in the canvas.
        pub inline fn cols(self: Self) usize {
            return self.image.cols;
        }

        /// Returns the total number of pixels in the canvas (rows * cols).
        pub inline fn size(self: Self) usize {
            return self.image.size();
        }

        /// Returns true if and only if this canvas and `other` have the same number of rows and columns.
        /// It does not compare pixel data or types.
        pub inline fn hasSameShape(self: Self, other: anytype) bool {
            return self.image.hasSameShape(other.image);
        }

        /// Creates a view (sub-canvas) of this canvas within the specified rectangle.
        /// The view shares memory with the parent canvas - changes are reflected in both.
        /// Coordinates are automatically clipped to the canvas bounds.
        pub fn view(self: Self, rect: Rectangle(usize)) Self {
            return .{
                .image = self.image.view(rect),
                .allocator = self.allocator,
            };
        }

        /// Sets a horizontal span to `color` using @memset.
        pub fn setHorizontalSpan(self: Self, x1: f32, x2: f32, y: f32, color: T) void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);

            if (y < 0 or y >= frows) return;
            if (x2 < 0 or x1 >= fcols) return;

            const row: usize = @intFromFloat(y);
            const start: usize = @intFromFloat(@max(0, @floor(x1)));
            const end: usize = @intFromFloat(@min(fcols - 1, @ceil(x2)));

            if (start > end) return;

            const offset = row * self.image.stride + start;
            const len = end - start + 1;
            @memset(self.image.data[offset .. offset + len], color);
        }

        /// Draws a line between two points with configurable width and rendering quality.
        ///
        /// Algorithm selection:
        /// - Width 1, fast mode: Bresenham's algorithm (pixel-perfect, no antialiasing)
        /// - Width 1, soft mode: Xiaolin Wu's algorithm (smooth antialiasing)
        /// - Width >1, fast mode: Rectangle with circular caps (solid rendering)
        /// - Width >1, soft mode: Distance-based antialiasing (superior quality)
        ///
        /// Parameters:
        /// - p1, p2: Line endpoints in floating-point coordinates
        /// - color: Any color type (Rgba colors support alpha blending)
        /// - width: Line thickness in pixels (0 = no drawing)
        /// - mode: .fast (performance) or .soft (quality with antialiasing)
        pub fn drawLine(self: Self, p1: Point(2, f32), p2: Point(2, f32), color: anytype, width: usize, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            switch (mode) {
                .fast => self.drawLineFast(p1, p2, width, color),
                .soft => self.drawLineSoft(p1, p2, width, color),
            }
        }

        /// Internal dispatcher for fast (non-antialiased) line rendering.
        /// - Width 1: Uses Bresenham's algorithm for pixel-perfect precision
        /// - Width >1: Uses rectangle-based approach with circular end caps
        fn drawLineFast(self: Self, p1: Point(2, f32), p2: Point(2, f32), width: usize, color: anytype) void {
            if (width == 1) {
                // Use Bresenham's algorithm for 1px lines - fast and precise
                self.drawLineBresenham(p1, p2, color);
            } else {
                // Use polygon-based approach for thick lines
                self.drawLineRectangle(p1, p2, width, color);
            }
        }
        /// Internal dispatcher for soft (antialiased) line rendering.
        /// - Width 1: Uses Xiaolin Wu's algorithm for optimal thin line antialiasing
        /// - Width >1: Uses distance-based algorithm for superior thick line quality
        fn drawLineSoft(self: Self, p1: Point(2, f32), p2: Point(2, f32), width: usize, color: anytype) void {
            if (width == 1) {
                // Use Wu's algorithm for 1px lines - optimal antialiasing and performance
                self.drawLineXiaolinWu(p1, p2, color);
            } else {
                // Use distance-based antialiasing for thick lines - better quality
                self.drawLineDistance(p1, p2, width, color);
            }
        }

        /// Bresenham's line algorithm for 1-pixel width lines.
        /// Classic rasterization algorithm using integer arithmetic for maximum speed.
        /// Produces pixel-perfect lines with hard edges and no antialiasing.
        /// Optimal for grid-aligned graphics and when performance is critical.
        fn drawLineBresenham(self: Self, p1: Point(2, f32), p2: Point(2, f32), color: anytype) void {
            var x1: i32 = @intFromFloat(p1.x());
            var y1: i32 = @intFromFloat(p1.y());
            const x2: i32 = @intFromFloat(p2.x());
            const y2: i32 = @intFromFloat(p2.y());

            const pixel_color = convertColor(T, color);

            // Special case for horizontal lines - use fillHorizontalSpan for better performance
            if (y1 == y2) {
                const min_x = @min(x1, x2);
                const max_x = @max(x1, x2);
                self.setHorizontalSpan(@floatFromInt(min_x), @floatFromInt(max_x), @floatFromInt(y1), pixel_color);
                return;
            }

            // Special case for vertical lines - direct pixel access
            if (x1 == x2) {
                const min_y = @min(y1, y2);
                const max_y = @max(y1, y2);
                var y = min_y;
                while (y <= max_y) : (y += 1) {
                    if (self.atOrNull(y, x1)) |pixel| {
                        pixel.* = pixel_color;
                    }
                }
                return;
            }

            // General case - standard Bresenham algorithm
            const dx: i32 = @intCast(@abs(x2 - x1));
            const dy: i32 = @intCast(@abs(y2 - y1));
            const sx: i32 = if (x1 < x2) 1 else -1;
            const sy: i32 = if (y1 < y2) 1 else -1;
            var err = dx - dy;

            while (true) {
                if (self.atOrNull(y1, x1)) |pixel| {
                    pixel.* = pixel_color;
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
        }

        /// Xiaolin Wu's antialiasing algorithm for 1-pixel width lines.
        /// Uses fractional coverage to create smooth line edges with alpha blending.
        /// Handles steep vs. shallow lines optimally by swapping coordinates.
        /// Provides the best quality-to-performance ratio for thin antialiased lines.
        fn drawLineXiaolinWu(self: Self, p1: Point(2, f32), p2: Point(2, f32), color: anytype) void {
            const c2 = convertColor(Rgba, color);

            var x1 = p1.x();
            var y1 = p1.y();
            var x2 = p2.x();
            var y2 = p2.y();

            // Special case for perfectly horizontal lines
            if (@abs(y2 - y1) < 0.01) {
                const y = @round(y1);
                const min_x = @min(x1, x2);
                const max_x = @max(x1, x2);

                // Handle fractional endpoints with antialiasing
                const left_x = @floor(min_x);
                const right_x = @ceil(max_x);

                // Left endpoint antialiasing
                if (min_x > left_x) {
                    const alpha = min_x - left_x;
                    self.setPixel(.point(.{ left_x, y }), c2.fade(alpha));
                }

                // Middle solid part - use fillHorizontalSpan for performance
                const solid_start = @ceil(min_x);
                const solid_end = @floor(max_x);
                if (solid_end >= solid_start) {
                    self.setHorizontalSpan(solid_start, solid_end, y, convertColor(T, c2));
                }

                // Right endpoint antialiasing
                if (max_x < right_x) {
                    const alpha = right_x - max_x;
                    self.setPixel(.point(.{ right_x, y }), c2.fade(alpha));
                }

                return;
            }

            const steep = @abs(y2 - y1) > @abs(x2 - x1);
            if (steep) {
                std.mem.swap(f32, &x1, &y1);
                std.mem.swap(f32, &x2, &y2);
            }
            if (x1 > x2) {
                std.mem.swap(f32, &x1, &x2);
                std.mem.swap(f32, &y1, &y2);
            }

            const dx = x2 - x1;
            const dy = y2 - y1;
            const gradient = if (dx == 0) 1.0 else dy / dx;

            // Handle first endpoint
            var x_end = @round(x1);
            var y_end = y1 + gradient * (x_end - x1);
            var x_gap = rfpart(x1 + 0.5);

            if (steep) {
                self.setPixel(.point(.{ y_end, x_end }), c2.fade(rfpart(y_end) * x_gap));
                self.setPixel(.point(.{ y_end + 1, x_end }), c2.fade(fpart(y_end) * x_gap));
            } else {
                self.setPixel(.point(.{ x_end, y_end }), c2.fade(rfpart(y_end) * x_gap));
                self.setPixel(.point(.{ x_end, y_end + 1 }), c2.fade(fpart(y_end) * x_gap));
            }
            var intery = y_end + gradient;

            // Handle second endpoint
            x_end = @round(x2);
            y_end = y2 + gradient * (x_end - x2);
            x_gap = fpart(x2 + 0.5);

            if (steep) {
                self.setPixel(.point(.{ y_end, x_end }), c2.fade(rfpart(y_end) * x_gap));
                self.setPixel(.point(.{ y_end + 1, x_end }), c2.fade(fpart(y_end) * x_gap));
            } else {
                self.setPixel(.point(.{ x_end, y_end }), c2.fade(rfpart(y_end) * x_gap));
                self.setPixel(.point(.{ x_end, y_end + 1 }), c2.fade(fpart(y_end) * x_gap));
            }

            // Main loop
            const x_px1 = @round(x1);
            const x_px2 = @round(x2);
            var x = x_px1 + 1;
            while (x < x_px2) : (x += 1) {
                if (steep) {
                    self.setPixel(.point(.{ intery, x }), c2.fade(rfpart(intery)));
                    self.setPixel(.point(.{ intery + 1, x }), c2.fade(fpart(intery)));
                } else {
                    self.setPixel(.point(.{ x, intery }), c2.fade(rfpart(intery)));
                    self.setPixel(.point(.{ x, intery + 1 }), c2.fade(fpart(intery)));
                }
                intery += gradient;
            }
        }

        /// Rectangle-based thick line rendering for fast (non-antialiased) mode.
        /// Constructs a filled rectangle perpendicular to the line direction,
        /// then adds circular end caps for smooth line termination.
        /// Handles zero-length lines by drawing a single filled circle.
        fn drawLineRectangle(self: Self, p1: Point(2, f32), p2: Point(2, f32), width: usize, color: anytype) void {
            const solid_color = convertColor(T, color);

            // For thick lines, draw as a filled rectangle
            const dx = p2.x() - p1.x();
            const dy = p2.y() - p1.y();
            const line_length = @sqrt(dx * dx + dy * dy);

            if (line_length == 0) {
                // Single point - draw a filled circle
                const half_width: f32 = @as(f32, @floatFromInt(width)) / 2.0;
                self.fillCircle(p1, half_width, color, .fast);
                return;
            }

            // Calculate perpendicular vector for thick line
            const half_width: f32 = @as(f32, @floatFromInt(width)) / 2.0;
            const perp_x = -dy / line_length * half_width;
            const perp_y = dx / line_length * half_width;

            // Create rectangle corners
            const corners = [_]Point(2, f32){
                .point(.{ p1.x() - perp_x, p1.y() - perp_y }),
                .point(.{ p1.x() + perp_x, p1.y() + perp_y }),
                .point(.{ p2.x() + perp_x, p2.y() + perp_y }),
                .point(.{ p2.x() - perp_x, p2.y() - perp_y }),
            };

            // Fill rectangle using scanline algorithm (no anti-aliasing)
            self.fillPolygon(&corners, solid_color, .fast) catch return;

            // Add rounded caps using solid circles
            self.fillCircle(p1, half_width, color, .fast);
            self.fillCircle(p2, half_width, color, .fast);
        }

        /// Distance-based antialiased rendering for thick lines.
        /// Calculates the exact perpendicular distance from each pixel to the line segment,
        /// applying smooth alpha falloff at edges for superior visual quality.
        /// Includes optimized paths for horizontal/vertical lines and handles end caps naturally.
        /// More expensive than rectangle-based approach but produces better results.
        fn drawLineDistance(self: Self, p1: Point(2, f32), p2: Point(2, f32), width: usize, color: anytype) void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const half_width: f32 = @as(f32, @floatFromInt(width)) / 2.0;
            const c2 = convertColor(Rgba, color);

            // Calculate line direction vector
            const dx = p2.x() - p1.x();
            const dy = p2.y() - p1.y();
            const line_length = @sqrt(dx * dx + dy * dy);

            if (line_length == 0) {
                // Single point - draw a small circle
                self.fillCircle(p1, half_width, color, .soft);
                return;
            }

            // Special case for perfectly horizontal/vertical lines (faster rendering)
            if (@abs(dx) < horizontal_vertical_threshold) { // Vertical line
                const x1 = @round(p1.x());
                var y1 = @round(p1.y());
                var y2 = @round(p2.y());
                if (y1 > y2) std.mem.swap(f32, &y1, &y2);
                if (x1 < 0 or x1 >= fcols) return;

                const pixel_color = convertColor(T, c2);
                var y = y1;
                while (y <= y2) : (y += 1) {
                    if (y < 0 or y >= frows) continue;
                    // Use fillHorizontalSpan for each horizontal segment of the thick vertical line
                    const x_start = x1 - half_width;
                    const x_end = x1 + half_width;
                    self.setHorizontalSpan(x_start, x_end, y, pixel_color);
                }
                // Add rounded caps
                self.fillCircle(p1, half_width, color, .soft);
                self.fillCircle(p2, half_width, color, .soft);
                return;
            } else if (@abs(dy) < horizontal_vertical_threshold) { // Horizontal line
                var x1 = @round(p1.x());
                var x2 = @round(p2.x());
                const y1 = @round(p1.y());
                if (x1 > x2) std.mem.swap(f32, &x1, &x2);
                if (y1 < 0 or y1 >= frows) return;

                const pixel_color = convertColor(T, c2);

                // Draw horizontal spans for each row of the thick line
                var i = -half_width;
                while (i <= half_width) : (i += 1) {
                    const py = y1 + i;
                    if (py >= 0 and py < frows) {
                        // For soft mode, we need to handle edge pixels with alpha blending
                        if (i == -half_width or i == half_width) {
                            // Edge rows - use setPixel for alpha blending
                            var x = x1;
                            while (x <= x2) : (x += 1) {
                                if (x >= 0 and x < fcols) {
                                    self.setPixel(.point(.{ x, py }), c2);
                                }
                            }
                        } else {
                            // Middle rows - use fillHorizontalSpan for performance
                            self.setHorizontalSpan(x1, x2, py, pixel_color);
                        }
                    }
                }
                // Add rounded caps
                self.fillCircle(p1, half_width, color, .soft);
                self.fillCircle(p2, half_width, color, .soft);
                return;
            }

            // For diagonal lines, use optimized distance-based anti-aliasing
            // Calculate tighter bounding box
            const line_min_x = @min(p1.x(), p2.x()) - half_width;
            const line_max_x = @max(p1.x(), p2.x()) + half_width;
            const line_min_y = @min(p1.y(), p2.y()) - half_width;
            const line_max_y = @max(p1.y(), p2.y()) + half_width;

            const min_x = @max(0, @floor(line_min_x));
            const max_x = @min(fcols - 1, @ceil(line_max_x));
            const min_y = @max(0, @floor(line_min_y));
            const max_y = @min(frows - 1, @ceil(line_max_y));

            // Precompute for distance calculation optimization
            const dx_sq = dx * dx;
            const dy_sq = dy * dy;
            const length_sq = dx_sq + dy_sq;
            const inv_length_sq = 1.0 / length_sq;

            // Iterate through pixels in bounding box
            var py: f32 = min_y;
            while (py <= max_y) : (py += 1) {
                var px: f32 = min_x;
                while (px <= max_x) : (px += 1) {
                    // Optimized distance calculation
                    const dpx = px - p1.x();
                    const dpy = py - p1.y();
                    const t = @max(0, @min(1, (dpx * dx + dpy * dy) * inv_length_sq));
                    const closest_x = p1.x() + t * dx;
                    const closest_y = p1.y() + t * dy;
                    const dist_x = px - closest_x;
                    const dist_y = py - closest_y;
                    const dist = @sqrt(dist_x * dist_x + dist_y * dist_y);

                    // Anti-aliased coverage based on distance
                    if (dist <= half_width + antialias_edge_offset) {
                        var alpha: f32 = 1.0;
                        if (dist > half_width - antialias_edge_offset) {
                            alpha = (half_width + antialias_edge_offset - dist);
                        }

                        if (alpha > 0) {
                            self.setPixel(.point(.{ px, py }), c2.fade(alpha));
                        }
                    }
                }
            }
        }

        /// Sets a color to a pixel at the given coordinates with alpha transparency.
        /// Uses optimized direct assignment for opaque colors or blends when transparency is needed.
        /// Provides bounds checking and handles coordinate conversion.
        /// Coordinates are truncated to integers for pixel placement.
        /// For Rgba colors, uses the color's alpha channel; for other colors, treats as opaque.
        pub fn setPixel(self: Self, point: Point(2, f32), color: anytype) void {
            const ColorType = @TypeOf(color);
            comptime assert(isColor(ColorType));
            if (self.atOrNull(@intFromFloat(point.y()), @intFromFloat(point.x()))) |pixel| {
                switch (ColorType) {
                    Rgba => {
                        if (color.a == 255) {
                            // Opaque - direct assignment
                            pixel.* = convertColor(T, color);
                        } else if (color.a > 0) {
                            // Transparent - blend
                            var dst = convertColor(Rgba, pixel.*);
                            dst.blend(color);
                            pixel.* = convertColor(T, dst);
                        }
                    },
                    else => pixel.* = convertColor(T, color),
                }
            }
        }

        /// Returns the fractional part of a floating-point number.
        /// Used in Wu's anti-aliasing algorithm to calculate pixel coverage.
        /// Example: fpart(3.7) = 0.7, fpart(-2.3) = 0.7
        fn fpart(x: f32) f32 {
            return x - @floor(x);
        }

        /// Returns the reverse fractional part (1 - fractional part).
        /// Used in Wu's anti-aliasing algorithm for complementary pixel coverage.
        /// Example: rfpart(3.7) = 0.3, rfpart(-2.3) = 0.3
        fn rfpart(x: f32) f32 {
            return 1 - fpart(x);
        }

        /// Draws the outline of a polygon on the given image.
        /// The polygon is defined by a sequence of vertices. Lines are drawn between consecutive
        /// vertices, and a final line is drawn from the last vertex to the first to close the shape.
        /// Round joints are added at vertices to ensure smooth connections.
        pub fn drawPolygon(self: Self, polygon: []const Point(2, f32), color: anytype, width: usize, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            // Draw all line segments
            for (0..polygon.len) |i| {
                self.drawLine(polygon[i], polygon[@mod(i + 1, polygon.len)], color, width, mode);
            }
        }

        /// Draws the outline of a rectangle on the given image.
        pub fn drawRectangle(self: Self, rect: Rectangle(f32), color: anytype, width: usize, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));
            // Rectangle has exclusive r,b bounds, but drawPolygon needs inclusive points
            // So we subtract 1 from r and b to get the actual corner positions
            const points: []const Point(2, f32) = &.{
                .point(.{ rect.l, rect.t }),
                .point(.{ rect.r - 1, rect.t }),
                .point(.{ rect.r - 1, rect.b - 1 }),
                .point(.{ rect.l, rect.b - 1 }),
            };
            self.drawPolygon(points, color, width, mode);
        }

        /// Fills a rectangle on the given image.
        /// The rectangle is defined using standard conventions where l,t are inclusive and r,b are exclusive.
        /// This means a rectangle from (0,0) to (10,10) will fill pixels at positions 0-9 in both dimensions.
        /// - **DrawMode.fast**: Uses @memset for optimal performance (no alpha blending)
        /// - **DrawMode.soft**: Supports alpha blending by using setPixel for each pixel
        pub fn fillRectangle(self: Self, rect: Rectangle(f32), color: anytype, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));

            // Use helper to clamp rectangle to image bounds
            const bounds = self.clampRectToImage(rect) orelse return;

            switch (mode) {
                .fast => {
                    // Fast mode: Use @memset for optimal performance (no alpha blending)
                    const target_color = convertColor(T, color);
                    for (bounds.t..bounds.b) |row| {
                        const start_idx = row * self.image.cols + bounds.l;
                        const end_idx = row * self.image.cols + bounds.r;
                        @memset(self.image.data[start_idx..end_idx], target_color);
                    }
                },
                .soft => {
                    // Soft mode: Support alpha blending by using setPixel for each pixel
                    for (bounds.t..bounds.b) |row| {
                        for (bounds.l..bounds.r) |col| {
                            self.setPixel(.point(.{ @as(f32, @floatFromInt(col)), @as(f32, @floatFromInt(row)) }), color);
                        }
                    }
                },
            }
        }

        /// Draws the outline of a circle on the given image.
        /// Use DrawMode.soft for anti-aliased edges or DrawMode.fast for fast aliased edges.
        pub fn drawCircle(self: Self, center: Point(2, f32), radius: f32, color: anytype, width: usize, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0 or width == 0) return;

            switch (mode) {
                .fast => self.drawCircleFast(center, radius, width, color),
                .soft => self.drawCircleSoft(center, radius, width, color),
            }
        }

        /// Internal function for drawing solid (aliased) circle outlines.
        fn drawCircleFast(self: Self, center: Point(2, f32), radius: f32, width: usize, color: anytype) void {
            if (width == 1) {
                // Use fast Bresenham for 1-pixel width
                const cx = @round(center.x());
                const cy = @round(center.y());
                const r = @round(radius);
                var x: f32 = r;
                var y: f32 = 0;
                var err: f32 = 0;
                while (x >= y) {
                    const points = [_]Point(2, f32){
                        .point(.{ cx + x, cy + y }),
                        .point(.{ cx - x, cy + y }),
                        .point(.{ cx + x, cy - y }),
                        .point(.{ cx - x, cy - y }),
                        .point(.{ cx + y, cy + x }),
                        .point(.{ cx - y, cy + x }),
                        .point(.{ cx + y, cy - x }),
                        .point(.{ cx - y, cy - x }),
                    };
                    for (points) |p| {
                        self.setPixel(p, color);
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
                const solid_color = convertColor(T, color);

                // Calculate bounding box
                const left: usize = @intFromFloat(@round(@max(0, center.x() - outer_radius - 1)));
                const top: usize = @intFromFloat(@round(@max(0, center.y() - outer_radius - 1)));
                const right: usize = @intFromFloat(@round(@min(fcols, center.x() + outer_radius + 1)));
                const bottom: usize = @intFromFloat(@round(@min(frows, center.y() + outer_radius + 1)));

                for (top..bottom) |r| {
                    const y = @as(f32, @floatFromInt(r)) - center.y();
                    for (left..right) |c| {
                        const x = @as(f32, @floatFromInt(c)) - center.x();
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
        fn drawCircleSoft(self: Self, center: Point(2, f32), radius: f32, width: usize, color: anytype) void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const line_width: f32 = @floatFromInt(width);
            const inner_radius = radius - line_width / 2.0;
            const outer_radius = radius + line_width / 2.0;

            // Calculate bounding box
            const left: usize = @intFromFloat(@round(@max(0, center.x() - outer_radius - 1)));
            const top: usize = @intFromFloat(@round(@max(0, center.y() - outer_radius - 1)));
            const right: usize = @intFromFloat(@round(@min(fcols, center.x() + outer_radius + 1)));
            const bottom: usize = @intFromFloat(@round(@min(frows, center.y() + outer_radius + 1)));

            const c2 = convertColor(Rgba, color);

            for (top..bottom) |r| {
                const y = @as(f32, @floatFromInt(r)) - center.y();
                for (left..right) |c| {
                    const x = @as(f32, @floatFromInt(c)) - center.x();
                    const dist = @sqrt(x * x + y * y);

                    // Only draw if we're in the ring area
                    if (dist >= inner_radius - antialias_edge_offset and dist <= outer_radius + antialias_edge_offset) {
                        var alpha: f32 = 1.0;

                        // Smooth outer edge
                        if (dist > outer_radius - antialias_edge_offset) {
                            alpha = @min(alpha, outer_radius + antialias_edge_offset - dist);
                        }

                        // Smooth inner edge
                        if (dist < inner_radius + antialias_edge_offset) {
                            alpha = @min(alpha, dist - (inner_radius - antialias_edge_offset));
                        }

                        alpha = @max(0, @min(1, alpha));

                        if (alpha > 0) {
                            self.setPixel(.point(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) }), c2.fade(alpha));
                        }
                    }
                }
            }
        }

        /// Fills the given polygon on an image using the scanline algorithm with @memset optimization.
        /// The polygon is defined by an array of points (vertices).
        ///
        /// **Rendering Modes:**
        /// - **DrawMode.fast**: Hard edges, maximum performance with @memset optimization
        /// - **DrawMode.soft**: Antialiased edges, uses alpha blending (no @memset)
        pub fn fillPolygon(self: Self, polygon: []const Point(2, f32), color: anytype, mode: DrawMode) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (polygon.len < 3) return;

            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);

            // Find bounding box for optimization
            var min_y = polygon[0].y();
            var max_y = polygon[0].y();
            for (polygon) |p| {
                min_y = @min(min_y, p.y());
                max_y = @max(max_y, p.y());
            }

            const start_y = @max(0, @floor(min_y));
            const end_y = @min(frows - 1, @ceil(max_y));

            // Use stack buffer for small polygons, fallback to heap for complex ones
            var stack_intersections: [polygon_intersection_stack_buffer_size]f32 = undefined;
            var heap_intersections: ?[]f32 = null;
            defer if (heap_intersections) |h| self.allocator.free(h);

            const c2 = convertColor(Rgba, color);
            const solid_color = convertColor(T, c2);

            var y = start_y;
            while (y <= end_y) : (y += 1) {
                var intersection_count: usize = 0;

                // Count intersections first
                for (0..polygon.len) |i| {
                    const p1 = polygon[i];
                    const p2 = polygon[(i + 1) % polygon.len];

                    if ((p1.y() <= y and p2.y() > y) or (p2.y() <= y and p1.y() > y)) {
                        intersection_count += 1;
                    }
                }

                // Get appropriate buffer
                var intersections: []f32 = undefined;
                if (intersection_count <= polygon_intersection_stack_buffer_size) {
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

                    if ((p1.y() <= y and p2.y() > y) or (p2.y() <= y and p1.y() > y)) {
                        const intersection = p1.x() + (y - p1.y()) * (p2.x() - p1.x()) / (p2.y() - p1.y());
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

                    const x_start = @max(0, @floor(left_edge));
                    const x_end = @min(fcols - 1, @ceil(right_edge));

                    switch (mode) {
                        .soft => {
                            var x = x_start;
                            while (x <= x_end) : (x += 1) {
                                // Apply antialiasing at edges
                                var alpha: f32 = 1.0;
                                if (x < left_edge + 1) {
                                    alpha = @min(alpha, x + antialias_edge_offset - left_edge);
                                }
                                if (x > right_edge - 1) {
                                    alpha = @min(alpha, right_edge - (x - antialias_edge_offset));
                                }
                                alpha = @max(0, @min(1, alpha));

                                if (alpha > 0) {
                                    self.setPixel(.point(.{ x, y }), c2.fade(alpha));
                                }
                            }
                        },
                        .fast => {
                            // Fast mode - use @memset for optimal span filling
                            self.setHorizontalSpan(left_edge, right_edge, y, solid_color);
                        },
                    }
                }
            }
        }

        /// Fills a circle on the given image.
        /// Use DrawMode.soft for anti-aliased edges or DrawMode.fast for hard edges.
        pub fn fillCircle(self: Self, center: Point(2, f32), radius: f32, color: anytype, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0) return;

            switch (mode) {
                .fast => self.fillCircleFast(center, radius, color),
                .soft => self.fillCircleSoft(center, radius, color),
            }
        }

        /// Internal function for filling smooth (anti-aliased) circles.
        fn fillCircleSoft(self: Self, center: Point(2, f32), radius: f32, color: anytype) void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);
            const left: usize = @intFromFloat(@round(@max(0, center.x() - radius)));
            const top: usize = @intFromFloat(@round(@max(0, center.y() - radius)));
            const right: usize = @intFromFloat(@round(@min(fcols, center.x() + radius)));
            const bottom: usize = @intFromFloat(@round(@min(frows, center.y() + radius)));

            for (top..bottom) |r| {
                const y = as(f32, r) - center.y();
                for (left..right) |c| {
                    const x = as(f32, c) - center.x();
                    const dist_sq = x * x + y * y;
                    if (dist_sq <= radius * radius) {
                        // Apply antialiasing at the edge
                        const dist = @sqrt(dist_sq);
                        if (dist > radius - 1) {
                            // Edge antialiasing
                            const edge_alpha = radius - dist;
                            const rgba_color = convertColor(Rgba, color);
                            self.setPixel(.point(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) }), rgba_color.fade(edge_alpha));
                        } else {
                            // Full opacity in the center - direct assignment
                            self.setPixel(.point(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) }), color);
                        }
                    }
                }
            }
        }

        /// Internal function for filling solid (non-anti-aliased) circles.
        fn fillCircleFast(self: Self, center: Point(2, f32), radius: f32, color: anytype) void {
            const solid_color = convertColor(T, color);
            const frows: f32 = @floatFromInt(self.image.rows);
            const top = @max(0, center.y() - radius);
            const bottom = @min(frows - 1, center.y() + radius);

            var y = top;
            while (y <= bottom) : (y += 1) {
                const dy = y - center.y();
                const dx = @sqrt(@max(0, radius * radius - dy * dy));

                if (dx > 0) {
                    const x1 = center.x() - dx;
                    const x2 = center.x() + dx;
                    self.setHorizontalSpan(x1, x2, y, solid_color);
                }
            }
        }

        /// Draws a quadratic Bézier curve with specified width and fill mode.
        pub fn drawQuadraticBezier(
            self: Self,
            p0: Point(2, f32),
            p1: Point(2, f32),
            p2: Point(2, f32),
            color: anytype,
            width: usize,
            mode: DrawMode,
        ) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            const estimated_length = estimateQuadraticBezierLength(p0, p1, p2);

            self.drawBezierTessellated(
                estimated_length,
                pixels_per_segment_quadratic,
                quadratic_min_segments_count,
                evalQuadraticBezier,
                .{ p0, p1, p2 },
                color,
                width,
                mode,
            );
        }

        /// Draws a cubic Bézier curve with specified width and fill mode.
        /// The curve is adaptively subdivided for optimal quality and performance.
        pub fn drawCubicBezier(
            self: Self,
            p0: Point(2, f32),
            p1: Point(2, f32),
            p2: Point(2, f32),
            p3: Point(2, f32),
            color: anytype,
            width: usize,
            mode: DrawMode,
        ) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            const estimated_length = estimateCubicBezierLength(p0, p1, p2, p3);
            const pixels_per_segment: f32 = if (mode == .soft or width > 2) pixels_per_segment_soft else pixels_per_segment_fast;

            self.drawBezierTessellated(
                estimated_length,
                pixels_per_segment,
                spline_min_segments_count,
                evalCubicBezier,
                .{ p0, p1, p2, p3 },
                color,
                width,
                mode,
            );
        }

        /// Draws a spline polygon outline with Bézier curves connecting vertices.
        /// The polygon's edges are rendered as cubic Bézier splines for smooth, curved appearance.
        /// Use tension to control curve smoothness: 0=sharp corners, 1=maximum smoothness.
        pub fn drawSplinePolygon(self: Self, polygon: []const Point(2, f32), color: anytype, width: usize, tension: f32, mode: DrawMode) void {
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
        pub fn fillSplinePolygon(self: Self, polygon: []const Point(2, f32), color: anytype, tension: f32, mode: DrawMode) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (polygon.len < 3) return;

            // Stack buffer for common cases (up to 50 segments per curve, 8 curves)
            var stack_buffer: [spline_polygon_stack_buffer_size]Point(2, f32) = undefined;
            var total_points: usize = 0;

            // First pass: calculate total points needed
            const pixels_per_segment = pixels_per_segment_fast; // Balance between quality and performance for filled shapes
            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const control_points = calculateSmoothControlPoints(p0, p1, p2, tension);
                const estimated_length = estimateCubicBezierLength(p0, control_points.cp1, control_points.cp2, p1);
                const segments = @max(spline_min_segments_count, @min(spline_max_segments_count, @as(usize, @intFromFloat(estimated_length / pixels_per_segment))));
                total_points += segments;
            }

            // Use stack buffer if possible, otherwise allocate
            var points_buffer: []Point(2, f32) = undefined;
            var heap_buffer: ?[]Point(2, f32) = null;
            defer if (heap_buffer) |h| self.allocator.free(h);

            if (total_points <= spline_polygon_stack_buffer_size) {
                points_buffer = stack_buffer[0..total_points];
            } else {
                heap_buffer = try self.allocator.alloc(Point(2, f32), total_points);
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
                const segments = @max(spline_min_segments_count, @min(spline_max_segments_count, @as(usize, @intFromFloat(estimated_length / pixels_per_segment))));

                // Tessellate directly into our buffer
                const segment_buffer = points_buffer[write_idx .. write_idx + segments];
                const actual_segments = tessellateBezier(
                    estimated_length,
                    pixels_per_segment,
                    spline_min_segments_count, // min_segments for cubic
                    spline_max_segments_count, // max_segments
                    evalCubicBezier,
                    .{ p0, control_points.cp1, control_points.cp2, p1 },
                    segment_buffer,
                );
                write_idx += actual_segments;
            }

            try self.fillPolygon(points_buffer, color, mode);
        }

        /// Evaluates a quadratic Bézier curve at parameter t.
        /// Uses the standard quadratic Bézier formula: (1-t)²P₀ + 2t(1-t)P₁ + t²P₂
        /// Parameter t is in range [0, 1] where 0=start point, 1=end point.
        fn evalQuadraticBezier(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32), t: f32) Point(2, f32) {
            const u = 1 - t;
            const uu = u * u;
            const tt = t * t;
            return .point(.{
                uu * p0.x() + 2 * u * t * p1.x() + tt * p2.x(),
                uu * p0.y() + 2 * u * t * p1.y() + tt * p2.y(),
            });
        }

        /// Evaluates a cubic Bézier curve at parameter t.
        /// Uses the standard cubic Bézier formula: (1-t)³P₀ + 3t(1-t)²P₁ + 3t²(1-t)P₂ + t³P₃
        /// Parameter t is in range [0, 1] where 0=start point, 1=end point.
        fn evalCubicBezier(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32), p3: Point(2, f32), t: f32) Point(2, f32) {
            const u = 1 - t;
            const uu = u * u;
            const uuu = uu * u;
            const tt = t * t;
            const ttt = tt * t;
            return .point(.{
                uuu * p0.x() + 3 * uu * t * p1.x() + 3 * u * tt * p2.x() + ttt * p3.x(),
                uuu * p0.y() + 3 * uu * t * p1.y() + 3 * u * tt * p2.y() + ttt * p3.y(),
            });
        }

        /// Estimates the length of a quadratic Bézier curve segment.
        /// Uses chord + control polygon approximation for fast, reasonably accurate estimation.
        /// The estimate is (chord_length + control_polygon_length) / 2.
        fn estimateQuadraticBezierLength(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32)) f32 {
            // Use chord + control polygon approximation
            const chord = p0.distance(p2);
            const control_net = p0.distance(p1) + p1.distance(p2);
            return (chord + control_net) / 2.0;
        }

        /// Estimates the length of a cubic Bézier curve segment.
        /// Uses chord + control polygon approximation for fast, reasonably accurate estimation.
        /// The estimate is (chord_length + control_polygon_length) / 2.
        fn estimateCubicBezierLength(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32), p3: Point(2, f32)) f32 {
            // Use chord + control polygon approximation
            const chord = p0.distance(p3);
            const control_net = p0.distance(p1) + p1.distance(p2) + p2.distance(p3);
            return (chord + control_net) / 2.0;
        }

        /// Tessellates a Bézier curve into discrete points for line segment rendering.
        /// Adaptively determines segment count based on curve length and desired quality.
        ///
        /// Parameters:
        /// - estimated_length: Approximate curve length in pixels
        /// - pixels_per_segment: Target distance between tessellation points
        /// - evalFn: Function to evaluate curve at parameter t (e.g. evalCubicBezier)
        /// - evalArgs: Arguments to pass to evalFn before the t parameter
        ///
        /// Returns the number of points actually written to buffer.
        fn tessellateBezier(
            estimated_length: f32,
            pixels_per_segment: f32,
            min_segments: usize,
            max_segments: usize,
            comptime evalFn: anytype,
            evalArgs: anytype,
            buffer: []Point(2, f32),
        ) usize {
            const segments = @max(min_segments, @min(max_segments, @as(usize, @intFromFloat(estimated_length / pixels_per_segment))));
            const actual_segments = @min(segments, buffer.len);

            for (0..actual_segments) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(actual_segments - 1));
                buffer[i] = @call(.auto, evalFn, evalArgs ++ .{t});
            }

            return actual_segments;
        }

        /// Draws a Bézier curve by tessellating it into line segments.
        fn drawBezierTessellated(
            self: Self,
            estimated_length: f32,
            pixels_per_segment: f32,
            min_segments: usize,
            comptime evalFn: anytype,
            evalArgs: anytype,
            color: anytype,
            width: usize,
            mode: DrawMode,
        ) void {
            var stack_buffer: [bezier_max_segments_count]Point(2, f32) = undefined;

            const actual_segments = tessellateBezier(
                estimated_length,
                pixels_per_segment,
                min_segments,
                bezier_max_segments_count,
                evalFn,
                evalArgs,
                &stack_buffer,
            );

            // Draw lines between consecutive points
            for (1..actual_segments) |i| {
                self.drawLine(stack_buffer[i - 1], stack_buffer[i], color, width, mode);
            }
        }

        /// Calculates Bézier control points for smooth spline interpolation through three points.
        /// Creates control points that produce a smooth curve through p1, influenced by p0 and p2.
        ///
        /// Parameters:
        /// - p0: Previous point (influences incoming tangent)
        /// - p1: Current point (the vertex being processed)
        /// - p2: Next point (influences outgoing tangent)
        /// - tension: Curve tension (0=sharp corners, 1=maximum smoothness)
        ///
        /// Returns control points for cubic Bézier: cp1 (outgoing from p0), cp2 (incoming to p1).
        fn calculateSmoothControlPoints(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32), tension: f32) struct { cp1: Point(2, f32), cp2: Point(2, f32) } {
            const tension_factor = 1 - @max(0, @min(1, tension));
            return .{
                .cp1 = .point(.{
                    p0.x() + (p1.x() - p0.x()) * tension_factor,
                    p0.y() + (p1.y() - p0.y()) * tension_factor,
                }),
                .cp2 = .point(.{
                    p1.x() - (p2.x() - p1.x()) * tension_factor,
                    p1.y() - (p2.y() - p1.y()) * tension_factor,
                }),
            };
        }

        /// Helper function to get a bit value from glyph bitmap data.
        /// Returns 1 if the bit is set, 0 otherwise.
        inline fn getGlyphBit(char_data: []const u8, row: usize, col: usize, bytes_per_row: usize) u1 {
            const byte_idx = col / 8;
            const bit_idx = col % 8;
            const row_byte_offset = row * bytes_per_row + byte_idx;
            if (row_byte_offset >= char_data.len) return 0;
            return @intCast((char_data[row_byte_offset] >> @intCast(bit_idx)) & 1);
        }

        /// Helper function to calculate bytes per row for a glyph.
        /// Handles both fixed-width and variable-width fonts.
        inline fn calculateGlyphBytesPerRow(glyph_info: anytype, font: anytype) usize {
            // Variable-width fonts use glyph-specific width, fixed-width fonts use font-wide stride
            return if (font.glyph_map != null)
                (@as(usize, glyph_info.width) + 7) / 8
            else
                font.bytesPerRow();
        }

        /// Draws text at the specified position using a bitmap font.
        /// The position specifies the top-left corner of the text.
        /// Supports newlines for multi-line text.
        pub fn drawText(self: Self, text: []const u8, position: Point(2, f32), color: anytype, font: BitmapFont, scale: f32, mode: DrawMode) void {
            comptime assert(isColor(@TypeOf(color)));
            if (scale <= 0) return;

            // Compute text bounding box and early exit if outside image
            const text_bounds = font.getTextBounds(text, scale);
            const text_rect = Rectangle(f32){
                .l = position.x() + text_bounds.l,
                .t = position.y() + text_bounds.t,
                .r = position.x() + text_bounds.r,
                .b = position.y() + text_bounds.b,
            };
            const image_rect: Rectangle(f32) = .{
                .l = 0,
                .t = 0,
                .r = @floatFromInt(self.cols()),
                .b = @floatFromInt(self.rows()),
            };
            const clip_rect = text_rect.intersect(image_rect) orelse return;

            var x = position.x();
            var y = position.y();
            const start_x = x;

            // For scale 1.0, use simple pixel-by-pixel drawing
            if (scale == 1.0) {
                var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
                while (utf8_iter.nextCodepoint()) |codepoint| {
                    if (codepoint == '\n') {
                        x = start_x;
                        y += @floatFromInt(font.char_height);
                        continue;
                    }

                    if (font.getGlyphInfo(codepoint)) |glyph_info| {
                        if (font.getCharData(codepoint)) |char_data| {
                            const bitmap_bytes_per_row = calculateGlyphBytesPerRow(glyph_info, font);
                            const render_height = if (font.glyph_map == null) font.char_height else glyph_info.height;

                            // Draw the character bitmap
                            for (0..render_height) |row| {
                                for (0..glyph_info.width) |col| {
                                    if (getGlyphBit(char_data, row, col, bitmap_bytes_per_row) != 0) {
                                        const px = x + @as(f32, @floatFromInt(col)) + @as(f32, @floatFromInt(glyph_info.x_offset));
                                        const py = y + @as(f32, @floatFromInt(row)) + @as(f32, @floatFromInt(glyph_info.y_offset));
                                        self.setPixel(.point(.{ px, py }), color);
                                    }
                                }
                            }
                        }
                    }
                    // Use character-specific advance width if available
                    const advance = font.getCharAdvanceWidth(codepoint);
                    x += @floatFromInt(advance);
                }
                return;
            }

            // Scaled rendering
            const char_height_scaled = @as(f32, @floatFromInt(font.char_height)) * scale;
            const rgba_color = if (mode == .soft) convertColor(Rgba, color) else undefined;

            var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
            while (utf8_iter.nextCodepoint()) |codepoint| {
                if (codepoint == '\n') {
                    x = start_x;
                    y += char_height_scaled;
                    continue;
                }

                if (font.getGlyphInfo(codepoint)) |glyph_info| {
                    if (font.getCharData(codepoint)) |char_data| {
                        const glyph_bytes_per_row = calculateGlyphBytesPerRow(glyph_info, font);

                        switch (mode) {
                            .fast => {
                                // Fast mode: nearest-neighbor scaling
                                for (0..glyph_info.height) |row| {
                                    for (0..glyph_info.width) |col| {
                                        if (getGlyphBit(char_data, row, col, glyph_bytes_per_row) != 0) {
                                            // Draw a scaled pixel block
                                            const base_x = x + (@as(f32, @floatFromInt(col)) + @as(f32, @floatFromInt(glyph_info.x_offset))) * scale;
                                            const base_y = y + (@as(f32, @floatFromInt(row)) + @as(f32, @floatFromInt(glyph_info.y_offset))) * scale;

                                            // Calculate the integer bounds of the scaled pixel
                                            const x_start_f = @floor(base_x);
                                            const y_start_f = @floor(base_y);
                                            const x_end_f = @ceil(base_x + scale);
                                            const y_end_f = @ceil(base_y + scale);

                                            // Clip to the valid rectangle
                                            const x_start = @as(usize, @intFromFloat(@max(x_start_f, clip_rect.l)));
                                            const y_start = @as(usize, @intFromFloat(@max(y_start_f, clip_rect.t)));
                                            const x_end = @as(usize, @intFromFloat(@min(x_end_f, clip_rect.r)));
                                            const y_end = @as(usize, @intFromFloat(@min(y_end_f, clip_rect.b)));

                                            // Fill the pixel block
                                            if (x_start < x_end and y_start < y_end) {
                                                for (y_start..y_end) |py| {
                                                    for (x_start..x_end) |px| {
                                                        self.setPixel(.point(.{ @as(f32, @floatFromInt(px)), @as(f32, @floatFromInt(py)) }), color);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            .soft => {
                                // Soft mode: antialiased scaling with box filtering
                                const glyph_width_f = @as(f32, @floatFromInt(glyph_info.width));
                                const glyph_height_f = @as(f32, @floatFromInt(glyph_info.height));
                                const dest_width = @ceil(@as(f32, @floatFromInt(glyph_info.width)) * scale);
                                const dest_height = @ceil(@as(f32, @floatFromInt(glyph_info.height)) * scale);

                                var dy: f32 = 0;
                                while (dy < dest_height) : (dy += 1) {
                                    var dx: f32 = 0;
                                    while (dx < dest_width) : (dx += 1) {
                                        const dest_x = x + dx + @as(f32, @floatFromInt(glyph_info.x_offset)) * scale;
                                        const dest_y = y + dy + @as(f32, @floatFromInt(glyph_info.y_offset)) * scale;

                                        if (self.atOrNull(@intFromFloat(dest_y), @intFromFloat(dest_x))) |_| {
                                            // Calculate which part of the source we're sampling
                                            const src_x = dx / scale;
                                            const src_y = dy / scale;

                                            // Box filter: sample a box around the source position
                                            const sample_radius = 0.5 / scale;
                                            const x0 = src_x - sample_radius;
                                            const x1 = src_x + sample_radius;
                                            const y0 = src_y - sample_radius;
                                            const y1 = src_y + sample_radius;

                                            var total_coverage: f32 = 0;

                                            // Sample the font bitmap
                                            const row_start_f = @max(0, @floor(y0));
                                            const row_end_f = @min(glyph_height_f - 1, @ceil(y1));
                                            const col_start_f = @max(0, @floor(x0));
                                            const col_end_f = @min(glyph_width_f - 1, @ceil(x1));

                                            var row_f = row_start_f;
                                            while (row_f <= row_end_f) : (row_f += 1) {
                                                var col_f = col_start_f;
                                                while (col_f <= col_end_f) : (col_f += 1) {
                                                    const row_idx = @as(usize, @intFromFloat(row_f));
                                                    const col_idx = @as(usize, @intFromFloat(col_f));

                                                    if (getGlyphBit(char_data, row_idx, col_idx, glyph_bytes_per_row) != 0) {
                                                        // Calculate how much this pixel contributes
                                                        const px0 = col_f;
                                                        const px1 = col_f + 1;
                                                        const py0 = row_f;
                                                        const py1 = row_f + 1;

                                                        const overlap_x = @max(0, @min(x1, px1) - @max(x0, px0));
                                                        const overlap_y = @max(0, @min(y1, py1) - @max(y0, py0));
                                                        total_coverage += overlap_x * overlap_y;
                                                    }
                                                }
                                            }

                                            // Normalize coverage by the box area
                                            const box_area = (x1 - x0) * (y1 - y0);
                                            const normalized_coverage = total_coverage / box_area;

                                            if (normalized_coverage > 0) {
                                                self.setPixel(.point(.{ dest_x, dest_y }), rgba_color.fade(normalized_coverage));
                                            }
                                        }
                                    }
                                }
                            },
                        }
                    }
                }
                // Use character-specific advance width if available
                const advance = font.getCharAdvanceWidth(codepoint);
                x += @as(f32, @floatFromInt(advance)) * scale;
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
    .{ .name = "circle_filled_solid", .md5sum = "3b3866e705fded47367902dedb825e4e", .draw_fn = drawCircleFilledSolid },
    .{ .name = "circle_filled_smooth", .md5sum = "4996924718641236276cdb1c166ae515", .draw_fn = drawCircleFilledSmooth },
    .{ .name = "circle_outline", .md5sum = "ae7e973d5644ff7bdde7338296e4ab40", .draw_fn = drawCircleOutline },
    .{ .name = "rectangle_filled", .md5sum = "1112ffbda92473effbd4d44c9722f563", .draw_fn = drawRectangleFilled },
    .{ .name = "rectangle_outline", .md5sum = "d5ee7fe598a82d16e33068d5bb6c6696", .draw_fn = drawRectangleOutline },
    .{ .name = "triangle_filled", .md5sum = "283a9de3dd51dd00794559cc231ff5ac", .draw_fn = drawTriangleFilled },
    .{ .name = "bezier_cubic", .md5sum = "fe95149bead3b0a028057c8c7fb969af", .draw_fn = drawBezierCubic },
    .{ .name = "bezier_quadratic", .md5sum = "c3286e308aaaef5b302129cf67b713c6", .draw_fn = drawBezierQuadratic },
    .{ .name = "polygon_complex", .md5sum = "da9b83426d2118ce99948eabebff91fb", .draw_fn = drawPolygonComplex },
    .{ .name = "spline_polygon", .md5sum = "6bae24f211c7fdd391cb5159dd4e8fd0", .draw_fn = drawSplinePolygon },
};

// Test drawing functions for MD5 checksums
fn drawLineHorizontal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 };
    canvas.drawLine(.point(.{ 10, 50 }), .point(.{ 90, 50 }), color, 1, .fast);
}

fn drawLineVertical(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 };
    canvas.drawLine(.point(.{ 50, 10 }), .point(.{ 50, 90 }), color, 1, .fast);
}

fn drawLineDiagonal(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 };
    canvas.drawLine(.point(.{ 10, 10 }), .point(.{ 90, 90 }), color, 1, .fast);
}

fn drawLineThick(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 0, .a = 255 };
    canvas.drawLine(.point(.{ 20, 20 }), .point(.{ 80, 80 }), color, 5, .soft);
}

fn drawCircleFilledSolid(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 0, .b = 128, .a = 255 };
    canvas.fillCircle(.point(.{ 50, 50 }), 30, color, .fast);
}

fn drawCircleFilledSmooth(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 0, .g = 128, .b = 128, .a = 255 };
    canvas.fillCircle(.point(.{ 50, 50 }), 25, color, .soft);
}

fn drawCircleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 255, .b = 0, .a = 255 };
    canvas.drawCircle(.point(.{ 50, 50 }), 35, color, 3, .soft);
}

fn drawRectangleFilled(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 64, .g = 128, .b = 192, .a = 255 };
    const rect = Rectangle(f32){ .l = 20, .t = 30, .r = 80, .b = 70 };
    canvas.fillRectangle(rect, color, .fast);
}

fn drawRectangleOutline(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 64, .b = 128, .a = 255 };
    const rect = Rectangle(f32){ .l = 15, .t = 25, .r = 85, .b = 75 };
    canvas.drawRectangle(rect, color, 2, .soft);
}

fn drawTriangleFilled(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 192, .b = 128, .a = 255 };
    const triangle = [_]Point(2, f32){
        .point(.{ 50, 20 }),
        .point(.{ 80, 80 }),
        .point(.{ 20, 80 }),
    };
    canvas.fillPolygon(&triangle, color, .soft) catch unreachable;
}

fn drawBezierCubic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 192, .b = 255, .a = 255 };
    canvas.drawCubicBezier(
        .point(.{ 10, 50 }),
        .point(.{ 30, 10 }),
        .point(.{ 70, 90 }),
        .point(.{ 90, 50 }),
        color,
        2,
        .fast,
    );
}

fn drawBezierQuadratic(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 255, .g = 128, .b = 192, .a = 255 };
    canvas.drawQuadraticBezier(
        .point(.{ 20, 80 }),
        .point(.{ 50, 20 }),
        .point(.{ 80, 80 }),
        color,
        3,
        .soft,
    );
}

fn drawPolygonComplex(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 128, .g = 255, .b = 128, .a = 255 };
    const polygon = [_]Point(2, f32){
        .point(.{ 50, 10 }),
        .point(.{ 70, 30 }),
        .point(.{ 90, 40 }),
        .point(.{ 70, 60 }),
        .point(.{ 50, 90 }),
        .point(.{ 30, 60 }),
        .point(.{ 10, 40 }),
        .point(.{ 30, 30 }),
    };
    canvas.fillPolygon(&polygon, color, .soft) catch unreachable;
}

fn drawSplinePolygon(canvas: Canvas(Rgba)) void {
    const color = Rgba{ .r = 192, .g = 128, .b = 255, .a = 255 };
    const polygon = [_]Point(2, f32){
        .point(.{ 50, 20 }),
        .point(.{ 80, 35 }),
        .point(.{ 80, 65 }),
        .point(.{ 50, 80 }),
        .point(.{ 20, 65 }),
        .point(.{ 20, 35 }),
    };
    canvas.drawSplinePolygon(&polygon, color, 2, 0.5, .soft);
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

        const canvas = Canvas(Rgba).init(allocator, img);
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

    const canvas = Canvas(Rgba).init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test various line directions
    const test_cases = [_]struct { p1: Point(2, f32), p2: Point(2, f32) }{
        .{ .p1 = .point(.{ 10, 10 }), .p2 = .point(.{ 90, 10 }) }, // horizontal
        .{ .p1 = .point(.{ 10, 10 }), .p2 = .point(.{ 10, 90 }) }, // vertical
        .{ .p1 = .point(.{ 10, 10 }), .p2 = .point(.{ 90, 90 }) }, // diagonal
        .{ .p1 = .point(.{ 90, 10 }), .p2 = .point(.{ 10, 90 }) }, // reverse diagonal
    };

    for (test_cases) |tc| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.drawLine(tc.p1, tc.p2, color, 1, .fast);

        // Check that endpoints are set (or very close)
        // At least one pixel near each endpoint should be black
        var p1_found = false;
        var p2_found = false;

        // Check 3x3 area around endpoints
        for (0..3) |dy| {
            for (0..3) |dx| {
                const y1 = @as(i32, @intFromFloat(tc.p1.y())) + @as(i32, @intCast(dy)) - 1;
                const x1 = @as(i32, @intFromFloat(tc.p1.x())) + @as(i32, @intCast(dx)) - 1;
                const y2 = @as(i32, @intFromFloat(tc.p2.y())) + @as(i32, @intCast(dy)) - 1;
                const x2 = @as(i32, @intFromFloat(tc.p2.x())) + @as(i32, @intCast(dx)) - 1;

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

    const canvas = Canvas(Rgba).init(allocator, img);
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
        canvas.drawLine(.point(.{ 50, y }), .point(.{ 150, y }), color, line_width, .fast);

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

    const canvas = Canvas(Rgba).init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const test_radii = [_]f32{ 5, 10, 20, 30, 40 };
    const center: Point(2, f32) = .point(.{ 100, 100 });

    for (test_radii) |radius| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.fillCircle(center, radius, color, .fast);

        // Check pixels at various distances from center
        var inside_count: usize = 0;
        var outside_count: usize = 0;
        var edge_count: usize = 0;

        for (0..height) |y| {
            for (0..width) |x| {
                const dx = @as(f32, @floatFromInt(x)) - center.x();
                const dy = @as(f32, @floatFromInt(y)) - center.y();
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

    const canvas = Canvas(Rgba).init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const center: Point(2, f32) = .point(.{ 100, 100 });
    const radius: f32 = 40;
    const line_widths = [_]usize{ 1, 3, 5, 10 };

    for (line_widths) |line_width| {
        // Clear image
        for (img.data) |*pixel| {
            pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        }

        canvas.drawCircle(center, radius, color, line_width, .fast);

        // Sample along several radii to check thickness
        const angles = [_]f32{ 0, std.math.pi / @as(f32, 4), std.math.pi / @as(f32, 2), 3 * std.math.pi / @as(f32, 4) };

        for (angles) |angle| {
            var black_pixels: usize = 0;

            // Count black pixels along this radius
            var r: f32 = 0;
            while (r < radius * 2) : (r += 0.5) {
                const x = center.x() + r * @cos(angle);
                const y = center.y() + r * @sin(angle);

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

    const canvas = Canvas(Rgba).init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    const rect = Rectangle(f32){ .l = 50, .t = 50, .r = 150, .b = 130 };
    const rect_width = rect.r - rect.l;
    const rect_height = rect.b - rect.t;
    const expected_area = rect_width * rect_height;

    // Clear and draw filled rectangle using polygon fill
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    const corners = [_]Point(2, f32){
        .point(.{ rect.l, rect.t }),
        .point(.{ rect.r, rect.t }),
        .point(.{ rect.r, rect.b }),
        .point(.{ rect.l, rect.b }),
    };
    try canvas.fillPolygon(&corners, color, .fast);

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

    const canvas = Canvas(Rgba).init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Test convex polygon (triangle)
    const triangle = [_]Point(2, f32){
        .point(.{ 100, 30 }),
        .point(.{ 170, 150 }),
        .point(.{ 30, 150 }),
    };

    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    try canvas.fillPolygon(&triangle, color, .fast);

    // Check that points inside triangle are filled
    const test_points = [_]struct { p: Point(2, f32), inside: bool }{
        .{ .p = .point(.{ 100, 100 }), .inside = true }, // centroid
        .{ .p = .point(.{ 100, 50 }), .inside = true }, // near top
        .{ .p = .point(.{ 50, 140 }), .inside = true }, // near bottom left
        .{ .p = .point(.{ 150, 140 }), .inside = true }, // near bottom right
        .{ .p = .point(.{ 20, 20 }), .inside = false }, // outside
        .{ .p = .point(.{ 180, 180 }), .inside = false }, // outside
    };

    for (test_points) |tp| {
        const x = @as(usize, @intFromFloat(tp.p.x()));
        const y = @as(usize, @intFromFloat(tp.p.y()));
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

    const canvas_solid = Canvas(Rgba).init(allocator, img_solid);
    const canvas_smooth = Canvas(Rgba).init(allocator, img_smooth);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Clear both images
    for (img_solid.data, img_smooth.data) |*p1, *p2| {
        p1.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
        p2.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    // Draw same circle with different modes
    const center: Point(2, f32) = .point(.{ 50, 50 });
    const radius: f32 = 20;

    canvas_solid.fillCircle(center, radius, color, .fast);
    canvas_smooth.fillCircle(center, radius, color, .soft);

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

    const canvas = Canvas(Rgba).init(allocator, img);
    const color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Clear image
    for (img.data) |*pixel| {
        pixel.* = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }

    // Draw cubic bezier
    const p0: Point(2, f32) = .point(.{ 20, 100 });
    const p1: Point(2, f32) = .point(.{ 60, 20 });
    const p2: Point(2, f32) = .point(.{ 140, 180 });
    const p3: Point(2, f32) = .point(.{ 180, 100 });

    canvas.drawCubicBezier(p0, p1, p2, p3, color, 2, .fast);

    // Verify endpoints are connected
    var p0_found = false;
    var p3_found = false;

    // Check 3x3 area around endpoints
    for (0..3) |dy| {
        for (0..3) |dx| {
            const y0 = @as(i32, @intFromFloat(p0.y())) + @as(i32, @intCast(dy)) - 1;
            const x0 = @as(i32, @intFromFloat(p0.x())) + @as(i32, @intCast(dx)) - 1;
            const y3 = @as(i32, @intFromFloat(p3.y())) + @as(i32, @intCast(dy)) - 1;
            const x3 = @as(i32, @intFromFloat(p3.x())) + @as(i32, @intCast(dx)) - 1;

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

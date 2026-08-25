//! This module provides a Canvas for drawing various shapes and lines on images.

const std = @import("std");
const assert = std.debug.assert;
const clamp = std.math.clamp;

const convertColor = @import("../color.zig").convertColor;
const isColor = @import("../color.zig").isColor;
const Rgba = @import("../color.zig").Rgba(u8);
const Blending = @import("../color.zig").Blending;
const BitmapFont = @import("../font.zig").BitmapFont;
const Font = @import("../font.zig").Font;
const VectorFont = @import("../font.zig").VectorFont;
const Outline = @import("../font.zig").Outline;
const TextLayout = @import("../font.zig").TextLayout;
const text_layout = @import("../font.zig").layout;
const Rectangle = @import("../geometry.zig").Rectangle;
const Point = @import("../geometry/Point.zig").Point;
const Image = @import("../image.zig").Image;
const assignPixel = @import("../image.zig").assignPixel;
const as = @import("../meta.zig").as;

/// Rendering quality mode for drawing operations
pub const DrawMode = enum {
    /// Fast rendering - hard edges, maximum performance
    fast,
    /// Soft rendering - antialiased edges, better quality
    soft,
};

/// Rendering style shared by all primitives: `mode` controls antialiasing only;
/// `blending` controls compositing and applies in both modes. The presets mirror
/// the classic `DrawMode` behavior: `.soft` composites, `.fast` overwrites.
pub const DrawOptions = struct {
    mode: DrawMode,
    blending: Blending,

    pub const soft: DrawOptions = .{ .mode = .soft, .blending = .normal };
    pub const fast: DrawOptions = .{ .mode = .fast, .blending = .none };
};

/// How the contours passed to `fillPolygons` combine.
pub const FillRule = enum {
    /// Inside where a ray from the point crosses an odd number of edges.
    even_odd,
    /// Inside where the contours wind around the point a nonzero net number of times;
    /// the rule glyph outlines are designed for.
    nonzero,
};

/// Coverage sink for `Canvas(u8)` masks: keeps the larger of the existing value and the
/// new coverage, so shapes accumulated over several calls never lighten each other.
const CoverageMax = struct {
    inline fn cover(_: CoverageMax, dest: *u8, alpha: f32) void {
        const coverage: u8 = @round(@min(alpha, 1) * 255);
        dest.* = @max(dest.*, coverage);
    }
};

/// How text glyphs are painted.
const GlyphStyle = union(enum) {
    fill,
    /// Stroke width in pixels.
    outline: f32,

    /// How far past the ink the paint reaches.
    fn reach(style: GlyphStyle) f32 {
        return switch (style) {
            .fill => 0,
            .outline => |width| width / 2,
        };
    }
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
        /// Offset for antialiasing edge calculations (0.5 = pixel center alignment). Soft paths
        /// treat pixel (r, c) as centered at (c, r); fast span writes are top-left inclusive.
        const antialias_edge_offset = 0.5;
        /// Vertical samples per pixel row for antialiased polygon fills
        const polygon_subscanlines = 8;
        /// Stack scratch (bytes) for polygon fills: edges and crossings for 256 vertices plus a
        /// 1024-pixel coverage row; larger inputs spill to the heap.
        const polygon_scratch_size = 256 * (@sizeOf(Edge) + @sizeOf(Crossing)) + 1024 * @sizeOf(CoverageCell);
        /// Stack scratch (bytes) for flattening a glyph outline; spills to heap beyond
        const glyph_scratch_size = 1024 * @sizeOf(Point(2, f32)) + 64 * @sizeOf([]const Point(2, f32));
        /// Stack scratch (points) for spline polygon tessellation; spills to heap beyond
        const spline_polygon_stack_buffer_size = 400;

        /// Creates a drawing canvas from an image.
        pub fn init(allocator: std.mem.Allocator, image: Image(T)) Self {
            return .{ .image = image, .allocator = allocator };
        }

        /// Clamps a floating-point coordinate to image bounds and converts to a u32 pixel index.
        inline fn clampToImageBounds(coord: f32, max_size: u32) u32 {
            return @trunc(clamp(coord, 0, as(f32, max_size)));
        }

        /// Clamps a rectangle to image bounds and returns integer pixel coordinates.
        /// Returns null if the rectangle is completely outside the image.
        inline fn clampRectToImage(self: Self, rect: Rectangle(f32)) ?Rectangle(u32) {
            const left = clampToImageBounds(rect.l, self.image.cols);
            const top = clampToImageBounds(rect.t, self.image.rows);
            const right = clampToImageBounds(rect.r, self.image.cols);
            const bottom = clampToImageBounds(rect.b, self.image.rows);

            if (left >= right or top >= bottom) {
                return null;
            }

            return .{ .l = left, .t = top, .r = right, .b = bottom };
        }

        /// Fills the entire canvas with a solid color.
        pub fn fill(self: Self, color: anytype) void {
            self.image.fill(convertColor(T, color));
        }

        /// Gets a reference to the pixel at the given coordinates.
        /// Panics if coordinates are out of bounds.
        pub inline fn at(self: Self, row: u32, col: u32) *T {
            return self.image.at(row, col);
        }

        /// Gets a reference to the pixel at the given coordinates, or null if out of bounds.
        pub inline fn atOrNull(self: Self, row: i32, col: i32) ?*T {
            return self.image.atOrNull(row, col);
        }

        /// Returns the number of rows (height) in the canvas.
        pub inline fn rows(self: Self) u32 {
            return self.image.rows;
        }

        /// Returns the number of columns (width) in the canvas.
        pub inline fn cols(self: Self) u32 {
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
        pub fn view(self: Self, rect: Rectangle(u32)) Self {
            return .{
                .image = self.image.view(rect),
                .allocator = self.allocator,
            };
        }

        /// Clamps a horizontal span to the image and returns its pixel slice, or null when
        /// fully outside.
        fn spanSlice(self: Self, x1: f32, x2: f32, y: f32) ?[]T {
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);

            if (y < 0 or y >= frows) return null;
            if (x2 < 0 or x1 >= fcols) return null;

            const row: u32 = @trunc(y);
            const start: u32 = @trunc(@max(0, @floor(x1)));
            const end: u32 = @trunc(@min(fcols - 1, @ceil(x2)));

            if (start > end) return null;

            const offset = row * self.image.stride + start;
            return self.image.data[offset .. offset + end - start + 1];
        }

        /// Writes a horizontal span: memset for plain overwrites, per-pixel composite otherwise.
        fn fillSpan(self: Self, x1: f32, x2: f32, y: f32, paint: Paint) void {
            const span = self.spanSlice(x1, x2, y) orelse return;
            if (paint.overwrite) @memset(span, paint.solid) else for (span) |*px| paint.put(px);
        }

        /// A color prepared for writing: pre-converted to the canvas type and to Rgba, with the
        /// overwrite decision hoisted out of pixel loops.
        const Paint = struct {
            solid: T,
            rgba: Rgba,
            blending: Blending,
            overwrite: bool,

            fn init(color: anytype, blending: Blending) Paint {
                comptime assert(isColor(@TypeOf(color)));
                const rgba = convertColor(Rgba, color);
                return .{
                    .solid = convertColor(T, color),
                    .rgba = rgba,
                    .blending = blending,
                    .overwrite = isOverwrite(blending, rgba),
                };
            }

            /// Writes the color at full coverage.
            inline fn put(p: Paint, dest: *T) void {
                if (p.overwrite) dest.* = p.solid else assignPixel(dest, p.rgba, p.blending);
            }

            /// Writes the color scaled by `alpha` coverage; full coverage takes the overwrite path.
            inline fn cover(p: Paint, dest: *T, alpha: f32) void {
                if (alpha >= 1) p.put(dest) else if (alpha > 0) assignPixel(dest, p.rgba.fade(alpha), p.blending);
            }
        };

        /// Draws a line between two points. `.fast` uses Bresenham (width 1) or a
        /// rectangle+caps; `.soft` antialiases via Wu (width 1) or distance-based rendering.
        pub fn drawLine(self: Self, p1: Point(2, f32), p2: Point(2, f32), color: anytype, width: u32, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            switch (opts.mode) {
                .fast => if (width == 1)
                    self.drawLineBresenham(p1, p2, color, opts.blending)
                else
                    self.drawLineRectangle(p1, p2, width, color, opts),
                .soft => if (width == 1)
                    self.drawLineXiaolinWu(p1, p2, color, opts.blending)
                else
                    self.drawLineDistance(p1, p2, width, color, opts),
            }
        }

        /// Bresenham's line algorithm for 1-pixel width lines.
        /// Classic rasterization algorithm using integer arithmetic for maximum speed.
        /// Produces pixel-perfect lines with hard edges and no antialiasing.
        /// Optimal for grid-aligned graphics and when performance is critical.
        fn drawLineBresenham(self: Self, p1: Point(2, f32), p2: Point(2, f32), color: anytype, blending: Blending) void {
            var x1: i32 = @trunc(p1.x());
            var y1: i32 = @trunc(p1.y());
            const x2: i32 = @trunc(p2.x());
            const y2: i32 = @trunc(p2.y());

            const paint: Paint = .init(color, blending);

            // Special case for horizontal lines - use fillSpan for better performance
            if (y1 == y2) {
                const min_x = @min(x1, x2);
                const max_x = @max(x1, x2);
                self.fillSpan(@floatFromInt(min_x), @floatFromInt(max_x), @floatFromInt(y1), paint);
                return;
            }

            // Special case for vertical lines - direct pixel access
            if (x1 == x2) {
                const min_y = @min(y1, y2);
                const max_y = @max(y1, y2);
                var y = min_y;
                while (y <= max_y) : (y += 1) {
                    if (self.atOrNull(y, x1)) |pixel| paint.put(pixel);
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
                if (self.atOrNull(y1, x1)) |pixel| paint.put(pixel);

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
        fn drawLineXiaolinWu(self: Self, p1: Point(2, f32), p2: Point(2, f32), color: anytype, blending: Blending) void {
            const paint: Paint = .init(color, blending);
            const c2 = paint.rgba;

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
                    self.setPoint(.init(.{ left_x, y }), c2.fade(alpha), blending);
                }

                // Middle solid part - use fillSpan for performance
                const solid_start = @ceil(min_x);
                const solid_end = @floor(max_x);
                if (solid_end >= solid_start) {
                    self.fillSpan(solid_start, solid_end, y, paint);
                }

                // Right endpoint antialiasing
                if (max_x < right_x) {
                    const alpha = right_x - max_x;
                    self.setPoint(.init(.{ right_x, y }), c2.fade(alpha), blending);
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

            var x_px1: f32 = undefined;
            var x_px2: f32 = undefined;
            var intery: f32 = undefined;
            inline for ([_]struct { x: f32, y: f32, is_start: bool }{
                .{ .x = x1, .y = y1, .is_start = true },
                .{ .x = x2, .y = y2, .is_start = false },
            }, 0..) |ep, idx| {
                const x_end = @round(ep.x);
                const y_end = ep.y + gradient * (x_end - ep.x);
                const x_gap = if (ep.is_start) rfpart(ep.x + 0.5) else fpart(ep.x + 0.5);
                const x_px = x_end;
                const y_px = @floor(y_end);

                if (steep) {
                    self.setPoint(.init(.{ y_px, x_px }), c2.fade(rfpart(y_end) * x_gap), blending);
                    self.setPoint(.init(.{ y_px + 1, x_px }), c2.fade(fpart(y_end) * x_gap), blending);
                } else {
                    self.setPoint(.init(.{ x_px, y_px }), c2.fade(rfpart(y_end) * x_gap), blending);
                    self.setPoint(.init(.{ x_px, y_px + 1 }), c2.fade(fpart(y_end) * x_gap), blending);
                }

                if (idx == 0) {
                    x_px1 = x_px;
                    intery = y_end + gradient;
                } else {
                    x_px2 = x_px;
                }
            }

            // Main loop
            var x = x_px1 + 1;
            while (x < x_px2) : (x += 1) {
                if (steep) {
                    self.setPoint(.init(.{ intery, x }), c2.fade(rfpart(intery)), blending);
                    self.setPoint(.init(.{ @floor(intery) + 1, x }), c2.fade(fpart(intery)), blending);
                } else {
                    self.setPoint(.init(.{ x, intery }), c2.fade(rfpart(intery)), blending);
                    self.setPoint(.init(.{ x, @floor(intery) + 1 }), c2.fade(fpart(intery)), blending);
                }
                intery += gradient;
            }
        }

        /// Rectangle-based thick line rendering for fast (non-antialiased) mode.
        /// Constructs a filled rectangle perpendicular to the line direction,
        /// then adds circular end caps for smooth line termination.
        /// Handles zero-length lines by drawing a single filled circle.
        fn drawLineRectangle(self: Self, p1: Point(2, f32), p2: Point(2, f32), width: u32, color: anytype, opts: DrawOptions) void {
            // For thick lines, draw as a filled rectangle
            const dx = p2.x() - p1.x();
            const dy = p2.y() - p1.y();
            const line_length = @sqrt(dx * dx + dy * dy);

            if (line_length == 0) {
                // Single point - draw a filled circle
                const half_width: f32 = as(f32, width) / 2.0;
                self.fillCircle(p1, half_width, color, opts);
                return;
            }

            // Calculate perpendicular vector for thick line
            const half_width: f32 = as(f32, width) / 2.0;
            const perp_x = -dy / line_length * half_width;
            const perp_y = dx / line_length * half_width;

            // Create rectangle corners
            const corners = [_]Point(2, f32){
                .init(.{ p1.x() - perp_x, p1.y() - perp_y }),
                .init(.{ p1.x() + perp_x, p1.y() + perp_y }),
                .init(.{ p2.x() + perp_x, p2.y() + perp_y }),
                .init(.{ p2.x() - perp_x, p2.y() - perp_y }),
            };

            // Fill rectangle using scanline algorithm (no anti-aliasing)
            self.fillPolygon(&corners, color, opts) catch return;

            // Add rounded caps using solid circles
            self.fillCircle(p1, half_width, color, opts);
            self.fillCircle(p2, half_width, color, opts);
        }

        /// Distance-based antialiased rendering for thick lines.
        /// Calculates the perpendicular distance from each pixel to the line segment and
        /// applies smooth alpha falloff at edges. End caps fall out naturally from the
        /// distance test.
        fn drawLineDistance(self: Self, p1: Point(2, f32), p2: Point(2, f32), width: u32, color: anytype, opts: DrawOptions) void {
            const half_width: f32 = as(f32, width) / 2.0;

            const dx = p2.x() - p1.x();
            const dy = p2.y() - p1.y();
            const length_sq = dx * dx + dy * dy;
            if (length_sq == 0) {
                self.fillCircle(p1, half_width, color, opts);
                return;
            }

            // Axis-aligned fast path: per-row (horizontal) or per-col (vertical) alpha is
            // uniform, so we can skip the per-pixel sqrt and use `fillSpan` (memset)
            // for fully-covered interior rows of horizontal lines. End-cap AA still comes from
            // `fillCircle`. Body bbox is tight to the line endpoints so caps don't double-blend.
            if (dx == 0 or dy == 0) {
                self.drawAxisAlignedThickLine(p1, p2, half_width, color, opts);
                return;
            }

            const paint: Paint = .init(color, opts.blending);

            const inv_length_sq = 1.0 / length_sq;
            const line_rect: Rectangle(f32) = .{
                .l = @min(p1.x(), p2.x()) - half_width,
                .t = @min(p1.y(), p2.y()) - half_width,
                .r = @max(p1.x(), p2.x()) + half_width + 1,
                .b = @max(p1.y(), p2.y()) + half_width + 1,
            };
            const bbox = self.clampRectToImage(line_rect) orelse return;

            for (bbox.t..bbox.b) |r| {
                const py = as(f32, r);
                for (bbox.l..bbox.r) |c| {
                    const px = as(f32, c);
                    const dpx = px - p1.x();
                    const dpy = py - p1.y();
                    const t = clamp((dpx * dx + dpy * dy) * inv_length_sq, 0, 1);
                    const dist_x = dpx - t * dx;
                    const dist_y = dpy - t * dy;
                    const dist = @sqrt(dist_x * dist_x + dist_y * dist_y);
                    if (dist > half_width + antialias_edge_offset) continue;
                    var alpha: f32 = 1.0;
                    if (dist > half_width - antialias_edge_offset) {
                        alpha = half_width + antialias_edge_offset - dist;
                    }
                    paint.cover(&self.image.data[r * self.image.stride + c], alpha);
                }
            }
        }

        /// Specialized renderer for horizontal/vertical thick lines. Computes the perpendicular
        /// coverage once per row (or column) — uniform across the body — and uses
        /// `fillSpan` for fully-covered interior rows of horizontal lines.
        /// End-cap AA is handled by the `fillCircle` calls at the bottom.
        fn drawAxisAlignedThickLine(self: Self, p1: Point(2, f32), p2: Point(2, f32), half_width: f32, color: anytype, opts: DrawOptions) void {
            const is_horizontal = p1.y() == p2.y();
            const paint: Paint = .init(color, opts.blending);

            // Body bbox is tight to the line's endpoints — end caps are drawn separately,
            // so excluding their region here avoids double-blend over-saturation.
            const body_rect: Rectangle(f32) = if (is_horizontal) .{
                .l = @min(p1.x(), p2.x()),
                .t = p1.y() - half_width,
                .r = @max(p1.x(), p2.x()) + 1,
                .b = p1.y() + half_width + 1,
            } else .{
                .l = p1.x() - half_width,
                .t = @min(p1.y(), p2.y()),
                .r = p1.x() + half_width + 1,
                .b = @max(p1.y(), p2.y()) + 1,
            };

            if (self.clampRectToImage(body_rect)) |bbox| {
                const perp_center = if (is_horizontal) p1.y() else p1.x();
                if (is_horizontal) {
                    for (bbox.t..bbox.b) |r| {
                        const alpha = perpendicularAlpha(as(f32, r), perp_center, half_width);
                        if (alpha >= 1.0) {
                            self.fillSpan(as(f32, bbox.l), as(f32, bbox.r - 1), as(f32, r), paint);
                        } else {
                            for (bbox.l..bbox.r) |c| paint.cover(&self.image.data[r * self.image.stride + c], alpha);
                        }
                    }
                } else {
                    for (bbox.l..bbox.r) |c| {
                        const alpha = perpendicularAlpha(as(f32, c), perp_center, half_width);
                        for (bbox.t..bbox.b) |r| paint.cover(&self.image.data[r * self.image.stride + c], alpha);
                    }
                }
            }

            self.fillCircle(p1, half_width, color, opts);
            self.fillCircle(p2, half_width, color, opts);
        }

        /// Coverage of a single perpendicular sample at distance |sample - center| from a
        /// band's centerline (half-width `half_width`). Same edge ramp as `ringCoverage`.
        inline fn perpendicularAlpha(sample: f32, center: f32, half_width: f32) f32 {
            const dist = @abs(sample - center);
            if (dist > half_width + antialias_edge_offset) return 0;
            if (dist > half_width - antialias_edge_offset) return half_width + antialias_edge_offset - dist;
            return 1.0;
        }

        /// True when the write is a plain overwrite (`.normal` + opaque degenerates to the overlay).
        inline fn isOverwrite(blending: Blending, rgba: Rgba) bool {
            return switch (blending) {
                .none => true,
                .normal => rgba.a == 255,
                else => false,
            };
        }

        /// Writes a pixel at integer (row, col), compositing `color` with `blending`
        /// (via an Rgba round-trip on non-Rgba canvases). Out-of-bounds is silently ignored.
        pub inline fn setPixel(self: Self, row: u32, col: u32, color: anytype, blending: Blending) void {
            if (row >= self.image.rows or col >= self.image.cols) return;
            Paint.init(color, blending).put(&self.image.data[row * self.image.stride + col]);
        }

        /// Floors `point` to an integer pixel cell and writes via `setPixel`. Bridges
        /// float-coordinate drawing primitives to the integer pixel grid.
        pub fn setPoint(self: Self, point: Point(2, f32), color: anytype, blending: Blending) void {
            const row: i32 = @floor(point.y());
            const col: i32 = @floor(point.x());
            if (row < 0 or col < 0) return;
            self.setPixel(@intCast(row), @intCast(col), color, blending);
        }

        /// Draws another image onto this canvas at the given top-left position.
        /// Supports alpha blending for RGBA images with the normal blend mode.
        /// For rotation, scaling, or custom blend modes, users should access the canvas's image field directly.
        pub fn drawImage(self: Self, source: anytype, position: Point(2, f32), source_rect_opt: ?Rectangle(u32), blend_mode: Blending) void {
            const SourcePixelType = std.meta.Child(@TypeOf(source.data));

            if (source.rows == 0 or source.cols == 0) return;

            const SourceRect = Rectangle(u32);
            const full_rect = SourceRect.init(0, 0, source.cols, source.rows);
            const requested = source_rect_opt orelse full_rect;
            const src_rect = full_rect.intersect(requested) orelse return;

            if (src_rect.isEmpty()) return;

            const origin_x: i32 = @round(position.x());
            const origin_y: i32 = @round(position.y());

            // Simple blit loop with type-based blending
            for (src_rect.t..src_rect.b) |src_r| {
                const row_offset = src_r - src_rect.t;
                const dest_y = origin_y + @as(i32, @intCast(row_offset));

                for (src_rect.l..src_rect.r) |src_c| {
                    const col_offset = src_c - src_rect.l;
                    const dest_x = origin_x + @as(i32, @intCast(col_offset));

                    if (self.atOrNull(dest_y, dest_x)) |dest_pixel| {
                        const src_pixel = source.at(src_r, src_c).*;
                        const mode = if (comptime SourcePixelType == Rgba) blend_mode else .none;
                        assignPixel(dest_pixel, src_pixel, mode);
                    }
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
        /// Each edge is an independent `drawLine`; vertices get no joins.
        pub fn drawPolygon(self: Self, polygon: []const Point(2, f32), color: anytype, width: u32, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            // Draw all line segments
            for (0..polygon.len) |i| {
                self.drawLine(polygon[i], polygon[@mod(i + 1, polygon.len)], color, width, opts);
            }
        }

        /// Draws the outline of a rectangle on the given image.
        pub fn drawRectangle(self: Self, rect: Rectangle(f32), color: anytype, width: u32, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));
            // Rectangle has exclusive r,b bounds, but drawPolygon needs inclusive points
            // So we subtract 1 from r and b to get the actual corner positions
            const points: []const Point(2, f32) = &.{
                .init(.{ rect.l, rect.t }),
                .init(.{ rect.r - 1, rect.t }),
                .init(.{ rect.r - 1, rect.b - 1 }),
                .init(.{ rect.l, rect.b - 1 }),
            };
            self.drawPolygon(points, color, width, opts);
        }

        /// Fills a rectangle on the given image.
        /// The rectangle is defined using standard conventions where l,t are inclusive and r,b are exclusive.
        /// This means a rectangle from (0,0) to (10,10) will fill pixels at positions 0-9 in both dimensions.
        /// Fractional edges are truncated to whole pixels, so `opts.mode` has no effect here.
        pub fn fillRectangle(self: Self, rect: Rectangle(f32), color: anytype, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));

            const bounds = self.clampRectToImage(rect) orelse return;
            const paint: Paint = .init(color, opts.blending);

            for (bounds.t..bounds.b) |row| {
                self.fillSpan(as(f32, bounds.l), as(f32, bounds.r - 1), as(f32, row), paint);
            }
        }

        /// Draws the outline of a circle on the given image.
        /// Use DrawMode.soft for anti-aliased edges or DrawMode.fast for fast aliased edges.
        pub fn drawCircle(self: Self, center: Point(2, f32), radius: f32, color: anytype, width: u32, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0 or width == 0) return;

            if (opts.mode == .fast and width == 1) {
                return self.drawBresenhamCircle(center, radius, color, .full, opts.blending);
            }
            const line_width: f32 = @floatFromInt(width);
            self.renderRing(center, radius - line_width / 2.0, radius + line_width / 2.0, color, .full, opts);
        }

        /// Draws an arc outline. Angles are in radians from the positive X-axis, counter-clockwise,
        /// and may exceed 2π (auto-normalized). Arcs spanning ≥ 2π render as a full circle.
        ///
        /// Example:
        /// ```zig
        /// // Red quarter arc from 0 to π/2
        /// try canvas.drawArc(center, 50, 0, std.math.pi / 2.0, Rgb.red, 2, .soft);
        /// ```
        pub fn drawArc(self: Self, center: Point(2, f32), radius: f32, start_angle: f32, end_angle: f32, color: anytype, width: u32, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0 or width == 0) return;

            // Validate angles are finite numbers
            if (!std.math.isFinite(start_angle) or !std.math.isFinite(end_angle)) {
                return;
            }

            if (@abs(end_angle - start_angle) >= 2 * std.math.pi) {
                self.drawCircle(center, radius, color, width, opts);
                return;
            }

            // Partial arc
            const arc: ArcRange = .init(start_angle, end_angle);
            switch (opts.mode) {
                .fast => if (width == 1) {
                    self.drawBresenhamCircle(center, radius, color, arc, opts.blending);
                } else {
                    const line_width: f32 = @floatFromInt(width);
                    self.renderRing(center, radius - line_width / 2.0, radius + line_width / 2.0, color, arc, opts);
                },
                .soft => try self.drawArcSoft(center, radius, arc, width, color, opts),
            }
        }

        /// Angular range for arc filtering. `start`/`end` are
        /// normalized to [0, 2π] with `end` shifted by +2π when the arc wraps past 0,
        /// so that per-pixel `isAngleInArc` checks need no `@mod`.
        const ArcRange = struct {
            start: f32,
            end: f32,

            inline fn init(start: f32, end: f32) ArcRange {
                const ns = normalize(start);
                var ne = normalize(end);
                if (ne < ns) ne += 2 * std.math.pi;
                return .{
                    .start = ns,
                    .end = ne,
                };
            }

            const full: ArcRange = .{ .start = 0, .end = 2 * std.math.pi };

            /// Normalizes an angle to the [0, 2π] range. Use only when the input range is unknown;
            /// for atan2 outputs (already in [-π, π]) prefer the cheaper inline form in `contains`.
            fn normalize(angle: f32) f32 {
                var normalized = @mod(angle, 2 * std.math.pi);
                if (normalized < 0) normalized += 2 * std.math.pi;
                return normalized;
            }

            /// Tests whether an `atan2`-produced angle lies within the precomputed arc range.
            /// Caller must pass a value in [-π, π] (i.e., the output of `std.math.atan2`); other
            /// inputs require a prior `normalizeAngle` call.
            inline fn contains(self: ArcRange, angle: f32) bool {
                // atan2 ∈ [-π, π] — one conditional add suffices to reach [0, 2π].
                const norm_angle = if (angle < 0) angle + 2 * std.math.pi else angle;
                if (norm_angle >= self.start and norm_angle <= self.end) return true;
                const shifted = norm_angle + 2 * std.math.pi;
                return shifted >= self.start and shifted <= self.end;
            }

            /// Returns the absolute angular span of the arc.
            inline fn span(self: ArcRange) f32 {
                return self.end - self.start;
            }

            /// Returns the absolute geometric length of the arc along the specified radius.
            inline fn length(self: ArcRange, radius: f32) f32 {
                return self.span() * radius;
            }

            /// Returns true if the arc spans more than half a circle (π radians).
            inline fn isLong(self: ArcRange) bool {
                return self.span() > std.math.pi;
            }

            /// Returns true if the arc spans a full circle (≥ 2π radians).
            inline fn isFull(self: ArcRange) bool {
                return self.span() >= 2 * std.math.pi;
            }

            /// Returns the directional vector for the start of the arc.
            inline fn startVector(self: ArcRange) Point(2, f32) {
                return .init(.{ @cos(self.start), @sin(self.start) });
            }

            /// Returns the directional vector for the end of the arc.
            inline fn endVector(self: ArcRange) Point(2, f32) {
                return .init(.{ @cos(self.end), @sin(self.end) });
            }

            /// Half-plane test for "angle in arc" using precomputed cross-product components.
            inline fn containsCross(self: ArcRange, start_cross: f32, end_cross: f32) bool {
                const a = start_cross <= 0;
                const b = end_cross >= 0;
                return if (self.isLong()) (a or b) else (a and b);
            }
        };

        /// Screen-space bounding box of the outer circle (padded by one pixel for the AA ramp),
        /// clamped to image bounds. Returns null when the box has zero area.
        inline fn ringBoundingBox(self: Self, center: Point(2, f32), outer_radius: f32) ?Rectangle(u32) {
            const pad = outer_radius + 1;
            return self.clampRectToImage(.{
                .l = @floor(center.x() - pad),
                .t = @floor(center.y() - pad),
                .r = @ceil(center.x() + pad),
                .b = @ceil(center.y() + pad),
            });
        }

        /// Coverage in the annulus [inner_r, outer_r] for a pixel at offset (x,y) from the
        /// center. `aa=true` returns boundary-centered coverage in [0,1] (~0.5 at the
        /// geometric edge); `aa=false` returns 1.0 strictly inside the ring, 0.0 otherwise.
        /// `inner_r <= 0` disables the inner edge — pass 0 to fill a disk.
        inline fn ringCoverage(x: f32, y: f32, inner_r: f32, outer_r: f32, mode: DrawMode) f32 {
            const dist_sq = x * x + y * y;
            if (mode == .soft) {
                const dist = @sqrt(dist_sq);
                if (dist > outer_r + antialias_edge_offset) return 0;
                if (inner_r > 0 and dist < inner_r - antialias_edge_offset) return 0;
                var alpha: f32 = 1.0;
                if (dist > outer_r - antialias_edge_offset) alpha = @min(alpha, outer_r + antialias_edge_offset - dist);
                if (inner_r > 0 and dist < inner_r + antialias_edge_offset) alpha = @min(alpha, dist - (inner_r - antialias_edge_offset));
                return clamp(alpha, 0, 1);
            } else {
                const inside_outer = dist_sq <= outer_r * outer_r;
                const outside_inner = inner_r <= 0 or dist_sq >= inner_r * inner_r;
                return if (inside_outer and outside_inner) 1.0 else 0.0;
            }
        }

        /// Renders a thick ring outline (or arc segment) by scanning its bounding box;
        /// `.fast` uses binary coverage.
        inline fn renderRing(
            self: Self,
            center: Point(2, f32),
            inner_radius: f32,
            outer_radius: f32,
            color: anytype,
            arc: ArcRange,
            opts: DrawOptions,
        ) void {
            const bbox = self.ringBoundingBox(center, outer_radius) orelse return;
            const paint: Paint = .init(color, opts.blending);
            for (bbox.t..bbox.b) |r| {
                const y = as(f32, r) - center.y();
                for (bbox.l..bbox.r) |c| {
                    const x = as(f32, c) - center.x();
                    const coverage = ringCoverage(x, y, inner_radius, outer_radius, opts.mode);
                    if (coverage <= 0) continue;
                    if (!arc.isFull()) {
                        if (!arc.contains(std.math.atan2(y, x))) continue;
                    }
                    paint.cover(&self.image.data[r * self.image.stride + c], coverage);
                }
            }
        }

        /// Rasterizes a 1-pixel-thick Bresenham circle around `center`.
        /// Each of the 8 octant-symmetric pixels is gated by an angle check.
        inline fn drawBresenhamCircle(
            self: Self,
            center: Point(2, f32),
            radius: f32,
            color: anytype,
            arc: ArcRange,
            blending: Blending,
        ) void {
            const paint: Paint = .init(color, blending);
            const cx: i32 = @round(center.x());
            const cy: i32 = @round(center.y());
            const r = @round(radius);
            var x: f32 = r;
            var y: f32 = 0;
            var err: f32 = 0;
            const full = arc.isFull();
            while (x >= y) {
                const offsets = [_][2]f32{
                    .{ x, y }, .{ -x, y }, .{ x, -y }, .{ -x, -y },
                    .{ y, x }, .{ -y, x }, .{ y, -x }, .{ -y, -x },
                };
                for (offsets) |o| {
                    if (!full) {
                        if (!arc.contains(std.math.atan2(o[1], o[0]))) continue;
                    }
                    const col: i32 = @trunc(o[0]);
                    const row: i32 = @trunc(o[1]);
                    if (self.atOrNull(cy + row, cx + col)) |dest| paint.put(dest);
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

        /// Internal function for drawing smooth (anti-aliased) arc outlines.
        fn drawArcSoft(self: Self, center: Point(2, f32), radius: f32, arc: ArcRange, width: u32, color: anytype, opts: DrawOptions) !void {
            const angle_span = arc.span();
            const arc_length = arc.length(radius);
            const segments: u32 = @max(8, @min(bezier_max_segments_count, @as(u32, @ceil(arc_length / 5.0))));
            const angle_step = angle_span / as(f32, segments);
            const total_points = if (width > 1) (segments + 1) * 2 else segments + 1;

            var stack: [256 * @sizeOf(Point(2, f32))]u8 align(16) = undefined;
            var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, self.allocator);
            const scratch = buffer_first.allocator();
            const points = try scratch.alloc(Point(2, f32), total_points);
            defer scratch.free(points);

            if (width == 1) {
                fillArcRing(points[0 .. segments + 1], center, radius, arc.start, angle_step);
                for (0..segments) |i| {
                    self.drawLine(points[i], points[i + 1], color, 1, opts);
                }
            } else {
                const line_width: f32 = @floatFromInt(width);
                fillArcRing(points[0 .. segments + 1], center, radius + line_width / 2.0, arc.start, angle_step);
                fillArcRing(points[segments + 1 ..], center, radius - line_width / 2.0, arc.end, -angle_step);
                try self.fillPolygon(points, color, opts);
            }
        }

        /// Populates `buf` with points along a circular arc, starting at `start_angle` and
        /// stepping by `angle_step` for each successive index.
        fn fillArcRing(buf: []Point(2, f32), center: Point(2, f32), radius: f32, start_angle: f32, angle_step: f32) void {
            for (buf, 0..) |*p, i| {
                const angle = start_angle + as(f32, i) * angle_step;
                p.* = .init(.{
                    center.x() + radius * @cos(angle),
                    center.y() + radius * @sin(angle),
                });
            }
        }

        /// Fills the given polygon on an image using an even-odd scanline algorithm.
        /// The polygon is defined by an array of points (vertices).
        ///
        /// **Rendering Modes:**
        /// - **DrawMode.fast**: hard edges, one sample per row.
        /// - **DrawMode.soft**: antialiased edges in every direction — each row is sampled at
        ///   `polygon_subscanlines` heights with exact horizontal coverage.
        pub fn fillPolygon(self: Self, polygon: []const Point(2, f32), color: anytype, opts: DrawOptions) !void {
            return self.fillPolygons(&.{polygon}, color, .even_odd, opts);
        }

        /// Fills several closed contours as one shape under `fill_rule`. Glyph outlines need
        /// `.nonzero`: their holes are reverse-winding contours and their strokes may overlap.
        pub fn fillPolygons(self: Self, contours: []const []const Point(2, f32), color: anytype, fill_rule: FillRule, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            const paint: Paint = .init(color, opts.blending);
            switch (opts.mode) {
                inline else => |mode| return self.fillContours(contours, fill_rule, mode, paint),
            }
        }

        /// Accumulates antialiased coverage of `contours` into an 8-bit mask:
        /// `dest = max(dest, 255 * coverage)`. Pixels outside the shape are never written, so
        /// clear the mask first. Only for `Canvas(u8)`.
        pub fn rasterizePolygons(self: Self, contours: []const []const Point(2, f32), fill_rule: FillRule) !void {
            comptime assert(T == u8);
            return self.fillContours(contours, fill_rule, .soft, CoverageMax{});
        }

        /// Fills a glyph outline with the nonzero rule; `transform` maps font units to pixels.
        pub fn fillGlyph(self: Self, outline: Outline, transform: Outline.Transform, color: anytype, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            const paint: Paint = .init(color, opts.blending);
            switch (opts.mode) {
                inline else => |mode| return self.fillOutline(outline, transform, mode, paint),
            }
        }

        /// Antialiased coverage of a glyph outline into an 8-bit mask, as `rasterizePolygons`.
        pub fn rasterizeGlyph(self: Self, outline: Outline, transform: Outline.Transform) !void {
            comptime assert(T == u8);
            return self.fillOutline(outline, transform, .soft, CoverageMax{});
        }

        /// A glyph outline flattened into device-space polygons, in scratch memory.
        const FlatGlyph = struct {
            points: []Point(2, f32),
            contours: [][]const Point(2, f32),
            polys: [][]const Point(2, f32),

            fn init(scratch: std.mem.Allocator, outline: Outline, transform: Outline.Transform) !FlatGlyph {
                const points = try scratch.alloc(Point(2, f32), outline.flattenedPointCount(transform));
                errdefer scratch.free(points);
                const contours = try scratch.alloc([]const Point(2, f32), outline.contourCount());
                return .{ .points = points, .contours = contours, .polys = outline.flatten(transform, points, contours) };
            }

            fn deinit(self: FlatGlyph, scratch: std.mem.Allocator) void {
                scratch.free(self.contours);
                scratch.free(self.points);
            }
        };

        fn fillOutline(self: Self, outline: Outline, transform: Outline.Transform, comptime mode: DrawMode, sink: anytype) !void {
            var stack: [glyph_scratch_size]u8 align(16) = undefined;
            var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, self.allocator);
            const scratch = buffer_first.allocator();
            const flat = try FlatGlyph.init(scratch, outline, transform);
            defer flat.deinit(scratch);
            return self.fillContours(flat.polys, .nonzero, mode, sink);
        }

        /// Strokes closed polylines `width` pixels wide with round joins and caps: each becomes
        /// a union of one quad per segment plus a polygonal disc at every vertex whose turn
        /// would otherwise leave a visible gap, all wound the same way and filled in a single
        /// nonzero pass so the overlaps never double-blend.
        fn strokePolylines(self: Self, scratch: std.mem.Allocator, polys: []const []const Point(2, f32), width: f32, comptime mode: DrawMode, sink: anytype) !void {
            const radius = @max(width, 0.5) / 2;
            const sides: usize = @intFromFloat(@min(64, @max(8, @ceil(radius * 2))));
            // The quads' vertex order and the disc's descending angle wind the same way.
            var disc: [64]Point(2, f32) = undefined;
            fillArcRing(disc[0..sides], .init(.{ 0, 0 }), radius, 0, -2 * std.math.pi / as(f32, sides));

            var vertices: usize = 0;
            for (polys) |poly| vertices += poly.len;
            const piece_points = try scratch.alloc(Point(2, f32), vertices * (4 + sides));
            defer scratch.free(piece_points);
            const pieces = try scratch.alloc([]const Point(2, f32), vertices * 2);
            defer scratch.free(pieces);

            var n: usize = 0;
            var k: usize = 0;
            for (polys) |poly| {
                var incoming: ?Point(2, f32) = if (poly.len > 1) unitDirection(poly[poly.len - 1], poly[0]) else null;
                for (poly, 0..) |p, i| {
                    const outgoing = if (poly.len > 1) unitDirection(p, poly[(i + 1) % poly.len]) else null;
                    if (outgoing) |d| {
                        const q = poly[(i + 1) % poly.len];
                        const normal: Point(2, f32) = .init(.{ -d.y() * radius, d.x() * radius });
                        piece_points[n..][0..4].* = .{ p.add(normal), q.add(normal), q.sub(normal), p.sub(normal) };
                        pieces[k] = piece_points[n..][0..4];
                        n += 4;
                        k += 1;
                    }
                    // A join's gap is r·(1 − cos(θ/2)); below the flatness tolerance it is invisible.
                    const gap = if (incoming) |a| if (outgoing) |b| radius * (1 - @sqrt(@max(0, (1 + a.x() * b.x() + a.y() * b.y()) / 2))) else radius else radius;
                    if (gap >= Outline.flatness_tolerance) {
                        for (disc[0..sides], 0..) |offset, j| piece_points[n + j] = p.add(offset);
                        pieces[k] = piece_points[n..][0..sides];
                        n += sides;
                        k += 1;
                    }
                    if (outgoing) |d| incoming = d;
                }
            }
            return self.fillContours(pieces[0..k], .nonzero, mode, sink);
        }

        /// Unit vector from `p` to `q`, or null when they coincide.
        fn unitDirection(p: Point(2, f32), q: Point(2, f32)) ?Point(2, f32) {
            const d = q.sub(p);
            const len = d.norm();
            return if (len > 0) d.scale(1 / len) else null;
        }

        /// Scanline fill shared by every polygon entry point. `sink` is a `Paint` or, for
        /// `.soft` masks, a `CoverageMax`.
        fn fillContours(self: Self, contours: []const []const Point(2, f32), fill_rule: FillRule, comptime mode: DrawMode, sink: anytype) !void {
            var vertices: usize = 0;
            var bounds: ?Rectangle(f32) = null;
            for (contours) |polygon| {
                if (polygon.len < 3) continue;
                vertices += polygon.len;
                const box: Rectangle(f32) = .fromPoints(polygon);
                bounds = if (bounds) |acc| acc.merge(box) else box;
            }
            const shape_bounds = bounds orelse return;

            var stack: [polygon_scratch_size]u8 align(16) = undefined;
            var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, self.allocator);
            const scratch = buffer_first.allocator();
            const edges_buf = try scratch.alloc(Edge, vertices);
            defer scratch.free(edges_buf);
            const crossings_buf = try scratch.alloc(Crossing, vertices);
            defer scratch.free(crossings_buf);

            const edges = polygonEdges(contours, edges_buf);
            switch (mode) {
                .fast => {
                    comptime assert(@TypeOf(sink) == Paint);
                    const frows: f32 = @floatFromInt(self.image.rows);
                    var y = @max(0, @floor(shape_bounds.t));
                    const end_y = @min(frows - 1, @ceil(shape_bounds.b));
                    while (y <= end_y) : (y += 1) {
                        var spans: SpanIter = .{ .crossings = scanlineCrossings(edges, y, crossings_buf), .rule = fill_rule };
                        while (spans.next()) |span| self.fillSpan(span[0], span[1], y, sink);
                    }
                },
                .soft => try self.fillPolygonSoft(edges, shape_bounds, crossings_buf, fill_rule, sink, scratch),
            }
        }

        /// Polygon edge with its y-extent precomputed for scanline crossing tests.
        const Edge = struct {
            p1: Point(2, f32),
            p2: Point(2, f32),
            y_min: f32,
            y_max: f32,
            /// +1 when the edge runs down the screen, -1 up; the winding contribution.
            dir: i8,

            /// x where the edge crosses the horizontal line at `y`, for y in [y_min, y_max).
            inline fn xAt(e: Edge, y: f32) f32 {
                return e.p1.x() + (y - e.p1.y()) * (e.p2.x() - e.p1.x()) / (e.p2.y() - e.p1.y());
            }
        };

        /// Where an edge crosses a scanline, with its winding direction.
        const Crossing = struct {
            x: f32,
            dir: i8,

            fn lessThan(_: void, a: Crossing, b: Crossing) bool {
                return a.x < b.x;
            }
        };

        /// Fills `buf` with the non-horizontal edges of every contour (horizontal ones never
        /// cross a scanline).
        fn polygonEdges(contours: []const []const Point(2, f32), buf: []Edge) []Edge {
            var count: usize = 0;
            for (contours) |polygon| {
                if (polygon.len < 3) continue;
                for (polygon, 0..) |p1, i| {
                    const p2 = polygon[(i + 1) % polygon.len];
                    if (p1.y() == p2.y()) continue;
                    buf[count] = .{
                        .p1 = p1,
                        .p2 = p2,
                        .y_min = @min(p1.y(), p2.y()),
                        .y_max = @max(p1.y(), p2.y()),
                        .dir = if (p1.y() < p2.y()) 1 else -1,
                    };
                    count += 1;
                }
            }
            return buf[0..count];
        }

        /// Crossings of `edges` with the horizontal line at `y`, sorted by x.
        fn scanlineCrossings(edges: []const Edge, y: f32, buf: []Crossing) []Crossing {
            var count: usize = 0;
            for (edges) |e| {
                if (y >= e.y_min and y < e.y_max) {
                    buf[count] = .{ .x = e.xAt(y), .dir = e.dir };
                    count += 1;
                }
            }
            const crossings = buf[0..count];
            if (count == 2) {
                if (crossings[0].x > crossings[1].x) std.mem.swap(Crossing, &crossings[0], &crossings[1]);
            } else if (count > 2) {
                std.mem.sort(Crossing, crossings, {}, Crossing.lessThan);
            }
            return crossings;
        }

        /// The spans of one scanline inside the shape under `rule`, from x-sorted crossings.
        /// Even-odd toggles on every crossing, pairing them as a pairwise walk would; nonzero
        /// sums the edge directions.
        const SpanIter = struct {
            crossings: []const Crossing,
            rule: FillRule,
            i: usize = 0,
            winding: i32 = 0,
            left: f32 = 0,

            fn next(it: *SpanIter) ?[2]f32 {
                while (it.i < it.crossings.len) {
                    const c = it.crossings[it.i];
                    it.i += 1;
                    const was_inside = it.winding != 0;
                    it.winding = switch (it.rule) {
                        .even_odd => it.winding ^ 1,
                        .nonzero => it.winding + c.dir,
                    };
                    if (it.winding != 0) {
                        if (!was_inside) it.left = c.x;
                    } else if (was_inside) {
                        return .{ it.left, c.x };
                    }
                }
                return null;
            }
        };

        /// One pixel of a `fillPolygonSoft` row: `area` accumulates partial coverage at span
        /// ends, `run` is a difference array for fully covered interiors.
        const CoverageCell = struct { area: f32 = 0, run: f32 = 0 };

        /// Antialiased fill. Each pixel row is sampled at `polygon_subscanlines` heights;
        /// span ends contribute their exact horizontal overlap and fully covered interiors go
        /// through a difference array, so per-row cost does not scale with the sample count.
        /// Polygons have no closed-form distance field, hence supersampling rather than the
        /// analytic coverage used for rings and lines.
        fn fillPolygonSoft(self: Self, edges: []Edge, bounds: Rectangle(f32), crossings_buf: []Crossing, rule: FillRule, sink: anytype, scratch: std.mem.Allocator) !void {
            const frows: f32 = @floatFromInt(self.image.rows);
            const end_y = @min(frows - 1, @ceil(bounds.b));
            const col_start = clampToImageBounds(@floor(bounds.l - 0.5), self.image.cols);
            const col_end = clampToImageBounds(@ceil(bounds.r + 0.5) + 1, self.image.cols);
            if (col_start >= col_end) return;
            const width = col_end - col_start;

            const cells = try scratch.alloc(CoverageCell, width);
            defer scratch.free(cells);
            @memset(cells, .{});

            // Buffer-relative x: cell j covers [j, j+1), i.e. image column col_start + j.
            const x_lo = as(f32, col_start) - 0.5;
            const x_hi = as(f32, col_end) - 0.5;
            const weight = 1.0 / as(f32, polygon_subscanlines);

            var y = @max(0, @floor(bounds.t));
            while (y <= end_y) : (y += 1) {
                // Partition the edges overlapping this row's band to the front so the
                // sub-scanline passes only test those.
                var active: usize = 0;
                for (edges, 0..) |e, i| {
                    if (e.y_min < y + 0.5 and e.y_max > y - 0.5) {
                        std.mem.swap(Edge, &edges[active], &edges[i]);
                        active += 1;
                    }
                }

                var touched_lo: usize = width;
                var touched_hi: usize = 0;
                for (0..polygon_subscanlines) |k| {
                    const sy = y - 0.5 + (as(f32, k) + 0.5) * weight;
                    var spans: SpanIter = .{ .crossings = scanlineCrossings(edges[0..active], sy, crossings_buf), .rule = rule };
                    while (spans.next()) |span| {
                        const left = @max(span[0], x_lo) - x_lo;
                        const right = @min(span[1], x_hi) - x_lo;
                        if (right <= left) continue;

                        const first: usize = @floor(left);
                        const last_raw: usize = @floor(right);
                        const last = @min(last_raw, width - 1);
                        if (first == last) {
                            cells[first].area += (right - left) * weight;
                        } else {
                            cells[first].area += (as(f32, first + 1) - left) * weight;
                            cells[last].area += (right - as(f32, last)) * weight;
                            cells[first + 1].run += weight;
                            cells[last].run -= weight;
                        }
                        touched_lo = @min(touched_lo, first);
                        touched_hi = @max(touched_hi, last);
                    }
                }
                if (touched_lo > touched_hi) continue;

                const row: u32 = @trunc(y);
                const row_px = self.image.data[row * self.image.stride + col_start ..][0..width];
                var run: f32 = 0;
                for (cells[touched_lo .. touched_hi + 1], row_px[touched_lo .. touched_hi + 1]) |*cell, *px| {
                    run += cell.run;
                    const alpha = @min(cell.area + run, 1);
                    cell.* = .{};
                    sink.cover(px, alpha);
                }
            }
        }

        /// Fills a circle on the given image.
        /// Use DrawMode.soft for anti-aliased edges or DrawMode.fast for hard edges.
        pub fn fillCircle(self: Self, center: Point(2, f32), radius: f32, color: anytype, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0) return;

            switch (opts.mode) {
                .fast => self.fillCircleFast(center, radius, color, opts.blending),
                .soft => self.renderRing(center, 0, radius, color, .full, opts),
            }
        }

        /// Fills a pie slice (arc including the center point). Angles are in radians from the
        /// positive X-axis, counter-clockwise. Arcs spanning ≥ 2π render as a full circle.
        ///
        /// Example:
        /// ```zig
        /// // Green pie slice from π/4 to 3π/4
        /// try canvas.fillArc(center, 60, std.math.pi / 4.0, 3.0 * std.math.pi / 4.0, Rgb.green, .soft);
        /// ```
        pub fn fillArc(self: Self, center: Point(2, f32), radius: f32, start_angle: f32, end_angle: f32, color: anytype, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (radius <= 0) return;

            // Validate angles are finite numbers
            if (!std.math.isFinite(start_angle) or !std.math.isFinite(end_angle)) {
                return;
            }

            if (@abs(end_angle - start_angle) >= 2 * std.math.pi) {
                self.fillCircle(center, radius, color, opts);
                return;
            }

            // Partial arc
            const arc: ArcRange = .init(start_angle, end_angle);
            switch (opts.mode) {
                .fast => self.fillArcFast(center, radius, arc, color, opts.blending),
                .soft => try self.fillArcSoft(center, radius, arc, color, opts.blending),
            }
        }

        /// Internal function for filling solid (non-anti-aliased) circles.
        fn fillCircleFast(self: Self, center: Point(2, f32), radius: f32, color: anytype, blending: Blending) void {
            const paint: Paint = .init(color, blending);
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
                    self.fillSpan(x1, x2, y, paint);
                }
            }
        }

        /// Internal function for filling solid (non-anti-aliased) arcs.
        /// Fills a pie slice (arc + lines to center).
        fn fillArcFast(self: Self, center: Point(2, f32), radius: f32, arc: ArcRange, color: anytype, blending: Blending) void {
            if (arc.span() <= 0) return;

            const paint: Paint = .init(color, blending);
            const frows: f32 = @floatFromInt(self.image.rows);
            const fcols: f32 = @floatFromInt(self.image.cols);

            // Half-plane edges: a point (dx, dy) is "after" start_angle CCW iff
            // dx*sin(start) - dy*cos(start) <= 0, and "before" end_angle CCW iff
            // dx*sin(end) - dy*cos(end) >= 0. For span <= π the wedge is their intersection;
            // for span > π it's their union (everything except the smaller complementary wedge).
            const sv = arc.startVector();
            const ev = arc.endVector();
            const sin_s = sv.y();
            const cos_s = sv.x();
            const sin_e = ev.y();
            const cos_e = ev.x();
            const cx_sin_s = center.x() * sin_s;
            const cx_sin_e = center.x() * sin_e;

            const top = @max(0, center.y() - radius);
            const bottom = @min(frows - 1, center.y() + radius);
            const left = @max(0, center.x() - radius);
            const right = @min(fcols - 1, center.x() + radius);

            const radius_sq = radius * radius;

            var y = top;
            while (y <= bottom) : (y += 1) {
                const dy = y - center.y();
                const dx_max_sq = radius_sq - dy * dy;
                if (dx_max_sq <= 0) continue;
                const dx_max = @sqrt(dx_max_sq);
                const scan_left = @max(left, center.x() - dx_max);
                const scan_right = @min(right, center.x() + dx_max);

                // Per-scanline x-independent components of the cross products.
                const start_const = -cx_sin_s - dy * cos_s;
                const end_const = -cx_sin_e - dy * cos_e;

                var x = scan_left;
                while (x <= scan_right) : (x += 1) {
                    if (!arc.containsCross(x * sin_s + start_const, x * sin_e + end_const)) continue;

                    var span_end = x;
                    while (span_end < scan_right) : (span_end += 1) {
                        const nx = span_end + 1;
                        const dnx = nx - center.x();
                        // Guard against scan_right's float imprecision pushing nx past the circle —
                        // without this, fillSpan's @ceil can include an extra pixel.
                        if (dnx * dnx + dy * dy > radius_sq) break;
                        if (!arc.containsCross(nx * sin_s + start_const, nx * sin_e + end_const)) break;
                    }

                    self.fillSpan(x, span_end, y, paint);
                    x = span_end;
                }
            }
        }

        /// Helper: Calculate antialiased coverage for arc boundaries
        inline fn calculateArcCoverage(dist: f32, radius: f32, in_arc: bool, start_cross_product: f32, end_cross_product: f32) f32 {
            const start_cross = @abs(start_cross_product);
            const end_cross = @abs(end_cross_product);

            // Circular boundary coverage
            const circ_coverage = if (dist <= radius - 1.0)
                1.0
            else if (dist < radius + 1.0)
                clamp(radius - dist + 0.5, 0, 1)
            else
                0.0;

            const eps = 1e-5;

            if (!in_arc) {
                // Outside arc - apply edge antialiasing
                var edge_coverage: f32 = 0;
                if (start_cross < 1.0 and start_cross_product < eps) edge_coverage = @max(edge_coverage, 1.0 - start_cross);
                if (end_cross < 1.0 and end_cross_product > -eps) edge_coverage = @max(edge_coverage, 1.0 - end_cross);
                return circ_coverage * edge_coverage;
            } else {
                // Inside arc - reduce coverage near edges
                var coverage = circ_coverage;
                if (start_cross < 1.0 and start_cross_product >= -eps) coverage = @min(coverage, start_cross);
                if (end_cross < 1.0 and end_cross_product <= eps) coverage = @min(coverage, end_cross);
                return coverage;
            }
        }

        /// Internal function for filling smooth (anti-aliased) arcs.
        fn fillArcSoft(self: Self, center: Point(2, f32), radius: f32, arc: ArcRange, color: anytype, blending: Blending) !void {
            // Precompute edge vectors
            const start_edge = arc.startVector();
            const end_edge = arc.endVector();

            const bounds = self.ringBoundingBox(center, radius) orelse return;
            const paint: Paint = .init(color, blending);

            for (bounds.t..bounds.b) |r| {
                const y = as(f32, r) - center.y();
                for (bounds.l..bounds.r) |c| {
                    const x = as(f32, c) - center.x();

                    const dist_sq = x * x + y * y;
                    if (dist_sq > (radius + 1) * (radius + 1)) continue;

                    const angle = std.math.atan2(y, x);
                    const in_arc = arc.contains(angle);

                    const p: Point(2, f32) = .init(.{ x, y });

                    const start_cross_product = p.cross(start_edge);
                    const end_cross_product = p.cross(end_edge);

                    if (!in_arc) {
                        const eps = 1e-5;
                        const near_start = @abs(start_cross_product) < 1.0 and start_cross_product < eps;
                        const near_end = @abs(end_cross_product) < 1.0 and end_cross_product > -eps;
                        if (!near_start and !near_end) continue;
                    }

                    const dist = @sqrt(dist_sq);
                    const coverage = calculateArcCoverage(dist, radius, in_arc, start_cross_product, end_cross_product);
                    paint.cover(&self.image.data[r * self.image.stride + c], coverage);
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
            width: u32,
            opts: DrawOptions,
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
                opts,
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
            width: u32,
            opts: DrawOptions,
        ) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0) return;

            const estimated_length = estimateCubicBezierLength(p0, p1, p2, p3);
            const pixels_per_segment: f32 = if (opts.mode == .soft or width > 2) pixels_per_segment_soft else pixels_per_segment_fast;

            self.drawBezierTessellated(
                estimated_length,
                pixels_per_segment,
                spline_min_segments_count,
                evalCubicBezier,
                .{ p0, p1, p2, p3 },
                color,
                width,
                opts,
            );
        }

        /// Draws a spline polygon outline with Bézier curves connecting vertices.
        /// The polygon's edges are rendered as cubic Bézier splines for smooth, curved appearance.
        /// Use tension to control curve smoothness: 0=sharp corners, 1=maximum smoothness.
        pub fn drawSplinePolygon(self: Self, polygon: []const Point(2, f32), color: anytype, width: u32, tension: f32, opts: DrawOptions) void {
            comptime assert(isColor(@TypeOf(color)));
            if (width == 0 or polygon.len < 3) return;

            for (0..polygon.len) |i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const control_points = calculateSmoothControlPoints(p0, p1, p2, tension);
                self.drawCubicBezier(p0, control_points.cp1, control_points.cp2, p1, color, width, opts);
            }
        }

        /// Fills a spline polygon with Bézier curves connecting vertices.
        /// The polygon's outline is defined by Bézier splines for smooth, curved edges.
        /// Use tension to control curve smoothness: 0=sharp corners, 1=maximum smoothness.
        pub fn fillSplinePolygon(self: Self, polygon: []const Point(2, f32), color: anytype, tension: f32, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            if (polygon.len < 3) return;

            const EdgeCurve = struct {
                cp1: Point(2, f32),
                cp2: Point(2, f32),
                length: f32,
                segments: u32,
            };

            const pixels_per_segment = pixels_per_segment_fast;

            var stack: [spline_polygon_stack_buffer_size * @sizeOf(Point(2, f32)) + 32 * @sizeOf(EdgeCurve)]u8 align(16) = undefined;
            var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, self.allocator);
            const scratch = buffer_first.allocator();

            // Cache per-edge curve data so the tessellation pass doesn't recompute control
            // points or curve-length estimates.
            const edges = try scratch.alloc(EdgeCurve, polygon.len);
            defer scratch.free(edges);

            var total_points: u32 = 0;
            for (edges, 0..) |*edge, i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const p2 = polygon[(i + 2) % polygon.len];
                const cps = calculateSmoothControlPoints(p0, p1, p2, tension);
                const length = estimateCubicBezierLength(p0, cps.cp1, cps.cp2, p1);
                const segments: u32 = @max(spline_min_segments_count, @min(spline_max_segments_count, @as(u32, @trunc(length / pixels_per_segment))));
                edge.* = .{ .cp1 = cps.cp1, .cp2 = cps.cp2, .length = length, .segments = segments };
                total_points += segments;
            }

            const points_buffer = try scratch.alloc(Point(2, f32), total_points);
            defer scratch.free(points_buffer);

            var write_idx: u32 = 0;
            for (edges, 0..) |edge, i| {
                const p0 = polygon[i];
                const p1 = polygon[(i + 1) % polygon.len];
                const segment_buffer = points_buffer[write_idx .. write_idx + edge.segments];
                const actual_segments = tessellateBezier(
                    edge.length,
                    pixels_per_segment,
                    spline_min_segments_count,
                    spline_max_segments_count,
                    evalCubicBezier,
                    .{ p0, edge.cp1, edge.cp2, p1 },
                    segment_buffer,
                );
                write_idx += actual_segments;
            }

            try self.fillPolygon(points_buffer, color, opts);
        }

        /// Evaluates a quadratic Bézier curve at parameter t.
        /// Uses the standard quadratic Bézier formula: (1-t)²P₀ + 2t(1-t)P₁ + t²P₂
        /// Parameter t is in range [0, 1] where 0=start point, 1=end point.
        fn evalQuadraticBezier(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32), t: f32) Point(2, f32) {
            const u = 1 - t;
            const uu = u * u;
            const tt = t * t;
            return .init(.{
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
            return .init(.{
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

        /// Tessellates a Bézier curve into discrete points, with segment count chosen adaptively
        /// from `estimated_length` and `pixels_per_segment`. Returns the number of points written.
        fn tessellateBezier(
            estimated_length: f32,
            pixels_per_segment: f32,
            min_segments: u32,
            max_segments: u32,
            comptime evalFn: anytype,
            evalArgs: anytype,
            buffer: []Point(2, f32),
        ) u32 {
            const segments: u32 = @max(min_segments, @min(max_segments, @as(u32, @trunc(estimated_length / pixels_per_segment))));
            const actual_segments = @min(segments, buffer.len);

            for (0..actual_segments) |i| {
                const t = as(f32, i) / as(f32, actual_segments - 1);
                buffer[i] = @call(.auto, evalFn, evalArgs ++ .{t});
            }

            return actual_segments;
        }

        /// Draws a Bézier curve by tessellating it into line segments.
        fn drawBezierTessellated(
            self: Self,
            estimated_length: f32,
            pixels_per_segment: f32,
            min_segments: u32,
            comptime evalFn: anytype,
            evalArgs: anytype,
            color: anytype,
            width: u32,
            opts: DrawOptions,
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
                self.drawLine(stack_buffer[i - 1], stack_buffer[i], color, width, opts);
            }
        }

        /// Calculates cubic Bézier control points (`cp1` outgoing from p0, `cp2` incoming to p1)
        /// for a smooth curve through `p1` influenced by neighbors `p0`/`p2`. `tension` ranges
        /// from 0 (sharp corners) to 1 (maximum smoothness).
        fn calculateSmoothControlPoints(p0: Point(2, f32), p1: Point(2, f32), p2: Point(2, f32), tension: f32) struct { cp1: Point(2, f32), cp2: Point(2, f32) } {
            const tension_factor = 1 - clamp(tension, 0, 1);
            return .{
                .cp1 = .init(.{
                    p0.x() + (p1.x() - p0.x()) * tension_factor,
                    p0.y() + (p1.y() - p0.y()) * tension_factor,
                }),
                .cp2 = .init(.{
                    p1.x() - (p2.x() - p1.x()) * tension_factor,
                    p1.y() - (p2.y() - p1.y()) * tension_factor,
                }),
            };
        }

        /// Helper function to get a bit value from glyph bitmap data.
        /// Returns 1 if the bit is set, 0 otherwise.
        inline fn getGlyphBit(char_data: []const u8, row: usize, col: usize, bytes_per_row: u32) u1 {
            const byte_idx = col / 8;
            const bit_idx = col % 8;
            const row_byte_offset = row * bytes_per_row + byte_idx;
            if (row_byte_offset >= char_data.len) return 0;
            return @intCast((char_data[row_byte_offset] >> @intCast(bit_idx)) & 1);
        }

        /// Helper function to calculate bytes per row for a glyph.
        /// Handles both fixed-width and variable-width fonts.
        inline fn calculateGlyphBytesPerRow(glyph_info: anytype, font: anytype) u32 {
            // Variable-width fonts use glyph-specific width, fixed-width fonts use font-wide stride
            return if (font.glyph_map != null)
                (@as(u32, glyph_info.width) + 7) / 8
            else
                font.bytesPerRow();
        }

        /// Draws `text` with its top-left corner at `position`, at `font_size` pixels: the em height
        /// for vector fonts, the character height for bitmap fonts. `null` draws at
        /// `font.defaultSize()`, a bitmap font's native size. `\n` starts a new line.
        pub fn drawText(self: Self, text: []const u8, position: Point(2, f32), color: anytype, font: Font, font_size: ?f32, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            return self.renderText(text, unboundedBox(position), .init(color, opts.blending), font, font_size, .default, .fill, opts.mode);
        }

        /// Lays `text` out inside `box` as `layout` says: wrapped to the box width when asked,
        /// each line aligned horizontally and the block vertically. Text that does not fit
        /// is clipped by the image only, not the box.
        pub fn drawTextBox(self: Self, text: []const u8, box: Rectangle(f32), color: anytype, font: Font, font_size: ?f32, layout: TextLayout, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            return self.renderText(text, box, .init(color, opts.blending), font, font_size, layout, .fill, opts.mode);
        }

        /// `drawText` stroking each glyph's outline `width` pixels wide (round joins and caps)
        /// instead of filling it. Bitmap fonts have no outlines and get a halo of that
        /// diameter; draw the text over it for a readable label.
        pub fn drawTextOutline(self: Self, text: []const u8, position: Point(2, f32), color: anytype, font: Font, font_size: ?f32, width: f32, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            return self.renderText(text, unboundedBox(position), .init(color, opts.blending), font, font_size, .default, .{ .outline = width }, opts.mode);
        }

        /// `drawTextBox` stroking the glyphs as `drawTextOutline` does.
        pub fn drawTextBoxOutline(self: Self, text: []const u8, box: Rectangle(f32), color: anytype, font: Font, font_size: ?f32, width: f32, layout: TextLayout, opts: DrawOptions) !void {
            comptime assert(isColor(@TypeOf(color)));
            return self.renderText(text, box, .init(color, opts.blending), font, font_size, layout, .{ .outline = width }, opts.mode);
        }

        /// The box `drawText` uses: anchored at `position`, open to the right and below, so
        /// only left/top alignment without wrapping makes sense in it.
        fn unboundedBox(position: Point(2, f32)) Rectangle(f32) {
            return .{ .l = position.x(), .t = position.y(), .r = std.math.inf(f32), .b = std.math.inf(f32) };
        }

        /// The canvas area as a float rectangle, for clipping tests.
        fn imageRect(self: Self) Rectangle(f32) {
            return .{ .l = 0, .t = 0, .r = as(f32, self.cols()), .b = as(f32, self.rows()) };
        }

        /// Shared by every text entry point: breaks `text` into lines, places the block and
        /// each line inside `box` per `layout`, and draws the lines.
        fn renderText(self: Self, text: []const u8, box: Rectangle(f32), paint: Paint, font: Font, font_size: ?f32, layout: TextLayout, style: GlyphStyle, mode: DrawMode) !void {
            const px = font_size orelse font.defaultSize();
            if (px <= 0) return;
            const max_width: ?f32 = if (layout.wrap) box.width() else null;
            const advance = text_layout.lineAdvance(font, px, layout);
            var y = box.t;
            if (layout.valign != .top) {
                const block = text_layout.measure(font, text, px, max_width, layout).b;
                y = if (layout.valign == .middle) box.t + (box.height() - block) / 2 else box.b - block;
            }

            var lines: text_layout.Lines = .init(font, text, px, max_width, layout.letter_spacing);
            while (lines.next()) |line| : (y += advance) {
                const x: f32 = switch (layout.halign) {
                    .left => box.l,
                    .center => box.l + (box.width() - line.width) / 2,
                    .right => box.r - line.width,
                };
                const position: Point(2, f32) = .init(.{ x, y });
                switch (font) {
                    .bitmap => |bitmap| self.drawTextBitmap(line.text, position, paint, bitmap, bitmap.scaleFor(px), layout.letter_spacing, style, mode),
                    .vector => |vector| try self.drawTextVector(line.text, position, paint, vector, px, layout.letter_spacing, style, mode),
                }
            }
        }

        /// Lays out one line with `VectorFont.Layout`, then fills or strokes each glyph's
        /// outline. Glyphs that fail to parse are skipped; only allocation errors propagate.
        fn drawTextVector(self: Self, text: []const u8, position: Point(2, f32), paint: Paint, font: VectorFont, font_size: f32, letter_spacing: f32, style: GlyphStyle, mode: DrawMode) !void {
            const canvas_rect = self.imageRect();
            const margin = style.reach() + 1;
            var layout: VectorFont.Layout = .init(font, text, font_size);
            layout.letter_spacing = letter_spacing;
            while (layout.next()) |item| {
                const ink = layout.inkBounds(item) orelse continue;
                if (ink.translate(position.x(), position.y()).grow(margin).intersect(canvas_rect) == null) continue;
                var outline = font.outline(self.allocator, item.gid) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                defer outline.deinit(self.allocator);
                var stack: [glyph_scratch_size]u8 align(16) = undefined;
                var buffer_first: std.heap.BufferFirstAllocator = .init(&stack, self.allocator);
                const scratch = buffer_first.allocator();
                const flat = try FlatGlyph.init(scratch, outline, layout.transform(item, position));
                defer flat.deinit(scratch);
                switch (mode) {
                    inline else => |m| switch (style) {
                        .fill => try self.fillContours(flat.polys, .nonzero, m, paint),
                        .outline => |width| try self.strokePolylines(scratch, flat.polys, width, m, paint),
                    },
                }
            }
        }

        /// Draws one line of bitmap glyphs. An `.outline` style blits every glyph at each
        /// integer offset within its reach, dilating it into a halo; the stamps blend
        /// independently, so translucent halos darken where they overlap.
        fn drawTextBitmap(self: Self, text: []const u8, position: Point(2, f32), paint: Paint, font: BitmapFont, scale: f32, letter_spacing: f32, style: GlyphStyle, mode: DrawMode) void {
            const radius: i32 = @intFromFloat(@ceil(style.reach()));
            const glyphs = std.unicode.utf8CountCodepoints(text) catch text.len;
            const text_bounds = font.getTextBounds(text, scale);
            const text_rect: Rectangle(f32) = .{
                .l = position.x() + text_bounds.l,
                .t = position.y() + text_bounds.t,
                .r = position.x() + text_bounds.r + @max(letter_spacing, 0) * as(f32, glyphs),
                .b = position.y() + text_bounds.b,
            };
            const clip_rect = text_rect.grow(as(f32, radius)).intersect(self.imageRect()) orelse return;

            var x = position.x();
            const y = position.y();
            var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
            while (utf8_iter.nextCodepoint()) |codepoint| {
                if (font.getGlyph(codepoint)) |glyph| {
                    var dy: i32 = -radius;
                    while (dy <= radius) : (dy += 1) {
                        var dx: i32 = -radius;
                        while (dx <= radius) : (dx += 1) {
                            if (dx * dx + dy * dy > radius * radius) continue;
                            const gx = x + as(f32, dx);
                            const gy = y + as(f32, dy);
                            if (scale == 1.0) {
                                self.renderGlyphUnscaled(glyph.info, glyph.data, font, gx, gy, paint);
                            } else switch (mode) {
                                .fast => self.renderGlyphFastScaled(glyph.info, glyph.data, font, gx, gy, scale, clip_rect, paint),
                                .soft => self.renderGlyphSoftScaled(glyph.info, glyph.data, font, gx, gy, scale, paint),
                            }
                        }
                    }
                    x += as(f32, glyph.info.advanceWidth()) * scale;
                } else {
                    x += as(f32, font.char_width) * scale;
                }
                x += letter_spacing;
            }
        }

        /// Blits a glyph 1:1 (no scaling). Fixed-width fonts iterate the full font row height
        /// even when the glyph's own height is smaller. Bypasses `setPixel` per lit bit: floors
        /// `x`/`y` once (floor commutes with adding the integer col/row/offsets), pre-converts
        /// `color`, hoists the blend-mode branch, and writes pixels through direct memory
        /// access with a single u32 bounds check.
        fn renderGlyphUnscaled(self: Self, glyph_info: anytype, char_data: []const u8, font: BitmapFont, x: f32, y: f32, paint: Paint) void {
            const bytes_per_row = calculateGlyphBytesPerRow(glyph_info, font);
            const render_height = if (font.glyph_map == null) font.char_height else glyph_info.height;

            const fx: i32 = @floor(x);
            const fy: i32 = @floor(y);
            const base_col = fx + as(i32, glyph_info.x_offset);
            const base_row = fy + as(i32, glyph_info.y_offset);
            const rows_i32: i32 = @intCast(self.image.rows);
            const cols_i32: i32 = @intCast(self.image.cols);

            for (0..render_height) |row| {
                const py = base_row + as(i32, row);
                if (py < 0 or py >= rows_i32) continue;
                const row_offset: usize = @as(usize, @intCast(py)) * self.image.stride;
                for (0..glyph_info.width) |col| {
                    if (getGlyphBit(char_data, row, col, bytes_per_row) == 0) continue;
                    const px = base_col + as(i32, col);
                    if (px < 0 or px >= cols_i32) continue;
                    paint.put(&self.image.data[row_offset + @as(usize, @intCast(px))]);
                }
            }
        }

        /// Nearest-neighbor upscale: each set glyph bit produces a `scale`-wide block of
        /// identical pixels, clipped to the precomputed text rect.
        fn renderGlyphFastScaled(self: Self, glyph_info: anytype, char_data: []const u8, font: BitmapFont, x: f32, y: f32, scale: f32, clip_rect: Rectangle(f32), paint: Paint) void {
            const bytes_per_row = calculateGlyphBytesPerRow(glyph_info, font);
            for (0..glyph_info.height) |row| {
                for (0..glyph_info.width) |col| {
                    if (getGlyphBit(char_data, row, col, bytes_per_row) == 0) continue;
                    const base_x = x + (as(f32, col) + as(f32, glyph_info.x_offset)) * scale;
                    const base_y = y + (as(f32, row) + as(f32, glyph_info.y_offset)) * scale;
                    const x_start: u32 = @trunc(@max(@floor(base_x), clip_rect.l));
                    const y_start: u32 = @trunc(@max(@floor(base_y), clip_rect.t));
                    const x_end: u32 = @trunc(@min(@ceil(base_x + scale), clip_rect.r));
                    const y_end: u32 = @trunc(@min(@ceil(base_y + scale), clip_rect.b));
                    if (x_start >= x_end or y_start >= y_end) continue;
                    // clip_rect is inside the image, so writes need no per-pixel bounds check.
                    for (y_start..y_end) |py| {
                        const row_offset = py * self.image.stride;
                        for (x_start..x_end) |px| {
                            const dest = &self.image.data[row_offset + px];
                            paint.put(dest);
                        }
                    }
                }
            }
        }

        /// Box-filter antialiased upscale: each destination pixel samples a `1/scale`-radius
        /// box of the source bitmap and writes the area-weighted coverage as alpha.
        fn renderGlyphSoftScaled(self: Self, glyph_info: anytype, char_data: []const u8, font: BitmapFont, x: f32, y: f32, scale: f32, paint: Paint) void {
            const bytes_per_row = calculateGlyphBytesPerRow(glyph_info, font);
            const glyph_width_f = as(f32, glyph_info.width);
            const glyph_height_f = as(f32, glyph_info.height);
            const dest_width = @ceil(glyph_width_f * scale);
            const dest_height = @ceil(glyph_height_f * scale);
            const sample_radius = 0.5 / scale;

            var dy: f32 = 0;
            while (dy < dest_height) : (dy += 1) {
                var dx: f32 = 0;
                while (dx < dest_width) : (dx += 1) {
                    const dest_x = x + dx + as(f32, glyph_info.x_offset) * scale;
                    const dest_y = y + dy + as(f32, glyph_info.y_offset) * scale;
                    const dest = self.atOrNull(@floor(dest_y), @floor(dest_x)) orelse continue;

                    const src_x = dx / scale;
                    const src_y = dy / scale;
                    const x0 = src_x - sample_radius;
                    const x1 = src_x + sample_radius;
                    const y0 = src_y - sample_radius;
                    const y1 = src_y + sample_radius;

                    const row_start_f = @max(0, @floor(y0));
                    const row_end_f = @min(glyph_height_f - 1, @ceil(y1));
                    const col_start_f = @max(0, @floor(x0));
                    const col_end_f = @min(glyph_width_f - 1, @ceil(x1));

                    var total_coverage: f32 = 0;
                    var row_f = row_start_f;
                    while (row_f <= row_end_f) : (row_f += 1) {
                        var col_f = col_start_f;
                        while (col_f <= col_end_f) : (col_f += 1) {
                            const row_idx: u32 = @trunc(row_f);
                            const col_idx: u32 = @trunc(col_f);
                            if (getGlyphBit(char_data, row_idx, col_idx, bytes_per_row) == 0) continue;
                            const overlap_x = clamp(@min(x1, col_f + 1) - @max(x0, col_f), 0, 1);
                            const overlap_y = clamp(@min(y1, row_f + 1) - @max(y0, row_f), 0, 1);
                            total_coverage += overlap_x * overlap_y;
                        }
                    }

                    const box_area = (x1 - x0) * (y1 - y0);
                    const normalized_coverage = total_coverage / box_area;
                    if (normalized_coverage > 0) {
                        paint.cover(dest, normalized_coverage);
                    }
                }
            }
        }
    };
}

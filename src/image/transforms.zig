//! Image geometric transformation operations
//!
//! This module provides various geometric transformations for images including
//! rotation, flipping, cropping, extraction, insertion, and letterboxing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Blending = @import("../blending.zig").Blending;
const Rectangle = @import("../geometry.zig").Rectangle;
const Point = @import("../geometry/Point.zig").Point;
const Image = @import("../image.zig").Image;
const assignPixel = @import("../image.zig").assignPixel;
const BorderMode = @import("border.zig").BorderMode;
const computeCoords = @import("border.zig").computeCoords;
const interpolate = @import("interpolation.zig").interpolate;
const Interpolation = @import("interpolation.zig").Interpolation;

/// Rotation bounds result
pub const RotationBounds = struct { rows: u32, cols: u32 };

/// Transform operations for Image(T)
pub fn Transform(comptime T: type) type {
    return struct {
        const Self = Image(T);

        // ============================================================================
        // Public API - Main transform functions
        // ============================================================================

        /// Flips an image from left to right (mirror effect).
        pub fn flipLeftRight(self: Self) void {
            for (0..self.rows) |r| {
                const start = r * self.stride;
                std.mem.reverse(T, self.data[start .. start + self.cols]);
            }
        }

        /// Flips an image from top to bottom (upside down effect).
        pub fn flipTopBottom(self: Self) void {
            for (0..self.rows / 2) |r| {
                const top_row = self.data[r * self.stride ..][0..self.cols];
                const bot_row = self.data[(self.rows - r - 1) * self.stride ..][0..self.cols];
                for (top_row, bot_row) |*t, *b| {
                    std.mem.swap(T, t, b);
                }
            }
        }

        /// Resizes an image to fit within the output dimensions while preserving aspect ratio.
        /// The image is centered with black/zero padding around it (letterboxing).
        /// Returns a rectangle describing the area containing the actual image content.
        pub fn letterbox(self: Self, out: Self, allocator: Allocator, method: Interpolation) Rectangle(u32) {
            const interpolation = @import("interpolation.zig");

            // Ensure output has valid dimensions
            if (out.rows == 0 or out.cols == 0) {
                return .init(0, 0, 0, 0);
            }

            // If source is empty, fill output with zeros to prevent uninitialized memory leaks
            if (self.rows == 0 or self.cols == 0) {
                out.fill(std.mem.zeroes(T));
                return .init(0, 0, 0, 0);
            }

            // Early return if dimensions match - just copy and return full rectangle
            if (self.rows == out.rows and self.cols == out.cols) {
                self.copy(out);
                return out.getRectangle();
            }

            // Calculate scale factors
            const rows_scale = @as(f32, @floatFromInt(out.rows)) / @as(f32, @floatFromInt(self.rows));
            const cols_scale = @as(f32, @floatFromInt(out.cols)) / @as(f32, @floatFromInt(self.cols));

            // If scale factors are exactly equal, aspect ratios match - skip letterboxing
            if (rows_scale == cols_scale) {
                interpolation.resize(T, self, out, allocator, method);
                return out.getRectangle();
            }

            // Choose the smaller scale to maintain aspect ratio
            const aspect_scale = @min(rows_scale, cols_scale);

            // Calculate dimensions of the scaled image (ensure at least 1 pixel)
            const scaled_rows: u32 = @round(aspect_scale * @as(f32, @floatFromInt(self.rows)));
            const scaled_cols: u32 = @round(aspect_scale * @as(f32, @floatFromInt(self.cols)));

            // Calculate offset to center the image
            const offset_row = (out.rows -| scaled_rows) / 2;
            const offset_col = (out.cols -| scaled_cols) / 2;

            // Create rectangle for the letterboxed content
            const content_rect: Rectangle(u32) = .init(
                offset_col,
                offset_row,
                offset_col + scaled_cols,
                offset_row + scaled_rows,
            );

            // Create a view of the output at the calculated position
            const output_view = out.view(content_rect);

            // Resize the image into the view
            interpolation.resize(T, self, output_view, allocator, method);

            // Zero only the padding bands
            out.setBorder(content_rect, std.mem.zeroes(T));

            return content_rect;
        }

        /// Computes the output dimensions needed to contain `self` rotated by `angle` (radians)
        /// without clipping.
        pub fn rotateBounds(self: Self, angle: f32) RotationBounds {
            // Normalize angle to [0, 2π) range
            const normalized_angle = @mod(angle, std.math.tau);
            const epsilon = 1e-6;

            // Optimized cases for orthogonal rotations
            if (@abs(normalized_angle) < epsilon or @abs(normalized_angle - std.math.tau) < epsilon) {
                // 0° or 360° - same dimensions
                return .{ .rows = self.rows, .cols = self.cols };
            }

            if (@abs(normalized_angle - std.math.pi / 2.0) < epsilon) {
                // 90° - swap dimensions
                return .{ .rows = self.cols, .cols = self.rows };
            }

            if (@abs(normalized_angle - std.math.pi) < epsilon) {
                // 180° - same dimensions
                return .{ .rows = self.rows, .cols = self.cols };
            }

            if (@abs(normalized_angle - 3.0 * std.math.pi / 2.0) < epsilon) {
                // 270° - swap dimensions
                return .{ .rows = self.cols, .cols = self.rows };
            }

            // General case using trigonometry
            const cos_abs = @abs(@cos(angle));
            const sin_abs = @abs(@sin(angle));
            const w: f32 = @floatFromInt(self.cols);
            const h: f32 = @floatFromInt(self.rows);
            const new_w = w * cos_abs + h * sin_abs;
            const new_h = h * cos_abs + w * sin_abs;
            return .{
                .cols = @ceil(new_w),
                .rows = @ceil(new_h),
            };
        }

        /// Rotates the image by `angle` (radians) around its center, returning a new image sized
        /// by `rotateBounds` to fit the rotated content.
        pub fn rotate(self: Self, gpa: Allocator, angle: f32, method: Interpolation, border: BorderMode) !Self {
            const bounds = rotateBounds(self, angle);
            const rotated = try Self.init(gpa, bounds.rows, bounds.cols);
            rotateInto(self, rotated, angle, method, border);
            return rotated;
        }

        /// Rotates the image by `angle` (radians) around its center into the pre-allocated `out`.
        /// `out` is typically sized via `rotateBounds`, but any shape is accepted; the result is
        /// centered with zero/`border` padding for any uncovered pixels.
        pub fn rotateInto(self: Self, out: Self, angle: f32, method: Interpolation, border: BorderMode) void {
            const center = self.getCenter();
            const normalized_angle = @mod(angle, std.math.tau);
            const epsilon = 1e-6;

            // Fast paths for orthogonal rotations
            if (@abs(normalized_angle) < epsilon or @abs(normalized_angle - std.math.tau) < epsilon) {
                rotate0(self, out);
                return;
            }

            if (@abs(normalized_angle - std.math.pi / 2.0) < epsilon) {
                rotate90CCW(self, out);
                return;
            }

            if (@abs(normalized_angle - std.math.pi) < epsilon) {
                rotate180(self, out);
                return;
            }

            if (@abs(normalized_angle - 3.0 * std.math.pi / 2.0) < epsilon) {
                rotate270CCW(self, out);
                return;
            }

            // General rotation using inverse transformation (writes every pixel)
            const cos = @cos(angle);
            const sin = @sin(angle);

            const offset_x = (@as(f32, @floatFromInt(out.cols)) - @as(f32, @floatFromInt(self.cols))) / 2.0;
            const offset_y = (@as(f32, @floatFromInt(out.rows)) - @as(f32, @floatFromInt(self.rows))) / 2.0;

            const rotated_center_x = center.x() + offset_x;
            const rotated_center_y = center.y() + offset_y;

            for (0..out.rows) |r| {
                const y: f32 = @floatFromInt(r);
                for (0..out.cols) |c| {
                    const x: f32 = @floatFromInt(c);
                    const dx = x - rotated_center_x;
                    const dy = y - rotated_center_y;
                    const rotated_dx = cos * dx - sin * dy;
                    const rotated_dy = sin * dx + cos * dy;
                    const src_x = rotated_dx + center.x();
                    const src_y = rotated_dy + center.y();
                    out.at(r, c).* = if (interpolate(T, self, src_x, src_y, method, border)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Crops a rectangular region from the image. Coordinates are rounded; out-of-bounds areas
        /// are filled with zeroed pixels (e.g., black/transparent).
        pub fn crop(self: Self, allocator: Allocator, rectangle: Rectangle(f32)) !Self {
            const chip_rows: u32 = @round(rectangle.height());
            const chip_cols: u32 = @round(rectangle.width());
            const chip = try Self.init(allocator, chip_rows, chip_cols);
            extract(self, chip, rectangle, 0, .nearest, .zero);
            return chip;
        }

        /// Extracts a rotated rectangular region (defined in source coordinates) and resamples it
        /// to fill the pre-allocated `out` image. `angle` is in radians, counter-clockwise around
        /// the rect center.
        ///
        /// Notes:
        /// - Out-of-bounds samples are filled with zeroed pixels (e.g., black/transparent).
        /// - `out` can be a view; strides are respected via `at()` accessors.
        pub fn extract(self: Self, out: Self, rect: Rectangle(f32), angle: f32, method: Interpolation, border: BorderMode) void {
            if (out.rows == 0 or out.cols == 0) return;

            const frows: f32 = @floatFromInt(out.rows);
            const fcols: f32 = @floatFromInt(out.cols);
            const width: f32 = rect.width();
            const height: f32 = rect.height();

            // Fast path: axis-aligned crop with no resampling
            const epsilon = 1e-6;
            if (@abs(angle) < epsilon and
                @abs(width - fcols) < epsilon and
                @abs(height - frows) < epsilon)
            {
                // Use the same logic as crop
                const rect_top: i32 = @round(rect.t);
                const rect_left: i32 = @round(rect.l);
                copyRect(self, rect_top, rect_left, out, border);
                return;
            }

            // General path: rotation and/or resampling
            const cx: f32 = (rect.l + rect.r) * 0.5;
            const cy: f32 = (rect.t + rect.b) * 0.5;

            const cos_a = @cos(angle);
            const sin_a = @sin(angle);

            // Normalized mapping with center sampling when size == 1
            for (0..out.rows) |r| {
                const ty: f32 = if (out.rows == 1)
                    0.5
                else
                    @as(f32, @floatFromInt(r)) / (frows - 1);
                const y_rect = rect.t + ty * height;
                for (0..out.cols) |c| {
                    const tx: f32 = if (out.cols == 1)
                        0.5
                    else
                        @as(f32, @floatFromInt(c)) / (fcols - 1);
                    const x_rect = rect.l + tx * width;

                    // Rotate around rectangle center by +angle (CCW)
                    const dx = x_rect - cx;
                    const dy = y_rect - cy;
                    const src_x = cx + cos_a * dx - sin_a * dy;
                    const src_y = cy + sin_a * dx + cos_a * dy;

                    out.at(r, c).* = if (interpolate(T, self, src_x, src_y, method, border)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Inserts `source` into `self` at the destination rectangle, with optional rotation
        /// (radians, counter-clockwise around the rect center). Complement of `extract`.
        ///
        /// Notes:
        /// - The source image is scaled to fit the destination rectangle.
        /// - For Image(Rgba) sources, alpha blending is applied using the specified blend mode.
        /// - When the source is not RGBA, pixels are copied directly.
        /// - Pixels outside the source bounds are not modified in self.
        /// - This method mutates self in-place.
        pub fn insert(self: *Self, source: anytype, rect: Rectangle(f32), angle: f32, method: Interpolation, blend_mode: Blending) void {
            if (source.rows == 0 or source.cols == 0) return;

            const SourcePixelType = std.meta.Child(@TypeOf(source.data));

            const frows: f32 = @floatFromInt(source.rows);
            const fcols: f32 = @floatFromInt(source.cols);
            const rect_width = rect.width();
            const rect_height = rect.height();

            // Fast path: axis-aligned, no resampling
            const epsilon = 1e-6;
            if (@abs(angle) < epsilon and
                @abs(rect_width - fcols) < epsilon and
                @abs(rect_height - frows) < epsilon)
            {
                const dst_top: i32 = @round(rect.t);
                const dst_left: i32 = @round(rect.l);
                for (0..source.rows) |r| {
                    const y: i32 = dst_top + @as(i32, @intCast(r));
                    for (0..source.cols) |c| {
                        const x: i32 = dst_left + @as(i32, @intCast(c));
                        if (self.atOrNull(y, x)) |dest| {
                            assignPixel(dest, source.at(r, c).*, blend_mode);
                        }
                    }
                }
                return;
            }

            // General path with rotation/scaling
            const cx = (rect.l + rect.r) * 0.5;
            const cy = (rect.t + rect.b) * 0.5;
            const cos = @cos(angle);
            const sin = @sin(angle);

            // Pre-compute for efficiency
            const inv_width = 1.0 / rect_width;
            const inv_height = 1.0 / rect_height;
            const half_width = rect_width * 0.5;
            const half_height = rect_height * 0.5;

            // Exact bounding box of rotated rectangle
            const abs_cos = @abs(cos);
            const abs_sin = @abs(sin);
            const bound_hw = half_width * abs_cos + half_height * abs_sin;
            const bound_hh = half_width * abs_sin + half_height * abs_cos;

            const min_r: u32 = if (cy - bound_hh < 0) 0 else @as(u32, @floor(cy - bound_hh));
            const max_r: u32 = @min(self.rows, @as(u32, @ceil(cy + bound_hh)) + 1);
            const min_c: u32 = if (cx - bound_hw < 0) 0 else @as(u32, @floor(cx - bound_hw));
            const max_c: u32 = @min(self.cols, @as(u32, @ceil(cx + bound_hw)) + 1);

            // Only iterate over potentially affected pixels
            for (min_r..max_r) |r| {
                const dest_y = @as(f32, @floatFromInt(r));
                const dy = dest_y - cy;

                for (min_c..max_c) |c| {
                    const dest_x = @as(f32, @floatFromInt(c));
                    const dx = dest_x - cx;

                    // Inverse rotate to rectangle space
                    const rect_x = cos * dx + sin * dy;
                    const rect_y = -sin * dx + cos * dy;

                    // Check if inside rectangle (simplified bounds check)
                    if (@abs(rect_x) > half_width or @abs(rect_y) > half_height) continue;

                    // Map to normalized [0,1] coordinates
                    const norm_x = (rect_x + half_width) * inv_width;
                    const norm_y = (rect_y + half_height) * inv_height;

                    // Map to source image coordinates
                    const src_x = if (source.cols == 1) 0 else norm_x * (fcols - 1);
                    const src_y = if (source.rows == 1) 0 else norm_y * (frows - 1);

                    // Sample from source
                    if (interpolate(SourcePixelType, source, src_x, src_y, method, .mirror)) |src_val| {
                        // Type-specific handling with compile-time optimization
                        const dest_pixel = self.at(r, c);
                        assignPixel(dest_pixel, src_val, blend_mode);
                    }
                }
            }
        }

        // ============================================================================
        // Private helper functions
        // ============================================================================

        /// Identity copy into a possibly-larger `out`, centering `self`.
        fn rotate0(self: Self, out: Self) void {
            const offset_r = (out.rows -| self.rows) / 2;
            const offset_c = (out.cols -| self.cols) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = r + offset_r;
                    const new_c = c + offset_c;
                    if (new_r < out.rows and new_c < out.cols) {
                        out.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(u32) = .init(offset_c, offset_r, offset_c + self.cols, offset_r + self.rows);
                out.setBorder(inner, std.mem.zeroes(T));
            }
        }

        /// Fast 90-degree counter-clockwise rotation into a pre-allocated `out`.
        fn rotate90CCW(self: Self, out: Self) void {
            const offset_r = (out.rows -| self.cols) / 2;
            const offset_c = (out.cols -| self.rows) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = (self.cols - 1 - c) + offset_r;
                    const new_c = r + offset_c;
                    if (new_r < out.rows and new_c < out.cols) {
                        out.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(u32) = .init(offset_c, offset_r, offset_c + self.rows, offset_r + self.cols);
                out.setBorder(inner, std.mem.zeroes(T));
            }
        }

        /// Fast 180-degree rotation into a pre-allocated `out`.
        fn rotate180(self: Self, out: Self) void {
            const offset_r = (out.rows -| self.rows) / 2;
            const offset_c = (out.cols -| self.cols) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = (self.rows - 1 - r) + offset_r;
                    const new_c = (self.cols - 1 - c) + offset_c;
                    if (new_r < out.rows and new_c < out.cols) {
                        out.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(u32) = .init(offset_c, offset_r, offset_c + self.cols, offset_r + self.rows);
                out.setBorder(inner, std.mem.zeroes(T));
            }
        }

        /// Fast 270-degree counter-clockwise rotation into a pre-allocated `out`.
        fn rotate270CCW(self: Self, out: Self) void {
            const offset_r = (out.rows -| self.cols) / 2;
            const offset_c = (out.cols -| self.rows) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = c + offset_r;
                    const new_c = (self.rows - 1 - r) + offset_c;
                    if (new_r < out.rows and new_c < out.cols) {
                        out.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(u32) = .init(offset_c, offset_r, offset_c + self.rows, offset_r + self.cols);
                out.setBorder(inner, std.mem.zeroes(T));
            }
        }

        /// Internal helper: copies a rectangular region into a pre-allocated output image.
        fn copyRect(self: Self, rect_top: i32, rect_left: i32, out: Self, border: BorderMode) void {
            // Optimization for zero border (common case for crop)
            if (border == .zero) {
                // Calculate intersection
                const src_r_min = @max(0, rect_top);
                const src_r_max = @min(@as(i32, @intCast(self.rows)), rect_top + @as(i32, @intCast(out.rows)));
                const src_c_min = @max(0, rect_left);
                const src_c_max = @min(@as(i32, @intCast(self.cols)), rect_left + @as(i32, @intCast(out.cols)));

                // Check valid intersection
                if (src_r_min < src_r_max and src_c_min < src_c_max) {
                    // If intersection doesn't cover the whole output, fill with zeros first
                    const covers_all = (@as(u32, @intCast(src_r_max - src_r_min)) == out.rows) and (@as(u32, @intCast(src_c_max - src_c_min)) == out.cols);
                    if (!covers_all) {
                        out.fill(std.mem.zeroes(T));
                    }

                    const dst_r_offset = -rect_top;
                    const dst_c_offset = -rect_left;

                    const len: usize = @intCast(src_c_max - src_c_min);
                    var r = src_r_min;
                    while (r < src_r_max) : (r += 1) {
                        const src_row_idx: usize = @intCast(r);
                        const dst_row_idx: usize = @intCast(r + dst_r_offset);

                        const src_start = src_row_idx * self.stride + @as(usize, @intCast(src_c_min));
                        const dst_start = dst_row_idx * out.stride + @as(usize, @intCast(src_c_min + dst_c_offset));

                        @memcpy(out.data[dst_start .. dst_start + len], self.data[src_start .. src_start + len]);
                    }
                    return;
                } else {
                    // No intersection, just zero everything
                    out.fill(std.mem.zeroes(T));
                    return;
                }
            }

            for (0..out.rows) |r| {
                const ir: i32 = @intCast(r);
                for (0..out.cols) |c| {
                    const ic: i32 = @intCast(c);
                    const src_row = ir + rect_top;
                    const src_col = ic + rect_left;

                    if (computeCoords(src_row, src_col, @intCast(self.rows), @intCast(self.cols), border)) |coords| {
                        out.at(r, c).* = self.at(coords.row, coords.col).*;
                    } else {
                        out.at(r, c).* = std.mem.zeroes(T);
                    }
                }
            }
        }

        /// Applies a geometric transform to the image using backward mapping.
        /// For each pixel in the output, applies the transform to find the corresponding source pixel.
        pub fn warp(self: Self, out: Self, transform: anytype, method: Interpolation) void {
            for (0..out.rows) |r| {
                for (0..out.cols) |c| {
                    const out_point: Point(2, f32) = .init(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) });
                    const src_point = transform.project(out_point);
                    const value = interpolate(T, self, src_point.x(), src_point.y(), method, .mirror) orelse std.mem.zeroes(T);
                    out.at(r, c).* = value;
                }
            }
        }
    };
}

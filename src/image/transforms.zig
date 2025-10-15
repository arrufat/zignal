//! Image geometric transformation operations
//!
//! This module provides various geometric transformations for images including
//! rotation, flipping, cropping, extraction, insertion, and letterboxing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Blending = @import("../color/blending.zig").Blending;
const Rectangle = @import("../geometry.zig").Rectangle;
const Image = @import("../image.zig").Image;
const interpolate = @import("interpolation.zig").interpolate;
const Interpolation = @import("interpolation.zig").Interpolation;
const assignPixel = @import("../image.zig").assignPixel;

/// Rotation bounds result
pub const RotationBounds = struct { rows: usize, cols: usize };

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
                for (0..self.cols / 2) |c| {
                    std.mem.swap(T, self.at(r, c), self.at(r, self.cols - c - 1));
                }
            }
        }

        /// Flips an image from top to bottom (upside down effect).
        pub fn flipTopBottom(self: Self) void {
            for (0..self.rows / 2) |r| {
                for (0..self.cols) |c| {
                    std.mem.swap(T, self.at(r, c), self.at(self.rows - r - 1, c));
                }
            }
        }

        /// Resizes an image to fit within the output dimensions while preserving aspect ratio.
        /// The image is centered with black/zero padding around it (letterboxing).
        /// Returns a rectangle describing the area containing the actual image content.
        pub fn letterbox(self: Self, allocator: Allocator, out: *Self, method: Interpolation) !Rectangle(usize) {
            const interpolation = @import("interpolation.zig");

            // Ensure output has valid dimensions
            if (out.rows == 0 or out.cols == 0) {
                return error.InvalidDimensions;
            }

            // Ensure output has a contiguous buffer of the requested size
            if (out.isContiguous() and out.data.len > 0) {
                out.data = try allocator.realloc(out.data, out.rows * out.cols);
                out.stride = out.cols;
            } else {
                out.* = try .init(allocator, out.rows, out.cols);
            }

            // Early return if dimensions match - just copy and return full rectangle
            if (self.rows == out.rows and self.cols == out.cols) {
                self.copy(out.*);
                return out.getRectangle();
            }

            // Calculate scale factors
            const rows_scale = @as(f32, @floatFromInt(out.rows)) / @as(f32, @floatFromInt(self.rows));
            const cols_scale = @as(f32, @floatFromInt(out.cols)) / @as(f32, @floatFromInt(self.cols));

            // If scale factors are exactly equal, aspect ratios match - skip letterboxing
            if (rows_scale == cols_scale) {
                try interpolation.resize(T, allocator, self, out.*, method);
                return out.getRectangle();
            }

            // Choose the smaller scale to maintain aspect ratio
            const aspect_scale = @min(rows_scale, cols_scale);

            // Calculate dimensions of the scaled image (ensure at least 1 pixel)
            const scaled_rows: usize = @intFromFloat(@round(aspect_scale * @as(f32, @floatFromInt(self.rows))));
            const scaled_cols: usize = @intFromFloat(@round(aspect_scale * @as(f32, @floatFromInt(self.cols))));

            // Calculate offset to center the image
            const offset_row = (out.rows -| scaled_rows) / 2;
            const offset_col = (out.cols -| scaled_cols) / 2;

            // Create rectangle for the letterboxed content
            const content_rect: Rectangle(usize) = .init(
                offset_col,
                offset_row,
                offset_col + scaled_cols,
                offset_row + scaled_rows,
            );

            // Create a view of the output at the calculated position
            const output_view = out.view(content_rect);

            // Resize the image into the view
            try interpolation.resize(T, allocator, self, output_view, method);

            // Zero only the padding bands
            out.setBorder(content_rect, std.mem.zeroes(T));

            return content_rect;
        }

        /// Computes the optimal output dimensions for rotating an image by the given angle.
        /// This ensures that the entire rotated image fits within the output bounds without clipping.
        ///
        /// Parameters:
        /// - `angle`: The rotation angle in radians.
        ///
        /// Returns:
        /// - A struct containing the optimal `rows` and `cols` for the rotated image.
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
                .cols = @intFromFloat(@ceil(new_w)),
                .rows = @intFromFloat(@ceil(new_h)),
            };
        }

        /// Rotates the image by `angle` (in radians) around its center.
        /// Returns a new image with optimal dimensions to fit the rotated content.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the rotated image's data.
        /// - `angle`: The rotation angle in radians.
        /// - `method`: The interpolation method to use for sampling pixels.
        pub fn rotate(self: Self, gpa: Allocator, angle: f32, method: Interpolation) !Self {
            const interpolation = @import("interpolation.zig");

            // Compute optimal bounds
            const bounds = rotateBounds(self, angle);
            const actual_rows = bounds.rows;
            const actual_cols = bounds.cols;

            // Get the image center
            const center = self.getCenter();

            // Normalize angle to [0, 2π) range
            const normalized_angle = @mod(angle, std.math.tau);
            const epsilon = 1e-6;

            // Fast paths for orthogonal rotations
            if (@abs(normalized_angle) < epsilon or @abs(normalized_angle - std.math.tau) < epsilon) {
                // 0° or 360°: just duplicate
                return try self.dupe(gpa);
            }

            if (@abs(normalized_angle - std.math.pi / 2.0) < epsilon) {
                // 90° counter-clockwise
                return rotate90CCW(self, gpa, actual_rows, actual_cols);
            }

            if (@abs(normalized_angle - std.math.pi) < epsilon) {
                // 180° - flip both axes
                return rotate180(self, gpa, actual_rows, actual_cols);
            }

            if (@abs(normalized_angle - 3.0 * std.math.pi / 2.0) < epsilon) {
                // 270° counter-clockwise (90° clockwise)
                return rotate270CCW(self, gpa, actual_rows, actual_cols);
            }

            // General rotation using inverse transformation (writes every pixel)
            var rotated = try Self.init(gpa, actual_rows, actual_cols);

            const cos = @cos(angle);
            const sin = @sin(angle);

            // For rotation around center, the offset is simply centering the image
            const offset_x = (@as(f32, @floatFromInt(actual_cols)) - @as(f32, @floatFromInt(self.cols))) / 2.0;
            const offset_y = (@as(f32, @floatFromInt(actual_rows)) - @as(f32, @floatFromInt(self.rows))) / 2.0;

            // The rotation center in output space
            const rotated_center_x = center.x() + offset_x;
            const rotated_center_y = center.y() + offset_y;

            for (0..actual_rows) |r| {
                const y: f32 = @floatFromInt(r);

                for (0..actual_cols) |c| {
                    const x: f32 = @floatFromInt(c);

                    // Apply inverse rotation around the center
                    const dx = x - rotated_center_x;
                    const dy = y - rotated_center_y;
                    const rotated_dx = cos * dx - sin * dy; // Inverse rotation (CCW)
                    const rotated_dy = sin * dx + cos * dy; // Inverse rotation (CCW)
                    const src_x = rotated_dx + center.x();
                    const src_y = rotated_dy + center.y();

                    rotated.at(r, c).* = if (interpolation.interpolate(T, self, src_x, src_y, method)) |val| val else std.mem.zeroes(T);
                }
            }

            return rotated;
        }

        /// Crops a rectangular region from the image.
        /// If the specified `rectangle` is not fully contained within the image, the out-of-bounds
        /// areas in the output are filled with zeroed pixels (e.g., black/transparent).
        /// Returns a new image containing the cropped region.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the cropped image's data.
        /// - `rectangle`: The `Rectangle(f32)` defining the region to crop. Coordinates will be rounded.
        pub fn crop(self: Self, allocator: Allocator, rectangle: Rectangle(f32)) !Self {
            const chip_top: isize = @intFromFloat(@round(rectangle.t));
            const chip_left: isize = @intFromFloat(@round(rectangle.l));
            const chip_rows: usize = @intFromFloat(@round(rectangle.height()));
            const chip_cols: usize = @intFromFloat(@round(rectangle.width()));

            const chip = try Self.init(allocator, chip_rows, chip_cols);
            copyRect(self, chip_top, chip_left, chip);
            return chip;
        }

        /// Extracts a rotated rectangular region from the image and resamples it into `out`.
        ///
        /// Parameters:
        /// - `rect`: Axis-aligned rectangle (in source image coordinates) defining the region before rotation.
        /// - `angle`: Rotation angle in radians (counter-clockwise) applied around `rect` center.
        /// - `out`: Pre-allocated destination image that defines the output size. The extracted content is
        ///          resampled to exactly fill this image using `method`.
        /// - `method`: Interpolation method used when sampling from the source.
        ///
        /// Notes:
        /// - Out-of-bounds samples are filled with zeroed pixels (e.g., black/transparent).
        /// - `out` can be a view; strides are respected via `at()` accessors.
        /// - Optimized fast path for axis-aligned crops when angle is 0 and dimensions match.
        pub fn extract(self: Self, rect: Rectangle(f32), angle: f32, out: Self, method: Interpolation) void {
            const interpolation = @import("interpolation.zig");

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
                const rect_top: isize = @intFromFloat(@round(rect.t));
                const rect_left: isize = @intFromFloat(@round(rect.l));
                copyRect(self, rect_top, rect_left, out);
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

                    out.at(r, c).* = if (interpolation.interpolate(T, self, src_x, src_y, method)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Inserts a source image into this image at the specified rectangle with rotation.
        ///
        /// This is the complement to `extract`. While `extract` pulls a region out of an image,
        /// `insert` places a source image into a destination region.
        ///
        /// Parameters:
        /// - `source`: The image to insert into self. Can be any Image type.
        /// - `rect`: Destination rectangle (in self's coordinates) where source will be placed.
        /// - `angle`: Rotation angle in radians (counter-clockwise) applied around `rect` center.
        /// - `method`: Interpolation method used when sampling from the source.
        /// - `blend_mode`: Blending mode to apply while inserting the image.
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
                const dst_top: isize = @intFromFloat(@round(rect.t));
                const dst_left: isize = @intFromFloat(@round(rect.l));
                for (0..source.rows) |r| {
                    const y: isize = dst_top + @as(isize, @intCast(r));
                    for (0..source.cols) |c| {
                        const x: isize = dst_left + @as(isize, @intCast(c));
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

            const min_r = if (cy - bound_hh < 0) 0 else @as(usize, @intFromFloat(@floor(cy - bound_hh)));
            const max_r = @min(self.rows, @as(usize, @intFromFloat(@ceil(cy + bound_hh))) + 1);
            const min_c = if (cx - bound_hw < 0) 0 else @as(usize, @intFromFloat(@floor(cx - bound_hw)));
            const max_c = @min(self.cols, @as(usize, @intFromFloat(@ceil(cx + bound_hw))) + 1);

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
                    if (interpolate(SourcePixelType, source, src_x, src_y, method)) |src_val| {
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

        /// Fast 90-degree counter-clockwise rotation.
        fn rotate90CCW(self: Self, gpa: Allocator, output_rows: usize, output_cols: usize) !Self {
            const offset_r = (output_rows -| self.cols) / 2;
            const offset_c = (output_cols -| self.rows) / 2;

            var rotated = try Self.init(gpa, output_rows, output_cols);

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = (self.cols - 1 - c) + offset_r;
                    const new_c = r + offset_c;
                    if (new_r < output_rows and new_c < output_cols) {
                        rotated.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            // Zero only padding bands if any
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(usize) = .init(offset_c, offset_r, offset_c + self.rows, offset_r + self.cols);
                rotated.setBorder(inner, std.mem.zeroes(T));
            }

            return rotated;
        }

        /// Fast 180-degree rotation.
        fn rotate180(self: Self, gpa: Allocator, output_rows: usize, output_cols: usize) !Self {
            const offset_r = (output_rows -| self.rows) / 2;
            const offset_c = (output_cols -| self.cols) / 2;

            var rotated = try Self.init(gpa, output_rows, output_cols);

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = (self.rows - 1 - r) + offset_r;
                    const new_c = (self.cols - 1 - c) + offset_c;
                    if (new_r < output_rows and new_c < output_cols) {
                        rotated.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(usize) = .init(offset_c, offset_r, offset_c + self.cols, offset_r + self.rows);
                rotated.setBorder(inner, std.mem.zeroes(T));
            }

            return rotated;
        }

        /// Fast 270-degree counter-clockwise rotation (90-degree clockwise).
        fn rotate270CCW(self: Self, gpa: Allocator, output_rows: usize, output_cols: usize) !Self {
            const offset_r = (output_rows -| self.cols) / 2;
            const offset_c = (output_cols -| self.rows) / 2;

            var rotated = try Self.init(gpa, output_rows, output_cols);

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = c + offset_r;
                    const new_c = (self.rows - 1 - r) + offset_c;
                    if (new_r < output_rows and new_c < output_cols) {
                        rotated.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
            if (offset_r != 0 or offset_c != 0) {
                const inner: Rectangle(usize) = .init(offset_c, offset_r, offset_c + self.rows, offset_r + self.cols);
                rotated.setBorder(inner, std.mem.zeroes(T));
            }

            return rotated;
        }

        /// Internal helper: copies a rectangular region into a pre-allocated output image.
        /// Used by both `crop` and `extract` (in fast-path).
        fn copyRect(self: Self, rect_top: isize, rect_left: isize, out: Self) void {
            for (0..out.rows) |r| {
                const ir: isize = @intCast(r);
                for (0..out.cols) |c| {
                    const ic: isize = @intCast(c);
                    out.at(r, c).* = if (self.atOrNull(ir + rect_top, ic + rect_left)) |val| val.* else std.mem.zeroes(T);
                }
            }
        }

        /// Applies a geometric transform to the image using backward mapping.
        /// For each pixel in the output, applies the transform to find the corresponding source pixel.
        pub fn warp(self: Self, allocator: Allocator, transform: anytype, method: Interpolation, out: *Self, out_rows: usize, out_cols: usize) !void {
            const Point = @import("../geometry/Point.zig").Point;
            const interpolation = @import("interpolation.zig");

            // Check if output needs allocation or reallocation
            const needs_alloc = (out.rows == 0 and out.cols == 0) or
                (out.rows != out_rows or out.cols != out_cols);

            if (needs_alloc) {
                if (out.rows > 0 and out.cols > 0 and out.isContiguous()) {
                    out.data = try allocator.realloc(out.data, out_rows * out_cols);
                    out.rows = out_rows;
                    out.cols = out_cols;
                    out.stride = out_cols;
                } else {
                    out.* = try Self.init(allocator, out_rows, out_cols);
                }
            }

            // Apply transform to each pixel in the output image
            for (0..out_rows) |r| {
                for (0..out_cols) |c| {
                    // Current pixel in output space
                    const out_point: Point(2, f32) = .init(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) });

                    // Transform to source image space using backward mapping
                    const src_point = transform.project(out_point);

                    // Sample from source image with interpolation
                    const value = interpolation.interpolate(T, self, src_point.x(), src_point.y(), method) orelse std.mem.zeroes(T);

                    // Write to output image
                    out.at(r, c).* = value;
                }
            }
        }
    };
}

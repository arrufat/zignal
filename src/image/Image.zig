//! This module defines a generic Image struct and provides a suite of image processing operations,
//! including initialization, manipulation (flipping, resizing, rotation, cropping),
//! filtering (integral image, box blur, sharpen, Sobel edge detection), and pixel access utilities.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const convertColor = @import("../color.zig").convertColor;
const Rectangle = @import("../geometry.zig").Rectangle;
const Point = @import("../geometry/Point.zig").Point;
const jpeg = @import("../jpeg.zig");
const as = @import("../meta.zig").as;
const isScalar = @import("../meta.zig").isScalar;
const png = @import("../png.zig");
const BorderMode = @import("filtering.zig").BorderMode;
const DisplayFormat = @import("display.zig").DisplayFormat;
const DisplayFormatter = @import("display.zig").DisplayFormatter;
const Filter = @import("filtering.zig").Filter;
const ImageFormat = @import("format.zig").ImageFormat;
const interpolation = @import("interpolation.zig");
const InterpolationMethod = interpolation.InterpolationMethod;
const PixelIterator = @import("PixelIterator.zig").PixelIterator;

/// A simple image struct that encapsulates the size and the data.
pub fn Image(comptime T: type) type {
    return struct {
        rows: usize,
        cols: usize,
        data: []T,
        stride: usize,

        const Self = @This();

        /// Creates an empty image with zero dimensions, used as a placeholder for output parameters.
        /// When passed to functions like `rotateFrom()`, `blurBox()`, etc., the function will
        /// automatically allocate and size the image appropriately. This eliminates the need
        /// to pre-allocate or guess output dimensions.
        ///
        /// Example usage:
        /// ```zig
        /// var rotated: Image(u8) = .empty;
        /// try image.rotateFrom(allocator, center, angle, &rotated); // Auto-sizes to optimal dimensions
        /// defer rotated.deinit(allocator);
        /// ```
        pub const empty: Self = .{ .rows = 0, .cols = 0, .data = undefined, .stride = 0 };

        /// Constructs an image of rows and cols size.  If the slice is owned by this image,
        /// deinit should also be called.
        pub fn init(rows: usize, cols: usize, data: []T) Image(T) {
            return .{ .rows = rows, .cols = cols, .data = data, .stride = cols };
        }

        /// Sets the image rows and cols to zero and frees the memory from the image.  It should
        /// only be called if the image owns the memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rows = 0;
            self.cols = 0;
            self.stride = 0;
            allocator.free(self.data);
        }

        /// Constructs an image of rows and cols size allocating its own memory.
        pub fn initAlloc(allocator: Allocator, rows: usize, cols: usize) !Image(T) {
            return .{ .rows = rows, .cols = cols, .data = try allocator.alloc(T, rows * cols), .stride = cols };
        }

        /// Constructs an image of `rows` and `cols` size by reinterpreting the provided slice of `bytes` as a slice of `T`.
        /// The length of the `bytes` slice must be exactly `rows * cols * @sizeOf(T)`.
        pub fn initFromBytes(rows: usize, cols: usize, bytes: []u8) Image(T) {
            assert(rows * cols * @sizeOf(T) == bytes.len);
            return .{
                .rows = rows,
                .cols = cols,
                .data = @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0 .. bytes.len / @sizeOf(T)],
                .stride = cols,
            };
        }

        /// Fills the entire image with a solid color using @memset.
        pub fn fill(self: Self, color: anytype) void {
            @memset(self.data, convertColor(T, color));
        }

        /// Returns the image data reinterpreted as a slice of bytes.
        /// Note: The image should not be a view; this is enforced by an assertion.
        pub fn asBytes(self: Self) []u8 {
            assert(self.rows * self.cols == self.data.len);
            assert(!self.isView());
            return @as([*]u8, @ptrCast(@alignCast(self.data.ptr)))[0 .. self.data.len * @sizeOf(T)];
        }

        /// Loads an image from a file with automatic format detection.
        /// Detects format based on file header signatures and calls the appropriate loader.
        ///
        /// Example usage:
        /// ```zig
        /// var img = try Image(Rgb).load(allocator, "photo.jpg");
        /// defer img.deinit(allocator);
        /// ```
        pub fn load(allocator: Allocator, file_path: []const u8) !Self {
            const image_format = try ImageFormat.detectFromPath(allocator, file_path) orelse return error.UnsupportedImageFormat;

            return switch (image_format) {
                .png => png.load(T, allocator, file_path),
                .jpeg => jpeg.load(T, allocator, file_path),
            };
        }

        /// Saves the image to a file in PNG format.
        /// Returns an error if the file path doesn't end in `.png` or `.PNG`.
        pub fn save(self: Self, allocator: Allocator, file_path: []const u8) !void {
            if (!std.mem.endsWith(u8, file_path, ".png") and !std.mem.endsWith(u8, file_path, ".PNG")) {
                return error.UnsupportedImageFormat;
            }
            try png.save(T, allocator, self, file_path);
        }

        /// Returns the total number of pixels in the image (rows * cols).
        pub inline fn size(self: Self) usize {
            return self.rows * self.cols;
        }

        /// Returns the number of channels or depth of this image type.
        pub fn channels() usize {
            return comptime switch (@typeInfo(T)) {
                .int, .float => 1,
                .@"struct" => std.meta.fields(T).len,
                .array => |info| info.len,
                else => @compileError("Image(" ++ @typeName(T) ++ " is unsupported."),
            };
        }

        /// Returns true if and only if `self` and `other` have the same number of rows and columns.
        /// It does not compare pixel data or types.
        pub fn hasSameShape(self: Self, other: anytype) bool {
            return self.rows == other.rows and self.cols == other.cols;
        }

        /// Returns the bounding rectangle for the current image.
        pub fn getRectangle(self: Self) Rectangle(usize) {
            return .{ .l = 0, .t = 0, .r = self.cols, .b = self.rows };
        }

        /// Returns the center point of the image as a Point(2, f32).
        /// This is commonly used as the rotation center for image rotation.
        ///
        /// Example usage:
        /// ```zig
        /// try image.rotate(allocator, image.getCenter(), angle, &rotated);
        /// ```
        pub fn getCenter(self: Self) Point(2, f32) {
            return .point(.{
                @as(f32, @floatFromInt(self.cols)) / 2.0,
                @as(f32, @floatFromInt(self.rows)) / 2.0,
            });
        }

        /// Returns an image view with boundaries defined by `rect` within the image boundaries.
        /// The returned image references the memory of `self`, so there are no allocations
        /// or copies.
        pub fn view(self: Self, rect: Rectangle(usize)) Image(T) {
            const bounded = Rectangle(usize){
                .l = rect.l,
                .t = rect.t,
                .r = @min(rect.r, self.cols),
                .b = @min(rect.b, self.rows),
            };
            return .{
                .rows = bounded.height(),
                .cols = bounded.width(),
                .data = self.data[bounded.t * self.stride + bounded.l .. (bounded.b - 1) * self.stride + bounded.r],
                .stride = self.cols,
            };
        }

        /// Returns true if, and only if, `self` is a view of another image.
        /// This is determined by checking if the `cols` field differs from the `stride` field.
        pub fn isView(self: Self) bool {
            return self.cols != self.stride;
        }

        /// Creates a duplicate of the image with newly allocated memory.
        /// Correctly handles views by copying only the visible data.
        ///
        /// Example usage:
        /// ```zig
        /// var duped = try image.dupe(allocator);
        /// defer duped.deinit(allocator);
        /// ```
        pub fn dupe(self: Self, allocator: Allocator) !Self {
            const result = try Self.initAlloc(allocator, self.rows, self.cols);
            self.copy(result);
            return result;
        }

        /// Copies image data from `self` to `dst`, correctly handling views.
        /// If src and dst are the same object, does nothing (no-op).
        /// Uses fast @memcpy when neither image is a view, falls back to row-by-row copying otherwise.
        pub fn copy(self: Self, dst: Self) void {
            if (self.data.ptr == dst.data.ptr) {
                return; // Same underlying data, nothing to copy
            }
            if (self.isView() or dst.isView()) {
                // Row-by-row copy for views
                for (0..self.rows) |r| {
                    const src_row_start = r * self.stride;
                    const dst_row_start = r * dst.stride;
                    @memcpy(
                        dst.data[dst_row_start .. dst_row_start + self.cols],
                        self.data[src_row_start .. src_row_start + self.cols],
                    );
                }
            } else {
                // Fast copy for non-views
                @memcpy(dst.data, self.data);
            }
        }

        /// Converts the image to a different pixel type.
        /// Allocates a new image with the target pixel type and converts each pixel using the color conversion system.
        ///
        /// Example usage:
        /// ```zig
        /// var rgba_image: Image(Rgba) = ...;
        /// var gray_image = try rgba_image.convert(u8, allocator);
        /// defer gray_image.deinit(allocator);
        /// ```
        pub fn convert(self: Self, comptime TargetType: type, allocator: Allocator) !Image(TargetType) {
            var result: Image(TargetType) = try .initAlloc(allocator, self.rows, self.cols);
            if (T == TargetType) {
                // For same type, we need to handle views properly
                if (self.stride == self.cols) {
                    // Contiguous data, can use memcpy
                    @memcpy(result.data, self.data);
                } else {
                    // Non-contiguous (view), copy row by row
                    var row: usize = 0;
                    while (row < self.rows) : (row += 1) {
                        const src_start = row * self.stride;
                        const dst_start = row * self.cols;
                        @memcpy(result.data[dst_start .. dst_start + self.cols], self.data[src_start .. src_start + self.cols]);
                    }
                }
            } else {
                // Different types, convert pixel by pixel
                var row: usize = 0;
                while (row < self.rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < self.cols) : (col += 1) {
                        const src_idx = row * self.stride + col;
                        const dst_idx = row * self.cols + col;
                        result.data[dst_idx] = convertColor(TargetType, self.data[src_idx]);
                    }
                }
            }
            return result;
        }

        /// Returns the value at position row, col.  It assumes the coordinates are in bounds and
        /// triggers safety-checked undefined behavior when they aren't.
        pub inline fn at(self: Self, row: usize, col: usize) *T {
            assert(row < self.rows);
            assert(col < self.cols);
            return &self.data[row * self.stride + col];
        }

        /// Returns the optional value at row, col in the image.
        pub fn atOrNull(self: Self, row: isize, col: isize) ?*T {
            const irows: isize = @intCast(self.rows);
            const icols: isize = @intCast(self.cols);
            if (row < 0 or col < 0 or row >= irows or col >= icols) {
                return null;
            } else {
                return self.at(@intCast(row), @intCast(col));
            }
        }

        /// Creates a formatter for terminal display with custom options.
        /// Provides fine-grained control over output format, palette modes, and dithering.
        /// Will still gracefully degrade from sixel to ANSI if needed.
        ///
        /// Display modes:
        /// - `.ansi_basic`: Uses background colors with spaces (universally compatible)
        /// - `.ansi_blocks`: Uses Unicode half-block characters for 2x vertical resolution (requires monospace font with U+2580 support)
        /// - `.braille`: Uses Braille patterns for 2x4 monochrome resolution (requires Unicode Braille support U+2800-U+28FF, converts to grayscale)
        /// - `.sixel`: Uses the sixel graphics protocol if supported
        /// - `.kitty`: Uses the kitty graphics protocol if supported
        /// - `.auto`: Automatically selects best available format: kitty -> sixek -> ansi_blocks
        ///
        /// Example:
        /// ```zig
        /// const img = try Image(Rgb).load(allocator, "test.png");
        /// std.debug.print("{f}", .{img.display(.ansi_basic)});     // Basic ANSI
        /// std.debug.print("{f}", .{img.display(.ansi_blocks)});    // 2x vertical resolution
        /// std.debug.print("{f}", .{img.display(.{ .braille = .{ .threshold = 0.5 } })}); // 2x4 monochrome
        /// std.debug.print("{f}", .{img.display(.{ .sixel = .{ .palette_mode = .adaptive } })});
        /// std.debug.print("{f}", .{img.display(.{ .kitty = .default })});  // Kitty graphics protocol
        /// ```
        pub fn display(self: *const Self, display_format: DisplayFormat) DisplayFormatter(T) {
            return DisplayFormatter(T){
                .image = self,
                .display_format = display_format,
            };
        }

        /// Formats the image using the best available terminal format.
        /// Automatically tries sixel with sensible defaults, falling back to ANSI blocks if needed.
        /// For explicit control over output format, use the display() method instead.
        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const type_name: []const u8 = @typeName(T);
            if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |pos| {
                try writer.print("Image({s}){{ .rows = {d}, .cols = {d} }}", .{ type_name[pos + 1 ..], self.rows, self.cols });
            } else {
                try writer.print("Image({s}){{ .rows = {d}, .cols = {d} }}", .{ type_name, self.rows, self.cols });
            }
        }

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

        /// Performs interpolation at position x, y using the specified method.
        /// Returns `null` if the coordinates are outside valid bounds for the chosen method.
        pub fn interpolate(self: Self, x: f32, y: f32, method: InterpolationMethod) ?T {
            return interpolation.interpolate(T, self, x, y, method);
        }

        /// Resizes an image to fit in out, using the specified interpolation method.
        pub fn resize(self: Self, allocator: Allocator, out: Self, method: InterpolationMethod) !void {
            try interpolation.resize(T, allocator, self, out, method);
        }

        /// Scales the image by the given factor using the specified interpolation method.
        /// A factor > 1.0 enlarges the image, < 1.0 shrinks it.
        /// The caller is responsible for calling deinit() on the returned image.
        pub fn scale(self: Self, allocator: Allocator, factor: f32, method: InterpolationMethod) !Self {
            if (factor <= 0) return error.InvalidScaleFactor;

            const new_rows = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(self.rows)) * factor)));
            const new_cols = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(self.cols)) * factor)));

            if (new_rows == 0 or new_cols == 0) return error.InvalidDimensions;

            const scaled = try Self.initAlloc(allocator, new_rows, new_cols);
            try self.resize(allocator, scaled, method);
            return scaled;
        }

        /// Resizes an image to fit within the output dimensions while preserving aspect ratio.
        /// The image is centered with black/zero padding around it (letterboxing).
        /// Returns a rectangle describing the area containing the actual image content.
        /// ```
        pub fn letterbox(self: Self, allocator: Allocator, out: *Self, method: InterpolationMethod) !Rectangle(usize) {
            // Ensure output has valid dimensions
            if (out.rows == 0 or out.cols == 0) {
                return error.InvalidDimensions;
            }

            // Allocate output if not already allocated
            if (out.data.len == 0) {
                out.* = try .initAlloc(allocator, out.rows, out.cols);
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
                try self.resize(allocator, out.*, method);
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

            // Fill output with zeros (black/transparent padding)
            @memset(out.data, std.mem.zeroes(T));

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
            try self.resize(allocator, output_view, method);

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
        pub fn rotateBounds(self: Self, angle: f32) struct { rows: usize, cols: usize } {
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
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the rotated image's data.
        /// - `angle`: The rotation angle in radians.
        /// - `method`: The interpolation method to use for sampling pixels.
        /// - `rotated`: An out-parameter pointer to an `Image(T)` that will be initialized by this function
        ///   with the rotated image data. If `rotated.rows` and `rotated.cols` are both 0, optimal
        ///   dimensions will be computed automatically. The caller is responsible for deallocating
        ///   `rotated.data` if it was allocated by this function.
        pub fn rotate(self: Self, gpa: Allocator, angle: f32, method: InterpolationMethod, rotated: *Self) !void {
            // Auto-compute optimal bounds if dimensions are 0
            const actual_rows, const actual_cols = if (rotated.rows == 0 and rotated.cols == 0) blk: {
                const bounds = self.rotateBounds(angle);
                break :blk .{ bounds.rows, bounds.cols };
            } else .{ rotated.rows, rotated.cols };

            // Get the image center
            const center = self.getCenter();

            // Normalize angle to [0, 2π) range
            const normalized_angle = @mod(angle, std.math.tau);
            const epsilon = 1e-6;

            // Fast paths for orthogonal rotations
            if (@abs(normalized_angle) < epsilon or @abs(normalized_angle - std.math.tau) < epsilon) {
                // 0° or 360° - copy
                var array: std.ArrayList(T) = .empty;
                try array.resize(gpa, actual_rows * actual_cols);
                rotated.* = .init(actual_rows, actual_cols, try array.toOwnedSlice(gpa));

                const offset_r = (actual_rows -| self.rows) / 2;
                const offset_c = (actual_cols -| self.cols) / 2;

                for (rotated.data) |*pixel| pixel.* = std.mem.zeroes(T);
                for (0..@min(self.rows, actual_rows)) |r| {
                    for (0..@min(self.cols, actual_cols)) |c| {
                        if (r + offset_r < actual_rows and c + offset_c < actual_cols) {
                            rotated.at(r + offset_r, c + offset_c).* = self.at(r, c).*;
                        }
                    }
                }
                return;
            }

            if (@abs(normalized_angle - std.math.pi / 2.0) < epsilon) {
                // 90° counter-clockwise
                return self.rotate90CCW(gpa, actual_rows, actual_cols, rotated);
            }

            if (@abs(normalized_angle - std.math.pi) < epsilon) {
                // 180° - flip both axes
                return self.rotate180(gpa, actual_rows, actual_cols, rotated);
            }

            if (@abs(normalized_angle - 3.0 * std.math.pi / 2.0) < epsilon) {
                // 270° counter-clockwise (90° clockwise)
                return self.rotate270CCW(gpa, actual_rows, actual_cols, rotated);
            }

            // General rotation using inverse transformation
            var array: std.ArrayList(T) = .empty;
            try array.resize(gpa, actual_rows * actual_cols);
            rotated.* = .init(actual_rows, actual_cols, try array.toOwnedSlice(gpa));

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

                    rotated.at(r, c).* = if (self.interpolate(src_x, src_y, method)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Fast 90-degree counter-clockwise rotation.
        fn rotate90CCW(self: Self, gpa: Allocator, output_rows: usize, output_cols: usize, rotated: *Self) !void {
            var array: std.ArrayList(T) = .empty;
            try array.resize(gpa, output_rows * output_cols);
            rotated.* = .init(output_rows, output_cols, try array.toOwnedSlice(gpa));

            for (rotated.data) |*pixel| pixel.* = std.mem.zeroes(T);

            const offset_r = (output_rows -| self.cols) / 2;
            const offset_c = (output_cols -| self.rows) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = (self.cols - 1 - c) + offset_r;
                    const new_c = r + offset_c;
                    if (new_r < output_rows and new_c < output_cols) {
                        rotated.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
        }

        /// Fast 180-degree rotation.
        fn rotate180(self: Self, gpa: Allocator, output_rows: usize, output_cols: usize, rotated: *Self) !void {
            var array: std.ArrayList(T) = .empty;
            try array.resize(gpa, output_rows * output_cols);
            rotated.* = .init(output_rows, output_cols, try array.toOwnedSlice(gpa));

            for (rotated.data) |*pixel| pixel.* = std.mem.zeroes(T);

            const offset_r = (output_rows -| self.rows) / 2;
            const offset_c = (output_cols -| self.cols) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = (self.rows - 1 - r) + offset_r;
                    const new_c = (self.cols - 1 - c) + offset_c;
                    if (new_r < output_rows and new_c < output_cols) {
                        rotated.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
        }

        /// Fast 270-degree counter-clockwise rotation (90-degree clockwise).
        fn rotate270CCW(self: Self, gpa: Allocator, output_rows: usize, output_cols: usize, rotated: *Self) !void {
            var array: std.ArrayList(T) = .empty;
            try array.resize(gpa, output_rows * output_cols);
            rotated.* = .init(output_rows, output_cols, try array.toOwnedSlice(gpa));

            for (rotated.data) |*pixel| pixel.* = std.mem.zeroes(T);

            const offset_r = (output_rows -| self.cols) / 2;
            const offset_c = (output_cols -| self.rows) / 2;

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const new_r = c + offset_r;
                    const new_c = (self.rows - 1 - r) + offset_c;
                    if (new_r < output_rows and new_c < output_cols) {
                        rotated.at(new_r, new_c).* = self.at(r, c).*;
                    }
                }
            }
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

        /// Crops a rectangular region from the image.
        /// If the specified `rectangle` is not fully contained within the image, the out-of-bounds
        /// areas in the output `chip` are filled with zeroed pixels (e.g., black/transparent).
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the cropped image's data.
        /// - `rectangle`: The `Rectangle(f32)` defining the region to crop. Coordinates will be rounded.
        /// - `chip`: An out-parameter pointer to an `Image(T)` that will be initialized by this function
        ///   with the cropped image data. The caller is responsible for deallocating `chip.data`.
        pub fn crop(self: Self, allocator: Allocator, rectangle: Rectangle(f32), chip: *Self) !void {
            const chip_top: isize = @intFromFloat(@round(rectangle.t));
            const chip_left: isize = @intFromFloat(@round(rectangle.l));
            const chip_rows: usize = @intFromFloat(@round(rectangle.height()));
            const chip_cols: usize = @intFromFloat(@round(rectangle.width()));
            chip.* = try .initAlloc(allocator, chip_rows, chip_cols);
            self.copyRect(chip_top, chip_left, chip.*);
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
        pub fn extract(self: Self, rect: Rectangle(f32), angle: f32, out: Self, method: InterpolationMethod) void {
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
                self.copyRect(rect_top, rect_left, out);
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

                    out.at(r, c).* = if (self.interpolate(src_x, src_y, method)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Inserts a source image into this image at the specified rectangle with rotation.
        ///
        /// This is the complement to `extract`. While `extract` pulls a region out of an image,
        /// `insert` places a source image into a destination region.
        ///
        /// Parameters:
        /// - `source`: The image to insert into self.
        /// - `rect`: Destination rectangle (in self's coordinates) where source will be placed.
        /// - `angle`: Rotation angle in radians (counter-clockwise) applied around `rect` center.
        /// - `method`: Interpolation method used when sampling from the source.
        ///
        /// Notes:
        /// - The source image is scaled to fit the destination rectangle.
        /// - Pixels outside the source bounds are not modified in self.
        /// - This method mutates self in-place.
        pub fn insert(self: *Self, source: Self, rect: Rectangle(f32), angle: f32, method: InterpolationMethod) void {
            if (source.rows == 0 or source.cols == 0) return;

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
                            dest.* = source.at(r, c).*;
                        }
                    }
                }
                return;
            }

            // General path with rotation/scaling
            const cx = (rect.l + rect.r) * 0.5;
            const cy = (rect.t + rect.b) * 0.5;
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);

            // Pre-compute for efficiency
            const inv_width = 1.0 / rect_width;
            const inv_height = 1.0 / rect_height;
            const half_width = rect_width * 0.5;
            const half_height = rect_height * 0.5;

            // Exact bounding box of rotated rectangle
            const abs_cos = @abs(cos_a);
            const abs_sin = @abs(sin_a);
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
                    const rect_x = cos_a * dx + sin_a * dy;
                    const rect_y = -sin_a * dx + cos_a * dy;

                    // Check if inside rectangle (simplified bounds check)
                    if (@abs(rect_x) > half_width or @abs(rect_y) > half_height) continue;

                    // Map to normalized [0,1] coordinates
                    const norm_x = (rect_x + half_width) * inv_width;
                    const norm_y = (rect_y + half_height) * inv_height;

                    // Map to source image coordinates
                    const src_x = if (source.cols == 1) 0 else norm_x * (fcols - 1);
                    const src_y = if (source.rows == 1) 0 else norm_y * (frows - 1);

                    // Sample and write
                    if (source.interpolate(src_x, src_y, method)) |val| {
                        self.at(r, c).* = val;
                    }
                }
            }
        }

        /// Computes the integral image, also known as a summed-area table (SAT), of `self`.
        /// For multi-channel images (e.g., structs like `Rgba`), it computes a per-channel
        /// integral image, storing the result as an array of floats per pixel in the output `integral` image.
        /// Uses SIMD optimizations for improved performance with a two-pass approach.
        pub fn integral(
            self: Self,
            allocator: Allocator,
            sat: *Image(if (isScalar(T)) f32 else [Self.channels()]f32),
        ) !void {
            return Filter(T).integral(self, allocator, sat);
        }

        /// Computes a blurred version of `self` using a box blur algorithm, efficiently implemented
        /// using an integral image. The `radius` parameter determines the size of the box window.
        /// This function is optimized using SIMD instructions for performance where applicable.
        pub fn boxBlur(self: Self, allocator: Allocator, blurred: *Self, radius: usize) !void {
            return Filter(T).boxBlur(self, allocator, blurred, radius);
        }

        /// Computes a sharpened version of `self` by enhancing edges.
        /// It uses the formula `sharpened = 2 * original - blurred`, where `blurred` is a box-blurred
        /// version of the original image (calculated efficiently using an integral image).
        /// The `radius` parameter controls the size of the blur. This operation effectively
        /// increases the contrast at edges. SIMD optimizations are used for performance where applicable.
        pub fn sharpen(self: Self, allocator: Allocator, sharpened: *Self, radius: usize) !void {
            return Filter(T).sharpen(self, allocator, sharpened, radius);
        }

        /// Applies a 2D convolution with the given kernel to the image.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
        /// - `kernel`: A 2D array representing the convolution kernel.
        /// - `out`: An out-parameter pointer to an `Image(T)` that will be filled with the convolved image.
        /// - `border_mode`: How to handle pixels at the image borders.
        pub fn convolve(self: Self, allocator: Allocator, kernel: anytype, out: *Self, border_mode: BorderMode) !void {
            return Filter(T).convolve(self, allocator, kernel, out, border_mode);
        }

        /// Performs separable convolution using two 1D kernels (horizontal and vertical).
        /// This is much more efficient for separable filters like Gaussian blur.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `kernel_x`: Horizontal (column) kernel.
        /// - `kernel_y`: Vertical (row) kernel.
        /// - `out`: Output image.
        /// - `border_mode`: How to handle image borders.
        pub fn convolveSeparable(self: Self, allocator: Allocator, kernel_x: []const f32, kernel_y: []const f32, out: *Self, border_mode: BorderMode) !void {
            return Filter(T).convolveSeparable(self, allocator, kernel_x, kernel_y, out, border_mode);
        }

        /// Applies Gaussian blur to the image using separable convolution.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma`: Standard deviation of the Gaussian kernel.
        /// - `out`: Output blurred image.
        pub fn gaussianBlur(self: Self, allocator: Allocator, sigma: f32, out: *Self) !void {
            return Filter(T).gaussianBlur(self, allocator, sigma, out);
        }

        /// Applies Difference of Gaussians (DoG) band-pass filter to the image.
        /// This efficiently computes the difference between two Gaussian blurs with different sigmas,
        /// which acts as a band-pass filter and is commonly used for edge detection and feature enhancement.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma1`: Standard deviation of the first (typically smaller) Gaussian kernel.
        /// - `sigma2`: Standard deviation of the second (typically larger) Gaussian kernel.
        /// - `out`: Output image containing the difference.
        ///
        /// The result is computed as: gaussian_blur(sigma1) - gaussian_blur(sigma2)
        /// For edge detection, typically sigma2 ≈ 1.6 * sigma1
        pub fn differenceOfGaussians(self: Self, allocator: Allocator, sigma1: f32, sigma2: f32, out: *Self) !void {
            return Filter(T).differenceOfGaussians(self, allocator, sigma1, sigma2, out);
        }

        /// Applies the Sobel filter to `self` to perform edge detection.
        /// The output is a grayscale image representing the magnitude of gradients at each pixel.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
        /// - `out`: An out-parameter pointer to an `Image(u8)` that will be filled with the Sobel magnitude image.
        pub fn sobel(self: Self, allocator: Allocator, out: *Image(u8)) !void {
            return Filter(T).sobel(self, allocator, out);
        }

        /// Calculates the Peak Signal-to-Noise Ratio (PSNR) between two images.
        /// PSNR is a measure of image quality, with higher values indicating better quality.
        /// Returns inf when images are identical (MSE = 0).
        ///
        /// Returns an error if the images have different dimensions.
        ///
        /// The calculation is type-agnostic and works with any pixel type:
        /// - Scalars (u8, f32, etc.)
        /// - Structs (Rgb, Rgba, etc.)
        /// - Arrays ([3]u8, [4]f32, etc.)
        pub fn psnr(self: Self, other: Self) !f64 {
            // Check dimensions match
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }

            var mse: f64 = 0.0;
            var component_count: usize = 0;

            // Calculate MSE across all pixels and components
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const pixel1 = self.at(r, c).*;
                    const pixel2 = other.at(r, c).*;

                    switch (@typeInfo(T)) {
                        .int, .float => {
                            // Scalar types
                            const val1: f64 = switch (@typeInfo(T)) {
                                .int => @floatFromInt(pixel1),
                                .float => @floatCast(pixel1),
                                else => unreachable,
                            };
                            const val2: f64 = switch (@typeInfo(T)) {
                                .int => @floatFromInt(pixel2),
                                .float => @floatCast(pixel2),
                                else => unreachable,
                            };
                            const diff = val1 - val2;
                            mse += diff * diff;
                            component_count += 1;
                        },
                        .@"struct" => {
                            // Struct types (Rgb, Rgba, etc.)
                            inline for (std.meta.fields(T)) |field| {
                                const val1 = @field(pixel1, field.name);
                                const val2 = @field(pixel2, field.name);
                                const f1: f64 = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(val1),
                                    .float => @floatCast(val1),
                                    else => @compileError("Unsupported field type in struct for PSNR"),
                                };
                                const f2: f64 = switch (@typeInfo(field.type)) {
                                    .int => @floatFromInt(val2),
                                    .float => @floatCast(val2),
                                    else => @compileError("Unsupported field type in struct for PSNR"),
                                };
                                const diff = f1 - f2;
                                mse += diff * diff;
                                component_count += 1;
                            }
                        },
                        .array => |array_info| {
                            // Array types ([3]u8, [4]f32, etc.)
                            for (0..array_info.len) |i| {
                                const val1 = pixel1[i];
                                const val2 = pixel2[i];
                                const f1: f64 = switch (@typeInfo(array_info.child)) {
                                    .int => @floatFromInt(val1),
                                    .float => @floatCast(val1),
                                    else => @compileError("Unsupported array element type for PSNR"),
                                };
                                const f2: f64 = switch (@typeInfo(array_info.child)) {
                                    .int => @floatFromInt(val2),
                                    .float => @floatCast(val2),
                                    else => @compileError("Unsupported array element type for PSNR"),
                                };
                                const diff = f1 - f2;
                                mse += diff * diff;
                                component_count += 1;
                            }
                        },
                        else => @compileError("Unsupported pixel type for PSNR: " ++ @typeName(T)),
                    }
                }
            }

            // Calculate average MSE
            mse = mse / @as(f64, @floatFromInt(component_count));

            // If MSE is 0, images are identical
            if (mse == 0.0) {
                return std.math.inf(f64);
            }

            // Determine MAX value based on the component type
            const max_val: f64 = blk: {
                const component_type = switch (@typeInfo(T)) {
                    .int, .float => T,
                    .@"struct" => std.meta.fields(T)[0].type, // Use first field type
                    .array => |array_info| array_info.child,
                    else => unreachable,
                };

                break :blk switch (@typeInfo(component_type)) {
                    .int => |int_info| if (int_info.signedness == .unsigned)
                        @floatFromInt(std.math.maxInt(component_type))
                    else
                        @compileError("Signed integers not supported for PSNR"),
                    .float => 1.0, // Assume normalized [0, 1] for float types
                    else => unreachable,
                };
            };

            // Calculate PSNR: 20 * log10(MAX) - 10 * log10(MSE)
            return 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse);
        }

        /// Returns an iterator over all pixels in the image
        pub fn pixels(self: Self) PixelIterator(T) {
            return .{
                .data = self.data,
                .cols = self.cols,
                .stride = self.stride,
                .rows = self.rows,
            };
        }
    };
}

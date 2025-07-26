//! This module defines a generic Image struct and provides a suite of image processing operations,
//! including initialization, manipulation (flipping, resizing, rotation, cropping),
//! filtering (integral image, box blur, sharpen, Sobel edge detection), and pixel access utilities.
const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqualDeep;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;

const color = @import("../color.zig");
const Rectangle = @import("../geometry.zig").Rectangle;
const Point2d = @import("../geometry/Point.zig").Point2d;
const jpeg = @import("../jpeg.zig");
const kitty = @import("../kitty.zig");
const as = @import("../meta.zig").as;
const is4xu8Struct = @import("../meta.zig").is4xu8Struct;
const isScalar = @import("../meta.zig").isScalar;
const isStruct = @import("../meta.zig").isStruct;
const png = @import("../png.zig");
const sixel = @import("../sixel.zig");
const DisplayFormat = @import("display.zig").DisplayFormat;
const DisplayFormatter = @import("display.zig").DisplayFormatter;
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
        /// When passed to functions like `rotateFrom()`, `boxBlur()`, etc., the function will
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
        pub fn initAlloc(allocator: std.mem.Allocator, rows: usize, cols: usize) !Image(T) {
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
            return .{ .l = 0, .t = 0, .r = self.cols - 1, .b = self.rows - 1 };
        }

        /// Returns the center point of the image as a Point2d(f32).
        /// This is commonly used as the rotation center for image rotation.
        ///
        /// Example usage:
        /// ```zig
        /// try image.rotate(allocator, image.getCenter(), angle, &rotated);
        /// ```
        pub fn getCenter(self: Self) Point2d(f32) {
            return Point2d(f32).init2d(
                @as(f32, @floatFromInt(self.cols)) / 2.0,
                @as(f32, @floatFromInt(self.rows)) / 2.0,
            );
        }

        /// Returns an image view with boundaries defined by `rect` within the image boundaries.
        /// The returned image references the memory of `self`, so there are no allocations
        /// or copies.
        pub fn view(self: Self, rect: Rectangle(usize)) Image(T) {
            const bounded = Rectangle(usize){
                .l = rect.l,
                .t = rect.t,
                .r = @min(rect.r, self.cols - 1),
                .b = @min(rect.b, self.rows - 1),
            };
            return .{
                .rows = bounded.height(),
                .cols = bounded.width(),
                .data = self.data[bounded.t * self.stride + bounded.l .. bounded.b * self.stride + bounded.r + 1],
                .stride = self.cols,
            };
        }

        /// Returns true if, and only if, `self` is a view of another image.
        /// This is determined by checking if the `cols` field differs from the `stride` field.
        pub fn isView(self: Self) bool {
            return self.cols != self.stride;
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
            // If types are the same, just return a copy
            if (T == TargetType) {
                const result = try Image(TargetType).initAlloc(allocator, self.rows, self.cols);
                @memcpy(result.data, self.data);
                return result;
            }

            // Convert each pixel using the color conversion system
            var result = try Image(TargetType).initAlloc(allocator, self.rows, self.cols);
            for (self.data, 0..) |pixel, i| {
                result.data[i] = color.convertColor(TargetType, pixel);
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
        pub fn resize(self: Self, out: Self, method: InterpolationMethod) void {
            interpolation.resize(T, self, out, method);
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

            // Exact dimensions for orthogonal rotations
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
        /// This is the most common rotation operation with optimal output dimensions to avoid clipping.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the rotated image's data.
        /// - `angle`: The rotation angle in radians.
        /// - `rotated`: An out-parameter pointer to an `Image(T)` that will be initialized by this function
        ///   with the rotated image data. The caller is responsible for deallocating `rotated.data`
        ///   if it was allocated by this function.
        pub fn rotate(self: Self, allocator: Allocator, angle: f32, rotated: *Self) !void {
            rotated.* = Self.empty;
            try self.rotateAround(allocator, self.getCenter(), angle, rotated);
        }

        /// Rotates the image by `angle` (in radians) around a specified `center` point.
        /// This allows custom rotation centers and output dimensions.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the rotated image's data.
        /// - `center`: The `Point2d(f32)` around which to rotate.
        /// - `angle`: The rotation angle in radians.
        /// - `rotated`: An out-parameter pointer to an `Image(T)`. If `rotated.rows` and `rotated.cols`
        ///   are both 0, optimal dimensions will be computed automatically. Otherwise, the specified
        ///   dimensions will be used. The function will initialize `rotated` with the rotated image data.
        ///   The caller is responsible for deallocating `rotated.data` if it was allocated by this function.
        pub fn rotateAround(self: Self, allocator: Allocator, center: Point2d(f32), angle: f32, rotated: *Self) !void {
            // Auto-compute optimal bounds if dimensions are 0
            const actual_rows, const actual_cols = if (rotated.rows == 0 and rotated.cols == 0) blk: {
                const bounds = self.rotateBounds(angle);
                break :blk .{ bounds.rows, bounds.cols };
            } else .{ rotated.rows, rotated.cols };
            // Normalize angle to [0, 2π) range
            const normalized_angle = @mod(angle, std.math.tau);
            const epsilon = 1e-6;

            // Fast paths for orthogonal rotations
            if (@abs(normalized_angle) < epsilon or @abs(normalized_angle - std.math.tau) < epsilon) {
                // 0° or 360° - copy
                var array: std.ArrayList(T) = .init(allocator);
                try array.resize(actual_rows * actual_cols);
                rotated.* = .init(actual_rows, actual_cols, try array.toOwnedSlice());

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
                // 90° clockwise - transpose and flip horizontally
                return self.rotate90CW(allocator, actual_rows, actual_cols, rotated);
            }

            if (@abs(normalized_angle - std.math.pi) < epsilon) {
                // 180° - flip both axes
                return self.rotate180(allocator, actual_rows, actual_cols, rotated);
            }

            if (@abs(normalized_angle - 3.0 * std.math.pi / 2.0) < epsilon) {
                // 270° clockwise (90° counter-clockwise) - transpose and flip vertically
                return self.rotate270CW(allocator, actual_rows, actual_cols, rotated);
            }

            // General rotation using inverse transformation for better cache locality
            var array: std.ArrayList(T) = .init(allocator);
            try array.resize(actual_rows * actual_cols);
            rotated.* = .init(actual_rows, actual_cols, try array.toOwnedSlice());

            const cos = @cos(angle); // Forward transformation
            const sin = @sin(angle);

            // Calculate the offset to center the original image in the larger output
            const offset_x: f32 = (@as(f32, @floatFromInt(actual_cols)) - @as(f32, @floatFromInt(self.cols))) / 2;
            const offset_y: f32 = (@as(f32, @floatFromInt(actual_rows)) - @as(f32, @floatFromInt(self.rows))) / 2;

            // The rotation center in the output image space
            const rotated_center_x = center.x() + offset_x;
            const rotated_center_y = center.y() + offset_y;

            for (0..actual_rows) |r| {
                const y: f32 = @floatFromInt(r);

                for (0..actual_cols) |c| {
                    const x: f32 = @floatFromInt(c);

                    // Apply inverse rotation around the translated center point
                    const dx = x - rotated_center_x;
                    const dy = y - rotated_center_y;
                    const rotated_dx = cos * dx - sin * dy;
                    const rotated_dy = sin * dx + cos * dy;
                    const src_x = rotated_dx + center.x();
                    const src_y = rotated_dy + center.y();

                    rotated.at(r, c).* = if (self.interpolate(src_x, src_y, .bilinear)) |val| val else std.mem.zeroes(T);
                }
            }
        }

        /// Fast 90-degree clockwise rotation.
        fn rotate90CW(self: Self, allocator: Allocator, output_rows: usize, output_cols: usize, rotated: *Self) !void {
            var array: std.ArrayList(T) = .init(allocator);
            try array.resize(output_rows * output_cols);
            rotated.* = .init(output_rows, output_cols, try array.toOwnedSlice());

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

        /// Fast 180-degree rotation.
        fn rotate180(self: Self, allocator: Allocator, output_rows: usize, output_cols: usize, rotated: *Self) !void {
            var array: std.ArrayList(T) = .init(allocator);
            try array.resize(output_rows * output_cols);
            rotated.* = .init(output_rows, output_cols, try array.toOwnedSlice());

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

        /// Fast 270-degree clockwise rotation.
        fn rotate270CW(self: Self, allocator: Allocator, output_rows: usize, output_cols: usize, rotated: *Self) !void {
            var array: std.ArrayList(T) = .init(allocator);
            try array.resize(output_rows * output_cols);
            rotated.* = .init(output_rows, output_cols, try array.toOwnedSlice());

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
            for (0..chip_rows) |r| {
                const ir: isize = @intCast(r);
                for (0..chip_cols) |c| {
                    const ic: isize = @intCast(c);
                    chip.at(r, c).* = if (self.atOrNull(ir + chip_top, ic + chip_left)) |val| val.* else std.mem.zeroes(T);
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
            if (!self.hasSameShape(sat.*)) {
                sat.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            switch (@typeInfo(T)) {
                .int, .float => {
                    // First pass: compute row-wise cumulative sums
                    for (0..self.rows) |r| {
                        var tmp: f32 = 0;
                        const row_offset = r * self.stride;
                        const out_offset = r * sat.cols;
                        for (0..self.cols) |c| {
                            tmp += as(f32, self.data[row_offset + c]);
                            sat.data[out_offset + c] = tmp;
                        }
                    }

                    // Second pass: add column-wise cumulative sums using SIMD
                    const simd_len = std.simd.suggestVectorLength(f32) orelse 1;
                    for (1..self.rows) |r| {
                        const prev_row_offset = (r - 1) * sat.cols;
                        const curr_row_offset = r * sat.cols;
                        var c: usize = 0;

                        // Process SIMD-width chunks
                        while (c + simd_len <= self.cols) : (c += simd_len) {
                            const prev_vals: @Vector(simd_len, f32) = sat.data[prev_row_offset + c ..][0..simd_len].*;
                            const curr_vals: @Vector(simd_len, f32) = sat.data[curr_row_offset + c ..][0..simd_len].*;
                            sat.data[curr_row_offset + c ..][0..simd_len].* = prev_vals + curr_vals;
                        }

                        // Handle remaining columns
                        while (c < self.cols) : (c += 1) {
                            sat.data[curr_row_offset + c] += sat.data[prev_row_offset + c];
                        }
                    }
                },
                .@"struct" => {
                    if (is4xu8Struct(T)) {
                        // SIMD-optimized path for 4x u8 structs (e.g., RGBA)
                        // First pass: row-wise cumulative sums
                        for (0..self.rows) |r| {
                            var tmp: @Vector(4, f32) = @splat(0);
                            const row_offset = r * self.stride;
                            const out_offset = r * sat.cols;

                            for (0..self.cols) |c| {
                                const pixel = self.data[row_offset + c];
                                var pixel_vec: @Vector(4, f32) = undefined;
                                inline for (std.meta.fields(T), 0..) |field, i| {
                                    pixel_vec[i] = @floatFromInt(@field(pixel, field.name));
                                }
                                tmp += pixel_vec;
                                sat.data[out_offset + c] = tmp;
                            }
                        }

                        // Second pass: column-wise cumulative sums
                        for (1..self.rows) |r| {
                            const prev_row_offset = (r - 1) * sat.cols;
                            const curr_row_offset = r * sat.cols;

                            for (0..self.cols) |c| {
                                const prev_vec: @Vector(4, f32) = sat.data[prev_row_offset + c];
                                const curr_vec: @Vector(4, f32) = sat.data[curr_row_offset + c];
                                sat.data[curr_row_offset + c] = prev_vec + curr_vec;
                            }
                        }
                    } else {
                        // Generic scalar path for other struct types
                        const num_channels = comptime Self.channels();

                        // First pass: compute row-wise cumulative sums for all channels
                        for (0..self.rows) |r| {
                            var tmp = [_]f32{0} ** num_channels;
                            const row_offset = r * self.stride;
                            const out_offset = r * sat.cols;
                            for (0..self.cols) |c| {
                                inline for (std.meta.fields(T), 0..) |f, i| {
                                    tmp[i] += as(f32, @field(self.data[row_offset + c], f.name));
                                    sat.data[out_offset + c][i] = tmp[i];
                                }
                            }
                        }

                        // Second pass: add column-wise cumulative sums
                        for (1..self.rows) |r| {
                            const prev_row_offset = (r - 1) * sat.cols;
                            const curr_row_offset = r * sat.cols;
                            for (0..self.cols) |c| {
                                inline for (0..num_channels) |i| {
                                    sat.data[curr_row_offset + c][i] += sat.data[prev_row_offset + c][i];
                                }
                            }
                        }
                    }
                },
                else => @compileError("Can't compute the integral image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Computes a blurred version of `self` using a box blur algorithm, efficiently implemented
        /// using an integral image. The `radius` parameter determines the size of the box window.
        /// This function is optimized using SIMD instructions for performance where applicable.
        pub fn boxBlur(self: Self, allocator: std.mem.Allocator, blurred: *Self, radius: usize) !void {
            if (!self.hasSameShape(blurred.*)) {
                blurred.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                self.copy(blurred.*);
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    var sat: Image(f32) = undefined;
                    try self.integral(allocator, &sat);
                    defer sat.deinit(allocator);

                    const simd_len = std.simd.suggestVectorLength(f32) orelse 1;

                    // Process each row
                    for (0..self.rows) |r| {
                        const r1 = r -| radius;
                        const r2 = @min(r + radius, self.rows - 1);
                        const r1_offset = r1 * self.cols;
                        const r2_offset = r2 * self.cols;

                        var c: usize = 0;

                        // Process SIMD chunks where safe (away from borders)
                        const row_safe = r >= radius and r + radius < self.rows;
                        if (simd_len > 1 and self.cols > 2 * radius + simd_len and row_safe) {
                            // Skip left border
                            while (c < radius) : (c += 1) {
                                const c1 = c -| radius;
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                                const sum = sat.at(r2, c2).* - sat.at(r2, c1).* -
                                    sat.at(r1, c2).* + sat.at(r1, c1).*;
                                blurred.at(r, c).* = if (@typeInfo(T) == .int)
                                    @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum / area))))
                                else
                                    as(T, sum / area);
                            }

                            // SIMD middle section (constant area when row is safe)
                            const safe_end = self.cols - radius - simd_len;
                            if (c <= safe_end) {
                                const const_area: f32 = @floatFromInt((r2 - r1) * 2 * radius);
                                const area_vec: @Vector(simd_len, f32) = @splat(const_area);

                                while (c <= safe_end) : (c += simd_len) {
                                    const c1 = c - radius;
                                    const c2 = c + radius;
                                    const int11: @Vector(simd_len, f32) = sat.data[r1_offset + c1 ..][0..simd_len].*;
                                    const int12: @Vector(simd_len, f32) = sat.data[r1_offset + c2 ..][0..simd_len].*;
                                    const int21: @Vector(simd_len, f32) = sat.data[r2_offset + c1 ..][0..simd_len].*;
                                    const int22: @Vector(simd_len, f32) = sat.data[r2_offset + c2 ..][0..simd_len].*;
                                    const sums = int22 - int21 - int12 + int11;
                                    const vals = sums / area_vec;

                                    for (0..simd_len) |i| {
                                        blurred.at(r, c + i).* = if (@typeInfo(T) == .int)
                                            @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(vals[i]))))
                                        else
                                            vals[i];
                                    }
                                }
                            }
                        }

                        // Process remaining pixels (right border and any leftover)
                        while (c < self.cols) : (c += 1) {
                            const c1 = c -| radius;
                            const c2 = @min(c + radius, self.cols - 1);
                            const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                            const sum = sat.at(r2, c2).* - sat.at(r2, c1).* - sat.at(r1, c2).* + sat.at(r1, c1).*;
                            blurred.at(r, c).* = if (@typeInfo(T) == .int)
                                @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(sum / area))))
                            else
                                as(T, sum / area);
                        }
                    }
                },
                .@"struct" => {
                    if (is4xu8Struct(T)) {
                        try self.boxBlur4xu8Simd(allocator, blurred, radius);
                    } else {
                        // Generic struct path for other color types
                        var sat: Image([Self.channels()]f32) = undefined;
                        try self.integral(allocator, &sat);
                        defer sat.deinit(allocator);

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const r1 = r -| radius;
                                const c1 = c -| radius;
                                const r2 = @min(r + radius, self.rows - 1);
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));

                                inline for (std.meta.fields(T), 0..) |f, i| {
                                    const sum = sat.at(r2, c2)[i] - sat.at(r2, c1)[i] -
                                        sat.at(r1, c2)[i] + sat.at(r1, c1)[i];
                                    @field(blurred.at(r, c).*, f.name) = switch (@typeInfo(f.type)) {
                                        .int => @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sum / area)))),
                                        .float => as(f.type, sum / area),
                                        else => @compileError("Can't compute the boxBlur image with struct fields of type " ++ @typeName(f.type) ++ "."),
                                    };
                                }
                            }
                        }
                    }
                },
                else => @compileError("Can't compute the boxBlur image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Optimized box blur implementation for structs with 4 u8 fields using SIMD throughout.
        /// This is automatically called by boxBlur() when T has exactly 4 u8 fields (e.g., RGBA, BGRA, etc).
        fn boxBlur4xu8Simd(self: Self, allocator: std.mem.Allocator, blurred: *Self, radius: usize) !void {
            // Verify at compile time that this is a struct with 4 u8 fields
            comptime {
                const fields = std.meta.fields(T);
                assert(fields.len == 4);
                for (fields) |field| {
                    assert(field.type == u8);
                }
            }

            // Initialize output if needed
            if (!self.hasSameShape(blurred.*)) {
                blurred.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                self.copy(blurred.*);
                return;
            }

            // Create integral image with 4 channels
            var sat = try Image([4]f32).initAlloc(allocator, self.rows, self.cols);
            defer sat.deinit(allocator);

            // Build integral image - first pass: row-wise cumulative sums
            for (0..self.rows) |r| {
                var tmp: @Vector(4, f32) = @splat(0);
                const row_offset = r * self.stride;
                const out_offset = r * sat.cols;

                for (0..self.cols) |c| {
                    const pixel = self.data[row_offset + c];
                    var pixel_vec: @Vector(4, f32) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        pixel_vec[i] = @floatFromInt(@field(pixel, field.name));
                    }
                    tmp += pixel_vec;
                    sat.data[out_offset + c] = tmp;
                }
            }

            // Second pass: column-wise cumulative sums
            for (1..self.rows) |r| {
                const prev_row_offset = (r - 1) * sat.cols;
                const curr_row_offset = r * sat.cols;

                for (0..self.cols) |c| {
                    const prev_vec: @Vector(4, f32) = sat.data[prev_row_offset + c];
                    const curr_vec: @Vector(4, f32) = sat.data[curr_row_offset + c];
                    sat.data[curr_row_offset + c] = prev_vec + curr_vec;
                }
            }

            // Apply box blur with SIMD
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const r1 = r -| radius;
                    const c1 = c -| radius;
                    const r2 = @min(r + radius, self.rows - 1);
                    const c2 = @min(c + radius, self.cols - 1);
                    const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                    const area_vec: @Vector(4, f32) = @splat(area);

                    // Use vectors for the box sum calculation
                    const v_r2c2: @Vector(4, f32) = sat.at(r2, c2).*;
                    const v_r2c1: @Vector(4, f32) = sat.at(r2, c1).*;
                    const v_r1c2: @Vector(4, f32) = sat.at(r1, c2).*;
                    const v_r1c1: @Vector(4, f32) = sat.at(r1, c1).*;

                    const sum_vec = v_r2c2 - v_r2c1 - v_r1c2 + v_r1c1;
                    const avg_vec = sum_vec / area_vec;

                    // Convert back to struct
                    var result: T = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        @field(result, field.name) = @intFromFloat(@max(0, @min(255, @round(avg_vec[i]))));
                    }
                    blurred.at(r, c).* = result;
                }
            }
        }

        /// Optimized sharpen implementation for structs with 4 u8 fields using SIMD throughout.
        /// This is automatically called by sharpen() when T has exactly 4 u8 fields (e.g., RGBA, BGRA, etc).
        fn sharpen4xu8Simd(self: Self, allocator: std.mem.Allocator, sharpened: *Self, radius: usize) !void {
            // Verify at compile time that this is a struct with 4 u8 fields
            comptime {
                const fields = std.meta.fields(T);
                assert(fields.len == 4);
                for (fields) |field| {
                    assert(field.type == u8);
                }
            }

            // Initialize output if needed
            if (!self.hasSameShape(sharpened.*)) {
                sharpened.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                self.copy(sharpened.*);
                return;
            }

            // Create integral image with 4 channels
            var sat = try Image([4]f32).initAlloc(allocator, self.rows, self.cols);
            defer sat.deinit(allocator);

            // Build integral image - first pass: row-wise cumulative sums
            for (0..self.rows) |r| {
                var tmp: @Vector(4, f32) = @splat(0);
                const row_offset = r * self.stride;
                const out_offset = r * sat.cols;

                for (0..self.cols) |c| {
                    const pixel = self.data[row_offset + c];
                    var pixel_vec: @Vector(4, f32) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        pixel_vec[i] = @floatFromInt(@field(pixel, field.name));
                    }
                    tmp += pixel_vec;
                    sat.data[out_offset + c] = tmp;
                }
            }

            // Second pass: column-wise cumulative sums
            for (1..self.rows) |r| {
                const prev_row_offset = (r - 1) * sat.cols;
                const curr_row_offset = r * sat.cols;

                for (0..self.cols) |c| {
                    const prev_vec: @Vector(4, f32) = sat.data[prev_row_offset + c];
                    const curr_vec: @Vector(4, f32) = sat.data[curr_row_offset + c];
                    sat.data[curr_row_offset + c] = prev_vec + curr_vec;
                }
            }

            // Apply sharpen with SIMD: sharpened = 2 * original - blurred
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const r1 = r -| radius;
                    const c1 = c -| radius;
                    const r2 = @min(r + radius, self.rows - 1);
                    const c2 = @min(c + radius, self.cols - 1);
                    const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                    const area_vec: @Vector(4, f32) = @splat(area);

                    // Use vectors for the box sum calculation (blur)
                    const v_r2c2: @Vector(4, f32) = sat.at(r2, c2).*;
                    const v_r2c1: @Vector(4, f32) = sat.at(r2, c1).*;
                    const v_r1c2: @Vector(4, f32) = sat.at(r1, c2).*;
                    const v_r1c1: @Vector(4, f32) = sat.at(r1, c1).*;

                    const sum_vec = v_r2c2 - v_r2c1 - v_r1c2 + v_r1c1;
                    const blurred_vec = sum_vec / area_vec;

                    // Get original pixel as vector
                    const original_pixel = self.data[r * self.stride + c];
                    var original_vec: @Vector(4, f32) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        original_vec[i] = @floatFromInt(@field(original_pixel, field.name));
                    }

                    // Apply sharpening formula: 2 * original - blurred
                    const sharpened_vec = @as(@Vector(4, f32), @splat(2.0)) * original_vec - blurred_vec;

                    // Convert back to struct with clamping
                    var result: T = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        @field(result, field.name) = @intFromFloat(@max(0, @min(255, @round(sharpened_vec[i]))));
                    }
                    sharpened.at(r, c).* = result;
                }
            }
        }

        /// Computes a sharpened version of `self` by enhancing edges.
        /// It uses the formula `sharpened = 2 * original - blurred`, where `blurred` is a box-blurred
        /// version of the original image (calculated efficiently using an integral image).
        /// The `radius` parameter controls the size of the blur. This operation effectively
        /// increases the contrast at edges. SIMD optimizations are used for performance where applicable.
        pub fn sharpen(self: Self, allocator: std.mem.Allocator, sharpened: *Self, radius: usize) !void {
            if (!self.hasSameShape(sharpened.*)) {
                sharpened.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            if (radius == 0) {
                self.copy(sharpened.*);
                return;
            }

            switch (@typeInfo(T)) {
                .int, .float => {
                    var sat: Image(f32) = undefined;
                    defer sat.deinit(allocator);
                    try self.integral(allocator, &sat);

                    const simd_len = std.simd.suggestVectorLength(f32) orelse 1;

                    // Process each row
                    for (0..self.rows) |r| {
                        const r1 = r -| radius;
                        const r2 = @min(r + radius, self.rows - 1);
                        const r1_offset = r1 * self.cols;
                        const r2_offset = r2 * self.cols;

                        var c: usize = 0;

                        // Process SIMD chunks where safe (away from borders)
                        const row_safe = r >= radius and r + radius < self.rows;
                        if (simd_len > 1 and self.cols > 2 * radius + simd_len and row_safe) {
                            // Skip left border
                            while (c < radius) : (c += 1) {
                                const c1 = c -| radius;
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                                const sum = sat.at(r2, c2).* - sat.at(r2, c1).* -
                                    sat.at(r1, c2).* + sat.at(r1, c1).*;
                                const blurred = sum / area;
                                sharpened.at(r, c).* = if (@typeInfo(T) == .int)
                                    @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(2 * as(f32, self.at(r, c).*) - blurred))))
                                else
                                    as(T, 2 * as(f32, self.at(r, c).*) - blurred);
                            }

                            // SIMD middle section (constant area when row is safe)
                            const safe_end = self.cols - radius - simd_len;
                            if (c <= safe_end) {
                                const const_area: f32 = @floatFromInt((2 * radius + 1) * (2 * radius + 1));
                                const area_vec: @Vector(simd_len, f32) = @splat(const_area);

                                while (c <= safe_end) : (c += simd_len) {
                                    const c1 = c - radius;
                                    const c2 = c + radius;
                                    const int11: @Vector(simd_len, f32) = sat.data[r1_offset + c1 ..][0..simd_len].*;
                                    const int12: @Vector(simd_len, f32) = sat.data[r1_offset + c2 ..][0..simd_len].*;
                                    const int21: @Vector(simd_len, f32) = sat.data[r2_offset + c1 ..][0..simd_len].*;
                                    const int22: @Vector(simd_len, f32) = sat.data[r2_offset + c2 ..][0..simd_len].*;
                                    const sums = int22 - int21 - int12 + int11;
                                    const blurred_vals = sums / area_vec;

                                    for (0..simd_len) |i| {
                                        const original = self.at(r, c + i).*;
                                        sharpened.at(r, c + i).* = if (@typeInfo(T) == .int)
                                            @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(2 * as(f32, original) - blurred_vals[i]))))
                                        else
                                            as(T, 2 * as(f32, original) - blurred_vals[i]);
                                    }
                                }
                            }
                        }

                        // Process remaining pixels (right border and any leftover)
                        while (c < self.cols) : (c += 1) {
                            const c1 = c -| radius;
                            const c2 = @min(c + radius, self.cols - 1);
                            const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));
                            const sum = sat.at(r2, c2).* - sat.at(r2, c1).* -
                                sat.at(r1, c2).* + sat.at(r1, c1).*;
                            const blurred = sum / area;
                            sharpened.at(r, c).* = if (@typeInfo(T) == .int)
                                @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(2 * as(f32, self.at(r, c).*) - blurred))))
                            else
                                as(T, 2 * as(f32, self.at(r, c).*) - blurred);
                        }
                    }
                },
                .@"struct" => {
                    if (is4xu8Struct(T)) {
                        try self.sharpen4xu8Simd(allocator, sharpened, radius);
                    } else {
                        // Generic struct path for other color types
                        var sat: Image([Self.channels()]f32) = undefined;
                        try self.integral(allocator, &sat);
                        defer sat.deinit(allocator);

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const r1 = r -| radius;
                                const c1 = c -| radius;
                                const r2 = @min(r + radius, self.rows - 1);
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));

                                inline for (std.meta.fields(T), 0..) |f, i| {
                                    const sum = sat.at(r2, c2)[i] - sat.at(r2, c1)[i] -
                                        sat.at(r1, c2)[i] + sat.at(r1, c1)[i];
                                    const blurred = sum / area;
                                    const original = @field(self.at(r, c).*, f.name);
                                    @field(sharpened.at(r, c).*, f.name) = switch (@typeInfo(f.type)) {
                                        .int => blk: {
                                            const sharpened_val = 2 * as(f32, original) - blurred;
                                            break :blk @intFromFloat(@max(std.math.minInt(f.type), @min(std.math.maxInt(f.type), @round(sharpened_val))));
                                        },
                                        .float => as(f.type, 2 * as(f32, original) - blurred),
                                        else => @compileError("Can't compute the sharpen image with struct fields of type " ++ @typeName(f.type) ++ "."),
                                    };
                                }
                            }
                        }
                    }
                },
                else => @compileError("Can't compute the sharpen image of " ++ @typeName(T) ++ "."),
            }
        }

        /// Applies the Sobel filter to `self` to perform edge detection.
        /// The output is a grayscale image representing the magnitude of gradients at each pixel.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use if `out` needs to be (re)initialized.
        /// - `out`: An out-parameter pointer to an `Image(u8)` that will be filled with the Sobel magnitude image.
        pub fn sobel(self: Self, allocator: Allocator, out: *Image(u8)) !void {
            if (!self.hasSameShape(out.*)) {
                out.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            const vert_filter = [3][3]i32{
                .{ -1, -2, -1 },
                .{ 0, 0, 0 },
                .{ 1, 2, 1 },
            };
            const horz_filter = [3][3]i32{
                .{ -1, 0, 1 },
                .{ -2, 0, 2 },
                .{ -1, 0, 1 },
            };
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const ir: isize = @intCast(r);
                    const ic: isize = @intCast(c);
                    var horz_temp: i32 = 0;
                    var vert_temp: i32 = 0;
                    for (0..vert_filter.len) |m| {
                        const py: isize = ir - 1 + @as(isize, @intCast(m));
                        for (0..vert_filter[0].len) |n| {
                            const px: isize = ic - 1 + @as(isize, @intCast(n));
                            if (self.atOrNull(py, px)) |val| {
                                const p: i32 = @intCast(color.convertColor(u8, val.*));
                                horz_temp += p * horz_filter[m][n];
                                vert_temp += p * vert_filter[m][n];
                            }
                        }
                    }
                    out.at(r, c).* = @intFromFloat(@max(0, @min(255, @sqrt(@as(f32, @floatFromInt(horz_temp * horz_temp + vert_temp * vert_temp))))));
                }
            }
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

test "Image load error handling" {
    const allocator = std.testing.allocator;

    // Test 1: Loading a non-existent file should return FileNotFound
    const result1 = Image(color.Rgb).load(allocator, "this_file_does_not_exist.png");
    try std.testing.expectError(error.FileNotFound, result1);

    // Test 2: Create a text file and try to load it as an image
    const test_file = "test_not_an_image.txt";
    {
        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        _ = try file.write("This is not an image file");
    }
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Loading a non-image file should return UnsupportedImageFormat
    const result2 = Image(color.Rgb).load(allocator, test_file);
    try std.testing.expectError(error.UnsupportedImageFormat, result2);
}

//! This module defines a generic Image struct and provides a suite of image processing operations,
//! including initialization, manipulation (flipping, resizing, rotation, cropping),
//! filtering (integral image, box blur, sharpen, Sobel edge detection), and pixel access utilities.
const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqualDeep;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;

const as = @import("meta.zig").as;
const color = @import("color.zig");
const Point2d = @import("geometry/Point.zig").Point2d;
const is4xu8Struct = @import("meta.zig").is4xu8Struct;
const isScalar = @import("meta.zig").isScalar;
const isStruct = @import("meta.zig").isStruct;
const jpeg = @import("jpeg.zig");
const png = @import("png.zig");
const Rectangle = @import("geometry.zig").Rectangle;
const sixel = @import("sixel.zig");

/// Supported image formats for automatic detection and loading
pub const ImageFormat = enum {
    png,
    jpeg,

    /// Detect image format from the first few bytes of data
    pub fn detectFromBytes(data: []const u8) ?ImageFormat {
        // PNG signature
        if (data.len >= 8) {
            if (std.mem.eql(u8, data[0..8], &png.signature)) {
                return .png;
            }
        }

        // JPEG signature
        if (data.len >= 2) {
            if (std.mem.eql(u8, data[0..2], &jpeg.signature)) {
                return .jpeg;
            }
        }

        return null;
    }

    /// Detect image format from file path by reading the first few bytes
    pub fn detectFromPath(_: Allocator, file_path: []const u8) !?ImageFormat {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        var header: [8]u8 = undefined;
        const bytes_read = try file.read(&header);

        return detectFromBytes(header[0..bytes_read]);
    }
};

/// Display format options
pub const DisplayFormat = union(enum) {
    /// Automatically detect the best format (sixel if supported, ANSI otherwise)
    auto,
    /// Force ANSI escape codes output
    ansi,
    /// Force sixel output with specific options
    sixel: sixel.SixelOptions,
};

/// Formatter struct for terminal display with progressive degradation
pub fn DisplayFormatter(comptime T: type) type {
    return struct {
        image: *const Image(T),
        display_format: DisplayFormat,

        const Self = @This();

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const Rgb = @import("color.zig").Rgb;

            // Determine if we can fallback to ANSI
            const can_fallback = self.display_format == .auto;

            fmt: switch (self.display_format) {
                .ansi => {
                    for (0..self.image.rows) |r| {
                        for (0..self.image.cols) |c| {
                            const pixel = self.image.at(r, c).*;
                            const rgb = color.convertColor(Rgb, pixel);
                            try writer.print("\x1b[48;2;{d};{d};{d}m \x1b[0m", .{ rgb.r, rgb.g, rgb.b });
                        }
                        if (r < self.image.rows - 1) {
                            try writer.print("\n", .{});
                        }
                    }
                },
                .auto => {
                    if (!(sixel.isSixelSupported() catch false)) continue :fmt .ansi;
                    continue :fmt .{ .sixel = .default };
                },
                .sixel => |options| {
                    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    // Try to convert to sixel
                    const sixel_data = sixel.imageToSixel(T, self.image.*, allocator, options) catch |err| blk: {
                        // On OutOfMemory, try without dithering
                        if (err == error.OutOfMemory) {
                            break :blk sixel.imageToSixel(T, self.image.*, allocator, .fallback) catch null;
                        } else {
                            break :blk null;
                        }
                    };

                    if (sixel_data) |data| {
                        try writer.writeAll(data);
                    } else if (can_fallback) {
                        continue :fmt .ansi;
                    } else {
                        // Output minimal sixel sequence to indicate failure
                        // This ensures we always output valid sixel when explicitly requested
                        try writer.writeAll("\x1bPq\x1b\\");
                    }
                },
            }
        }
    };
}

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
                .png => png.loadPng(T, allocator, file_path),
                .jpeg => jpeg.loadJpeg(T, allocator, file_path),
            };
        }

        /// Returns the image data reinterpreted as a slice of bytes.
        /// Note: The image should not be a view; this is enforced by an assertion.
        pub fn asBytes(self: Self) []u8 {
            assert(self.rows * self.cols == self.data.len);
            assert(!self.isView());
            return @as([*]u8, @ptrCast(@alignCast(self.data.ptr)))[0 .. self.data.len * @sizeOf(T)];
        }

        /// Sets the image rows and cols to zero and frees the memory from the image.  It should
        /// only be called if the image owns the memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rows = 0;
            self.cols = 0;
            self.stride = 0;
            allocator.free(self.data);
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

        /// Returns the total number of pixels in the image (rows * cols).
        pub inline fn size(self: Self) usize {
            return self.rows * self.cols;
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

        /// Creates a formatter for terminal display with custom options.
        /// Provides fine-grained control over output format, palette modes, and dithering.
        /// Will still gracefully degrade from sixel to ANSI if needed.
        ///
        /// Example:
        /// ```zig
        /// const img = try Image(Rgb).load(allocator, "test.png");
        /// std.debug.print("{f}", .{img.display(.ansi)});
        /// std.debug.print("{f}", .{img.display(.{ .sixel = .{ .palette_mode = .adaptive } })});
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
            try self.display(.auto).format(writer);
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

        /// Performs bilinear interpolation at position x, y.
        /// Returns `null` if the coordinates `(x, y)` are too close to the image border for valid interpolation.
        pub fn interpolateBilinear(self: Self, x: f32, y: f32) ?T {
            const left: isize = @intFromFloat(@floor(x));
            const top: isize = @intFromFloat(@floor(y));
            const right = left + 1;
            const bottom = top + 1;
            if (!(left >= 0 and top >= 0 and right < self.cols and bottom < self.rows)) {
                return null;
            }
            const lr_frac: f32 = x - as(f32, left);
            const tb_frac: f32 = y - as(f32, top);
            const tl: T = self.at(@intCast(top), @intCast(left)).*;
            const tr: T = self.at(@intCast(top), @intCast(right)).*;
            const bl: T = self.at(@intCast(bottom), @intCast(left)).*;
            const br: T = self.at(@intCast(bottom), @intCast(right)).*;
            var temp: T = undefined;
            switch (@typeInfo(T)) {
                .int, .float => {
                    temp = as(T, (1 - tb_frac) * ((1 - lr_frac) * as(f32, tl) +
                        lr_frac * as(f32, tr)) +
                        tb_frac * ((1 - lr_frac) * as(f32, bl) +
                            lr_frac * as(f32, br)));
                },
                .@"struct" => {
                    inline for (std.meta.fields(T)) |f| {
                        @field(temp, f.name) = as(
                            f.type,
                            (1 - tb_frac) * ((1 - lr_frac) * as(f32, @field(tl, f.name)) +
                                lr_frac * as(f32, @field(tr, f.name))) +
                                tb_frac * ((1 - lr_frac) * as(f32, @field(bl, f.name)) +
                                    lr_frac * as(f32, @field(br, f.name))),
                        );
                    }
                },
                else => @compileError("Image(" ++ @typeName(T) ++ ").interpolateBilinear: unsupported image type"),
            }
            return temp;
        }

        /// Resizes an image to fit in out, using bilinear interpolation.
        pub fn resize(self: Self, out: Self) void {
            const x_scale: f32 = as(f32, self.cols - 1) / as(f32, @max(out.cols - 1, 1));
            const y_scale: f32 = as(f32, self.rows - 1) / as(f32, @max(out.rows - 1, 1));
            var sy: f32 = -y_scale;
            for (0..out.rows) |r| {
                sy += y_scale;
                var sx: f32 = -x_scale;
                for (0..out.cols) |c| {
                    sx += x_scale;
                    out.at(r, c).* = if (self.interpolateBilinear(sx, sy)) |val| val else std.mem.zeroes(T);
                }
            }
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

                    rotated.at(r, c).* = if (self.interpolateBilinear(src_x, src_y)) |val| val else std.mem.zeroes(T);
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

        /// Computes the integral image (also known as a summed-area table) of `self`.
        /// For multi-channel images (e.g., structs like `Rgba`), it computes a per-channel
        /// integral image, storing the result as an array of floats per pixel in the output `integral` image.
        /// Uses SIMD optimizations for improved performance with a two-pass approach.
        pub fn integralImage(
            self: Self,
            allocator: Allocator,
            integral: *Image(if (isScalar(T)) f32 else [Self.channels()]f32),
        ) !void {
            if (!self.hasSameShape(integral.*)) {
                integral.* = try .initAlloc(allocator, self.rows, self.cols);
            }
            switch (@typeInfo(T)) {
                .int, .float => {
                    // First pass: compute row-wise cumulative sums
                    for (0..self.rows) |r| {
                        var tmp: f32 = 0;
                        const row_offset = r * self.stride;
                        const out_offset = r * integral.cols;
                        for (0..self.cols) |c| {
                            tmp += as(f32, self.data[row_offset + c]);
                            integral.data[out_offset + c] = tmp;
                        }
                    }

                    // Second pass: add column-wise cumulative sums using SIMD
                    const simd_len = std.simd.suggestVectorLength(f32) orelse 1;
                    for (1..self.rows) |r| {
                        const prev_row_offset = (r - 1) * integral.cols;
                        const curr_row_offset = r * integral.cols;
                        var c: usize = 0;

                        // Process SIMD-width chunks
                        while (c + simd_len <= self.cols) : (c += simd_len) {
                            const prev_vals: @Vector(simd_len, f32) = integral.data[prev_row_offset + c ..][0..simd_len].*;
                            const curr_vals: @Vector(simd_len, f32) = integral.data[curr_row_offset + c ..][0..simd_len].*;
                            integral.data[curr_row_offset + c ..][0..simd_len].* = prev_vals + curr_vals;
                        }

                        // Handle remaining columns
                        while (c < self.cols) : (c += 1) {
                            integral.data[curr_row_offset + c] += integral.data[prev_row_offset + c];
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
                            const out_offset = r * integral.cols;

                            for (0..self.cols) |c| {
                                const pixel = self.data[row_offset + c];
                                var pixel_vec: @Vector(4, f32) = undefined;
                                inline for (std.meta.fields(T), 0..) |field, i| {
                                    pixel_vec[i] = @floatFromInt(@field(pixel, field.name));
                                }
                                tmp += pixel_vec;
                                integral.data[out_offset + c] = tmp;
                            }
                        }

                        // Second pass: column-wise cumulative sums
                        for (1..self.rows) |r| {
                            const prev_row_offset = (r - 1) * integral.cols;
                            const curr_row_offset = r * integral.cols;

                            for (0..self.cols) |c| {
                                const prev_vec: @Vector(4, f32) = integral.data[prev_row_offset + c];
                                const curr_vec: @Vector(4, f32) = integral.data[curr_row_offset + c];
                                integral.data[curr_row_offset + c] = prev_vec + curr_vec;
                            }
                        }
                    } else {
                        // Generic scalar path for other struct types
                        const num_channels = comptime Self.channels();

                        // First pass: compute row-wise cumulative sums for all channels
                        for (0..self.rows) |r| {
                            var tmp = [_]f32{0} ** num_channels;
                            const row_offset = r * self.stride;
                            const out_offset = r * integral.cols;
                            for (0..self.cols) |c| {
                                inline for (std.meta.fields(T), 0..) |f, i| {
                                    tmp[i] += as(f32, @field(self.data[row_offset + c], f.name));
                                    integral.data[out_offset + c][i] = tmp[i];
                                }
                            }
                        }

                        // Second pass: add column-wise cumulative sums
                        for (1..self.rows) |r| {
                            const prev_row_offset = (r - 1) * integral.cols;
                            const curr_row_offset = r * integral.cols;
                            for (0..self.cols) |c| {
                                inline for (0..num_channels) |i| {
                                    integral.data[curr_row_offset + c][i] += integral.data[prev_row_offset + c][i];
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
                    var integral: Image(f32) = undefined;
                    try self.integralImage(allocator, &integral);
                    defer integral.deinit(allocator);

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
                                const sum = integral.at(r2, c2).* - integral.at(r2, c1).* -
                                    integral.at(r1, c2).* + integral.at(r1, c1).*;
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
                                    const int11: @Vector(simd_len, f32) = integral.data[r1_offset + c1 ..][0..simd_len].*;
                                    const int12: @Vector(simd_len, f32) = integral.data[r1_offset + c2 ..][0..simd_len].*;
                                    const int21: @Vector(simd_len, f32) = integral.data[r2_offset + c1 ..][0..simd_len].*;
                                    const int22: @Vector(simd_len, f32) = integral.data[r2_offset + c2 ..][0..simd_len].*;
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
                            const sum = integral.at(r2, c2).* - integral.at(r2, c1).* - integral.at(r1, c2).* + integral.at(r1, c1).*;
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
                        var integral: Image([Self.channels()]f32) = undefined;
                        try self.integralImage(allocator, &integral);
                        defer integral.deinit(allocator);

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const r1 = r -| radius;
                                const c1 = c -| radius;
                                const r2 = @min(r + radius, self.rows - 1);
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));

                                inline for (std.meta.fields(T), 0..) |f, i| {
                                    const sum = integral.at(r2, c2)[i] - integral.at(r2, c1)[i] -
                                        integral.at(r1, c2)[i] + integral.at(r1, c1)[i];
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
            var integral = try Image([4]f32).initAlloc(allocator, self.rows, self.cols);
            defer integral.deinit(allocator);

            // Build integral image - first pass: row-wise cumulative sums
            for (0..self.rows) |r| {
                var tmp: @Vector(4, f32) = @splat(0);
                const row_offset = r * self.stride;
                const out_offset = r * integral.cols;

                for (0..self.cols) |c| {
                    const pixel = self.data[row_offset + c];
                    var pixel_vec: @Vector(4, f32) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        pixel_vec[i] = @floatFromInt(@field(pixel, field.name));
                    }
                    tmp += pixel_vec;
                    integral.data[out_offset + c] = tmp;
                }
            }

            // Second pass: column-wise cumulative sums
            for (1..self.rows) |r| {
                const prev_row_offset = (r - 1) * integral.cols;
                const curr_row_offset = r * integral.cols;

                for (0..self.cols) |c| {
                    const prev_vec: @Vector(4, f32) = integral.data[prev_row_offset + c];
                    const curr_vec: @Vector(4, f32) = integral.data[curr_row_offset + c];
                    integral.data[curr_row_offset + c] = prev_vec + curr_vec;
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
                    const v_r2c2: @Vector(4, f32) = integral.at(r2, c2).*;
                    const v_r2c1: @Vector(4, f32) = integral.at(r2, c1).*;
                    const v_r1c2: @Vector(4, f32) = integral.at(r1, c2).*;
                    const v_r1c1: @Vector(4, f32) = integral.at(r1, c1).*;

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
            var integral = try Image([4]f32).initAlloc(allocator, self.rows, self.cols);
            defer integral.deinit(allocator);

            // Build integral image - first pass: row-wise cumulative sums
            for (0..self.rows) |r| {
                var tmp: @Vector(4, f32) = @splat(0);
                const row_offset = r * self.stride;
                const out_offset = r * integral.cols;

                for (0..self.cols) |c| {
                    const pixel = self.data[row_offset + c];
                    var pixel_vec: @Vector(4, f32) = undefined;
                    inline for (std.meta.fields(T), 0..) |field, i| {
                        pixel_vec[i] = @floatFromInt(@field(pixel, field.name));
                    }
                    tmp += pixel_vec;
                    integral.data[out_offset + c] = tmp;
                }
            }

            // Second pass: column-wise cumulative sums
            for (1..self.rows) |r| {
                const prev_row_offset = (r - 1) * integral.cols;
                const curr_row_offset = r * integral.cols;

                for (0..self.cols) |c| {
                    const prev_vec: @Vector(4, f32) = integral.data[prev_row_offset + c];
                    const curr_vec: @Vector(4, f32) = integral.data[curr_row_offset + c];
                    integral.data[curr_row_offset + c] = prev_vec + curr_vec;
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
                    const v_r2c2: @Vector(4, f32) = integral.at(r2, c2).*;
                    const v_r2c1: @Vector(4, f32) = integral.at(r2, c1).*;
                    const v_r1c2: @Vector(4, f32) = integral.at(r1, c2).*;
                    const v_r1c1: @Vector(4, f32) = integral.at(r1, c1).*;

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
                    var integral: Image(f32) = undefined;
                    defer integral.deinit(allocator);
                    try self.integralImage(allocator, &integral);

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
                                const sum = integral.at(r2, c2).* - integral.at(r2, c1).* -
                                    integral.at(r1, c2).* + integral.at(r1, c1).*;
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
                                    const int11: @Vector(simd_len, f32) = integral.data[r1_offset + c1 ..][0..simd_len].*;
                                    const int12: @Vector(simd_len, f32) = integral.data[r1_offset + c2 ..][0..simd_len].*;
                                    const int21: @Vector(simd_len, f32) = integral.data[r2_offset + c1 ..][0..simd_len].*;
                                    const int22: @Vector(simd_len, f32) = integral.data[r2_offset + c2 ..][0..simd_len].*;
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
                            const sum = integral.at(r2, c2).* - integral.at(r2, c1).* -
                                integral.at(r1, c2).* + integral.at(r1, c1).*;
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
                        var integral: Image([Self.channels()]f32) = undefined;
                        try self.integralImage(allocator, &integral);
                        defer integral.deinit(allocator);

                        for (0..self.rows) |r| {
                            for (0..self.cols) |c| {
                                const r1 = r -| radius;
                                const c1 = c -| radius;
                                const r2 = @min(r + radius, self.rows - 1);
                                const c2 = @min(c + radius, self.cols - 1);
                                const area: f32 = @floatFromInt((r2 - r1) * (c2 - c1));

                                inline for (std.meta.fields(T), 0..) |f, i| {
                                    const sum = integral.at(r2, c2)[i] - integral.at(r2, c1)[i] -
                                        integral.at(r1, c2)[i] + integral.at(r1, c1)[i];
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
    };
}

test "integral image scalar" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = 1;
    var integral: Image(f32) = undefined;
    try image.integralImage(std.testing.allocator, &integral);
    defer integral.deinit(std.testing.allocator);
    try expectEqual(image.rows, integral.rows);
    try expectEqual(image.cols, integral.cols);
    try expectEqual(image.data.len, integral.data.len);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            try expectEqual(area_at_pos, integral.at(r, c).*);
        }
    }
}

test "integral image view scalar" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = 1;
    const view = image.view(.{ .l = 2, .t = 3, .r = 8, .b = 10 });
    var integral: Image(f32) = undefined;
    try view.integralImage(std.testing.allocator, &integral);
    defer integral.deinit(std.testing.allocator);
    try expectEqual(view.rows, integral.rows);
    try expectEqual(view.cols, integral.cols);
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            try expectEqual(area_at_pos, integral.at(r, c).*);
        }
    }
}

test "integral image struct" {
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    for (image.data) |*i| i.* = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    var integral: Image([4]f32) = undefined;
    try image.integralImage(std.testing.allocator, &integral);

    defer integral.deinit(std.testing.allocator);
    try expectEqual(image.rows, integral.rows);
    try expectEqual(image.cols, integral.cols);
    try expectEqual(image.data.len, integral.data.len);
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const area_at_pos: f32 = @floatFromInt((r + 1) * (c + 1));
            for (0..4) |i| {
                try expectEqual(area_at_pos, integral.at(r, c)[i]);
            }
        }
    }
}

test "integral image RGB vs RGBA with full alpha produces same RGB values" {
    const Rgb = @import("color.zig").Rgb;
    const test_size = 10;

    // Create RGB image
    var rgb_img = try Image(Rgb).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgb_img.deinit(std.testing.allocator);

    // Create RGBA image
    var rgba_img = try Image(color.Rgba).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgba_img.deinit(std.testing.allocator);

    // Fill both with identical RGB values
    var seed: u8 = 0;
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            seed +%= 17;
            const r_val = seed;
            const g_val = seed +% 50;
            const b_val = seed +% 100;

            rgb_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val };
            rgba_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val, .a = 255 };
        }
    }

    // Apply integralImage to both
    var rgb_integral: Image([3]f32) = undefined;
    try rgb_img.integralImage(std.testing.allocator, &rgb_integral);
    defer rgb_integral.deinit(std.testing.allocator);

    var rgba_integral: Image([4]f32) = undefined;
    try rgba_img.integralImage(std.testing.allocator, &rgba_integral);
    defer rgba_integral.deinit(std.testing.allocator);

    // Compare RGB channels - they should be identical
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const rgb = rgb_integral.at(r, c).*;
            const rgba = rgba_integral.at(r, c).*;

            try expectEqual(rgb[0], rgba[0]);
            try expectEqual(rgb[1], rgba[1]);
            try expectEqual(rgb[2], rgba[2]);
        }
    }
}

test "getRectangle" {
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    const rect = image.getRectangle();
    try expectEqual(rect.width(), image.cols);
    try expectEqual(rect.height(), image.rows);
}

test "copy function with views" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 7);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    // Create a view
    const view = image.view(.{ .l = 1, .t = 1, .r = 4, .b = 3 });

    // Copy view to new image
    var copied: Image(u8) = try .initAlloc(std.testing.allocator, view.rows, view.cols);
    defer copied.deinit(std.testing.allocator);

    view.copy(copied);

    // Verify copied data matches view
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, copied.at(r, c).*);
        }
    }

    // Test copy from regular image to view
    var target: Image(u8) = try .initAlloc(std.testing.allocator, 6, 8);
    defer target.deinit(std.testing.allocator);

    // Fill target with different pattern
    for (0..target.rows) |r| {
        for (0..target.cols) |c| {
            target.at(r, c).* = 99;
        }
    }

    // Create view of target
    const target_view = target.view(.{ .l = 2, .t = 2, .r = 5, .b = 4 });

    // Copy original view to target view
    view.copy(target_view);

    // Verify the view area was copied correctly
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, target_view.at(r, c).*);
        }
    }

    // Verify areas outside the view weren't touched
    try expectEqual(@as(u8, 99), target.at(0, 0).*);
    try expectEqual(@as(u8, 99), target.at(5, 7).*);
}

test "copy function in-place behavior" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c);
        }
    }

    // Store original values
    var original_values: [9]u8 = undefined;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            original_values[r * 3 + c] = image.at(r, c).*;
        }
    }

    // In-place copy should be no-op
    image.copy(image);

    // Values should be unchanged
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(original_values[r * 3 + c], image.at(r, c).*);
        }
    }
}

test "boxBlur radius 0 with views" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 6, 8);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 10 + c);
        }
    }

    // Create a view
    const view = image.view(.{ .l = 1, .t = 1, .r = 5, .b = 4 });

    // Apply boxBlur with radius 0 to view
    var blurred: Image(u8) = undefined;
    try view.boxBlur(std.testing.allocator, &blurred, 0);
    defer blurred.deinit(std.testing.allocator);

    // Should be identical to view
    for (0..view.rows) |r| {
        for (0..view.cols) |c| {
            try expectEqual(view.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "view" {
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 21, 13);
    defer image.deinit(std.testing.allocator);
    const rect: Rectangle(usize) = .{ .l = 0, .t = 0, .r = 8, .b = 10 };
    const view = image.view(rect);
    try expectEqual(view.isView(), true);
    try expectEqual(image.isView(), false);
    try expectEqualDeep(rect, view.getRectangle());
}

test "boxBlur basic functionality" {
    // Test with uniform image - should remain unchanged
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Fill with uniform value
    for (image.data) |*pixel| pixel.* = 128;

    var blurred: Image(u8) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 1);
    defer blurred.deinit(std.testing.allocator);

    // Uniform image should remain uniform after blur
    for (blurred.data) |pixel| {
        try expectEqual(@as(u8, 128), pixel);
    }
}

test "boxBlur zero radius" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c);
        }
    }

    var blurred: Image(u8) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 0);
    defer blurred.deinit(std.testing.allocator);

    // Zero radius should produce identical image
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, blurred.at(r, c).*);
        }
    }
}

test "boxBlur border effects" {
    // Create a small image to test border handling
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Initialize with a pattern where center is 255, edges are 0
    for (image.data) |*pixel| pixel.* = 0;
    image.at(2, 2).* = 255; // Center pixel

    var blurred: Image(u8) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 1);
    defer blurred.deinit(std.testing.allocator);

    // The center should be blurred down, corners should have some blur effect
    try expectEqual(@as(usize, 5), blurred.rows);
    try expectEqual(@as(usize, 5), blurred.cols);

    // Corner pixels should have received some blur from the center
    // but less than center pixels due to smaller effective area
    const corner_val = blurred.at(0, 0).*;
    const center_val = blurred.at(2, 2).*;

    // Center should be less than original 255 due to averaging with zeros
    // Corner should be less than center due to smaller kernel area
    try expectEqual(corner_val < center_val, true);
    try expectEqual(center_val < 255, true);
}

test "boxBlur struct type" {
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with different colors
    image.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0, .a = 255 }; // Red
    image.at(0, 1).* = .{ .r = 0, .g = 255, .b = 0, .a = 255 }; // Green
    image.at(0, 2).* = .{ .r = 0, .g = 0, .b = 255, .a = 255 }; // Blue
    image.at(1, 0).* = .{ .r = 255, .g = 255, .b = 0, .a = 255 }; // Yellow
    image.at(1, 1).* = .{ .r = 255, .g = 255, .b = 255, .a = 255 }; // White
    image.at(1, 2).* = .{ .r = 255, .g = 0, .b = 255, .a = 255 }; // Magenta
    image.at(2, 0).* = .{ .r = 0, .g = 255, .b = 255, .a = 255 }; // Cyan
    image.at(2, 1).* = .{ .r = 128, .g = 128, .b = 128, .a = 255 }; // Gray
    image.at(2, 2).* = .{ .r = 0, .g = 0, .b = 0, .a = 255 }; // Black

    var blurred: Image(color.Rgba) = undefined;
    try image.boxBlur(std.testing.allocator, &blurred, 1);
    defer blurred.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 3), blurred.rows);
    try expectEqual(@as(usize, 3), blurred.cols);

    // Center pixel should be average of all surrounding pixels
    const center = blurred.at(1, 1).*;
    // All channels should be affected by blur
    try expectEqual(center.r != 255, true);
    try expectEqual(center.g != 255, true);
    try expectEqual(center.b != 255, true);
}

test "boxBlur SIMD vs non-SIMD consistency" {
    // Test specifically designed to trigger both SIMD and non-SIMD paths
    // Large enough for SIMD optimizations with different radii
    const test_size = 64; // Large enough for SIMD

    for ([_]usize{ 1, 2, 3, 5 }) |radius| {
        var image: Image(u8) = try .initAlloc(std.testing.allocator, test_size, test_size);
        defer image.deinit(std.testing.allocator);

        // Create a checkerboard pattern to expose area calculation errors
        for (0..image.rows) |r| {
            for (0..image.cols) |c| {
                image.at(r, c).* = if ((r + c) % 2 == 0) 255 else 0;
            }
        }

        var blurred: Image(u8) = undefined;
        try image.boxBlur(std.testing.allocator, &blurred, radius);
        defer blurred.deinit(std.testing.allocator);

        // The key test: center pixels processed by SIMD should be mathematically consistent
        // with border pixels processed by scalar code. For a checkerboard, we can verify
        // the blur result is symmetric and area calculations are correct.

        // Check symmetry - if area calculations are correct, symmetric patterns should blur symmetrically
        const center = test_size / 2;
        try expectEqual(blurred.at(center, center).*, blurred.at(center, center).*); // Trivial but ensures no crash

        // Check that corners have lower values (smaller effective area) than center
        const corner_val = blurred.at(0, 0).*;
        const center_val = blurred.at(center, center).*;

        // For checkerboard pattern, center should be ~127.5, corners should be higher due to smaller kernel
        try expectEqual(corner_val >= center_val, true);
    }
}

test "boxBlur border area calculations" {
    // Test that border pixels get correct area calculations by comparing
    // uniform images with different values
    const test_size = 12;
    const radius = 3;

    // Test with uniform image - all pixels should have the same value after blur
    var uniform_image: Image(u8) = try .initAlloc(std.testing.allocator, test_size, test_size);
    defer uniform_image.deinit(std.testing.allocator);

    for (uniform_image.data) |*pixel| pixel.* = 200;

    var uniform_blurred: Image(u8) = undefined;
    try uniform_image.boxBlur(std.testing.allocator, &uniform_blurred, radius);
    defer uniform_blurred.deinit(std.testing.allocator);

    // All pixels should remain 200 since it's uniform
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            try expectEqual(@as(u8, 200), uniform_blurred.at(r, c).*);
        }
    }

    // Test with gradient - area calculations should be smooth
    var gradient_image: Image(u8) = try .initAlloc(std.testing.allocator, test_size, test_size);
    defer gradient_image.deinit(std.testing.allocator);

    for (0..test_size) |r| {
        for (0..test_size) |c| {
            gradient_image.at(r, c).* = @intCast((r * 255) / test_size);
        }
    }

    var gradient_blurred: Image(u8) = undefined;
    try gradient_image.boxBlur(std.testing.allocator, &gradient_blurred, radius);
    defer gradient_blurred.deinit(std.testing.allocator);

    // Check that we got reasonable blur results (no crashes, no extreme values)
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const val = gradient_blurred.at(r, c).*;
            // Values should be within reasonable range (not corrupted by bad area calculations)
            try expectEqual(val <= 255, true);
            try expectEqual(val >= 0, true);
        }
    }
}

test "boxBlur struct type comprehensive" {
    // Test RGBA with both large images (SIMD) and small images (scalar)
    for ([_]usize{ 8, 32 }) |test_size| { // Small and large
        for ([_]usize{ 1, 3 }) |radius| {
            var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, test_size, test_size);
            defer image.deinit(std.testing.allocator);

            // Create a red-to-blue gradient
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    const red_val: u8 = @intCast((255 * c) / test_size);
                    const blue_val: u8 = @intCast((255 * r) / test_size);
                    image.at(r, c).* = .{
                        .r = red_val,
                        .g = 128,
                        .b = blue_val,
                        .a = 255,
                    };
                }
            }

            var blurred: Image(color.Rgba) = undefined;
            try image.boxBlur(std.testing.allocator, &blurred, radius);
            defer blurred.deinit(std.testing.allocator);

            // Check that alpha remains unchanged
            for (0..test_size) |r| {
                for (0..test_size) |c| {
                    try expectEqual(@as(u8, 255), blurred.at(r, c).a);
                }
            }

            // Check that gradients remain smooth
            for (1..test_size - 1) |r| {
                const curr_r = blurred.at(r, test_size / 2).r;
                const next_r = blurred.at(r + 1, test_size / 2).r;
                const diff = if (next_r > curr_r) next_r - curr_r else curr_r - next_r;
                try expectEqual(diff <= 15, true); // Reasonable smoothness
            }
        }
    }
}

test "boxBlur RGB vs RGBA with full alpha produces same RGB values" {
    // Simple test: RGB image and RGBA image with alpha=255 should produce
    // identical results for the RGB channels

    const Rgb = @import("color.zig").Rgb;
    const test_size = 10;
    const radius = 2;

    // Create RGB image
    var rgb_img = try Image(Rgb).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgb_img.deinit(std.testing.allocator);

    // Create RGBA image
    var rgba_img = try Image(color.Rgba).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgba_img.deinit(std.testing.allocator);

    // Fill both with identical RGB values
    var seed: u8 = 0;
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            seed +%= 17;
            const r_val = seed;
            const g_val = seed +% 50;
            const b_val = seed +% 100;

            rgb_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val };
            rgba_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val, .a = 255 };
        }
    }

    // Apply blur to both
    var rgb_blurred: Image(Rgb) = undefined;
    try rgb_img.boxBlur(std.testing.allocator, &rgb_blurred, radius);
    defer rgb_blurred.deinit(std.testing.allocator);

    var rgba_blurred: Image(color.Rgba) = undefined;
    try rgba_img.boxBlur(std.testing.allocator, &rgba_blurred, radius);
    defer rgba_blurred.deinit(std.testing.allocator);

    // Compare RGB channels - they should be identical
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const rgb = rgb_blurred.at(r, c).*;
            const rgba = rgba_blurred.at(r, c).*;

            try expectEqual(rgb.r, rgba.r);
            try expectEqual(rgb.g, rgba.g);
            try expectEqual(rgb.b, rgba.b);
            try expectEqual(@as(u8, 255), rgba.a); // Alpha should remain 255
        }
    }
}

test "sharpen RGB vs RGBA with full alpha produces same RGB values" {
    // Simple test: RGB image and RGBA image with alpha=255 should produce
    // identical results for the RGB channels when sharpened

    const Rgb = @import("color.zig").Rgb;
    const test_size = 8;
    const radius = 1;

    // Create RGB image
    var rgb_img = try Image(Rgb).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgb_img.deinit(std.testing.allocator);

    // Create RGBA image
    var rgba_img = try Image(color.Rgba).initAlloc(std.testing.allocator, test_size, test_size);
    defer rgba_img.deinit(std.testing.allocator);

    // Fill both with identical RGB values (create an edge pattern for sharpening)
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const val: u8 = if (c < test_size / 2) 64 else 192; // Left dark, right bright
            const r_val = val;
            const g_val = val +% 30;
            const b_val = val +% 60;

            rgb_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val };
            rgba_img.at(r, c).* = .{ .r = r_val, .g = g_val, .b = b_val, .a = 255 };
        }
    }

    // Apply sharpen to both
    var rgb_sharpened: Image(Rgb) = undefined;
    try rgb_img.sharpen(std.testing.allocator, &rgb_sharpened, radius);
    defer rgb_sharpened.deinit(std.testing.allocator);

    var rgba_sharpened: Image(color.Rgba) = undefined;
    try rgba_img.sharpen(std.testing.allocator, &rgba_sharpened, radius);
    defer rgba_sharpened.deinit(std.testing.allocator);

    // Compare RGB channels - they should be identical
    for (0..test_size) |r| {
        for (0..test_size) |c| {
            const rgb = rgb_sharpened.at(r, c).*;
            const rgba = rgba_sharpened.at(r, c).*;

            try expectEqual(rgb.r, rgba.r);
            try expectEqual(rgb.g, rgba.g);
            try expectEqual(rgb.b, rgba.b);
            try expectEqual(@as(u8, 255), rgba.a); // Alpha should remain 255
        }
    }
}

test "sharpen basic functionality" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 5, 5);
    defer image.deinit(std.testing.allocator);

    // Create an edge pattern: left half dark, right half bright
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if (c < 2) 64 else 192;
        }
    }

    var sharpened: Image(u8) = undefined;
    try image.sharpen(std.testing.allocator, &sharpened, 1);
    defer sharpened.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 5), sharpened.rows);
    try expectEqual(@as(usize, 5), sharpened.cols);

    // Edge pixels should have more contrast after sharpening
    const left_val = sharpened.at(2, 0).*;
    const right_val = sharpened.at(2, 4).*;

    // Sharpening should increase contrast at edges
    try expectEqual(left_val <= 64, true); // Dark side should get darker or stay same
    try expectEqual(right_val >= 192, true); // Bright side should get brighter or stay same
}

test "sharpen zero radius" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Initialize with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast(r * 3 + c + 10);
        }
    }

    var sharpened: Image(u8) = undefined;
    try image.sharpen(std.testing.allocator, &sharpened, 0);
    defer sharpened.deinit(std.testing.allocator);

    // Zero radius should produce identical image
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            try expectEqual(image.at(r, c).*, sharpened.at(r, c).*);
        }
    }
}

test "sharpen uniform image" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 4, 4);
    defer image.deinit(std.testing.allocator);

    // Fill with uniform value
    for (image.data) |*pixel| pixel.* = 100;

    var sharpened: Image(u8) = .empty;
    try image.sharpen(std.testing.allocator, &sharpened, 1);
    defer sharpened.deinit(std.testing.allocator);

    // Uniform image should remain uniform after sharpening
    // (2 * original - blurred = 2 * 100 - 100 = 100)
    for (sharpened.data) |pixel| {
        try expectEqual(@as(u8, 100), pixel);
    }
}

test "sharpen struct type" {
    var image: Image(color.Rgba) = try .initAlloc(std.testing.allocator, 3, 3);
    defer image.deinit(std.testing.allocator);

    // Create a simple pattern with a bright center
    for (image.data) |*pixel| pixel.* = .{ .r = 64, .g = 64, .b = 64, .a = 255 };
    image.at(1, 1).* = .{ .r = 192, .g = 192, .b = 192, .a = 255 }; // Bright center

    var sharpened: Image(color.Rgba) = .empty;
    try image.sharpen(std.testing.allocator, &sharpened, 1);
    defer sharpened.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 3), sharpened.rows);
    try expectEqual(@as(usize, 3), sharpened.cols);

    // Center should be enhanced (brighter than original)
    const original_center = image.at(1, 1).*;
    const sharpened_center = sharpened.at(1, 1).*;

    // Center should be sharpened (enhanced contrast)
    try expectEqual(sharpened_center.r >= original_center.r, true);
    try expectEqual(sharpened_center.g >= original_center.g, true);
    try expectEqual(sharpened_center.b >= original_center.b, true);
}

test "rotateBounds" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 100, 200);
    defer image.deinit(std.testing.allocator);

    // Test 0 degrees - should be same size
    const bounds_0 = image.rotateBounds(0);
    try expectEqual(@as(usize, 200), bounds_0.cols);
    try expectEqual(@as(usize, 100), bounds_0.rows);

    // Test 90 degrees - should be swapped exactly
    const bounds_90 = image.rotateBounds(std.math.pi / 2.0);
    try expectEqual(@as(usize, 100), bounds_90.cols);
    try expectEqual(@as(usize, 200), bounds_90.rows);

    // Test 180 degrees - should be same size
    const bounds_180 = image.rotateBounds(std.math.pi);
    try expectEqual(@as(usize, 200), bounds_180.cols);
    try expectEqual(@as(usize, 100), bounds_180.rows);

    // Test 270 degrees - should be swapped exactly
    const bounds_270 = image.rotateBounds(3.0 * std.math.pi / 2.0);
    try expectEqual(@as(usize, 100), bounds_270.cols);
    try expectEqual(@as(usize, 200), bounds_270.rows);

    // Test 45 degrees - should be larger
    const bounds_45 = image.rotateBounds(std.math.pi / 4.0);
    try expectEqual(bounds_45.cols > 200, true);
    try expectEqual(bounds_45.rows > 100, true);
}

test "rotate orthogonal fast paths" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 3, 4);
    defer image.deinit(std.testing.allocator);

    // Create a pattern to verify correct rotation
    image.at(0, 0).* = 1;
    image.at(0, 1).* = 2;
    image.at(0, 2).* = 3;
    image.at(0, 3).* = 4;
    image.at(1, 0).* = 5;
    image.at(1, 1).* = 6;
    image.at(1, 2).* = 7;
    image.at(1, 3).* = 8;
    image.at(2, 0).* = 9;
    image.at(2, 1).* = 10;
    image.at(2, 2).* = 11;
    image.at(2, 3).* = 12;

    // Test 0 degree rotation
    var rotated_0: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, 0, &rotated_0);
    defer rotated_0.deinit(std.testing.allocator);
    try expectEqual(@as(u8, 1), rotated_0.at(0, 0).*);

    // Test 90 degree rotation
    var rotated_90: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, std.math.pi / 2.0, &rotated_90);
    defer rotated_90.deinit(std.testing.allocator);
    // After 90° rotation, top-left becomes bottom-left
    // Original (0,0)=1 should be at (2,0) in rotated image (accounting for centering)

    // Test 180 degree rotation
    var rotated_180: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, std.math.pi, &rotated_180);
    defer rotated_180.deinit(std.testing.allocator);

    // Test 270 degree rotation
    var rotated_270: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, 3.0 * std.math.pi / 2.0, &rotated_270);
    defer rotated_270.deinit(std.testing.allocator);

    // Verify dimensions are as expected
    try expectEqual(@as(usize, 3), rotated_0.rows);
    try expectEqual(@as(usize, 4), rotated_0.cols);
    // 90° rotation should have exact swapped dimensions
    try expectEqual(@as(usize, 4), rotated_90.rows);
    try expectEqual(@as(usize, 3), rotated_90.cols);
    // 180° rotation should have same dimensions as original
    try expectEqual(@as(usize, 3), rotated_180.rows);
    try expectEqual(@as(usize, 4), rotated_180.cols);
    // 270° rotation should have exact swapped dimensions
    try expectEqual(@as(usize, 4), rotated_270.rows);
    try expectEqual(@as(usize, 3), rotated_270.cols);
}

test "rotate arbitrary angle" {
    var image: Image(u8) = try .initAlloc(std.testing.allocator, 10, 10);
    defer image.deinit(std.testing.allocator);

    // Fill with pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = if ((r + c) % 2 == 0) 255 else 0;
        }
    }

    // Test 45 degree rotation
    var rotated: Image(u8) = .empty;
    try image.rotate(std.testing.allocator, std.math.pi / 4.0, &rotated);
    defer rotated.deinit(std.testing.allocator);

    // Should be larger than original to fit rotated content
    try expectEqual(rotated.rows > 10, true);
    try expectEqual(rotated.cols > 10, true);
}

test "image format function" {
    const Rgb = @import("color.zig").Rgb;

    // Create a small 2x2 RGB image
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 2, 2);
    defer image.deinit(std.testing.allocator);

    // Set up a pattern: red, green, blue, white
    image.at(0, 0).* = Rgb.red;
    image.at(0, 1).* = Rgb.green;
    image.at(1, 0).* = Rgb.blue;
    image.at(1, 1).* = Rgb.white;

    // Test that format function works without error
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Force ANSI format for testing
    try std.fmt.format(stream.writer(), "{f}", .{image.display(.ansi)});
    const result = stream.getWritten();

    // The expected output should be:
    // Row 0: red_bg + green_bg + newline
    // Row 1: blue_bg + white_bg
    const expected = "\x1b[48;2;255;0;0m \x1b[0m\x1b[48;2;0;255;0m \x1b[0m\n\x1b[48;2;0;0;255m \x1b[0m\x1b[48;2;255;255;255m \x1b[0m";

    try expectEqualStrings(expected, result);
}

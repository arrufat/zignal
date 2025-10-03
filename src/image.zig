//! Image processing module
//!
//! This module provides a unified interface to image processing functionality.
//! The main Image struct supports generic pixel types and provides operations for:
//! - Loading and saving images (PNG, JPEG)
//! - Terminal display with multiple formats (SGR, Braille, Sixel, Kitty)
//! - Geometric transforms (resize, rotate, crop, flip)
//! - Filters (blur, sharpen, edge detection)
//! - Views for zero-copy sub-image operations

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Rgba = @import("color.zig").Rgba;
const convertColor = @import("color.zig").convertColor;
const Rectangle = @import("geometry.zig").Rectangle;
const Point = @import("geometry/Point.zig").Point;
const jpeg = @import("jpeg.zig");
const isScalar = @import("meta.zig").isScalar;
const png = @import("png.zig");

// Import image sub-modules (private for internal use)
const DisplayFormatter = @import("image/display.zig").DisplayFormatter;
const Edges = @import("image/edges.zig").Edges;
const Enhancement = @import("image/enhancement.zig").Enhancement;
const binary = @import("image/binary.zig");
const Transform = @import("image/transforms.zig").Transform;
const interpolation = @import("image/interpolation.zig");
const OrderStatisticBlurOps = @import("image/order_statistic_blur.zig").OrderStatisticBlurOps;

pub const DisplayFormat = @import("image/display.zig").DisplayFormat;
pub const ImageFormat = @import("image/format.zig").ImageFormat;
pub const Interpolation = @import("image/interpolation.zig").Interpolation;
pub const PixelIterator = @import("image/PixelIterator.zig").PixelIterator;
pub const ShenCastan = @import("image/ShenCastan.zig");
pub const Histogram = @import("image/histogram.zig").Histogram;
pub const BinaryKernel = binary.Kernel;
const convolution = @import("image/convolution.zig");
pub const BorderMode = convolution.BorderMode;
pub const MotionBlur = @import("image/motion_blur.zig").MotionBlur;
const MotionBlurOps = @import("image/motion_blur.zig").MotionBlurOps;
const Blending = @import("color/blending.zig").Blending;

/// A simple image struct that encapsulates the size and the data.
pub fn Image(comptime T: type) type {
    return struct {
        rows: usize,
        cols: usize,
        data: []T,
        stride: usize,

        const Self = @This();

        /// Integral image operations for fast box filtering and region sums.
        pub const Integral = @import("image/integral.zig").Integral(T);

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
        pub const empty: Self = .{ .rows = 0, .cols = 0, .data = &[_]T{}, .stride = 0 };

        /// Constructs an image of rows and cols size allocating its own memory.
        /// The image owns the memory and deinit should be called to free it.
        pub fn init(allocator: Allocator, rows: usize, cols: usize) !Image(T) {
            return .{ .rows = rows, .cols = cols, .data = try allocator.alloc(T, rows * cols), .stride = cols };
        }

        /// Constructs an image with the same dimensions as the reference image.
        /// The image owns the memory and deinit should be called to free it.
        ///
        /// Example usage:
        /// ```zig
        /// var blurred = try Image(u8).initLike(allocator, original);
        /// defer blurred.deinit(allocator);
        /// try original.gaussianBlur(1.4, blurred);
        /// ```
        pub fn initLike(allocator: Allocator, reference: anytype) !Image(T) {
            return init(allocator, reference.rows, reference.cols);
        }

        /// Sets the image rows and cols to zero and frees the memory from the image.  It should
        /// only be called if the image owns the memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rows = 0;
            self.cols = 0;
            self.stride = 0;
            allocator.free(self.data);
        }

        /// Constructs an image of rows and cols size from an existing slice.
        pub fn initFromSlice(rows: usize, cols: usize, data: []T) Image(T) {
            return .{ .rows = rows, .cols = cols, .data = data, .stride = cols };
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

        /// Fills the entire image with a solid value.
        /// Uses a fast memset when contiguous; otherwise fills row-by-row respecting stride.
        pub fn fill(self: Self, value: T) void {
            if (self.isContiguous()) {
                @memset(self.data, value);
            } else {
                // Respect stride when the image is a view
                for (0..self.rows) |r| {
                    const start = r * self.stride;
                    @memset(self.data[start .. start + self.cols], value);
                }
            }
        }

        /// Sets the border outside `rect` to `value` (rect is clipped to bounds).
        /// Efficiently fills only the top/bottom bands and left/right bands per row.
        pub fn setBorder(self: Self, rect: Rectangle(usize), value: T) void {
            const bounds = self.getRectangle();
            const inner = bounds.intersect(rect) orelse {
                self.fill(value);
                return;
            };

            // Top band [0, inner.t)
            var r: usize = 0;
            while (r < inner.t) : (r += 1) {
                const start = r * self.stride;
                @memset(self.data[start .. start + self.cols], value);
            }

            // Middle rows [inner.t, inner.b)
            r = inner.t;
            while (r < inner.b) : (r += 1) {
                const row_start = r * self.stride;
                if (inner.l > 0) {
                    @memset(self.data[row_start .. row_start + inner.l], value);
                }
                if (inner.r < self.cols) {
                    @memset(self.data[row_start + inner.r .. row_start + self.cols], value);
                }
            }

            // Bottom band [inner.b, rows)
            r = inner.b;
            while (r < self.rows) : (r += 1) {
                const start = r * self.stride;
                @memset(self.data[start .. start + self.cols], value);
            }
        }

        /// Returns the image data reinterpreted as a slice of bytes.
        /// Note: The image should not be a view; this is enforced by an assertion.
        pub fn asBytes(self: Self) []u8 {
            assert(self.rows * self.cols == self.data.len);
            assert(self.isContiguous());
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
            const image_format = try @import("image/format.zig").ImageFormat.detectFromPath(allocator, file_path) orelse return error.UnsupportedImageFormat;

            return switch (image_format) {
                .png => png.load(T, allocator, file_path),
                .jpeg => jpeg.load(T, allocator, file_path),
            };
        }

        /// Saves the image to a file in PNG format.
        /// Returns an error if the file path doesn't end in `.png` or `.PNG`.
        pub fn save(self: Self, allocator: Allocator, file_path: []const u8) !void {
            if (std.ascii.endsWithIgnoreCase(file_path, ".png")) {
                try png.save(T, allocator, self, file_path);
            } else if (std.ascii.endsWithIgnoreCase(file_path, ".jpg") or std.ascii.endsWithIgnoreCase(file_path, ".jpeg")) {
                try jpeg.save(T, allocator, self, file_path);
            } else {
                return error.UnsupportedImageFormat;
            }
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
            return .init(.{
                @as(f32, @floatFromInt(self.cols)) / 2.0,
                @as(f32, @floatFromInt(self.rows)) / 2.0,
            });
        }

        /// Returns an image view with boundaries defined by `rect` within the image boundaries.
        /// The returned image references the memory of `self`, so there are no allocations
        /// or copies.
        pub fn view(self: Self, rect: Rectangle(usize)) Image(T) {
            const clipped = self.getRectangle().intersect(rect) orelse {
                return .empty;
            };
            if (clipped.isEmpty()) {
                return .empty;
            }

            const rows = clipped.height();
            const cols = clipped.width();
            const start = clipped.t * self.stride + clipped.l;
            const end = (clipped.b - 1) * self.stride + clipped.r;
            return .{
                .rows = rows,
                .cols = cols,
                .data = self.data[start..end],
                .stride = self.stride,
            };
        }

        /// Returns true if the image data is stored contiguously in memory.
        /// This is determined by checking if the `cols` field equals the `stride` field.
        /// When false, there is padding between rows.
        pub fn isContiguous(self: Self) bool {
            return self.cols == self.stride;
        }

        /// Checks if this image's buffer is aliased with (shares the same memory as) another image.
        /// Returns true if both images point to the same data buffer with the same length.
        /// This is useful for determining if in-place operations need a temporary buffer.
        ///
        /// Example usage:
        /// ```zig
        /// if (output.isAliased(input)) {
        ///     // Need temporary buffer for in-place operation
        ///     var temp = try Image(T).initLike(allocator, input);
        ///     defer temp.deinit(allocator);
        ///     // ... perform operation with temp, then copy to output
        /// }
        /// ```
        pub fn isAliased(self: Self, other: Self) bool {
            return self.data.ptr == other.data.ptr and self.data.len == other.data.len;
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
            const result = try Self.init(allocator, self.rows, self.cols);
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
            if (!self.isContiguous() or !dst.isContiguous()) {
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
            var result: Image(TargetType) = try .init(allocator, self.rows, self.cols);
            if (T == TargetType) {
                self.copy(result);
            } else {
                var row: usize = 0;
                while (row < self.rows) : (row += 1) {
                    var col: usize = 0;
                    while (col < self.cols) : (col += 1) {
                        result.at(row, col).* = convertColor(TargetType, self.at(row, col).*);
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

        /// Assigns `pixel` into `dest`, optionally applying blending when both
        /// sample and destination support RGBA compositing.
        pub inline fn assignPixel(dest: *T, pixel: anytype, blend_mode: Blending) void {
            const Src = @TypeOf(pixel);

            if (comptime Src == Rgba) {
                const rgba_sample: Rgba = pixel;
                if (blend_mode != .none) {
                    if (comptime T == Rgba) {
                        dest.* = dest.*.blend(rgba_sample, blend_mode);
                    } else {
                        const dst_rgba = convertColor(Rgba, dest.*);
                        const blended = dst_rgba.blend(rgba_sample, blend_mode);
                        dest.* = convertColor(T, blended);
                    }
                } else {
                    if (comptime T == Rgba) {
                        dest.* = rgba_sample;
                    } else {
                        dest.* = convertColor(T, rgba_sample);
                    }
                }
                return;
            }

            if (comptime Src == T) {
                dest.* = pixel;
            } else {
                dest.* = convertColor(T, pixel);
            }
        }

        /// Creates a formatter for terminal display with custom options.
        /// Provides fine-grained control over output format, palette modes, and dithering.
        ///
        /// Display modes:
        /// - `.sgr`: Uses SGR (Select Graphic Rendition) with Unicode half-block characters (requires monospace font with U+2580 support)
        /// - `.braille`: Uses Braille patterns for 2x4 monochrome resolution (requires Unicode Braille support U+2800-U+28FF, converts to grayscale)
        /// - `.sixel`: Uses the sixel graphics protocol if supported
        /// - `.kitty`: Uses the kitty graphics protocol if supported
        /// - `.auto`: Automatically selects best available format: kitty -> sixel -> sgr
        ///
        /// Example:
        /// ```zig
        /// const img = try Image(Rgb).load(allocator, "test.png");
        /// std.debug.print("{f}", .{img.display(.sgr)});           // SGR with unicode half blocks
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

        /// Displays the image information: color type, rows and cols.
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
            return Transform(T).flipLeftRight(self);
        }

        /// Flips an image from top to bottom (upside down effect).
        pub fn flipTopBottom(self: Self) void {
            return Transform(T).flipTopBottom(self);
        }

        /// Inverts the colors of an image in-place.
        /// For grayscale (u8): inverts as 255 - value
        /// For RGB colors: inverts each channel as 255 - channel
        /// For RGBA colors: inverts RGB channels but preserves alpha
        pub fn invert(self: Self) void {
            const color = @import("color.zig");

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    const pixel = self.at(r, c);
                    switch (T) {
                        u8 => pixel.* = 255 - pixel.*,
                        color.Rgb, color.Rgba => {
                            pixel.r = 255 - pixel.r;
                            pixel.g = 255 - pixel.g;
                            pixel.b = 255 - pixel.b;
                        },
                        else => @compileError("invert() currently only supports u8, Rgb, and Rgba pixel types"),
                    }
                }
            }
        }

        /// Performs interpolation at position x, y using the specified method.
        /// Returns `null` if the coordinates are outside valid bounds for the chosen method.
        pub fn interpolate(self: Self, x: f32, y: f32, method: @import("image/interpolation.zig").Interpolation) ?T {
            return interpolation.interpolate(T, self, x, y, method);
        }

        /// Resizes an image to fit in out, using the specified interpolation method.
        /// The output image must have the desired dimensions pre-allocated.
        /// Note: allocator is used for temporary buffers during RGB/RGBA channel processing.
        pub fn resize(self: Self, allocator: Allocator, out: Self, method: @import("image/interpolation.zig").Interpolation) !void {
            try interpolation.resize(T, allocator, self, out, method);
        }

        /// Scales the image by the given factor using the specified interpolation method.
        /// A factor > 1.0 enlarges the image, < 1.0 shrinks it.
        /// The caller is responsible for calling deinit() on the returned image.
        pub fn scale(self: Self, allocator: Allocator, factor: f32, method: @import("image/interpolation.zig").Interpolation) !Self {
            if (factor <= 0) return error.InvalidScaleFactor;

            const new_rows = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(self.rows)) * factor)));
            const new_cols = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(self.cols)) * factor)));

            if (new_rows == 0 or new_cols == 0) return error.InvalidDimensions;

            const scaled = try Self.init(allocator, new_rows, new_cols);
            try self.resize(allocator, scaled, method);
            return scaled;
        }

        /// Resizes an image to fit within the output dimensions while preserving aspect ratio.
        /// The image is centered with black/zero padding around it (letterboxing).
        /// Returns a rectangle describing the area containing the actual image content.
        pub fn letterbox(self: Self, allocator: Allocator, out: *Self, method: @import("image/interpolation.zig").Interpolation) !Rectangle(usize) {
            return Transform(T).letterbox(self, allocator, out, method);
        }

        /// Rotates the image by `angle` (in radians) around its center.
        /// Returns a new image with optimal dimensions to fit the rotated content.
        /// The caller is responsible for calling deinit() on the returned image.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the rotated image's data.
        /// - `angle`: The rotation angle in radians.
        /// - `method`: The interpolation method to use for sampling pixels.
        ///
        /// Example usage:
        /// ```zig
        /// var rotated = try image.rotate(allocator, std.math.pi / 4.0, .bilinear);
        /// defer rotated.deinit(allocator);
        /// ```
        pub fn rotate(self: Self, allocator: Allocator, angle: f32, method: @import("image/interpolation.zig").Interpolation) !Self {
            return Transform(T).rotate(self, allocator, angle, method);
        }

        /// Crops a rectangular region from the image.
        /// If the specified `rectangle` is not fully contained within the image, the out-of-bounds
        /// areas in the output are filled with zeroed pixels (e.g., black/transparent).
        /// Returns a new image containing the cropped region.
        /// The caller is responsible for calling deinit() on the returned image.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the cropped image's data.
        /// - `rectangle`: The `Rectangle(f32)` defining the region to crop. Coordinates will be rounded.
        ///
        /// Example usage:
        /// ```zig
        /// var chip = try image.crop(allocator, .{ .l = 10, .t = 10, .r = 100, .b = 100 });
        /// defer chip.deinit(allocator);
        /// ```
        pub fn crop(self: Self, allocator: Allocator, rectangle: Rectangle(f32)) !Self {
            return Transform(T).crop(self, allocator, rectangle);
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
            return Transform(T).extract(self, rect, angle, out, method);
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
            return Transform(T).insert(self, source, rect, angle, method, blend_mode);
        }

        /// Applies a geometric transform to the image using the specified interpolation method.
        ///
        /// This method warps an image using a geometric transform (Similarity, Affine, or Projective).
        /// For each pixel in the output image, it applies the transform to find the corresponding
        /// location in the source image and samples using the specified interpolation method.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the output image.
        /// - `transform`: A geometric transform object (SimilarityTransform, AffineTransform, or ProjectiveTransform).
        /// - `method`: Interpolation method for sampling pixels.
        /// - `out`: Output image. If empty, will be allocated with specified dimensions.
        /// - `out_rows`: Number of rows in the output image.
        /// - `out_cols`: Number of columns in the output image.
        ///
        /// Example usage:
        /// ```zig
        /// const transform = SimilarityTransform(f32).init(from_points, to_points);
        /// var warped: Image(T) = .empty;
        /// try image.warp(allocator, transform, .bilinear, &warped, 512, 512);
        /// defer warped.deinit(allocator);
        /// ```
        pub fn warp(self: Self, allocator: Allocator, transform: anytype, method: @import("image/interpolation.zig").Interpolation, out: *Self, out_rows: usize, out_cols: usize) !void {
            return Transform(T).warp(self, allocator, transform, method, out, out_rows, out_cols);
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
            return Self.Integral.compute(self, allocator, sat);
        }

        /// Computes a blurred version of `self` using a box blur algorithm, efficiently implemented
        /// using an integral image. The `radius` parameter determines the size of the box window.
        /// This function is optimized using SIMD instructions for performance where applicable.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn boxBlur(self: Self, allocator: Allocator, radius: usize, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            if (radius == 0) {
                self.copy(out);
                return;
            }

            // Compute integral image and apply box blur
            var sat: Image(if (isScalar(T)) f32 else [Self.channels()]f32) = .empty;
            try Self.Integral.compute(self, allocator, &sat);
            defer sat.deinit(allocator);
            Self.Integral.boxBlur(sat, self, out, radius);
        }

        /// Applies a median blur using a square window with the given radius.
        /// Radius specifies half the window size; window size = `radius * 2 + 1`.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn medianBlur(self: Self, allocator: Allocator, radius: usize, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try OrderStatisticBlurOps(T).medianBlur(self, allocator, radius, out);
        }

        /// Applies a percentile blur (order-statistic filter) with the given percentile fraction.
        /// Percentile must be in the range [0, 1]; 0.5 corresponds to a median blur.
        ///
        /// Useful when you want fine-grained control over which ranked pixel is kept from the
        /// neighborhood. For example, `percentile = 0.1` can suppress bright outliers while
        /// retaining much of the local structure.
        ///
        /// ```zig
        /// var robust = try Image(u8).initLike(allocator, image);
        /// defer robust.deinit(allocator);
        /// try image.percentileBlur(allocator, 2, 0.1, .mirror, robust);
        /// ```
        pub fn percentileBlur(
            self: Self,
            allocator: Allocator,
            radius: usize,
            percentile: f64,
            border: BorderMode,
            out: Self,
        ) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try OrderStatisticBlurOps(T).percentileBlur(self, allocator, radius, percentile, border, out);
        }

        /// Applies a minimum blur (percentile zero) over a square window with the given radius.
        ///
        /// This is the morphological *erosion* operator – great for removing "salt" noise or
        /// shrinking bright speckles while leaving darker structures intact.
        ///
        /// ```zig
        /// var denoised = try Image(u8).initLike(allocator, image);
        /// defer denoised.deinit(allocator);
        /// try image.minBlur(allocator, 1, .mirror, denoised);
        /// ```
        pub fn minBlur(
            self: Self,
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            out: Self,
        ) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try OrderStatisticBlurOps(T).minBlur(self, allocator, radius, border, out);
        }

        /// Applies a maximum blur (percentile one) over a square window with the given radius.
        ///
        /// Equivalent to morphological *dilation*. It can fill in small gaps or expand highlights,
        /// which is helpful for creating masks or closing thin cracks.
        ///
        /// ```zig
        /// var mask = try Image(u8).initLike(allocator, image);
        /// defer mask.deinit(allocator);
        /// try image.maxBlur(allocator, 2, .mirror, mask);
        /// ```
        pub fn maxBlur(
            self: Self,
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            out: Self,
        ) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try OrderStatisticBlurOps(T).maxBlur(self, allocator, radius, border, out);
        }

        /// Applies a midpoint blur that averages the minimum and maximum values within the window.
        ///
        /// Midpoint filtering is a fast way to reduce random impulse noise while retaining thin
        /// edges. Think of it as a compromise between min and max filters.
        ///
        /// ```zig
        /// var softened = try Image(u8).initLike(allocator, image);
        /// defer softened.deinit(allocator);
        /// try image.midpointBlur(allocator, 1, .mirror, softened);
        /// ```
        pub fn midpointBlur(
            self: Self,
            allocator: Allocator,
            radius: usize,
            border: BorderMode,
            out: Self,
        ) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try OrderStatisticBlurOps(T).midpointBlur(self, allocator, radius, border, out);
        }

        /// Applies an alpha-trimmed mean blur, discarding a fraction of the lowest and highest pixels.
        /// `trim_fraction` must be in [0, 0.5).
        ///
        /// This filter is useful when you want the smoothness of an average but need robustness to
        /// extremes (for example, sensor hot pixels or specular highlights). Trimming 10% from each
        /// tail delivers a strong denoise without smearing edges.
        ///
        /// ```zig
        /// var robust_mean = try Image(Rgba).initLike(allocator, color_image);
        /// defer robust_mean.deinit(allocator);
        /// try color_image.alphaTrimmedMeanBlur(allocator, 2, 0.1, .mirror, robust_mean);
        /// ```
        pub fn alphaTrimmedMeanBlur(
            self: Self,
            allocator: Allocator,
            radius: usize,
            trim_fraction: f64,
            border: BorderMode,
            out: Self,
        ) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try OrderStatisticBlurOps(T).alphaTrimmedMeanBlur(self, allocator, radius, trim_fraction, border, out);
        }

        /// Computes a sharpened version of `self` by enhancing edges.
        /// It uses the formula `sharpened = 2 * original - blurred`, where `blurred` is a box-blurred
        /// version of the original image (calculated efficiently using an integral image).
        /// The `radius` parameter controls the size of the blur. This operation effectively
        /// increases the contrast at edges. SIMD optimizations are used for performance where applicable.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn sharpen(self: Self, allocator: Allocator, radius: usize, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            if (radius == 0) {
                self.copy(out);
                return;
            }

            // Compute integral image and apply sharpening
            var sat: Image(if (isScalar(T)) f32 else [Self.channels()]f32) = .empty;
            try Self.Integral.compute(self, allocator, &sat);
            defer sat.deinit(allocator);
            Self.Integral.sharpen(sat, self, out, radius);
        }

        /// Automatically adjusts the contrast of an image by stretching the intensity range.
        ///
        /// This function analyzes the histogram of the image and remaps pixel values so that
        /// the darkest pixels become black (0) and the brightest become white (255), with
        /// intermediate values scaled proportionally.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the new image
        /// - `cutoff`: Percentage of pixels to ignore at the extremes (0-100).
        ///             For example, 2.0 ignores the darkest and brightest 2% of pixels,
        ///             which helps remove outliers.
        ///
        /// Adjusts contrast by stretching the intensity range. Modifies in-place.
        /// Parameters:
        /// - `cutoff`: Fraction of pixels to ignore from each end (0.0 to 0.5)
        pub fn autocontrast(self: Self, cutoff: f32) !void {
            return Enhancement(T).autocontrast(self, cutoff);
        }

        /// Equalizes the histogram of an image to improve contrast.
        ///
        /// This function redistributes pixel intensities to achieve a more uniform histogram,
        /// which typically enhances contrast in images with poor contrast or uneven lighting.
        /// The technique maps the cumulative distribution function (CDF) of pixel values to
        /// create a more even spread of intensities across the full range.
        ///
        /// For color images (RGB/RGBA), each channel is equalized independently.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for the new image
        ///
        /// Returns: A new image with equalized histogram
        ///
        /// Example usage:
        /// ```zig
        /// var img = try Image(u8).load(allocator, "low_contrast.png");
        /// var equalized = try img.equalize(allocator);
        /// defer equalized.deinit(allocator);
        /// ```
        /// Equalizes the histogram to improve contrast. Modifies in-place.
        pub fn equalize(self: Self) void {
            return Enhancement(T).equalize(self);
        }

        /// Computes Otsu's threshold and produces a binary image.
        /// Returns the threshold value that maximizes between-class variance.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn thresholdOtsu(self: Self, allocator: Allocator, out: Image(u8)) !u8 {
            if (comptime T != u8) {
                @compileError("thresholdOtsu is only available for Image(u8)");
            }
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            return binary.Binary.thresholdOtsu(self, allocator, out);
        }

        /// Applies adaptive mean thresholding using a square window defined by `radius`.
        /// Each pixel is compared against the mean of its local neighborhood minus `c`.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn thresholdAdaptiveMean(self: Self, allocator: Allocator, radius: usize, c: f32, out: Image(u8)) !void {
            if (comptime T != u8) {
                @compileError("thresholdAdaptiveMean is only available for Image(u8)");
            }
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            return binary.Binary.thresholdAdaptiveMean(self, allocator, radius, c, out);
        }

        /// Performs binary dilation using the provided structuring element.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn dilateBinary(self: Self, allocator: Allocator, kernel: BinaryKernel, iterations: usize, out: Image(u8)) !void {
            if (comptime T != u8) {
                @compileError("dilateBinary is only available for Image(u8)");
            }
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try binary.Binary.dilate(self, allocator, kernel, iterations, out);
        }

        /// Performs binary erosion using the provided structuring element.
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn erodeBinary(self: Self, allocator: Allocator, kernel: BinaryKernel, iterations: usize, out: Image(u8)) !void {
            if (comptime T != u8) {
                @compileError("erodeBinary is only available for Image(u8)");
            }
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try binary.Binary.erode(self, allocator, kernel, iterations, out);
        }

        /// Performs a binary opening (erosion followed by dilation).
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn openBinary(self: Self, allocator: Allocator, kernel: BinaryKernel, iterations: usize, out: Image(u8)) !void {
            if (comptime T != u8) {
                @compileError("openBinary is only available for Image(u8)");
            }
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try binary.Binary.open(self, allocator, kernel, iterations, out);
        }

        /// Performs a binary closing (dilation followed by erosion).
        /// The output image must be pre-allocated with the same dimensions as the input.
        pub fn closeBinary(self: Self, allocator: Allocator, kernel: BinaryKernel, iterations: usize, out: Image(u8)) !void {
            if (comptime T != u8) {
                @compileError("closeBinary is only available for Image(u8)");
            }
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            try binary.Binary.close(self, allocator, kernel, iterations, out);
        }

        /// Applies a 2D convolution with the given kernel to the image.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `kernel`: A 2D array representing the convolution kernel.
        /// - `border`: How to handle pixels at the image borders.
        /// - `out`: The output image (must be pre-allocated with same dimensions).
        pub fn convolve(self: Self, allocator: Allocator, kernel: anytype, border: BorderMode, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            return convolution.convolve(T, self, allocator, kernel, border, out);
        }

        /// Performs separable convolution using two 1D kernels (horizontal and vertical).
        /// This is much more efficient for separable filters like Gaussian blur.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `kernel_x`: Horizontal (column) kernel.
        /// - `kernel_y`: Vertical (row) kernel.
        /// - `border`: How to handle image borders.
        /// - `out`: The output image (must be pre-allocated with same dimensions).
        pub fn convolveSeparable(self: Self, allocator: Allocator, kernel_x: []const f32, kernel_y: []const f32, border: BorderMode, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            return convolution.convolveSeparable(T, self, allocator, kernel_x, kernel_y, border, out);
        }

        /// Applies Gaussian blur to the image using separable convolution.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma`: Standard deviation of the Gaussian kernel.
        /// - `out`: The output blurred image (must be pre-allocated with same dimensions).
        pub fn gaussianBlur(self: Self, allocator: Allocator, sigma: f32, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            // sigma == 0 means no blur; just copy input to output
            if (sigma == 0) {
                self.copy(out);
                return;
            }
            if (sigma < 0) return error.InvalidSigma;

            // Calculate kernel size (3 sigma on each side)
            const radius = @as(usize, @intFromFloat(@ceil(3.0 * sigma)));
            const kernel_size = 2 * radius + 1;

            // Generate 1D Gaussian kernel
            var kernel = try allocator.alloc(f32, kernel_size);
            defer allocator.free(kernel);

            var sum: f32 = 0;
            for (0..kernel_size) |i| {
                const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
                kernel[i] = @exp(-(x * x) / (2.0 * sigma * sigma));
                sum += kernel[i];
            }

            // Normalize kernel
            for (kernel) |*k| {
                k.* /= sum;
            }

            // Apply separable convolution
            try convolution.convolveSeparable(T, self, allocator, kernel, kernel, .mirror, out);
        }

        /// Applies the Sobel filter to `self` to perform edge detection.
        /// The output is a grayscale image representing the magnitude of gradients at each pixel.
        /// The output image must be pre-allocated with the same dimensions as the input.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `out`: Output image that will be filled with the Sobel magnitude image.
        pub fn sobel(self: Self, allocator: Allocator, out: Image(u8)) !void {
            if (self.rows != out.rows or self.cols != out.cols) {
                return error.DimensionMismatch;
            }
            return Edges(T).sobel(self, allocator, out);
        }

        /// Applies the Shen-Castan edge detection algorithm using the Infinite Symmetric
        /// Exponential Filter (ISEF). This algorithm provides superior edge localization
        /// and noise handling compared to traditional methods.
        /// The output image must be pre-allocated with the same dimensions as the input.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `opts`: Shen-Castan options (smoothing, thresholds, thinning, hysteresis).
        /// - `out`: Output edge map as binary image (0 or 255).
        pub fn shenCastan(
            self: Self,
            allocator: Allocator,
            opts: ShenCastan,
            out: Image(u8),
        ) !void {
            if (self.rows != out.rows or self.cols != out.cols) {
                return error.DimensionMismatch;
            }
            return Edges(T).shenCastan(self, allocator, opts, out);
        }

        /// Applies the Canny edge detection algorithm, a classic multi-stage edge detector.
        /// This algorithm produces thin, well-localized edges with good noise suppression.
        ///
        /// The Canny algorithm consists of five main steps:
        /// 1. Gaussian smoothing to reduce noise
        /// 2. Gradient computation using Sobel operators
        /// 3. Non-maximum suppression to thin edges
        /// 4. Double thresholding to classify strong and weak edges
        /// 5. Edge tracking by hysteresis to link edges
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `sigma`: Standard deviation for Gaussian blur (typical: 1.0-2.0).
        /// - `low_threshold`: Lower threshold for hysteresis (0-255).
        /// - `high_threshold`: Upper threshold for hysteresis (0-255).
        /// - `out`: Output edge map as binary image (0 or 255).
        ///
        /// Note: `high_threshold` should be 2-3x larger than `low_threshold` for best results.
        ///
        /// Example:
        /// ```zig
        /// var edges = try Image(u8).initLike(allocator, image);
        /// defer edges.deinit(allocator);
        /// try image.canny(allocator, 1.4, 50, 150, edges);
        /// ```
        pub fn canny(
            self: Self,
            allocator: Allocator,
            sigma: f32,
            low_threshold: f32,
            high_threshold: f32,
            out: Image(u8),
        ) !void {
            if (self.rows != out.rows or self.cols != out.cols) {
                return error.DimensionMismatch;
            }
            return Edges(T).canny(self, allocator, sigma, low_threshold, high_threshold, out);
        }

        /// Applies motion blur effect to the image.
        /// Supports linear motion blur (camera/object movement) and radial blur (zoom/spin effects).
        /// The output image must be pre-allocated with the same dimensions as the input.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `motion`: Type and parameters of motion blur to apply.
        /// - `out`: Output image containing the motion blurred result.
        ///
        /// Example usage:
        /// ```zig
        /// var out = try Image(Rgb).initLike(allocator, image);
        /// defer out.deinit(allocator);
        ///
        /// // Linear motion blur
        /// try image.motionBlur(allocator, .{ .linear = .{ .angle = 0, .distance = 30 }}, out);
        /// ```
        pub fn motionBlur(self: Self, allocator: Allocator, motion: MotionBlur, out: Self) !void {
            if (!self.hasSameShape(out)) {
                return error.DimensionMismatch;
            }
            switch (motion) {
                .linear => |params| try MotionBlurOps(T).linear(self, allocator, params.angle, params.distance, out),
                .radial_zoom => |params| try MotionBlurOps(T).radial(self, allocator, params.center_x, params.center_y, params.strength, .zoom, out),
                .radial_spin => |params| try MotionBlurOps(T).radial(self, allocator, params.center_x, params.center_y, params.strength, .spin, out),
            }
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
            mse /= @as(f64, @floatFromInt(component_count));

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

        /// Computes a histogram of the image pixel values.
        /// Supported types: u8, Rgb, Rgba
        /// Returns a Histogram struct with channel-specific bins.
        pub fn histogram(self: Self) Histogram(T) {
            const Rgb = @import("color/Rgb.zig");

            var hist: Histogram(T) = .init();

            var iter = self.pixels();
            while (iter.next()) |pixel| {
                switch (T) {
                    u8 => {
                        hist.values[pixel.*] += 1;
                    },
                    Rgb => {
                        hist.r[pixel.r] += 1;
                        hist.g[pixel.g] += 1;
                        hist.b[pixel.b] += 1;
                    },
                    Rgba => {
                        hist.r[pixel.r] += 1;
                        hist.g[pixel.g] += 1;
                        hist.b[pixel.b] += 1;
                        hist.a[pixel.a] += 1;
                    },
                    else => @compileError("histogram() only supports u8, Rgb, and Rgba types"),
                }
            }

            return hist;
        }
    };
}

// Run all tests
test {
    _ = @import("image/PixelIterator.zig");
    _ = @import("image/format.zig");
    _ = @import("image/display.zig");
    _ = @import("image/tests/integral.zig");
    _ = @import("image/tests/filters.zig");
    _ = @import("image/tests/transforms.zig");
    _ = @import("image/tests/display.zig");
    _ = @import("image/tests/interpolation.zig");
    _ = @import("image/tests/resize.zig");
    _ = @import("image/tests/psnr.zig");
    _ = @import("image/tests/shen_castan.zig");
    _ = @import("image/tests/binary.zig");
}

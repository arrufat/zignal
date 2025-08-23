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
const Transform = @import("transforms.zig").Transform;
const RotationBounds = @import("transforms.zig").RotationBounds;
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

        /// Constructs an image of rows and cols size allocating its own memory.
        /// The image owns the memory and deinit should be called to free it.
        pub fn init(allocator: Allocator, rows: usize, cols: usize) !Image(T) {
            return .{ .rows = rows, .cols = cols, .data = try allocator.alloc(T, rows * cols), .stride = cols };
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
                .stride = self.stride,
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
            var result: Image(TargetType) = try .init(allocator, self.rows, self.cols);
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
            return Transform(T).flipLeftRight(self);
        }

        /// Flips an image from top to bottom (upside down effect).
        pub fn flipTopBottom(self: Self) void {
            return Transform(T).flipTopBottom(self);
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

            const scaled = try Self.init(allocator, new_rows, new_cols);
            try self.resize(allocator, scaled, method);
            return scaled;
        }

        /// Resizes an image to fit within the output dimensions while preserving aspect ratio.
        /// The image is centered with black/zero padding around it (letterboxing).
        /// Returns a rectangle describing the area containing the actual image content.
        pub fn letterbox(self: Self, allocator: Allocator, out: *Self, method: InterpolationMethod) !Rectangle(usize) {
            return Transform(T).letterbox(self, allocator, out, method);
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
            return Transform(T).rotateBounds(self, angle);
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
            return Transform(T).rotate(self, gpa, angle, method, rotated);
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
            return Transform(T).crop(self, allocator, rectangle, chip);
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
            return Transform(T).extract(self, rect, angle, out, method);
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
            return Transform(T).insert(self, source, rect, angle, method);
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

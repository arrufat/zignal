//! Core image operations: I/O, memory management, type conversion

const std = @import("std");

const zignal = @import("zignal");
const Image = zignal.Image;
const ImageFormat = zignal.ImageFormat;

const canvas = @import("../canvas.zig");
const color_bindings = @import("../color.zig");
const parseColorTo = @import("../color_utils.zig").parseColor;
const moveImageToPython = @import("../image.zig").moveImageToPython;
const ImageObject = @import("../image.zig").ImageObject;
const getImageType = @import("../image.zig").getImageType;
const PyImageMod = @import("../PyImage.zig");
const PyImage = PyImageMod.PyImage;
const python = @import("../python.zig");
const ctx = python.ctx;
const allocator = ctx.allocator;
const c = python.c;
const rectangle = @import("../rectangle.zig");

const Rgba = zignal.Rgba(u8);
const Rgb = zignal.Rgb(u8);
const default_png_limits: zignal.png.DecodeLimits = .{};
const file_png_limits: zignal.png.DecodeLimits = .{ .max_png_bytes = 100 * 1024 * 1024 };
const default_jpeg_limits: zignal.jpeg.DecodeLimits = .{};
const file_jpeg_limits: zignal.jpeg.DecodeLimits = .{
    .max_jpeg_bytes = 200 * 1024 * 1024,
    .max_marker_bytes = 16 * 1024 * 1024,
};

// Import the ImageObject type from parent
inline fn readLimit(max_bytes: usize) usize {
    return if (max_bytes == 0) std.math.maxInt(usize) else max_bytes;
}

fn setDecodeError(kind: []const u8, err: anyerror) void {
    switch (err) {
        error.OutOfMemory => python.setMemoryError(kind),
        else => python.setValueError("Failed to decode {s}: {s}", .{ kind, @errorName(err) }),
    }
}

fn wrapNativeImage(native: anytype) ?*c.PyObject {
    switch (native) {
        inline else => |img| {
            return @ptrCast(moveImageToPython(img) orelse return null);
        },
    }
}

fn loadBytes(comptime format: ImageFormat, data: []const u8) ?*c.PyObject {
    switch (format) {
        .png => {
            const kind = "PNG data";
            var decoded = zignal.png.decode(allocator, data, default_png_limits) catch |err| {
                setDecodeError(kind, err);
                return null;
            };
            defer decoded.deinit(allocator);
            const native = zignal.png.toNativeImage(allocator, decoded) catch |err| {
                setDecodeError(kind, err);
                return null;
            };
            return wrapNativeImage(native);
        },
        .jpeg => {
            const kind = "JPEG data";
            var decoded = zignal.jpeg.decode(allocator, data, default_jpeg_limits) catch |err| {
                setDecodeError(kind, err);
                return null;
            };
            defer decoded.deinit();
            const native = zignal.jpeg.toNativeImage(allocator, &decoded) catch |err| {
                setDecodeError(kind, err);
                return null;
            };
            return wrapNativeImage(native);
        },
    }
}

// ============================================================================
// IMAGE LOAD
// ============================================================================

pub const image_load_doc =
    \\Load an image from file (PNG or JPEG).
    \\
    \\The pixel format (Gray, Rgb, or Rgba) is automatically determined from the
    \\file metadata. For PNGs, the format matches the file's color type. For JPEGs,
    \\grayscale images load as Gray, color images as Rgb.
    \\
    \\## Parameters
    \\- `path` (str): Path to the PNG or JPEG file to load
    \\
    \\## Returns
    \\Image: A new Image object with pixels in the format matching the file
    \\
    \\## Raises
    \\- `FileNotFoundError`: If the file does not exist
    \\- `ValueError`: If the file format is unsupported
    \\- `MemoryError`: If allocation fails during loading
    \\- `PermissionError`: If read permission is denied
    \\
    \\## Examples
    \\```python
    \\# Load images with automatic format detection
    \\img = Image.load("photo.png")     # May be Rgba
    \\img2 = Image.load("grayscale.jpg") # Will be Gray
    \\img3 = Image.load("rgb.png")       # Will be Rgb
    \\
    \\# Check format after loading
    \\print(img.dtype)  # e.g., Rgba, Rgb, or Gray
    \\```
;

pub fn image_load(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;

    const Params = struct { path: [*c]const u8 };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const path_slice = std.mem.span(params.path);

    // Detect format and load accordingly
    const is_jpeg = std.mem.endsWith(u8, path_slice, ".jpg") or
        std.mem.endsWith(u8, path_slice, ".jpeg") or
        std.mem.endsWith(u8, path_slice, ".JPG") or
        std.mem.endsWith(u8, path_slice, ".JPEG");

    if (is_jpeg) {
        // Read file and decode JPEG
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path_slice, allocator, .limited(readLimit(file_jpeg_limits.max_jpeg_bytes))) catch |err| {
            python.setErrorWithPath(err, path_slice);
            return null;
        };
        defer allocator.free(data);

        var decoded = zignal.jpeg.decode(allocator, data, file_jpeg_limits) catch |err| {
            python.setErrorWithPath(err, path_slice);
            return null;
        };
        defer decoded.deinit();

        const native = zignal.jpeg.toNativeImage(allocator, &decoded) catch |err| {
            python.setErrorWithPath(err, path_slice);
            return null;
        };
        switch (native) {
            inline else => |img| {
                return @ptrCast(moveImageToPython(img) orelse return null);
            },
        }
    }

    // PNG: load native dtype (Gray, RGB, RGBA)
    if (std.mem.endsWith(u8, path_slice, ".png") or std.mem.endsWith(u8, path_slice, ".PNG")) {
        const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path_slice, allocator, .limited(readLimit(file_png_limits.max_png_bytes))) catch |err| {
            python.setErrorWithPath(err, path_slice);
            return null;
        };
        defer allocator.free(data);
        var decoded = zignal.png.decode(allocator, data, file_png_limits) catch |err| {
            python.setErrorWithPath(err, path_slice);
            return null;
        };
        defer decoded.deinit(allocator);
        const native = zignal.png.toNativeImage(allocator, decoded) catch |err| {
            python.setErrorWithPath(err, path_slice);
            return null;
        };
        switch (native) {
            inline else => |img| {
                return @ptrCast(moveImageToPython(img) orelse return null);
            },
        }
    }

    // Default: Try to load as RGB
    const image = Image(Rgb).load(ctx.io, allocator, path_slice) catch |err| {
        python.setErrorWithPath(err, path_slice);
        return null;
    };
    return @ptrCast(moveImageToPython(image) orelse return null);
}

pub const image_load_from_bytes_doc =
    \\Load an image from an in-memory bytes-like object (PNG or JPEG).
    \\
    \\Accepts any object that implements the Python buffer protocol, such as
    \\`bytes`, `bytearray`, or `memoryview`. The image format is detected from
    \\the data's file signature, so no file extension is required.
    \\
    \\## Parameters
    \\- `data` (bytes-like): Raw PNG or JPEG bytes.
    \\
    \\## Returns
    \\Image: A new Image with pixel storage matching the encoded file (Gray, Rgb, or Rgba).
    \\
    \\## Raises
    \\- `ValueError`: If the buffer is empty or the format is unsupported
    \\- `MemoryError`: If allocation fails during decoding
    \\
    \\## Examples
    \\```python
    \\payload = http_response.read()
    \\img = Image.load_from_bytes(payload)
    \\```
;

pub fn image_load_from_bytes(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;

    const Params = struct {
        data: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const data_obj = params.data orelse {
        python.setTypeError("bytes-like object", null);
        return null;
    };

    if (c.PyObject_CheckBuffer(data_obj) == 0) {
        python.setTypeError("bytes-like object", data_obj);
        return null;
    }

    var buffer: c.Py_buffer = std.mem.zeroes(c.Py_buffer);
    if (c.PyObject_GetBuffer(data_obj, &buffer, c.PyBUF_CONTIG_RO) != 0) {
        return null;
    }
    defer c.PyBuffer_Release(&buffer);

    if (buffer.len == 0) {
        python.setValueError("Image data buffer cannot be empty", .{});
        return null;
    }

    const byte_ptr: [*]const u8 = @ptrCast(buffer.buf);
    const data_slice = byte_ptr[0..@intCast(buffer.len)];

    const detected = ImageFormat.detectFromBytes(data_slice) orelse {
        python.setValueError("Unsupported image data: expected PNG or JPEG signature", .{});
        return null;
    };

    return switch (detected) {
        .png => loadBytes(.png, data_slice),
        .jpeg => loadBytes(.jpeg, data_slice),
    };
}

// ============================================================================
// IMAGE SAVE
// ============================================================================

pub const image_save_doc =
    \\Save the image to a file (PNG or JPEG format).
    \\
    \\The format is determined by the file extension (.png, .jpg, or .jpeg).
    \\
    \\## Parameters
    \\- `path` (str): Path where the image file will be saved.
    \\  Must have .png, .jpg, or .jpeg extension.
    \\
    \\## Raises
    \\- `ValueError`: If the file has an unsupported extension
    \\- `MemoryError`: If allocation fails during save
    \\- `PermissionError`: If write permission is denied
    \\- `FileNotFoundError`: If the directory does not exist
    \\
    \\## Examples
    \\```python
    \\img = Image.load("input.png")
    \\img.save("output.png")   # Save as PNG
    \\img.save("output.jpg")   # Save as JPEG
    \\```
;

pub fn image_save(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { path: [*c]const u8 };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const path_slice = std.mem.span(params.path);

    return self.py_image.?.dispatch(.{path_slice}, struct {
        fn apply(img: anytype, path: []const u8) ?*c.PyObject {
            img.save(ctx.io, allocator, path) catch |err| {
                if (err == error.UnsupportedImageFormat) {
                    python.setValueError("Unsupported image format. File must have a valid PNG or JPEG extension.", .{});
                    return null;
                }
                python.setErrorWithPath(err, path);
                return null;
            };
            return python.none();
        }
    }.apply);
}

// ============================================================================
// IMAGE COPY
// ============================================================================

pub const image_copy_doc =
    \\Create a deep copy of the image.
    \\
    \\Returns a new Image with the same dimensions and pixel data,
    \\but with its own allocated memory.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\copy = img.copy()
    \\# Modifying copy doesn't affect original
    \\copy[0, 0] = (255, 0, 0)
    \\```
;

pub fn image_copy(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    return self.py_image.?.dispatch(.{}, struct {
        fn apply(img: anytype) ?*c.PyObject {
            const T = @TypeOf(img.data[0]);
            const copy = Image(T).init(allocator, img.rows, img.cols) catch {
                python.setMemoryError("image data");
                return null;
            };
            img.copy(copy);
            return @ptrCast(moveImageToPython(copy) orelse return null);
        }
    }.apply);
}

// ============================================================================
// IMAGE FILL
// ============================================================================

pub const image_fill_doc =
    \\Fill the entire image with a solid color.
    \\
    \\## Parameters
    \\- `color`: Fill color. Can be:
    \\  - Integer (0-255) for grayscale images
    \\  - RGB tuple (r, g, b) with values 0-255
    \\  - RGBA tuple (r, g, b, a) with values 0-255
    \\  - Any color object (Rgb, Hsl, Hsv, etc.)
    \\
    \\## Examples
    \\```python
    \\img = Image(100, 100)
    \\img.fill((255, 0, 0))  # Fill with red
    \\```
;

pub fn image_fill(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { color: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return self.py_image.?.dispatch(.{params.color}, struct {
        fn apply(img: anytype, color_obj: ?*c.PyObject) ?*c.PyObject {
            const T = @TypeOf(img.data[0]);
            img.fill(parseColorTo(T, color_obj) catch return null);
            return python.none();
        }
    }.apply);
}

// ============================================================================
// IMAGE VIEW
// ============================================================================

pub const image_view_doc =
    \\Create a view of the image or a sub-region (zero-copy).
    \\
    \\Creates a new Image that shares the same underlying pixel data. Changes
    \\to the view affect the original image and vice versa.
    \\
    \\## Parameters
    \\- `rect` (Rectangle | tuple[float, float, float, float] | None): Optional rectangle
    \\  defining the sub-region to view. If None, creates a view of the entire image.
    \\  When providing a tuple, it should be (left, top, right, bottom).
    \\
    \\## Returns
    \\Image: A view of the image that shares the same pixel data
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\# View entire image
    \\view = img.view()
    \\# View sub-region
    \\rect = Rectangle(10, 10, 100, 100)
    \\sub = img.view(rect)
    \\# Modifications to view affect original
    \\sub.fill((255, 0, 0))  # Fills region in original image
    \\```
;

pub fn image_view(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { rect: ?*c.PyObject = null };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const pimg_view = self.py_image.?.dispatch(.{params.rect}, struct {
        fn apply(img: anytype, rect_obj: ?*c.PyObject) ?*PyImage {
            if (rect_obj) |ro| {
                const rect = python.parse(zignal.Rectangle(usize), ro) catch return null;
                return PyImage.createFrom(allocator, img.view(rect), .borrowed);
            } else {
                const full_rect = zignal.Rectangle(usize).init(0, 0, img.cols, img.rows);
                return PyImage.createFrom(allocator, img.view(full_rect), .borrowed);
            }
        }
    }.apply) orelse {
        python.setMemoryError("image view");
        return null;
    };

    return @import("../image.zig").wrapPyImage(pimg_view, self_obj);
}

// ============================================================================
// IMAGE IS_CONTIGUOUS
// ============================================================================

pub const image_is_contiguous_doc =
    \\Check if the image data is stored contiguously in memory.
    \\
    \\Returns True if pixels are stored without gaps (stride == cols),
    \\False for views or images with custom strides.
    \\
    \\## Examples
    \\```python
    \\img = Image(100, 100)
    \\print(img.is_contiguous())  # True
    \\view = img.view(Rectangle(10, 10, 50, 50))
    \\print(view.is_contiguous())  # False
    \\```
;

pub fn image_is_contiguous(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const is_contig = self.py_image.?.dispatch(.{}, struct {
        fn apply(img: anytype) bool {
            return img.isContiguous();
        }
    }.apply);

    return @ptrCast(python.create(is_contig));
}

// ============================================================================
// IMAGE GET_RECTANGLE
// ============================================================================

pub const image_get_rectangle_doc =
    \\Get the full image bounds as a Rectangle(left=0, top=0, right=cols, bottom=rows).
;

pub fn image_get_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    return self.py_image.?.dispatch(.{}, struct {
        fn apply(img: anytype) ?*c.PyObject {
            const left: f64 = 0.0;
            const top: f64 = 0.0;
            const right: f64 = @floatFromInt(img.cols);
            const bottom: f64 = @floatFromInt(img.rows);
            const args_tuple = c.Py_BuildValue("(dddd)", left, top, right, bottom) orelse return null;
            defer c.Py_DECREF(args_tuple);
            return c.PyObject_CallObject(@ptrCast(&rectangle.RectangleType), args_tuple);
        }
    }.apply);
}

// ============================================================================
// IMAGE CONVERT
// ============================================================================

pub const image_convert_doc =
    \\
    \\Convert the image to a different pixel data type.
    \\
    \\Supported targets: Gray, Rgb, Rgba.
    \\
    \\Returns a new Image with the requested format.
;

pub fn image_convert(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { dtype: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const dtype_obj = params.dtype;

    if (dtype_obj == null) {
        python.setTypeError("target dtype (zignal.Gray, zignal.Rgb, or zignal.Rgba)", null);
        return null;
    }

    // Determine target type
    var target_gray = false;
    var target_rgb = false;
    var target_rgba = false;

    // TODO: Remove explicit cast after Python 3.10 is dropped
    const is_type_obj = c.PyObject_TypeCheck(dtype_obj.?, @as([*c]c.PyTypeObject, @ptrCast(&c.PyType_Type))) != 0;
    // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
    if (is_type_obj) {
        if (dtype_obj.? == @as(*c.PyObject, @ptrCast(&color_bindings.gray))) {
            target_gray = true;
        } else if (dtype_obj.? == @as(*c.PyObject, @ptrCast(&color_bindings.rgb))) {
            target_rgb = true;
        } else if (dtype_obj.? == @as(*c.PyObject, @ptrCast(&color_bindings.rgba))) {
            target_rgba = true;
        } else {
            python.setTypeError("zignal.Gray, zignal.Rgb, or zignal.Rgba", dtype_obj);
            return null;
        }
    } else {
        if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.gray)) == 1) {
            target_gray = true;
        } else if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.rgb)) == 1) {
            target_rgb = true;
        } else if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.rgba)) == 1) {
            target_rgba = true;
        } else {
            python.setTypeError("zignal.Gray, zignal.Rgb, or zignal.Rgba", dtype_obj);
            return null;
        }
    }

    return self.py_image.?.dispatch(.{ target_gray, target_rgb, target_rgba }, struct {
        fn apply(img: anytype, t_gray: bool, t_rgb: bool, t_rgba: bool) ?*c.PyObject {
            const T = @TypeOf(img.data[0]);
            if (t_gray) {
                if (T == u8) {
                    const out = Image(u8).init(allocator, img.rows, img.cols) catch {
                        python.setMemoryError("image data");
                        return null;
                    };
                    img.copy(out);
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else {
                    const out = img.convert(u8, allocator) catch {
                        python.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                }
            } else if (t_rgb) {
                if (T == Rgb) {
                    const out = Image(Rgb).init(allocator, img.rows, img.cols) catch {
                        python.setMemoryError("image data");
                        return null;
                    };
                    img.copy(out);
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else {
                    const out = img.convert(Rgb, allocator) catch {
                        python.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                }
            } else if (t_rgba) {
                if (T == Rgba) {
                    const out = Image(Rgba).init(allocator, img.rows, img.cols) catch {
                        python.setMemoryError("image data");
                        return null;
                    };
                    img.copy(out);
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else {
                    const out = img.convert(Rgba, allocator) catch {
                        python.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                }
            }
            return null;
        }
    }.apply);
}

// ============================================================================
// IMAGE CANVAS
// ============================================================================

pub const image_canvas_doc =
    \\Get a Canvas object for drawing on this image.
    \\
    \\Returns a Canvas that can be used to draw shapes, lines, and text
    \\directly onto the image pixels.
    \\
    \\## Examples
    \\```python
    \\img = Image(200, 200)
    \\cv = img.canvas()
    \\cv.draw_circle(100, 100, 50, (255, 0, 0))
    \\cv.fill_rect(10, 10, 50, 50, (0, 255, 0))
    \\```
;

pub fn image_canvas(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments expected
    // Create Canvas by calling its constructor with this Image object
    const args_tuple = c.Py_BuildValue("(O)", self_obj.?) orelse return null;
    defer c.Py_DECREF(args_tuple);
    const canvas_py = c.PyObject_CallObject(@ptrCast(&canvas.CanvasType), args_tuple) orelse return null;
    return canvas_py;
}

// ============================================================================
// IMAGE PSNR
// ============================================================================

pub const image_psnr_doc =
    \\Calculate Peak Signal-to-Noise Ratio between two images.
    \\
    \\PSNR is a quality metric where higher values indicate greater similarity.
    \\Typical values: 30-50 dB (higher is better). Returns infinity for identical images.
    \\
    \\## Parameters
    \\- `other` (Image): The image to compare against. Must have same dimensions and dtype.
    \\
    \\## Returns
    \\float: PSNR value in decibels (dB), or inf for identical images
    \\
    \\## Raises
    \\- `ValueError`: If images have different dimensions or dtypes
    \\
    \\## Examples
    \\```python
    \\original = Image.load("original.png")
    \\compressed = Image.load("compressed.png")
    \\quality = original.psnr(compressed)
    \\print(f"PSNR: {quality:.2f} dB")
    \\```
;

pub fn image_psnr(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    // Validate it's an Image object
    if (c.PyObject_IsInstance(params.other, @ptrCast(getImageType())) <= 0) {
        python.setTypeError("Image", params.other);
        return null;
    }

    const other = python.safeCast(ImageObject, params.other);
    python.ensureInitialized(other, "py_image", "Other image not initialized") catch return null;

    const self_pimg = self.py_image.?;
    const other_pimg = other.py_image.?;

    if (std.meta.activeTag(self_pimg.data) != std.meta.activeTag(other_pimg.data)) {
        python.setValueError("Images must have the same dtype for PSNR calculation", .{});
        return null;
    }

    if (self_pimg.rows() != other_pimg.rows() or self_pimg.cols() != other_pimg.cols()) {
        python.setValueError("Images must have the same dimensions", .{});
        return null;
    }

    const psnr_value = self_pimg.dispatch(.{other_pimg}, struct {
        fn apply(img1: anytype, img2_p: *PyImage) f64 {
            const T = @TypeOf(img1.data[0]);
            const img2 = switch (img2_p.data) {
                inline else => |*img| if (@TypeOf(img) == @TypeOf(img1)) img else unreachable,
            };

            const channels: f64 = comptime if (T == u8) 1.0 else if (T == Rgb) 3.0 else 4.0;

            // Calculate MSE
            var sum: f64 = 0.0;
            for (0..img1.rows) |r| {
                for (0..img1.cols) |col| {
                    const p1 = img1.at(r, col);
                    const p2 = img2.at(r, col);
                    if (T == u8) {
                        const diff: f64 = @floatFromInt(@as(i32, p1.*) - p2.*);
                        sum += diff * diff;
                    } else { // Rgb or Rgba
                        const dr: f64 = @floatFromInt(@as(i32, p1.r) - p2.r);
                        const dg: f64 = @floatFromInt(@as(i32, p1.g) - p2.g);
                        const db: f64 = @floatFromInt(@as(i32, p1.b) - p2.b);
                        sum += dr * dr + dg * dg + db * db;
                        if (T == Rgba) {
                            const da: f64 = @floatFromInt(@as(i32, p1.a) - p2.a);
                            sum += da * da;
                        }
                    }
                }
            }
            const mse = sum / (@as(f64, @floatFromInt(img1.rows * img1.cols)) * channels);
            if (mse == 0.0) {
                return std.math.inf(f64);
            }
            const max_pixel_value = 255.0;
            return 20.0 * std.math.log10(max_pixel_value / @sqrt(mse));
        }
    }.apply);

    return c.PyFloat_FromDouble(psnr_value);
}

// ============================================================================
// IMAGE SSIM
// ============================================================================

pub const image_ssim_doc =
    \\Calculate Structural Similarity Index between two images.
    \\
    \\SSIM is a perceptual metric in the range [0, 1] where higher values indicate
    \\greater structural similarity.
    \\
    \\## Parameters
    \\- `other` (Image): The image to compare against. Must have same dimensions and dtype.
    \\
    \\## Returns
    \\float: SSIM value between 0 and 1 (inclusive)
    \\
    \\## Raises
    \\- `ValueError`: If images have different dimensions or dtypes, or are smaller than 11x11
    \\
    \\## Examples
    \\```python
    \\original = Image.load("frame.png")
    \\processed = pipeline(original)
    \\score = original.ssim(processed)
    \\print(f"SSIM: {score:.4f}")
    \\```
;

pub fn image_ssim(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    if (c.PyObject_IsInstance(params.other, @ptrCast(getImageType())) <= 0) {
        python.setTypeError("Image", params.other);
        return null;
    }

    const other = python.safeCast(ImageObject, params.other);
    python.ensureInitialized(other, "py_image", "Other image not initialized") catch return null;

    if (std.meta.activeTag(self.py_image.?.data) != std.meta.activeTag(other.py_image.?.data)) {
        python.setValueError("Images must have the same dtype for SSIM calculation", .{});
        return null;
    }

    const other_pimg = other.py_image.?;

    if (self.py_image.?.rows() != other_pimg.rows() or self.py_image.?.cols() != other_pimg.cols()) {
        python.setValueError("Images must have the same dimensions", .{});
        return null;
    }

    const ssim_value = self.py_image.?.dispatch(.{other_pimg}, struct {
        fn apply(img1: anytype, img2_p: *PyImage) ?f64 {
            const img2 = switch (img2_p.data) {
                inline else => |*img| if (@TypeOf(img) == @TypeOf(img1)) img else unreachable,
            };

            if (img1.rows < 11 or img1.cols < 11) {
                python.setValueError("Images must be at least 11x11 for SSIM", .{});
                return null;
            }

            return img1.ssim(img2.*) catch |err| {
                python.setZigError(err);
                return null;
            };
        }
    }.apply);

    return if (ssim_value) |val| c.PyFloat_FromDouble(val) else null;
}

// ============================================================================
// IMAGE MEAN PIXEL ERROR
// ============================================================================

pub const image_mean_pixel_error_doc =
    \\Calculate mean absolute pixel error between two images, normalized to [0, 1].
    \\
    \\## Parameters
    \\- `other` (Image): The image to compare against. Must have same dimensions and dtype.
    \\
    \\## Returns
    \\float: Mean absolute pixel error in [0, 1] (0 = identical, higher = more different)
    \\
    \\## Raises
    \\- `ValueError`: If images have different dimensions or dtypes
    \\
    \\## Examples
    \\```python
    \\original = Image.load("photo.png")
    \\noisy = add_noise(original)
    \\percent = original.mean_pixel_error(noisy) * 100
    \\print(f"Mean pixel error: {percent:.3f}%")
    \\```
;

pub fn image_mean_pixel_error(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    if (c.PyObject_IsInstance(params.other, @ptrCast(getImageType())) <= 0) {
        python.setTypeError("Image", params.other);
        return null;
    }

    const other = python.safeCast(ImageObject, params.other);
    python.ensureInitialized(other, "py_image", "Other image not initialized") catch return null;

    if (std.meta.activeTag(self.py_image.?.data) != std.meta.activeTag(other.py_image.?.data)) {
        python.setValueError("Images must have the same dtype for mean pixel error", .{});
        return null;
    }

    const other_pimg = other.py_image.?;

    if (self.py_image.?.rows() != other_pimg.rows() or self.py_image.?.cols() != other_pimg.cols()) {
        python.setValueError("Images must have the same dimensions", .{});
        return null;
    }

    const error_value = self.py_image.?.dispatch(.{other_pimg}, struct {
        fn apply(img1: anytype, img2_p: *PyImage) ?f64 {
            const img2 = switch (img2_p.data) {
                inline else => |*img| if (@TypeOf(img) == @TypeOf(img1)) img else unreachable,
            };
            return img1.meanPixelError(img2.*) catch |err| {
                if (err == error.DimensionMismatch) {
                    python.setValueError("Images must have the same dimensions", .{});
                } else {
                    python.setZigError(err);
                }
                return null;
            };
        }
    }.apply);

    return if (error_value) |val| c.PyFloat_FromDouble(val) else null;
}

// ============================================================================
// PROPERTY GETTERS
// ============================================================================

pub fn image_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;
    return c.PyLong_FromSize_t(self.py_image.?.rows());
}

pub fn image_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;
    return c.PyLong_FromSize_t(self.py_image.?.cols());
}

pub fn image_get_dtype(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const dtype_obj: *c.PyObject = switch (self.py_image.?.data) {
        .gray => @ptrCast(&color_bindings.gray),
        .rgb => @ptrCast(&color_bindings.rgb),
        .rgba => @ptrCast(&color_bindings.rgba),
    };
    c.Py_INCREF(dtype_obj);
    return dtype_obj;
}

// ============================================================================
// IMAGE SET_BORDER
// ============================================================================

pub const image_set_border_doc =
    \\Set the image border outside a rectangle to a value.
    \\
    \\Sets pixels outside the given rectangle to the provided color/value,
    \\leaving the interior untouched. The rectangle may be provided as a
    \\Rectangle or a tuple (left, top, right, bottom). It is clipped to the
    \\image bounds.
    \\
    \\## Parameters
    \\- `rect` (Rectangle | tuple[float, float, float, float]): Inner rectangle to preserve.
    \\- `color` (optional): Fill value for border. Accepts the same types as `fill`.
    \\   If omitted, uses zeros for the current dtype (0, Rgb(0,0,0), or Rgba(0,0,0,0)).
    \\
    \\## Examples
    \\```python
    \\img = Image(100, 100)
    \\rect = Rectangle(10, 10, 90, 90)
    \\img.set_border(rect)               # zero border
    \\img.set_border(rect, (255, 0, 0))  # red border
    \\
    \\# Common pattern: set a uniform 16px border using shrink()
    \\img.set_border(img.get_rectangle().shrink(16))
    \\```
;

pub fn image_set_border(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ImageObject, self_obj);
    python.ensureInitialized(self, "py_image", "Image not initialized") catch return null;

    const Params = struct {
        rect: ?*c.PyObject,
        color: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = python.parse(zignal.Rectangle(usize), params.rect) catch return null;

    return self.py_image.?.dispatch(.{ rect, params.color }, struct {
        fn apply(img: anytype, r: zignal.Rectangle(usize), color_obj: ?*c.PyObject) ?*c.PyObject {
            const T = @TypeOf(img.data[0]);
            if (color_obj) |cobj| {
                img.setBorder(r, parseColorTo(T, cobj) catch return null);
            } else {
                img.setBorder(r, std.mem.zeroes(T));
            }
            return python.none();
        }
    }.apply);
}

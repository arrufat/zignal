//! Core image operations: I/O, memory management, type conversion

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;
const ImageFormat = zignal.ImageFormat;

const py_utils = @import("../py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;

const canvas = @import("../canvas.zig");
const color_bindings = @import("../color.zig");
const parseColorTo = @import("../color_utils.zig").parseColor;
const grayscale_format = @import("../grayscale_format.zig");
const PyImageMod = @import("../PyImage.zig");
const PyImage = PyImageMod.PyImage;
const rectangle = @import("../rectangle.zig");
const moveImageToPython = @import("../image.zig").moveImageToPython;

// Import the ImageObject type from parent
const ImageObject = @import("../image.zig").ImageObject;
const getImageType = @import("../image.zig").getImageType;

fn setDecodeError(kind: []const u8, err: anyerror) void {
    switch (err) {
        error.OutOfMemory => py_utils.setMemoryError(kind),
        else => py_utils.setValueError("Failed to decode {s}: {s}", .{ kind, @errorName(err) }),
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
            var decoded = zignal.png.decode(allocator, data) catch |err| {
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
            var decoded = zignal.jpeg.decode(allocator, data) catch |err| {
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
    \\The pixel format (Grayscale, Rgb, or Rgba) is automatically determined from the
    \\file metadata. For PNGs, the format matches the file's color type. For JPEGs,
    \\grayscale images load as Grayscale, color images as Rgb.
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
    \\img2 = Image.load("grayscale.jpg") # Will be Grayscale
    \\img3 = Image.load("rgb.png")       # Will be Rgb
    \\
    \\# Check format after loading
    \\print(img.dtype)  # e.g., Rgba, Rgb, or Grayscale
    \\```
;

pub fn image_load(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;

    const Params = struct { path: [*c]const u8 };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const path_slice = std.mem.span(params.path);

    // Detect format and load accordingly
    const is_jpeg = std.mem.endsWith(u8, path_slice, ".jpg") or
        std.mem.endsWith(u8, path_slice, ".jpeg") or
        std.mem.endsWith(u8, path_slice, ".JPG") or
        std.mem.endsWith(u8, path_slice, ".JPEG");

    if (is_jpeg) {
        // Read file and decode JPEG
        const data = std.fs.cwd().readFileAlloc(path_slice, allocator, .limited(200 * 1024 * 1024)) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        defer allocator.free(data);

        var decoded = zignal.jpeg.decode(allocator, data) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        defer decoded.deinit();

        const native = zignal.jpeg.toNativeImage(allocator, &decoded) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        switch (native) {
            inline else => |img| {
                return @ptrCast(moveImageToPython(img) orelse return null);
            },
        }
    }

    // PNG: load native dtype (Grayscale, RGB, RGBA)
    if (std.mem.endsWith(u8, path_slice, ".png") or std.mem.endsWith(u8, path_slice, ".PNG")) {
        const data = std.fs.cwd().readFileAlloc(path_slice, allocator, .limited(100 * 1024 * 1024)) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        defer allocator.free(data);
        var decoded = zignal.png.decode(allocator, data) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        defer decoded.deinit(allocator);
        const native = zignal.png.toNativeImage(allocator, decoded) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        switch (native) {
            inline else => |img| {
                return @ptrCast(moveImageToPython(img) orelse return null);
            },
        }
    }

    // Default: Try to load as RGB
    const image = Image(Rgb).load(allocator, path_slice) catch |err| {
        py_utils.setErrorWithPath(err, path_slice);
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
    \\Image: A new Image with pixel storage matching the encoded file (Grayscale, Rgb, or Rgba).
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
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const data_obj = params.data orelse {
        py_utils.setTypeError("bytes-like object", null);
        return null;
    };

    if (c.PyObject_CheckBuffer(data_obj) == 0) {
        py_utils.setTypeError("bytes-like object", data_obj);
        return null;
    }

    var buffer: c.Py_buffer = std.mem.zeroes(c.Py_buffer);
    if (c.PyObject_GetBuffer(data_obj, &buffer, c.PyBUF_CONTIG_RO) != 0) {
        return null;
    }
    defer c.PyBuffer_Release(&buffer);

    if (buffer.len == 0) {
        py_utils.setValueError("Image data buffer cannot be empty", .{});
        return null;
    }

    const byte_ptr = @as([*]const u8, @ptrCast(buffer.buf));
    const data_slice = byte_ptr[0..@intCast(buffer.len)];

    const detected = ImageFormat.detectFromBytes(data_slice) orelse {
        py_utils.setValueError("Unsupported image data: expected PNG or JPEG signature", .{});
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { path: [*c]const u8 };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const path_slice = std.mem.span(params.path);

    // Save image using the core library's save method which handles format detection
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| img.save(allocator, path_slice) catch |err| {
                if (err == error.UnsupportedImageFormat) {
                    py_utils.setValueError("Unsupported image format. File must have a valid PNG or JPEG extension.", .{});
                    return null;
                }
                py_utils.setErrorWithPath(err, path_slice);
                return null;
            },
        }
    } else {
        py_utils.setValueError("Image not initialized", .{});
        return null;
    }

    return py_utils.getPyNone();
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const copy = Image(@TypeOf(img.data[0])).init(allocator, img.rows, img.cols) catch {
                    py_utils.setMemoryError("image data");
                    return null;
                };
                img.copy(copy);
                return @ptrCast(moveImageToPython(copy) orelse return null);
            },
        }
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { color: ?*c.PyObject };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const color_obj = params.color;

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| img.fill(parseColorTo(@TypeOf(img.data[0]), color_obj) catch return null),
        }
    } else {
        py_utils.setValueError("Image not initialized", .{});
        return null;
    }

    return py_utils.getPyNone();
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { rect: ?*c.PyObject = null };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const rect_obj = params.rect;

    if (self.py_image) |pimg| {
        // Create view based on current image type
        const view_result = switch (pimg.data) {
            inline else => |img| blk: {
                if (rect_obj) |ro| {
                    const rect = py_utils.parseRectangle(usize, ro) catch return null;
                    break :blk PyImage.createFrom(allocator, img.view(rect), .borrowed);
                } else {
                    const full_rect = zignal.Rectangle(usize).init(0, 0, img.cols, img.rows);
                    break :blk PyImage.createFrom(allocator, img.view(full_rect), .borrowed);
                }
            },
        };

        const pimg_view = view_result orelse {
            py_utils.setMemoryError("image view");
            return null;
        };

        // Create new Image object to wrap the view
        const new_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse {
            pimg_view.deinit(allocator);
            return null;
        };
        const new_self = py_utils.safeCast(ImageObject, new_obj);
        new_self.py_image = pimg_view;
        new_self.numpy_ref = null;
        // Keep reference to parent to prevent deallocation
        c.Py_INCREF(self_obj);
        new_self.parent_ref = self_obj;

        return new_obj;
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    if (self.py_image) |pimg| {
        const is_contig = switch (pimg.data) {
            inline else => |img| img.isContiguous(),
        };

        return @ptrCast(py_utils.getPyBool(is_contig));
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
}

// ============================================================================
// IMAGE GET_RECTANGLE
// ============================================================================

pub const image_get_rectangle_doc =
    \\Get the full image bounds as a Rectangle(left=0, top=0, right=cols, bottom=rows).
;

pub fn image_get_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = py_utils.safeCast(ImageObject, self_obj);
    if (self.py_image) |pimg| {
        const rows = switch (pimg.data) {
            inline else => |img| img.rows,
        };
        const cols = switch (pimg.data) {
            inline else => |img| img.cols,
        };
        const left: f64 = 0.0;
        const top: f64 = 0.0;
        const right: f64 = @floatFromInt(cols);
        const bottom: f64 = @floatFromInt(rows);
        const args_tuple = c.Py_BuildValue("(dddd)", left, top, right, bottom) orelse return null;
        defer c.Py_DECREF(args_tuple);
        const rect_obj = c.PyObject_CallObject(@ptrCast(&rectangle.RectangleType), args_tuple);
        return rect_obj;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

// ============================================================================
// IMAGE CONVERT
// ============================================================================

pub const image_convert_doc =
    \\
    \\Convert the image to a different pixel data type.
    \\
    \\Supported targets: Grayscale, Rgb, Rgba.
    \\
    \\Returns a new Image with the requested format.
;

pub fn image_convert(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { dtype: ?*c.PyObject };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const dtype_obj = params.dtype;

    if (dtype_obj == null) {
        py_utils.setTypeError("target dtype (zignal.Grayscale, zignal.Rgb, or zignal.Rgba)", null);
        return null;
    }

    // Determine target type
    var target_gray = false;
    var target_rgb = false;
    var target_rgba = false;

    // TODO: Remove explicit cast after Python 3.10 is dropped
    const is_type_obj = c.PyObject_TypeCheck(dtype_obj.?, @as([*c]c.PyTypeObject, @ptrCast(&c.PyType_Type))) != 0;
    if (is_type_obj) {
        if (dtype_obj.? == @as(*c.PyObject, @ptrCast(&grayscale_format.GrayscaleType))) {
            target_gray = true;
        } else if (dtype_obj.? == @as(*c.PyObject, @ptrCast(&color_bindings.RgbType))) {
            target_rgb = true;
        } else if (dtype_obj.? == @as(*c.PyObject, @ptrCast(&color_bindings.RgbaType))) {
            target_rgba = true;
        } else {
            py_utils.setTypeError("zignal.Grayscale, zignal.Rgb, or zignal.Rgba", dtype_obj);
            return null;
        }
    } else {
        if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.RgbType)) == 1) {
            target_rgb = true;
        } else if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.RgbaType)) == 1) {
            target_rgba = true;
        } else {
            py_utils.setTypeError("zignal.Grayscale, zignal.Rgb, or zignal.Rgba", dtype_obj);
            return null;
        }
    }

    // Execute conversion using underlying Image(T).convert
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .grayscale => |*img| {
                if (target_gray) {
                    // Same dtype: copy
                    const out = Image(u8).init(allocator, img.rows, img.cols) catch {
                        py_utils.setMemoryError("image data");
                        return null;
                    };
                    img.copy(out);
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else if (target_rgb) {
                    const out = img.convert(Rgb, allocator) catch {
                        py_utils.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else if (target_rgba) {
                    const out = img.convert(Rgba, allocator) catch {
                        py_utils.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                }
            },
            .rgb => |*img| {
                if (target_gray) {
                    const out = img.convert(u8, allocator) catch {
                        py_utils.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else if (target_rgb) {
                    const out = Image(Rgb).init(allocator, img.rows, img.cols) catch {
                        py_utils.setMemoryError("image data");
                        return null;
                    };
                    img.copy(out);
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else if (target_rgba) {
                    const out = img.convert(Rgba, allocator) catch {
                        py_utils.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                }
            },
            .rgba => |*img| {
                if (target_gray) {
                    const out = img.convert(u8, allocator) catch {
                        py_utils.setMemoryError("image conversion");
                        return null;
                    };
                    return @ptrCast(moveImageToPython(out) orelse return null);
                } else if (target_rgb) {
                    const out = img.convert(Rgb, allocator) catch {
                        py_utils.setMemoryError("image conversion");
                        return null;
                    };
                    const wrapped = moveImageToPython(out) orelse return null;
                    return @ptrCast(wrapped);
                } else if (target_rgba) {
                    const out = Image(Rgba).init(allocator, img.rows, img.cols) catch {
                        py_utils.setMemoryError("image data");
                        return null;
                    };
                    img.copy(out);
                    const wrapped = moveImageToPython(out) orelse return null;
                    return @ptrCast(wrapped);
                }
            },
        }
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Validate it's an Image object
    if (c.PyObject_IsInstance(params.other, @ptrCast(getImageType())) <= 0) {
        py_utils.setTypeError("Image", params.other);
        return null;
    }

    const other = py_utils.safeCast(ImageObject, params.other);

    if (self.py_image == null or other.py_image == null) {
        py_utils.setValueError("Both images must be initialized", .{});
        return null;
    }

    // Check that images have compatible types
    const self_type = switch (self.py_image.?.data) {
        .grayscale => "grayscale",
        .rgb => "rgb",
        .rgba => "rgba",
    };
    const other_type = switch (other.py_image.?.data) {
        .grayscale => "grayscale",
        .rgb => "rgb",
        .rgba => "rgba",
    };

    if (!std.mem.eql(u8, self_type, other_type)) {
        py_utils.setValueError("Images must have the same dtype for PSNR calculation", .{});
        return null;
    }

    // Calculate PSNR based on image type
    const psnr_value = switch (self.py_image.?.data) {
        .grayscale => |img1| blk: {
            const img2 = other.py_image.?.data.grayscale;
            if (img1.rows != img2.rows or img1.cols != img2.cols) {
                py_utils.setValueError("Images must have the same dimensions", .{});
                return null;
            }

            // Calculate MSE
            var sum: f64 = 0.0;
            for (0..img1.rows) |r| {
                for (0..img1.cols) |col| {
                    const p1 = img1.at(r, col);
                    const p2 = img2.at(r, col);
                    const diff = @as(f64, @floatFromInt(@as(i32, @intCast(p1.*)) - @as(i32, @intCast(p2.*))));
                    sum += diff * diff;
                }
            }
            const mse = sum / @as(f64, @floatFromInt(img1.rows * img1.cols));
            if (mse == 0.0) {
                break :blk std.math.inf(f64);
            }
            const max_pixel_value = 255.0;
            break :blk 20.0 * std.math.log10(max_pixel_value / @sqrt(mse));
        },
        .rgb => |img1| blk: {
            const img2 = other.py_image.?.data.rgb;
            if (img1.rows != img2.rows or img1.cols != img2.cols) {
                py_utils.setValueError("Images must have the same dimensions", .{});
                return null;
            }

            // Calculate MSE across all channels
            var sum: f64 = 0.0;
            for (0..img1.rows) |r| {
                for (0..img1.cols) |col| {
                    const p1 = img1.at(r, col);
                    const p2 = img2.at(r, col);
                    const dr = @as(f64, @floatFromInt(@as(i32, p1.r) - @as(i32, p2.r)));
                    const dg = @as(f64, @floatFromInt(@as(i32, p1.g) - @as(i32, p2.g)));
                    const db = @as(f64, @floatFromInt(@as(i32, p1.b) - @as(i32, p2.b)));
                    sum += dr * dr + dg * dg + db * db;
                }
            }
            const mse = sum / @as(f64, @floatFromInt(img1.rows * img1.cols * 3));
            if (mse == 0.0) {
                break :blk std.math.inf(f64);
            }
            const max_pixel_value = 255.0;
            break :blk 20.0 * std.math.log10(max_pixel_value / @sqrt(mse));
        },
        .rgba => |img1| blk: {
            const img2 = other.py_image.?.data.rgba;
            if (img1.rows != img2.rows or img1.cols != img2.cols) {
                py_utils.setValueError("Images must have the same dimensions", .{});
                return null;
            }

            // Calculate MSE across all channels including alpha
            var sum: f64 = 0.0;
            for (0..img1.rows) |r| {
                for (0..img1.cols) |col| {
                    const p1 = img1.at(r, col);
                    const p2 = img2.at(r, col);
                    const dr = @as(f64, @floatFromInt(@as(i32, p1.r) - @as(i32, p2.r)));
                    const dg = @as(f64, @floatFromInt(@as(i32, p1.g) - @as(i32, p2.g)));
                    const db = @as(f64, @floatFromInt(@as(i32, p1.b) - @as(i32, p2.b)));
                    const da = @as(f64, @floatFromInt(@as(i32, p1.a) - @as(i32, p2.a)));
                    sum += dr * dr + dg * dg + db * db + da * da;
                }
            }
            const mse = sum / @as(f64, @floatFromInt(img1.rows * img1.cols * 4));
            if (mse == 0.0) {
                break :blk std.math.inf(f64);
            }
            const max_pixel_value = 255.0;
            break :blk 20.0 * std.math.log10(max_pixel_value / @sqrt(mse));
        },
    };

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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    if (c.PyObject_IsInstance(params.other, @ptrCast(getImageType())) <= 0) {
        py_utils.setTypeError("Image", params.other);
        return null;
    }

    const other = py_utils.safeCast(ImageObject, params.other);

    if (self.py_image == null or other.py_image == null) {
        py_utils.setValueError("Both images must be initialized", .{});
        return null;
    }

    const self_tag = std.meta.activeTag(self.py_image.?.data);
    const other_tag = std.meta.activeTag(other.py_image.?.data);
    if (self_tag != other_tag) {
        py_utils.setValueError("Images must have the same dtype for SSIM calculation", .{});
        return null;
    }

    const min_size_error = "Images must be at least 11x11 for SSIM";

    const other_variant = other.py_image.?.data;
    const ssim_value = switch (self.py_image.?.data) {
        inline else => |img1| blk: {
            const img2 = switch (other_variant) {
                inline else => |img| variant_blk: {
                    if (@TypeOf(img) != @TypeOf(img1)) unreachable;
                    break :variant_blk img;
                },
            };

            if (img1.rows != img2.rows or img1.cols != img2.cols) {
                py_utils.setValueError("Images must have the same dimensions", .{});
                return null;
            }
            if (img1.rows < 11 or img1.cols < 11) {
                py_utils.setValueError(min_size_error, .{});
                return null;
            }

            const result = img1.ssim(img2) catch |err| switch (err) {
                error.ImageTooSmall => {
                    py_utils.setValueError(min_size_error, .{});
                    return null;
                },
                else => {
                    py_utils.setZigError(err);
                    return null;
                },
            };
            break :blk result;
        },
    };

    return c.PyFloat_FromDouble(ssim_value);
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
    \\percent = original.mean_pixel_error(noisy)
    \\print(f"Mean pixel error: {percent:.3f}%")
    \\```
;

pub fn image_mean_pixel_error(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { other: ?*c.PyObject };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    if (c.PyObject_IsInstance(params.other, @ptrCast(getImageType())) <= 0) {
        py_utils.setTypeError("Image", params.other);
        return null;
    }

    const other = py_utils.safeCast(ImageObject, params.other);
    if (self.py_image == null or other.py_image == null) {
        py_utils.setValueError("Both images must be initialized", .{});
        return null;
    }

    const self_tag = std.meta.activeTag(self.py_image.?.data);
    const other_tag = std.meta.activeTag(other.py_image.?.data);
    if (self_tag != other_tag) {
        py_utils.setValueError("Images must have the same dtype for mean pixel error", .{});
        return null;
    }

    const other_variant = other.py_image.?.data;
    const error_value = switch (self.py_image.?.data) {
        inline else => |img1| blk: {
            const img2 = switch (other_variant) {
                inline else => |img| if (@TypeOf(img) == @TypeOf(img1)) img else unreachable,
            };
            const val = img1.meanPixelError(img2) catch |err| switch (err) {
                error.DimensionMismatch => {
                    py_utils.setValueError("Images must have the same dimensions", .{});
                    return null;
                },
            };
            break :blk val;
        },
    };

    return c.PyFloat_FromDouble(error_value);
}

// ============================================================================
// PROPERTY GETTERS
// ============================================================================

pub fn image_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(ImageObject, self_obj);
    if (self.py_image) |pimg| {
        const rows = switch (pimg.data) {
            inline else => |img| img.rows,
        };
        return c.PyLong_FromSize_t(rows);
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub fn image_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(ImageObject, self_obj);
    if (self.py_image) |pimg| {
        const cols = switch (pimg.data) {
            inline else => |img| img.cols,
        };
        return c.PyLong_FromSize_t(cols);
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub fn image_get_dtype(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(ImageObject, self_obj);
    if (self.py_image) |pimg| {
        const dtype_obj = switch (pimg.data) {
            .grayscale => @as(*c.PyObject, @ptrCast(&grayscale_format.GrayscaleType)),
            .rgb => @as(*c.PyObject, @ptrCast(&color_bindings.RgbType)),
            .rgba => @as(*c.PyObject, @ptrCast(&color_bindings.RgbaType)),
        };
        c.Py_INCREF(dtype_obj);
        return dtype_obj;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        rect: ?*c.PyObject,
        color: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const rect = py_utils.parseRectangle(usize, params.rect) catch return null;
    const color_obj = params.color;

    if (self.py_image) |pimg| {
        if (color_obj) |cobj| {
            switch (pimg.data) {
                inline else => |img| img.setBorder(rect, parseColorTo(@TypeOf(img.data[0]), cobj) catch return null),
            }
        } else {
            switch (pimg.data) {
                inline else => |img| img.setBorder(rect, std.mem.zeroes(@TypeOf(img.data[0]))),
            }
        }

        const none = c.Py_None();
        c.Py_INCREF(none);
        return none;
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
}

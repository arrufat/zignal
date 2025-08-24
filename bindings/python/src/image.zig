const std = @import("std");

const zignal = @import("zignal");
const InterpolationMethod = zignal.InterpolationMethod;
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;
const DisplayFormat = zignal.DisplayFormat;

const canvas = @import("canvas.zig");
const color_utils = @import("color_utils.zig");
const color_bindings = @import("color.zig");
const grayscale_format = @import("grayscale_format.zig");
const PyImageMod = @import("PyImage.zig");
const PyImage = PyImageMod.PyImage;
const pixel_iterator = @import("pixel_iterator.zig");
const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const image_class_doc =
    \\
    \\Image for processing and manipulation.\n\n
    \\This object is iterable: iterating yields (row, col, pixel) in native\n
    \\dtype (Grayscale→int, Rgb→Rgb, Rgba→Rgba) in row-major order. For bulk\n
    \\numeric work, prefer to_numpy().
;

pub const ImageObject = extern struct {
    ob_base: c.PyObject,
    // Store dynamic image for non-RGBA formats (or future migration)
    py_image: ?*PyImage,
    // Store reference to NumPy array if created from numpy (for zero-copy)
    numpy_ref: ?*c.PyObject,
    // Store reference to parent Image if this is a view (for memory management)
    parent_ref: ?*c.PyObject,
};

fn image_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize to none
        obj.py_image = null;
        obj.numpy_ref = null;
        obj.parent_ref = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

const image_init_doc =
    \\Create a new Image with the specified dimensions and optional fill color.
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows (height) of the image
    \\- `cols` (int): Number of columns (width) of the image
    \\- `color` (optional): Fill color. Can be:
    \\  - Integer (0-255) for grayscale
    \\  - RGB tuple (r, g, b) with values 0-255
    \\  - RGBA tuple (r, g, b, a) with values 0-255
    \\  - Any color object (Rgb, Hsl, Hsv, etc.)
    \\  - Defaults to transparent (0, 0, 0, 0)
    \\- `dtype` (type, keyword-only): Pixel data type specifying storage type.
    \\  - `zignal.Grayscale` → single-channel u8 (NumPy shape (H, W, 1))
    \\  - `zignal.Rgb` (default) → 3-channel RGB (NumPy shape (H, W, 3))
    \\  - `zignal.Rgba` → 4-channel RGBA (NumPy shape (H, W, 4))
    \\
    \\## Examples
    \\```python
    \\# Create a 100x200 black image (default RGB)
    \\img = Image(100, 200)
    \\
    \\# Create a 100x200 red image (RGBA)
    \\img = Image(100, 200, (255, 0, 0))
    \\
    \\# Create a 100x200 grayscale image with mid-gray fill
    \\img = Image(100, 200, 128, dtype=zignal.Grayscale)
    \\
    \\# Create a 100x200 RGB image
    \\img = Image(100, 200, (0, 255, 0), dtype=zignal.Rgb)
    \\
    \\# Create an image from numpy array dimensions
    \\img = Image(*arr.shape[:2])
    \\
    \\# Create with semi-transparent blue (requires RGBA)
    \\img = Image(100, 200, (0, 0, 255, 128), dtype=zignal.Rgba)
    \\```
;

fn image_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if the image is already initialized (might be from load or from_numpy)
    if (self.py_image != null) {
        // Already initialized, just return success
        return 0;
    }

    // Define color input types for cleaner logic
    const ColorInputType = enum {
        none,
        grayscale, // Integer value
        rgb_tuple, // 3-component tuple
        rgba_tuple, // 4-component tuple
        rgb_object, // Rgb instance
        rgba_object, // Rgba instance
        other, // Other color object
    };

    // Parse arguments: rows, cols, optional color, keyword-only dtype
    var rows: c_int = 0;
    var cols: c_int = 0;
    var color_obj: ?*c.PyObject = null;
    var dtype_obj: ?*c.PyObject = null;

    var kwlist = [_:null]?[*:0]u8{ @constCast("rows"), @constCast("cols"), @constCast("color"), @constCast("dtype"), null };
    const fmt = std.fmt.comptimePrint("ii|O$O", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, fmt.ptr, @ptrCast(&kwlist), &rows, &cols, &color_obj, &dtype_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Image() requires (rows, cols, color=None, *, dtype=...) arguments");
        return -1;
    }

    // Validate dimensions - validateRange now properly handles negative values when converting to usize
    const validated_rows = py_utils.validateRange(usize, rows, 1, std.math.maxInt(usize), "Rows") catch return -1;
    const validated_cols = py_utils.validateRange(usize, cols, 1, std.math.maxInt(usize), "Cols") catch return -1;

    // Detect color input type
    var color_type = ColorInputType.none;
    if (color_obj != null and color_obj != c.Py_None()) {
        if (c.PyLong_Check(color_obj) != 0) {
            color_type = .grayscale;
        } else if (c.PyTuple_Check(color_obj) != 0) {
            const tuple_size = c.PyTuple_Size(color_obj);
            if (tuple_size == 3) {
                color_type = .rgb_tuple;
            } else if (tuple_size == 4) {
                color_type = .rgba_tuple;
            } else {
                c.PyErr_SetString(c.PyExc_ValueError, "Color tuple must have 3 or 4 elements");
                return -1;
            }
        } else if (c.PyObject_IsInstance(color_obj, @ptrCast(&color_bindings.RgbaType)) == 1) {
            color_type = .rgba_object;
        } else if (c.PyObject_IsInstance(color_obj, @ptrCast(&color_bindings.RgbType)) == 1) {
            color_type = .rgb_object;
        } else {
            color_type = .other;
        }
    }

    // Determine target dtype based on color type and explicit dtype parameter
    const ImageFormat = enum { grayscale, rgb, rgba };
    var target_format: ImageFormat = undefined;

    if (dtype_obj) |fmt_obj| {
        // Explicit dtype specified
        // TODO: Remove explicit cast after Python 3.10 is dropped
        const is_type_obj = c.PyObject_TypeCheck(fmt_obj, @as([*c]c.PyTypeObject, @ptrCast(&c.PyType_Type))) != 0;
        if (is_type_obj) {
            if (fmt_obj == @as(*c.PyObject, @ptrCast(&grayscale_format.GrayscaleType))) {
                target_format = .grayscale;
            } else if (fmt_obj == @as(*c.PyObject, @ptrCast(&color_bindings.RgbType))) {
                target_format = .rgb;
            } else if (fmt_obj == @as(*c.PyObject, @ptrCast(&color_bindings.RgbaType))) {
                target_format = .rgba;
            } else {
                c.PyErr_SetString(c.PyExc_TypeError, "dtype must be zignal.Grayscale, zignal.Rgb, or zignal.Rgba");
                return -1;
            }
        } else {
            // Instances: allow Rgb/Rgba instances for convenience
            if (c.PyObject_IsInstance(fmt_obj, @ptrCast(&grayscale_format.GrayscaleType)) == 1) {
                target_format = .grayscale;
            } else if (c.PyObject_IsInstance(fmt_obj, @ptrCast(&color_bindings.RgbType)) == 1) {
                target_format = .rgb;
            } else if (c.PyObject_IsInstance(fmt_obj, @ptrCast(&color_bindings.RgbaType)) == 1) {
                target_format = .rgba;
            } else {
                c.PyErr_SetString(c.PyExc_TypeError, "dtype must be zignal.Grayscale, zignal.Rgb, or zignal.Rgba");
                return -1;
            }
        }
    } else {
        // Auto-detect dtype based on color type
        target_format = switch (color_type) {
            .none => .rgb, // Default to RGB for no color
            .grayscale => .grayscale,
            .rgb_tuple => .rgb,
            .rgba_tuple => .rgba,
            .rgb_object => .rgb,
            .rgba_object => .rgba,
            .other => .rgb, // Default to RGB for other color objects
        };
    }

    // Create image with appropriate dtype and fill with color
    switch (target_format) {
        .grayscale => {
            var gimg = Image(u8).init(allocator, validated_rows, validated_cols) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                return -1;
            };

            // Parse color to grayscale if provided
            if (color_obj != null and color_obj != c.Py_None()) {
                const gray_value = color_utils.parseColorTo(u8, color_obj) catch {
                    gimg.deinit(allocator);
                    // Error already set by parseColorTo
                    return -1;
                };
                @memset(gimg.data, gray_value);
            } else {
                @memset(gimg.data, 0); // Default to black
            }

            const pimg = allocator.create(PyImage) catch {
                gimg.deinit(allocator);
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                return -1;
            };
            pimg.data = PyImage.Variant{ .gray = gimg };
            pimg.owning = true;
            self.py_image = pimg;
            self.numpy_ref = null;
            self.parent_ref = null;
            return 0;
        },
        .rgb => {
            var rimg = Image(Rgb).init(allocator, validated_rows, validated_cols) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                return -1;
            };

            // Parse color to RGB if provided
            if (color_obj != null and color_obj != c.Py_None()) {
                const rgb_color = color_utils.parseColorTo(Rgb, color_obj) catch {
                    rimg.deinit(allocator);
                    // Error already set by parseColorTo
                    return -1;
                };
                @memset(rimg.data, rgb_color);
            } else {
                @memset(rimg.data, Rgb{ .r = 0, .g = 0, .b = 0 }); // Default to black
            }

            const pimg = allocator.create(PyImage) catch {
                rimg.deinit(allocator);
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                return -1;
            };
            pimg.data = PyImage.Variant{ .rgb = rimg };
            pimg.owning = true;
            self.py_image = pimg;
            self.numpy_ref = null;
            self.parent_ref = null;
            return 0;
        },
        .rgba => {
            var image = Image(Rgba).init(allocator, validated_rows, validated_cols) catch {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                return -1;
            };

            // Parse color to RGBA if provided
            if (color_obj != null and color_obj != c.Py_None()) {
                const rgba_color = color_utils.parseColorTo(Rgba, color_obj) catch {
                    image.deinit(allocator);
                    // Error already set by parseColorTo
                    return -1;
                };
                @memset(image.data, rgba_color);
            } else {
                @memset(image.data, Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 }); // Default to transparent
            }

            const pimg = allocator.create(PyImage) catch {
                image.deinit(allocator);
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                return -1;
            };
            pimg.* = .{ .data = .{ .rgba = image } };
            self.py_image = pimg;
            self.numpy_ref = null;
            self.parent_ref = null;
            return 0;
        },
    }
}

fn image_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Free PyImage if present
    if (self.py_image) |pimg| {
        var tmp = pimg.*;
        tmp.deinit(py_utils.allocator);
        py_utils.allocator.destroy(pimg);
        self.py_image = null;
    }

    // Release reference to NumPy array if we have one
    if (self.numpy_ref) |ref| {
        c.Py_XDECREF(ref);
    }

    // Release reference to parent Image if this is a view
    if (self.parent_ref) |ref| {
        c.Py_XDECREF(ref);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn image_richcompare(self_obj: [*c]c.PyObject, other_obj: [*c]c.PyObject, op: c_int) callconv(.c) [*c]c.PyObject {
    // Only handle == (Py_EQ=2) and != (Py_NE=3); defer other comparisons
    if (op != c.Py_EQ and op != c.Py_NE) {
        const not_impl = c.Py_NotImplemented();
        c.Py_INCREF(not_impl);
        return not_impl;
    }

    // Check if other is an Image object; if not, defer using NotImplemented
    const image_type = @as([*c]c.PyTypeObject, @ptrCast(&ImageType));
    if (c.PyObject_TypeCheck(other_obj, image_type) == 0) {
        const not_impl = c.Py_NotImplemented();
        c.Py_INCREF(not_impl);
        return not_impl;
    }

    // Cast to ImageObject
    const self = @as(*ImageObject, @ptrCast(self_obj));
    const other = @as(*ImageObject, @ptrCast(other_obj));

    // Variant-aware equality: compare size and per-pixel RGBA values
    if (self.py_image == null or other.py_image == null) {
        // If either is uninitialized, they are equal only for != case
        return @ptrCast(py_utils.getPyBool(op != c.Py_EQ));
    }
    // Store in local variables after null check to avoid repeated unwrapping
    const self_img = self.py_image.?;
    const other_img = other.py_image.?;
    const dims_self = .{ self_img.rows(), self_img.cols() };
    const dims_other = .{ other_img.rows(), other_img.cols() };

    if (dims_self[0] != dims_other[0] or dims_self[1] != dims_other[1]) {
        return @ptrCast(py_utils.getPyBool(op != c.Py_EQ));
    }

    const rows = dims_self[0];
    const cols = dims_self[1];
    var equal = true;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var cidx: usize = 0;
        while (cidx < cols) : (cidx += 1) {
            const a = self_img.getPixelRgba(r, cidx);
            const b = other_img.getPixelRgba(r, cidx);
            if (a != b) {
                equal = false;
                break;
            }
        }
        if (!equal) break;
    }

    if (op == c.Py_EQ) {
        return @ptrCast(py_utils.getPyBool(equal));
    } else {
        return @ptrCast(py_utils.getPyBool(!equal));
    }
}

fn image_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        var buffer: [96]u8 = undefined;
        const fmt_name = switch (pimg.data) {
            .gray => "Grayscale",
            .rgb => "Rgb",
            .rgba => "Rgba",
        };
        const formatted = std.fmt.bufPrintZ(&buffer, "Image({d}x{d}, dtype={s})", .{ pimg.rows(), pimg.cols(), fmt_name }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("Image(uninitialized)");
    }
}

fn image_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        return c.PyLong_FromLong(@intCast(pimg.rows()));
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

fn image_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        return c.PyLong_FromLong(@intCast(pimg.cols()));
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

fn image_get_dtype(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Return sentinel type objects: zignal.Grayscale, zignal.Rgb, or zignal.Rgba
    if (self.py_image) |pimg| {
        return switch (pimg.data) {
            .gray => blk: {
                const obj = @as(*c.PyObject, @ptrCast(&grayscale_format.GrayscaleType));
                c.Py_INCREF(obj);
                break :blk obj;
            },
            .rgb => blk: {
                const obj = @as(*c.PyObject, @ptrCast(&color_bindings.RgbType));
                c.Py_INCREF(obj);
                break :blk obj;
            },
            .rgba => blk: {
                const obj = @as(*c.PyObject, @ptrCast(&color_bindings.RgbaType));
                c.Py_INCREF(obj);
                break :blk obj;
            },
        };
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

fn image_is_view(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const is_view = switch (pimg.data) {
            .gray => |img| img.isView(),
            .rgb => |img| img.isView(),
            .rgba => |img| img.isView(),
        };
        return @ptrCast(py_utils.getPyBool(is_view));
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_load_doc =
    \\Load an image from file (PNG/JPEG).
    \\
    \\## Parameters
    \\- `path` (`str`): Path to the image file to load
    \\
    \\## Raises
    \\- `FileNotFoundError`: If the image file is not found
    \\- `ValueError`: If the image format is not supported
    \\- `MemoryError`: If allocation fails
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\print(img.rows, img.cols)
    \\# Output: 512 768
    \\```
;

fn image_load(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var file_path: [*c]const u8 = undefined;

    const format = std.fmt.comptimePrint("s", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &file_path) == 0) {
        return null;
    }

    // Convert C string to Zig slice
    const path_slice = std.mem.span(file_path);

    // PNG: load native dtype (Grayscale, RGB, RGBA)
    if (std.mem.endsWith(u8, path_slice, ".png") or std.mem.endsWith(u8, path_slice, ".PNG")) {
        const data = std.fs.cwd().readFileAlloc(allocator, path_slice, 100 * 1024 * 1024) catch |err| {
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
        const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
        if (self == null) return null;
        switch (native) {
            .grayscale => |img| {
                const p = allocator.create(PyImage) catch {
                    var tmp = img;
                    tmp.deinit(allocator);
                    c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                p.* = .{ .data = .{ .gray = img }, .owning = true };
                self.?.py_image = p;
            },
            .rgb => |img| {
                const p = allocator.create(PyImage) catch {
                    var tmp = img;
                    tmp.deinit(allocator);
                    c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                p.* = .{ .data = .{ .rgb = img }, .owning = true };
                self.?.py_image = p;
            },
            .rgba => |img| {
                const p = allocator.create(PyImage) catch {
                    var tmp = img;
                    tmp.deinit(allocator);
                    c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                p.* = .{ .data = .{ .rgba = img }, .owning = true };
                self.?.py_image = p;
            },
        }
        self.?.numpy_ref = null;
        self.?.parent_ref = null;
        return @as(?*c.PyObject, @ptrCast(self));
    }

    // JPEG: detect grayscale vs color and load native
    if (std.mem.endsWith(u8, path_slice, ".jpg") or std.mem.endsWith(u8, path_slice, ".JPG") or
        std.mem.endsWith(u8, path_slice, ".jpeg") or std.mem.endsWith(u8, path_slice, ".JPEG"))
    {
        const data = std.fs.cwd().readFileAlloc(allocator, path_slice, 200 * 1024 * 1024) catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
        defer allocator.free(data);

        const comps = detectJpegComponents(data) orelse {
            c.PyErr_SetString(c.PyExc_ValueError, "Invalid JPEG file (no SOF marker)");
            return null;
        };
        if (comps == 1) {
            const image = Image(u8).load(allocator, path_slice) catch |err| {
                py_utils.setErrorWithPath(err, path_slice);
                return null;
            };
            const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
            if (self == null) {
                var img = image;
                img.deinit(allocator);
                return null;
            }
            const pimg = allocator.create(PyImage) catch {
                var img = image;
                img.deinit(allocator);
                c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                return null;
            };
            pimg.* = .{ .data = .{ .gray = image }, .owning = true };
            self.?.py_image = pimg;
            self.?.numpy_ref = null;
            self.?.parent_ref = null;
            return @as(?*c.PyObject, @ptrCast(self));
        } else {
            const image = Image(Rgb).load(allocator, path_slice) catch |err| {
                py_utils.setErrorWithPath(err, path_slice);
                return null;
            };
            const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
            if (self == null) {
                var img = image;
                img.deinit(allocator);
                return null;
            }
            const pimg = allocator.create(PyImage) catch {
                var img = image;
                img.deinit(allocator);
                c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                return null;
            };
            pimg.* = .{ .data = .{ .rgb = image }, .owning = true };
            self.?.py_image = pimg;
            self.?.numpy_ref = null;
            self.?.parent_ref = null;
            return @as(?*c.PyObject, @ptrCast(self));
        }
    }

    // Others: default to RGB
    const image = Image(Rgb).load(allocator, path_slice) catch |err| {
        py_utils.setErrorWithPath(err, path_slice);
        return null;
    };
    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) {
        var img = image;
        img.deinit(allocator);
        return null;
    }
    const pimg = allocator.create(PyImage) catch {
        var img = image;
        img.deinit(allocator);
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    pimg.* = .{ .data = .{ .rgb = image }, .owning = true };
    self.?.py_image = pimg;
    self.?.numpy_ref = null;
    self.?.parent_ref = null;
    return @as(?*c.PyObject, @ptrCast(self));
}

// Minimal JPEG header scan to detect number of components.
// Returns 1 for grayscale, 3 for color, or null on error.
fn detectJpegComponents(data: []const u8) ?u8 {
    if (data.len < 4) return null;
    // SOI
    if (!(data[0] == 0xFF and data[1] == 0xD8)) return null;
    var i: usize = 2;
    while (i + 3 < data.len) {
        // Find marker prefix 0xFF
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }
        // Skip fill bytes 0xFF
        while (i < data.len and data[i] == 0xFF) i += 1;
        if (i >= data.len) break;
        const marker = data[i];
        i += 1;
        // Markers without length
        if (marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01) {
            continue;
        }
        if (i + 1 >= data.len) break;
        const len: usize = (@as(usize, data[i]) << 8) | data[i + 1];
        i += 2;
        if (len < 2 or i + len - 2 > data.len) break;
        // SOF0 or SOF2
        if (marker == 0xC0 or marker == 0xC2) {
            if (len < 8) break; // need at least up to components byte
            // length bytes cover: [precision(1), height(2), width(2), components(1), ...]
            const components = data[i + 5];
            return components;
        }
        i += len - 2;
    }
    return null;
}

const image_to_numpy_doc =
    \\Convert the image to a NumPy array (zero-copy when possible).
    \\
    \\Returns an array in the image's native dtype:\n
    \\- Grayscale → shape (rows, cols, 1)\n
    \\- Rgb → shape (rows, cols, 3)\n
    \\- Rgba → shape (rows, cols, 4)
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\arr = img.to_numpy()
    \\print(arr.shape, arr.dtype)
    \\# Example: (H, W, C) uint8 where C is 1, 3, or 4
    \\```
;

fn image_to_numpy(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .gray => |img| {
                // Import numpy
                const np_module = c.PyImport_ImportModule("numpy") orelse {
                    c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
                    return null;
                };
                defer c.Py_DECREF(np_module);

                // Create a memoryview from our image data
                var buffer = c.Py_buffer{
                    .buf = @ptrCast(img.data.ptr),
                    .obj = self_obj,
                    .len = @intCast(img.rows * img.cols * @sizeOf(u8)),
                    .itemsize = 1,
                    .readonly = 0,
                    .ndim = 1,
                    .format = @constCast("B"),
                    .shape = null,
                    .strides = null,
                    .suboffsets = null,
                    .internal = null,
                };
                c.Py_INCREF(self_obj); // Keep parent alive

                const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
                    c.Py_DECREF(self_obj);
                    return null;
                };
                defer c.Py_DECREF(memview);

                // numpy.frombuffer(memview, dtype='uint8').reshape(rows, cols, 1)
                const frombuffer = c.PyObject_GetAttrString(np_module, "frombuffer") orelse return null;
                defer c.Py_DECREF(frombuffer);
                const args_tuple2 = c.Py_BuildValue("(O)", memview) orelse return null;
                defer c.Py_DECREF(args_tuple2);
                const kwargs2 = c.Py_BuildValue("{s:s}", "dtype", "uint8") orelse return null;
                defer c.Py_DECREF(kwargs2);
                const flat_array = c.PyObject_Call(frombuffer, args_tuple2, kwargs2) orelse return null;
                const reshape_method = c.PyObject_GetAttrString(flat_array, "reshape") orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                defer c.Py_DECREF(reshape_method);
                const shape_tuple = c.Py_BuildValue("(III)", img.rows, img.cols, @as(c_uint, 1)) orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                defer c.Py_DECREF(shape_tuple);
                const reshaped = c.PyObject_CallObject(reshape_method, shape_tuple) orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                c.Py_DECREF(flat_array);
                return reshaped;
            },
            .rgb => |img| {
                // Import numpy
                const np_module = c.PyImport_ImportModule("numpy") orelse {
                    c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
                    return null;
                };
                defer c.Py_DECREF(np_module);

                // Create a memoryview from our image data (packed RGB u8)
                var buffer = c.Py_buffer{
                    .buf = @ptrCast(img.data.ptr),
                    .obj = self_obj,
                    .len = @intCast(img.rows * img.cols * @sizeOf(Rgb)),
                    .itemsize = 1,
                    .readonly = 0,
                    .ndim = 1,
                    .format = @constCast("B"),
                    .shape = null,
                    .strides = null,
                    .suboffsets = null,
                    .internal = null,
                };
                c.Py_INCREF(self_obj); // Keep parent alive

                const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
                    c.Py_DECREF(self_obj);
                    return null;
                };
                defer c.Py_DECREF(memview);

                // numpy.frombuffer(memview, dtype='uint8').reshape(rows, cols, 3)
                const frombuffer = c.PyObject_GetAttrString(np_module, "frombuffer") orelse return null;
                defer c.Py_DECREF(frombuffer);
                const args_tuple2 = c.Py_BuildValue("(O)", memview) orelse return null;
                defer c.Py_DECREF(args_tuple2);
                const kwargs2 = c.Py_BuildValue("{s:s}", "dtype", "uint8") orelse return null;
                defer c.Py_DECREF(kwargs2);
                const flat_array = c.PyObject_Call(frombuffer, args_tuple2, kwargs2) orelse return null;
                const reshape_method = c.PyObject_GetAttrString(flat_array, "reshape") orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                defer c.Py_DECREF(reshape_method);
                const shape_tuple = c.Py_BuildValue("(III)", img.rows, img.cols, @as(c_uint, 3)) orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                defer c.Py_DECREF(shape_tuple);
                const reshaped = c.PyObject_CallObject(reshape_method, shape_tuple) orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                c.Py_DECREF(flat_array);
                return reshaped;
            },
            .rgba => |img| {
                // Import numpy
                const np_module = c.PyImport_ImportModule("numpy") orelse {
                    c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
                    return null;
                };
                defer c.Py_DECREF(np_module);

                // Create a memoryview from our image data (packed RGBA u8)
                var buffer = c.Py_buffer{
                    .buf = @ptrCast(img.data.ptr),
                    .obj = self_obj,
                    .len = @intCast(img.rows * img.cols * @sizeOf(Rgba)),
                    .itemsize = 1,
                    .readonly = 0,
                    .ndim = 1,
                    .format = @constCast("B"),
                    .shape = null,
                    .strides = null,
                    .suboffsets = null,
                    .internal = null,
                };
                c.Py_INCREF(self_obj); // Keep parent alive

                const memview = c.PyMemoryView_FromBuffer(&buffer) orelse {
                    c.Py_DECREF(self_obj);
                    return null;
                };
                defer c.Py_DECREF(memview);

                // numpy.frombuffer(memview, dtype='uint8').reshape(rows, cols, 4)
                const frombuffer = c.PyObject_GetAttrString(np_module, "frombuffer") orelse return null;
                defer c.Py_DECREF(frombuffer);
                const args_tuple2 = c.Py_BuildValue("(O)", memview) orelse return null;
                defer c.Py_DECREF(args_tuple2);
                const kwargs2 = c.Py_BuildValue("{s:s}", "dtype", "uint8") orelse return null;
                defer c.Py_DECREF(kwargs2);
                const flat_array = c.PyObject_Call(frombuffer, args_tuple2, kwargs2) orelse return null;
                const reshape_method = c.PyObject_GetAttrString(flat_array, "reshape") orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                defer c.Py_DECREF(reshape_method);
                const shape_tuple = c.Py_BuildValue("(III)", img.rows, img.cols, @as(c_uint, 4)) orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                defer c.Py_DECREF(shape_tuple);
                const reshaped = c.PyObject_CallObject(reshape_method, shape_tuple) orelse {
                    c.Py_DECREF(flat_array);
                    return null;
                };
                c.Py_DECREF(flat_array);
                return reshaped;
            },
        }
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_from_numpy_doc =
    \\Create Image from a NumPy array with dtype uint8.
    \\
    \\Zero-copy is used for contiguous arrays with these shapes:
    \\- RGB: (rows, cols, 3) → Image(Rgb)
    \\- RGBA: (rows, cols, 4) → Image(Rgba)
    \\
    \\Arrays must be C-contiguous. Non-contiguous inputs should be converted with `numpy.ascontiguousarray`.
    \\
    \\## Parameters
    \\- `array` (NDArray[np.uint8]): NumPy array with shape (rows, cols, 3) or (rows, cols, 4) and dtype uint8.
    \\  Must be C-contiguous.
    \\
    \\## Raises
    \\- `TypeError`: If array is None or has wrong dtype
    \\- `ValueError`: If array has wrong shape or is not C-contiguous
    \\
    \\## Notes
    \\The array must be C-contiguous. If your array is not C-contiguous
    \\(e.g., from slicing or transposing), use np.ascontiguousarray() first:
    \\
    \\```python
    \\arr = np.ascontiguousarray(arr)
    \\img = Image.from_numpy(arr)
    \\```
    \\
    \\## Examples
    \\```python
    \\arr = np.zeros((100, 200, 3), dtype=np.uint8)
    \\img = Image.from_numpy(arr)
    \\print(img.rows, img.cols)
    \\# Output: 100 200
    \\```
;

fn image_from_numpy(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var array_obj: ?*c.PyObject = undefined;

    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &array_obj) == 0) {
        return null;
    }

    if (array_obj == null or array_obj == c.Py_None()) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array cannot be None");
        return null;
    }

    // Get buffer interface from the array
    var buffer: c.Py_buffer = undefined;
    buffer = std.mem.zeroes(c.Py_buffer);

    // Request buffer with strides info
    const flags: c_int = 0x001c; // PyBUF_ND | PyBUF_STRIDES | PyBUF_FORMAT
    if (c.PyObject_GetBuffer(array_obj, &buffer, flags) != 0) {
        // Error already set by PyObject_GetBuffer
        return null;
    }
    defer c.PyBuffer_Release(&buffer);

    // Validate buffer format if available (should be 'B' for uint8)
    // Note: format might be null if PyBUF_FORMAT wasn't requested
    if (buffer.format != null and (buffer.format[0] != 'B' or buffer.format[1] != 0)) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array must have dtype uint8");
        return null;
    }

    // Validate dimensions and shape: only 3D arrays with 3 or 4 channels are supported
    const ndim: c_int = buffer.ndim;
    if (ndim != 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have shape (rows, cols, 3|4)");
        return null;
    }

    const shape = @as([*]c.Py_ssize_t, @ptrCast(buffer.shape));
    const rows = @as(usize, @intCast(shape[0]));
    const cols = @as(usize, @intCast(shape[1]));
    const channels: usize = @as(usize, @intCast(shape[2]));
    if (!(channels == 3 or channels == 4)) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have 3 channels (RGB) or 4 channels (RGBA)");
        return null;
    }

    // Check if array is C-contiguous
    const strides = @as([*]c.Py_ssize_t, @ptrCast(buffer.strides));
    const item = buffer.itemsize; // 1 for uint8
    const expected_stride_2 = item; // 1
    const expected_stride_1 = expected_stride_2 * @as(c.Py_ssize_t, @intCast(channels));
    const expected_stride_0 = expected_stride_1 * @as(c.Py_ssize_t, @intCast(cols));
    if (strides[2] != expected_stride_2 or strides[1] != expected_stride_1 or strides[0] != expected_stride_0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array is not C-contiguous. Use numpy.ascontiguousarray() first.");
        return null;
    }

    // Create new Python object
    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) {
        return null;
    }

    if (channels == 4) {
        // Zero-copy: create image that points to NumPy's data directly
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const data_slice = data_ptr[0..@intCast(buffer.len)];

        // Use initFromBytes to reinterpret the data as RGBA pixels
        const img = Image(Rgba).initFromBytes(rows, cols, data_slice);

        // Keep a reference to the NumPy array to prevent deallocation
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
        // Wrap as PyImage non-owning RGBA
        const pimg = allocator.create(PyImage) catch {
            c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
            return null;
        };
        pimg.* = .{ .data = .{ .rgba = img }, .owning = false };
        self.?.py_image = pimg;
        self.?.parent_ref = null;
        return @as(?*c.PyObject, @ptrCast(self));
    } else if (channels == 3) {
        // Zero-copy RGB
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const data_slice = data_ptr[0..@intCast(buffer.len)];
        const img = Image(Rgb).initFromBytes(rows, cols, data_slice);
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
        const pimg = allocator.create(PyImage) catch {
            c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
            return null;
        };
        pimg.* = .{ .data = .{ .rgb = img }, .owning = false };
        self.?.py_image = pimg;
        self.?.parent_ref = null;
    } else unreachable; // validated above
    return @as(?*c.PyObject, @ptrCast(self));
}

const image_save_doc =
    \\Save the image to a PNG file.
    \\
    \\## Parameters
    \\- `path` (str): Path where the PNG file will be saved. Must have .png extension.
    \\
    \\## Raises
    \\- `ValueError`: If the file does not have .png extension
    \\- `MemoryError`: If allocation fails during save
    \\- `PermissionError`: If write permission is denied
    \\- `FileNotFoundError`: If the directory does not exist
    \\
    \\## Examples
    \\```python
    \\img = Image.load("input.png")
    \\img.save("output.png")
    \\```
;

fn image_save(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Determine display format based on spec (parsed below)

    // Parse file path argument
    var file_path: [*c]const u8 = undefined;
    const format = std.fmt.comptimePrint("s", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &file_path) == 0) {
        return null;
    }

    // Convert C string to Zig slice
    const path_slice = std.mem.span(file_path);

    // Validate file extension
    if (!std.mem.endsWith(u8, path_slice, ".png") and
        !std.mem.endsWith(u8, path_slice, ".PNG"))
    {
        c.PyErr_SetString(c.PyExc_ValueError, "File must have .png extension. Currently only PNG format is supported.");
        return null;
    }

    // Save PNG for current image format
    if (self.py_image) |pimg| {
        const res = switch (pimg.data) {
            .gray => |img| img.save(allocator, path_slice),
            .rgb => |img| img.save(allocator, path_slice),
            .rgba => |img| img.save(allocator, path_slice),
        };
        res catch |err| {
            py_utils.setErrorWithPath(err, path_slice);
            return null;
        };
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

const image_convert_doc =
    \\
    \\Convert the image to a different pixel data type.
    \\
    \\Supported targets: Grayscale, Rgb, Rgba.
    \\
    \\Returns a new Image with the requested format.
;

fn image_convert(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse one argument: target dtype sentinel or instance of Rgb/Rgba
    var dtype_obj: ?*c.PyObject = null;
    const fmt = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, fmt.ptr, &dtype_obj) == 0) {
        return null;
    }

    if (dtype_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "convert() requires a target dtype (zignal.Grayscale, zignal.Rgb, or zignal.Rgba)");
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
            c.PyErr_SetString(c.PyExc_TypeError, "format must be zignal.Grayscale, zignal.Rgb, or zignal.Rgba");
            return null;
        }
    } else {
        if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.RgbType)) == 1) {
            target_rgb = true;
        } else if (c.PyObject_IsInstance(dtype_obj.?, @ptrCast(&color_bindings.RgbaType)) == 1) {
            target_rgba = true;
        } else {
            c.PyErr_SetString(c.PyExc_TypeError, "format must be zignal.Grayscale, zignal.Rgb, or zignal.Rgba");
            return null;
        }
    }

    // Execute conversion using underlying Image(T).convert
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .gray => |*img| {
                if (target_gray) {
                    // Same dtype: copy
                    var out = Image(u8).init(allocator, img.rows, img.cols) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                        return null;
                    };
                    img.copy(out);
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        out.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .gray = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                } else if (target_rgb) {
                    const out = img.convert(Rgb, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert image");
                        return null;
                    };
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        var tmp = out;
                        tmp.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .rgb = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                } else if (target_rgba) {
                    const out = img.convert(Rgba, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert image");
                        return null;
                    };
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        var tmp = out;
                        tmp.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .rgba = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                }
            },
            .rgb => |*img| {
                if (target_gray) {
                    const out = img.convert(u8, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert image");
                        return null;
                    };
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        var tmp = out;
                        tmp.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .gray = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                } else if (target_rgb) {
                    var out = Image(Rgb).init(allocator, img.rows, img.cols) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                        return null;
                    };
                    img.copy(out);
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        out.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .rgb = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                } else if (target_rgba) {
                    const out = img.convert(Rgba, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert image");
                        return null;
                    };
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        var tmp = out;
                        tmp.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .rgba = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                }
            },
            .rgba => |*img| {
                if (target_gray) {
                    const out = img.convert(u8, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert image");
                        return null;
                    };
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        var tmp = out;
                        tmp.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .gray = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                } else if (target_rgb) {
                    const out = img.convert(Rgb, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert image");
                        return null;
                    };
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        var tmp = out;
                        tmp.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .rgb = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                } else if (target_rgba) {
                    var out = Image(Rgba).init(allocator, img.rows, img.cols) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                        return null;
                    };
                    img.copy(out);
                    const py = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
                    const out_self = @as(*ImageObject, @ptrCast(py));
                    const pnew = allocator.create(PyImage) catch {
                        out.deinit(allocator);
                        c.Py_DECREF(py);
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                        return null;
                    };
                    pnew.* = .{ .data = .{ .rgba = out } };
                    out_self.py_image = pnew;
                    out_self.numpy_ref = null;
                    out_self.parent_ref = null;
                    return py;
                }
            },
        }
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

fn image_iter(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));
    // Require PyImage variant for iteration
    if (self.py_image == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
    return pixel_iterator.new(self_obj);
}

/// Parse dimension string "WIDTHxHEIGHT" into optional width and height values
/// Examples: "800x600" -> (800, 600), "800x" -> (800, null), "x600" -> (null, 600)
fn parseDimensions(dims_str: []const u8) !struct { width: ?u32, height: ?u32 } {
    const x_pos = std.mem.indexOf(u8, dims_str, "x") orelse
        return error.InvalidFormat;

    const width_str = dims_str[0..x_pos];
    const height_str = dims_str[x_pos + 1 ..];

    var width: ?u32 = null;
    var height: ?u32 = null;

    if (width_str.len > 0) {
        width = std.fmt.parseInt(u32, width_str, 10) catch
            return error.InvalidWidth;
    }

    if (height_str.len > 0) {
        height = std.fmt.parseInt(u32, height_str, 10) catch
            return error.InvalidHeight;
    }

    return .{ .width = width, .height = height };
}

const image_format_doc =
    \\Format image for display using various terminal graphics protocols.
    \\
    \\## Parameters
    \\- `format_spec` (str): Format specifier for display:
    \\  - `''` (empty): Returns text representation (e.g., 'Image(800x600)')
    \\  - `'auto'`: Auto-detect best format with progressive degradation: kitty → sixel → blocks
    \\  - `'ansi'`: Display using ANSI escape codes (spaces with background)
    \\  - `'blocks'`: Display using ANSI escape codes (half colored half-blocks with background: 2x vertical resolution)
    \\  - `'braille'`: Display using Braille patterns (good for monochrome images)
    \\  - `'sixel'`: Display using sixel graphics protocol (up to 256 colors)
    \\  - `'sixel:WIDTHxHEIGHT'`: Display using sixel scaled to fit (e.g., 'sixel:800x600')
    \\  - `'sixel:WIDTHx'`: Scale to fit width, maintain aspect ratio (e.g., 'sixel:800x')
    \\  - `'sixel:xHEIGHT'`: Scale to fit height, maintain aspect ratio (e.g., 'sixel:x600')
    \\  - `'kitty'`: Display using kitty graphics protocol (24-bit color)
    \\  - `'kitty:WIDTHxHEIGHT'`: Display using kitty scaled to fit (e.g., 'kitty:800x600')
    \\  - `'kitty:WIDTHx'`: Display with specified width, height auto-calculated (e.g., 'kitty:800x')
    \\  - `'kitty:xHEIGHT'`: Display with specified height, width auto-calculated (e.g., 'kitty:x600')
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\print(f"{img}")         # Image(800x600)
    \\print(f"{img:ansi}")    # Display with ANSI colors
    \\print(f"{img:blocks}")  # Display with unicode blocks
    \\print(f"{img:braille}") # Display with braille patterns
    \\print(f"{img:sixel}")   # Display with sixel graphics
    \\print(f"{img:sixel:800x600}")   # Display with sixel, scaled to fit 800x600
    \\print(f"{img:sixel:800x}")      # Display with sixel, scaled to 800px width
    \\print(f"{img:sixel:x600}")      # Display with sixel, scaled to 600px height
    \\print(f"{img:kitty}")           # Display with kitty graphics
    \\print(f"{img:kitty:800x600}")   # Display with kitty, scaled to fit 800x600
    \\print(f"{img:kitty:800x}")      # Display with kitty, 800 pixels wide
    \\print(f"{img:kitty:x600}")      # Display with kitty, 600 pixels tall
    \\```
;

fn image_format(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse format_spec argument
    var format_spec: [*c]const u8 = undefined;
    const format = std.fmt.comptimePrint("s", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &format_spec) == 0) {
        return null;
    }

    // Convert C string to Zig slice
    const spec_slice = std.mem.span(format_spec);

    // If empty format spec, return default repr
    if (spec_slice.len == 0) {
        return image_repr(self_obj);
    }

    // Determine display format based on spec

    // Determine display format based on spec
    const display_format: DisplayFormat = if (std.mem.eql(u8, spec_slice, "ansi"))
        .ansi_basic
    else if (std.mem.eql(u8, spec_slice, "blocks"))
        .ansi_blocks
    else if (std.mem.eql(u8, spec_slice, "braille"))
        .{ .braille = .default }
    else if (std.mem.eql(u8, spec_slice, "sixel"))
        .{ .sixel = .default }
    else if (std.mem.startsWith(u8, spec_slice, "sixel:")) blk: {
        // Parse sixel with dimensions: "sixel:WIDTHxHEIGHT"
        const dims_str = spec_slice[6..]; // Skip "sixel:"

        const dims = parseDimensions(dims_str) catch |err| {
            const msg = switch (err) {
                error.InvalidFormat => "Invalid sixel format. Use 'sixel:WIDTHxHEIGHT', 'sixel:WIDTHx', or 'sixel:xHEIGHT'",
                error.InvalidWidth => "Invalid width value in sixel format",
                error.InvalidHeight => "Invalid height value in sixel format",
            };
            c.PyErr_SetString(c.PyExc_ValueError, msg);
            return null;
        };

        // Create sixel options with custom dimensions
        break :blk .{ .sixel = .{
            .palette = .{ .adaptive = .{ .max_colors = 256 } },
            .dither = .auto,
            .width = dims.width,
            .height = dims.height,
            .interpolation = .nearest_neighbor,
        } };
    } else if (std.mem.eql(u8, spec_slice, "kitty"))
        .{ .kitty = .default }
    else if (std.mem.startsWith(u8, spec_slice, "kitty:")) blk: {
        // Parse kitty with dimensions: "kitty:WIDTHxHEIGHT"
        const dims_str = spec_slice[6..]; // Skip "kitty:"

        const dims = parseDimensions(dims_str) catch |err| {
            const msg = switch (err) {
                error.InvalidFormat => "Invalid kitty format. Use 'kitty:WIDTHxHEIGHT', 'kitty:WIDTHx', or 'kitty:xHEIGHT'",
                error.InvalidWidth => "Invalid width value in kitty format",
                error.InvalidHeight => "Invalid height value in kitty format",
            };
            c.PyErr_SetString(c.PyExc_ValueError, msg);
            return null;
        };

        // Create kitty options with custom dimensions (in pixels)
        break :blk .{
            .kitty = .{
                .quiet = 1,
                .image_id = null,
                .placement_id = null,
                .delete_after = false,
                .enable_chunking = false,
                .width = dims.width,
                .height = dims.height,
                .interpolation = .bilinear,
            },
        };
    } else if (std.mem.eql(u8, spec_slice, "auto"))
        .auto
    else if (std.mem.startsWith(u8, spec_slice, "sixel")) {
        // Invalid sixel format that doesn't match "sixel" or "sixel:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sixel format. Use 'sixel' or 'sixel:WIDTHxHEIGHT' (e.g., 'sixel:800x600', 'sixel:800x', 'sixel:x600')");
        return null;
    } else if (std.mem.startsWith(u8, spec_slice, "kitty")) {
        // Invalid kitty format that doesn't match "kitty" or "kitty:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid kitty format. Use 'kitty' or 'kitty:WIDTHxHEIGHT' (e.g., 'kitty:800x600', 'kitty:800x', 'kitty:x600')");
        return null;
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid format spec. Use '', 'ansi', 'blocks', 'braille', 'sixel', 'sixel:WIDTHxHEIGHT', 'kitty', 'kitty:WIDTHxHEIGHT', or 'auto'");
        return null;
    };

    // Format image according to display_format and return a string
    if (self.py_image) |pimg| {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);
        const w = buffer.writer(allocator);
        switch (pimg.data) {
            .gray => |*img| std.fmt.format(w, "{f}", .{img.display(display_format)}) catch |err| {
                if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                return null;
            },
            .rgb => |*img| std.fmt.format(w, "{f}", .{img.display(display_format)}) catch |err| {
                if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                return null;
            },
            .rgba => |*img| std.fmt.format(w, "{f}", .{img.display(display_format)}) catch |err| {
                if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                return null;
            },
        }
        return c.PyUnicode_FromStringAndSize(buffer.items.ptr, @intCast(buffer.items.len));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

fn pythonToZigInterpolation(py_value: c_long) !InterpolationMethod {
    return switch (py_value) {
        0 => .nearest_neighbor,
        1 => .bilinear,
        2 => .bicubic,
        3 => .catmull_rom,
        4 => .{ .mitchell = .{ .b = 1.0 / 3.0, .c = 1.0 / 3.0 } }, // Default Mitchell parameters
        5 => .lanczos,
        else => return error.InvalidInterpolationMethod,
    };
}

fn image_scale(self: *ImageObject, scale: f32, method: InterpolationMethod) !*ImageObject {
    if (self.py_image) |pimg| {
        // Dispatch by variant
        switch (pimg.data) {
            .gray => |*img| {
                var out = img.scale(allocator, scale, method) catch |err| return mapScaleError(err);
                const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
            .rgb => |*img| {
                var out = img.scale(allocator, scale, method) catch |err| return mapScaleError(err);
                const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
            .rgba => |*img| {
                var out = img.scale(allocator, scale, method) catch |err| return mapScaleError(err);
                const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
        }
    }
    return error.ImageNotInitialized;
}

fn image_reshape(self: *ImageObject, rows: usize, cols: usize, method: InterpolationMethod) !*ImageObject {
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .gray => |*img| {
                var out = Image(u8).init(allocator, rows, cols) catch return error.OutOfMemory;
                img.resize(allocator, out, method) catch return error.OutOfMemory;
                const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
            .rgb => |*img| {
                var out = Image(Rgb).init(allocator, rows, cols) catch return error.OutOfMemory;
                img.resize(allocator, out, method) catch return error.OutOfMemory;
                const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
            .rgba => |*img| {
                var out = Image(Rgba).init(allocator, rows, cols) catch return error.OutOfMemory;
                img.resize(allocator, out, method) catch return error.OutOfMemory;
                const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
                const result = @as(*ImageObject, @ptrCast(py_obj));
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
                result.numpy_ref = null;
                result.parent_ref = null;
                return result;
            },
        }
    }
    return error.ImageNotInitialized;
}

fn mapScaleError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidScaleFactor => blk: {
            c.PyErr_SetString(c.PyExc_ValueError, "Scale factor must be positive");
            break :blk error.InvalidScaleFactor;
        },
        error.InvalidDimensions => blk: {
            c.PyErr_SetString(c.PyExc_ValueError, "Resulting image dimensions would be zero");
            break :blk error.InvalidDimensions;
        },
        error.OutOfMemory => blk: {
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate scaled image");
            break :blk error.OutOfMemory;
        },
        else => err,
    };
}

const image_fill_doc =
    \\Fill the entire image with a solid color.
    \\
    \\The color is converted to the image's native pixel data type (Grayscale/Rgb/Rgba).
    \\
    \\## Parameters
    \\- `color`: Color value as:
    \\  - int: Grayscale value (0-255)
    \\  - tuple[int, int, int]: RGB values
    \\  - tuple[int, int, int, int]: RGBA values
    \\  - Any supported color object (e.g., Rgb, Rgba)
    \\
    \\## Examples
    \\```python
    \\img.fill(128)                      # Fill with gray
    \\img.fill((255, 0, 0))              # Fill with red
    \\img.fill((0, 255, 0, 128))         # Fill with semi-transparent green
    \\img.fill(zignal.Rgb(255, 128, 0))  # Fill with orange using color object
    \\```
;

fn image_fill(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments - expect a color
    var color_obj: ?*c.PyObject = null;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &color_obj) == 0) {
        return null;
    }

    const color = color_utils.parseColorTo(Rgba, color_obj) catch {
        return null;
    };

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .gray => |*img| img.fill(color),
            .rgb => |*img| img.fill(color),
            .rgba => |*img| img.fill(color),
        }
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    c.Py_INCREF(c.Py_None());
    return c.Py_None();
}

const image_resize_doc =
    \\Resize the image to the specified size.
    \\
    \\## Parameters
    \\- `size` (float or tuple[int, int]):
    \\  - If float: scale factor (e.g., 0.5 for half size, 2.0 for double size)
    \\  - If tuple: target dimensions as (rows, cols)
    \\- `method` (`InterpolationMethod`, optional): Interpolation method to use. Default is `InterpolationMethod.BILINEAR`.
;

fn image_resize(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var shape_or_scale: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR

    var kwlist = [_:null]?[*:0]u8{ @constCast("size"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("O|l", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &shape_or_scale, &method_value) == 0) {
        return null;
    }

    if (shape_or_scale == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "resize() missing required argument: 'size' (pos 1)");
        return null;
    }

    // Convert method value to Zig enum
    const method = pythonToZigInterpolation(method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };

    // Check if argument is a number (scale) or tuple (dimensions)
    if (c.PyFloat_Check(shape_or_scale) != 0 or c.PyLong_Check(shape_or_scale) != 0) {
        // It's a scale factor
        const scale = c.PyFloat_AsDouble(shape_or_scale);
        if (scale == -1.0 and c.PyErr_Occurred() != null) {
            return null;
        }
        if (scale <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Scale factor must be positive");
            return null;
        }

        const result = image_scale(self, @floatCast(scale), method) catch return null;
        return @ptrCast(result);
    } else if (c.PyTuple_Check(shape_or_scale) != 0) {
        // It's a tuple of dimensions
        if (c.PyTuple_Size(shape_or_scale) != 2) {
            c.PyErr_SetString(c.PyExc_ValueError, "Size must be a 2-tuple of (rows, cols)");
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(shape_or_scale, 0);
        const cols_obj = c.PyTuple_GetItem(shape_or_scale, 1);

        const rows = c.PyLong_AsLong(rows_obj);
        if (rows == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Rows must be an integer");
            return null;
        }
        if (rows <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Rows must be positive");
            return null;
        }

        const cols = c.PyLong_AsLong(cols_obj);
        if (cols == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Cols must be an integer");
            return null;
        }
        if (cols <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Cols must be positive");
            return null;
        }

        const result = image_reshape(self, @intCast(rows), @intCast(cols), method) catch return null;
        return @ptrCast(result);
    } else {
        c.PyErr_SetString(c.PyExc_TypeError, "resize() argument must be a number (scale) or tuple (rows, cols)");
        return null;
    }
}

fn image_letterbox_square(self: *ImageObject, size: usize, method: InterpolationMethod) !*ImageObject {
    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).init(allocator, size, size) catch return error.OutOfMemory;
                _ = img.letterbox(allocator, &out, method) catch return error.OutOfMemory;
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).init(allocator, size, size) catch return error.OutOfMemory;
                _ = img.letterbox(allocator, &out, method) catch return error.OutOfMemory;
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).init(allocator, size, size) catch return error.OutOfMemory;
                _ = img.letterbox(allocator, &out, method) catch {
                    out.deinit(allocator);
                    return error.OutOfMemory;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return result;
    }
    return error.ImageNotInitialized;
}

fn image_letterbox_shape(self: *ImageObject, rows: usize, cols: usize, method: InterpolationMethod) !*ImageObject {
    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return error.OutOfMemory;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).init(allocator, rows, cols) catch return error.OutOfMemory;
                _ = img.letterbox(allocator, &out, method) catch return error.OutOfMemory;
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).init(allocator, rows, cols) catch return error.OutOfMemory;
                _ = img.letterbox(allocator, &out, method) catch return error.OutOfMemory;
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).init(allocator, rows, cols) catch return error.OutOfMemory;
                _ = img.letterbox(allocator, &out, method) catch {
                    out.deinit(allocator);
                    return error.OutOfMemory;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return error.OutOfMemory;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return result;
    }
    return error.ImageNotInitialized;
}

const image_rotate_doc =
    \\Rotate the image by the specified angle around its center.
    \\
    \\The output image is automatically sized to fit the entire rotated image without clipping.
    \\
    \\## Parameters
    \\- `angle` (float): Rotation angle in radians counter-clockwise.
    \\- `method` (`InterpolationMethod`, optional): Interpolation method to use. Default is `InterpolationMethod.BILINEAR`.
    \\
    \\## Examples
    \\```python
    \\import math
    \\img = Image.load("photo.png")
    \\
    \\# Rotate 45 degrees with default bilinear interpolation
    \\rotated = img.rotate(math.radians(45))
    \\
    \\# Rotate 90 degrees with nearest neighbor (faster, lower quality)
    \\rotated = img.rotate(math.radians(90), InterpolationMethod.NEAREST_NEIGHBOR)
    \\
    \\# Rotate -30 degrees with Lanczos (slower, higher quality)
    \\rotated = img.rotate(math.radians(-30), InterpolationMethod.LANCZOS)
    \\```
;

fn image_rotate(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var angle: f64 = 0;
    var method_value: c_long = 1; // Default to BILINEAR
    var kwlist = [_:null]?[*:0]u8{ @constCast("angle"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("d|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &angle, &method_value) == 0) {
        return null;
    }

    // Convert method value to Zig enum
    const method = pythonToZigInterpolation(method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).empty;
                img.rotate(allocator, @floatCast(angle), method, &out) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).empty;
                img.rotate(allocator, @floatCast(angle), method, &out) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).empty;
                img.rotate(allocator, @floatCast(angle), method, &out) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_box_blur_doc =
    \\Apply a box blur to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius in pixels. `0` returns an unmodified copy.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\soft = img.box_blur(2)
    \\identity = img.box_blur(0)  # no-op copy
    \\```
;

fn image_box_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var radius_long: c_long = 0;
    var kwlist = [_:null]?[*:0]u8{ @constCast("radius"), null };
    const format = std.fmt.comptimePrint("l", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &radius_long) == 0) {
        return null;
    }

    if (radius_long < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "radius must be >= 0");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).empty;
                img.boxBlur(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).empty;
                img.boxBlur(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).empty;
                img.boxBlur(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_sharpen_doc =
    \\Sharpen the image using unsharp masking (2 * self - blur_box).
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius used to compute the unsharp mask. `0` returns an unmodified copy.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\crisp = img.sharpen(2)
    \\identity = img.sharpen(0)  # no-op copy
    \\```
;

fn image_sharpen(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var radius_long: c_long = 0;
    var kwlist = [_:null]?[*:0]u8{ @constCast("radius"), null };
    const format = std.fmt.comptimePrint("l", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &radius_long) == 0) {
        return null;
    }

    if (radius_long < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "radius must be >= 0");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).empty;
                img.sharpen(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).empty;
                img.sharpen(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).empty;
                img.sharpen(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_gaussian_blur_doc =
    \\Apply Gaussian blur to the image.
    \\
    \\## Parameters
    \\- `sigma` (float): Standard deviation of the Gaussian kernel. Must be > 0.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\blurred = img.gaussian_blur(2.0)
    \\blurred_soft = img.gaussian_blur(5.0)  # More blur
    \\```
;

fn image_gaussian_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var sigma: f64 = 0;
    var kwlist = [_:null]?[*:0]u8{ @constCast("sigma"), null };
    const format = std.fmt.comptimePrint("d", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &sigma) == 0) {
        return null;
    }

    // Validate sigma: must be finite and > 0
    if (!std.math.isFinite(sigma) or sigma <= 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "sigma must be > 0");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).empty;
                img.gaussianBlur(allocator, @floatCast(sigma), &out) catch |err| {
                    c.Py_DECREF(py_obj);
                    if (err == error.InvalidSigma) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sigma value");
                    } else {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    }
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).empty;
                img.gaussianBlur(allocator, @floatCast(sigma), &out) catch |err| {
                    c.Py_DECREF(py_obj);
                    if (err == error.InvalidSigma) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sigma value");
                    } else {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    }
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).empty;
                img.gaussianBlur(allocator, @floatCast(sigma), &out) catch |err| {
                    c.Py_DECREF(py_obj);
                    if (err == error.InvalidSigma) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sigma value");
                    } else {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    }
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_psnr_doc =
    \\Calculate the Peak Signal-to-Noise Ratio (PSNR) between two images.
    \\
    \\Returns the PSNR value in decibels (dB). Higher values indicate more similarity.
    \\  - Typical values: 30-50 dB for good quality
    \\  - Returns `inf` for identical images
    \\
    \\## Parameters
    \\- `other` (Image): The image to compare against. Must have the same dimensions.
    \\
    \\
    \\## Raises
    \\- `ValueError`: If the images have different dimensions
    \\- `TypeError`: If `other` is not an Image object
    \\
    \\## Examples
    \\```python
    \\img1 = Image.load("original.png")
    \\img2 = Image.load("compressed.jpg")
    \\psnr_value = img1.psnr(img2)
    \\print(f"PSNR: {psnr_value:.2f} dB")
    \\
    \\# Identical images return infinity
    \\img3 = img1.copy()
    \\print(img1.psnr(img3))  # inf
    \\```
;

fn image_psnr(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments - expecting one Image object
    var other_obj: ?*c.PyObject = null;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &other_obj) == 0) {
        return null;
    }

    // Check if other is an Image instance
    if (c.PyObject_IsInstance(other_obj, @ptrCast(&ImageType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Argument must be an Image object");
        return null;
    }

    const other = @as(*ImageObject, @ptrCast(other_obj.?));

    // Require both images initialized via PyImage
    if (self.py_image == null or other.py_image == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    // Store in local variables after null check
    const a = self.py_image.?;
    const b = other.py_image.?;

    // Compute PSNR only when both have the same pixel dtype
    var out_value: f64 = 0;
    switch (a.data) {
        .gray => |img_a| {
            const img_b = switch (b.data) {
                .gray => |i| i,
                else => {
                    c.PyErr_SetString(c.PyExc_TypeError, "PSNR requires both images have the same pixel dtype");
                    return null;
                },
            };
            out_value = img_a.psnr(img_b) catch |err| {
                if (err == error.DimensionMismatch) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrintZ(&buf, "Image dimensions must match. Self: {}x{}, Other: {}x{}", .{
                        img_a.rows,
                        img_a.cols,
                        img_b.rows,
                        img_b.cols,
                    }) catch "Image dimensions must match";
                    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                    return null;
                }
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to compute PSNR");
                return null;
            };
        },
        .rgb => |img_a| {
            const img_b = switch (b.data) {
                .rgb => |i| i,
                else => {
                    c.PyErr_SetString(c.PyExc_TypeError, "PSNR requires both images have the same pixel dtype");
                    return null;
                },
            };
            out_value = img_a.psnr(img_b) catch |err| {
                if (err == error.DimensionMismatch) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrintZ(&buf, "Image dimensions must match. Self: {}x{}, Other: {}x{}", .{
                        img_a.rows,
                        img_a.cols,
                        img_b.rows,
                        img_b.cols,
                    }) catch "Image dimensions must match";
                    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                    return null;
                }
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to compute PSNR");
                return null;
            };
        },
        .rgba => |img_a| {
            const img_b = switch (b.data) {
                .rgba => |i| i,
                else => {
                    c.PyErr_SetString(c.PyExc_TypeError, "PSNR requires both images have the same pixel dtype");
                    return null;
                },
            };
            out_value = img_a.psnr(img_b) catch |err| {
                if (err == error.DimensionMismatch) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrintZ(&buf, "Image dimensions must match. Self: {}x{}, Other: {}x{}", .{
                        img_a.rows,
                        img_a.cols,
                        img_b.rows,
                        img_b.cols,
                    }) catch "Image dimensions must match";
                    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                    return null;
                }
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to compute PSNR");
                return null;
            };
        },
    }

    return c.PyFloat_FromDouble(out_value);
}

const image_copy_doc =
    \\Return a deep copy of the image.
    \\
    \\The returned image has the same dimensions and pixel data, but its
    \\memory is independent. Modifying one image does not affect the other.
    \\
    \\## Examples
    \\```python
    \\img2 = img.copy()
    \\```
;

fn image_copy(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                const out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    var tmp = out;
                    tmp.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                const out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    var tmp = out;
                    tmp.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                const out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    var tmp = out;
                    tmp.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_view_doc =
    \\Create a view (sub-image) from a rectangular region.
    \\
    \\A view shares memory with the parent image, so changes to either
    \\are reflected in both. This is a zero-copy operation.
    \\
    \\## Parameters
    \\- `rect` (`Rectangle`): The rectangular region to view
    \\
    \\## Examples
    \\```python
    \\# Create a view of the top-left quadrant
    \\rect = Rectangle(0, 0, img.cols // 2, img.rows // 2)
    \\view = img.view(rect)
    \\
    \\# Modifications to the view affect the parent
    \\view.fill((255, 0, 0))  # Fills the top-left quadrant with red
    \\
    \\# Check if an image is a view
    \\print(view.is_view)  # True
    \\print(img.is_view)   # False (unless img itself is a view)
    \\```
    \\
    \\## Notes
    \\- Views maintain a reference to their parent to prevent memory deallocation
    \\- The rectangle bounds are clipped to the parent image dimensions
    \\- Views can be nested (a view of a view)
;

fn image_view(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse the Rectangle argument
    var rect_obj: ?*c.PyObject = null;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &rect_obj) == 0) {
        return null;
    }

    // Parse the Rectangle object
    const frect = py_utils.parseRectangle(rect_obj) catch return null;

    // Convert f32 rectangle to usize for the view method
    const rect = zignal.Rectangle(usize).init(
        @intFromFloat(@max(0, frect.l)),
        @intFromFloat(@max(0, frect.t)),
        @intFromFloat(@max(0, frect.r)),
        @intFromFloat(@max(0, frect.b)),
    );

    if (self.py_image) |pimg| {
        // Create new Python Image wrapping the view in the same variant
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                const view_img = img.view(rect);
                const pnew = allocator.create(PyImage) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate view");
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = view_img }, .owning = false };
                result.py_image = pnew;
            },
            .rgb => |img| {
                const view_img = img.view(rect);
                const pnew = allocator.create(PyImage) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate view");
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = view_img }, .owning = false };
                result.py_image = pnew;
            },
            .rgba => |img| {
                const view_img = img.view(rect);
                const pnew = allocator.create(PyImage) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate view");
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = view_img }, .owning = false };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        c.Py_INCREF(self_obj);
        result.parent_ref = self_obj;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_flip_left_right_doc =
    \\Flip image left-to-right (horizontal mirror).
    \\
    \\Returns a new image that is a horizontal mirror of the original.
    \\```python
    \\flipped = img.flip_left_right()
    \\```
;

fn image_flip_left_right(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipLeftRight();
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipLeftRight();
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipLeftRight();
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_flip_top_bottom_doc =
    \\Flip image top-to-bottom (vertical mirror).
    \\
    \\Returns a new image that is a vertical mirror of the original.
    \\```python
    \\flipped = img.flip_top_bottom()
    \\```
;

fn image_flip_top_bottom(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipTopBottom();
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipTopBottom();
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = img.dupe(allocator) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                out.flipTopBottom();
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_letterbox_doc =
    \\Resize image to fit within the specified size while preserving aspect ratio.
    \\
    \\The image is scaled to fit within the target dimensions and centered with
    \\black borders (letterboxing) to maintain the original aspect ratio.
    \\
    \\## Parameters
    \\- `size` (int or tuple[int, int]):
    \\  - If int: creates a square output of size x size
    \\  - If tuple: target dimensions as (rows, cols)
    \\- `method` (`InterpolationMethod`, optional): Interpolation method to use. Default is `InterpolationMethod.BILINEAR`.
;

fn image_letterbox(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var size: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR
    var kwlist = [_:null]?[*:0]u8{ @constCast("size"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("O|l", .{});

    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &size, &method_value) == 0) {
        return null;
    }

    if (size == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "letterbox() missing required argument: 'size' (pos 1)");
        return null;
    }

    // Convert method value to Zig enum
    const method = pythonToZigInterpolation(method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };

    // Check if argument is a number (square) or tuple (dimensions)
    if (c.PyLong_Check(size) != 0) {
        // It's an integer for square letterbox
        const square_size = c.PyLong_AsLong(size);
        if (square_size == -1 and c.PyErr_Occurred() != null) {
            return null;
        }
        if (square_size <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Size must be positive");
            return null;
        }
        const result = image_letterbox_square(self, @intCast(square_size), method) catch return null;
        return @ptrCast(result);
    } else if (c.PyTuple_Check(size) != 0) {
        // It's a tuple for dimensions
        if (c.PyTuple_Size(size) != 2) {
            c.PyErr_SetString(c.PyExc_ValueError, "Dimensions must be a tuple of 2 integers (rows, cols)");
            return null;
        }

        const rows_obj = c.PyTuple_GetItem(size, 0);
        const cols_obj = c.PyTuple_GetItem(size, 1);

        if (c.PyLong_Check(rows_obj) == 0 or c.PyLong_Check(cols_obj) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "Dimensions must be integers");
            return null;
        }

        const rows = c.PyLong_AsLong(rows_obj);
        const cols = c.PyLong_AsLong(cols_obj);

        if ((rows == -1 or cols == -1) and c.PyErr_Occurred() != null) {
            return null;
        }

        if (rows <= 0 or cols <= 0) {
            c.PyErr_SetString(c.PyExc_ValueError, "Dimensions must be positive");
            return null;
        }

        const result = image_letterbox_shape(self, @intCast(rows), @intCast(cols), method) catch return null;
        return @ptrCast(result);
    } else {
        c.PyErr_SetString(c.PyExc_TypeError, "letterbox() argument must be an integer (square) or tuple (rows, cols)");
        return null;
    }
}

const image_crop_doc =
    \\Extract a rectangular region from the image.
    \\
    \\Returns a new Image containing the cropped region. Pixels outside the original
    \\image bounds are filled with transparent black (0, 0, 0, 0).
    \\
    \\## Parameters
    \\- `rect` (Rectangle): The rectangular region to extract
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\rect = Rectangle(10, 10, 110, 110)  # 100x100 region starting at (10, 10)
    \\cropped = img.crop(rect)
    \\print(cropped.rows, cropped.cols)  # 100 100
    \\```
;

fn image_crop(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse Rectangle argument
    var rect_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &rect_obj) == 0) {
        return null;
    }

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(rect_obj) catch return null;

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |*img| {
                var out = Image(u8).init(allocator, img.rows, img.cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                img.crop(allocator, rect, &out) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate cropped image");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |*img| {
                var out = Image(Rgb).init(allocator, img.rows, img.cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                img.crop(allocator, rect, &out) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate cropped image");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |*img| {
                var out = Image(Rgba).init(allocator, img.rows, img.cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                img.crop(allocator, rect, &out) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate cropped image");
                    return null;
                };
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_extract_doc =
    \\Extract a rotated rectangular region from the image and resample it.
    \\
    \\Returns a new Image containing the extracted and resampled region.
    \\
    \\## Parameters
    \\- `rect` (Rectangle): The rectangular region to extract (before rotation)
    \\- `angle` (float, optional): Rotation angle in radians (counter-clockwise). Default: 0.0
    \\- `size` (int or tuple[int, int], optional). If not specified, uses the rectangle's dimensions.
    \\  - If int: output is a square of side `size`
    \\  - If tuple: output size as (rows, cols)
    \\- `method` (InterpolationMethod, optional): Interpolation method. Default: BILINEAR
    \\
    \\## Examples
    \\```python
    \\import math
    \\img = Image.load("photo.png")
    \\rect = Rectangle(10, 10, 110, 110)
    \\
    \\# Extract without rotation
    \\extracted = img.extract(rect)
    \\
    \\# Extract with 45-degree rotation
    \\rotated = img.extract(rect, angle=math.radians(45))
    \\
    \\# Extract and resize to specific dimensions
    \\resized = img.extract(rect, size=(50, 75))
    \\
    \\# Extract to a 64x64 square
    \\square = img.extract(rect, size=64)
    \\```
;

fn image_extract(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var rect_obj: ?*c.PyObject = undefined;
    var angle: f64 = 0.0;
    var size_obj: ?*c.PyObject = null;
    var method_value: c_long = 1; // Default to BILINEAR

    var kwlist = [_:null]?[*:0]u8{ @constCast("rect"), @constCast("angle"), @constCast("size"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("O|dOl", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &rect_obj, &angle, &size_obj, &method_value) == 0) {
        return null;
    }

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(rect_obj) catch return null;

    // Convert method value to Zig enum
    const method = pythonToZigInterpolation(method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };

    // Determine output size
    var out_rows: usize = @intFromFloat(@round(rect.height()));
    var out_cols: usize = @intFromFloat(@round(rect.width()));

    if (size_obj != null and size_obj != c.Py_None()) {
        // Accept either an integer (square) or a tuple (rows, cols)
        if (c.PyLong_Check(size_obj) != 0) {
            const square = c.PyLong_AsLong(size_obj);
            if (square == -1 and c.PyErr_Occurred() != null) {
                return null;
            }
            if (square <= 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "size must be positive");
                return null;
            }
            out_rows = @intCast(square);
            out_cols = @intCast(square);
        } else if (c.PyTuple_Check(size_obj) != 0) {
            if (c.PyTuple_Size(size_obj) != 2) {
                c.PyErr_SetString(c.PyExc_ValueError, "size must be a 2-tuple of (rows, cols)");
                return null;
            }

            const rows_obj = c.PyTuple_GetItem(size_obj, 0);
            const cols_obj = c.PyTuple_GetItem(size_obj, 1);

            const rows = c.PyLong_AsLong(rows_obj);
            if (rows == -1 and c.PyErr_Occurred() != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "Rows must be an integer");
                return null;
            }
            if (rows <= 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "Rows must be positive");
                return null;
            }

            const cols = c.PyLong_AsLong(cols_obj);
            if (cols == -1 and c.PyErr_Occurred() != null) {
                c.PyErr_SetString(c.PyExc_TypeError, "Cols must be an integer");
                return null;
            }
            if (cols <= 0) {
                c.PyErr_SetString(c.PyExc_ValueError, "Cols must be positive");
                return null;
            }

            out_rows = @intCast(rows);
            out_cols = @intCast(cols);
        } else {
            c.PyErr_SetString(c.PyExc_TypeError, "size must be an int (square) or a tuple (rows, cols)");
            return null;
        }
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            .gray => |img| {
                var out = Image(u8).init(allocator, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                img.extract(rect, @floatCast(angle), out, method);
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .gray = out } };
                result.py_image = pnew;
            },
            .rgb => |img| {
                var out = Image(Rgb).init(allocator, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                img.extract(rect, @floatCast(angle), out, method);
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgb = out } };
                result.py_image = pnew;
            },
            .rgba => |img| {
                var out = Image(Rgba).init(allocator, out_rows, out_cols) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
                    return null;
                };
                img.extract(rect, @floatCast(angle), out, method);
                const pnew = allocator.create(PyImage) catch {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                pnew.* = .{ .data = .{ .rgba = out } };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_insert_doc =
    \\Insert a source image into this image at a specified rectangle with optional rotation.
    \\
    \\This method modifies the image in-place.
    \\
    \\## Parameters
    \\- `source` (Image): The image to insert
    \\- `rect` (Rectangle): Destination rectangle where the source will be placed
    \\- `angle` (float, optional): Rotation angle in radians (counter-clockwise). Default: 0.0
    \\- `method` (InterpolationMethod, optional): Interpolation method. Default: BILINEAR
    \\
    \\## Examples
    \\```python
    \\import math
    \\canvas = Image(500, 500)
    \\logo = Image.load("logo.png")
    \\
    \\# Insert at top-left
    \\rect = Rectangle(10, 10, 110, 110)
    \\canvas.insert(logo, rect)
    \\
    \\# Insert with rotation
    \\rect2 = Rectangle(200, 200, 300, 300)
    \\canvas.insert(logo, rect2, angle=math.radians(45))
    \\```
;

fn image_insert(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var source_obj: ?*c.PyObject = undefined;
    var rect_obj: ?*c.PyObject = undefined;
    var angle: f64 = 0.0;
    var method_value: c_long = 1; // Default to BILINEAR

    var kwlist = [_:null]?[*:0]u8{ @constCast("source"), @constCast("rect"), @constCast("angle"), @constCast("method"), null };
    const format = std.fmt.comptimePrint("OO|dl", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &source_obj, &rect_obj, &angle, &method_value) == 0) {
        return null;
    }

    // Check if source is an Image object
    if (c.PyObject_IsInstance(source_obj, @ptrCast(&ImageType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "source must be an Image object");
        return null;
    }

    const source = @as(*ImageObject, @ptrCast(source_obj.?));

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(rect_obj) catch return null;

    // Convert method value to Zig enum
    const method = pythonToZigInterpolation(method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };

    // Variant-aware in-place insert
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            .gray => |*dst| {
                var src_u8: Image(u8) = undefined;
                if (source.py_image == null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "Source image not initialized");
                    return null;
                }
                const src_pimg = source.py_image.?;
                switch (src_pimg.data) {
                    .gray => |img| src_u8 = img,
                    .rgb => |img| src_u8 = img.convert(u8, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                    .rgba => |img| src_u8 = img.convert(u8, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                }
                defer src_u8.deinit(allocator);
                dst.insert(src_u8, rect, @floatCast(angle), method);
            },
            .rgb => |*dst| {
                var src_rgb: Image(Rgb) = undefined;
                if (source.py_image == null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "Source image not initialized");
                    return null;
                }
                const src_pimg = source.py_image.?;
                switch (src_pimg.data) {
                    .rgb => |img| src_rgb = img,
                    .gray => |img| src_rgb = img.convert(Rgb, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                    .rgba => |img| src_rgb = img.convert(Rgb, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                }
                defer src_rgb.deinit(allocator);
                dst.insert(src_rgb, rect, @floatCast(angle), method);
            },
            .rgba => |*dst| {
                var src_rgba: Image(Rgba) = undefined;
                if (source.py_image == null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "Source image not initialized");
                    return null;
                }
                const src_pimg = source.py_image.?;
                switch (src_pimg.data) {
                    .rgba => |img| src_rgba = img,
                    .gray => |img| src_rgba = img.convert(Rgba, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                    .rgb => |img| src_rgba = img.convert(Rgba, allocator) catch {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to convert source image");
                        return null;
                    },
                }
                dst.insert(src_rgba, rect, @floatCast(angle), method);
            },
        }
        const none = c.Py_None();
        c.Py_INCREF(none);
        return none;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

const image_canvas_doc =
    \\Create a Canvas object for drawing operations on this image.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\canvas = img.canvas()
    \\canvas.fill((255, 0, 0))  # Fill with red
    \\canvas.draw_line((0, 0), (100, 100), (0, 255, 0))  # Draw green line
    \\```
;

fn image_canvas(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments expected
    // Create Canvas by calling its constructor with this Image object
    const args_tuple = c.Py_BuildValue("(O)", self_obj.?) orelse return null;
    defer c.Py_DECREF(args_tuple);
    const canvas_py = c.PyObject_CallObject(@ptrCast(&canvas.CanvasType), args_tuple) orelse return null;
    return canvas_py;
}

fn image_getitem(self_obj: ?*c.PyObject, key: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));
    const pimg_opt = self.py_image;

    // Parse the key - expecting a tuple of (row, col)
    if (c.PyTuple_Check(key) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Image indices must be a tuple of (row, col)");
        return null;
    }

    if (c.PyTuple_Size(key) != 2) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image indices must be a tuple of exactly 2 integers");
        return null;
    }

    // Extract row and col
    const row_obj = c.PyTuple_GetItem(key, 0);
    const col_obj = c.PyTuple_GetItem(key, 1);

    const row = c.PyLong_AsLong(row_obj);
    if (row == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Row index must be an integer");
        return null;
    }

    const col = c.PyLong_AsLong(col_obj);
    if (col == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Column index must be an integer");
        return null;
    }

    // Bounds checking
    if (pimg_opt) |pimg| {
        if (row < 0 or row >= pimg.rows()) {
            c.PyErr_SetString(c.PyExc_IndexError, "Row index out of bounds");
            return null;
        }
        if (col < 0 or col >= pimg.cols()) {
            c.PyErr_SetString(c.PyExc_IndexError, "Column index out of bounds");
            return null;
        }
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    // Variant-specific pixel return
    if (pimg_opt) |pimg| {
        switch (pimg.data) {
            .gray => |img| {
                const gray = img.at(@intCast(row), @intCast(col)).*;
                return c.PyLong_FromLong(@intCast(gray));
            },
            .rgb => |img| {
                const p = img.at(@intCast(row), @intCast(col)).*;
                const color_module = @import("color.zig");
                const rgb_obj = c.PyType_GenericAlloc(@ptrCast(&color_module.RgbType), 0);
                if (rgb_obj == null) return null;
                const rgb = @as(*color_module.RgbBinding.PyObjectType, @ptrCast(rgb_obj));
                rgb.field0 = p.r;
                rgb.field1 = p.g;
                rgb.field2 = p.b;
                return rgb_obj;
            },
            .rgba => |img| {
                const p = img.at(@intCast(row), @intCast(col)).*;
                const color_module = @import("color.zig");
                const rgba_obj = c.PyType_GenericAlloc(@ptrCast(&color_module.RgbaType), 0);
                if (rgba_obj == null) return null;
                const rgba = @as(*color_module.RgbaBinding.PyObjectType, @ptrCast(rgba_obj));
                rgba.field0 = p.r;
                rgba.field1 = p.g;
                rgba.field2 = p.b;
                rgba.field3 = p.a;
                return rgba_obj;
            },
        }
    }

    // Unreachable; bounds check above should have returned
    return null;
}

fn image_setitem(self_obj: ?*c.PyObject, key: ?*c.PyObject, value: ?*c.PyObject) callconv(.c) c_int {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // If PyImage present, use it; else use RGBA pointer
    const pimg_opt = self.py_image;

    // Check if key is a slice object (for view[:] = image syntax)
    // Use direct type comparison instead of PySlice_Check to avoid Zig translation issues
    // TODO: replace with `if (c.PySlice_Check(key) != 0) {` after Python 3.10 support is dropped
    if (c.Py_TYPE(key) == &c.PySlice_Type) {
        // Handle slice assignment
        var start: c.Py_ssize_t = undefined;
        var stop: c.Py_ssize_t = undefined;
        var step: c.Py_ssize_t = undefined;

        // For full slice [:], start=0, stop=PY_SSIZE_T_MAX, step=1
        if (c.PySlice_Unpack(key, &start, &stop, &step) < 0) {
            return -1; // Error already set
        }

        // Check if this is a full slice [:] (start=0, stop=MAX, step=1)
        const is_full_slice = (start == 0 or start == c.PY_SSIZE_T_MIN) and
            (stop == c.PY_SSIZE_T_MAX) and
            (step == 1);

        if (!is_full_slice) {
            c.PyErr_SetString(c.PyExc_NotImplementedError, "Only full slice [:] assignment is currently supported");
            return -1;
        }

        // Check if value is an Image object
        if (c.PyObject_IsInstance(value, @ptrCast(&ImageType)) != 1) {
            c.PyErr_SetString(c.PyExc_TypeError, "Can only assign another Image to a slice");
            return -1;
        }

        const src_image = @as(*ImageObject, @ptrCast(value));

        // Ensure both images are initialized
        if (pimg_opt == null) {
            c.PyErr_SetString(c.PyExc_ValueError, "Destination image not initialized");
            return -1;
        }

        if (src_image.py_image == null) {
            c.PyErr_SetString(c.PyExc_ValueError, "Source image not initialized");
            return -1;
        }

        const dst_pimg = pimg_opt.?;
        const src_pimg = src_image.py_image.?;

        // Check dimensions match
        if (dst_pimg.rows() != src_pimg.rows() or dst_pimg.cols() != src_pimg.cols()) {
            _ = c.PyErr_Format(c.PyExc_ValueError, "Image dimensions must match for slice assignment. Got (%zu, %zu) vs (%zu, %zu)", dst_pimg.rows(), dst_pimg.cols(), src_pimg.rows(), src_pimg.cols());
            return -1;
        }

        // Copy pixels from source to destination
        dst_pimg.copyFrom(src_pimg.*);

        return 0;
    }

    // Parse the key - expecting a tuple of (row, col)
    if (c.PyTuple_Check(key) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Image indices must be a tuple of (row, col) or a slice");
        return -1;
    }

    if (c.PyTuple_Size(key) != 2) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image indices must be a tuple of exactly 2 integers");
        return -1;
    }

    // Extract row and col
    const row_obj = c.PyTuple_GetItem(key, 0);
    const col_obj = c.PyTuple_GetItem(key, 1);

    const row = c.PyLong_AsLong(row_obj);
    if (row == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Row index must be an integer");
        return -1;
    }

    const col = c.PyLong_AsLong(col_obj);
    if (col == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Column index must be an integer");
        return -1;
    }

    // Bounds checking
    if (pimg_opt) |pimg| {
        if (row < 0 or row >= pimg.rows()) {
            c.PyErr_SetString(c.PyExc_IndexError, "Row index out of bounds");
            return -1;
        }
        if (col < 0 or col >= pimg.cols()) {
            c.PyErr_SetString(c.PyExc_IndexError, "Column index out of bounds");
            return -1;
        }
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return -1;
    }

    // Parse the color value using parseColorTo
    const color = color_utils.parseColorTo(Rgba, value) catch {
        // Error already set by parseColorTo
        return -1;
    };

    // Set the pixel value
    if (pimg_opt) |pimg| {
        pimg.setPixelRgba(@intCast(row), @intCast(col), color);
    } else {
        return -1;
    }

    return 0;
}

fn image_len(self_obj: ?*c.PyObject) callconv(.c) c.Py_ssize_t {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    if (self.py_image) |pimg| {
        return @intCast(pimg.rows() * pimg.cols());
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return -1;
}

pub const image_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "load",
        .meth = @ptrCast(&image_load),
        .flags = c.METH_VARARGS | c.METH_CLASS,
        .doc = image_load_doc,
        .params = "cls, path: str",
        .returns = "Image",
    },
    .{
        .name = "convert",
        .meth = @ptrCast(&image_convert),
        .flags = c.METH_VARARGS,
        .doc = image_convert_doc,
        .params = "self, dtype: Grayscale | Rgb | Rgba",
        .returns = "Image",
    },
    .{
        .name = "from_numpy",
        .meth = @ptrCast(&image_from_numpy),
        .flags = c.METH_VARARGS | c.METH_CLASS,
        .doc = image_from_numpy_doc,
        .params = "cls, array: NDArray[np.uint8]",
        .returns = "Image",
    },
    .{
        .name = "to_numpy",
        .meth = @ptrCast(&image_to_numpy),
        .flags = c.METH_NOARGS,
        .doc = image_to_numpy_doc,
        .params = "self",
        .returns = "NDArray[np.uint8]",
    },
    .{
        .name = "save",
        .meth = @ptrCast(&image_save),
        .flags = c.METH_VARARGS,
        .doc = image_save_doc,
        .params = "self, path: str",
        .returns = "None",
    },
    .{
        .name = "fill",
        .meth = @ptrCast(&image_fill),
        .flags = c.METH_VARARGS,
        .doc = image_fill_doc,
        .params = "self, color: " ++ stub_metadata.COLOR,
        .returns = "None",
    },
    .{
        .name = "resize",
        .meth = @ptrCast(&image_resize),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_resize_doc,
        .params = "self, size: float | tuple[int, int], method: InterpolationMethod = InterpolationMethod.BILINEAR",
        .returns = "Image",
    },
    .{
        .name = "letterbox",
        .meth = @ptrCast(&image_letterbox),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_letterbox_doc,
        .params = "self, size: int | tuple[int, int], method: InterpolationMethod = InterpolationMethod.BILINEAR",
        .returns = "Image",
    },
    .{
        .name = "rotate",
        .meth = @ptrCast(&image_rotate),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_rotate_doc,
        .params = "self, angle: float, method: InterpolationMethod = InterpolationMethod.BILINEAR",
        .returns = "Image",
    },
    .{
        .name = "copy",
        .meth = @ptrCast(&image_copy),
        .flags = c.METH_NOARGS,
        .doc = image_copy_doc,
        .params = "self",
        .returns = "Image",
    },
    .{
        .name = "view",
        .meth = @ptrCast(&image_view),
        .flags = c.METH_VARARGS,
        .doc = image_view_doc,
        .params = "self, rect: Rectangle",
        .returns = "Image",
    },
    .{
        .name = "is_view",
        .meth = @ptrCast(&image_is_view),
        .flags = c.METH_NOARGS,
        .doc = "Check if this image is a view of another image.\n\nReturns True if this image references another image's memory,\nFalse if it owns its own memory.",
        .params = "self",
        .returns = "bool",
    },
    .{
        .name = "flip_left_right",
        .meth = @ptrCast(&image_flip_left_right),
        .flags = c.METH_NOARGS,
        .doc = image_flip_left_right_doc,
        .params = "self",
        .returns = "Image",
    },
    .{
        .name = "flip_top_bottom",
        .meth = @ptrCast(&image_flip_top_bottom),
        .flags = c.METH_NOARGS,
        .doc = image_flip_top_bottom_doc,
        .params = "self",
        .returns = "Image",
    },
    .{
        .name = "box_blur",
        .meth = @ptrCast(&image_box_blur),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_box_blur_doc,
        .params = "self, radius: int",
        .returns = "Image",
    },
    .{
        .name = "sharpen",
        .meth = @ptrCast(&image_sharpen),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_sharpen_doc,
        .params = "self, radius: int",
        .returns = "Image",
    },
    .{
        .name = "gaussian_blur",
        .meth = @ptrCast(&image_gaussian_blur),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_gaussian_blur_doc,
        .params = "self, sigma: float",
        .returns = "Image",
    },
    .{
        .name = "psnr",
        .meth = @ptrCast(&image_psnr),
        .flags = c.METH_VARARGS,
        .doc = image_psnr_doc,
        .params = "self, other: Image",
        .returns = "float",
    },
    .{
        .name = "__format__",
        .meth = @ptrCast(&image_format),
        .flags = c.METH_VARARGS,
        .doc = image_format_doc,
        .params = "self, format_spec: str",
        .returns = "str",
    },
    .{
        .name = "canvas",
        .meth = @ptrCast(&image_canvas),
        .flags = c.METH_NOARGS,
        .doc = image_canvas_doc,
        .params = "self",
        .returns = "Canvas",
    },
    .{
        .name = "crop",
        .meth = @ptrCast(&image_crop),
        .flags = c.METH_VARARGS,
        .doc = image_crop_doc,
        .params = "self, rect: Rectangle",
        .returns = "Image",
    },
    .{
        .name = "extract",
        .meth = @ptrCast(&image_extract),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_extract_doc,
        .params = "self, rect: Rectangle, angle: float = 0.0, size: int | tuple[int, int] | None = None, method: InterpolationMethod = InterpolationMethod.BILINEAR",
        .returns = "Image",
    },
    .{
        .name = "insert",
        .meth = @ptrCast(&image_insert),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_insert_doc,
        .params = "self, source: Image, rect: Rectangle, angle: float = 0.0, method: InterpolationMethod = InterpolationMethod.BILINEAR",
        .returns = "None",
    },
};

var image_methods = stub_metadata.toPyMethodDefArray(&image_methods_metadata);

pub const image_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "rows",
        .get = @ptrCast(&image_get_rows),
        .set = null,
        .doc = "Number of rows (height) in the image",
        .type = "int",
    },
    .{
        .name = "cols",
        .get = @ptrCast(&image_get_cols),
        .set = null,
        .doc = "Number of columns (width) in the image",
        .type = "int",
    },
    .{
        .name = "dtype",
        .get = @ptrCast(&image_get_dtype),
        .set = null,
        .doc = "Pixel data type (Grayscale, Rgb, or Rgba)",
        .type = "Grayscale | Rgb | Rgba",
    },
};

var image_getset = stub_metadata.toPyGetSetDefArray(&image_properties_metadata);

// Special methods metadata for stub generation
pub const image_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, rows: int, cols: int, color: " ++ stub_metadata.COLOR ++ " | None = None, dtype = Grayscale | Rgb | Rgba",
        .returns = "None",
        .doc = image_init_doc,
    },
    .{
        .name = "__len__",
        .params = "self",
        .returns = "int",
    },
    .{
        .name = "__iter__",
        .params = "self",
        .returns = "PixelIterator",
        .doc = "Iterate over pixels in row-major order, yielding (row, col, pixel) in native dtype (int|Rgb|Rgba).",
    },
    .{
        .name = "__getitem__",
        .params = "self, key: tuple[int, int]",
        .returns = "int | Rgb | Rgba",
    },
    .{
        .name = "__setitem__",
        .params = "self, key: tuple[int, int] | slice, value: " ++ stub_metadata.COLOR ++ " | Image",
        .returns = "None",
    },
    .{
        .name = "__format__",
        .params = "self, format_spec: str",
        .returns = "str",
        .doc = "Format image for display. Supports 'ansi', 'blocks', 'braille', 'sixel', 'sixel:WIDTHxHEIGHT', 'kitty', and 'auto'.",
    },
    .{
        .name = "__eq__",
        .params = "self, other: object",
        .returns = "bool",
        .doc = "Check equality with another Image by comparing dimensions and pixel data.",
    },
    .{
        .name = "__ne__",
        .params = "self, other: object",
        .returns = "bool",
        .doc = "Check inequality with another Image.",
    },
};

var image_as_mapping = c.PyMappingMethods{
    .mp_length = image_len,
    .mp_subscript = image_getitem,
    .mp_ass_subscript = image_setitem,
};

pub var ImageType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.Image",
    .tp_basicsize = @sizeOf(ImageObject),
    .tp_dealloc = image_dealloc,
    .tp_repr = image_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = image_class_doc,
    .tp_methods = @ptrCast(&image_methods),
    .tp_getset = @ptrCast(&image_getset),
    .tp_as_mapping = @ptrCast(&image_as_mapping),
    .tp_iter = image_iter,
    .tp_init = image_init,
    .tp_new = image_new,
    .tp_richcompare = @ptrCast(&image_richcompare),
};

//! Python bindings for Zignal Image type
//! This module aggregates functionality from sub-modules

const std = @import("std");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;
const DisplayFormat = zignal.DisplayFormat;

const color_bindings = @import("color.zig");
const color_utils = @import("color_utils.zig");
const grayscale_format = @import("grayscale_format.zig");
const core = @import("image/core.zig");
const filtering = @import("image/filtering.zig");
const numpy_interop = @import("image/numpy_interop.zig");
const transforms = @import("image/transforms.zig");
const makeRgbaProxy = @import("pixel_proxy.zig").makeRgbaProxy;
const makeRgbProxy = @import("pixel_proxy.zig").makeRgbProxy;
const pixel_iterator = @import("pixel_iterator.zig");
const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const PyImageMod = @import("PyImage.zig");
const PyImage = PyImageMod.PyImage;
const stub_metadata = @import("stub_metadata.zig");

// Import sub-modules
pub const ImageVariant = union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),
};

const image_class_doc =
    \\Image for processing and manipulation.
    \\
    \\Pixel access via indexing returns a proxy object that allows in-place
    \\modification. Use `.item()` on the proxy to extract the color value:
    \\```python
    \\  pixel = img[row, col]  # Returns pixel proxy
    \\  color = pixel.item()   # Extracts color object (Rgb/Rgba/int)
    \\```
    \\This object is iterable: iterating yields (row, col, pixel) in native
    \\dtype in row-major order. For bulk numeric work, prefer `to_numpy()`.
;

pub const ImageObject = extern struct {
    ob_base: c.PyObject,
    /// Store dynamic image for non-RGBA formats (or future migration)
    py_image: ?*PyImage,
    /// Store reference to NumPy array if created from numpy (for zero-copy)
    numpy_ref: ?*c.PyObject,
    /// Store reference to parent Image if this is a view (for memory management)
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
    \\- `dtype` (type, optional): Pixel data type specifying storage type.
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
    \\img = Image(100, 200, (255, 0, 0, 255))
    \\
    \\# Create a 100x200 grayscale image with mid-gray fill
    \\img = Image(100, 200, 128, dtype=zignal.Grayscale)
    \\
    \\# Create a 100x200 RGB image (dtype overrides the color value)
    \\img = Image(100, 200, (0, 255, 0, 255), dtype=zignal.Rgb)
    \\
    \\# Create an image from numpy array dimensions
    \\img = Image(*arr.shape[:2])
    \\
    \\# Create with semi-transparent blue (requires RGBA)
    \\img = Image(100, 100, (0, 0, 255, 128), dtype=zignal.Rgba)
    \\```
;

fn image_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = py_utils.safeCast(ImageObject, self_obj);

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

    // Parse arguments: rows, cols, optional color, optional dtype
    const Params = struct {
        rows: c_int,
        cols: c_int,
        color: ?*c.PyObject = null, // Optional with default
        dtype: ?*c.PyObject = null, // Optional with default (was keyword-only, now regular optional)
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch {
        py_utils.setTypeError("(rows, cols, color=None, dtype=None) arguments", null);
        return -1;
    };

    // Validate dimensions - validateRange now properly handles negative values when converting to usize
    const validated_rows = py_utils.validateRange(usize, params.rows, 1, std.math.maxInt(usize), "Rows") catch return -1;
    const validated_cols = py_utils.validateRange(usize, params.cols, 1, std.math.maxInt(usize), "Cols") catch return -1;

    // Detect color input type
    var color_type = ColorInputType.none;
    if (params.color != null and params.color != c.Py_None()) {
        if (c.PyLong_Check(params.color) != 0) {
            color_type = .grayscale;
        } else if (c.PyTuple_Check(params.color) != 0) {
            const tuple_size = c.PyTuple_Size(params.color);
            if (tuple_size == 3) {
                color_type = .rgb_tuple;
            } else if (tuple_size == 4) {
                color_type = .rgba_tuple;
            } else {
                py_utils.setValueError("Color tuple must have 3 or 4 elements", .{});
                return -1;
            }
        } else if (c.PyObject_IsInstance(params.color, @ptrCast(&color_bindings.RgbaType)) == 1) {
            color_type = .rgba_object;
        } else if (c.PyObject_IsInstance(params.color, @ptrCast(&color_bindings.RgbType)) == 1) {
            color_type = .rgb_object;
        } else {
            color_type = .other;
        }
    }

    // Determine target dtype based on color type and explicit dtype parameter
    const ImageFormat = enum { grayscale, rgb, rgba };
    var target_format: ImageFormat = undefined;

    if (params.dtype) |fmt_obj| {
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
                py_utils.setTypeError("zignal.Grayscale, zignal.Rgb, or zignal.Rgba", fmt_obj);
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
                py_utils.setTypeError("zignal.Grayscale, zignal.Rgb, or zignal.Rgba", fmt_obj);
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
                py_utils.setMemoryError("image data");
                return -1;
            };

            // Parse color to grayscale if provided
            if (params.color != null and params.color != c.Py_None()) {
                const gray = color_utils.parseColor(u8, params.color) catch {
                    gimg.deinit(allocator);
                    // Error already set by parseColorTo
                    return -1;
                };
                @memset(gimg.data, gray);
            } else {
                @memset(gimg.data, 0); // Default to black
            }

            const pimg = PyImage.createFrom(allocator, gimg, .owned) orelse {
                gimg.deinit(allocator);
                py_utils.setMemoryError("image");
                return -1;
            };
            self.py_image = pimg;
            self.numpy_ref = null;
            self.parent_ref = null;
            return 0;
        },
        .rgb => {
            var rimg = Image(Rgb).init(allocator, validated_rows, validated_cols) catch {
                py_utils.setMemoryError("image data");
                return -1;
            };

            // Parse color to RGB if provided
            if (params.color != null and params.color != c.Py_None()) {
                const rgb_color = color_utils.parseColor(Rgb, params.color) catch {
                    rimg.deinit(allocator);
                    // Error already set by parseColorTo
                    return -1;
                };
                @memset(rimg.data, rgb_color);
            } else {
                @memset(rimg.data, Rgb{ .r = 0, .g = 0, .b = 0 }); // Default to black
            }

            const pimg = PyImage.createFrom(allocator, rimg, .owned) orelse {
                rimg.deinit(allocator);
                py_utils.setMemoryError("image");
                return -1;
            };
            self.py_image = pimg;
            self.numpy_ref = null;
            self.parent_ref = null;
            return 0;
        },
        .rgba => {
            var image = Image(Rgba).init(allocator, validated_rows, validated_cols) catch {
                py_utils.setMemoryError("image data");
                return -1;
            };

            // Parse color to RGBA if provided
            if (params.color != null and params.color != c.Py_None()) {
                const rgba_color = color_utils.parseColor(Rgba, params.color) catch {
                    image.deinit(allocator);
                    // Error already set by parseColorTo
                    return -1;
                };
                @memset(image.data, rgba_color);
            } else {
                @memset(image.data, Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 }); // Default to transparent
            }

            const pimg = PyImage.createFrom(allocator, image, .owned) orelse {
                image.deinit(allocator);
                py_utils.setMemoryError("image");
                return -1;
            };
            self.py_image = pimg;
            self.numpy_ref = null;
            self.parent_ref = null;
            return 0;
        },
    }
}

fn image_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = py_utils.safeCast(ImageObject, self_obj);

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

fn image_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    if (self.py_image) |pimg| {
        var buffer: [96]u8 = undefined;
        const fmt_name = switch (pimg.data) {
            .grayscale => "Grayscale",
            .rgb => "Rgb",
            .rgba => "Rgba",
        };
        const formatted = std.fmt.bufPrintZ(&buffer, "Image({d}x{d}, dtype={s})", .{ pimg.rows(), pimg.cols(), fmt_name }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("Image(uninitialized)");
    }
}

fn image_len(self_obj: ?*c.PyObject) callconv(.c) c.Py_ssize_t {
    const self = py_utils.safeCast(ImageObject, self_obj);

    // Check if image is initialized
    if (self.py_image) |pimg| {
        return @intCast(pimg.rows() * pimg.cols());
    }
    py_utils.setValueError("Image not initialized", .{});
    return -1;
}

fn image_getitem(self_obj: ?*c.PyObject, key: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);
    const pimg_opt = self.py_image;

    const coords = py_utils.expectTupleLen(2, key, "tuple of (row, col)") catch return null;

    const row_obj = coords[0];
    const col_obj = coords[1];

    const row = c.PyLong_AsLong(row_obj);
    if (row == -1 and c.PyErr_Occurred() != null) {
        py_utils.setTypeError("integer", row_obj);
        return null;
    }

    const col = c.PyLong_AsLong(col_obj);
    if (col == -1 and c.PyErr_Occurred() != null) {
        py_utils.setTypeError("integer", col_obj);
        return null;
    }

    // Bounds checking
    if (pimg_opt) |pimg| {
        if (row < 0 or row >= pimg.rows()) {
            py_utils.setIndexError("Row index out of bounds", .{});
            return null;
        }
        if (col < 0 or col >= pimg.cols()) {
            py_utils.setIndexError("Column index out of bounds", .{});
            return null;
        }
    } else {
        py_utils.setValueError("Image not initialized", .{});
        return null;
    }

    // Variant-specific pixel return
    if (pimg_opt) |pimg| {
        return switch (pimg.data) {
            .grayscale => |img| return c.PyLong_FromLong(@intCast(img.at(@intCast(row), @intCast(col)).*)),
            .rgb => return makeRgbProxy(@ptrCast(self_obj), @intCast(row), @intCast(col)),
            .rgba => return makeRgbaProxy(@ptrCast(self_obj), @intCast(row), @intCast(col)),
        };
    }

    // Unreachable; bounds check above should have returned
    return null;
}

fn image_setitem(self_obj: ?*c.PyObject, key: ?*c.PyObject, value: ?*c.PyObject) callconv(.c) c_int {
    const self = py_utils.safeCast(ImageObject, self_obj);

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
            py_utils.setTypeError("Image object", value);
            return -1;
        }

        const src_image = py_utils.safeCast(ImageObject, value);

        // Ensure both images are initialized
        if (pimg_opt == null) {
            py_utils.setValueError("Destination image not initialized", .{});
            return -1;
        }

        if (src_image.py_image == null) {
            py_utils.setValueError("Source image not initialized", .{});
            return -1;
        }

        const dst_pimg = pimg_opt.?;
        const src_pimg = src_image.py_image.?;

        // Check dimensions match
        if (dst_pimg.rows() != src_pimg.rows() or dst_pimg.cols() != src_pimg.cols()) {
            py_utils.setValueError(
                "Image dimensions must match for slice assignment. Got ({d}, {d}) vs ({d}, {d})",
                .{ dst_pimg.rows(), dst_pimg.cols(), src_pimg.rows(), src_pimg.cols() },
            );
            return -1;
        }

        // Copy pixels from source to destination
        dst_pimg.copyFrom(src_pimg.*);

        return 0;
    }

    const coords = py_utils.expectTupleLen(2, key, "tuple of (row, col)") catch return -1;

    const row_obj = coords[0];
    const col_obj = coords[1];

    const row = c.PyLong_AsLong(row_obj);
    if (row == -1 and c.PyErr_Occurred() != null) {
        py_utils.setTypeError("integer", row_obj);
        return -1;
    }

    const col = c.PyLong_AsLong(col_obj);
    if (col == -1 and c.PyErr_Occurred() != null) {
        py_utils.setTypeError("integer", col_obj);
        return -1;
    }

    // Bounds checking
    if (pimg_opt) |pimg| {
        if (row < 0 or row >= pimg.rows()) {
            py_utils.setIndexError("Row index out of bounds", .{});
            return -1;
        }
        if (col < 0 or col >= pimg.cols()) {
            py_utils.setIndexError("Column index out of bounds", .{});
            return -1;
        }
    } else {
        py_utils.setValueError("Image not initialized", .{});
        return -1;
    }

    // Parse the color value using parseColorTo
    const color = color_utils.parseColor(Rgba, value) catch {
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

fn image_iter(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);
    // Require PyImage variant for iteration
    if (self.py_image == null) {
        py_utils.setValueError("Image not initialized", .{});
        return null;
    }
    return pixel_iterator.new(self_obj);
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

/// Parse dimension string like "800x600", "800x", or "x600"
/// Returns struct with optional width and height
fn parseDimensions(dims_str: []const u8) !struct { width: ?u32, height: ?u32 } {
    if (dims_str.len == 0) {
        return error.InvalidFormat;
    }

    // Find the 'x' separator
    const x_pos = std.mem.indexOf(u8, dims_str, "x") orelse return error.InvalidFormat;

    // Parse width (before 'x')
    const width: ?u32 = if (x_pos == 0) null else blk: {
        const width_str = dims_str[0..x_pos];
        break :blk std.fmt.parseInt(u32, width_str, 10) catch return error.InvalidWidth;
    };

    // Parse height (after 'x')
    const height: ?u32 = if (x_pos + 1 >= dims_str.len) null else blk: {
        const height_str = dims_str[x_pos + 1 ..];
        break :blk std.fmt.parseInt(u32, height_str, 10) catch return error.InvalidHeight;
    };

    // At least one dimension must be specified
    if (width == null and height == null) {
        return error.InvalidFormat;
    }

    return .{ .width = width, .height = height };
}

const image_format_doc =
    \\Format image for display using various terminal graphics protocols.
    \\
    \\## Parameters
    \\- `format_spec` (str): Format specifier with optional size constraints
    \\
    \\  **Pattern:** `format` or `format:WIDTHxHEIGHT` or `format:WIDTHx` or `format:xHEIGHT`
    \\
    \\  **Formats:**
    \\  - `''` (empty): Text representation (e.g., 'Image(800x600)')
    \\  - `'auto'`: Auto-detect best format (kitty → sixel → sgr)
    \\  - `'sgr'`: Unicode half-blocks with 24-bit color
    \\  - `'braille'`: Braille patterns (monochrome, 2x4 resolution per character)
    \\  - `'sixel'`: Sixel graphics protocol (up to 256 colors)
    \\  - `'kitty'`: Kitty graphics protocol (full 24-bit color)
    \\
    \\  **Size constraints (optional):**
    \\  All size parameters maintain the original aspect ratio:
    \\  - `:WIDTHxHEIGHT` - Scale to fit within WIDTH×HEIGHT box
    \\  - `:WIDTHx` - Constrain width to WIDTH pixels
    \\  - `:xHEIGHT` - Constrain height to HEIGHT pixels
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")  # e.g., 1920x1080
    \\
    \\# Basic display formats
    \\print(f"{img}")           # Text: Image(1920x1080)
    \\print(f"{img:sgr}")       # Display with unicode half-blocks
    \\print(f"{img:braille}")   # Display with braille patterns
    \\print(f"{img:sixel}")     # Display with sixel graphics
    \\print(f"{img:kitty}")     # Display with kitty graphics
    \\print(f"{img:auto}")      # Auto-detect best format
    \\
    \\# With size constraints (aspect ratio always preserved)
    \\print(f"{img:sgr:400x300}")     # Fit within 400x300 (actual: 400x225)
    \\print(f"{img:braille:200x}")    # Width=200, height auto-calculated
    \\print(f"{img:sixel:x150}")      # Height=150, width auto-calculated
    \\print(f"{img:auto:500x500}")    # Fit within 500x500 box
    \\```
;

fn image_format(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    // Parse format_spec argument
    const Params = struct {
        format_spec: [*c]const u8,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Convert C string to Zig slice
    const spec_slice = std.mem.span(params.format_spec);

    // If empty format spec, return default repr
    if (spec_slice.len == 0) {
        return image_repr(self_obj);
    }

    // Determine display format based on spec
    const display_format: DisplayFormat = if (std.mem.eql(u8, spec_slice, "sgr"))
        .{ .sgr = .default }
    else if (std.mem.startsWith(u8, spec_slice, "sgr:")) blk: {
        // Parse sgr with dimensions: "sgr:WIDTHxHEIGHT"
        const dims_str = spec_slice[4..]; // Skip "sgr:"

        const dims = parseDimensions(dims_str) catch |err| {
            const msg = switch (err) {
                error.InvalidFormat => "Invalid sgr format. Use 'sgr:WIDTHxHEIGHT', 'sgr:WIDTHx', or 'sgr:xHEIGHT'",
                error.InvalidWidth => "Invalid width value in sgr format",
                error.InvalidHeight => "Invalid height value in sgr format",
            };
            c.PyErr_SetString(c.PyExc_ValueError, msg);
            return null;
        };

        // Create sgr options with custom dimensions
        break :blk .{ .sgr = .{
            .width = dims.width,
            .height = dims.height,
        } };
    } else if (std.mem.eql(u8, spec_slice, "braille"))
        .{ .braille = .default }
    else if (std.mem.startsWith(u8, spec_slice, "braille:")) blk: {
        // Parse braille with dimensions: "braille:WIDTHxHEIGHT"
        const dims_str = spec_slice[8..]; // Skip "braille:"

        const dims = parseDimensions(dims_str) catch |err| {
            const msg = switch (err) {
                error.InvalidFormat => "Invalid braille format. Use 'braille:WIDTHxHEIGHT', 'braille:WIDTHx', or 'braille:xHEIGHT'",
                error.InvalidWidth => "Invalid width value in braille format",
                error.InvalidHeight => "Invalid height value in braille format",
            };
            c.PyErr_SetString(c.PyExc_ValueError, msg);
            return null;
        };

        // Create braille options with custom dimensions
        break :blk .{ .braille = .{
            .threshold = 0.5,
            .width = dims.width,
            .height = dims.height,
        } };
    } else if (std.mem.eql(u8, spec_slice, "sixel"))
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
        .{ .auto = .default }
    else if (std.mem.startsWith(u8, spec_slice, "auto:")) blk: {
        // Parse auto with dimensions: "auto:WIDTHxHEIGHT"
        const dims_str = spec_slice[5..]; // Skip "auto:"

        const dims = parseDimensions(dims_str) catch |err| {
            const msg = switch (err) {
                error.InvalidFormat => "Invalid auto format. Use 'auto:WIDTHxHEIGHT', 'auto:WIDTHx', or 'auto:xHEIGHT'",
                error.InvalidWidth => "Invalid width value in auto format",
                error.InvalidHeight => "Invalid height value in auto format",
            };
            c.PyErr_SetString(c.PyExc_ValueError, msg);
            return null;
        };

        // Create auto options with custom dimensions
        break :blk .{ .auto = .{
            .width = dims.width,
            .height = dims.height,
        } };
    } else if (std.mem.startsWith(u8, spec_slice, "sgr")) {
        // Invalid sgr format that doesn't match "sgr" or "sgr:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sgr format. Use 'sgr' or 'sgr:WIDTHxHEIGHT' (e.g., 'sgr:800x600', 'sgr:800x', 'sgr:x600')");
        return null;
    } else if (std.mem.startsWith(u8, spec_slice, "braille")) {
        // Invalid braille format that doesn't match "braille" or "braille:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid braille format. Use 'braille' or 'braille:WIDTHxHEIGHT' (e.g., 'braille:800x600', 'braille:800x', 'braille:x600')");
        return null;
    } else if (std.mem.startsWith(u8, spec_slice, "sixel")) {
        // Invalid sixel format that doesn't match "sixel" or "sixel:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sixel format. Use 'sixel' or 'sixel:WIDTHxHEIGHT' (e.g., 'sixel:800x600', 'sixel:800x', 'sixel:x600')");
        return null;
    } else if (std.mem.startsWith(u8, spec_slice, "kitty")) {
        // Invalid kitty format that doesn't match "kitty" or "kitty:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid kitty format. Use 'kitty' or 'kitty:WIDTHxHEIGHT' (e.g., 'kitty:800x600', 'kitty:800x', 'kitty:x600')");
        return null;
    } else if (std.mem.startsWith(u8, spec_slice, "auto")) {
        // Invalid auto format that doesn't match "auto" or "auto:..."
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid auto format. Use 'auto' or 'auto:WIDTHxHEIGHT' (e.g., 'auto:800x600', 'auto:800x', 'auto:x600')");
        return null;
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid format spec. Use '', 'sgr', 'sgr:WIDTHxHEIGHT', 'braille', 'braille:WIDTHxHEIGHT', 'sixel', 'sixel:WIDTHxHEIGHT', 'kitty', 'kitty:WIDTHxHEIGHT', 'auto', or 'auto:WIDTHxHEIGHT'");
        return null;
    };

    // Format image according to display_format and return a string
    if (self.py_image) |pimg| {
        var buffer = std.ArrayList(u8).initCapacity(allocator, 4096) catch {
            c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
            return null;
        };
        defer buffer.deinit(allocator);

        switch (pimg.data) {
            .grayscale => |*img| {
                const formatted = std.fmt.allocPrint(allocator, "{f}", .{img.display(display_format)}) catch |err| {
                    if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                defer allocator.free(formatted);
                buffer.appendSlice(allocator, formatted) catch |err| {
                    if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
            },
            .rgb => |*img| {
                const formatted = std.fmt.allocPrint(allocator, "{f}", .{img.display(display_format)}) catch |err| {
                    if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                defer allocator.free(formatted);
                buffer.appendSlice(allocator, formatted) catch |err| {
                    if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
            },
            .rgba => |*img| {
                const formatted = std.fmt.allocPrint(allocator, "{f}", .{img.display(display_format)}) catch |err| {
                    if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                defer allocator.free(formatted);
                buffer.appendSlice(allocator, formatted) catch |err| {
                    if (err == error.OutOfMemory) c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
            },
        }
        return c.PyUnicode_FromStringAndSize(buffer.items.ptr, @intCast(buffer.items.len));
    } else {
        py_utils.setValueError("Image not initialized", .{});
        return null;
    }
}

// Aggregate method metadata from all sub-modules
pub const image_methods_metadata = blk: {
    // ========================================================================
    // Core/Creation methods
    // ========================================================================
    const core_methods = [_]stub_metadata.MethodWithMetadata{
        .{
            .name = "load",
            .meth = @ptrCast(&core.image_load),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
            .doc = core.image_load_doc,
            .params = "cls, path: str",
            .returns = "Image",
        },
        .{
            .name = "save",
            .meth = @ptrCast(&core.image_save),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = core.image_save_doc,
            .params = "self, path: str",
            .returns = "None",
        },
        .{
            .name = "copy",
            .meth = @ptrCast(&core.image_copy),
            .flags = c.METH_NOARGS,
            .doc = core.image_copy_doc,
            .params = "self",
            .returns = "Image",
        },
        .{
            .name = "fill",
            .meth = @ptrCast(&core.image_fill),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = core.image_fill_doc,
            .params = "self, color: Color",
            .returns = "None",
        },
        .{
            .name = "view",
            .meth = @ptrCast(&core.image_view),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = core.image_view_doc,
            .params = "self, rect: Rectangle | tuple[float, float, float, float] | None = None",
            .returns = "Image",
        },
        .{
            .name = "set_border",
            .meth = @ptrCast(&core.image_set_border),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = core.image_set_border_doc,
            .params = "self, rect: Rectangle | tuple[float, float, float, float], color: Color | None = None",
            .returns = "None",
        },
        .{
            .name = "is_contiguous",
            .meth = @ptrCast(&core.image_is_contiguous),
            .flags = c.METH_NOARGS,
            .doc = core.image_is_contiguous_doc,
            .params = "self",
            .returns = "bool",
        },
        .{
            .name = "get_rectangle",
            .meth = @ptrCast(&core.image_get_rectangle),
            .flags = c.METH_NOARGS,
            .doc = core.image_get_rectangle_doc,
            .params = "self",
            .returns = "Rectangle",
        },
        .{
            .name = "convert",
            .meth = @ptrCast(&core.image_convert),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = core.image_convert_doc,
            .params = "self, dtype: Grayscale | Rgb | Rgba",
            .returns = "Image",
        },
        .{
            .name = "canvas",
            .meth = @ptrCast(&core.image_canvas),
            .flags = c.METH_NOARGS,
            .doc = core.image_canvas_doc,
            .params = "self",
            .returns = "Canvas",
        },
        .{
            .name = "psnr",
            .meth = @ptrCast(&core.image_psnr),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = core.image_psnr_doc,
            .params = "self, other: Image",
            .returns = "float",
        },
    };

    // ========================================================================
    // NumPy interop
    // ========================================================================
    const numpy_methods = [_]stub_metadata.MethodWithMetadata{
        .{
            .name = "from_numpy",
            .meth = @ptrCast(&numpy_interop.image_from_numpy),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
            .doc = numpy_interop.image_from_numpy_doc,
            .params = "cls, array: NDArray[np.uint8]",
            .returns = "Image",
        },
        .{
            .name = "to_numpy",
            .meth = @ptrCast(&numpy_interop.image_to_numpy),
            .flags = c.METH_NOARGS,
            .doc = numpy_interop.image_to_numpy_doc,
            .params = "self",
            .returns = "NDArray[np.uint8]",
        },
    };

    // ========================================================================
    // Geometric transforms
    // ========================================================================
    const transform_methods = [_]stub_metadata.MethodWithMetadata{
        .{
            .name = "resize",
            .meth = @ptrCast(&transforms.image_resize),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_resize_doc,
            .params = "self, size: float | tuple[int, int], method: Interpolation = Interpolation.BILINEAR",
            .returns = "Image",
        },
        .{
            .name = "letterbox",
            .meth = @ptrCast(&transforms.image_letterbox),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_letterbox_doc,
            .params = "self, size: int | tuple[int, int], method: Interpolation = Interpolation.BILINEAR",
            .returns = "Image",
        },
        .{
            .name = "rotate",
            .meth = @ptrCast(&transforms.image_rotate),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_rotate_doc,
            .params = "self, angle: float, method: Interpolation = Interpolation.BILINEAR",
            .returns = "Image",
        },
        .{
            .name = "warp",
            .meth = @ptrCast(&transforms.image_warp),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_warp_doc,
            .params = "self, transform: SimilarityTransform | AffineTransform | ProjectiveTransform, shape: tuple[int, int] | None = None, method: Interpolation = Interpolation.BILINEAR",
            .returns = "Image",
        },
        .{
            .name = "flip_left_right",
            .meth = @ptrCast(&transforms.image_flip_left_right),
            .flags = c.METH_NOARGS,
            .doc = transforms.image_flip_left_right_doc,
            .params = "self",
            .returns = "Image",
        },
        .{
            .name = "flip_top_bottom",
            .meth = @ptrCast(&transforms.image_flip_top_bottom),
            .flags = c.METH_NOARGS,
            .doc = transforms.image_flip_top_bottom_doc,
            .params = "self",
            .returns = "Image",
        },
        .{
            .name = "crop",
            .meth = @ptrCast(&transforms.image_crop),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_crop_doc,
            .params = "self, rect: Rectangle",
            .returns = "Image",
        },
        .{
            .name = "extract",
            .meth = @ptrCast(&transforms.image_extract),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_extract_doc,
            .params = "self, rect: Rectangle, angle: float = 0.0, size: int | tuple[int, int] | None = None, method: Interpolation = Interpolation.BILINEAR",
            .returns = "Image",
        },
        .{
            .name = "insert",
            .meth = @ptrCast(&transforms.image_insert),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = transforms.image_insert_doc,
            .params = "self, source: Image, rect: Rectangle, angle: float = 0.0, method: Interpolation = Interpolation.BILINEAR",
            .returns = "None",
        },
    };

    // ========================================================================
    // Filtering/Effects
    // ========================================================================
    const filter_methods = [_]stub_metadata.MethodWithMetadata{
        .{
            .name = "box_blur",
            .meth = @ptrCast(&filtering.image_box_blur),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_box_blur_doc,
            .params = "self, radius: int",
            .returns = "Image",
        },
        .{
            .name = "gaussian_blur",
            .meth = @ptrCast(&filtering.image_gaussian_blur),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_gaussian_blur_doc,
            .params = "self, sigma: float",
            .returns = "Image",
        },
        .{
            .name = "sharpen",
            .meth = @ptrCast(&filtering.image_sharpen),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_sharpen_doc,
            .params = "self, radius: int",
            .returns = "Image",
        },
        .{
            .name = "invert",
            .meth = @ptrCast(&filtering.image_invert),
            .flags = c.METH_NOARGS,
            .doc = filtering.image_invert_doc,
            .params = "self",
            .returns = "Image",
        },
        .{
            .name = "autocontrast",
            .meth = @ptrCast(&filtering.image_autocontrast),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_autocontrast_doc,
            .params = "self, cutoff: float = 0.0",
            .returns = "Image",
        },
        .{
            .name = "equalize",
            .meth = @ptrCast(&filtering.image_equalize),
            .flags = c.METH_NOARGS,
            .doc = filtering.image_equalize_doc,
            .params = "self",
            .returns = "Image",
        },
        .{
            .name = "motion_blur",
            .meth = @ptrCast(&filtering.image_motion_blur),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_motion_blur_doc,
            .params = "self, config: MotionBlur",
            .returns = "Image",
        },
        .{
            .name = "sobel",
            .meth = @ptrCast(&filtering.image_sobel),
            .flags = c.METH_NOARGS,
            .doc = filtering.image_sobel_doc,
            .params = "self",
            .returns = "Image",
        },
        .{
            .name = "shen_castan",
            .meth = @ptrCast(&filtering.image_shen_castan),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_shen_castan_doc,
            .params = "self, smooth: float = 0.9, window_size: int = 7, high_ratio: float = 0.99, low_rel: float = 0.5, hysteresis: bool = True, use_nms: bool = False",
            .returns = "Image",
        },
        .{
            .name = "blend",
            .meth = @ptrCast(&filtering.image_blend),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = filtering.image_blend_doc,
            .params = "self, overlay: Image, mode: Blending = Blending.NORMAL",
            .returns = "None",
        },
    };

    // ========================================================================
    // Special Python methods
    // ========================================================================
    const special_methods = [_]stub_metadata.MethodWithMetadata{
        .{
            .name = "__format__",
            .meth = @ptrCast(&image_format),
            .flags = c.METH_VARARGS | c.METH_KEYWORDS,
            .doc = image_format_doc,
            .params = "self, format_spec: str",
            .returns = "str",
        },
    };

    // Combine all methods
    break :blk core_methods ++ numpy_methods ++ transform_methods ++ filter_methods ++ special_methods;
};

var image_methods = stub_metadata.toPyMethodDefArray(&image_methods_metadata);

pub const image_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "rows",
        .get = @ptrCast(&core.image_get_rows),
        .set = null,
        .doc = "Number of rows (height) in the image",
        .type = "int",
    },
    .{
        .name = "cols",
        .get = @ptrCast(&core.image_get_cols),
        .set = null,
        .doc = "Number of columns (width) in the image",
        .type = "int",
    },
    .{
        .name = "dtype",
        .get = @ptrCast(&core.image_get_dtype),
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
        .params = "self, rows: int, cols: int, color: Color | None = None, dtype = Grayscale | Rgb | Rgba",
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
        .params = "self, key: tuple[int, int] | slice, value: Color | Image",
        .returns = "None",
    },
    .{
        .name = "__format__",
        .params = "self, format_spec: str",
        .returns = "str",
        .doc = image_format_doc,
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

// Function to get ImageType pointer for sub-modules
pub fn getImageType() *c.PyTypeObject {
    return &ImageType;
}

/// Create a new Python Image object by moving ownership from a Zignal image.
/// The input must be a fully-initialized, owned `zignal.Image(T)` where `T` is one of: `u8`, `Rgb`, or `Rgba`.
/// On success, returns the newly allocated Image instance; on failure, sets a Python exception,
/// deinitializes the input image, and returns null.
pub fn moveImageToPython(owned_img: anytype) ?*ImageObject {
    comptime switch (@TypeOf(owned_img)) {
        zignal.Image(u8),
        zignal.Image(Rgb),
        zignal.Image(Rgba),
        => {},
        else => @compileError("moveImageToPython expects zignal.Image(u8|Rgb|Rgba)"),
    };

    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0) orelse {
        var tmp = owned_img;
        tmp.deinit(allocator);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Image object");
        return null;
    };
    const result = @as(*ImageObject, @ptrCast(py_obj));

    const pnew = PyImage.createFrom(allocator, owned_img, .owned) orelse {
        var tmp = owned_img;
        tmp.deinit(allocator);
        c.Py_DECREF(py_obj);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return null;
    };

    result.py_image = pnew;
    result.numpy_ref = null;
    result.parent_ref = null;
    return result;
}

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

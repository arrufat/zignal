const std = @import("std");

const zignal = @import("zignal");
const InterpolationMethod = zignal.InterpolationMethod;
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const DisplayFormat = zignal.DisplayFormat;

const canvas = @import("canvas.zig");
const color_utils = @import("color_utils.zig");
const pixel_iterator = @import("pixel_iterator.zig");
const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const image_class_doc =
    \\
    \\RGBA image for processing and manipulation.\n\n
    \\This object is iterable: iterating yields (row, col, Rgba) for each pixel\n
    \\in row-major order. For bulk numeric work, prefer to_numpy().
;

pub const ImageObject = extern struct {
    ob_base: c.PyObject,
    // Store pointer to heap-allocated image data (optional)
    image_ptr: ?*Image(Rgba),
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
        // Initialize to null pointer to avoid undefined behavior
        obj.image_ptr = null;
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
    \\
    \\## Examples
    \\```python
    \\# Create a 100x200 transparent image
    \\img = Image(100, 200)
    \\
    \\# Create a 100x200 red image
    \\img = Image(100, 200, (255, 0, 0))
    \\
    \\# Create a 100x200 gray image
    \\img = Image(100, 200, 128)
    \\
    \\# Create an image from numpy array dimensions
    \\img = Image(*arr.shape[:2])
    \\
    \\# Create with semi-transparent blue
    \\img = Image(100, 200, (0, 0, 255, 128))
    \\```
;

fn image_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = kwds; // Not used in current implementation
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if the image is already initialized (might be from load or from_numpy)
    if (self.image_ptr != null) {
        // Already initialized, just return success
        return 0;
    }

    // Parse arguments
    var rows: c_int = 0;
    var cols: c_int = 0;
    var color_obj: ?*c.PyObject = null;

    // Parse as separate integers
    const format = std.fmt.comptimePrint("ii|O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &rows, &cols, &color_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Image() requires (rows, cols, color=None) as arguments");
        return -1;
    }

    // Validate dimensions - validateRange now properly handles negative values when converting to usize
    const validated_rows = py_utils.validateRange(usize, rows, 1, std.math.maxInt(usize), "Rows") catch return -1;
    const validated_cols = py_utils.validateRange(usize, cols, 1, std.math.maxInt(usize), "Cols") catch return -1;

    // Parse color if provided, otherwise use transparent
    var fill_color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 }; // Default transparent
    if (color_obj != null and color_obj != c.Py_None()) {
        fill_color = color_utils.parseColorToRgba(color_obj) catch {
            // Error already set by parseColorToRgba
            return -1;
        };
    }

    // Create image
    var image = Image(Rgba).initAlloc(allocator, validated_rows, validated_cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return -1;
    };

    // Fill with specified color
    @memset(image.data, fill_color);

    // Store the image
    const image_ptr = allocator.create(Image(Rgba)) catch {
        image.deinit(allocator);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return -1;
    };

    image_ptr.* = image;
    self.image_ptr = image_ptr;
    self.numpy_ref = null;
    self.parent_ref = null;

    return 0;
}

fn image_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Free the image data if it was allocated
    if (self.image_ptr) |ptr| {
        // Only free if we allocated it (not if it's from numpy or a view)
        if (self.numpy_ref == null and self.parent_ref == null) {
            // Full deallocation: image data + pointer wrapper
            ptr.deinit(py_utils.allocator);
            py_utils.allocator.destroy(ptr);
        } else {
            // NumPy or parent owns the data, just destroy the pointer wrapper
            py_utils.allocator.destroy(ptr);
        }
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

    // Get the image pointers
    const self_img = self.image_ptr orelse {
        // Self has no image data, compare with other
        const other_has_data = other.image_ptr != null;
        if (op == c.Py_EQ) {
            return @ptrCast(py_utils.getPyBool(!other_has_data));
        } else {
            return @ptrCast(py_utils.getPyBool(other_has_data));
        }
    };

    const other_img = other.image_ptr orelse {
        // Other has no image data, self does
        if (op == c.Py_EQ) {
            return @ptrCast(py_utils.getPyBool(false));
        } else {
            return @ptrCast(py_utils.getPyBool(true));
        }
    };

    // Compare dimensions first
    if (self_img.rows != other_img.rows or self_img.cols != other_img.cols) {
        // Dimensions don't match
        if (op == c.Py_EQ) {
            return @ptrCast(py_utils.getPyBool(false));
        } else {
            return @ptrCast(py_utils.getPyBool(true));
        }
    }

    var pixels_equal: bool = undefined;
    if (!self_img.isView() and !other_img.isView()) {
        // for non views, compare all data at once
        pixels_equal = std.mem.eql(Rgba, self_img.data, other_img.data);
    } else {
        // for views, compare row by row
        pixels_equal = true;
        for (0..self_img.rows) |row| {
            const self_row_start = row * self_img.stride;
            const other_row_start = row * other_img.stride;

            const self_row = self_img.data[self_row_start..][0..self_img.cols];
            const other_row = other_img.data[other_row_start..][0..other_img.cols];

            if (!std.mem.eql(Rgba, self_row, other_row)) {
                pixels_equal = false;
                break;
            }
        }
    }

    if (op == c.Py_EQ) {
        return @ptrCast(py_utils.getPyBool(pixels_equal));
    } else {
        return @ptrCast(py_utils.getPyBool(!pixels_equal));
    }
}

fn image_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        var buffer: [64]u8 = undefined;
        const formatted = std.fmt.bufPrintZ(&buffer, "Image({d}x{d})", .{ ptr.rows, ptr.cols }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("Image(uninitialized)");
    }
}

fn image_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    const ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;
    return c.PyLong_FromLong(@intCast(ptr.rows));
}

fn image_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    const ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;
    return c.PyLong_FromLong(@intCast(ptr.cols));
}

fn image_is_view(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args; // No arguments
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    const ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;
    return @ptrCast(py_utils.getPyBool(ptr.isView()));
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

    // Load the image as RGBA for SIMD optimization benefits
    const image = Image(Rgba).load(allocator, path_slice) catch |err| {
        py_utils.setErrorWithPath(err, path_slice);
        return null;
    };

    // Create new Python object
    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) {
        var img = image;
        img.deinit(allocator);
        return null;
    }

    // Allocate space for the image on heap and move it there
    const image_ptr = allocator.create(Image(Rgba)) catch {
        var img = image;
        img.deinit(allocator);
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };

    image_ptr.* = image;
    self.?.image_ptr = image_ptr;

    return @as(?*c.PyObject, @ptrCast(self));
}

const image_to_numpy_doc =
    \\Convert the image to a NumPy array (zero-copy when possible).
    \\
    \\## Parameters
    \\- `include_alpha` (bool, optional): If True (default), returns array with shape (rows, cols, 4).
    \\  If False, returns array with shape (rows, cols, 3).
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\arr_rgba = img.to_numpy()  # Include alpha
    \\arr_rgb = img.to_numpy(include_alpha=False)  # RGB only
    \\print(arr_rgba.shape, arr_rgb.shape)
    \\# Output: (512, 768, 4) (512, 768, 3)
    \\```
;

fn image_to_numpy(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments - include_alpha defaults to true
    var include_alpha: c_int = 1;
    var kwlist = [_:null]?[*:0]u8{ @constCast("include_alpha"), null };
    const format = std.fmt.comptimePrint("|p", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &include_alpha) == 0) {
        return null;
    }

    const ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // If created from numpy and include_alpha matches, return the original array
    if (self.numpy_ref) |numpy_array| {
        // Check if numpy array has the right number of channels
        // For now, just return it if include_alpha is true (4 channels)
        if (include_alpha != 0) {
            c.Py_INCREF(numpy_array);
            return numpy_array;
        }
        // If include_alpha is false and we have a 4-channel array, we need to slice it
        // Fall through to create a new view
    }
    // Import numpy
    const np_module = c.PyImport_ImportModule("numpy") orelse {
        c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
        return null;
    };
    defer c.Py_DECREF(np_module);

    // Create a memoryview from our image data
    var buffer = c.Py_buffer{
        .buf = @ptrCast(ptr.data.ptr),
        .obj = self_obj,
        .len = @intCast(ptr.rows * ptr.cols * @sizeOf(Rgba)),
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

    // Get numpy.frombuffer function
    const frombuffer = c.PyObject_GetAttrString(np_module, "frombuffer") orelse return null;
    defer c.Py_DECREF(frombuffer);

    // Create arguments for frombuffer(memview, dtype='uint8')
    const args_tuple = c.Py_BuildValue("(O)", memview) orelse return null;
    defer c.Py_DECREF(args_tuple);

    const kwargs = c.Py_BuildValue("{s:s}", "dtype", "uint8") orelse return null;
    defer c.Py_DECREF(kwargs);

    // Call numpy.frombuffer
    const flat_array = c.PyObject_Call(frombuffer, args_tuple, kwargs) orelse return null;

    // Always reshape to (rows, cols, 4) since internal storage is RGBA
    const reshape_method = c.PyObject_GetAttrString(flat_array, "reshape") orelse {
        c.Py_DECREF(flat_array);
        return null;
    };
    defer c.Py_DECREF(reshape_method);

    const shape_tuple = c.Py_BuildValue("(III)", ptr.rows, ptr.cols, @as(c_uint, 4)) orelse {
        c.Py_DECREF(flat_array);
        return null;
    };
    defer c.Py_DECREF(shape_tuple);

    const reshaped_array = c.PyObject_CallObject(reshape_method, shape_tuple) orelse {
        c.Py_DECREF(flat_array);
        return null;
    };

    c.Py_DECREF(flat_array);

    // If include_alpha is false, slice to get only RGB channels
    if (include_alpha == 0) {
        // array[:, :, :3]
        const slice_obj = c.PySlice_New(c.Py_None(), c.Py_None(), c.Py_None()) orelse {
            c.Py_DECREF(reshaped_array);
            return null;
        };
        defer c.Py_DECREF(slice_obj);

        const three = c.PyLong_FromLong(3) orelse {
            c.Py_DECREF(reshaped_array);
            return null;
        };
        defer c.Py_DECREF(three);

        const slice_tuple = c.Py_BuildValue("(OOO)", slice_obj, slice_obj, c.PySlice_New(c.Py_None(), three, c.Py_None())) orelse {
            c.Py_DECREF(reshaped_array);
            return null;
        };
        defer c.Py_DECREF(slice_tuple);

        const sliced_array = c.PyObject_GetItem(reshaped_array, slice_tuple) orelse {
            c.Py_DECREF(reshaped_array);
            return null;
        };

        c.Py_DECREF(reshaped_array);
        return sliced_array;
    }

    return reshaped_array;
}

const image_from_numpy_doc =
    \\Create Image from NumPy array with shape (rows, cols, 3) or (rows, cols, 4) and dtype uint8.
    \\
    \\For 4-channel arrays, zero-copy is used. For 3-channel arrays, the data is
    \\converted to RGBA format with alpha=255 (requires allocation).
    \\To enable zero-copy for RGB arrays, use Image.add_alpha() first.
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

    // Validate dimensions (should be 3D with shape (rows, cols, 3 or 4))
    if (buffer.ndim != 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have shape (rows, cols, 3) or (rows, cols, 4)");
        return null;
    }

    // Get shape information
    const shape = @as([*]c.Py_ssize_t, @ptrCast(buffer.shape));
    const rows = @as(usize, @intCast(shape[0]));
    const cols = @as(usize, @intCast(shape[1]));
    const channels = @as(usize, @intCast(shape[2]));

    if (channels != 3 and channels != 4) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have 3 channels (RGB) or 4 channels (RGBA)");
        return null;
    }

    // Check if array is C-contiguous
    // For C-contiguous, strides should be: (cols*channels, channels, 1)
    const strides = @as([*]c.Py_ssize_t, @ptrCast(buffer.strides));
    const expected_stride_2 = buffer.itemsize; // Should be 1 for uint8
    const expected_stride_1 = expected_stride_2 * @as(c.Py_ssize_t, @intCast(channels)); // Should be 3 or 4
    const expected_stride_0 = expected_stride_1 * @as(c.Py_ssize_t, @intCast(cols)); // Should be cols * channels

    if (strides[0] != expected_stride_0 or strides[1] != expected_stride_1 or strides[2] != expected_stride_2) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array is not C-contiguous. Use numpy.ascontiguousarray() first.");
        return null;
    }

    // Create new Python object
    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) {
        return null;
    }

    // Allocate space for the image struct on heap
    const image_ptr = allocator.create(Image(Rgba)) catch {
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };

    if (channels == 4) {
        // Zero-copy: create image that points to NumPy's data directly
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const data_slice = data_ptr[0..@intCast(buffer.len)];

        // Use initFromBytes to reinterpret the data as RGBA pixels
        image_ptr.* = Image(Rgba).initFromBytes(rows, cols, data_slice);

        // Keep a reference to the NumPy array to prevent deallocation
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
    } else {
        // 3 channels - need to allocate and convert to RGBA
        var rgba_image = Image(Rgba).initAlloc(allocator, rows, cols) catch {
            allocator.destroy(image_ptr);
            c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
            c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate RGBA image");
            return null;
        };

        // Copy RGB data and set alpha to 255
        const rgb_data = @as([*]const u8, @ptrCast(buffer.buf));
        for (0..rows) |r| {
            for (0..cols) |col| {
                const src_idx = (r * cols + col) * 3;
                const dst_idx = r * cols + col;
                rgba_image.data[dst_idx] = Rgba{
                    .r = rgb_data[src_idx],
                    .g = rgb_data[src_idx + 1],
                    .b = rgb_data[src_idx + 2],
                    .a = 255,
                };
            }
        }

        image_ptr.* = rgba_image;
        // No numpy_ref since we allocated new memory
        self.?.numpy_ref = null;
        self.?.parent_ref = null;
    }

    self.?.image_ptr = image_ptr;
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

    // Check if image is initialized
    const image_ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

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

    // Get allocator and save PNG
    image_ptr.save(allocator, path_slice) catch |err| {
        py_utils.setErrorWithPath(err, path_slice);
        return null;
    };

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

const image_add_alpha_doc =
    \\Add alpha channel to a 3-channel RGB numpy array.
    \\
    \\This is useful for enabling zero-copy when creating Images from RGB arrays.
    \\
    \\## Parameters
    \\- `array` (NDArray[np.uint8]): NumPy array with shape (rows, cols, 3) and dtype uint8
    \\- `alpha` (int, optional): Alpha value to use for all pixels (default: 255)
    \\
    \\## Examples
    \\```python
    \\rgb_arr = np.zeros((100, 200, 3), dtype=np.uint8)
    \\rgba_arr = Image.add_alpha(rgb_arr)
    \\print(rgba_arr.shape)
    \\# Output: (100, 200, 4)
    \\img = Image.from_numpy(rgba_arr)  # Zero-copy creation
    \\```
;

fn image_add_alpha(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;
    var array_obj: ?*c.PyObject = undefined;
    var alpha_value: c_int = 255;

    const format = std.fmt.comptimePrint("O|i", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &array_obj, &alpha_value) == 0) {
        return null;
    }

    if (array_obj == null or array_obj == c.Py_None()) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array cannot be None");
        return null;
    }

    // Import numpy if not already imported
    const np_module = c.PyImport_ImportModule("numpy") orelse {
        c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
        return null;
    };
    defer c.Py_DECREF(np_module);

    // Get array shape
    const shape_attr = c.PyObject_GetAttrString(array_obj, "shape") orelse {
        c.PyErr_SetString(c.PyExc_TypeError, "Input must be a numpy array");
        return null;
    };
    defer c.Py_DECREF(shape_attr);

    // Check if shape is (h, w, 3)
    var h: c.Py_ssize_t = 0;
    var w: c.Py_ssize_t = 0;
    var c_var: c.Py_ssize_t = 0;
    if (c.PyArg_ParseTuple(shape_attr, "nnn", &h, &w, &c_var) == 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have shape (rows, cols, 3)");
        return null;
    }

    if (c_var != 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have 3 channels (RGB)");
        return null;
    }

    // Create alpha array: np.full((h, w, 1), alpha_value, dtype=np.uint8)
    const full_func = c.PyObject_GetAttrString(np_module, "full") orelse return null;
    defer c.Py_DECREF(full_func);

    const shape_tuple = c.Py_BuildValue("((nnn)i)", h, w, @as(c.Py_ssize_t, 1), alpha_value) orelse return null;
    defer c.Py_DECREF(shape_tuple);

    const kwargs = c.Py_BuildValue("{s:s}", "dtype", "uint8") orelse return null;
    defer c.Py_DECREF(kwargs);

    const alpha_array = c.PyObject_Call(full_func, shape_tuple, kwargs) orelse return null;
    defer c.Py_DECREF(alpha_array);

    // Concatenate: np.concatenate([array, alpha_array], axis=2)
    const concatenate_func = c.PyObject_GetAttrString(np_module, "concatenate") orelse return null;
    defer c.Py_DECREF(concatenate_func);

    const arrays_list = c.PyList_New(2) orelse return null;
    defer c.Py_DECREF(arrays_list);

    c.Py_INCREF(array_obj.?);
    _ = c.PyList_SetItem(arrays_list, 0, array_obj.?);
    c.Py_INCREF(alpha_array);
    _ = c.PyList_SetItem(arrays_list, 1, alpha_array);

    const concat_args = c.Py_BuildValue("(O)", arrays_list) orelse return null;
    defer c.Py_DECREF(concat_args);

    const concat_kwargs = c.Py_BuildValue("{s:i}", "axis", @as(c_int, 2)) orelse return null;
    defer c.Py_DECREF(concat_kwargs);

    return c.PyObject_Call(concatenate_func, concat_args, concat_kwargs);
}

fn image_iter(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));
    _ = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;
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

    // Check if image is initialized
    const image_ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

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

    // Create formatter
    const formatter = image_ptr.display(display_format);

    // Capture formatted output using std.fmt.format
    var buffer: std.ArrayList(u8) = .init(allocator);
    defer buffer.deinit();

    // Use std.fmt.format to invoke the formatter's format method properly
    std.fmt.format(buffer.writer(), "{f}", .{formatter}) catch |err| {
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory"),
        }
        return null;
    };

    // Create Python string from buffer
    return c.PyUnicode_FromStringAndSize(buffer.items.ptr, @intCast(buffer.items.len));
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
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch {
        return error.ImageNotInitialized;
    };

    var scaled_image = src_image.scale(allocator, scale, method) catch |err| {
        switch (err) {
            error.InvalidScaleFactor => {
                c.PyErr_SetString(c.PyExc_ValueError, "Scale factor must be positive");
                return error.InvalidScaleFactor;
            },
            error.InvalidDimensions => {
                c.PyErr_SetString(c.PyExc_ValueError, "Resulting image dimensions would be zero");
                return error.InvalidDimensions;
            },
            error.OutOfMemory => {
                c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate scaled image");
                return error.OutOfMemory;
            },
        }
    };

    // Wrap in heap-allocated pointer
    const new_image = allocator.create(Image(Rgba)) catch {
        scaled_image.deinit(allocator);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return error.OutOfMemory;
    };
    errdefer allocator.destroy(new_image);
    new_image.* = scaled_image;

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return error.OutOfMemory;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));

    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;

    return result;
}

fn image_reshape(self: *ImageObject, rows: usize, cols: usize, method: InterpolationMethod) !*ImageObject {
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch {
        return error.ImageNotInitialized;
    };

    // Create new image
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return error.OutOfMemory;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, rows, cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return error.OutOfMemory;
    };

    // Perform resize
    src_image.resize(new_image.*, method);

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return error.OutOfMemory;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));

    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;

    return result;
}

const image_fill_doc =
    \\Fill the entire image with a solid color.
    \\
    \\## Parameters
    \\- `color`: Color value as:
    \\  - int: Grayscale value (0-255), expanded to RGBA
    \\  - tuple[int, int, int]: RGB values
    \\  - tuple[int, int, int, int]: RGBA values
    \\  - Color object with to_rgba() method or r,g,b,a attributes
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

    const color = color_utils.parseColorToRgba(color_obj) catch {
        return null;
    };

    const image_ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch {
        return null;
    };

    image_ptr.fill(color);

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
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch {
        return error.ImageNotInitialized;
    };

    // Create new image for letterbox output
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return error.OutOfMemory;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, size, size) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return error.OutOfMemory;
    };

    // Perform letterbox
    _ = src_image.letterbox(allocator, new_image, method) catch |err| {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory"),
            error.InvalidDimensions => c.PyErr_SetString(c.PyExc_ValueError, "Invalid dimensions"),
        }
        return err;
    };

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return error.OutOfMemory;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return result;
}

fn image_letterbox_shape(self: *ImageObject, rows: usize, cols: usize, method: InterpolationMethod) !*ImageObject {
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch {
        return error.ImageNotInitialized;
    };

    // Create new image for letterbox output
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return error.OutOfMemory;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, rows, cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return error.OutOfMemory;
    };

    // Perform letterbox
    _ = src_image.letterbox(allocator, new_image, method) catch |err| {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory"),
            error.InvalidDimensions => c.PyErr_SetString(c.PyExc_ValueError, "Invalid dimensions"),
        }
        return err;
    };

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return error.OutOfMemory;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return result;
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

    // Get the source image
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Create new image for rotated output
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    // Initialize as empty, will be auto-sized by rotate function
    new_image.* = Image(Rgba).empty;

    // Perform rotation
    src_image.rotate(allocator, @floatCast(angle), method, new_image) catch {
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
        return null;
    };

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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

    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Allocate new image wrapper; underlying data will be allocated by boxBlur
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    // Initialize as empty; boxBlur will allocate and size appropriately
    new_image.* = Image(Rgba).empty;

    src_image.boxBlur(allocator, new_image, @intCast(radius_long)) catch {
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
        return null;
    };

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }

    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
}

const image_sharpen_doc =
    \\Sharpen the image using unsharp masking (2 * self - box_blur).
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

    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Allocate new image wrapper; underlying data will be allocated by sharpen
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    // Initialize as empty; sharpen will allocate and size appropriately
    new_image.* = Image(Rgba).empty;

    src_image.sharpen(allocator, new_image, @intCast(radius_long)) catch {
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
        return null;
    };

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }

    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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

    // Get both images
    const self_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Self image") catch return null;
    const other_image = py_utils.validateNonNull(*Image(Rgba), other.image_ptr, "Other image") catch return null;

    // Calculate PSNR
    const psnr_value = self_image.psnr(other_image.*) catch |err| {
        switch (err) {
            error.DimensionMismatch => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "Image dimensions must match. Self: {}x{}, Other: {}x{}", .{
                    self_image.rows,
                    self_image.cols,
                    other_image.rows,
                    other_image.cols,
                }) catch "Image dimensions must match";
                c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                return null;
            },
        }
    };

    // Return the PSNR value as a Python float
    return c.PyFloat_FromDouble(psnr_value);
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

    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Allocate destination image of same size
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, src_image.rows, src_image.cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return null;
    };

    // Perform copy
    src_image.copy(new_image.*);

    // Wrap into Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }

    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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

    // Get the source image
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Create the view (this returns a new Image struct that shares data)
    const view_image = src_image.view(rect);

    // Create wrapper for the view
    const view_ptr = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image view");
        return null;
    };
    errdefer allocator.destroy(view_ptr);

    view_ptr.* = view_image;

    // Create new Python object for the view
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        allocator.destroy(view_ptr);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }

    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = view_ptr;
    result.numpy_ref = null;

    // IMPORTANT: Keep a reference to the parent to prevent deallocation
    c.Py_INCREF(self_obj);
    result.parent_ref = self_obj;

    return py_obj;
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

    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Create copy
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, src_image.rows, src_image.cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return null;
    };

    // Copy and flip
    src_image.copy(new_image.*);
    new_image.flipLeftRight();

    // Wrap into Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }

    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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

    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Create copy
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, src_image.rows, src_image.cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return null;
    };

    // Copy and flip
    src_image.copy(new_image.*);
    new_image.flipTopBottom();

    // Wrap into Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }

    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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

    // Get the source image
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Create new image for cropped output
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    // Perform crop
    src_image.crop(allocator, rect, new_image) catch {
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate cropped image");
        return null;
    };

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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

    // Get the source image
    const src_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

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

    // Create output image
    const new_image = allocator.create(Image(Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = Image(Rgba).initAlloc(allocator, out_rows, out_cols) catch {
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image data");
        return null;
    };

    // Perform extraction
    src_image.extract(rect, @floatCast(angle), new_image.*, method);

    // Create new Python object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ImageType), 0);
    if (py_obj == null) {
        new_image.deinit(allocator);
        allocator.destroy(new_image);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Python object");
        return null;
    }
    const result = @as(*ImageObject, @ptrCast(py_obj));
    result.image_ptr = new_image;
    result.numpy_ref = null;
    result.parent_ref = null;
    return py_obj;
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
    const source_image = py_utils.validateNonNull(*Image(Rgba), source.image_ptr, "Source image") catch return null;

    // Parse the Rectangle object
    const rect = py_utils.parseRectangle(rect_obj) catch return null;

    // Convert method value to Zig enum
    const method = pythonToZigInterpolation(method_value) catch {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid interpolation method");
        return null;
    };

    // Get the destination image (self)
    const dst_image = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Perform insertion (modifies dst_image in-place)
    dst_image.insert(source_image.*, rect, @floatCast(angle), method);

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
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
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    const img_ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

    // Create new Canvas object
    const canvas_obj = @as(?*canvas.CanvasObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(&canvas.CanvasType), 0)));
    if (canvas_obj == null) {
        return null;
    }

    // Keep reference to parent Image to prevent garbage collection
    c.Py_INCREF(self_obj.?);
    canvas_obj.?.image_ref = @ptrCast(self_obj);

    // Create and store the Canvas struct
    const canvas_ptr = allocator.create(canvas.Canvas(Rgba)) catch {
        c.Py_DECREF(self_obj.?);
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(canvas_obj)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Canvas");
        return null;
    };

    // Initialize the Canvas
    canvas_ptr.* = canvas.Canvas(Rgba).init(allocator, img_ptr.*);
    canvas_obj.?.canvas_ptr = canvas_ptr;

    return @as(?*c.PyObject, @ptrCast(canvas_obj));
}

fn image_getitem(self_obj: ?*c.PyObject, key: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    const img_ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return null;

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
    if (row < 0 or row >= img_ptr.rows) {
        c.PyErr_SetString(c.PyExc_IndexError, "Row index out of bounds");
        return null;
    }
    if (col < 0 or col >= img_ptr.cols) {
        c.PyErr_SetString(c.PyExc_IndexError, "Column index out of bounds");
        return null;
    }

    // Get the pixel value
    const pixel = img_ptr.at(@intCast(row), @intCast(col)).*;

    // Import color module to get RgbaType
    const color_module = @import("color.zig");

    // Create and return an Rgba object
    const rgba_obj = c.PyType_GenericAlloc(@ptrCast(&color_module.RgbaType), 0);
    if (rgba_obj == null) {
        return null;
    }

    const rgba = @as(*color_module.RgbaBinding.PyObjectType, @ptrCast(rgba_obj));
    rgba.field0 = pixel.r;
    rgba.field1 = pixel.g;
    rgba.field2 = pixel.b;
    rgba.field3 = pixel.a;

    return rgba_obj;
}

fn image_setitem(self_obj: ?*c.PyObject, key: ?*c.PyObject, value: ?*c.PyObject) callconv(.c) c_int {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    const img_ptr = py_utils.validateNonNull(*Image(Rgba), self.image_ptr, "Image") catch return -1;

    // Parse the key - expecting a tuple of (row, col)
    if (c.PyTuple_Check(key) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Image indices must be a tuple of (row, col)");
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
    if (row < 0 or row >= img_ptr.rows) {
        c.PyErr_SetString(c.PyExc_IndexError, "Row index out of bounds");
        return -1;
    }
    if (col < 0 or col >= img_ptr.cols) {
        c.PyErr_SetString(c.PyExc_IndexError, "Column index out of bounds");
        return -1;
    }

    // Parse the color value using parseColorToRgba
    const color = color_utils.parseColorToRgba(value) catch {
        // Error already set by parseColorToRgba
        return -1;
    };

    // Set the pixel value
    img_ptr.at(@intCast(row), @intCast(col)).* = color;

    return 0;
}

fn image_len(self_obj: ?*c.PyObject) callconv(.c) c.Py_ssize_t {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return -1;
    }

    const img = self.image_ptr.?;
    return @intCast(img.rows * img.cols);
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
        .name = "from_numpy",
        .meth = @ptrCast(&image_from_numpy),
        .flags = c.METH_VARARGS | c.METH_CLASS,
        .doc = image_from_numpy_doc,
        .params = "cls, array: NDArray[np.uint8]",
        .returns = "Image",
    },
    .{
        .name = "add_alpha",
        .meth = @ptrCast(&image_add_alpha),
        .flags = c.METH_VARARGS | c.METH_STATIC,
        .doc = image_add_alpha_doc,
        .params = "array: NDArray[np.uint8], alpha: int = 255",
        .returns = "NDArray[np.uint8]",
    },
    .{
        .name = "to_numpy",
        .meth = @ptrCast(&image_to_numpy),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = image_to_numpy_doc,
        .params = "self, include_alpha: bool = True",
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
};

var image_getset = stub_metadata.toPyGetSetDefArray(&image_properties_metadata);

// Special methods metadata for stub generation
pub const image_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        // .params = "self, rows: int, cols: int, color: " ++ stub_metadata.COLOR ++ " | None = None",
        .params = "self, rows: int, cols: int, color: " ++ stub_metadata.COLOR ++ " | None = None",
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
        .doc = "Iterate over pixels in row-major order, yielding (row, col, Rgba).",
    },
    .{
        .name = "__getitem__",
        .params = "self, key: tuple[int, int]",
        .returns = "Rgba",
    },
    .{
        .name = "__setitem__",
        .params = "self, key: tuple[int, int], value: " ++ stub_metadata.COLOR,
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

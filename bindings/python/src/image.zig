const std = @import("std");

const zignal = @import("zignal");

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// IMAGERGB TYPE
// ============================================================================

pub const ImageRgbObject = extern struct {
    ob_base: c.PyObject,
    // Store pointer to heap-allocated image data (optional)
    image_ptr: ?*zignal.Image(zignal.Rgb),
    // Store reference to NumPy array if created from numpy (for zero-copy)
    numpy_ref: ?*c.PyObject,
};

fn imagergb_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*ImageRgbObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize to null pointer to avoid undefined behavior
        obj.image_ptr = null;
        obj.numpy_ref = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn imagergb_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;

    // For now, don't allow direct instantiation
    c.PyErr_SetString(c.PyExc_TypeError, "ImageRgb cannot be instantiated directly. Use ImageRgb.load() instead.");
    return -1;
}

fn imagergb_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    // Free the image data if it was allocated
    if (self.image_ptr) |ptr| {
        // Only free if we allocated it (not if it's from numpy)
        if (self.numpy_ref == null) {
            // Full deallocation: image data + pointer wrapper
            ptr.deinit(py_utils.allocator);
            py_utils.allocator.destroy(ptr);
        } else {
            // NumPy owns the data, just destroy the pointer wrapper
            py_utils.allocator.destroy(ptr);
        }
    }

    // Release reference to NumPy array if we have one
    if (self.numpy_ref) |ref| {
        c.Py_XDECREF(ref);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn imagergb_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        var buffer: [64]u8 = undefined;
        const formatted = std.fmt.bufPrintZ(&buffer, "ImageRgb({d}x{d})", .{ ptr.rows, ptr.cols }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("ImageRgb(uninitialized)");
    }
}

// Property getters
fn imagergb_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        return c.PyLong_FromLong(@intCast(ptr.rows));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

fn imagergb_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        return c.PyLong_FromLong(@intCast(ptr.cols));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

// Class methods
fn imagergb_load(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var file_path: [*c]const u8 = undefined;

    const format = comptime std.fmt.comptimePrint("s", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &file_path) == 0) {
        return null;
    }

    // Convert C string to Zig slice
    const path_slice = std.mem.span(file_path);

    // Check if file exists first to provide better error message
    std.fs.cwd().access(path_slice, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                c.PyErr_SetString(c.PyExc_FileNotFoundError, "Image file not found");
                return null;
            },
            else => {}, // Continue with load attempt
        }
    };

    // Load the image
    const image = zignal.Image(zignal.Rgb).load(allocator, path_slice) catch |err| {
        switch (err) {
            error.FileNotFound => c.PyErr_SetString(c.PyExc_FileNotFoundError, "Image file not found"),
            error.UnsupportedImageFormat => c.PyErr_SetString(c.PyExc_ValueError, "Unsupported image format"),
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory"),
            else => c.PyErr_SetString(c.PyExc_IOError, "Failed to load image"),
        }
        return null;
    };

    // Create new Python object
    const self = @as(?*ImageRgbObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) {
        var img = image;
        img.deinit(allocator);
        return null;
    }

    // Allocate space for the image on heap and move it there
    const image_ptr = allocator.create(zignal.Image(zignal.Rgb)) catch {
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

// Convert image to numpy array (zero-copy)
fn imagergb_to_numpy(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        // If created from numpy, return the original array (true zero-copy roundtrip)
        if (self.numpy_ref) |numpy_array| {
            c.Py_INCREF(numpy_array);
            return numpy_array;
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
            .len = @intCast(ptr.rows * ptr.cols * @sizeOf(zignal.Rgb)),
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

        // Reshape to (rows, cols, 3)
        const reshape_method = c.PyObject_GetAttrString(flat_array, "reshape") orelse {
            c.Py_DECREF(flat_array);
            return null;
        };
        defer c.Py_DECREF(reshape_method);

        const shape_tuple = c.Py_BuildValue("(III)", ptr.rows, ptr.cols, @as(c_uint, 3)) orelse {
            c.Py_DECREF(flat_array);
            return null;
        };
        defer c.Py_DECREF(shape_tuple);

        const reshaped_array = c.PyObject_CallObject(reshape_method, shape_tuple) orelse {
            c.Py_DECREF(flat_array);
            return null;
        };

        c.Py_DECREF(flat_array);
        return reshaped_array;
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

// Create ImageRgb from numpy array
fn imagergb_from_numpy(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var array_obj: ?*c.PyObject = undefined;

    const format = comptime std.fmt.comptimePrint("O", .{});
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

    // Validate dimensions (should be 3D with shape (rows, cols, 3))
    if (buffer.ndim != 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have shape (rows, cols, 3)");
        return null;
    }

    // Get shape information
    const shape = @as([*]c.Py_ssize_t, @ptrCast(buffer.shape));
    const rows = @as(usize, @intCast(shape[0]));
    const cols = @as(usize, @intCast(shape[1]));
    const channels = @as(usize, @intCast(shape[2]));

    if (channels != 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must have 3 channels (RGB)");
        return null;
    }

    // Check if array is C-contiguous
    // For C-contiguous, strides should be: (cols*3, 3, 1)
    const strides = @as([*]c.Py_ssize_t, @ptrCast(buffer.strides));
    const expected_stride_2 = buffer.itemsize; // Should be 1 for uint8
    const expected_stride_1 = expected_stride_2 * @as(c.Py_ssize_t, @intCast(channels)); // Should be 3
    const expected_stride_0 = expected_stride_1 * @as(c.Py_ssize_t, @intCast(cols)); // Should be cols * 3

    if (strides[0] != expected_stride_0 or strides[1] != expected_stride_1 or strides[2] != expected_stride_2) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array is not C-contiguous. Use numpy.ascontiguousarray() first.");
        return null;
    }

    // Create new Python object
    const self = @as(?*ImageRgbObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) {
        return null;
    }

    // Allocate space for the image struct on heap
    const image_ptr = allocator.create(zignal.Image(zignal.Rgb)) catch {
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };

    // Zero-copy: create image that points to NumPy's data
    // Note: We only get here if the array is C-contiguous
    const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
    const data_slice = data_ptr[0..@intCast(buffer.len)];

    // Use initFromBytes to reinterpret the data as RGB pixels
    image_ptr.* = zignal.Image(zignal.Rgb).initFromBytes(rows, cols, data_slice);

    // Keep a reference to the NumPy array to prevent deallocation
    c.Py_INCREF(array_obj.?);
    self.?.numpy_ref = array_obj;

    self.?.image_ptr = image_ptr;
    return @as(?*c.PyObject, @ptrCast(self));
}

// Save image to PNG file
fn imagergb_save(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    // Parse file path argument
    var file_path: [*c]const u8 = undefined;
    const format = comptime std.fmt.comptimePrint("s", .{});
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
    zignal.savePng(zignal.Rgb, allocator, self.image_ptr.?.*, path_slice) catch |err| {
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory"),
            error.AccessDenied => c.PyErr_SetString(c.PyExc_PermissionError, "Permission denied"),
            error.FileNotFound => c.PyErr_SetString(c.PyExc_FileNotFoundError, "Directory not found"),
            else => c.PyErr_SetString(c.PyExc_IOError, "Failed to save image"),
        }
        return null;
    };

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// Format image for display with format specifiers
fn imagergb_format(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    // Parse format_spec argument
    var format_spec: [*c]const u8 = undefined;
    const format = comptime std.fmt.comptimePrint("s", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &format_spec) == 0) {
        return null;
    }

    // Convert C string to Zig slice
    const spec_slice = std.mem.span(format_spec);

    // If empty format spec, return default repr
    if (spec_slice.len == 0) {
        return imagergb_repr(self_obj);
    }

    // Check if image is initialized
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    // Determine display format based on spec
    const display_format: zignal.DisplayFormat = if (std.mem.eql(u8, spec_slice, "ansi"))
        .ansi
    else if (std.mem.eql(u8, spec_slice, "sixel"))
        .{ .sixel = .default }
    else if (std.mem.eql(u8, spec_slice, "auto"))
        .auto
    else {
        c.PyErr_SetString(c.PyExc_ValueError, "Invalid format spec. Use '', 'ansi', 'sixel', or 'auto'");
        return null;
    };

    // Create formatter
    const formatter = self.image_ptr.?.display(display_format);

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

var imagergb_methods = [_]c.PyMethodDef{
    .{ .ml_name = "load", .ml_meth = imagergb_load, .ml_flags = c.METH_VARARGS | c.METH_CLASS, .ml_doc = "Load an RGB image from file" },
    .{ .ml_name = "from_numpy", .ml_meth = imagergb_from_numpy, .ml_flags = c.METH_VARARGS | c.METH_CLASS, .ml_doc = 
    \\Create ImageRgb from NumPy array with shape (rows, cols, 3) and dtype uint8.
    \\
    \\Note: The array must be C-contiguous. If your array is not C-contiguous
    \\(e.g., from slicing or transposing), use np.ascontiguousarray() first:
    \\
    \\    arr = np.ascontiguousarray(arr)
    \\    img = ImageRgb.from_numpy(arr)
    \\
    \\When possible, zero-copy is used for C-contiguous arrays.
    },
    .{ .ml_name = "to_numpy", .ml_meth = imagergb_to_numpy, .ml_flags = c.METH_NOARGS, .ml_doc = "Convert image to NumPy array with shape (rows, cols, 3) without copying data" },
    .{ .ml_name = "save", .ml_meth = imagergb_save, .ml_flags = c.METH_VARARGS, .ml_doc = "Save image to PNG file. File must have .png extension." },
    .{ .ml_name = "__format__", .ml_meth = imagergb_format, .ml_flags = c.METH_VARARGS, .ml_doc = 
    \\Format image for display. Supports format specifiers:
    \\  '' (empty): Returns text representation (e.g., 'ImageRgb(800x600)')
    \\  'ansi': Display using ANSI escape codes (colored blocks)
    \\  'sixel': Display using sixel graphics protocol
    \\  'auto': Auto-detect best format (sixel if supported, otherwise ANSI)
    \\
    \\Example:
    \\  print(f"{img}")        # ImageRgb(800x600)
    \\  print(f"{img:ansi}")   # Display with ANSI colors
    \\  print(f"{img:sixel}")  # Display with sixel graphics
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var imagergb_getset = [_]c.PyGetSetDef{
    .{ .name = "rows", .get = imagergb_get_rows, .set = null, .doc = "Number of rows (height) in the image", .closure = null },
    .{ .name = "cols", .get = imagergb_get_cols, .set = null, .doc = "Number of columns (width) in the image", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var ImageRgbType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.ImageRgb",
    .tp_basicsize = @sizeOf(ImageRgbObject),
    .tp_dealloc = imagergb_dealloc,
    .tp_repr = imagergb_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "RGB image class",
    .tp_methods = &imagergb_methods,
    .tp_getset = &imagergb_getset,
    .tp_init = imagergb_init,
    .tp_new = imagergb_new,
};

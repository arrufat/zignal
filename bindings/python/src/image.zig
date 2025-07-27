const std = @import("std");

const zignal = @import("zignal");
const InterpolationMethod = zignal.InterpolationMethod;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// IMAGE TYPE (uses RGBA internally for SIMD performance)
// ============================================================================

pub const ImageObject = extern struct {
    ob_base: c.PyObject,
    // Store pointer to heap-allocated image data (optional)
    image_ptr: ?*zignal.Image(zignal.Rgba),
    // Store reference to NumPy array if created from numpy (for zero-copy)
    numpy_ref: ?*c.PyObject,
};

fn image_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*ImageObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize to null pointer to avoid undefined behavior
        obj.image_ptr = null;
        obj.numpy_ref = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn image_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;

    // For now, don't allow direct instantiation
    c.PyErr_SetString(c.PyExc_TypeError, "Image cannot be instantiated directly. Use Image.load() instead.");
    return -1;
}

fn image_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

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

// Property getters
fn image_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        return c.PyLong_FromLong(@intCast(ptr.rows));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

fn image_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.image_ptr) |ptr| {
        return c.PyLong_FromLong(@intCast(ptr.cols));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

// Class methods
fn image_load(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var file_path: [*c]const u8 = undefined;

    const format = std.fmt.comptimePrint("s", .{});
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

    // Load the image as RGBA for SIMD optimization benefits
    const image = zignal.Image(zignal.Rgba).load(allocator, path_slice) catch |err| {
        switch (err) {
            error.FileNotFound => c.PyErr_SetString(c.PyExc_FileNotFoundError, "Image file not found"),
            error.UnsupportedImageFormat => c.PyErr_SetString(c.PyExc_ValueError, "Unsupported image format"),
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory"),
            else => c.PyErr_SetString(c.PyExc_IOError, "Failed to load image"),
        }
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
    const image_ptr = allocator.create(zignal.Image(zignal.Rgba)) catch {
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

// Convert image to numpy array (zero-copy when possible)
fn image_to_numpy(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments - include_alpha defaults to true
    var include_alpha: c_int = 1;
    var kwlist = [_:null]?[*:0]u8{ @constCast("include_alpha"), null };
    const format = std.fmt.comptimePrint("|p", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &include_alpha) == 0) {
        return null;
    }

    if (self.image_ptr) |ptr| {
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
            .len = @intCast(ptr.rows * ptr.cols * @sizeOf(zignal.Rgba)),
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
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }
}

// Create Image from numpy array
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
    const image_ptr = allocator.create(zignal.Image(zignal.Rgba)) catch {
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(self)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return null;
    };

    if (channels == 4) {
        // Zero-copy: create image that points to NumPy's data directly
        const data_ptr = @as([*]u8, @ptrCast(buffer.buf));
        const data_slice = data_ptr[0..@intCast(buffer.len)];

        // Use initFromBytes to reinterpret the data as RGBA pixels
        image_ptr.* = zignal.Image(zignal.Rgba).initFromBytes(rows, cols, data_slice);

        // Keep a reference to the NumPy array to prevent deallocation
        c.Py_INCREF(array_obj.?);
        self.?.numpy_ref = array_obj;
    } else {
        // 3 channels - need to allocate and convert to RGBA
        var rgba_image = zignal.Image(zignal.Rgba).initAlloc(allocator, rows, cols) catch {
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
                rgba_image.data[dst_idx] = zignal.Rgba{
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
    }

    self.?.image_ptr = image_ptr;
    return @as(?*c.PyObject, @ptrCast(self));
}

// Save image to PNG file
fn image_save(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Check if image is initialized
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

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
    self.image_ptr.?.save(allocator, path_slice) catch |err| {
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

// Static method to add alpha channel to RGB array for zero-copy usage
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

// Format image for display with format specifiers
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
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return null;
    }

    // Determine display format based on spec
    const display_format: zignal.DisplayFormat = if (std.mem.eql(u8, spec_slice, "ansi"))
        .ansi_basic
    else if (std.mem.eql(u8, spec_slice, "blocks"))
        .ansi_blocks
    else if (std.mem.eql(u8, spec_slice, "braille"))
        .{ .braille = .default }
    else if (std.mem.eql(u8, spec_slice, "sixel"))
        .{ .sixel = .default }
    else if (std.mem.eql(u8, spec_slice, "kitty"))
        .{ .kitty = .default }
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

// Convert Python enum value to Zig InterpolationMethod
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

// Internal function to scale image by a factor
fn image_scale(self: *ImageObject, scale: f32, method: InterpolationMethod) !*ImageObject {
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return error.ImageNotInitialized;
    }

    const src_image = self.image_ptr.?;

    // Calculate new dimensions
    const new_rows = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(src_image.rows)) * scale))));
    const new_cols = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(src_image.cols)) * scale))));

    // Create new image
    const new_image = allocator.create(zignal.Image(zignal.Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return error.OutOfMemory;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = zignal.Image(zignal.Rgba).initAlloc(allocator, new_rows, new_cols) catch {
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

    return result;
}

// Internal function to resize image to specific dimensions
fn image_reshape(self: *ImageObject, rows: usize, cols: usize, method: InterpolationMethod) !*ImageObject {
    if (self.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return error.ImageNotInitialized;
    }

    const src_image = self.image_ptr.?;

    // Create new image
    const new_image = allocator.create(zignal.Image(zignal.Rgba)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate image");
        return error.OutOfMemory;
    };
    errdefer allocator.destroy(new_image);

    new_image.* = zignal.Image(zignal.Rgba).initAlloc(allocator, rows, cols) catch {
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

    return result;
}

// Documentation for the resize method
pub const resize_doc =
    \\resize(size, method=InterpolationMethod.BILINEAR, /)
    \\--
    \\
    \\Resize the image using the specified interpolation method.
    \\
    \\Parameters
    \\----------
    \\size : float or tuple[int, int]
    \\    Either a scale factor (float) or target dimensions (rows, cols).
    \\    - If float: Image will be scaled by this factor (e.g., 2.0 doubles the size)
    \\    - If tuple: Image will be resized to exactly (rows, cols) dimensions
    \\method : InterpolationMethod, optional
    \\    Interpolation method to use. Default is InterpolationMethod.BILINEAR.
    \\    Available methods: NEAREST_NEIGHBOR, BILINEAR, BICUBIC, CATMULL_ROM, MITCHELL, LANCZOS
    \\
    \\Returns
    \\-------
    \\Image
    \\    A new resized Image object
    \\
    \\Raises
    \\------
    \\ValueError
    \\    If scale factor is <= 0, or if target dimensions contain zero or negative values
    \\TypeError
    \\    If size is neither a float nor a tuple of two integers
    \\
    \\Examples
    \\--------
    \\>>> img = Image.load("photo.png")
    \\>>> # Scale by factor
    \\>>> img2x = img.resize(2.0)  # Double the size
    \\>>> img_half = img.resize(0.5)  # Half the size
    \\>>> # Resize to specific dimensions
    \\>>> thumbnail = img.resize((64, 64))
    \\>>> # Use different interpolation
    \\>>> smooth = img.resize(2.0, method=InterpolationMethod.LANCZOS)
;

// Python-facing resize method that handles both scale and dimensions
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

var image_methods = [_]c.PyMethodDef{
    .{ .ml_name = "load", .ml_meth = image_load, .ml_flags = c.METH_VARARGS | c.METH_CLASS, .ml_doc = "Load an image from file (PNG/JPEG)" },
    .{ .ml_name = "from_numpy", .ml_meth = image_from_numpy, .ml_flags = c.METH_VARARGS | c.METH_CLASS, .ml_doc = 
    \\Create Image from NumPy array with shape (rows, cols, 3) or (rows, cols, 4) and dtype uint8.
    \\
    \\Note: The array must be C-contiguous. If your array is not C-contiguous
    \\(e.g., from slicing or transposing), use np.ascontiguousarray() first:
    \\
    \\    arr = np.ascontiguousarray(arr)
    \\    img = Image.from_numpy(arr)
    \\
    \\For 4-channel arrays, zero-copy is used. For 3-channel arrays, the data is
    \\converted to RGBA format with alpha=255 (requires allocation).
    \\To enable zero-copy for RGB arrays, use Image.add_alpha() first.
    },
    .{ .ml_name = "add_alpha", .ml_meth = image_add_alpha, .ml_flags = c.METH_VARARGS | c.METH_STATIC, .ml_doc = 
    \\Add alpha channel to a 3-channel RGB numpy array.
    \\
    \\Parameters:
    \\    array: numpy array with shape (rows, cols, 3) and dtype uint8
    \\    alpha: alpha value to use (default: 255)
    \\
    \\Returns:
    \\    New numpy array with shape (rows, cols, 4) suitable for zero-copy usage
    \\
    \\Example:
    \\    rgb_array = np.array(..., shape=(h,w,3), dtype=np.uint8)
    \\    rgba_array = Image.add_alpha(rgb_array)
    \\    img = Image.from_numpy(rgba_array)  # Zero-copy!
    },
    .{ .ml_name = "to_numpy", .ml_meth = @ptrCast(&image_to_numpy), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = 
    \\Convert image to NumPy array.
    \\
    \\Parameters:
    \\    include_alpha: If True (default), returns shape (rows, cols, 4).
    \\                   If False, returns shape (rows, cols, 3) without alpha channel.
    \\
    \\Returns:
    \\    NumPy array view of the image data (zero-copy when possible)
    },
    .{ .ml_name = "save", .ml_meth = image_save, .ml_flags = c.METH_VARARGS, .ml_doc = 
    \\save(path, /)
    \\--
    \\
    \\Save image to PNG file. File must have .png extension.
    },
    .{ .ml_name = "resize", .ml_meth = @ptrCast(&image_resize), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = 
    \\resize(size, method=InterpolationMethod.BILINEAR, /)
    \\--
    \\
    \\Resize the image using the specified interpolation method.
    \\
    \\Parameters
    \\----------
    \\size : float or tuple[int, int]
    \\    Either a scale factor (float) or target dimensions (rows, cols).
    \\    - If float: Image will be scaled by this factor (e.g., 2.0 doubles the size)
    \\    - If tuple: Image will be resized to exactly (rows, cols) dimensions
    \\method : InterpolationMethod, optional
    \\    Interpolation method to use. Default is InterpolationMethod.BILINEAR.
    \\    Available methods: NEAREST_NEIGHBOR, BILINEAR, BICUBIC, CATMULL_ROM, MITCHELL, LANCZOS
    \\
    \\Returns
    \\-------
    \\Image
    \\    A new resized Image object
    \\
    \\Raises
    \\------
    \\ValueError
    \\    If scale factor is <= 0, or if target dimensions contain zero or negative values
    \\TypeError
    \\    If size is neither a float nor a tuple of two integers
    \\
    \\Examples
    \\--------
    \\>>> img = Image.load("photo.png")
    \\>>> # Scale by factor
    \\>>> img2x = img.resize(2.0)  # Double the size
    \\>>> img_half = img.resize(0.5)  # Half the size
    \\>>> # Resize to specific dimensions
    \\>>> thumbnail = img.resize((64, 64))
    \\>>> # Use different interpolation
    \\>>> smooth = img.resize(2.0, method=InterpolationMethod.LANCZOS)
    },
    .{ .ml_name = "__format__", .ml_meth = image_format, .ml_flags = c.METH_VARARGS, .ml_doc = 
    \\Format image for display. Supports format specifiers:
    \\  '' (empty): Returns text representation (e.g., 'Image(800x600)')
    \\  'auto': Auto-detect best format with progressive degradation: kitty -> sixel -> blocks
    \\  'ansi': Display using ANSI escape codes (spaces with background)
    \\  'blocks': Display using ANSI escape codes (half colored half-blocks with background: 2x vertical resolution)
    \\  'braille': Display using Braille patterns (good for monochrome images)
    \\  'sixel': Display using sixel graphics protocol (up to 256 colors)
    \\  'kitty': Display using kitty graphics protocol (24-bit color)
    \\
    \\Example:
    \\  print(f"{img}")         # Image(800x600)
    \\  print(f"{img:ansi}")    # Display with ANSI colors
    \\  print(f"{img:blocks}")  # Display with ANSI colors using unicode blocks (double vertical resolution, better aspect ratio)
    \\  print(f"{img:braille}") # Display with ANSI colors using braille patterns (good for monochrome images)
    \\  print(f"{img:sixel}")   # Display with sixel graphics
    \\  print(f"{img:kitty}")   # Display with kitty graphics
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var image_getset = [_]c.PyGetSetDef{
    .{ .name = "rows", .get = image_get_rows, .set = null, .doc = "Number of rows (height) in the image", .closure = null },
    .{ .name = "cols", .get = image_get_cols, .set = null, .doc = "Number of columns (width) in the image", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
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
    .tp_doc = "Image class with RGBA storage for SIMD-optimized operations",
    .tp_methods = &image_methods,
    .tp_getset = &image_getset,
    .tp_init = image_init,
    .tp_new = image_new,
};

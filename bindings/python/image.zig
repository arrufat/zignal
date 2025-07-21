const std = @import("std");

const zignal = @import("zignal");

const py_utils = @import("py_utils.zig");
pub const registerType = py_utils.registerType;

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// IMAGERGB TYPE
// ============================================================================

const ImageRgbObject = extern struct {
    ob_base: c.PyObject,
    // Store pointer to heap-allocated image data (optional)
    image_ptr: ?*zignal.Image(zignal.Rgb),
};

fn imagergb_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*ImageRgbObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize to null pointer to avoid undefined behavior
        obj.image_ptr = null;
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

// Global allocator for the module
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn imagergb_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*ImageRgbObject, @ptrCast(self_obj.?));

    // Free the image data if it was allocated
    if (self.image_ptr) |ptr| {
        const allocator = gpa.allocator();
        ptr.deinit(allocator);
        allocator.destroy(ptr);
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

    // Use global allocator
    const allocator = gpa.allocator();

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
    _ = type_obj;
    var array_obj: ?*c.PyObject = undefined;

    const format = comptime std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &array_obj) == 0) {
        return null;
    }

    // For debugging, just return an error for now
    if (array_obj != null) {
        c.PyErr_SetString(c.PyExc_NotImplementedError, "from_numpy is temporarily disabled for debugging");
    }
    return null;
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
    const allocator = gpa.allocator();
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

var imagergb_methods = [_]c.PyMethodDef{
    .{ .ml_name = "load", .ml_meth = imagergb_load, .ml_flags = c.METH_VARARGS | c.METH_CLASS, .ml_doc = "Load an RGB image from file" },
    .{ .ml_name = "from_numpy", .ml_meth = imagergb_from_numpy, .ml_flags = c.METH_VARARGS | c.METH_CLASS, .ml_doc = "Create ImageRgb from NumPy array with shape (rows, cols, 3) and dtype uint8" },
    .{ .ml_name = "to_numpy", .ml_meth = imagergb_to_numpy, .ml_flags = c.METH_NOARGS, .ml_doc = "Convert image to NumPy array with shape (rows, cols, 3) without copying data" },
    .{ .ml_name = "save", .ml_meth = imagergb_save, .ml_flags = c.METH_VARARGS, .ml_doc = "Save image to PNG file. File must have .png extension." },
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

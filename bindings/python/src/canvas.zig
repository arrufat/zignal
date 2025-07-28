const std = @import("std");

const zignal = @import("zignal");
pub const Canvas = zignal.Canvas;
const DrawMode = zignal.DrawMode;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// CANVAS TYPE
// ============================================================================

pub const CanvasObject = extern struct {
    ob_base: c.PyObject,
    // Keep reference to parent Image to prevent garbage collection
    image_ref: ?*c.PyObject,
    // Store a pointer to the heap-allocated Canvas struct
    canvas_ptr: ?*Canvas(zignal.Rgba),
};

fn canvas_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*CanvasObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.image_ref = null;
        obj.canvas_ptr = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn canvas_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = kwds;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Parse arguments - expect an Image object
    var image_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &image_obj) == 0) {
        return -1;
    }

    // Import the image module to get the ImageType
    const image_module = @import("image.zig");

    // Check if it's an Image instance
    if (c.PyObject_IsInstance(image_obj, @ptrCast(&image_module.ImageType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Argument must be an Image instance");
        return -1;
    }

    const image = @as(*image_module.ImageObject, @ptrCast(image_obj.?));

    // Check if image is initialized
    if (image.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return -1;
    }

    // Keep reference to parent Image to prevent garbage collection
    c.Py_INCREF(image_obj.?);
    self.image_ref = image_obj;

    // Create and store the Canvas struct
    const canvas_ptr = allocator.create(Canvas(zignal.Rgba)) catch {
        c.Py_DECREF(image_obj.?);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Canvas");
        return -1;
    };

    // Initialize the Canvas
    if (image.image_ptr) |img_ptr| {
        canvas_ptr.* = Canvas(zignal.Rgba).init(allocator, img_ptr.*);
    } else {
        allocator.destroy(canvas_ptr);
        c.Py_DECREF(image_obj.?);
        c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
        return -1;
    }
    self.canvas_ptr = canvas_ptr;

    return 0;
}

fn canvas_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Free the Canvas struct
    if (self.canvas_ptr) |ptr| {
        allocator.destroy(ptr);
    }

    // Release reference to parent Image
    if (self.image_ref) |ref| {
        c.Py_XDECREF(ref);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn canvas_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.canvas_ptr) |canvas| {
        var buffer: [64]u8 = undefined;
        const formatted = std.fmt.bufPrintZ(&buffer, "Canvas({d}x{d})", .{ canvas.image.rows, canvas.image.cols }) catch return null;
        return c.PyUnicode_FromString(formatted.ptr);
    } else {
        return c.PyUnicode_FromString("Canvas(uninitialized)");
    }
}

// Helper function to convert Python color tuple to Rgba
fn parseColorTuple(color_obj: ?*c.PyObject) !zignal.Rgba {
    if (color_obj == null) {
        return error.InvalidColor;
    }

    // Check if it's a tuple
    if (c.PyTuple_Check(color_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Color must be a tuple of (r, g, b) or (r, g, b, a)");
        return error.InvalidColor;
    }

    const size = c.PyTuple_Size(color_obj);
    if (size != 3 and size != 4) {
        c.PyErr_SetString(c.PyExc_ValueError, "Color tuple must have 3 or 4 elements");
        return error.InvalidColor;
    }

    // Extract color components
    var r: c_long = 0;
    var g: c_long = 0;
    var b: c_long = 0;
    var a: c_long = 255;

    // Get R
    const r_obj = c.PyTuple_GetItem(color_obj, 0);
    r = c.PyLong_AsLong(r_obj);
    if (r == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Color components must be integers");
        return error.InvalidColor;
    }

    // Get G
    const g_obj = c.PyTuple_GetItem(color_obj, 1);
    g = c.PyLong_AsLong(g_obj);
    if (g == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Color components must be integers");
        return error.InvalidColor;
    }

    // Get B
    const b_obj = c.PyTuple_GetItem(color_obj, 2);
    b = c.PyLong_AsLong(b_obj);
    if (b == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Color components must be integers");
        return error.InvalidColor;
    }

    // Get A if present
    if (size == 4) {
        const a_obj = c.PyTuple_GetItem(color_obj, 3);
        a = c.PyLong_AsLong(a_obj);
        if (a == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Color components must be integers");
            return error.InvalidColor;
        }
    }

    // Validate range
    if (r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 or a < 0 or a > 255) {
        c.PyErr_SetString(c.PyExc_ValueError, "Color components must be in range 0-255");
        return error.InvalidColor;
    }

    return zignal.Rgba{
        .r = @intCast(r),
        .g = @intCast(g),
        .b = @intCast(b),
        .a = @intCast(a),
    };
}

// Fill the entire canvas with a color
fn canvas_fill(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse color argument
    var color_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &color_obj) == 0) {
        return null;
    }

    // Convert color tuple to Rgba
    const color = parseColorTuple(color_obj) catch return null;

    // Use the stored Canvas directly
    self.canvas_ptr.?.fill(color);

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// Property getters
fn canvas_get_rows(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.canvas_ptr) |canvas| {
        return c.PyLong_FromLong(@intCast(canvas.image.rows));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }
}

fn canvas_get_cols(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.canvas_ptr) |canvas| {
        return c.PyLong_FromLong(@intCast(canvas.image.cols));
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }
}

fn canvas_get_image(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    if (self.image_ref) |img_ref| {
        c.Py_INCREF(img_ref);
        return img_ref;
    } else {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }
}

var canvas_methods = [_]c.PyMethodDef{
    .{ .ml_name = "fill", .ml_meth = canvas_fill, .ml_flags = c.METH_VARARGS, .ml_doc = 
    \\fill(color, /)
    \\--
    \\
    \\Fill the entire canvas with a solid color.
    \\
    \\Parameters
    \\----------
    \\color : tuple[int, int, int] or tuple[int, int, int, int]
    \\    RGB or RGBA color tuple with values in range 0-255.
    \\    If only RGB is provided, alpha defaults to 255 (fully opaque).
    \\
    \\Examples
    \\--------
    \\>>> img = Image.load("photo.png")
    \\>>> canvas = img.canvas()
    \\>>> canvas.fill((255, 0, 0))      # Fill with red
    \\>>> canvas.fill((0, 255, 0, 128)) # Fill with semi-transparent green
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var canvas_getset = [_]c.PyGetSetDef{
    .{ .name = "rows", .get = canvas_get_rows, .set = null, .doc = "Number of rows (height) in the canvas", .closure = null },
    .{ .name = "cols", .get = canvas_get_cols, .set = null, .doc = "Number of columns (width) in the canvas", .closure = null },
    .{ .name = "image", .get = canvas_get_image, .set = null, .doc = "The Image object this canvas draws on", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var CanvasType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.Canvas",
    .tp_basicsize = @sizeOf(CanvasObject),
    .tp_dealloc = canvas_dealloc,
    .tp_repr = canvas_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Canvas for drawing operations on images",
    .tp_methods = &canvas_methods,
    .tp_getset = &canvas_getset,
    .tp_init = canvas_init,
    .tp_new = canvas_new,
};

// ============================================================================
// DRAWMODE ENUM
// ============================================================================

pub fn registerDrawMode(module: *c.PyObject) !void {
    // Create the enum type
    const enum_dict = c.PyDict_New() orelse return error.OutOfMemory;
    defer c.Py_DECREF(enum_dict);

    // Add enum values
    const fast_value = c.PyLong_FromLong(0) orelse return error.OutOfMemory;
    defer c.Py_DECREF(fast_value);
    if (c.PyDict_SetItemString(enum_dict, "FAST", fast_value) < 0) return error.Failed;

    const soft_value = c.PyLong_FromLong(1) orelse return error.OutOfMemory;
    defer c.Py_DECREF(soft_value);
    if (c.PyDict_SetItemString(enum_dict, "SOFT", soft_value) < 0) return error.Failed;

    // Create enum class
    const enum_module = c.PyImport_ImportModule("enum") orelse return error.ImportError;
    defer c.Py_DECREF(enum_module);

    const int_enum = c.PyObject_GetAttrString(enum_module, "IntEnum") orelse return error.AttributeError;
    defer c.Py_DECREF(int_enum);

    const args = c.Py_BuildValue("(sO)", "DrawMode", enum_dict) orelse return error.OutOfMemory;
    defer c.Py_DECREF(args);

    const draw_mode_type = c.PyObject_CallObject(int_enum, args) orelse return error.CallError;

    // Set docstring
    const doc_str = c.PyUnicode_FromString(
        \\Rendering quality mode for drawing operations.
        \\
        \\Values:
        \\    FAST: Fast rendering with hard edges, maximum performance
        \\    SOFT: Soft rendering with antialiased edges, better quality
    ) orelse return error.OutOfMemory;
    defer c.Py_DECREF(doc_str);

    if (c.PyObject_SetAttrString(draw_mode_type, "__doc__", doc_str) < 0) {
        c.Py_DECREF(draw_mode_type);
        return error.Failed;
    }

    // Add to module
    if (c.PyModule_AddObject(module, "DrawMode", draw_mode_type) < 0) {
        c.Py_DECREF(draw_mode_type);
        return error.Failed;
    }
}

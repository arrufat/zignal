const std = @import("std");

const zignal = @import("zignal");
pub const Canvas = zignal.Canvas;
const DrawMode = zignal.DrawMode;
const Point2d = zignal.Point2d;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
pub const registerType = py_utils.registerType;
const stub_metadata = @import("stub_metadata.zig");
const metadata_converter = @import("metadata_converter.zig");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

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

const canvas_fill_doc =
    \\fill(color, /)
    \\--
    \\
    \\Fill the entire canvas with a color.
    \\
    \\Parameters
    \\----------
    \\color : tuple or color object
    \\    Color to fill the canvas with. Can be:
    \\    - RGB tuple: (r, g, b) with values 0-255
    \\    - RGBA tuple: (r, g, b, a) with values 0-255
    \\    - Any color object: Rgb, Rgba, Hsl, Hsv, Lab, Lch, Lms, Oklab, Oklch, Xyb, Xyz, Ycbcr
    \\
    \\Returns
    \\-------
    \\None
    \\
    \\Examples
    \\--------
    \\>>> img = Image.load("photo.png")
    \\>>> canvas = img.canvas()
    \\>>> canvas.fill((255, 0, 0))  # Fill with red
    \\>>> canvas.fill(Rgb(0, 255, 0))  # Fill with green using Rgb object
;

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

    // Convert color to Rgba
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;

    // Use the stored Canvas directly
    self.canvas_ptr.?.fill(color);

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

const canvas_draw_line_doc =
    \\draw_line(p1, p2, color, width=1, mode=DrawMode.FAST, /)
    \\--
    \\
    \\Draw a line between two points.
    \\
    \\Parameters
    \\----------
    \\p1 : tuple[float, float]
    \\    Starting point coordinates (x, y)
    \\p2 : tuple[float, float]
    \\    Ending point coordinates (x, y)
    \\color : tuple or color object
    \\    Color of the line. Can be:
    \\    - RGB tuple: (r, g, b) with values 0-255
    \\    - RGBA tuple: (r, g, b, a) with values 0-255
    \\    - Any color object: Rgb, Rgba, Hsl, Hsv, Lab, Lch, Lms, Oklab, Oklch, Xyb, Xyz, Ycbcr
    \\width : int, optional
    \\    Line width in pixels (default: 1)
    \\mode : DrawMode, optional
    \\    Drawing mode - DrawMode.FAST or DrawMode.SOFT (default: DrawMode.FAST)
    \\
    \\Returns
    \\-------
    \\None
    \\
    \\Examples
    \\--------
    \\>>> img = Image.load("photo.png")
    \\>>> canvas = img.canvas()
    \\>>> # Draw a red line from top-left to bottom-right
    \\>>> canvas.draw_line((0, 0), (100, 100), (255, 0, 0))
    \\>>> # Draw a thick blue line with antialiasing
    \\>>> canvas.draw_line((50, 50), (150, 50), (0, 0, 255), width=5, mode=DrawMode.SOFT)
;

fn canvas_draw_line(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*CanvasObject, @ptrCast(self_obj.?));

    // Check if canvas is initialized
    if (self.canvas_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Canvas not initialized");
        return null;
    }

    // Parse arguments - p1, p2, color are required; width and mode are optional
    var p1_obj: ?*c.PyObject = undefined;
    var p2_obj: ?*c.PyObject = undefined;
    var color_obj: ?*c.PyObject = undefined;
    var width: c_long = 1;
    var mode: c_long = 0; // DrawMode.FAST

    const kwlist = [_][*c]const u8{ "p1", "p2", "color", "width", "mode", null };
    const format = std.fmt.comptimePrint("OOO|ll", .{});

    // TODO: remove @constCast once we only use Python >= 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @constCast(@ptrCast(&kwlist)), &p1_obj, &p2_obj, &color_obj, &width, &mode) == 0) {
        return null;
    }

    // Validate width
    if (width < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Width must be non-negative");
        return null;
    }

    // Validate mode
    if (mode != 0 and mode != 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "Mode must be DrawMode.FAST (0) or DrawMode.SOFT (1)");
        return null;
    }

    // Convert Python objects to Zig types
    const p1 = py_utils.parsePointTuple(@ptrCast(p1_obj)) catch return null;
    const p2 = py_utils.parsePointTuple(@ptrCast(p2_obj)) catch return null;
    const color = py_utils.parseColorToRgba(@ptrCast(color_obj)) catch return null;

    // Convert mode to DrawMode enum
    const draw_mode: DrawMode = if (mode == 0) .fast else .soft;

    // Draw the line
    self.canvas_ptr.?.drawLine(p1, p2, color, @intCast(width), draw_mode);

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

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

const colors = "'Rgb', 'Rgba', 'Hsl', 'Hsv', 'Lab', 'Lch', 'Lms', 'Oklab', 'Oklch', 'Xyb', 'Xyz', 'Ycbcr'";

pub const canvas_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "fill",
        .meth = @ptrCast(&canvas_fill),
        .flags = c.METH_VARARGS,
        .doc = canvas_fill_doc,
        .params = "self, color: Union[Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "]",
        .returns = "None",
    },
    .{
        .name = "draw_line",
        .meth = @ptrCast(&canvas_draw_line),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = canvas_draw_line_doc,
        .params = "self, p1: Tuple[float, float], p2: Tuple[float, float], color: Union[Tuple[int, int, int], Tuple[int, int, int, int], " ++ colors ++ "], width: int = 1, mode: DrawMode = ...",
        .returns = "None",
    },
};

var canvas_methods = metadata_converter.toPyMethodDefArray(&canvas_methods_metadata);

pub const canvas_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "rows",
        .get = @ptrCast(&canvas_get_rows),
        .set = null,
        .doc = "Number of rows in the canvas",
        .type = "int",
    },
    .{
        .name = "cols",
        .get = @ptrCast(&canvas_get_cols),
        .set = null,
        .doc = "Number of columns in the canvas",
        .type = "int",
    },
    .{
        .name = "image",
        .get = @ptrCast(&canvas_get_image),
        .set = null,
        .doc = "Parent Image object",
        .type = "Image",
    },
};

var canvas_getset = metadata_converter.toPyGetSetDefArray(&canvas_properties_metadata);

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
    .tp_methods = @ptrCast(&canvas_methods),
    .tp_getset = @ptrCast(&canvas_getset),
    .tp_init = canvas_init,
    .tp_new = canvas_new,
};

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

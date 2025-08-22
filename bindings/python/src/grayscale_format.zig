const std = @import("std");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;

// Minimal Grayscale type sentinel used to indicate grayscale (u8) image format.
// It is a non-instantiable type object added to the module as zignal.Grayscale.
pub const GrayscaleTypeObject = extern struct {
    ob_base: c.PyObject,
};

fn grayscale_repr(self: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    _ = self;
    return c.PyUnicode_FromString("Grayscale");
}

pub var GrayscaleType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Grayscale",
    .tp_basicsize = @sizeOf(GrayscaleTypeObject),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Grayscale image format (single channel, u8)",
    .tp_new = null, // not instantiable; used as a sentinel
    .tp_repr = grayscale_repr,
    .tp_str = grayscale_repr,
};

pub fn registerGrayscaleType(module: [*c]c.PyObject) !void {
    // Add the type object to the module under the name "Grayscale"
    try py_utils.registerType(@ptrCast(module), "Grayscale", @ptrCast(&GrayscaleType));
}

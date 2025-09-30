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

pub var GrayscaleType = py_utils.buildTypeObject(.{
    .name = "zignal.Grayscale",
    .basicsize = @sizeOf(GrayscaleTypeObject),
    .doc = "Grayscale image format (single channel, u8)",
    .new = null, // not instantiable; used as a sentinel
    .repr = grayscale_repr,
    .str = grayscale_repr,
});

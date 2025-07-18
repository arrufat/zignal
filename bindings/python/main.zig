const std = @import("std");
const build_options = @import("build_options");

const color = @import("color.zig");
const image = @import("image.zig");
const py_utils = @import("py_utils.zig");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// MODULE FUNCTIONS
// ============================================================================

var zignal_methods = [_]c.PyMethodDef{
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var zignal_module = c.PyModuleDef{
    .m_name = "zignal",
    .m_doc = "zero dependency image processing library",
    .m_size = -1,
    .m_methods = &zignal_methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

pub export fn PyInit__zignal() ?*c.PyObject {
    const m = c.PyModule_Create(&zignal_module);
    if (m == null) return null;

    // Register Rgb type (using factory)
    py_utils.registerType(@ptrCast(m), "Rgb", @ptrCast(&color.RgbType)) catch {
        c.Py_DECREF(m);
        return null;
    };

    // Register Hsv type (using factory)
    py_utils.registerType(@ptrCast(m), "Hsv", @ptrCast(&color.HsvType)) catch |err| {
        std.log.err("Failed to register HSV type: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register ImageRgb type
    py_utils.registerType(@ptrCast(m), "ImageRgb", @ptrCast(&image.ImageRgbType)) catch {
        c.Py_DECREF(m);
        return null;
    };

    // Add __version__ as a module attribute from build options
    const version_str = c.PyUnicode_FromString(@ptrCast(build_options.version));
    if (version_str == null) {
        c.Py_DECREF(m);
        return null;
    }
    if (c.PyModule_AddObject(m, "__version__", version_str) < 0) {
        c.Py_DECREF(version_str);
        c.Py_DECREF(m);
        return null;
    }

    return m;
}

pub fn main() void {}

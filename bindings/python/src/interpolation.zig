const std = @import("std");
const py_utils = @import("py_utils.zig");
const stub_metadata = @import("stub_metadata.zig");
const zignal = @import("zignal");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// INTERPOLATION METHOD ENUM
// ============================================================================

// Python object for InterpolationMethod (empty, it's just an enum)
pub const InterpolationMethodObject = extern struct {
    ob_base: c.PyObject,
};

// Create the enum type
pub var InterpolationMethodType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.InterpolationMethod",
    .tp_basicsize = 0, // No instance size needed for enum
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Interpolation methods for image resizing",
    .tp_new = null, // Cannot instantiate
};

// Register the InterpolationMethod enum
pub fn registerInterpolationMethod(module: *c.PyObject) !void {
    // Create the enum using Python's enum module
    const enum_module = c.PyImport_ImportModule("enum") orelse return error.ImportFailed;
    defer c.Py_DECREF(enum_module);

    const int_enum = c.PyObject_GetAttrString(enum_module, "IntEnum") orelse return error.AttributeFailed;
    defer c.Py_DECREF(int_enum);

    // Create the enum values dictionary
    const values = c.PyDict_New() orelse return error.DictCreationFailed;
    defer c.Py_DECREF(values);

    // Add enum values
    const enum_values = .{
        .{ "NEAREST_NEIGHBOR", 0 },
        .{ "BILINEAR", 1 },
        .{ "BICUBIC", 2 },
        .{ "CATMULL_ROM", 3 },
        .{ "MITCHELL", 4 },
        .{ "LANCZOS", 5 },
    };

    inline for (enum_values) |value| {
        const py_value = c.PyLong_FromLong(value[1]) orelse return error.ValueCreationFailed;
        defer c.Py_DECREF(py_value);
        if (c.PyDict_SetItemString(values, value[0], py_value) < 0) {
            return error.DictSetFailed;
        }
    }

    // Create the enum class: IntEnum('InterpolationMethod', values)
    const args = c.PyTuple_Pack(2, c.PyUnicode_FromString("InterpolationMethod"), values) orelse return error.TupleCreationFailed;
    defer c.Py_DECREF(args);

    const interpolation_method = c.PyObject_CallObject(int_enum, args) orelse return error.EnumCreationFailed;

    // Add docstring to the enum
    const doc_str = c.PyUnicode_FromString(
        \\Interpolation methods for image resizing.
        \\
        \\Performance and quality comparison:
        \\
        \\| Method            | Quality | Speed | Best Use Case       | Overshoot |
        \\|-------------------|---------|-------|---------------------|-----------|
        \\| NEAREST_NEIGHBOR  | ★☆☆☆☆   | ★★★★★ | Pixel art, masks    | No        |
        \\| BILINEAR          | ★★☆☆☆   | ★★★★☆ | Real-time, preview  | No        |
        \\| BICUBIC           | ★★★☆☆   | ★★★☆☆ | General purpose     | Yes       |
        \\| CATMULL_ROM       | ★★★★☆   | ★★★☆☆ | Natural images      | No        |
        \\| MITCHELL          | ★★★★☆   | ★★☆☆☆ | Balanced quality    | Yes       |
        \\| LANCZOS           | ★★★★★   | ★☆☆☆☆ | High-quality resize | Yes       |
        \\
        \\Note: "Overshoot" means the filter can create values outside the input range,
        \\which can cause ringing artifacts but may also enhance sharpness.
    ) orelse return error.DocStringFailed;
    if (c.PyObject_SetAttrString(interpolation_method, "__doc__", doc_str) < 0) {
        c.Py_DECREF(doc_str);
        c.Py_DECREF(interpolation_method);
        return error.DocStringSetFailed;
    }
    c.Py_DECREF(doc_str);

    // Set __module__ attribute to help pdoc recognize it as a top-level class
    const module_name = c.PyUnicode_FromString("zignal") orelse return error.ModuleNameFailed;
    if (c.PyObject_SetAttrString(interpolation_method, "__module__", module_name) < 0) {
        c.Py_DECREF(module_name);
        c.Py_DECREF(interpolation_method);
        return error.ModuleSetFailed;
    }
    c.Py_DECREF(module_name);

    // Add to module
    if (c.PyModule_AddObject(module, "InterpolationMethod", interpolation_method) < 0) {
        c.Py_DECREF(interpolation_method);
        return error.ModuleAddFailed;
    }
}

// ============================================================================
// INTERPOLATION METHOD STUB GENERATION METADATA
// ============================================================================

pub const interpolation_enum_info = stub_metadata.EnumInfo{
    .name = "InterpolationMethod",
    .doc = "Interpolation methods for image resizing",
    .zig_type = zignal.InterpolationMethod,
};

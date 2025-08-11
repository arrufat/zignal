//! BlendMode enum for color blending operations

const zignal = @import("zignal");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;

// Register the BlendMode enum
pub fn registerBlendMode(module: *c.PyObject) !void {
    // Create the enum using Python's enum module
    const enum_module = c.PyImport_ImportModule("enum") orelse return error.ImportFailed;
    defer c.Py_DECREF(enum_module);

    const int_enum = c.PyObject_GetAttrString(enum_module, "IntEnum") orelse return error.AttributeFailed;
    defer c.Py_DECREF(int_enum);

    // Create the enum values dictionary
    const values = c.PyDict_New() orelse return error.DictCreationFailed;
    defer c.Py_DECREF(values);

    // Add enum values - must match the order in zignal.BlendMode
    const enum_values = .{
        .{ "NORMAL", 0 },
        .{ "MULTIPLY", 1 },
        .{ "SCREEN", 2 },
        .{ "OVERLAY", 3 },
        .{ "SOFT_LIGHT", 4 },
        .{ "HARD_LIGHT", 5 },
        .{ "COLOR_DODGE", 6 },
        .{ "COLOR_BURN", 7 },
        .{ "DARKEN", 8 },
        .{ "LIGHTEN", 9 },
        .{ "DIFFERENCE", 10 },
        .{ "EXCLUSION", 11 },
    };

    inline for (enum_values) |value| {
        const py_value = c.PyLong_FromLong(value[1]) orelse return error.ValueCreationFailed;
        defer c.Py_DECREF(py_value);
        if (c.PyDict_SetItemString(values, value[0], py_value) < 0) {
            return error.DictSetFailed;
        }
    }

    // Create the enum class: IntEnum('BlendMode', values)
    const args = c.PyTuple_Pack(2, c.PyUnicode_FromString("BlendMode"), values) orelse return error.TupleCreationFailed;
    defer c.Py_DECREF(args);

    const blend_mode = c.PyObject_CallObject(int_enum, args) orelse return error.EnumCreationFailed;

    // Add docstring to the enum
    const doc_str = c.PyUnicode_FromString(
        \\Blending modes for color composition.
        \\
        \\## Overview
        \\These modes determine how colors are combined when blending. Each mode produces
        \\different visual effects useful for various image compositing operations.
        \\
        \\## Blend Modes
        \\
        \\| Mode        | Description                                            | Best Use Case     |
        \\|-------------|--------------------------------------------------------|-------------------|
        \\| NORMAL      | Standard alpha blending with transparency              | Layering images   |
        \\| MULTIPLY    | Darkens by multiplying colors (white has no effect)    | Shadows, darkening|
        \\| SCREEN      | Lightens by inverting, multiplying, then inverting     | Highlights, glow  |
        \\| OVERLAY     | Combines multiply and screen based on base color       | Contrast enhance  |
        \\| SOFT_LIGHT  | Gentle contrast adjustment                             | Subtle lighting   |
        \\| HARD_LIGHT  | Like overlay but uses overlay color to determine blend | Strong contrast   |
        \\| COLOR_DODGE | Brightens base color based on overlay                  | Bright highlights |
        \\| COLOR_BURN  | Darkens base color based on overlay                    | Deep shadows      |
        \\| DARKEN      | Selects darker color per channel                       | Remove white      |
        \\| LIGHTEN     | Selects lighter color per channel                      | Remove black      |
        \\| DIFFERENCE  | Subtracts darker from lighter color                    | Invert/compare    |
        \\| EXCLUSION   | Similar to difference but with lower contrast          | Soft inversion    |
        \\
        \\## Examples
        \\```python
        \\base = zignal.Rgb(100, 100, 100)
        \\overlay = zignal.Rgba(200, 50, 150, 128)
        \\
        \\# Apply different blend modes
        \\normal = base.blend(overlay, zignal.BlendMode.NORMAL)
        \\multiply = base.blend(overlay, zignal.BlendMode.MULTIPLY)
        \\screen = base.blend(overlay, zignal.BlendMode.SCREEN)
        \\```
        \\
        \\## Notes
        \\- All blend modes respect alpha channel for proper compositing
        \\- Result color type matches the base color type
        \\- Overlay must be RGBA or convertible to RGBA
    ) orelse return error.DocStringFailed;
    if (c.PyObject_SetAttrString(blend_mode, "__doc__", doc_str) < 0) {
        c.Py_DECREF(doc_str);
        c.Py_DECREF(blend_mode);
        return error.DocStringSetFailed;
    }
    c.Py_DECREF(doc_str);

    // Set __module__ attribute
    const module_name = c.PyUnicode_FromString("zignal") orelse return error.ModuleNameFailed;
    if (c.PyObject_SetAttrString(blend_mode, "__module__", module_name) < 0) {
        c.Py_DECREF(module_name);
        c.Py_DECREF(blend_mode);
        return error.ModuleSetFailed;
    }
    c.Py_DECREF(module_name);

    // Add to module
    if (c.PyModule_AddObject(module, "BlendMode", blend_mode) < 0) {
        c.Py_DECREF(blend_mode);
        return error.ModuleAddFailed;
    }
}

/// Convert Python BlendMode enum value to Zig enum
pub fn convertToZigBlendMode(py_obj: *c.PyObject) !zignal.BlendMode {
    // Check if it's an integer or can be converted to one
    const value = c.PyLong_AsLong(py_obj);
    if (value == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_Clear();
        // Try to get the value attribute if it's an enum member
        const value_attr = c.PyObject_GetAttrString(py_obj, "value") orelse {
            c.PyErr_SetString(c.PyExc_TypeError, "BlendMode must be an integer or enum member");
            return error.InvalidType;
        };
        defer c.Py_DECREF(value_attr);
        const enum_value = c.PyLong_AsLong(value_attr);
        if (enum_value == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Failed to extract enum value");
            return error.InvalidType;
        }
        return intToBlendMode(enum_value);
    }
    return intToBlendMode(value);
}

fn intToBlendMode(value: c_long) !zignal.BlendMode {
    return switch (value) {
        0 => .normal,
        1 => .multiply,
        2 => .screen,
        3 => .overlay,
        4 => .soft_light,
        5 => .hard_light,
        6 => .color_dodge,
        7 => .color_burn,
        8 => .darken,
        9 => .lighten,
        10 => .difference,
        11 => .exclusion,
        else => {
            c.PyErr_SetString(c.PyExc_ValueError, "Invalid BlendMode value");
            return error.InvalidValue;
        },
    };
}

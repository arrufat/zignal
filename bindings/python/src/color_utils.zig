const std = @import("std");
const c = @import("py_utils.zig").c;
const zignal = @import("zignal");

/// Extract RGBA values from a Python object with r,g,b,a attributes
pub fn extractRgbaFromObject(obj: *c.PyObject) !zignal.Rgba {
    const r_attr = c.PyObject_GetAttrString(obj, "r");
    if (r_attr == null) return error.InvalidColor;
    defer c.Py_DECREF(r_attr);

    const g_attr = c.PyObject_GetAttrString(obj, "g");
    if (g_attr == null) return error.InvalidColor;
    defer c.Py_DECREF(g_attr);

    const b_attr = c.PyObject_GetAttrString(obj, "b");
    if (b_attr == null) return error.InvalidColor;
    defer c.Py_DECREF(b_attr);

    const a_attr = c.PyObject_GetAttrString(obj, "a");
    if (a_attr == null) return error.InvalidColor;
    defer c.Py_DECREF(a_attr);

    const r = c.PyLong_AsLong(r_attr);
    const g = c.PyLong_AsLong(g_attr);
    const b = c.PyLong_AsLong(b_attr);
    const a = c.PyLong_AsLong(a_attr);

    if (c.PyErr_Occurred() != null) {
        return error.InvalidColor;
    }

    return zignal.Rgba{
        .r = @intCast(r),
        .g = @intCast(g),
        .b = @intCast(b),
        .a = @intCast(a),
    };
}

/// Parse a Python color - either an integer (grayscale), a tuple (RGB/RGBA), or a color object
/// Returns a zignal.Rgba color with values in range 0-255
pub fn parseColorToRgba(color_obj: ?*c.PyObject) !zignal.Rgba {
    if (color_obj == null) {
        return error.InvalidColor;
    }

    // Check if it's an integer (grayscale)
    if (c.PyLong_Check(color_obj) != 0) {
        const gray_value = c.PyLong_AsLong(color_obj);
        if (gray_value == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Grayscale value must be an integer");
            return error.InvalidColor;
        }

        if (gray_value < 0 or gray_value > 255) {
            c.PyErr_SetString(c.PyExc_ValueError, "Grayscale value must be in range 0-255");
            return error.InvalidColor;
        }

        return zignal.Rgba{
            .r = @intCast(gray_value),
            .g = @intCast(gray_value),
            .b = @intCast(gray_value),
            .a = 255,
        };
    }

    // Check if it's a tuple
    if (c.PyTuple_Check(color_obj) != 0) {
        return parseColorTuple(color_obj);
    }

    // Check if it has a to_rgba method (duck typing)
    const to_rgba_str = c.PyUnicode_FromString("to_rgba");
    defer c.Py_DECREF(to_rgba_str);

    if (c.PyObject_HasAttr(color_obj, to_rgba_str) != 0) {
        // Call to_rgba() method
        const rgba_obj = c.PyObject_CallMethodObjArgs(color_obj, to_rgba_str, @as(?*c.PyObject, null));
        if (rgba_obj == null) {
            return error.InvalidColor;
        }
        defer c.Py_DECREF(rgba_obj);

        return extractRgbaFromObject(rgba_obj);
    }

    // Check if it's an Rgba-like object directly (has r,g,b,a attributes)
    if (extractRgbaFromObject(color_obj.?)) |rgba| {
        return rgba;
    } else |_| {
        // Clear any Python error that might have been set by failed attribute access
        c.PyErr_Clear();
    }

    c.PyErr_SetString(c.PyExc_TypeError, "Color must be an integer (0-255), a tuple of (r, g, b) or (r, g, b, a), or a color object with to_rgba() method or r,g,b,a attributes");
    return error.InvalidColor;
}

/// Parse a Python tuple representing a color (RGB or RGBA)
/// Returns a zignal.Rgba color with values in range 0-255
/// This is now a helper function used by parseColor
pub fn parseColorTuple(color_obj: ?*c.PyObject) !zignal.Rgba {
    if (color_obj == null) {
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

const std = @import("std");
const c = @import("py_utils.zig").c;
const zignal = @import("zignal");

const Rgb = zignal.Rgb;
const Rgba = zignal.Rgba;

/// Extract color component attribute from a Python object.
/// This is a helper function used internally.
/// Returns null if the attribute doesn't exist or isn't a valid integer.
/// Note: This function does NOT set Python exceptions.
fn extractColorAttribute(obj: *c.PyObject, name: [*c]const u8) ?c_long {
    const attr = c.PyObject_GetAttrString(obj, name);
    if (attr == null) return null;
    defer c.Py_DECREF(attr);

    const value = c.PyLong_AsLong(attr);
    if (c.PyErr_Occurred() != null) {
        return null;
    }

    return value;
}

/// Extract RGB values from a Python object with r,g,b attributes.
/// This is a helper function used internally.
/// Returns error.InvalidColor if the object doesn't have the required attributes
/// or if the attribute values cannot be converted to integers.
/// Note: This function does NOT set Python exceptions.
fn extractRgbFromObject(obj: *c.PyObject) !Rgb {
    const r = extractColorAttribute(obj, "r") orelse return error.InvalidColor;
    const g = extractColorAttribute(obj, "g") orelse return error.InvalidColor;
    const b = extractColorAttribute(obj, "b") orelse return error.InvalidColor;

    return Rgb{
        .r = @intCast(r),
        .g = @intCast(g),
        .b = @intCast(b),
    };
}

/// Extract RGBA values from a Python object with r,g,b,a attributes.
/// This is a helper function used internally.
/// Returns error.InvalidColor if the object doesn't have the required attributes
/// or if the attribute values cannot be converted to integers.
/// Note: This function does NOT set Python exceptions.
fn extractRgbaFromObject(obj: *c.PyObject) !Rgba {
    const r = extractColorAttribute(obj, "r") orelse return error.InvalidColor;
    const g = extractColorAttribute(obj, "g") orelse return error.InvalidColor;
    const b = extractColorAttribute(obj, "b") orelse return error.InvalidColor;
    const a = extractColorAttribute(obj, "a") orelse return error.InvalidColor;

    return .{
        .r = @intCast(r),
        .g = @intCast(g),
        .b = @intCast(b),
        .a = @intCast(a),
    };
}

/// Generic color parsing function that converts Python color objects to the specified type.
/// Supported target types: u8 (grayscale), Rgb, Rgba
///
/// Supported input formats:
/// - Integer (0-255): Interpreted as grayscale, converted to target type
/// - Tuple of 3 ints: RGB values, converted to target type
/// - Tuple of 4 ints: RGBA values, converted to target type
/// - Color object with appropriate conversion method (to_gray, to_rgb, to_rgba)
/// - Color object with r,g,b[,a] attributes
///
/// On error, sets one of these Python exceptions:
/// - TypeError: For invalid input types
/// - ValueError: For out-of-range color values (not 0-255)
pub fn parseColor(comptime T: type, color_obj: ?*c.PyObject) !T {
    if (color_obj == null) {
        return error.InvalidColor;
    }

    // Determine the conversion method name based on target type
    const method_name = switch (T) {
        u8 => "to_gray",
        Rgb => "to_rgb",
        Rgba => "to_rgba",
        else => @compileError("Unsupported color type: " ++ @typeName(T)),
    };

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

        // Convert grayscale to target type
        return switch (T) {
            u8 => @intCast(gray_value),
            Rgb => Rgb{
                .r = @intCast(gray_value),
                .g = @intCast(gray_value),
                .b = @intCast(gray_value),
            },
            Rgba => Rgba{
                .r = @intCast(gray_value),
                .g = @intCast(gray_value),
                .b = @intCast(gray_value),
                .a = 255,
            },
            else => unreachable,
        };
    }

    // Check if it's a tuple
    if (c.PyTuple_Check(color_obj) != 0) {
        const rgba = try parseColorTuple(color_obj);
        // Convert RGBA to target type
        return switch (T) {
            u8 => rgba.toGray(),
            Rgb => rgba.toRgb(),
            Rgba => rgba,
            else => unreachable,
        };
    }

    // Check if it has the appropriate conversion method (duck typing)
    const method_str = c.PyUnicode_FromString(method_name);
    defer c.Py_DECREF(method_str);

    if (c.PyObject_HasAttr(color_obj, method_str) != 0) {
        // Call the conversion method
        const result_obj = c.PyObject_CallMethodObjArgs(color_obj, method_str, @as(?*c.PyObject, null));
        if (result_obj == null) {
            return error.InvalidColor;
        }
        defer c.Py_DECREF(result_obj);

        // Extract value based on target type
        return switch (T) {
            u8 => blk: {
                const gray_value = c.PyLong_AsLong(result_obj);
                if (gray_value == -1 and c.PyErr_Occurred() != null) {
                    c.PyErr_SetString(c.PyExc_TypeError, "to_gray() must return an integer");
                    return error.InvalidColor;
                }
                if (gray_value < 0 or gray_value > 255) {
                    c.PyErr_SetString(c.PyExc_ValueError, "Gray value must be in range 0-255");
                    return error.InvalidColor;
                }
                break :blk @intCast(gray_value);
            },
            Rgb => try extractRgbFromObject(result_obj),
            Rgba => try extractRgbaFromObject(result_obj),
            else => unreachable,
        };
    }

    // Try to extract RGB/RGBA values directly from the object
    const extract_result = switch (T) {
        u8 => blk: {
            // For grayscale, try to extract RGB and convert to gray
            if (extractRgbFromObject(color_obj.?)) |rgb| {
                break :blk rgb.toGray();
            } else |_| {
                c.PyErr_Clear();
                break :blk error.InvalidColor;
            }
        },
        Rgb => extractRgbFromObject(color_obj.?),
        Rgba => extractRgbaFromObject(color_obj.?),
        else => unreachable,
    };

    if (extract_result) |result| {
        return result;
    } else |_| {
        // Clear any Python error that might have been set by failed attribute access
        c.PyErr_Clear();
    }

    // Set appropriate error message based on target type
    const error_msg = switch (T) {
        u8 => "Color must be an integer (0-255), a tuple of RGB values, or a color object with to_gray() method or r,g,b attributes",
        Rgb => "Color must be an integer (0-255), a tuple of (r, g, b) or (r, g, b, a), or a color object with to_rgb() method or r,g,b attributes",
        Rgba => "Color must be an integer (0-255), a tuple of (r, g, b) or (r, g, b, a), or a color object with to_rgba() method or r,g,b,a attributes",
        else => unreachable,
    };
    c.PyErr_SetString(c.PyExc_TypeError, error_msg);
    return error.InvalidColor;
}

/// Parse a Python tuple representing a color (RGB or RGBA).
/// Returns a Rgba color with values in range 0-255.
/// This is a helper function used by parseColorTo.
///
/// Sets Python exception messages on error:
/// - ValueError: If tuple size is not 3 or 4
/// - TypeError: If tuple elements are not integers
/// - ValueError: If color values are out of range (0-255)
pub fn parseColorTuple(color_obj: ?*c.PyObject) !Rgba {
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

    return Rgba{
        .r = @intCast(r),
        .g = @intCast(g),
        .b = @intCast(b),
        .a = @intCast(a),
    };
}

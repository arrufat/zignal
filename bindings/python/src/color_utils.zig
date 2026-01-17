const python = @import("python.zig");
const c = python.c;
const zignal = @import("zignal");

const color = @import("color.zig");

const Gray = zignal.Gray(u8);
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);
const Hsl = zignal.Hsl(f64);
const Hsv = zignal.Hsv(f64);
const Lab = zignal.Lab(f64);
const Lch = zignal.Lch(f64);
const Lms = zignal.Lms(f64);
const Oklab = zignal.Oklab(f64);
const Oklch = zignal.Oklch(f64);
const Xyb = zignal.Xyb(f64);
const Xyz = zignal.Xyz(f64);
const Ycbcr = zignal.Ycbcr(u8);

const zignalColorTypes = .{
    .{ .py_type = &color.gray, .zig_type = Gray, .binding = color.GrayBinding },
    .{ .py_type = &color.rgb, .zig_type = Rgb, .binding = color.RgbBinding },
    .{ .py_type = &color.rgba, .zig_type = Rgba, .binding = color.RgbaBinding },
    .{ .py_type = &color.hsl, .zig_type = Hsl, .binding = color.HslBinding },
    .{ .py_type = &color.hsv, .zig_type = Hsv, .binding = color.HsvBinding },
    .{ .py_type = &color.lab, .zig_type = Lab, .binding = color.LabBinding },
    .{ .py_type = &color.lch, .zig_type = Lch, .binding = color.LchBinding },
    .{ .py_type = &color.lms, .zig_type = Lms, .binding = color.LmsBinding },
    .{ .py_type = &color.oklab, .zig_type = Oklab, .binding = color.OklabBinding },
    .{ .py_type = &color.oklch, .zig_type = Oklch, .binding = color.OklchBinding },
    .{ .py_type = &color.xyb, .zig_type = Xyb, .binding = color.XybBinding },
    .{ .py_type = &color.xyz, .zig_type = Xyz, .binding = color.XyzBinding },
    .{ .py_type = &color.ycbcr, .zig_type = Ycbcr, .binding = color.YcbcrBinding },
};

fn objectToZigColor(comptime ColorType: type, comptime Binding: type, obj: *c.PyObject) ColorType {
    const py_obj: *Binding.PyObjectType = @ptrCast(@alignCast(obj));
    const fields = @typeInfo(ColorType).@"struct".fields;

    if (comptime zignal.meta.isPacked(ColorType)) {
        comptime {
            for (fields) |field| {
                if (field.type != u8) @compileError("Packed color components must be u8");
            }
        }

        const bytes = switch (fields.len) {
            4 => [4]u8{ py_obj.field0, py_obj.field1, py_obj.field2, py_obj.field3 },
            3 => [3]u8{ py_obj.field0, py_obj.field1, py_obj.field2 },
            2 => [2]u8{ py_obj.field0, py_obj.field1 },
            1 => [1]u8{py_obj.field0},
            else => @compileError("Color types with more than 4 fields not supported"),
        };
        return @bitCast(bytes);
    }

    var zig_color: ColorType = undefined;
    inline for (fields, 0..) |field, i| {
        const field_value = switch (i) {
            0 => py_obj.field0,
            1 => py_obj.field1,
            2 => py_obj.field2,
            3 => py_obj.field3,
            else => unreachable,
        };
        @field(zig_color, field.name) = field_value;
    }
    return zig_color;
}

fn parseFromZignalColorTypes(comptime T: type, color_obj: *c.PyObject) ?T {
    const obj_c: [*c]c.PyObject = @ptrCast(color_obj);

    inline for (zignalColorTypes) |color_info| {
        const type_ptr: [*c]c.PyTypeObject = @ptrCast(color_info.py_type);
        if (c.PyObject_TypeCheck(obj_c, type_ptr) != 0) {
            const zig_color = objectToZigColor(color_info.zig_type, color_info.binding, color_obj);
            return zignal.convertColor(T, zig_color);
        }
    }

    return null;
}

fn tryParseViaToMethod(comptime T: type, color_obj: *c.PyObject) !?T {
    const method = c.PyObject_GetAttrString(color_obj, "to");
    if (method == null) {
        if (c.PyErr_Occurred() != null) c.PyErr_Clear();
        return null;
    }
    defer c.Py_DECREF(method);

    const target_type_obj: *c.PyTypeObject = switch (T) {
        u8 => &color.gray,
        Rgb => &color.rgb,
        Rgba => &color.rgba,
        else => unreachable,
    };

    const args = c.PyTuple_New(1);
    if (args == null) return error.InvalidColor;
    defer c.Py_DECREF(args);

    // PyTuple_SetItem steals a reference, so INCREF first.
    // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(target_type_obj)));
    if (c.PyTuple_SetItem(args, 0, @ptrCast(target_type_obj)) < 0) {
        return error.InvalidColor;
    }

    const converted = c.PyObject_CallObject(method, args);
    if (converted == null) {
        // Leave the Python exception set by the conversion method.
        return error.InvalidColor;
    }
    defer c.Py_DECREF(converted);

    return switch (T) {
        u8 => blk: {
            const y_val = extractColorAttribute(converted, "y") orelse {
                c.PyErr_SetString(c.PyExc_TypeError, "Converted Gray color is missing 'y' attribute");
                return error.InvalidColor;
            };
            break :blk try python.validateRange(u8, y_val, 0, 255, "y");
        },
        Rgb => try extractRgbFromObject(converted),
        Rgba => try extractRgbaFromObject(converted),
        else => unreachable,
    };
}

/// Extract color component attribute from a Python object.
/// This is a helper function used internally.
/// Returns null if the attribute doesn't exist or isn't a valid integer.
/// Note: This function does NOT set Python exceptions.
fn extractColorAttribute(obj: *c.PyObject, name: [*c]const u8) ?c_long {
    const attr = c.PyObject_GetAttrString(obj, name);
    if (attr == null) return null;
    defer c.Py_DECREF(attr);

    return python.parse(c_long, attr) catch null;
}

/// Extract RGB values from a Python object with r,g,b attributes.
/// This is a helper function used internally.
/// Returns error.InvalidColor if the object doesn't have the required attributes
/// or if the attribute values cannot be converted to integers.
/// Returns error.OutOfRange if values are not in 0-255 range.
fn extractRgbFromObject(obj: *c.PyObject) !Rgb {
    const r_val = extractColorAttribute(obj, "r") orelse return error.InvalidColor;
    const g_val = extractColorAttribute(obj, "g") orelse return error.InvalidColor;
    const b_val = extractColorAttribute(obj, "b") orelse return error.InvalidColor;

    const r = python.validateRange(u8, r_val, 0, 255, "r") catch return error.OutOfRange;
    const g = python.validateRange(u8, g_val, 0, 255, "g") catch return error.OutOfRange;
    const b = python.validateRange(u8, b_val, 0, 255, "b") catch return error.OutOfRange;

    return Rgb{
        .r = r,
        .g = g,
        .b = b,
    };
}

/// Extract RGBA values from a Python object with r,g,b,a attributes.
/// This is a helper function used internally.
/// Returns error.InvalidColor if the object doesn't have the required attributes
/// or if the attribute values cannot be converted to integers.
/// Returns error.OutOfRange if values are not in 0-255 range.
fn extractRgbaFromObject(obj: *c.PyObject) !Rgba {
    const rgb = try extractRgbFromObject(obj);
    const a_val = extractColorAttribute(obj, "a") orelse return error.InvalidColor;
    const a = try python.validateRange(u8, a_val, 0, 255, "a");

    return .{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
        .a = a,
    };
}

/// Generic color parsing function that converts Python color objects to the specified type.
/// Supported target types: u8 (grayscale), Rgb, Rgba
///
/// Supported input formats:
/// - Integer (0-255): Interpreted as grayscale, converted to target type
/// - Tuple of 3 ints: RGB values, converted to target type
/// - Tuple of 4 ints: RGBA values, converted to target type
/// - Color object with appropriate conversion method (to_rgb, to_rgba)
/// - Color object with r,g,b[,a] attributes
///
/// On error, sets one of these Python exceptions:
/// - TypeError: For invalid input types
/// - ValueError: For out-of-range color values (not 0-255)
pub fn parseColor(comptime T: type, color_obj: ?*c.PyObject) !T {
    if (color_obj == null) {
        return error.InvalidColor;
    }

    // If this is one of our bound color types, accept any colorspace and convert.
    if (parseFromZignalColorTypes(T, color_obj.?)) |converted| {
        return converted;
    }

    // Check if it's an integer (grayscale)
    if (c.PyLong_Check(color_obj) != 0) {
        const gray_value = python.parse(c_long, color_obj) catch return error.InvalidColor;

        if (gray_value < 0 or gray_value > 255) {
            c.PyErr_SetString(c.PyExc_ValueError, "Gray value must be in range 0-255");
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
            u8 => rgba.to(.gray).y,
            Rgb => rgba.to(.rgb),
            Rgba => rgba,
            else => unreachable,
        };
    }

    // Fall back to calling `.to(zignal.<Target>)` when available (supports all colorspaces).
    if (try tryParseViaToMethod(T, color_obj.?)) |via_to| {
        return via_to;
    }

    // Try to extract RGB/RGBA values directly from the object
    const extract_result = switch (T) {
        u8 => blk: {
            // For grayscale, try to extract RGB and convert to gray
            if (extractRgbFromObject(color_obj.?)) |rgb| {
                break :blk rgb.to(.gray).y;
            } else |err| {
                if (err == error.OutOfRange) return err;
                c.PyErr_Clear();
                break :blk error.InvalidColor;
            }
        },
        Rgb => blk: {
            if (extractRgbFromObject(color_obj.?)) |rgb| {
                break :blk rgb;
            } else |err| {
                if (err == error.OutOfRange) return err;
                c.PyErr_Clear();
                break :blk error.InvalidColor;
            }
        },
        Rgba => blk: {
            if (extractRgbaFromObject(color_obj.?)) |rgba| {
                break :blk rgba;
            } else |err| {
                if (err == error.OutOfRange) return err;
                c.PyErr_Clear();
                // Accept RGB-like objects by adding full alpha
                const rgb = extractRgbFromObject(color_obj.?) catch |err2| {
                    if (err2 == error.OutOfRange) return err2;
                    c.PyErr_Clear();
                    break :blk error.InvalidColor;
                };
                break :blk Rgba{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 };
            }
        },
        else => unreachable,
    };

    if (extract_result) |result| {
        return result;
    } else |err| {
        // Clear any Python error that might have been set by failed attribute access
        // Only if no specific error was propagated
        if (err == error.OutOfRange) return err;
        if (c.PyErr_Occurred() != null) c.PyErr_Clear();
    }

    // Set appropriate error message based on target type
    const error_msg = switch (T) {
        u8 => "Color must be an integer (0-255), a tuple of RGB values, or an object with r,g,b attributes",
        Rgb => "Color must be an integer (0-255), a tuple of (r, g, b) or (r, g, b, a), or an object with r,g,b attributes",
        Rgba => "Color must be an integer (0-255), a tuple of (r, g, b) or (r, g, b, a), or an object with r,g,b,a attributes",
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
    r = python.parse(c_long, r_obj) catch return error.InvalidColor;

    // Get G
    const g_obj = c.PyTuple_GetItem(color_obj, 1);
    g = python.parse(c_long, g_obj) catch return error.InvalidColor;

    // Get B
    const b_obj = c.PyTuple_GetItem(color_obj, 2);
    b = python.parse(c_long, b_obj) catch return error.InvalidColor;

    // Get A if present
    if (size == 4) {
        const a_obj = c.PyTuple_GetItem(color_obj, 3);
        a = python.parse(c_long, a_obj) catch return error.InvalidColor;
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

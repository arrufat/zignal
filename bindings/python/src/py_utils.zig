const std = @import("std");
pub const allocator = std.heap.c_allocator;

const zignal = @import("zignal");
const Point = zignal.Point;

pub const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

/// Helper to register a type with a module
pub fn registerType(module: [*c]c.PyObject, comptime name: []const u8, type_obj: *c.PyTypeObject) !void {
    if (c.PyType_Ready(type_obj) < 0) return error.TypeInitFailed;

    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(type_obj)));
    if (c.PyModule_AddObject(module, name.ptr, @as(?*c.PyObject, @ptrCast(type_obj))) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(type_obj)));
        return error.TypeAddFailed;
    }
}

/// Get Python boolean singletons using the stable Python C API
pub fn getPyBool(value: bool) [*c]c.PyObject {
    return c.PyBool_FromLong(@intFromBool(value));
}

/// Helper to return Python None
pub fn getPyNone() ?*c.PyObject {
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

/// Convert a Zig value to Python object
pub fn convertToPython(value: anytype) ?*c.PyObject {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .unsigned)
            c.PyLong_FromUnsignedLong(value)
        else
            c.PyLong_FromLong(value),
        .float => c.PyFloat_FromDouble(value),
        .bool => @ptrCast(getPyBool(value)),
        .pointer => |ptr| blk: {
            if (ptr.size == .Slice and ptr.child == u8) {
                break :blk c.PyUnicode_FromStringAndSize(value.ptr, @intCast(value.len));
            }
            break :blk null;
        },
        .array => |arr| blk: {
            if (arr.child == u8) {
                break :blk c.PyUnicode_FromStringAndSize(&value[0], @intCast(arr.len));
            }
            break :blk null;
        },
        .optional => blk: {
            if (value) |v| {
                break :blk convertToPython(v);
            } else {
                c.Py_INCREF(c.Py_None);
                break :blk c.Py_None;
            }
        },
        else => null,
    };
}

/// Error set for conversion failures
pub const ConversionError = error{
    not_python_object,
    not_integer,
    not_float,
    integer_out_of_range,
    float_out_of_range,
    unsupported_type,
};

/// Convert Python value to Zig type using idiomatic error union
pub fn convertFromPython(comptime T: type, py_obj: ?*c.PyObject) ConversionError!T {
    if (py_obj == null) {
        return ConversionError.not_python_object;
    }

    return switch (@typeInfo(T)) {
        .int => blk: {
            // Always use PyLong_AsLong for better negative value handling
            const val = c.PyLong_AsLong(py_obj);
            if (val == -1 and c.PyErr_Occurred() != null) {
                c.PyErr_Clear(); // Clear the Python error since we're handling it
                break :blk ConversionError.not_integer;
            }

            // Check if value fits in target type
            const min_val = std.math.minInt(T);
            const max_val = std.math.maxInt(T);
            if (val < min_val or val > max_val) {
                break :blk ConversionError.integer_out_of_range;
            }
            break :blk @intCast(val);
        },
        .float => blk: {
            const val = c.PyFloat_AsDouble(py_obj);
            if (val == -1.0 and c.PyErr_Occurred() != null) {
                c.PyErr_Clear(); // Clear the Python error since we're handling it
                break :blk ConversionError.not_float;
            }
            break :blk @floatCast(val);
        },
        else => ConversionError.unsupported_type,
    };
}

/// Convert Python object to Zig type with comprehensive error handling
/// This is a general-purpose utility for safe Python argument parsing
pub fn convertPythonArgument(comptime T: type, py_obj: ?*c.PyObject, field_name: []const u8) ConversionError!T {
    const converted = convertFromPython(T, py_obj) catch |err| {
        switch (err) {
            ConversionError.not_integer => {
                c.PyErr_SetString(c.PyExc_TypeError, "Expected integer value");
                return err;
            },
            ConversionError.integer_out_of_range => {
                // Generate helpful range message for integer types
                if (@typeInfo(T) == .int) {
                    const min_val = std.math.minInt(T);
                    const max_val = std.math.maxInt(T);
                    var buffer: [256]u8 = undefined;
                    const msg = std.fmt.bufPrintZ(&buffer, "{s} value is out of range for {s} (valid range: {} to {})", .{ field_name, @typeName(T), min_val, max_val }) catch "Value out of range";
                    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                } else {
                    c.PyErr_SetString(c.PyExc_ValueError, "Value out of range");
                }
                return err;
            },
            ConversionError.not_float => {
                c.PyErr_SetString(c.PyExc_TypeError, "Expected float value");
                return err;
            },
            else => {
                c.PyErr_SetString(c.PyExc_TypeError, "Unsupported value type");
                return err;
            },
        }
    };

    return converted;
}

/// Convert Python object to Zig type with optional custom validation
/// This provides a flexible foundation for domain-specific argument parsing
pub fn convertWithValidation(
    comptime T: type,
    py_obj: ?*c.PyObject,
    field_name: []const u8,
    comptime validator: ?*const fn (field_name: []const u8, value: anytype) bool,
    error_message: ?[]const u8,
) ConversionError!T {
    // First do the basic type conversion
    const converted = convertPythonArgument(T, py_obj, field_name) catch |err| {
        return err;
    };

    // Then apply custom validation if provided
    if (validator) |validate_fn| {
        if (!validate_fn(field_name, converted)) {
            const msg = error_message orelse "Validation failed";
            c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
            return ConversionError.integer_out_of_range; // Reuse existing error type
        }
    }

    return converted;
}

/// Parse a Python tuple representing a 2D point (x, y)
/// Returns a Point(2, T) where T can be f32 or f64
pub fn parsePointTuple(comptime T: type, point_obj: ?*c.PyObject) !Point(2, T) {
    if (point_obj == null) {
        return error.InvalidPoint;
    }

    // Check if it's a tuple
    if (c.PyTuple_Check(point_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Point must be a tuple of (x, y)");
        return error.InvalidPoint;
    }

    const size = c.PyTuple_Size(point_obj);
    if (size != 2) {
        c.PyErr_SetString(c.PyExc_ValueError, "Point tuple must have exactly 2 elements");
        return error.InvalidPoint;
    }

    // Extract x and y coordinates
    const x_obj = c.PyTuple_GetItem(point_obj, 0);
    const x = c.PyFloat_AsDouble(x_obj);
    if (x == -1.0 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Point coordinates must be numbers");
        return error.InvalidPoint;
    }

    const y_obj = c.PyTuple_GetItem(point_obj, 1);
    const y = c.PyFloat_AsDouble(y_obj);
    if (y == -1.0 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Point coordinates must be numbers");
        return error.InvalidPoint;
    }

    return .point(.{ @as(T, @floatCast(x)), @as(T, @floatCast(y)) });
}

/// Parse a Python tuple representing a rectangle (left, top, right, bottom)
/// Returns a Rectangle(T) where T can be any numeric type
pub fn parseRectangleTuple(comptime T: type, tuple_obj: ?*c.PyObject) !zignal.Rectangle(T) {
    if (tuple_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle tuple is null");
        return error.InvalidRectangle;
    }

    // Check if it's a tuple
    if (c.PyTuple_Check(tuple_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle must be a tuple of (left, top, right, bottom)");
        return error.InvalidRectangle;
    }

    const size = c.PyTuple_Size(tuple_obj);
    if (size != 4) {
        c.PyErr_SetString(c.PyExc_ValueError, "Rectangle tuple must have exactly 4 elements (left, top, right, bottom)");
        return error.InvalidRectangle;
    }

    // Extract all four coordinates
    const left_obj = c.PyTuple_GetItem(tuple_obj, 0);
    const left = c.PyFloat_AsDouble(left_obj);
    if (left == -1.0 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle tuple elements must be numbers");
        return error.InvalidRectangle;
    }

    const top_obj = c.PyTuple_GetItem(tuple_obj, 1);
    const top = c.PyFloat_AsDouble(top_obj);
    if (top == -1.0 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle tuple elements must be numbers");
        return error.InvalidRectangle;
    }

    const right_obj = c.PyTuple_GetItem(tuple_obj, 2);
    const right = c.PyFloat_AsDouble(right_obj);
    if (right == -1.0 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle tuple elements must be numbers");
        return error.InvalidRectangle;
    }

    const bottom_obj = c.PyTuple_GetItem(tuple_obj, 3);
    const bottom = c.PyFloat_AsDouble(bottom_obj);
    if (bottom == -1.0 and c.PyErr_Occurred() != null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle tuple elements must be numbers");
        return error.InvalidRectangle;
    }

    // Convert to target type and return
    const info = @typeInfo(T);
    if (info == .float) {
        return zignal.Rectangle(T).init(
            @as(T, @floatCast(left)),
            @as(T, @floatCast(top)),
            @as(T, @floatCast(right)),
            @as(T, @floatCast(bottom)),
        );
    } else {
        // For integer types, truncate the float values
        return zignal.Rectangle(T).init(
            @as(T, @intFromFloat(left)),
            @as(T, @intFromFloat(top)),
            @as(T, @intFromFloat(right)),
            @as(T, @intFromFloat(bottom)),
        );
    }
}

/// Parse a Rectangle object or tuple to Zignal Rectangle(T)
/// Accepts either a Rectangle instance or a tuple of (left, top, right, bottom)
pub fn parseRectangle(comptime T: type, rect_obj: ?*c.PyObject) !zignal.Rectangle(T) {
    const rectangle = @import("rectangle.zig");

    if (rect_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Rectangle object is null");
        return error.InvalidRectangle;
    }

    // Check if it's a tuple first
    if (c.PyTuple_Check(rect_obj) != 0) {
        return parseRectangleTuple(T, rect_obj);
    }

    // Check if it's a Rectangle instance
    if (c.PyObject_IsInstance(rect_obj, @ptrCast(&rectangle.RectangleType)) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Object must be a Rectangle instance or a tuple of (left, top, right, bottom)");
        return error.InvalidRectangle;
    }

    const rect = @as(*rectangle.RectangleObject, @ptrCast(rect_obj.?));
    // Handle integer vs float types
    const info = @typeInfo(T);
    return switch (info) {
        .int => zignal.Rectangle(T).init(@as(T, @intFromFloat(rect.left)), @as(T, @intFromFloat(rect.top)), @as(T, @intFromFloat(rect.right)), @as(T, @intFromFloat(rect.bottom))),
        .float => zignal.Rectangle(T).init(@as(T, @floatCast(rect.left)), @as(T, @floatCast(rect.top)), @as(T, @floatCast(rect.right)), @as(T, @floatCast(rect.bottom))),
        else => @compileError("Rectangle type must be integer or float"),
    };
}

/// Parse a Python list of point tuples to an allocated slice of Point(2, T)
pub fn parsePointList(comptime T: type, list_obj: ?*c.PyObject) ![]Point(2, T) {
    if (list_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Points list is null");
        return error.InvalidPointList;
    }

    // Check if it's a list or tuple
    const is_list = c.PyList_Check(list_obj) != 0;
    const is_tuple = c.PyTuple_Check(list_obj) != 0;

    if (!is_list and !is_tuple) {
        c.PyErr_SetString(c.PyExc_TypeError, "Points must be a list or tuple of (x, y) tuples");
        return error.InvalidPointList;
    }

    const size = if (is_list) c.PyList_Size(list_obj) else c.PyTuple_Size(list_obj);
    if (size < 0) {
        return error.InvalidPointList;
    }

    // Allocate memory for points
    const points = allocator.alloc(Point(2, T), @intCast(size)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate memory for points");
        return error.OutOfMemory;
    };
    errdefer allocator.free(points);

    // Parse each point
    for (0..@intCast(size)) |i| {
        const item = if (is_list)
            c.PyList_GetItem(list_obj, @intCast(i))
        else
            c.PyTuple_GetItem(list_obj, @intCast(i));

        points[i] = parsePointTuple(T, item) catch {
            return error.InvalidPointList;
        };
    }

    return points;
}

/// Convert a Point(2, f64) back to a Python tuple
pub fn pointToTuple(point: Point(2, f64)) ?*c.PyObject {
    return c.PyTuple_Pack(2, c.PyFloat_FromDouble(point.x()), c.PyFloat_FromDouble(point.y()));
}

/// Set a Python exception with an error message that includes a file path.
/// Maps common errors to appropriate Python exception types.
pub fn setErrorWithPath(err: anyerror, path: []const u8) void {
    // Map only the most important Zig errors to Python exception types
    const exc_type = switch (err) {
        error.FileNotFound => c.PyExc_FileNotFoundError,

        error.AccessDenied,
        error.PermissionDenied,
        => c.PyExc_PermissionError,

        error.UnsupportedImageFormat,
        error.UnsupportedFontFormat,
        => c.PyExc_ValueError,

        error.OutOfMemory => c.PyExc_MemoryError,

        // Default to IOError for all other errors
        else => c.PyExc_IOError,
    };

    // Format error message with path and error name for debugging
    var buffer: [std.fs.max_path_bytes + 128]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buffer, "Could not open file '{s}': {s}", .{ path, @errorName(err) }) catch "Could not open file";
    c.PyErr_SetString(exc_type, msg.ptr);
}

/// Generic range validation that works with both integers and floats
pub fn validateRange(comptime T: type, value: anytype, min: T, max: T, name: []const u8) !T {
    const ValueType = @TypeOf(value);

    // Special handling for signed to unsigned conversion
    const info = @typeInfo(T);
    if (info == .int and info.int.signedness == .unsigned) {
        // If target is unsigned and value is signed, check for negative first
        if (ValueType == c_long or ValueType == c_int) {
            if (value < 0) {
                var buffer: [256]u8 = undefined;
                const msg = if (min == 0)
                    std.fmt.bufPrintZ(&buffer, "{s} must be non-negative", .{name}) catch "Value out of range"
                else if (min == 1)
                    std.fmt.bufPrintZ(&buffer, "{s} must be positive", .{name}) catch "Value out of range"
                else
                    std.fmt.bufPrintZ(&buffer, "{s} must be at least {}", .{ name, min }) catch "Value out of range";
                c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                return error.OutOfRange;
            }
        }
    }

    // Check range before converting to avoid truncation issues with @intCast
    switch (ValueType) {
        c_long, c_int => {
            // For integer types, check range using the original value
            if (value < min or value > max) {
                var buffer: [256]u8 = undefined;
                const msg = blk: {
                    // For infinity or max integer values, simplify the message
                    if (info == .float and std.math.isInf(max)) {
                        break :blk std.fmt.bufPrintZ(&buffer, "{s} must be at least {}", .{ name, min }) catch "Value out of range";
                    } else if (info == .int and max == std.math.maxInt(T) and T != u8) {
                        // Don't simplify for u8 since 255 is often a specific limit (e.g., color values)
                        if (min == 0) {
                            break :blk std.fmt.bufPrintZ(&buffer, "{s} must be non-negative", .{name}) catch "Value out of range";
                        } else if (min == 1) {
                            break :blk std.fmt.bufPrintZ(&buffer, "{s} must be positive", .{name}) catch "Value out of range";
                        } else {
                            break :blk std.fmt.bufPrintZ(&buffer, "{s} must be at least {}", .{ name, min }) catch "Value out of range";
                        }
                    } else {
                        break :blk std.fmt.bufPrintZ(&buffer, "{s} must be between {} and {}", .{ name, min, max }) catch "Value out of range";
                    }
                };
                c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                return error.OutOfRange;
            }
        },
        f64 => {
            const min_f64 = if (info == .float) @as(f64, min) else @as(f64, @floatFromInt(min));
            const max_f64 = if (info == .float) @as(f64, max) else @as(f64, @floatFromInt(max));
            if (value < min_f64 or value > max_f64) {
                var buffer: [256]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buffer, "{s} must be between {} and {}", .{ name, min, max }) catch "Value out of range";
                c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                return error.OutOfRange;
            }
        },
        else => @compileError("Unsupported value type"),
    }

    // Now convert after range check
    const converted = switch (ValueType) {
        c_long, c_int => blk: {
            if (info == .float) {
                break :blk @as(T, @floatFromInt(value));
            } else {
                break :blk @as(T, @intCast(value));
            }
        },
        f64 => @as(T, @floatCast(value)),
        else => unreachable,
    };

    return converted;
}

/// Convenience function for non-negative values
pub fn validateNonNegative(comptime T: type, value: anytype, name: []const u8) !T {
    const info = @typeInfo(T);
    const max = if (info == .float) std.math.inf(T) else std.math.maxInt(T);
    return validateRange(T, value, 0, max, name);
}

/// Validate that a pointer is not null, with a custom error message
pub fn validateNonNull(comptime T: type, ptr: ?T, name: []const u8) !T {
    if (ptr == null) {
        var buffer: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buffer, "{s} not initialized", .{name}) catch "Value is null";
        c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
        return error.NullPointer;
    }
    return ptr.?;
}

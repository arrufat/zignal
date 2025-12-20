const std = @import("std");
const builtin = @import("builtin");

// Python embeds long-lived objects (module singletons, pytest fixtures), so
// running the DebugAllocator at shutdown produces noisy "leaks". Use c_allocator
// for the Python bindings to keep teardown clean.
const use_debug_allocator = false;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub const allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;

pub fn deinitAllocator() void {
    if (use_debug_allocator) {
        // Ignore LeakSummary; we just want to surface problems during shutdown.
        _ = debug_allocator.deinit();
    }
}

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
            c.PyLong_FromUnsignedLongLong(@as(
                @typeInfo(@TypeOf(c.PyLong_FromUnsignedLongLong)).@"fn".params[0].type.?,
                @intCast(value),
            ))
        else
            c.PyLong_FromLongLong(@as(
                @typeInfo(@TypeOf(c.PyLong_FromLongLong)).@"fn".params[0].type.?,
                @intCast(value),
            )),
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

/// Wrapper for arguments tuple ownership. If `owned` is true, `tuple` must be decref'd.
pub const ArgsTupleHandle = struct {
    tuple: ?*c.PyObject,
    owned: bool,

    pub fn deinit(self: ArgsTupleHandle) void {
        if (self.owned and self.tuple != null) {
            c.Py_DECREF(self.tuple.?);
        }
    }
};

/// Ensure we always have a tuple for varargs-style APIs.
/// Returns a handle describing whether the tuple is newly allocated (thus owned).
pub fn ensureArgsTuple(args: ?*c.PyObject) ?ArgsTupleHandle {
    if (args) |existing| {
        return ArgsTupleHandle{ .tuple = existing, .owned = false };
    }

    const empty = c.PyTuple_New(0);
    if (empty == null) return null;
    return ArgsTupleHandle{ .tuple = empty, .owned = true };
}

/// Call an object's method borrowing the provided args tuple.
pub fn callMethodBorrowingArgs(target: ?*c.PyObject, method_name: [*c]const u8, args: ?*c.PyObject) ?*c.PyObject {
    if (target == null or args == null) return null;

    const method_ptr = c.PyObject_GetAttrString(target.?, method_name);
    if (method_ptr == null) return null;
    defer c.Py_DECREF(method_ptr);

    return c.PyObject_CallObject(method_ptr, args.?);
}

/// Call an object's method, automatically creating an empty args tuple when needed.
pub fn callMethod(target: ?*c.PyObject, method_name: [*c]const u8, args: ?*c.PyObject) ?*c.PyObject {
    const handle = ensureArgsTuple(args) orelse return null;
    defer handle.deinit();
    return callMethodBorrowingArgs(target, method_name, handle.tuple);
}

/// Build a `(row, col, pixel)` tuple while consuming the pixel reference.
pub fn buildPixelTuple(row: usize, col: usize, pixel_obj: ?*c.PyObject) ?*c.PyObject {
    if (pixel_obj == null) return null;
    return c.Py_BuildValue("(nnN)", @as(c.Py_ssize_t, @intCast(row)), @as(c.Py_ssize_t, @intCast(col)), pixel_obj.?);
}

/// Build a field getter function pointer for a Python-exposed struct.
/// The returned pointer matches Python's `getter` signature and uses
/// `convertToPython` to return a new Python object for the field value.
pub fn getterForField(comptime Obj: type, comptime field_name: []const u8) *const anyopaque {
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
            _ = closure;
            const self = @as(*Obj, @ptrCast(self_obj.?));
            const val = @field(self, field_name);
            return convertToPython(val);
        }
    };
    return @ptrCast(&Gen.get);
}

/// Auto-generate a PyGetSetDef array for simple field-backed properties.
/// - Obj: the Python object struct type (e.g., RectangleObject)
/// - field_names: comptime list of field names to expose (e.g., &.{"left", "top"})
/// Returns an array with a trailing sentinel entry.
pub fn autoGetSet(
    comptime Obj: type,
    comptime field_names: []const []const u8,
) [field_names.len + 1]c.PyGetSetDef {
    comptime {
        var defs: [field_names.len + 1]c.PyGetSetDef = undefined;
        for (field_names, 0..) |fname, i| {
            defs[i] = .{
                .name = fname.ptr,
                .get = @ptrCast(@alignCast(getterForField(Obj, fname))),
                .set = null,
                .doc = null,
                .closure = null,
            };
        }
        defs[field_names.len] = .{ .name = null, .get = null, .set = null, .doc = null, .closure = null };
        return defs;
    }
}

/// Create PyGetSetDef array with auto-generated field getters plus custom entries.
/// This eliminates the need for manual array copying when combining autoGetSet with custom getters.
/// - Obj: the Python object struct type
/// - field_names: comptime list of field names to auto-generate getters for
/// - custom: comptime array of custom PyGetSetDef entries (without sentinel)
/// Returns a combined array with auto-generated + custom + sentinel.
///
/// Example usage:
/// ```zig
/// const getset = py_utils.autoGetSetCustom(RectangleObject, &.{"left", "top", "right", "bottom"}, &[_]c.PyGetSetDef{
///     .{ .name = "width", .get = @ptrCast(&rectangle_get_width), .set = null, .doc = "Width", .closure = null },
///     .{ .name = "height", .get = @ptrCast(&rectangle_get_height), .set = null, .doc = "Height", .closure = null },
/// });
/// ```
pub fn autoGetSetCustom(
    comptime Obj: type,
    comptime field_names: []const []const u8,
    comptime custom: []const c.PyGetSetDef,
) [field_names.len + custom.len + 1]c.PyGetSetDef {
    comptime {
        var result: [field_names.len + custom.len + 1]c.PyGetSetDef = undefined;

        // Add auto-generated field getters
        for (field_names, 0..) |fname, i| {
            result[i] = .{
                .name = fname.ptr,
                .get = @ptrCast(@alignCast(getterForField(Obj, fname))),
                .set = null,
                .doc = null,
                .closure = null,
            };
        }

        // Add custom getters
        for (custom, 0..) |custom_def, i| {
            result[field_names.len + i] = custom_def;
        }

        // Add sentinel
        result[field_names.len + custom.len] = .{ .name = null, .get = null, .set = null, .doc = null, .closure = null };

        return result;
    }
}

/// Build a getter that returns an optional field: the field value if Predicate(self) is true,
/// otherwise Python None. Useful when a field is only meaningful under certain modes.
pub fn getterOptionalFieldWhere(
    comptime Obj: type,
    comptime field_name: []const u8,
    comptime Predicate: fn (*Obj) bool,
) *const anyopaque {
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            const self = @as(*Obj, @ptrCast(self_obj.?));
            if (!Predicate(self)) return getPyNone();
            const val = @field(self, field_name);
            return convertToPython(val);
        }
    };
    return @ptrCast(&Gen.get);
}

/// Build a getter for optional pointer fields, returning converter(value) or Python None.
pub fn getterOptionalPtr(
    comptime Obj: type,
    comptime field_name: []const u8,
    comptime converter: anytype,
) *const anyopaque {
    const field_index = std.meta.fieldIndex(Obj, field_name) orelse
        @compileError("Field '" ++ field_name ++ "' not found on type " ++ @typeName(Obj));
    const FieldType = std.meta.fields(Obj)[field_index].type;
    const opt_info = @typeInfo(FieldType);
    if (opt_info != .optional) {
        @compileError("Field '" ++ field_name ++ "' on type " ++ @typeName(Obj) ++ " must be optional");
    }
    const child_type = opt_info.optional.child;
    if (@typeInfo(child_type) != .pointer) {
        @compileError("Field '" ++ field_name ++ "' on type " ++ @typeName(Obj) ++ " must be an optional pointer");
    }

    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            const self = safeCast(Obj, self_obj);
            if (@field(self, field_name)) |ptr| {
                return converter(ptr);
            }
            return getPyNone();
        }
    };
    return @ptrCast(&Gen.get);
}

/// Build a getter that packs two fields into a tuple when Predicate(self) is true,
/// otherwise returns Python None. Uses Py_BuildValue with (NN) and steals references
/// of the intermediate objects created via convertToPython.
pub fn getterTuple2FieldsWhere(
    comptime Obj: type,
    comptime field0: []const u8,
    comptime field1: []const u8,
    comptime Predicate: fn (*Obj) bool,
) *const anyopaque {
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            const self = @as(*Obj, @ptrCast(self_obj.?));
            if (!Predicate(self)) return getPyNone();
            const a = convertToPython(@field(self, field0)) orelse return null;
            const b = convertToPython(@field(self, field1)) orelse {
                c.Py_DECREF(a);
                return null;
            };
            const tup = c.Py_BuildValue("(NN)", a, b);
            return tup; // steals references to a and b
        }
    };
    return @ptrCast(&Gen.get);
}

/// Build a getter that returns a 2-tuple from an array field's two indices.
/// Example: struct { bias: [2]f64 } → returns (bias[0], bias[1]).
pub fn getterTuple2FromArrayField(
    comptime Obj: type,
    comptime array_field: []const u8,
    comptime idx0: usize,
    comptime idx1: usize,
) *const anyopaque {
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            const self = @as(*Obj, @ptrCast(self_obj.?));
            const arr = @field(self, array_field);
            const a = convertToPython(arr[idx0]) orelse return null;
            const b = convertToPython(arr[idx1]) orelse {
                c.Py_DECREF(a);
                return null;
            };
            return c.Py_BuildValue("(NN)", a, b);
        }
    };
    return @ptrCast(&Gen.get);
}

/// Build a getter that returns a nested Python list from a fixed-size 2D array field.
/// Example: struct { matrix: [2][2]f64 } → returns [[a,b],[c,d]].
pub fn getterMatrixNested(
    comptime Obj: type,
    comptime field_name: []const u8,
    comptime rows: usize,
    comptime cols: usize,
) *const anyopaque {
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            const self = @as(*Obj, @ptrCast(self_obj.?));
            const mat = @field(self, field_name);

            const outer = c.PyList_New(@intCast(rows));
            if (outer == null) return null;

            var i: usize = 0;
            while (i < rows) : (i += 1) {
                const row_list = c.PyList_New(@intCast(cols));
                if (row_list == null) {
                    c.Py_DECREF(outer);
                    return null;
                }

                var j: usize = 0;
                while (j < cols) : (j += 1) {
                    const val_obj = convertToPython(mat[i][j]);
                    if (val_obj == null) {
                        c.Py_DECREF(row_list);
                        c.Py_DECREF(outer);
                        return null;
                    }
                    // PyList_SetItem steals reference to val_obj
                    _ = c.PyList_SetItem(row_list, @intCast(j), val_obj);
                }

                // PyList_SetItem steals reference to row_list
                _ = c.PyList_SetItem(outer, @intCast(i), row_list);
            }

            return outer;
        }
    };
    return @ptrCast(&Gen.get);
}

/// Build a getter that returns a constant string (new Python str on each call).
pub fn getterStaticString(comptime text: []const u8) *const anyopaque {
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            _ = self_obj;
            return c.PyUnicode_FromString(text.ptr);
        }
    };
    return @ptrCast(&Gen.get);
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

/// Convert a Python sequence (list/tuple) to a Zig ArrayList(T).
///
/// Arguments:
/// - T: The target element type.
/// - seq_obj: A Python object implementing the sequence protocol (list, tuple).
///
/// Returns:
/// - A std.ArrayList(T) containing the converted elements.
/// - The caller owns the memory and is responsible for calling `deinit()` on the returned list.
///
/// Errors:
/// - error.InvalidType: If `seq_obj` is null or not a sequence.
/// - error.PythonError: If a Python C-API call fails (e.g., getting an item).
/// - error.OutOfMemory: If memory allocation fails.
/// - ConversionError: If an element cannot be converted to type T.
pub fn listFromPython(comptime T: type, seq_obj: ?*c.PyObject) !std.ArrayList(T) {
    if (seq_obj == null) {
        c.PyErr_SetString(c.PyExc_TypeError, "Expected a sequence, got None");
        return error.InvalidType;
    }

    if (c.PySequence_Check(seq_obj) == 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Expected a sequence (list or tuple)");
        return error.InvalidType;
    }

    const size = c.PySequence_Size(seq_obj);
    if (size < 0) return error.PythonError;

    var list = std.ArrayList(T).init(allocator);
    errdefer list.deinit();
    try list.ensureTotalCapacity(@intCast(size));

    var i: usize = 0;
    while (i < size) : (i += 1) {
        const val = blk: {
            const item = c.PySequence_GetItem(seq_obj, @intCast(i)); // New reference
            if (item == null) return error.PythonError;
            defer c.Py_DECREF(item);
            break :blk try convertFromPython(T, item);
        };
        list.appendAssumeCapacity(val);
    }

    return list;
}

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
    const converted = convertFromPython(T, py_obj) catch |err| {
        switch (err) {
            ConversionError.not_integer => {
                c.PyErr_SetString(c.PyExc_TypeError, "Expected integer value");
                return err;
            },
            ConversionError.integer_out_of_range => {
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

    return .init(.{ @as(T, @floatCast(x)), @as(T, @floatCast(y)) });
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

pub fn PointPairs(comptime T: type) type {
    return struct {
        from_points: []Point(2, T),
        to_points: []Point(2, T),

        pub fn deinit(self: *@This()) void {
            allocator.free(self.from_points);
            allocator.free(self.to_points);
        }
    };
}

pub fn parsePointPairs(
    comptime T: type,
    from_obj: ?*c.PyObject,
    to_obj: ?*c.PyObject,
    min_points: usize,
    comptime min_points_message: []const u8,
) !PointPairs(T) {
    const from_points = parsePointList(T, from_obj) catch |err| return err;
    errdefer allocator.free(from_points);

    const to_points = parsePointList(T, to_obj) catch |err| return err;
    errdefer allocator.free(to_points);

    if (from_points.len != to_points.len) {
        setValueError("from_points and to_points must have the same length", .{});
        return error.InvalidPointList;
    }

    if (from_points.len < min_points) {
        setValueError(min_points_message, .{});
        return error.InvalidPointList;
    }

    return PointPairs(T){
        .from_points = from_points,
        .to_points = to_points,
    };
}

pub fn projectPoints2D(points_obj: ?*c.PyObject, ctx: anytype, comptime apply: anytype) ?*c.PyObject {
    if (points_obj == null) {
        setTypeError("(x, y) tuple or list of tuples", null);
        return null;
    }

    if (c.PyTuple_Check(points_obj) != 0 and c.PyTuple_Size(points_obj) == 2) {
        const point = parsePointTuple(f64, points_obj) catch return null;
        const result = @call(.auto, apply, .{ ctx, point.x(), point.y() });
        const x_obj = c.PyFloat_FromDouble(result[0]) orelse return null;
        const y_obj = c.PyFloat_FromDouble(result[1]) orelse {
            c.Py_DECREF(x_obj);
            return null;
        };
        return c.PyTuple_Pack(2, x_obj, y_obj);
    }

    if (c.PySequence_Check(points_obj) != 0) {
        const points = parsePointList(f64, points_obj) catch return null;
        defer allocator.free(points);

        const result_list = c.PyList_New(@intCast(points.len)) orelse return null;

        for (points, 0..) |point, i| {
            const result = @call(.auto, apply, .{ ctx, point.x(), point.y() });
            const x_obj = c.PyFloat_FromDouble(result[0]) orelse {
                c.Py_DECREF(result_list);
                return null;
            };
            const y_obj = c.PyFloat_FromDouble(result[1]) orelse {
                c.Py_DECREF(x_obj);
                c.Py_DECREF(result_list);
                return null;
            };
            const tuple = c.PyTuple_Pack(2, x_obj, y_obj) orelse {
                // PyTuple_Pack decrements references on failure.
                c.Py_DECREF(result_list);
                return null;
            };
            _ = c.PyList_SetItem(result_list, @intCast(i), tuple);
        }

        return result_list;
    }

    setTypeError("(x, y) tuple or list of tuples", points_obj);
    return null;
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

/// Convenience function for strictly positive values (> 0)
pub fn validatePositive(comptime T: type, value: anytype, name: []const u8) !T {
    const info = @typeInfo(T);
    const max = if (info == .float) std.math.inf(T) else std.math.maxInt(T);
    // For floats, allow any positive value > 0. For integers, minimum is 1.
    const min = if (info == .float) std.math.floatEps(T) else 1;
    return validateRange(T, value, min, max, name);
}

/// Build a Python kwlist for PyArg_ParseTupleAndKeywords from a comptime list of names.
/// Usage: `const kw = py_utils.kw(&.{ "size", "method" });`
/// Pass to CPython with: `@ptrCast(@constCast(&kw))`.
///
/// Notes on Python versions:
/// - CPython < 3.13 expects a non-const kwlist pointer; we use `@constCast(&kw)` for compatibility.
/// - Once the minimum supported Python is >= 3.13, we can drop the `@constCast` at call sites
///   and pass `&kw` directly.
pub fn kw(comptime names: []const []const u8) [names.len + 1]?[*:0]const u8 {
    comptime {
        var out: [names.len + 1]?[*:0]const u8 = undefined;
        for (names, 0..) |nm, i| {
            // Convert Zig string literal to C string pointer
            out[i] = @ptrCast(@constCast(nm));
        }
        out[names.len] = null;
        return out;
    }
}

/// Parse Python arguments into a struct using automatic type detection.
/// The struct fields define both the parameter names and types.
/// Optional fields (e.g., `?f64`) are automatically handled with a `|` separator.
///
/// Usage:
/// ```zig
/// const Params = struct {
///     x: f64,                    // Required
///     y: f64,                    // Required
///     width: ?f64 = null,        // Optional with default
///     height: ?f64 = null,       // Optional with default
/// };
/// var params: Params = undefined;
/// py_utils.parseArgs(Params, args, kwds, &params) catch return null;
/// ```
pub fn parseArgs(comptime T: type, args: ?*c.PyObject, kwds: ?*c.PyObject, out: *T) !void {
    const type_info = @typeInfo(T);
    const fields = switch (type_info) {
        .@"struct" => |s| s.fields,
        else => @compileError("parseArgs expects a struct type, got: " ++ @typeName(T)),
    };

    // Build format string at comptime with automatic | separator
    const format = comptime blk: {
        // Validate field ordering and find where to insert |
        var first_optional_idx: ?usize = null;

        for (fields, 0..) |field, i| {
            const has_default = field.default_value_ptr != null;

            if (!has_default) {
                // Required field - must not come after optional
                if (first_optional_idx != null) {
                    @compileError("Required field '" ++ field.name ++ "' cannot come after optional fields. Once a field has a default value, all subsequent fields must also have defaults.");
                }
            } else {
                // Optional field - mark first occurrence
                if (first_optional_idx == null) {
                    first_optional_idx = i;
                }
            }
        }

        var format_buf: [fields.len * 2 + 2]u8 = undefined; // +2 for | and null
        var format_len: usize = 0;

        for (fields, 0..) |field, i| {
            // Insert | before first optional field (if any)
            if (first_optional_idx != null and i == first_optional_idx.?) {
                format_buf[format_len] = '|';
                format_len += 1;
            }

            // Get the actual type (unwrap optional if needed)
            const actual_type = if (@typeInfo(field.type) == .optional)
                @typeInfo(field.type).optional.child
            else
                field.type;

            const type_chars = switch (@typeInfo(actual_type)) {
                .float => "d",
                .int => |info| blk2: {
                    if (actual_type == c.Py_ssize_t) break :blk2 "n";
                    if (info.signedness == .signed) {
                        if (info.bits <= 32) break :blk2 "i";
                        break :blk2 "L";
                    } else {
                        if (info.bits <= 32) break :blk2 "I";
                        break :blk2 "K";
                    }
                },
                .pointer => |ptr| blk2: {
                    if (ptr.child == c.PyObject) break :blk2 "O";
                    if (ptr.child == u8 and ptr.size == .c) break :blk2 "s";
                    @compileError("Unsupported pointer type: " ++ @typeName(actual_type));
                },
                else => @compileError("Unsupported type: " ++ @typeName(actual_type)),
            };
            for (type_chars) |ch| {
                format_buf[format_len] = ch;
                format_len += 1;
            }
        }

        format_buf[format_len] = 0; // null terminate
        const final = format_buf[0..format_len :0].*;
        break :blk final;
    };

    // Build names array at comptime
    const names = comptime blk: {
        var result: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            result[i] = field.name;
        }
        break :blk result;
    };

    // Build keywords list
    const keywords = comptime kw(&names);

    // Initialize struct with defaults - especially important for optional fields
    inline for (fields) |field| {
        if (field.default_value_ptr) |default_ptr| {
            const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
            @field(out.*, field.name) = default_value;
        } else if (@typeInfo(field.type) == .optional) {
            @field(out.*, field.name) = null;
        }
    }

    // Build argument tuple
    var arg_tuple: std.meta.Tuple(&[_]type{*anyopaque} ** fields.len) = undefined;
    inline for (fields, 0..) |field, i| {
        arg_tuple[i] = @ptrCast(&@field(out.*, field.name));
    }

    // TODO(py3.13): drop @constCast once minimum Python >= 3.13
    const result = @call(.auto, c.PyArg_ParseTupleAndKeywords, .{
        args,
        kwds,
        &format,
        @as([*c][*c]u8, @ptrCast(@constCast(&keywords))),
    } ++ arg_tuple);

    if (result == 0) {
        return error.ArgumentParseError;
    }
}

// ============================================================================
// Essential Error Helpers - Keep it simple!
// ============================================================================

/// Simple helper for memory errors with context
pub fn setMemoryError(context: []const u8) void {
    var buffer: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buffer, "Failed to allocate {s}", .{context}) catch "Out of memory";
    c.PyErr_SetString(c.PyExc_MemoryError, msg.ptr);
}

/// Set a type error with expected type information
pub fn setTypeError(expected: []const u8, got: ?*c.PyObject) void {
    var buffer: [256]u8 = undefined;

    const type_name = if (got != null) blk: {
        const tp = c.Py_TYPE(got);
        const tp_name = tp.*.tp_name;
        // Extract just the type name (after the last dot)
        var i: usize = 0;
        while (tp_name[i] != 0) : (i += 1) {}
        var last_dot: usize = 0;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (tp_name[j] == '.') last_dot = j + 1;
        }
        break :blk tp_name[last_dot..i];
    } else "None";

    const msg = std.fmt.bufPrintZ(&buffer, "Expected {s}, got {s}", .{ expected, type_name }) catch "Type error";
    c.PyErr_SetString(c.PyExc_TypeError, msg.ptr);
}

/// Set a value error with a custom message
fn setFormattedError(
    exc_type: [*c]c.PyObject,
    comptime fallback: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buffer: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buffer, fmt, args) catch fallback;
    c.PyErr_SetString(exc_type, msg.ptr);
}

/// Set a value error with a custom message
pub fn setValueError(comptime fmt: []const u8, args: anytype) void {
    setFormattedError(c.PyExc_ValueError, "Value error", fmt, args);
}

/// Helper to ensure a Python-wrapped object is initialized.
/// Checks if the specified field is non-null. If null, sets a Python ValueError and returns error.NotInitialized.
pub fn ensureInitialized(obj: anytype, comptime field_name: []const u8, comptime error_msg: []const u8) !void {
    if (@field(obj, field_name) == null) {
        setValueError(error_msg, .{});
        return error.NotInitialized;
    }
}

/// Set a runtime error with a custom message
pub fn setRuntimeError(comptime fmt: []const u8, args: anytype) void {
    setFormattedError(c.PyExc_RuntimeError, "Runtime error", fmt, args);
}

/// Set an index error with a custom message
pub fn setIndexError(comptime fmt: []const u8, args: anytype) void {
    setFormattedError(c.PyExc_IndexError, "Index error", fmt, args);
}

/// Set an import error with a custom message
pub fn setImportError(comptime fmt: []const u8, args: anytype) void {
    setFormattedError(c.PyExc_ImportError, "Import error", fmt, args);
}

/// Simple error mapping for common Zig errors
pub fn setZigError(err: anyerror) void {
    const exc_type = switch (err) {
        error.OutOfMemory => c.PyExc_MemoryError,
        else => c.PyExc_RuntimeError,
    };
    var buffer: [256]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buffer, "Operation failed: {s}", .{@errorName(err)}) catch "Operation failed";
    c.PyErr_SetString(exc_type, msg.ptr);
}

// ============================================================================
// Safe Casting Helpers
// ============================================================================

/// Safely cast a Python object to a specific type without null checking
/// Use when you're certain the object is not null (e.g., in methods where self is guaranteed)
pub fn safeCast(comptime T: type, obj: ?*c.PyObject) *T {
    return @as(*T, @ptrCast(@alignCast(obj.?)));
}

/// Safely cast a Python object to a specific type with null checking.
/// Returns error.NullPointer if the object is null.
pub fn safeCastChecked(comptime T: type, obj: ?*c.PyObject) !*T {
    if (obj) |o| {
        return @as(*T, @ptrCast(@alignCast(o)));
    }
    return error.NullPointer;
}

// ============================================================================
// Object Lifecycle Management
// ============================================================================

/// Generic new function for Python objects
pub fn genericNew(comptime T: type) fn (?*c.PyTypeObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return struct {
        fn new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            _ = args;
            _ = kwds;

            const self = @as(?*T, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
            if (self) |obj| {
                // Initialize all pointer fields to null
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (@typeInfo(field.type) == .optional) {
                        @field(obj, field.name) = null;
                    }
                }
            }
            return @as(?*c.PyObject, @ptrCast(self));
        }
    }.new;
}

/// Generic dealloc function for objects with heap-allocated pointers
pub fn genericDealloc(comptime T: type, comptime deinit_fn: ?fn (*T) void) fn (?*c.PyObject) callconv(.c) void {
    return struct {
        fn dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
            const self = safeCast(T, self_obj);

            // Call custom deinit if provided
            if (deinit_fn) |deinit| {
                deinit(self);
            }

            // Free the Python object
            const tp = @as(*c.PyTypeObject, @ptrCast(c.Py_TYPE(self_obj)));
            tp.*.tp_free.?(self_obj);
        }
    }.dealloc;
}

// ============================================================================
// PyTypeObject Builder
// ============================================================================

pub const TypeObjectConfig = struct {
    name: []const u8,
    doc: ?[]const u8 = null,
    basicsize: usize,
    methods: ?[*]c.PyMethodDef = null,
    getset: ?[*]c.PyGetSetDef = null,
    init: ?*const anyopaque = null,
    new: ?*const anyopaque = null,
    dealloc: ?*const anyopaque = null,
    repr: ?*const anyopaque = null,
    str: ?*const anyopaque = null,
    richcompare: ?*const anyopaque = null,
    iter: ?*const anyopaque = null,
    iternext: ?*const anyopaque = null,
    getattro: ?*const anyopaque = null,
    setattro: ?*const anyopaque = null,
    as_number: ?*c.PyNumberMethods = null,
    as_sequence: ?*c.PySequenceMethods = null,
    as_mapping: ?*c.PyMappingMethods = null,
    hash: ?*const anyopaque = null,
    call: ?*const anyopaque = null,
    flags: c_ulong = c.Py_TPFLAGS_DEFAULT,
};

/// Build a PyTypeObject with the given configuration
pub fn buildTypeObject(comptime config: TypeObjectConfig) c.PyTypeObject {
    const str_fn: ?*const anyopaque = config.str orelse config.repr;

    return .{
        .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
        .tp_name = config.name.ptr,
        .tp_basicsize = @intCast(config.basicsize),
        .tp_dealloc = if (config.dealloc) |func| @ptrCast(@alignCast(func)) else null,
        .tp_repr = if (config.repr) |func| @ptrCast(@alignCast(func)) else null,
        .tp_str = if (str_fn) |func| @ptrCast(@alignCast(func)) else null,
        .tp_flags = config.flags,
        .tp_doc = if (config.doc) |d| d.ptr else null,
        .tp_methods = config.methods,
        .tp_getset = config.getset,
        .tp_richcompare = if (config.richcompare) |func| @ptrCast(@alignCast(func)) else null,
        .tp_iter = if (config.iter) |func| @ptrCast(@alignCast(func)) else null,
        .tp_iternext = if (config.iternext) |func| @ptrCast(@alignCast(func)) else null,
        .tp_init = if (config.init) |func| @ptrCast(@alignCast(func)) else null,
        .tp_new = if (config.new) |func| @ptrCast(@alignCast(func)) else null,
        .tp_getattro = if (config.getattro) |func| @ptrCast(@alignCast(func)) else null,
        .tp_setattro = if (config.setattro) |func| @ptrCast(@alignCast(func)) else null,
        .tp_as_number = config.as_number,
        .tp_as_sequence = config.as_sequence,
        .tp_as_mapping = config.as_mapping,
        .tp_hash = if (config.hash) |func| @ptrCast(@alignCast(func)) else null,
        .tp_call = if (config.call) |func| @ptrCast(@alignCast(func)) else null,
    };
}

/// Create a heap-allocated object with automatic memory management
pub fn createHeapObject(comptime T: type, args: anytype) !*T {
    const obj = allocator.create(T) catch {
        setMemoryError(@typeName(T));
        return error.OutOfMemory;
    };
    obj.* = T.init(args[0]);
    return obj;
}

/// Destroy a heap-allocated object
pub fn destroyHeapObject(comptime T: type, ptr: ?*T) void {
    if (ptr) |p| {
        p.deinit();
        allocator.destroy(p);
    }
}

pub const TupleExpectError = error{InvalidTuple};

/// Ensure object is a tuple of fixed length and return borrowed elements.
pub fn expectTupleLen(
    comptime len: usize,
    obj: ?*c.PyObject,
    description: []const u8,
) TupleExpectError![len]*c.PyObject {
    if (obj == null or c.PyTuple_Check(obj) == 0) {
        setTypeError(description, obj);
        return TupleExpectError.InvalidTuple;
    }

    if (c.PyTuple_Size(obj) != len) {
        setValueError("{s} must have exactly {d} elements", .{ description, len });
        return TupleExpectError.InvalidTuple;
    }

    var result: [len]*c.PyObject = undefined;
    inline for (0..len) |index| {
        const item = c.PyTuple_GetItem(obj, @intCast(index));
        if (item == null) {
            return TupleExpectError.InvalidTuple;
        }
        result[index] = item;
    }
    return result;
}

/// Build a Python list from a Zig slice using a custom element converter.
/// The converter must return a new reference for each element or null to signal failure.
pub fn listFromSliceCustom(
    comptime T: type,
    slice: []const T,
    comptime converter: fn (value: T, index: usize) ?*c.PyObject,
) ?*c.PyObject {
    const list = c.PyList_New(@intCast(slice.len));
    if (list == null) return null;

    for (slice, 0..) |item, idx| {
        const py_item = converter(item, idx);
        if (py_item == null) {
            c.Py_DECREF(list);
            return null;
        }
        _ = c.PyList_SetItem(list, @intCast(idx), py_item);
    }

    return list;
}

/// Convert a slice of known type into a Python list using built-in converters.
/// Currently supports floating-point and integer slices; extend the switch to add more types.
pub fn listFromSlice(comptime T: type, slice: []const T) ?*c.PyObject {
    return switch (@typeInfo(T)) {
        .float => blk: {
            const Converter = struct {
                fn convert(value: T, _: usize) ?*c.PyObject {
                    const as_f64: f64 = @floatCast(value);
                    return c.PyFloat_FromDouble(as_f64);
                }
            };
            break :blk listFromSliceCustom(T, slice, Converter.convert);
        },
        .int => blk: {
            const info = @typeInfo(T).int;
            const SignedParam = @typeInfo(@TypeOf(c.PyLong_FromLongLong)).@"fn".params[0].type.?;
            const UnsignedParam = @typeInfo(@TypeOf(c.PyLong_FromUnsignedLongLong)).@"fn".params[0].type.?;
            const Converter = struct {
                fn convert(value: T, _: usize) ?*c.PyObject {
                    return if (info.signedness == .signed)
                        c.PyLong_FromLongLong(@as(SignedParam, @intCast(value)))
                    else
                        c.PyLong_FromUnsignedLongLong(@as(UnsignedParam, @intCast(value)));
                }
            };
            break :blk listFromSliceCustom(T, slice, Converter.convert);
        },
        else => @compileError("listFromSlice for type " ++ @typeName(T) ++ " requires a custom converter overload"),
    };
}

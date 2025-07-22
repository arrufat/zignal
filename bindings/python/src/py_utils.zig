const std = @import("std");
const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

/// Creates an arena allocator optimized for Python C API integration.
/// Uses c_allocator as backing since we're already linking with libc.
pub fn createArenaAllocator() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.c_allocator);
}

/// Direct access to the optimal allocator for Python bindings.
/// Use this for simple allocations that don't need arena batching.
pub const allocator = std.heap.c_allocator;

/// Helper to register a type with a module
pub fn registerType(module: [*c]c.PyObject, comptime name: []const u8, type_obj: *c.PyTypeObject) !void {
    if (c.PyType_Ready(type_obj) < 0) return error.TypeInitFailed;

    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(type_obj)));
    if (c.PyModule_AddObject(module, name.ptr, @as(?*c.PyObject, @ptrCast(type_obj))) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(type_obj)));
        return error.TypeAddFailed;
    }
}

/// Get Python boolean singletons
pub fn getPyBool(value: bool) [*c]c.PyObject {
    const py_true = @extern(*c.PyObject, .{ .name = "_Py_TrueStruct", .linkage = .weak });
    const py_false = @extern(*c.PyObject, .{ .name = "_Py_FalseStruct", .linkage = .weak });

    const result = if (value) py_true else py_false;
    c.Py_INCREF(result);
    return @ptrCast(result);
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
                // String slice
                break :blk c.PyUnicode_FromStringAndSize(value.ptr, @intCast(value.len));
            }
            break :blk null;
        },
        .array => |arr| blk: {
            if (arr.child == u8) {
                // String array
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

/// Generate a property getter function for any field type
pub fn makeFieldGetter(comptime ObjectType: type, comptime field_name: []const u8) fn ([*c]c.PyObject, ?*anyopaque) callconv(.c) [*c]c.PyObject {
    return struct {
        fn getter(self_obj: [*c]c.PyObject, closure: ?*anyopaque) callconv(.c) [*c]c.PyObject {
            _ = closure;
            const self = @as(*ObjectType, @ptrCast(self_obj));
            const value = @field(self, field_name);
            return @ptrCast(convertToPython(value));
        }
    }.getter;
}

/// Generate property getters for all fields in a struct type (excluding ob_base)
pub fn generateGetSetDefs(comptime ObjectType: type) *const [countNonObBaseFields(ObjectType) + 1]c.PyGetSetDef {
    const struct_info = @typeInfo(ObjectType).@"struct";

    // Count fields excluding ob_base
    const field_count = countNonObBaseFields(ObjectType);

    // Generate getters array
    const getters = blk: {
        var result: [field_count + 1]c.PyGetSetDef = undefined;
        var index = 0;

        inline for (struct_info.fields) |field| {
            if (std.mem.eql(u8, field.name, "ob_base")) continue;

            result[index] = c.PyGetSetDef{
                .name = field.name ++ "",
                .get = makeFieldGetter(ObjectType, field.name),
                .set = null,
                .doc = (comptime generateFieldDoc(field.name, field.type)) ++ "",
                .closure = null,
            };
            index += 1;
        }

        // Null terminator
        result[field_count] = c.PyGetSetDef{
            .name = null,
            .get = null,
            .set = null,
            .doc = null,
            .closure = null,
        };

        break :blk result;
    };

    return &getters;
}

/// Count fields excluding ob_base
fn countNonObBaseFields(comptime ObjectType: type) comptime_int {
    const struct_info = @typeInfo(ObjectType).@"struct";
    comptime var field_count = 0;
    inline for (struct_info.fields) |field| {
        if (!std.mem.eql(u8, field.name, "ob_base")) {
            field_count += 1;
        }
    }
    return field_count;
}

/// Generate documentation string for a field
fn generateFieldDoc(comptime field_name: []const u8, comptime field_type: type) []const u8 {
    return switch (@typeInfo(field_type)) {
        .int => |info| if (info.signedness == .unsigned)
            field_name ++ " component (unsigned integer)"
        else
            field_name ++ " component (signed integer)",
        .float => field_name ++ " component (float)",
        .bool => field_name ++ " component (boolean)",
        else => field_name ++ " component",
    };
}

/// Helper to check if a type has a specific method
fn hasMethod(comptime T: type, comptime method_name: []const u8) bool {
    return @hasDecl(T, method_name);
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

/// Method descriptor for automatic generation
pub const MethodDescriptor = struct {
    name: []const u8,
    zig_method: []const u8,
    flags: c_int = c.METH_NOARGS,
    doc: []const u8,
    args: []const []const u8 = &.{},
};

/// Generate a method wrapper for no-args instance methods
pub fn makeNoArgsMethodWrapper(
    comptime ObjectType: type,
    comptime ZigType: type,
    comptime method_name: []const u8,
) fn ([*c]c.PyObject, [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    return struct {
        fn wrapper(self_obj: [*c]c.PyObject, ignored: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            _ = ignored;
            const self = @as(*ObjectType, @ptrCast(self_obj));

            // Convert ObjectType to ZigType
            const zig_obj = convertObjectToZig(ObjectType, ZigType, self);

            // Call the method
            const result = @call(.auto, @field(ZigType, method_name), .{zig_obj});

            // Convert result back to Python
            return @ptrCast(convertToPython(result));
        }
    }.wrapper;
}

/// Generate a method wrapper for single-argument instance methods
pub fn makeSingleArgMethodWrapper(
    comptime ObjectType: type,
    comptime ZigType: type,
    comptime method_name: []const u8,
    comptime ArgType: type,
    comptime arg_format: []const u8,
) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return struct {
        fn wrapper(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const self = @as(*ObjectType, @ptrCast(self_obj.?));

            // Parse arguments
            var arg_value: ArgType = undefined;
            if (parseArguments(args, arg_format, &arg_value) != 0) {
                return null;
            }

            // Convert ObjectType to ZigType
            const zig_obj = convertObjectToZig(ObjectType, ZigType, self);

            // Call the method
            const result = @call(.auto, @field(ZigType, method_name), .{ zig_obj, arg_value });

            // Convert result back to Python
            return convertToPython(result);
        }
    }.wrapper;
}

/// Generate a class method wrapper (for constructors)
pub fn makeClassMethodWrapper(
    comptime ZigType: type,
    comptime method_name: []const u8,
    comptime ArgType: type,
    comptime arg_format: []const u8,
) fn (?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return struct {
        fn wrapper(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            // Parse arguments
            var arg_value: ArgType = undefined;
            if (parseArguments(args, arg_format, &arg_value) != 0) {
                return null;
            }

            // Call the Zig constructor/class method
            const zig_result = @call(.auto, @field(ZigType, method_name), .{arg_value});

            // Create new Python object
            const new_args = convertZigToPythonArgs(ZigType, zig_result);
            defer c.Py_DECREF(new_args);

            return c.PyObject_CallObject(type_obj, new_args);
        }
    }.wrapper;
}

/// Convert Python object to Zig type by copying fields
fn convertObjectToZig(comptime ObjectType: type, comptime ZigType: type, obj: *ObjectType) ZigType {
    var result: ZigType = undefined;

    // Copy matching fields from ObjectType to ZigType
    inline for (@typeInfo(ZigType).@"struct".fields) |field| {
        if (@hasField(ObjectType, field.name)) {
            @field(result, field.name) = @field(obj, field.name);
        }
    }

    return result;
}

/// Convert Zig result to Python arguments tuple
fn convertZigToPythonArgs(comptime ZigType: type, zig_obj: ZigType) ?*c.PyObject {
    const fields = @typeInfo(ZigType).@"struct".fields;

    // Create tuple with field values
    const tuple = c.PyTuple_New(@intCast(fields.len));
    if (tuple == null) return null;

    inline for (fields, 0..) |field, i| {
        const value = @field(zig_obj, field.name);
        const py_value = convertToPython(value);
        if (py_value == null) {
            c.Py_DECREF(tuple);
            return null;
        }
        _ = c.PyTuple_SetItem(tuple, @intCast(i), py_value);
    }

    return tuple;
}

/// Parse Python arguments with format string
fn parseArguments(args: ?*c.PyObject, comptime format: []const u8, values: anytype) c_int {
    switch (format.len) {
        1 => {
            switch (format[0]) {
                'i' => {
                    var val: c_int = 0;
                    const result = c.PyArg_ParseTuple(args, format.ptr, &val);
                    if (result != 0) {
                        values.* = @intCast(val);
                    }
                    return result;
                },
                'I' => {
                    var val: c_uint = 0;
                    const result = c.PyArg_ParseTuple(args, format.ptr, &val);
                    if (result != 0) {
                        values.* = @intCast(val);
                    }
                    return result;
                },
                'd' => {
                    var val: f64 = 0;
                    const result = c.PyArg_ParseTuple(args, format.ptr, &val);
                    if (result != 0) {
                        values.* = @floatCast(val);
                    }
                    return result;
                },
                else => return -1,
            }
        },
        else => return -1,
    }
}

/// Generate standard dealloc function
pub fn generateDealloc(comptime ObjectType: type) fn ([*c]c.PyObject) callconv(.c) void {
    return struct {
        fn dealloc(self_obj: [*c]c.PyObject) callconv(.c) void {
            // Add any custom cleanup logic here if needed
            _ = @as(*ObjectType, @ptrCast(self_obj));
            c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
        }
    }.dealloc;
}

/// Generate standard new function
pub fn generateNew(comptime ObjectType: type) fn (?*c.PyTypeObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return struct {
        fn new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            _ = args;
            _ = kwds;

            const self = @as(?*ObjectType, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
            if (self) |obj| {
                // Initialize fields to zero
                const fields = @typeInfo(ObjectType).@"struct".fields;
                inline for (fields) |field| {
                    if (std.mem.eql(u8, field.name, "ob_base")) continue;
                    @field(obj, field.name) = std.mem.zeroes(field.type);
                }
            }
            return @ptrCast(self);
        }
    }.new;
}

/// Generate standard init function
pub fn generateInit(comptime ObjectType: type, comptime ZigType: type) fn (?*c.PyObject, ?*c.PyObject, ?*c.PyObject) callconv(.c) c_int {
    return struct {
        fn init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
            _ = kwds;
            const self = @as(*ObjectType, @ptrCast(self_obj.?));

            // Parse arguments based on ZigType fields
            const fields = @typeInfo(ZigType).@"struct".fields;

            // For now, support up to 4 fields
            switch (fields.len) {
                1 => {
                    var arg0: @TypeOf(@field(@as(ZigType, undefined), fields[0].name)) = undefined;
                    const format = getFormatString(fields[0].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0) == 0) {
                        return -1;
                    }
                    @field(self, fields[0].name) = arg0;
                },
                2 => {
                    var arg0: @TypeOf(@field(@as(ZigType, undefined), fields[0].name)) = undefined;
                    var arg1: @TypeOf(@field(@as(ZigType, undefined), fields[1].name)) = undefined;
                    const format = getFormatString(fields[0].type) ++ getFormatString(fields[1].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0, &arg1) == 0) {
                        return -1;
                    }
                    @field(self, fields[0].name) = arg0;
                    @field(self, fields[1].name) = arg1;
                },
                3 => {
                    var arg0: @TypeOf(@field(@as(ZigType, undefined), fields[0].name)) = undefined;
                    var arg1: @TypeOf(@field(@as(ZigType, undefined), fields[1].name)) = undefined;
                    var arg2: @TypeOf(@field(@as(ZigType, undefined), fields[2].name)) = undefined;
                    const format = getFormatString(fields[0].type) ++ getFormatString(fields[1].type) ++ getFormatString(fields[2].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0, &arg1, &arg2) == 0) {
                        return -1;
                    }
                    @field(self, fields[0].name) = arg0;
                    @field(self, fields[1].name) = arg1;
                    @field(self, fields[2].name) = arg2;
                },
                4 => {
                    var arg0: @TypeOf(@field(@as(ZigType, undefined), fields[0].name)) = undefined;
                    var arg1: @TypeOf(@field(@as(ZigType, undefined), fields[1].name)) = undefined;
                    var arg2: @TypeOf(@field(@as(ZigType, undefined), fields[2].name)) = undefined;
                    var arg3: @TypeOf(@field(@as(ZigType, undefined), fields[3].name)) = undefined;
                    const format = getFormatString(fields[0].type) ++ getFormatString(fields[1].type) ++ getFormatString(fields[2].type) ++ getFormatString(fields[3].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0, &arg1, &arg2, &arg3) == 0) {
                        return -1;
                    }
                    @field(self, fields[0].name) = arg0;
                    @field(self, fields[1].name) = arg1;
                    @field(self, fields[2].name) = arg2;
                    @field(self, fields[3].name) = arg3;
                },
                else => {
                    c.PyErr_SetString(c.PyExc_TypeError, "Unsupported number of fields for automatic init");
                    return -1;
                },
            }

            return 0;
        }
    }.init;
}

/// Generate standard repr function
pub fn generateRepr(comptime ObjectType: type, comptime ZigType: type) fn ([*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    return struct {
        fn repr(self_obj: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            const self = @as(*ObjectType, @ptrCast(self_obj));

            // Create a simple representation
            const type_name = @typeName(ZigType);
            const fields = @typeInfo(ZigType).@"struct".fields;

            // For now, support common cases
            switch (fields.len) {
                1 => {
                    const val = @field(self, fields[0].name);
                    var buffer: [64]u8 = undefined;
                    const formatted = std.fmt.bufPrintZ(&buffer, "{s}({s}={})", .{ type_name, fields[0].name, val }) catch return null;
                    return @ptrCast(c.PyUnicode_FromString(formatted.ptr));
                },
                2 => {
                    const val0 = @field(self, fields[0].name);
                    const val1 = @field(self, fields[1].name);
                    var buffer: [128]u8 = undefined;
                    const formatted = std.fmt.bufPrintZ(&buffer, "{s}({s}={}, {s}={})", .{ type_name, fields[0].name, val0, fields[1].name, val1 }) catch return null;
                    return @ptrCast(c.PyUnicode_FromString(formatted.ptr));
                },
                3 => {
                    const val0 = @field(self, fields[0].name);
                    const val1 = @field(self, fields[1].name);
                    const val2 = @field(self, fields[2].name);
                    var buffer: [128]u8 = undefined;
                    const formatted = std.fmt.bufPrintZ(&buffer, "{s}({s}={}, {s}={}, {s}={})", .{ type_name, fields[0].name, val0, fields[1].name, val1, fields[2].name, val2 }) catch return null;
                    return @ptrCast(c.PyUnicode_FromString(formatted.ptr));
                },
                else => {
                    var buffer: [64]u8 = undefined;
                    const formatted = std.fmt.bufPrintZ(&buffer, "{s}(...)", .{type_name}) catch return null;
                    return @ptrCast(c.PyUnicode_FromString(formatted.ptr));
                },
            }
        }
    }.repr;
}

/// Get format string for a type
pub fn getFormatString(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .unsigned) "I" else "i",
        .float => "d",
        .bool => "i",
        else => "O",
    };
}

/// Generate methods array from descriptors
pub fn generateMethods(comptime ObjectType: type, comptime ZigType: type, comptime methods: []const MethodDescriptor) []c.PyMethodDef {
    comptime var method_defs: [methods.len + 1]c.PyMethodDef = undefined;

    inline for (methods, 0..) |method, i| {
        method_defs[i] = c.PyMethodDef{
            .ml_name = method.name ++ "",
            .ml_meth = if (method.flags & c.METH_NOARGS != 0)
                makeNoArgsMethodWrapper(ObjectType, ZigType, method.zig_method)
            else if (method.flags & c.METH_CLASS != 0)
                @compileError("Class methods not yet supported by generateMethods")
            else
                @compileError("Only METH_NOARGS methods supported by generateMethods"),
            .ml_flags = method.flags,
            .ml_doc = method.doc ++ "",
        };
    }

    // Null terminator
    method_defs[methods.len] = c.PyMethodDef{
        .ml_name = null,
        .ml_meth = null,
        .ml_flags = 0,
        .ml_doc = null,
    };

    return &method_defs;
}

/// Generate a complete Python type definition
pub fn generatePythonType(
    comptime name: []const u8,
    comptime ObjectType: type,
    comptime ZigType: type,
    comptime methods: []const MethodDescriptor,
) c.PyTypeObject {
    return c.PyTypeObject{
        .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
        .tp_name = "zignal." ++ name,
        .tp_basicsize = @sizeOf(ObjectType),
        .tp_dealloc = generateDealloc(ObjectType),
        .tp_repr = generateRepr(ObjectType, ZigType),
        .tp_str = generateRepr(ObjectType, ZigType),
        .tp_flags = c.Py_TPFLAGS_DEFAULT,
        .tp_doc = @typeName(ZigType) ++ " Python binding",
        .tp_methods = generateMethods(ObjectType, ZigType, methods),
        .tp_getset = generateGetSetDefs(ObjectType),
        .tp_init = generateInit(ObjectType, ZigType),
        .tp_new = generateNew(ObjectType),
    };
}

// ============================================================================
// COLOR TYPE FACTORY
// ============================================================================

/// Configuration for color type binding generation
pub const ColorTypeConfig = struct {
    /// Custom validation function (optional)
    custom_validation: ?*const fn (field_name: []const u8, value: anytype) bool = null,
    /// Custom error message for validation failures
    validation_error: []const u8 = "Invalid color component value",
    /// Custom methods to add to the type
    custom_methods: []const MethodDescriptor = &.{},
    /// Custom documentation for the type
    custom_doc: ?[]const u8 = null,
};

/// Generate a complete color type binding with automatic property getters,
/// validation, and standard color methods
pub fn createColorBinding(
    comptime name: []const u8,
    comptime ZigColorType: type,
    comptime config: ColorTypeConfig,
) type {
    // Generate the Python object type
    const ObjectType = generateColorObjectType(ZigColorType);

    // Generate standard color methods
    const standard_methods = generateStandardColorMethods(ObjectType, ZigColorType);

    // Combine standard and custom methods
    const all_methods = standard_methods ++ config.custom_methods;

    return struct {
        pub const PyObjectType = ObjectType;
        pub const ZigType = ZigColorType;

        // Generate the Python type object
        pub var TypeObject = generateColorPythonType(name, ObjectType, ZigColorType, all_methods, config);

        // Generate custom init with validation
        pub fn init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
            _ = kwds;
            const self = @as(*ObjectType, @ptrCast(self_obj.?));
            const fields = @typeInfo(ZigColorType).@"struct".fields;

            // Parse arguments based on field count
            switch (fields.len) {
                1 => {
                    var arg0: @TypeOf(@field(@as(ZigColorType, undefined), fields[0].name)) = undefined;
                    if (c.PyArg_ParseTuple(args, getFormatString(fields[0].type).ptr, &arg0) == 0) {
                        return -1;
                    }

                    // Validate if custom validation is provided
                    if (config.custom_validation) |validator| {
                        if (!validator(fields[0].name, arg0)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    @field(self, fields[0].name) = arg0;
                },
                2 => {
                    var arg0: @TypeOf(@field(@as(ZigColorType, undefined), fields[0].name)) = undefined;
                    var arg1: @TypeOf(@field(@as(ZigColorType, undefined), fields[1].name)) = undefined;
                    const format = getFormatString(fields[0].type) ++ getFormatString(fields[1].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0, &arg1) == 0) {
                        return -1;
                    }

                    // Validate if custom validation is provided
                    if (config.custom_validation) |validator| {
                        if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    @field(self, fields[0].name) = arg0;
                    @field(self, fields[1].name) = arg1;
                },
                3 => {
                    var arg0: @TypeOf(@field(@as(ZigColorType, undefined), fields[0].name)) = undefined;
                    var arg1: @TypeOf(@field(@as(ZigColorType, undefined), fields[1].name)) = undefined;
                    var arg2: @TypeOf(@field(@as(ZigColorType, undefined), fields[2].name)) = undefined;
                    const format = getFormatString(fields[0].type) ++ getFormatString(fields[1].type) ++ getFormatString(fields[2].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0, &arg1, &arg2) == 0) {
                        return -1;
                    }

                    // Validate if custom validation is provided
                    if (config.custom_validation) |validator| {
                        if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1) or !validator(fields[2].name, arg2)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    @field(self, fields[0].name) = arg0;
                    @field(self, fields[1].name) = arg1;
                    @field(self, fields[2].name) = arg2;
                },
                4 => {
                    var arg0: @TypeOf(@field(@as(ZigColorType, undefined), fields[0].name)) = undefined;
                    var arg1: @TypeOf(@field(@as(ZigColorType, undefined), fields[1].name)) = undefined;
                    var arg2: @TypeOf(@field(@as(ZigColorType, undefined), fields[2].name)) = undefined;
                    var arg3: @TypeOf(@field(@as(ZigColorType, undefined), fields[3].name)) = undefined;
                    const format = getFormatString(fields[0].type) ++ getFormatString(fields[1].type) ++ getFormatString(fields[2].type) ++ getFormatString(fields[3].type);
                    if (c.PyArg_ParseTuple(args, format.ptr, &arg0, &arg1, &arg2, &arg3) == 0) {
                        return -1;
                    }

                    // Validate if custom validation is provided
                    if (config.custom_validation) |validator| {
                        if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1) or !validator(fields[2].name, arg2) or !validator(fields[3].name, arg3)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    @field(self, fields[0].name) = arg0;
                    @field(self, fields[1].name) = arg1;
                    @field(self, fields[2].name) = arg2;
                    @field(self, fields[3].name) = arg3;
                },
                else => {
                    c.PyErr_SetString(c.PyExc_TypeError, "Unsupported number of color components");
                    return -1;
                },
            }

            return 0;
        }
    };
}

/// Generate a Python object type for a color type
fn generateColorObjectType(comptime ZigColorType: type) type {
    const fields = @typeInfo(ZigColorType).@"struct".fields;

    // Create the object type with ob_base and all color fields
    var object_fields: [fields.len + 1]std.builtin.Type.StructField = undefined;

    // Add ob_base as first field
    object_fields[0] = std.builtin.Type.StructField{
        .name = "ob_base",
        .type = c.PyObject,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 0,
    };

    // Add all color component fields
    inline for (fields, 1..) |field, i| {
        object_fields[i] = std.builtin.Type.StructField{
            .name = field.name,
            .type = field.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .@"extern",
            .fields = &object_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Generate standard color methods (automatic detection of available methods)
fn generateStandardColorMethods(comptime ObjectType: type, comptime ZigColorType: type) []const MethodDescriptor {
    _ = ObjectType;
    comptime var methods: []const MethodDescriptor = &.{};

    // Check for common color methods and add them automatically
    if (@hasDecl(ZigColorType, "toHex")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_hex", .zig_method = "toHex", .doc = "Convert to hexadecimal representation" },
        };
    }

    if (@hasDecl(ZigColorType, "luma")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "luma", .zig_method = "luma", .doc = "Calculate perceptual luminance" },
        };
    }

    if (@hasDecl(ZigColorType, "isGray")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "is_gray", .zig_method = "isGray", .doc = "Check if color is grayscale" },
        };
    }

    if (@hasDecl(ZigColorType, "toGray")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_gray", .zig_method = "toGray", .doc = "Convert to grayscale" },
        };
    }

    if (@hasDecl(ZigColorType, "toRgb")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_rgb", .zig_method = "toRgb", .doc = "Convert to RGB color space" },
        };
    }

    if (@hasDecl(ZigColorType, "toHsl")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_hsl", .zig_method = "toHsl", .doc = "Convert to HSL color space" },
        };
    }

    if (@hasDecl(ZigColorType, "toHsv")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_hsv", .zig_method = "toHsv", .doc = "Convert to HSV color space" },
        };
    }

    if (@hasDecl(ZigColorType, "toLab")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_lab", .zig_method = "toLab", .doc = "Convert to CIELAB color space" },
        };
    }

    if (@hasDecl(ZigColorType, "toOklab")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_oklab", .zig_method = "toOklab", .doc = "Convert to Oklab color space" },
        };
    }

    if (@hasDecl(ZigColorType, "toOklch")) {
        methods = methods ++ &[_]MethodDescriptor{
            .{ .name = "to_oklch", .zig_method = "toOklch", .doc = "Convert to Oklch color space" },
        };
    }

    return methods;
}

/// Generate Python type object for color types
fn generateColorPythonType(
    comptime name: []const u8,
    comptime ObjectType: type,
    comptime ZigColorType: type,
    comptime methods: []const MethodDescriptor,
    comptime config: ColorTypeConfig,
) c.PyTypeObject {
    const doc = if (config.custom_doc) |custom| custom else @typeName(ZigColorType) ++ " color type";

    return c.PyTypeObject{
        .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
        .tp_name = "zignal." ++ name,
        .tp_basicsize = @sizeOf(ObjectType),
        .tp_dealloc = generateDealloc(ObjectType),
        .tp_repr = generateRepr(ObjectType, ZigColorType),
        .tp_str = generateRepr(ObjectType, ZigColorType),
        .tp_flags = c.Py_TPFLAGS_DEFAULT,
        .tp_doc = doc.ptr,
        .tp_methods = @ptrCast(generateMethods(ObjectType, ZigColorType, methods)),
        .tp_getset = @ptrCast(@constCast(generateGetSetDefs(ObjectType))),
        .tp_init = null, // Will be set manually
        .tp_new = generateNew(ObjectType),
    };
}

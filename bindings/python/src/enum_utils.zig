const std = @import("std");
const c = @import("py_utils.zig").c;
const zignal = @import("zignal");
const BuiltinEnum = std.builtin.Type.Enum;

/// Internal: extract enum type info from a Zig type that is either enum or union(enum)
fn getEnumInfo(comptime E: type) BuiltinEnum {
    const ti = @typeInfo(E);
    return switch (ti) {
        .@"enum" => ti.@"enum",
        .@"union" => |u| blk: {
            if (u.tag_type) |tag| {
                const tag_info = @typeInfo(tag);
                if (tag_info == .@"enum") break :blk tag_info.@"enum";
            }
            @compileError("Type " ++ @typeName(E) ++ " is not an enum or union(enum)");
        },
        else => @compileError("Type " ++ @typeName(E) ++ " is not an enum or union(enum)"),
    };
}

/// Register a Python IntEnum for the given Zig enum or union(enum) type.
pub fn registerEnum(
    comptime E: type,
    module: *c.PyObject,
    doc: []const u8,
) !void {
    // Import enum.IntEnum
    const enum_module = c.PyImport_ImportModule("enum") orelse return error.ImportFailed;
    defer c.Py_DECREF(enum_module);
    const int_enum = c.PyObject_GetAttrString(enum_module, "IntEnum") orelse return error.AttributeFailed;
    defer c.Py_DECREF(int_enum);

    // Build values dict: { UPPERCASE_NAME: int_value }
    const values = c.PyDict_New() orelse return error.DictCreationFailed;
    defer c.Py_DECREF(values);

    const EI = getEnumInfo(E);
    inline for (EI.fields) |field| {
        // Uppercase name for Python convention
        var up: [129]u8 = undefined;
        const n = field.name.len;
        if (n > up.len - 1) return error.NameTooLong;
        var i: usize = 0;
        while (i < n) : (i += 1) up[i] = std.ascii.toUpper(field.name[i]);
        up[n] = 0; // NUL terminate

        const py_val = c.PyLong_FromLong(@intCast(field.value)) orelse return error.ValueCreationFailed;
        defer c.Py_DECREF(py_val);
        if (c.PyDict_SetItemString(values, @ptrCast(&up[0]), py_val) < 0) return error.DictSetFailed;
    }

    // Create IntEnum(Name, values) using simple type name
    const name = zignal.meta.getSimpleTypeName(E);
    const name_uni = c.PyUnicode_FromStringAndSize(name.ptr, @intCast(name.len)) orelse return error.TupleCreationFailed;
    defer c.Py_DECREF(name_uni);
    const args = c.PyTuple_Pack(2, name_uni, values) orelse return error.TupleCreationFailed;
    defer c.Py_DECREF(args);
    const enum_obj = c.PyObject_CallObject(int_enum, args) orelse return error.EnumCreationFailed;

    // Set docstring
    const doc_str = c.PyUnicode_FromStringAndSize(doc.ptr, @intCast(doc.len)) orelse {
        c.Py_DECREF(enum_obj);
        return error.DocStringFailed;
    };
    if (c.PyObject_SetAttrString(enum_obj, "__doc__", doc_str) < 0) {
        c.Py_DECREF(doc_str);
        c.Py_DECREF(enum_obj);
        return error.DocStringSetFailed;
    }
    c.Py_DECREF(doc_str);

    // Set __module__ to top-level package for docs
    const module_name = c.PyUnicode_FromString("zignal") orelse {
        c.Py_DECREF(enum_obj);
        return error.ModuleNameFailed;
    };
    if (c.PyObject_SetAttrString(enum_obj, "__module__", module_name) < 0) {
        c.Py_DECREF(module_name);
        c.Py_DECREF(enum_obj);
        return error.ModuleSetFailed;
    }
    c.Py_DECREF(module_name);

    // Add to module (steals reference)
    var name_buf: [128]u8 = undefined;
    if (name.len >= name_buf.len) {
        c.Py_DECREF(enum_obj);
        return error.NameTooLong;
    }
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    if (c.PyModule_AddObject(module, @ptrCast(&name_buf[0]), enum_obj) < 0) {
        c.Py_DECREF(enum_obj);
        return error.ModuleAddFailed;
    }
}

/// Convert a Python object (IntEnum or int) to a Zig enum value.
/// Sets a Python exception on failure and returns an error.
pub fn pyToEnum(comptime E: type, obj: *c.PyObject) !E {
    // Try as int first
    var v = c.PyLong_AsLong(obj);
    if (v == -1 and c.PyErr_Occurred() != null) {
        // Clear and try to access .value (enum member)
        c.PyErr_Clear();
        const value_attr = c.PyObject_GetAttrString(obj, "value");
        if (value_attr == null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Enum must be an integer or IntEnum member");
            return error.InvalidType;
        }
        defer c.Py_DECREF(value_attr);
        v = c.PyLong_AsLong(value_attr);
        if (v == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Failed to extract enum value");
            return error.InvalidType;
        }
    }

    // Validate against declared enum values
    const EI = getEnumInfo(E);
    var matched = false;
    var out: E = @enumFromInt(0);
    inline for (EI.fields) |field| {
        if (v == field.value) {
            matched = true;
            out = @enumFromInt(field.value);
        }
    }
    if (!matched) {
        var buf: [128]u8 = undefined;
        const name = zignal.meta.getSimpleTypeName(E);
        const msg = std.fmt.bufPrintZ(&buf, "Invalid {s} value", .{name}) catch "Invalid enum value";
        c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
        return error.InvalidValue;
    }
    return out;
}

/// Return the tag enum type for a union(enum)
fn TagOf(comptime U: type) type {
    const ti = @typeInfo(U);
    if (ti != .@"union" or ti.@"union".tag_type == null) {
        @compileError("Type " ++ @typeName(U) ++ " is not a tagged union");
    }
    return ti.@"union".tag_type.?;
}

/// Convert a Python object (IntEnum or int) to the tag of a union(enum)
pub fn pyToUnionTag(comptime U: type, obj: *c.PyObject) !TagOf(U) {
    var v = c.PyLong_AsLong(obj);
    if (v == -1 and c.PyErr_Occurred() != null) {
        c.PyErr_Clear();
        const value_attr = c.PyObject_GetAttrString(obj, "value");
        if (value_attr == null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Enum must be an integer or IntEnum member");
            return error.InvalidType;
        }
        defer c.Py_DECREF(value_attr);
        v = c.PyLong_AsLong(value_attr);
        if (v == -1 and c.PyErr_Occurred() != null) {
            c.PyErr_SetString(c.PyExc_TypeError, "Failed to extract enum value");
            return error.InvalidType;
        }
    }

    const EI = getEnumInfo(U);
    inline for (EI.fields) |field| {
        if (v == field.value) {
            return @enumFromInt(field.value);
        }
    }
    var buf: [128]u8 = undefined;
    const name = zignal.meta.getSimpleTypeName(U);
    const msg = std.fmt.bufPrintZ(&buf, "Invalid {s} value", .{name}) catch "Invalid enum value";
    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
    return error.InvalidValue;
}

/// Convert a c_long integer to the tag of a union(enum)
pub fn longToUnionTag(comptime U: type, value: c_long) !TagOf(U) {
    const EI = getEnumInfo(U);
    inline for (EI.fields) |field| {
        if (value == field.value) {
            return @enumFromInt(field.value);
        }
    }
    var buf: [128]u8 = undefined;
    const name = zignal.meta.getSimpleTypeName(U);
    const msg = std.fmt.bufPrintZ(&buf, "Invalid {s} value", .{name}) catch "Invalid enum value";
    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
    return error.InvalidValue;
}

const std = @import("std");

const zignal = @import("zignal");

const py_utils = @import("py_utils.zig");
pub const registerType = py_utils.registerType;

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// SIMPLIFIED COLOR FACTORY
// ============================================================================

/// Configuration for color type binding generation
pub const ColorBindingConfig = struct {
    /// Custom validation function (optional)
    validation_fn: ?*const fn (field_name: []const u8, value: anytype) bool = null,
    /// Custom error message for validation failures
    validation_error: []const u8 = "Invalid color component value",
    /// Custom documentation for the type
    doc: []const u8 = "Color type",
};

/// Generate a color binding with automatic property getters and validation
pub fn createColorBinding(
    comptime name: []const u8,
    comptime ZigColorType: type,
    comptime config: ColorBindingConfig,
) type {
    const fields = @typeInfo(ZigColorType).@"struct".fields;

    // Create the Python object type manually (avoiding @Type complexity)
    const ObjectType = switch (fields.len) {
        1 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,

            pub const field_names = [_][]const u8{fields[0].name};
        },
        2 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
            field1: fields[1].type,

            pub const field_names = [_][]const u8{ fields[0].name, fields[1].name };
        },
        3 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
            field1: fields[1].type,
            field2: fields[2].type,

            pub const field_names = [_][]const u8{ fields[0].name, fields[1].name, fields[2].name };
        },
        4 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
            field1: fields[1].type,
            field2: fields[2].type,
            field3: fields[3].type,

            pub const field_names = [_][]const u8{ fields[0].name, fields[1].name, fields[2].name, fields[3].name };
        },
        else => @compileError("Color types with more than 4 fields not supported yet"),
    };

    return struct {
        pub const PyObjectType = ObjectType;
        pub const ZigType = ZigColorType;

        // Generate property getters
        pub fn generateGetters() [fields.len + 1]c.PyGetSetDef {
            var getters: [fields.len + 1]c.PyGetSetDef = undefined;

            // Generate getter for each field
            inline for (fields, 0..) |field, i| {
                getters[i] = c.PyGetSetDef{
                    .name = field.name ++ "",
                    .get = generateFieldGetter(i),
                    .set = null,
                    .doc = field.name ++ " component",
                    .closure = null,
                };
            }

            // Null terminator
            getters[fields.len] = c.PyGetSetDef{
                .name = null,
                .get = null,
                .set = null,
                .doc = null,
                .closure = null,
            };

            return getters;
        }

        // Generate field getter for specific field index
        fn generateFieldGetter(comptime field_index: usize) fn ([*c]c.PyObject, ?*anyopaque) callconv(.c) [*c]c.PyObject {
            return struct {
                fn getter(self_obj: [*c]c.PyObject, closure: ?*anyopaque) callconv(.c) [*c]c.PyObject {
                    _ = closure;
                    const self = @as(*ObjectType, @ptrCast(self_obj));

                    const value = switch (field_index) {
                        0 => self.field0,
                        1 => self.field1,
                        2 => self.field2,
                        3 => self.field3,
                        else => unreachable,
                    };

                    return @ptrCast(@alignCast(py_utils.convertToPythonCast(value)));
                }
            }.getter;
        }

        // Generate methods array
        pub fn generateMethods() [getMethodCount() + 1]c.PyMethodDef {
            var methods: [getMethodCount() + 1]c.PyMethodDef = undefined;
            var index: usize = 0;

            // Add methods based on what's available on the Zig type
            if (@hasDecl(ZigColorType, "toHex")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "to_hex",
                    .ml_meth = generateToHexMethod(),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Convert to hexadecimal representation",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "luma")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "luma",
                    .ml_meth = generateLumaMethod(),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Calculate perceptual luminance",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "isGray")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "is_gray",
                    .ml_meth = generateIsGrayMethod(),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Check if color is grayscale",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "toHsv")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "to_hsv",
                    .ml_meth = generateToHsvMethod(),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Convert to HSV color space",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "toRgb")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "to_rgb",
                    .ml_meth = generateToRgbMethod(),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Convert to RGB color space",
                };
                index += 1;
            }

            // Null terminator
            methods[index] = c.PyMethodDef{
                .ml_name = null,
                .ml_meth = null,
                .ml_flags = 0,
                .ml_doc = null,
            };

            return methods;
        }

        // Count available methods
        fn getMethodCount() comptime_int {
            var count: comptime_int = 0;
            if (@hasDecl(ZigColorType, "toHex")) count += 1;
            if (@hasDecl(ZigColorType, "luma")) count += 1;
            if (@hasDecl(ZigColorType, "isGray")) count += 1;
            if (@hasDecl(ZigColorType, "toHsv")) count += 1;
            if (@hasDecl(ZigColorType, "toRgb")) count += 1;
            return count;
        }

        // Method generators
        fn generateToHexMethod() fn ([*c]c.PyObject, [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return struct {
                fn method(self_obj: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    const self = @as(*ObjectType, @ptrCast(self_obj));
                    const zig_color = objectToZigColor(self);
                    const result = zig_color.toHex();
                    return @ptrCast(py_utils.convertToPython(result));
                }
            }.method;
        }

        fn generateLumaMethod() fn ([*c]c.PyObject, [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return struct {
                fn method(self_obj: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    const self = @as(*ObjectType, @ptrCast(self_obj));
                    const zig_color = objectToZigColor(self);
                    const result = zig_color.luma();
                    return @ptrCast(py_utils.convertToPython(result));
                }
            }.method;
        }

        fn generateIsGrayMethod() fn ([*c]c.PyObject, [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return struct {
                fn method(self_obj: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    const self = @as(*ObjectType, @ptrCast(self_obj));
                    const zig_color = objectToZigColor(self);
                    const result = zig_color.isGray();
                    return @ptrCast(py_utils.getPyBool(result));
                }
            }.method;
        }

        fn generateToHsvMethod() fn ([*c]c.PyObject, [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return struct {
                fn method(self_obj: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    const self = @as(*ObjectType, @ptrCast(self_obj));
                    const zig_color = objectToZigColor(self);
                    const hsv_result = zig_color.toHsv();

                    // Create a new HSV Python object
                    return createHsvPyObject(hsv_result);
                }
            }.method;
        }

        fn generateToRgbMethod() fn ([*c]c.PyObject, [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            return struct {
                fn method(self_obj: [*c]c.PyObject, _: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
                    const self = @as(*ObjectType, @ptrCast(self_obj));
                    const zig_color = objectToZigColor(self);
                    const rgb_result = zig_color.toRgb();

                    // Create a new RGB Python object
                    return createRgbPyObject(rgb_result);
                }
            }.method;
        }

        // Helper functions to create Python objects from Zig colors
        fn createHsvPyObject(hsv: zignal.Hsv) ?*c.PyObject {
            // Import the color module to access HsvType
            const color = @import("color.zig");

            // Create a new HSV object
            const hsv_obj = c.PyType_GenericNew(@ptrCast(&color.HsvType), null, null);
            if (hsv_obj == null) return null;

            const hsv_py = @as(*color.HsvBinding.PyObjectType, @ptrCast(hsv_obj));
            hsv_py.field0 = hsv.h;
            hsv_py.field1 = hsv.s;
            hsv_py.field2 = hsv.v;

            return hsv_obj;
        }

        fn createRgbPyObject(rgb: zignal.Rgb) ?*c.PyObject {
            // Import the color module to access RgbType
            const color = @import("color.zig");

            // Create a new RGB object
            const rgb_obj = c.PyType_GenericNew(@ptrCast(&color.RgbType), null, null);
            if (rgb_obj == null) return null;

            const rgb_py = @as(*color.RgbBinding.PyObjectType, @ptrCast(rgb_obj));
            rgb_py.field0 = rgb.r;
            rgb_py.field1 = rgb.g;
            rgb_py.field2 = rgb.b;

            return rgb_obj;
        }

        // Convert Python object to Zig color
        fn objectToZigColor(obj: *ObjectType) ZigColorType {
            var zig_color: ZigColorType = undefined;

            inline for (fields, 0..) |field, i| {
                const field_value = switch (i) {
                    0 => obj.field0,
                    1 => obj.field1,
                    2 => obj.field2,
                    3 => obj.field3,
                    else => unreachable,
                };
                @field(zig_color, field.name) = field_value;
            }

            return zig_color;
        }

        // Convert Zig color to Python object fields
        fn zigColorToObject(zig_color: ZigColorType, obj: *ObjectType) void {
            inline for (fields, 0..) |field, i| {
                const field_value = @field(zig_color, field.name);
                switch (i) {
                    0 => obj.field0 = field_value,
                    1 => obj.field1 = field_value,
                    2 => obj.field2 = field_value,
                    3 => obj.field3 = field_value,
                    else => unreachable,
                }
            }
        }

        // Custom init function with validation
        pub fn init(self_obj: [*c]c.PyObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) c_int {
            _ = kwds;
            const self = @as(*ObjectType, @ptrCast(self_obj));

            // Parse arguments based on field count
            switch (fields.len) {
                1 => {
                    var arg0: fields[0].type = undefined;
                    const format = comptime std.fmt.comptimePrint("{s}", .{py_utils.getFormatString(fields[0].type)});
                    if (c.PyArg_ParseTuple(args, format, &arg0) == 0) {
                        return -1;
                    }

                    if (config.validation_fn) |validator| {
                        if (!validator(fields[0].name, arg0)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    self.field0 = arg0;
                },
                2 => {
                    var arg0: fields[0].type = undefined;
                    var arg1: fields[1].type = undefined;
                    const format = comptime std.fmt.comptimePrint("{s}{s}", .{
                        py_utils.getFormatString(fields[0].type),
                        py_utils.getFormatString(fields[1].type),
                    });
                    if (c.PyArg_ParseTuple(args, format, &arg0, &arg1) == 0) {
                        return -1;
                    }

                    if (config.validation_fn) |validator| {
                        if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    self.field0 = arg0;
                    self.field1 = arg1;
                },
                3 => {
                    // For validation, we need to parse as larger types to avoid overflow
                    if (fields[0].type == u8) {
                        // RGB case: parse as int to avoid u8 wrapping, then validate
                        var arg0: c_int = undefined;
                        var arg1: c_int = undefined;
                        var arg2: c_int = undefined;
                        if (c.PyArg_ParseTuple(args, "iii", &arg0, &arg1, &arg2) == 0) {
                            return -1;
                        }

                        if (config.validation_fn) |validator| {
                            if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1) or !validator(fields[2].name, arg2)) {
                                c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                                return -1;
                            }
                        }

                        self.field0 = @intCast(arg0);
                        self.field1 = @intCast(arg1);
                        self.field2 = @intCast(arg2);
                    } else {
                        // Non-u8 case: use field types directly
                        var arg0: fields[0].type = undefined;
                        var arg1: fields[1].type = undefined;
                        var arg2: fields[2].type = undefined;
                        const format = comptime std.fmt.comptimePrint("{s}{s}{s}", .{
                            py_utils.getFormatString(fields[0].type),
                            py_utils.getFormatString(fields[1].type),
                            py_utils.getFormatString(fields[2].type),
                        });
                        if (c.PyArg_ParseTuple(args, format, &arg0, &arg1, &arg2) == 0) {
                            return -1;
                        }

                        if (config.validation_fn) |validator| {
                            if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1) or !validator(fields[2].name, arg2)) {
                                c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                                return -1;
                            }
                        }

                        self.field0 = arg0;
                        self.field1 = arg1;
                        self.field2 = arg2;
                    }
                },
                4 => {
                    var arg0: fields[0].type = undefined;
                    var arg1: fields[1].type = undefined;
                    var arg2: fields[2].type = undefined;
                    var arg3: fields[3].type = undefined;
                    const format = comptime std.fmt.comptimePrint("{s}{s}{s}{s}", .{
                        py_utils.getFormatString(fields[0].type),
                        py_utils.getFormatString(fields[1].type),
                        py_utils.getFormatString(fields[2].type),
                        py_utils.getFormatString(fields[3].type),
                    });
                    if (c.PyArg_ParseTuple(args, format, &arg0, &arg1, &arg2, &arg3) == 0) {
                        return -1;
                    }

                    if (config.validation_fn) |validator| {
                        if (!validator(fields[0].name, arg0) or !validator(fields[1].name, arg1) or !validator(fields[2].name, arg2) or !validator(fields[3].name, arg3)) {
                            c.PyErr_SetString(c.PyExc_ValueError, config.validation_error.ptr);
                            return -1;
                        }
                    }

                    self.field0 = arg0;
                    self.field1 = arg1;
                    self.field2 = arg2;
                    self.field3 = arg3;
                },
                else => unreachable,
            }

            return 0;
        }

        // Standard Python object methods
        pub fn dealloc(self_obj: [*c]c.PyObject) callconv(.c) void {
            c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
        }

        pub fn new(type_obj: [*c]c.PyTypeObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
            _ = args;
            _ = kwds;

            const self = @as(?*ObjectType, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
            if (self) |obj| {
                // Initialize fields to zero
                obj.field0 = std.mem.zeroes(fields[0].type);
                if (fields.len > 1) obj.field1 = std.mem.zeroes(fields[1].type);
                if (fields.len > 2) obj.field2 = std.mem.zeroes(fields[2].type);
                if (fields.len > 3) obj.field3 = std.mem.zeroes(fields[3].type);
            }
            return @ptrCast(self);
        }

        pub fn repr(self_obj: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
            const self = @as(*ObjectType, @ptrCast(self_obj));

            var buffer: [128]u8 = undefined;
            const formatted = switch (fields.len) {
                1 => std.fmt.bufPrintZ(&buffer, "{s}({s}={})", .{ name, fields[0].name, self.field0 }) catch return null,
                2 => std.fmt.bufPrintZ(&buffer, "{s}({s}={}, {s}={})", .{ name, fields[0].name, self.field0, fields[1].name, self.field1 }) catch return null,
                3 => std.fmt.bufPrintZ(&buffer, "{s}({s}={}, {s}={}, {s}={})", .{ name, fields[0].name, self.field0, fields[1].name, self.field1, fields[2].name, self.field2 }) catch return null,
                4 => std.fmt.bufPrintZ(&buffer, "{s}({s}={}, {s}={}, {s}={}, {s}={})", .{ name, fields[0].name, self.field0, fields[1].name, self.field1, fields[2].name, self.field2, fields[3].name, self.field3 }) catch return null,
                else => unreachable,
            };

            return @ptrCast(c.PyUnicode_FromString(formatted.ptr));
        }
    };
}

// Make getFormatString public
pub fn getFormatString(comptime T: type) []const u8 {
    return py_utils.getFormatString(T);
}

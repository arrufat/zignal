const std = @import("std");

const zignal = @import("zignal");
const isPacked = zignal.meta.isPacked;
const getSimpleTypeName = zignal.meta.getSimpleTypeName;

const c = @import("py_utils.zig").c;
const color = @import("color.zig");
const createColorPyObject = color.createColorPyObject;
const color_types = @import("color_registry.zig").color_types;
const ConversionError = @import("py_utils.zig").ConversionError;
const convertFromPython = @import("py_utils.zig").convertFromPython;
const convertToPython = @import("py_utils.zig").convertToPython;
const convertWithValidation = @import("py_utils.zig").convertWithValidation;
const enum_utils = @import("enum_utils.zig");
const getValidationErrorMessage = @import("color_registry.zig").getValidationErrorMessage;
const validateColorComponent = @import("color_registry.zig").validateColorComponent;

const Rgba = zignal.Rgba(u8);

/// Automatically generate documentation from type name for color conversion methods
pub fn getConversionMethodDoc(comptime TargetColorType: type) []const u8 {
    const type_name = @typeName(TargetColorType);
    if (comptime std.mem.lastIndexOf(u8, type_name, ".")) |dot_index| {
        const color_space = comptime type_name[dot_index + 1 ..];
        return comptime "Convert to `" ++ color_space ++ "` color space.";
    } else {
        @compileError("Expected zignal.ColorName format, got: " ++ type_name);
    }
}

/// Generate a color binding with automatic property getters and validation
pub fn ColorBinding(comptime ZigColorType: type) type {
    const name = comptime getSimpleTypeName(ZigColorType);
    const fields = @typeInfo(ZigColorType).@"struct".fields;
    const is_packed = isPacked(ZigColorType);

    // Create the Python object type manually (avoiding @Type complexity)
    const ObjectType = switch (fields.len) {
        1 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
        },
        2 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
            field1: fields[1].type,
        },
        3 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
            field1: fields[1].type,
            field2: fields[2].type,
        },
        4 => extern struct {
            ob_base: c.PyObject,
            field0: fields[0].type,
            field1: fields[1].type,
            field2: fields[2].type,
            field3: fields[3].type,
        },
        else => @compileError("Color types with more than 4 fields not supported yet"),
    };

    return struct {
        pub const PyObjectType = ObjectType;
        pub const ZigType = ZigColorType;

        /// Create a Python object from a Zig color value
        pub fn createPyObject(zig_color: ZigType, type_obj: *c.PyTypeObject) ?*c.PyObject {
            const obj = c.PyType_GenericNew(@ptrCast(type_obj), null, null);
            if (obj == null) return null;
            const py_obj: *PyObjectType = @ptrCast(obj);
            zigColorToObject(zig_color, py_obj);
            return obj;
        }

        /// Generate property getters and setters
        pub fn generateGetSet() [fields.len + 1]c.PyGetSetDef {
            var getset: [fields.len + 1]c.PyGetSetDef = undefined;
            inline for (fields, 0..) |field, i| {
                getset[i] = c.PyGetSetDef{
                    .name = field.name ++ "",
                    .get = generateFieldGetter(i),
                    .set = generateFieldSetter(i),
                    .doc = field.name ++ " component",
                    .closure = null,
                };
            }
            getset[fields.len] = c.PyGetSetDef{ .name = null, .get = null, .set = null, .doc = null, .closure = null };
            return getset;
        }

        /// Generate field getter for specific field index
        fn generateFieldGetter(comptime field_index: usize) fn ([*c]c.PyObject, ?*anyopaque) callconv(.c) [*c]c.PyObject {
            return struct {
                fn getter(self_obj: [*c]c.PyObject, closure: ?*anyopaque) callconv(.c) [*c]c.PyObject {
                    _ = closure;
                    const self: *ObjectType = @ptrCast(self_obj);
                    const value = switch (field_index) {
                        0 => self.field0,
                        1 => if (fields.len > 1) self.field1 else unreachable,
                        2 => if (fields.len > 2) self.field2 else unreachable,
                        3 => if (fields.len > 3) self.field3 else unreachable,
                        else => unreachable,
                    };
                    return @ptrCast(@alignCast(convertToPython(value)));
                }
            }.getter;
        }

        /// Generate field setter for specific field index
        fn generateFieldSetter(comptime field_index: usize) fn ([*c]c.PyObject, [*c]c.PyObject, ?*anyopaque) callconv(.c) c_int {
            return struct {
                fn setter(self_obj: [*c]c.PyObject, value_obj: [*c]c.PyObject, closure: ?*anyopaque) callconv(.c) c_int {
                    _ = closure;
                    const self: *ObjectType = @ptrCast(self_obj);

                    // Get field info
                    const field = fields[field_index];
                    const field_name = field.name;

                    // Convert Python value using idiomatic error union
                    const new_value = convertFromPython(field.type, @ptrCast(value_obj)) catch |err| {
                        switch (err) {
                            ConversionError.not_integer => {
                                c.PyErr_SetString(c.PyExc_TypeError, "Expected integer value");
                                return -1;
                            },
                            ConversionError.not_float => {
                                c.PyErr_SetString(c.PyExc_TypeError, "Expected float value");
                                return -1;
                            },
                            ConversionError.integer_out_of_range => {
                                // Generate helpful range message without the attempted value
                                if (@typeInfo(field.type) == .int) {
                                    const min_val = std.math.minInt(field.type);
                                    const max_val = std.math.maxInt(field.type);

                                    var buffer: [256]u8 = undefined;
                                    const msg = std.fmt.bufPrintZ(&buffer, "Value is out of range for {s} (valid range: {} to {})", .{ @typeName(field.type), min_val, max_val }) catch "Value out of range";

                                    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                                    return -1;
                                } else {
                                    c.PyErr_SetString(c.PyExc_ValueError, "Value out of range");
                                    return -1;
                                }
                            },
                            else => {
                                c.PyErr_SetString(c.PyExc_TypeError, "Unsupported value type");
                                return -1;
                            },
                        }
                    };

                    // Validate using the color registry
                    if (!validateColorComponent(ZigColorType, field_name, new_value)) {
                        const error_msg = getValidationErrorMessage(ZigColorType);
                        c.PyErr_SetString(c.PyExc_ValueError, error_msg.ptr);
                        return -1;
                    }

                    // Set the field value
                    switch (field_index) {
                        0 => self.field0 = new_value,
                        1 => if (fields.len > 1) {
                            self.field1 = new_value;
                        } else unreachable,
                        2 => if (fields.len > 2) {
                            self.field2 = new_value;
                        } else unreachable,
                        3 => if (fields.len > 3) {
                            self.field3 = new_value;
                        } else unreachable,
                        else => unreachable,
                    }

                    return 0; // Success
                }
            }.setter;
        }

        /// Generate methods array - __format__, blend, to, invert, luma, hex, from_hex, with_alpha
        pub fn generateMethods() [9]c.PyMethodDef {
            var methods: [9]c.PyMethodDef = undefined;
            var index: usize = 0;

            // Add __format__ method
            methods[index] = c.PyMethodDef{
                .ml_name = "__format__",
                .ml_meth = @ptrCast(&formatMethod),
                .ml_flags = c.METH_VARARGS,
                .ml_doc =
                \\Format the color object with optional format specifier.
                \\
                \\## Parameters
                \\- `format_spec` (str): Format specifier string:
                \\  - `''` (empty): Returns the default repr() output
                \\  - `'sgr'`: Returns SGR-colored terminal representation
                \\
                \\## Examples
                \\```python
                \\color = zignal.Rgb(255, 0, 0)
                \\print(f"{color}")        # Default repr: Rgb(r=255, g=0, b=0)
                \\print(f"{color:sgr}")   # SGR colored output in terminal
                \\```
                ,
            };
            index += 1;

            // Add blend method if the type has it
            if (@hasDecl(ZigColorType, "blend")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "blend",
                    .ml_meth = @ptrCast(&blendMethod),
                    .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS,
                    .ml_doc =
                    \\Blend with another color using the specified blend mode.
                    \\
                    \\## Parameters
                    \\- `overlay`: An `Rgba` color or tuple (r, g, b, a) with values 0-255
                    \\- `mode`: `Blending` enum value (optional, defaults to `Blending.NORMAL`)
                    \\
                    \\## Examples
                    \\```python
                    \\base = zignal.Rgb(255, 0, 0)
                    \\overlay = zignal.Rgba(0, 255, 0, 128)
                    \\
                    \\result = base.blend(overlay)
                    \\result = base.blend(overlay, mode=zignal.Blending.MULTIPLY)
                    \\```
                    ,
                };
                index += 1;
            }

            // Add generic to(space) conversion
            methods[index] = c.PyMethodDef{
                .ml_name = "to",
                .ml_meth = @ptrCast(&toMethod),
                .ml_flags = c.METH_VARARGS,
                .ml_doc = "Convert to the given color type (pass the class, e.g. zignal.Rgb).",
            };
            index += 1;

            if (@hasDecl(ZigColorType, "invert")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "invert",
                    .ml_meth = @ptrCast(&invertMethod),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Return a new color with inverted components while preserving alpha (if present).",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "luma")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "luma",
                    .ml_meth = @ptrCast(&lumaMethod),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Calculate the perceptual luminance (0.0 to 1.0) using ITU-R BT.709 coefficients.",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "hex")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "hex",
                    .ml_meth = @ptrCast(&hexMethod),
                    .ml_flags = c.METH_NOARGS,
                    .ml_doc = "Return the hexadecimal representation of the color (e.g. 0xRRGGBB or 0xRRGGBBAA).",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "initHex")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "from_hex",
                    .ml_meth = @ptrCast(&fromHexMethod),
                    .ml_flags = c.METH_VARARGS | c.METH_STATIC,
                    .ml_doc = "Create a color from a hexadecimal value (e.g. 0xRRGGBB or 0xRRGGBBAA).",
                };
                index += 1;
            }

            if (@hasDecl(ZigColorType, "withAlpha")) {
                methods[index] = c.PyMethodDef{
                    .ml_name = "with_alpha",
                    .ml_meth = @ptrCast(&withAlphaMethod),
                    .ml_flags = c.METH_VARARGS,
                    .ml_doc = "Return a new Rgba color with the specified alpha channel value.",
                };
                index += 1;
            }

            methods[index] = c.PyMethodDef{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null };
            return methods;
        }

        /// invert method implementation
        pub fn invertMethod(self_obj: [*c]c.PyObject, _: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const py_utils = @import("py_utils.zig");
            const self: *ObjectType = @ptrCast(self_obj);
            const inverted = objectToZigColor(self).invert();
            const result = createPyObject(inverted, py_utils.getPyType(self_obj)) orelse return null;
            return @ptrCast(result);
        }

        /// luma method implementation
        pub fn lumaMethod(self_obj: [*c]c.PyObject, _: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const self: *ObjectType = @ptrCast(self_obj);
            const luma_val = objectToZigColor(self).luma();
            return @ptrCast(convertToPython(luma_val));
        }

        /// hex method implementation
        pub fn hexMethod(self_obj: [*c]c.PyObject, _: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const self: *ObjectType = @ptrCast(self_obj);
            const hex_val = objectToZigColor(self).hex();
            return @ptrCast(convertToPython(hex_val));
        }

        /// from_hex method implementation (static)
        pub fn fromHexMethod(_: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            var hex_code: c_ulong = 0;
            if (c.PyArg_ParseTuple(args, "k", &hex_code) == 0) return null;

            const zig_color = ZigColorType.initHex(@intCast(hex_code));

            const color_module = @import("color.zig");
            return @ptrCast(color_module.createColorPyObject(zig_color));
        }

        /// with_alpha method implementation
        pub fn withAlphaMethod(self_obj: [*c]c.PyObject, args: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const self: *ObjectType = @ptrCast(self_obj);
            var alpha_obj: ?*c.PyObject = null;
            if (c.PyArg_ParseTuple(args, "O", &alpha_obj) == 0) return null;

            const field_type = @typeInfo(ZigColorType).@"struct".fields[0].type;
            var alpha: field_type = undefined;

            if (@typeInfo(field_type) == .float) {
                const val: f64 = blk: {
                    if (c.PyFloat_Check(alpha_obj.?) != 0) {
                        break :blk c.PyFloat_AsDouble(alpha_obj.?);
                    } else if (c.PyLong_Check(alpha_obj.?) != 0) {
                        break :blk @floatFromInt(c.PyLong_AsLong(alpha_obj.?));
                    } else {
                        c.PyErr_SetString(c.PyExc_TypeError, "alpha must be an int or float");
                        return null;
                    }
                };
                if (val < 0.0 or val > 1.0) {
                    c.PyErr_SetString(c.PyExc_ValueError, "Alpha value for float colors must be between 0.0 and 1.0");
                    return null;
                }
                alpha = @floatCast(val);
            } else if (field_type == u8) {
                if (c.PyFloat_Check(@as(*c.PyObject, @ptrCast(alpha_obj.?))) != 0) {
                    const val = c.PyFloat_AsDouble(@ptrCast(alpha_obj.?));
                    if (val < 0.0 or val > 1.0) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Alpha float value for integer colors must be between 0.0 and 1.0");
                        return null;
                    }
                    alpha = @intFromFloat(@round(val * 255.0));
                } else if (c.PyLong_Check(@as(*c.PyObject, @ptrCast(alpha_obj.?))) != 0) {
                    const val = c.PyLong_AsLong(@ptrCast(alpha_obj.?));
                    if (val < 0 or val > 255) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Alpha integer value must be between 0 and 255");
                        return null;
                    }
                    alpha = @intCast(val);
                } else {
                    c.PyErr_SetString(c.PyExc_TypeError, "alpha must be an int or float");
                    return null;
                }
            } else {
                @compileError("unsupported field type for with_alpha");
            }

            const zig_color = objectToZigColor(self);
            const with_alpha = zig_color.withAlpha(alpha);

            // Need to find RgbaType to create the correct object
            const color_module = @import("color.zig");
            const result = color_module.createColorPyObject(with_alpha);
            if (result == null) {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to create color object");
                return null;
            }
            return @ptrCast(result);
        }

        /// Blend method implementation
        pub fn blendMethod(self_obj: [*c]c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const self: *ObjectType = @ptrCast(self_obj);

            // Parse arguments: overlay (required) and mode (optional keyword, defaults to NORMAL)
            const py_utils_local = @import("py_utils.zig");
            const Params = struct {
                overlay: ?*c.PyObject,
                mode: ?*c.PyObject = null,
            };
            var params: Params = undefined;
            py_utils_local.parseArgs(Params, args, kwds, &params) catch return null;

            const overlay_obj = params.overlay;
            const mode_obj = params.mode;

            // Convert overlay to Zig Rgba
            var overlay: Rgba = undefined;

            // Check if overlay is an Rgba instance
            if (c.PyObject_IsInstance(overlay_obj, @ptrCast(&color.rgba)) == 1) {
                // It's an Rgba object, extract directly
                const overlay_pyobj: *color.RgbaBinding.PyObjectType = @ptrCast(overlay_obj);
                overlay = .{
                    .r = overlay_pyobj.field0,
                    .g = overlay_pyobj.field1,
                    .b = overlay_pyobj.field2,
                    .a = overlay_pyobj.field3,
                };
            } else if (c.PyTuple_Check(overlay_obj) == 1) {
                // It's a tuple, parse RGBA values using PyArg_ParseTuple
                var r: c_long = undefined;
                var g: c_long = undefined;
                var b: c_long = undefined;
                var a: c_long = undefined;

                if (c.PyArg_ParseTuple(overlay_obj, "llll", &r, &g, &b, &a) == 0) {
                    c.PyErr_SetString(c.PyExc_TypeError, "overlay tuple must contain 4 integers (r, g, b, a)");
                    return null;
                }

                // Validate ranges using py_utils helper (it sets appropriate error messages)
                const py_utils = @import("py_utils.zig");
                const r_val = py_utils.validateRange(u8, r, 0, 255, "r") catch return null;
                const g_val = py_utils.validateRange(u8, g, 0, 255, "g") catch return null;
                const b_val = py_utils.validateRange(u8, b, 0, 255, "b") catch return null;
                const a_val = py_utils.validateRange(u8, a, 0, 255, "a") catch return null;

                overlay = .{
                    .r = r_val,
                    .g = g_val,
                    .b = b_val,
                    .a = a_val,
                };
            } else {
                c.PyErr_SetString(c.PyExc_TypeError, "overlay must be an Rgba color or a tuple of 4 integers (r, g, b, a)");
                return null;
            }

            // Convert mode to Zig Blending (use NORMAL if not provided), in case of failure the error set by enum_utils
            const mode = if (mode_obj) |obj| enum_utils.pyToEnum(zignal.Blending, obj) catch return null else .normal;

            // Convert self to Zig color
            const zig_color = objectToZigColor(self);

            // Perform the blend
            const blended = zig_color.blend(overlay, mode);

            // Create and return new Python object with the blended result
            const type_obj: *c.PyTypeObject = @ptrCast(self_obj.*.ob_type);
            return createPyObject(blended, type_obj);
        }

        /// Map a Python color class object to the underlying ColorSpace
        fn colorSpaceFromPyType(type_obj: *c.PyTypeObject) ?zignal.ColorSpace {
            const type_name_str = std.mem.span(type_obj.tp_name);
            inline for (color_types) |ColorType| {
                const type_name = comptime zignal.meta.getGenericBaseName(ColorType);
                const full_name = comptime "zignal." ++ type_name;

                if (std.mem.eql(u8, type_name_str, full_name)) {
                    return ColorType.space;
                }
            }
            return null;
        }

        /// to(space) method implementation using Python color classes
        pub fn toMethod(self_obj: [*c]c.PyObject, args: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const self: *ObjectType = @ptrCast(self_obj);
            var target_type_obj: ?*c.PyObject = null;
            if (args == null or c.PyArg_ParseTuple(args.?, "O", &target_type_obj) == 0) return null;

            if (c.PyType_Check(target_type_obj) == 0) {
                c.PyErr_SetString(c.PyExc_TypeError, "Expected a zignal color type (e.g., zignal.Rgb)");
                return null;
            }

            const target_space = colorSpaceFromPyType(@ptrCast(target_type_obj.?)) orelse {
                c.PyErr_SetString(c.PyExc_TypeError, "Unsupported target color type");
                return null;
            };

            const zig_color = objectToZigColor(self);

            const ColorType = @TypeOf(zig_color);
            const is_u8_backed = switch (@typeInfo(ColorType)) {
                .@"struct" => |info| info.fields[0].type == u8,
                else => false,
            };
            const float_color = if (is_u8_backed) zig_color.as(f64) else zig_color;

            const result_obj = switch (target_space) {
                .gray => createColorPyObject(float_color.to(.gray).as(u8)),
                .rgb => createColorPyObject(float_color.to(.rgb).as(u8)),
                .rgba => createColorPyObject(float_color.to(.rgba).as(u8)),
                .ycbcr => createColorPyObject(float_color.to(.ycbcr).as(u8)),
                inline else => |s| createColorPyObject(float_color.to(s)),
            };

            return @ptrCast(result_obj);
        }

        /// Convert Python object to Zig color
        fn objectToZigColor(obj: *ObjectType) ZigColorType {
            if (comptime is_packed) {
                // For packed structs, create a temporary unpacked representation
                // then use @bitCast to convert to packed layout
                return switch (fields.len) {
                    4 => blk: {
                        // Create array of bytes for packed struct
                        const bytes = [4]u8{ obj.field0, obj.field1, obj.field2, obj.field3 };
                        break :blk @bitCast(bytes);
                    },
                    3 => blk: {
                        // Create array of bytes for packed struct
                        const bytes = [3]u8{ obj.field0, obj.field1, obj.field2 };
                        break :blk @bitCast(bytes);
                    },
                    2 => blk: {
                        // Create array of bytes for packed struct
                        const bytes = [2]u8{ obj.field0, obj.field1 };
                        break :blk @bitCast(bytes);
                    },
                    1 => blk: {
                        // Single field packed struct
                        break :blk @bitCast([1]u8{obj.field0});
                    },
                    else => @compileError("Unsupported field count for packed struct"),
                };
            } else {
                // Regular struct - use field-by-field assignment
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
        }

        /// Convert Zig color to Python object fields
        pub fn zigColorToObject(zig_color: ZigColorType, obj: *ObjectType) void {
            if (comptime is_packed) {
                // For packed structs, convert to byte array using @bitCast
                const bytes: [fields.len]u8 = @bitCast(zig_color);
                switch (fields.len) {
                    4 => {
                        obj.field0 = bytes[0];
                        obj.field1 = bytes[1];
                        obj.field2 = bytes[2];
                        obj.field3 = bytes[3];
                    },
                    3 => {
                        obj.field0 = bytes[0];
                        obj.field1 = bytes[1];
                        obj.field2 = bytes[2];
                    },
                    2 => {
                        obj.field0 = bytes[0];
                        obj.field1 = bytes[1];
                    },
                    1 => {
                        obj.field0 = bytes[0];
                    },
                    else => @compileError("Unsupported field count for packed struct"),
                }
            } else {
                // Regular struct - use field-by-field assignment
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
        }

        /// Helper function to convert Python object to field type with color validation
        fn convertArgument(comptime T: type, py_obj: ?*c.PyObject, field_name: []const u8) !T {
            const validator = struct {
                fn validate(field_name_inner: []const u8, value: anytype) bool {
                    return validateColorComponent(ZigColorType, field_name_inner, value);
                }
            }.validate;

            const error_msg = getValidationErrorMessage(ZigColorType);
            return convertWithValidation(T, @ptrCast(py_obj), field_name, validator, error_msg);
        }

        /// Custom init function with validation
        pub fn init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
            _ = kwds;

            // Handle null pointers using Zig's type system
            const self: *ObjectType = @ptrCast(self_obj orelse {
                c.PyErr_SetString(c.PyExc_SystemError, "self object is null");
                return -1;
            });

            const args_tuple = args orelse {
                c.PyErr_SetString(c.PyExc_SystemError, "args object is null");
                return -1;
            };

            // Parse arguments based on field count
            switch (fields.len) {
                1 => {
                    // Parse as Python object for consistent type safety
                    var py_arg0: ?*c.PyObject = null;
                    if (c.PyArg_ParseTuple(args_tuple, "O", &py_arg0) == 0) {
                        return -1;
                    }

                    // Convert using helper function with integrated validation
                    const arg0 = convertArgument(fields[0].type, py_arg0, fields[0].name) catch {
                        return -1;
                    };

                    self.field0 = arg0;
                },
                2 => {
                    // Parse as Python objects for consistent type safety
                    var py_arg0: ?*c.PyObject = null;
                    var py_arg1: ?*c.PyObject = null;
                    if (c.PyArg_ParseTuple(args_tuple, "OO", &py_arg0, &py_arg1) == 0) {
                        return -1;
                    }

                    // Convert using helper function with integrated validation
                    const arg0 = convertArgument(fields[0].type, py_arg0, fields[0].name) catch {
                        return -1;
                    };
                    const arg1 = convertArgument(fields[1].type, py_arg1, fields[1].name) catch {
                        return -1;
                    };

                    self.field0 = arg0;
                    self.field1 = arg1;
                },
                3 => {
                    // Parse as Python objects for consistent type safety
                    var py_arg0: ?*c.PyObject = null;
                    var py_arg1: ?*c.PyObject = null;
                    var py_arg2: ?*c.PyObject = null;
                    if (c.PyArg_ParseTuple(args_tuple, "OOO", &py_arg0, &py_arg1, &py_arg2) == 0) {
                        return -1;
                    }

                    // Convert using helper function with integrated validation
                    const arg0 = convertArgument(fields[0].type, py_arg0, fields[0].name) catch {
                        return -1;
                    };
                    const arg1 = convertArgument(fields[1].type, py_arg1, fields[1].name) catch {
                        return -1;
                    };
                    const arg2 = convertArgument(fields[2].type, py_arg2, fields[2].name) catch {
                        return -1;
                    };

                    self.field0 = arg0;
                    self.field1 = arg1;
                    self.field2 = arg2;
                },
                4 => {
                    // Parse as Python objects for consistent type safety
                    var py_arg0: ?*c.PyObject = null;
                    var py_arg1: ?*c.PyObject = null;
                    var py_arg2: ?*c.PyObject = null;
                    var py_arg3: ?*c.PyObject = null;
                    if (c.PyArg_ParseTuple(args_tuple, "OOOO", &py_arg0, &py_arg1, &py_arg2, &py_arg3) == 0) {
                        return -1;
                    }

                    // Convert using helper function with integrated validation
                    const arg0 = convertArgument(fields[0].type, py_arg0, fields[0].name) catch {
                        return -1;
                    };
                    const arg1 = convertArgument(fields[1].type, py_arg1, fields[1].name) catch {
                        return -1;
                    };
                    const arg2 = convertArgument(fields[2].type, py_arg2, fields[2].name) catch {
                        return -1;
                    };
                    const arg3 = convertArgument(fields[3].type, py_arg3, fields[3].name) catch {
                        return -1;
                    };

                    self.field0 = arg0;
                    self.field1 = arg1;
                    self.field2 = arg2;
                    self.field3 = arg3;
                },
                else => unreachable,
            }

            return 0;
        }

        /// Standard Python object methods
        pub fn dealloc(self_obj: [*c]c.PyObject) callconv(.c) void {
            const py_utils = @import("py_utils.zig");
            py_utils.getPyType(self_obj).*.tp_free.?(self_obj);
        }

        pub fn new(type_obj: [*c]c.PyTypeObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
            _ = args;
            _ = kwds;

            const self: ?*ObjectType = @ptrCast(c.PyType_GenericAlloc(type_obj, 0));
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
            const self: *ObjectType = @ptrCast(self_obj);

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

        /// Rich comparison method implementing RGBA-based equality/inequality
        /// Colors are compared by their RGBA representation for visual equivalence
        pub fn richcompare(self_obj: [*c]c.PyObject, other_obj: [*c]c.PyObject, op: c_int) callconv(.c) [*c]c.PyObject {
            const py_utils = @import("py_utils.zig");
            const color_utils = @import("color_utils.zig");

            // Only handle == (Py_EQ=2) and != (Py_NE=3); defer other comparisons
            if (op != c.Py_EQ and op != c.Py_NE) {
                const not_impl = c.Py_NotImplemented();
                c.Py_INCREF(not_impl);
                return not_impl;
            }

            // Convert self to RGBA
            const self_rgba = color_utils.parseColor(Rgba, self_obj) catch {
                // If conversion fails, clear error and return NotImplemented
                c.PyErr_Clear();
                const not_impl = c.Py_NotImplemented();
                c.Py_INCREF(not_impl);
                return not_impl;
            };

            // Convert other to RGBA
            const other_rgba = color_utils.parseColor(Rgba, other_obj) catch {
                // If conversion fails, clear error and return NotImplemented
                c.PyErr_Clear();
                const not_impl = c.Py_NotImplemented();
                c.Py_INCREF(not_impl);
                return not_impl;
            };

            const equal = self_rgba == other_rgba;

            const result = if (op == c.Py_EQ) equal else !equal;
            return @ptrCast(py_utils.getPyBool(result));
        }

        /// __format__ method implementation
        pub fn formatMethod(self_obj: [*c]c.PyObject, args: ?*c.PyObject) callconv(.c) [*c]c.PyObject {
            const self: *ObjectType = @ptrCast(self_obj);

            // Parse format_spec argument
            var format_spec: [*c]const u8 = undefined;
            const format = std.fmt.comptimePrint("s", .{});
            if (args == null or c.PyArg_ParseTuple(args.?, format.ptr, &format_spec) == 0) {
                return null;
            }

            // Convert C string to Zig slice
            const format_str = std.mem.span(format_spec);
            if (std.mem.eql(u8, format_str, "sgr")) {
                const zig_color = objectToZigColor(self);
                const rgb = zig_color.to(.rgb).as(u8);
                const fg: u8 = if (rgb.as(f32).to(.oklab).l < 0.5) 255 else 0;

                // Build SGR formatted string with Python-style repr
                var buffer: [512]u8 = undefined;
                var offset: usize = 0;

                // Start with SGR escape codes and type name
                const header = std.fmt.bufPrint(
                    buffer[offset..],
                    "\x1b[1m\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m{s}(",
                    .{ fg, fg, fg, rgb.r, rgb.g, rgb.b, name },
                ) catch return null;
                offset += header.len;

                // Print each field in Python style (field=value)
                inline for (fields, 0..) |field, i| {
                    const field_name = std.fmt.bufPrint(
                        buffer[offset..],
                        "{s}=",
                        .{field.name},
                    ) catch return null;
                    offset += field_name.len;

                    // Format the field value appropriately
                    const value = switch (i) {
                        0 => self.field0,
                        1 => self.field1,
                        2 => self.field2,
                        3 => self.field3,
                        else => unreachable,
                    };

                    const field_value = switch (field.type) {
                        u8 => std.fmt.bufPrint(buffer[offset..], "{d}", .{value}) catch return null,
                        f64 => std.fmt.bufPrint(buffer[offset..], "{d}", .{value}) catch return null,
                        else => std.fmt.bufPrint(buffer[offset..], "{any}", .{value}) catch return null,
                    };
                    offset += field_value.len;

                    if (i < fields.len - 1) {
                        const sep = std.fmt.bufPrint(buffer[offset..], ", ", .{}) catch return null;
                        offset += sep.len;
                    }
                }

                // Close parenthesis and reset SGR codes
                const footer = std.fmt.bufPrint(buffer[offset..], ")\x1b[0m", .{}) catch return null;
                offset += footer.len;

                const formatted = buffer[0..offset];
                return @ptrCast(c.PyUnicode_FromStringAndSize(formatted.ptr, @intCast(formatted.len)));
            } else if (format_str.len == 0) {
                // Empty format spec - use repr
                return repr(self_obj);
            } else {
                // Unknown format spec
                _ = c.PyErr_Format(c.PyExc_ValueError, "Unknown format code '%s' for object of type '%s'", format_spec, name.ptr);
                return null;
            }
        }
    };
}

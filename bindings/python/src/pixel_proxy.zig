const std = @import("std");

const zignal = @import("zignal");

const color_registry = @import("color_registry.zig");
const color_utils = @import("color_utils.zig");
const ImageObject = @import("image.zig").ImageObject;
const py_utils = @import("py_utils.zig");
const c = py_utils.c;

// Proxy object layouts
const RgbPixelProxy = extern struct {
    ob_base: c.PyObject,
    parent: ?*c.PyObject,
    row: c.Py_ssize_t,
    col: c.Py_ssize_t,
};

const RgbaPixelProxy = extern struct {
    ob_base: c.PyObject,
    parent: ?*c.PyObject,
    row: c.Py_ssize_t,
    col: c.Py_ssize_t,
};

fn PixelProxyBinding(comptime ColorType: type, comptime ProxyObjectType: type) type {
    const fields = @typeInfo(ColorType).@"struct".fields;

    return struct {
        const Self = @This();

        fn parentFromObj(self_obj: ?*c.PyObject) ?*ImageObject {
            const self = @as(*ProxyObjectType, @ptrCast(self_obj.?));
            if (self.parent) |p| return @as(*ImageObject, @ptrCast(p));
            return null;
        }

        // Helper function to delegate method calls to the underlying color object
        fn delegateToColorMethod(self_obj: ?*c.PyObject, method_name: [*c]const u8, args: ?*c.PyObject) ?*c.PyObject {
            // Get the color object via item()
            const color_obj = itemMethod(self_obj, @ptrCast(@alignCast(args orelse c.PyTuple_New(0)))) orelse return null;
            defer c.Py_DECREF(color_obj);

            // Get the method from the color object
            const method_ptr = c.PyObject_GetAttrString(color_obj, method_name);
            if (method_ptr == null) return null;
            defer c.Py_DECREF(method_ptr);

            // Call the method with the provided arguments
            const result = if (args) |a| c.PyObject_CallObject(method_ptr, a) else c.PyObject_CallObject(method_ptr, c.PyTuple_New(0));
            return result;
        }

        fn repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            // Delegate to the color object's repr
            return delegateToColorMethod(self_obj, "__repr__", null);
        }

        fn dealloc(self_obj: [*c]c.PyObject) callconv(.c) void {
            const self = @as(*ProxyObjectType, @ptrCast(self_obj));
            if (self.parent) |parent| c.Py_DECREF(parent);
            c.PyObject_Free(@ptrCast(self));
        }

        fn richcompare(self_obj: [*c]c.PyObject, other_obj: [*c]c.PyObject, op: c_int) callconv(.c) [*c]c.PyObject {
            if (op != c.Py_EQ and op != c.Py_NE) {
                const not_impl = c.Py_NotImplemented();
                c.Py_INCREF(not_impl);
                return not_impl;
            }
            const parent = Self.parentFromObj(@ptrCast(self_obj));
            if (parent == null or parent.?.py_image == null) {
                return @ptrCast(py_utils.getPyBool(op != c.Py_EQ));
            }
            const proxy = @as(*ProxyObjectType, @ptrCast(self_obj));
            const px = parent.?.py_image.?.getPixelRgba(@intCast(proxy.row), @intCast(proxy.col));

            var equal = false;
            const other: ?*c.PyObject = @ptrCast(other_obj);
            const parsed = color_utils.parseColor(zignal.Rgba, other) catch null;
            if (parsed) |rgba| {
                if (std.meta.eql(ColorType, zignal.Rgb)) {
                    equal = (px.r == rgba.r and px.g == rgba.g and px.b == rgba.b and rgba.a == 255);
                } else if (std.meta.eql(ColorType, zignal.Rgba)) {
                    equal = (px.r == rgba.r and px.g == rgba.g and px.b == rgba.b and px.a == rgba.a);
                } else {
                    equal = (px == rgba);
                }
            } else {
                if (c.PyErr_Occurred() != null) c.PyErr_Clear();
                const not_impl = c.Py_NotImplemented();
                c.Py_INCREF(not_impl);
                return not_impl;
            }
            return if (op == c.Py_EQ) @ptrCast(py_utils.getPyBool(equal)) else @ptrCast(py_utils.getPyBool(!equal));
        }

        fn getField(comptime index: usize) fn (?*c.PyObject, ?*anyopaque) callconv(.c) ?*c.PyObject {
            return struct {
                fn getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
                    _ = closure;
                    const parent = Self.parentFromObj(self_obj) orelse {
                        c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
                        return null;
                    };
                    if (parent.py_image) |pimg| {
                        const proxy = @as(*ProxyObjectType, @ptrCast(self_obj.?));
                        const rgba = pimg.getPixelRgba(@intCast(proxy.row), @intCast(proxy.col));
                        const value = @field(rgba, fields[index].name);
                        return py_utils.convertToPython(value);
                    }
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
                    return null;
                }
            }.getter;
        }

        fn setField(comptime index: usize) fn (?*c.PyObject, ?*c.PyObject, ?*anyopaque) callconv(.c) c_int {
            return struct {
                fn setter(self_obj: ?*c.PyObject, value: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) c_int {
                    _ = closure;
                    if (value == null) {
                        c.PyErr_SetString(c.PyExc_TypeError, "Cannot delete attribute");
                        return -1;
                    }
                    const T = fields[index].type;
                    const field_name = fields[index].name;
                    const parsed = py_utils.convertFromPython(T, value) catch |err| {
                        switch (err) {
                            py_utils.ConversionError.not_integer => {
                                c.PyErr_SetString(c.PyExc_TypeError, "Expected integer value");
                                return -1;
                            },
                            py_utils.ConversionError.not_float => {
                                c.PyErr_SetString(c.PyExc_TypeError, "Expected float value");
                                return -1;
                            },
                            py_utils.ConversionError.integer_out_of_range, py_utils.ConversionError.float_out_of_range => {
                                if (std.meta.eql(ColorType, zignal.Rgb) or std.meta.eql(ColorType, zignal.Rgba)) {
                                    c.PyErr_SetString(c.PyExc_ValueError, "Value must be between 0 and 255");
                                } else {
                                    const msg = color_registry.getValidationErrorMessage(ColorType);
                                    c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                                }
                                return -1;
                            },
                            else => {
                                c.PyErr_SetString(c.PyExc_TypeError, "Unsupported value type");
                                return -1;
                            },
                        }
                    };
                    if (!color_registry.validateColorComponent(ColorType, field_name, parsed)) {
                        if (std.meta.eql(ColorType, zignal.Rgb) or std.meta.eql(ColorType, zignal.Rgba)) {
                            c.PyErr_SetString(c.PyExc_ValueError, "Value must be between 0 and 255");
                        } else {
                            const msg = color_registry.getValidationErrorMessage(ColorType);
                            c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
                        }
                        return -1;
                    }
                    const parent = Self.parentFromObj(self_obj) orelse {
                        c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
                        return -1;
                    };
                    if (parent.py_image) |pimg| {
                        const proxy = @as(*ProxyObjectType, @ptrCast(self_obj.?));
                        var px = pimg.getPixelRgba(@intCast(proxy.row), @intCast(proxy.col));
                        @field(px, field_name) = parsed;
                        pimg.setPixelRgba(@intCast(proxy.row), @intCast(proxy.col), px);
                        return 0;
                    }
                    c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
                    return -1;
                }
            }.setter;
        }

        pub fn generateGetSet() [fields.len + 1]c.PyGetSetDef {
            var arr: [fields.len + 1]c.PyGetSetDef = undefined;
            inline for (fields, 0..) |f, i| {
                arr[i] = c.PyGetSetDef{
                    .name = f.name ++ "",
                    .get = Self.getField(i),
                    .set = Self.setField(i),
                    .doc = f.name ++ " component",
                    .closure = null,
                };
            }
            arr[fields.len] = c.PyGetSetDef{ .name = null, .get = null, .set = null, .doc = null, .closure = null };
            return arr;
        }

        // __format__ method implementation - delegate to color object
        fn formatMethod(self_obj: ?*c.PyObject, args: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
            return delegateToColorMethod(self_obj, "__format__", @ptrCast(args));
        }

        // to_gray method implementation - delegate to color object
        fn toGrayMethod(self_obj: ?*c.PyObject, args: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
            _ = args;
            return delegateToColorMethod(self_obj, "to_gray", null);
        }

        // item method implementation - extract the pixel value as a color object
        fn itemMethod(self_obj: ?*c.PyObject, _: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
            const parent = Self.parentFromObj(self_obj) orelse {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
                return null;
            };

            if (parent.py_image) |pimg| {
                const proxy = @as(*ProxyObjectType, @ptrCast(self_obj.?));
                const rgba = pimg.getPixelRgba(@intCast(proxy.row), @intCast(proxy.col));

                // Return the color as the appropriate type
                if (ColorType == zignal.Rgb) {
                    const color_mod = @import("color.zig");
                    const obj = c.PyType_GenericNew(@ptrCast(&color_mod.RgbType), null, null);
                    if (obj == null) return null;
                    const py_obj = @as(*color_mod.RgbBinding.PyObjectType, @ptrCast(obj));
                    py_obj.field0 = rgba.r;
                    py_obj.field1 = rgba.g;
                    py_obj.field2 = rgba.b;
                    return obj;
                } else {
                    const color_mod = @import("color.zig");
                    const obj = c.PyType_GenericNew(@ptrCast(&color_mod.RgbaType), null, null);
                    if (obj == null) return null;
                    const py_obj = @as(*color_mod.RgbaBinding.PyObjectType, @ptrCast(obj));
                    py_obj.field0 = rgba.r;
                    py_obj.field1 = rgba.g;
                    py_obj.field2 = rgba.b;
                    py_obj.field3 = rgba.a;
                    return obj;
                }
            }

            c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
            return null;
        }

        // blend method implementation
        fn blendMethod(self_obj: ?*c.PyObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
            const Params = struct {
                overlay: ?*c.PyObject,
                mode: ?*c.PyObject = null,
            };
            var params: Params = undefined;
            py_utils.parseArgs(Params, args, kwds, &params) catch return null;

            const overlay_obj = params.overlay;
            const mode_obj = params.mode;

            const parent = Self.parentFromObj(self_obj) orelse {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
                return null;
            };

            if (parent.py_image) |pimg| {
                const proxy = @as(*ProxyObjectType, @ptrCast(self_obj.?));

                // Parse overlay color
                const overlay = color_utils.parseColor(zignal.Rgba, overlay_obj) catch {
                    // Error already set by parseColorTo
                    return null;
                };

                // Parse blend mode
                const enum_utils = @import("enum_utils.zig");
                const mode = if (mode_obj != null)
                    enum_utils.pyToEnum(zignal.Blending, mode_obj.?) catch {
                        // Error already set
                        return null;
                    }
                else
                    zignal.Blending.normal;

                // Get current pixel, blend, and write back
                const current = pimg.getPixelRgba(@intCast(proxy.row), @intCast(proxy.col));
                const blended = current.blend(overlay, mode);
                pimg.setPixelRgba(@intCast(proxy.row), @intCast(proxy.col), blended);

                // Return the new blended color as an Rgb or Rgba object
                if (ColorType == zignal.Rgb) {
                    const color_mod = @import("color.zig");
                    const obj = c.PyType_GenericNew(@ptrCast(&color_mod.RgbType), null, null);
                    if (obj == null) return null;
                    const py_obj = @as(*color_mod.RgbBinding.PyObjectType, @ptrCast(obj));
                    py_obj.field0 = blended.r;
                    py_obj.field1 = blended.g;
                    py_obj.field2 = blended.b;
                    return obj;
                } else {
                    const color_mod = @import("color.zig");
                    const obj = c.PyType_GenericNew(@ptrCast(&color_mod.RgbaType), null, null);
                    if (obj == null) return null;
                    const py_obj = @as(*color_mod.RgbaBinding.PyObjectType, @ptrCast(obj));
                    py_obj.field0 = blended.r;
                    py_obj.field1 = blended.g;
                    py_obj.field2 = blended.b;
                    py_obj.field3 = blended.a;
                    return obj;
                }
            }

            c.PyErr_SetString(c.PyExc_RuntimeError, "Invalid pixel proxy");
            return null;
        }

        // Generate conversion method for a specific target color type - delegate to color object
        fn generateConversionMethod(comptime TargetColorType: type) c.PyCFunction {
            const method_name = comptime getConversionMethodName(TargetColorType);
            return struct {
                fn method(self_obj: ?*c.PyObject, args: [*c]c.PyObject) callconv(.c) ?*c.PyObject {
                    // Delegate to the color object's conversion method
                    return delegateToColorMethod(self_obj, method_name.ptr, @ptrCast(args));
                }
            }.method;
        }

        // Helper to get conversion method name as a comptime string
        fn getConversionMethodName(comptime TargetType: type) []const u8 {
            const type_name = zignal.meta.getSimpleTypeName(TargetType);
            return "to_" ++ zignal.meta.comptimeLowercase(type_name);
        }

        // Generate methods array
        // Note: +4 for __format__, blend, to_gray, item, +1 for null terminator, -1 because we skip self-conversion
        pub fn generateMethods() [color_registry.color_types.len + 4]c.PyMethodDef {
            var methods: [color_registry.color_types.len + 4]c.PyMethodDef = undefined;
            var index: usize = 0;

            // Add __format__ method
            methods[index] = c.PyMethodDef{
                .ml_name = "__format__",
                .ml_meth = @ptrCast(&formatMethod),
                .ml_flags = c.METH_VARARGS,
                .ml_doc = "Format the pixel with optional format specifier (supports 'sgr')",
            };
            index += 1;

            // Add blend method
            methods[index] = c.PyMethodDef{
                .ml_name = "blend",
                .ml_meth = @ptrCast(&blendMethod),
                .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS,
                .ml_doc = "Blend with another color using the specified blend mode",
            };
            index += 1;

            // Add to_gray method
            methods[index] = c.PyMethodDef{
                .ml_name = "to_gray",
                .ml_meth = @ptrCast(&toGrayMethod),
                .ml_flags = c.METH_NOARGS,
                .ml_doc = "Convert to grayscale value (0-255)",
            };
            index += 1;

            // Add item method
            methods[index] = c.PyMethodDef{
                .ml_name = "item",
                .ml_meth = @ptrCast(&itemMethod),
                .ml_flags = c.METH_NOARGS,
                .ml_doc = "Extract the pixel value as a color object",
            };
            index += 1;

            // Generate conversion methods for each color type
            inline for (color_registry.color_types) |TargetColorType| {
                // Skip self-conversion - use .item() instead
                if (TargetColorType == ColorType) continue;

                const method_name = comptime getConversionMethodName(TargetColorType);

                methods[index] = c.PyMethodDef{
                    .ml_name = method_name.ptr,
                    .ml_meth = generateConversionMethod(TargetColorType),
                    .ml_flags = if (TargetColorType == zignal.Rgba) c.METH_VARARGS else c.METH_NOARGS,
                    .ml_doc = "Convert to " ++ @typeName(TargetColorType),
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
    };
}

const RgbProxyBinding = PixelProxyBinding(zignal.Rgb, RgbPixelProxy);
const RgbaProxyBinding = PixelProxyBinding(zignal.Rgba, RgbaPixelProxy);

var rgb_proxy_getset = RgbProxyBinding.generateGetSet();
var rgba_proxy_getset = RgbaProxyBinding.generateGetSet();
var rgb_proxy_methods = RgbProxyBinding.generateMethods();
var rgba_proxy_methods = RgbaProxyBinding.generateMethods();

pub var RgbPixelProxyType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.RgbPixelProxy",
    .tp_basicsize = @sizeOf(RgbPixelProxy),
    .tp_dealloc = RgbProxyBinding.dealloc,
    .tp_repr = RgbProxyBinding.repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Proxy object for RGB pixel access",
    .tp_methods = @ptrCast(&rgb_proxy_methods),
    .tp_getset = @ptrCast(&rgb_proxy_getset),
    .tp_richcompare = RgbProxyBinding.richcompare,
};

pub var RgbaPixelProxyType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.RgbaPixelProxy",
    .tp_basicsize = @sizeOf(RgbaPixelProxy),
    .tp_dealloc = RgbaProxyBinding.dealloc,
    .tp_repr = RgbaProxyBinding.repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Proxy object for RGBA pixel access",
    .tp_methods = @ptrCast(&rgba_proxy_methods),
    .tp_getset = @ptrCast(&rgba_proxy_getset),
    .tp_richcompare = RgbaProxyBinding.richcompare,
};

pub fn makeRgbProxy(parent: ?*c.PyObject, row: c.Py_ssize_t, col: c.Py_ssize_t) ?*c.PyObject {
    const proxy_obj = c.PyType_GenericAlloc(@ptrCast(&RgbPixelProxyType), 0);
    if (proxy_obj == null) return null;
    const proxy = @as(*RgbPixelProxy, @ptrCast(proxy_obj));
    proxy.parent = parent;
    proxy.row = row;
    proxy.col = col;
    if (parent != null) c.Py_INCREF(parent);
    return proxy_obj;
}

pub fn makeRgbaProxy(parent: ?*c.PyObject, row: c.Py_ssize_t, col: c.Py_ssize_t) ?*c.PyObject {
    const proxy_obj = c.PyType_GenericAlloc(@ptrCast(&RgbaPixelProxyType), 0);
    if (proxy_obj == null) return null;
    const proxy = @as(*RgbaPixelProxy, @ptrCast(proxy_obj));
    proxy.parent = parent;
    proxy.row = row;
    proxy.col = col;
    if (parent != null) c.Py_INCREF(parent);
    return proxy_obj;
}

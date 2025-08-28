const std = @import("std");

const zignal = @import("zignal");

const color_registry = @import("color_registry.zig");
const color_utils = @import("color_utils.zig");
const ImageObject = @import("image.zig").ImageObject;
const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const PyImageMod = @import("PyImage.zig");
const PyImage = PyImageMod.PyImage;

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

        fn repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
            const parent = Self.parentFromObj(self_obj) orelse {
                return c.PyUnicode_FromString(comptime zignal.meta.getSimpleTypeName(ColorType) ++ "(invalid)");
            };
            if (parent.py_image) |pimg| {
                const proxy = @as(*ProxyObjectType, @ptrCast(self_obj.?));
                const rgba = pimg.getPixelRgba(@intCast(proxy.row), @intCast(proxy.col));
                var buf: [256]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const w = fbs.writer();
                _ = w.print("{s}(", .{comptime zignal.meta.getSimpleTypeName(ColorType)}) catch return null;
                inline for (fields, 0..) |f, i| {
                    if (i != 0) _ = w.print(", ", .{}) catch return null;
                    _ = w.print("{s}={}", .{ f.name, @field(rgba, f.name) }) catch return null;
                }
                _ = w.print(")", .{}) catch return null;
                const s = fbs.getWritten();
                return c.PyUnicode_FromStringAndSize(s.ptr, @intCast(s.len));
            }
            return c.PyUnicode_FromString(comptime zignal.meta.getSimpleTypeName(ColorType) ++ "(invalid)");
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
            const parsed = color_utils.parseColorTo(zignal.Rgba, other) catch null;
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
    };
}

const RgbProxyBinding = PixelProxyBinding(zignal.Rgb, RgbPixelProxy);
const RgbaProxyBinding = PixelProxyBinding(zignal.Rgba, RgbaPixelProxy);

var rgb_proxy_getset = RgbProxyBinding.generateGetSet();
var rgba_proxy_getset = RgbaProxyBinding.generateGetSet();

pub var RgbPixelProxyType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.RgbPixelProxy",
    .tp_basicsize = @sizeOf(RgbPixelProxy),
    .tp_dealloc = RgbProxyBinding.dealloc,
    .tp_repr = RgbProxyBinding.repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Proxy object for RGB pixel access",
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

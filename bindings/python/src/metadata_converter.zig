// Conversion functions from metadata types to Python C API types
// This file imports Python.h and is only used in the actual Python bindings

const std = @import("std");
const stub_metadata = @import("stub_metadata.zig");

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

/// Convert an array of MethodWithMetadata to PyMethodDef array at compile time
pub fn toPyMethodDefArray(
    comptime methods: []const stub_metadata.MethodWithMetadata,
) [methods.len + 1]c.PyMethodDef {
    comptime {
        var result: [methods.len + 1]c.PyMethodDef = undefined;
        for (methods, 0..) |m, i| {
            result[i] = .{
                .ml_name = m.name.ptr,
                .ml_meth = @alignCast(@ptrCast(m.meth)),
                .ml_flags = m.flags,
                .ml_doc = m.doc.ptr,
            };
        }
        // Sentinel value
        result[methods.len] = .{
            .ml_name = null,
            .ml_meth = null,
            .ml_flags = 0,
            .ml_doc = null,
        };
        return result;
    }
}

/// Convert an array of PropertyWithMetadata to PyGetSetDef array at compile time
pub fn toPyGetSetDefArray(
    comptime props: []const stub_metadata.PropertyWithMetadata,
) [props.len + 1]c.PyGetSetDef {
    comptime {
        var result: [props.len + 1]c.PyGetSetDef = undefined;
        for (props, 0..) |p, i| {
            result[i] = .{
                .name = p.name.ptr,
                .get = @alignCast(@ptrCast(p.get)),
                .set = if (p.set) |s| @alignCast(@ptrCast(s)) else null,
                .doc = p.doc.ptr,
                .closure = null,
            };
        }
        // Sentinel value
        result[props.len] = .{
            .name = null,
            .get = null,
            .set = null,
            .doc = null,
            .closure = null,
        };
        return result;
    }
}

/// Convert an array of FunctionWithMetadata to PyMethodDef array at compile time
pub fn functionsToPyMethodDefArray(
    comptime funcs: []const stub_metadata.FunctionWithMetadata,
) [funcs.len + 1]c.PyMethodDef {
    comptime {
        var result: [funcs.len + 1]c.PyMethodDef = undefined;
        for (funcs, 0..) |f, i| {
            result[i] = .{
                .ml_name = f.name.ptr,
                .ml_meth = @alignCast(@ptrCast(f.meth)),
                .ml_flags = f.flags,
                .ml_doc = f.doc.ptr,
            };
        }
        // Sentinel value
        result[funcs.len] = .{
            .ml_name = null,
            .ml_meth = null,
            .ml_flags = 0,
            .ml_doc = null,
        };
        return result;
    }
}

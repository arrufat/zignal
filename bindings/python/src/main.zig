const std = @import("std");
const build_options = @import("build_options");

const canvas = @import("canvas.zig");
const color = @import("color.zig");
const fdm = @import("fdm.zig");
const image = @import("image.zig");
const interpolation = @import("interpolation.zig");
const py_utils = @import("py_utils.zig");
const stub_metadata = @import("stub_metadata.zig");

const c = py_utils.c;

// ============================================================================
// MODULE FUNCTIONS
// ============================================================================

var zignal_module = c.PyModuleDef{
    .m_name = "zignal",
    .m_doc = "zero dependency image processing library",
    .m_size = -1,
    .m_methods = @ptrCast(&zignal_methods),
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

// Module function metadata
pub const module_functions_metadata = [_]stub_metadata.FunctionWithMetadata{
    fdm.fdm_metadata,
};

// Generate PyMethodDef array at compile time
var zignal_methods = stub_metadata.functionsToPyMethodDefArray(&module_functions_metadata);

pub export fn PyInit__zignal() ?*c.PyObject {
    const m = c.PyModule_Create(&zignal_module);
    if (m == null) return null;

    // Register Image type
    py_utils.registerType(@ptrCast(m), "Image", @ptrCast(&image.ImageType)) catch |err| {
        std.log.err("Failed to register Image: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register Canvas type
    py_utils.registerType(@ptrCast(m), "Canvas", @ptrCast(&canvas.CanvasType)) catch |err| {
        std.log.err("Failed to register Canvas: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register DrawMode enum
    canvas.registerDrawMode(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register DrawMode: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register InterpolationMethod enum
    interpolation.registerInterpolationMethod(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register InterpolationMethod: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register all color types from the registry
    color.registerAllColorTypes(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register color types: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Add __version__ as a module attribute from build options
    const version_str = c.PyUnicode_FromString(@ptrCast(build_options.version));
    if (version_str == null) {
        c.Py_DECREF(m);
        return null;
    }
    if (c.PyModule_AddObject(m, "__version__", version_str) < 0) {
        c.Py_DECREF(version_str);
        c.Py_DECREF(m);
        return null;
    }

    return m;
}

pub fn main() void {}

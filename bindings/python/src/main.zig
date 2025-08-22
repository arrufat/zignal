const std = @import("std");
const build_options = @import("build_options");

const bitmap_font = @import("bitmap_font.zig");
const blending = @import("blending.zig");
const canvas = @import("canvas.zig");
const color = @import("color.zig");
const grayscale_format = @import("grayscale_format.zig");
const convex_hull = @import("convex_hull.zig");
const fdm = @import("fdm.zig");
const image = @import("image.zig");
const interpolation = @import("interpolation.zig");
const pixel_iterator = @import("pixel_iterator.zig");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const rectangle = @import("rectangle.zig");
const stub_metadata = @import("stub_metadata.zig");

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

// Module function metadata - empty now since we removed the function
pub const module_functions_metadata = [_]stub_metadata.FunctionWithMetadata{};

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

    // Register PixelIterator type
    py_utils.registerType(@ptrCast(m), "PixelIterator", @ptrCast(&pixel_iterator.PixelIteratorType)) catch |err| {
        std.log.err("Failed to register PixelIterator: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register InterpolationMethod enum
    interpolation.registerInterpolationMethod(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register InterpolationMethod: {}", .{err});
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

    // Register Rectangle type
    py_utils.registerType(@ptrCast(m), "Rectangle", @ptrCast(&rectangle.RectangleType)) catch |err| {
        std.log.err("Failed to register Rectangle: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register BitmapFont type
    py_utils.registerType(@ptrCast(m), "BitmapFont", @ptrCast(&bitmap_font.BitmapFontType)) catch |err| {
        std.log.err("Failed to register BitmapFont: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register FeatureDistributionMatching type
    py_utils.registerType(@ptrCast(m), "FeatureDistributionMatching", @ptrCast(&fdm.FeatureDistributionMatchingType)) catch |err| {
        std.log.err("Failed to register FeatureDistributionMatching: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register ConvexHull type
    py_utils.registerType(@ptrCast(m), "ConvexHull", @ptrCast(&convex_hull.ConvexHullType)) catch |err| {
        std.log.err("Failed to register ConvexHull: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register BlendMode enum
    blending.registerBlendMode(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register BlendMode: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register all color types from the registry
    color.registerAllColorTypes(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register color types: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register Grayscale sentinel type
    grayscale_format.registerGrayscaleType(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register Grayscale type: {}", .{err});
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

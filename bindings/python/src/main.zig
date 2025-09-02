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
const pixel_proxy = @import("pixel_proxy.zig");
const matrix = @import("matrix.zig");
const motion_blur = @import("motion_blur.zig");
const interpolation = @import("interpolation.zig");
const optimization = @import("optimization.zig");
const pca = @import("pca.zig");
const pixel_iterator = @import("pixel_iterator.zig");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const rectangle = @import("rectangle.zig");
const stub_metadata = @import("stub_metadata.zig");
const transforms = @import("transforms.zig");

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

// Module function metadata - combines functions from various modules
pub const module_functions_metadata = optimization.module_functions_metadata;

// Generate PyMethodDef array at compile time
var zignal_methods = stub_metadata.functionsToPyMethodDefArray(&module_functions_metadata);

pub export fn PyInit__zignal() ?*c.PyObject {
    const m = c.PyModule_Create(&zignal_module);
    if (m == null) return null;

    // ========================================================================
    // Core Types
    // ========================================================================
    
    // Register Image type
    py_utils.registerType(@ptrCast(m), "Image", @ptrCast(&image.ImageType)) catch |err| {
        std.log.err("Failed to register Image: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register Matrix type
    py_utils.registerType(@ptrCast(m), "Matrix", @ptrCast(&matrix.MatrixType)) catch |err| {
        std.log.err("Failed to register Matrix: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Geometry & Transforms
    // ========================================================================
    
    // Register Rectangle type
    py_utils.registerType(@ptrCast(m), "Rectangle", @ptrCast(&rectangle.RectangleType)) catch |err| {
        std.log.err("Failed to register Rectangle: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register ConvexHull type
    py_utils.registerType(@ptrCast(m), "ConvexHull", @ptrCast(&convex_hull.ConvexHullType)) catch |err| {
        std.log.err("Failed to register ConvexHull: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register transform types
    py_utils.registerType(@ptrCast(m), "SimilarityTransform", @ptrCast(&transforms.SimilarityTransformType)) catch |err| {
        std.log.err("Failed to register SimilarityTransform: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    py_utils.registerType(@ptrCast(m), "AffineTransform", @ptrCast(&transforms.AffineTransformType)) catch |err| {
        std.log.err("Failed to register AffineTransform: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    py_utils.registerType(@ptrCast(m), "ProjectiveTransform", @ptrCast(&transforms.ProjectiveTransformType)) catch |err| {
        std.log.err("Failed to register ProjectiveTransform: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Drawing & Display
    // ========================================================================
    
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

    // Register BitmapFont type
    py_utils.registerType(@ptrCast(m), "BitmapFont", @ptrCast(&bitmap_font.BitmapFontType)) catch |err| {
        std.log.err("Failed to register BitmapFont: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Color Management
    // ========================================================================
    
    // Register all color types from the registry
    color.registerAllColorTypes(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register color types: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register Blending enum
    blending.registerBlending(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register Blending: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register Grayscale sentinel type
    grayscale_format.registerGrayscaleType(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register Grayscale type: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Image Processing & Analysis
    // ========================================================================
    
    // Register Interpolation enum
    interpolation.registerInterpolation(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register Interpolation: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register MotionBlur classes
    motion_blur.registerMotionBlur(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register MotionBlur: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register PCA type
    py_utils.registerType(@ptrCast(m), "PCA", @ptrCast(&pca.PCAType)) catch |err| {
        std.log.err("Failed to register PCA: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register FeatureDistributionMatching type
    py_utils.registerType(@ptrCast(m), "FeatureDistributionMatching", @ptrCast(&fdm.FeatureDistributionMatchingType)) catch |err| {
        std.log.err("Failed to register FeatureDistributionMatching: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Optimization & Utilities
    // ========================================================================
    
    // Register OptimizationPolicy enum
    optimization.registerOptimizationPolicy(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register OptimizationPolicy: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register Assignment type
    py_utils.registerType(@ptrCast(m), "Assignment", @ptrCast(&optimization.AssignmentType)) catch |err| {
        std.log.err("Failed to register Assignment: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // Register PixelIterator type
    py_utils.registerType(@ptrCast(m), "PixelIterator", @ptrCast(&pixel_iterator.PixelIteratorType)) catch |err| {
        std.log.err("Failed to register PixelIterator: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Internal Types (not exposed in public API)
    // ========================================================================
    
    // Register RgbPixelProxy type (internal, not exposed in public API)
    if (c.PyType_Ready(&pixel_proxy.RgbPixelProxyType) < 0) {
        c.Py_DECREF(m);
        return null;
    }

    // Register RgbaPixelProxy type (internal, not exposed in public API)
    if (c.PyType_Ready(&pixel_proxy.RgbaPixelProxyType) < 0) {
        c.Py_DECREF(m);
        return null;
    }

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

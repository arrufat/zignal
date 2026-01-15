const std = @import("std");
const zignal = @import("zignal");

const bitmap_font = @import("bitmap_font.zig");
const blending = @import("blending.zig");
const canvas = @import("canvas.zig");
const color = @import("color.zig");
const convex_hull = @import("convex_hull.zig");
const fdm = @import("fdm.zig");
const image = @import("image.zig");
const pixel_proxy = @import("pixel_proxy.zig");
const matrix = @import("matrix.zig");
const motion_blur = @import("motion_blur.zig");
const interpolation = @import("interpolation.zig");
const border_mode = @import("border_mode.zig");
const optimization = @import("optimization.zig");
const pca = @import("pca.zig");
const pixel_iterator = @import("pixel_iterator.zig");
const running_stats = @import("running_stats.zig");
const perlin = @import("perlin.zig");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const rectangle = @import("rectangle.zig");
const stub_metadata = @import("stub_metadata.zig");
const transforms = @import("transforms.zig");
const enum_utils = @import("enum_utils.zig");

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
pub const module_functions_metadata = optimization.module_functions_metadata ++ perlin.perlin_functions_metadata;

// Generate PyMethodDef array at compile time
var zignal_methods = stub_metadata.functionsToPyMethodDefArray(&module_functions_metadata);

// Replaces the Py_TYPE macro/inline function which can cause undefined symbol errors.
comptime {
    @export(&py_utils.getPyType, .{ .name = "Py_TYPE" });
}

pub export fn PyInit__zignal() ?*c.PyObject {
    const m = c.PyModule_Create(&zignal_module);
    if (m == null) return null;

    // ========================================================================
    // Consolidated Type Registration
    // ========================================================================
    const TypeReg = struct {
        name: []const u8,
        ty: *c.PyTypeObject,
    };

    const type_table = [_]TypeReg{
        .{ .name = "Image", .ty = @ptrCast(&image.ImageType) },
        .{ .name = "Matrix", .ty = @ptrCast(&matrix.MatrixType) },
        .{ .name = "Rectangle", .ty = @ptrCast(&rectangle.RectangleType) },
        .{ .name = "ConvexHull", .ty = @ptrCast(&convex_hull.ConvexHullType) },
        .{ .name = "SimilarityTransform", .ty = @ptrCast(&transforms.SimilarityTransformType) },
        .{ .name = "AffineTransform", .ty = @ptrCast(&transforms.AffineTransformType) },
        .{ .name = "ProjectiveTransform", .ty = @ptrCast(&transforms.ProjectiveTransformType) },
        .{ .name = "Canvas", .ty = @ptrCast(&canvas.CanvasType) },
        .{ .name = "BitmapFont", .ty = @ptrCast(&bitmap_font.BitmapFontType) },
        .{ .name = "PCA", .ty = @ptrCast(&pca.PCAType) },
        .{ .name = "FeatureDistributionMatching", .ty = @ptrCast(&fdm.FeatureDistributionMatchingType) },
        .{ .name = "Assignment", .ty = @ptrCast(&optimization.AssignmentType) },
        .{ .name = "PixelIterator", .ty = @ptrCast(&pixel_iterator.PixelIteratorType) },
        .{ .name = "RunningStats", .ty = @ptrCast(&running_stats.RunningStatsType) },
    };

    inline for (type_table) |entry| {
        py_utils.registerType(@ptrCast(m), entry.name, entry.ty) catch |err| {
            std.log.err("Failed to register {s}: {}", .{ entry.name, err });
            c.Py_DECREF(m);
            return null;
        };
    }

    // ========================================================================
    // Enum Registration (table-driven)
    // ========================================================================

    const EnumReg = struct {
        type: type,
        doc: []const u8,
    };

    const enum_registrations = [_]EnumReg{
        .{ .type = zignal.DrawMode, .doc = canvas.draw_mode_doc },
        .{ .type = zignal.Blending, .doc = blending.blending_doc },
        .{ .type = zignal.Interpolation, .doc = interpolation.interpolation_doc },
        .{ .type = zignal.BorderMode, .doc = border_mode.border_mode_doc },
        .{ .type = zignal.optimization.OptimizationPolicy, .doc = optimization.optimization_policy_doc },
    };

    inline for (enum_registrations) |reg| {
        enum_utils.registerEnum(reg.type, @ptrCast(m), reg.doc) catch |err| {
            std.log.err("Failed to register {s}: {}", .{ @typeName(reg.type), err });
            c.Py_DECREF(m);
            return null;
        };
    }

    // ========================================================================
    // Color Management
    // ========================================================================

    // Register all color types from the registry
    color.registerAllColorTypes(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register color types: {}", .{err});
        c.Py_DECREF(m);
        return null;
    };

    // ========================================================================
    // Image Processing & Analysis
    // ========================================================================

    // Register MotionBlur classes
    motion_blur.registerMotionBlur(@ptrCast(m)) catch |err| {
        std.log.err("Failed to register MotionBlur: {}", .{err});
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
    const version_str = c.PyUnicode_FromString(@ptrCast(zignal.version));
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

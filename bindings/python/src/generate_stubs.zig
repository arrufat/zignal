// Auto-generate Python type stub (.pyi) files from Zig source code
// This leverages Zig's compile-time reflection to create accurate type information

const std = @import("std");
const zignal = @import("zignal");
const color_registry = @import("color_registry.zig");
const stub_metadata = @import("stub_metadata.zig");
const color_factory = @import("color_factory.zig");

// Import modules that contain metadata
const image_module = @import("image.zig");
const canvas_module = @import("canvas.zig");
const main_module = @import("main.zig");
const matrix_module = @import("matrix.zig");
const motion_blur_module = @import("motion_blur.zig");
const fdm_module = @import("fdm.zig");
const pca_module = @import("pca.zig");
const rectangle_module = @import("rectangle.zig");
const convex_hull_module = @import("convex_hull.zig");
const bitmap_font_module = @import("bitmap_font.zig");
const blending_module = @import("blending.zig");
const interpolation_module = @import("interpolation.zig");
const optimization_module = @import("optimization.zig");
const transforms_module = @import("transforms.zig");

const GeneratedStub = struct {
    content: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) GeneratedStub {
        return GeneratedStub{
            .allocator = gpa,
            .content = .empty,
        };
    }

    fn deinit(self: *GeneratedStub) void {
        self.content.deinit(self.allocator);
    }

    fn write(self: *GeneratedStub, text: []const u8) !void {
        try self.content.appendSlice(self.allocator, text);
    }

    fn writef(self: *GeneratedStub, comptime fmt: []const u8, args: anytype) !void {
        try self.content.writer(self.allocator).print(fmt, args);
    }
};

/// Map Zig types to Python type hints
fn getPythonType(comptime ZigType: type) []const u8 {
    return switch (ZigType) {
        u8, u16, u32, u64, i8, i16, i32, i64, c_int => "int",
        f16, f32, f64 => "float",
        bool => "bool",
        []const u8, []u8 => "str",
        else => "Any",
    };
}

/// Generate property getter for a field
fn generatePropertyGetter(stub: *GeneratedStub, field_name: []const u8, field_type: type) !void {
    const python_type = getPythonType(field_type);
    try stub.writef("    @property\n", .{});
    try stub.writef("    def {s}(self) -> {s}: ...\n", .{ field_name, python_type });
}

/// Generate property setter for a field
fn generatePropertySetter(stub: *GeneratedStub, field_name: []const u8, field_type: type) !void {
    const python_type = getPythonType(field_type);
    try stub.writef("    @{s}.setter\n", .{field_name});
    try stub.writef("    def {s}(self, value: {s}) -> None: ...\n", .{ field_name, python_type });
}

/// Generate conversion method signature with documentation
fn generateConversionMethod(stub: *GeneratedStub, comptime SourceType: type, comptime TargetType: type) !void {
    // Skip self-conversion
    if (SourceType == TargetType) return;

    // Generate method name at runtime using string manipulation
    const target_class = getClassNameFromType(TargetType);

    // Write method with lowercase target class name
    try stub.write("    def to_");

    // Write the class name character by character in lowercase
    for (target_class) |char| {
        const lower_char = std.ascii.toLower(char);
        try stub.writef("{c}", .{lower_char});
    }

    // Special case for to_rgba which accepts optional alpha parameter
    if (TargetType == zignal.Rgba) {
        try stub.writef("(self, alpha: int = 255) -> {s}:\n", .{target_class});
        try stub.write("        \"\"\"Convert to RGBA color space with the given alpha value (0-255, default: 255)\"\"\"\n");
    } else {
        // Include self parameter for proper LSP support
        try stub.writef("(self) -> {s}:\n", .{target_class});

        // Add docstring using the documentation from color_factory
        const doc = color_factory.getConversionMethodDoc(TargetType);
        try stub.writef("        \"\"\"{s}\"\"\"\n", .{doc});
    }
    try stub.write("        ...\n");
}

/// Convert color.Rgb or zignal.Rgb -> "Rgb"
fn getClassNameFromType(comptime T: type) []const u8 {
    const type_name = @typeName(T);

    if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_index| {
        return type_name[dot_index + 1 ..];
    } else {
        // For types without dots, return the full name
        return type_name;
    }
}

/// Generate complete color class stub
fn generateColorClass(stub: *GeneratedStub, comptime ColorType: type) !void {
    const class_name = getClassNameFromType(ColorType);
    const doc_string = color_registry.getDocumentationString(ColorType);
    const type_info = @typeInfo(ColorType).@"struct";

    try stub.writef("\nclass {s}:\n", .{class_name});
    try stub.writef("    \"\"\"{s}\"\"\"\n", .{doc_string});

    // Constructor
    try stub.write("    def __init__(self");
    inline for (type_info.fields) |field| {
        const python_type = getPythonType(field.type);
        try stub.writef(", {s}: {s}", .{ field.name, python_type });
    }
    try stub.write(") -> None: ...\n");

    // Properties (getters and setters)
    inline for (type_info.fields) |field| {
        try generatePropertyGetter(stub, field.name, field.type);
        try generatePropertySetter(stub, field.name, field.type);
    }

    // Auto-discover conversion methods by checking which methods exist
    inline for (color_registry.color_types) |TargetType| {
        if (TargetType != ColorType) {
            // Use the same method checking logic as the color factory
            const method_name = comptime blk: {
                const target_name = getClassNameFromType(TargetType);
                break :blk "to" ++ target_name;
            };

            if (@hasDecl(ColorType, method_name)) {
                try generateConversionMethod(stub, ColorType, TargetType);
            }
        }
    }

    // Add to_gray method (all color types have it)
    try stub.write(
        \\    def to_gray(self) -> int:
        \\        """Convert to a grayscale value representing the luminance/lightness as an integer between 0 and 255."""
        \\    ...
        \\
    );

    // Add blend method if the type has it
    if (@hasDecl(ColorType, "blend")) {
        try stub.write("    def blend(self, overlay: Rgba | tuple[int, int, int, int], mode: Blending = Blending.NORMAL) -> ");
        try stub.writef("{s}: ...\n", .{class_name});
    }

    // Standard Python methods
    try stub.write("    def __repr__(self) -> str: ...\n");
    try stub.write("    def __str__(self) -> str: ...\n");
}

/// Generate class from metadata
fn generateClassFromMetadata(stub: *GeneratedStub, class_info: stub_metadata.ClassInfo) !void {
    // Class declaration
    try stub.writef("\nclass {s}:\n", .{class_info.name});

    // Class docstring
    try stub.writef("    \"\"\"{s}\n    \"\"\"\n", .{class_info.doc});

    // Generate methods
    for (class_info.methods) |method| {
        // Add decorator if needed
        if (method.is_classmethod) {
            try stub.write("    @classmethod\n");
        } else if (method.is_staticmethod) {
            try stub.write("    @staticmethod\n");
        }

        // Write method signature
        try stub.writef("    def {s}({s}) -> {s}:", .{
            method.name,
            method.params,
            method.returns,
        });

        // Add docstring if available
        if (method.doc) |doc| {
            try stub.write("\n");
            try stub.writef("        \"\"\"{s}\"\"\"\n", .{doc});
            try stub.write("        ...\n");
        } else {
            try stub.write(" ...\n");
        }
    }

    // Generate properties
    for (class_info.properties) |prop| {
        try stub.write("    @property\n");
        try stub.writef("    def {s}(self) -> {s}: ...\n", .{ prop.name, prop.type });

        // Add setter if not readonly
        if (!prop.readonly) {
            try stub.writef("    @{s}.setter\n", .{prop.name});
            try stub.writef("    def {s}(self, value: {s}) -> None: ...\n", .{ prop.name, prop.type });
        }
    }

    // Generate special methods if provided
    if (class_info.special_methods) |special_methods| {
        for (special_methods) |method| {
            // Write method signature normally
            try stub.writef("    def {s}({s}) -> {s}:", .{
                method.name,
                method.params,
                method.returns,
            });

            // Add docstring if available
            if (method.doc) |doc| {
                try stub.write("\n");
                try stub.writef("        \"\"\"{s}\"\"\"\n", .{doc});
                try stub.write("        ...\n");
            } else {
                try stub.write(" ...\n");
            }
        }
    }
}

/// Generate enum from Zig type metadata
fn generateEnumFromMetadata(stub: *GeneratedStub, enum_info: stub_metadata.EnumInfo) !void {
    const type_info = @typeInfo(enum_info.zig_type);

    // Handle both enum and union(enum) types
    const enum_type_info = switch (type_info) {
        .@"enum" => |e| e,
        .@"union" => |u| blk: {
            // For union(enum), we want to extract the enum tag type
            if (u.tag_type) |tag_type| {
                const tag_info = @typeInfo(tag_type);
                if (tag_info == .@"enum") {
                    break :blk tag_info.@"enum";
                }
            }
            @compileError("Type " ++ @typeName(enum_info.zig_type) ++ " is not an enum or union(enum)");
        },
        else => @compileError("Type " ++ @typeName(enum_info.zig_type) ++ " is not an enum or union(enum)"),
    };

    try stub.writef("\nclass {s}({s}):\n", .{ enum_info.name, enum_info.base });
    try stub.writef("    \"\"\"{s}\"\"\"\n", .{enum_info.doc});

    // Generate enum values
    inline for (enum_type_info.fields) |field| {
        // Convert field name to uppercase for Python convention
        var uppercase_name: [128]u8 = undefined;
        const name_len = field.name.len;
        if (name_len > uppercase_name.len) {
            return error.NameTooLong;
        }
        for (field.name, 0..) |c, i| {
            uppercase_name[i] = std.ascii.toUpper(c);
        }

        // Write enum value with optional inline documentation
        try stub.writef("    {s} = {d}\n", .{ uppercase_name[0..name_len], field.value });

        // Add inline comment if documentation is provided
        if (enum_info.value_docs) |docs| {
            for (docs) |doc| {
                if (std.mem.eql(u8, doc.name, uppercase_name[0..name_len])) {
                    try stub.writef("    \"\"\"{s}\"\"\"", .{doc.doc});
                    break;
                }
            }
        }

        try stub.write("\n");
    }
}

/// Generate module-level functions from metadata
fn generateModuleFunctionsFromMetadata(stub: *GeneratedStub, functions: []const stub_metadata.FunctionInfo) !void {
    for (functions) |func| {
        try stub.writef("\ndef {s}({s}) -> {s}:\n", .{ func.name, func.params, func.returns });
        try stub.writef("    \"\"\"{s}\"\"\"\n", .{func.doc});
        try stub.write("    ...\n");
    }
}

/// Generate unified MotionBlur class from metadata
fn generateMotionBlurClasses(stub: *GeneratedStub) !void {
    // Generate unified MotionBlur class from metadata
    const properties = stub_metadata.extractPropertyInfo(&motion_blur_module.motion_blur_properties_metadata);
    const doc = std.mem.span(motion_blur_module.MotionBlurType.tp_doc);
    try generateClassFromMetadata(stub, .{
        .name = "MotionBlur",
        .doc = doc,
        .methods = &motion_blur_module.motion_blur_methods_metadata,
        .properties = &properties,
        .bases = &.{},
        .special_methods = &motion_blur_module.motion_blur_special_methods_metadata,
    });
}

/// Generate complete stub file
fn generateStubFile(gpa: std.mem.Allocator) ![]u8 {
    var stub = GeneratedStub.init(gpa);
    defer stub.deinit();

    try stub.write(
        \\# Auto-generated Python type stubs for zignal
        \\# Generated from Zig source code using compile-time reflection
        \\# Do not modify manually - regenerate using: zig build generate-stubs
        \\
        \\
    );

    // Header and imports
    try stub.write(
        \\from __future__ import annotations
        \\
        \\from enum import IntEnum
        \\from typing import Literal, TypeAlias
        \\
        \\import numpy as np
        \\from numpy.typing import NDArray
        \\
        \\
    );

    // Type aliases for common patterns
    try stub.write(
        \\# Type aliases for common patterns
        \\Point: TypeAlias = tuple[float, float]
        \\Size: TypeAlias = tuple[int, int]
        \\RgbTuple: TypeAlias = tuple[int, int, int]
        \\RgbaTuple: TypeAlias = tuple[int, int, int, int]
        \\
        \\
    );

    // PixelIterator class from metadata (in image module)
    const pixel_iter_module = @import("pixel_iterator.zig");
    const pixel_iter_doc = std.mem.span(pixel_iter_module.PixelIteratorType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "PixelIterator",
        .doc = pixel_iter_doc,
        .methods = &[_]stub_metadata.MethodInfo{},
        .properties = &[_]stub_metadata.PropertyInfo{},
        .bases = &.{},
        .special_methods = &pixel_iter_module.pixel_iterator_special_methods_metadata,
    });

    // Generate Rectangle class from metadata
    const rectangle_methods = stub_metadata.extractMethodInfo(&rectangle_module.rectangle_methods_metadata);
    const rectangle_properties = stub_metadata.extractPropertyInfo(&rectangle_module.rectangle_properties_metadata);
    const rectangle_doc = std.mem.span(rectangle_module.RectangleType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "Rectangle",
        .doc = rectangle_doc,
        .methods = &rectangle_methods,
        .properties = &rectangle_properties,
        .bases = &.{},
        .special_methods = &rectangle_module.rectangle_special_methods_metadata,
    });

    // Generate BitmapFont class from metadata
    const bitmap_font_methods = stub_metadata.extractMethodInfo(&bitmap_font_module.bitmap_font_methods_metadata);
    const bitmap_font_doc = std.mem.span(bitmap_font_module.BitmapFontType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "BitmapFont",
        .doc = bitmap_font_doc,
        .methods = &bitmap_font_methods,
        .properties = &[_]stub_metadata.PropertyInfo{},
        .bases = &.{},
        .special_methods = null,
    });
    // Note: BitmapFont.font8x8() returns a cached singleton

    // Generate Interpolation enum
    try generateEnumFromMetadata(&stub, .{
        .name = "Interpolation",
        .base = "IntEnum",
        .doc = interpolation_module.interpolation_doc,
        .zig_type = zignal.Interpolation,
        .value_docs = &interpolation_module.interpolation_values,
    });

    // Generate Blending enum
    try generateEnumFromMetadata(&stub, .{
        .name = "Blending",
        .base = "IntEnum",
        .doc = blending_module.blending_doc,
        .zig_type = zignal.Blending,
        .value_docs = &blending_module.blending_values,
    });

    // Generate DrawMode enum
    try generateEnumFromMetadata(&stub, .{
        .name = "DrawMode",
        .base = "IntEnum",
        .doc = canvas_module.draw_mode_doc,
        .zig_type = zignal.DrawMode,
        .value_docs = &canvas_module.draw_mode_values,
    });

    // Generate OptimizationPolicy enum
    try generateEnumFromMetadata(&stub, .{
        .name = "OptimizationPolicy",
        .base = "IntEnum",
        .doc = optimization_module.optimization_policy_doc,
        .zig_type = zignal.optimization.OptimizationPolicy,
        .value_docs = &[_]stub_metadata.EnumValueDoc{
            .{ .name = "MIN", .doc = "Minimize total cost" },
            .{ .name = "MAX", .doc = "Maximize total cost (profit)" },
        },
    });

    // Generate MotionBlur classes
    try generateMotionBlurClasses(&stub);

    // Generate all color classes
    inline for (color_registry.color_types) |ColorType| {
        try generateColorClass(&stub, ColorType);
    }

    // Generate Color type alias with all color types
    try stub.write("\n# Union type for any color value\n");
    try stub.write("Color: TypeAlias = int | RgbTuple | RgbaTuple");
    inline for (color_registry.color_types) |ColorType| {
        const class_name = getClassNameFromType(ColorType);
        try stub.writef(" | {s}", .{class_name});
    }
    try stub.write("\n");

    // Add Grayscale sentinel type (format selector for images)
    try stub.write("\nclass Grayscale:\n");
    try stub.write("    \"\"\"Grayscale image format (single channel, u8)\"\"\"\n");
    try stub.write("    ...\n");

    // Generate Assignment class from metadata
    const assignment_properties = stub_metadata.extractPropertyInfo(&optimization_module.assignment_properties_metadata);
    const assignment_doc = std.mem.span(optimization_module.AssignmentType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "Assignment",
        .doc = assignment_doc,
        .methods = &[_]stub_metadata.MethodInfo{},
        .properties = &assignment_properties,
        .bases = &.{},
        .special_methods = null,
    });

    // Generate Image class from metadata
    const image_methods = stub_metadata.extractMethodInfo(&image_module.image_methods_metadata);
    const image_properties = stub_metadata.extractPropertyInfo(&image_module.image_properties_metadata);
    const image_doc = std.mem.span(image_module.ImageType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "Image",
        .doc = image_doc,
        .methods = &image_methods,
        .properties = &image_properties,
        .bases = &.{},
        .special_methods = &image_module.image_special_methods_metadata,
    });

    // Generate Matrix class from metadata
    const matrix_methods = stub_metadata.extractMethodInfo(&matrix_module.matrix_methods_metadata);
    const matrix_properties = stub_metadata.extractPropertyInfo(&matrix_module.matrix_properties_metadata);
    const matrix_doc = std.mem.span(matrix_module.MatrixType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "Matrix",
        .doc = matrix_doc,
        .methods = &matrix_methods,
        .properties = &matrix_properties,
        .bases = &.{},
        .special_methods = &matrix_module.matrix_special_methods_metadata,
    });

    // Generate Canvas class from metadata
    const canvas_methods = stub_metadata.extractMethodInfo(&canvas_module.canvas_methods_metadata);
    const canvas_properties = stub_metadata.extractPropertyInfo(&canvas_module.canvas_properties_metadata);
    const canvas_doc = std.mem.span(canvas_module.CanvasType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "Canvas",
        .doc = canvas_doc,
        .methods = &canvas_methods,
        .properties = &canvas_properties,
        .bases = &.{},
        .special_methods = &canvas_module.canvas_special_methods_metadata,
    });

    // Generate FeatureDistributionMatching class from metadata
    const fdm_methods = stub_metadata.extractMethodInfo(&fdm_module.fdm_methods_metadata);
    const fdm_doc = std.mem.span(fdm_module.FeatureDistributionMatchingType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "FeatureDistributionMatching",
        .doc = fdm_doc,
        .methods = &fdm_methods,
        .properties = &[_]stub_metadata.PropertyInfo{},
        .bases = &.{},
        .special_methods = &fdm_module.fdm_special_methods_metadata,
    });

    // Generate PCA class from metadata
    const pca_doc = std.mem.span(pca_module.PCAType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "PCA",
        .doc = pca_doc,
        .methods = pca_module.pca_class_metadata.methods,
        .properties = pca_module.pca_class_metadata.properties,
        .bases = &.{},
        .special_methods = null,
    });

    // Generate ConvexHull class from metadata
    const convex_hull_methods = stub_metadata.extractMethodInfo(&convex_hull_module.convex_hull_methods_metadata);
    const convex_hull_doc = std.mem.span(convex_hull_module.ConvexHullType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "ConvexHull",
        .doc = convex_hull_doc,
        .methods = &convex_hull_methods,
        .properties = &[_]stub_metadata.PropertyInfo{},
        .bases = &.{},
        .special_methods = &convex_hull_module.convex_hull_special_methods_metadata,
    });

    // Generate Transform classes from metadata
    // SimilarityTransform
    const similarity_methods = transforms_module.similarity_methods_metadata;
    const similarity_properties = transforms_module.similarity_properties_metadata;
    const similarity_doc = std.mem.span(transforms_module.SimilarityTransformType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "SimilarityTransform",
        .doc = similarity_doc,
        .methods = &similarity_methods,
        .properties = &similarity_properties,
        .bases = &.{},
        .special_methods = null,
    });

    // AffineTransform
    const affine_methods = transforms_module.affine_methods_metadata;
    const affine_properties = transforms_module.affine_properties_metadata;
    const affine_doc = std.mem.span(transforms_module.AffineTransformType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "AffineTransform",
        .doc = affine_doc,
        .methods = &affine_methods,
        .properties = &affine_properties,
        .bases = &.{},
        .special_methods = null,
    });

    // ProjectiveTransform
    const projective_methods = transforms_module.projective_methods_metadata;
    const projective_properties = transforms_module.projective_properties_metadata;
    const projective_doc = std.mem.span(transforms_module.ProjectiveTransformType.tp_doc);
    try generateClassFromMetadata(&stub, .{
        .name = "ProjectiveTransform",
        .doc = projective_doc,
        .methods = &projective_methods,
        .properties = &projective_properties,
        .bases = &.{},
        .special_methods = null,
    });

    // Generate module-level functions from metadata
    const module_functions = stub_metadata.extractFunctionInfo(&main_module.module_functions_metadata);
    try generateModuleFunctionsFromMetadata(&stub, &module_functions);

    // Module metadata
    try stub.write("\n__version__: str\n");
    try stub.write("__all__: list[str]\n");

    return try stub.content.toOwnedSlice(gpa);
}

/// Generate __init__.pyi stub file for the main package
fn generateInitStub(gpa: std.mem.Allocator) ![]u8 {
    var stub = GeneratedStub.init(gpa);
    defer stub.deinit();

    // Header
    try stub.write("# Type stubs for zignal package\n");
    try stub.write("# This file helps LSPs understand the module structure\n\n");
    try stub.write("from __future__ import annotations\n\n");

    // Re-export all types from _zignal
    try stub.write("# Re-export all types from _zignal\n");
    try stub.write("from ._zignal import (\n");

    // Auto-generate import list from color types
    inline for (color_registry.color_types) |ColorType| {
        const class_name = getClassNameFromType(ColorType);
        try stub.writef("    {s} as {s},\n", .{ class_name, class_name });
    }

    // Add Image and classes
    try stub.write("    Rectangle as Rectangle,\n");
    try stub.write("    BitmapFont as BitmapFont,\n");
    try stub.write("    Image as Image,\n");
    try stub.write("    Matrix as Matrix,\n");
    try stub.write("    Canvas as Canvas,\n");
    try stub.write("    Interpolation as Interpolation,\n");
    try stub.write("    Blending as Blending,\n");
    try stub.write("    DrawMode as DrawMode,\n");
    try stub.write("    MotionBlur as MotionBlur,\n");
    try stub.write("    OptimizationPolicy as OptimizationPolicy,\n");
    try stub.write("    Assignment as Assignment,\n");
    try stub.write("    FeatureDistributionMatching as FeatureDistributionMatching,\n");
    try stub.write("    PCA as PCA,\n");
    try stub.write("    ConvexHull as ConvexHull,\n");
    try stub.write("    SimilarityTransform as SimilarityTransform,\n");
    try stub.write("    AffineTransform as AffineTransform,\n");
    try stub.write("    ProjectiveTransform as ProjectiveTransform,\n");
    try stub.write("    solve_assignment_problem as solve_assignment_problem,\n");
    try stub.write("    # Type aliases\n");
    try stub.write("    Point as Point,\n");
    try stub.write("    Size as Size,\n");
    try stub.write("    RgbTuple as RgbTuple,\n");
    try stub.write("    RgbaTuple as RgbaTuple,\n");
    try stub.write("    Color as Color,\n");
    try stub.write(")\n\n");

    // Module metadata
    try stub.write("__version__: str\n");
    try stub.write("__all__: list[str]\n");

    return try stub.content.toOwnedSlice(gpa);
}

/// Main function to generate and write all stub files
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate main comprehensive stub file
    const main_stub_content = try generateStubFile(allocator);
    defer allocator.free(main_stub_content);

    // Generate __init__.pyi stub file
    const init_stub_content = try generateInitStub(allocator);
    defer allocator.free(init_stub_content);

    // Write _zignal.pyi (stub file for C extension)
    {
        const file = try std.fs.cwd().createFile("_zignal.pyi", .{});
        defer file.close();
        try file.writeAll(main_stub_content);
    }

    // Write __init__.pyi (package-level stub file)
    {
        const file = try std.fs.cwd().createFile("__init__.pyi", .{});
        defer file.close();
        try file.writeAll(init_stub_content);
    }

    std.debug.print("Generated stub files:\n", .{});
    std.debug.print("  _zignal.pyi: {} bytes\n", .{main_stub_content.len});
    std.debug.print("  __init__.pyi: {} bytes\n", .{init_stub_content.len});
}

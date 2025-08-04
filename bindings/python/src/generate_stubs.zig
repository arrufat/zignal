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
const fdm_module = @import("fdm.zig");
const rectangle_module = @import("rectangle.zig");
const convex_hull_module = @import("convex_hull.zig");

const GeneratedStub = struct {
    content: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) GeneratedStub {
        return GeneratedStub{
            .content = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *GeneratedStub) void {
        self.content.deinit();
    }

    fn write(self: *GeneratedStub, text: []const u8) !void {
        try self.content.appendSlice(text);
    }

    fn writef(self: *GeneratedStub, comptime fmt: []const u8, args: anytype) !void {
        try self.content.writer().print(fmt, args);
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

    // Include self parameter for proper LSP support
    try stub.writef("(self) -> {s}:\n", .{target_class});

    // Add docstring using the documentation from color_factory
    const doc = color_factory.getConversionMethodDoc(TargetType);
    try stub.write("        \"\"\"");
    try stub.write(doc);
    try stub.write("\"\"\"\n");
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

    // Standard Python methods
    try stub.write("    def __repr__(self) -> str: ...\n");
    try stub.write("    def __str__(self) -> str: ...\n");
}

/// Generate class from metadata
fn generateClassFromMetadata(stub: *GeneratedStub, class_info: stub_metadata.ClassInfo) !void {
    try stub.writef("\nclass {s}:\n", .{class_info.name});
    try stub.writef("    \"\"\"{s}\"\"\"\n", .{class_info.doc});

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
        try stub.writef("    {s} = {d}\n", .{ uppercase_name[0..name_len], field.value });
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

/// Generate complete stub file
fn generateStubFile(allocator: std.mem.Allocator) ![]u8 {
    var stub = GeneratedStub.init(allocator);
    defer stub.deinit();

    // Header and imports
    try stub.write("# Auto-generated Python type stubs for zignal\n");
    try stub.write("# Generated from Zig source code using compile-time reflection\n");
    try stub.write("# Do not modify manually - regenerate using: zig build generate-stubs\n\n");
    try stub.write("from __future__ import annotations\n");
    try stub.write("from typing import Any, Union, Tuple\n");
    try stub.write("from enum import IntEnum\n");
    try stub.write("import numpy as np\n");

    // Generate all color classes
    inline for (color_registry.color_types) |ColorType| {
        try generateColorClass(&stub, ColorType);
    }

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
    });

    // Generate BitmapFont class
    try stub.write("\nclass BitmapFont:\n");
    try stub.write("    \"\"\"Bitmap font for text rendering\"\"\"\n");
    try stub.write("    @classmethod\n");
    try stub.write("    def load(cls, path: str) -> BitmapFont:\n");
    try stub.write("        \"\"\"Load a bitmap font from file.\"\"\"\n");
    try stub.write("        ...\n");
    try stub.write("    @classmethod\n");
    try stub.write("    def get_default_font(cls) -> BitmapFont:\n");
    try stub.write("        \"\"\"Get the built-in default 8x8 bitmap font.\"\"\"\n");
    try stub.write("        ...\n");

    // Generate InterpolationMethod enum
    try generateEnumFromMetadata(&stub, .{
        .name = "InterpolationMethod",
        .base = "IntEnum",
        .doc = "Interpolation methods for image resizing",
        .zig_type = zignal.InterpolationMethod,
    });

    // Generate DrawMode enum
    try generateEnumFromMetadata(&stub, .{
        .name = "DrawMode",
        .base = "IntEnum",
        .doc = "Rendering quality mode for drawing operations",
        .zig_type = zignal.DrawMode,
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
    });

    // Add special methods for Image class (pixel access)
    try stub.write("    def __len__(self) -> int: ...\n");
    try stub.write("    def __getitem__(self, key: Tuple[int, int]) -> Rgba: ...\n");
    try stub.write("    def __setitem__(self, key: Tuple[int, int], value: Union[int, Tuple[int, int, int], Tuple[int, int, int, int], Rgb, Rgba, Hsl, Hsv, Lab, Lch, Lms, Oklab, Oklch, Xyb, Xyz, Ycbcr]) -> None: ...\n");

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
    });

    // Generate module-level functions from metadata
    const module_functions = stub_metadata.extractFunctionInfo(&main_module.module_functions_metadata);
    try generateModuleFunctionsFromMetadata(&stub, &module_functions);

    // Module metadata
    try stub.write("\n__version__: str\n");
    try stub.write("__all__: list[str]\n");

    return try stub.content.toOwnedSlice();
}

/// Generate __init__.pyi stub file for the main package
fn generateInitStub(allocator: std.mem.Allocator) ![]u8 {
    var stub = GeneratedStub.init(allocator);
    defer stub.deinit();

    // Header
    try stub.write("# Type stubs for zignal package\n");
    try stub.write("# This file helps LSPs understand the module structure\n\n");
    try stub.write("from __future__ import annotations\n");
    try stub.write("from typing import Any, Union, Tuple\n");
    try stub.write("from enum import IntEnum\n");
    try stub.write("import numpy as np\n\n");

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
    try stub.write("    Canvas as Canvas,\n");
    try stub.write("    InterpolationMethod as InterpolationMethod,\n");
    try stub.write("    DrawMode as DrawMode,\n");
    try stub.write("    FeatureDistributionMatching as FeatureDistributionMatching,\n");
    try stub.write("    ConvexHull as ConvexHull,\n");
    try stub.write(")\n\n");

    // Module metadata
    try stub.write("__version__: str\n");
    try stub.write("__all__: list[str]\n");

    return try stub.content.toOwnedSlice();
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

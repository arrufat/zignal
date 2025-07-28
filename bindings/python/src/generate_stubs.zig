// Auto-generate Python type stub (.pyi) files from Zig source code
// This leverages Zig's compile-time reflection to create accurate type information

const std = @import("std");
const zignal = @import("zignal");
const color_registry = @import("color_registry.zig");

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

/// Generate conversion method signature
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
    try stub.writef("(self) -> {s}: ...\n", .{target_class});
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

/// Generate Image class stub - comprehensive method coverage
fn generateImageClass(stub: *GeneratedStub) !void {
    try stub.write("\nclass Image:\n");
    try stub.write("    \"\"\"Image class with RGBA storage for SIMD-optimized operations\"\"\"\n");

    // Constructor
    try stub.write("    def __init__(self) -> None: ...\n");

    // All methods that are known to exist in the Python bindings
    // These are defined in the actual Python binding implementation
    try stub.write("    @classmethod\n");
    try stub.write("    def load(cls, path: str) -> Image: ...\n");
    try stub.write("    @classmethod\n");
    try stub.write("    def from_numpy(cls, array: np.ndarray[Any, np.dtype[np.uint8]]) -> Image: ...\n");
    try stub.write("    @staticmethod\n");
    try stub.write("    def add_alpha(array: np.ndarray[Any, np.dtype[np.uint8]], alpha: int = 255) -> np.ndarray[Any, np.dtype[np.uint8]]: ...\n");
    try stub.write("    def save(self, path: str) -> None: ...\n");
    try stub.write("    def to_numpy(self, include_alpha: bool = True) -> np.ndarray[Any, np.dtype[np.uint8]]: ...\n");
    try stub.write("    def resize(self, size: Union[float, Tuple[int, int]], method: InterpolationMethod = InterpolationMethod.BILINEAR) -> Image: ...\n");
    try stub.write("    def letterbox(self, size: Union[int, Tuple[int, int]], method: InterpolationMethod = InterpolationMethod.BILINEAR) -> Image: ...\n");
    try stub.write("    def canvas(self) -> Canvas: ...\n");
    try stub.write("    @property\n");
    try stub.write("    def rows(self) -> int: ...\n");
    try stub.write("    @property\n");
    try stub.write("    def cols(self) -> int: ...\n");

    // Standard Python methods
    try stub.write("    def __repr__(self) -> str: ...\n");
}

/// Generate InterpolationMethod enum
fn generateInterpolationMethod(stub: *GeneratedStub) !void {
    try stub.write("\nclass InterpolationMethod(IntEnum):\n");
    try stub.write("    \"\"\"Interpolation methods for image resizing\"\"\"\n");
    try stub.write("    NEAREST_NEIGHBOR = 0\n");
    try stub.write("    BILINEAR = 1\n");
    try stub.write("    BICUBIC = 2\n");
    try stub.write("    CATMULL_ROM = 3\n");
    try stub.write("    MITCHELL = 4\n");
    try stub.write("    LANCZOS = 5\n");
}

/// Generate Canvas class stub
fn generateCanvasClass(stub: *GeneratedStub) !void {
    try stub.write("\nclass Canvas:\n");
    try stub.write("    \"\"\"Canvas for drawing operations on images\"\"\"\n");

    // Constructor
    try stub.write("    def __init__(self, image: Image) -> None: ...\n");

    // Methods
    try stub.write("    def fill(self, color: Union[Tuple[int, int, int], Tuple[int, int, int, int], 'Rgb', 'Rgba', 'Hsl', 'Hsv', 'Lab', 'Lch', 'Lms', 'Oklab', 'Oklch', 'Xyb', 'Xyz', 'Ycbcr']) -> None: ...\n");
    try stub.write("    def draw_line(self, p1: Tuple[float, float], p2: Tuple[float, float], color: Union[Tuple[int, int, int], Tuple[int, int, int, int], 'Rgb', 'Rgba', 'Hsl', 'Hsv', 'Lab', 'Lch', 'Lms', 'Oklab', 'Oklch', 'Xyb', 'Xyz', 'Ycbcr'], width: int = 1, mode: DrawMode = ...) -> None: ...\n");

    // Properties
    try stub.write("    @property\n");
    try stub.write("    def rows(self) -> int: ...\n");
    try stub.write("    @property\n");
    try stub.write("    def cols(self) -> int: ...\n");
    try stub.write("    @property\n");
    try stub.write("    def image(self) -> Image: ...\n");

    // Standard Python methods
    try stub.write("    def __repr__(self) -> str: ...\n");
}

/// Generate DrawMode enum
fn generateDrawModeEnum(stub: *GeneratedStub) !void {
    try stub.write("\nclass DrawMode(IntEnum):\n");
    try stub.write("    \"\"\"Rendering quality mode for drawing operations\"\"\"\n");
    try stub.write("    FAST = 0\n");
    try stub.write("    SOFT = 1\n");
}

/// Auto-discover and generate known module-level functions
fn generateModuleFunctions(stub: *GeneratedStub) !void {
    // Check for known functions that should be exposed to Python
    if (@hasDecl(zignal, "featureDistributionMatch")) {
        try stub.write("\ndef feature_distribution_match(source: Image, reference: Image) -> None:\n");
        try stub.write("    \"\"\"Apply Feature Distribution Matching (FDM) to transfer color/style from reference to source image.\n");
        try stub.write("    \n");
        try stub.write("    This function modifies the source image in-place to match the color distribution\n");
        try stub.write("    (mean and covariance) of the reference image while preserving the structure of the source.\n");
        try stub.write("    \n");
        try stub.write("    Parameters\n");
        try stub.write("    ----------\n");
        try stub.write("    source : Image\n");
        try stub.write("        Source image to be modified (modified in-place)\n");
        try stub.write("    reference : Image\n");
        try stub.write("        Reference image providing target color distribution\n");
        try stub.write("    \n");
        try stub.write("    Returns\n");
        try stub.write("    -------\n");
        try stub.write("    None\n");
        try stub.write("        This function modifies the source image in-place\n");
        try stub.write("    \"\"\"\n");
        try stub.write("    ...\n");
    }

    // Could add more function discovery here as needed
}

/// Generate complete stub file
fn generateStubFile(allocator: std.mem.Allocator) ![]u8 {
    var stub = GeneratedStub.init(allocator);
    defer stub.deinit();

    // Header and imports
    try stub.write("# Auto-generated Python type stubs for zignal\n");
    try stub.write("# Generated from Zig source code using compile-time reflection\n");
    try stub.write("# Do not modify manually - regenerate using: zig build generate-stubs\n\n");
    try stub.write("from typing import Any, Union, Tuple\n");
    try stub.write("from enum import IntEnum\n");
    try stub.write("import numpy as np\n");

    // Generate all color classes
    inline for (color_registry.color_types) |ColorType| {
        try generateColorClass(&stub, ColorType);
    }

    // Generate InterpolationMethod enum
    try generateInterpolationMethod(&stub);

    // Generate DrawMode enum
    try generateDrawModeEnum(&stub);

    // Generate Image class
    try generateImageClass(&stub);

    // Generate Canvas class
    try generateCanvasClass(&stub);

    // Auto-discover and generate all module-level functions
    try generateModuleFunctions(&stub);

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

    // Add Image and function
    try stub.write("    Image as Image,\n");
    try stub.write("    InterpolationMethod as InterpolationMethod,\n");
    try stub.write("    feature_distribution_match as feature_distribution_match,\n");
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

    // Write zignal.pyi (comprehensive stub file)
    {
        const file = try std.fs.cwd().createFile("zignal.pyi", .{});
        defer file.close();
        try file.writeAll(main_stub_content);
    }

    // Write _zignal.pyi (copy of comprehensive stub file for C extension)
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
    std.debug.print("  zignal.pyi: {} bytes\n", .{main_stub_content.len});
    std.debug.print("  _zignal.pyi: {} bytes\n", .{main_stub_content.len});
    std.debug.print("  __init__.pyi: {} bytes\n", .{init_stub_content.len});
}

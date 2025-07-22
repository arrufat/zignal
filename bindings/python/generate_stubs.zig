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

    // Use empty parameter list since these methods only take self
    try stub.writef("() -> {s}: ...\n", .{target_class});
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

/// Generate ImageRgb class stub - comprehensive method coverage
fn generateImageClass(stub: *GeneratedStub) !void {
    try stub.write("\nclass ImageRgb:\n");
    try stub.write("    \"\"\"RGB image with load/save and NumPy integration capabilities\"\"\"\n");

    // Constructor
    try stub.write("    def __init__(self) -> None: ...\n");

    // All methods that are known to exist in the Python bindings
    // These are defined in the actual Python binding implementation
    try stub.write("    @classmethod\n");
    try stub.write("    def load(cls, path: str) -> ImageRgb: ...\n");
    try stub.write("    def save(self, path: str) -> None: ...\n");
    try stub.write("    def to_numpy(self) -> np.ndarray[Any, np.dtype[np.uint8]]: ...\n");
    try stub.write("    def from_numpy(self, array: np.ndarray[Any, np.dtype[np.uint8]]) -> None: ...\n");
    try stub.write("    @property\n");
    try stub.write("    def rows(self) -> int: ...\n");
    try stub.write("    @property\n");
    try stub.write("    def cols(self) -> int: ...\n");

    // Standard Python methods
    try stub.write("    def __repr__(self) -> str: ...\n");
}

/// Auto-discover and generate known module-level functions
fn generateModuleFunctions(stub: *GeneratedStub) !void {
    // Check for known functions that should be exposed to Python
    if (@hasDecl(zignal, "featureDistributionMatch")) {
        try stub.write("\ndef feature_distribution_match(source: ImageRgb, reference: ImageRgb) -> None:\n");
        try stub.write("    \"\"\"Apply Feature Distribution Matching (FDM) to transfer color/style from reference to source image.\n");
        try stub.write("    \n");
        try stub.write("    This function modifies the source image in-place to match the color distribution\n");
        try stub.write("    (mean and covariance) of the reference image while preserving the structure of the source.\n");
        try stub.write("    \n");
        try stub.write("    Parameters\n");
        try stub.write("    ----------\n");
        try stub.write("    source : ImageRgb\n");
        try stub.write("        Source image to be modified (modified in-place)\n");
        try stub.write("    reference : ImageRgb\n");
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
    try stub.write("from typing import Any\n");
    try stub.write("import numpy as np\n");

    // Generate all color classes
    inline for (color_registry.color_types) |ColorType| {
        try generateColorClass(&stub, ColorType);
    }

    // Generate ImageRgb class
    try generateImageClass(&stub);

    // Auto-discover and generate all module-level functions
    try generateModuleFunctions(&stub);

    // Module metadata
    try stub.write("\n__version__: str\n");
    try stub.write("__all__: list[str]\n");

    return try stub.content.toOwnedSlice();
}

/// Main function to generate and write stub file
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stub_content = try generateStubFile(allocator);
    defer allocator.free(stub_content);

    // Write to zignal.pyi
    const file = try std.fs.cwd().createFile("zignal.pyi", .{});
    defer file.close();

    try file.writeAll(stub_content);

    std.debug.print("Generated zignal.pyi with {} bytes\n", .{stub_content.len});
}

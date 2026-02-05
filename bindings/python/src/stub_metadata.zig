//! Metadata types for automatic Python stub generation
//! This file defines structures that describe Python bindings in a way
//! that can be introspected at compile time for stub generation

const python = @import("python.zig");

/// Describes a Python method for stub generation
pub const MethodInfo = struct {
    /// Method name as it appears in Python
    name: []const u8,
    /// Method signature (parameters with type hints)
    /// Examples: "self, path: str", "cls, array: np.ndarray"
    params: []const u8,
    /// Return type annotation
    /// Examples: "None", "Image", "Tuple[int, int]"
    returns: []const u8,
    /// Method flags
    is_classmethod: bool = false,
    is_staticmethod: bool = false,
    /// Documentation string (optional)
    doc: ?[]const u8 = null,
};

/// Describes a Python property for stub generation
pub const PropertyInfo = struct {
    /// Property name
    name: []const u8,
    /// Property type annotation
    /// Examples: "int", "str", "float"
    type: []const u8,
    /// Whether the property is read-only
    readonly: bool = true,
    /// Documentation string (optional)
    doc: ?[]const u8 = null,
};

/// Describes a Python class for stub generation
pub const ClassInfo = struct {
    /// Class name
    name: []const u8,
    /// Class docstring
    doc: []const u8,
    /// List of methods
    methods: []const MethodInfo,
    /// List of properties
    properties: []const PropertyInfo,
    /// Base classes (optional)
    bases: []const []const u8 = &.{},
    /// Special methods like __init__, __len__, __getitem__ (optional)
    special_methods: ?[]const MethodInfo = null,
};

/// Describes a module-level function
pub const FunctionInfo = struct {
    /// Function name
    name: []const u8,
    /// Function signature (parameters with type hints)
    params: []const u8,
    /// Return type annotation
    returns: []const u8,
    /// Documentation string
    doc: []const u8,
};

/// Documentation for a single enum value
pub const EnumValueDoc = struct {
    /// Enum value name (e.g., "NORMAL", "MULTIPLY")
    name: []const u8,
    /// Short description for inline comment
    doc: []const u8,
};

/// Describes an enum for stub generation
pub const EnumInfo = struct {
    /// Enum name
    name: []const u8,
    /// Base class (usually IntEnum)
    base: []const u8 = "IntEnum",
    /// Documentation string
    doc: []const u8,
    /// Zig type to extract values from
    zig_type: type,
    /// Optional documentation for each enum value
    value_docs: ?[]const EnumValueDoc = null,
};

/// Complete module metadata
pub const ModuleInfo = struct {
    /// Module-level functions
    functions: []const FunctionInfo = &.{},
    /// Classes defined in the module
    classes: []const ClassInfo = &.{},
    /// Enums defined in the module
    enums: []const EnumInfo = &.{},
};

/// Extract MethodInfo array from MethodWithMetadata array for stub generation
pub fn extractMethodInfo(
    comptime methods: []const python.MethodWithMetadata,
) [methods.len]MethodInfo {
    var result: [methods.len]MethodInfo = undefined;
    for (methods, 0..) |m, i| {
        result[i] = .{
            .name = m.name,
            .params = m.params,
            .returns = m.returns,
            .is_classmethod = (m.flags & python.METH_CLASS) != 0,
            .is_staticmethod = (m.flags & python.METH_STATIC) != 0,
            .doc = m.doc,
        };
    }
    return result;
}

/// Extract PropertyInfo array from PropertyWithMetadata array for stub generation
pub fn extractPropertyInfo(
    comptime props: []const python.PropertyWithMetadata,
) [props.len]PropertyInfo {
    var result: [props.len]PropertyInfo = undefined;
    for (props, 0..) |p, i| {
        result[i] = .{
            .name = p.name,
            .type = p.type,
            .readonly = p.set == null,
            .doc = p.doc,
        };
    }
    return result;
}

/// Extract FunctionInfo array from FunctionWithMetadata array for stub generation
pub fn extractFunctionInfo(
    comptime funcs: []const python.FunctionWithMetadata,
) [funcs.len]FunctionInfo {
    var result: [funcs.len]FunctionInfo = undefined;
    for (funcs, 0..) |f, i| {
        result[i] = .{
            .name = f.name,
            .params = f.params,
            .returns = f.returns,
            .doc = f.doc,
        };
    }
    return result;
}

//! Metadata types for automatic Python stub generation
//! This file defines structures that describe Python bindings in a way
//! that can be introspected at compile time for stub generation

const c = @import("python.zig").c;

// Python method flags constants (matching Python C API values)
pub const METH_CLASS = 0x0010;
pub const METH_STATIC = 0x0020;

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

/// Enhanced method definition that includes both PyMethodDef fields and metadata
/// This struct is designed to work with actual Python C API types when imported
pub const MethodWithMetadata = struct {
    /// Method name (required for both C and stub generation)
    name: []const u8,
    /// C function pointer
    meth: *const anyopaque,
    /// Method flags (METH_VARARGS, METH_CLASS, etc.)
    flags: c_int,
    /// Documentation string
    doc: []const u8,

    // Additional metadata for stub generation
    /// Method signature parameters (e.g., "self, x: int, y: int")
    params: []const u8,
    /// Return type annotation (e.g., "None", "int", "Image")
    returns: []const u8,

    /// Convert to MethodInfo for stub generation
    pub fn toMethodInfo(self: MethodWithMetadata) MethodInfo {
        return .{
            .name = self.name,
            .params = self.params,
            .returns = self.returns,
            .is_classmethod = (self.flags & METH_CLASS) != 0,
            .is_staticmethod = (self.flags & METH_STATIC) != 0,
            .doc = self.doc,
        };
    }
};

/// Extract MethodInfo array from MethodWithMetadata array for stub generation
pub fn extractMethodInfo(
    comptime methods: []const MethodWithMetadata,
) [methods.len]MethodInfo {
    var result: [methods.len]MethodInfo = undefined;
    for (methods, 0..) |method, i| {
        result[i] = method.toMethodInfo();
    }
    return result;
}

// Similar structures for properties and functions

/// Enhanced property definition with metadata
pub const PropertyWithMetadata = struct {
    /// Property name
    name: []const u8,
    /// Getter function
    get: *const anyopaque,
    /// Setter function (null for readonly)
    set: ?*anyopaque,
    /// Documentation string
    doc: []const u8,
    /// Type annotation for stub generation
    type: []const u8,

    /// Convert to PropertyInfo for stub generation
    pub fn toPropertyInfo(self: PropertyWithMetadata) PropertyInfo {
        return .{
            .name = self.name,
            .type = self.type,
            .readonly = self.set == null,
            .doc = self.doc,
        };
    }
};

/// Extract PropertyInfo array from PropertyWithMetadata array for stub generation
pub fn extractPropertyInfo(
    comptime props: []const PropertyWithMetadata,
) [props.len]PropertyInfo {
    var result: [props.len]PropertyInfo = undefined;
    for (props, 0..) |prop, i| {
        result[i] = prop.toPropertyInfo();
    }
    return result;
}

/// Enhanced function definition for module-level functions
pub const FunctionWithMetadata = struct {
    /// Function name
    name: []const u8,
    /// C function pointer
    meth: *const anyopaque,
    /// Method flags
    flags: c_int,
    /// Documentation string
    doc: []const u8,
    /// Parameters for stub generation
    params: []const u8,
    /// Return type for stub generation
    returns: []const u8,

    /// Convert to FunctionInfo for stub generation
    pub fn toFunctionInfo(self: FunctionWithMetadata) FunctionInfo {
        return .{
            .name = self.name,
            .params = self.params,
            .returns = self.returns,
            .doc = self.doc,
        };
    }
};

/// Extract FunctionInfo array from FunctionWithMetadata array for stub generation
pub fn extractFunctionInfo(
    comptime funcs: []const FunctionWithMetadata,
) [funcs.len]FunctionInfo {
    var result: [funcs.len]FunctionInfo = undefined;
    for (funcs, 0..) |func, i| {
        result[i] = func.toFunctionInfo();
    }
    return result;
}

/// Convert an array of MethodWithMetadata to PyMethodDef array at compile time
pub fn toPyMethodDefArray(
    comptime methods: []const MethodWithMetadata,
) [methods.len + 1]c.PyMethodDef {
    comptime {
        var result: [methods.len + 1]c.PyMethodDef = undefined;
        for (methods, 0..) |m, i| {
            result[i] = .{
                .ml_name = m.name.ptr,
                .ml_meth = @ptrCast(@alignCast(m.meth)),
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
    comptime props: []const PropertyWithMetadata,
) [props.len + 1]c.PyGetSetDef {
    comptime {
        var result: [props.len + 1]c.PyGetSetDef = undefined;
        for (props, 0..) |p, i| {
            result[i] = .{
                .name = p.name.ptr,
                .get = @ptrCast(@alignCast(p.get)),
                .set = if (p.set) |s| @ptrCast(@alignCast(s)) else null,
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
    comptime funcs: []const FunctionWithMetadata,
) [funcs.len + 1]c.PyMethodDef {
    comptime {
        var result: [funcs.len + 1]c.PyMethodDef = undefined;
        for (funcs, 0..) |f, i| {
            result[i] = .{
                .ml_name = f.name.ptr,
                .ml_meth = @ptrCast(@alignCast(f.meth)),
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

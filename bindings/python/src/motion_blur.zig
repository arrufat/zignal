const std = @import("std");

const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

// ============================================================================
// Motion Blur Type Enum
// ============================================================================

const MotionBlurVariant = enum(u8) {
    linear,
    radial_zoom,
    radial_spin,
};

// ============================================================================
// Unified MotionBlur Object
// ============================================================================

pub const MotionBlurObject = extern struct {
    ob_base: c.PyObject,
    blur_type: MotionBlurVariant,

    // Linear parameters
    angle: f64,
    distance: c_long,

    // Radial parameters (shared by zoom and spin)
    center_x: f64,
    center_y: f64,
    strength: f64,
};

// ============================================================================
// MotionBlur Implementation
// ============================================================================

// Using genericDealloc since there's no heap allocation to clean up
const motion_blur_dealloc = py_utils.genericDealloc(MotionBlurObject, null);

fn motion_blur_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*MotionBlurObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize with defaults
        obj.blur_type = .linear;
        obj.angle = 0.0;
        obj.distance = 0;
        obj.center_x = 0.5;
        obj.center_y = 0.5;
        obj.strength = 0.5;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn motion_blur_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;
    // This should not be called directly - factory methods handle initialization
    py_utils.setTypeError("MotionBlur factory methods", null);
    return -1;
}

fn motion_blur_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(MotionBlurObject, self_obj);
    var buf: [256]u8 = undefined;

    const str = switch (self.blur_type) {
        .linear => std.fmt.bufPrintZ(
            &buf,
            "MotionBlur.linear(angle={d:.4}, distance={d})",
            .{ self.angle, self.distance },
        ) catch return null,
        .radial_zoom => std.fmt.bufPrintZ(
            &buf,
            "MotionBlur.radial_zoom(center=({d:.3}, {d:.3}), strength={d:.3})",
            .{ self.center_x, self.center_y, self.strength },
        ) catch return null,
        .radial_spin => std.fmt.bufPrintZ(
            &buf,
            "MotionBlur.radial_spin(center=({d:.3}, {d:.3}), strength={d:.3})",
            .{ self.center_x, self.center_y, self.strength },
        ) catch return null,
    };

    return c.PyUnicode_FromString(str);
}

// ============================================================================
// Static Factory Methods
// ============================================================================

fn motion_blur_linear(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;

    const Params = struct {
        angle: f64,
        distance: c_long,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;
    const angle = params.angle;
    const distance = params.distance;

    const dist = py_utils.validateNonNegative(u32, distance, "distance") catch return null;

    // Create new instance
    const self = @as(?*MotionBlurObject, @ptrCast(c.PyType_GenericAlloc(&MotionBlurType, 0)));
    if (self) |obj| {
        obj.blur_type = .linear;
        obj.angle = angle;
        obj.distance = @intCast(dist);
        // Other fields keep their defaults
        obj.center_x = 0.5;
        obj.center_y = 0.5;
        obj.strength = 0.5;
    }

    return @as(?*c.PyObject, @ptrCast(self));
}

fn motion_blur_radial_zoom(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;

    const Params = struct {
        center: ?*c.PyObject = null, // Optional with default
        strength: f64 = 0.5, // Optional with default
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;
    const center_tuple = params.center;
    const strength = params.strength;

    var center_x: f64 = 0.5;
    var center_y: f64 = 0.5;

    // Parse center tuple if provided
    if (center_tuple != null) {
        if (c.PyArg_ParseTuple(center_tuple, "dd", &center_x, &center_y) == 0) {
            py_utils.setTypeError("tuple of two floats", center_tuple);
            return null;
        }

        _ = py_utils.validateRange(f64, center_x, 0.0, 1.0, "center[0]") catch return null;
        _ = py_utils.validateRange(f64, center_y, 0.0, 1.0, "center[1]") catch return null;
    }

    const strength_val = py_utils.validateRange(f64, strength, 0.0, 1.0, "strength") catch return null;

    // Create new instance
    const self = @as(?*MotionBlurObject, @ptrCast(c.PyType_GenericAlloc(&MotionBlurType, 0)));
    if (self) |obj| {
        obj.blur_type = .radial_zoom;
        obj.center_x = center_x;
        obj.center_y = center_y;
        obj.strength = strength_val;
        // Linear fields keep their defaults
        obj.angle = 0.0;
        obj.distance = 0;
    }

    return @as(?*c.PyObject, @ptrCast(self));
}

fn motion_blur_radial_spin(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = type_obj;

    const Params = struct {
        center: ?*c.PyObject = null, // Optional with default
        strength: f64 = 0.5, // Optional with default
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;
    const center_tuple = params.center;
    const strength = params.strength;

    var center_x: f64 = 0.5;
    var center_y: f64 = 0.5;

    // Parse center tuple if provided
    if (center_tuple != null) {
        if (c.PyArg_ParseTuple(center_tuple, "dd", &center_x, &center_y) == 0) {
            py_utils.setTypeError("tuple of two floats", center_tuple);
            return null;
        }

        _ = py_utils.validateRange(f64, center_x, 0.0, 1.0, "center[0]") catch return null;
        _ = py_utils.validateRange(f64, center_y, 0.0, 1.0, "center[1]") catch return null;
    }

    const strength_val = py_utils.validateRange(f64, strength, 0.0, 1.0, "strength") catch return null;

    // Create new instance
    const self = @as(?*MotionBlurObject, @ptrCast(c.PyType_GenericAlloc(&MotionBlurType, 0)));
    if (self) |obj| {
        obj.blur_type = .radial_spin;
        obj.center_x = center_x;
        obj.center_y = center_y;
        obj.strength = strength_val;
        // Linear fields keep their defaults
        obj.angle = 0.0;
        obj.distance = 0;
    }

    return @as(?*c.PyObject, @ptrCast(self));
}

// ============================================================================
// Property Getters
// ============================================================================
fn get_type(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(MotionBlurObject, self_obj);
    const type_str = switch (self.blur_type) {
        .linear => "linear",
        .radial_zoom => "radial_zoom",
        .radial_spin => "radial_spin",
    };
    return c.PyUnicode_FromString(type_str);
}

// Predicates for optional properties
fn is_linear(self: *MotionBlurObject) bool {
    return self.blur_type == .linear;
}
fn is_not_linear(self: *MotionBlurObject) bool {
    return self.blur_type != .linear;
}

// ============================================================================
// Type Definition
// ============================================================================

pub const motion_blur_doc =
    \\Motion blur effect configuration.
    \\
    \\Use the static factory methods to create motion blur configurations:
    \\- `MotionBlur.linear(angle, distance)` - Linear motion blur
    \\- `MotionBlur.radial_zoom(center, strength)` - Radial zoom blur
    \\- `MotionBlur.radial_spin(center, strength)` - Radial spin blur
    \\
    \\## Examples
    \\```python
    \\import math
    \\from zignal import Image, MotionBlur
    \\
    \\img = Image.load("photo.jpg")
    \\
    \\# Linear motion blur
    \\horizontal = img.motion_blur(MotionBlur.linear(angle=0, distance=30))
    \\vertical = img.motion_blur(MotionBlur.linear(angle=math.pi/2, distance=20))
    \\
    \\# Radial zoom blur
    \\zoom = img.motion_blur(MotionBlur.radial_zoom(center=(0.5, 0.5), strength=0.7))
    \\zoom_default = img.motion_blur(MotionBlur.radial_zoom())  # Uses defaults
    \\
    \\# Radial spin blur
    \\spin = img.motion_blur(MotionBlur.radial_spin(center=(0.3, 0.7), strength=0.5))
    \\```
;

var motion_blur_methods = [_]c.PyMethodDef{
    .{
        .ml_name = "linear",
        .ml_meth = @ptrCast(&motion_blur_linear),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create linear motion blur configuration.\n\nArgs:\n    angle: Blur angle in radians (0 = horizontal)\n    distance: Blur distance in pixels",
    },
    .{
        .ml_name = "radial_zoom",
        .ml_meth = @ptrCast(&motion_blur_radial_zoom),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create radial zoom blur configuration.\n\nArgs:\n    center: Normalized center (x, y), default (0.5, 0.5)\n    strength: Blur strength (0.0-1.0), default 0.5",
    },
    .{
        .ml_name = "radial_spin",
        .ml_meth = @ptrCast(&motion_blur_radial_spin),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create radial spin blur configuration.\n\nArgs:\n    center: Normalized center (x, y), default (0.5, 0.5)\n    strength: Blur strength (0.0-1.0), default 0.5",
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var motion_blur_getset = [_]c.PyGetSetDef{
    .{
        .name = "type",
        .get = get_type,
        .set = null,
        .doc = "Type of motion blur: 'linear', 'radial_zoom', or 'radial_spin'",
        .closure = null,
    },
    .{
        .name = "angle",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalFieldWhere(MotionBlurObject, "angle", is_linear))),
        .set = null,
        .doc = "Blur angle in radians (linear only)",
        .closure = null,
    },
    .{
        .name = "distance",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalFieldWhere(MotionBlurObject, "distance", is_linear))),
        .set = null,
        .doc = "Blur distance in pixels (linear only)",
        .closure = null,
    },
    .{
        .name = "center",
        .get = @ptrCast(@alignCast(py_utils.getterTuple2FieldsWhere(MotionBlurObject, "center_x", "center_y", is_not_linear))),
        .set = null,
        .doc = "Normalized center position (zoom/spin only)",
        .closure = null,
    },
    .{
        .name = "strength",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalFieldWhere(MotionBlurObject, "strength", is_not_linear))),
        .set = null,
        .doc = "Blur strength 0.0-1.0 (zoom/spin only)",
        .closure = null,
    },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

// Using buildTypeObject helper for cleaner initialization
pub var MotionBlurType = py_utils.buildTypeObject(.{
    .name = "zignal.MotionBlur",
    .basicsize = @sizeOf(MotionBlurObject),
    .doc = motion_blur_doc,
    .methods = &motion_blur_methods,
    .getset = &motion_blur_getset,
    .new = motion_blur_new,
    .init = motion_blur_init,
    .dealloc = motion_blur_dealloc,
    .repr = motion_blur_repr,
});

// ============================================================================
// Metadata for stub generation
// ============================================================================

pub const motion_blur_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "type",
        .get = get_type,
        .set = null,
        .doc = "Type of motion blur: 'linear', 'radial_zoom', or 'radial_spin'",
        .type = "Literal['linear', 'radial_zoom', 'radial_spin']",
    },
    .{
        .name = "angle",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalFieldWhere(MotionBlurObject, "angle", is_linear))),
        .set = null,
        .doc = "Blur angle in radians (linear only)",
        .type = "float | None",
    },
    .{
        .name = "distance",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalFieldWhere(MotionBlurObject, "distance", is_linear))),
        .set = null,
        .doc = "Blur distance in pixels (linear only)",
        .type = "int | None",
    },
    .{
        .name = "center",
        .get = @ptrCast(@alignCast(py_utils.getterTuple2FieldsWhere(MotionBlurObject, "center_x", "center_y", is_not_linear))),
        .set = null,
        .doc = "Normalized center position (zoom/spin only)",
        .type = "tuple[float, float] | None",
    },
    .{
        .name = "strength",
        .get = @ptrCast(@alignCast(py_utils.getterOptionalFieldWhere(MotionBlurObject, "strength", is_not_linear))),
        .set = null,
        .doc = "Blur strength 0.0-1.0 (zoom/spin only)",
        .type = "float | None",
    },
};

pub const motion_blur_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "linear",
        .params = "angle: float, distance: int",
        .returns = "MotionBlur",
        .doc = "Create linear motion blur configuration.",
    },
    .{
        .name = "radial_zoom",
        .params = "center: tuple[float, float] = (0.5, 0.5), strength: float = 0.5",
        .returns = "MotionBlur",
        .doc = "Create radial zoom blur configuration.",
    },
    .{
        .name = "radial_spin",
        .params = "center: tuple[float, float] = (0.5, 0.5), strength: float = 0.5",
        .returns = "MotionBlur",
        .doc = "Create radial spin blur configuration.",
    },
};

pub const motion_blur_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__repr__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
};

// Register the motion blur type
pub fn registerMotionBlur(module: *c.PyObject) !void {
    // Initialize type
    if (c.PyType_Ready(&MotionBlurType) < 0) {
        return error.TypeInitFailed;
    }

    // Add to module
    // TODO: Remove explicit cast after Python 3.10 is dropped
    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(&MotionBlurType)));
    if (c.PyModule_AddObject(module, "MotionBlur", @as(?*c.PyObject, @ptrCast(&MotionBlurType))) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(&MotionBlurType)));
        return error.ModuleAddFailed;
    }
}

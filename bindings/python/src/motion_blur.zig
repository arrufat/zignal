const std = @import("std");
const zignal = @import("zignal");

const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

// ============================================================================
// Motion Blur Configuration Classes
// ============================================================================

// MotionBlurLinear configuration object
pub const LinearObject = extern struct {
    ob_base: c.PyObject,
    angle: f64,
    distance: c_long,
};

// MotionBlurZoom configuration object
pub const RadialZoomObject = extern struct {
    ob_base: c.PyObject,
    center_x: f64,
    center_y: f64,
    strength: f64,
};

// MotionBlurSpin configuration object
pub const RadialSpinObject = extern struct {
    ob_base: c.PyObject,
    center_x: f64,
    center_y: f64,
    strength: f64,
};

// ============================================================================
// MotionBlurLinear Implementation
// ============================================================================

fn linear_dealloc(self: [*c]c.PyObject) callconv(.c) void {
    c.Py_TYPE(self).*.tp_free.?(self);
}

fn linear_new(type_obj: [*c]c.PyTypeObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*LinearObject, @ptrCast(type_obj.*.tp_alloc.?(type_obj, 0)));
    if (self) |obj| {
        obj.angle = 0.0;
        obj.distance = 0;
    }
    return @ptrCast(self);
}

fn linear_init(self_obj: [*c]c.PyObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) c_int {
    const self = @as(*LinearObject, @ptrCast(self_obj));

    var angle: f64 = 0.0;
    var distance: c_long = 0;

    var kwlist = [_:null]?[*:0]u8{ @constCast("angle"), @constCast("distance"), null };
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, "dl", @ptrCast(&kwlist), &angle, &distance) == 0) {
        return -1;
    }

    if (distance < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "distance must be non-negative");
        return -1;
    }

    self.angle = angle;
    self.distance = distance;

    return 0;
}

fn linear_repr(self_obj: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    const self = @as(*LinearObject, @ptrCast(self_obj));
    var buf: [256]u8 = undefined;
    const str = std.fmt.bufPrintZ(
        &buf,
        "MotionBlurLinear(angle={d:.4}, distance={d})",
        .{ self.angle, self.distance },
    ) catch return null;

    return @ptrCast(c.PyUnicode_FromString(str));
}

fn linear_get_angle(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*LinearObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(self.angle);
}

fn linear_get_distance(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*LinearObject, @ptrCast(self_obj.?));
    return c.PyLong_FromLong(self.distance);
}

pub const linear_doc =
    \\Linear motion blur configuration.
    \\
    \\Simulates straight-line motion blur effects such as camera shake or panning.
    \\This type of blur is commonly seen when a camera moves in a straight line during exposure.
    \\
    \\## Parameters:
    \\- `angle` (float): Blur angle in radians. 0 = horizontal, π/2 = vertical, π/4 = diagonal.
    \\- `distance` (int): Blur distance in pixels. Larger values create stronger blur.
;

pub var LinearType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.MotionBlurLinear",
    .tp_basicsize = @sizeOf(LinearObject),
    .tp_dealloc = linear_dealloc,
    .tp_repr = linear_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = linear_doc,
    .tp_getset = &linear_getset,
    .tp_init = linear_init,
    .tp_new = linear_new,
};

// ============================================================================
// MotionBlurZoom Implementation
// ============================================================================

fn zoom_dealloc(self: [*c]c.PyObject) callconv(.c) void {
    c.Py_TYPE(self).*.tp_free.?(self);
}

fn zoom_new(type_obj: [*c]c.PyTypeObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*RadialZoomObject, @ptrCast(type_obj.*.tp_alloc.?(type_obj, 0)));
    if (self) |obj| {
        obj.center_x = 0.5;
        obj.center_y = 0.5;
        obj.strength = 0.5;
    }
    return @ptrCast(self);
}

fn zoom_init(self_obj: [*c]c.PyObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) c_int {
    const self = @as(*RadialZoomObject, @ptrCast(self_obj));

    var center_tuple: [*c]c.PyObject = null;
    var strength: f64 = 0.5;

    var kwlist = [_:null]?[*:0]u8{ @constCast("center"), @constCast("strength"), null };
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, "|Od", @ptrCast(&kwlist), &center_tuple, &strength) == 0) {
        return -1;
    }

    // Parse center tuple if provided
    if (center_tuple != null) {
        var center_x: f64 = 0.5;
        var center_y: f64 = 0.5;
        if (c.PyArg_ParseTuple(center_tuple, "dd", &center_x, &center_y) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "center must be a tuple of two floats");
            return -1;
        }
        self.center_x = center_x;
        self.center_y = center_y;

        // Validate parameters
        if (self.center_x < 0.0 or self.center_x > 1.0) {
            c.PyErr_SetString(c.PyExc_ValueError, "center[0] must be between 0.0 and 1.0");
            return -1;
        }
        if (self.center_y < 0.0 or self.center_y > 1.0) {
            c.PyErr_SetString(c.PyExc_ValueError, "center[1] must be between 0.0 and 1.0");
            return -1;
        }
    } else {
        self.center_x = 0.5;
        self.center_y = 0.5;
    }

    if (strength < 0.0 or strength > 1.0) {
        c.PyErr_SetString(c.PyExc_ValueError, "strength must be between 0.0 and 1.0");
        return -1;
    }

    self.strength = strength;

    return 0;
}

fn zoom_repr(self_obj: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    const self = @as(*RadialZoomObject, @ptrCast(self_obj));
    var buf: [256]u8 = undefined;
    const str = std.fmt.bufPrintZ(
        &buf,
        "MotionBlurZoom(center=({d:.3}, {d:.3}), strength={d:.3})",
        .{ self.center_x, self.center_y, self.strength },
    ) catch return null;

    return @ptrCast(c.PyUnicode_FromString(str));
}

fn zoom_get_center(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RadialZoomObject, @ptrCast(self_obj.?));
    return c.Py_BuildValue("(dd)", self.center_x, self.center_y);
}

fn zoom_get_strength(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RadialZoomObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(self.strength);
}

pub const zoom_doc =
    \\Motion blur zoom effect configuration.
    \\
    \\Simulates zooming in or out from a center point, creating a "zoom burst" effect.
    \\This effect radiates outward from the specified center point, similar to zooming
    \\a camera lens during exposure.
    \\
    \\## Parameters:
    \\- `center` (tuple[float, float]): Normalized center position (x, y) where both values are 0.0-1.0. Default is (0.5, 0.5).
    \\- `strength` (float): Blur strength (0.0-1.0). Higher values create stronger zoom effect.
;

pub var ZoomType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.MotionBlurZoom",
    .tp_basicsize = @sizeOf(RadialZoomObject),
    .tp_dealloc = zoom_dealloc,
    .tp_repr = zoom_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = zoom_doc,
    .tp_getset = &zoom_getset,
    .tp_init = zoom_init,
    .tp_new = zoom_new,
};

// ============================================================================
// MotionBlurSpin Implementation
// ============================================================================

fn spin_dealloc(self: [*c]c.PyObject) callconv(.c) void {
    c.Py_TYPE(self).*.tp_free.?(self);
}

fn spin_new(type_obj: [*c]c.PyTypeObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*RadialSpinObject, @ptrCast(type_obj.*.tp_alloc.?(type_obj, 0)));
    if (self) |obj| {
        obj.center_x = 0.5;
        obj.center_y = 0.5;
        obj.strength = 0.5;
    }
    return @ptrCast(self);
}

fn spin_init(self_obj: [*c]c.PyObject, args: [*c]c.PyObject, kwds: [*c]c.PyObject) callconv(.c) c_int {
    const self = @as(*RadialSpinObject, @ptrCast(self_obj));

    var center_tuple: [*c]c.PyObject = null;
    var strength: f64 = 0.5;

    var kwlist = [_:null]?[*:0]u8{ @constCast("center"), @constCast("strength"), null };
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, "|Od", @ptrCast(&kwlist), &center_tuple, &strength) == 0) {
        return -1;
    }

    // Parse center tuple if provided
    if (center_tuple != null) {
        var center_x: f64 = 0.5;
        var center_y: f64 = 0.5;
        if (c.PyArg_ParseTuple(center_tuple, "dd", &center_x, &center_y) == 0) {
            c.PyErr_SetString(c.PyExc_TypeError, "center must be a tuple of two floats");
            return -1;
        }
        self.center_x = center_x;
        self.center_y = center_y;

        // Validate parameters
        if (self.center_x < 0.0 or self.center_x > 1.0) {
            c.PyErr_SetString(c.PyExc_ValueError, "center[0] must be between 0.0 and 1.0");
            return -1;
        }
        if (self.center_y < 0.0 or self.center_y > 1.0) {
            c.PyErr_SetString(c.PyExc_ValueError, "center[1] must be between 0.0 and 1.0");
            return -1;
        }
    } else {
        self.center_x = 0.5;
        self.center_y = 0.5;
    }

    if (strength < 0.0 or strength > 1.0) {
        c.PyErr_SetString(c.PyExc_ValueError, "strength must be between 0.0 and 1.0");
        return -1;
    }

    self.strength = strength;

    return 0;
}

fn spin_repr(self_obj: [*c]c.PyObject) callconv(.c) [*c]c.PyObject {
    const self = @as(*RadialSpinObject, @ptrCast(self_obj));
    var buf: [256]u8 = undefined;
    const str = std.fmt.bufPrintZ(
        &buf,
        "MotionBlurSpin(center=({d:.3}, {d:.3}), strength={d:.3})",
        .{ self.center_x, self.center_y, self.strength },
    ) catch return null;

    return @ptrCast(c.PyUnicode_FromString(str));
}

fn spin_get_center(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RadialSpinObject, @ptrCast(self_obj.?));
    return c.Py_BuildValue("(dd)", self.center_x, self.center_y);
}

fn spin_get_strength(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*RadialSpinObject, @ptrCast(self_obj.?));
    return c.PyFloat_FromDouble(self.strength);
}

pub const spin_doc =
    \\Motion blur spin effect configuration.
    \\
    \\Simulates rotational motion blur around a center point, creating a spinning effect.
    \\This effect creates circular blur trails around the specified center, similar to
    \\rotating the camera during exposure.
    \\
    \\## Parameters:
    \\- `center` (tuple[float, float]): Normalized center position (x, y) where both values are 0.0-1.0. Default is (0.5, 0.5).
    \\- `strength` (float): Blur strength (0.0-1.0). Higher values create stronger rotation.
;

pub var SpinType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.MotionBlurSpin",
    .tp_basicsize = @sizeOf(RadialSpinObject),
    .tp_dealloc = spin_dealloc,
    .tp_repr = spin_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = spin_doc,
    .tp_getset = &spin_getset,
    .tp_init = spin_init,
    .tp_new = spin_new,
};

// ============================================================================
// Metadata for stub generation
// ============================================================================

// Linear class metadata
pub const linear_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "angle",
        .get = linear_get_angle,
        .set = null,
        .doc = "Blur angle in radians (0 = horizontal)",
        .type = "float",
    },
    .{
        .name = "distance",
        .get = linear_get_distance,
        .set = null,
        .doc = "Blur distance in pixels",
        .type = "int",
    },
};

pub const linear_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, angle: float, distance: int",
        .returns = "None",
        .doc = "Create linear motion blur configuration.\n\nArgs:\n    angle: Blur angle in radians (0 = horizontal)\n    distance: Blur distance in pixels",
    },
    .{
        .name = "__repr__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
};

// Generate getset array from metadata
var linear_getset = stub_metadata.toPyGetSetDefArray(&linear_properties_metadata);

// Zoom class metadata
pub const zoom_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "center",
        .get = zoom_get_center,
        .set = null,
        .doc = "Normalized center position (x, y)",
        .type = "tuple[float, float]",
    },
    .{
        .name = "strength",
        .get = zoom_get_strength,
        .set = null,
        .doc = "Blur strength (0.0-1.0)",
        .type = "float",
    },
};

pub const zoom_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, center: tuple[float, float] = (0.5, 0.5), strength: float = 0.5",
        .returns = "None",
        .doc = "Create radial zoom blur configuration.\n\nArgs:\n    center: Normalized center position (x, y), default (0.5, 0.5)\n    strength: Blur strength (0.0-1.0), default 0.5",
    },
    .{
        .name = "__repr__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
};

// Generate getset array from metadata
var zoom_getset = stub_metadata.toPyGetSetDefArray(&zoom_properties_metadata);

// Spin class metadata
pub const spin_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "center",
        .get = spin_get_center,
        .set = null,
        .doc = "Normalized center position (x, y)",
        .type = "tuple[float, float]",
    },
    .{
        .name = "strength",
        .get = spin_get_strength,
        .set = null,
        .doc = "Blur strength (0.0-1.0)",
        .type = "float",
    },
};

pub const spin_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, center: tuple[float, float] = (0.5, 0.5), strength: float = 0.5",
        .returns = "None",
        .doc = "Create radial spin blur configuration.\n\nArgs:\n    center: Normalized center position (x, y), default (0.5, 0.5)\n    strength: Blur strength (0.0-1.0), default 0.5",
    },
    .{
        .name = "__repr__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
};

// Generate getset array from metadata
var spin_getset = stub_metadata.toPyGetSetDefArray(&spin_properties_metadata);

// Register all motion blur types
pub fn registerMotionBlur(module: *c.PyObject) !void {
    // Initialize types
    if (c.PyType_Ready(&LinearType) < 0) {
        return error.TypeInitFailed;
    }
    if (c.PyType_Ready(&ZoomType) < 0) {
        return error.TypeInitFailed;
    }
    if (c.PyType_Ready(&SpinType) < 0) {
        return error.TypeInitFailed;
    }

    // Add to module as top-level classes
    // TODO: Remove explicit cast after Python 3.10 is dropped
    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(&LinearType)));
    if (c.PyModule_AddObject(module, "MotionBlurLinear", @as(?*c.PyObject, @ptrCast(&LinearType))) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(&LinearType)));
        return error.ModuleAddFailed;
    }

    // TODO: Remove explicit cast after Python 3.10 is dropped
    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(&ZoomType)));
    if (c.PyModule_AddObject(module, "MotionBlurZoom", @as(?*c.PyObject, @ptrCast(&ZoomType))) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(&ZoomType)));
        return error.ModuleAddFailed;
    }

    // TODO: Remove explicit cast after Python 3.10 is dropped
    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(&SpinType)));
    if (c.PyModule_AddObject(module, "MotionBlurSpin", @as(?*c.PyObject, @ptrCast(&SpinType))) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(&SpinType)));
        return error.ModuleAddFailed;
    }
}

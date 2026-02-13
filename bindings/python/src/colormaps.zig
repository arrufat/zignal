const std = @import("std");

const python = @import("python.zig");
const c = python.c;
const stub_metadata = @import("stub_metadata.zig");
const zignal = @import("zignal");

// ============================================================================
// Colormap Type Enum
// ============================================================================

const ColormapVariant = enum(u8) {
    jet,
    heat,
    turbo,
    viridis,
};

// ============================================================================
// Colormap Object
// ============================================================================

pub const ColormapObject = extern struct {
    ob_base: c.PyObject,
    map_type: ColormapVariant,
    min: f64,
    max: f64,
    has_min: bool,
    has_max: bool,
};

// ============================================================================
// Colormap Implementation
// ============================================================================

// Using genericDealloc since there's no heap allocation to clean up
const colormap_dealloc = python.genericDealloc(ColormapObject, null);

fn colormap_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self: ?*ColormapObject = @ptrCast(c.PyType_GenericAlloc(type_obj, 0));
    if (self) |obj| {
        // Initialize with defaults (no range set)
        obj.map_type = .jet;
        obj.min = 0.0;
        obj.max = 0.0;
        obj.has_min = false;
        obj.has_max = false;
    }
    return @ptrCast(self);
}

fn colormap_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;
    // This should not be called directly - factory methods handle initialization
    python.setTypeError("Colormap factory methods", null);
    return -1;
}

fn colormap_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ColormapObject, self_obj);
    var buf: [256]u8 = undefined;

    const type_name = switch (self.map_type) {
        .jet => "jet",
        .heat => "heat",
        .turbo => "turbo",
        .viridis => "viridis",
    };

    var min_str: [32]u8 = undefined;
    var max_str: [32]u8 = undefined;

    const min_part = if (self.has_min) std.fmt.bufPrint(&min_str, "{d}", .{self.min}) catch "..." else "None";
    const max_part = if (self.has_max) std.fmt.bufPrint(&max_str, "{d}", .{self.max}) catch "..." else "None";

    const str = std.fmt.bufPrintZ(
        &buf,
        "Colormap.{s}(min={s}, max={s})",
        .{ type_name, min_part, max_part },
    ) catch return null;

    return python.create(str);
}

// ============================================================================
// Internal Factory Helper
// ============================================================================

fn create_colormap(type_obj: ?*c.PyObject, variant: ColormapVariant, args: ?*c.PyObject, kwds: ?*c.PyObject) ?*c.PyObject {
    _ = type_obj;

    const Params = struct {
        min: ?*c.PyObject = null,
        max: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    // Create new instance
    const self: ?*ColormapObject = @ptrCast(c.PyType_GenericAlloc(&ColormapType, 0));
    if (self) |obj| {
        obj.map_type = variant;

        if (params.min) |min_obj| {
            if (min_obj == c.Py_None()) {
                obj.has_min = false;
            } else {
                obj.min = c.PyFloat_AsDouble(min_obj);
                if (c.PyErr_Occurred() != null) {
                    c.Py_DECREF(@ptrCast(obj));
                    return null;
                }
                obj.has_min = true;
            }
        } else {
            obj.has_min = false;
        }

        if (params.max) |max_obj| {
            if (max_obj == c.Py_None()) {
                obj.has_max = false;
            } else {
                obj.max = c.PyFloat_AsDouble(max_obj);
                if (c.PyErr_Occurred() != null) {
                    c.Py_DECREF(@ptrCast(obj));
                    return null;
                }
                obj.has_max = true;
            }
        } else {
            obj.has_max = false;
        }
    }

    return @ptrCast(self);
}

// ============================================================================
// Static Factory Methods
// ============================================================================

fn colormap_jet(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return create_colormap(type_obj, .jet, args, kwds);
}

fn colormap_heat(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return create_colormap(type_obj, .heat, args, kwds);
}

fn colormap_turbo(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return create_colormap(type_obj, .turbo, args, kwds);
}

fn colormap_viridis(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return create_colormap(type_obj, .viridis, args, kwds);
}

// ============================================================================
// Property Getters
// ============================================================================
fn get_type(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(ColormapObject, self_obj);
    const type_str = switch (self.map_type) {
        .jet => "jet",
        .heat => "heat",
        .turbo => "turbo",
        .viridis => "viridis",
    };
    return python.create(type_str);
}

fn get_min(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(ColormapObject, self_obj);
    if (self.has_min) {
        return python.create(self.min);
    } else {
        c.Py_INCREF(c.Py_None());
        return c.Py_None();
    }
}

fn get_max(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(ColormapObject, self_obj);
    if (self.has_max) {
        return python.create(self.max);
    } else {
        c.Py_INCREF(c.Py_None());
        return c.Py_None();
    }
}

// ============================================================================
// Type Definition
// ============================================================================

pub const colormap_doc =
    \\Colormap configuration for visualization.
    \\
    \\Use the static factory methods to create colormap configurations:
    \\- `Colormap.jet(min=None, max=None)` - Classic rainbow (blue->cyan->yellow->red)
    \\- `Colormap.heat(min=None, max=None)` - Heat map (black->red->yellow->white)
    \\- `Colormap.turbo(min=None, max=None)` - Improved smooth rainbow
    \\- `Colormap.viridis(min=None, max=None)` - Perceptually uniform (purple->green->yellow)
    \\
    \\If `min` or `max` are not provided, they will be automatically calculated from the image content.
    \\
    \\## Examples
    \\```python
    \\from zignal import Image, Colormap
    \\
    \\img = Image.load("depth_map.png")
    \\
    \\# Use auto-scaling
    \\vis = img.apply_colormap(Colormap.turbo())
    \\
    \\# Use fixed range
    \\heatmap = img.apply_colormap(Colormap.heat(min=0.0, max=100.0))
    \\```
;

var colormap_methods = [_]c.PyMethodDef{
    .{
        .ml_name = "jet",
        .ml_meth = @ptrCast(&colormap_jet),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create jet colormap configuration.\n\nArgs:\n    min: Minimum value (optional)\n    max: Maximum value (optional)",
    },
    .{
        .ml_name = "heat",
        .ml_meth = @ptrCast(&colormap_heat),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create heat colormap configuration.\n\nArgs:\n    min: Minimum value (optional)\n    max: Maximum value (optional)",
    },
    .{
        .ml_name = "turbo",
        .ml_meth = @ptrCast(&colormap_turbo),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create turbo colormap configuration.\n\nArgs:\n    min: Minimum value (optional)\n    max: Maximum value (optional)",
    },
    .{
        .ml_name = "viridis",
        .ml_meth = @ptrCast(&colormap_viridis),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_STATIC,
        .ml_doc = "Create viridis colormap configuration.\n\nArgs:\n    min: Minimum value (optional)\n    max: Maximum value (optional)",
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var colormap_getset = python.toPyGetSetDefArray(&colormap_properties_metadata);

pub var ColormapType = python.buildTypeObject(.{
    .name = "zignal.Colormap",
    .basicsize = @sizeOf(ColormapObject),
    .doc = colormap_doc,
    .methods = &colormap_methods,
    .getset = &colormap_getset,
    .new = colormap_new,
    .init = colormap_init,
    .dealloc = colormap_dealloc,
    .repr = colormap_repr,
});

// ============================================================================
// Metadata for stub generation
// ============================================================================

pub const colormap_properties_metadata = [_]python.PropertyWithMetadata{
    .{
        .name = "type",
        .get = get_type,
        .set = null,
        .doc = "Type of colormap",
        .type = "Literal['jet', 'heat', 'turbo', 'viridis']",
    },
    .{
        .name = "min",
        .get = get_min,
        .set = null,
        .doc = "Minimum value for scaling (or None for auto)",
        .type = "float | None",
    },
    .{
        .name = "max",
        .get = get_max,
        .set = null,
        .doc = "Maximum value for scaling (or None for auto)",
        .type = "float | None",
    },
};

pub const colormap_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "jet",
        .params = "min: float | None = None, max: float | None = None",
        .returns = "Colormap",
        .doc = "Create jet colormap configuration.",
    },
    .{
        .name = "heat",
        .params = "min: float | None = None, max: float | None = None",
        .returns = "Colormap",
        .doc = "Create heat colormap configuration.",
    },
    .{
        .name = "turbo",
        .params = "min: float | None = None, max: float | None = None",
        .returns = "Colormap",
        .doc = "Create turbo colormap configuration.",
    },
    .{
        .name = "viridis",
        .params = "min: float | None = None, max: float | None = None",
        .returns = "Colormap",
        .doc = "Create viridis colormap configuration.",
    },
};

pub const colormap_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__repr__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
};

// Register the colormap type
pub fn registerColormap(module: *c.PyObject) !void {
    if (c.PyType_Ready(&ColormapType) < 0) {
        return error.TypeInitFailed;
    }

    c.Py_INCREF(@as(?*c.PyObject, @ptrCast(&ColormapType)));
    if (c.PyModule_AddObject(module, "Colormap", @ptrCast(&ColormapType)) < 0) {
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(&ColormapType)));
        return error.ModuleAddFailed;
    }
}

// ============================================================================
// Helper to convert Python ColormapObject to Zig Colormap union
// ============================================================================

pub fn toZigColormap(obj: *ColormapObject) zignal.Colormap {
    const range = zignal.Colormap.Range{
        .min = if (obj.has_min) obj.min else null,
        .max = if (obj.has_max) obj.max else null,
    };

    return switch (obj.map_type) {
        .jet => .{ .jet = range },
        .heat => .{ .heat = range },
        .turbo => .{ .turbo = range },
        .viridis => .{ .viridis = range },
    };
}

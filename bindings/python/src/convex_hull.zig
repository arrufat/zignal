const std = @import("std");

const zignal = @import("zignal");
const ConvexHull = zignal.ConvexHull;

const py_utils = @import("py_utils.zig");
pub const registerType = py_utils.registerType;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

pub const ConvexHullObject = extern struct {
    ob_base: c.PyObject,
    hull: ?*ConvexHull(f32),
};

fn convex_hull_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*ConvexHullObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.hull = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn convex_hull_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = args;
    _ = kwds;
    const self = @as(*ConvexHullObject, @ptrCast(self_obj.?));

    const hull = py_utils.allocator.create(ConvexHull(f32)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate ConvexHull");
        return -1;
    };
    hull.* = ConvexHull(f32).init(py_utils.allocator);
    self.hull = hull;

    return 0;
}

fn convex_hull_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*ConvexHullObject, @ptrCast(self_obj.?));

    if (self.hull) |hull| {
        hull.deinit();
        py_utils.allocator.destroy(hull);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn convex_hull_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self_obj;
    return c.PyUnicode_FromString("ConvexHull()");
}

// Instance methods
const convex_hull_find_doc =
    \\Find the convex hull of a set of 2D points.
    \\
    \\Returns the vertices of the convex hull in clockwise order as a list of
    \\(x, y) tuples, or None if the hull is degenerate (e.g., all points are
    \\collinear).
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]]): List of (x, y) coordinate pairs.
    \\  At least 3 points are required.
    \\
    \\## Examples
    \\```python
    \\hull = ConvexHull()
    \\points = [(0, 0), (1, 1), (2, 2), (3, 1), (4, 0), (2, 4), (1, 3)]
    \\result = hull.find(points)
    \\# Returns: [(0.0, 0.0), (1.0, 3.0), (2.0, 4.0), (4.0, 0.0)]
    \\```
;

fn convex_hull_find(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ConvexHullObject, @ptrCast(self_obj.?));

    // Check if hull is initialized
    if (self.hull == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "ConvexHull not initialized");
        return null;
    }

    // Parse points argument
    var points_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &points_obj) == 0) {
        return null;
    }

    // Parse the point list
    const points = py_utils.parsePointList(points_obj) catch {
        // Error already set by parsePointList
        return null;
    };
    defer py_utils.freePointList(points);

    // Find convex hull
    const hull_points = self.hull.?.find(points) catch {
        c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to compute convex hull");
        return null;
    };

    // Check if hull is degenerate
    if (hull_points == null) {
        const none = c.Py_None();
        c.Py_INCREF(none);
        return none;
    }

    // Convert hull points to Python list of tuples
    const result_list = c.PyList_New(@intCast(hull_points.?.len));
    if (result_list == null) {
        return null;
    }

    for (hull_points.?, 0..) |point, i| {
        const tuple = c.PyTuple_New(2);
        if (tuple == null) {
            c.Py_DECREF(result_list);
            return null;
        }

        const x_obj = c.PyFloat_FromDouble(@as(f64, point.x()));
        if (x_obj == null) {
            c.Py_DECREF(tuple);
            c.Py_DECREF(result_list);
            return null;
        }

        const y_obj = c.PyFloat_FromDouble(@as(f64, point.y()));
        if (y_obj == null) {
            c.Py_DECREF(x_obj);
            c.Py_DECREF(tuple);
            c.Py_DECREF(result_list);
            return null;
        }

        // PyTuple_SetItem steals references
        _ = c.PyTuple_SetItem(tuple, 0, x_obj);
        _ = c.PyTuple_SetItem(tuple, 1, y_obj);

        // PyList_SetItem steals reference to tuple
        _ = c.PyList_SetItem(result_list, @intCast(i), tuple);
    }

    return result_list;
}

pub const convex_hull_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "find",
        .meth = @ptrCast(&convex_hull_find),
        .flags = c.METH_VARARGS,
        .doc = convex_hull_find_doc,
        .params = "self, points: list[tuple[float, float]]",
        .returns = "Optional[list[tuple[float, float]]]",
    },
};

var convex_hull_methods = stub_metadata.toPyMethodDefArray(&convex_hull_methods_metadata);

pub var ConvexHullType = c.PyTypeObject{
    .ob_base = .{
        .ob_base = .{},
        .ob_size = 0,
    },
    .tp_name = "zignal.ConvexHull",
    .tp_basicsize = @sizeOf(ConvexHullObject),
    .tp_dealloc = convex_hull_dealloc,
    .tp_repr = convex_hull_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "Convex hull computation using Graham's scan algorithm",
    .tp_methods = @ptrCast(&convex_hull_methods),
    .tp_init = convex_hull_init,
    .tp_new = convex_hull_new,
};

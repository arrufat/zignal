const zignal = @import("zignal");
const ConvexHull = zignal.ConvexHull(f64);
const Point2F = zignal.Point(2, f64);
const rectangle = @import("rectangle.zig");

const python = @import("python.zig");
pub const registerType = python.register;
const c = python.c;
const stub_metadata = @import("stub_metadata.zig");

pub const ConvexHullObject = extern struct {
    ob_base: c.PyObject,
    hull: ?*ConvexHull,
};

// Using genericNew helper for standard object creation
const convex_hull_new = python.genericNew(ConvexHullObject);

fn convex_hull_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = python.safeCast(ConvexHullObject, self_obj);

    // Using createHeapObject helper for allocation with error handling
    self.hull = python.createHeapObject(ConvexHull, .{python.ctx.allocator}) catch return -1;

    // Parse optional points argument
    const Params = struct {
        points: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    const points_obj = params.points orelse return 0;

    // Parse the point list
    const points = python.parse([]zignal.Point(2, f64), points_obj) catch return -1;
    defer python.ctx.allocator.free(points);

    // Find convex hull
    _ = self.hull.?.find(points) catch |err| {
        python.mapZigError(err, "ConvexHull");
        return -1;
    };

    return 0;
}

// Helper function for custom cleanup
fn convexHullDeinit(self: *ConvexHullObject) void {
    python.destroyHeapObject(ConvexHull, self.hull);
}

// Using genericDealloc helper
const convex_hull_dealloc = python.genericDealloc(ConvexHullObject, convexHullDeinit);

fn convex_hull_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self_obj;
    return python.create("ConvexHull()");
}

/// Helper to convert a slice of Point2F to a Python list of tuples.
fn convertHullToPython(points: []const Point2F) ?*c.PyObject {
    return python.listFromSliceCustom(Point2F, points, struct {
        fn toPythonTuple(point: Point2F, _: usize) ?*c.PyObject {
            const tuple = c.PyTuple_New(2);
            if (tuple == null) return null;

            const x_obj = python.create(point.x());
            if (x_obj == null) {
                c.Py_DECREF(tuple);
                return null;
            }

            const y_obj = python.create(point.y());
            if (y_obj == null) {
                c.Py_DECREF(x_obj);
                c.Py_DECREF(tuple);
                return null;
            }

            _ = c.PyTuple_SetItem(tuple, 0, x_obj);
            _ = c.PyTuple_SetItem(tuple, 1, y_obj);
            return tuple;
        }
    }.toPythonTuple);
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

fn convex_hull_find(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {

    // Using validateNonNull helper for null check with error message
    const hull = python.unwrap(ConvexHullObject, "hull", self_obj, "ConvexHull") orelse return null;

    // Parse points argument
    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const points_obj = params.points;

    // Parse the point list
    const points = python.parse([]zignal.Point(2, f64), points_obj) catch {
        // Error already set by parsePointList
        return null;
    };
    defer python.ctx.allocator.free(points);

    // Find convex hull with improved error handling
    const hull_points = hull.find(points) catch |err| {
        python.setRuntimeError("Failed to compute convex hull: {s}", .{@errorName(err)});
        return null;
    };

    // Check if hull is degenerate
    if (hull_points == null) {
        return python.none();
    }

    return convertHullToPython(hull_points.?);
}

// Property getters
fn convex_hull_get_points(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const hull = python.unwrap(ConvexHullObject, "hull", self_obj, "ConvexHull") orelse return null;

    if (!hull.isValid()) {
        return python.none();
    }

    return convertHullToPython(hull.hull.items);
}

const convex_hull_contains_doc =
    \\Check if a point is inside the convex hull.
    \\
    \\## Parameters
    \\- `point` (tuple[float, float]): (x, y) coordinates of the point to check.
    \\
    \\## Returns
    \\- `bool`: True if the point is inside or on the boundary, False otherwise.
    \\- Returns `False` if no valid hull has been computed yet.
;

fn convex_hull_contains(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const hull = python.unwrap(ConvexHullObject, "hull", self_obj, "ConvexHull") orelse return null;

    const Params = struct {
        point: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const p = python.parse(zignal.Point(2, f64), params.point) catch return null;
    const result = hull.contains(p);

    return @ptrCast(python.create(result));
}

const convex_hull_get_rectangle_doc =
    \\Return the tightest axis-aligned rectangle enclosing the last hull.
    \\
    \\The rectangle is expressed in image-style coordinates `(left, top, right, bottom)`
    \\and matches the bounds of the currently cached convex hull. If no hull has
    \\been computed yet or the last call was degenerate (e.g., all points were
    \\collinear), this method returns `None`.
    \\
    \\## Returns
    \\- `Rectangle | None`: Bounding rectangle instance or `None` when unavailable.
;

fn convex_hull_get_rectangle(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const hull = python.unwrap(ConvexHullObject, "hull", self_obj, "ConvexHull") orelse return null;

    if (hull.getRectangle()) |rect| {
        const args_tuple = c.Py_BuildValue(
            "(dddd)",
            rect.l,
            rect.t,
            rect.r,
            rect.b,
        ) orelse return null;
        defer c.Py_DECREF(args_tuple);
        return c.PyObject_CallObject(@ptrCast(&rectangle.RectangleType), args_tuple);
    }

    return python.none();
}

pub const convex_hull_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "find",
        .meth = @ptrCast(&convex_hull_find),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = convex_hull_find_doc,
        .params = "self, points: list[tuple[float, float]]",
        .returns = "list[tuple[float, float]] | None",
    },
    .{
        .name = "get_rectangle",
        .meth = @ptrCast(&convex_hull_get_rectangle),
        .flags = c.METH_NOARGS,
        .doc = convex_hull_get_rectangle_doc,
        .params = "self",
        .returns = "Rectangle | None",
    },
    .{
        .name = "contains",
        .meth = @ptrCast(&convex_hull_contains),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = convex_hull_contains_doc,
        .params = "self, point: tuple[float, float]",
        .returns = "bool",
    },
};

var convex_hull_methods = stub_metadata.toPyMethodDefArray(&convex_hull_methods_metadata);

pub const convex_hull_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "points",
        .get = @ptrCast(&convex_hull_get_points),
        .set = null,
        .doc = "Vertices of the computed convex hull in clockwise order. Returns `None` if the hull is invalid or hasn't been computed. When not `None`, the list is guaranteed to contain at least 3 points.",
        .type = "list[tuple[float, float]] | None",
    },
};

var convex_hull_getset = stub_metadata.toPyGetSetDefArray(&convex_hull_properties_metadata);

// Class documentation - keep it simple
const convex_hull_class_doc = "Convex hull computation using Graham's scan algorithm.";

// Init documentation - detailed explanation
pub const convex_hull_init_doc =
    \\Initialize a new ConvexHull instance.
    \\
    \\Creates a new ConvexHull instance that can compute the convex hull of
    \\2D point sets using Graham's scan algorithm. If points are provided,
    \\the hull is computed immediately.
    \\
    \\## Parameters
    \\- `points` (list[tuple[float, float]], optional): List of (x, y) coordinate pairs.
    \\
    \\## Examples
    \\```python
    \\# Create and compute hull in one step
    \\points = [(0, 0), (1, 1), (2, 2), (3, 1), (4, 0), (2, 4), (1, 3)]
    \\hull = ConvexHull(points)
    \\# The computed vertices are available in .points (None if degenerate)
    \\if hull.points:
    \\    print(hull.points)
    \\
    \\# Or create empty and compute later
    \\hull = ConvexHull()
    \\result = hull.find(points)
    \\```
    \\
    \\## Notes
    \\- Returns vertices in clockwise order via the .points property
    \\- The .points property returns None for degenerate cases (e.g., all points collinear)
    \\- Requires at least 3 points for a valid hull
;

// Special methods metadata for stub generation
pub const convex_hull_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, points: list[tuple[float, float]] = None",
        .returns = "None",
        .doc = convex_hull_init_doc,
    },
};

// Using buildTypeObject helper for cleaner initialization
pub var ConvexHullType = python.buildTypeObject(.{
    .name = "zignal.ConvexHull",
    .basicsize = @sizeOf(ConvexHullObject),
    .doc = convex_hull_class_doc,
    .methods = @ptrCast(&convex_hull_methods),
    .getset = @ptrCast(&convex_hull_getset),
    .new = convex_hull_new,
    .init = convex_hull_init,
    .dealloc = convex_hull_dealloc,
    .repr = convex_hull_repr,
});

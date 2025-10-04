const std = @import("std");

const zignal = @import("zignal");
const SimilarityTransform = zignal.SimilarityTransform;
const AffineTransform = zignal.AffineTransform;
const ProjectiveTransform = zignal.ProjectiveTransform;

const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const allocator = py_utils.allocator;
const stub_metadata = @import("stub_metadata.zig");

// ============================================================================
// SIMILARITY TRANSFORM
// ============================================================================

pub const SimilarityTransformObject = extern struct {
    ob_base: c.PyObject,
    // Store 2x2 matrix as array
    matrix: [2][2]f64,
    // Store translation vector as array
    bias: [2]f64,
};

fn similarity_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*SimilarityTransformObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize as identity transform
        obj.matrix = .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } };
        obj.bias = .{ 0.0, 0.0 };
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn similarity_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = py_utils.safeCast(SimilarityTransformObject, self_obj);

    const Params = struct {
        from_points: ?*c.PyObject,
        to_points: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return -1;

    const from_points_obj = params.from_points;
    const to_points_obj = params.to_points;

    // Parse point lists
    const from_points = py_utils.parsePointList(f64, from_points_obj) catch {
        return -1;
    };
    defer allocator.free(from_points);

    const to_points = py_utils.parsePointList(f64, to_points_obj) catch {
        return -1;
    };
    defer allocator.free(to_points);

    // Check we have same number of points
    if (from_points.len != to_points.len) {
        py_utils.setValueError("from_points and to_points must have the same length", .{});
        return -1;
    }

    // Check we have at least 2 points
    if (from_points.len < 2) {
        py_utils.setValueError("Need at least 2 point correspondences for similarity transform", .{});
        return -1;
    }

    // Create and fit the transform
    const transform = SimilarityTransform(f64).init(from_points, to_points);

    // Store matrix components
    self.matrix[0][0] = transform.matrix.at(0, 0).*;
    self.matrix[0][1] = transform.matrix.at(0, 1).*;
    self.matrix[1][0] = transform.matrix.at(1, 0).*;
    self.matrix[1][1] = transform.matrix.at(1, 1).*;
    self.bias[0] = transform.bias.at(0, 0).*;
    self.bias[1] = transform.bias.at(1, 0).*;

    return 0;
}

fn similarity_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn similarity_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(SimilarityTransformObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const point_obj = params.points;

    // Check if it's a single tuple (x, y)
    if (c.PyTuple_Check(point_obj) != 0 and c.PyTuple_Size(point_obj) == 2) {
        // Single point - return single tuple
        const point = py_utils.parsePointTuple(f64, point_obj) catch return null;

        // Apply transform: new = matrix * point + bias
        const new_x = self.matrix[0][0] * point.x() + self.matrix[0][1] * point.y() + self.bias[0];
        const new_y = self.matrix[1][0] * point.x() + self.matrix[1][1] * point.y() + self.bias[1];

        return c.PyTuple_Pack(2, c.PyFloat_FromDouble(new_x), c.PyFloat_FromDouble(new_y));
    } else if (c.PySequence_Check(point_obj) != 0) {
        // List/sequence of points - return list of tuples
        const points = py_utils.parsePointList(f64, point_obj) catch return null;
        defer allocator.free(points);

        const result_list = c.PyList_New(@intCast(points.len)) orelse return null;

        for (points, 0..) |point, i| {
            const new_x = self.matrix[0][0] * point.x() + self.matrix[0][1] * point.y() + self.bias[0];
            const new_y = self.matrix[1][0] * point.x() + self.matrix[1][1] * point.y() + self.bias[1];

            const tuple = c.PyTuple_Pack(2, c.PyFloat_FromDouble(new_x), c.PyFloat_FromDouble(new_y)) orelse {
                c.Py_DECREF(result_list);
                return null;
            };

            // TODO: Use PyList_SET_ITEM once we drop Python 3.10 support
            // PyList_SET_ITEM is a macro that doesn't translate properly in Python 3.10
            _ = c.PyList_SetItem(result_list, @intCast(i), tuple);
        }

        return result_list;
    } else {
        py_utils.setTypeError("(x, y) tuple or list of tuples", point_obj);
        return null;
    }
}

fn similarity_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(SimilarityTransformObject, self_obj);

    var buffer: [512]u8 = undefined;
    const str = std.fmt.bufPrintZ(&buffer, "SimilarityTransform(matrix=[[{d:.6}, {d:.6}], [{d:.6}, {d:.6}]], bias=({d:.6}, {d:.6}))", .{ self.matrix[0][0], self.matrix[0][1], self.matrix[1][0], self.matrix[1][1], self.bias[0], self.bias[1] }) catch return null;

    return c.PyUnicode_FromString(str.ptr);
}

// Property getters for matrix and bias
// matrix getter generated via generic helper

// bias getter generated via generic helper

var similarity_methods = [_]c.PyMethodDef{
    .{ .ml_name = "project", .ml_meth = @ptrCast(&similarity_project), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = "Transform point(s). Accepts (x,y) tuple or list of tuples." },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var similarity_getset = [_]c.PyGetSetDef{
    .{ .name = "matrix", .get = @ptrCast(@alignCast(py_utils.getterMatrixNested(SimilarityTransformObject, "matrix", 2, 2))), .set = null, .doc = "2x2 transformation matrix", .closure = null },
    .{ .name = "bias", .get = @ptrCast(@alignCast(py_utils.getterTuple2FromArrayField(SimilarityTransformObject, "bias", 0, 1))), .set = null, .doc = "Translation vector (x, y)", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var SimilarityTransformType = py_utils.buildTypeObject(.{
    .name = "zignal.SimilarityTransform",
    .basicsize = @sizeOf(SimilarityTransformObject),
    .doc = "Similarity transform (rotation + uniform scale + translation)",
    .methods = @ptrCast(&similarity_methods),
    .getset = @ptrCast(&similarity_getset),
    .new = similarity_new,
    .init = similarity_init,
    .dealloc = similarity_dealloc,
    .repr = similarity_repr,
});

// ============================================================================
// AFFINE TRANSFORM
// ============================================================================

pub const AffineTransformObject = extern struct {
    ob_base: c.PyObject,
    // Store 2x2 matrix as array
    matrix: [2][2]f64,
    // Store translation vector as array
    bias: [2]f64,
};

fn affine_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*AffineTransformObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize as identity transform
        obj.matrix = .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } };
        obj.bias = .{ 0.0, 0.0 };
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn affine_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = py_utils.safeCast(AffineTransformObject, self_obj);

    const Params = struct {
        from_points: ?*c.PyObject,
        to_points: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return -1;

    const from_points_obj = params.from_points;
    const to_points_obj = params.to_points;

    // Parse point lists
    const from_points = py_utils.parsePointList(f64, from_points_obj) catch {
        return -1;
    };
    defer allocator.free(from_points);

    const to_points = py_utils.parsePointList(f64, to_points_obj) catch {
        return -1;
    };
    defer allocator.free(to_points);

    // Check we have same number of points
    if (from_points.len != to_points.len) {
        py_utils.setValueError("from_points and to_points must have the same length", .{});
        return -1;
    }

    // Check we have at least 3 points
    if (from_points.len < 3) {
        py_utils.setValueError("Need at least 3 point correspondences for affine transform", .{});
        return -1;
    }

    // Create and fit the transform
    const transform = AffineTransform(f64).init(allocator, from_points, to_points) catch |err| {
        switch (err) {
            error.OutOfMemory => py_utils.setMemoryError("affine transform"),
            error.DimensionMismatch => py_utils.setValueError(
                "Point arrays must be 2D coordinates",
                .{},
            ),
            error.Singular, error.NotConverged => py_utils.setValueError(
                "Point correspondences are rank deficient; cannot fit affine transform",
                .{},
            ),
            else => py_utils.setRuntimeError("Failed to compute affine transform: {s}", .{@errorName(err)}),
        }
        return -1;
    };

    // Store matrix components
    self.matrix[0][0] = transform.matrix.at(0, 0).*;
    self.matrix[0][1] = transform.matrix.at(0, 1).*;
    self.matrix[1][0] = transform.matrix.at(1, 0).*;
    self.matrix[1][1] = transform.matrix.at(1, 1).*;
    self.bias[0] = transform.bias.at(0, 0).*;
    self.bias[1] = transform.bias.at(1, 0).*;

    return 0;
}

fn affine_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn affine_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(AffineTransformObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const point_obj = params.points;

    // Check if it's a single tuple (x, y)
    if (c.PyTuple_Check(point_obj) != 0 and c.PyTuple_Size(point_obj) == 2) {
        // Single point - return single tuple
        const point = py_utils.parsePointTuple(f64, point_obj) catch return null;

        // Apply transform: new = matrix * point + bias
        const new_x = self.matrix[0][0] * point.x() + self.matrix[0][1] * point.y() + self.bias[0];
        const new_y = self.matrix[1][0] * point.x() + self.matrix[1][1] * point.y() + self.bias[1];

        return c.PyTuple_Pack(2, c.PyFloat_FromDouble(new_x), c.PyFloat_FromDouble(new_y));
    } else if (c.PySequence_Check(point_obj) != 0) {
        // List/sequence of points - return list of tuples
        const points = py_utils.parsePointList(f64, point_obj) catch return null;
        defer allocator.free(points);

        const result_list = c.PyList_New(@intCast(points.len)) orelse return null;

        for (points, 0..) |point, i| {
            const new_x = self.matrix[0][0] * point.x() + self.matrix[0][1] * point.y() + self.bias[0];
            const new_y = self.matrix[1][0] * point.x() + self.matrix[1][1] * point.y() + self.bias[1];

            const tuple = c.PyTuple_Pack(2, c.PyFloat_FromDouble(new_x), c.PyFloat_FromDouble(new_y)) orelse {
                c.Py_DECREF(result_list);
                return null;
            };

            // TODO: Use PyList_SET_ITEM once we drop Python 3.10 support
            // PyList_SET_ITEM is a macro that doesn't translate properly in Python 3.10
            _ = c.PyList_SetItem(result_list, @intCast(i), tuple);
        }

        return result_list;
    } else {
        py_utils.setTypeError("(x, y) tuple or list of tuples", point_obj);
        return null;
    }
}

fn affine_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(AffineTransformObject, self_obj);

    var buffer: [512]u8 = undefined;
    const str = std.fmt.bufPrintZ(&buffer, "AffineTransform(matrix=[[{d:.6}, {d:.6}], [{d:.6}, {d:.6}]], bias=({d:.6}, {d:.6}))", .{ self.matrix[0][0], self.matrix[0][1], self.matrix[1][0], self.matrix[1][1], self.bias[0], self.bias[1] }) catch return null;

    return c.PyUnicode_FromString(str.ptr);
}

// Property getters for matrix and bias
// matrix getter generated via generic helper

// bias getter generated via generic helper

var affine_methods = [_]c.PyMethodDef{
    .{ .ml_name = "project", .ml_meth = @ptrCast(&affine_project), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = "Transform point(s). Accepts (x,y) tuple or list of tuples." },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var affine_getset = [_]c.PyGetSetDef{
    .{ .name = "matrix", .get = @ptrCast(@alignCast(py_utils.getterMatrixNested(AffineTransformObject, "matrix", 2, 2))), .set = null, .doc = "2x2 transformation matrix", .closure = null },
    .{ .name = "bias", .get = @ptrCast(@alignCast(py_utils.getterTuple2FromArrayField(AffineTransformObject, "bias", 0, 1))), .set = null, .doc = "Translation vector (x, y)", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var AffineTransformType = py_utils.buildTypeObject(.{
    .name = "zignal.AffineTransform",
    .basicsize = @sizeOf(AffineTransformObject),
    .doc = "Affine transform (general 2D linear transform)",
    .methods = @ptrCast(&affine_methods),
    .getset = @ptrCast(&affine_getset),
    .new = affine_new,
    .init = affine_init,
    .dealloc = affine_dealloc,
    .repr = affine_repr,
});

// ============================================================================
// PROJECTIVE TRANSFORM
// ============================================================================

pub const ProjectiveTransformObject = extern struct {
    ob_base: c.PyObject,
    // Store 3x3 homogeneous matrix as array
    matrix: [3][3]f64,
};

fn projective_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*ProjectiveTransformObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        // Initialize as identity transform
        obj.matrix = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        };
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn projective_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = py_utils.safeCast(ProjectiveTransformObject, self_obj);

    const Params = struct {
        from_points: ?*c.PyObject,
        to_points: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return -1;

    const from_points_obj = params.from_points;
    const to_points_obj = params.to_points;

    // Parse point lists
    const from_points = py_utils.parsePointList(f64, from_points_obj) catch {
        return -1;
    };
    defer allocator.free(from_points);

    const to_points = py_utils.parsePointList(f64, to_points_obj) catch {
        return -1;
    };
    defer allocator.free(to_points);

    // Check we have same number of points
    if (from_points.len != to_points.len) {
        py_utils.setValueError("from_points and to_points must have the same length", .{});
        return -1;
    }

    // Check we have at least 4 points
    if (from_points.len < 4) {
        py_utils.setValueError("Need at least 4 point correspondences for projective transform", .{});
        return -1;
    }

    // Create and fit the transform
    const transform = ProjectiveTransform(f64).init(from_points, to_points);

    // Store matrix components
    for (0..3) |i| {
        for (0..3) |j| {
            self.matrix[i][j] = transform.matrix.at(i, j).*;
        }
    }

    return 0;
}

fn projective_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn projective_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ProjectiveTransformObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const point_obj = params.points;

    // Check if it's a single tuple (x, y)
    if (c.PyTuple_Check(point_obj) != 0 and c.PyTuple_Size(point_obj) == 2) {
        // Single point - return single tuple
        const point = py_utils.parsePointTuple(f64, point_obj) catch return null;

        // Apply projective transform: [x', y', w'] = matrix * [x, y, 1]
        const x = point.x();
        const y = point.y();
        const new_x = self.matrix[0][0] * x + self.matrix[0][1] * y + self.matrix[0][2];
        const new_y = self.matrix[1][0] * x + self.matrix[1][1] * y + self.matrix[1][2];
        const w = self.matrix[2][0] * x + self.matrix[2][1] * y + self.matrix[2][2];

        // Normalize by w
        const result_x = if (w != 0) new_x / w else new_x;
        const result_y = if (w != 0) new_y / w else new_y;

        return c.PyTuple_Pack(2, c.PyFloat_FromDouble(result_x), c.PyFloat_FromDouble(result_y));
    } else if (c.PySequence_Check(point_obj) != 0) {
        // List/sequence of points - return list of tuples
        const points = py_utils.parsePointList(f64, point_obj) catch return null;
        defer allocator.free(points);

        const result_list = c.PyList_New(@intCast(points.len)) orelse return null;

        for (points, 0..) |point, i| {
            const x = point.x();
            const y = point.y();
            const new_x = self.matrix[0][0] * x + self.matrix[0][1] * y + self.matrix[0][2];
            const new_y = self.matrix[1][0] * x + self.matrix[1][1] * y + self.matrix[1][2];
            const w = self.matrix[2][0] * x + self.matrix[2][1] * y + self.matrix[2][2];

            // Normalize by w
            const result_x = if (w != 0) new_x / w else new_x;
            const result_y = if (w != 0) new_y / w else new_y;

            const tuple = c.PyTuple_Pack(2, c.PyFloat_FromDouble(result_x), c.PyFloat_FromDouble(result_y)) orelse {
                c.Py_DECREF(result_list);
                return null;
            };

            // TODO: Use PyList_SET_ITEM once we drop Python 3.10 support
            // PyList_SET_ITEM is a macro that doesn't translate properly in Python 3.10
            _ = c.PyList_SetItem(result_list, @intCast(i), tuple);
        }

        return result_list;
    } else {
        py_utils.setTypeError("(x, y) tuple or list of tuples", point_obj);
        return null;
    }
}

fn projective_inverse(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = py_utils.safeCast(ProjectiveTransformObject, self_obj);

    // Reconstruct the matrix from components
    const matrix = zignal.SMatrix(f64, 3, 3).init(.{
        .{ self.matrix[0][0], self.matrix[0][1], self.matrix[0][2] },
        .{ self.matrix[1][0], self.matrix[1][1], self.matrix[1][2] },
        .{ self.matrix[2][0], self.matrix[2][1], self.matrix[2][2] },
    });

    // Compute inverse
    const transform = ProjectiveTransform(f64){ .matrix = matrix };
    const inverse_transform = transform.inverse() orelse {
        const none = c.Py_None();
        c.Py_INCREF(none);
        return none;
    };

    // Create new ProjectiveTransform object
    const py_obj = c.PyType_GenericAlloc(@ptrCast(&ProjectiveTransformType), 0) orelse return null;
    const result = py_utils.safeCast(ProjectiveTransformObject, py_obj);

    // Copy inverse matrix components
    for (0..3) |i| {
        for (0..3) |j| {
            result.matrix[i][j] = inverse_transform.matrix.at(i, j).*;
        }
    }

    return py_obj;
}

fn projective_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ProjectiveTransformObject, self_obj);

    var buffer: [1024]u8 = undefined;
    const str = std.fmt.bufPrintZ(&buffer, "ProjectiveTransform(matrix=[[{d:.6}, {d:.6}, {d:.6}], [{d:.6}, {d:.6}, {d:.6}], [{d:.6}, {d:.6}, {d:.6}]])", .{ self.matrix[0][0], self.matrix[0][1], self.matrix[0][2], self.matrix[1][0], self.matrix[1][1], self.matrix[1][2], self.matrix[2][0], self.matrix[2][1], self.matrix[2][2] }) catch return null;

    return c.PyUnicode_FromString(str.ptr);
}

// Property getter for matrix
// matrix getter generated via generic helper

var projective_methods = [_]c.PyMethodDef{
    .{ .ml_name = "project", .ml_meth = @ptrCast(&projective_project), .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS, .ml_doc = "Transform point(s). Accepts (x,y) tuple or list of tuples." },
    .{ .ml_name = "inverse", .ml_meth = @ptrCast(&projective_inverse), .ml_flags = c.METH_NOARGS, .ml_doc = "Get inverse transform, or None if not invertible." },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var projective_getset = [_]c.PyGetSetDef{
    .{ .name = "matrix", .get = @ptrCast(@alignCast(py_utils.getterMatrixNested(ProjectiveTransformObject, "matrix", 3, 3))), .set = null, .doc = "3x3 homogeneous transformation matrix", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var ProjectiveTransformType = py_utils.buildTypeObject(.{
    .name = "zignal.ProjectiveTransform",
    .basicsize = @sizeOf(ProjectiveTransformObject),
    .doc = "Projective transform (homography/perspective transform)",
    .methods = @ptrCast(&projective_methods),
    .getset = @ptrCast(&projective_getset),
    .new = projective_new,
    .init = projective_init,
    .dealloc = projective_dealloc,
    .repr = projective_repr,
});

// ============================================================================
// STUB GENERATION METADATA
// ============================================================================

pub const similarity_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, from_points: list[tuple[float, float]], to_points: list[tuple[float, float]]",
        .returns = "None",
        .doc = "Create similarity transform from point correspondences.",
    },
    .{
        .name = "project",
        .params = "self, points: tuple[float, float] | list[tuple[float, float]]",
        .returns = "tuple[float, float] | list[tuple[float, float]]",
        .doc = "Transform point(s). Returns same type as input.",
    },
};

pub const similarity_properties_metadata = [_]stub_metadata.PropertyInfo{
    .{
        .name = "matrix",
        .type = "list[list[float]]",
        .doc = "2x2 transformation matrix",
    },
    .{
        .name = "bias",
        .type = "tuple[float, float]",
        .doc = "Translation vector (x, y)",
    },
};

pub const affine_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, from_points: list[tuple[float, float]], to_points: list[tuple[float, float]]",
        .returns = "None",
        .doc = "Create affine transform from point correspondences.",
    },
    .{
        .name = "project",
        .params = "self, points: tuple[float, float] | list[tuple[float, float]]",
        .returns = "tuple[float, float] | list[tuple[float, float]]",
        .doc = "Transform point(s). Returns same type as input.",
    },
};

pub const affine_properties_metadata = [_]stub_metadata.PropertyInfo{
    .{
        .name = "matrix",
        .type = "list[list[float]]",
        .doc = "2x2 transformation matrix",
    },
    .{
        .name = "bias",
        .type = "tuple[float, float]",
        .doc = "Translation vector (x, y)",
    },
};

pub const projective_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, from_points: list[tuple[float, float]], to_points: list[tuple[float, float]]",
        .returns = "None",
        .doc = "Create projective transform from point correspondences.",
    },
    .{
        .name = "project",
        .params = "self, points: tuple[float, float] | list[tuple[float, float]]",
        .returns = "tuple[float, float] | list[tuple[float, float]]",
        .doc = "Transform point(s). Returns same type as input.",
    },
    .{
        .name = "inverse",
        .params = "self",
        .returns = "ProjectiveTransform | None",
        .doc = "Get inverse transform, or None if not invertible.",
    },
};

pub const projective_properties_metadata = [_]stub_metadata.PropertyInfo{
    .{
        .name = "matrix",
        .type = "list[list[float]]",
        .doc = "3x3 homogeneous transformation matrix",
    },
};

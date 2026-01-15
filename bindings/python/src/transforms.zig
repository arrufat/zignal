const std = @import("std");

const zignal = @import("zignal");
const SimilarityTransform = zignal.SimilarityTransform;
const AffineTransform = zignal.AffineTransform;
const ProjectiveTransform = zignal.ProjectiveTransform;

const python = @import("python.zig");
const c = python.c;
const allocator = python.ctx.allocator;
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

    const self: ?*SimilarityTransformObject = @ptrCast(c.PyType_GenericAlloc(type_obj, 0));
    if (self) |obj| {
        // Initialize as identity transform
        obj.matrix = .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } };
        obj.bias = .{ 0.0, 0.0 };
    }
    return @ptrCast(self);
}

fn similarity_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = python.safeCast(SimilarityTransformObject, self_obj);

    const Params = struct {
        from_points: ?*c.PyObject,
        to_points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    var pairs = python.parsePointPairs(
        f64,
        params.from_points,
        params.to_points,
        2,
        "Need at least 2 point correspondences for similarity transform",
    ) catch return -1;
    defer pairs.deinit();

    // Create and fit the transform
    const transform = SimilarityTransform(f64).init(pairs.from_points, pairs.to_points) catch |err| {
        switch (err) {
            error.NotConverged => python.setValueError(
                "SVD failed to converge; cannot fit similarity transform",
                .{},
            ),
            error.RankDeficient => python.setValueError(
                "Point correspondences are rank deficient; cannot fit similarity transform",
                .{},
            ),
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

fn similarity_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    python.typeOf(self_obj).*.tp_free.?(self_obj);
}

fn similarity_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(SimilarityTransformObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return python.projectPoints2D(params.points, self, applyLinear2D);
}

inline fn applyLinear2D(self: anytype, x: f64, y: f64) [2]f64 {
    return .{
        self.matrix[0][0] * x + self.matrix[0][1] * y + self.bias[0],
        self.matrix[1][0] * x + self.matrix[1][1] * y + self.bias[1],
    };
}

fn similarity_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(SimilarityTransformObject, self_obj);

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
    .{ .name = "matrix", .get = @ptrCast(@alignCast(python.getterMatrixNested(SimilarityTransformObject, "matrix", 2, 2))), .set = null, .doc = "2x2 transformation matrix", .closure = null },
    .{ .name = "bias", .get = @ptrCast(@alignCast(python.getterTuple2FromArrayField(SimilarityTransformObject, "bias", 0, 1))), .set = null, .doc = "Translation vector (x, y)", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var SimilarityTransformType = python.buildTypeObject(.{
    .name = "zignal.SimilarityTransform",
    .basicsize = @sizeOf(SimilarityTransformObject),
    .doc =
    \\Similarity transform (rotation + uniform scale + translation).
    \\Raises ValueError when the point correspondences are rank deficient or the fit fails to converge.
    ,
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

    const self: ?*AffineTransformObject = @ptrCast(c.PyType_GenericAlloc(type_obj, 0));
    if (self) |obj| {
        // Initialize as identity transform
        obj.matrix = .{ .{ 1.0, 0.0 }, .{ 0.0, 1.0 } };
        obj.bias = .{ 0.0, 0.0 };
    }
    return @ptrCast(self);
}

fn affine_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = python.safeCast(AffineTransformObject, self_obj);

    const Params = struct {
        from_points: ?*c.PyObject,
        to_points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    var pairs = python.parsePointPairs(
        f64,
        params.from_points,
        params.to_points,
        3,
        "Need at least 3 point correspondences for affine transform",
    ) catch return -1;
    defer pairs.deinit();

    // Create and fit the transform
    const transform = AffineTransform(f64).init(allocator, pairs.from_points, pairs.to_points) catch |err| {
        switch (err) {
            error.OutOfMemory => python.setMemoryError("affine transform"),
            error.DimensionMismatch => python.setValueError("Point arrays must be 2D coordinates", .{}),
            error.NotConverged => python.setValueError(
                "SVD failed to converge; cannot fit affine transform",
                .{},
            ),
            error.Singular, error.RankDeficient => python.setValueError(
                "Point correspondences are rank deficient; cannot fit affine transform",
                .{},
            ),
            else => python.setRuntimeError("Failed to compute affine transform: {s}", .{@errorName(err)}),
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
    python.typeOf(self_obj).*.tp_free.?(self_obj);
}

fn affine_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(AffineTransformObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return python.projectPoints2D(params.points, self, applyLinear2D);
}

fn affine_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(AffineTransformObject, self_obj);

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
    .{ .name = "matrix", .get = @ptrCast(@alignCast(python.getterMatrixNested(AffineTransformObject, "matrix", 2, 2))), .set = null, .doc = "2x2 transformation matrix", .closure = null },
    .{ .name = "bias", .get = @ptrCast(@alignCast(python.getterTuple2FromArrayField(AffineTransformObject, "bias", 0, 1))), .set = null, .doc = "Translation vector (x, y)", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var AffineTransformType = python.buildTypeObject(.{
    .name = "zignal.AffineTransform",
    .basicsize = @sizeOf(AffineTransformObject),
    .doc =
    \\Affine transform (general 2D linear transform).
    \\Raises ValueError when correspondences are rank deficient or the fit fails to converge.
    ,
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

    const self: ?*ProjectiveTransformObject = @ptrCast(c.PyType_GenericAlloc(type_obj, 0));
    if (self) |obj| {
        // Initialize as identity transform
        obj.matrix = .{
            .{ 1.0, 0.0, 0.0 },
            .{ 0.0, 1.0, 0.0 },
            .{ 0.0, 0.0, 1.0 },
        };
    }
    return @ptrCast(self);
}

fn projective_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = python.safeCast(ProjectiveTransformObject, self_obj);

    const Params = struct {
        from_points: ?*c.PyObject,
        to_points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    var pairs = python.parsePointPairs(
        f64,
        params.from_points,
        params.to_points,
        4,
        "Need at least 4 point correspondences for projective transform",
    ) catch return -1;
    defer pairs.deinit();

    // Create and fit the transform
    const transform = ProjectiveTransform(f64).init(pairs.from_points, pairs.to_points) catch |err| {
        switch (err) {
            error.NotConverged => python.setValueError(
                "SVD failed to converge; cannot fit projective transform",
                .{},
            ),
            error.RankDeficient => python.setValueError(
                "Point correspondences are rank deficient; cannot fit projective transform",
                .{},
            ),
        }
        return -1;
    };

    // Store matrix components
    for (0..3) |i| {
        for (0..3) |j| {
            self.matrix[i][j] = transform.matrix.at(i, j).*;
        }
    }

    return 0;
}

fn projective_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    python.typeOf(self_obj).*.tp_free.?(self_obj);
}

fn projective_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ProjectiveTransformObject, self_obj);

    const Params = struct {
        points: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    return python.projectPoints2D(params.points, self, applyProjective);
}

fn applyProjective(self: *ProjectiveTransformObject, x: f64, y: f64) [2]f64 {
    const new_x = self.matrix[0][0] * x + self.matrix[0][1] * y + self.matrix[0][2];
    const new_y = self.matrix[1][0] * x + self.matrix[1][1] * y + self.matrix[1][2];
    const w = self.matrix[2][0] * x + self.matrix[2][1] * y + self.matrix[2][2];

    if (w == 0) {
        const inf = std.math.inf(f64);
        return .{
            std.math.copysign(inf, new_x),
            std.math.copysign(inf, new_y),
        };
    }
    return .{ new_x / w, new_y / w };
}

fn projective_inverse(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = python.safeCast(ProjectiveTransformObject, self_obj);

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
    const result = python.safeCast(ProjectiveTransformObject, py_obj);

    // Copy inverse matrix components
    for (0..3) |i| {
        for (0..3) |j| {
            result.matrix[i][j] = inverse_transform.matrix.at(i, j).*;
        }
    }

    return py_obj;
}

fn projective_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(ProjectiveTransformObject, self_obj);

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
    .{ .name = "matrix", .get = @ptrCast(@alignCast(python.getterMatrixNested(ProjectiveTransformObject, "matrix", 3, 3))), .set = null, .doc = "3x3 homogeneous transformation matrix", .closure = null },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var ProjectiveTransformType = python.buildTypeObject(.{
    .name = "zignal.ProjectiveTransform",
    .basicsize = @sizeOf(ProjectiveTransformObject),
    .doc =
    \\Projective transform (homography/perspective transform).
    \\Raises ValueError when correspondences are rank deficient or the fit fails to converge.
    ,
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

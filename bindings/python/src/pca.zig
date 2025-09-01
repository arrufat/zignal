const std = @import("std");

const zignal = @import("zignal");
const Pca = zignal.Pca;
const Matrix = zignal.Matrix;

const matrix = @import("matrix.zig");
const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const pca_class_doc =
    \\Principal Component Analysis (PCA) for dimensionality reduction.
    \\
    \\PCA is a statistical technique that transforms data to a new coordinate system
    \\where the greatest variance lies on the first coordinate (first principal component),
    \\the second greatest variance on the second coordinate, and so on.
    \\
    \\## Examples
    \\```python
    \\import zignal
    \\import numpy as np
    \\
    \\# Create PCA instance
    \\pca = zignal.PCA()
    \\
    \\# Prepare data using Matrix
    \\data = np.array([[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]])
    \\matrix = zignal.Matrix.from_numpy(data)
    \\
    \\# Fit PCA, keeping 2 components
    \\pca.fit(matrix, num_components=2)
    \\
    \\# Project a single vector
    \\coeffs = pca.project([2, 3, 4])
    \\
    \\# Transform batch of data
    \\transformed = pca.transform(matrix)
    \\
    \\# Reconstruct from coefficients
    \\reconstructed = pca.reconstruct(coeffs)
    \\```
;

// PCA Python object
pub const PCAObject = extern struct {
    ob_base: c.PyObject,
    pca_ptr: ?*Pca(f64),
};

fn pca_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*PCAObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.pca_ptr = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

const pca_init_doc =
    \\Initialize a new PCA instance.
    \\
    \\The dimensionality of the data is inferred when fit() is called.
    \\
    \\## Examples
    \\```python
    \\pca = PCA()
    \\```
;

fn pca_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = args;
    _ = kwds;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    // Create and store the PCA struct
    const pca_ptr = allocator.create(Pca(f64)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate PCA");
        return -1;
    };

    // Initialize the PCA instance
    pca_ptr.* = Pca(f64).init(allocator) catch {
        allocator.destroy(pca_ptr);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to initialize PCA");
        return -1;
    };
    self.pca_ptr = pca_ptr;

    return 0;
}

fn pca_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr) |pca| {
        pca.deinit();
        allocator.destroy(pca);
    }

    const tp = @as(*c.PyTypeObject, @ptrCast(c.Py_TYPE(self_obj)));
    tp.*.tp_free.?(self_obj);
}

const pca_fit_doc =
    \\Fit the PCA model on training data.
    \\
    \\## Parameters
    \\- `data` (Matrix): Training samples matrix (n_samples × n_features)
    \\- `num_components` (int, optional): Number of components to keep. If None, keeps min(n_samples-1, n_features)
    \\
    \\## Raises
    \\- ValueError: If data has insufficient samples (< 2)
    \\- ValueError: If num_components is 0
    \\
    \\## Examples
    \\```python
    \\matrix = zignal.Matrix([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
    \\pca.fit(matrix)  # Keep all possible components
    \\pca.fit(matrix, num_components=2)  # Keep only 2 components
    \\```
;

fn pca_fit(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    // Parse arguments
    var matrix_obj: ?*c.PyObject = null;
    var num_components: c.Py_ssize_t = -1; // -1 means not provided

    const kwlist = [_]?[*:0]const u8{ "data", "num_components", null };
    // TODO: remove @constCast when we don't use Python < 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, "O|n:fit", @ptrCast(@constCast(&kwlist)), &matrix_obj, &num_components) == 0) {
        return null;
    }

    // Check if matrix_obj is a Matrix
    if (c.Py_TYPE(matrix_obj) != @as(*c.PyTypeObject, @ptrCast(&matrix.MatrixType))) {
        c.PyErr_SetString(c.PyExc_TypeError, "data must be a Matrix object");
        return null;
    }

    const matrix_struct = @as(*matrix.MatrixObject, @ptrCast(matrix_obj.?));
    if (matrix_struct.matrix_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix is not initialized");
        return null;
    }

    // Convert num_components to optional usize
    const components: ?usize = if (num_components < 0) null else @intCast(num_components);

    // Fit the PCA model
    self.pca_ptr.?.fit(matrix_struct.matrix_ptr.?.*, components) catch |err| {
        switch (err) {
            error.NoVectors => {
                c.PyErr_SetString(c.PyExc_ValueError, "No data provided");
                return null;
            },
            error.InsufficientData => {
                c.PyErr_SetString(c.PyExc_ValueError, "Need at least 2 samples for PCA");
                return null;
            },
            error.InvalidComponents => {
                c.PyErr_SetString(c.PyExc_ValueError, "Number of components must be > 0");
                return null;
            },
            else => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to fit PCA model");
                return null;
            },
        }
    };

    c.Py_INCREF(c.Py_None());
    return c.Py_None();
}

const pca_project_doc =
    \\Project a single vector onto the PCA space.
    \\
    \\## Parameters
    \\- `vector` (list[float]): Input vector to project
    \\
    \\## Returns
    \\list[float]: Coefficients in PCA space
    \\
    \\## Raises
    \\- RuntimeError: If PCA has not been fitted
    \\- ValueError: If vector dimension doesn't match fitted data
    \\
    \\## Examples
    \\```python
    \\coeffs = pca.project([1.0, 2.0, 3.0])
    \\```
;

fn pca_project(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = kwds;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    // Parse single argument: list of floats
    var list_obj: ?*c.PyObject = null;
    if (c.PyArg_ParseTuple(args, "O:project", &list_obj) == 0) {
        return null;
    }

    // Check if it's a list
    if (c.PyList_Check(list_obj) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "project() takes a list of floats as argument");
        return null;
    }

    const pca = self.pca_ptr.?;
    const list_size = c.PyList_Size(list_obj);

    // Allocate temporary buffer for input vector
    const vector = allocator.alloc(f64, @intCast(list_size)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate vector");
        return null;
    };
    defer allocator.free(vector);

    // Convert Python list to f64 array
    for (0..@intCast(list_size)) |i| {
        const item = c.PyList_GetItem(list_obj, @intCast(i));
        const value = c.PyFloat_AsDouble(item);
        if (c.PyErr_Occurred() != null) {
            return null;
        }
        vector[i] = value;
    }

    // Project the vector
    const coeffs = pca.project(vector) catch |err| {
        switch (err) {
            error.NotFitted => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
                return null;
            },
            error.DimensionMismatch => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "Vector dimension ({}) doesn't match fitted data dimension ({})", .{ list_size, pca.dim }) catch "Dimension mismatch";
                c.PyErr_SetString(c.PyExc_ValueError, msg);
                return null;
            },
            else => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to project vector");
                return null;
            },
        }
    };
    defer allocator.free(coeffs);

    // Convert coefficients to Python list
    const result = c.PyList_New(@intCast(coeffs.len));
    if (result == null) {
        return null;
    }

    for (coeffs, 0..) |coeff, i| {
        const py_float = c.PyFloat_FromDouble(coeff);
        if (py_float == null) {
            c.Py_DECREF(result);
            return null;
        }
        _ = c.PyList_SetItem(result, @intCast(i), py_float);
    }

    return result;
}

const pca_transform_doc =
    \\Transform data matrix to PCA space.
    \\
    \\## Parameters
    \\- `data` (Matrix): Data matrix (n_samples × n_features)
    \\
    \\## Returns
    \\Matrix: Transformed data (n_samples × n_components)
    \\
    \\## Raises
    \\- RuntimeError: If PCA has not been fitted
    \\- ValueError: If data dimensions don't match fitted data
    \\
    \\## Examples
    \\```python
    \\transformed = pca.transform(matrix)
    \\```
;

fn pca_transform(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = kwds;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    // Parse single argument: Matrix
    var matrix_obj: ?*c.PyObject = null;
    if (c.PyArg_ParseTuple(args, "O:transform", &matrix_obj) == 0) {
        return null;
    }

    // Check if matrix_obj is a Matrix
    if (c.Py_TYPE(matrix_obj) != @as(*c.PyTypeObject, @ptrCast(&matrix.MatrixType))) {
        c.PyErr_SetString(c.PyExc_TypeError, "transform() takes a Matrix object as argument");
        return null;
    }

    const matrix_struct = @as(*matrix.MatrixObject, @ptrCast(matrix_obj.?));
    if (matrix_struct.matrix_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix is not initialized");
        return null;
    }

    // Transform the data
    var transformed = self.pca_ptr.?.transform(matrix_struct.matrix_ptr.?.*) catch |err| {
        switch (err) {
            error.NotFitted => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
                return null;
            },
            error.DimensionMismatch => {
                const pca = self.pca_ptr.?;
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "Data dimension ({}) doesn't match fitted data dimension ({})", .{ matrix_struct.matrix_ptr.?.cols, pca.dim }) catch "Dimension mismatch";
                c.PyErr_SetString(c.PyExc_ValueError, msg);
                return null;
            },
            error.NoVectors => {
                c.PyErr_SetString(c.PyExc_ValueError, "No data provided");
                return null;
            },
            else => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to transform data");
                return null;
            },
        }
    };

    // Create a new Matrix object to return
    const result = @as(?*matrix.MatrixObject, @ptrCast(c.PyType_GenericAlloc(&matrix.MatrixType, 0)));
    if (result == null) {
        transformed.deinit();
        return null;
    }

    // Allocate and store the matrix pointer
    result.?.matrix_ptr = allocator.create(Matrix(f64)) catch {
        transformed.deinit();
        // TODO: Remove explicit cast after Python 3.10 is dropped
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(result)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Matrix");
        return null;
    };
    result.?.matrix_ptr.?.* = transformed;
    result.?.numpy_ref = null;
    result.?.owns_memory = true;

    return @ptrCast(result);
}

const pca_reconstruct_doc =
    \\Reconstruct a vector from PCA coefficients.
    \\
    \\## Parameters
    \\- `coefficients` (List[float]): Coefficients in PCA space
    \\
    \\## Returns
    \\List[float]: Reconstructed vector in original space
    \\
    \\## Raises
    \\- RuntimeError: If PCA has not been fitted
    \\- ValueError: If number of coefficients doesn't match number of components
    \\
    \\## Examples
    \\```python
    \\reconstructed = pca.reconstruct([1.0, 2.0])
    \\```
;

fn pca_reconstruct(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = kwds;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    // Parse single argument: list of floats
    var list_obj: ?*c.PyObject = null;
    if (c.PyArg_ParseTuple(args, "O:reconstruct", &list_obj) == 0) {
        return null;
    }

    // Check if it's a list
    if (c.PyList_Check(list_obj) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "reconstruct() takes a list of floats as argument");
        return null;
    }

    const pca = self.pca_ptr.?;
    const list_size = c.PyList_Size(list_obj);

    // Allocate temporary buffer for coefficients
    const coeffs = allocator.alloc(f64, @intCast(list_size)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate coefficients");
        return null;
    };
    defer allocator.free(coeffs);

    // Convert Python list to f64 array
    for (0..@intCast(list_size)) |i| {
        const item = c.PyList_GetItem(list_obj, @intCast(i));
        const value = c.PyFloat_AsDouble(item);
        if (c.PyErr_Occurred() != null) {
            return null;
        }
        coeffs[i] = value;
    }

    // Reconstruct the vector
    const reconstructed = pca.reconstruct(coeffs) catch |err| {
        switch (err) {
            error.NotFitted => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
                return null;
            },
            error.InvalidCoefficients => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "Number of coefficients ({}) doesn't match number of components ({})", .{ list_size, pca.num_components }) catch "Invalid coefficients";
                c.PyErr_SetString(c.PyExc_ValueError, msg);
                return null;
            },
            else => {
                c.PyErr_SetString(c.PyExc_RuntimeError, "Failed to reconstruct vector");
                return null;
            },
        }
    };
    defer allocator.free(reconstructed);

    // Convert reconstructed vector to Python list
    const result = c.PyList_New(@intCast(reconstructed.len));
    if (result == null) {
        return null;
    }

    for (reconstructed, 0..) |value, i| {
        const py_float = c.PyFloat_FromDouble(value);
        if (py_float == null) {
            c.Py_DECREF(result);
            return null;
        }
        _ = c.PyList_SetItem(result, @intCast(i), py_float);
    }

    return result;
}

// Property getters

fn pca_get_mean(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    const pca = self.pca_ptr.?;
    const mean = pca.getMean();

    if (mean.len == 0) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
        return null;
    }

    // Convert mean to Python list
    const result = c.PyList_New(@intCast(mean.len));
    if (result == null) {
        return null;
    }

    for (mean, 0..) |value, i| {
        const py_float = c.PyFloat_FromDouble(value);
        if (py_float == null) {
            c.Py_DECREF(result);
            return null;
        }
        _ = c.PyList_SetItem(result, @intCast(i), py_float);
    }

    return result;
}

fn pca_get_components(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    const pca = self.pca_ptr.?;
    if (pca.num_components == 0) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
        return null;
    }

    // Create a copy of the components matrix
    var components_copy = Matrix(f64).init(allocator, pca.components.rows, pca.components.cols) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate components matrix");
        return null;
    };

    // Copy data
    // Copy data from components matrix
    for (0..pca.components.rows) |i| {
        for (0..pca.components.cols) |j| {
            components_copy.at(i, j).* = pca.components.at(i, j).*;
        }
    }

    // Create a new Matrix object to return
    const result = @as(?*matrix.MatrixObject, @ptrCast(c.PyType_GenericAlloc(&matrix.MatrixType, 0)));
    if (result == null) {
        components_copy.deinit();
        return null;
    }

    // Allocate and store the matrix pointer
    result.?.matrix_ptr = allocator.create(Matrix(f64)) catch {
        components_copy.deinit();
        // TODO: Remove explicit cast after Python 3.10 is dropped
        c.Py_DECREF(@as(*c.PyObject, @ptrCast(result)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Matrix");
        return null;
    };
    result.?.matrix_ptr.?.* = components_copy;
    result.?.numpy_ref = null;
    result.?.owns_memory = true;

    return @ptrCast(result);
}

fn pca_get_eigenvalues(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    const pca = self.pca_ptr.?;
    if (pca.eigenvalues.len == 0) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
        return null;
    }

    // Convert eigenvalues to Python list
    const result = c.PyList_New(@intCast(pca.eigenvalues.len));
    if (result == null) {
        return null;
    }

    for (pca.eigenvalues, 0..) |value, i| {
        const py_float = c.PyFloat_FromDouble(value);
        if (py_float == null) {
            c.Py_DECREF(result);
            return null;
        }
        _ = c.PyList_SetItem(result, @intCast(i), py_float);
    }

    return result;
}

fn pca_get_num_components(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    const pca = self.pca_ptr.?;
    return c.PyLong_FromSize_t(pca.num_components);
}

fn pca_get_dim(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*PCAObject, @ptrCast(self_obj.?));

    if (self.pca_ptr == null) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA not initialized");
        return null;
    }

    const pca = self.pca_ptr.?;
    if (pca.dim == 0) {
        c.PyErr_SetString(c.PyExc_RuntimeError, "PCA has not been fitted yet");
        return null;
    }

    return c.PyLong_FromSize_t(pca.dim);
}

// Method definitions
var PCAMethods = [_]c.PyMethodDef{
    c.PyMethodDef{
        .ml_name = "fit",
        .ml_meth = @ptrCast(&pca_fit),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .ml_doc = pca_fit_doc,
    },
    c.PyMethodDef{
        .ml_name = "project",
        .ml_meth = @ptrCast(&pca_project),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .ml_doc = pca_project_doc,
    },
    c.PyMethodDef{
        .ml_name = "transform",
        .ml_meth = @ptrCast(&pca_transform),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .ml_doc = pca_transform_doc,
    },
    c.PyMethodDef{
        .ml_name = "reconstruct",
        .ml_meth = @ptrCast(&pca_reconstruct),
        .ml_flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .ml_doc = pca_reconstruct_doc,
    },
    c.PyMethodDef{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

// Property definitions
var PCAGetSet = [_]c.PyGetSetDef{
    c.PyGetSetDef{
        .name = "mean",
        .get = @ptrCast(&pca_get_mean),
        .set = null,
        .doc = "Mean vector used for centering data",
        .closure = null,
    },
    c.PyGetSetDef{
        .name = "components",
        .get = @ptrCast(&pca_get_components),
        .set = null,
        .doc = "Principal components matrix (shape: dim × num_components)",
        .closure = null,
    },
    c.PyGetSetDef{
        .name = "eigenvalues",
        .get = @ptrCast(&pca_get_eigenvalues),
        .set = null,
        .doc = "Eigenvalues (variances) in descending order",
        .closure = null,
    },
    c.PyGetSetDef{
        .name = "num_components",
        .get = @ptrCast(&pca_get_num_components),
        .set = null,
        .doc = "Number of components retained",
        .closure = null,
    },
    c.PyGetSetDef{
        .name = "dim",
        .get = @ptrCast(&pca_get_dim),
        .set = null,
        .doc = "Dimension of input vectors",
        .closure = null,
    },
    c.PyGetSetDef{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

// Type definition
pub var PCAType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.PCA",
    .tp_basicsize = @sizeOf(PCAObject),
    .tp_dealloc = @ptrCast(&pca_dealloc),
    .tp_flags = c.Py_TPFLAGS_DEFAULT | c.Py_TPFLAGS_BASETYPE,
    .tp_doc = pca_class_doc,
    .tp_methods = @ptrCast(&PCAMethods),
    .tp_getset = @ptrCast(&PCAGetSet),
    .tp_init = @ptrCast(&pca_init),
    .tp_new = pca_new,
};

// Metadata for stub generation
pub const pca_class_metadata = stub_metadata.ClassInfo{
    .name = "PCA",
    .doc = pca_class_doc,
    .methods = &.{
        .{
            .name = "fit",
            .params = "self, data: Matrix, num_components: int|None = None",
            .returns = "None",
            .doc = pca_fit_doc,
        },
        .{
            .name = "project",
            .params = "self, vector: list[float]",
            .returns = "list[float]",
            .doc = pca_project_doc,
        },
        .{
            .name = "transform",
            .params = "self, data: Matrix",
            .returns = "Matrix",
            .doc = pca_transform_doc,
        },
        .{
            .name = "reconstruct",
            .params = "self, coefficients: list[float]",
            .returns = "list[float]",
            .doc = pca_reconstruct_doc,
        },
    },
    .properties = &.{
        .{
            .name = "mean",
            .type = "list[float]",
            .doc = "Mean vector used for centering data",
        },
        .{
            .name = "components",
            .type = "Matrix",
            .doc = "Principal components matrix (shape: dim × num_components)",
        },
        .{
            .name = "eigenvalues",
            .type = "list[float]",
            .doc = "Eigenvalues (variances) in descending order",
        },
        .{
            .name = "num_components",
            .type = "int",
            .doc = "Number of components retained",
        },
        .{
            .name = "dim",
            .type = "int",
            .doc = "Dimension of input vectors",
        },
    },
};

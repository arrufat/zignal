const std = @import("std");

const zignal = @import("zignal");
const Matrix = zignal.Matrix;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const matrix_class_doc =
    \\Matrix for numerical computations with f64 (float64) values.
    \\
    \\This class provides a bridge between zignal's Matrix type and NumPy arrays,
    \\with zero-copy operations when possible.
    \\
    \\## Examples
    \\```python
    \\import zignal
    \\import numpy as np
    \\
    \\# Create from dimensions
    \\m = zignal.Matrix(3, 4)  # 3x4 matrix of zeros
    \\m = zignal.Matrix(3, 4, fill_value=1.0)  # filled with 1.0
    \\
    \\# From numpy (zero-copy for float64 contiguous arrays)
    \\arr = np.random.randn(10, 5)
    \\m = zignal.Matrix.from_numpy(arr)
    \\
    \\# To numpy (zero-copy)
    \\arr = m.to_numpy()
    \\```
;

pub const MatrixObject = extern struct {
    ob_base: c.PyObject,
    matrix_ptr: ?*Matrix(f64),
    numpy_ref: ?*c.PyObject, // Reference to numpy array if created from numpy
    owns_memory: bool, // True if we allocated the matrix
};

fn matrix_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*MatrixObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.matrix_ptr = null;
        obj.numpy_ref = null;
        obj.owns_memory = false;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

const matrix_init_doc =
    \\Create a new Matrix with the specified dimensions.
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows
    \\- `cols` (int): Number of columns
    \\- `fill_value` (float, optional): Value to fill the matrix with (default: 0.0)
    \\
    \\## Examples
    \\```python
    \\m = Matrix(3, 4)  # 3x4 matrix of zeros
    \\m = Matrix(3, 4, fill_value=1.0)  # 3x4 matrix of ones
    \\```
;

fn matrix_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    // Check if already initialized (e.g., from from_numpy)
    if (self.matrix_ptr != null) {
        return 0;
    }

    // Parse arguments: rows, cols, optional fill_value
    var rows: c_int = 0;
    var cols: c_int = 0;
    var fill_value: f64 = 0.0;

    const kwlist = [_:null]?[*:0]const u8{ "rows", "cols", "fill_value", null };
    const format = std.fmt.comptimePrint("ii|d:Matrix", .{});

    // TODO: remove @constCast when we don't use Python < 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(@constCast(&kwlist)), &rows, &cols, &fill_value) == 0) {
        return -1;
    }

    // Validate dimensions
    if (rows <= 0 or cols <= 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix dimensions must be positive");
        return -1;
    }

    // Create the matrix
    const matrix_ptr = allocator.create(Matrix(f64)) catch {
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Matrix");
        return -1;
    };

    matrix_ptr.* = Matrix(f64).init(allocator, @intCast(rows), @intCast(cols)) catch {
        allocator.destroy(matrix_ptr);
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate matrix data");
        return -1;
    };

    // Fill with value if non-zero
    if (fill_value != 0.0) {
        @memset(matrix_ptr.items, fill_value);
    }

    self.matrix_ptr = matrix_ptr;
    self.owns_memory = true;
    self.numpy_ref = null;

    return 0;
}

fn matrix_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    // Free the matrix if we own it
    if (self.matrix_ptr) |ptr| {
        if (self.owns_memory) {
            ptr.deinit();
        }
        allocator.destroy(ptr);
    }

    // Decref numpy array if we hold a reference
    if (self.numpy_ref) |ref| {
        c.Py_DECREF(ref);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn matrix_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    if (self.matrix_ptr) |ptr| {
        // Create a string representation
        var buffer: [256]u8 = undefined;
        const slice = std.fmt.bufPrintZ(&buffer, "Matrix({} x {}, float64)", .{ ptr.rows, ptr.cols }) catch {
            return c.PyUnicode_FromString("Matrix(error formatting)");
        };
        return c.PyUnicode_FromString(slice.ptr);
    }

    return c.PyUnicode_FromString("Matrix(uninitialized)");
}

fn matrix_str(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    if (self.matrix_ptr) |ptr| {
        // For small matrices, show the actual values
        if (ptr.rows <= 6 and ptr.cols <= 6) {
            var list = std.ArrayList(u8).initCapacity(allocator, 256) catch return null;
            defer list.deinit(allocator);

            list.appendSlice(allocator, "Matrix[\n") catch return null;

            for (0..ptr.rows) |i| {
                list.appendSlice(allocator, "  [") catch return null;
                for (0..ptr.cols) |j| {
                    const val = ptr.at(i, j).*;
                    if (j > 0) list.appendSlice(allocator, ", ") catch return null;
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d:.4}", .{val}) catch return null;
                    list.appendSlice(allocator, s) catch return null;
                }
                list.appendSlice(allocator, "]\n") catch return null;
            }
            list.append(allocator, ']') catch return null;

            const str = list.toOwnedSlice(allocator) catch return null;
            defer allocator.free(str);
            // Use FromStringAndSize to ensure proper length
            return c.PyUnicode_FromStringAndSize(str.ptr, @intCast(str.len));
        } else {
            // For large matrices, just show dimensions
            return matrix_repr(self_obj);
        }
    }

    return c.PyUnicode_FromString("Matrix(uninitialized)");
}

// Properties
fn matrix_rows_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    if (self.matrix_ptr) |ptr| {
        return c.PyLong_FromLong(@intCast(ptr.rows));
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Matrix not initialized");
    return null;
}

fn matrix_cols_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    if (self.matrix_ptr) |ptr| {
        return c.PyLong_FromLong(@intCast(ptr.cols));
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Matrix not initialized");
    return null;
}

fn matrix_shape_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    if (self.matrix_ptr) |ptr| {
        return c.PyTuple_Pack(2, c.PyLong_FromLong(@intCast(ptr.rows)), c.PyLong_FromLong(@intCast(ptr.cols)));
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Matrix not initialized");
    return null;
}

fn matrix_dtype_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    _ = self_obj;
    return c.PyUnicode_FromString("float64");
}

const matrix_to_numpy_doc =
    \\Convert the matrix to a NumPy array (zero-copy).
    \\
    \\Returns a float64 NumPy array that shares memory with the Matrix.
    \\Modifying the array will modify the Matrix.
    \\
    \\## Returns
    \\NDArray[np.float64]: A 2D NumPy array with shape (rows, cols)
    \\
    \\## Examples
    \\```python
    \\m = Matrix(3, 4, fill_value=1.0)
    \\arr = m.to_numpy()  # shape (3, 4), dtype float64
    \\```
;

fn matrix_to_numpy(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    const ptr = self.matrix_ptr orelse {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix not initialized");
        return null;
    };

    // Import numpy
    const np_module = c.PyImport_ImportModule("numpy") orelse {
        c.PyErr_SetString(c.PyExc_ImportError, "NumPy is not installed. Please install it with: pip install numpy");
        return null;
    };
    defer c.Py_DECREF(np_module);

    // Create a memoryview from our matrix data
    var buffer = c.Py_buffer{
        .buf = @ptrCast(ptr.items.ptr),
        .obj = self_obj,
        .len = @intCast(ptr.rows * ptr.cols * @sizeOf(f64)),
        .itemsize = @sizeOf(f64),
        .readonly = 0,
        .ndim = 2,
        .format = @ptrCast(@constCast("d")), // 'd' for double/float64
        .shape = null,
        .strides = null,
        .suboffsets = null,
        .internal = null,
    };

    // Set up shape and strides
    var shape = [_]c.Py_ssize_t{ @intCast(ptr.rows), @intCast(ptr.cols) };
    var strides = [_]c.Py_ssize_t{ @intCast(ptr.cols * @sizeOf(f64)), @sizeOf(f64) };
    buffer.shape = &shape;
    buffer.strides = &strides;

    // Create memoryview
    const memview = c.PyMemoryView_FromBuffer(&buffer) orelse return null;
    defer c.Py_DECREF(memview);

    // Get numpy.frombuffer function
    const frombuffer = c.PyObject_GetAttrString(np_module, "frombuffer") orelse return null;
    defer c.Py_DECREF(frombuffer);

    // Call numpy.frombuffer with dtype='float64'
    const dtype_str = c.PyUnicode_FromString("float64") orelse return null;
    defer c.Py_DECREF(dtype_str);

    const flat_array = c.PyObject_CallFunctionObjArgs(frombuffer, memview, dtype_str, @as(?*c.PyObject, null)) orelse return null;
    defer c.Py_DECREF(flat_array);

    // Reshape to 2D
    const reshape_method = c.PyObject_GetAttrString(flat_array, "reshape") orelse return null;
    defer c.Py_DECREF(reshape_method);

    const shape_tuple = c.PyTuple_Pack(2, c.PyLong_FromLong(@intCast(ptr.rows)), c.PyLong_FromLong(@intCast(ptr.cols))) orelse return null;
    defer c.Py_DECREF(shape_tuple);

    return c.PyObject_CallObject(reshape_method, shape_tuple);
}

const matrix_from_numpy_doc =
    \\Create a Matrix from a NumPy array (zero-copy when possible).
    \\
    \\The array must be 2D with dtype float64 and be C-contiguous.
    \\If the array is not contiguous or not float64, an error is raised.
    \\
    \\## Parameters
    \\- `array` (NDArray[np.float64]): A 2D NumPy array with dtype float64
    \\
    \\## Returns
    \\Matrix: A new Matrix that shares memory with the NumPy array
    \\
    \\## Examples
    \\```python
    \\import numpy as np
    \\arr = np.random.randn(10, 5)  # float64 by default
    \\m = Matrix.from_numpy(arr)
    \\# Modifying arr will modify m and vice versa
    \\```
;

fn matrix_from_numpy(type_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    var array_obj: ?*c.PyObject = undefined;
    const format = std.fmt.comptimePrint("O", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &array_obj) == 0) {
        return null;
    }

    if (array_obj == null or array_obj == c.Py_None()) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array cannot be None");
        return null;
    }

    // Get buffer interface from the array
    var buffer: c.Py_buffer = undefined;
    buffer = std.mem.zeroes(c.Py_buffer);

    // Request buffer with format and strides info
    const flags: c_int = c.PyBUF_FORMAT | c.PyBUF_ND | c.PyBUF_STRIDES;
    if (c.PyObject_GetBuffer(array_obj, &buffer, flags) != 0) {
        return null;
    }
    defer c.PyBuffer_Release(&buffer);

    // Check dimensions
    if (buffer.ndim != 2) {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must be 2-dimensional");
        return null;
    }

    // Check dtype - must be float64 ('d')
    if (buffer.format == null or buffer.format[0] != 'd' or buffer.format[1] != 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "Array must have dtype float64. Use array.astype(np.float64) to convert.");
        return null;
    }

    // Check if array is C-contiguous
    const rows: usize = @intCast(buffer.shape[0]);
    const cols: usize = @intCast(buffer.shape[1]);
    const expected_stride_row = cols * @sizeOf(f64);
    const expected_stride_col = @sizeOf(f64);

    if (buffer.strides[0] != @as(c.Py_ssize_t, @intCast(expected_stride_row)) or
        buffer.strides[1] != @as(c.Py_ssize_t, @intCast(expected_stride_col)))
    {
        c.PyErr_SetString(c.PyExc_ValueError, "Array must be C-contiguous. Use np.ascontiguousarray() to convert.");
        return null;
    }

    // Create new Matrix object
    const self = @as(?*MatrixObject, @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0)));
    if (self == null) return null;

    // Create Matrix that references the numpy data
    const matrix_ptr = allocator.create(Matrix(f64)) catch {
        // TODO: remove explcit cast when we don't use Python < 3.13
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(self)));
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Matrix");
        return null;
    };

    // Create a Matrix that uses the numpy buffer's memory
    const data_slice = @as([*]f64, @ptrCast(@alignCast(buffer.buf)))[0 .. rows * cols];
    matrix_ptr.* = Matrix(f64){
        .items = data_slice,
        .rows = rows,
        .cols = cols,
        .allocator = allocator,
    };

    self.?.matrix_ptr = matrix_ptr;
    self.?.numpy_ref = array_obj;
    self.?.owns_memory = false;

    // Increment reference to numpy array to keep it alive
    c.Py_INCREF(array_obj);

    return @ptrCast(self);
}

// Indexing support
fn matrix_getitem(self_obj: ?*c.PyObject, key: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    const ptr = self.matrix_ptr orelse {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix not initialized");
        return null;
    };

    // Parse the key - expecting (row, col) tuple or two integers
    if (c.PyTuple_Check(key) == 1) {
        const size = c.PyTuple_Size(key);
        if (size != 2) {
            c.PyErr_SetString(c.PyExc_IndexError, "Matrix indices must be a tuple of two integers");
            return null;
        }

        const row_obj = c.PyTuple_GetItem(key, 0);
        const col_obj = c.PyTuple_GetItem(key, 1);

        const row = c.PyLong_AsLong(row_obj);
        const col = c.PyLong_AsLong(col_obj);

        if (c.PyErr_Occurred() != null) {
            return null;
        }

        // Handle negative indices
        const actual_row: usize = if (row < 0)
            @intCast(@as(i64, @intCast(ptr.rows)) + row)
        else
            @intCast(row);

        const actual_col: usize = if (col < 0)
            @intCast(@as(i64, @intCast(ptr.cols)) + col)
        else
            @intCast(col);

        // Bounds checking
        if (actual_row >= ptr.rows or actual_col >= ptr.cols) {
            c.PyErr_SetString(c.PyExc_IndexError, "Matrix index out of bounds");
            return null;
        }

        const value = ptr.at(actual_row, actual_col).*;
        return c.PyFloat_FromDouble(value);
    }

    c.PyErr_SetString(c.PyExc_TypeError, "Matrix indices must be a tuple of two integers");
    return null;
}

fn matrix_setitem(self_obj: ?*c.PyObject, key: ?*c.PyObject, value: ?*c.PyObject) callconv(.c) c_int {
    const self = @as(*MatrixObject, @ptrCast(self_obj.?));

    const ptr = self.matrix_ptr orelse {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix not initialized");
        return -1;
    };

    // Parse the key - expecting (row, col) tuple
    if (c.PyTuple_Check(key) == 1) {
        const size = c.PyTuple_Size(key);
        if (size != 2) {
            c.PyErr_SetString(c.PyExc_IndexError, "Matrix indices must be a tuple of two integers");
            return -1;
        }

        const row_obj = c.PyTuple_GetItem(key, 0);
        const col_obj = c.PyTuple_GetItem(key, 1);

        const row = c.PyLong_AsLong(row_obj);
        const col = c.PyLong_AsLong(col_obj);

        if (c.PyErr_Occurred() != null) {
            return -1;
        }

        // Handle negative indices
        const actual_row: usize = if (row < 0)
            @intCast(@as(i64, @intCast(ptr.rows)) + row)
        else
            @intCast(row);

        const actual_col: usize = if (col < 0)
            @intCast(@as(i64, @intCast(ptr.cols)) + col)
        else
            @intCast(col);

        // Bounds checking
        if (actual_row >= ptr.rows or actual_col >= ptr.cols) {
            c.PyErr_SetString(c.PyExc_IndexError, "Matrix index out of bounds");
            return -1;
        }

        // Get the value as a float
        const val = c.PyFloat_AsDouble(value);
        if (c.PyErr_Occurred() != null) {
            return -1;
        }

        ptr.at(actual_row, actual_col).* = val;
        return 0;
    }

    c.PyErr_SetString(c.PyExc_TypeError, "Matrix indices must be a tuple of two integers");
    return -1;
}

// Mapping methods for indexing
var matrix_as_mapping = c.PyMappingMethods{
    .mp_length = null,
    .mp_subscript = matrix_getitem,
    .mp_ass_subscript = matrix_setitem,
};

// Metadata for stub generation
pub const matrix_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "from_numpy",
        .meth = @ptrCast(&matrix_from_numpy),
        .flags = c.METH_VARARGS | c.METH_CLASS,
        .doc = matrix_from_numpy_doc,
        .params = "cls, array: NDArray[np.float64]",
        .returns = "Matrix",
    },
    .{
        .name = "to_numpy",
        .meth = @ptrCast(&matrix_to_numpy),
        .flags = c.METH_NOARGS,
        .doc = matrix_to_numpy_doc,
        .params = "self",
        .returns = "NDArray[np.float64]",
    },
};

var matrix_methods = stub_metadata.toPyMethodDefArray(&matrix_methods_metadata);

pub const matrix_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "rows",
        .get = matrix_rows_getter,
        .set = null,
        .doc = "Number of rows",
        .type = "int",
    },
    .{
        .name = "cols",
        .get = matrix_cols_getter,
        .set = null,
        .doc = "Number of columns",
        .type = "int",
    },
    .{
        .name = "shape",
        .get = matrix_shape_getter,
        .set = null,
        .doc = "Shape as (rows, cols) tuple",
        .type = "tuple[int, int]",
    },
    .{
        .name = "dtype",
        .get = matrix_dtype_getter,
        .set = null,
        .doc = "Data type (always 'float64')",
        .type = "str",
    },
};

var matrix_getset = stub_metadata.toPyGetSetDefArray(&matrix_properties_metadata);

pub const matrix_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, rows: int, cols: int, fill_value: float = 0.0",
        .returns = "None",
        .doc = matrix_init_doc,
    },
    .{
        .name = "__getitem__",
        .params = "self, key: tuple[int, int]",
        .returns = "float",
        .doc = "Get matrix element at (row, col)",
    },
    .{
        .name = "__setitem__",
        .params = "self, key: tuple[int, int], value: float",
        .returns = "None",
        .doc = "Set matrix element at (row, col)",
    },
    .{
        .name = "__repr__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
    .{
        .name = "__str__",
        .params = "self",
        .returns = "str",
        .doc = null,
    },
};

// Type object definition
pub var MatrixType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Matrix",
    .tp_basicsize = @sizeOf(MatrixObject),
    .tp_itemsize = 0,
    .tp_dealloc = matrix_dealloc,
    .tp_repr = matrix_repr,
    .tp_str = matrix_str,
    .tp_as_mapping = &matrix_as_mapping,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = matrix_class_doc,
    .tp_methods = @ptrCast(&matrix_methods),
    .tp_getset = @ptrCast(&matrix_getset),
    .tp_init = matrix_init,
    .tp_new = matrix_new,
};

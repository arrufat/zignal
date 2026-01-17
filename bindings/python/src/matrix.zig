const std = @import("std");

const zignal = @import("zignal");
const Matrix = zignal.Matrix;

const python = @import("python.zig");
const allocator = python.ctx.allocator;
const c = python.c;
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
    \\# Create from list of lists
    \\m = zignal.Matrix([[1, 2, 3], [4, 5, 6]])
    \\
    \\# Create with dimensions using full()
    \\m = zignal.Matrix.full(3, 4)  # 3x4 matrix of zeros
    \\m = zignal.Matrix.full(3, 4, fill_value=1.0)  # filled with 1.0
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

// Using genericNew helper for standard object creation
const matrix_new = python.genericNew(MatrixObject);

const matrix_init_doc =
    \\Create a new Matrix from a list of lists.
    \\
    \\## Parameters
    \\- `data` (List[List[float]]): List of lists containing matrix data
    \\
    \\## Examples
    \\```python
    \\# Create from list of lists
    \\m = Matrix([[1, 2, 3], [4, 5, 6]])  # 2x3 matrix
    \\m = Matrix([[1.0, 2.5], [3.7, 4.2]])  # 2x2 matrix
    \\```
;

fn matrix_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    const self = python.safeCast(MatrixObject, self_obj);

    // Check if already initialized (e.g., from from_numpy)
    if (self.matrix_ptr != null) {
        return 0;
    }

    // Parse single argument: list of lists
    const Params = struct {
        data: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return -1;

    const list_obj = params.data;

    // Check if it's a list
    if (c.PyList_Check(list_obj) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "Matrix data must be a list of lists");
        return -1;
    }

    // Initialize from list of lists
    return matrix_init_from_list(self, list_obj);
}

const matrix_full_doc =
    \\Create a Matrix filled with a specified value.
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows
    \\- `cols` (int): Number of columns
    \\- `fill_value` (float, optional): Value to fill the matrix with (default: 0.0)
    \\
    \\## Returns
    \\Matrix: A new Matrix of the specified dimensions filled with fill_value
    \\
    \\## Examples
    \\```python
    \\# Create 3x4 matrix of zeros
    \\m = Matrix.full(3, 4)
    \\
    \\# Create 3x4 matrix of ones
    \\m = Matrix.full(3, 4, 1.0)
    \\
    \\# Create 5x5 matrix filled with 3.14
    \\m = Matrix.full(5, 5, 3.14)
    \\```
;

fn matrix_full(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        rows: c_int,
        cols: c_int,
        fill_value: f64 = 0.0,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rows = params.rows;
    const cols = params.cols;
    const fill_value = params.fill_value;

    // Validate dimensions
    const rows_pos = python.validatePositive(usize, rows, "rows") catch return null;
    const cols_pos = python.validatePositive(usize, cols, "cols") catch return null;

    const allocation = allocOwnedMatrix(type_obj) orelse return null;
    var cleanup_needed = true;
    var matrix_initialized = false;
    defer if (cleanup_needed) cleanupOwnedMatrix(allocation, matrix_initialized);

    allocation.matrix_ptr.* = Matrix(f64).init(allocator, rows_pos, cols_pos) catch {
        python.setMemoryError("matrix data");
        return null;
    };
    matrix_initialized = true;

    // Fill with value
    @memset(allocation.matrix_ptr.items, fill_value);

    cleanup_needed = false;
    return allocation.py_obj;
}

fn matrix_init_from_list(self: *MatrixObject, list_obj: ?*c.PyObject) c_int {
    // Get dimensions
    const n_rows = c.PyList_Size(list_obj);
    if (n_rows == 0) {
        python.setValueError("Cannot create Matrix from empty list", .{});
        return -1;
    }

    // Check first row to get number of columns
    const first_row = c.PyList_GetItem(list_obj, 0);
    if (c.PyList_Check(first_row) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "Matrix data must be a list of lists");
        return -1;
    }

    const n_cols = c.PyList_Size(first_row);
    if (n_cols == 0) {
        python.setValueError("Cannot create Matrix with empty rows", .{});
        return -1;
    }

    // Create the matrix
    const matrix_ptr = allocator.create(Matrix(f64)) catch {
        python.setMemoryError("Matrix");
        return -1;
    };

    matrix_ptr.* = Matrix(f64).init(allocator, @intCast(n_rows), @intCast(n_cols)) catch {
        allocator.destroy(matrix_ptr);
        python.setMemoryError("matrix data");
        return -1;
    };

    const n_rows_usize: usize = @intCast(n_rows);
    const n_cols_usize: usize = @intCast(n_cols);

    // Fill matrix with data from list
    var row_idx: usize = 0;
    while (row_idx < n_rows_usize) : (row_idx += 1) {
        const row_obj = c.PyList_GetItem(list_obj, @intCast(row_idx));

        // Check that this is a list
        if (c.PyList_Check(row_obj) != 1) {
            matrix_ptr.deinit();
            allocator.destroy(matrix_ptr);
            python.setTypeError("list", row_obj);
            return -1;
        }

        // Check that row has correct number of columns
        const row_size = c.PyList_Size(row_obj);
        if (row_size != n_cols) {
            matrix_ptr.deinit();
            allocator.destroy(matrix_ptr);
            python.setValueError("All rows must have the same number of columns", .{});
            return -1;
        }

        // Extract values from row
        var col_idx: usize = 0;
        while (col_idx < n_cols_usize) : (col_idx += 1) {
            const item = c.PyList_GetItem(row_obj, @intCast(col_idx));

            const value = python.parse(f64, item) catch {
                matrix_ptr.deinit();
                allocator.destroy(matrix_ptr);
                c.PyErr_Clear(); // Clear the generic error from python.parse
                c.PyErr_SetString(c.PyExc_TypeError, "Matrix elements must be numeric");
                return -1;
            };

            matrix_ptr.at(row_idx, col_idx).* = value;
        }
    }

    self.matrix_ptr = matrix_ptr;
    self.owns_memory = true;
    self.numpy_ref = null;

    return 0;
}

// Helper function for custom cleanup
fn matrixDeinit(self: *MatrixObject) void {
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
}

// Using genericDealloc helper
const matrix_dealloc = python.genericDealloc(MatrixObject, matrixDeinit);

fn matrix_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(MatrixObject, self_obj);

    if (self.matrix_ptr) |ptr| {
        // Create a string representation
        var buffer: [256]u8 = undefined;
        const slice = std.fmt.bufPrintZ(&buffer, "Matrix({} x {}, float64)", .{ ptr.rows, ptr.cols }) catch {
            return python.create("Matrix(error formatting)");
        };
        return python.create(slice);
    }

    return python.create("Matrix(uninitialized)");
}

fn matrix_str(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(MatrixObject, self_obj);

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
            return python.create(str);
        } else {
            // For large matrices, just show dimensions
            return matrix_repr(self_obj);
        }
    }

    return python.create("Matrix(uninitialized)");
}

// Properties
fn matrix_shape_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const rows_obj = python.create(ptr.rows) orelse return null;
    const cols_obj = python.create(ptr.cols) orelse {
        c.Py_DECREF(rows_obj);
        return null;
    };

    const tuple = c.PyTuple_New(2) orelse {
        c.Py_DECREF(rows_obj);
        c.Py_DECREF(cols_obj);
        return null;
    };

    _ = c.PyTuple_SetItem(tuple, 0, rows_obj);
    _ = c.PyTuple_SetItem(tuple, 1, cols_obj);

    return tuple;
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
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    // Import numpy
    const np_module = c.PyImport_ImportModule("numpy") orelse {
        python.setImportError("NumPy is not installed. Please install it with: pip install numpy", .{});
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
    const dtype_str = python.create("float64") orelse return null;
    defer c.Py_DECREF(dtype_str);

    const flat_array = c.PyObject_CallFunctionObjArgs(frombuffer, memview, dtype_str, @as(?*c.PyObject, null)) orelse return null;
    defer c.Py_DECREF(flat_array);

    const rows_obj = python.create(ptr.rows) orelse return null;
    const cols_obj = python.create(ptr.cols) orelse {
        c.Py_DECREF(rows_obj);
        return null;
    };

    const shape_tuple = c.PyTuple_New(2) orelse {
        c.Py_DECREF(rows_obj);
        c.Py_DECREF(cols_obj);
        return null;
    };

    _ = c.PyTuple_SetItem(shape_tuple, 0, rows_obj);
    _ = c.PyTuple_SetItem(shape_tuple, 1, cols_obj);

    defer c.Py_DECREF(shape_tuple);

    return python.callMethodBorrowingArgs(flat_array, "reshape", shape_tuple);
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

fn matrix_from_numpy(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        array: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const array_obj = params.array;

    if (array_obj == null or array_obj == c.Py_None()) {
        python.setTypeError("non-None array", array_obj);
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
        python.setValueError("Array must be 2-dimensional", .{});
        return null;
    }

    // Check dtype - must be float64 ('d')
    if (buffer.format == null or buffer.format[0] != 'd' or buffer.format[1] != 0) {
        python.setTypeError("float64 array", array_obj);
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
        python.setValueError("Array must be C-contiguous. Use np.ascontiguousarray() to convert.", .{});
        return null;
    }

    // Create new Matrix object
    const self: ?*MatrixObject = @ptrCast(c.PyType_GenericAlloc(@ptrCast(type_obj), 0));
    if (self == null) return null;

    // Create Matrix that references the numpy data
    const matrix_ptr = allocator.create(Matrix(f64)) catch {
        // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(self)));
        python.setMemoryError("Matrix");
        return null;
    };

    // Create a Matrix that uses the numpy buffer's memory.
    // NumPy buffers are not guaranteed to be 64-byte aligned.
    // We check alignment and fallback to a copy if it doesn't meet our requirements.
    const simd_align = 64;
    const is_aligned = if (buffer.buf) |ptr| (@intFromPtr(ptr) % simd_align == 0) else false;

    if (is_aligned) {
        const data_slice = @as([*]align(simd_align) f64, @ptrCast(@alignCast(buffer.buf.?)))[0 .. rows * cols];
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
    } else {
        // Fallback: copy unaligned data to an aligned buffer
        matrix_ptr.* = Matrix(f64).init(allocator, rows, cols) catch {
            allocator.destroy(matrix_ptr);
            // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
            c.Py_DECREF(@as(?*c.PyObject, @ptrCast(self)));
            python.setMemoryError("Matrix");
            return null;
        };
        if (buffer.buf) |src_buf| {
            const src_ptr: [*]const u8 = @ptrCast(src_buf);
            const src_bytes = src_ptr[0 .. rows * cols * @sizeOf(f64)];
            @memcpy(std.mem.sliceAsBytes(matrix_ptr.items), src_bytes);
        }

        self.?.matrix_ptr = matrix_ptr;
        self.?.numpy_ref = null;
        self.?.owns_memory = true;
    }

    return @ptrCast(self);
}

// Indexing support
fn matrix_getitem(self_obj: ?*c.PyObject, key: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    // Parse the key - expecting (row, col) tuple or two integers
    if (c.PyTuple_Check(key) == 1) {
        const size = c.PyTuple_Size(key);
        if (size != 2) {
            python.setIndexError("Matrix indices must be a tuple of two integers", .{});
            return null;
        }

        const row_obj = c.PyTuple_GetItem(key, 0);
        const col_obj = c.PyTuple_GetItem(key, 1);

        const row = python.parse(c_long, row_obj) catch return null;
        const col = python.parse(c_long, col_obj) catch return null;

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
            python.setIndexError("Matrix index out of bounds", .{});
            return null;
        }

        const value = ptr.at(actual_row, actual_col).*;
        return python.create(value);
    }

    python.setTypeError("tuple of two integers", key);
    return null;
}

fn matrix_setitem(self_obj: ?*c.PyObject, key: ?*c.PyObject, value: ?*c.PyObject) callconv(.c) c_int {
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return -1;

    // Parse the key - expecting (row, col) tuple
    if (c.PyTuple_Check(key) == 1) {
        const size = c.PyTuple_Size(key);
        if (size != 2) {
            python.setIndexError("Matrix indices must be a tuple of two integers", .{});
            return -1;
        }

        const row_obj = c.PyTuple_GetItem(key, 0);
        const col_obj = c.PyTuple_GetItem(key, 1);

        const row = python.parse(c_long, row_obj) catch return -1;
        const col = python.parse(c_long, col_obj) catch return -1;

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
            python.setIndexError("Matrix index out of bounds", .{});
            return -1;
        }

        // Get the value as a float
        const val = python.parse(f64, value) catch return -1;

        ptr.at(actual_row, actual_col).* = val;
        return 0;
    }

    python.setTypeError("tuple of two integers", key);
    return -1;
}

// Mapping methods for indexing
var matrix_as_mapping = c.PyMappingMethods{
    .mp_length = null,
    .mp_subscript = matrix_getitem,
    .mp_ass_subscript = matrix_setitem,
};

// ===== Operator overloads for number protocol =====

/// Generic dispatcher for binary matrix operations
fn dispatchMatrixOp(
    left: ?*c.PyObject,
    right: ?*c.PyObject,
    mat_mat_op: fn (*Matrix(f64), *Matrix(f64)) Matrix(f64),
    mat_scalar_op: fn (*Matrix(f64), f64) Matrix(f64),
    scalar_mat_op: ?fn (f64, *Matrix(f64)) Matrix(f64),
) ?*c.PyObject {
    const left_is_mat = c.PyObject_IsInstance(left, @ptrCast(&MatrixType)) == 1;
    const right_is_mat = c.PyObject_IsInstance(right, @ptrCast(&MatrixType)) == 1;

    if (left_is_mat and right_is_mat) {
        const left_ptr = python.unwrap(MatrixObject, "matrix_ptr", left, "Matrix") orelse return null;
        const right_ptr = python.unwrap(MatrixObject, "matrix_ptr", right, "Matrix") orelse return null;
        return matrixToObject(mat_mat_op(left_ptr, right_ptr));
    }

    if (left_is_mat) {
        if (python.parse(f64, right)) |scalar| {
            const left_ptr = python.unwrap(MatrixObject, "matrix_ptr", left, "Matrix") orelse return null;
            return matrixToObject(mat_scalar_op(left_ptr, scalar));
        } else |_| {
            python.clearError();
        }
    }

    if (right_is_mat) {
        if (scalar_mat_op) |op| {
            if (python.parse(f64, left)) |scalar| {
                const right_ptr = python.unwrap(MatrixObject, "matrix_ptr", right, "Matrix") orelse return null;
                return matrixToObject(op(scalar, right_ptr));
            } else |_| {
                python.clearError();
            }
        }
    }

    return python.notImplemented();
}

fn op_add(a: *Matrix(f64), b: *Matrix(f64)) Matrix(f64) {
    return a.add(b.*);
}
fn op_add_scalar(a: *Matrix(f64), s: f64) Matrix(f64) {
    return a.offset(s);
}
fn op_radd_scalar(s: f64, a: *Matrix(f64)) Matrix(f64) {
    return a.offset(s);
}
fn op_sub(a: *Matrix(f64), b: *Matrix(f64)) Matrix(f64) {
    return a.sub(b.*);
}
fn op_sub_scalar(a: *Matrix(f64), s: f64) Matrix(f64) {
    return a.offset(-s);
}
fn op_rsub_scalar(s: f64, a: *Matrix(f64)) Matrix(f64) {
    var negated = a.scale(-1.0);
    defer negated.deinit();
    return negated.offset(s);
}
fn op_mul(a: *Matrix(f64), b: *Matrix(f64)) Matrix(f64) {
    return a.times(b.*);
}
fn op_mul_scalar(a: *Matrix(f64), s: f64) Matrix(f64) {
    return a.scale(s);
}
fn op_rmul_scalar(s: f64, a: *Matrix(f64)) Matrix(f64) {
    return a.scale(s);
}

fn matrix_add(left: ?*c.PyObject, right: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return dispatchMatrixOp(left, right, op_add, op_add_scalar, op_radd_scalar);
}

fn matrix_subtract(left: ?*c.PyObject, right: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return dispatchMatrixOp(left, right, op_sub, op_sub_scalar, op_rsub_scalar);
}

fn matrix_multiply(left: ?*c.PyObject, right: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    return dispatchMatrixOp(left, right, op_mul, op_mul_scalar, op_rmul_scalar);
}

fn matrix_matmul(left: ?*c.PyObject, right: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyObject_IsInstance(left, @ptrCast(&MatrixType)) != 1 or
        c.PyObject_IsInstance(right, @ptrCast(&MatrixType)) != 1)
    {
        return python.notImplemented();
    }

    const self_ptr = python.unwrap(MatrixObject, "matrix_ptr", left, "Matrix") orelse return null;
    const other_ptr = python.unwrap(MatrixObject, "matrix_ptr", right, "Matrix") orelse return null;

    const result_matrix = self_ptr.dot(other_ptr.*);
    return matrixToObject(result_matrix);
}

fn matrix_truediv(left: ?*c.PyObject, right: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    if (c.PyObject_IsInstance(left, @ptrCast(&MatrixType)) != 1) {
        return python.notImplemented();
    }

    const scalar = python.parse(f64, right) catch return python.notImplemented();

    if (scalar == 0.0) {
        c.PyErr_SetString(c.PyExc_ZeroDivisionError, "Cannot divide matrix by zero");
        return null;
    }

    const self_ptr = python.unwrap(MatrixObject, "matrix_ptr", left, "Matrix") orelse return null;

    const result_matrix = self_ptr.scale(1.0 / scalar);
    return matrixToObject(result_matrix);
}

fn matrix_negative(obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self_ptr = python.unwrap(MatrixObject, "matrix_ptr", obj, "Matrix") orelse return null;

    const result_matrix = self_ptr.scale(-1.0);
    return matrixToObject(result_matrix);
}

// Helper function to convert Zig Matrix to Python MatrixObject
fn matrixToObject(matrix: Matrix(f64)) ?*c.PyObject {
    if (matrix.err) |e| {
        python.mapZigError(e, "Matrix");
        return null;
    }

    const self: ?*MatrixObject = @ptrCast(c.PyType_GenericAlloc(@ptrCast(&MatrixType), 0));
    if (self == null) return null;

    const matrix_ptr = allocator.create(Matrix(f64)) catch {
        // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
        c.Py_DECREF(@as(?*c.PyObject, @ptrCast(self)));
        python.setMemoryError("Matrix");
        return null;
    };

    matrix_ptr.* = matrix;
    self.?.matrix_ptr = matrix_ptr;
    self.?.owns_memory = true;
    self.?.numpy_ref = null;

    return @ptrCast(self);
}

const OwnedMatrixAlloc = struct {
    py_obj: ?*c.PyObject,
    matrix_obj: *MatrixObject,
    matrix_ptr: *Matrix(f64),
};

fn allocOwnedMatrix(type_obj: ?*c.PyObject) ?OwnedMatrixAlloc {
    const raw_self = c.PyType_GenericAlloc(@ptrCast(type_obj), 0);
    if (raw_self == null) return null;

    const matrix_obj: *MatrixObject = @ptrCast(raw_self.?);
    matrix_obj.matrix_ptr = null;
    matrix_obj.numpy_ref = null;
    matrix_obj.owns_memory = false;

    const matrix_ptr = allocator.create(Matrix(f64)) catch {
        c.Py_DECREF(raw_self);
        python.setMemoryError("Matrix");
        return null;
    };

    matrix_obj.matrix_ptr = matrix_ptr;
    matrix_obj.numpy_ref = null;
    matrix_obj.owns_memory = true;

    return .{ .py_obj = raw_self, .matrix_obj = matrix_obj, .matrix_ptr = matrix_ptr };
}

fn cleanupOwnedMatrix(allocation: OwnedMatrixAlloc, matrix_initialized: bool) void {
    if (matrix_initialized) {
        allocation.matrix_ptr.deinit();
    }
    allocator.destroy(allocation.matrix_ptr);

    allocation.matrix_obj.matrix_ptr = null;
    allocation.matrix_obj.owns_memory = false;

    c.Py_DECREF(allocation.py_obj);
}

fn matrixDimensionGetter(comptime dim: enum { rows, cols }) *const anyopaque {
    const dimension = dim;
    const Gen = struct {
        fn get(self_obj: ?*c.PyObject, _: ?*anyopaque) callconv(.c) ?*c.PyObject {
            const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
            const value: usize = switch (dimension) {
                .rows => ptr.rows,
                .cols => ptr.cols,
            };
            return python.create(value);
        }
    };
    return @ptrCast(&Gen.get);
}

const matrix_rows_getter = matrixDimensionGetter(.rows);
const matrix_cols_getter = matrixDimensionGetter(.cols);

// Number protocol for arithmetic operations
var matrix_as_number = c.PyNumberMethods{
    .nb_add = matrix_add,
    .nb_subtract = matrix_subtract,
    .nb_multiply = matrix_multiply,
    .nb_remainder = null,
    .nb_divmod = null,
    .nb_power = null,
    .nb_negative = matrix_negative,
    .nb_positive = null,
    .nb_absolute = null,
    .nb_bool = null,
    .nb_invert = null,
    .nb_lshift = null,
    .nb_rshift = null,
    .nb_and = null,
    .nb_xor = null,
    .nb_or = null,
    .nb_int = null,
    .nb_reserved = null,
    .nb_float = null,
    .nb_inplace_add = null,
    .nb_inplace_subtract = null,
    .nb_inplace_multiply = null,
    .nb_inplace_remainder = null,
    .nb_inplace_power = null,
    .nb_inplace_lshift = null,
    .nb_inplace_rshift = null,
    .nb_inplace_and = null,
    .nb_inplace_xor = null,
    .nb_inplace_or = null,
    .nb_floor_divide = null,
    .nb_true_divide = matrix_truediv,
    .nb_inplace_floor_divide = null,
    .nb_inplace_true_divide = null,
    .nb_index = null,
    .nb_matrix_multiply = matrix_matmul,
    .nb_inplace_matrix_multiply = null,
};

// ===== Matrix methods =====

const matrix_transpose_doc =
    \\Transpose the matrix.
    \\
    \\## Returns
    \\Matrix: A new transposed matrix where rows and columns are swapped
    \\
    \\## Examples
    \\```python
    \\m = Matrix([[1, 2, 3], [4, 5, 6]])
    \\t = m.transpose()  # shape (3, 2)
    \\```
;

fn matrix_transpose(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result_matrix = ptr.transpose();
    return matrixToObject(result_matrix);
}

const matrix_inverse_doc =
    \\Compute the matrix inverse.
    \\
    \\## Returns
    \\Matrix: The inverse matrix such that A @ A.inverse() ≈ I
    \\
    \\## Raises
    \\ValueError: If matrix is not square or is singular
    \\
    \\## Examples
    \\```python
    \\m = Matrix([[2, 0], [0, 2]])
    \\inv = m.inverse()  # [[0.5, 0], [0, 0.5]]
    \\```
;

fn matrix_inverse(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result_matrix = ptr.inverse();
    return matrixToObject(result_matrix);
}

const matrix_dot_doc =
    \\Matrix multiplication (dot product).
    \\
    \\## Parameters
    \\- `other` (Matrix): Matrix to multiply with
    \\
    \\## Returns
    \\Matrix: Result of matrix multiplication
    \\
    \\## Examples
    \\```python
    \\a = Matrix([[1, 2], [3, 4]])
    \\b = Matrix([[5, 6], [7, 8]])
    \\c = a.dot(b)  # or a @ b
    \\```
;

fn matrix_dot_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        other: ?*c.PyObject,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    if (c.PyObject_IsInstance(params.other, @ptrCast(&MatrixType)) != 1) {
        python.setTypeError("Matrix", params.other);
        return null;
    }

    return matrix_matmul(self_obj, params.other);
}

const matrix_sum_doc =
    \\Sum of all matrix elements.
    \\
    \\## Returns
    \\float: The sum of all elements
    \\
    \\## Examples
    \\```python
    \\m = Matrix([[1, 2], [3, 4]])
    \\s = m.sum()  # 10.0
    \\```
;

fn matrix_sum_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.sum();
    return python.create(result);
}

const matrix_mean_doc =
    \\Mean (average) of all matrix elements.
    \\
    \\## Returns
    \\float: The mean of all elements
;

fn matrix_mean_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.mean();
    return python.create(result);
}

const matrix_min_doc =
    \\Minimum element in the matrix.
    \\
    \\## Returns
    \\float: The minimum value
;

fn matrix_min_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.min();
    return python.create(result);
}

const matrix_max_doc =
    \\Maximum element in the matrix.
    \\
    \\## Returns
    \\float: The maximum value
;

fn matrix_max_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.max();
    return python.create(result);
}

const matrix_trace_doc =
    \\Sum of diagonal elements (trace).
    \\
    \\## Returns
    \\float: The trace of the matrix
    \\
    \\## Raises
    \\ValueError: If matrix is not square
;

fn matrix_trace_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    if (ptr.rows != ptr.cols) {
        python.setValueError("Matrix must be square to compute trace", .{});
        return null;
    }

    const result = ptr.trace();
    return python.create(result);
}

const matrix_identity_doc =
    \\Create an identity matrix.
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows
    \\- `cols` (int): Number of columns
    \\
    \\## Returns
    \\Matrix: Identity matrix with ones on diagonal
;

fn matrix_identity(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        rows: c_int,
        cols: c_int,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rows_pos = python.validatePositive(usize, params.rows, "rows") catch return null;
    const cols_pos = python.validatePositive(usize, params.cols, "cols") catch return null;

    const allocation = allocOwnedMatrix(type_obj) orelse return null;
    var cleanup_needed = true;
    var matrix_initialized = false;
    defer if (cleanup_needed) cleanupOwnedMatrix(allocation, matrix_initialized);

    allocation.matrix_ptr.* = Matrix(f64).identity(allocator, rows_pos, cols_pos) catch {
        python.setMemoryError("matrix data");
        return null;
    };
    matrix_initialized = true;

    cleanup_needed = false;
    return allocation.py_obj;
}

const matrix_zeros_doc =
    \\Create a matrix filled with zeros.
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows
    \\- `cols` (int): Number of columns
    \\
    \\## Returns
    \\Matrix: Matrix filled with zeros
;

fn matrix_zeros(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        rows: c_int,
        cols: c_int,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rows_pos = python.validatePositive(usize, params.rows, "rows") catch return null;
    const cols_pos = python.validatePositive(usize, params.cols, "cols") catch return null;

    const allocation = allocOwnedMatrix(type_obj) orelse return null;
    var cleanup_needed = true;
    var matrix_initialized = false;
    defer if (cleanup_needed) cleanupOwnedMatrix(allocation, matrix_initialized);

    allocation.matrix_ptr.* = Matrix(f64).init(allocator, rows_pos, cols_pos) catch {
        python.setMemoryError("matrix data");
        return null;
    };
    matrix_initialized = true;

    @memset(allocation.matrix_ptr.items, 0.0);

    cleanup_needed = false;
    return allocation.py_obj;
}

const matrix_ones_doc =
    \\Create a matrix filled with ones.
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows
    \\- `cols` (int): Number of columns
    \\
    \\## Returns
    \\Matrix: Matrix filled with ones
;

fn matrix_ones(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        rows: c_int,
        cols: c_int,
        fill_value: f64 = 1.0,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rows_pos = python.validatePositive(usize, params.rows, "rows") catch return null;
    const cols_pos = python.validatePositive(usize, params.cols, "cols") catch return null;

    const allocation = allocOwnedMatrix(type_obj) orelse return null;
    var cleanup_needed = true;
    var matrix_initialized = false;
    defer if (cleanup_needed) cleanupOwnedMatrix(allocation, matrix_initialized);

    allocation.matrix_ptr.* = Matrix(f64).init(allocator, rows_pos, cols_pos) catch {
        python.setMemoryError("matrix data");
        return null;
    };
    matrix_initialized = true;

    @memset(allocation.matrix_ptr.items, params.fill_value);

    cleanup_needed = false;
    return allocation.py_obj;
}

const matrix_copy_doc =
    \\Create a copy of the matrix.
    \\
    \\## Returns
    \\Matrix: A new matrix with the same values
;

fn matrix_copy_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result_matrix = ptr.dupe(allocator) catch {
        python.setMemoryError("Matrix copy");
        return null;
    };

    return matrixToObject(result_matrix);
}

const matrix_determinant_doc =
    \\Compute the determinant of the matrix.
    \\
    \\## Returns
    \\float: The determinant value
    \\
    \\## Raises
    \\ValueError: If matrix is not square
;

fn matrix_determinant_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    if (ptr.rows != ptr.cols) {
        python.setValueError("Matrix must be square to compute determinant", .{});
        return null;
    }

    const result = ptr.determinant() catch {
        python.setMemoryError("determinant computation");
        return null;
    };

    return python.create(result);
}

const matrix_gram_doc =
    \\Compute Gram matrix (X × X^T).
    \\
    \\## Returns
    \\Matrix: The Gram matrix (rows × rows)
;

fn matrix_gram_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result_matrix = ptr.gram();
    return matrixToObject(result_matrix);
}

const matrix_covariance_doc =
    \\Compute covariance matrix (X^T × X).
    \\
    \\## Returns
    \\Matrix: The covariance matrix (cols × cols)
;

fn matrix_covariance_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result_matrix = ptr.covariance();
    return matrixToObject(result_matrix);
}

const matrix_frobenius_norm_doc =
    \\Frobenius norm (entrywise ℓ2).
    \\
    \\## Returns
    \\float: Frobenius norm value
;

fn matrix_frobenius_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
    return python.create(ptr.frobeniusNorm());
}

const matrix_l1_norm_doc =
    \\Entrywise L1 norm (sum of absolute values).
    \\
    \\## Returns
    \\float: L1 norm value
;

fn matrix_l1_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
    return python.create(ptr.l1Norm());
}

const matrix_max_norm_doc =
    \\Entrywise infinity norm (maximum absolute value).
    \\
    \\## Returns
    \\float: Infinity norm value
;

fn matrix_max_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
    return python.create(ptr.maxNorm());
}

const matrix_element_norm_doc =
    \\Entrywise ℓᵖ norm with runtime exponent.
    \\
    \\## Parameters
    \\- `p` (float, optional): Exponent (default 2).
    \\
    \\## Returns
    \\float: Element norm value
;

fn matrix_element_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { p: f64 = 2 };
    var params: Params = .{};
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
    if (!std.math.isFinite(params.p)) {
        if (!std.math.isInf(params.p)) {
            python.setValueError("Element norm exponent must be finite or ±inf", .{});
            return null;
        }
    } else if (params.p < 0) {
        python.setValueError("Element norm requires p >= 0 (or ±inf)", .{});
        return null;
    }

    const result = ptr.elementNorm(params.p) catch |err| {
        python.mapZigError(err, "element norm");
        return null;
    };

    return python.create(result);
}

const matrix_schatten_norm_doc =
    \\Schatten ℓᵖ norm based on singular values.
    \\
    \\## Parameters
    \\- `p` (float, optional): Exponent (default 2, must be ≥ 1 when finite).
    \\
    \\## Returns
    \\float: Schatten norm value
;

fn matrix_schatten_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { p: f64 = 2 };
    var params: Params = .{};
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
    if (!std.math.isFinite(params.p)) {
        if (!(std.math.isInf(params.p) and params.p > 0)) {
            python.setValueError("Schatten norm exponent must be finite ≥ 1 or +inf", .{});
            return null;
        }
    } else if (params.p < 1) {
        python.setValueError("Schatten norm requires p >= 1", .{});
        return null;
    }

    const result = ptr.schattenNorm(allocator, params.p) catch |err| {
        python.mapZigError(err, "schatten norm");
        return null;
    };

    return python.create(result);
}

const matrix_induced_norm_doc =
    \\Induced operator norm with p ∈ {1, 2, ∞}.
    \\
    \\## Parameters
    \\- `p` (float, optional): Exponent (allowed values: 1, 2, +inf; default 2).
    \\
    \\## Returns
    \\float: Induced norm value
;

fn matrix_induced_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { p: f64 = 2 };
    var params: Params = .{};
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;
    const valid = (params.p == 1) or (params.p == 2) or (std.math.isInf(params.p) and params.p > 0);
    if (!valid) {
        python.setValueError("Induced norm supports p = 1, 2, or +inf", .{});
        return null;
    }

    const result = ptr.inducedNorm(allocator, params.p) catch |err| {
        python.mapZigError(err, "induced norm");
        return null;
    };

    return python.create(result);
}

const matrix_nuclear_norm_doc =
    \\Nuclear norm (sum of singular values).
    \\
    \\## Returns
    \\float: Nuclear norm value
;

fn matrix_nuclear_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.nuclearNorm(allocator) catch |err| {
        python.mapZigError(err, "nuclear norm");
        return null;
    };

    return python.create(result);
}

const matrix_spectral_norm_doc =
    \\Spectral norm (largest singular value).
    \\
    \\## Returns
    \\float: Spectral norm value
;

fn matrix_spectral_norm_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.spectralNorm(allocator) catch |err| {
        python.mapZigError(err, "spectral norm");
        return null;
    };

    return python.create(result);
}

const matrix_variance_doc =
    \\Compute variance of all matrix elements.
    \\
    \\## Returns
    \\float: The variance
;

fn matrix_variance_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.variance();
    return python.create(result);
}

const matrix_std_doc =
    \\Compute standard deviation of all matrix elements.
    \\
    \\## Returns
    \\float: The standard deviation
;

fn matrix_std_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.stdDev();
    return python.create(result);
}

const matrix_pow_doc =
    \\Raise all elements to power n (element-wise).
    \\
    \\## Parameters
    \\- `n` (float): The exponent
    \\
    \\## Returns
    \\Matrix: Matrix with elements raised to power n
;

fn matrix_pow_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        n: f64,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result_matrix = ptr.pow(params.n);
    return matrixToObject(result_matrix);
}

const matrix_row_doc =
    \\Extract a row as a column vector.
    \\
    \\## Parameters
    \\- `idx` (int): Row index
    \\
    \\## Returns
    \\Matrix: Column vector containing the row
;

fn matrix_row_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { idx: c_int };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const idx: usize = if (params.idx < 0)
        @intCast(@as(i64, @intCast(ptr.rows)) + params.idx)
    else
        @intCast(params.idx);

    if (idx >= ptr.rows) {
        python.setIndexError("Row index out of bounds", .{});
        return null;
    }

    const result_matrix = ptr.row(idx);
    return matrixToObject(result_matrix);
}

const matrix_col_doc =
    \\Extract a column as a column vector.
    \\
    \\## Parameters
    \\- `idx` (int): Column index
    \\
    \\## Returns
    \\Matrix: Column vector
;

fn matrix_col_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { idx: c_int };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const idx: usize = if (params.idx < 0)
        @intCast(@as(i64, @intCast(ptr.cols)) + params.idx)
    else
        @intCast(params.idx);

    if (idx >= ptr.cols) {
        python.setIndexError("Column index out of bounds", .{});
        return null;
    }

    const result_matrix = ptr.col(idx);
    return matrixToObject(result_matrix);
}

const matrix_submatrix_doc =
    \\Extract a submatrix.
    \\
    \\## Parameters
    \\- `row_start` (int): Starting row index
    \\- `col_start` (int): Starting column index
    \\- `row_count` (int): Number of rows
    \\- `col_count` (int): Number of columns
    \\
    \\## Returns
    \\Matrix: Submatrix
;

fn matrix_submatrix_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        row_start: c_int,
        col_start: c_int,
        row_count: c_int,
        col_count: c_int,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    // Starting indices can be zero, but counts must be positive
    if (params.row_start < 0) {
        python.setValueError("row_start must be non-negative", .{});
        return null;
    }
    if (params.col_start < 0) {
        python.setValueError("col_start must be non-negative", .{});
        return null;
    }

    const row_start_pos: usize = @intCast(params.row_start);
    const col_start_pos: usize = @intCast(params.col_start);
    const row_count_pos = python.validatePositive(usize, params.row_count, "row_count") catch return null;
    const col_count_pos = python.validatePositive(usize, params.col_count, "col_count") catch return null;

    const result_matrix = ptr.subMatrix(row_start_pos, col_start_pos, row_count_pos, col_count_pos);
    return matrixToObject(result_matrix);
}

// ===== Advanced decomposition methods =====

const matrix_random_doc =
    \\Create a matrix filled with random values in [0, 1).
    \\
    \\## Parameters
    \\- `rows` (int): Number of rows
    \\- `cols` (int): Number of columns
    \\- `seed` (int, optional): Random seed for reproducibility
    \\
    \\## Returns
    \\Matrix: Matrix filled with random float64 values
    \\
    \\## Examples
    \\```python
    \\m = Matrix.random(10, 5)  # Random 10x5 matrix
    \\m = Matrix.random(10, 5, seed=42)  # Reproducible random matrix
    \\```
;

fn matrix_random(type_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        rows: c_int,
        cols: c_int,
        seed: ?u64 = null,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const rows_pos = python.validatePositive(usize, params.rows, "rows") catch return null;
    const cols_pos = python.validatePositive(usize, params.cols, "cols") catch return null;

    const allocation = allocOwnedMatrix(type_obj) orelse return null;
    var cleanup_needed = true;
    var matrix_initialized = false;
    defer if (cleanup_needed) cleanupOwnedMatrix(allocation, matrix_initialized);

    allocation.matrix_ptr.* = Matrix(f64).random(allocator, rows_pos, cols_pos, params.seed) catch {
        python.setMemoryError("matrix data");
        return null;
    };
    matrix_initialized = true;

    cleanup_needed = false;
    return allocation.py_obj;
}

const matrix_rank_doc =
    \\Compute the numerical rank of the matrix.
    \\
    \\Uses QR decomposition with column pivoting to determine the rank.
    \\
    \\## Returns
    \\int: The numerical rank
;

fn matrix_rank_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const result = ptr.rank() catch {
        python.setMemoryError("rank computation");
        return null;
    };

    return python.create(result);
}

const matrix_pinv_doc =
    \\Compute the Moore-Penrose pseudoinverse.
    \\
    \\Works for rectangular matrices and gracefully handles rank deficiency.
    \\Uses SVD-based algorithm.
    \\
    \\## Parameters
    \\- `tolerance` (float, optional): Threshold for small singular values
    \\
    \\## Returns
    \\Matrix: The pseudoinverse matrix
    \\
    \\## Examples
    \\```python
    \\# For rectangular matrix
    \\m = Matrix([[1, 2], [3, 4], [5, 6]])
    \\pinv = m.pinv()
    \\# With custom tolerance
    \\pinv = m.pinv(tolerance=1e-10)
    \\```
;

fn matrix_pinv_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct { tolerance: ?f64 = null };
    var params: Params = .{};
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    const options = Matrix(f64).PseudoInverseOptions{
        .tolerance = params.tolerance,
        .effective_rank = null,
    };

    const result_matrix = ptr.pseudoInverse(options);
    return matrixToObject(result_matrix);
}

const matrix_lu_doc =
    \\Compute LU decomposition with partial pivoting.
    \\
    \\Returns L, U matrices and permutation vector such that PA = LU.
    \\
    \\## Returns
    \\dict: Dictionary with keys:
    \\  - 'l': Lower triangular matrix
    \\  - 'u': Upper triangular matrix
    \\  - 'p': Permutation vector (list of int)
    \\  - 'sign': Determinant sign (+1.0 or -1.0)
    \\
    \\## Raises
    \\ValueError: If matrix is not square
;

fn matrix_lu_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    if (ptr.rows != ptr.cols) {
        python.setValueError("Matrix must be square for LU decomposition", .{});
        return null;
    }

    var lu_result = ptr.lu() catch {
        python.setMemoryError("LU decomposition");
        return null;
    };
    defer lu_result.deinit();

    // Create Python dictionary
    const result_dict = c.PyDict_New() orelse return null;

    // Add matrices
    const l_obj = matrixToObject(lu_result.l.dupe(allocator) catch {
        c.Py_DECREF(result_dict);
        python.setMemoryError("Matrix copy");
        return null;
    }) orelse {
        c.Py_DECREF(result_dict);
        return null;
    };
    const u_obj = matrixToObject(lu_result.u.dupe(allocator) catch {
        c.Py_DECREF(l_obj);
        c.Py_DECREF(result_dict);
        python.setMemoryError("Matrix copy");
        return null;
    }) orelse {
        c.Py_DECREF(l_obj);
        c.Py_DECREF(result_dict);
        return null;
    };
    const p_list = python.listFromSlice(usize, lu_result.p.indices) orelse {
        c.Py_DECREF(l_obj);
        c.Py_DECREF(u_obj);
        c.Py_DECREF(result_dict);
        return null;
    };

    _ = c.PyDict_SetItemString(result_dict, "l", l_obj);
    _ = c.PyDict_SetItemString(result_dict, "u", u_obj);
    _ = c.PyDict_SetItemString(result_dict, "p", p_list);

    const sign_obj = python.create(lu_result.sign) orelse {
        c.Py_DECREF(l_obj);
        c.Py_DECREF(u_obj);
        c.Py_DECREF(p_list);
        c.Py_DECREF(result_dict);
        return null;
    };
    _ = c.PyDict_SetItemString(result_dict, "sign", sign_obj);
    c.Py_DECREF(sign_obj);

    c.Py_DECREF(l_obj);
    c.Py_DECREF(u_obj);
    c.Py_DECREF(p_list);

    return result_dict;
}

const matrix_qr_doc =
    \\Compute QR decomposition with column pivoting.
    \\
    \\Returns Q, R matrices and additional information about the decomposition.
    \\
    \\## Returns
    \\dict: Dictionary with keys:
    \\  - 'q': Orthogonal matrix (m×n)
    \\  - 'r': Upper triangular matrix (n×n)
    \\  - 'rank': Numerical rank (int)
    \\  - 'perm': Column permutation indices (list of int)
    \\  - 'col_norms': Final column norms (list of float)
;

fn matrix_qr_method(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    var qr_result = ptr.qr() catch {
        python.setMemoryError("QR decomposition");
        return null;
    };
    defer qr_result.deinit();

    // Create Python dictionary
    const result_dict = c.PyDict_New() orelse return null;

    // Add matrices
    const q_obj = matrixToObject(qr_result.q.dupe(allocator) catch {
        c.Py_DECREF(result_dict);
        python.setMemoryError("Matrix copy");
        return null;
    }) orelse {
        c.Py_DECREF(result_dict);
        return null;
    };
    const r_obj = matrixToObject(qr_result.r.dupe(allocator) catch {
        c.Py_DECREF(q_obj);
        c.Py_DECREF(result_dict);
        python.setMemoryError("Matrix copy");
        return null;
    }) orelse {
        c.Py_DECREF(q_obj);
        c.Py_DECREF(result_dict);
        return null;
    };

    _ = c.PyDict_SetItemString(result_dict, "q", q_obj);
    _ = c.PyDict_SetItemString(result_dict, "r", r_obj);

    const rank_obj = python.create(qr_result.rank) orelse {
        c.Py_DECREF(q_obj);
        c.Py_DECREF(r_obj);
        c.Py_DECREF(result_dict);
        return null;
    };
    _ = c.PyDict_SetItemString(result_dict, "rank", rank_obj);
    c.Py_DECREF(rank_obj);

    // Convert permutation to Python list
    const perm_list = python.listFromSlice(usize, qr_result.perm.indices) orelse {
        c.Py_DECREF(q_obj);
        c.Py_DECREF(r_obj);
        c.Py_DECREF(result_dict);
        return null;
    };
    _ = c.PyDict_SetItemString(result_dict, "perm", perm_list);

    // Convert col_norms to Python list
    const col_norms_list = python.listFromSlice(f64, qr_result.col_norms) orelse {
        c.Py_DECREF(q_obj);
        c.Py_DECREF(r_obj);
        c.Py_DECREF(perm_list);
        c.Py_DECREF(result_dict);
        return null;
    };
    _ = c.PyDict_SetItemString(result_dict, "col_norms", col_norms_list);

    c.Py_DECREF(q_obj);
    c.Py_DECREF(r_obj);
    c.Py_DECREF(perm_list);
    c.Py_DECREF(col_norms_list);

    return result_dict;
}

const matrix_svd_doc =
    \\Compute Singular Value Decomposition (SVD).
    \\
    \\Computes A = U × Σ × V^T where U and V are orthogonal matrices
    \\and Σ is a diagonal matrix of singular values.
    \\
    \\## Parameters
    \\- `full_matrices` (bool, optional): If True, U is m×m; if False, U is m×n (default: True)
    \\- `compute_uv` (bool, optional): If True, compute U and V; if False, only compute singular values (default: True)
    \\
    \\## Returns
    \\dict: Dictionary with keys:
    \\  - 'u': Left singular vectors (Matrix or None)
    \\  - 's': Singular values as column vector (Matrix)
    \\  - 'v': Right singular vectors (Matrix or None)
    \\  - 'converged': Convergence status (0 = success, k = failed at k-th value)
    \\
    \\## Raises
    \\ValueError: If rows < cols (matrix must be tall or square)
;

fn matrix_svd_method(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const Params = struct {
        full_matrices: c_int = 1,
        compute_uv: c_int = 1,
    };
    var params: Params = .{};
    python.parseArgs(Params, args, kwds, &params) catch return null;

    const ptr = python.unwrap(MatrixObject, "matrix_ptr", self_obj, "Matrix") orelse return null;

    if (ptr.rows < ptr.cols) {
        python.setValueError("Matrix must have rows >= cols for SVD", .{});
        return null;
    }

    const full_matrices_bool = params.full_matrices != 0;
    const compute_uv_bool = params.compute_uv != 0;

    const svd_options: Matrix(f64).SvdOptions = .{
        .with_u = compute_uv_bool,
        .with_v = compute_uv_bool,
        .mode = if (full_matrices_bool) .full_u else .skinny_u,
    };

    var svd_result = ptr.svd(allocator, svd_options) catch {
        python.setMemoryError("SVD computation");
        return null;
    };
    defer svd_result.deinit();

    // Create Python dictionary
    const result_dict = c.PyDict_New() orelse return null;

    // Add U matrix (or None)
    if (compute_uv_bool) {
        const u_obj = matrixToObject(svd_result.u.dupe(allocator) catch {
            c.Py_DECREF(result_dict);
            python.setMemoryError("Matrix copy");
            return null;
        });
        if (u_obj == null) {
            c.Py_DECREF(result_dict);
            return null;
        }
        _ = c.PyDict_SetItemString(result_dict, "u", u_obj);
        c.Py_DECREF(u_obj);
    } else {
        _ = c.PyDict_SetItemString(result_dict, "u", c.Py_None());
    }

    // Add S matrix (always computed)
    const s_obj = matrixToObject(svd_result.s.dupe(allocator) catch {
        c.Py_DECREF(result_dict);
        python.setMemoryError("Matrix copy");
        return null;
    });
    if (s_obj == null) {
        c.Py_DECREF(result_dict);
        return null;
    }
    _ = c.PyDict_SetItemString(result_dict, "s", s_obj);
    c.Py_DECREF(s_obj);

    // Add V matrix (or None)
    if (compute_uv_bool) {
        const v_obj = matrixToObject(svd_result.v.dupe(allocator) catch {
            c.Py_DECREF(result_dict);
            python.setMemoryError("Matrix copy");
            return null;
        });
        if (v_obj == null) {
            c.Py_DECREF(result_dict);
            return null;
        }
        _ = c.PyDict_SetItemString(result_dict, "v", v_obj);
        c.Py_DECREF(v_obj);
    } else {
        _ = c.PyDict_SetItemString(result_dict, "v", c.Py_None());
    }

    // Add convergence status
    const converged_obj = python.create(svd_result.converged) orelse {
        c.Py_DECREF(result_dict);
        return null;
    };
    _ = c.PyDict_SetItemString(result_dict, "converged", converged_obj);
    c.Py_DECREF(converged_obj);

    return result_dict;
}

// Metadata for stub generation
pub const matrix_methods_metadata = [_]stub_metadata.MethodWithMetadata{
    .{
        .name = "full",
        .meth = @ptrCast(&matrix_full),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = matrix_full_doc,
        .params = "cls, rows: int, cols: int, fill_value: float = 0.0",
        .returns = "Matrix",
    },
    .{
        .name = "from_numpy",
        .meth = @ptrCast(&matrix_from_numpy),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = matrix_from_numpy_doc,
        .params = "cls, array: NDArray[np.float64]",
        .returns = "Matrix",
    },
    .{
        .name = "identity",
        .meth = @ptrCast(&matrix_identity),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = matrix_identity_doc,
        .params = "cls, rows: int, cols: int",
        .returns = "Matrix",
    },
    .{
        .name = "zeros",
        .meth = @ptrCast(&matrix_zeros),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = matrix_zeros_doc,
        .params = "cls, rows: int, cols: int",
        .returns = "Matrix",
    },
    .{
        .name = "ones",
        .meth = @ptrCast(&matrix_ones),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = matrix_ones_doc,
        .params = "cls, rows: int, cols: int",
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
    .{
        .name = "transpose",
        .meth = @ptrCast(&matrix_transpose),
        .flags = c.METH_NOARGS,
        .doc = matrix_transpose_doc,
        .params = "self",
        .returns = "Matrix",
    },
    .{
        .name = "inverse",
        .meth = @ptrCast(&matrix_inverse),
        .flags = c.METH_NOARGS,
        .doc = matrix_inverse_doc,
        .params = "self",
        .returns = "Matrix",
    },
    .{
        .name = "dot",
        .meth = @ptrCast(&matrix_dot_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_dot_doc,
        .params = "self, other: Matrix",
        .returns = "Matrix",
    },
    .{
        .name = "sum",
        .meth = @ptrCast(&matrix_sum_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_sum_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "mean",
        .meth = @ptrCast(&matrix_mean_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_mean_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "min",
        .meth = @ptrCast(&matrix_min_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_min_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "max",
        .meth = @ptrCast(&matrix_max_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_max_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "trace",
        .meth = @ptrCast(&matrix_trace_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_trace_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "copy",
        .meth = @ptrCast(&matrix_copy_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_copy_doc,
        .params = "self",
        .returns = "Matrix",
    },
    .{
        .name = "determinant",
        .meth = @ptrCast(&matrix_determinant_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_determinant_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "gram",
        .meth = @ptrCast(&matrix_gram_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_gram_doc,
        .params = "self",
        .returns = "Matrix",
    },
    .{
        .name = "covariance",
        .meth = @ptrCast(&matrix_covariance_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_covariance_doc,
        .params = "self",
        .returns = "Matrix",
    },
    .{
        .name = "frobenius_norm",
        .meth = @ptrCast(&matrix_frobenius_norm_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_frobenius_norm_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "l1_norm",
        .meth = @ptrCast(&matrix_l1_norm_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_l1_norm_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "max_norm",
        .meth = @ptrCast(&matrix_max_norm_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_max_norm_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "element_norm",
        .meth = @ptrCast(&matrix_element_norm_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_element_norm_doc,
        .params = "self, p: float = 2",
        .returns = "float",
    },
    .{
        .name = "schatten_norm",
        .meth = @ptrCast(&matrix_schatten_norm_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_schatten_norm_doc,
        .params = "self, p: float = 2",
        .returns = "float",
    },
    .{
        .name = "induced_norm",
        .meth = @ptrCast(&matrix_induced_norm_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_induced_norm_doc,
        .params = "self, p: float = 2",
        .returns = "float",
    },
    .{
        .name = "nuclear_norm",
        .meth = @ptrCast(&matrix_nuclear_norm_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_nuclear_norm_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "spectral_norm",
        .meth = @ptrCast(&matrix_spectral_norm_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_spectral_norm_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "variance",
        .meth = @ptrCast(&matrix_variance_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_variance_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "std",
        .meth = @ptrCast(&matrix_std_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_std_doc,
        .params = "self",
        .returns = "float",
    },
    .{
        .name = "pow",
        .meth = @ptrCast(&matrix_pow_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_pow_doc,
        .params = "self, n: float",
        .returns = "Matrix",
    },
    .{
        .name = "row",
        .meth = @ptrCast(&matrix_row_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_row_doc,
        .params = "self, idx: int",
        .returns = "Matrix",
    },
    .{
        .name = "col",
        .meth = @ptrCast(&matrix_col_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_col_doc,
        .params = "self, idx: int",
        .returns = "Matrix",
    },
    .{
        .name = "submatrix",
        .meth = @ptrCast(&matrix_submatrix_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_submatrix_doc,
        .params = "self, row_start: int, col_start: int, row_count: int, col_count: int",
        .returns = "Matrix",
    },
    .{
        .name = "random",
        .meth = @ptrCast(&matrix_random),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS | c.METH_CLASS,
        .doc = matrix_random_doc,
        .params = "cls, rows: int, cols: int, seed: int | None = None",
        .returns = "Matrix",
    },
    .{
        .name = "rank",
        .meth = @ptrCast(&matrix_rank_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_rank_doc,
        .params = "self",
        .returns = "int",
    },
    .{
        .name = "pinv",
        .meth = @ptrCast(&matrix_pinv_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_pinv_doc,
        .params = "self, tolerance: float | None = None",
        .returns = "Matrix",
    },
    .{
        .name = "lu",
        .meth = @ptrCast(&matrix_lu_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_lu_doc,
        .params = "self",
        .returns = "dict",
    },
    .{
        .name = "qr",
        .meth = @ptrCast(&matrix_qr_method),
        .flags = c.METH_NOARGS,
        .doc = matrix_qr_doc,
        .params = "self",
        .returns = "dict",
    },
    .{
        .name = "svd",
        .meth = @ptrCast(&matrix_svd_method),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = matrix_svd_doc,
        .params = "self, full_matrices: bool = True, compute_uv: bool = True",
        .returns = "dict",
    },
};

var matrix_methods = stub_metadata.toPyMethodDefArray(&matrix_methods_metadata);

fn matrix_T_getter(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    return matrix_transpose(self_obj, null);
}

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
        .get = @ptrCast(@alignCast(python.getterStaticString("float64"))),
        .set = null,
        .doc = "Data type (always 'float64')",
        .type = "str",
    },
    .{
        .name = "T",
        .get = matrix_T_getter,
        .set = null,
        .doc = "Transpose of the matrix (read-only property)",
        .type = "Matrix",
    },
};

var matrix_getset = stub_metadata.toPyGetSetDefArray(&matrix_properties_metadata);

pub const matrix_special_methods_metadata = [_]stub_metadata.MethodInfo{
    .{
        .name = "__init__",
        .params = "self, data: list[list[float]]",
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
    .{
        .name = "__add__",
        .params = "self, other: Matrix | float",
        .returns = "Matrix",
        .doc = "Element-wise addition or scalar offset",
    },
    .{
        .name = "__radd__",
        .params = "self, other: float",
        .returns = "Matrix",
        .doc = "Reverse addition (scalar + matrix)",
    },
    .{
        .name = "__sub__",
        .params = "self, other: Matrix | float",
        .returns = "Matrix",
        .doc = "Element-wise subtraction or scalar offset",
    },
    .{
        .name = "__rsub__",
        .params = "self, other: float",
        .returns = "Matrix",
        .doc = "Reverse subtraction (scalar - matrix)",
    },
    .{
        .name = "__mul__",
        .params = "self, other: Matrix | float",
        .returns = "Matrix",
        .doc = "Element-wise multiplication or scalar multiplication",
    },
    .{
        .name = "__rmul__",
        .params = "self, other: float",
        .returns = "Matrix",
        .doc = "Reverse multiplication (scalar * matrix)",
    },
    .{
        .name = "__truediv__",
        .params = "self, other: float",
        .returns = "Matrix",
        .doc = "Scalar division",
    },
    .{
        .name = "__matmul__",
        .params = "self, other: Matrix",
        .returns = "Matrix",
        .doc = "Matrix multiplication",
    },
    .{
        .name = "__neg__",
        .params = "self",
        .returns = "Matrix",
        .doc = "Unary negation",
    },
};

// Using buildTypeObject helper for cleaner initialization
pub var MatrixType = python.buildTypeObject(.{
    .name = "zignal.Matrix",
    .basicsize = @sizeOf(MatrixObject),
    .doc = matrix_class_doc,
    .methods = @ptrCast(&matrix_methods),
    .getset = @ptrCast(&matrix_getset),
    .init = matrix_init,
    .new = matrix_new,
    .dealloc = matrix_dealloc,
    .repr = matrix_repr,
    .str = matrix_str,
    .as_mapping = &matrix_as_mapping,
    .as_number = &matrix_as_number,
});

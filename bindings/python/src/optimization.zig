const std = @import("std");

const zignal = @import("zignal");
const Matrix = zignal.Matrix;
const optimization = zignal.optimization;

const py_utils = @import("py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

const matrix_module = @import("matrix.zig");
const MatrixObject = matrix_module.MatrixObject;

// ============================================================================
// OPTIMIZATION POLICY ENUM
// ============================================================================

pub const optimization_policy_doc =
    \\Optimization policy for assignment problems.
    \\
    \\Determines whether to minimize or maximize the total cost.
;

var OptimizationPolicyType: c.PyTypeObject = undefined;

pub fn registerOptimizationPolicy(module: *c.PyObject) !void {
    // Create enum module
    const enum_module = c.PyImport_ImportModule("enum") orelse return error.ImportFailed;
    defer c.Py_DECREF(enum_module);

    // Get IntEnum class
    const int_enum = c.PyObject_GetAttrString(enum_module, "IntEnum") orelse return error.GetAttrFailed;
    defer c.Py_DECREF(int_enum);

    // Create enum values dict
    const values = c.PyDict_New() orelse return error.DictCreationFailed;
    defer c.Py_DECREF(values);

    // Add MIN = 0
    const min_val = c.PyLong_FromLong(@intFromEnum(optimization.OptimizationPolicy.min));
    if (min_val == null) return error.ValueCreationFailed;
    defer c.Py_DECREF(min_val);
    if (c.PyDict_SetItemString(values, "MIN", min_val) < 0) return error.DictSetFailed;

    // Add MAX = 1
    const max_val = c.PyLong_FromLong(@intFromEnum(optimization.OptimizationPolicy.max));
    if (max_val == null) return error.ValueCreationFailed;
    defer c.Py_DECREF(max_val);
    if (c.PyDict_SetItemString(values, "MAX", max_val) < 0) return error.DictSetFailed;

    // Create tuple for enum class creation
    const args = c.PyTuple_Pack(2, c.PyUnicode_FromString("OptimizationPolicy"), values) orelse return error.TupleCreationFailed;
    defer c.Py_DECREF(args);

    // Create the enum class
    const optimization_policy = c.PyObject_CallObject(int_enum, args) orelse return error.CallFailed;
    defer c.Py_DECREF(optimization_policy);

    // Set docstring
    const doc_str = c.PyUnicode_FromString(optimization_policy_doc);
    if (doc_str != null) {
        _ = c.PyObject_SetAttrString(optimization_policy, "__doc__", doc_str);
        c.Py_DECREF(doc_str);
    }

    // Add to module
    c.Py_INCREF(optimization_policy);
    if (c.PyModule_AddObject(module, "OptimizationPolicy", optimization_policy) < 0) {
        c.Py_DECREF(optimization_policy);
        return error.ModuleAddFailed;
    }

    // Store the type for later use
    OptimizationPolicyType = @as(*c.PyTypeObject, @ptrCast(optimization_policy)).*;
}

// ============================================================================
// ASSIGNMENT TYPE
// ============================================================================

const assignment_doc =
    \\Result of solving an assignment problem.
    \\
    \\Contains the optimal assignments and total cost.
    \\
    \\## Attributes
    \\- `assignments`: List of column indices for each row (None if unassigned)
    \\- `total_cost`: Total cost of the assignment
;

pub const AssignmentObject = extern struct {
    ob_base: c.PyObject,
    assignment_ptr: ?*optimization.Assignment,
};

fn assignment_new(type_obj: ?*c.PyTypeObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    _ = kwds;

    const self = @as(?*AssignmentObject, @ptrCast(c.PyType_GenericAlloc(type_obj, 0)));
    if (self) |obj| {
        obj.assignment_ptr = null;
    }
    return @as(?*c.PyObject, @ptrCast(self));
}

fn assignment_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;
    // Assignment objects are created internally, not by users
    c.PyErr_SetString(c.PyExc_TypeError, "Assignment objects cannot be created directly");
    return -1;
}

fn assignment_dealloc(self_obj: ?*c.PyObject) callconv(.c) void {
    const self = @as(*AssignmentObject, @ptrCast(self_obj.?));

    // Free the assignment if we have one
    if (self.assignment_ptr) |ptr| {
        ptr.deinit();
        allocator.destroy(ptr);
    }

    c.Py_TYPE(self_obj).*.tp_free.?(self_obj);
}

fn assignment_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*AssignmentObject, @ptrCast(self_obj.?));

    if (self.assignment_ptr) |ptr| {
        var buffer: [256]u8 = undefined;
        const slice = std.fmt.bufPrintZ(&buffer, "Assignment(assignments={} items, total_cost={d:.2})", .{ ptr.assignments.len, ptr.total_cost }) catch {
            return c.PyUnicode_FromString("Assignment(error formatting)");
        };
        return c.PyUnicode_FromString(slice.ptr);
    }

    return c.PyUnicode_FromString("Assignment(uninitialized)");
}

// Property getters
fn assignment_get_assignments(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*AssignmentObject, @ptrCast(self_obj.?));

    if (self.assignment_ptr) |ptr| {
        // Create a Python list
        const list = c.PyList_New(@intCast(ptr.assignments.len));
        if (list == null) return null;

        for (ptr.assignments, 0..) |assignment, i| {
            const item = if (assignment) |col|
                c.PyLong_FromLong(@intCast(col))
            else
                py_utils.getPyNone();

            if (item == null) {
                c.Py_DECREF(list);
                return null;
            }
            // PyList_SetItem steals the reference
            _ = c.PyList_SetItem(list, @intCast(i), item);
        }

        return list;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Assignment not initialized");
    return null;
}

fn assignment_get_total_cost(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = @as(*AssignmentObject, @ptrCast(self_obj.?));

    if (self.assignment_ptr) |ptr| {
        return c.PyFloat_FromDouble(ptr.total_cost);
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Assignment not initialized");
    return null;
}

// Property definitions
var assignment_getset = [_]c.PyGetSetDef{
    .{
        .name = "assignments",
        .get = assignment_get_assignments,
        .set = null,
        .doc = "List of column indices for each row (None if unassigned)",
        .closure = null,
    },
    .{
        .name = "total_cost",
        .get = assignment_get_total_cost,
        .set = null,
        .doc = "Total cost of the assignment",
        .closure = null,
    },
    .{ .name = null, .get = null, .set = null, .doc = null, .closure = null },
};

pub var AssignmentType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Assignment",
    .tp_basicsize = @sizeOf(AssignmentObject),
    .tp_dealloc = assignment_dealloc,
    .tp_repr = assignment_repr,
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = assignment_doc,
    .tp_getset = &assignment_getset,
    .tp_init = assignment_init,
    .tp_new = assignment_new,
};

// ============================================================================
// MODULE FUNCTIONS
// ============================================================================

const solve_assignment_problem_doc =
    \\Solve the assignment problem using the Hungarian algorithm.
    \\
    \\Finds the optimal one-to-one assignment that minimizes or maximizes
    \\the total cost in O(n³) time. Handles both square and rectangular matrices.
    \\
    \\## Parameters
    \\- `cost_matrix` (`Matrix`): Cost matrix where element (i,j) is the cost of assigning row i to column j
    \\- `policy` (`OptimizationPolicy`): Whether to minimize or maximize total cost (default: MIN)
    \\
    \\## Returns
    \\`Assignment`: Object containing the optimal assignments and total cost
    \\
    \\## Examples
    \\```python
    \\from zignal import Matrix, OptimizationPolicy, solve_assignment_problem
    \\
    \\matrix = Matrix([[1, 2, 6], [5, 3, 6], [4, 5, 0]])
    \\
    \\for p in [OptimizationPolicy.MIN, OptimizationPolicy.MAX]:
    \\    result = solve_assignment_problem(matrix, p)
    \\    print("minimum cost") if p == OptimizationPolicy.MIN else print("maximum profit")
    \\    print(f"  - Total cost:  {result.total_cost}")
    \\    print(f"  - Assignments: {result.assignments}")
    \\```
;

fn solve_assignment_problem(self: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;

    // Parse arguments
    var matrix_obj: ?*c.PyObject = null;
    var policy_obj: ?*c.PyObject = null;

    const kwlist = [_:null]?[*:0]const u8{ "cost_matrix", "policy", null };
    const format = std.fmt.comptimePrint("O|O:solve_assignment_problem", .{});

    // TODO: remove @constCast when we don't use Python < 3.13
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(@constCast(&kwlist)), &matrix_obj, &policy_obj) == 0) {
        return null;
    }

    // Check matrix type
    const matrix_type_obj = @as(*c.PyObject, @ptrCast(&matrix_module.MatrixType));
    if (c.PyObject_IsInstance(matrix_obj, matrix_type_obj) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "cost_matrix must be a Matrix object");
        return null;
    }

    const matrix = @as(*MatrixObject, @ptrCast(matrix_obj.?));
    if (matrix.matrix_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Matrix is not initialized");
        return null;
    }

    // Parse policy (default to MIN)
    var policy = optimization.OptimizationPolicy.min;
    if (policy_obj != null) {
        // Get the integer value from the enum
        const value = c.PyLong_AsLong(policy_obj);
        if (value == -1 and c.PyErr_Occurred() != null) {
            // Not an integer, check if it has a 'value' attribute (enum)
            c.PyErr_Clear();
            const value_attr = c.PyObject_GetAttrString(policy_obj, "value");
            if (value_attr == null) {
                c.PyErr_SetString(c.PyExc_TypeError, "policy must be an OptimizationPolicy enum value");
                return null;
            }
            defer c.Py_DECREF(value_attr);

            const enum_value = c.PyLong_AsLong(value_attr);
            if (enum_value == -1 and c.PyErr_Occurred() != null) {
                return null;
            }
            policy = switch (enum_value) {
                0 => optimization.OptimizationPolicy.min,
                1 => optimization.OptimizationPolicy.max,
                else => {
                    c.PyErr_SetString(c.PyExc_ValueError, "Invalid OptimizationPolicy value");
                    return null;
                },
            };
        } else {
            policy = switch (value) {
                0 => optimization.OptimizationPolicy.min,
                1 => optimization.OptimizationPolicy.max,
                else => {
                    c.PyErr_SetString(c.PyExc_ValueError, "Invalid OptimizationPolicy value");
                    return null;
                },
            };
        }
    }

    // Solve the assignment problem
    const result = optimization.solveAssignmentProblem(
        f64,
        allocator,
        matrix.matrix_ptr.?.*,
        policy,
    ) catch |err| {
        const err_msg = switch (err) {
            error.OutOfMemory => "Out of memory",
        };
        c.PyErr_SetString(c.PyExc_RuntimeError, err_msg);
        return null;
    };

    // Create Assignment Python object
    const assignment_obj = AssignmentType.tp_new.?(&AssignmentType, null, null);
    if (assignment_obj == null) {
        var temp_result = result;
        temp_result.deinit();
        return null;
    }

    const assignment = @as(*AssignmentObject, @ptrCast(assignment_obj));

    // Allocate and store the result
    assignment.assignment_ptr = allocator.create(optimization.Assignment) catch {
        c.Py_DECREF(assignment_obj);
        var temp_result = result;
        temp_result.deinit();
        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate Assignment");
        return null;
    };
    assignment.assignment_ptr.?.* = result;

    return assignment_obj;
}

// Assignment metadata for stub generation
pub const assignment_properties_metadata = [_]stub_metadata.PropertyWithMetadata{
    .{
        .name = "assignments",
        .get = @ptrCast(&assignment_get_assignments),
        .set = null,
        .doc = "List of column indices for each row (None if unassigned)",
        .type = "list[int|None]",
    },
    .{
        .name = "total_cost",
        .get = @ptrCast(&assignment_get_total_cost),
        .set = null,
        .doc = "Total cost of the assignment",
        .type = "float",
    },
};

// Module function definitions
pub const module_functions_metadata = [_]stub_metadata.FunctionWithMetadata{
    .{
        .name = "solve_assignment_problem",
        .meth = @ptrCast(&solve_assignment_problem),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = solve_assignment_problem_doc,
        .params = "cost_matrix: Matrix, policy: OptimizationPolicy = OptimizationPolicy.MIN",
        .returns = "Assignment",
    },
};

// Generate PyMethodDef array at compile time
pub var optimization_methods = stub_metadata.functionsToPyMethodDefArray(&module_functions_metadata);

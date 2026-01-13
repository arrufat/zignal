const std = @import("std");

const zignal = @import("zignal");
const optimization = zignal.optimization;

const enum_utils = @import("enum_utils.zig");
const matrix_module = @import("matrix.zig");
const MatrixObject = matrix_module.MatrixObject;
const py_utils = @import("py_utils.zig");
const allocator = py_utils.ctx.allocator;
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

// ============================================================================
// OPTIMIZATION POLICY ENUM
// ============================================================================

pub const optimization_policy_doc =
    \\Optimization policy for assignment problems.
    \\
    \\Determines whether to minimize or maximize the total cost.
;

// No runtime wrapper; OptimizationPolicy is registered via enum_utils.registerEnum in main

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

// Using genericNew helper for standard object creation
const assignment_new = py_utils.genericNew(AssignmentObject);

fn assignment_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;
    // Assignment objects are created internally, not by users
    py_utils.setTypeError("Assignment objects (internal only)", null);
    return -1;
}

// Helper function for custom cleanup
fn assignmentDeinit(self: *AssignmentObject) void {
    if (self.assignment_ptr) |ptr| {
        ptr.deinit();
        allocator.destroy(ptr);
    }
}

// Using genericDealloc helper
const assignment_dealloc = py_utils.genericDealloc(AssignmentObject, assignmentDeinit);

fn assignment_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(AssignmentObject, self_obj);

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
    const self = py_utils.safeCast(AssignmentObject, self_obj);

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

    py_utils.setValueError("Assignment not initialized", .{});
    return null;
}

fn assignment_get_total_cost(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = py_utils.safeCast(AssignmentObject, self_obj);

    if (self.assignment_ptr) |ptr| {
        return c.PyFloat_FromDouble(ptr.total_cost);
    }

    py_utils.setValueError("Assignment not initialized", .{});
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

pub var AssignmentType = py_utils.buildTypeObject(.{
    .name = "zignal.Assignment",
    .basicsize = @sizeOf(AssignmentObject),
    .doc = assignment_doc,
    .getset = &assignment_getset,
    .new = assignment_new,
    .init = assignment_init,
    .dealloc = assignment_dealloc,
    .repr = assignment_repr,
});

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
    const Params = struct {
        cost_matrix: ?*c.PyObject,
        policy: ?*c.PyObject = null, // Optional with default
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;
    const matrix_obj = params.cost_matrix;
    const policy_obj = params.policy;

    // Check matrix type
    const matrix_mod = @import("matrix.zig");
    // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
    const matrix_type_obj: *c.PyObject = @ptrCast(&matrix_mod.MatrixType);
    if (c.PyObject_IsInstance(matrix_obj, matrix_type_obj) != 1) {
        py_utils.setTypeError("Matrix object", matrix_obj);
        return null;
    }

    const matrix = py_utils.safeCast(MatrixObject, matrix_obj);
    if (matrix.matrix_ptr == null) {
        py_utils.setValueError("Matrix is not initialized", .{});
        return null;
    }

    // Parse policy (default to MIN)
    var policy = optimization.OptimizationPolicy.min;
    if (policy_obj != null) {
        policy = enum_utils.pyToEnum(optimization.OptimizationPolicy, policy_obj.?) catch return null;
    }

    // Solve the assignment problem
    const result = optimization.solveAssignmentProblem(
        f64,
        allocator,
        matrix.matrix_ptr.?.*,
        policy,
    ) catch |err| {
        py_utils.setZigError(err);
        return null;
    };

    // Create Assignment Python object
    const assignment_obj = AssignmentType.tp_new.?(&AssignmentType, null, null);
    if (assignment_obj == null) {
        var temp_result = result;
        temp_result.deinit();
        return null;
    }

    const assignment = py_utils.safeCast(AssignmentObject, assignment_obj);

    // Allocate and store the result
    assignment.assignment_ptr = allocator.create(optimization.Assignment) catch {
        c.Py_DECREF(assignment_obj);
        var temp_result = result;
        temp_result.deinit();
        py_utils.setMemoryError("Assignment");
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

const std = @import("std");

const zignal = @import("zignal");
const optimization = zignal.optimization;

const enum_utils = @import("enum_utils.zig");
const matrix_module = @import("matrix.zig");
const MatrixObject = matrix_module.MatrixObject;
const python = @import("python.zig");
const allocator = python.ctx.allocator;
const c = python.c;

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
const assignment_new = python.genericNew(AssignmentObject);

fn assignment_init(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) c_int {
    _ = self_obj;
    _ = args;
    _ = kwds;
    // Assignment objects are created internally, not by users
    python.setTypeError("Assignment objects (internal only)", null);
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
const assignment_dealloc = python.genericDealloc(AssignmentObject, assignmentDeinit);

fn assignment_repr(self_obj: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = python.safeCast(AssignmentObject, self_obj);

    if (self.assignment_ptr) |ptr| {
        var buffer: [256]u8 = undefined;
        const slice = std.fmt.bufPrintSentinel(&buffer, "Assignment(assignments={} items, total_cost={d:.2})", .{ ptr.assignments.len, ptr.total_cost }, 0) catch {
            return python.create("Assignment(error formatting)");
        };
        return python.create(slice);
    }

    return python.create("Assignment(uninitialized)");
}

// Property getters
fn assignment_get_assignments(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(AssignmentObject, self_obj);

    if (self.assignment_ptr) |ptr| {
        // Create a Python list
        const list = c.PyList_New(@intCast(ptr.assignments.len));
        if (list == null) return null;

        for (ptr.assignments, 0..) |assignment, i| {
            const item = if (assignment) |col|
                python.create(col)
            else
                python.none();

            if (item == null) {
                c.Py_DecRef(list);
                return null;
            }
            // PyList_SetItem steals the reference
            _ = c.PyList_SetItem(list, @intCast(i), item);
        }

        return list;
    }

    python.setValueError("Assignment not initialized", .{});
    return null;
}

fn assignment_get_total_cost(self_obj: ?*c.PyObject, closure: ?*anyopaque) callconv(.c) ?*c.PyObject {
    _ = closure;
    const self = python.safeCast(AssignmentObject, self_obj);

    if (self.assignment_ptr) |ptr| {
        return python.create(ptr.total_cost);
    }

    python.setValueError("Assignment not initialized", .{});
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

pub var AssignmentType = python.buildTypeObject(.{
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
    python.parseArgs(Params, args, kwds, &params) catch return null;
    const matrix_obj = params.cost_matrix;
    const policy_obj = params.policy;

    // Check matrix type
    const matrix_mod = @import("matrix.zig");
    // TODO(py3.10): drop explicit cast once minimum Python >= 3.11
    const matrix_type_obj: *c.PyObject = @ptrCast(&matrix_mod.MatrixType);
    if (c.PyObject_IsInstance(matrix_obj, matrix_type_obj) != 1) {
        python.setTypeError("Matrix object", matrix_obj);
        return null;
    }

    const matrix = python.safeCast(MatrixObject, matrix_obj);
    if (matrix.matrix_ptr == null) {
        python.setValueError("Matrix is not initialized", .{});
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
        python.setZigError(err);
        return null;
    };

    // Create Assignment Python object
    const assignment_obj = AssignmentType.tp_new.?(&AssignmentType, null, null);
    if (assignment_obj == null) {
        var temp_result = result;
        temp_result.deinit();
        return null;
    }

    const assignment = python.safeCast(AssignmentObject, assignment_obj);

    // Allocate and store the result
    assignment.assignment_ptr = allocator.create(optimization.Assignment) catch {
        c.Py_DecRef(assignment_obj);
        var temp_result = result;
        temp_result.deinit();
        python.setMemoryError("Assignment");
        return null;
    };
    assignment.assignment_ptr.?.* = result;

    return assignment_obj;
}

// ----------------------------------------------------------------------------
// GLOBAL OPTIMIZER (MaxLIPO + Trust Region)
// ----------------------------------------------------------------------------

const optimize_doc =
    \\Find the global optimum of a function over bounded variables (MaxLIPO + Trust Region).
    \\
    \\Derivative-free, bound-constrained global optimization. The objective is sampled at points
    \\chosen to balance global exploration (a Lipschitz upper bound) and local exploitation
    \\(trust-region quadratic fits), so it works on multimodal, non-smooth, black-box functions.
    \\
    \\## Parameters
    \\- `objective` (`Callable[[list[float]], float]`): Function to optimize. Receives one list of
    \\  coordinates (one per dimension) and returns a finite float.
    \\- `bounds` (`list[tuple[float, float]]`): Inclusive `(lower, upper)` box for each variable.
    \\  Its length sets the dimensionality.
    \\- `max_evals` (`int`): Budget — maximum number of objective evaluations.
    \\- `policy` (`OptimizationPolicy`): Whether to minimize or maximize (default: MIN).
    \\- `is_integer` (`list[bool] | None`): Per-variable integer constraint; if given it must match
    \\  the length of `bounds`, and integer dimensions require integral bounds (default: all continuous).
    \\- `seed` (`int`): PRNG seed for reproducibility (default: 0).
    \\- `target` (`float | None`): Stop early once the best value reaches this threshold — `<= target`
    \\  when minimizing, `>= target` when maximizing (default: no target).
    \\- `patience` (`int | None`): Stop early after this many consecutive evaluations without
    \\  improvement (default: disabled).
    \\- `pure_random_probability` (`float`): Probability of a uniform random step instead of a
    \\  MaxLIPO step, in `[0, 1]` (default: 0.02).
    \\- `num_random_samples` (`int`): Candidates drawn when maximizing the Lipschitz upper bound each
    \\  exploration step (default: 5000).
    \\- `trust_region_eps` (`float`): Minimum model-predicted improvement required to take a
    \\  trust-region (exploit) step (default: 0.0).
    \\- `relative_noise_magnitude` (`float`): Noise term of the Lipschitz surrogate (default: 0.001).
    \\- `solver_eps` (`float`): Tolerance of the surrogate's quadratic-program solver (default: 1e-4).
    \\
    \\## Returns
    \\`tuple[list[float], float]`: The best point found and its objective value `(x, y)`.
    \\
    \\## Raises
    \\- `ValueError`: Invalid bounds (`lower >= upper`), non-integral bounds for an integer variable,
    \\  mismatched `is_integer` length, or a non-positive `max_evals`.
    \\- `TypeError`: `objective` is not callable, or `bounds` is malformed.
    \\- Any exception raised by `objective` propagates out unchanged.
    \\
    \\## Examples
    \\```python
    \\from zignal import optimize, OptimizationPolicy
    \\
    \\# Minimize a 2-D bowl; optimum at (1, -2).
    \\x, y = optimize(lambda v: (v[0] - 1) ** 2 + (v[1] + 2) ** 2,
    \\                bounds=[(-5, 5), (-5, 5)], max_evals=150)
    \\print(x, y)  # ~[1.0, -2.0]  ~0.0
    \\
    \\# Maximize, with one integer variable and an early-stop target.
    \\x, y = optimize(score, bounds=[(0, 10), (-1, 1)], max_evals=200,
    \\                policy=OptimizationPolicy.MAX, is_integer=[True, False], target=0.99)
    \\```
;

/// Adapts a Python callable to the Zig optimizer's objective interface. The optimizer's objective
/// returns a bare `f64` with no error channel, so a failed Python call is captured here (first
/// exception wins, stashed via `PyErr_Fetch`) and replayed by the caller after the run.
const PyObjective = struct {
    callable: *c.PyObject,
    failed: bool = false,
    err_type: ?*c.PyObject = null,
    err_value: ?*c.PyObject = null,
    err_tb: ?*c.PyObject = null,

    /// Called by GlobalOptimizer for each candidate point. The GIL is held throughout (sequential
    /// path on the calling thread), so no GIL management is needed.
    pub fn evaluate(self: *PyObjective, x: []const f64) f64 {
        if (self.failed) return 0;
        const list = python.listFromSlice(f64, x) orelse return self.fail();
        defer c.Py_DecRef(list);
        const args = c.PyTuple_Pack(1, list) orelse return self.fail();
        defer c.Py_DecRef(args);
        const ret = c.PyObject_CallObject(self.callable, args) orelse return self.fail();
        defer c.Py_DecRef(ret);
        const y = c.PyFloat_AsDouble(ret);
        if (y == -1.0 and c.PyErr_Occurred() != null) return self.fail();
        return y;
    }

    fn fail(self: *PyObjective) f64 {
        if (!self.failed) {
            self.failed = true;
            if (c.PyErr_Occurred() == null) {
                c.PyErr_SetString(c.PyExc_RuntimeError, "objective evaluation failed");
            }
            c.PyErr_Fetch(&self.err_type, &self.err_value, &self.err_tb);
        }
        return 0;
    }
};

fn mapGlobalError(err: anyerror) void {
    switch (err) {
        error.InvalidBounds => python.setValueError("each bound must satisfy lower < upper", .{}),
        error.NonIntegralBound => python.setValueError("integer dimensions require integral bounds", .{}),
        error.DimensionMismatch => python.setValueError("bounds dimension mismatch", .{}),
        else => python.setZigError(err),
    }
}

fn optimize(self: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;

    const Params = struct {
        objective: ?*c.PyObject,
        bounds: ?*c.PyObject,
        max_evals: c_long,
        policy: ?*c.PyObject = null,
        is_integer: ?*c.PyObject = null,
        seed: c_long = 0,
        target: ?*c.PyObject = null,
        patience: ?*c.PyObject = null,
        pure_random_probability: f64 = 0.02,
        num_random_samples: c_long = 5000,
        trust_region_eps: f64 = 0.0,
        relative_noise_magnitude: f64 = 0.001,
        solver_eps: f64 = 1e-4,
    };
    var params: Params = undefined;
    python.parseArgs(Params, args, kwds, &params) catch return null;

    // Objective must be callable.
    if (params.objective == null or c.PyCallable_Check(params.objective) == 0) {
        python.setTypeError("callable", params.objective);
        return null;
    }

    // Scalars (validated; the range checks also guard the @intCast into the Zig structs).
    const max_evals = python.validatePositive(usize, params.max_evals, "max_evals") catch return null;
    const seed = python.validateNonNegative(u64, params.seed, "seed") catch return null;
    const num_random_samples = python.validatePositive(usize, params.num_random_samples, "num_random_samples") catch return null;
    const pure_random_probability = python.validateRange(f64, params.pure_random_probability, 0.0, 1.0, "pure_random_probability") catch return null;
    const trust_region_eps = python.validateNonNegative(f64, params.trust_region_eps, "trust_region_eps") catch return null;
    const relative_noise_magnitude = python.validateNonNegative(f64, params.relative_noise_magnitude, "relative_noise_magnitude") catch return null;
    const solver_eps = python.validatePositive(f64, params.solver_eps, "solver_eps") catch return null;

    // Policy (default MIN).
    var policy = optimization.OptimizationPolicy.min;
    if (params.policy != null and params.policy != c.Py_None()) {
        policy = enum_utils.pyToEnum(optimization.OptimizationPolicy, params.policy.?) catch return null;
    }

    // Optional stop criteria.
    var target_opt: ?f64 = null;
    if (params.target != null and params.target != c.Py_None()) {
        target_opt = python.parse(f64, params.target.?) catch return null;
    }
    var patience_opt: ?usize = null;
    if (params.patience != null and params.patience != c.Py_None()) {
        const pv = python.parse(c_long, params.patience.?) catch return null;
        patience_opt = python.validatePositive(usize, pv, "patience") catch return null;
    }

    // Build the search space from bounds (+ optional per-dimension integer flags).
    const Variable = zignal.GlobalOptimizer.Variable;
    if (c.PySequence_Check(params.bounds) == 0) {
        python.setTypeError("sequence of (lower, upper) pairs", params.bounds);
        return null;
    }
    const n = c.PySequence_Size(params.bounds);
    if (n <= 0) {
        python.setValueError("bounds must contain at least one (lower, upper) pair", .{});
        return null;
    }
    var has_int = false;
    if (params.is_integer != null and params.is_integer != c.Py_None()) {
        if (c.PySequence_Check(params.is_integer) == 0) {
            python.setTypeError("sequence of bool", params.is_integer);
            return null;
        }
        if (c.PySequence_Size(params.is_integer) != n) {
            python.setValueError("is_integer must have the same length as bounds ({d})", .{n});
            return null;
        }
        has_int = true;
    }

    const dims = allocator.alloc(Variable, @intCast(n)) catch {
        python.setMemoryError("dimensions");
        return null;
    };
    defer allocator.free(dims);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const pair = c.PySequence_GetItem(params.bounds, @intCast(i)) orelse return null;
        defer c.Py_DecRef(pair);
        if (c.PySequence_Check(pair) == 0 or c.PySequence_Size(pair) != 2) {
            python.setValueError("bounds[{d}] must be a (lower, upper) pair", .{i});
            return null;
        }
        const lo_obj = c.PySequence_GetItem(pair, 0) orelse return null;
        defer c.Py_DecRef(lo_obj);
        const hi_obj = c.PySequence_GetItem(pair, 1) orelse return null;
        defer c.Py_DecRef(hi_obj);
        const lower = python.parse(f64, lo_obj) catch return null;
        const upper = python.parse(f64, hi_obj) catch return null;
        var is_int = false;
        if (has_int) {
            const b_obj = c.PySequence_GetItem(params.is_integer, @intCast(i)) orelse return null;
            defer c.Py_DecRef(b_obj);
            const t = c.PyObject_IsTrue(b_obj);
            if (t < 0) return null;
            is_int = t == 1;
        }
        dims[i] = .{ .lower = lower, .upper = upper, .is_integer = is_int };
    }

    // Initialize the optimizer.
    var opt = zignal.GlobalOptimizer.init(allocator, dims, .{
        .policy = policy,
        .seed = seed,
        .upper_bound = .{
            .relative_noise_magnitude = relative_noise_magnitude,
            .solver_eps = solver_eps,
        },
        .pure_random_probability = pure_random_probability,
        .num_random_samples = num_random_samples,
        .trust_region_eps = trust_region_eps,
    }) catch |err| {
        mapGlobalError(err);
        return null;
    };
    defer opt.deinit();

    // Drive the ask-tell loop here (instead of opt.optimize) so a Python exception in the objective
    // aborts immediately — opt.optimize would keep running expensive search steps to the budget
    // before surfacing the error. Stop semantics mirror GlobalOptimizer.shouldStop.
    var ctx = PyObjective{ .callable = params.objective.? };
    const target_internal: ?f64 = if (target_opt) |t| opt.sign * t else null;
    var prev_best: ?f64 = opt.best_y;
    var since_improve: usize = 0;
    while (opt.evals < max_evals) {
        const step_res = opt.step(&ctx);
        if (ctx.failed) {
            c.PyErr_Restore(ctx.err_type, ctx.err_value, ctx.err_tb);
            return null;
        }
        _ = step_res catch |err| {
            mapGlobalError(err);
            return null;
        };
        const cur = opt.best_y.?;
        if (target_internal) |t| {
            if (cur >= t) break;
        }
        if (patience_opt) |pat| {
            if (prev_best == null or cur > prev_best.?) {
                prev_best = cur;
                since_improve = 0;
            } else {
                since_improve += 1;
                if (since_improve >= pat) break;
            }
        }
    }

    // Return (best_x, best_y) as a plain tuple. PyTuple_Pack increfs its args, so drop our refs.
    const best = opt.best();
    const x_list = python.listFromSlice(f64, best.x) orelse return null;
    const y_obj = python.create(best.y) orelse {
        c.Py_DecRef(x_list);
        return null;
    };
    const result = c.PyTuple_Pack(2, x_list, y_obj);
    c.Py_DecRef(x_list);
    c.Py_DecRef(y_obj);
    return result;
}

// Assignment metadata for stub generation
pub const assignment_properties_metadata = [_]python.PropertyWithMetadata{
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
pub const module_functions_metadata = [_]python.FunctionWithMetadata{
    .{
        .name = "solve_assignment_problem",
        .meth = @ptrCast(&solve_assignment_problem),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = solve_assignment_problem_doc,
        .params = "cost_matrix: Matrix, policy: OptimizationPolicy = OptimizationPolicy.MIN",
        .returns = "Assignment",
    },
    .{
        .name = "optimize",
        .meth = @ptrCast(&optimize),
        .flags = c.METH_VARARGS | c.METH_KEYWORDS,
        .doc = optimize_doc,
        .params = "objective: Callable[[list[float]], float], bounds: list[tuple[float, float]], max_evals: int, policy: OptimizationPolicy = OptimizationPolicy.MIN, is_integer: list[bool] | None = None, seed: int = 0, target: float | None = None, patience: int | None = None, pure_random_probability: float = 0.02, num_random_samples: int = 5000, trust_region_eps: float = 0.0, relative_noise_magnitude: float = 0.001, solver_eps: float = 1e-4",
        .returns = "tuple[list[float], float]",
    },
};

// Generate PyMethodDef array at compile time
pub var optimization_methods = python.functionsToPyMethodDefArray(&module_functions_metadata);

//! Assignment problem solver (Hungarian / Kuhn-Munkres algorithm).
//!
//! Solves square and rectangular cost matrices under a `.min` or `.max` policy.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const as = @import("../meta.zig").as;
const Matrix = @import("../matrix.zig").Matrix;
const OptimizationPolicy = @import("../optimization.zig").OptimizationPolicy;

/// Result of the assignment problem
pub const Assignment = struct {
    /// assignments[i] = j means row i is assigned to column j
    /// null means row i has no assignment
    assignments: []?u32,
    /// Total cost of the assignment
    total_cost: f64,
    /// Allocator used for assignments array
    allocator: Allocator,

    pub fn deinit(self: *Assignment) void {
        self.allocator.free(self.assignments);
    }
};

/// Solves the assignment problem with the Hungarian (Kuhn-Munkres) algorithm in O(n³), handling
/// square and rectangular cost matrices and either a `.min` or `.max` policy.
pub fn solveAssignmentProblem(
    comptime T: type,
    allocator: Allocator,
    cost_matrix: Matrix(T),
    policy: OptimizationPolicy,
) !Assignment {
    const multiplier: i64 = switch (policy) {
        .min => 1,
        .max => -1,
    };
    const n_rows = cost_matrix.rows;
    const n_cols = cost_matrix.cols;
    const n = @max(n_rows, n_cols);

    if (n == 0) return .{
        .assignments = try allocator.alloc(?u32, n_rows),
        .total_cost = 0,
        .allocator = allocator,
    };

    var scale_factor: f64 = 1.0;
    var padding_value: i64 = 1;

    if (@typeInfo(T) == .float) {
        var max_abs: f64 = 0;
        var sum_abs: f64 = 0;
        for (cost_matrix.items) |val_raw| {
            const val = @abs(as(f64, val_raw));
            max_abs = @max(max_abs, val);
            sum_abs += val;
        }
        if (max_abs > 0) {
            // Scale floats to integers (~12 significant digits), but cap the total well under i64 max
            // so accumulated u/v potentials and padding_value can't overflow. `+ 1` guards num_elements == 0.
            const precision_range = 1e12;
            const max_total = 4e18;
            const num_elements: f64 = n_rows * n_cols;
            scale_factor = @min(precision_range, max_total / (num_elements + 1.0)) / max_abs;
        }
        padding_value = @as(i64, @ceil(sum_abs * scale_factor)) + 1;
    } else {
        var sum_abs: u64 = 0;
        for (cost_matrix.items) |val_raw| {
            sum_abs += @abs(@as(i64, val_raw));
        }
        padding_value = @intCast(sum_abs + 1);
    }

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const work = try aa.alloc(i64, n * n);
    const u = try aa.alloc(i64, n);
    const v = try aa.alloc(i64, n);
    const slack = try aa.alloc(i64, n);
    const row_assignment = try aa.alloc(?u32, n);
    const col_assignment = try aa.alloc(?u32, n);
    const slack_col = try aa.alloc(u32, n);
    const row_covered = try aa.alloc(bool, n);
    const col_covered = try aa.alloc(bool, n);

    const sign: f64 = @floatFromInt(multiplier);
    for (0..n) |i| {
        for (0..n) |j| {
            if (i < n_rows and j < n_cols) {
                const base_val = cost_matrix.at(i, j).*;
                work[i * n + j] = switch (@typeInfo(T)) {
                    .float => @round(as(f64, base_val) * sign * scale_factor),
                    .int => @as(i64, base_val) * multiplier,
                    else => @compileError("Unsupported type for cost matrix"),
                };
            } else {
                work[i * n + j] = padding_value;
            }
        }
    }
    for (0..n) |i| {
        const min_val = std.mem.min(i64, work[i * n ..][0..n]);
        if (min_val != 0) {
            for (0..n) |j| {
                work[i * n + j] -= min_val;
            }
        }
    }

    @memset(u, 0);
    @memset(v, 0);
    @memset(row_assignment, null);
    @memset(col_assignment, null);

    for (0..n) |r_start| {
        @memset(row_covered, false);
        @memset(col_covered, false);
        @memset(slack, std.math.maxInt(i64));

        var r = r_start;
        var c_min: usize = 0;

        while (true) {
            row_covered[r] = true;
            var delta: i64 = std.math.maxInt(i64);

            for (0..n) |c| {
                if (!col_covered[c]) {
                    const val = work[r * n + c] - u[r] - v[c];
                    if (val < slack[c]) {
                        slack[c] = val;
                        slack_col[c] = @intCast(r);
                    }
                    if (slack[c] < delta) {
                        delta = slack[c];
                        c_min = c;
                    }
                }
            }

            if (delta > 0) {
                for (0..n) |i| {
                    if (row_covered[i]) u[i] += delta;
                }
                for (0..n) |j| {
                    if (col_covered[j]) {
                        v[j] -= delta;
                    } else {
                        slack[j] -= delta;
                    }
                }
            }

            col_covered[c_min] = true;

            const match_r = col_assignment[c_min];
            if (match_r == null) {
                var curr_c = c_min;
                while (true) {
                    const parent_r = slack_col[curr_c];
                    const prev_c = row_assignment[parent_r];
                    col_assignment[curr_c] = parent_r;
                    row_assignment[parent_r] = @intCast(curr_c);
                    if (prev_c == null) break;
                    curr_c = prev_c.?;
                }
                break;
            } else {
                r = match_r.?;
            }
        }
    }

    // Calculate total cost and prepare result
    var total_cost: f64 = 0;
    var result_assignments = try allocator.alloc(?u32, n_rows);
    for (0..n_rows) |i| {
        result_assignments[i] = null;
        if (row_assignment[i]) |col| if (col < n_cols) {
            result_assignments[i] = col;
            // Use original cost matrix values (not the multiplied work matrix)
            total_cost += as(f64, cost_matrix.at(i, col).*);
        };
    }

    return .{
        .assignments = result_assignments,
        .total_cost = total_cost,
        .allocator = allocator,
    };
}

// Tests
test "Hungarian algorithm - simple 3x3" {
    const allocator = std.testing.allocator;

    // Create cost matrix
    var cost: Matrix(f32) = try .fromSlice(allocator, 3, 3, &.{
        1, 2, 3,
        2, 4, 6,
        3, 6, 9,
    });
    defer cost.deinit();

    var result = try solveAssignmentProblem(f32, allocator, cost, .min);
    defer result.deinit();

    // Optimal: row0->col2 (3), row1->col1 (4), row2->col0 (3), total=10
    try expectEqual(@as(u32, 3), result.assignments.len);
    try expectEqual(@as(f64, 10), result.total_cost);
}

test "Hungarian algorithm - integer matrix" {
    const allocator = std.testing.allocator;

    // Test with integer cost matrix
    var cost: Matrix(i32) = try .fromSlice(allocator, 3, 3, &.{
        10, 20, 30,
        15, 25, 35,
        20, 30, 40,
    });
    defer cost.deinit();

    var result = try solveAssignmentProblem(i32, allocator, cost, .min);
    defer result.deinit();

    // Verify we got valid assignments
    try expectEqual(@as(u32, 3), result.assignments.len);

    // Check that each row has an assignment
    for (result.assignments) |assignment| {
        try expectEqual(true, assignment != null);
    }

    // Optimal: row0->col0 (10), row1->col1 (25), row2->col2 (40), total=75
    try expectEqual(@as(f64, 75), result.total_cost);
}

test "Hungarian algorithm - rectangular matrix" {
    const allocator = std.testing.allocator;

    // 2x3 cost matrix
    var cost: Matrix(f32) = try .init(allocator, 2, 3);
    defer cost.deinit();

    cost.at(0, 0).* = 1;
    cost.at(0, 1).* = 2;
    cost.at(0, 2).* = 3;
    cost.at(1, 0).* = 4;
    cost.at(1, 1).* = 2;
    cost.at(1, 2).* = 1;

    var result = try solveAssignmentProblem(f32, allocator, cost, .min);
    defer result.deinit();

    try expectEqual(@as(u32, 2), result.assignments.len);
    // Optimal: row0->col0 (1), row1->col2 (1), total=2
    try expectEqual(@as(f64, 2), result.total_cost);
}

test "Hungarian algorithm - tiny costs keep relative scale" {
    const allocator = std.testing.allocator;

    // Costs ~1e-8: the old decimal-place scaling rounded them all to 0 and returned an arbitrary
    // (diagonal, total 14e-8) assignment. The true optimum is the anti-diagonal at total 10e-8.
    var cost: Matrix(f64) = try .init(allocator, 3, 3);
    defer cost.deinit();
    const base = [3][3]f64{ .{ 1, 2, 3 }, .{ 2, 4, 6 }, .{ 3, 6, 9 } };
    for (0..3) |i| for (0..3) |j| {
        cost.at(i, j).* = base[i][j] * 1e-8;
    };

    var result = try solveAssignmentProblem(f64, allocator, cost, .min);
    defer result.deinit();
    try expectEqual(@as(?u32, 2), result.assignments[0]);
    try expectEqual(@as(?u32, 1), result.assignments[1]);
    try expectEqual(@as(?u32, 0), result.assignments[2]);
    try expectApproxEqAbs(@as(f64, 10e-8), result.total_cost, 1e-15);
}

fn bruteForceAssignment(cost: Matrix(i32), n: usize, row: usize, used: *[8]bool, acc: i32, best: *i32, comptime is_max: bool) void {
    if (row == n) {
        best.* = if (is_max) @max(best.*, acc) else @min(best.*, acc);
        return;
    }
    for (0..n) |col| {
        if (used[col]) continue;
        used[col] = true;
        bruteForceAssignment(cost, n, row + 1, used, acc + cost.at(row, col).*, best, is_max);
        used[col] = false;
    }
}

test "Hungarian algorithm - matches brute force on random square matrices" {
    const allocator = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xA55E7);
    const rand = prng.random();
    for (1..7) |n| {
        var trial: usize = 0;
        while (trial < 30) : (trial += 1) {
            var cost = try Matrix(i32).init(allocator, @intCast(n), @intCast(n));
            defer cost.deinit();
            for (0..n) |i| for (0..n) |j| {
                cost.at(i, j).* = rand.intRangeAtMost(i32, 0, 50);
            };

            inline for (.{ false, true }) |is_max| {
                var used: [8]bool = @splat(false);
                var best: i32 = if (is_max) std.math.minInt(i32) else std.math.maxInt(i32);
                bruteForceAssignment(cost, n, 0, &used, 0, &best, is_max);

                var result = try solveAssignmentProblem(i32, allocator, cost, if (is_max) .max else .min);
                defer result.deinit();
                try expectEqual(@as(f64, @floatFromInt(best)), result.total_cost);
            }
        }
    }
}

test "Hungarian algorithm - empty matrix" {
    const allocator = std.testing.allocator;

    var cost: Matrix(f32) = try .init(allocator, 0, 0);
    defer cost.deinit();

    var result = try solveAssignmentProblem(f32, allocator, cost, .min);
    defer result.deinit();

    try expectEqual(@as(usize, 0), result.assignments.len);
    try expectEqual(@as(f64, 0), result.total_cost);
}

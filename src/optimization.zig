//! Optimization algorithms for solving various mathematical optimization problems
//!
//! This module provides implementations of classical optimization algorithms
//! including the Hungarian algorithm for assignment problems.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;

const as = @import("meta.zig").as;
const Matrix = @import("matrix.zig").Matrix;

/// Optimization policy for the assignment problem
pub const OptimizationPolicy = enum {
    /// Minimize total cost
    min,
    /// Maximize total cost (profit)
    max,
};

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

/// Find the optimal scale factor for converting float matrix to integers
/// by analyzing the decimal places in the data
fn findScaleFactor(comptime T: type, matrix: Matrix(T)) i32 {
    if (@typeInfo(T) != .float) return 1; // No scaling for integers

    var max_decimal_places: u8 = 0;
    for (0..matrix.rows) |i| {
        for (0..matrix.cols) |j| {
            const val = matrix.at(i, j).*;
            const decimal_places = countDecimalPlaces(val);
            max_decimal_places = @max(max_decimal_places, decimal_places);
        }
    }

    const capped_places = @min(max_decimal_places, 6); // Cap at 6 decimal places
    var scale: i32 = 1;
    for (0..capped_places) |_| scale *= 10;
    return scale;
}

/// Count the number of significant decimal places in a float
fn countDecimalPlaces(val: anytype) u8 {
    if (val == 0) return 0;

    const abs_val = @abs(val);
    var count: u8 = 0;
    var temp = abs_val - @floor(abs_val); // Remove integer part

    // Count decimal places (up to precision limits)
    while (temp > 0.000001 and count < 7) {
        temp = temp * 10 - @floor(temp * 10);
        count += 1;
    }

    return count;
}

/// Solves the assignment problem using the Hungarian algorithm (Kuhn-Munkres algorithm)
///
/// Finds the optimal one-to-one assignment that minimizes/maximizes total cost in O(n³) time.
/// This implementation handles both square and rectangular cost matrices.
///
/// @param T The numeric type of the cost matrix (int or float)
/// @param allocator Memory allocator for temporary data structures
/// @param cost_matrix Matrix where element (i,j) is the cost/profit of assigning row i to column j
/// @param policy Whether to minimize cost or maximize profit
/// @return Optimal assignment that minimizes/maximizes total cost
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

    const scale_factor = if (@typeInfo(T) == .float) findScaleFactor(T, cost_matrix) else 1;

    // Create square working matrix - pad with large values
    var work = try allocator.alloc(i64, n * n);
    defer allocator.free(work);

    // Find a large padding value (sum of all absolute values + 1)
    var padding_value: i64 = 1;
    for (0..n_rows) |i| {
        for (0..n_cols) |j| {
            const base_val = cost_matrix.at(i, j).*;
            const abs_val = @abs(as(f64, base_val));
            padding_value += @intFromFloat(@ceil(abs_val * @as(f64, @floatFromInt(scale_factor))));
        }
    }

    // Initialize work matrix - convert all types to i64 with appropriate scaling for floats
    for (0..n) |i| {
        for (0..n) |j| {
            if (i < n_rows and j < n_cols) {
                const base_val = cost_matrix.at(i, j).*;
                work[i * n + j] = switch (@typeInfo(T)) {
                    .float => blk: {
                        const val = base_val * @as(T, @floatFromInt(multiplier));
                        break :blk @intFromFloat(@round(val * @as(T, @floatFromInt(scale_factor))));
                    },
                    .int => @as(i64, base_val) * multiplier,
                    else => @compileError("Unsupported type for cost matrix"),
                };
            } else {
                work[i * n + j] = padding_value;
            }
        }
    }

    // Step 1: Row reduction - subtract row minimum from each row
    for (0..n) |i| {
        // Find minimum value in this row
        var min_val: i64 = work[i * n];
        for (0..n) |j| {
            min_val = @min(min_val, work[i * n + j]);
        }

        // Subtract minimum from all cells in the row
        if (min_val != 0) {
            for (0..n) |j| {
                work[i * n + j] -= min_val;
            }
        }
    }

    // Step 2: Column reduction - subtract column minimum from each column
    for (0..n) |j| {
        // Find minimum value in this column
        var min_val: i64 = work[j];
        for (0..n) |i| {
            min_val = @min(min_val, work[i * n + j]);
        }

        // Subtract minimum from all cells in the column
        if (min_val != 0) {
            for (0..n) |i| {
                work[i * n + j] -= min_val;
            }
        }
    }

    // Arrays for tracking assignments and coverings
    var row_assignment = try allocator.alloc(?u32, n);
    defer allocator.free(row_assignment);
    var col_assignment = try allocator.alloc(?u32, n);
    defer allocator.free(col_assignment);
    const row_covered = try allocator.alloc(bool, n);
    defer allocator.free(row_covered);
    const col_covered = try allocator.alloc(bool, n);
    defer allocator.free(col_covered);

    // Arrays for tracking marked cells and paths
    // Using separate arrays instead of Matrix since Matrix requires float types
    var starred = try allocator.alloc(bool, n * n);
    defer allocator.free(starred);
    var primed = try allocator.alloc(bool, n * n);
    defer allocator.free(primed);
    @memset(starred, false);
    @memset(primed, false);

    // Initialize assignments
    for (row_assignment) |*r| r.* = null;
    for (col_assignment) |*c| c.* = null;

    // Step 1: Find initial zeros and create stars (assignments)
    for (0..n) |i| {
        for (0..n) |j| {
            if (work[i * n + j] == 0 and row_assignment[i] == null and col_assignment[j] == null) {
                row_assignment[i] = @intCast(j);
                col_assignment[j] = @intCast(i);
                starred[i * n + j] = true; // Star the zero
            }
        }
    }

    // Main loop with safety counter
    var iterations: u32 = 0;
    const max_iterations = n * n * 10; // Reasonable upper bound

    while (countAssignments(row_assignment) < n and iterations < max_iterations) {
        iterations += 1;

        // Step 2: Cover columns containing starred zeros
        @memset(row_covered, false);
        @memset(col_covered, false);

        for (0..n) |i| {
            if (row_assignment[i]) |col| {
                col_covered[col] = true;
            }
        }

        // Check if all columns are covered (optimal assignment found)
        var covered_count: u32 = 0;
        for (col_covered) |covered| {
            if (covered) covered_count += 1;
        }
        if (covered_count >= n) break;

        // Step 3: Keep finding uncovered zeros until we construct a path or need to modify matrix
        while (true) {
            // Find uncovered zero
            var found_zero = false;
            var zero_row: u32 = 0;
            var zero_col: u32 = 0;

            search: for (0..n) |i| {
                if (!row_covered[i]) {
                    for (0..n) |j| {
                        if (!col_covered[j]) {
                            if (work[i * n + j] == 0) {
                                zero_row = @intCast(i);
                                zero_col = @intCast(j);
                                found_zero = true;
                                break :search;
                            }
                        }
                    }
                }
            }

            if (found_zero) {
                // Prime the zero
                primed[zero_row * n + zero_col] = true;

                // Check if there's a starred zero in the same row
                const star_col = for (0..n) |j| {
                    if (starred[zero_row * n + j]) {
                        break j;
                    }
                } else null;

                if (star_col) |col| {
                    // Cover this row and uncover the star's column
                    row_covered[zero_row] = true;
                    col_covered[col] = false;
                    // Continue loop to find next uncovered zero
                } else {
                    // No starred zero in row, construct augmenting path
                    try constructAugmentingPath(allocator, starred, primed, zero_row, zero_col, row_assignment, col_assignment, n);

                    // Clear primes and break to restart from step 2
                    @memset(primed, false);
                    break;
                }
            } else {
                // Step 4: No uncovered zeros, modify matrix
                var min_uncovered: ?i64 = null;

                // Find minimum uncovered value
                var found_uncovered = false;
                for (0..n) |i| {
                    if (!row_covered[i]) {
                        for (0..n) |j| {
                            if (!col_covered[j]) {
                                if (!found_uncovered) {
                                    min_uncovered = work[i * n + j];
                                    found_uncovered = true;
                                } else {
                                    min_uncovered = @min(min_uncovered.?, work[i * n + j]);
                                }
                            }
                        }
                    }
                }

                if (!found_uncovered) break; // No valid solution

                // Add to covered rows, subtract from uncovered columns
                if (min_uncovered) |min| {
                    for (0..n) |i| {
                        for (0..n) |j| {
                            if (row_covered[i]) {
                                work[i * n + j] += min;
                            }
                            if (!col_covered[j]) {
                                work[i * n + j] -= min;
                            }
                        }
                    }
                }
                break; // Break inner while loop after modifying matrix
            }
        }
    }

    // Calculate total cost and prepare result
    var total_cost: f64 = 0;
    var result_assignments = try allocator.alloc(?u32, n_rows);
    for (0..n_rows) |i| {
        if (row_assignment[i]) |col| {
            if (col < n_cols) {
                result_assignments[i] = col;
                // Use original cost matrix values (not the multiplied work matrix)
                const cost_val = cost_matrix.at(i, col).*;
                total_cost += as(f64, cost_val);
            } else {
                result_assignments[i] = null;
            }
        } else {
            result_assignments[i] = null;
        }
    }

    return Assignment{
        .assignments = result_assignments,
        .total_cost = total_cost,
        .allocator = allocator,
    };
}

fn countAssignments(assignments: []const ?u32) u32 {
    var count: u32 = 0;
    for (assignments) |a| {
        if (a != null) count += 1;
    }
    return count;
}

fn constructAugmentingPath(
    allocator: Allocator,
    starred: []bool,
    primed: []bool,
    start_row: u32,
    start_col: u32,
    row_assignment: []?u32,
    col_assignment: []?u32,
    n: u32,
) !void {
    // Build augmenting path: alternating primed and starred zeros
    // Path can have up to 2*n elements (alternating starred and primed)
    const PathNode = struct { row: u32, col: u32 };
    const path = try allocator.alloc(PathNode, 2 * @as(usize, n));
    defer allocator.free(path);
    var path_len: u32 = 0;

    path[path_len] = .{ .row = start_row, .col = start_col };
    path_len += 1;

    var current_col = start_col;
    while (true) {
        // Find starred zero in current column
        const star_row = for (0..n) |i| {
            if (starred[i * n + current_col]) break i;
        } else null;

        if (star_row) |r| {
            // Add starred zero to path
            path[path_len] = .{ .row = @intCast(r), .col = current_col };
            path_len += 1;

            // Find primed zero in this row
            const prime_col = for (0..n) |j| {
                if (primed[r * n + j]) break j;
            } else null;

            if (prime_col) |c| {
                // Add primed zero to path
                path[path_len] = .{ .row = @intCast(r), .col = @intCast(c) };
                path_len += 1;
                current_col = @intCast(c);
            } else {
                break;
            }
        } else {
            break;
        }
    }

    // Flip the path: star even indices (primed), unstar odd indices (starred)
    for (0..path_len) |i| {
        const r = path[i].row;
        const c = path[i].col;
        starred[r * n + c] = (i % 2) == 0;
    }

    // Update assignments based on starred zeros
    for (row_assignment) |*r| r.* = null;
    for (col_assignment) |*c| c.* = null;

    for (0..n) |i| {
        for (0..n) |j| {
            if (starred[i * n + j]) {
                row_assignment[i] = @intCast(j);
                col_assignment[j] = @intCast(i);
            }
        }
    }
}

// Tests
test "Hungarian algorithm - simple 3x3" {
    const allocator = std.testing.allocator;

    // Create cost matrix
    // [1, 2, 3]
    // [2, 4, 6]
    // [3, 6, 9]
    var cost = try Matrix(f32).init(allocator, 3, 3);
    defer cost.deinit();

    cost.at(0, 0).* = 1;
    cost.at(0, 1).* = 2;
    cost.at(0, 2).* = 3;
    cost.at(1, 0).* = 2;
    cost.at(1, 1).* = 4;
    cost.at(1, 2).* = 6;
    cost.at(2, 0).* = 3;
    cost.at(2, 1).* = 6;
    cost.at(2, 2).* = 9;

    var result = try solveAssignmentProblem(f32, allocator, cost, .min);
    defer result.deinit();

    // Optimal: row0->col2 (3), row1->col1 (4), row2->col0 (3), total=10
    try expectEqual(@as(u32, 3), result.assignments.len);
    try expectEqual(@as(f64, 10), result.total_cost);
}

test "Hungarian algorithm - integer matrix" {
    const allocator = std.testing.allocator;

    // Test with integer cost matrix
    var cost = try Matrix(i32).init(allocator, 3, 3);
    defer cost.deinit();

    // Simple integer costs
    cost.at(0, 0).* = 10;
    cost.at(0, 1).* = 20;
    cost.at(0, 2).* = 30;
    cost.at(1, 0).* = 15;
    cost.at(1, 1).* = 25;
    cost.at(1, 2).* = 35;
    cost.at(2, 0).* = 20;
    cost.at(2, 1).* = 30;
    cost.at(2, 2).* = 40;

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
    var cost = try Matrix(f32).init(allocator, 2, 3);
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

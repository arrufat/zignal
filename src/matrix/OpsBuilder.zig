//! Builder for chaining matrix operations with in-place modifications

const std = @import("std");
const assert = std.debug.assert;
const Matrix = @import("Matrix.zig").Matrix;

/// Builder for chaining matrix operations with in-place modifications
pub fn OpsBuilder(comptime T: type) type {
    assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();

        result: Matrix(T),
        allocator: std.mem.Allocator,
        consumed: bool = false,

        /// Initialize builder with a copy of the input matrix
        pub fn init(allocator: std.mem.Allocator, matrix: Matrix(T)) !Self {
            const result = try Matrix(T).init(allocator, matrix.rows, matrix.cols);
            @memcpy(result.items, matrix.items);
            return Self{
                .result = result,
                .allocator = allocator,
            };
        }

        /// Clean up the builder (only if exec() was not called)
        pub fn deinit(self: *Self) void {
            if (!self.consumed) {
                self.result.deinit();
            }
        }

        /// Add another matrix element-wise
        pub fn add(self: *Self, other: Matrix(T)) !void {
            assert(self.result.rows == other.rows and self.result.cols == other.cols);
            for (0..self.result.items.len) |i| {
                self.result.items[i] += other.items[i];
            }
        }

        /// Subtract another matrix element-wise
        pub fn sub(self: *Self, other: Matrix(T)) !void {
            assert(self.result.rows == other.rows and self.result.cols == other.cols);
            for (0..self.result.items.len) |i| {
                self.result.items[i] -= other.items[i];
            }
        }

        /// Scale all elements by a value
        pub fn scale(self: *Self, value: T) !void {
            for (0..self.result.items.len) |i| {
                self.result.items[i] *= value;
            }
        }

        /// Transpose the matrix
        pub fn transpose(self: *Self) !void {
            var transposed = try Matrix(T).init(self.allocator, self.result.cols, self.result.rows);
            for (0..self.result.rows) |r| {
                for (0..self.result.cols) |c| {
                    transposed.at(c, r).* = self.result.at(r, c).*;
                }
            }
            self.result.deinit();
            self.result = transposed;
        }

        /// Perform element-wise multiplication
        pub fn times(self: *Self, other: Matrix(T)) !void {
            assert(self.result.rows == other.rows and self.result.cols == other.cols);
            for (0..self.result.items.len) |i| {
                self.result.items[i] *= other.items[i];
            }
        }

        /// Matrix multiplication (dot product) - changes dimensions
        pub fn dot(self: *Self, other: Matrix(T)) !void {
            try self.gemm(other, false, false, 1.0, 0.0, null);
        }

        /// Computes the determinant of the matrix (only for square matrices up to 3x3)
        fn determinant(matrix: Matrix(T)) T {
            assert(matrix.rows == matrix.cols);

            return switch (matrix.rows) {
                1 => matrix.at(0, 0).*,
                2 => matrix.at(0, 0).* * matrix.at(1, 1).* - matrix.at(0, 1).* * matrix.at(1, 0).*,
                3 => matrix.at(0, 0).* * matrix.at(1, 1).* * matrix.at(2, 2).* +
                    matrix.at(0, 1).* * matrix.at(1, 2).* * matrix.at(2, 0).* +
                    matrix.at(0, 2).* * matrix.at(1, 0).* * matrix.at(2, 1).* -
                    matrix.at(0, 2).* * matrix.at(1, 1).* * matrix.at(2, 0).* -
                    matrix.at(0, 1).* * matrix.at(1, 0).* * matrix.at(2, 2).* -
                    matrix.at(0, 0).* * matrix.at(1, 2).* * matrix.at(2, 1).*,
                else => blk: {
                    std.debug.panic("OpsBuilder.determinant() is not implemented for sizes above 3x3", .{});
                    break :blk 0;
                },
            };
        }

        /// Inverts the matrix (only for square matrices up to 3x3)
        pub fn inverse(self: *Self) !void {
            assert(self.result.rows == self.result.cols);

            const det = determinant(self.result);
            if (det == 0) {
                return error.SingularMatrix;
            }

            var inv = try Matrix(T).init(self.allocator, self.result.rows, self.result.cols);

            switch (self.result.rows) {
                1 => inv.at(0, 0).* = 1 / det,
                2 => {
                    inv.at(0, 0).* = self.result.at(1, 1).* / det;
                    inv.at(0, 1).* = -self.result.at(0, 1).* / det;
                    inv.at(1, 0).* = -self.result.at(1, 0).* / det;
                    inv.at(1, 1).* = self.result.at(0, 0).* / det;
                },
                3 => {
                    inv.at(0, 0).* = (self.result.at(1, 1).* * self.result.at(2, 2).* - self.result.at(1, 2).* * self.result.at(2, 1).*) / det;
                    inv.at(0, 1).* = (self.result.at(0, 2).* * self.result.at(2, 1).* - self.result.at(0, 1).* * self.result.at(2, 2).*) / det;
                    inv.at(0, 2).* = (self.result.at(0, 1).* * self.result.at(1, 2).* - self.result.at(0, 2).* * self.result.at(1, 1).*) / det;
                    inv.at(1, 0).* = (self.result.at(1, 2).* * self.result.at(2, 0).* - self.result.at(1, 0).* * self.result.at(2, 2).*) / det;
                    inv.at(1, 1).* = (self.result.at(0, 0).* * self.result.at(2, 2).* - self.result.at(0, 2).* * self.result.at(2, 0).*) / det;
                    inv.at(1, 2).* = (self.result.at(0, 2).* * self.result.at(1, 0).* - self.result.at(0, 0).* * self.result.at(1, 2).*) / det;
                    inv.at(2, 0).* = (self.result.at(1, 0).* * self.result.at(2, 1).* - self.result.at(1, 1).* * self.result.at(2, 0).*) / det;
                    inv.at(2, 1).* = (self.result.at(0, 1).* * self.result.at(2, 0).* - self.result.at(0, 0).* * self.result.at(2, 1).*) / det;
                    inv.at(2, 2).* = (self.result.at(0, 0).* * self.result.at(1, 1).* - self.result.at(0, 1).* * self.result.at(1, 0).*) / det;
                },
                else => {
                    std.debug.panic("OpsBuilder.inverse() is not implemented for sizes above 3x3", .{});
                },
            }

            self.result.deinit();
            self.result = inv;
        }

        /// Extract a submatrix - changes dimensions
        pub fn subMatrix(self: *Self, row_begin: usize, col_begin: usize, row_count: usize, col_count: usize) !void {
            assert(row_begin + row_count <= self.result.rows);
            assert(col_begin + col_count <= self.result.cols);

            var new_result = try Matrix(T).init(self.allocator, row_count, col_count);

            for (0..row_count) |r| {
                for (0..col_count) |c| {
                    new_result.at(r, c).* = self.result.at(row_begin + r, col_begin + c).*;
                }
            }

            self.result.deinit();
            self.result = new_result;
        }

        /// Extract a column - changes dimensions
        pub fn col(self: *Self, col_idx: usize) !void {
            assert(col_idx < self.result.cols);

            var new_result = try Matrix(T).init(self.allocator, self.result.rows, 1);

            for (0..self.result.rows) |r| {
                new_result.at(r, 0).* = self.result.at(r, col_idx).*;
            }

            self.result.deinit();
            self.result = new_result;
        }

        /// Extract a row - changes dimensions
        pub fn row(self: *Self, row_idx: usize) !void {
            assert(row_idx < self.result.rows);

            var new_result = try Matrix(T).init(self.allocator, 1, self.result.cols);

            for (0..self.result.cols) |c| {
                new_result.at(0, c).* = self.result.at(row_idx, c).*;
            }

            self.result.deinit();
            self.result = new_result;
        }

        /// Compute Gram matrix: X * X^T
        /// Useful for kernel methods and when rows < columns
        /// The resulting matrix is rows × rows
        pub fn gram(self: *Self) !void {
            try self.gemm(self.result, false, true, 1.0, 0.0, null);
        }

        /// Compute covariance matrix: X^T * X
        /// Useful for statistical analysis and when rows > columns
        /// The resulting matrix is columns × columns
        pub fn covariance(self: *Self) !void {
            try self.gemm(self.result, true, false, 1.0, 0.0, null);
        }

        /// General Matrix Multiply (GEMM): C = α * op(A) * op(B) + β * C
        ///
        /// This is the fundamental matrix operation that unifies many matrix computations:
        /// - op(A) = A if trans_a is false, A^T if trans_a is true
        /// - op(B) = B if trans_b is false, B^T if trans_b is true
        /// - α (alpha) scales the product op(A) * op(B)
        /// - β (beta) scales the existing matrix C before adding the product
        /// - If c_matrix is null, it defaults to zero matrix
        ///
        /// Examples:
        /// - Matrix multiplication: gemm(B, false, false, 1.0, 0.0, null)
        /// - Gram matrix: gemm(self, false, true, 1.0, 0.0, null) -> A * A^T
        /// - Covariance: gemm(self, true, false, 1.0, 0.0, null) -> A^T * A
        /// - Scaled product: gemm(B, false, false, 2.0, 0.0, null) -> 2 * A * B
        /// - Accumulation: gemm(B, false, false, 1.0, 1.0, C) -> A * B + C
        pub fn gemm(
            self: *Self,
            other: Matrix(T),
            trans_a: bool,
            trans_b: bool,
            alpha: T,
            beta: T,
            c_matrix: ?Matrix(T),
        ) !void {
            // Determine dimensions after potential transposition
            const a_rows = if (trans_a) self.result.cols else self.result.rows;
            const a_cols = if (trans_a) self.result.rows else self.result.cols;
            const b_rows = if (trans_b) other.cols else other.rows;
            const b_cols = if (trans_b) other.rows else other.cols;

            // Verify matrix multiplication compatibility
            assert(a_cols == b_rows);

            var result = try Matrix(T).init(self.allocator, a_rows, b_cols);

            // Initialize with scaled C matrix if provided
            if (c_matrix) |c| {
                assert(c.rows == a_rows and c.cols == b_cols);
                if (beta != 0) {
                    for (0..a_rows) |i| {
                        for (0..b_cols) |j| {
                            result.at(i, j).* = beta * c.at(i, j).*;
                        }
                    }
                }
            } else {
                // Initialize to zero
                for (0..result.items.len) |i| {
                    result.items[i] = 0;
                }
            }

            // Skip computation if alpha is zero
            if (alpha != 0) {
                // Perform matrix multiplication with optional transpositions
                for (0..a_rows) |i| {
                    for (0..b_cols) |j| {
                        var accumulator: T = 0;
                        for (0..a_cols) |k| {
                            // Get elements with potential transposition
                            const a_val = if (trans_a) self.result.at(k, i).* else self.result.at(i, k).*;
                            const b_val = if (trans_b) other.at(j, k).* else other.at(k, j).*;
                            accumulator += a_val * b_val;
                        }
                        result.at(i, j).* += alpha * accumulator;
                    }
                }
            }

            self.result.deinit();
            self.result = result;
        }

        /// Scaled matrix multiplication: α * A * B
        /// Convenience method for common GEMM use case
        pub fn scaledDot(self: *Self, other: Matrix(T), alpha: T) !void {
            try self.gemm(other, false, false, alpha, 0.0, null);
        }

        /// Matrix multiplication with transpose: A * B^T
        /// Convenience method for common GEMM use case
        pub fn dotTranspose(self: *Self, other: Matrix(T)) !void {
            try self.gemm(other, false, true, 1.0, 0.0, null);
        }

        /// Transpose matrix multiplication: A^T * B
        /// Convenience method for common GEMM use case
        pub fn transposeDot(self: *Self, other: Matrix(T)) !void {
            try self.gemm(other, true, false, 1.0, 0.0, null);
        }

        /// Transfer ownership of the result to the caller
        pub fn toOwned(self: *Self) Matrix(T) {
            const final_result = self.result;
            // Mark as consumed to prevent deinit from freeing it
            self.consumed = true;
            return final_result;
        }
    };
}

// Tests for OpsBuilder functionality
const expectEqual = std.testing.expectEqual;
const SMatrix = @import("SMatrix.zig").SMatrix;

test "dynamic matrix with OpsBuilder dot product" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create two dynamic matrices for multiplication
    var a = try Matrix(f64).init(arena.allocator(), 2, 3);
    var b = try Matrix(f64).init(arena.allocator(), 3, 2);

    // Set values for matrix A (2x3)
    a.at(0, 0).* = 1.0;
    a.at(0, 1).* = 2.0;
    a.at(0, 2).* = 3.0;
    a.at(1, 0).* = 4.0;
    a.at(1, 1).* = 5.0;
    a.at(1, 2).* = 6.0;

    // Set values for matrix B (3x2)
    b.at(0, 0).* = 7.0;
    b.at(0, 1).* = 8.0;
    b.at(1, 0).* = 9.0;
    b.at(1, 1).* = 10.0;
    b.at(2, 0).* = 11.0;
    b.at(2, 1).* = 12.0;

    // Multiply A * B using OpsBuilder
    var ops = try OpsBuilder(f64).init(arena.allocator(), a);
    try ops.dot(b);
    const result = ops.toOwned();

    // Verify result dimensions
    const shape = result.shape();
    try expectEqual(@as(usize, 2), shape[0]);
    try expectEqual(@as(usize, 2), shape[1]);

    // Verify result values
    // A * B = [1*7+2*9+3*11  1*8+2*10+3*12] = [58  64]
    //         [4*7+5*9+6*11  4*8+5*10+6*12]   [139 154]
    try expectEqual(@as(f64, 58.0), result.at(0, 0).*);
    try expectEqual(@as(f64, 64.0), result.at(0, 1).*);
    try expectEqual(@as(f64, 139.0), result.at(1, 0).*);
    try expectEqual(@as(f64, 154.0), result.at(1, 1).*);
}

test "complex operation chaining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test data
    const static_a = SMatrix(f32, 2, 2).init(.{ .{ 1.0, 2.0 }, .{ 3.0, 4.0 } });
    const static_b = SMatrix(f32, 2, 2).init(.{ .{ 2.0, 0.0 }, .{ 0.0, 2.0 } });

    // SMatrix chaining (direct method calls)
    const static_result = static_a.dot(static_b).transpose().scale(0.5);

    // OpsBuilder chaining (equivalent operations)
    const dynamic_a = try static_a.toMatrix(arena.allocator());
    const dynamic_b = try static_b.toMatrix(arena.allocator());

    var ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_a);
    try ops.dot(dynamic_b);
    try ops.transpose();
    try ops.scale(0.5);
    const dynamic_result = ops.toOwned();

    // Verify both approaches give identical results
    for (0..2) |r| {
        for (0..2) |c| {
            try expectEqual(static_result.at(r, c).*, dynamic_result.at(r, c).*);
        }
    }
}

test "row and column extraction with OpsBuilder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test data
    const test_matrix = SMatrix(f32, 3, 2).init(.{
        .{ 1.0, 2.0 },
        .{ 3.0, 4.0 },
        .{ 5.0, 6.0 },
    });

    // Test OpsBuilder row/col extraction on equivalent Matrix
    const dynamic_matrix = try test_matrix.toMatrix(arena.allocator());

    var row_ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_matrix);
    try row_ops.row(1);
    const dynamic_row = row_ops.toOwned();
    try expectEqual(@as(usize, 1), dynamic_row.rows);
    try expectEqual(@as(usize, 2), dynamic_row.cols);
    try expectEqual(@as(f32, 3.0), dynamic_row.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), dynamic_row.at(0, 1).*);

    var col_ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_matrix);
    try col_ops.col(1);
    const dynamic_col = col_ops.toOwned();
    try expectEqual(@as(usize, 3), dynamic_col.rows);
    try expectEqual(@as(usize, 1), dynamic_col.cols);
    try expectEqual(@as(f32, 2.0), dynamic_col.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), dynamic_col.at(1, 0).*);
    try expectEqual(@as(f32, 6.0), dynamic_col.at(2, 0).*);
}

test "OpsBuilder gram and covariance matrices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create test matrix (3 samples × 2 features)
    var data = try Matrix(f64).init(arena.allocator(), 3, 2);
    data.at(0, 0).* = 1.0;
    data.at(0, 1).* = 2.0;
    data.at(1, 0).* = 3.0;
    data.at(1, 1).* = 4.0;
    data.at(2, 0).* = 5.0;
    data.at(2, 1).* = 6.0;

    // Test Gram matrix (X * X^T) - should be 3×3
    var gram_ops = try OpsBuilder(f64).init(arena.allocator(), data);
    try gram_ops.gram();
    const gram_result = gram_ops.toOwned();

    try expectEqual(@as(usize, 3), gram_result.rows);
    try expectEqual(@as(usize, 3), gram_result.cols);

    // Verify gram matrix values
    // First row: [1*1+2*2, 1*3+2*4, 1*5+2*6] = [5, 11, 17]
    try expectEqual(@as(f64, 5.0), gram_result.at(0, 0).*);
    try expectEqual(@as(f64, 11.0), gram_result.at(0, 1).*);
    try expectEqual(@as(f64, 17.0), gram_result.at(0, 2).*);

    // Test Covariance matrix (X^T * X) - should be 2×2
    var cov_ops = try OpsBuilder(f64).init(arena.allocator(), data);
    try cov_ops.covariance();
    const cov_result = cov_ops.toOwned();

    try expectEqual(@as(usize, 2), cov_result.rows);
    try expectEqual(@as(usize, 2), cov_result.cols);

    // Verify covariance matrix values
    // First row: [1*1+3*3+5*5, 1*2+3*4+5*6] = [35, 44]
    try expectEqual(@as(f64, 35.0), cov_result.at(0, 0).*);
    try expectEqual(@as(f64, 44.0), cov_result.at(0, 1).*);
    // Second row: [2*1+4*3+6*5, 2*2+4*4+6*6] = [44, 56]
    try expectEqual(@as(f64, 44.0), cov_result.at(1, 0).*);
    try expectEqual(@as(f64, 56.0), cov_result.at(1, 1).*);
}

test "OpsBuilder GEMM operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create test matrices
    var a = try Matrix(f32).init(arena.allocator(), 2, 3);
    a.at(0, 0).* = 1.0;
    a.at(0, 1).* = 2.0;
    a.at(0, 2).* = 3.0;
    a.at(1, 0).* = 4.0;
    a.at(1, 1).* = 5.0;
    a.at(1, 2).* = 6.0;

    var b = try Matrix(f32).init(arena.allocator(), 3, 2);
    b.at(0, 0).* = 7.0;
    b.at(0, 1).* = 8.0;
    b.at(1, 0).* = 9.0;
    b.at(1, 1).* = 10.0;
    b.at(2, 0).* = 11.0;
    b.at(2, 1).* = 12.0;

    var c = try Matrix(f32).init(arena.allocator(), 2, 2);
    c.at(0, 0).* = 1.0;
    c.at(0, 1).* = 1.0;
    c.at(1, 0).* = 1.0;
    c.at(1, 1).* = 1.0;

    // Test basic matrix multiplication: A * B
    var ops1 = try OpsBuilder(f32).init(arena.allocator(), a);
    try ops1.gemm(b, false, false, 1.0, 0.0, null);
    const result1 = ops1.toOwned();

    try expectEqual(@as(f32, 58.0), result1.at(0, 0).*); // 1*7 + 2*9 + 3*11
    try expectEqual(@as(f32, 64.0), result1.at(0, 1).*); // 1*8 + 2*10 + 3*12
    try expectEqual(@as(f32, 139.0), result1.at(1, 0).*); // 4*7 + 5*9 + 6*11
    try expectEqual(@as(f32, 154.0), result1.at(1, 1).*); // 4*8 + 5*10 + 6*12

    // Test scaled multiplication: 2 * A * B
    var ops2 = try OpsBuilder(f32).init(arena.allocator(), a);
    try ops2.gemm(b, false, false, 2.0, 0.0, null);
    const result2 = ops2.toOwned();

    try expectEqual(@as(f32, 116.0), result2.at(0, 0).*); // 2 * 58
    try expectEqual(@as(f32, 128.0), result2.at(0, 1).*); // 2 * 64

    // Test accumulation: A * B + C
    var ops3 = try OpsBuilder(f32).init(arena.allocator(), a);
    try ops3.gemm(b, false, false, 1.0, 1.0, c);
    const result3 = ops3.toOwned();

    try expectEqual(@as(f32, 59.0), result3.at(0, 0).*); // 58 + 1
    try expectEqual(@as(f32, 65.0), result3.at(0, 1).*); // 64 + 1

    // Test Gram matrix using GEMM: A * A^T
    var ops4 = try OpsBuilder(f32).init(arena.allocator(), a);
    try ops4.gemm(a, false, true, 1.0, 0.0, null);
    const gram = ops4.toOwned();

    try expectEqual(@as(usize, 2), gram.rows);
    try expectEqual(@as(usize, 2), gram.cols);
    try expectEqual(@as(f32, 14.0), gram.at(0, 0).*); // 1*1 + 2*2 + 3*3
    try expectEqual(@as(f32, 32.0), gram.at(0, 1).*); // 1*4 + 2*5 + 3*6

    // Test covariance using GEMM: A^T * A
    var ops5 = try OpsBuilder(f32).init(arena.allocator(), a);
    try ops5.gemm(a, true, false, 1.0, 0.0, null);
    const cov = ops5.toOwned();

    try expectEqual(@as(usize, 3), cov.rows);
    try expectEqual(@as(usize, 3), cov.cols);
    try expectEqual(@as(f32, 17.0), cov.at(0, 0).*); // 1*1 + 4*4
    try expectEqual(@as(f32, 22.0), cov.at(0, 1).*); // 1*2 + 4*5
}

test "OpsBuilder matrix operations: add, sub, scale, transpose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test data
    const static_matrix = SMatrix(f32, 2, 3).init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });

    // Test operand matrix for add/sub operations
    const static_operand = SMatrix(f32, 2, 3).init(.{
        .{ 0.5, 1.0, 1.5 },
        .{ 2.0, 2.5, 3.0 },
    });

    // SMatrix operations for reference
    const static_scaled = static_matrix.scale(2.0);
    const static_transposed = static_matrix.transpose();
    const static_subtracted = static_matrix.sub(static_operand);

    // OpsBuilder operations on equivalent matrix
    const dynamic_matrix = try static_matrix.toMatrix(arena.allocator());

    // Test scale
    var scale_ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_matrix);
    try scale_ops.scale(2.0);
    const dynamic_scaled = scale_ops.toOwned();

    // Test transpose
    var transpose_ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_matrix);
    try transpose_ops.transpose();
    const dynamic_transposed = transpose_ops.toOwned();

    // Test add
    const add_matrix = try Matrix(f32).initAll(arena.allocator(), 2, 3, 1.0);
    var add_ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_matrix);
    try add_ops.add(add_matrix);
    const dynamic_added = add_ops.toOwned();

    // Test subtract
    const dynamic_operand = try static_operand.toMatrix(arena.allocator());
    var sub_ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_matrix);
    try sub_ops.sub(dynamic_operand);
    const dynamic_subtracted = sub_ops.toOwned();

    // Verify results match
    for (0..2) |r| {
        for (0..3) |c| {
            try expectEqual(static_scaled.at(r, c).*, dynamic_scaled.at(r, c).*);
        }
    }
    for (0..3) |r| {
        for (0..2) |c| {
            try expectEqual(static_transposed.at(r, c).*, dynamic_transposed.at(r, c).*);
        }
    }
    try expectEqual(@as(f32, 2.0), dynamic_added.at(0, 0).*); // 1 + 1
    try expectEqual(@as(f32, 7.0), dynamic_added.at(1, 2).*); // 6 + 1
    for (0..2) |r| {
        for (0..3) |c| {
            try expectEqual(static_subtracted.at(r, c).*, dynamic_subtracted.at(r, c).*);
        }
    }
}

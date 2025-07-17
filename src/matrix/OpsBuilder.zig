//! Builder for chaining matrix operations with in-place modifications
//!
//! Performance note: GEMM operations use SIMD optimization for larger matrices.
//! The threshold is set at 512 multiply-accumulate operations (e.g., 8x8 * 8x8).
//! For smaller matrices, the scalar path is used to avoid allocation overhead.

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;

const Matrix = @import("Matrix.zig").Matrix;
const SMatrix = @import("SMatrix.zig").SMatrix;

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
            const result: Matrix(T) = try .init(allocator, matrix.rows, matrix.cols);
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
            var transposed: Matrix(T) = try .init(self.allocator, self.result.cols, self.result.rows);
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

        /// Computes the determinant of the matrix using analytical formulas for small matrices
        /// and LU decomposition for larger matrices
        pub fn determinant(self: *Self) !T {
            assert(self.result.rows == self.result.cols);

            const n = self.result.rows;

            // Use analytical formulas for small matrices (more efficient)
            if (n <= 3) {
                return switch (n) {
                    1 => self.result.at(0, 0).*,
                    2 => self.result.at(0, 0).* * self.result.at(1, 1).* -
                        self.result.at(0, 1).* * self.result.at(1, 0).*,
                    3 => self.result.at(0, 0).* * self.result.at(1, 1).* * self.result.at(2, 2).* +
                        self.result.at(0, 1).* * self.result.at(1, 2).* * self.result.at(2, 0).* +
                        self.result.at(0, 2).* * self.result.at(1, 0).* * self.result.at(2, 1).* -
                        self.result.at(0, 2).* * self.result.at(1, 1).* * self.result.at(2, 0).* -
                        self.result.at(0, 1).* * self.result.at(1, 0).* * self.result.at(2, 2).* -
                        self.result.at(0, 0).* * self.result.at(1, 2).* * self.result.at(2, 1).*,
                    else => unreachable,
                };
            }

            // Use LU decomposition for larger matrices
            var lu_result = try self.lu();
            defer lu_result.deinit();

            // det(A) = sign * product of diagonal elements of U
            var det = lu_result.sign;
            for (0..n) |i| {
                det *= lu_result.u.at(i, i).*;
            }

            return det;
        }

        /// Inverts the matrix using analytical formulas for small matrices (≤3x3)
        /// and Gauss-Jordan elimination for larger matrices
        pub fn inverse(self: *Self) !void {
            assert(self.result.rows == self.result.cols);

            const n = self.result.rows;

            // Use analytical formulas for small matrices (more efficient)
            if (n <= 3) {
                const det = try self.determinant();
                if (@abs(det) < std.math.floatEps(T)) {
                    return error.SingularMatrix;
                }

                var inv = try Matrix(T).init(self.allocator, n, n);

                switch (n) {
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
                    else => unreachable,
                }

                self.result.deinit();
                self.result = inv;
            } else {
                // Use Gauss-Jordan elimination for larger matrices
                try self.inverseGaussJordan();
            }
        }

        /// Inverts the matrix using Gauss-Jordan elimination with partial pivoting
        /// This is a general method that works for any size square matrix
        fn inverseGaussJordan(self: *Self) !void {
            const n = self.result.rows;

            // Create augmented matrix [A | I]
            var augmented: Matrix(T) = try .init(self.allocator, n, 2 * n);
            defer augmented.deinit();

            // Copy original matrix to left half and identity to right half
            for (0..n) |i| {
                for (0..n) |j| {
                    augmented.at(i, j).* = self.result.at(i, j).*;
                    augmented.at(i, n + j).* = if (i == j) 1.0 else 0.0;
                }
            }

            // Perform Gauss-Jordan elimination
            for (0..n) |pivot_col| {
                // Find pivot (partial pivoting for numerical stability)
                var max_row = pivot_col;
                var max_val = @abs(augmented.at(pivot_col, pivot_col).*);

                for (pivot_col + 1..n) |row_idx| {
                    const val = @abs(augmented.at(row_idx, pivot_col).*);
                    if (val > max_val) {
                        max_val = val;
                        max_row = row_idx;
                    }
                }

                // Check for singular matrix
                if (max_val < std.math.floatEps(T) * 10) {
                    return error.SingularMatrix;
                }

                // Swap rows if needed
                if (max_row != pivot_col) {
                    for (0..2 * n) |j| {
                        const temp = augmented.at(pivot_col, j).*;
                        augmented.at(pivot_col, j).* = augmented.at(max_row, j).*;
                        augmented.at(max_row, j).* = temp;
                    }
                }

                // Scale pivot row
                const pivot = augmented.at(pivot_col, pivot_col).*;
                for (0..2 * n) |j| {
                    augmented.at(pivot_col, j).* /= pivot;
                }

                // Eliminate column in all other rows
                for (0..n) |row_idx| {
                    if (row_idx != pivot_col) {
                        const factor = augmented.at(row_idx, pivot_col).*;
                        for (0..2 * n) |j| {
                            augmented.at(row_idx, j).* -= factor * augmented.at(pivot_col, j).*;
                        }
                    }
                }
            }

            // Extract inverse from right half of augmented matrix
            var inv: Matrix(T) = try .init(self.allocator, n, n);
            for (0..n) |i| {
                for (0..n) |j| {
                    inv.at(i, j).* = augmented.at(i, n + j).*;
                }
            }

            self.result.deinit();
            self.result = inv;
        }

        /// Extract a submatrix - changes dimensions
        pub fn subMatrix(self: *Self, row_begin: usize, col_begin: usize, row_count: usize, col_count: usize) !void {
            assert(row_begin + row_count <= self.result.rows);
            assert(col_begin + col_count <= self.result.cols);

            var new_result: Matrix(T) = try .init(self.allocator, row_count, col_count);

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

            var new_result: Matrix(T) = try .init(self.allocator, self.result.rows, 1);

            for (0..self.result.rows) |r| {
                new_result.at(r, 0).* = self.result.at(r, col_idx).*;
            }

            self.result.deinit();
            self.result = new_result;
        }

        /// Extract a row - changes dimensions
        pub fn row(self: *Self, row_idx: usize) !void {
            assert(row_idx < self.result.rows);

            var new_result: Matrix(T) = try .init(self.allocator, 1, self.result.cols);

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

        /// Helper function for optimized SIMD GEMM kernel
        /// Both matrices must be arranged for row-major access
        fn simdGemmKernel(
            comptime VecType: type,
            comptime vec_len: usize,
            result: *Matrix(T),
            matrix_a: Matrix(T),
            matrix_b: Matrix(T),
            alpha: T,
            a_rows: usize,
            a_cols: usize,
            b_cols: usize,
        ) void {
            // Both matrices are now guaranteed to be accessed row-wise
            for (0..a_rows) |i| {
                for (0..b_cols) |j| {
                    var accumulator: T = 0;

                    // Process vec_len elements at once
                    var k: usize = 0;
                    while (k + vec_len <= a_cols) : (k += vec_len) {
                        // Load vectors from both matrices (both are row-major access)
                        const a_vec: VecType = matrix_a.items[i * a_cols + k .. i * a_cols + k + vec_len][0..vec_len].*;
                        const b_vec: VecType = matrix_b.items[j * a_cols + k .. j * a_cols + k + vec_len][0..vec_len].*;

                        // Vectorized multiply-accumulate
                        const prod_vec = a_vec * b_vec;
                        accumulator += @reduce(.Add, prod_vec);
                    }

                    // Handle remainder elements
                    while (k < a_cols) : (k += 1) {
                        accumulator += matrix_a.at(i, k).* * matrix_b.at(j, k).*;
                    }

                    result.at(i, j).* += alpha * accumulator;
                }
            }
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

            var result: Matrix(T) = try .init(self.allocator, a_rows, b_cols);

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
                @memset(result.items, 0);
            }

            // Skip computation if alpha is zero
            if (alpha != 0) {
                const vec_len = std.simd.suggestVectorLength(T) orelse 1;

                // Calculate total operations to determine if SIMD is worth the overhead
                const total_ops = a_rows * a_cols * b_cols;
                const simd_threshold = 512; // Use SIMD for larger matrices (>512 operations)

                // Use SIMD only for larger matrices where the benefit outweighs allocation overhead
                if (vec_len > 1 and total_ops >= simd_threshold) {
                    // Enable SIMD for all 4 transpose combinations
                    const VecType = @Vector(vec_len, T);

                    if (!trans_a and !trans_b) {
                        // Case 1: A * B - transpose B for cache-friendly row-major access

                        // Handle special case when A and B are the same matrix (for A * A)
                        if (self.result.rows == other.rows and
                            self.result.cols == other.cols and
                            std.mem.eql(T, self.result.items, other.items))
                        {
                            // For A * A, we need to transpose A for the second operand
                            var a_transposed = try Matrix(T).init(self.allocator, b_cols, a_cols);
                            defer a_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    a_transposed.at(j, k).* = self.result.at(k, j).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, self.result, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: transpose B for cache-friendly row-major access
                            var b_transposed = try Matrix(T).init(self.allocator, b_cols, a_cols);
                            defer b_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    b_transposed.at(j, k).* = other.at(k, j).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, self.result, b_transposed, alpha, a_rows, a_cols, b_cols);
                        }
                    } else if (trans_a and !trans_b) {
                        // Case 2: A^T * B - transpose A for cache-friendly row-major access
                        var a_transposed = try Matrix(T).init(self.allocator, a_rows, a_cols);
                        defer a_transposed.deinit();
                        // Transpose A: a_transposed[i,j] = A[j,i]
                        for (0..a_cols) |k| {
                            for (0..a_rows) |i| {
                                a_transposed.at(i, k).* = self.result.at(k, i).*;
                            }
                        }
                        // Handle special case when A and B are the same matrix (for covariance)
                        if (self.result.rows == other.rows and
                            self.result.cols == other.cols and
                            std.mem.eql(T, self.result.items, other.items))
                        {
                            // For covariance (A^T * A), we need to also use transposed for B
                            simdGemmKernel(VecType, vec_len, &result, a_transposed, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: transpose B for row-wise access
                            var b_transposed = try Matrix(T).init(self.allocator, b_cols, a_cols);
                            defer b_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    b_transposed.at(j, k).* = other.at(k, j).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, a_transposed, b_transposed, alpha, a_rows, a_cols, b_cols);
                        }
                    } else if (!trans_a and trans_b) {
                        // Case 3: A * B^T - no transpose needed, B^T is naturally row-wise

                        // Handle special case when A and B are the same matrix (for A * A^T)
                        if (self.result.rows == other.rows and
                            self.result.cols == other.cols and
                            std.mem.eql(T, self.result.items, other.items))
                        {
                            // For A * A^T, we need to transpose A for the second operand
                            var a_transposed = try Matrix(T).init(self.allocator, b_cols, a_cols);
                            defer a_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    a_transposed.at(j, k).* = self.result.at(j, k).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, self.result, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: B^T is naturally row-wise
                            simdGemmKernel(VecType, vec_len, &result, self.result, other, alpha, a_rows, a_cols, b_cols);
                        }
                    } else if (trans_a and trans_b) {
                        // Case 4: A^T * B^T - no transpose needed, both naturally row-wise

                        // Handle special case when A and B are the same matrix (for A^T * A^T)
                        if (self.result.rows == other.rows and
                            self.result.cols == other.cols and
                            std.mem.eql(T, self.result.items, other.items))
                        {
                            // For A^T * A^T, we transpose A to get the transposed version
                            var a_transposed = try Matrix(T).init(self.allocator, a_rows, a_cols);
                            defer a_transposed.deinit();
                            for (0..self.result.rows) |i| {
                                for (0..self.result.cols) |j| {
                                    a_transposed.at(j, i).* = self.result.at(i, j).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, a_transposed, self.result, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: both A^T and B^T are naturally row-wise
                            simdGemmKernel(VecType, vec_len, &result, self.result, other, alpha, a_rows, a_cols, b_cols);
                        }
                    }
                } else {
                    // No SIMD support, use scalar implementation for all transpose combinations
                    for (0..a_rows) |i| {
                        for (0..b_cols) |j| {
                            var accumulator: T = 0;
                            for (0..a_cols) |k| {
                                const a_val = if (trans_a) self.result.at(k, i).* else self.result.at(i, k).*;
                                const b_val = if (trans_b) other.at(j, k).* else other.at(k, j).*;
                                accumulator += a_val * b_val;
                            }
                            result.at(i, j).* += alpha * accumulator;
                        }
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

        /// Result of LU decomposition
        pub const LuResult = struct {
            l: Matrix(T), // Lower triangular matrix
            u: Matrix(T), // Upper triangular matrix
            p: Matrix(T), // Permutation vector (nx1 matrix)
            sign: T, // Determinant sign (+1 or -1)

            pub fn deinit(self: *@This()) void {
                self.l.deinit();
                self.u.deinit();
                self.p.deinit();
            }
        };

        /// Compute LU decomposition with partial pivoting
        /// Returns L, U matrices and permutation vector such that PA = LU
        pub fn lu(self: *Self) !LuResult {
            const n = self.result.rows;
            assert(n == self.result.cols); // Must be square

            // Create working copy
            var work: Matrix(T) = try .init(self.allocator, n, n);
            defer work.deinit();
            @memcpy(work.items, self.result.items);

            // Initialize L as identity, U as zero
            var l: Matrix(T) = try .init(self.allocator, n, n);
            errdefer l.deinit();
            var u: Matrix(T) = try .init(self.allocator, n, n);
            errdefer u.deinit();

            // Initialize permutation vector
            var p: Matrix(f64) = try .init(self.allocator, n, 1);
            errdefer p.deinit();
            for (0..n) |i| {
                p.items[i] = @floatFromInt(i);
            }

            // Initialize matrices
            @memset(l.items, 0);
            @memset(u.items, 0);
            for (0..n) |i| {
                l.at(i, i).* = 1.0; // L starts as identity
            }

            var sign: T = 1.0;

            // Perform LU decomposition with partial pivoting
            for (0..n) |pivot_col| {
                // Find pivot
                var max_row = pivot_col;
                var max_val = @abs(work.at(pivot_col, pivot_col).*);

                for (pivot_col + 1..n) |row_idx| {
                    const val = @abs(work.at(row_idx, pivot_col).*);
                    if (val > max_val) {
                        max_val = val;
                        max_row = row_idx;
                    }
                }

                // Check for zero pivot (singular matrix)
                if (max_val < std.math.floatEps(T) * 10) {
                    // Continue with decomposition even if singular
                    // User can check if U has zeros on diagonal
                }

                // Swap rows if needed
                if (max_row != pivot_col) {
                    sign = -sign;
                    // Swap in permutation vector
                    const temp_p = p.items[pivot_col];
                    p.items[pivot_col] = p.items[max_row];
                    p.items[max_row] = temp_p;

                    // Swap rows in work matrix
                    for (0..n) |j| {
                        const temp = work.at(pivot_col, j).*;
                        work.at(pivot_col, j).* = work.at(max_row, j).*;
                        work.at(max_row, j).* = temp;
                    }

                    // Swap rows in L (only the part already computed)
                    for (0..pivot_col) |j| {
                        const temp = l.at(pivot_col, j).*;
                        l.at(pivot_col, j).* = l.at(max_row, j).*;
                        l.at(max_row, j).* = temp;
                    }
                }

                // Copy pivot row to U
                for (pivot_col..n) |j| {
                    u.at(pivot_col, j).* = work.at(pivot_col, j).*;
                }

                // Compute L column and eliminate
                for (pivot_col + 1..n) |row_idx| {
                    if (@abs(work.at(pivot_col, pivot_col).*) > std.math.floatEps(T)) {
                        const factor = work.at(row_idx, pivot_col).* / work.at(pivot_col, pivot_col).*;
                        l.at(row_idx, pivot_col).* = factor;

                        for (pivot_col + 1..n) |col_idx| {
                            work.at(row_idx, col_idx).* -= factor * work.at(pivot_col, col_idx).*;
                        }
                    }
                }
            }

            return LuResult{
                .l = l,
                .u = u,
                .p = p,
                .sign = sign,
            };
        }

        pub const QrResult = struct {
            q: Matrix(T), // Orthogonal matrix (Q^T Q = I)
            r: Matrix(T), // Upper triangular matrix

            pub fn deinit(self: *@This()) void {
                self.q.deinit();
                self.r.deinit();
            }
        };

        /// Compute QR decomposition using Modified Gram-Schmidt algorithm
        /// Returns Q, R matrices such that A = QR where Q is orthogonal and R is upper triangular
        pub fn qr(self: *Self) !QrResult {
            const m = self.result.rows;
            const n = self.result.cols;

            // Initialize Q and R matrices
            var q: Matrix(T) = try .init(self.allocator, m, n);
            errdefer q.deinit();
            var r: Matrix(T) = try .init(self.allocator, n, n);
            errdefer r.deinit();

            // Copy A to Q (will be modified in-place)
            @memcpy(q.items, self.result.items);

            // Initialize R as zero
            @memset(r.items, 0);

            // Modified Gram-Schmidt algorithm
            for (0..n) |j| {
                // Compute R[j,j] = ||Q[:,j]||
                var norm_sq: T = 0;
                for (0..m) |i| {
                    const val = q.at(i, j).*;
                    norm_sq += val * val;
                }
                r.at(j, j).* = @sqrt(norm_sq);

                // Check for linear dependence
                if (r.at(j, j).* < std.math.floatEps(T) * 100) {
                    return error.LinearlyDependent;
                }

                // Normalize Q[:,j]
                const inv_norm = 1.0 / r.at(j, j).*;
                for (0..m) |i| {
                    q.at(i, j).* *= inv_norm;
                }

                // Orthogonalize remaining columns
                for (j + 1..n) |k| {
                    // Compute R[j,k] = Q[:,j]^T * Q[:,k]
                    var dot_product: T = 0;
                    for (0..m) |i| {
                        dot_product += q.at(i, j).* * q.at(i, k).*;
                    }
                    r.at(j, k).* = dot_product;

                    // Q[:,k] = Q[:,k] - R[j,k] * Q[:,j]
                    for (0..m) |i| {
                        q.at(i, k).* -= r.at(j, k).* * q.at(i, j).*;
                    }
                }
            }

            return QrResult{
                .q = q,
                .r = r,
            };
        }

        /// Apply a function to all matrix elements with optional arguments
        pub fn apply(self: *Self, comptime func: anytype, args: anytype) !void {
            for (0..self.result.items.len) |i| {
                self.result.items[i] = @call(.auto, func, .{self.result.items[i]} ++ args);
            }
        }

        /// Sum of all elements
        pub fn sum(self: *Self) T {
            var total: T = 0;
            for (0..self.result.items.len) |i| {
                total += self.result.items[i];
            }
            return total;
        }

        /// Mean (average) of all elements
        pub fn mean(self: *Self) T {
            return self.sum() / @as(T, @floatFromInt(self.result.items.len));
        }

        /// Variance: E[(X - μ)²]
        pub fn variance(self: *Self) T {
            const mu = self.mean();
            var sum_sq_diff: T = 0;
            for (0..self.result.items.len) |i| {
                const diff = self.result.items[i] - mu;
                sum_sq_diff += diff * diff;
            }
            return sum_sq_diff / @as(T, @floatFromInt(self.result.items.len));
        }

        /// Standard deviation: sqrt(variance)
        pub fn stdDev(self: *Self) T {
            return @sqrt(self.variance());
        }

        /// Minimum element
        pub fn min(self: *Self) T {
            var min_val = self.result.items[0];
            for (1..self.result.items.len) |i| {
                if (self.result.items[i] < min_val) {
                    min_val = self.result.items[i];
                }
            }
            return min_val;
        }

        /// Maximum element
        pub fn max(self: *Self) T {
            var max_val = self.result.items[0];
            for (1..self.result.items.len) |i| {
                if (self.result.items[i] > max_val) {
                    max_val = self.result.items[i];
                }
            }
            return max_val;
        }

        /// Frobenius norm: sqrt(sum of squares of all elements)
        pub fn frobeniusNorm(self: *Self) T {
            var sum_squares: T = 0;
            for (0..self.result.items.len) |i| {
                sum_squares += self.result.items[i] * self.result.items[i];
            }
            return @sqrt(sum_squares);
        }

        /// L1 norm (nuclear norm): sum of absolute values of all elements
        pub fn l1Norm(self: *Self) T {
            var sum_abs: T = 0;
            for (0..self.result.items.len) |i| {
                sum_abs += @abs(self.result.items[i]);
            }
            return sum_abs;
        }

        /// Max norm (L-infinity): maximum absolute value
        pub fn maxNorm(self: *Self) T {
            var max_abs: T = 0;
            for (0..self.result.items.len) |i| {
                const abs_val = @abs(self.result.items[i]);
                if (abs_val > max_abs) {
                    max_abs = abs_val;
                }
            }
            return max_abs;
        }

        /// Trace: sum of diagonal elements (square matrices only)
        pub fn trace(self: *Self) T {
            assert(self.result.rows == self.result.cols);
            var sum_diag: T = 0;
            for (0..self.result.rows) |i| {
                sum_diag += self.result.at(i, i).*;
            }
            return sum_diag;
        }

        /// Add scalar to all elements
        pub fn offset(self: *Self, value: T) !void {
            for (0..self.result.items.len) |i| {
                self.result.items[i] += value;
            }
        }

        /// Raise all elements to power n (convenience method)
        pub fn pow(self: *Self, n: T) !void {
            const powN = struct {
                fn f(x: T, exponent: T) T {
                    return std.math.pow(T, x, exponent);
                }
            }.f;
            try self.apply(powN, .{n});
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

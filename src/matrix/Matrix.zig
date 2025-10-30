//! Dynamic matrix with runtime dimensions
//!
//! ## Chainable Operations
//!
//! Matrix operations can be chained together for expressive linear algebra:
//! ```zig
//! const result = try matrix.transpose().inverse().scale(2.0).eval();
//! ```
//!
//! Each operation executes immediately and returns a new Matrix. Errors are
//! stored internally and checked when you call `.eval()` at the end of the chain.
//!
//! ## Memory Management
//!
//! **Important**: When chaining multiple operations, each operation creates a new
//! matrix. For optimal memory usage, use an ArenaAllocator:
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(allocator);
//! defer arena.deinit();
//!
//! var matrix = try Matrix(f64).init(arena.allocator(), 10, 10);
//! // ... initialize matrix ...
//!
//! // Chain operations - intermediate matrices are managed by arena
//! const result = try matrix
//!     .transpose()
//!     .dot(other_matrix)
//!     .inverse()
//!     .eval();
//! ```
//!
//! With an arena allocator, all intermediate matrices created during the chain
//! are automatically freed when the arena is destroyed, preventing memory leaks.
//!
//! ## Available Operations
//!
//! - Element-wise: `add()`, `sub()`, `times()`, `scale()`, `offset()`, `pow()`
//! - Matrix operations: `dot()`, `transpose()`, `inverse()`
//! - Special products: `gram()`, `covariance()`
//! - Advanced: `gemm()` (general matrix multiply), `apply()` (custom functions)
//! - Extraction: `row()`, `col()`, `subMatrix()`

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const formatting = @import("formatting.zig");
const SMatrix = @import("SMatrix.zig").SMatrix;
const svd_module = @import("svd.zig");

/// Matrix-specific errors
pub const MatrixError = error{
    DimensionMismatch,
    NotSquare,
    Singular,
    OutOfBounds,
    OutOfMemory,
    NotConverged,
    InvalidArgument,
};

/// Matrix with runtime dimensions using flat array storage
pub fn Matrix(comptime T: type) type {
    return struct {
        pub const SvdMode = svd_module.SvdMode;
        pub const SvdOptions = svd_module.SvdOptions;
        pub const SvdResult = svd_module.SvdResult;
        const Self = @This();

        items: []T,
        rows: usize,
        cols: usize,
        allocator: std.mem.Allocator,
        err: ?MatrixError = null,

        pub const PseudoInverseOptions = struct {
            /// Optional absolute tolerance used to discard very small singular values.
            /// When null, a tolerance derived from the largest singular value is used.
            tolerance: ?T = null,
            /// Optional pointer that receives the effective numerical rank (#σ > tol).
            effective_rank: ?*usize = null,
        };

        pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            const data = try allocator.alloc(T, rows * cols);
            return Self{
                .items = data,
                .rows = rows,
                .cols = cols,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.items.len > 0) {
                self.allocator.free(self.items);
            }
        }

        /// Create a duplicate of this matrix with the specified allocator.
        /// The caller owns the returned matrix and must call deinit() on it.
        ///
        /// Error propagation: if this matrix carries a deferred error (`self.err != null`),
        /// the duplicate will also carry the same error and no allocation is performed.
        /// This preserves failure state across chains.
        ///
        /// Example:
        /// var copy = try matrix.dupe(allocator);
        /// defer copy.deinit();
        pub fn dupe(self: Self, allocator: std.mem.Allocator) !Self {
            if (self.err) |e| return errorMatrix(allocator, e);
            const result = try Self.init(allocator, self.rows, self.cols);
            @memcpy(result.items, self.items);
            return result;
        }

        /// Returns the rows and columns as a struct.
        pub fn shape(self: Self) struct { usize, usize } {
            return .{ self.rows, self.cols };
        }

        /// Retrieves the element at position row, col in the matrix.
        pub inline fn at(self: Self, row_idx: usize, col_idx: usize) *T {
            assert(row_idx < self.rows);
            assert(col_idx < self.cols);
            return &self.items[row_idx * self.cols + col_idx];
        }

        /// Returns a matrix with all elements set to value.
        pub fn initAll(allocator: std.mem.Allocator, rows: usize, cols: usize, value: T) !Self {
            const result = try init(allocator, rows, cols);
            @memset(result.items, value);
            return result;
        }

        /// Returns an identity-like matrix.
        pub fn identity(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            var result = try initAll(allocator, rows, cols, 0);
            for (0..@min(rows, cols)) |i| {
                result.at(i, i).* = 1;
            }
            return result;
        }

        /// Returns a matrix filled with random floating-point numbers.
        pub fn random(allocator: std.mem.Allocator, rows: usize, cols: usize, seed: ?u64) !Self {
            const s: u64 = seed orelse @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
            var prng: std.Random.DefaultPrng = .init(s);
            var rand = prng.random();
            var result = try init(allocator, rows, cols);
            for (0..rows * cols) |i| {
                result.items[i] = rand.float(T);
            }
            return result;
        }

        /// Cast matrix elements to a different type (rounds when converting float to int)
        pub fn cast(self: Self, comptime TargetType: type, allocator: std.mem.Allocator) !Matrix(TargetType) {
            var result = try Matrix(TargetType).init(allocator, self.rows, self.cols);
            for (self.items, 0..) |val, i| {
                result.items[i] = switch (@typeInfo(TargetType)) {
                    .int => switch (@typeInfo(T)) {
                        .float => @intFromFloat(@round(val)),
                        .int => @intCast(val),
                        else => @compileError("Unsupported cast from " ++ @typeName(T) ++ " to " ++ @typeName(TargetType)),
                    },
                    .float => switch (@typeInfo(T)) {
                        .float => @floatCast(val),
                        .int => @floatFromInt(val),
                        else => @compileError("Unsupported cast from " ++ @typeName(T) ++ " to " ++ @typeName(TargetType)),
                    },
                    else => @compileError("Target type must be numeric"),
                };
            }
            return result;
        }

        // ===== Chainable operations (return Self) =====

        /// Add another matrix element-wise
        pub fn add(self: Self, other: Self) Self {
            if (self.err != null) return self;
            if (other.err != null) return other;

            if (self.rows != other.rows or self.cols != other.cols) {
                return errorMatrix(self.allocator, error.DimensionMismatch);
            }

            var result = Matrix(T).init(self.allocator, self.rows, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..result.items.len) |i| {
                result.items[i] = self.items[i] + other.items[i];
            }
            return result;
        }

        /// Subtract another matrix element-wise
        pub fn sub(self: Self, other: Self) Self {
            if (self.err != null) return self;
            if (other.err != null) return other;

            if (self.rows != other.rows or self.cols != other.cols) {
                return errorMatrix(self.allocator, error.DimensionMismatch);
            }

            var result = Matrix(T).init(self.allocator, self.rows, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..result.items.len) |i| {
                result.items[i] = self.items[i] - other.items[i];
            }
            return result;
        }

        /// Scale all elements by a value
        pub fn scale(self: Self, value: T) Self {
            if (self.err != null) return self;

            var result = Matrix(T).init(self.allocator, self.rows, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..result.items.len) |i| {
                result.items[i] = self.items[i] * value;
            }
            return result;
        }

        /// Transpose the matrix
        pub fn transpose(self: Self) Self {
            if (self.err != null) return self;

            var result = Matrix(T).init(self.allocator, self.cols, self.rows) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.at(c, r).* = self.at(r, c).*;
                }
            }
            return result;
        }

        /// Perform element-wise multiplication
        pub fn times(self: Self, other: Self) Self {
            if (self.err != null) return self;
            if (other.err != null) return other;

            if (self.rows != other.rows or self.cols != other.cols) {
                return errorMatrix(self.allocator, error.DimensionMismatch);
            }

            var result = Matrix(T).init(self.allocator, self.rows, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..result.items.len) |i| {
                result.items[i] = self.items[i] * other.items[i];
            }
            return result;
        }

        /// Matrix multiplication (dot product) - changes dimensions
        pub fn dot(self: Self, other: Self) Self {
            return self.gemm(false, other, false, 1.0, 0.0, null);
        }

        /// Inverts the matrix using analytical formulas for small matrices (≤3x3)
        /// and Gauss-Jordan elimination for larger matrices
        pub fn inverse(self: Self) Self {
            if (self.err != null) return self;

            if (self.rows != self.cols) {
                return errorMatrix(self.allocator, error.NotSquare);
            }

            const n = self.rows;

            // Use analytical formulas for small matrices (more efficient)
            if (n <= 3) {
                const det = self.determinant() catch |e| {
                    return errorMatrix(self.allocator, e);
                };

                if (@abs(det) < std.math.floatEps(T)) {
                    return errorMatrix(self.allocator, error.Singular);
                }

                var inv = Matrix(T).init(self.allocator, n, n) catch |e| {
                    return errorMatrix(self.allocator, e);
                };

                switch (n) {
                    1 => inv.at(0, 0).* = 1 / det,
                    2 => {
                        inv.at(0, 0).* = self.at(1, 1).* / det;
                        inv.at(0, 1).* = -self.at(0, 1).* / det;
                        inv.at(1, 0).* = -self.at(1, 0).* / det;
                        inv.at(1, 1).* = self.at(0, 0).* / det;
                    },
                    3 => {
                        inv.at(0, 0).* = (self.at(1, 1).* * self.at(2, 2).* - self.at(1, 2).* * self.at(2, 1).*) / det;
                        inv.at(0, 1).* = (self.at(0, 2).* * self.at(2, 1).* - self.at(0, 1).* * self.at(2, 2).*) / det;
                        inv.at(0, 2).* = (self.at(0, 1).* * self.at(1, 2).* - self.at(0, 2).* * self.at(1, 1).*) / det;
                        inv.at(1, 0).* = (self.at(1, 2).* * self.at(2, 0).* - self.at(1, 0).* * self.at(2, 2).*) / det;
                        inv.at(1, 1).* = (self.at(0, 0).* * self.at(2, 2).* - self.at(0, 2).* * self.at(2, 0).*) / det;
                        inv.at(1, 2).* = (self.at(0, 2).* * self.at(1, 0).* - self.at(0, 0).* * self.at(1, 2).*) / det;
                        inv.at(2, 0).* = (self.at(1, 0).* * self.at(2, 1).* - self.at(1, 1).* * self.at(2, 0).*) / det;
                        inv.at(2, 1).* = (self.at(0, 1).* * self.at(2, 0).* - self.at(0, 0).* * self.at(2, 1).*) / det;
                        inv.at(2, 2).* = (self.at(0, 0).* * self.at(1, 1).* - self.at(0, 1).* * self.at(1, 0).*) / det;
                    },
                    else => unreachable,
                }

                return inv;
            } else {
                // Use Gauss-Jordan elimination for larger matrices
                return self.inverseGaussJordan();
            }
        }

        /// Computes the Moore-Penrose pseudoinverse using an SVD-based algorithm.
        /// Works for rectangular matrices and gracefully handles rank deficiency
        /// by discarding singular values below the provided tolerance. The optional
        /// `effective_rank` pointer receives the number of singular values kept.
        pub fn pseudoInverse(self: Self, options: PseudoInverseOptions) Self {
            if (self.err != null) return self;

            if (self.rows == 0 or self.cols == 0) {
                return errorMatrix(self.allocator, error.DimensionMismatch);
            }

            if (self.rows >= self.cols) {
                return self.pseudoInverseTall(options);
            }

            var transposed = self.transpose();
            if (transposed.err != null) return transposed;
            defer transposed.deinit();

            var pinv_transposed = transposed.pseudoInverseTall(options);
            if (pinv_transposed.err != null) return pinv_transposed;

            const result = pinv_transposed.transpose();
            pinv_transposed.deinit();
            return result;
        }

        fn pseudoInverseTall(self: Self, options: PseudoInverseOptions) Self {
            if (self.err != null) return self;
            std.debug.assert(self.rows >= self.cols);

            const allocator = self.allocator;
            const svd_options = SvdOptions{ .with_u = true, .with_v = true, .mode = .skinny_u };

            var svd_result = self.svd(allocator, svd_options) catch |e| {
                return errorMatrix(allocator, e);
            };
            defer svd_result.deinit();

            if (svd_result.converged != 0) {
                return errorMatrix(allocator, error.NotConverged);
            }

            const singular_count = svd_result.s.rows;
            const sigma_max: T = if (singular_count > 0) svd_result.s.at(0, 0).* else 0;
            if (sigma_max == 0) {
                const zero_rows = self.cols;
                const zero_cols = self.rows;
                const zero = Matrix(T).initAll(allocator, zero_rows, zero_cols, 0) catch |e| {
                    return errorMatrix(allocator, e);
                };
                if (options.effective_rank) |rank_ptr| {
                    rank_ptr.* = 0;
                }
                return zero;
            }
            const max_dim = if (self.rows > self.cols) self.rows else self.cols;
            const default_tol: T = sigma_max * @as(T, @floatFromInt(max_dim)) * std.math.floatEps(T);
            const tol = options.tolerance orelse default_tol;

            var sigma_inv = Matrix(T).initAll(allocator, singular_count, singular_count, 0) catch |e| {
                return errorMatrix(allocator, e);
            };
            defer sigma_inv.deinit();

            var effective_rank: usize = 0;
            for (0..singular_count) |i| {
                const sigma = svd_result.s.at(i, 0).*;
                if (sigma > tol) {
                    sigma_inv.at(i, i).* = 1 / sigma;
                    effective_rank += 1;
                }
            }

            if (options.effective_rank) |rank_ptr| {
                rank_ptr.* = effective_rank;
            }

            var u_t = svd_result.u.transpose();
            if (u_t.err != null) return u_t;
            defer u_t.deinit();

            var v_sigma = svd_result.v.dot(sigma_inv);
            if (v_sigma.err != null) return v_sigma;
            defer v_sigma.deinit();

            return v_sigma.dot(u_t);
        }

        /// Inverts the matrix using Gauss-Jordan elimination with partial pivoting
        /// This is a general method that works for any size square matrix
        fn inverseGaussJordan(self: Self) Self {
            if (self.err != null) return self;

            const n = self.rows;

            // Create augmented matrix [A | I]
            var augmented = Matrix(T).init(self.allocator, n, 2 * n) catch |e| {
                return errorMatrix(self.allocator, e);
            };
            defer augmented.deinit();

            // Copy original matrix to left half and identity to right half
            for (0..n) |i| {
                for (0..n) |j| {
                    augmented.at(i, j).* = self.at(i, j).*;
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
                    return errorMatrix(self.allocator, error.Singular);
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
            var inv = Matrix(T).init(self.allocator, n, n) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..n) |i| {
                for (0..n) |j| {
                    inv.at(i, j).* = augmented.at(i, n + j).*;
                }
            }

            return inv;
        }

        /// Extract a submatrix - changes dimensions
        pub fn subMatrix(self: Self, row_begin: usize, col_begin: usize, row_count: usize, col_count: usize) Self {
            if (self.err != null) return self;

            if (row_begin + row_count > self.rows or col_begin + col_count > self.cols) {
                return errorMatrix(self.allocator, error.OutOfBounds);
            }

            var result = Matrix(T).init(self.allocator, row_count, col_count) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..row_count) |r| {
                for (0..col_count) |c| {
                    result.at(r, c).* = self.at(row_begin + r, col_begin + c).*;
                }
            }

            return result;
        }

        /// Extract a column - changes dimensions
        pub fn col(self: Self, col_idx: usize) Self {
            if (self.err != null) return self;

            if (col_idx >= self.cols) {
                return errorMatrix(self.allocator, error.OutOfBounds);
            }

            var result = Matrix(T).init(self.allocator, self.rows, 1) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..self.rows) |r| {
                result.at(r, 0).* = self.at(r, col_idx).*;
            }

            return result;
        }

        /// Extract a row - changes dimensions
        pub fn row(self: Self, row_idx: usize) Self {
            if (self.err != null) return self;

            if (row_idx >= self.rows) {
                return errorMatrix(self.allocator, error.OutOfBounds);
            }

            var result = Matrix(T).init(self.allocator, 1, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..self.cols) |c| {
                result.at(0, c).* = self.at(row_idx, c).*;
            }

            return result;
        }

        /// Compute Gram matrix: X * X^T
        /// Useful for kernel methods and when rows < columns
        /// The resulting matrix is rows × rows
        pub fn gram(self: Self) Self {
            return self.gemm(false, self, true, 1.0, 0.0, null);
        }

        /// Compute covariance matrix: X^T * X
        /// Useful for statistical analysis and when rows > columns
        /// The resulting matrix is columns × columns
        pub fn covariance(self: Self) Self {
            return self.gemm(true, self, false, 1.0, 0.0, null);
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
        /// - If c is null, it defaults to zero matrix
        ///
        /// Examples:
        /// - Matrix multiplication: gemm(false, B, false, 1.0, 0.0, null)
        /// - Gram matrix: gemm(false, self, true, 1.0, 0.0, null) -> A * A^T
        /// - Covariance: gemm(true, self, false, 1.0, 0.0, null) -> A^T * A
        /// - Scaled product: gemm(false, B, false, 2.0, 0.0, null) -> 2 * A * B
        /// - Accumulation: gemm(false, B, false, 1.0, 1.0, C) -> A * B + C
        pub fn gemm(
            self: Self,
            trans_a: bool,
            other: Self,
            trans_b: bool,
            alpha: T,
            beta: T,
            c: ?Self,
        ) Self {
            if (self.err != null) return self;
            if (other.err != null) return other;

            if (c) |c_mat| {
                if (c_mat.err != null) return c_mat;
            }

            // Determine dimensions after potential transposition
            const a_rows = if (trans_a) self.cols else self.rows;
            const a_cols = if (trans_a) self.rows else self.cols;
            const b_rows = if (trans_b) other.cols else other.rows;
            const b_cols = if (trans_b) other.rows else other.cols;

            // Verify matrix multiplication compatibility
            if (a_cols != b_rows) {
                return errorMatrix(self.allocator, error.DimensionMismatch);
            }

            var result = Matrix(T).init(self.allocator, a_rows, b_cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            // Initialize with scaled C matrix if provided
            if (c) |c_mat| {
                if (c_mat.rows != a_rows or c_mat.cols != b_cols) {
                    result.deinit();
                    return errorMatrix(self.allocator, error.DimensionMismatch);
                }
                if (beta != 0) {
                    for (0..a_rows) |i| {
                        for (0..b_cols) |j| {
                            result.at(i, j).* = beta * c_mat.at(i, j).*;
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
                        if (self.rows == other.rows and
                            self.cols == other.cols and
                            std.mem.eql(T, self.items, other.items))
                        {
                            // For A * A, we need to transpose A for the second operand
                            var a_transposed = Matrix(T).init(self.allocator, b_cols, a_cols) catch |e| {
                                result.deinit();
                                return errorMatrix(self.allocator, e);
                            };
                            defer a_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    a_transposed.at(j, k).* = self.at(k, j).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, self, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: transpose B for cache-friendly row-major access
                            var b_transposed = Matrix(T).init(self.allocator, b_cols, a_cols) catch |e| {
                                result.deinit();
                                return errorMatrix(self.allocator, e);
                            };
                            defer b_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    b_transposed.at(j, k).* = other.at(k, j).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, self, b_transposed, alpha, a_rows, a_cols, b_cols);
                        }
                    } else if (trans_a and !trans_b) {
                        // Case 2: A^T * B - transpose A for cache-friendly row-major access
                        var a_transposed = Matrix(T).init(self.allocator, a_rows, a_cols) catch |e| {
                            result.deinit();
                            return errorMatrix(self.allocator, e);
                        };
                        defer a_transposed.deinit();
                        // Transpose A: a_transposed[i,j] = A[j,i]
                        for (0..a_cols) |k| {
                            for (0..a_rows) |i| {
                                a_transposed.at(i, k).* = self.at(k, i).*;
                            }
                        }
                        // Handle special case when A and B are the same matrix (for covariance)
                        if (self.rows == other.rows and
                            self.cols == other.cols and
                            std.mem.eql(T, self.items, other.items))
                        {
                            // For covariance (A^T * A), we need to also use transposed for B
                            simdGemmKernel(VecType, vec_len, &result, a_transposed, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: transpose B for row-wise access
                            var b_transposed = Matrix(T).init(self.allocator, b_cols, a_cols) catch |e| {
                                result.deinit();
                                return errorMatrix(self.allocator, e);
                            };
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
                        if (self.rows == other.rows and
                            self.cols == other.cols and
                            std.mem.eql(T, self.items, other.items))
                        {
                            // For A * A^T, we need to transpose A for the second operand
                            var a_transposed = Matrix(T).init(self.allocator, b_cols, a_cols) catch |e| {
                                result.deinit();
                                return errorMatrix(self.allocator, e);
                            };
                            defer a_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    a_transposed.at(j, k).* = self.at(j, k).*;
                                }
                            }
                            simdGemmKernel(VecType, vec_len, &result, self, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: B^T is naturally row-wise
                            simdGemmKernel(VecType, vec_len, &result, self, other, alpha, a_rows, a_cols, b_cols);
                        }
                    } else if (trans_a and trans_b) {
                        // Case 4: A^T * B^T - transpose A so rows are contiguous, reuse B rows directly
                        var a_transposed = Matrix(T).init(self.allocator, a_rows, a_cols) catch |e| {
                            result.deinit();
                            return errorMatrix(self.allocator, e);
                        };
                        defer a_transposed.deinit();
                        for (0..a_rows) |i| {
                            for (0..a_cols) |j| {
                                a_transposed.at(i, j).* = self.at(j, i).*;
                            }
                        }

                        // op(B) = B^T. Each column j of B^T corresponds to row j of B, which is already
                        // contiguous in memory, so we can feed `other` directly to the SIMD kernel.
                        simdGemmKernel(VecType, vec_len, &result, a_transposed, other, alpha, a_rows, a_cols, b_cols);
                    }
                } else {
                    // No SIMD support, use scalar implementation for all transpose combinations
                    for (0..a_rows) |i| {
                        for (0..b_cols) |j| {
                            var accumulator: T = 0;
                            for (0..a_cols) |k| {
                                const a_val = if (trans_a) self.at(k, i).* else self.at(i, k).*;
                                const b_val = if (trans_b) other.at(j, k).* else other.at(k, j).*;
                                accumulator += a_val * b_val;
                            }
                            result.at(i, j).* += alpha * accumulator;
                        }
                    }
                }
            }

            return result;
        }

        /// Scaled matrix multiplication: α * A * B
        /// Convenience method for common GEMM use case
        pub fn scaledDot(self: Self, other: Self, alpha: T) Self {
            return self.gemm(false, other, false, alpha, 0.0, null);
        }

        /// Matrix multiplication with transpose: A * B^T
        /// Convenience method for common GEMM use case
        pub fn dotTranspose(self: Self, other: Self) Self {
            return self.gemm(false, other, true, 1.0, 0.0, null);
        }

        /// Transpose matrix multiplication: A^T * B
        /// Convenience method for common GEMM use case
        pub fn transposeDot(self: Self, other: Self) Self {
            return self.gemm(true, other, false, 1.0, 0.0, null);
        }

        /// Apply a function to all matrix elements with optional arguments
        pub fn apply(self: Self, comptime func: anytype, args: anytype) Self {
            if (self.err != null) return self;

            var result = Matrix(T).init(self.allocator, self.rows, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..result.items.len) |i| {
                result.items[i] = @call(.auto, func, .{self.items[i]} ++ args);
            }
            return result;
        }

        /// Add scalar to all elements
        pub fn offset(self: Self, value: T) Self {
            if (self.err != null) return self;

            var result = Matrix(T).init(self.allocator, self.rows, self.cols) catch |e| {
                return errorMatrix(self.allocator, e);
            };

            for (0..result.items.len) |i| {
                result.items[i] = self.items[i] + value;
            }
            return result;
        }

        /// Raise all elements to power n (convenience method)
        pub fn pow(self: Self, n: T) Self {
            const powN = struct {
                fn f(x: T, exponent: T) T {
                    return std.math.pow(T, x, exponent);
                }
            }.f;
            return self.apply(powN, .{n});
        }

        fn ensureFloat(comptime context: []const u8) void {
            comptime if (@typeInfo(T) != .float)
                @compileError(context ++ " requires floating-point elements");
        }

        /// Terminal operation - evaluates the chain and returns result or error
        pub fn eval(self: Self) MatrixError!Self {
            if (self.err) |e| return e;
            return self;
        }

        /// Helper to create an error matrix
        fn errorMatrix(allocator: std.mem.Allocator, err: MatrixError) Self {
            return Self{
                .items = &.{},
                .rows = 0,
                .cols = 0,
                .allocator = allocator,
                .err = err,
            };
        }

        // ===== Query operations (return values, not Self) =====

        /// Sums all the elements in a matrix.
        pub fn sum(self: Self) T {
            var accum: T = 0;
            for (self.items) |val| {
                accum += val;
            }
            return accum;
        }

        /// Computes the Frobenius norm of the matrix.
        pub fn frobeniusNorm(self: Self) T {
            ensureFloat("frobeniusNorm");
            var squared_sum: T = 0;
            for (self.items) |val| {
                squared_sum += val * val;
            }
            return @sqrt(squared_sum);
        }

        /// Mean (average) of all elements
        pub fn mean(self: Self) T {
            return self.sum() / @as(T, @floatFromInt(self.items.len));
        }

        /// Variance: E[(X - μ)²]
        pub fn variance(self: Self) T {
            const mu = self.mean();
            var sum_sq_diff: T = 0;
            for (self.items) |val| {
                const diff = val - mu;
                sum_sq_diff += diff * diff;
            }
            return sum_sq_diff / @as(T, @floatFromInt(self.items.len));
        }

        /// Standard deviation: sqrt(variance)
        pub fn stdDev(self: Self) T {
            ensureFloat("stdDev");
            return @sqrt(self.variance());
        }

        /// Minimum element
        pub fn min(self: Self) T {
            var min_val = self.items[0];
            for (self.items[1..]) |val| {
                if (val < min_val) {
                    min_val = val;
                }
            }
            return min_val;
        }

        /// Maximum element
        pub fn max(self: Self) T {
            var max_val = self.items[0];
            for (self.items[1..]) |val| {
                if (val > max_val) {
                    max_val = val;
                }
            }
            return max_val;
        }

        /// Entrywise L1 norm: sum of absolute values of all elements
        pub fn l1Norm(self: Self) T {
            ensureFloat("l1Norm");
            var sum_abs: T = 0;
            for (self.items) |val| {
                sum_abs += @abs(val);
            }
            return sum_abs;
        }

        /// Max norm (L-infinity): maximum absolute value
        pub fn maxNorm(self: Self) T {
            ensureFloat("maxNorm");
            var max_abs: T = 0;
            for (self.items) |val| {
                const abs_val = @abs(val);
                if (abs_val > max_abs) {
                    max_abs = abs_val;
                }
            }
            return max_abs;
        }

        /// Minimum absolute value among all elements.
        pub fn minNorm(self: Self) T {
            ensureFloat("minNorm");
            if (self.items.len == 0) return 0;
            var min_abs = @abs(self.items[0]);
            for (self.items[1..]) |val| {
                const abs_val = @abs(val);
                if (abs_val < min_abs) {
                    min_abs = abs_val;
                }
            }
            return min_abs;
        }

        /// Counts non-zero elements.
        pub fn sparseNorm(self: Self) T {
            ensureFloat("sparseNorm");
            var count: T = 0;
            for (self.items) |val| {
                if (val != 0) count += 1;
            }
            return count;
        }

        /// Entrywise ℓᵖ norm with optional runtime exponent.
        pub fn elementNorm(self: Self, p: T) MatrixError!T {
            ensureFloat("elementNorm");
            if (std.math.isInf(p)) {
                if (p > 0) {
                    return self.maxNorm();
                } else if (p < 0) {
                    return self.minNorm();
                }
                return error.InvalidArgument;
            }
            if (!std.math.isFinite(p)) {
                return error.InvalidArgument;
            }
            if (p == 0) {
                return self.sparseNorm();
            } else if (p == 1) {
                return self.l1Norm();
            } else if (p == 2) {
                return self.frobeniusNorm();
            } else if (p > 0) {
                var accum: T = 0;
                for (self.items) |val| {
                    const abs_val = @abs(val);
                    if (abs_val != 0) {
                        accum += std.math.pow(T, abs_val, p);
                    }
                }
                return std.math.pow(T, accum, 1 / p);
            }
            return error.InvalidArgument;
        }

        fn leadingSingularValue(self: Self, allocator: std.mem.Allocator) !T {
            ensureFloat("leadingSingularValue");
            if (self.rows == 0 or self.cols == 0) return 0;

            if (self.rows < self.cols) {
                var transposed = self.transpose();
                if (transposed.err) |err| return err;
                defer transposed.deinit();
                return transposed.leadingSingularValue(allocator);
            }

            var svd_result = try self.svd(allocator, .{ .with_u = false, .with_v = false, .mode = .skinny_u });
            defer svd_result.deinit();
            if (svd_result.converged != 0) {
                return error.NotConverged;
            }
            return svd_result.s.at(0, 0).*;
        }

        fn sumSingularP(self: Self, allocator: std.mem.Allocator, exponent: T) !T {
            ensureFloat("schattenNorm");
            if (self.rows == 0 or self.cols == 0) return 0;

            if (self.rows >= self.cols) {
                var svd_result = try self.svd(allocator, .{ .with_u = false, .with_v = false, .mode = .skinny_u });
                defer svd_result.deinit();
                if (svd_result.converged != 0) {
                    return error.NotConverged;
                }
                var accum: T = 0;
                for (0..svd_result.s.rows) |i| {
                    accum += std.math.pow(T, svd_result.s.at(i, 0).*, exponent);
                }
                return accum;
            }

            var transposed = self.transpose();
            if (transposed.err) |err| return err;
            defer transposed.deinit();
            return transposed.sumSingularP(allocator, exponent);
        }

        /// Schatten p-norm of the matrix.
        pub fn schattenNorm(self: Self, allocator: std.mem.Allocator, p: T) !T {
            ensureFloat("schattenNorm");
            if (std.math.isInf(p)) {
                if (p > 0) {
                    return self.leadingSingularValue(allocator);
                }
                return error.InvalidArgument;
            }
            if (!std.math.isFinite(p) or p < 1) {
                return error.InvalidArgument;
            }
            if (p == 1) {
                return self.sumSingularP(allocator, 1);
            } else if (p == 2) {
                return self.frobeniusNorm();
            } else {
                const accum = try self.sumSingularP(allocator, p);
                return std.math.pow(T, accum, 1 / p);
            }
        }

        /// Sum of singular values.
        pub fn nuclearNorm(self: Self, allocator: std.mem.Allocator) !T {
            return self.schattenNorm(allocator, 1);
        }

        /// Largest singular value.
        pub fn spectralNorm(self: Self, allocator: std.mem.Allocator) !T {
            return self.schattenNorm(allocator, std.math.inf(T));
        }

        /// Induced operator norms with p ∈ {1, 2, ∞}.
        pub fn inducedNorm(self: Self, allocator: std.mem.Allocator, p: T) !T {
            ensureFloat("inducedNorm");
            if (p == 1) {
                var max_sum: T = 0;
                for (0..self.cols) |c| {
                    var col_sum: T = 0;
                    for (0..self.rows) |r| {
                        col_sum += @abs(self.items[r * self.cols + c]);
                    }
                    if (col_sum > max_sum) {
                        max_sum = col_sum;
                    }
                }
                return max_sum;
            } else if (p == 2) {
                return try self.leadingSingularValue(allocator);
            } else if (std.math.isInf(p) and p > 0) {
                var max_sum: T = 0;
                for (0..self.rows) |r| {
                    var row_sum: T = 0;
                    for (0..self.cols) |c| {
                        row_sum += @abs(self.items[r * self.cols + c]);
                    }
                    if (row_sum > max_sum) {
                        max_sum = row_sum;
                    }
                }
                return max_sum;
            }
            return error.InvalidArgument;
        }

        /// Trace: sum of diagonal elements (square matrices only)
        pub fn trace(self: Self) T {
            assert(self.rows == self.cols);
            var sum_diag: T = 0;
            for (0..self.rows) |i| {
                sum_diag += self.at(i, i).*;
            }
            return sum_diag;
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
        pub fn lu(self: Self) !LuResult {
            comptime assert(@typeInfo(T) == .float);
            const n = self.rows;
            assert(n == self.cols); // Must be square

            // Create working copy
            var work: Matrix(T) = try .init(self.allocator, n, n);
            defer work.deinit();
            @memcpy(work.items, self.items);

            // Initialize L as identity, U as zero
            var l: Matrix(T) = try .init(self.allocator, n, n);
            errdefer l.deinit();
            var u: Matrix(T) = try .init(self.allocator, n, n);
            errdefer u.deinit();

            // Initialize permutation vector
            var p: Matrix(T) = try .init(self.allocator, n, 1);
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

            return .{
                .l = l,
                .u = u,
                .p = p,
                .sign = sign,
            };
        }

        /// Computes the determinant of the matrix using analytical formulas for small matrices
        /// and LU decomposition for larger matrices
        pub fn determinant(self: Self) !T {
            comptime assert(@typeInfo(T) == .float);
            assert(self.rows == self.cols);
            assert(self.rows > 0);

            const n = self.rows;

            // Use analytical formulas for small matrices (more efficient)
            return switch (n) {
                1 => self.at(0, 0).*,
                2 => self.at(0, 0).* * self.at(1, 1).* -
                    self.at(0, 1).* * self.at(1, 0).*,
                3 => self.at(0, 0).* * self.at(1, 1).* * self.at(2, 2).* +
                    self.at(0, 1).* * self.at(1, 2).* * self.at(2, 0).* +
                    self.at(0, 2).* * self.at(1, 0).* * self.at(2, 1).* -
                    self.at(0, 2).* * self.at(1, 1).* * self.at(2, 0).* -
                    self.at(0, 1).* * self.at(1, 0).* * self.at(2, 2).* -
                    self.at(0, 0).* * self.at(1, 2).* * self.at(2, 1).*,
                else => blk: {
                    // Use LU decomposition for larger matrices
                    var lu_result = try self.lu();
                    defer lu_result.deinit();

                    // det(A) = sign * product of diagonal elements of U
                    var det = lu_result.sign;
                    for (0..n) |i| det *= lu_result.u.at(i, i).*;
                    break :blk det;
                },
            };
        }

        pub const QrResult = struct {
            q: Matrix(T), // Orthogonal matrix (m×n)
            r: Matrix(T), // Upper triangular matrix (n×n)
            perm: []usize, // Column permutation indices (length n)
            rank: usize, // Numerical rank of the matrix
            col_norms: []T, // Final column norms after pivoting (diagnostic)
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
                self.q.deinit();
                self.r.deinit();
                self.allocator.free(self.perm);
                self.allocator.free(self.col_norms);
            }

            /// Get the permutation as a matrix if needed
            /// Since perm[j] tells us which original column is at position j,
            /// the permutation matrix P should satisfy: A*P has column perm[j] of A at position j
            pub fn permutationMatrix(self: *const @This()) !Matrix(T) {
                const n = self.perm.len;
                var p: Matrix(T) = try .initAll(self.allocator, n, n, 0);
                // P[i,j] = 1 if original column i is at position j
                // Since perm[j] = i means original column i is at position j
                for (0..n) |j| {
                    p.at(self.perm[j], j).* = 1;
                }
                return p;
            }
        };

        /// Compute QR decomposition with column pivoting using Modified Gram-Schmidt algorithm
        /// Returns Q, R matrices and permutation such that A*P = Q*R where Q is orthogonal and R is upper triangular
        /// Also computes the numerical rank of the matrix
        pub fn qr(self: Self) !QrResult {
            comptime assert(@typeInfo(T) == .float);
            const m = self.rows;
            const n = self.cols;

            // Initialize matrices
            var q: Matrix(T) = try .init(self.allocator, m, n);
            errdefer q.deinit();
            var r: Matrix(T) = try .init(self.allocator, n, n);
            errdefer r.deinit();

            // Initialize permutation and column norms
            const perm = try self.allocator.alloc(usize, n);
            errdefer self.allocator.free(perm);
            const col_norms = try self.allocator.alloc(T, n);
            errdefer self.allocator.free(col_norms);

            // Initialize permutation as identity
            for (0..n) |i| {
                perm[i] = i;
            }

            // Copy A to Q (will be modified in-place)
            @memcpy(q.items, self.items);

            // Initialize R as zero
            @memset(r.items, 0);

            // Compute initial column norms
            for (0..n) |j| {
                var norm_sq: T = 0;
                for (0..m) |i| {
                    const val = q.at(i, j).*;
                    norm_sq += val * val;
                }
                col_norms[j] = norm_sq;
            }

            // Compute tolerance for rank determination
            // Find maximum initial column norm for scaling
            var max_norm: T = 0;
            for (0..n) |j| {
                max_norm = @max(max_norm, @sqrt(col_norms[j]));
            }
            const eps = std.math.floatEps(T);
            // Use a practical tolerance that accounts for accumulated rounding errors
            // Standard practice is to use sqrt(eps) * norm for rank determination
            const sqrt_eps = @sqrt(eps);
            const tol = sqrt_eps * @as(T, @floatFromInt(@max(m, n))) * max_norm;

            var computed_rank: usize = 0;

            // Modified Gram-Schmidt with column pivoting
            for (0..n) |k| {

                // Find column with maximum norm from k to n-1
                var max_col = k;
                var max_col_norm = col_norms[k];
                for (k + 1..n) |j| {
                    if (col_norms[j] > max_col_norm) {
                        max_col_norm = col_norms[j];
                        max_col = j;
                    }
                }

                // Swap columns if needed
                if (max_col != k) {
                    // Swap in Q
                    for (0..m) |i| {
                        const temp = q.at(i, k).*;
                        q.at(i, k).* = q.at(i, max_col).*;
                        q.at(i, max_col).* = temp;
                    }
                    // Swap in R (for already computed rows)
                    for (0..k) |i| {
                        const temp = r.at(i, k).*;
                        r.at(i, k).* = r.at(i, max_col).*;
                        r.at(i, max_col).* = temp;
                    }
                    // Swap in permutation
                    const temp_perm = perm[k];
                    perm[k] = perm[max_col];
                    perm[max_col] = temp_perm;
                    // Swap column norms
                    const temp_norm = col_norms[k];
                    col_norms[k] = col_norms[max_col];
                    col_norms[max_col] = temp_norm;
                }

                // Compute R[k,k] = ||Q[:,k]||
                r.at(k, k).* = @sqrt(col_norms[k]);

                // Check for rank deficiency
                if (r.at(k, k).* <= tol) {
                    // Set remaining diagonal elements to zero
                    for (k..n) |j| {
                        r.at(j, j).* = 0;
                        col_norms[j] = 0;
                    }
                    break;
                }

                // Count this as a non-zero pivot
                computed_rank += 1;

                // Normalize Q[:,k]
                const inv_norm = 1.0 / r.at(k, k).*;
                for (0..m) |i| {
                    q.at(i, k).* *= inv_norm;
                }

                // Orthogonalize remaining columns
                for (k + 1..n) |j| {
                    // Compute R[k,j] = Q[:,k]^T * Q[:,j]
                    var dot_product: T = 0;
                    for (0..m) |i| {
                        dot_product += q.at(i, k).* * q.at(i, j).*;
                    }
                    r.at(k, j).* = dot_product;

                    // Q[:,j] = Q[:,j] - R[k,j] * Q[:,k]
                    for (0..m) |i| {
                        q.at(i, j).* -= r.at(k, j).* * q.at(i, k).*;
                    }

                    // Update column norm efficiently
                    // ||v - proj||^2 = ||v||^2 - ||proj||^2
                    col_norms[j] -= dot_product * dot_product;
                    // Ensure non-negative due to rounding
                    if (col_norms[j] < 0) {
                        col_norms[j] = 0;
                    }
                }
            }

            // Store final column norms (after orthogonalization)
            for (0..n) |j| {
                col_norms[j] = @sqrt(col_norms[j]);
            }

            return .{
                .q = q,
                .r = r,
                .perm = perm,
                .rank = computed_rank,
                .col_norms = col_norms,
                .allocator = self.allocator,
            };
        }

        /// Compute the numerical rank of the matrix
        /// Uses QR decomposition with column pivoting
        /// The rank is determined by counting non-zero diagonal elements in R
        /// above a tolerance based on machine precision and matrix norm
        pub fn rank(self: Self) !usize {
            comptime assert(@typeInfo(T) == .float);
            // Compute QR decomposition with column pivoting
            var qr_result = try self.qr();
            defer qr_result.deinit();

            // The rank is already computed by the QR algorithm
            return qr_result.rank;
        }

        /// Returns a formatter for decimal notation with specified precision
        pub fn decimal(self: Self, comptime precision: u8) formatting.DecimalFormatter(Self, precision) {
            return formatting.DecimalFormatter(Self, precision){ .matrix = self };
        }

        /// Returns a formatter for scientific notation
        pub fn scientific(self: Self) formatting.ScientificFormatter(Self) {
            return formatting.ScientificFormatter(Self){ .matrix = self };
        }

        /// Performs singular value decomposition (SVD) on the matrix.
        /// Returns the decomposition A = U × Σ × V^T where:
        /// - U contains left singular vectors
        /// - Σ is a diagonal matrix of singular values (stored as a vector)
        /// - V contains right singular vectors
        ///
        /// Requires rows >= cols. See `SvdOptions` for configuration details.
        pub fn svd(self: Self, allocator: std.mem.Allocator, options: SvdOptions) !SvdResult(T) {
            comptime assert(@typeInfo(T) == .float);
            std.debug.assert(self.rows >= self.cols);
            return svd_module.svd(T, allocator, self, options);
        }

        /// Default formatting (scientific notation)
        pub fn format(self: Self, writer: *std.Io.Writer) !void {
            try formatting.formatMatrix(self, "{e}", writer);
        }

        /// Converts a Matrix to a static SMatrix with the given dimensions
        pub fn toSMatrix(self: Self, comptime rows: usize, comptime cols: usize) SMatrix(T, rows, cols) {
            assert(self.rows == rows);
            assert(self.cols == cols);

            var result: SMatrix(T, rows, cols) = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.at(r, c).* = self.at(r, c).*;
                }
            }
            return result;
        }

        /// Creates a Matrix from a static SMatrix
        pub fn fromSMatrix(allocator: std.mem.Allocator, smatrix: anytype) !Matrix(T) {
            var result = try Matrix(T).init(allocator, smatrix.rows, smatrix.cols);
            for (0..smatrix.rows) |r| {
                for (0..smatrix.cols) |c| {
                    result.at(r, c).* = smatrix.at(r, c).*;
                }
            }
            return result;
        }
    };
}

// Tests for dynamic Matrix functionality
test "matrix propagates chained errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var singular = try Matrix(f64).init(arena.allocator(), 2, 2);
    defer singular.deinit();

    singular.at(0, 0).* = 1;
    singular.at(0, 1).* = 2;
    singular.at(1, 0).* = 2;
    singular.at(1, 1).* = 4;

    var invalid = singular.inverse();
    defer invalid.deinit();

    var valid = try Matrix(f64).initAll(arena.allocator(), 2, 2, 1.0);
    defer valid.deinit();

    var left_error = invalid.add(valid);
    defer left_error.deinit();
    try expectError(MatrixError.Singular, left_error.eval());

    var right_error = valid.add(invalid);
    defer right_error.deinit();
    try expectError(MatrixError.Singular, right_error.eval());

    var sub_error = valid.sub(invalid);
    defer sub_error.deinit();
    try expectError(MatrixError.Singular, sub_error.eval());

    var times_error = valid.times(invalid);
    defer times_error.deinit();
    try expectError(MatrixError.Singular, times_error.eval());

    var gemm_other_error = valid.gemm(false, invalid, false, 1.0, 0.0, null);
    defer gemm_other_error.deinit();
    try expectError(MatrixError.Singular, gemm_other_error.eval());

    var gemm_c_error = valid.gemm(false, valid, false, 1.0, 1.0, invalid);
    defer gemm_c_error.deinit();
    try expectError(MatrixError.Singular, gemm_c_error.eval());
}

test "matrix elementNorm invalid exponent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var m = try Matrix(f64).init(arena.allocator(), 1, 1);
    defer m.deinit();
    m.at(0, 0).* = 1.0;

    try std.testing.expectError(MatrixError.InvalidArgument, m.elementNorm(-1.0));
    try std.testing.expectError(MatrixError.InvalidArgument, m.elementNorm(std.math.nan(f64)));
}

test "dynamic matrix format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test dynamic Matrix formatting
    var dm = try Matrix(f32).init(arena.allocator(), 2, 2);
    dm.at(0, 0).* = 3.14159;
    dm.at(0, 1).* = -2.71828;
    dm.at(1, 0).* = 1.41421;
    dm.at(1, 1).* = 0.57721;

    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Test default format (scientific notation)
    try stream.print("{f}", .{dm});
    const result_default = buffer[0..stream.end];
    const expected_default =
        \\[ 3.14159e0  -2.71828e0 ]
        \\[ 1.41421e0   5.7721e-1 ]
    ;
    try expectEqualStrings(expected_default, result_default);

    // Test decimal(3) formatting
    stream.end = 0;
    try stream.print("{f}", .{dm.decimal(3)});
    const result_decimal3 = buffer[0..stream.end];
    const expected_decimal3 =
        \\[ 3.142  -2.718 ]
        \\[ 1.414   0.577 ]
    ;
    try expectEqualStrings(expected_decimal3, result_decimal3);

    // Test decimal(0) formatting
    stream.end = 0;
    try stream.print("{f}", .{dm.decimal(0)});
    const result_decimal0 = buffer[0..stream.end];
    const expected_decimal0 =
        \\[ 3  -3 ]
        \\[ 1   1 ]
    ;
    try expectEqualStrings(expected_decimal0, result_decimal0);

    // Test scientific formatting
    stream.end = 0;
    try stream.print("{f}", .{dm.scientific()});
    const result_scientific = buffer[0..stream.end];
    const expected_scientific =
        \\[ 3.14159e0  -2.71828e0 ]
        \\[ 1.41421e0   5.7721e-1 ]
    ;
    try expectEqualStrings(expected_scientific, result_scientific);
}

test "matrix conversions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test SMatrix to Matrix conversion
    const static_matrix = SMatrix(f64, 2, 3).init(.{
        .{ 1.5, 2.5, 3.5 },
        .{ 4.5, 5.5, 6.5 },
    });
    const dynamic_matrix = try static_matrix.toMatrix(arena.allocator());
    try expectEqual(@as(usize, 2), dynamic_matrix.rows);
    try expectEqual(@as(usize, 3), dynamic_matrix.cols);
    try expectEqual(@as(f64, 1.5), dynamic_matrix.at(0, 0).*);
    try expectEqual(@as(f64, 6.5), dynamic_matrix.at(1, 2).*);

    // Test round-trip conversion: SMatrix -> Matrix -> SMatrix
    const back_to_static = dynamic_matrix.toSMatrix(2, 3);
    for (0..2) |r| {
        for (0..3) |c| {
            try expectEqual(static_matrix.at(r, c).*, back_to_static.at(r, c).*);
        }
    }
}

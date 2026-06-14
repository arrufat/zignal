//! Dynamic matrix with runtime dimensions
//!
//! ## Single operations
//!
//! Each operation that produces a new matrix returns `MatrixError!Matrix(T)`.
//! Use standard Zig error handling:
//!
//! ```zig
//! const product = try a.dot(b);
//! defer product.deinit();
//! ```
//!
//! ## Chained operations
//!
//! For multi-step chains, use `chain()` to obtain a `Chain(T)`. The
//! `Chain` frees each intermediate as the next op runs, so peak memory is
//! at most two matrices regardless of chain length.
//!
//! ```zig
//! var p = matrix.chain();
//! defer p.deinit();
//! const result = try p.transpose().dot(other).inv().toOwned();
//! defer result.deinit();
//! ```
//!
//! `defer p.deinit()` is safe whether or not `toOwned()` ran — `toOwned`
//! transfers ownership of the final matrix to the caller and clears the chain.
//!
//! ## Available Operations
//!
//! - Element-wise: `add()`, `sub()`, `hadamard()`, `scale()`, `offset()`, `pow()`
//! - Matrix operations: `dot()`, `transpose()`, `inv()`
//! - Special products: `gram()`, `covariance()`
//! - Advanced: `gemm()` (general matrix multiply), `apply()` (custom functions)
//! - Extraction: `row()`, `col()`, `subMatrix()`

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const meta = @import("../meta.zig");
const formatting = @import("formatting.zig");
const SMatrix = @import("SMatrix.zig").SMatrix;
const svd_module = @import("svd.zig");
const eigen_module = @import("eigen.zig");
const Chain = @import("Chain.zig").Chain;

/// Matrix-specific errors
pub const MatrixError = error{
    DimensionMismatch,
    NotSquare,
    Singular,
    OutOfBounds,
    OutOfMemory,
    NotConverged,
    InvalidArgument,
    NotPositiveDefinite,
    NotSymmetric,
};

/// Recommended alignment for SIMD operations (64 bytes covers AVX-512)
const simd_alignment = 64;

/// Matrix with runtime dimensions using flat array storage
pub fn Matrix(comptime T: type) type {
    return struct {
        pub const SvdMode = svd_module.Mode;
        pub const SvdOptions = svd_module.Options;
        pub const SvdResult = svd_module.Result;
        pub const EighResult = eigen_module.Result;

        pub const Permutation = struct {
            pub const Mode = enum { row, column };

            indices: []u32,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
                self.allocator.free(self.indices);
            }

            /// Returns the permutation as a square matrix P.
            /// For LU, PA = LU (use .row). For QR, AP = QR (use .column).
            pub fn toMatrix(self: *const @This(), mode: Mode) !Matrix(T) {
                const n = self.indices.len;
                var p_mat: Matrix(T) = try .initAll(self.allocator, @intCast(n), @intCast(n), 0);
                switch (mode) {
                    .row => {
                        // For PA = LU
                        for (0..n) |i| {
                            p_mat.at(i, self.indices[i]).* = 1;
                        }
                    },
                    .column => {
                        // For AP = QR
                        for (0..n) |j| {
                            p_mat.at(self.indices[j], j).* = 1;
                        }
                    },
                }
                return p_mat;
            }
        };

        const Self = @This();

        items: []align(simd_alignment) T,
        rows: u32,
        cols: u32,
        allocator: std.mem.Allocator,

        pub const PinvOptions = struct {
            /// Optional absolute tolerance used to discard very small singular values.
            /// When null, a tolerance derived from the largest singular value is used.
            tolerance: ?T = null,
            /// Optional pointer that receives the effective numerical rank (#σ > tol).
            effective_rank: ?*u32 = null,
        };

        pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !Self {
            const data = try allocator.alignedAlloc(T, comptime .fromByteUnits(simd_alignment), @as(usize, rows) * cols);
            return Self{
                .items = data,
                .rows = rows,
                .cols = cols,
                .allocator = allocator,
            };
        }

        /// Initializes a matrix from a flat slice of values.
        /// The slice length must be exactly rows * cols.
        pub fn fromSlice(allocator: std.mem.Allocator, rows: u32, cols: u32, data: []const T) !Self {
            if (data.len != @as(usize, rows) * @as(usize, cols)) {
                return error.DimensionMismatch;
            }
            const result = try init(allocator, rows, cols);
            @memcpy(result.items, data);
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        /// Relinquish ownership of the matrix's buffer. Returns the current
        /// matrix and resets the receiver to an empty state.
        pub fn release(self: *Self) Self {
            const out = self.*;
            self.items = self.items[0..0];
            self.rows = 0;
            self.cols = 0;
            return out;
        }

        /// Lift this matrix into a `Chain(T)` for fluent chaining of multiple ops.
        /// The matrix is borrowed — callers retain ownership and must still `deinit` it.
        pub fn chain(self: Self) Chain(T) {
            return Chain(T).from(self);
        }

        /// Cast the underlying items of the matrix from T to U.
        pub fn as(self: Self, allocator: std.mem.Allocator, comptime U: type) !Matrix(U) {
            const result: Matrix(U) = try .init(allocator, self.rows, self.cols);
            for (result.items, self.items) |*dst, src| {
                dst.* = meta.as(U, src);
            }
            return result;
        }

        /// Create a duplicate of this matrix with the specified allocator.
        /// The caller owns the returned matrix and must call deinit() on it.
        pub fn dupe(self: Self, allocator: std.mem.Allocator) !Self {
            const result = try Self.init(allocator, self.rows, self.cols);
            @memcpy(result.items, self.items);
            return result;
        }

        /// Returns the rows and columns as a struct.
        pub fn shape(self: Self) struct { u32, u32 } {
            return .{ self.rows, self.cols };
        }

        /// Retrieves the element at position row, col in the matrix.
        pub inline fn at(self: Self, row_idx: usize, col_idx: usize) *T {
            assert(row_idx < self.rows);
            assert(col_idx < self.cols);
            return &self.items[row_idx * self.cols + col_idx];
        }

        /// Returns a matrix with all elements set to value.
        pub fn initAll(allocator: std.mem.Allocator, rows: u32, cols: u32, value: T) !Self {
            const result = try init(allocator, rows, cols);
            @memset(result.items, value);
            return result;
        }

        /// Returns an identity-like matrix.
        pub fn identity(allocator: std.mem.Allocator, rows: u32, cols: u32) !Self {
            var result = try initAll(allocator, rows, cols, 0);
            for (0..@min(rows, cols)) |i| {
                result.at(i, i).* = 1;
            }
            return result;
        }

        /// Returns a square diagonal matrix with `values` on the main diagonal (dlib's `diagm`).
        /// The result is `values.len × values.len`.
        pub fn diagonal(allocator: std.mem.Allocator, values: []const T) !Self {
            const n: u32 = @intCast(values.len);
            var result = try initAll(allocator, n, n, 0);
            for (values, 0..) |value, i| result.at(i, i).* = value;
            return result;
        }

        /// Returns a matrix filled with random floating-point numbers.
        pub fn random(allocator: std.mem.Allocator, rows: u32, cols: u32, seed: u64) !Self {
            var prng: std.Random.DefaultPrng = .init(seed);
            var rand = prng.random();

            const result = try init(allocator, rows, cols);
            for (result.items) |*item| {
                item.* = rand.float(T);
            }
            return result;
        }

        // ===== Summary operations =====

        /// Sum all elements across each row, returning a 1 × cols row vector.
        pub fn sumRows(self: Self) MatrixError!Self {
            var result: Matrix(T) = try .initAll(self.allocator, 1, self.cols, 0);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.at(0, c).* += self.at(r, c).*;
                }
            }
            return result;
        }

        /// Sum all elements down each column, returning a rows × 1 column vector.
        pub fn sumCols(self: Self) MatrixError!Self {
            var result: Matrix(T) = try .initAll(self.allocator, self.rows, 1, 0);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.at(r, 0).* += self.at(r, c).*;
                }
            }
            return result;
        }

        // ===== Chainable operations (return Self) =====

        /// Add another matrix element-wise
        pub fn add(self: Self, other: Self) MatrixError!Self {
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }
            const result: Matrix(T) = try .init(self.allocator, self.rows, self.cols);
            for (result.items, self.items, other.items) |*dst, a, b| {
                dst.* = a + b;
            }
            return result;
        }

        /// Add another matrix element-wise (in-place)
        pub fn addBy(self: *Self, other: Self) MatrixError!void {
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }
            for (self.items, other.items) |*dst, b| {
                dst.* += b;
            }
        }

        /// Subtract another matrix element-wise
        pub fn sub(self: Self, other: Self) MatrixError!Self {
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }
            const result: Matrix(T) = try .init(self.allocator, self.rows, self.cols);
            for (result.items, self.items, other.items) |*dst, a, b| {
                dst.* = a - b;
            }
            return result;
        }

        /// Subtract another matrix element-wise (in-place)
        pub fn subBy(self: *Self, other: Self) MatrixError!void {
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }
            for (self.items, other.items) |*dst, b| {
                dst.* -= b;
            }
        }

        /// Scale all elements by a value
        pub fn scale(self: Self, value: T) MatrixError!Self {
            const result: Matrix(T) = try .init(self.allocator, self.rows, self.cols);
            for (result.items, self.items) |*dst, a| {
                dst.* = a * value;
            }
            return result;
        }

        /// Scale all elements by a value (in-place)
        pub fn scaleBy(self: *Self, value: T) MatrixError!void {
            for (self.items) |*item| {
                item.* *= value;
            }
        }

        /// Transpose the matrix
        pub fn transpose(self: Self) MatrixError!Self {
            var result: Matrix(T) = try .init(self.allocator, self.cols, self.rows);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.at(c, r).* = self.at(r, c).*;
                }
            }
            return result;
        }

        /// Perform element-wise multiplication
        pub fn hadamard(self: Self, other: Self) MatrixError!Self {
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }
            const result: Matrix(T) = try .init(self.allocator, self.rows, self.cols);
            for (result.items, self.items, other.items) |*dst, a, b| {
                dst.* = a * b;
            }
            return result;
        }

        /// Perform element-wise multiplication (in-place)
        pub fn hadamardBy(self: *Self, other: Self) MatrixError!void {
            if (self.rows != other.rows or self.cols != other.cols) {
                return error.DimensionMismatch;
            }
            for (self.items, other.items) |*dst, b| {
                dst.* *= b;
            }
        }

        /// Matrix multiplication (dot product) - changes dimensions
        pub fn dot(self: Self, other: Self) MatrixError!Self {
            return self.gemm(false, other, false, 1.0, 0.0, null);
        }

        /// Inverts the matrix using analytical formulas for small matrices (≤3x3)
        /// and Gauss-Jordan elimination for larger matrices
        pub fn inv(self: Self) MatrixError!Self {
            if (self.rows != self.cols) return error.NotSquare;

            const n = self.rows;

            // Use analytical formulas for small matrices (more efficient)
            if (n <= 3) {
                switch (n) {
                    1 => {
                        const d = self.at(0, 0).*;
                        if (@abs(d) < std.math.floatEps(T)) return error.Singular;
                        var ans: Matrix(T) = try .init(self.allocator, n, n);
                        ans.at(0, 0).* = 1 / d;
                        return ans;
                    },
                    2 => {
                        const d = self.at(0, 0).* * self.at(1, 1).* - self.at(0, 1).* * self.at(1, 0).*;
                        if (@abs(d) < std.math.floatEps(T)) return error.Singular;
                        var ans: Matrix(T) = try .init(self.allocator, n, n);
                        ans.at(0, 0).* = self.at(1, 1).* / d;
                        ans.at(0, 1).* = -self.at(0, 1).* / d;
                        ans.at(1, 0).* = -self.at(1, 0).* / d;
                        ans.at(1, 1).* = self.at(0, 0).* / d;
                        return ans;
                    },
                    3 => {
                        const c00 = self.at(1, 1).* * self.at(2, 2).* - self.at(1, 2).* * self.at(2, 1).*;
                        const c01 = self.at(0, 2).* * self.at(2, 1).* - self.at(0, 1).* * self.at(2, 2).*;
                        const c02 = self.at(0, 1).* * self.at(1, 2).* - self.at(0, 2).* * self.at(1, 1).*;

                        const d = self.at(0, 0).* * c00 + self.at(1, 0).* * c01 + self.at(2, 0).* * c02;
                        if (@abs(d) < std.math.floatEps(T)) return error.Singular;

                        var ans: Matrix(T) = try .init(self.allocator, n, n);
                        ans.at(0, 0).* = c00 / d;
                        ans.at(0, 1).* = c01 / d;
                        ans.at(0, 2).* = c02 / d;
                        ans.at(1, 0).* = (self.at(1, 2).* * self.at(2, 0).* - self.at(1, 0).* * self.at(2, 2).*) / d;
                        ans.at(1, 1).* = (self.at(0, 0).* * self.at(2, 2).* - self.at(0, 2).* * self.at(2, 0).*) / d;
                        ans.at(1, 2).* = (self.at(0, 2).* * self.at(1, 0).* - self.at(0, 0).* * self.at(1, 2).*) / d;
                        ans.at(2, 0).* = (self.at(1, 0).* * self.at(2, 1).* - self.at(1, 1).* * self.at(2, 0).*) / d;
                        ans.at(2, 1).* = (self.at(0, 1).* * self.at(2, 0).* - self.at(0, 0).* * self.at(2, 1).*) / d;
                        ans.at(2, 2).* = (self.at(0, 0).* * self.at(1, 1).* - self.at(0, 1).* * self.at(1, 0).*) / d;
                        return ans;
                    },
                    else => unreachable,
                }
            } else {
                // Use Gauss-Jordan elimination for larger matrices
                return self.inverseGaussJordan();
            }
        }

        /// Computes the Moore-Penrose pseudoinverse using an SVD-based algorithm.
        /// Works for rectangular matrices and gracefully handles rank deficiency
        /// by discarding singular values below the provided tolerance. The optional
        /// `effective_rank` pointer receives the number of singular values kept.
        pub fn pinv(self: Self, options: PinvOptions) MatrixError!Self {
            if (self.rows == 0 or self.cols == 0) return error.DimensionMismatch;

            if (self.rows >= self.cols) {
                return self.pinvTall(options);
            }

            var transposed = try self.transpose();
            defer transposed.deinit();

            var pinv_transposed = try transposed.pinvTall(options);
            defer pinv_transposed.deinit();

            return pinv_transposed.transpose();
        }

        fn pinvTall(self: Self, options: PinvOptions) MatrixError!Self {
            std.debug.assert(self.rows >= self.cols);

            const allocator = self.allocator;
            const svd_options = SvdOptions{ .with_v = true, .mode = .skinny_u };

            var svd_result = try self.svd(allocator, svd_options);
            defer svd_result.deinit();

            if (svd_result.converged != 0) return error.NotConverged;

            const singular_count = svd_result.s.rows;
            const sigma_max: T = if (singular_count > 0) svd_result.s.at(0, 0).* else 0;
            if (sigma_max == 0) {
                const zero_rows = self.cols;
                const zero_cols = self.rows;
                const zero: Matrix(T) = try .initAll(allocator, zero_rows, zero_cols, 0);
                if (options.effective_rank) |rank_ptr| {
                    rank_ptr.* = 0;
                }
                return zero;
            }
            const max_dim = @max(self.rows, self.cols);
            const default_tol: T = sigma_max * @as(T, @floatFromInt(max_dim)) * std.math.floatEps(T);
            const tol = options.tolerance orelse default_tol;

            // Compute V * Σ⁻¹ by scaling each column of V in place;
            // singular values below the tolerance are discarded (column zeroed).
            var v_sigma = try svd_result.v.dupe(allocator);
            defer v_sigma.deinit();

            var effective_rank: u32 = 0;
            for (0..singular_count) |i| {
                const sigma = svd_result.s.at(i, 0).*;
                const inv_sigma: T = if (sigma > tol) 1 / sigma else 0;
                if (sigma > tol) effective_rank += 1;
                for (0..v_sigma.rows) |r| {
                    v_sigma.at(r, i).* *= inv_sigma;
                }
            }

            if (options.effective_rank) |rank_ptr| {
                rank_ptr.* = effective_rank;
            }

            return v_sigma.dotTranspose(svd_result.u);
        }

        /// Inverts the matrix using Gauss-Jordan elimination with partial pivoting
        /// This is a general method that works for any size square matrix
        fn inverseGaussJordan(self: Self) MatrixError!Self {
            const n = self.rows;

            // Create augmented matrix [A | I]
            var augmented: Matrix(T) = try .init(self.allocator, n, 2 * n);
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
                if (max_val < std.math.floatEps(T) * 10) return error.Singular;

                // Columns before pivot_col in the left half are already reduced
                // to unit columns (exact zeros in the rows below), so the row
                // operations can start at pivot_col.

                // Swap rows if needed
                if (max_row != pivot_col) {
                    for (pivot_col..2 * n) |j| {
                        std.mem.swap(T, augmented.at(pivot_col, j), augmented.at(max_row, j));
                    }
                }

                // Scale pivot row
                const pivot = augmented.at(pivot_col, pivot_col).*;
                for (pivot_col..2 * n) |j| {
                    augmented.at(pivot_col, j).* /= pivot;
                }

                // Eliminate column in all other rows
                for (0..n) |row_idx| {
                    if (row_idx != pivot_col) {
                        const factor = augmented.at(row_idx, pivot_col).*;
                        for (pivot_col..2 * n) |j| {
                            augmented.at(row_idx, j).* -= factor * augmented.at(pivot_col, j).*;
                        }
                    }
                }
            }

            // Extract inverse from right half of augmented matrix
            var ans: Matrix(T) = try .init(self.allocator, n, n);

            for (0..n) |i| {
                for (0..n) |j| {
                    ans.at(i, j).* = augmented.at(i, n + j).*;
                }
            }

            return ans;
        }

        /// Extract a submatrix - changes dimensions
        pub fn subMatrix(self: Self, row_begin: u32, col_begin: u32, row_count: u32, col_count: u32) MatrixError!Self {
            if (row_begin + row_count > self.rows or col_begin + col_count > self.cols) {
                return error.OutOfBounds;
            }
            var result: Matrix(T) = try .init(self.allocator, row_count, col_count);
            for (0..row_count) |r| {
                const src_offset = (row_begin + r) * self.cols + col_begin;
                @memcpy(result.items[r * col_count ..][0..col_count], self.items[src_offset..][0..col_count]);
            }
            return result;
        }

        /// Extract a column - changes dimensions
        pub fn col(self: Self, col_idx: u32) MatrixError!Self {
            if (col_idx >= self.cols) return error.OutOfBounds;
            var result: Matrix(T) = try .init(self.allocator, self.rows, 1);
            for (0..self.rows) |r| {
                result.at(r, 0).* = self.at(r, col_idx).*;
            }
            return result;
        }

        /// Extract a row - changes dimensions
        pub fn row(self: Self, row_idx: u32) MatrixError!Self {
            if (row_idx >= self.rows) return error.OutOfBounds;
            const result: Matrix(T) = try .init(self.allocator, 1, self.cols);
            @memcpy(result.items, self.items[@as(usize, row_idx) * self.cols ..][0..self.cols]);
            return result;
        }

        /// Compute Gram matrix: X * X^T
        /// Useful for kernel methods and when rows < columns
        /// The resulting matrix is rows × rows
        pub fn gram(self: Self) MatrixError!Self {
            return self.gemm(false, self, true, 1.0, 0.0, null);
        }

        /// Compute covariance matrix: X^T * X
        /// Useful for statistical analysis and when rows > columns
        /// The resulting matrix is columns × columns
        pub fn covariance(self: Self) MatrixError!Self {
            return self.gemm(true, self, false, 1.0, 0.0, null);
        }

        /// SIMD GEMM kernel. Both matrices must be arranged for row-major access.
        fn simdGemmKernel(
            comptime VecType: type,
            result: *Matrix(T),
            matrix_a: Matrix(T),
            matrix_b: Matrix(T),
            alpha: T,
            a_rows: u32,
            a_cols: u32,
            b_cols: u32,
        ) void {
            comptime assert(@typeInfo(VecType) == .vector);
            const vec_len = @typeInfo(VecType).vector.len;
            const alignment = @alignOf(VecType);

            // Determine if we can use aligned loads for all rows.
            // This requires:
            // 1. Both base pointers are aligned to VecType.
            // 2. The row stride (a_cols) is a multiple of the alignment (in elements).
            const row_stride_aligned = (a_cols * @sizeOf(T)) % alignment == 0;
            const all_aligned = row_stride_aligned;

            // Both matrices are now guaranteed to be accessed row-wise
            for (0..a_rows) |i| {
                const a_row_offset = i * a_cols;
                for (0..b_cols) |j| {
                    const b_row_offset = j * a_cols;
                    var accumulator: T = 0;

                    // Process vec_len elements at once
                    var k: u32 = 0;
                    if (all_aligned) {
                        while (k + vec_len <= a_cols) : (k += vec_len) {
                            const a_ptr: *const VecType = @ptrCast(@alignCast(&matrix_a.items[a_row_offset + k]));
                            const b_ptr: *const VecType = @ptrCast(@alignCast(&matrix_b.items[b_row_offset + k]));
                            accumulator += @reduce(.Add, a_ptr.* * b_ptr.*);
                        }
                    } else {
                        while (k + vec_len <= a_cols) : (k += vec_len) {
                            // Use unaligned loads (Zig's slice-to-vector dereference)
                            const a_vec: VecType = matrix_a.items[a_row_offset + k .. a_row_offset + k + vec_len][0..vec_len].*;
                            const b_vec: VecType = matrix_b.items[b_row_offset + k .. b_row_offset + k + vec_len][0..vec_len].*;
                            accumulator += @reduce(.Add, a_vec * b_vec);
                        }
                    }

                    // Handle remainder elements
                    while (k < a_cols) : (k += 1) {
                        accumulator += matrix_a.items[a_row_offset + k] * matrix_b.items[b_row_offset + k];
                    }

                    result.at(i, j).* += alpha * accumulator;
                }
            }
        }

        /// General Matrix Multiply (GEMM): C = α * op(A) * op(B) + β * C
        ///
        /// This is the fundamental matrix operation that unifies many matrix computations.
        ///
        /// Examples:
        /// - Matrix multiplication: gemm(false, B, false, 1.0, 0.0, null)
        /// - Gram matrix: gemm(false, self, true, 1.0, 0.0, null) -> A * A^T
        /// - Covariance: gemm(true, self, false, 1.0, 0.0, null) -> A^T * A
        /// - Scaled product: gemm(false, B, false, 2.0, 0.0, null) -> 2 * A * B
        /// - Accumulation: gemm(false, B, false, 1.0, 1.0, C) -> A * B + C
        pub fn gemm(
            self: Self,
            /// If true, use A^T (transpose of self) instead of A.
            trans_a: bool,
            other: Self,
            /// If true, use B^T (transpose of other) instead of B.
            trans_b: bool,
            /// Scales the product op(A) * op(B).
            alpha: T,
            /// Scales the existing matrix C before adding the product.
            beta: T,
            /// Existing matrix to accumulate into; if null, defaults to the zero matrix.
            c: ?Self,
        ) MatrixError!Self {
            // Determine dimensions after potential transposition
            const a_rows = if (trans_a) self.cols else self.rows;
            const a_cols = if (trans_a) self.rows else self.cols;
            const b_rows = if (trans_b) other.cols else other.rows;
            const b_cols = if (trans_b) other.rows else other.cols;

            // Verify matrix multiplication compatibility
            if (a_cols != b_rows) return error.DimensionMismatch;

            var result: Matrix(T) = try .init(self.allocator, a_rows, b_cols);
            errdefer result.deinit();

            // Initialize with scaled C matrix if provided
            if (c) |c_mat| {
                if (c_mat.rows != a_rows or c_mat.cols != b_cols) {
                    return error.DimensionMismatch;
                }
            }
            if (c != null and beta != 0) {
                const c_mat = c.?;
                for (0..a_rows) |i| {
                    for (0..b_cols) |j| {
                        result.at(i, j).* = beta * c_mat.at(i, j).*;
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
                        var b_transposed: Matrix(T) = try .init(self.allocator, b_cols, a_cols);
                        defer b_transposed.deinit();
                        for (0..a_cols) |k| {
                            for (0..b_cols) |j| {
                                b_transposed.at(j, k).* = other.at(k, j).*;
                            }
                        }
                        simdGemmKernel(VecType, &result, self, b_transposed, alpha, a_rows, a_cols, b_cols);
                    } else if (trans_a and !trans_b) {
                        // Case 2: A^T * B - transpose A for cache-friendly row-major access
                        var a_transposed: Matrix(T) = try .init(self.allocator, a_rows, a_cols);
                        defer a_transposed.deinit();
                        // Transpose A: a_transposed[i,j] = A[j,i]
                        for (0..a_cols) |k| {
                            for (0..a_rows) |i| {
                                a_transposed.at(i, k).* = self.at(k, i).*;
                            }
                        }
                        // Handle special case when A and B are the same matrix (for covariance)
                        if (self.items.ptr == other.items.ptr) {
                            // For covariance (A^T * A), we need to also use transposed for B
                            simdGemmKernel(VecType, &result, a_transposed, a_transposed, alpha, a_rows, a_cols, b_cols);
                        } else {
                            // General case: transpose B for row-wise access
                            var b_transposed: Matrix(T) = try .init(self.allocator, b_cols, a_cols);
                            defer b_transposed.deinit();
                            for (0..a_cols) |k| {
                                for (0..b_cols) |j| {
                                    b_transposed.at(j, k).* = other.at(k, j).*;
                                }
                            }
                            simdGemmKernel(VecType, &result, a_transposed, b_transposed, alpha, a_rows, a_cols, b_cols);
                        }
                    } else if (!trans_a and trans_b) {
                        // Case 3: A * B^T - no transpose needed, B^T is naturally row-wise
                        simdGemmKernel(VecType, &result, self, other, alpha, a_rows, a_cols, b_cols);
                    } else if (trans_a and trans_b) {
                        // Case 4: A^T * B^T - transpose A so rows are contiguous, reuse B rows directly
                        var a_transposed: Matrix(T) = try .init(self.allocator, a_rows, a_cols);
                        defer a_transposed.deinit();
                        for (0..a_rows) |i| {
                            for (0..a_cols) |j| {
                                a_transposed.at(i, j).* = self.at(j, i).*;
                            }
                        }

                        // op(B) = B^T. Each column j of B^T corresponds to row j of B, which is already
                        // contiguous in memory, so we can feed `other` directly to the SIMD kernel.
                        simdGemmKernel(VecType, &result, a_transposed, other, alpha, a_rows, a_cols, b_cols);
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
        pub fn scaledDot(self: Self, other: Self, alpha: T) MatrixError!Self {
            return self.gemm(false, other, false, alpha, 0.0, null);
        }

        /// Matrix multiplication with transpose: A * B^T
        /// Convenience method for common GEMM use case
        pub fn dotTranspose(self: Self, other: Self) MatrixError!Self {
            return self.gemm(false, other, true, 1.0, 0.0, null);
        }

        /// Transpose matrix multiplication: A^T * B
        /// Convenience method for common GEMM use case
        pub fn transposeDot(self: Self, other: Self) MatrixError!Self {
            return self.gemm(true, other, false, 1.0, 0.0, null);
        }

        /// Apply a function to all matrix elements with optional arguments
        pub fn apply(self: Self, comptime func: anytype, args: anytype) MatrixError!Self {
            const result: Matrix(T) = try .init(self.allocator, self.rows, self.cols);
            for (result.items, self.items) |*dst, src| {
                dst.* = @call(.auto, func, .{src} ++ args);
            }
            return result;
        }

        /// Apply a function to all matrix elements with optional arguments (in-place)
        pub fn applyBy(self: *Self, comptime func: anytype, args: anytype) MatrixError!void {
            for (self.items) |*item| {
                item.* = @call(.auto, func, .{item.*} ++ args);
            }
        }

        /// Add scalar to all elements
        pub fn offset(self: Self, value: T) MatrixError!Self {
            const result: Matrix(T) = try .init(self.allocator, self.rows, self.cols);
            for (result.items, self.items) |*dst, a| {
                dst.* = a + value;
            }
            return result;
        }

        /// Add scalar to all elements (in-place)
        pub fn offsetBy(self: *Self, value: T) MatrixError!void {
            for (self.items) |*item| {
                item.* += value;
            }
        }

        fn powN(x: T, exponent: T) T {
            return std.math.pow(T, x, exponent);
        }

        /// Raise all elements to power n (convenience method)
        pub fn pow(self: Self, n: T) MatrixError!Self {
            return self.apply(powN, .{n});
        }

        /// Raise all elements to power n (convenience method) (in-place)
        pub fn powBy(self: *Self, n: T) MatrixError!void {
            try self.applyBy(powN, .{n});
        }

        fn ensureFloat(comptime context: []const u8) void {
            comptime if (@typeInfo(T) != .float)
                @compileError(context ++ " requires floating-point elements");
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
            assert(self.items.len > 0);
            return self.sum() / @as(T, @floatFromInt(self.items.len));
        }

        /// Variance: E[(X - μ)²]
        pub fn variance(self: Self) T {
            assert(self.items.len > 0);
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
            assert(self.items.len > 0);
            return std.mem.min(T, self.items);
        }

        /// Maximum element
        pub fn max(self: Self) T {
            assert(self.items.len > 0);
            return std.mem.max(T, self.items);
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
                var transposed = try self.transpose();
                defer transposed.deinit();
                return transposed.leadingSingularValue(allocator);
            }

            var svd_result = try self.svd(allocator, .{ .with_v = false, .mode = .no_u });
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
                var svd_result = try self.svd(allocator, .{ .with_v = false, .mode = .no_u });
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

            var transposed = try self.transpose();
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
            p: Permutation, // Permutation P such that PA = LU
            sign: T, // Determinant sign (+1 or -1)

            pub fn deinit(self: *@This()) void {
                self.l.deinit();
                self.u.deinit();
                self.p.deinit();
            }

            /// Returns the permutation as a matrix P such that PA = LU.
            pub fn permutationMatrix(self: *const @This()) !Matrix(T) {
                return self.p.toMatrix(.row);
            }
        };

        /// Compute LU decomposition with partial pivoting
        /// Returns L, U matrices and permutation vector such that PA = LU
        pub fn lu(self: Self) !LuResult {
            comptime assert(@typeInfo(T) == .float);
            const n = self.rows;
            if (n != self.cols) return error.NotSquare;

            // Create working copy
            var work = try self.dupe(self.allocator);
            defer work.deinit();

            // Initialize L as identity, U as zero
            var l: Matrix(T) = try .init(self.allocator, n, n);
            errdefer l.deinit();
            var u: Matrix(T) = try .init(self.allocator, n, n);
            errdefer u.deinit();

            // Initialize permutation
            const p_indices = try self.allocator.alloc(u32, n);
            errdefer self.allocator.free(p_indices);
            for (0..n) |i| {
                p_indices[i] = @intCast(i);
            }
            const p = Permutation{ .indices = p_indices, .allocator = self.allocator };

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

                // A zero pivot (singular matrix) is allowed: the decomposition
                // continues and the user can check if U has zeros on its diagonal.

                // Swap rows if needed
                if (max_row != pivot_col) {
                    sign = -sign;
                    // Swap in permutation vector
                    std.mem.swap(u32, &p.indices[pivot_col], &p.indices[max_row]);

                    // Swap rows in work matrix
                    for (0..n) |j| {
                        std.mem.swap(T, work.at(pivot_col, j), work.at(max_row, j));
                    }

                    // Swap rows in L (only the part already computed)
                    for (0..pivot_col) |j| {
                        std.mem.swap(T, l.at(pivot_col, j), l.at(max_row, j));
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

        /// Computes the Cholesky decomposition of a symmetric positive-definite matrix.
        /// Returns L such that A = L * L^T where L is lower triangular.
        pub fn chol(self: Self) MatrixError!Self {
            ensureFloat("chol");
            if (self.rows != self.cols) return error.NotSquare;
            const n = self.rows;
            var l: Matrix(T) = try .init(self.allocator, n, n);
            errdefer l.deinit();
            @memset(l.items, 0);
            for (0..n) |i| {
                for (0..i + 1) |j| {
                    var accum: T = 0;
                    for (0..j) |k| accum += l.at(i, k).* * l.at(j, k).*;
                    if (i == j) {
                        const val = self.at(i, i).* - accum;
                        if (val <= 0) return error.NotPositiveDefinite;
                        l.at(i, i).* = @sqrt(val);
                    } else {
                        const val = self.at(i, j).* - accum;
                        l.at(i, j).* = val / l.at(j, j).*;
                    }
                }
            }
            return l;
        }

        /// Computes the determinant of the matrix using analytical formulas for small matrices
        /// and LU decomposition for larger matrices
        pub fn det(self: Self) !T {
            comptime assert(@typeInfo(T) == .float);
            if (self.rows != self.cols) return error.NotSquare;
            if (self.rows == 0) return error.DimensionMismatch;

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
                    var d = lu_result.sign;
                    for (0..n) |i| d *= lu_result.u.at(i, i).*;
                    break :blk d;
                },
            };
        }

        pub const QrResult = struct {
            q: Matrix(T), // Orthogonal matrix (m×n)
            r: Matrix(T), // Upper triangular matrix (n×n)
            perm: Permutation, // Permutation P such that AP = QR
            rank: u32, // Numerical rank of the matrix
            col_norms: []T, // Final column norms after pivoting (diagnostic)
            allocator: std.mem.Allocator,

            pub fn deinit(self: *@This()) void {
                self.q.deinit();
                self.r.deinit();
                self.perm.deinit();
                self.allocator.free(self.col_norms);
            }

            /// Get the permutation as a matrix P such that AP = QR.
            pub fn permutationMatrix(self: *const @This()) !Matrix(T) {
                return self.perm.toMatrix(.column);
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
            const perm_indices = try self.allocator.alloc(u32, n);
            errdefer self.allocator.free(perm_indices);
            const col_norms = try self.allocator.alloc(T, n);
            errdefer self.allocator.free(col_norms);

            // Initialize permutation as identity
            for (0..n) |i| {
                perm_indices[i] = @intCast(i);
            }
            const perm = Permutation{ .indices = perm_indices, .allocator = self.allocator };

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

            var computed_rank: u32 = 0;

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
                        std.mem.swap(T, q.at(i, k), q.at(i, max_col));
                    }
                    // Swap in R (for already computed rows)
                    for (0..k) |i| {
                        std.mem.swap(T, r.at(i, k), r.at(i, max_col));
                    }
                    // Swap in permutation
                    std.mem.swap(u32, &perm.indices[k], &perm.indices[max_col]);
                    // Swap column norms
                    std.mem.swap(T, &col_norms[k], &col_norms[max_col]);
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
        pub fn rank(self: Self) !u32 {
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
            if (self.rows < self.cols) return error.DimensionMismatch;
            return svd_module.svd(T, allocator, self, options);
        }

        /// Symmetric (Hermitian) eigendecomposition A = V · diag(λ) · Vᵀ via cyclic Jacobi rotations.
        /// Returns eigenvalues as an n×1 column in ascending order and `vectors` whose column j is
        /// the unit eigenvector corresponding to the j-th eigenvalue. Unlike `svd`, this recovers
        /// signed eigenvalues, so it handles indefinite matrices. The matrix must be square; it is
        /// validated to be symmetric (within a magnitude-relative tolerance) and otherwise returns
        /// `error.NotSymmetric`. A general non-symmetric `eig` (complex spectrum) is not provided.
        pub fn eigh(self: Self, allocator: std.mem.Allocator) !EighResult(T) {
            comptime assert(@typeInfo(T) == .float);
            if (self.rows != self.cols) return error.NotSquare;
            return eigen_module.eigh(T, allocator, self);
        }

        /// Default formatting (scientific notation)
        pub fn format(self: Self, writer: *Io.Writer) !void {
            try formatting.formatMatrix(self, "{e}", writer);
        }

        /// Converts a Matrix to a static SMatrix with the given dimensions
        pub fn toSMatrix(self: Self, comptime rows: u32, comptime cols: u32) SMatrix(T, rows, cols) {
            assert(self.rows == rows);
            assert(self.cols == cols);

            var result: SMatrix(T, rows, cols) = .{};
            @memcpy(@as(*[rows * cols]T, @ptrCast(&result.items)), self.items);
            return result;
        }

        /// Creates a Matrix from a static SMatrix
        pub fn fromSMatrix(allocator: std.mem.Allocator, smatrix: anytype) !Matrix(T) {
            return smatrix.toMatrix(allocator);
        }
    };
}

test "Matrix as" {
    const allocator = std.testing.allocator;
    var a: Matrix(f32) = try .random(allocator, 3, 4, 1234);
    defer a.deinit();
    var b = try a.as(allocator, f64);
    defer b.deinit();
    for (0..a.rows) |r| {
        for (0..a.cols) |c| {
            try expectEqual(@as(f64, a.at(r, c).*), b.at(r, c).*);
        }
    }
}

test "Matrix diagonal" {
    const allocator = std.testing.allocator;
    var d: Matrix(f64) = try .diagonal(allocator, &.{ 2, -3, 5 });
    defer d.deinit();
    try expectEqual(@as(u32, 3), d.rows);
    try expectEqual(@as(u32, 3), d.cols);
    for (0..3) |i| {
        for (0..3) |j| {
            const expected: f64 = if (i == j) (&[_]f64{ 2, -3, 5 })[i] else 0;
            try expectEqual(expected, d.at(i, j).*);
        }
    }
}

// Tests for dynamic Matrix functionality
test "matrix surfaces errors at the source op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var singular: Matrix(f64) = try .init(alloc, 2, 2);
    defer singular.deinit();
    singular.at(0, 0).* = 1;
    singular.at(0, 1).* = 2;
    singular.at(1, 0).* = 2;
    singular.at(1, 1).* = 4;

    // Singular inverse surfaces error directly — no deferred state.
    try expectError(MatrixError.Singular, singular.inv());

    // Dimension mismatch surfaces from the failing op directly.
    var a: Matrix(f64) = try .initAll(alloc, 2, 3, 1.0);
    defer a.deinit();
    var b: Matrix(f64) = try .initAll(alloc, 3, 2, 1.0);
    defer b.deinit();
    try expectError(MatrixError.DimensionMismatch, a.add(b));
    try expectError(MatrixError.DimensionMismatch, a.sub(b));
    try expectError(MatrixError.DimensionMismatch, a.hadamard(b));

    // Chains short-circuit at the failing step and free intermediates.
    var p = a.chain();
    defer p.deinit();
    try expectError(MatrixError.DimensionMismatch, p.add(b).scale(2.0).toOwned());
}

test "matrix elementNorm invalid exponent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var m: Matrix(f64) = try .init(arena.allocator(), 1, 1);
    defer m.deinit();
    m.at(0, 0).* = 1.0;

    try std.testing.expectError(MatrixError.InvalidArgument, m.elementNorm(-1.0));
    try std.testing.expectError(MatrixError.InvalidArgument, m.elementNorm(std.math.nan(f64)));
}

test "dynamic matrix format" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test dynamic Matrix formatting
    var dm: Matrix(f32) = try .init(arena.allocator(), 2, 2);
    dm.at(0, 0).* = 3.14159;
    dm.at(0, 1).* = -2.71828;
    dm.at(1, 0).* = 1.41421;
    dm.at(1, 1).* = 0.57721;

    var buffer: [512]u8 = undefined;
    var stream: Io.Writer = .fixed(&buffer);

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

test "Matrix(T).sumRows and sumCols" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .init(allocator, 2, 3);
    defer a.deinit();
    a.at(0, 0).* = 1;
    a.at(0, 1).* = 2;
    a.at(0, 2).* = 3;
    a.at(1, 0).* = 4;
    a.at(1, 1).* = 5;
    a.at(1, 2).* = 6;

    var rows_sum = try a.sumRows();
    defer rows_sum.deinit();
    try std.testing.expectEqual(@as(u32, 1), rows_sum.rows);
    try std.testing.expectEqual(@as(u32, 3), rows_sum.cols);
    try std.testing.expectEqual(@as(f64, 5), rows_sum.at(0, 0).*);
    try std.testing.expectEqual(@as(f64, 7), rows_sum.at(0, 1).*);
    try std.testing.expectEqual(@as(f64, 9), rows_sum.at(0, 2).*);

    var cols_sum = try a.sumCols();
    defer cols_sum.deinit();
    try std.testing.expectEqual(@as(u32, 2), cols_sum.rows);
    try std.testing.expectEqual(@as(u32, 1), cols_sum.cols);
    try std.testing.expectEqual(@as(f64, 6), cols_sum.at(0, 0).*);
    try std.testing.expectEqual(@as(f64, 15), cols_sum.at(1, 0).*);
}

test "Matrix(T).By operations (in-place)" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .initAll(allocator, 2, 2, 10.0);
    defer a.deinit();
    var b: Matrix(f64) = try .initAll(allocator, 2, 2, 5.0);
    defer b.deinit();

    try a.addBy(b);
    try std.testing.expectEqual(@as(f64, 15.0), a.at(0, 0).*);

    try a.subBy(b);
    try std.testing.expectEqual(@as(f64, 10.0), a.at(0, 0).*);

    try a.scaleBy(2.0);
    try std.testing.expectEqual(@as(f64, 20.0), a.at(0, 0).*);

    try a.hadamardBy(b);
    try std.testing.expectEqual(@as(f64, 100.0), a.at(0, 0).*);

    try a.offsetBy(1.0);
    try std.testing.expectEqual(@as(f64, 101.0), a.at(0, 0).*);

    try a.powBy(2.0);
    try std.testing.expectEqual(@as(f64, 10201.0), a.at(0, 0).*);
}

test "matrix conversions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test SMatrix to Matrix conversion
    const static_matrix: SMatrix(f64, 2, 3) = .init(.{
        .{ 1.5, 2.5, 3.5 },
        .{ 4.5, 5.5, 6.5 },
    });
    const dynamic_matrix = try static_matrix.toMatrix(arena.allocator());
    try expectEqual(@as(u32, 2), dynamic_matrix.rows);
    try expectEqual(@as(u32, 3), dynamic_matrix.cols);
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

test "Matrix fromSlice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const data = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };

    // Test successful initialization (2x3)
    var mat: Matrix(f64) = try .fromSlice(arena.allocator(), 2, 3, &data);
    defer mat.deinit();

    try expectEqual(@as(u32, 2), mat.rows);
    try expectEqual(@as(u32, 3), mat.cols);
    try expectEqual(@as(f64, 1.0), mat.at(0, 0).*);
    try expectEqual(@as(f64, 2.0), mat.at(0, 1).*);
    try expectEqual(@as(f64, 3.0), mat.at(0, 2).*);
    try expectEqual(@as(f64, 4.0), mat.at(1, 0).*);
    try expectEqual(@as(f64, 5.0), mat.at(1, 1).*);
    try expectEqual(@as(f64, 6.0), mat.at(1, 2).*);

    // Test dimension mismatch
    try std.testing.expectError(error.DimensionMismatch, Matrix(f64).fromSlice(arena.allocator(), 2, 2, &data));
}

//! Static matrix with compile-time dimensions

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const Point = @import("../geometry/Point.zig").Point;
const formatting = @import("formatting.zig");
const svd_module = @import("svd_static.zig");
pub const SvdMode = svd_module.SvdMode;
pub const SvdOptions = svd_module.SvdOptions;
pub const SvdResult = svd_module.SvdResult;

/// Creates a static matrix with elements of type T and size rows times cols.
pub fn SMatrix(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    return struct {
        const Self = @This();
        items: [rows][cols]T = undefined,
        comptime rows: usize = rows,
        comptime cols: usize = cols,

        /// Initialize a SMatrix with the given items.
        pub fn init(items: [rows][cols]T) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = items[r][c];
                }
            }
            return result;
        }

        /// Returns the rows and columns as a struct.
        pub fn shape(self: Self) struct { usize, usize } {
            _ = self;
            return .{ rows, cols };
        }

        /// Retrieves a pointer to the element at position row, col in the matrix.
        pub inline fn at(self: anytype, row_idx: usize, col_idx: usize) @TypeOf(&self.items[row_idx][col_idx]) {
            assert(row_idx < rows);
            assert(col_idx < cols);
            return &self.items[row_idx][col_idx];
        }

        /// Returns a matrix with all elements set to value.
        pub fn initAll(value: T) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                @memset(&result.items[r], value);
            }
            return result;
        }

        /// Returns an identity-like matrix.
        pub fn identity() Self {
            var result: Self = .initAll(0);
            for (0..@min(rows, cols)) |i| {
                result.items[i][i] = 1;
            }
            return result;
        }

        /// Returns a matrix filled with random floating-point numbers.
        pub fn random(seed: ?u64) Self {
            const s: u64 = seed orelse @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
            var prng: std.Random.DefaultPrng = .init(s);
            var rand = prng.random();
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = rand.float(T);
                }
            }
            return result;
        }

        /// Sums all the elements in a matrix.
        pub fn sum(self: Self) T {
            var accum: T = 0;
            for (0..rows) |r| {
                for (0..cols) |c| {
                    accum += self.items[r][c];
                }
            }
            return accum;
        }

        /// Scales all matrix values.
        pub fn scale(self: Self, value: T) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = value * self.items[r][c];
                }
            }
            return result;
        }

        /// Applies a unary function to all matrix values.
        pub fn apply(self: Self, comptime unaryFn: fn (arg: T) T) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = unaryFn(self.items[r][c]);
                }
            }
            return result;
        }

        /// Adds an offset to all matrix values.
        pub fn offset(self: Self, value: T) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = value + self.items[r][c];
                }
            }
            return result;
        }

        /// Performs pointwise multiplication.
        pub fn times(self: Self, other: Self) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = self.items[r][c] * other.items[r][c];
                }
            }
            return result;
        }

        /// Computes the Frobenius norm of the matrix.
        pub fn frobeniusNorm(self: Self) T {
            return @sqrt(self.times(self).sum());
        }

        /// Computes the nuclear norm of the matrix as sum of the absolute values of all elements.
        pub fn nuclearNorm(self: Self) T {
            var accum: T = 0;
            for (0..rows) |r| {
                for (0..cols) |c| {
                    accum += @abs(self.items[r][c]);
                }
            }
            return accum;
        }

        /// If the matrix only contains one element, it returns it, otherwise it fails to compile.
        pub fn item(self: Self) T {
            comptime assert(rows == 1 and cols == 1);
            return self.items[0][0];
        }

        /// Computes the L-infinity norm (maximum absolute value among all elements) of the matrix.
        pub fn maxNorm(self: Self) T {
            var result: T = -std.math.inf(T);
            for (0..rows) |r| {
                for (0..cols) |c| {
                    const val = @abs(self.items[r][c]);
                    if (val > result) {
                        result = val;
                    }
                }
            }
            return result;
        }

        /// Computes the minimum absolute value among all elements of the matrix.
        pub fn minNorm(self: Self) T {
            var result: T = std.math.inf(T);
            for (0..rows) |r| {
                for (0..cols) |c| {
                    const val = @abs(self.items[r][c]);
                    if (val < result) {
                        result = val;
                    }
                }
            }
            return result;
        }

        /// Computes the L0 norm, which is the count of non-zero elements in the matrix.
        pub fn sparseNorm(self: Self) T {
            var count: T = 0;
            for (0..rows) |r| {
                for (0..cols) |c| {
                    count += if (self.items[r][c] != 0) 1 else 0;
                }
            }
            return count;
        }

        /// Computes the "element-wise" matrix norm of the matrix.
        pub fn norm(self: Self, p: T) T {
            if (p == std.math.inf(T)) {
                return self.maxNorm();
            } else if (p == -std.math.inf(T)) {
                return self.minNorm();
            }
            assert(p >= 0);
            if (p == 0) {
                return self.sparseNorm();
            } else if (p == 1) {
                return self.nuclearNorm();
            } else if (p == 2) {
                return self.frobeniusNorm();
            } else {
                var result: T = 0;
                for (self.items) |row_data| {
                    for (row_data) |value| {
                        result += if (value == 0) 0 else std.math.pow(T, @abs(value), p);
                    }
                }
                return std.math.pow(T, result, 1 / p);
            }
        }

        /// Performs the dot (or internal product) of two matrices.
        pub fn dot(self: Self, other: anytype) SMatrix(T, rows, other.cols) {
            return self.gemm(false, other, false, 1.0, 0.0, null);
        }

        /// Adds a matrix.
        pub fn add(self: Self, other: Self) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = self.items[r][c] + other.items[r][c];
                }
            }
            return result;
        }

        /// Subtracts a matrix.
        pub fn sub(self: Self, other: Self) Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][c] = self.items[r][c] - other.items[r][c];
                }
            }
            return result;
        }

        /// Sets the sub-matrix at position row, col to sub_matrix.
        pub fn setSubMatrix(self: *Self, row_idx: usize, col_idx: usize, matrix: anytype) void {
            assert(matrix.rows + row_idx <= rows);
            assert(matrix.cols + col_idx <= cols);
            for (0..matrix.rows) |r| {
                for (0..matrix.cols) |c| {
                    self.items[row_idx + r][col_idx + c] = matrix.items[r][c];
                }
            }
        }

        /// Transposes the matrix.
        pub fn transpose(self: Self) SMatrix(T, cols, rows) {
            var result: SMatrix(T, cols, rows) = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[c][r] = self.items[r][c];
                }
            }
            return result;
        }

        /// Compute Gram matrix: X * X^T
        /// Useful for kernel methods and when rows < columns
        /// The resulting matrix is rows × rows
        pub fn gram(self: Self) SMatrix(T, rows, rows) {
            return self.gemm(false, self, true, 1.0, 0.0, null);
        }

        /// Compute covariance matrix: X^T * X
        /// Useful for statistical analysis and when rows > columns
        /// The resulting matrix is columns × columns
        pub fn covariance(self: Self) SMatrix(T, cols, cols) {
            return self.gemm(true, self, false, 1.0, 0.0, null);
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
            comptime trans_a: bool,
            other: anytype,
            comptime trans_b: bool,
            alpha: T,
            beta: T,
            c: anytype,
        ) blk: {
            // Determine dimensions after potential transposition
            const a_rows = if (trans_a) cols else rows;
            const a_cols = if (trans_a) rows else cols;
            const b_rows = if (trans_b) other.cols else other.rows;
            const b_cols = if (trans_b) other.rows else other.cols;

            // Verify matrix multiplication compatibility
            assert(a_cols == b_rows);

            break :blk SMatrix(T, a_rows, b_cols);
        } {
            // Determine result dimensions
            const a_rows = if (trans_a) cols else rows;
            const a_cols = if (trans_a) rows else cols;
            const b_cols = if (trans_b) other.rows else other.cols;

            var result: SMatrix(T, a_rows, b_cols) = undefined;

            // Check if c is null or not (comptime detection)
            const has_c = @TypeOf(c) != @TypeOf(null);

            // Initialize with scaled C matrix if provided
            if (has_c) {
                assert(c.rows == a_rows and c.cols == b_cols);
                if (beta != 0) {
                    for (0..a_rows) |i| {
                        for (0..b_cols) |j| {
                            result.items[i][j] = beta * c.items[i][j];
                        }
                    }
                } else {
                    // Beta is 0, so initialize to zero
                    result = .initAll(0);
                }
            } else {
                // Initialize to zero
                result = .initAll(0);
            }

            // Skip computation if alpha is zero
            if (alpha != 0) {
                const vec_len = std.simd.suggestVectorLength(T) orelse 1;
                const VecType = @Vector(vec_len, T);

                for (0..a_rows) |i| {
                    for (0..b_cols) |j| {
                        var accumulator: T = 0;

                        // SIMD loop - process vec_len elements at once
                        var k: usize = 0;
                        while (k + vec_len <= a_cols) : (k += vec_len) {
                            var a_vec: VecType = undefined;
                            var b_vec: VecType = undefined;

                            // Load vectors with appropriate indexing based on transpose flags
                            for (0..vec_len) |v| {
                                const a_val = if (trans_a) self.items[k + v][i] else self.items[i][k + v];
                                const b_val = if (trans_b) other.items[j][k + v] else other.items[k + v][j];
                                a_vec[v] = a_val;
                                b_vec[v] = b_val;
                            }

                            // Vectorized multiply-accumulate
                            const prod_vec = a_vec * b_vec;
                            accumulator += @reduce(.Add, prod_vec);
                        }

                        // Handle remainder elements with scalar code
                        while (k < a_cols) : (k += 1) {
                            const a_val = if (trans_a) self.items[k][i] else self.items[i][k];
                            const b_val = if (trans_b) other.items[j][k] else other.items[k][j];
                            accumulator += a_val * b_val;
                        }

                        result.items[i][j] += alpha * accumulator;
                    }
                }
            }

            return result;
        }

        /// Scaled matrix multiplication: α * A * B
        /// Convenience method for common GEMM use case
        pub fn scaledDot(self: Self, other: anytype, alpha: T) SMatrix(T, rows, other.cols) {
            return self.gemm(false, other, false, alpha, 0.0, null);
        }

        /// Matrix multiplication with transpose: A * B^T
        /// Convenience method for common GEMM use case
        pub fn dotTranspose(self: Self, other: anytype) SMatrix(T, rows, other.rows) {
            return self.gemm(false, other, true, 1.0, 0.0, null);
        }

        /// Transpose matrix multiplication: A^T * B
        /// Convenience method for common GEMM use case
        pub fn transposeDot(self: Self, other: anytype) SMatrix(T, cols, other.cols) {
            return self.gemm(true, other, false, 1.0, 0.0, null);
        }

        /// Returns a new matrix which is a copy of the specified rectangular region of `self`.
        pub fn subMatrix(
            self: Self,
            comptime row_begin: usize,
            comptime col_begin: usize,
            comptime row_end: usize,
            comptime col_end: usize,
        ) SMatrix(T, row_end - row_begin, col_end - col_begin) {
            comptime assert(row_begin < row_end);
            comptime assert(col_begin < col_end);
            comptime assert(row_end <= rows);
            comptime assert(col_end <= cols);
            var result: SMatrix(T, row_end - row_begin, col_end - col_begin) = .{};
            for (row_begin..row_end) |r| {
                for (col_begin..col_end) |c| {
                    result.items[r - row_begin][c - col_begin] = self.items[r][c];
                }
            }
            return result;
        }

        /// Returns the elements in the column as a column Matrix.
        pub fn col(self: Self, col_idx: usize) SMatrix(T, rows, 1) {
            assert(col_idx < cols);
            var result: SMatrix(T, rows, 1) = .{};
            for (0..rows) |r| {
                result.items[r][0] = self.items[r][col_idx];
            }
            return result;
        }

        /// Returns the elements in the row as a row Matrix.
        pub fn row(self: Self, row_idx: usize) SMatrix(T, 1, cols) {
            assert(row_idx < rows);
            var result: SMatrix(T, 1, cols) = .{};
            for (0..cols) |c| {
                result.items[0][c] = self.items[row_idx][c];
            }
            return result;
        }

        /// Converts this SMatrix to a dynamic Matrix
        pub fn toMatrix(self: Self, allocator: std.mem.Allocator) !@import("Matrix.zig").Matrix(T) {
            var result = try @import("Matrix.zig").Matrix(T).init(allocator, rows, cols);
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.at(r, c).* = self.items[r][c];
                }
            }
            return result;
        }

        /// Returns a new matrix with dimensions `new_rows` x `new_cols`, containing the same elements
        /// as `self` interpreted in row-major order.
        pub fn reshape(self: Self, comptime new_rows: usize, comptime new_cols: usize) SMatrix(T, new_rows, new_cols) {
            comptime assert(rows * cols == new_rows * new_cols);
            var result: SMatrix(T, new_rows, new_cols) = .{};
            for (0..new_rows) |r| {
                for (0..new_cols) |c| {
                    const idx = r * new_cols + c;
                    result.items[r][c] = self.items[idx / cols][idx % cols];
                }
            }
            return result;
        }

        /// Converts a column matrix into a Point with the specified dimension.
        pub fn toPoint(self: Self, comptime dim: usize) Point(dim, T) {
            comptime assert(rows >= dim and cols == 1);
            var components: [dim]T = undefined;
            inline for (0..dim) |i| {
                components[i] = self.items[i][0];
            }
            return .fromArray(components);
        }

        /// Computes the trace (sum of diagonal elements) of a square matrix.
        pub fn trace(self: Self) T {
            comptime assert(rows == cols);
            var result: T = 0;
            for (0..rows) |i| {
                result += self.items[i][i];
            }
            return result;
        }

        /// Computes the determinant of self if it's a square matrix.
        pub fn determinant(self: Self) T {
            comptime assert(rows == cols);
            return switch (rows) {
                1 => self.item(),
                2 => self.items[0][0] * self.items[1][1] - self.items[0][1] * self.items[1][0],
                3 => self.items[0][0] * self.items[1][1] * self.items[2][2] +
                    self.items[0][1] * self.items[1][2] * self.items[2][0] +
                    self.items[0][2] * self.items[1][0] * self.items[2][1] -
                    self.items[0][2] * self.items[1][1] * self.items[2][0] -
                    self.items[0][1] * self.items[1][0] * self.items[2][2] -
                    self.items[0][0] * self.items[1][2] * self.items[2][1],
                else => @compileError("Matrix(T).determinant() is not implemented for sizes above 3"),
            };
        }

        /// Computes the inverse of self if it's a square matrix.
        pub fn inverse(self: Self) ?Self {
            comptime assert(rows == cols);
            const det = self.determinant();
            if (det == 0) {
                return null;
            }
            var inv: Self = .{};
            switch (rows) {
                1 => inv.items[0][0] = 1 / det,
                2 => {
                    inv.items[0][0] = self.items[1][1] / det;
                    inv.items[0][1] = -self.items[0][1] / det;
                    inv.items[1][0] = -self.items[1][0] / det;
                    inv.items[1][1] = self.items[0][0] / det;
                },
                3 => {
                    inv.items[0][0] = (self.items[1][1] * self.items[2][2] - self.items[1][2] * self.items[2][1]) / det;
                    inv.items[0][1] = (self.items[0][2] * self.items[2][1] - self.items[0][1] * self.items[2][2]) / det;
                    inv.items[0][2] = (self.items[0][1] * self.items[1][2] - self.items[0][2] * self.items[1][1]) / det;
                    inv.items[1][0] = (self.items[1][2] * self.items[2][0] - self.items[1][0] * self.items[2][2]) / det;
                    inv.items[1][1] = (self.items[0][0] * self.items[2][2] - self.items[0][2] * self.items[2][0]) / det;
                    inv.items[1][2] = (self.items[0][2] * self.items[1][0] - self.items[0][0] * self.items[1][2]) / det;
                    inv.items[2][0] = (self.items[1][0] * self.items[2][1] - self.items[1][1] * self.items[2][0]) / det;
                    inv.items[2][1] = (self.items[0][1] * self.items[2][0] - self.items[0][0] * self.items[2][1]) / det;
                    inv.items[2][2] = (self.items[0][0] * self.items[1][1] - self.items[0][1] * self.items[1][0]) / det;
                },
                else => @compileError("Matrix(T).inverse() is not implemented for sizes above 3"),
            }
            return inv;
        }

        /// Performs singular value decomposition (SVD) on the matrix.
        /// Returns the decomposition A = U × Σ × V^T where:
        /// - U contains left singular vectors
        /// - Σ is a diagonal matrix of singular values (stored as a vector)
        /// - V contains right singular vectors
        ///
        /// Requires rows >= cols. See SvdOptions for configuration details.
        pub fn svd(self: Self, comptime options: SvdOptions) SvdResult(T, rows, cols, options) {
            comptime assert(rows >= cols);
            return svd_module.svd(T, rows, cols, self, options);
        }

        /// Returns a formatter for decimal notation with specified precision
        pub fn decimal(self: Self, comptime precision: u8) formatting.DecimalFormatter(Self, precision) {
            return formatting.DecimalFormatter(Self, precision){ .matrix = self };
        }

        /// Returns a formatter for scientific notation
        pub fn scientific(self: Self) formatting.ScientificFormatter(Self) {
            return formatting.ScientificFormatter(Self){ .matrix = self };
        }

        /// Default formatting (scientific notation)
        pub fn format(self: Self, writer: *std.Io.Writer) !void {
            try formatting.formatMatrix(self, "{e}", writer);
        }

        /// Sums all the elements in rows.
        pub fn sumRows(self: Self) SMatrix(T, 1, cols) {
            var result: SMatrix(T, 1, cols) = .initAll(0);
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[0][c] = result.items[0][c] + self.items[r][c];
                }
            }
            return result;
        }

        /// Sums all the elements in columns.
        pub fn sumCols(self: Self) SMatrix(T, rows, 1) {
            var result: SMatrix(T, rows, 1) = .initAll(0);
            for (0..rows) |r| {
                for (0..cols) |c| {
                    result.items[r][0] = result.items[r][0] + self.items[r][c];
                }
            }
            return result;
        }
    };
}

test "SMatrix identity" {
    const eye: SMatrix(f32, 3, 3) = .identity();
    try expectEqual(eye.sum(), 3);
    for (0..eye.rows) |r| {
        for (0..eye.cols) |c| {
            if (r == c) {
                try expectEqual(eye.at(r, c).*, 1);
            } else {
                try expectEqual(eye.at(r, c).*, 0);
            }
        }
    }
}

test "SMatrix initAll" {
    const zeros: SMatrix(f32, 3, 3) = .initAll(0);
    try expectEqual(zeros.sum(), 0);
    const ones: SMatrix(f32, 3, 3) = .initAll(1);
    const shape = ones.shape();
    try expectEqual(ones.sum(), @as(f32, @floatFromInt(shape[0] * shape[1])));
}

test "SMatrix shape" {
    const matrix: SMatrix(f32, 4, 5) = .{};
    const shape = matrix.shape();
    try expectEqual(shape[0], 4);
    try expectEqual(shape[1], 5);
}

test "SMatrix scale" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const a: SMatrix(f32, 4, 3) = .random(seed);
    const b = SMatrix(f32, 4, 3).random(seed).scale(std.math.pi);
    try expectEqualDeep(a.shape(), b.shape());
    for (0..a.rows) |r| {
        for (0..a.cols) |c| {
            try expectEqual(std.math.pi * a.at(r, c).*, b.at(r, c).*);
        }
    }
}

test "SMatrix apply" {
    var a: SMatrix(f32, 3, 4) = .random(null);

    const f = struct {
        fn f(x: f32) f32 {
            return @sin(x);
        }
    }.f;

    var b = a.apply(f);
    try expectEqualDeep(a.shape(), b.shape());
    for (0..a.rows) |r| {
        for (0..a.cols) |c| {
            try expectEqual(@sin(a.at(r, c).*), b.at(r, c).*);
        }
    }
}

test "SMatrix norm" {
    var matrix: SMatrix(f32, 3, 4) = .random(null);
    try expectEqual(matrix.frobeniusNorm(), @sqrt(matrix.times(matrix).sum()));

    const f = struct {
        fn f(x: f32) f32 {
            return @abs(x);
        }
    }.f;
    try expectEqual(matrix.nuclearNorm(), matrix.apply(f).sum());

    matrix.at(2, 3).* = 1000000;
    try expectEqual(matrix.maxNorm(), 1000000);

    matrix = matrix.offset(10);
    matrix.at(2, 3).* = -5;
    try expectEqual(matrix.minNorm(), 5);

    matrix.at(2, 3).* = 0;
    try expectEqual(matrix.sparseNorm(), 11);

    // Test general norm function
    try expectEqual(matrix.norm(0), matrix.sparseNorm());
    try expectEqual(matrix.norm(1), matrix.nuclearNorm());
    try expectEqual(matrix.norm(2), matrix.frobeniusNorm());
    try expectEqual(matrix.norm(std.math.inf(f32)), matrix.maxNorm());
    try expectEqual(matrix.norm(-std.math.inf(f32)), matrix.minNorm());
}

test "SMatrix sum" {
    var matrix: SMatrix(f32, 3, 4) = .initAll(1);
    const matrixSumCols: SMatrix(f32, 3, 1) = .initAll(4);
    const matrixSumRows: SMatrix(f32, 1, 4) = .initAll(3);
    try expectEqual(matrix.sumRows(), matrixSumRows);
    try expectEqual(matrix.sumCols(), matrixSumCols);
    try expectEqual(matrix.sumCols().sumRows().item(), matrix.sum());
}

test "SMatrix inverse" {
    var a: SMatrix(f32, 2, 2) = .{};
    a.at(0, 0).* = -1;
    a.at(0, 1).* = 1.5;
    a.at(1, 0).* = 1;
    a.at(1, 1).* = -1;
    try expectEqual(a.determinant(), -0.5);
    var a_i: SMatrix(f32, 2, 2) = .{};
    a_i.at(0, 0).* = 2;
    a_i.at(0, 1).* = 3;
    a_i.at(1, 0).* = 2;
    a_i.at(1, 1).* = 2;
    try expectEqualDeep(a.inverse(), a_i);
    var b: SMatrix(f32, 3, 3) = .{};
    b.at(0, 0).* = 1;
    b.at(0, 1).* = 2;
    b.at(0, 2).* = 3;
    b.at(1, 0).* = 4;
    b.at(1, 1).* = 5;
    b.at(1, 2).* = 6;
    b.at(2, 0).* = 7;
    b.at(2, 1).* = 2;
    b.at(2, 2).* = 9;
    try expectEqual(b.determinant(), -36);
    var b_i: SMatrix(f32, 3, 3) = .{};
    b_i.at(0, 0).* = -11.0 / 12.0;
    b_i.at(0, 1).* = 1.0 / 3.0;
    b_i.at(0, 2).* = 1.0 / 12.0;
    b_i.at(1, 0).* = -1.0 / 6.0;
    b_i.at(1, 1).* = 1.0 / 3.0;
    b_i.at(1, 2).* = -1.0 / 6.0;
    b_i.at(2, 0).* = 3.0 / 4.0;
    b_i.at(2, 1).* = -1.0 / 3.0;
    b_i.at(2, 2).* = 1.0 / 12.0;
    try expectEqualDeep(b.inverse().?, b_i);
}

test "SMatrix row and column extraction" {
    // Test data
    const test_matrix: SMatrix(f32, 3, 2) = .init(.{
        .{ 1.0, 2.0 },
        .{ 3.0, 4.0 },
        .{ 5.0, 6.0 },
    });

    // Test SMatrix row/col extraction
    const static_row = test_matrix.row(1);
    const static_col = test_matrix.col(1);
    try expectEqual(@as(f32, 3.0), static_row.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), static_row.at(0, 1).*);
    try expectEqual(@as(f32, 2.0), static_col.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), static_col.at(1, 0).*);
    try expectEqual(@as(f32, 6.0), static_col.at(2, 0).*);
}

test "SMatrix matrix multiplication (dot product)" {
    // Test matrices
    const static_a: SMatrix(f32, 2, 3) = .init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });
    const static_b: SMatrix(f32, 3, 2) = .init(.{
        .{ 7.0, 8.0 },
        .{ 9.0, 10.0 },
        .{ 11.0, 12.0 },
    });

    // SMatrix dot product
    const static_result = static_a.dot(static_b);
    try expectEqual(@as(f32, 58.0), static_result.at(0, 0).*); // 1*7 + 2*9 + 3*11 = 58
    try expectEqual(@as(f32, 64.0), static_result.at(0, 1).*); // 1*8 + 2*10 + 3*12 = 64
    try expectEqual(@as(f32, 139.0), static_result.at(1, 0).*); // 4*7 + 5*9 + 6*11 = 139
    try expectEqual(@as(f32, 154.0), static_result.at(1, 1).*); // 4*8 + 5*10 + 6*12 = 154
}

test "SMatrix operations: add, sub, scale, transpose" {
    // Test data
    const static_matrix: SMatrix(f32, 2, 3) = .init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });

    // Test operand matrix for add/sub operations
    const static_operand: SMatrix(f32, 2, 3) = .init(.{
        .{ 0.5, 1.0, 1.5 },
        .{ 2.0, 2.5, 3.0 },
    });

    // SMatrix operations
    const static_scaled = static_matrix.scale(2.0);
    const static_transposed = static_matrix.transpose();
    const static_added = static_matrix.add(static_operand);
    const static_subtracted = static_matrix.sub(static_operand);

    try expectEqual(@as(f32, 2.0), static_scaled.at(0, 0).*);
    try expectEqual(@as(f32, 12.0), static_scaled.at(1, 2).*);
    try expectEqual(@as(usize, 3), static_transposed.rows);
    try expectEqual(@as(usize, 2), static_transposed.cols);
    try expectEqual(@as(f32, 1.0), static_transposed.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), static_transposed.at(0, 1).*);
    try expectEqual(@as(f32, 1.5), static_added.at(0, 0).*); // 1.0 + 0.5
    try expectEqual(@as(f32, 9.0), static_added.at(1, 2).*); // 6.0 + 3.0
    try expectEqual(@as(f32, 0.5), static_subtracted.at(0, 0).*); // 1.0 - 0.5
    try expectEqual(@as(f32, 3.0), static_subtracted.at(1, 2).*); // 6.0 - 3.0
}

test "SMatrix gram and covariance matrices" {
    // Create test matrix (3 samples × 2 features)
    const data: SMatrix(f64, 3, 2) = .init(.{
        .{ 1.0, 2.0 },
        .{ 3.0, 4.0 },
        .{ 5.0, 6.0 },
    });

    // Test Gram matrix (X * X^T) - should be 3×3
    const gram_result = data.gram();
    try expectEqual(@as(usize, 3), gram_result.rows);
    try expectEqual(@as(usize, 3), gram_result.cols);

    // Verify gram matrix values
    // First row: [1*1+2*2, 1*3+2*4, 1*5+2*6] = [5, 11, 17]
    try expectEqual(@as(f64, 5.0), gram_result.at(0, 0).*);
    try expectEqual(@as(f64, 11.0), gram_result.at(0, 1).*);
    try expectEqual(@as(f64, 17.0), gram_result.at(0, 2).*);

    // Test Covariance matrix (X^T * X) - should be 2×2
    const cov_result = data.covariance();
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

test "SMatrix GEMM operations" {
    // Test matrices
    const a: SMatrix(f32, 2, 3) = .init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });
    const b: SMatrix(f32, 3, 2) = .init(.{
        .{ 7.0, 8.0 },
        .{ 9.0, 10.0 },
        .{ 11.0, 12.0 },
    });
    const c: SMatrix(f32, 2, 2) = .init(.{
        .{ 1.0, 1.0 },
        .{ 1.0, 1.0 },
    });

    // Test basic matrix multiplication: A * B
    const result1 = a.gemm(false, b, false, 1.0, 0.0, null);
    try expectEqual(@as(f32, 58.0), result1.at(0, 0).*); // 1*7 + 2*9 + 3*11
    try expectEqual(@as(f32, 64.0), result1.at(0, 1).*); // 1*8 + 2*10 + 3*12
    try expectEqual(@as(f32, 139.0), result1.at(1, 0).*); // 4*7 + 5*9 + 6*11
    try expectEqual(@as(f32, 154.0), result1.at(1, 1).*); // 4*8 + 5*10 + 6*12

    // Test scaled multiplication: 2 * A * B
    const result2 = a.gemm(false, b, false, 2.0, 0.0, null);
    try expectEqual(@as(f32, 116.0), result2.at(0, 0).*); // 2 * 58
    try expectEqual(@as(f32, 128.0), result2.at(0, 1).*); // 2 * 64

    // Test accumulation: A * B + C
    const result3 = a.gemm(false, b, false, 1.0, 1.0, c);
    try expectEqual(@as(f32, 59.0), result3.at(0, 0).*); // 58 + 1
    try expectEqual(@as(f32, 65.0), result3.at(0, 1).*); // 64 + 1

    // Test Gram matrix using GEMM: A * A^T
    const gram = a.gemm(false, a, true, 1.0, 0.0, null);
    try expectEqual(@as(usize, 2), gram.rows);
    try expectEqual(@as(usize, 2), gram.cols);
    try expectEqual(@as(f32, 14.0), gram.at(0, 0).*); // 1*1 + 2*2 + 3*3
    try expectEqual(@as(f32, 32.0), gram.at(0, 1).*); // 1*4 + 2*5 + 3*6

    // Test covariance using GEMM: A^T * A
    const cov = a.gemm(true, a, false, 1.0, 0.0, null);
    try expectEqual(@as(usize, 3), cov.rows);
    try expectEqual(@as(usize, 3), cov.cols);
    try expectEqual(@as(f32, 17.0), cov.at(0, 0).*); // 1*1 + 4*4
    try expectEqual(@as(f32, 22.0), cov.at(0, 1).*); // 1*2 + 4*5

    // Test alpha = 0 (should return zero matrix)
    const zero_result = a.gemm(false, b, false, 0.0, 0.0, null);
    try expectEqual(@as(f32, 0.0), zero_result.at(0, 0).*);
    try expectEqual(@as(f32, 0.0), zero_result.at(1, 1).*);
}

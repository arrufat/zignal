//! Static matrix with compile-time dimensions

const std = @import("std");
const assert = std.debug.assert;
const formatting = @import("formatting.zig");

const Point2d = @import("../geometry/points.zig").Point2d;
const Point3d = @import("../geometry/points.zig").Point3d;

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
                for (0..cols) |c| {
                    result.items[r][c] = value;
                }
            }
            return result;
        }

        /// Returns an identity-like matrix.
        pub fn identity() Self {
            var result: Self = .{};
            for (0..rows) |r| {
                for (0..cols) |c| {
                    if (r == c) {
                        result.items[r][c] = 1;
                    } else {
                        result.items[r][c] = 0;
                    }
                }
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

        /// Performs the dot (or internal product) of two matrices.
        pub fn dot(self: Self, other: anytype) SMatrix(T, rows, other.cols) {
            comptime assert(cols == other.rows);
            var result: SMatrix(T, rows, other.cols) = .initAll(0);
            for (0..rows) |r| {
                for (0..other.cols) |c| {
                    for (0..cols) |k| {
                        result.items[r][c] += self.items[r][k] * other.items[k][c];
                    }
                }
            }
            return result;
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

        /// Converts a column matrix into a Point2d.
        pub fn toPoint2d(self: Self) Point2d(T) {
            comptime assert(rows >= 2 and cols == 1);
            return .{ .x = self.items[0][0], .y = self.items[1][0] };
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
                2 => self.at(0, 0).* * self.at(1, 1).* - self.at(0, 1).* * self.at(1, 0).*,
                3 => self.at(0, 0).* * self.at(1, 1).* * self.at(2, 2).* +
                    self.at(0, 1).* * self.at(1, 2).* * self.at(2, 0).* +
                    self.at(0, 2).* * self.at(1, 0).* * self.at(2, 1).* -
                    self.at(0, 2).* * self.at(1, 1).* * self.at(2, 0).* -
                    self.at(0, 1).* * self.at(1, 0).* * self.at(2, 2).* -
                    self.at(0, 0).* * self.at(1, 2).* * self.at(2, 1).*,
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
                else => @compileError("Matrix(T).inverse() is not implemented for sizes above 3"),
            }
            return inv;
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
        pub fn format(self: Self, writer: anytype) !void {
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

// Tests for SMatrix functionality
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

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
    const test_matrix = SMatrix(f32, 3, 2).init(.{
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
    const static_a = SMatrix(f32, 2, 3).init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });
    const static_b = SMatrix(f32, 3, 2).init(.{
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
    const static_matrix = SMatrix(f32, 2, 3).init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });

    // Test operand matrix for add/sub operations
    const static_operand = SMatrix(f32, 2, 3).init(.{
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

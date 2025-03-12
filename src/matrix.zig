const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const builtin = @import("builtin");

const Point2d = @import("point.zig").Point2d;
const Point3d = @import("point.zig").Point3d;

/// Creates a Matrix with elements of type T and size rows times cols.
pub fn Matrix(comptime T: type, comptime rows: usize, comptime cols: usize) type {
    assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();
        comptime rows: usize = rows,
        comptime cols: usize = cols,
        items: [rows][cols]T = undefined,

        /// Sets all elements to value.
        pub fn initAll(value: T) Self {
            var self = Self{};
            for (&self.items) |*row| {
                for (row) |*col| {
                    col.* = value;
                }
            }
            return self;
        }

        /// Returns an identity matrix of the matrix size.
        pub fn identity() Self {
            var self = Self{};
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    if (r == c) {
                        self.items[r][c] = 1;
                    } else {
                        self.items[r][c] = 0;
                    }
                }
            }
            return self;
        }

        /// Returns a matrix filled with random numbers.
        pub fn random(seed: ?u64) Self {
            const s: u64 = seed orelse @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
            var prng: std.Random.DefaultPrng = .init(s);
            var rand = prng.random();
            var self = Self{};
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    self.items[r][c] = rand.float(T);
                }
            }
            return self;
        }

        /// Returns the rows and columns as a struct.
        pub fn shape(self: Self) struct { usize, usize } {
            return .{
                self.rows,
                self.cols,
            };
        }

        /// Reshapes the matrix to a new shape.
        pub fn reshape(self: Self, comptime new_rows: usize, comptime new_cols: usize) Matrix(T, new_rows, new_cols) {
            comptime assert(rows * cols == new_rows * new_cols);
            var matrix = Matrix(T, new_rows, new_cols){};
            for (0..new_rows) |r| {
                for (0..new_cols) |c| {
                    const idx = r * new_cols + c;
                    matrix.items[r][c] = self.at(idx / cols, @mod(idx, cols));
                }
            }
            return matrix;
        }

        /// Returns a string representation of the matrix, for printing.
        pub fn toString(self: Self) [rows * cols * @bitSizeOf(T)]u8 {
            var print_buffer: [rows * cols * @bitSizeOf(T)]u8 = undefined;
            var printed: usize = 0;
            var written: []u8 = undefined;
            for (self.items) |row| {
                for (row) |val| {
                    written = std.fmt.bufPrint(print_buffer[printed..], " {}", .{val}) catch unreachable;
                    printed += written.len;
                }
                written = std.fmt.bufPrint(print_buffer[printed..], "\n", .{}) catch unreachable;
                printed += written.len;
            }
            return print_buffer;
        }

        /// Converts a 2D+ column matrix into a Point2d.
        pub fn toPoint2d(self: Self) Point2d(T) {
            comptime assert(rows >= 2 and cols == 1);
            return .{ .x = self.at(0, 0), .y = self.at(1, 0) };
        }

        /// Converts a 3D+ column matrix into a Point3d.
        pub fn toPoint3d(self: Self) Point3d(T) {
            comptime assert(rows >= 3 and cols == 1);
            return .{ .x = self.at(0, 0), .y = self.at(1, 0), .z = self.at(2, 0) };
        }

        /// Retrieves the element at position row, col in the matrix.
        pub fn at(self: Self, row: usize, col: usize) T {
            assert(row < self.rows);
            assert(col < self.cols);
            return self.items[row][col];
        }

        /// Sets the element at row, col to val.
        pub fn set(self: *Self, row: usize, col: usize, val: T) void {
            assert(row < self.rows);
            assert(col < self.cols);
            self.items[row][col] = val;
        }

        /// Computes the trace (i.e. sum of the diagonal elements).
        pub fn trace(self: Self) T {
            comptime assert(self.cols == self.rows);
            var val: T = 0;
            for (0..self.cols) |i| {
                val += self.items[i][i];
            }
            return val;
        }

        /// Adds an offset to all matrix values.
        pub fn offset(self: Self, value: T) Self {
            var matrix: Self = undefined;
            for (0..rows) |r| {
                for (0..cols) |c| {
                    matrix.items[r][c] = value + self.items[r][c];
                }
            }
            return matrix;
        }

        /// Scales all matrix values.
        pub fn scale(self: Self, value: T) Self {
            var matrix: Self = undefined;
            for (0..rows) |r| {
                for (0..cols) |c| {
                    matrix.items[r][c] = value * self.items[r][c];
                }
            }
            return matrix;
        }

        /// Applies a unary function to all matrix values.
        pub fn apply(self: Self, comptime unaryFn: fn (arg: T) T) Self {
            var matrix: Self = undefined;
            for (0..rows) |r| {
                for (0..cols) |c| {
                    matrix.items[r][c] = unaryFn(self.items[r][c]);
                }
            }
            return matrix;
        }

        /// Sets the sub-matrix at positon row, col to sub_matrix.
        pub fn setSubMatrix(self: *Self, row: usize, col: usize, matrix: anytype) void {
            assert(matrix.rows + row <= self.rows);
            assert(matrix.cols + col <= self.cols);
            for (0..matrix.rows) |r| {
                for (0..matrix.cols) |c| {
                    self.items[row + r][col + c] = matrix.items[r][c];
                }
            }
        }

        /// Sets the elements in the row.
        pub fn setRow(self: *Self, row: usize, values: [cols]T) void {
            assert(row < self.rows);
            for (0..self.cols) |c| {
                self.items[row][c] = values[c];
            }
        }

        /// Sets the elements in the column.
        pub fn setCol(self: *Self, col: usize, values: [rows]T) void {
            assert(col < self.cols);
            for (0..self.rows) |r| {
                self.items[r][col] = values[r];
            }
        }

        /// Returns the sub-matrix at positon row, col.
        pub fn getSubMatrix(
            self: Self,
            comptime row_begin: usize,
            comptime col_begin: usize,
            comptime row_end: usize,
            comptime col_end: usize,
        ) Matrix(T, row_end - row_begin, col_end - col_begin) {
            comptime assert(row_begin < row_end);
            comptime assert(col_begin < col_end);
            comptime assert(row_end <= self.rows);
            comptime assert(col_end <= self.cols);
            var matrix: Matrix(T, row_end - row_begin, col_end - col_begin) = undefined;
            for (row_begin..row_end) |r| {
                for (col_begin..col_end) |c| {
                    matrix.items[r - row_begin][c - col_begin] = self.items[r][c];
                }
            }
            return matrix;
        }

        /// Returns the elements in the row as a row Matrix.
        pub fn getRow(self: Self, row: usize) Matrix(T, 1, cols) {
            assert(row < self.rows);
            var matrix = Matrix(T, 1, cols){};
            for (0..self.cols) |c| {
                matrix.items[0][c] = self.items[row][c];
            }
            return matrix;
        }

        /// Returns the elements in the column as a column Matrix.
        pub fn getCol(self: Self, col: usize) Matrix(T, rows, 1) {
            assert(col < self.cols);
            var matrix = Matrix(T, rows, 1){};
            for (0..self.rows) |r| {
                matrix.items[r][0] = self.items[r][col];
            }
            return matrix;
        }

        /// Transposes the matrix.
        pub fn transpose(self: Self) Matrix(T, cols, rows) {
            var m = Matrix(T, cols, rows){};
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    m.items[c][r] = self.items[r][c];
                }
            }
            return m;
        }

        /// Adds a matrix.
        pub fn add(self: Self, other: Self) Self {
            var result: @TypeOf(self) = undefined;
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.items[r][c] = self.items[r][c] + other.items[r][c];
                }
            }
            return result;
        }

        /// Performs pointwise multiplication
        pub fn times(self: Self, other: Self) Self {
            var result: @TypeOf(self) = undefined;
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.items[r][c] = self.items[r][c] * other.items[r][c];
                }
            }
            return result;
        }

        /// Performs the dot (or internal product) of two matrices.
        pub fn dot(self: Self, other: anytype) Matrix(T, self.rows, other.cols) {
            comptime assert(self.cols == other.rows);
            var result: Matrix(T, self.rows, other.cols) = .initAll(0);
            for (0..self.rows) |r| {
                for (0..other.cols) |c| {
                    for (0..self.cols) |k| {
                        result.items[r][c] += self.items[r][k] * other.items[k][c];
                    }
                }
            }
            return result;
        }

        /// If the matrix only contains one element, it returns it, otherwise it fails to compile.
        pub fn item(self: Self) T {
            comptime assert(self.rows == 1 and self.cols == 1);
            return self.items[0][0];
        }

        /// Sums all the elements in a matrix.
        pub fn sum(self: Self) T {
            var accum: T = 0;
            for (self.items) |row| {
                for (row) |col| {
                    accum += col;
                }
            }
            return accum;
        }

        /// Sums all the elements in columns.
        pub fn sumCols(self: Self) Matrix(T, rows, 1) {
            var result: Matrix(T, rows, 1) = .initAll(0);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.items[r][0] += self.items[r][c];
                }
            }
            return result;
        }

        /// Sums all the elements in rows.
        pub fn sumRows(self: Self) Matrix(T, 1, cols) {
            var result: Matrix(T, 1, cols) = .initAll(0);
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    result.items[0][c] += self.items[r][c];
                }
            }
            return result;
        }

        /// Computes the "element-wise" matrix norm of the matrix.
        pub fn norm(self: Self, p: T) T {
            assert(p >= 0);
            if (p == std.math.inf(T)) {
                return self.maxNorm();
            } else if (p == -std.math.inf(T)) {
                return self.minNorm();
            } else {
                var result: T = 0;
                for (self.items) |row| {
                    for (row) |col| {
                        result += if (col == 0) 0 else std.math.pow(T, @abs(col), p);
                    }
                }
                return if (p != 0) std.math.pow(T, result, (1 / p)) else result;
            }
        }

        /// Computes the L0 norm, also know as the sparse norm of the matrix.
        pub fn sparseNorm(self: Self) T {
            return self.norm(0);
        }

        /// Computes the Frobenius norm of the matrix as the square root of the sum of its squared values.
        pub fn frobeniusNorm(self: Self) T {
            return self.norm(2);
        }

        /// Computes the Nuclear norm of the matrix as the sum of its absolute values.
        pub fn nuclearNorm(self: Self) T {
            return self.norm(1);
        }

        /// Computes the Max norm of the matrix as the maximum absolute value.
        pub fn maxNorm(self: Self) T {
            var result: T = -std.math.inf(T);
            for (self.items) |row| {
                for (row) |col| {
                    const val = @abs(col);
                    if (val > result) {
                        result = val;
                    }
                }
            }
            return result;
        }

        /// Computes the Min norm of the matrix as the minimum absolute value.
        pub fn minNorm(self: Self) T {
            var result: T = std.math.inf(T);
            for (self.items) |row| {
                for (row) |col| {
                    const val = @abs(col);
                    if (val < result) {
                        result = val;
                    }
                }
            }
            return result;
        }

        /// Computes the determinant of self if it's a square matrix, otherwise it fails to compile.
        pub fn determinant(self: Self) T {
            comptime assert(self.rows == self.cols);
            return switch (self.rows) {
                1 => self.item(),
                2 => self.at(0, 0) * self.at(1, 1) - self.at(0, 1) * self.at(1, 0),
                3 => self.at(0, 0) * self.at(1, 1) * self.at(2, 2) +
                    self.at(0, 1) * self.at(1, 2) * self.at(2, 0) +
                    self.at(0, 2) * self.at(1, 0) * self.at(2, 1) -
                    self.at(0, 2) * self.at(1, 1) * self.at(2, 0) -
                    self.at(0, 1) * self.at(1, 0) * self.at(2, 2) -
                    self.at(0, 0) * self.at(1, 2) * self.at(2, 1),
                else => @compileError("Matrix(T).determinant() is not implemented for sizes above 3"),
            };
        }

        /// Computes the inverse of self if it's a square matrix, otherwise it fails to compile.
        /// Returns null if the matrix is not invertible.
        pub fn inverse(self: Self) ?Self {
            comptime assert(self.rows == self.cols);
            const det = self.determinant();
            if (det == 0) {
                return null;
            }
            var inv = Self{};
            switch (self.rows) {
                1 => inv.items[0][0] = 1 / det,
                2 => {
                    inv.items[0][0] = self.at(1, 1) / det;
                    inv.items[0][1] = -self.at(0, 1) / det;
                    inv.items[1][0] = -self.at(1, 0) / det;
                    inv.items[1][1] = self.at(0, 0) / det;
                },
                3 => {
                    inv.items[0][0] = (self.at(1, 1) * self.at(2, 2) - self.at(1, 2) * self.at(2, 1)) / det;
                    inv.items[0][1] = (self.at(0, 2) * self.at(2, 1) - self.at(0, 1) * self.at(2, 2)) / det;
                    inv.items[0][2] = (self.at(0, 1) * self.at(1, 2) - self.at(0, 2) * self.at(1, 1)) / det;
                    inv.items[1][0] = (self.at(1, 2) * self.at(2, 0) - self.at(1, 0) * self.at(2, 2)) / det;
                    inv.items[1][1] = (self.at(0, 0) * self.at(2, 2) - self.at(0, 2) * self.at(2, 0)) / det;
                    inv.items[1][2] = (self.at(0, 2) * self.at(1, 0) - self.at(0, 0) * self.at(1, 2)) / det;
                    inv.items[2][0] = (self.at(1, 0) * self.at(2, 1) - self.at(1, 1) * self.at(2, 0)) / det;
                    inv.items[2][1] = (self.at(0, 1) * self.at(2, 0) - self.at(0, 0) * self.at(2, 1)) / det;
                    inv.items[2][2] = (self.at(0, 0) * self.at(1, 1) - self.at(0, 1) * self.at(1, 0)) / det;
                },
                else => @compileError("Matrix(T).inverse() is not implemented for sizes above 3"),
            }
            return inv;
        }
    };
}

test "identity" {
    const eye: Matrix(f32, 3, 3) = .identity();
    try expectEqual(eye.sum(), 3);
    for (0..eye.rows) |r| {
        for (0..eye.cols) |c| {
            if (r == c) {
                try expectEqual(eye.at(r, c), 1);
            } else {
                try expectEqual(eye.at(r, c), 0);
            }
        }
    }
}

test "initAll" {
    const zeros: Matrix(f32, 3, 3) = .initAll(0);
    try expectEqual(zeros.sum(), 0);
    const ones: Matrix(f32, 3, 3) = .initAll(1);
    const shape = ones.shape();
    try expectEqual(ones.sum(), @as(f32, @floatFromInt(shape[0] * shape[1])));
}

test "shape" {
    const matrix: Matrix(f32, 4, 5) = .{};
    const shape = matrix.shape();
    try expectEqual(shape[0], 4);
    try expectEqual(shape[1], 5);
}

test "scale" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const a: Matrix(f32, 4, 3) = .random(seed);
    const b = Matrix(f32, 4, 3).random(seed).scale(std.math.pi);
    try expectEqualDeep(a.shape(), b.shape());
    for (0..a.rows) |r| {
        for (0..a.cols) |c| {
            try expectEqual(std.math.pi * a.at(r, c), b.at(r, c));
        }
    }
}

test "apply" {
    var a: Matrix(f32, 3, 4) = .random(null);

    const f = struct {
        fn f(x: f32) f32 {
            return @sin(x);
        }
    }.f;

    var b = a.apply(f);
    try expectEqualDeep(a.shape(), b.shape());
    for (0..a.rows) |r| {
        for (0..a.cols) |c| {
            try expectEqual(@sin(a.at(r, c)), b.at(r, c));
        }
    }
}

test "norm" {
    var matrix: Matrix(f32, 3, 4) = .random(null);
    try expectEqual(matrix.frobeniusNorm(), @sqrt(matrix.times(matrix).sum()));

    const f = struct {
        fn f(x: f32) f32 {
            return @abs(x);
        }
    }.f;
    try expectEqual(matrix.nuclearNorm(), matrix.apply(f).sum());

    matrix.set(2, 3, 1000000);
    try expectEqual(matrix.maxNorm(), 1000000);

    matrix = matrix.offset(10);
    matrix.set(2, 3, -5);
    try expectEqual(matrix.minNorm(), 5);

    matrix.set(2, 3, 0);
    try expectEqual(matrix.sparseNorm(), 11);
}

test "sum" {
    var matrix: Matrix(f32, 3, 4) = .initAll(1);
    const matrixSumCols: Matrix(f32, 3, 1) = .initAll(4);
    const matrixSumRows: Matrix(f32, 1, 4) = .initAll(3);
    try expectEqual(matrix.sumRows(), matrixSumRows);
    try expectEqual(matrix.sumCols(), matrixSumCols);
    try expectEqual(matrix.sumCols().sumRows().item(), matrix.sum());
}

test "inverse" {
    const a: Matrix(f32, 2, 2) = .{ .items = .{ .{ -1, 1.5 }, .{ 1, -1 } } };
    try expectEqual(a.determinant(), -0.5);
    const a_i: Matrix(f32, 2, 2) = .{ .items = .{ .{ 2, 3 }, .{ 2, 2 } } };
    try expectEqualDeep(a.inverse(), a_i);
    const b: Matrix(f32, 3, 3) = .{ .items = .{ .{ 1, 2, 3 }, .{ 4, 5, 6 }, .{ 7, 2, 9 } } };
    try expectEqual(b.determinant(), -36);
    const b_i: Matrix(f32, 3, 3) = .{ .items = .{
        .{ -11.0 / 12.0, 1.0 / 3.0, 1.0 / 12.0 },
        .{ -1.0 / 6.0, 1.0 / 3.0, -1.0 / 6.0 },
        .{ 3.0 / 4.0, -1.0 / 3.0, 1.0 / 12.0 },
    } };
    try expectEqualDeep(b.inverse().?, b_i);
}

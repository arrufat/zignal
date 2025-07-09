//! This module provides a generic, fixed-size Matrix struct for floating-point types
//! and a collection of common linear algebra operations such as addition, multiplication,
//! dot product, transpose, norm computation, determinant, and inverse (for small matrices).
const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const builtin = @import("builtin");

const Point2d = @import("geometry/points.zig").Point2d;
const Point3d = @import("geometry/points.zig").Point3d;

/// Helper function to format numbers with fallback to scientific notation
fn formatNumber(comptime T: type, buf: []u8, comptime format_str: []const u8, value: T) []const u8 {
    return std.fmt.bufPrint(buf, format_str, .{value}) catch {
        // If formatting fails (number too large), try scientific notation
        return std.fmt.bufPrint(buf, "{}", .{value}) catch {
            // If even scientific notation fails, use a fallback
            return "ERR";
        };
    };
}

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
        pub fn toMatrix(self: Self, allocator: std.mem.Allocator) !Matrix(T) {
            var result = try Matrix(T).init(allocator, rows, cols);
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

        /// Formats the matrix for pretty printing with configurable precision.
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;

            // First pass: calculate the maximum width needed for each column
            var col_widths: [cols]usize = [_]usize{0} ** cols;

            for (0..rows) |r| {
                for (0..cols) |c| {
                    // Create a temporary buffer to measure the width of this element
                    var temp_buf: [64]u8 = undefined;
                    const formatted = if (options.precision) |precision|
                        switch (precision) {
                            inline 0...15 => |p| formatNumber(T, temp_buf[0..], std.fmt.comptimePrint("{{d:.{d}}}", .{p}), self.items[r][c]),
                            else => formatNumber(T, temp_buf[0..], "{d}", self.items[r][c]),
                        }
                    else
                        formatNumber(T, temp_buf[0..], "{}", self.items[r][c]);
                    col_widths[c] = @max(col_widths[c], formatted.len);
                }
            }

            // Second pass: format and write the matrix with proper alignment
            for (0..rows) |r| {
                try writer.writeAll("[ ");
                for (0..cols) |c| {
                    // Format the number with specified precision
                    var temp_buf: [64]u8 = undefined;
                    const formatted = if (options.precision) |precision|
                        switch (precision) {
                            inline 0...15 => |p| formatNumber(T, temp_buf[0..], std.fmt.comptimePrint("{{d:.{d}}}", .{p}), self.items[r][c]),
                            else => formatNumber(T, temp_buf[0..], "{d}", self.items[r][c]),
                        }
                    else
                        formatNumber(T, temp_buf[0..], "{}", self.items[r][c]);

                    // Right-align the number within the column width
                    const padding = col_widths[c] - formatted.len;
                    for (0..padding) |_| {
                        try writer.writeAll(" ");
                    }
                    try writer.writeAll(formatted);

                    if (c < cols - 1) {
                        try writer.writeAll("  "); // Two spaces between columns
                    }
                }
                try writer.writeAll(" ]");
                if (r < rows - 1) {
                    try writer.writeAll("\n");
                }
            }
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

/// Matrix with runtime dimensions using flat array storage
pub fn Matrix(comptime T: type) type {
    assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();

        items: []T,
        rows: usize,
        cols: usize,
        allocator: std.mem.Allocator,

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
            self.allocator.free(self.items);
        }

        /// Returns the rows and columns as a struct.
        pub fn shape(self: Self) struct { usize, usize } {
            return .{ self.rows, self.cols };
        }

        /// Retrieves the element at position row, col in the matrix.
        pub inline fn at(self: Self, row: usize, col: usize) *T {
            assert(row < self.rows);
            assert(col < self.cols);
            return &self.items[row * self.cols + col];
        }

        /// Returns a matrix with all elements set to value.
        pub fn initAll(allocator: std.mem.Allocator, rows: usize, cols: usize, value: T) !Self {
            var result = try init(allocator, rows, cols);
            for (0..rows * cols) |i| {
                result.items[i] = value;
            }
            return result;
        }

        /// Returns an identity-like matrix.
        pub fn identity(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            var result = try init(allocator, rows, cols);
            for (0..rows) |r| {
                for (0..cols) |c| {
                    if (r == c) {
                        result.set(r, c, 1);
                    } else {
                        result.set(r, c, 0);
                    }
                }
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
            var squared_sum: T = 0;
            for (self.items) |val| {
                squared_sum += val * val;
            }
            return @sqrt(squared_sum);
        }

        /// Formats the matrix for pretty printing with configurable precision.
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;

            // Use a fixed-size array for column widths (should be sufficient for most cases)
            // For very large matrices, this will just work with default alignment
            var col_widths_buffer: [256]usize = undefined;
            const col_widths = if (self.cols <= 256) col_widths_buffer[0..self.cols] else blk: {
                // For very wide matrices, skip column width calculation
                @memset(col_widths_buffer[0..], 0);
                break :blk col_widths_buffer[0..0];
            };

            if (col_widths.len > 0) {
                @memset(col_widths, 0);

                // First pass: calculate the maximum width needed for each column
                for (0..self.rows) |r| {
                    for (0..self.cols) |c| {
                        // Create a temporary buffer to measure the width of this element
                        var temp_buf: [64]u8 = undefined;
                        const formatted = if (options.precision) |precision|
                            switch (precision) {
                                inline 0...15 => |p| formatNumber(T, temp_buf[0..], std.fmt.comptimePrint("{{d:.{d}}}", .{p}), self.at(r, c).*),
                                else => formatNumber(T, temp_buf[0..], "{d}", self.at(r, c).*),
                            }
                        else
                            formatNumber(T, temp_buf[0..], "{}", self.at(r, c).*);
                        col_widths[c] = @max(col_widths[c], formatted.len);
                    }
                }
            }

            // Second pass: format and write the matrix with proper alignment
            for (0..self.rows) |r| {
                try writer.writeAll("[ ");
                for (0..self.cols) |c| {
                    // Format the number with specified precision
                    var temp_buf: [64]u8 = undefined;
                    const formatted = if (options.precision) |precision|
                        switch (precision) {
                            inline 0...15 => |p| formatNumber(T, temp_buf[0..], std.fmt.comptimePrint("{{d:.{d}}}", .{p}), self.at(r, c).*),
                            else => formatNumber(T, temp_buf[0..], "{d}", self.at(r, c).*),
                        }
                    else
                        formatNumber(T, temp_buf[0..], "{}", self.at(r, c).*);

                    // Right-align the number within the column width
                    const padding = col_widths[c] - formatted.len;
                    for (0..padding) |_| {
                        try writer.writeAll(" ");
                    }
                    try writer.writeAll(formatted);

                    if (c < self.cols - 1) {
                        try writer.writeAll("  "); // Two spaces between columns
                    }
                }
                try writer.writeAll(" ]");
                if (r < self.rows - 1) {
                    try writer.writeAll("\n");
                }
            }
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
            assert(self.result.cols == other.rows);
            var new_result = try Matrix(T).init(self.allocator, self.result.rows, other.cols);

            for (0..self.result.rows) |r| {
                for (0..other.cols) |c| {
                    var accum: T = 0;
                    for (0..self.result.cols) |k| {
                        accum += self.result.at(r, k).* * other.at(k, c).*;
                    }
                    new_result.at(r, c).* = accum;
                }
            }

            self.result.deinit();
            self.result = new_result;
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

        /// Transfer ownership of the result to the caller
        pub fn toOwned(self: *Self) Matrix(T) {
            const final_result = self.result;
            // Mark as consumed to prevent deinit from freeing it
            self.consumed = true;
            return final_result;
        }
    };
}

test "identity" {
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

test "initAll" {
    const zeros: SMatrix(f32, 3, 3) = .initAll(0);
    try expectEqual(zeros.sum(), 0);
    const ones: SMatrix(f32, 3, 3) = .initAll(1);
    const shape = ones.shape();
    try expectEqual(ones.sum(), @as(f32, @floatFromInt(shape[0] * shape[1])));
}

test "shape" {
    const matrix: SMatrix(f32, 4, 5) = .{};
    const shape = matrix.shape();
    try expectEqual(shape[0], 4);
    try expectEqual(shape[1], 5);
}

test "scale" {
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

test "apply" {
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

test "norm" {
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

test "sum" {
    var matrix: SMatrix(f32, 3, 4) = .initAll(1);
    const matrixSumCols: SMatrix(f32, 3, 1) = .initAll(4);
    const matrixSumRows: SMatrix(f32, 1, 4) = .initAll(3);
    try expectEqual(matrix.sumRows(), matrixSumRows);
    try expectEqual(matrix.sumCols(), matrixSumCols);
    try expectEqual(matrix.sumCols().sumRows().item(), matrix.sum());
}

test "inverse" {
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

test "format" {
    // Test 2x3 matrix with known values
    var m: SMatrix(f32, 2, 3) = .{};
    m.at(0, 0).* = 1.23;
    m.at(0, 1).* = -4.5;
    m.at(0, 2).* = 7.0;
    m.at(1, 0).* = 10.1;
    m.at(1, 1).* = 0.0;
    m.at(1, 2).* = -5.67;

    // Test default formatting (scientific notation)
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try std.fmt.format(stream.writer(), "{}", .{m});
    const result_default = stream.getWritten();
    const expected_default = "[ 1.23e0  -4.5e0      7e0 ]\n[ 1.01e1     0e0  -5.67e0 ]";
    try std.testing.expect(std.mem.eql(u8, result_default, expected_default));

    // Test 2 decimal places
    stream.reset();
    try std.fmt.format(stream.writer(), "{:.2}", .{m});
    const result_2dp = stream.getWritten();
    const expected_2dp = "[  1.23  -4.50   7.00 ]\n[ 10.10   0.00  -5.67 ]";
    try std.testing.expect(std.mem.eql(u8, result_2dp, expected_2dp));

    // Test 0 decimal places (integers)
    stream.reset();
    try std.fmt.format(stream.writer(), "{:.0}", .{m});
    const result_0dp = stream.getWritten();
    const expected_0dp = "[  1  -5   7 ]\n[ 10   0  -6 ]";
    try std.testing.expect(std.mem.eql(u8, result_0dp, expected_0dp));

    // Test 1x1 matrix
    var m_single: SMatrix(f64, 1, 1) = .{};
    m_single.at(0, 0).* = 3.14159;
    stream.reset();
    try std.fmt.format(stream.writer(), "{:.3}", .{m_single});
    const result_single = stream.getWritten();
    const expected_single = "[ 3.142 ]";
    try std.testing.expect(std.mem.eql(u8, result_single, expected_single));
}

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

test "row and column extraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

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

    // Verify both approaches give identical results
    try expectEqual(static_row.at(0, 0).*, dynamic_row.at(0, 0).*);
    try expectEqual(static_row.at(0, 1).*, dynamic_row.at(0, 1).*);
    try expectEqual(static_col.at(0, 0).*, dynamic_col.at(0, 0).*);
    try expectEqual(static_col.at(1, 0).*, dynamic_col.at(1, 0).*);
    try expectEqual(static_col.at(2, 0).*, dynamic_col.at(2, 0).*);
}

test "matrix multiplication (dot product)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

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

    // OpsBuilder dot product on equivalent matrices
    const dynamic_a = try static_a.toMatrix(arena.allocator());
    const dynamic_b = try static_b.toMatrix(arena.allocator());

    var ops = try OpsBuilder(f32).init(arena.allocator(), dynamic_a);
    try ops.dot(dynamic_b);
    const dynamic_result = ops.toOwned();

    // Verify both approaches give identical results
    try expectEqual(@as(usize, 2), dynamic_result.rows);
    try expectEqual(@as(usize, 2), dynamic_result.cols);
    for (0..2) |r| {
        for (0..2) |c| {
            try expectEqual(static_result.at(r, c).*, dynamic_result.at(r, c).*);
        }
    }
}

test "matrix operations: add, sub, scale, transpose" {
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
    try expectEqual(@as(f32, 1.5), static_added.at(0, 0).*);     // 1.0 + 0.5
    try expectEqual(@as(f32, 9.0), static_added.at(1, 2).*);     // 6.0 + 3.0
    try expectEqual(@as(f32, 0.5), static_subtracted.at(0, 0).*); // 1.0 - 0.5
    try expectEqual(@as(f32, 3.0), static_subtracted.at(1, 2).*); // 6.0 - 3.0

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

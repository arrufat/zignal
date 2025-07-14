//! Dynamic matrix with runtime dimensions

const std = @import("std");
const assert = std.debug.assert;
const formatting = @import("formatting.zig");
const SMatrix = @import("SMatrix.zig").SMatrix;

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
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

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
    var stream = std.io.fixedBufferStream(&buffer);

    // Test default format (scientific notation)
    try std.fmt.format(stream.writer(), "{f}", .{dm});
    const result_default = stream.getWritten();
    const expected_default =
        \\[ 3.14159e0  -2.71828e0 ]
        \\[ 1.41421e0   5.7721e-1 ]
    ;
    try expectEqualStrings(expected_default, result_default);

    // Test decimal(3) formatting
    stream.reset();
    try std.fmt.format(stream.writer(), "{f}", .{dm.decimal(3)});
    const result_decimal3 = stream.getWritten();
    const expected_decimal3 =
        \\[ 3.142  -2.718 ]
        \\[ 1.414   0.577 ]
    ;
    try expectEqualStrings(expected_decimal3, result_decimal3);

    // Test decimal(0) formatting
    stream.reset();
    try std.fmt.format(stream.writer(), "{f}", .{dm.decimal(0)});
    const result_decimal0 = stream.getWritten();
    const expected_decimal0 =
        \\[ 3  -3 ]
        \\[ 1   1 ]
    ;
    try expectEqualStrings(expected_decimal0, result_decimal0);

    // Test scientific formatting
    stream.reset();
    try std.fmt.format(stream.writer(), "{f}", .{dm.scientific()});
    const result_scientific = stream.getWritten();
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

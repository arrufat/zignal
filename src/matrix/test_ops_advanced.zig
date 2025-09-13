const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Matrix = @import("Matrix.zig").Matrix;
const OpsBuilder = @import("OpsBuilder.zig").OpsBuilder;

test "OpsBuilder apply method" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test matrix
    var mat: Matrix(f64) = try .init(arena.allocator(), 2, 3);
    mat.at(0, 0).* = 1.0;
    mat.at(0, 1).* = 4.0;
    mat.at(0, 2).* = 9.0;
    mat.at(1, 0).* = 16.0;
    mat.at(1, 1).* = 25.0;
    mat.at(1, 2).* = 36.0;

    // Test apply with no arguments (sqrt)
    var ops1: OpsBuilder(f64) = try .init(arena.allocator(), mat);
    var result1 = try ops1.apply(std.math.sqrt, .{}).build();
    defer result1.deinit();

    try expectEqual(@as(f64, 1.0), result1.at(0, 0).*);
    try expectEqual(@as(f64, 2.0), result1.at(0, 1).*);
    try expectEqual(@as(f64, 3.0), result1.at(0, 2).*);
    try expectEqual(@as(f64, 4.0), result1.at(1, 0).*);
    try expectEqual(@as(f64, 5.0), result1.at(1, 1).*);
    try expectEqual(@as(f64, 6.0), result1.at(1, 2).*);

    // Test apply with arguments (pow)
    const pow2 = struct {
        fn f(x: f64, n: f64) f64 {
            return std.math.pow(f64, x, n);
        }
    }.f;
    var ops2: OpsBuilder(f64) = try .init(arena.allocator(), result1);
    var result2 = try ops2.apply(pow2, .{@as(f64, 2.0)}).build();
    defer result2.deinit();

    try expectEqual(@as(f64, 1.0), result2.at(0, 0).*);
    try expectEqual(@as(f64, 4.0), result2.at(0, 1).*);
    try expectEqual(@as(f64, 9.0), result2.at(0, 2).*);
    try expectEqual(@as(f64, 16.0), result2.at(1, 0).*);
    try expectEqual(@as(f64, 25.0), result2.at(1, 1).*);
    try expectEqual(@as(f64, 36.0), result2.at(1, 2).*);

    // Test custom function
    const reciprocal = struct {
        fn f(x: f64) f64 {
            return 1.0 / x;
        }
    }.f;

    var ops3: OpsBuilder(f64) = try .init(arena.allocator(), result1);
    var result3 = try ops3.apply(reciprocal, .{}).build();
    defer result3.deinit();

    try expectEqual(@as(f64, 1.0), result3.at(0, 0).*);
    try expectEqual(@as(f64, 0.5), result3.at(0, 1).*);
    try expectEqual(@as(f64, 1.0 / 3.0), result3.at(0, 2).*);
}

test "Matrix statistical operations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test matrix with known values
    const mat: Matrix(f64) = try .init(arena.allocator(), 2, 3);
    mat.at(0, 0).* = 1.0;
    mat.at(0, 1).* = 2.0;
    mat.at(0, 2).* = 3.0;
    mat.at(1, 0).* = 4.0;
    mat.at(1, 1).* = 5.0;
    mat.at(1, 2).* = 6.0;

    // Test sum: 1+2+3+4+5+6 = 21
    try expectEqual(@as(f64, 21.0), mat.sum());

    // Test mean: 21/6 = 3.5
    try expectEqual(@as(f64, 3.5), mat.mean());

    // Test min and max
    try expectEqual(@as(f64, 1.0), mat.min());
    try expectEqual(@as(f64, 6.0), mat.max());

    // Test variance: E[(X - 3.5)²]
    // Values: (1-3.5)² + (2-3.5)² + (3-3.5)² + (4-3.5)² + (5-3.5)² + (6-3.5)²
    //       = 6.25 + 2.25 + 0.25 + 0.25 + 2.25 + 6.25 = 17.5
    // Variance = 17.5 / 6 = 2.916666...
    const variance = mat.variance();
    try std.testing.expect(@abs(variance - 2.916666666666667) < 1e-10);

    // Test standard deviation: sqrt(variance)
    const std_dev = mat.stdDev();
    try std.testing.expect(@abs(std_dev - @sqrt(2.916666666666667)) < 1e-10);
}

test "Matrix norms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test matrix
    const mat: Matrix(f64) = try .init(arena.allocator(), 2, 2);
    mat.at(0, 0).* = 3.0;
    mat.at(0, 1).* = -4.0;
    mat.at(1, 0).* = -1.0;
    mat.at(1, 1).* = 2.0;

    // Test Frobenius norm: sqrt(9 + 16 + 1 + 4) = sqrt(30)
    const frob = mat.frobeniusNorm();
    try std.testing.expect(@abs(frob - @sqrt(30.0)) < 1e-10);

    // Test L1 norm: 3 + 4 + 1 + 2 = 10
    try expectEqual(@as(f64, 10.0), mat.l1Norm());

    // Test max norm: max(3, 4, 1, 2) = 4
    try expectEqual(@as(f64, 4.0), mat.maxNorm());

    // Test trace (diagonal sum): 3 + 2 = 5
    try expectEqual(@as(f64, 5.0), mat.trace());
}

test "OpsBuilder offset and pow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test matrix
    var mat: Matrix(f64) = try .init(arena.allocator(), 2, 2);
    mat.at(0, 0).* = 1.0;
    mat.at(0, 1).* = 2.0;
    mat.at(1, 0).* = 3.0;
    mat.at(1, 1).* = 4.0;

    // Test offset
    var ops1: OpsBuilder(f64) = try .init(arena.allocator(), mat);
    var result1 = try ops1.offset(5.0).build();
    defer result1.deinit();

    try expectEqual(@as(f64, 6.0), result1.at(0, 0).*);
    try expectEqual(@as(f64, 7.0), result1.at(0, 1).*);
    try expectEqual(@as(f64, 8.0), result1.at(1, 0).*);
    try expectEqual(@as(f64, 9.0), result1.at(1, 1).*);

    // Test pow
    var ops2: OpsBuilder(f64) = try .init(arena.allocator(), mat);
    var result2 = try ops2.pow(2.0).build();
    defer result2.deinit();

    try expectEqual(@as(f64, 1.0), result2.at(0, 0).*);
    try expectEqual(@as(f64, 4.0), result2.at(0, 1).*);
    try expectEqual(@as(f64, 9.0), result2.at(1, 0).*);
    try expectEqual(@as(f64, 16.0), result2.at(1, 1).*);
}

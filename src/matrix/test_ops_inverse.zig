const std = @import("std");
const Matrix = @import("Matrix.zig").Matrix;
const OpsBuilder = @import("OpsBuilder.zig").OpsBuilder;

test "OpsBuilder matrix inverse - small matrices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test 2x2 matrix inverse
    var mat2: Matrix(f64) = try .init(arena.allocator(), 2, 2);
    mat2.at(0, 0).* = 4.0;
    mat2.at(0, 1).* = 7.0;
    mat2.at(1, 0).* = 2.0;
    mat2.at(1, 1).* = 6.0;

    var ops2: OpsBuilder(f64) = try .init(arena.allocator(), mat2);
    try ops2.inverse();
    const inv2 = ops2.toOwned();

    // Verify A * A^(-1) = I
    var check2: OpsBuilder(f64) = try .init(arena.allocator(), mat2);
    try check2.dot(inv2);
    const identity2 = check2.toOwned();

    const eps = 1e-10;
    try std.testing.expect(@abs(identity2.at(0, 0).* - 1.0) < eps);
    try std.testing.expect(@abs(identity2.at(0, 1).* - 0.0) < eps);
    try std.testing.expect(@abs(identity2.at(1, 0).* - 0.0) < eps);
    try std.testing.expect(@abs(identity2.at(1, 1).* - 1.0) < eps);

    // Test 3x3 matrix inverse
    var mat3: Matrix(f64) = try .init(arena.allocator(), 3, 3);
    mat3.at(0, 0).* = 1.0;
    mat3.at(0, 1).* = 2.0;
    mat3.at(0, 2).* = 3.0;
    mat3.at(1, 0).* = 0.0;
    mat3.at(1, 1).* = 1.0;
    mat3.at(1, 2).* = 4.0;
    mat3.at(2, 0).* = 5.0;
    mat3.at(2, 1).* = 6.0;
    mat3.at(2, 2).* = 0.0;

    var ops3: OpsBuilder(f64) = try .init(arena.allocator(), mat3);
    try ops3.inverse();
    const inv3 = ops3.toOwned();

    // Verify A * A^(-1) = I
    var check3: OpsBuilder(f64) = try .init(arena.allocator(), mat3);
    try check3.dot(inv3);
    const identity3 = check3.toOwned();

    for (0..3) |i| {
        for (0..3) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            try std.testing.expect(@abs(identity3.at(i, j).* - expected) < eps);
        }
    }
}

test "OpsBuilder matrix inverse - large matrices using Gauss-Jordan" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test 4x4 matrix inverse
    var mat4: Matrix(f64) = try .init(arena.allocator(), 4, 4);
    // Create a well-conditioned matrix
    mat4.at(0, 0).* = 5.0;
    mat4.at(0, 1).* = 1.0;
    mat4.at(0, 2).* = 0.0;
    mat4.at(0, 3).* = 2.0;
    mat4.at(1, 0).* = 1.0;
    mat4.at(1, 1).* = 4.0;
    mat4.at(1, 2).* = 1.0;
    mat4.at(1, 3).* = 1.0;
    mat4.at(2, 0).* = 0.0;
    mat4.at(2, 1).* = 1.0;
    mat4.at(2, 2).* = 3.0;
    mat4.at(2, 3).* = 0.0;
    mat4.at(3, 0).* = 2.0;
    mat4.at(3, 1).* = 1.0;
    mat4.at(3, 2).* = 0.0;
    mat4.at(3, 3).* = 4.0;

    var ops4: OpsBuilder(f64) = try .init(arena.allocator(), mat4);
    try ops4.inverse();
    const inv4 = ops4.toOwned();

    // Verify A * A^(-1) = I
    var check4: OpsBuilder(f64) = try .init(arena.allocator(), mat4);
    try check4.dot(inv4);
    const identity4 = check4.toOwned();

    const eps = 1e-10;
    for (0..4) |i| {
        for (0..4) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            try std.testing.expect(@abs(identity4.at(i, j).* - expected) < eps);
        }
    }

    // Test 5x5 matrix inverse
    var mat5 = try Matrix(f64).init(arena.allocator(), 5, 5);
    // Create a diagonally dominant matrix (well-conditioned)
    for (0..5) |i| {
        for (0..5) |j| {
            if (i == j) {
                mat5.at(i, j).* = 10.0;
            } else {
                mat5.at(i, j).* = @as(f64, @floatFromInt(i + j)) * 0.5;
            }
        }
    }

    var ops5: OpsBuilder(f64) = try .init(arena.allocator(), mat5);
    try ops5.inverse();
    const inv5 = ops5.toOwned();

    // Verify A * A^(-1) = I
    var check5: OpsBuilder(f64) = try .init(arena.allocator(), mat5);
    try check5.dot(inv5);
    const identity5 = check5.toOwned();

    for (0..5) |i| {
        for (0..5) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            try std.testing.expect(@abs(identity5.at(i, j).* - expected) < eps);
        }
    }
}

test "OpsBuilder matrix inverse - singular matrix error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test singular 2x2 matrix
    var sing2: Matrix(f64) = try .init(arena.allocator(), 2, 2);
    sing2.at(0, 0).* = 1.0;
    sing2.at(0, 1).* = 2.0;
    sing2.at(1, 0).* = 2.0;
    sing2.at(1, 1).* = 4.0; // Second row is multiple of first

    var ops_sing2: OpsBuilder(f64) = try .init(arena.allocator(), sing2);
    try std.testing.expectError(error.SingularMatrix, ops_sing2.inverse());

    // Test singular 4x4 matrix (uses Gauss-Jordan)
    var sing4: Matrix(f64) = try .init(arena.allocator(), 4, 4);
    // Make third row a linear combination of first two
    sing4.at(0, 0).* = 1.0;
    sing4.at(0, 1).* = 2.0;
    sing4.at(0, 2).* = 3.0;
    sing4.at(0, 3).* = 4.0;
    sing4.at(1, 0).* = 5.0;
    sing4.at(1, 1).* = 6.0;
    sing4.at(1, 2).* = 7.0;
    sing4.at(1, 3).* = 8.0;
    sing4.at(2, 0).* = 6.0; // row2 = row0 + row1
    sing4.at(2, 1).* = 8.0;
    sing4.at(2, 2).* = 10.0;
    sing4.at(2, 3).* = 12.0;
    sing4.at(3, 0).* = 9.0;
    sing4.at(3, 1).* = 10.0;
    sing4.at(3, 2).* = 11.0;
    sing4.at(3, 3).* = 12.0;

    var ops_sing4: OpsBuilder(f64) = try .init(arena.allocator(), sing4);
    defer ops_sing4.deinit();
    try std.testing.expectError(error.SingularMatrix, ops_sing4.inverse());
}

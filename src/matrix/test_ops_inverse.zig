const std = @import("std");
const Matrix = @import("Matrix.zig").Matrix;

test "Matrix inverse - small matrices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test 2x2 matrix inverse
    var mat2: Matrix(f64) = try .init(arena.allocator(), 2, 2);
    mat2.at(0, 0).* = 4.0;
    mat2.at(0, 1).* = 7.0;
    mat2.at(1, 0).* = 2.0;
    mat2.at(1, 1).* = 6.0;

    const inv2 = try mat2.inverse().eval();

    // Verify A * A^(-1) = I
    const identity2 = try mat2.dot(inv2).eval();

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

    const inv3 = try mat3.inverse().eval();

    // Verify A * A^(-1) = I
    const identity3 = try mat3.dot(inv3).eval();

    for (0..3) |i| {
        for (0..3) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            try std.testing.expect(@abs(identity3.at(i, j).* - expected) < eps);
        }
    }
}

test "Matrix inverse - large matrices using Gauss-Jordan" {
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

    const inv4 = try mat4.inverse().eval();

    // Verify A * A^(-1) = I
    const identity4 = try mat4.dot(inv4).eval();

    const eps = 1e-10;
    for (0..4) |i| {
        for (0..4) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            try std.testing.expect(@abs(identity4.at(i, j).* - expected) < eps);
        }
    }

    // Test 5x5 matrix inverse
    var mat5: Matrix(f64) = try .init(arena.allocator(), 5, 5);
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

    const inv5 = try mat5.inverse().eval();

    // Verify A * A^(-1) = I
    const identity5 = try mat5.dot(inv5).eval();

    for (0..5) |i| {
        for (0..5) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            try std.testing.expect(@abs(identity5.at(i, j).* - expected) < eps);
        }
    }
}

test "Matrix inverse - singular matrix error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test singular 2x2 matrix
    var sing2: Matrix(f64) = try .init(arena.allocator(), 2, 2);
    sing2.at(0, 0).* = 1.0;
    sing2.at(0, 1).* = 2.0;
    sing2.at(1, 0).* = 2.0;
    sing2.at(1, 1).* = 4.0; // Second row is multiple of first

    try std.testing.expectError(error.Singular, sing2.inverse().eval());

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

    try std.testing.expectError(error.Singular, sing4.inverse().eval());
}

test "Matrix pseudo-inverse handles tall and wide matrices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tall: Matrix(f64) = try .init(allocator, 4, 3);
    defer tall.deinit();
    tall.at(0, 0).* = 1.0;
    tall.at(0, 1).* = 2.0;
    tall.at(0, 2).* = -1.0;
    tall.at(1, 0).* = 0.0;
    tall.at(1, 1).* = 3.0;
    tall.at(1, 2).* = 4.0;
    tall.at(2, 0).* = -2.0;
    tall.at(2, 1).* = 1.0;
    tall.at(2, 2).* = 0.5;
    tall.at(3, 0).* = 5.0;
    tall.at(3, 1).* = -1.0;
    tall.at(3, 2).* = 2.0;

    var tall_rank: u32 = undefined;
    var tall_pinv = try tall.pseudoInverse(.{ .effective_rank = &tall_rank }).eval();
    defer tall_pinv.deinit();
    var tall_recon = try tall.dot(tall_pinv).dot(tall).eval();
    defer tall_recon.deinit();
    var tall_pinv_recon = try tall_pinv.dot(tall).dot(tall_pinv).eval();
    defer tall_pinv_recon.deinit();

    const tol = 1e-9;
    try std.testing.expect(tall_rank == 3);
    for (0..tall.rows) |r| {
        for (0..tall.cols) |c| {
            try std.testing.expectApproxEqAbs(tall.at(r, c).*, tall_recon.at(r, c).*, tol);
        }
    }
    for (0..tall_pinv.rows) |r| {
        for (0..tall_pinv.cols) |c| {
            try std.testing.expectApproxEqAbs(tall_pinv.at(r, c).*, tall_pinv_recon.at(r, c).*, tol);
        }
    }

    var wide: Matrix(f64) = try .init(allocator, 3, 5);
    defer wide.deinit();
    wide.at(0, 0).* = 1.0;
    wide.at(0, 1).* = -2.0;
    wide.at(0, 2).* = 3.0;
    wide.at(0, 3).* = 0.5;
    wide.at(0, 4).* = -1.5;
    wide.at(1, 0).* = 2.0;
    wide.at(1, 1).* = 0.0;
    wide.at(1, 2).* = -4.0;
    wide.at(1, 3).* = 1.0;
    wide.at(1, 4).* = 2.5;
    wide.at(2, 0).* = -3.0;
    wide.at(2, 1).* = 1.0;
    wide.at(2, 2).* = 2.0;
    wide.at(2, 3).* = -2.0;
    wide.at(2, 4).* = 0.25;

    var wide_rank: u32 = undefined;
    var wide_pinv = try wide.pseudoInverse(.{ .effective_rank = &wide_rank }).eval();
    defer wide_pinv.deinit();
    var wide_recon = try wide.dot(wide_pinv).dot(wide).eval();
    defer wide_recon.deinit();
    var wide_pinv_recon = try wide_pinv.dot(wide).dot(wide_pinv).eval();
    defer wide_pinv_recon.deinit();

    try std.testing.expectEqual(wide.cols, wide_pinv.rows);
    try std.testing.expectEqual(wide.rows, wide_pinv.cols);
    try std.testing.expect(wide_rank == 3);

    for (0..wide.rows) |r| {
        for (0..wide.cols) |c| {
            try std.testing.expectApproxEqAbs(wide.at(r, c).*, wide_recon.at(r, c).*, tol);
        }
    }
    for (0..wide_pinv.rows) |r| {
        for (0..wide_pinv.cols) |c| {
            try std.testing.expectApproxEqAbs(wide_pinv.at(r, c).*, wide_pinv_recon.at(r, c).*, tol);
        }
    }
}

test "Matrix pseudo-inverse zero matrix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zero: Matrix(f64) = try .initAll(allocator, 4, 2, 0);
    defer zero.deinit();

    var rank: u32 = 1234;
    var pinv = try zero.pseudoInverse(.{ .effective_rank = &rank }).eval();
    defer pinv.deinit();

    try std.testing.expectEqual(@as(u32, 2), pinv.rows);
    try std.testing.expectEqual(@as(u32, 4), pinv.cols);
    for (0..pinv.items.len) |i| {
        try std.testing.expectEqual(@as(f64, 0), pinv.items[i]);
    }
    try std.testing.expectEqual(@as(u32, 0), rank);
}

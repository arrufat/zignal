const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Matrix = @import("Matrix.zig").Matrix;
const OpsBuilder = @import("OpsBuilder.zig").OpsBuilder;

test "OpsBuilder LU decomposition" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test 3x3 matrix
    var mat: Matrix(f64) = try .init(arena.allocator(), 3, 3);
    mat.at(0, 0).* = 2.0;
    mat.at(0, 1).* = 1.0;
    mat.at(0, 2).* = 1.0;
    mat.at(1, 0).* = 4.0;
    mat.at(1, 1).* = 3.0;
    mat.at(1, 2).* = 3.0;
    mat.at(2, 0).* = 8.0;
    mat.at(2, 1).* = 7.0;
    mat.at(2, 2).* = 9.0;

    var ops: OpsBuilder(f64) = try .init(arena.allocator(), mat);
    defer ops.deinit();

    // Compute LU decomposition
    var lu_result = try ops.lu();
    defer lu_result.deinit();

    // Verify dimensions
    try expectEqual(@as(usize, 3), lu_result.l.rows);
    try expectEqual(@as(usize, 3), lu_result.l.cols);
    try expectEqual(@as(usize, 3), lu_result.u.rows);
    try expectEqual(@as(usize, 3), lu_result.u.cols);

    // Verify L is lower triangular with 1s on diagonal
    try expectEqual(@as(f64, 1.0), lu_result.l.at(0, 0).*);
    try expectEqual(@as(f64, 1.0), lu_result.l.at(1, 1).*);
    try expectEqual(@as(f64, 1.0), lu_result.l.at(2, 2).*);
    try expectEqual(@as(f64, 0.0), lu_result.l.at(0, 1).*);
    try expectEqual(@as(f64, 0.0), lu_result.l.at(0, 2).*);
    try expectEqual(@as(f64, 0.0), lu_result.l.at(1, 2).*);

    // Verify U is upper triangular
    try expectEqual(@as(f64, 0.0), lu_result.u.at(1, 0).*);
    try expectEqual(@as(f64, 0.0), lu_result.u.at(2, 0).*);
    try expectEqual(@as(f64, 0.0), lu_result.u.at(2, 1).*);

    // Reconstruct PA = LU
    var pa: Matrix(f64) = try .init(arena.allocator(), 3, 3);
    defer pa.deinit();

    // Apply permutation: PA[i,j] = A[p[i],j]
    for (0..3) |i| {
        for (0..3) |j| {
            pa.at(i, j).* = mat.at(@intFromFloat(lu_result.p.items[i]), j).*;
        }
    }

    // Compute L * U
    var lu_product: Matrix(f64) = try .init(arena.allocator(), 3, 3);
    defer lu_product.deinit();
    @memset(lu_product.items, 0);

    for (0..3) |i| {
        for (0..3) |j| {
            for (0..3) |k| {
                lu_product.at(i, j).* += lu_result.l.at(i, k).* * lu_result.u.at(k, j).*;
            }
        }
    }

    // Verify PA = LU (within numerical tolerance)
    const eps = 1e-10;
    for (0..3) |i| {
        for (0..3) |j| {
            const diff = @abs(pa.at(i, j).* - lu_product.at(i, j).*);
            try std.testing.expect(diff < eps);
        }
    }
}

test "OpsBuilder QR decomposition" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test 3x3 matrix
    var mat: Matrix(f64) = try .init(arena.allocator(), 3, 3);
    mat.at(0, 0).* = 12.0;
    mat.at(0, 1).* = -51.0;
    mat.at(0, 2).* = 4.0;
    mat.at(1, 0).* = 6.0;
    mat.at(1, 1).* = 167.0;
    mat.at(1, 2).* = -68.0;
    mat.at(2, 0).* = -4.0;
    mat.at(2, 1).* = 24.0;
    mat.at(2, 2).* = -41.0;

    var ops: OpsBuilder(f64) = try .init(arena.allocator(), mat);
    defer ops.deinit();

    // Compute QR decomposition
    var qr_result = try ops.qr();
    defer qr_result.deinit();

    // Verify dimensions
    try expectEqual(@as(usize, 3), qr_result.q.rows);
    try expectEqual(@as(usize, 3), qr_result.q.cols);
    try expectEqual(@as(usize, 3), qr_result.r.rows);
    try expectEqual(@as(usize, 3), qr_result.r.cols);

    // Verify R is upper triangular
    try expectEqual(@as(f64, 0.0), qr_result.r.at(1, 0).*);
    try expectEqual(@as(f64, 0.0), qr_result.r.at(2, 0).*);
    try expectEqual(@as(f64, 0.0), qr_result.r.at(2, 1).*);

    // Verify Q is orthogonal: Q^T * Q should be identity
    var qtq: Matrix(f64) = try .init(arena.allocator(), 3, 3);
    defer qtq.deinit();
    @memset(qtq.items, 0);

    for (0..3) |i| {
        for (0..3) |j| {
            for (0..3) |k| {
                qtq.at(i, j).* += qr_result.q.at(k, i).* * qr_result.q.at(k, j).*;
            }
        }
    }

    // Check that Q^T * Q is approximately identity
    const eps = 1e-10;
    for (0..3) |i| {
        for (0..3) |j| {
            const expected: f64 = if (i == j) 1.0 else 0.0;
            const diff = @abs(qtq.at(i, j).* - expected);
            try std.testing.expect(diff < eps);
        }
    }

    // Verify A = Q * R
    var qr_product = try Matrix(f64).init(arena.allocator(), 3, 3);
    defer qr_product.deinit();
    @memset(qr_product.items, 0);

    for (0..3) |i| {
        for (0..3) |j| {
            for (0..3) |k| {
                qr_product.at(i, j).* += qr_result.q.at(i, k).* * qr_result.r.at(k, j).*;
            }
        }
    }

    // Verify A = QR (within numerical tolerance)
    for (0..3) |i| {
        for (0..3) |j| {
            const diff = @abs(mat.at(i, j).* - qr_product.at(i, j).*);
            try std.testing.expect(diff < eps);
        }
    }

    // Test rectangular matrix (4x3) with linearly independent columns
    var rect_mat = try Matrix(f64).init(arena.allocator(), 4, 3);
    rect_mat.at(0, 0).* = 1.0;
    rect_mat.at(0, 1).* = 0.0;
    rect_mat.at(0, 2).* = 0.0;
    rect_mat.at(1, 0).* = 1.0;
    rect_mat.at(1, 1).* = 1.0;
    rect_mat.at(1, 2).* = 0.0;
    rect_mat.at(2, 0).* = 1.0;
    rect_mat.at(2, 1).* = 1.0;
    rect_mat.at(2, 2).* = 1.0;
    rect_mat.at(3, 0).* = 1.0;
    rect_mat.at(3, 1).* = 1.0;
    rect_mat.at(3, 2).* = 2.0;

    var rect_ops = try OpsBuilder(f64).init(arena.allocator(), rect_mat);
    defer rect_ops.deinit();

    var rect_qr = try rect_ops.qr();
    defer rect_qr.deinit();

    // Verify dimensions for rectangular matrix
    try expectEqual(@as(usize, 4), rect_qr.q.rows);
    try expectEqual(@as(usize, 3), rect_qr.q.cols);
    try expectEqual(@as(usize, 3), rect_qr.r.rows);
    try expectEqual(@as(usize, 3), rect_qr.r.cols);

    // Verify A = Q * R for rectangular matrix
    var rect_product = try Matrix(f64).init(arena.allocator(), 4, 3);
    defer rect_product.deinit();
    @memset(rect_product.items, 0);

    for (0..4) |i| {
        for (0..3) |j| {
            for (0..3) |k| {
                rect_product.at(i, j).* += rect_qr.q.at(i, k).* * rect_qr.r.at(k, j).*;
            }
        }
    }

    for (0..4) |i| {
        for (0..3) |j| {
            const diff = @abs(rect_mat.at(i, j).* - rect_product.at(i, j).*);
            try std.testing.expect(diff < eps);
        }
    }
}

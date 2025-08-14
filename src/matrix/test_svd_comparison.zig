const std = @import("std");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectApproxEqRel = testing.expectApproxEqRel;
const expectApproxEqAbs = testing.expectApproxEqAbs;

const Matrix = @import("Matrix.zig").Matrix;
const SMatrix = @import("SMatrix.zig").SMatrix;
const svd_dynamic = @import("svd.zig").svd;
const svd_static = @import("svd_static.zig").svd;

test "SVD comparison: basic 5x4 matrix" {
    const allocator = testing.allocator;
    const m: usize = 5;
    const n: usize = 4;

    // Same matrix used in both SVD test files
    const test_matrix = [_][4]f64{
        .{ 1, 0, 0, 0 },
        .{ 0, 0, 0, 2 },
        .{ 0, 3, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 2, 0, 0, 0 },
    };

    // Static SVD
    const a_static: SMatrix(f64, m, n) = .init(test_matrix);
    const static_result = svd_static(f64, m, n, a_static, .{ .with_u = true, .with_v = true, .mode = .full_u });

    // Dynamic SVD
    var a_dynamic = try Matrix(f64).init(allocator, m, n);
    defer a_dynamic.deinit();
    for (0..m) |i| {
        for (0..n) |j| {
            a_dynamic.at(i, j).* = test_matrix[i][j];
        }
    }
    var dynamic_result = try svd_dynamic(f64, allocator, a_dynamic, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer dynamic_result.deinit();

    // Compare convergence
    try expectEqual(static_result.converged, dynamic_result.converged);
    try expectEqual(@as(usize, 0), static_result.converged);

    // Compare singular values - should be identical
    for (0..n) |i| {
        const static_s = static_result.s.at(i, 0).*;
        const dynamic_s = dynamic_result.s.at(i, 0).*;
        try expectApproxEqRel(static_s, dynamic_s, 1e-10);
    }

    // Compare U matrices (accounting for potential sign differences)
    for (0..m) |i| {
        for (0..m) |j| {
            const static_u = static_result.u.at(i, j).*;
            const dynamic_u = dynamic_result.u.at(i, j).*;
            // Check if values are close (same sign) or negatives of each other (opposite sign)
            const same_sign = @abs(static_u - dynamic_u) < 1e-10;
            const opposite_sign = @abs(static_u + dynamic_u) < 1e-10;
            try testing.expect(same_sign or opposite_sign);
        }
    }

    // Compare V matrices (accounting for potential sign differences)
    for (0..n) |i| {
        for (0..n) |j| {
            const static_v = static_result.v.at(i, j).*;
            const dynamic_v = dynamic_result.v.at(i, j).*;
            const same_sign = @abs(static_v - dynamic_v) < 1e-10;
            const opposite_sign = @abs(static_v + dynamic_v) < 1e-10;
            try testing.expect(same_sign or opposite_sign);
        }
    }
}

test "SVD comparison: identity matrix" {
    const allocator = testing.allocator;
    const n: usize = 3;

    // Static SVD
    const a_static: SMatrix(f64, n, n) = .identity();
    const static_result = svd_static(f64, n, n, a_static, .{ .with_u = true, .with_v = true, .mode = .full_u });

    // Dynamic SVD
    var a_dynamic = try Matrix(f64).init(allocator, n, n);
    defer a_dynamic.deinit();
    for (0..n) |i| {
        for (0..n) |j| {
            a_dynamic.at(i, j).* = if (i == j) 1.0 else 0.0;
        }
    }
    var dynamic_result = try svd_dynamic(f64, allocator, a_dynamic, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer dynamic_result.deinit();

    // All singular values should be 1.0 for identity matrix
    for (0..n) |i| {
        const static_s = static_result.s.at(i, 0).*;
        const dynamic_s = dynamic_result.s.at(i, 0).*;
        try expectApproxEqAbs(1.0, static_s, 1e-10);
        try expectApproxEqAbs(1.0, dynamic_s, 1e-10);
        try expectApproxEqRel(static_s, dynamic_s, 1e-10);
    }
}

test "SVD comparison: singular matrix" {
    const allocator = testing.allocator;
    const m: usize = 3;
    const n: usize = 3;

    // Rank-1 matrix
    const test_matrix = [_][3]f64{
        .{ 1, 2, 3 },
        .{ 2, 4, 6 },
        .{ 1, 2, 3 },
    };

    // Static SVD
    const a_static: SMatrix(f64, m, n) = .init(test_matrix);
    const static_result = svd_static(f64, m, n, a_static, .{ .with_u = true, .with_v = true, .mode = .full_u });

    // Dynamic SVD
    var a_dynamic = try Matrix(f64).init(allocator, m, n);
    defer a_dynamic.deinit();
    for (0..m) |i| {
        for (0..n) |j| {
            a_dynamic.at(i, j).* = test_matrix[i][j];
        }
    }
    var dynamic_result = try svd_dynamic(f64, allocator, a_dynamic, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer dynamic_result.deinit();

    // Compare singular values
    for (0..n) |i| {
        const static_s = static_result.s.at(i, 0).*;
        const dynamic_s = dynamic_result.s.at(i, 0).*;
        try expectApproxEqRel(static_s, dynamic_s, 1e-10);
    }

    // Count near-zero singular values (should be 2 for rank-1 matrix)
    const tol = @sqrt(std.math.floatEps(f64));
    var static_zero_count: usize = 0;
    var dynamic_zero_count: usize = 0;

    for (0..n) |i| {
        if (static_result.s.at(i, 0).* < tol) {
            static_zero_count += 1;
        }
        if (dynamic_result.s.at(i, 0).* < tol) {
            dynamic_zero_count += 1;
        }
    }

    try expectEqual(static_zero_count, dynamic_zero_count);
    try expectEqual(@as(usize, 2), static_zero_count);
}

test "SVD comparison: skinny_u mode" {
    const allocator = testing.allocator;
    const m: usize = 4;
    const n: usize = 3;

    const test_matrix = [_][3]f64{
        .{ 2, 1, 0 },
        .{ 1, 2, 1 },
        .{ 0, 1, 2 },
        .{ 1, 0, 1 },
    };

    // Static SVD with skinny_u
    const a_static: SMatrix(f64, m, n) = .init(test_matrix);
    const static_result = svd_static(f64, m, n, a_static, .{ .with_u = true, .with_v = false, .mode = .skinny_u });

    // Dynamic SVD with skinny_u
    var a_dynamic = try Matrix(f64).init(allocator, m, n);
    defer a_dynamic.deinit();
    for (0..m) |i| {
        for (0..n) |j| {
            a_dynamic.at(i, j).* = test_matrix[i][j];
        }
    }
    var dynamic_result = try svd_dynamic(f64, allocator, a_dynamic, .{ .with_u = true, .with_v = false, .mode = .skinny_u });
    defer dynamic_result.deinit();

    // Check dimensions
    try expectEqual(static_result.u.rows, dynamic_result.u.rows);
    try expectEqual(static_result.u.cols, dynamic_result.u.cols);
    try expectEqual(@as(usize, m), static_result.u.rows);
    try expectEqual(@as(usize, n), static_result.u.cols); // skinny mode

    // Compare singular values
    for (0..n) |i| {
        const static_s = static_result.s.at(i, 0).*;
        const dynamic_s = dynamic_result.s.at(i, 0).*;
        try expectApproxEqRel(static_s, dynamic_s, 1e-10);
    }
}

test "SVD comparison: rectangular matrix" {
    const allocator = testing.allocator;
    const m: usize = 6;
    const n: usize = 3;

    const test_matrix = [_][3]f64{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
        .{ 7.0, 8.0, 9.0 },
        .{ 10.0, 11.0, 12.0 },
        .{ 13.0, 14.0, 15.0 },
        .{ 16.0, 17.0, 18.0 },
    };

    // Static SVD
    const a_static: SMatrix(f64, m, n) = .init(test_matrix);
    const static_result = svd_static(f64, m, n, a_static, .{ .with_u = true, .with_v = true, .mode = .full_u });

    // Dynamic SVD
    var a_dynamic = try Matrix(f64).init(allocator, m, n);
    defer a_dynamic.deinit();
    for (0..m) |i| {
        for (0..n) |j| {
            a_dynamic.at(i, j).* = test_matrix[i][j];
        }
    }
    var dynamic_result = try svd_dynamic(f64, allocator, a_dynamic, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer dynamic_result.deinit();

    // Compare convergence
    try expectEqual(static_result.converged, dynamic_result.converged);

    // Compare singular values
    for (0..n) |i| {
        const static_s = static_result.s.at(i, 0).*;
        const dynamic_s = dynamic_result.s.at(i, 0).*;
        // Use relative comparison for non-zero values
        if (static_s > 1e-10) {
            try expectApproxEqRel(static_s, dynamic_s, 1e-10);
        } else {
            try expectApproxEqAbs(static_s, dynamic_s, 1e-10);
        }
    }

    // Verify singular values are in descending order for both
    for (1..n) |i| {
        try testing.expect(static_result.s.at(i - 1, 0).* >= static_result.s.at(i, 0).*);
        try testing.expect(dynamic_result.s.at(i - 1, 0).* >= dynamic_result.s.at(i, 0).*);
    }
}

test "SVD comparison: reconstruction accuracy" {
    const allocator = testing.allocator;
    const m: usize = 4;
    const n: usize = 3;

    const test_matrix = [_][3]f64{
        .{ 3.5, 1.2, 0.8 },
        .{ 1.1, 4.7, 2.3 },
        .{ 0.9, 2.1, 5.6 },
        .{ 2.4, 0.7, 3.1 },
    };

    // Static SVD
    const a_static: SMatrix(f64, m, n) = .init(test_matrix);
    const static_result = svd_static(f64, m, n, a_static, .{ .with_u = true, .with_v = true, .mode = .skinny_u });

    // Dynamic SVD
    var a_dynamic = try Matrix(f64).init(allocator, m, n);
    defer a_dynamic.deinit();
    for (0..m) |i| {
        for (0..n) |j| {
            a_dynamic.at(i, j).* = test_matrix[i][j];
        }
    }
    var dynamic_result = try svd_dynamic(f64, allocator, a_dynamic, .{ .with_u = true, .with_v = true, .mode = .skinny_u });
    defer dynamic_result.deinit();

    // Reconstruct A = U * S * V^T for both implementations
    // and verify they give the same reconstruction
    for (0..m) |i| {
        for (0..n) |j| {
            var static_reconstructed: f64 = 0;
            var dynamic_reconstructed: f64 = 0;

            for (0..n) |k| {
                // Static reconstruction
                var static_sum: f64 = 0;
                for (0..n) |l| {
                    const s_val = if (l == k) static_result.s.at(l, 0).* else 0;
                    static_sum += s_val * static_result.v.at(j, l).*;
                }
                static_reconstructed += static_result.u.at(i, k).* * static_sum;

                // Dynamic reconstruction
                var dynamic_sum: f64 = 0;
                for (0..n) |l| {
                    const s_val = if (l == k) dynamic_result.s.at(l, 0).* else 0;
                    dynamic_sum += s_val * dynamic_result.v.at(j, l).*;
                }
                dynamic_reconstructed += dynamic_result.u.at(i, k).* * dynamic_sum;
            }

            // Both should reconstruct to the original matrix
            try expectApproxEqAbs(test_matrix[i][j], static_reconstructed, 1e-10);
            try expectApproxEqAbs(test_matrix[i][j], dynamic_reconstructed, 1e-10);

            // And they should be equal to each other
            try expectApproxEqRel(static_reconstructed, dynamic_reconstructed, 1e-10);
        }
    }
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Matrix = @import("Matrix.zig").Matrix;

test "Matrix gram and covariance matrices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Create test matrix (3 samples × 2 features)
    var data: Matrix(f64) = try .init(arena.allocator(), 3, 2);
    data.at(0, 0).* = 1.0;
    data.at(0, 1).* = 2.0;
    data.at(1, 0).* = 3.0;
    data.at(1, 1).* = 4.0;
    data.at(2, 0).* = 5.0;
    data.at(2, 1).* = 6.0;

    // Test Gram matrix (X * X^T) - should be 3×3
    const gram_result = try data.gram().eval();

    try expectEqual(@as(usize, 3), gram_result.rows);
    try expectEqual(@as(usize, 3), gram_result.cols);

    // Verify gram matrix values
    // First row: [1*1+2*2, 1*3+2*4, 1*5+2*6] = [5, 11, 17]
    try expectEqual(@as(f64, 5.0), gram_result.at(0, 0).*);
    try expectEqual(@as(f64, 11.0), gram_result.at(0, 1).*);
    try expectEqual(@as(f64, 17.0), gram_result.at(0, 2).*);

    // Test Covariance matrix (X^T * X) - should be 2×2
    const cov_result = try data.covariance().eval();

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

test "Matrix GEMM operations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Create test matrices
    var a: Matrix(f32) = try .init(arena.allocator(), 2, 3);
    a.at(0, 0).* = 1.0;
    a.at(0, 1).* = 2.0;
    a.at(0, 2).* = 3.0;
    a.at(1, 0).* = 4.0;
    a.at(1, 1).* = 5.0;
    a.at(1, 2).* = 6.0;

    var b: Matrix(f32) = try .init(arena.allocator(), 3, 2);
    b.at(0, 0).* = 7.0;
    b.at(0, 1).* = 8.0;
    b.at(1, 0).* = 9.0;
    b.at(1, 1).* = 10.0;
    b.at(2, 0).* = 11.0;
    b.at(2, 1).* = 12.0;

    var c: Matrix(f32) = try .init(arena.allocator(), 2, 2);
    c.at(0, 0).* = 1.0;
    c.at(0, 1).* = 1.0;
    c.at(1, 0).* = 1.0;
    c.at(1, 1).* = 1.0;

    // Test basic matrix multiplication: A * B using dot() method
    const dot_result = try a.dot(b).eval();

    try expectEqual(@as(f32, 58.0), dot_result.at(0, 0).*); // 1*7 + 2*9 + 3*11
    try expectEqual(@as(f32, 64.0), dot_result.at(0, 1).*); // 1*8 + 2*10 + 3*12
    try expectEqual(@as(f32, 139.0), dot_result.at(1, 0).*); // 4*7 + 5*9 + 6*11
    try expectEqual(@as(f32, 154.0), dot_result.at(1, 1).*); // 4*8 + 5*10 + 6*12

    // Test basic matrix multiplication: A * B using gemm() method
    const result1 = try a.gemm(false, b, false, 1.0, 0.0, null).eval();

    try expectEqual(@as(f32, 58.0), result1.at(0, 0).*); // 1*7 + 2*9 + 3*11
    try expectEqual(@as(f32, 64.0), result1.at(0, 1).*); // 1*8 + 2*10 + 3*12
    try expectEqual(@as(f32, 139.0), result1.at(1, 0).*); // 4*7 + 5*9 + 6*11
    try expectEqual(@as(f32, 154.0), result1.at(1, 1).*); // 4*8 + 5*10 + 6*12

    // Test scaled multiplication: 2 * A * B
    const result2 = try a.gemm(false, b, false, 2.0, 0.0, null).eval();

    try expectEqual(@as(f32, 116.0), result2.at(0, 0).*); // 2 * 58
    try expectEqual(@as(f32, 128.0), result2.at(0, 1).*); // 2 * 64

    // Test accumulation: A * B + C
    const result3 = try a.gemm(false, b, false, 1.0, 1.0, c).eval();

    try expectEqual(@as(f32, 59.0), result3.at(0, 0).*); // 58 + 1
    try expectEqual(@as(f32, 65.0), result3.at(0, 1).*); // 64 + 1

    // Test Gram matrix using GEMM: A * A^T
    const gram = try a.gemm(false, a, true, 1.0, 0.0, null).eval();

    try expectEqual(@as(usize, 2), gram.rows);
    try expectEqual(@as(usize, 2), gram.cols);
    try expectEqual(@as(f32, 14.0), gram.at(0, 0).*); // 1*1 + 2*2 + 3*3
    try expectEqual(@as(f32, 32.0), gram.at(0, 1).*); // 1*4 + 2*5 + 3*6

    // Test covariance using GEMM: A^T * A
    const cov = try a.gemm(true, a, false, 1.0, 0.0, null).eval();

    try expectEqual(@as(usize, 3), cov.rows);
    try expectEqual(@as(usize, 3), cov.cols);
    try expectEqual(@as(f32, 17.0), cov.at(0, 0).*); // 1*1 + 4*4
    try expectEqual(@as(f32, 22.0), cov.at(0, 1).*); // 1*2 + 4*5
}

test "Matrix SIMD case 2: A^T * B with same matrix (covariance)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Create a test matrix
    var data: Matrix(f32) = try .init(arena.allocator(), 4, 3);
    data.at(0, 0).* = 1.0;
    data.at(0, 1).* = 2.0;
    data.at(0, 2).* = 3.0;
    data.at(1, 0).* = 4.0;
    data.at(1, 1).* = 5.0;
    data.at(1, 2).* = 6.0;
    data.at(2, 0).* = 7.0;
    data.at(2, 1).* = 8.0;
    data.at(2, 2).* = 9.0;
    data.at(3, 0).* = 10.0;
    data.at(3, 1).* = 11.0;
    data.at(3, 2).* = 12.0;

    // Test covariance using Matrix (should use SIMD)
    const simd_result = try data.covariance().eval();

    // Compute expected result manually
    var expected: Matrix(f32) = try .init(arena.allocator(), 3, 3);
    @memset(expected.items, 0);

    // Compute A^T * A manually
    for (0..3) |i| {
        for (0..3) |j| {
            var sum: f32 = 0;
            for (0..4) |k| {
                sum += data.at(k, i).* * data.at(k, j).*;
            }
            expected.at(i, j).* = sum;
        }
    }

    // Verify dimensions
    try expectEqual(@as(usize, 3), simd_result.rows);
    try expectEqual(@as(usize, 3), simd_result.cols);

    // Verify values match
    for (0..3) |i| {
        for (0..3) |j| {
            const diff = @abs(simd_result.at(i, j).* - expected.at(i, j).*);
            try std.testing.expect(diff < 1e-5);
        }
    }

    // Also test direct GEMM call with same matrix
    const direct_result = try data.gemm(true, data, false, 1.0, 0.0, null).eval();

    // Verify direct GEMM gives same result
    for (0..3) |i| {
        for (0..3) |j| {
            const diff = @abs(direct_result.at(i, j).* - expected.at(i, j).*);
            try std.testing.expect(diff < 1e-5);
        }
    }
}

test "Matrix GEMM all transpose cases with same matrix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Create test matrix A (3x2 for non-square tests)
    var a: Matrix(f32) = try .init(arena.allocator(), 3, 2);
    a.at(0, 0).* = 1.0;
    a.at(0, 1).* = 2.0;
    a.at(1, 0).* = 3.0;
    a.at(1, 1).* = 4.0;
    a.at(2, 0).* = 5.0;
    a.at(2, 1).* = 6.0;

    // Create square matrix for Case 1 and Case 4
    var square_a: Matrix(f32) = try .init(arena.allocator(), 2, 2);
    square_a.at(0, 0).* = 1.0;
    square_a.at(0, 1).* = 2.0;
    square_a.at(1, 0).* = 3.0;
    square_a.at(1, 1).* = 4.0;

    // Case 1: A * A (SIMD same-matrix handling)
    const result1 = try square_a.gemm(false, square_a, false, 1.0, 0.0, null).eval();

    // Expected: A * A = [[1*1+2*3, 1*2+2*4], [3*1+4*3, 3*2+4*4]] = [[7, 10], [15, 22]]
    try expectEqual(@as(usize, 2), result1.rows);
    try expectEqual(@as(usize, 2), result1.cols);
    try expectEqual(@as(f32, 7.0), result1.at(0, 0).*); // 1*1 + 2*3
    try expectEqual(@as(f32, 10.0), result1.at(0, 1).*); // 1*2 + 2*4
    try expectEqual(@as(f32, 15.0), result1.at(1, 0).*); // 3*1 + 4*3
    try expectEqual(@as(f32, 22.0), result1.at(1, 1).*); // 3*2 + 4*4

    // Case 2: A^T * A (covariance - SIMD same-matrix handling)
    const result2 = try a.gemm(true, a, false, 1.0, 0.0, null).eval();

    // Expected: A^T * A (3x2 -> 2x2 result)
    // A^T = [[1,3,5], [2,4,6]]
    // A^T * A = [[1*1+3*3+5*5, 1*2+3*4+5*6], [2*1+4*3+6*5, 2*2+4*4+6*6]] = [[35, 44], [44, 56]]
    try expectEqual(@as(usize, 2), result2.rows);
    try expectEqual(@as(usize, 2), result2.cols);
    try expectEqual(@as(f32, 35.0), result2.at(0, 0).*); // 1*1 + 3*3 + 5*5
    try expectEqual(@as(f32, 44.0), result2.at(0, 1).*); // 1*2 + 3*4 + 5*6
    try expectEqual(@as(f32, 44.0), result2.at(1, 0).*); // 2*1 + 4*3 + 6*5
    try expectEqual(@as(f32, 56.0), result2.at(1, 1).*); // 2*2 + 4*4 + 6*6

    // Case 3: A * A^T (gram matrix - SIMD same-matrix handling)
    const result3 = try a.gemm(false, a, true, 1.0, 0.0, null).eval();

    // Expected: A * A^T (3x2 -> 3x3 result)
    // A * A^T = [[1*1+2*2, 1*3+2*4, 1*5+2*6], [3*1+4*2, 3*3+4*4, 3*5+4*6], [5*1+6*2, 5*3+6*4, 5*5+6*6]]
    //         = [[5, 11, 17], [11, 25, 39], [17, 39, 61]]
    try expectEqual(@as(usize, 3), result3.rows);
    try expectEqual(@as(usize, 3), result3.cols);
    try expectEqual(@as(f32, 5.0), result3.at(0, 0).*); // 1*1 + 2*2
    try expectEqual(@as(f32, 11.0), result3.at(0, 1).*); // 1*3 + 2*4
    try expectEqual(@as(f32, 17.0), result3.at(0, 2).*); // 1*5 + 2*6
    try expectEqual(@as(f32, 11.0), result3.at(1, 0).*); // 3*1 + 4*2
    try expectEqual(@as(f32, 25.0), result3.at(1, 1).*); // 3*3 + 4*4
    try expectEqual(@as(f32, 39.0), result3.at(1, 2).*); // 3*5 + 4*6
    try expectEqual(@as(f32, 17.0), result3.at(2, 0).*); // 5*1 + 6*2
    try expectEqual(@as(f32, 39.0), result3.at(2, 1).*); // 5*3 + 6*4
    try expectEqual(@as(f32, 61.0), result3.at(2, 2).*); // 5*5 + 6*6

    // Case 4: A^T * A^T (both transposed - SIMD same-matrix handling)
    const result4 = try square_a.gemm(true, square_a, true, 1.0, 0.0, null).eval();

    // Expected: A^T * A^T where A^T = [[1,3], [2,4]]
    // A^T * A^T = [[1*1+3*2, 1*3+3*4], [2*1+4*2, 2*3+4*4]] = [[7, 15], [10, 22]]
    try expectEqual(@as(usize, 2), result4.rows);
    try expectEqual(@as(usize, 2), result4.cols);
    try expectEqual(@as(f32, 7.0), result4.at(0, 0).*); // 1*1 + 3*2
    try expectEqual(@as(f32, 15.0), result4.at(0, 1).*); // 1*3 + 3*4
    try expectEqual(@as(f32, 10.0), result4.at(1, 0).*); // 2*1 + 4*2
    try expectEqual(@as(f32, 22.0), result4.at(1, 1).*); // 2*3 + 4*4
}

test "Matrix SIMD 9x9 matrix with known values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Create simple 9x9 matrix with predictable values (forces SIMD: 729 ops > 512)
    var test_matrix: Matrix(f32) = try .init(arena.allocator(), 9, 9);

    // Fill with simple pattern: A[i,j] = i + 1 (row number)
    for (0..9) |i| {
        for (0..9) |j| {
            test_matrix.at(i, j).* = @as(f32, @floatFromInt(i + 1));
        }
    }

    // Test Case 1: A * A (should use SIMD same-matrix optimization)
    const result1 = try test_matrix.gemm(false, test_matrix, false, 1.0, 0.0, null).eval();

    // Verify Case 1: A * A (uses SIMD same-matrix optimization)
    try expectEqual(@as(usize, 9), result1.rows);
    try expectEqual(@as(usize, 9), result1.cols);
    try expectEqual(@as(f32, 45.0), result1.at(0, 0).*); // Row 0 * Col 0
    try expectEqual(@as(f32, 90.0), result1.at(1, 0).*); // Row 1 * Col 0
    try expectEqual(@as(f32, 405.0), result1.at(8, 8).*); // Row 8 * Col 8

    // Test Case 2: A^T * A (covariance)
    const result2 = try test_matrix.gemm(true, test_matrix, false, 1.0, 0.0, null).eval();

    // Verify Case 2: A^T * A (covariance, uses SIMD same-matrix optimization)
    try expectEqual(@as(usize, 9), result2.rows);
    try expectEqual(@as(usize, 9), result2.cols);
    try expectEqual(@as(f32, 285.0), result2.at(0, 0).*); // Sum of squares: 1²+2²+...+9²
    try expectEqual(@as(f32, 285.0), result2.at(8, 8).*); // Same for all diagonal elements

    // Test Case 3: A * A^T (gram matrix)
    const result3 = try test_matrix.gemm(false, test_matrix, true, 1.0, 0.0, null).eval();

    // Verify Case 3: A * A^T (gram matrix, uses SIMD same-matrix optimization)
    try expectEqual(@as(usize, 9), result3.rows);
    try expectEqual(@as(usize, 9), result3.cols);
    try expectEqual(@as(f32, 9.0), result3.at(0, 0).*); // 1² * 9 elements
    try expectEqual(@as(f32, 36.0), result3.at(1, 1).*); // 2² * 9 elements
    try expectEqual(@as(f32, 729.0), result3.at(8, 8).*); // 9² * 9 elements

    // Test Case 4: A^T * A^T
    const result4 = try test_matrix.gemm(true, test_matrix, true, 1.0, 0.0, null).eval();

    // Verify Case 4: A^T * A^T (uses SIMD same-matrix optimization)
    try expectEqual(@as(usize, 9), result4.rows);
    try expectEqual(@as(usize, 9), result4.cols);
    try expectEqual(@as(f32, 45.0), result4.at(0, 0).*); // Corners same as case 1
    try expectEqual(@as(f32, 405.0), result4.at(0, 8).*);
    try expectEqual(@as(f32, 45.0), result4.at(8, 0).*);
    try expectEqual(@as(f32, 405.0), result4.at(8, 8).*);
}

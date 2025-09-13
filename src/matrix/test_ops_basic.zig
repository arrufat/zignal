const std = @import("std");
const expectEqual = std.testing.expectEqual;
const Matrix = @import("Matrix.zig").Matrix;
const SMatrix = @import("SMatrix.zig").SMatrix;

test "complex operation chaining" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test data
    const static_a: SMatrix(f32, 2, 2) = .init(.{ .{ 1.0, 2.0 }, .{ 3.0, 4.0 } });
    const static_b: SMatrix(f32, 2, 2) = .init(.{ .{ 2.0, 0.0 }, .{ 0.0, 2.0 } });

    // SMatrix chaining (direct method calls)
    const static_result = static_a.dot(static_b).transpose().scale(0.5);

    // Matrix chaining (equivalent operations)
    const dynamic_a = try static_a.toMatrix(arena.allocator());
    const dynamic_b = try static_b.toMatrix(arena.allocator());

    const dynamic_result = try dynamic_a
        .dot(dynamic_b)
        .transpose()
        .scale(0.5)
        .eval();

    // Verify both approaches give identical results
    for (0..2) |r| {
        for (0..2) |c| {
            try expectEqual(static_result.at(r, c).*, dynamic_result.at(r, c).*);
        }
    }
}

test "row and column extraction with Matrix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test data
    const test_matrix: SMatrix(f32, 3, 2) = .init(.{
        .{ 1.0, 2.0 },
        .{ 3.0, 4.0 },
        .{ 5.0, 6.0 },
    });

    // Test Matrix row/col extraction
    const dynamic_matrix = try test_matrix.toMatrix(arena.allocator());

    const dynamic_row = try dynamic_matrix.row(1).eval();
    try expectEqual(@as(usize, 1), dynamic_row.rows);
    try expectEqual(@as(usize, 2), dynamic_row.cols);
    try expectEqual(@as(f32, 3.0), dynamic_row.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), dynamic_row.at(0, 1).*);

    const dynamic_col = try dynamic_matrix.col(1).eval();
    try expectEqual(@as(usize, 3), dynamic_col.rows);
    try expectEqual(@as(usize, 1), dynamic_col.cols);
    try expectEqual(@as(f32, 2.0), dynamic_col.at(0, 0).*);
    try expectEqual(@as(f32, 4.0), dynamic_col.at(1, 0).*);
    try expectEqual(@as(f32, 6.0), dynamic_col.at(2, 0).*);
}

test "Matrix operations: add, sub, scale, transpose" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Test data
    const static_matrix: SMatrix(f32, 2, 3) = .init(.{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    });

    // Test operand matrix for add/sub operations
    const static_operand: SMatrix(f32, 2, 3) = .init(.{
        .{ 0.5, 1.0, 1.5 },
        .{ 2.0, 2.5, 3.0 },
    });

    // SMatrix operations for reference
    const static_scaled = static_matrix.scale(2.0);
    const static_transposed = static_matrix.transpose();
    const static_subtracted = static_matrix.sub(static_operand);

    // OpsBuilder operations on equivalent matrix
    const dynamic_matrix = try static_matrix.toMatrix(arena.allocator());

    // Test scale
    const dynamic_scaled = try dynamic_matrix.scale(2.0).eval();

    // Test transpose
    const dynamic_transposed = try dynamic_matrix.transpose().eval();

    // Test add
    const add_matrix: Matrix(f32) = try .initAll(arena.allocator(), 2, 3, 1.0);
    const dynamic_added = try dynamic_matrix.add(add_matrix).eval();

    // Test subtract
    const dynamic_operand = try static_operand.toMatrix(arena.allocator());
    const dynamic_subtracted = try dynamic_matrix.sub(dynamic_operand).eval();

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

//! Symmetric eigendecomposition via cyclic Jacobi rotations.
//!
//! Computes A = V · diag(λ) · Vᵀ for a real symmetric matrix A. Unlike `svd` (whose singular
//! values are |λ| and therefore lose eigenvalue sign), this recovers *signed* eigenvalues, so it
//! works for indefinite matrices. Robust and fast for the small dense matrices it is meant for.

const std = @import("std");
const assert = std.debug.assert;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const Matrix = @import("Matrix.zig").Matrix;

/// Result of a symmetric eigendecomposition: A = V · diag(values) · Vᵀ.
pub fn Result(comptime T: type) type {
    return struct {
        /// Eigenvalues as an n×1 column vector, in ascending order.
        values: Matrix(T),
        /// Eigenvectors as columns: column j is the unit eigenvector corresponding to the j-th
        /// eigenvalue (`values.at(j, 0)`). The matrix is orthogonal (Vᵀ · V = I).
        vectors: Matrix(T),

        pub fn deinit(self: *@This()) void {
            self.values.deinit();
            self.vectors.deinit();
        }
    };
}

/// Eigendecomposition of the symmetric n×n matrix `a` via cyclic Jacobi rotations. Eigenvalues are
/// returned ascending, with `vectors`' columns the matching unit eigenvectors. The caller owns the
/// returned matrices. Returns `error.NotSymmetric` if `a` is not symmetric within a magnitude-relative
/// tolerance (a general non-symmetric eigendecomposition, with its complex spectrum, is out of scope).
pub fn eigh(comptime T: type, allocator: std.mem.Allocator, a: Matrix(T)) !Result(T) {
    comptime assert(@typeInfo(T) == .float);
    assert(a.rows == a.cols);
    const n = a.rows;

    // Validate symmetry within a magnitude-relative tolerance: exact-equal entries pass trivially and
    // floating-point rounding noise (e.g. a Hessian assembled from separately-grouped sums) passes,
    // but a genuinely non-symmetric matrix is rejected rather than silently mis-decomposed.
    {
        var max_abs: T = 0;
        for (a.items) |x| max_abs = @max(max_abs, @abs(x));
        const tol = max_abs * @sqrt(std.math.floatEps(T));
        for (0..n) |i| for (i + 1..n) |j| {
            if (@abs(a.at(i, j).* - a.at(j, i).*) > tol) return error.NotSymmetric;
        };
    }

    // Working copy (destroyed by the sweeps) and the accumulating eigenvector matrix V = I.
    var work = try a.dupe(allocator);
    defer work.deinit();
    var v = try Matrix(T).identity(allocator, n, n);
    errdefer v.deinit();

    // Scale-invariant convergence: off-diagonals are "zero" relative to the matrix magnitude. The
    // Frobenius norm is invariant under Jacobi rotations, so this bound is computed once.
    var frob_sq: T = 0;
    for (work.items) |x| frob_sq += x * x;
    const eps = std.math.floatEps(T);
    const off_tol = frob_sq * eps * eps;

    var sweep: usize = 0;
    while (sweep < 100) : (sweep += 1) {
        var off: T = 0;
        for (0..n) |p| for (p + 1..n) |q| {
            off += work.at(p, q).* * work.at(p, q).*;
        };
        if (off <= off_tol) break;

        for (0..n) |p| {
            for (p + 1..n) |q| {
                const apq = work.at(p, q).*;
                if (apq == 0) continue;
                const theta = 0.5 * (work.at(q, q).* - work.at(p, p).*) / apq;
                const t = blk: {
                    const sign: T = if (theta < 0) -1 else 1;
                    break :blk sign / (@abs(theta) + @sqrt(theta * theta + 1));
                };
                const c = 1.0 / @sqrt(t * t + 1);
                const s = t * c;
                // A <- Jᵀ A J : first rotate columns p,q, then rows p,q.
                for (0..n) |k| {
                    const akp = work.at(k, p).*;
                    const akq = work.at(k, q).*;
                    work.at(k, p).* = c * akp - s * akq;
                    work.at(k, q).* = s * akp + c * akq;
                }
                for (0..n) |k| {
                    const apk = work.at(p, k).*;
                    const aqk = work.at(q, k).*;
                    work.at(p, k).* = c * apk - s * aqk;
                    work.at(q, k).* = s * apk + c * aqk;
                }
                // Accumulate eigenvectors: V <- V J.
                for (0..n) |k| {
                    const vkp = v.at(k, p).*;
                    const vkq = v.at(k, q).*;
                    v.at(k, p).* = c * vkp - s * vkq;
                    v.at(k, q).* = s * vkp + c * vkq;
                }
            }
        }
    }

    var values = try Matrix(T).init(allocator, n, 1);
    errdefer values.deinit();
    for (0..n) |i| values.at(i, 0).* = work.at(i, i).*;

    // Sort ascending, permuting eigenvector columns to match (selection sort; n is small).
    for (0..n) |i| {
        var min_idx = i;
        for (i + 1..n) |j| {
            if (values.at(j, 0).* < values.at(min_idx, 0).*) min_idx = j;
        }
        if (min_idx != i) {
            std.mem.swap(T, values.at(i, 0), values.at(min_idx, 0));
            for (0..n) |k| std.mem.swap(T, v.at(k, i), v.at(k, min_idx));
        }
    }

    return .{ .values = values, .vectors = v };
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

test "eigh: [[2,1],[1,2]] -> eigenvalues 1, 3 (ascending), orthonormal vectors" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .fromSlice(allocator, 2, 2, &.{ 2, 1, 1, 2 });
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();

    try expectApproxEqAbs(@as(f64, 1), eig.values.at(0, 0).*, 1e-9);
    try expectApproxEqAbs(@as(f64, 3), eig.values.at(1, 0).*, 1e-9);
    // Each eigenvector column is unit norm.
    for (0..2) |j| {
        const c0 = eig.vectors.at(0, j).*;
        const c1 = eig.vectors.at(1, j).*;
        try expectApproxEqAbs(@as(f64, 1), c0 * c0 + c1 * c1, 1e-9);
    }
}

test "eigh: indefinite matrix keeps eigenvalue signs (SVD cannot)" {
    const allocator = std.testing.allocator;
    // [[0,1],[1,0]] has eigenvalues -1 and 1 — a sign that SVD (|λ| = 1, 1) would lose.
    var a: Matrix(f64) = try .fromSlice(allocator, 2, 2, &.{ 0, 1, 1, 0 });
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();
    try expectApproxEqAbs(@as(f64, -1), eig.values.at(0, 0).*, 1e-9);
    try expectApproxEqAbs(@as(f64, 1), eig.values.at(1, 0).*, 1e-9);
}

test "eigh: scale invariant (large-magnitude matrix)" {
    const allocator = std.testing.allocator;
    const s: f64 = 1e8;
    var a: Matrix(f64) = try .fromSlice(allocator, 2, 2, &.{ 2 * s, 1 * s, 1 * s, 2 * s });
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();
    try expectApproxEqAbs(@as(f64, 1e8), eig.values.at(0, 0).*, 1.0);
    try expectApproxEqAbs(@as(f64, 3e8), eig.values.at(1, 0).*, 1.0);
}

test "eigh: 1x1" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .fromSlice(allocator, 1, 1, &.{-2});
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();
    try expectApproxEqAbs(@as(f64, -2), eig.values.at(0, 0).*, 1e-12);
    try expectApproxEqAbs(@as(f64, 1), eig.vectors.at(0, 0).*, 1e-12);
}

test "eigh: each column is a matching eigenpair (A·v = λ·v)" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .fromSlice(allocator, 3, 3, &.{
        4,  1, -2,
        1,  2, 0,
        -2, 0, 3,
    });
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();
    // Directly checks the ascending-sort column permutation keeps each eigenvector with its eigenvalue.
    for (0..3) |j| {
        const lambda = eig.values.at(j, 0).*;
        for (0..3) |i| {
            var av: f64 = 0;
            for (0..3) |k| av += a.at(i, k).* * eig.vectors.at(k, j).*;
            try expectApproxEqAbs(lambda * eig.vectors.at(i, j).*, av, 1e-9);
        }
    }
}

test "eigh: already-diagonal input (no rotations) still sorts and permutes basis vectors" {
    const allocator = std.testing.allocator;
    // diag(5, -3, 2): off-diagonals are zero, so the sweep breaks before any rotation and only the
    // ascending sort runs — exercising the permutation on identity columns.
    var a: Matrix(f64) = try .diagonal(allocator, &.{ 5, -3, 2 });
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();
    try expectApproxEqAbs(@as(f64, -3), eig.values.at(0, 0).*, 1e-12);
    try expectApproxEqAbs(@as(f64, 2), eig.values.at(1, 0).*, 1e-12);
    try expectApproxEqAbs(@as(f64, 5), eig.values.at(2, 0).*, 1e-12);
    // Columns are the permuted standard basis: col0=e1, col1=e2, col2=e0 (up to sign).
    try expectApproxEqAbs(@as(f64, 1), @abs(eig.vectors.at(1, 0).*), 1e-12);
    try expectApproxEqAbs(@as(f64, 1), @abs(eig.vectors.at(2, 1).*), 1e-12);
    try expectApproxEqAbs(@as(f64, 1), @abs(eig.vectors.at(0, 2).*), 1e-12);
}

test "eigh: rejects a non-symmetric matrix" {
    const allocator = std.testing.allocator;
    var a: Matrix(f64) = try .fromSlice(allocator, 2, 2, &.{ 0, 1, 2, 0 });
    defer a.deinit();
    try std.testing.expectError(error.NotSymmetric, eigh(f64, allocator, a));
}

test "eigh: reconstructs A = V diag(λ) Vᵀ" {
    const allocator = std.testing.allocator;
    // A symmetric 3×3 with mixed-sign eigenvalues.
    var a: Matrix(f64) = try .fromSlice(allocator, 3, 3, &.{
        4,  1, -2,
        1,  2, 0,
        -2, 0, 3,
    });
    defer a.deinit();
    var eig = try eigh(f64, allocator, a);
    defer eig.deinit();

    // Rebuild via the diagonal constructor: V · diag(λ) · Vᵀ.
    var d: Matrix(f64) = try .diagonal(allocator, eig.values.items);
    defer d.deinit();
    var vd = try eig.vectors.dot(d);
    defer vd.deinit();
    var recon = try vd.dotTranspose(eig.vectors);
    defer recon.deinit();

    for (0..3) |i| {
        for (0..3) |j| {
            try expectApproxEqAbs(a.at(i, j).*, recon.at(i, j).*, 1e-9);
        }
    }
}

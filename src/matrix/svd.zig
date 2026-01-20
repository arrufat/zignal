const std = @import("std");

const Matrix = @import("Matrix.zig").Matrix;
const SMatrix = @import("SMatrix.zig").SMatrix;

/// Controls the size and computation of the left singular vectors matrix (U) in SVD.
/// This allows optimization of memory usage and computation time based on your needs.
pub const SvdMode = enum {
    /// Skip computation of U matrix entirely. Use when only singular values are needed.
    no_u,
    /// Compute only the first n columns of U (economy/thin SVD). Results in U being m×n.
    /// More memory efficient when m >> n.
    skinny_u,
    /// Compute the full m×m U matrix. Use when all left singular vectors are needed.
    full_u,
};

/// Internal state machine for the SVD algorithm's iterative process.
/// Based on the classical Golub-Reinsch algorithm.
const SvdState = enum {
    /// Test if the superdiagonal element can be set to zero (decoupling test)
    test_splitting,
    /// Cancel the superdiagonal element using Givens rotations
    cancellation,
    /// Check if the algorithm has converged for the current singular value
    test_convergence,
    /// Final convergence check and sign correction
    convergence_check,
};

/// Configuration options for SVD computation.
/// Allows fine-grained control over which matrices are computed.
pub const SvdOptions = struct {
    /// Whether to compute the left singular vectors (U matrix).
    /// Set to false when only singular values are needed.
    with_u: bool = true,
    /// Whether to compute the right singular vectors (V matrix).
    /// Set to false when only U and singular values are needed.
    with_v: bool = false,
    /// Controls the size of the U matrix when with_u is true.
    /// Ignored when with_u is false.
    mode: SvdMode = .full_u,
};

/// Result type for SVD decomposition: A = U × Σ × V^T
/// where A is the input matrix, U contains left singular vectors,
/// Σ is a diagonal matrix of singular values (stored as a vector),
/// and V contains right singular vectors.
///
/// The dimensions of matrices depend on the options used:
/// - U: m×m (full_u), m×n (skinny_u), or empty (no_u)
/// - s: n×1 vector of singular values in descending order
/// - V: n×n matrix (or empty if with_v=false)
pub fn SvdResult(comptime T: type) type {
    return struct {
        /// Left singular vectors matrix. Each column is a left singular vector.
        /// Dimensions: m×m (full_u) or m×n (skinny_u)
        u: Matrix(T),
        /// Singular values in descending order as a column vector.
        /// These are the diagonal elements of the Σ matrix.
        s: Matrix(T),
        /// Right singular vectors matrix. Each column is a right singular vector.
        /// The matrix is orthogonal: V^T × V = I
        v: Matrix(T),
        /// Convergence status: 0 if successful, k if failed at k-th singular value.
        /// Non-zero values indicate the iterative algorithm failed to converge.
        converged: usize,

        pub fn deinit(self: *@This()) void {
            self.u.deinit();
            self.s.deinit();
            self.v.deinit();
        }
    };
}

/// Performs singular value decomposition. Code adapted from dlib's svd4, which is, in turn,
/// translated to 'C' from the original Algol code in "Hanbook for Automatic Computation, vol. II,
/// Linear Algebra", Springer-Verlag.  Note that this published algorithm is considered to be
/// the best and numerically stable approach to computing the real-valued svd and is referenced
/// repeatedly in ieee journal papers, etc where the svd is used.
///
/// This is almost an exact translation from the original, except that an iteration counter
/// is added to prevent stalls.  This corresponds to similar changes in other translations.
/// Returns an error code = 0, if no errors and 'k' if a failure to converge at the 'kth'
/// singular value.
///
/// USAGE: given the singular value decomposition a = u * diagm(q) * trans(v) for an m*n
/// matrix a with m >= n.  After the svd call, u is an m x m matrix which is columnwise
/// orthogonal. q will be an n element vector consisting of singular values and v an n x n
/// orthogonal matrix. eps and tol are tolerance constants.  Suitable values are eps=1e-16
/// and tol=(1e-300)/eps if T == double.
///
/// If options.mode == .no_u, then u won't be computed and similarly if options.with_v == false
/// then v won't be computed.  If options.mode == .skinny_u then u will be m x n instead of m x m.
pub fn svd(
    comptime T: type,
    allocator: std.mem.Allocator,
    a: Matrix(T),
    options: SvdOptions,
) !SvdResult(T) {
    std.debug.assert(a.rows >= a.cols);
    var eps: T = std.math.floatEps(T);
    const tol: T = std.math.floatMin(T) / eps;
    const m = a.rows;
    const n = a.cols;

    // Allocate matrices based on options
    var u = if (options.mode == .full_u)
        try Matrix(T).initAll(allocator, m, m, 0)
    else
        try Matrix(T).initAll(allocator, m, n, 0);
    errdefer u.deinit();

    var v = try Matrix(T).initAll(allocator, n, n, 0);
    errdefer v.deinit();

    var q = try Matrix(T).initAll(allocator, n, 1, 0);
    errdefer q.deinit();

    var e = try Matrix(T).initAll(allocator, n, 1, 0);
    defer e.deinit(); // e is only used internally

    var l: usize = 0;
    var retval: usize = 0;
    var c: T = undefined;
    var f: T = undefined;
    var g: T = undefined;
    var h: T = undefined;
    var s: T = undefined;
    var x: T = undefined;
    var y: T = undefined;
    var z: T = undefined;

    // Copy a to u.
    for (0..m) |i| {
        for (0..n) |j| {
            u.at(i, j).* = a.at(i, j).*;
        }
    }

    // Householder's reduction to bidiagonal form.
    g = 0;
    x = 0;
    for (0..n) |i| {
        e.at(i, 0).* = g;
        s = 0;
        l = i + 1;

        for (i..m) |j| {
            s += u.at(j, i).* * u.at(j, i).*;
        }

        if (s < tol) {
            g = 0;
        } else {
            f = u.at(i, i).*;
            g = if (f < 0) @sqrt(s) else -@sqrt(s);
            h = f * g - s;
            u.at(i, i).* = f - g;

            for (l..n) |j| {
                s = 0;
                for (i..m) |k| {
                    s += u.at(k, i).* * u.at(k, j).*;
                }
                f = s / h;

                for (i..m) |k| {
                    u.at(k, j).* += f * u.at(k, i).*;
                }
            }
        }

        q.at(i, 0).* = g;
        s = 0;

        for (l..n) |j| {
            s += u.at(i, j).* * u.at(i, j).*;
        }

        if (s < tol) {
            g = 0;
        } else {
            f = u.at(i, i + 1).*;
            g = if (f < 0) @sqrt(s) else -@sqrt(s);
            h = f * g - s;
            u.at(i, i + 1).* = f - g;

            for (l..n) |j| {
                e.at(j, 0).* = u.at(i, j).* / h;
            }

            for (l..m) |j| {
                s = 0;
                for (l..n) |k| {
                    s += u.at(j, k).* * u.at(i, k).*;
                }
                for (l..n) |k| {
                    u.at(j, k).* += s * e.at(k, 0).*;
                }
            }
        }
        y = @abs(q.at(i, 0).*) + @abs(e.at(i, 0).*);
        if (y > x) {
            x = y;
        }
    }

    // Accumulation of right-hand transformations.
    if (options.with_v) {
        for (0..n) |ri| {
            const i = n - 1 - ri;
            if (g != 0) {
                h = u.at(i, i + 1).* * g;
                for (l..n) |j| {
                    v.at(j, i).* = u.at(i, j).* / h;
                }
                for (l..n) |j| {
                    s = 0;
                    for (l..n) |k| {
                        s += u.at(i, k).* * v.at(k, j).*;
                    }
                    for (l..n) |k| {
                        v.at(k, j).* += s * v.at(k, i).*;
                    }
                }
            }
            for (l..n) |j| {
                v.at(i, j).* = 0;
                v.at(j, i).* = 0;
            }
            v.at(i, i).* = 1;
            g = e.at(i, 0).*;
            l = i;
        }
    }

    // Accumulation of left-hand transformations.
    if (options.mode != .no_u) {
        for (n..u.rows) |i| {
            for (n..u.cols) |j| {
                u.at(i, j).* = 0;
            }
            if (i < u.cols) {
                u.at(i, i).* = 1;
            }
        }
    }

    if (options.mode != .no_u) {
        for (0..n) |ri| {
            const i = n - 1 - ri;
            l = i + 1;
            g = q.at(i, 0).*;

            for (l..u.cols) |j| {
                u.at(i, j).* = 0;
            }
            if (g != 0) {
                h = u.at(i, i).* * g;
                for (l..u.cols) |j| {
                    s = 0;
                    for (l..m) |k| {
                        s += u.at(k, i).* * u.at(k, j).*;
                    }
                    f = s / h;
                    for (i..m) |k| {
                        u.at(k, j).* += f * u.at(k, i).*;
                    }
                }
                for (i..m) |j| {
                    u.at(j, i).* /= g;
                }
            } else {
                for (i..m) |j| {
                    u.at(j, i).* = 0;
                }
            }
            u.at(i, i).* += 1;
        }
    }

    // Diagonalization of the bidiagonal form.
    eps *= x;

    for (0..n) |rk| {
        const k = n - 1 - rk;
        var iter: usize = 0;

        svd_state: switch (SvdState.test_splitting) {
            .test_splitting => {
                for (0..k + 1) |rl| {
                    l = k - rl;
                    if (@abs(e.at(l, 0).*) <= eps) {
                        continue :svd_state .test_convergence;
                    }
                    if (@abs(q.at(l - 1, 0).*) <= eps) {
                        continue :svd_state .cancellation;
                    }
                }
                continue :svd_state .test_convergence;
            },

            .cancellation => {
                // Cancellation of e.at(l, 0) if l > 0
                c = 0;
                s = 1;
                const l1 = l - 1;
                for (l..k + 1) |i| {
                    f = s * e.at(i, 0).*;
                    e.at(i, 0).* *= c;

                    if (@abs(f) <= eps) {
                        continue :svd_state .test_convergence;
                    }
                    g = q.at(i, 0).*;
                    h = @sqrt(f * f + g * g);
                    q.at(i, 0).* = h;
                    c = g / h;
                    s = -f / h;
                    if (options.mode != .no_u) {
                        for (0..m) |j| {
                            y = u.at(j, l1).*;
                            z = u.at(j, i).*;
                            u.at(j, l1).* = y * c + z * s;
                            u.at(j, i).* = -y * s + z * c;
                        }
                    }
                }
                continue :svd_state .test_convergence;
            },

            .test_convergence => {
                z = q.at(k, 0).*;
                if (l == k) {
                    continue :svd_state .convergence_check;
                }
                // Shift from bottom 2x2 minor.
                iter += 1;
                if (iter > 300) {
                    retval = k;
                    break :svd_state;
                }
                x = q.at(l, 0).*;
                y = q.at(k - 1, 0).*;
                g = e.at(k - 1, 0).*;
                h = e.at(k, 0).*;
                f = ((y - z) * (y + z) + (g - h) * (g + h)) / (2 * h * y);
                g = @sqrt(f * f + 1.0);
                f = ((x - z) * (x + z) + h * (y / (if (f < 0) (f - g) else (f + g)) - h)) / x;

                // Next QR transformation.
                c = 1;
                s = 1;
                for (l + 1..k + 1) |i| {
                    g = e.at(i, 0).*;
                    y = q.at(i, 0).*;
                    h = s * g;
                    g *= c;
                    z = @sqrt(f * f + h * h);
                    e.at(i - 1, 0).* = z;
                    c = f / z;
                    s = h / z;
                    f = x * c + g * s;
                    g = -x * s + g * c;
                    h = y * s;
                    y *= c;
                    if (options.with_v) {
                        for (0..n) |j| {
                            x = v.at(j, i - 1).*;
                            z = v.at(j, i).*;
                            v.at(j, i - 1).* = x * c + z * s;
                            v.at(j, i).* = -x * s + z * c;
                        }
                    }
                    z = @sqrt(f * f + h * h);
                    q.at(i - 1, 0).* = z;
                    if (z != 0) {
                        c = f / z;
                        s = h / z;
                    }
                    f = c * g + s * y;
                    x = -s * g + c * y;
                    if (options.mode != .no_u) {
                        for (0..m) |j| {
                            y = u.at(j, i - 1).*;
                            z = u.at(j, i).*;
                            u.at(j, i - 1).* = y * c + z * s;
                            u.at(j, i).* = -y * s + z * c;
                        }
                    }
                }
                e.at(l, 0).* = 0;
                e.at(k, 0).* = f;
                q.at(k, 0).* = x;
                continue :svd_state .test_splitting;
            },

            .convergence_check => {
                if (z < 0) {
                    // q.at(k, 0) made non-negative
                    q.at(k, 0).* = -z;
                    if (options.with_v) {
                        for (0..n) |j| {
                            v.at(j, k).* = -v.at(j, k).*;
                        }
                    }
                }
                break :svd_state;
            },
        }
    }
    // Sort singular values in descending order
    // This requires swapping columns of U and V accordingly
    for (0..n) |i| {
        var max_idx = i;
        var max_val = q.at(i, 0).*;

        // Find the maximum singular value from i to n
        for (i + 1..n) |j| {
            if (q.at(j, 0).* > max_val) {
                max_idx = j;
                max_val = q.at(j, 0).*;
            }
        }

        // Swap if needed
        if (max_idx != i) {
            // Swap singular values
            const temp_s = q.at(i, 0).*;
            q.at(i, 0).* = q.at(max_idx, 0).*;
            q.at(max_idx, 0).* = temp_s;

            // Swap columns of U
            if (options.mode != .no_u) {
                for (0..m) |row| {
                    const temp_u = u.at(row, i).*;
                    u.at(row, i).* = u.at(row, max_idx).*;
                    u.at(row, max_idx).* = temp_u;
                }
            }

            // Swap columns of V
            if (options.with_v) {
                for (0..n) |row| {
                    const temp_v = v.at(row, i).*;
                    v.at(row, i).* = v.at(row, max_idx).*;
                    v.at(row, max_idx).* = temp_v;
                }
            }
        }
    }

    return SvdResult(T){ .u = u, .s = q, .v = v, .converged = retval };
}

test "svd basic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const m: usize = 5;
    const n: usize = 4;
    // Example matrix taken from Wikipedia
    var a: Matrix(f64) = try .init(allocator, m, n);
    const data = [m][n]f64{
        .{ 1, 0, 0, 0 },
        .{ 0, 0, 0, 2 },
        .{ 0, 3, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 2, 0, 0, 0 },
    };
    for (0..m) |i| {
        for (0..n) |j| {
            a.at(i, j).* = data[i][j];
        }
    }

    var res = try a.svd(allocator, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer res.deinit();
    const u = &res.u;
    const s = &res.s;
    const v = &res.v;

    // Check that we got the right dimensions
    try std.testing.expectEqual(@as(usize, m), u.rows);
    try std.testing.expectEqual(@as(usize, m), u.cols);
    try std.testing.expectEqual(@as(usize, n), s.rows);
    try std.testing.expectEqual(@as(usize, 1), s.cols);
    try std.testing.expectEqual(@as(usize, n), v.rows);
    try std.testing.expectEqual(@as(usize, n), v.cols);

    // Check convergence
    try std.testing.expectEqual(@as(usize, 0), res.converged);

    // Check that singular values are non-negative and in descending order
    for (0..n) |i| {
        try std.testing.expect(s.at(i, 0).* >= 0);
        if (i > 0) {
            try std.testing.expect(s.at(i - 1, 0).* >= s.at(i, 0).*);
        }
    }
}

test "svd modes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const m: usize = 4;
    const n: usize = 4;
    var a: Matrix(f64) = try .fromSlice(allocator, m, n, &.{
        2, 1, 0, 0,
        1, 2, 1, 0,
        0, 1, 2, 1,
        0, 0, 1, 2,
    });

    // Test no_u mode
    var res_no_u = try a.svd(allocator, .{ .with_u = false, .with_v = true, .mode = .no_u });
    defer res_no_u.deinit();
    const s_no_u = &res_no_u.s;

    // Test skinny_u mode
    var res_skinny = try a.svd(allocator, .{ .with_u = true, .with_v = false, .mode = .skinny_u });
    defer res_skinny.deinit();
    const u_skinny = &res_skinny.u;
    const s_skinny = &res_skinny.s;

    // Test full_u mode
    var res_full = try a.svd(allocator, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer res_full.deinit();
    const u_full = &res_full.u;
    const s_full = &res_full.s;

    // Singular values should be the same across modes
    const tol = @sqrt(std.math.floatEps(f64));
    for (0..n) |i| {
        try std.testing.expectApproxEqRel(s_no_u.at(i, 0).*, s_skinny.at(i, 0).*, tol);
        try std.testing.expectApproxEqRel(s_skinny.at(i, 0).*, s_full.at(i, 0).*, tol);
    }

    // Check matrix dimensions
    try std.testing.expect(u_skinny.rows == m and u_skinny.cols == n);
    try std.testing.expect(u_full.rows == m and u_full.cols == m);
}

test "svd identity matrix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const n: usize = 3;
    var a = try Matrix(f64).identity(allocator, n, n);

    var res = try a.svd(allocator, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer res.deinit();
    const s = &res.s;

    // Identity matrix should have all singular values equal to 1
    const tol = @sqrt(std.math.floatEps(f64));
    for (0..n) |i| {
        try std.testing.expectApproxEqRel(s.at(i, 0).*, 1.0, tol);
    }
}

test "svd singular matrix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const m: usize = 3;
    const n: usize = 3;
    var a: Matrix(f64) = try .fromSlice(allocator, m, n, &.{
        1, 2, 3,
        2, 4, 6,
        1, 2, 3,
    });

    var res = try a.svd(allocator, .{ .with_u = true, .with_v = true, .mode = .full_u });
    defer res.deinit();
    const s = &res.s;

    // This matrix has rank 1, so should have 2 zero singular values
    const tol = @sqrt(std.math.floatEps(f64));
    var zero_count: usize = 0;
    for (0..n) |i| {
        if (s.at(i, 0).* < tol) {
            zero_count += 1;
        }
    }
    try std.testing.expect(zero_count == 2);
}

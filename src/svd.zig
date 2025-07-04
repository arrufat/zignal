const std = @import("std");

const Matrix = @import("matrix.zig").Matrix;

const SvdMode = enum {
    no_u,
    skinny_u,
    full_u,
};

const SvdState = enum {
    test_splitting,
    cancellation,
    test_convergence,
    convergence_check,
};
const SvdOptions = struct {
    with_u: bool = true,
    with_v: bool = false,
    mode: SvdMode = .full_u,
};

/// Performs singular value decompostion. Code adapted from dlib's svd4, which is, in turn,
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
    comptime rows: usize,
    comptime cols: usize,
    a: Matrix(T, rows, cols),
    comptime options: SvdOptions,
) struct { Matrix(T, rows, rows), Matrix(T, cols, 1), Matrix(T, cols, cols), usize } {
    comptime std.debug.assert(rows >= cols);
    var eps: T = std.math.floatEps(T);
    const tol: T = std.math.floatMin(T) / eps;
    const m = rows;
    const n = cols;
    var u = comptime if (options.mode == .full_u) Matrix(T, m, m){} else Matrix(T, m, n){};
    var v: Matrix(T, n, n) = .{};
    var q: Matrix(T, n, 1) = .{};
    var e: Matrix(T, n, 1) = .{};
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
            u.items[i][j] = a.items[i][j];
        }
    }

    // Householder's reduction to bidiagonal form.
    g = 0;
    x = 0;
    for (0..n) |i| {
        e.items[i][0] = g;
        s = 0;
        l = i + 1;

        for (i..m) |j| {
            s += u.at(j, i) * u.at(j, i);
        }

        if (s < tol) {
            g = 0;
        } else {
            f = u.at(i, i);
            g = if (f < 0) @sqrt(s) else -@sqrt(s);
            h = f * g - s;
            u.items[i][i] = f - g;

            for (l..n) |j| {
                s = 0;
                for (i..m) |k| {
                    s += u.at(k, i) * u.at(k, j);
                }
                f = s / h;

                for (i..m) |k| {
                    u.items[k][j] += f * u.at(k, i);
                }
            }
        }

        q.items[i][0] = g;
        s = 0;

        for (l..n) |j| {
            s += u.at(i, j) * u.at(i, j);
        }

        if (s < tol) {
            g = 0;
        } else {
            f = u.at(i, i + 1);
            g = if (f < 0) @sqrt(s) else -@sqrt(s);
            h = f * g - s;
            u.items[i][i + 1] = f - g;

            for (l..n) |j| {
                e.items[j][0] = u.at(i, j) / h;
            }

            for (l..m) |j| {
                s = 0;
                for (l..n) |k| {
                    s += u.at(j, k) * u.at(i, k);
                }
                for (l..n) |k| {
                    u.items[j][k] += s * e.at(k, 0);
                }
            }
        }
        y = @abs(q.at(i, 0)) + @abs(e.at(i, 0));
        if (y > x) {
            x = y;
        }
    }

    // Accumulation of right-hand transformations.
    if (options.with_v) {
        for (0..n) |ri| {
            const i = n - 1 - ri;
            if (g != 0) {
                h = u.at(i, i + 1) * g;
                for (l..n) |j| {
                    v.items[j][i] = u.at(i, j) / h;
                }
                for (l..n) |j| {
                    s = 0;
                    for (l..n) |k| {
                        s += u.at(i, k) * v.at(k, j);
                    }
                    for (l..n) |k| {
                        v.items[k][j] += s * v.at(k, i);
                    }
                }
            }
            for (l..n) |j| {
                v.items[i][j] = 0;
                v.items[j][i] = 0;
            }
            v.items[i][i] = 1;
            g = e.at(i, 0);
            l = i;
        }
    }

    // Accumulation of left-hand transformations.
    if (options.mode != .no_u) {
        for (n..u.rows) |i| {
            for (n..u.cols) |j| {
                u.items[i][j] = 0;
            }
            if (i < u.cols) {
                u.items[i][i] = 1;
            }
        }
    }

    if (options.mode != .no_u) {
        for (0..n) |ri| {
            const i = n - 1 - ri;
            l = i + 1;
            g = q.at(i, 0);

            for (l..u.cols) |j| {
                u.items[i][j] = 0;
            }
            if (g != 0) {
                h = u.at(i, i) * g;
                for (l..u.cols) |j| {
                    s = 0;
                    for (l..m) |k| {
                        s += u.at(k, i) * u.at(k, j);
                    }
                    f = s / h;
                    for (i..m) |k| {
                        u.items[k][j] += f * u.at(k, i);
                    }
                }
                for (i..m) |j| {
                    u.items[j][i] /= g;
                }
            } else {
                for (i..m) |j| {
                    u.items[j][i] = 0;
                }
            }
            u.items[i][i] += 1;
        }
    }

    // Diagonalization of the bidiagonal form.
    eps *= x;

    for (0..n) |rk| {
        const k = n - 1 - rk;
        var iter: usize = 0;

        state_machine: switch (SvdState.test_splitting) {
            .test_splitting => {
                for (0..k + 1) |rl| {
                    l = k - rl;
                    if (@abs(e.at(l, 0)) <= eps) {
                        continue :state_machine .test_convergence;
                    }
                    if (@abs(q.at(l - 1, 0)) <= eps) {
                        continue :state_machine .cancellation;
                    }
                }
                continue :state_machine .test_convergence;
            },

            .cancellation => {
                // Cancellation of e.at(l, 0) if l > 0
                c = 0;
                s = 1;
                const l1 = l - 1;
                inner: for (l..k + 1) |i| {
                    f = s * e.at(i, 0);
                    e.items[i][0] *= c;

                    if (@abs(f) <= eps) {
                        break :inner;
                    }
                    g = q.at(i, 0);
                    h = @sqrt(f * f + g * g);
                    q.items[i][0] = h;
                    c = g / h;
                    s = -f / h;
                    if (options.mode != .no_u) {
                        for (0..m) |j| {
                            y = u.at(j, l1);
                            z = u.at(j, i);
                            u.items[j][l1] = y * c + z * s;
                            u.items[j][i] = -y * s + z * c;
                        }
                    }
                }
                continue :state_machine .test_convergence;
            },

            .test_convergence => {
                z = q.at(k, 0);
                if (l == k) {
                    continue :state_machine .convergence_check;
                }
                // Shift from bottom 2x2 minor.
                iter += 1;
                if (iter > 300) {
                    retval = k;
                    break :state_machine;
                }
                x = q.at(l, 0);
                y = q.at(k - 1, 0);
                g = e.at(k - 1, 0);
                h = e.at(k, 0);
                f = ((y - z) * (y + z) + (g - h) * (g + h)) / (2 * h * y);
                g = @sqrt(f * f + 1.0);
                f = ((x - z) * (x + z) + h * (y / (if (f < 0) (f - g) else (f + g)) - h)) / x;

                // Next QR transformation.
                c = 1;
                s = 1;
                for (l + 1..k + 1) |i| {
                    g = e.at(i, 0);
                    y = q.at(i, 0);
                    h = s * g;
                    g *= c;
                    z = @sqrt(f * f + h * h);
                    e.items[i - 1][0] = z;
                    c = f / z;
                    s = h / z;
                    f = x * c + g * s;
                    g = -x * s + g * c;
                    h = y * s;
                    y *= c;
                    if (options.with_v) {
                        for (0..n) |j| {
                            x = v.at(j, i - 1);
                            z = v.at(j, i);
                            v.items[j][i - 1] = x * c + z * s;
                            v.items[j][i] = -x * s + z * c;
                        }
                    }
                    z = @sqrt(f * f + h * h);
                    q.items[i - 1][0] = z;
                    if (z != 0) {
                        c = f / z;
                        s = h / z;
                    }
                    f = c * g + s * y;
                    x = -s * g + c * y;
                    if (options.mode != .no_u) {
                        for (0..m) |j| {
                            y = u.at(j, i - 1);
                            z = u.at(j, i);
                            u.items[j][i - 1] = y * c + z * s;
                            u.items[j][i] = -y * s + z * c;
                        }
                    }
                }
                e.items[l][0] = 0;
                e.items[k][0] = f;
                q.items[k][0] = x;
                continue :state_machine .test_splitting;
            },

            .convergence_check => {
                if (z < 0) {
                    // q.at(k, 0) is made non-negative
                    q.items[k][0] = -z;
                    if (options.with_v) {
                        for (0..n) |j| {
                            v.items[j][k] = -v.at(j, k);
                        }
                    }
                }
                break :state_machine;
            },
        }
    }
    return .{ u, q, v, retval };
}

test "svd basic" {
    const m: usize = 5;
    const n: usize = 4;
    // Example matrix taken from Wikipedia
    const a: Matrix(f64, m, n) = .{
        .items = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 0, 0, 2 },
            .{ 0, 3, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 2, 0, 0, 0 },
        },
    };
    const res = svd(f64, m, n, a, .{ .with_u = true, .with_v = true, .mode = .full_u });
    const u: *const Matrix(f64, m, m) = &res[0];
    const q: *const Matrix(f64, n, 1) = &res[1];
    const v: *const Matrix(f64, n, n) = &res[2];
    var w: Matrix(f64, m, n) = .initAll(0);
    // build the diagonal matrix from q.
    for (0..q.rows) |i| {
        w.items[i][i] = q.at(i, 0);
    }
    // check decomposition
    const tol = @sqrt(std.math.floatEps(f64));
    const b = u.dot(w.dot(v.transpose()));
    for (0..m) |i| {
        for (0..n) |j| {
            try std.testing.expectApproxEqRel(a.at(i, j), b.at(i, j), tol);
        }
    }
    // check for orhonormality of u and v
    const id_m: Matrix(f64, m, m) = .identity();
    const uut = u.dot(u.transpose());
    for (u.items) |row| {
        const vec: @Vector(m, f64) = row;
        const norm = @reduce(.Add, vec * vec);
        try std.testing.expectApproxEqRel(norm, 1, tol);
    }
    for (0..m) |i| {
        for (0..m) |j| {
            try std.testing.expectApproxEqAbs(uut.at(i, j), id_m.at(i, j), 1e-15);
        }
    }
    const id_n: Matrix(f64, n, n) = .identity();
    const vvt = v.dot(v.transpose());
    for (v.items) |row| {
        const vec: @Vector(n, f64) = row;
        const norm = @reduce(.Add, vec * vec);
        try std.testing.expectApproxEqRel(norm, 1, tol);
    }
    for (0..n) |i| {
        for (0..n) |j| {
            try std.testing.expectApproxEqAbs(vvt.at(i, j), id_n.at(i, j), 1e-15);
        }
    }
}

test "svd modes" {
    const m: usize = 4;
    const n: usize = 4;
    const a: Matrix(f64, m, n) = .{
        .items = .{
            .{ 2, 1, 0, 0 },
            .{ 1, 2, 1, 0 },
            .{ 0, 1, 2, 1 },
            .{ 0, 0, 1, 2 },
        },
    };

    // Test no_u mode
    const res_no_u = svd(f64, m, n, a, .{ .with_u = false, .with_v = true, .mode = .no_u });
    const q_no_u = res_no_u[1];
    _ = res_no_u[2]; // v_no_u

    // Test skinny_u mode
    const res_skinny = svd(f64, m, n, a, .{ .with_u = true, .with_v = false, .mode = .skinny_u });
    const u_skinny = res_skinny[0];
    const q_skinny = res_skinny[1];

    // Test full_u mode
    const res_full = svd(f64, m, n, a, .{ .with_u = true, .with_v = true, .mode = .full_u });
    const u_full = res_full[0];
    const q_full = res_full[1];
    _ = res_full[2]; // v_full

    // Singular values should be the same across modes
    const tol = @sqrt(std.math.floatEps(f64));
    for (0..n) |i| {
        try std.testing.expectApproxEqRel(q_no_u.at(i, 0), q_skinny.at(i, 0), tol);
        try std.testing.expectApproxEqRel(q_skinny.at(i, 0), q_full.at(i, 0), tol);
    }

    // Check matrix dimensions
    try std.testing.expect(u_skinny.rows == m and u_skinny.cols == n);
    try std.testing.expect(u_full.rows == m and u_full.cols == m);
}

test "svd identity matrix" {
    const n: usize = 3;
    const a: Matrix(f64, n, n) = .identity();

    const res = svd(f64, n, n, a, .{ .with_u = true, .with_v = true, .mode = .full_u });
    const q = res[1];

    // Identity matrix should have all singular values equal to 1
    const tol = @sqrt(std.math.floatEps(f64));
    for (0..n) |i| {
        try std.testing.expectApproxEqRel(q.at(i, 0), 1.0, tol);
    }
}

test "svd singular matrix" {
    const m: usize = 3;
    const n: usize = 3;
    const a: Matrix(f64, m, n) = .{
        .items = .{
            .{ 1, 2, 3 },
            .{ 2, 4, 6 },
            .{ 1, 2, 3 },
        },
    };

    const res = svd(f64, m, n, a, .{ .with_u = true, .with_v = true, .mode = .full_u });
    const q = res[1];

    // This matrix has rank 1, so should have 2 zero singular values
    const tol = @sqrt(std.math.floatEps(f64));
    var zero_count: usize = 0;
    for (0..n) |i| {
        if (q.at(i, 0) < tol) {
            zero_count += 1;
        }
    }
    try std.testing.expect(zero_count == 2);
}

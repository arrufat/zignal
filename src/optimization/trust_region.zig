//! Numeric primitives for the local (trust-region) exploitation step of the global optimizer.
//!
//! Ported from dlib's `optimization_trust_region.h` (`solve_trust_region_subproblem[_bounded]`,
//! Nocedal & Wright Algorithm 4.3) and `global_function_search.cpp` (`fit_quadratic_to_points`).
//!
//! Everything operates on f64 with small, dense, row-major matrices stored as flat slices, which
//! suits the low-dimensional sub-problems that arise here. Heavy decompositions reuse zignal's
//! `Matrix` (pseudo-inverse for the quadratic fit, `eigh` for the trust-region hard case);
//! the rest is self-contained.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const Matrix = @import("../matrix.zig").Matrix;

// ---------------------------------------------------------------------------------------
// Small vector helpers (on []f64)
// ---------------------------------------------------------------------------------------

fn dot(a: []const f64, b: []const f64) f64 {
    var s: f64 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

fn norm(a: []const f64) f64 {
    return @sqrt(dot(a, a));
}

// ---------------------------------------------------------------------------------------
// Dense linear-algebra helpers (row-major n*n in []f64)
// ---------------------------------------------------------------------------------------

/// In-place Cholesky factorization. `a` is an n*n row-major symmetric matrix; on success its
/// lower triangle is overwritten with L such that A = L*L^T. Returns false if A is not positive
/// definite (the partial result is then meaningless).
fn cholInPlace(a: []f64, n: usize) bool {
    for (0..n) |j| {
        var sum = a[j * n + j];
        for (0..j) |k| sum -= a[j * n + k] * a[j * n + k];
        if (sum <= 0) return false;
        const ljj = @sqrt(sum);
        a[j * n + j] = ljj;
        for (j + 1..n) |i| {
            var s = a[i * n + j];
            for (0..j) |k| s -= a[i * n + k] * a[j * n + k];
            a[i * n + j] = s / ljj;
        }
    }
    return true;
}

/// Solve L*y = b (forward substitution), L lower-triangular (only lower triangle of `l` read).
fn solveLower(l: []const f64, n: usize, b: []const f64, y: []f64) void {
    for (0..n) |i| {
        var s = b[i];
        for (0..i) |k| s -= l[i * n + k] * y[k];
        y[i] = s / l[i * n + i];
    }
}

/// Solve L^T*x = y (back substitution), L lower-triangular (L^T is upper).
fn solveLowerT(l: []const f64, n: usize, y: []const f64, x: []f64) void {
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var s = y[i];
        for (i + 1..n) |k| s -= l[k * n + i] * x[k];
        x[i] = s / l[i * n + i];
    }
}

// ---------------------------------------------------------------------------------------
// Trust-region subproblem (unbounded)
// ---------------------------------------------------------------------------------------

/// Tuning knobs for the trust-region subproblem solvers. The defaults suit the local quadratic
/// models fit during exploitation, so callers normally pass `.{}`.
pub const TrustRegionOptions = struct {
    /// Relative tolerance on |‖p‖ - radius| for the Newton-on-lambda iteration.
    eps: f64 = 1e-3,
    /// Max Newton iterations before falling back to the eigenvalue "hard case".
    max_iter: usize = 500,

    pub const default: TrustRegionOptions = .{ .eps = 1e-3, .max_iter = 500 };
};

/// Solve   minimize  0.5*p^T B p + g^T p   subject to ||p|| <= radius.
/// `b` is an n*n row-major symmetric matrix, `g` length n, result written to `p` (length n).
/// Port of dlib `solve_trust_region_subproblem` (Nocedal & Wright Alg. 4.3).
pub fn solveTrustRegionSubproblem(
    allocator: Allocator,
    b: []const f64,
    g: []const f64,
    n: usize,
    radius: f64,
    p: []f64,
    options: TrustRegionOptions,
) !void {
    const eps = options.eps;
    const max_iter = options.max_iter;
    @memset(p, 0);

    // numeric_eps = max_i |B_ii| * eps_machine
    var max_diag: f64 = 0;
    for (0..n) |i| max_diag = @max(max_diag, @abs(b[i * n + i]));
    const numeric_eps = max_diag * std.math.floatEps(f64);

    // Gershgorin lower bound on the eigenvalues of B.
    var bb_min_eig: f64 = std.math.floatMax(f64);
    for (0..n) |i| {
        var off_sum: f64 = 0;
        for (0..n) |j| {
            if (j != i) off_sum += @abs(b[i * n + j]);
        }
        bb_min_eig = @min(bb_min_eig, b[i * n + i] - off_sum);
    }

    const g_norm = norm(g);

    var lambda_min: f64 = 0;
    var lambda_max: f64 = std.math.clamp(g_norm / radius - bb_min_eig, 0, std.math.floatMax(f64));

    // Minimum is at 0.
    if (g_norm < numeric_eps and bb_min_eig > numeric_eps) return;

    const m = try allocator.alloc(f64, n * n); // scratch for B + lambda*I (destroyed by chol)
    defer allocator.free(m);
    const tmp = try allocator.alloc(f64, n); // scratch for the forward-solve result q
    defer allocator.free(tmp);

    var lambda: f64 = 0;
    var lambda_delta: f64 = 0;
    var converged = false;

    for (0..max_iter) |_| {
        @memcpy(m, b[0 .. n * n]);
        for (0..n) |d| m[d * n + d] += lambda;

        if (!cholInPlace(m, n)) {
            // Cholesky doesn't exist: B + lambda*I not positive definite.
            if (g_norm <= numeric_eps) break; // go to eigen-decomposition path
            lambda_min = lambda;
            const alpha = 0.10;
            lambda = (1 - alpha) * lambda + alpha * lambda_max;
            continue;
        }

        // Solve (L L^T) p = -g.
        const neg_g = tmp; // reuse: first store -g
        for (0..n) |k| neg_g[k] = -g[k];
        solveLower(m, n, neg_g, p); // p = q = L^-1 (-g)
        const q_norm = norm(p);
        // copy q out, then back-solve in place
        @memcpy(tmp, p);
        solveLowerT(m, n, tmp, p);
        const p_norm = norm(p);

        if (lambda == 0) {
            if (p_norm < radius) {
                converged = true;
                break;
            }
        } else {
            if (@abs(p_norm - radius) / radius < eps) {
                converged = true;
                break;
            }
        }

        if (p_norm < radius) lambda_max = lambda else lambda_min = lambda;

        if (p_norm <= radius * std.math.floatEps(f64)) {
            const alpha = 0.01;
            lambda = (1 - alpha) * lambda_min + alpha * lambda_max;
            continue;
        }

        const old_lambda = lambda;
        lambda = lambda + std.math.pow(f64, q_norm / p_norm, 2) * (p_norm - radius) / radius;

        const gap = (lambda_max - lambda_min) * 0.01;
        lambda = std.math.clamp(lambda, lambda_min + gap, lambda_max - gap);

        lambda_delta += @abs(lambda - old_lambda);
        if (lambda_delta > 3 * (lambda_max - lambda_min)) {
            lambda = (lambda_min + lambda_max) / 2;
            lambda_delta = 0;
        }
    }

    if (converged) return;

    // Hard case: use a symmetric eigendecomposition (port of dlib's fallback). Eigenvalues come back
    // ascending, so the most-negative one and its eigenvector are at index 0.
    var bmat: Matrix(f64) = try .fromSlice(allocator, @intCast(n), @intCast(n), b[0 .. n * n]);
    defer bmat.deinit();
    var eig = try bmat.eigh(allocator);
    defer eig.deinit();

    const min_eig = eig.values.at(0, 0).*;

    // ev <- reciprocal of (eigenvalue - min_eig), with near-zero entries zeroed. The tolerance is
    // relative to the shifted spread (max - min, values are ascending), matching dlib.
    const ev = tmp;
    const zero_tol = (eig.values.at(n - 1, 0).* - min_eig) * std.math.floatEps(f64);
    for (0..n) |i| {
        const shifted = eig.values.at(i, 0).* - min_eig;
        ev[i] = if (shifted > zero_tol) 1.0 / shifted else 0;
    }

    // p_hard = V * diag(ev) * V^T * g. Needs 2*n contiguous slots (p_hard + vt_g); the `m` Newton
    // scratch is only n*n, which is < 2*n when n == 1, so use a dedicated buffer here.
    const hard = try allocator.alloc(f64, 2 * n);
    defer allocator.free(hard);
    const p_hard = hard[0..n];
    const vt_g = hard[n .. 2 * n];
    for (0..n) |j| {
        var s: f64 = 0;
        for (0..n) |k| s += eig.vectors.at(k, j).* * g[k]; // (V^T g)_j
        vt_g[j] = s * ev[j];
    }
    for (0..n) |row| {
        var s: f64 = 0;
        for (0..n) |j| s += eig.vectors.at(row, j).* * vt_g[j];
        p_hard[row] = s;
    }

    const p_hard_norm = norm(p_hard);
    if (p_hard_norm < radius and p_hard_norm >= norm(p)) {
        const tau = @sqrt(@max(0.0, radius * radius - p_hard_norm * p_hard_norm));
        for (0..n) |row| p[row] = p_hard[row] + tau * eig.vectors.at(row, 0).*;
    }
}

// ---------------------------------------------------------------------------------------
// Trust-region subproblem (box-bounded)
// ---------------------------------------------------------------------------------------

fn boundsViolated(p: []const f64, lower: []const f64, upper: []const f64) bool {
    for (p, lower, upper) |v, lo, hi| {
        if (!(lo <= v and v <= hi)) return true;
    }
    return false;
}

/// Solve   minimize  0.5*p^T B p + g^T p   s.t. ||p|| <= radius  and  lower <= p <= upper.
/// Port of dlib `solve_trust_region_subproblem_bounded` (greedy active-set on the box).
pub fn solveTrustRegionSubproblemBounded(
    allocator: Allocator,
    b: []const f64,
    g: []const f64,
    n: usize,
    radius: f64,
    lower: []const f64,
    upper: []const f64,
    p_out: []f64,
    options: TrustRegionOptions,
) !void {
    try solveTrustRegionSubproblem(allocator, b, g, n, radius, p_out, options);
    if (!boundsViolated(p_out, lower, upper)) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Compact (reduced) problem over the still-free variables. idx maps compact -> original.
    var cur = n;
    var idx = try a.alloc(usize, n);
    for (0..n) |i| idx[i] = i;
    var bb = try a.dupe(f64, b[0 .. n * n]);
    var gg = try a.dupe(f64, g[0..n]);
    var lo = try a.dupe(f64, lower[0..n]);
    var hi = try a.dupe(f64, upper[0..n]);
    var pp = try a.dupe(f64, p_out[0..n]);
    var radius_cur = radius;

    while (boundsViolated(pp[0..cur], lo[0..cur], hi[0..cur])) {
        // Find the most-violated free variable and lock it to its bound.
        var most: usize = 0;
        var max_violation: f64 = 0;
        var bounded_value: f64 = 0;
        for (0..cur) |i| {
            if (!(lo[i] <= pp[i] and pp[i] <= hi[i])) {
                if (lo[i] - pp[i] > max_violation) {
                    max_violation = lo[i] - pp[i];
                    most = i;
                    bounded_value = lo[i];
                } else if (pp[i] - hi[i] > max_violation) {
                    max_violation = pp[i] - hi[i];
                    most = i;
                    bounded_value = hi[i];
                }
            }
        }

        p_out[idx[most]] = bounded_value;

        const new_cur = cur - 1;
        if (new_cur == 0) {
            cur = 0; // all variables locked to a bound; skip the writeback below
            break;
        }

        // Build the reduced problem excluding compact index `most`.
        const nb = try a.alloc(f64, new_cur * new_cur);
        const ng = try a.alloc(f64, new_cur);
        const nlo = try a.alloc(f64, new_cur);
        const nhi = try a.alloc(f64, new_cur);
        const npp = try a.alloc(f64, new_cur);
        const nidx = try a.alloc(usize, new_cur);

        var ri: usize = 0;
        for (0..cur) |i| {
            if (i == most) continue;
            nidx[ri] = idx[i];
            // g += B[:,most]*bounded_value, then drop row `most`.
            ng[ri] = gg[i] + bb[i * cur + most] * bounded_value;
            nlo[ri] = lo[i];
            nhi[ri] = hi[i];
            // npp is the reduced solve's output buffer; solveTrustRegionSubproblem zeroes it, so it
            // needs no seed value here.
            var rj: usize = 0;
            for (0..cur) |j| {
                if (j == most) continue;
                nb[ri * new_cur + rj] = bb[i * cur + j];
                rj += 1;
            }
            ri += 1;
        }

        const squared_radius = radius_cur * radius_cur - bounded_value * bounded_value;
        if (squared_radius <= 0) {
            for (0..new_cur) |i| p_out[nidx[i]] = 0;
            cur = 0;
            break;
        }
        radius_cur = @sqrt(squared_radius);

        idx = nidx;
        bb = nb;
        gg = ng;
        lo = nlo;
        hi = nhi;
        pp = npp;
        cur = new_cur;

        try solveTrustRegionSubproblem(a, bb, gg, cur, radius_cur, pp, options);
    }

    // Write back the remaining free variables.
    for (0..cur) |i| p_out[idx[i]] = pp[i];
}

// ---------------------------------------------------------------------------------------
// Quadratic fit
// ---------------------------------------------------------------------------------------

/// Fit Q(x) = 0.5*x^T H x + g^T x + c to the points whose coordinates are the columns of `x`
/// (row-major dims*m: x[d*m + j] is coordinate d of point j) with values `y` (length m).
///
/// Writes H (row-major dims*dims) and g (length dims), returns c. When there are exactly enough
/// points it interpolates; with more it is a least-squares fit; with fewer than required for a full
/// quadratic it picks the minimum-Frobenius-norm Hessian. Port of dlib `fit_quadratic_to_points`.
pub fn fitQuadratic(
    allocator: Allocator,
    x: []const f64,
    dims: usize,
    m: usize,
    y: []const f64,
    h: []f64,
    g: []f64,
) !f64 {
    const k_full = (dims + 1) * (dims + 2) / 2;
    if (m >= k_full) {
        return fitQuadraticMse(allocator, x, dims, m, y, h, g);
    }
    return fitQuadraticInterp(allocator, x, dims, m, y, h, g);
}

fn fitQuadraticMse(
    allocator: Allocator,
    x: []const f64,
    dims: usize,
    m: usize,
    y: []const f64,
    h: []f64,
    g: []f64,
) !f64 {
    const k = (dims + 1) * (dims + 2) / 2;

    // Wt is m x k: row j holds the monomial features of point j:
    //   [ x_0..x_{dims-1}, 1, 0.5*x_r*x_r (r==r2) or x_r*x_r2 (r<r2) ].
    var wt: Matrix(f64) = try .initAll(allocator, @intCast(m), @intCast(k), 0);
    defer wt.deinit();
    for (0..m) |j| {
        for (0..dims) |r| wt.at(j, r).* = x[r * m + j];
        wt.at(j, dims).* = 1;
        var col: usize = dims + 1;
        for (0..dims) |r| {
            for (r..dims) |r2| {
                var v = x[r * m + j] * x[r2 * m + j];
                if (r == r2) v *= 0.5;
                wt.at(j, @intCast(col)).* = v;
                col += 1;
            }
        }
    }

    var ycol: Matrix(f64) = try .init(allocator, @intCast(m), 1);
    defer ycol.deinit();
    for (0..m) |j| ycol.at(j, 0).* = y[j];

    var pinv = try wt.pinv(.{}); // k x m
    defer pinv.deinit();
    var z = try pinv.dot(ycol); // k x 1
    defer z.deinit();

    return unpackQuadratic(z, dims, h, g);
}

fn fitQuadraticInterp(
    allocator: Allocator,
    x: []const f64,
    dims: usize,
    m: usize,
    y: []const f64,
    h: []f64,
    g: []f64,
) !f64 {
    // Block KKT system (Powell NEWUOA eqns 3.9-3.12), size (m+dims+1).
    const n = m + dims + 1;
    var w: Matrix(f64) = try .initAll(allocator, @intCast(n), @intCast(n), 0);
    defer w.deinit();

    // Top-left m x m: 0.5 * (X^T X)^2 (elementwise square of the Gram matrix).
    for (0..m) |i| {
        for (0..m) |j| {
            var gram: f64 = 0;
            for (0..dims) |d| gram += x[d * m + i] * x[d * m + j];
            w.at(i, j).* = 0.5 * gram * gram;
        }
    }
    // Ones coupling row/column.
    for (0..m) |i| {
        w.at(i, @intCast(m)).* = 1;
        w.at(@intCast(m), i).* = 1;
    }
    // X^T (top-right) and X (bottom-left).
    for (0..m) |i| {
        for (0..dims) |d| {
            w.at(i, @intCast(m + 1 + d)).* = x[d * m + i];
            w.at(@intCast(m + 1 + d), i).* = x[d * m + i];
        }
    }

    var rcol: Matrix(f64) = try .initAll(allocator, @intCast(n), 1, 0);
    defer rcol.deinit();
    for (0..m) |i| rcol.at(i, 0).* = y[i];

    var pinv = try w.pinv(.{});
    defer pinv.deinit();
    var z = try pinv.dot(rcol); // n x 1
    defer z.deinit();

    // lambda = z[0..m], c = z[m], g = z[m+1 .. m+dims], H = X diag(lambda) X^T.
    const c = z.at(m, 0).*;
    for (0..dims) |d| g[d] = z.at(@intCast(m + 1 + d), 0).*;
    for (0..dims) |a| {
        for (0..dims) |bcol| {
            var s: f64 = 0;
            for (0..m) |mm| s += x[a * m + mm] * z.at(mm, 0).* * x[bcol * m + mm];
            h[a * dims + bcol] = s;
        }
    }
    return c;
}

/// Extract c, g, and symmetric H from the MSE solution vector z (layout: g[0..dims], c at dims,
/// then upper-triangular H entries row-major).
fn unpackQuadratic(z: Matrix(f64), dims: usize, h: []f64, g: []f64) f64 {
    const c = z.at(dims, 0).*;
    for (0..dims) |r| g[r] = z.at(r, 0).*;
    var wr: usize = dims + 1;
    for (0..dims) |r| {
        for (r..dims) |r2| {
            const v = z.at(@intCast(wr), 0).*;
            h[r * dims + r2] = v;
            h[r2 * dims + r] = v;
            wr += 1;
        }
    }
    return c;
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

fn evalQuad(h: []const f64, g: []const f64, c: f64, dims: usize, x: []const f64) f64 {
    var q: f64 = c;
    for (0..dims) |i| {
        q += g[i] * x[i];
        for (0..dims) |j| q += 0.5 * x[i] * h[i * dims + j] * x[j];
    }
    return q;
}

test "cholInPlace + solve" {
    // A = [[4,2],[2,3]] (SPD), solve A x = b with b = [10, 8] -> x = [...]
    var a = [_]f64{ 4, 2, 2, 3 };
    try std.testing.expect(cholInPlace(&a, 2));
    const b = [_]f64{ 10, 8 };
    var y: [2]f64 = undefined;
    var x: [2]f64 = undefined;
    solveLower(&a, 2, &b, &y);
    solveLowerT(&a, 2, &y, &x);
    // Verify A_orig * x ≈ b
    const ax0 = 4 * x[0] + 2 * x[1];
    const ax1 = 2 * x[0] + 3 * x[1];
    try expectApproxEqAbs(@as(f64, 10), ax0, 1e-9);
    try expectApproxEqAbs(@as(f64, 8), ax1, 1e-9);
}

test "trust region: interior solution" {
    // B = I, g = [-0.5, 0]. Unconstrained min at -B^-1 g = [0.5, 0], norm 0.5 < radius.
    const b = [_]f64{ 1, 0, 0, 1 };
    const g = [_]f64{ -0.5, 0 };
    var p: [2]f64 = undefined;
    try solveTrustRegionSubproblem(std.testing.allocator, &b, &g, 2, 10.0, &p, .{ .eps = 1e-6 });
    try expectApproxEqAbs(@as(f64, 0.5), p[0], 1e-6);
    try expectApproxEqAbs(@as(f64, 0.0), p[1], 1e-6);
}

test "trust region: boundary solution" {
    // B = I, g = [-10, 0]. Unconstrained min at [10,0] (norm 10) but radius 1 -> p ~ [1, 0].
    const b = [_]f64{ 1, 0, 0, 1 };
    const g = [_]f64{ -10, 0 };
    var p: [2]f64 = undefined;
    try solveTrustRegionSubproblem(std.testing.allocator, &b, &g, 2, 1.0, &p, .{ .eps = 1e-7 });
    try expectApproxEqAbs(@as(f64, 1.0), norm(&p), 1e-4);
    try expectApproxEqAbs(@as(f64, 1.0), p[0], 1e-3);
    try expectApproxEqAbs(@as(f64, 0.0), p[1], 1e-3);
}

test "trust region: n==1 hard case (negative curvature, ~zero gradient)" {
    // A 1-D subproblem with non-positive curvature and a ~zero gradient takes the eigen-decomposition
    // ("hard case") fallback. Regression: that path reuses scratch as two length-n views (p_hard and
    // vt_g), needing 2*n slots, which exceeds the n*n Newton scratch when n == 1. minimize
    // 0.5*(-1)*p^2 over |p| <= 1 -> the optimum sits on the boundary (|p| == radius).
    const b = [_]f64{-1};
    const g = [_]f64{0};
    var p: [1]f64 = undefined;
    try solveTrustRegionSubproblem(std.testing.allocator, &b, &g, 1, 1.0, &p, .{});
    try expectApproxEqAbs(@as(f64, 1.0), @abs(p[0]), 1e-9);
}

test "trust region: n==2 hard case follows the min eigenvector of an indefinite B" {
    // Indefinite B = [[1,2],[2,1]] (eigenvalues 3 and -1) with a ~zero gradient drives the eigen
    // ("hard case") fallback for n>=2 — the path that actually depends on eigh returning eigenvalues
    // ascending so the consumer reads the most-negative one and its eigenvector at index 0.
    const b = [_]f64{ 1, 2, 2, 1 };
    const g = [_]f64{ 0, 0 };
    var p: [2]f64 = undefined;
    try solveTrustRegionSubproblem(std.testing.allocator, &b, &g, 2, 1.0, &p, .{});
    // The step rides the trust-region boundary along the min eigenvector [1,-1]/sqrt2.
    try expectApproxEqAbs(@as(f64, 1.0), norm(&p), 1e-9);
    try expectApproxEqAbs(@abs(p[0]), @abs(p[1]), 1e-9);
    try std.testing.expect(p[0] * p[1] < 0);
}

test "trust region bounded: box clips a variable" {
    // Same as boundary case but cap p[0] <= 0.3. Then p[0] should lock to 0.3.
    const b = [_]f64{ 1, 0, 0, 1 };
    const g = [_]f64{ -10, -10 };
    const lower = [_]f64{ -1, -1 };
    const upper = [_]f64{ 0.3, 1 };
    var p: [2]f64 = undefined;
    try solveTrustRegionSubproblemBounded(std.testing.allocator, &b, &g, 2, 1.0, &lower, &upper, &p, .{ .eps = 1e-7 });
    try expectApproxEqAbs(@as(f64, 0.3), p[0], 1e-6);
    try std.testing.expect(p[1] >= -1 and p[1] <= 1);
    try std.testing.expect(norm(&p) <= 1.0 + 1e-6);
}

test "trust region bounded: active set empties (every variable locks to a bound)" {
    // Both coords are pushed past their upper bound, so the active set locks every variable.
    // Regression: the empty-active-set exit used to overwrite the last lock with a stale value.
    const b = [_]f64{ 1, 0, 0, 1 };
    const g = [_]f64{ -10, -10 };
    const lower = [_]f64{ -1, -1 };
    const upper = [_]f64{ 0.3, 0.3 };
    var p: [2]f64 = undefined;
    try solveTrustRegionSubproblemBounded(std.testing.allocator, &b, &g, 2, 1.0, &lower, &upper, &p, .{ .eps = 1e-7 });
    // Every coordinate must respect the box; before the fix p[1] came back at ~0.95 (outside it).
    try std.testing.expect(p[0] >= -1 and p[0] <= 0.3 + 1e-9);
    try std.testing.expect(p[1] >= -1 and p[1] <= 0.3 + 1e-9);
    // Both are driven to the upper bound.
    try expectApproxEqAbs(@as(f64, 0.3), p[0], 1e-6);
    try expectApproxEqAbs(@as(f64, 0.3), p[1], 1e-6);
}

test "fitQuadratic: exact recovery (overdetermined, 2D)" {
    // True quadratic: H = diag(2, 4), g = [1, -1], c = 3.
    const dims = 2;
    const h_true = [_]f64{ 2, 0, 0, 4 };
    const g_true = [_]f64{ 1, -1 };
    const c_true: f64 = 3;

    // 8 sample points (K = 6, so this is overdetermined -> MSE path).
    const pts = [_][2]f64{
        .{ 0, 0 },  .{ 1, 0 },  .{ 0, 1 },   .{ 1, 1 },
        .{ -1, 2 }, .{ 2, -1 }, .{ -2, -2 }, .{ 1.5, 0.5 },
    };
    const m = pts.len;
    var xbuf: [dims * m]f64 = undefined;
    var ybuf: [m]f64 = undefined;
    for (pts, 0..) |pt, j| {
        xbuf[0 * m + j] = pt[0];
        xbuf[1 * m + j] = pt[1];
        ybuf[j] = evalQuad(&h_true, &g_true, c_true, dims, &pt);
    }

    var h: [dims * dims]f64 = undefined;
    var g: [dims]f64 = undefined;
    const c = try fitQuadratic(std.testing.allocator, &xbuf, dims, m, &ybuf, &h, &g);

    try expectApproxEqAbs(c_true, c, 1e-6);
    for (0..dims) |i| try expectApproxEqAbs(g_true[i], g[i], 1e-6);
    for (0..dims * dims) |i| try expectApproxEqAbs(h_true[i], h[i], 1e-6);
}

test "fitQuadratic: interpolation path reproduces sample values" {
    // dims=2 -> K=6; provide only 4 points (dims+1=3 < 4 < 6) to hit the interpolation path.
    const dims = 2;
    const h_true = [_]f64{ 1, 0.5, 0.5, 2 };
    const g_true = [_]f64{ 0.2, -0.3 };
    const c_true: f64 = 1;
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    const m = pts.len;
    var xbuf: [dims * m]f64 = undefined;
    var ybuf: [m]f64 = undefined;
    for (pts, 0..) |pt, j| {
        xbuf[0 * m + j] = pt[0];
        xbuf[1 * m + j] = pt[1];
        ybuf[j] = evalQuad(&h_true, &g_true, c_true, dims, &pt);
    }
    var h: [dims * dims]f64 = undefined;
    var g: [dims]f64 = undefined;
    const c = try fitQuadratic(std.testing.allocator, &xbuf, dims, m, &ybuf, &h, &g);

    // The fit need not equal the true quadratic (under-determined), but must interpolate the points.
    for (pts, 0..) |pt, j| {
        const q = evalQuad(&h, &g, c, dims, &pt);
        try expectApproxEqAbs(ybuf[j], q, 1e-6);
    }
}

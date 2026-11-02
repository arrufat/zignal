//! Piecewise Lipschitz upper bound — the LIPO surrogate used by the global optimizer's exploration
//! step. Port of dlib's `upper_bound_function` (`global_optimization/upper_bound_function.h`).
//!
//! For evaluated points (x_i, y_i) the surrogate is
//!   ub(x) = min_i [ y_i + sqrt(offset_i + sum_k slopes_k*(x_k - x_i,k)^2) ].
//! The per-dimension `slopes` (squared Lipschitz constants) and per-point `offsets`
//! (noise terms) are fit so the surrogate is consistent with every observed pair.
//!
//! dlib fits them by reformulating a hard-margin linear SVM. That is exactly the convex QP
//!   minimize ||u||^2  subject to  A u >= c   (u >= 0 falls out of the dual),
//! which we solve directly with dual coordinate descent (Hsieh et al. 2008) — no SVM machinery.
//! Only a small working set of the O(n^2) pairwise constraints binds; each refit solves over it and
//! re-adds any left-out pair the solution violates.

const std = @import("std");
const Allocator = std.mem.Allocator;

const VarStats = @import("../stats.zig").Running(f64, .variance);
const vec = @import("vec.zig");

pub const UpperBound = struct {
    allocator: Allocator,
    dims: usize,
    relative_noise_magnitude: f64,
    solver_eps: f64,

    xs: std.ArrayList(f64) = .empty, // flat n*dims, row-major (point i at xs.items[i*dims ..][0..dims])
    ys: std.ArrayList(f64) = .empty,

    slopes: []f64, // length dims (>= 0)
    offsets: std.ArrayList(f64) = .empty, // length n (>= 0)

    x_stats: []VarStats = &.{},
    x_stats_prev: []VarStats = &.{}, // scratch for the add() rollback snapshot
    y_stats: VarStats = .init(),

    arena: std.heap.ArenaAllocator,

    // Working set of pairwise constraints. After each refit only the binding pairs (alpha > 0) are
    // kept; the next `add` appends the new point's pairs, and the surviving alphas warm-start the
    // dual coordinate descent.
    active: std.ArrayList(Constraint) = .empty,
    /// DCD sweeps the last refit needed (diagnostic; stays small thanks to warm-starting).
    last_sweeps: usize = 0,

    /// Pairwise constraint between points i < j, with its dual variable.
    const Constraint = struct { i: usize, j: usize, alpha: f64 };

    pub const Options = struct {
        /// Multiplicative noise model for the upper bound (per dlib's relative_noise_magnitude).
        relative_noise_magnitude: f64 = 0.001,
        /// KKT tolerance for the dual-coordinate-descent QP solver.
        solver_eps: f64 = 1e-4,

        pub const default: Options = .{};
    };

    pub fn init(allocator: Allocator, dims: usize, options: Options) !UpperBound {
        const slopes = try allocator.alloc(f64, dims);
        @memset(slopes, 0);
        const x_stats = try allocator.alloc(VarStats, dims);
        for (x_stats) |*s| s.* = .init();
        const x_stats_prev = try allocator.alloc(VarStats, dims);
        return .{
            .allocator = allocator,
            .dims = dims,
            .relative_noise_magnitude = options.relative_noise_magnitude,
            .solver_eps = options.solver_eps,
            .slopes = slopes,
            .x_stats = x_stats,
            .x_stats_prev = x_stats_prev,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *UpperBound) void {
        self.xs.deinit(self.allocator);
        self.ys.deinit(self.allocator);
        self.allocator.free(self.slopes);
        self.offsets.deinit(self.allocator);
        self.active.deinit(self.allocator);
        self.allocator.free(self.x_stats);
        self.allocator.free(self.x_stats_prev);
        self.arena.deinit();
    }

    pub fn numPoints(self: *const UpperBound) usize {
        return self.ys.items.len;
    }

    pub fn pointX(self: *const UpperBound, i: usize) []const f64 {
        return self.xs.items[i * self.dims ..][0..self.dims];
    }

    pub fn pointY(self: *const UpperBound, i: usize) f64 {
        return self.ys.items[i];
    }

    /// Append an observed point and refit the surrogate (once there are >= 2 points).
    pub fn add(self: *UpperBound, x: []const f64, y: f64) !void {
        std.debug.assert(x.len == self.dims);
        const n = self.numPoints();
        try self.xs.appendSlice(self.allocator, x);
        // A failed append or refit must not leave the point set or the running stats ahead of the
        // fitted parameters.
        errdefer self.xs.shrinkRetainingCapacity(n * self.dims);
        try self.ys.append(self.allocator, y);
        errdefer self.ys.shrinkRetainingCapacity(n);
        try self.offsets.append(self.allocator, 0);
        errdefer self.offsets.shrinkRetainingCapacity(n);

        const y_stats_prev = self.y_stats;
        @memcpy(self.x_stats_prev, self.x_stats);
        errdefer {
            self.y_stats = y_stats_prev;
            @memcpy(self.x_stats, self.x_stats_prev);
        }

        for (0..self.dims) |k| self.x_stats[k].add(x[k]);
        self.y_stats.add(y);

        if (self.numPoints() >= 2) try self.learnParams();
    }

    /// The bound a single point `(xi, y)` contributes at `x`: `y + sqrt(base + Σ slopes·d²)`.
    /// `base` is the point's noise offset for stored points, or 0 for imputed in-flight ones.
    fn pointBound(self: *const UpperBound, x: []const f64, xi: []const f64, y: f64, base: f64, current_best: f64) f64 {
        if (y >= current_best) return y;
        const diff_limit = current_best - y;
        const s_limit = diff_limit * diff_limit;

        var s = base;
        for (0..self.dims) |k| {
            const d = x[k] - xi[k];
            s += self.slopes[k] * d * d;
            if (s >= s_limit) return current_best;
        }
        return y + @sqrt(s);
    }

    /// Evaluate the upper bound at x. Requires at least one point (with a single point the bound is
    /// simply that point's value, since the slopes are still zero).
    pub fn evaluate(self: *const UpperBound, x: []const f64) f64 {
        var ub: f64 = std.math.inf(f64);
        for (0..self.numPoints()) |i| {
            ub = @min(ub, self.pointBound(x, self.pointX(i), self.pointY(i), self.offsets.items[i], ub));
        }
        return ub;
    }

    /// Nearest-neighbor `y` among the stored points (Euclidean over `x`). Used to impute a
    /// provisional value for an in-flight ("pending") point so concurrent asks don't collapse
    /// onto it. Returns 0 when there are no points yet.
    pub fn nearestY(self: *const UpperBound, x: []const f64) f64 {
        var best_d: f64 = std.math.inf(f64);
        var best_y: f64 = 0;
        for (0..self.numPoints()) |i| {
            const s = vec.distSq(x, self.pointX(i));
            if (s < best_d) {
                best_d = s;
                best_y = self.pointY(i);
            }
        }
        return best_y;
    }

    /// Like `evaluate`, but also lowers the bound near in-flight points (point p at
    /// `pending_xs[p*dims..][0..dims]`, provisional value `pending_ys[p]`), reusing the current
    /// slopes with a zero offset (no refit). The cheap read-only analogue of dlib's
    /// `build_upper_bound_with_all_function_evals`.
    pub fn evaluateWithPending(
        self: *const UpperBound,
        x: []const f64,
        pending_xs: []const f64,
        pending_ys: []const f64,
    ) f64 {
        var ub = self.evaluate(x);
        const dims = self.dims;
        const npending = pending_ys.len;
        for (0..npending) |p| {
            const xp = pending_xs[p * dims ..][0..dims];
            ub = @min(ub, self.pointBound(x, xp, pending_ys[p], 0, ub));
        }
        return ub;
    }

    /// `evaluateWithPending`, but only as far as needed to decide whether the bound exceeds
    /// `incumbent`: returns the exact bound if it does, otherwise some value <= `incumbent`.
    /// `order` is a permutation of the stored point indices giving the order to try them in; the
    /// point that rejects `x` moves to the front, since it tends to reject the next candidate too.
    /// Port of dlib's `upper_bound_search::evaluate_candidate`.
    pub fn evaluateAbove(
        self: *const UpperBound,
        x: []const f64,
        pending_xs: []const f64,
        pending_ys: []const f64,
        incumbent: f64,
        order: []usize,
    ) f64 {
        std.debug.assert(order.len == self.numPoints());
        for (order, 0..) |i, j| {
            if (self.rejects(x, self.pointX(i), self.pointY(i), self.offsets.items[i], incumbent)) |v| {
                std.mem.swap(usize, &order[0], &order[j]);
                return v;
            }
        }
        for (pending_ys, 0..) |y, p| {
            if (self.rejects(x, pending_xs[p * self.dims ..][0..self.dims], y, 0, incumbent)) |v| return v;
        }
        return self.evaluateWithPending(x, pending_xs, pending_ys);
    }

    /// The bound point `(xi, y)` gives at `x` when it is <= `incumbent`, else null. The squared
    /// test is only a filter; the returned value is confirmed with the unsquared expression so
    /// rounding cannot reject a candidate whose bound beats the incumbent.
    fn rejects(self: *const UpperBound, x: []const f64, xi: []const f64, y: f64, base: f64, incumbent: f64) ?f64 {
        if (y > incumbent) return null;
        const h = incumbent - y;
        const s_limit = h * h;
        var s = base;
        for (0..self.dims) |k| {
            const d = x[k] - xi[k];
            s += self.slopes[k] * d * d;
            if (s > s_limit) return null;
        }
        const v = y + @sqrt(s);
        return if (v <= incumbent) v else null;
    }

    fn learnParams(self: *UpperBound) !void {
        const n = self.numPoints();
        const dims = self.dims;
        const rnm = self.relative_noise_magnitude;

        defer _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        // --- normalization (matches dlib: scale x by per-dim stddev, y by stddev) ---
        const y_std = self.y_stats.stdDev();
        const yscale: f64 = if (y_std > 0) 1.0 / y_std else 1.0;

        const xscale = try a.alloc(f64, dims);
        for (0..dims) |k| {
            const x_std = self.x_stats[k].stdDev();
            xscale[k] = if (x_std > 0) 1.0 / (x_std * yscale) else 0;
        }

        // Points pre-scaled so pair (i, j) contributes (xn_i,k - xn_j,k)^2 to slope k.
        const xn = try a.alloc(f64, n * dims);
        for (0..n) |i| {
            for (0..dims) |k| xn[i * dims + k] = self.xs.items[i * dims + k] * xscale[k] * yscale;
        }
        const u = try a.alloc(f64, dims + n); // [slopes_normalized (dims), offset weights (n)]

        // The working set is the binding pairs of the last refit plus the new point's pairs (as in
        // dlib). Unlike dlib, pairs left out are checked after each solve and violated ones are
        // added back, so the result satisfies every pairwise constraint to `solver_eps`.
        try self.active.ensureUnusedCapacity(self.allocator, n - 1);
        for (0..n - 1) |i| self.active.appendAssumeCapacity(.{ .i = i, .j = n - 1, .alpha = 0 });
        // The caller drops the new point on failure; an empty working set stays valid.
        errdefer self.active.clearRetainingCapacity();

        self.last_sweeps = 0;
        while (true) {
            const sweeps = try self.solve(a, xn, yscale, u);
            self.last_sweeps += sweeps;
            if (sweeps == max_sweeps) break; // unconverged: the violation check would be meaningless
            if (!try self.addViolated(xn, yscale, u)) break;
        }

        // Keep only the binding pairs (and their alphas) for the next refit.
        var kept: usize = 0;
        for (self.active.items) |c| {
            if (c.alpha == 0) continue;
            self.active.items[kept] = c;
            kept += 1;
        }
        self.active.shrinkRetainingCapacity(kept);

        // --- recover slopes/offsets in original space (offsets already sized to n by add) ---
        for (0..dims) |k| self.slopes[k] = u[k] * xscale[k] * xscale[k];
        for (0..n) |i| self.offsets.items[i] = u[dims + i] * rnm;
    }

    const max_sweeps: usize = 1000;

    /// Dual coordinate descent over the working set, warm-started from `alpha`:
    /// max_{alpha>=0} sum alpha*c - 0.5||u||^2, u = sum alpha*a. Leaves the solution in `u` and
    /// returns the number of sweeps.
    fn solve(self: *UpperBound, a: Allocator, xn: []const f64, yscale: f64, u: []f64) !usize {
        const dims = self.dims;
        const rnm = self.relative_noise_magnitude;
        const cons = self.active.items;
        const npairs = cons.len;

        // Sparse constraints: dmat[p][k] = (xn_i,k - xn_j,k)^2; one noise term at `offset index`
        // noise_idx (the lower-y point); rhs c = diff^2; qnn = ||a_p||^2.
        const dmat = try a.alloc(f64, npairs * dims);
        const noise_idx = try a.alloc(usize, npairs);
        const cvec = try a.alloc(f64, npairs);
        const qnn = try a.alloc(f64, npairs);
        for (cons, 0..) |c, p| {
            const i = c.i;
            const j = c.j;
            var q: f64 = 0;
            for (0..dims) |k| {
                const dx = xn[i * dims + k] - xn[j * dims + k];
                const dk = dx * dx;
                dmat[p * dims + k] = dk;
                q += dk * dk;
            }
            noise_idx[p] = if (self.ys.items[i] > self.ys.items[j]) j else i;
            const diff = (self.ys.items[i] - self.ys.items[j]) * yscale;
            cvec[p] = diff * diff;
            qnn[p] = q + rnm * rnm;
        }

        // Rebuild u under the current normalization from the (warm) dual variables.
        @memset(u, 0);
        for (0..npairs) |np| {
            const al = cons[np].alpha;
            if (al == 0) continue;
            for (0..dims) |k| u[k] += al * dmat[np * dims + k];
            u[dims + noise_idx[np]] += al * rnm;
        }

        var sweep: usize = 0;
        while (sweep < max_sweeps) : (sweep += 1) {
            var max_pg: f64 = 0;
            for (0..npairs) |np| {
                if (qnn[np] == 0) continue;
                const ni = noise_idx[np];
                // grad = c - u . a_np
                var ua: f64 = u[dims + ni] * rnm;
                for (0..dims) |k| ua += u[k] * dmat[np * dims + k];
                const grad = cvec[np] - ua;
                const al = cons[np].alpha;
                const pg = if (al > 0) grad else @max(grad, 0);
                const abs_pg = @abs(pg);
                max_pg = @max(max_pg, abs_pg);
                if (abs_pg > 1e-12) {
                    const new_alpha = @max(0.0, al + grad / qnn[np]);
                    const delta = new_alpha - al;
                    if (delta != 0) {
                        for (0..dims) |k| u[k] += delta * dmat[np * dims + k];
                        u[dims + ni] += delta * rnm;
                        cons[np].alpha = new_alpha;
                    }
                }
            }
            if (max_pg < self.solver_eps) break;
        }
        return sweep;
    }

    /// Append every pair outside the working set whose constraint `u . a >= c` is violated by more
    /// than `solver_eps`, with alpha 0. Returns whether any was. The set only grows, so the
    /// solve/check loop terminates.
    fn addViolated(self: *UpperBound, xn: []const f64, yscale: f64, u: []const f64) !bool {
        const n = self.numPoints();
        const dims = self.dims;
        const rnm = self.relative_noise_magnitude;
        const ys = self.ys.items;

        // Walk the working set in scan order (j, then i) to skip its pairs.
        std.mem.sort(Constraint, self.active.items, {}, struct {
            fn lt(_: void, p: Constraint, q: Constraint) bool {
                return if (p.j != q.j) p.j < q.j else p.i < q.i;
            }
        }.lt);
        const in_set = self.active.items.len;
        var w: usize = 0;

        for (1..n) |j| {
            const xj = xn[j * dims ..][0..dims];
            for (0..j) |i| {
                if (w < in_set and self.active.items[w].i == i and self.active.items[w].j == j) {
                    w += 1;
                    continue;
                }
                const diff = (ys[i] - ys[j]) * yscale;
                const limit = diff * diff - self.solver_eps;
                const lo = if (ys[i] > ys[j]) j else i;
                var ua = u[dims + lo] * rnm;
                if (ua >= limit) continue;
                const xi = xn[i * dims ..][0..dims];
                for (0..dims) |k| {
                    const d = xi[k] - xj[k];
                    ua += u[k] * (d * d);
                    if (ua >= limit) break;
                } else try self.active.append(self.allocator, .{ .i = i, .j = j, .alpha = 0 });
            }
        }
        return self.active.items.len > in_set;
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

test "UpperBound.evaluate: dominates the sampled points" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 2, .default);
    defer ub.deinit();

    // Sample a simple bowl f(x,y) = -((x-0.3)^2 + (y+0.2)^2) at a grid.
    const pts = [_][2]f64{
        .{ 0, 0 },      .{ 1, 0 },      .{ 0, 1 },      .{ 1, 1 }, .{ 0.5, 0.5 },
        .{ -0.5, 0.2 }, .{ 0.3, -0.2 }, .{ 0.8, -0.4 },
    };
    for (pts) |pt| {
        const f = -((pt[0] - 0.3) * (pt[0] - 0.3) + (pt[1] + 0.2) * (pt[1] + 0.2));
        try ub.add(&pt, f);
    }

    // The surrogate must be an upper bound at every observed point.
    for (0..ub.numPoints()) |i| {
        const val = ub.evaluate(ub.pointX(i));
        try std.testing.expect(val >= ub.pointY(i) - 1e-6);
    }
    // Slopes are non-negative.
    for (ub.slopes) |s| try std.testing.expect(s >= 0);
}

test "UpperBound.add: working-set refits stay a valid bound" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 3, .default);
    defer ub.deinit();

    var prng = std.Random.DefaultPrng.init(123);
    var r = prng.random();
    for (0..30) |_| {
        var x: [3]f64 = undefined;
        for (0..3) |k| x[k] = r.float(f64) * 2 - 1;
        const y = -(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
        try ub.add(&x, y);
        // Pairs dropped from the working set must still hold up to the solver tolerance (dlib's
        // heuristic misses by ~1e-3 here).
        for (0..ub.numPoints()) |k| {
            try std.testing.expect(ub.evaluate(ub.pointX(k)) >= ub.pointY(k) - 1e-5);
        }
    }
    // Only a few of the 435 pairs bind, and the warm-started solve needs few sweeps.
    try std.testing.expect(ub.active.items.len < 435 / 4);
    try std.testing.expect(ub.last_sweeps < 50);
}

test "UpperBound.add: terminates on duplicate points without noise" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 1, .{ .relative_noise_magnitude = 0 });
    defer ub.deinit();
    // Same x with different y makes the pair's constraint unsatisfiable; it must not be re-added.
    for ([_]f64{ 0, 1, 0, 2, 1, 0 }, 0..) |x, i| try ub.add(&[_]f64{x}, @floatFromInt(i));
    try std.testing.expectEqual(@as(usize, 6), ub.numPoints());
}

test "UpperBound.evaluate: a single point evaluates to that point's value" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 2, .default);
    defer ub.deinit();
    // Before any refit (npoints == 1) the surrogate must still be safe to evaluate.
    try ub.add(&[_]f64{ 0.2, -0.1 }, 1.5);
    try std.testing.expectEqual(@as(usize, 1), ub.numPoints());
    try std.testing.expectEqual(@as(f64, 1.5), ub.evaluate(&[_]f64{ 0.2, -0.1 }));
    try std.testing.expectEqual(@as(f64, 1.5), ub.evaluate(&[_]f64{ 5.0, 5.0 }));
}

test "UpperBound.evaluate: consistent for a 1D Lipschitz function" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 1, .default);
    defer ub.deinit();

    // f(x) = -|x - 0.4| sampled on [0,1]; the bound must dominate samples and stay finite.
    for (0..11) |i| {
        const x = @as(f64, @floatFromInt(i)) / 10.0;
        try ub.add(&[_]f64{x}, -@abs(x - 0.4));
    }
    for (0..ub.numPoints()) |k| {
        const val = ub.evaluate(ub.pointX(k));
        try std.testing.expect(val >= ub.pointY(k) - 1e-6);
        try std.testing.expect(std.math.isFinite(val));
    }
    // The bound at the known peak location should be >= the true optimum (0).
    try std.testing.expect(ub.evaluate(&[_]f64{0.4}) >= -1e-6);
}

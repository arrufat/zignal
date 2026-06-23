//! Piecewise Lipschitz upper bound — the LIPO surrogate used by the global optimizer's exploration
//! step. Port of dlib's `upper_bound_function` (`global_optimization/upper_bound_function.h`).
//!
//! For evaluated points (x_i, y_i) the surrogate is
//!   ub(x) = min_i [ y_i + sqrt(offset_i + sum_k slopes_k*(x_k - x_i,k)^2) ].
//! The per-dimension `slopes` (squared Lipschitz constants) and per-point `offsets` (noise terms)
//! are fit so the surrogate is consistent with every observed pair while being as tight as possible.
//!
//! dlib fits them by reformulating a hard-margin linear SVM. That is exactly the convex QP
//!   minimize ||u||^2  subject to  A u >= c   (u >= 0 falls out of the dual),
//! which we solve directly with dual coordinate descent (Hsieh et al. 2008) — no SVM machinery.
//!
//! v1 simplification: all O(n^2) pairwise constraints are rebuilt on every `add` (dlib keeps an
//! incremental active set). Correct and simple; fine for hundreds of samples.

const std = @import("std");
const Allocator = std.mem.Allocator;

const VarStats = @import("../stats.zig").RunningStats(f64, .variance);
const tr = @import("trust_region.zig");

pub const UpperBound = struct {
    allocator: Allocator,
    dims: usize,
    relative_noise_magnitude: f64,
    solver_eps: f64,

    npoints: usize = 0,
    capacity: usize = 0,
    xs: []f64 = &.{}, // flat capacity*dims, row-major (point i at xs[i*dims ..][0..dims])
    ys: []f64 = &.{},

    slopes: []f64, // length dims (>= 0)
    offsets: []f64 = &.{}, // length capacity (>= 0)

    x_stats: []VarStats = &.{},
    x_stats_prev: []VarStats = &.{}, // scratch for the add() rollback snapshot
    y_stats: VarStats = .init(),

    arena: std.heap.ArenaAllocator,

    // QP dual variables, persisted across refits to warm-start the dual coordinate descent. Indexed
    // by the n-independent pair index j*(j-1)/2 + i, so an entry keeps referring to the same pair as
    // points accumulate (new pairs only ever append at the tail).
    alpha: []f64 = &.{},
    /// DCD sweeps the last refit needed (diagnostic; stays small thanks to warm-starting).
    last_sweeps: usize = 0,

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
            .y_stats = .init(),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *UpperBound) void {
        self.allocator.free(self.xs);
        self.allocator.free(self.ys);
        self.allocator.free(self.slopes);
        self.allocator.free(self.offsets);
        self.allocator.free(self.alpha);
        self.allocator.free(self.x_stats);
        self.allocator.free(self.x_stats_prev);
        self.arena.deinit();
    }

    pub fn numPoints(self: *const UpperBound) usize {
        return self.npoints;
    }

    pub fn pointX(self: *const UpperBound, i: usize) []const f64 {
        return self.xs[i * self.dims ..][0..self.dims];
    }

    pub fn pointY(self: *const UpperBound, i: usize) f64 {
        return self.ys[i];
    }

    /// Append an observed point and refit the surrogate (once there are >= 2 points).
    pub fn add(self: *UpperBound, x: []const f64, y: f64) !void {
        std.debug.assert(x.len == self.dims);
        const n = self.npoints;
        if (n >= self.capacity) {
            const new_cap = if (self.capacity == 0) 8 else self.capacity * 2;
            self.xs = try self.allocator.realloc(self.xs, new_cap * self.dims);
            self.ys = try self.allocator.realloc(self.ys, new_cap);
            self.offsets = try self.allocator.realloc(self.offsets, new_cap);
            self.capacity = new_cap;
        }
        @memcpy(self.xs[n * self.dims ..][0..self.dims], x);
        self.ys[n] = y;
        self.offsets[n] = 0;
        self.npoints = n + 1;
        // A failed refit must not leave npoints or the running stats ahead of the fitted parameters.
        errdefer self.npoints = n;

        const y_stats_prev = self.y_stats;
        @memcpy(self.x_stats_prev, self.x_stats);
        errdefer {
            self.y_stats = y_stats_prev;
            @memcpy(self.x_stats, self.x_stats_prev);
        }

        for (0..self.dims) |k| self.x_stats[k].add(x[k]);
        self.y_stats.add(y);

        if (self.npoints >= 2) try self.learnParams();
    }

    /// The bound a single point `(xi, y)` contributes at `x`: `y + sqrt(max(0, base + Σ slopes·d²))`.
    /// `base` is the point's noise offset for stored points, or 0 for imputed in-flight ones.
    fn pointBound(self: *const UpperBound, x: []const f64, xi: []const f64, y: f64, base: f64, current_best: f64) f64 {
        var s = base;
        if (y >= current_best) return y;
        const diff_limit = current_best - y;
        const s_limit = diff_limit * diff_limit;

        for (0..self.dims) |k| {
            const d = x[k] - xi[k];
            s += self.slopes[k] * d * d;
            if (s >= s_limit) return current_best;
        }
        return y + @sqrt(@max(0.0, s));
    }

    /// Evaluate the upper bound at x. Requires at least one point (with a single point the bound is
    /// simply that point's value, since the slopes are still zero).
    pub fn evaluate(self: *const UpperBound, x: []const f64) f64 {
        var ub: f64 = std.math.inf(f64);
        const dims = self.dims;
        for (0..self.npoints) |i| {
            const xi = self.xs[i * dims ..][0..dims];
            ub = @min(ub, self.pointBound(x, xi, self.ys[i], self.offsets[i], ub));
        }
        return ub;
    }

    /// Nearest-neighbor `y` among the stored points (Euclidean over `x`). Used to impute a provisional
    /// value for an in-flight ("pending") point so concurrent asks don't collapse onto it. Returns 0
    /// when there are no points yet.
    pub fn nearestY(self: *const UpperBound, x: []const f64) f64 {
        const dims = self.dims;
        var best_d: f64 = std.math.inf(f64);
        var best_y: f64 = 0;
        for (0..self.npoints) |i| {
            const xi = self.xs[i * dims ..][0..dims];
            const s = tr.distSq(x, xi);
            if (s < best_d) {
                best_d = s;
                best_y = self.ys[i];
            }
        }
        return best_y;
    }

    /// Like `evaluate`, but also lowers the bound near in-flight points (point p at
    /// `pending_xs[p*dims..][0..dims]`, provisional value `pending_ys[p]`), reusing the current slopes
    /// with a zero offset (no refit). The cheap read-only analogue of dlib's
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

    fn learnParams(self: *UpperBound) !void {
        const dims = self.dims;

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

        try self.solveAndStore(a, xscale, yscale);
    }

    fn solveAndStore(self: *UpperBound, a: Allocator, xscale: []const f64, yscale: f64) !void {
        const n = self.npoints;
        const dims = self.dims;
        const rnm = self.relative_noise_magnitude;

        const npairs = n * (n - 1) / 2;
        // Sparse constraints: dmat[p][k] = (dx_k * xscale_k * yscale)^2; one noise term at
        // `offset index` noise_idx (the lower-y point); rhs c = diff^2; qnn = ||a_p||^2.
        const dmat = try a.alloc(f64, npairs * dims);
        const noise_idx = try a.alloc(usize, npairs);
        const cvec = try a.alloc(f64, npairs);
        const qnn = try a.alloc(f64, npairs);

        // Enumerate pairs in the n-independent order p = j*(j-1)/2 + i (i < j). Each pair keeps its
        // index as points accumulate, so the persisted `alpha` warm-starts the solve below.
        var p: usize = 0;
        for (1..n) |j| {
            for (0..j) |i| {
                var q: f64 = 0;
                for (0..dims) |k| {
                    const dx = (self.xs[i * dims + k] - self.xs[j * dims + k]) * xscale[k] * yscale;
                    const dk = dx * dx;
                    dmat[p * dims + k] = dk;
                    q += dk * dk;
                }
                noise_idx[p] = if (self.ys[i] > self.ys[j]) j else i;
                const diff = (self.ys[i] - self.ys[j]) * yscale;
                cvec[p] = diff * diff;
                qnn[p] = q + rnm * rnm;
                p += 1;
            }
        }

        // Warm-start: keep dual variables for pre-existing pairs, zero only the newly appended tail.
        const old_len = self.alpha.len;
        self.alpha = try self.allocator.realloc(self.alpha, npairs);
        if (npairs > old_len) @memset(self.alpha[old_len..], 0);
        const alpha = self.alpha;

        // --- dual coordinate descent: max_{alpha>=0} sum alpha*c - 0.5||u||^2, u = sum alpha*a ---
        // Rebuild u under the current normalization from the (warm) dual variables.
        const fdim = dims + n; // u layout: [slopes_normalized (dims), offset weights (n)]
        const u = try a.alloc(f64, fdim);
        @memset(u, 0);
        for (0..npairs) |np| {
            if (alpha[np] == 0) continue;
            for (0..dims) |k| u[k] += alpha[np] * dmat[np * dims + k];
            u[dims + noise_idx[np]] += alpha[np] * rnm;
        }

        const max_sweeps: usize = 1000;
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
                const pg = if (alpha[np] > 0) grad else @max(grad, 0);
                const abs_pg = @abs(pg);
                max_pg = @max(max_pg, abs_pg);
                if (abs_pg > 1e-12) {
                    const new_alpha = @max(0.0, alpha[np] + grad / qnn[np]);
                    const delta = new_alpha - alpha[np];
                    if (delta != 0) {
                        for (0..dims) |k| u[k] += delta * dmat[np * dims + k];
                        u[dims + ni] += delta * rnm;
                        alpha[np] = new_alpha;
                    }
                }
            }
            if (max_pg < self.solver_eps) break;
        }
        self.last_sweeps = sweep;

        // --- recover slopes/offsets in original space (offsets already sized to n by add) ---
        for (0..dims) |k| self.slopes[k] = u[k] * xscale[k] * xscale[k];
        for (0..n) |i| self.offsets[i] = u[dims + i] * rnm;
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

test "UpperBound dominates the sampled points" {
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

test "UpperBound warm-start: incremental refits converge fast and stay correct" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 3, .default);
    defer ub.deinit();

    var prng = std.Random.DefaultPrng.init(123);
    var r = prng.random();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var x: [3]f64 = undefined;
        for (0..3) |k| x[k] = r.float(f64) * 2 - 1;
        const y = -(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
        try ub.add(&x, y);
    }

    // After 30 incremental points (435 constraints) the warm-started solve still converges in only
    // a handful of sweeps, far below the 1000-sweep cap — that is the warm-start win.
    try std.testing.expect(ub.last_sweeps < 50);
    // And the surrogate remains a valid upper bound at every sample.
    for (0..ub.numPoints()) |k| {
        try std.testing.expect(ub.evaluate(ub.pointX(k)) >= ub.pointY(k) - 1e-6);
    }
}

test "UpperBound with a single point evaluates to that point's value" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 2, .default);
    defer ub.deinit();
    // Before any refit (npoints == 1) the surrogate must still be safe to evaluate.
    try ub.add(&[_]f64{ 0.2, -0.1 }, 1.5);
    try std.testing.expectEqual(@as(usize, 1), ub.numPoints());
    try std.testing.expectEqual(@as(f64, 1.5), ub.evaluate(&[_]f64{ 0.2, -0.1 }));
    try std.testing.expectEqual(@as(f64, 1.5), ub.evaluate(&[_]f64{ 5.0, 5.0 }));
}

test "UpperBound is consistent for a 1D Lipschitz function" {
    const allocator = std.testing.allocator;
    var ub = try UpperBound.init(allocator, 1, .default);
    defer ub.deinit();

    // f(x) = -|x - 0.4| sampled on [0,1]; the bound must dominate samples and stay finite.
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
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

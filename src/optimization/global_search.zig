//! Derivative-free, bound-constrained global optimization: MaxLIPO + Trust Region.
//!
//! Port of dlib's `find_min_global`/`find_max_global` (`global_optimization/`). The optimizer
//! alternates between two moves:
//!   - **explore** (MaxLIPO): sample the point that maximizes a piecewise Lipschitz upper bound
//!     (`lipschitz.UpperBound`) — global, finds the basin of the optimum.
//!   - **exploit** (trust region): fit a local quadratic to the nearest evaluated points and jump
//!     to the maximizer of that model within an adaptive trust region (`trust_region`).
//!
//! It does NOT use BOBYQA — the exploitation step is the lightweight quadratic-fit + bounded
//! trust-region subproblem dlib actually uses.
//!
//! `GlobalOptimizer` is an ask-tell engine exposed as `step()` (one evaluation, useful for
//! visualizing progress) and `optimize()` (run to a stop condition). `findGlobalOptimum` is a
//! one-shot convenience wrapper.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const tr = @import("trust_region.zig");
const UpperBound = @import("lipschitz.zig").UpperBound;
const OptimizationPolicy = @import("../optimization.zig").OptimizationPolicy;

pub const GlobalError = error{
    InvalidBounds,
    DimensionMismatch,
    NonIntegralBound,
};

/// Call an objective: either a bare `fn([]const f64) f64` (or pointer to one) or any value with a
/// `pub fn evaluate(self, x: []const f64) f64` method (which can carry context/closure data).
inline fn callObjective(objective: anytype, x: []const f64) f64 {
    const T = @TypeOf(objective);
    return switch (@typeInfo(T)) {
        .@"fn" => objective(x),
        .pointer => |ptr| if (@typeInfo(ptr.child) == .@"fn") objective(x) else objective.evaluate(x),
        else => objective.evaluate(x),
    };
}

pub const GlobalOptimizer = struct {
    allocator: Allocator,

    // Search space stored as a struct-of-arrays; `space.items(.lower)` etc. give the per-field
    // columns the hot loops iterate over. `space.len` is the dimensionality.
    space: std.MultiArrayList(Dimension),

    upper_bound: UpperBound,

    best_x: []f64,
    best_y: ?f64, // internal (maximization) convention; null until the first evaluation

    last_x: []f64, // point evaluated in the most recent step (borrowed by Step)
    scratch: []f64,

    radius: f64,
    do_trust_region_step: bool,
    evals: usize,

    prng: std.Random.DefaultPrng,

    sign: f64, // +1 for .max, -1 for .min (internal always maximizes)
    pure_random_probability: f64,
    num_random_samples: usize,
    solver_epsilon: f64,

    /// One search dimension: its inclusive box bounds and whether it is integer-valued. Define the
    /// search space by passing a `[]const Dimension` (one per variable) to `init`/`findGlobalOptimum`.
    pub const Dimension = struct {
        lower: f64,
        upper: f64,
        is_integer: bool = false,
    };

    pub const Options = struct {
        policy: OptimizationPolicy,
        seed: u64 = 0,
        relative_noise_magnitude: f64 = UpperBound.Options.default.relative_noise_magnitude,
        pure_random_probability: f64 = 0.02,
        num_random_samples: usize = 5000,
        solver_epsilon: f64 = 0.0,

        /// Minimize, with default search settings.
        pub const min_default: Options = .{ .policy = .min };
        /// Maximize, with default search settings.
        pub const max_default: Options = .{ .policy = .max };
    };

    pub const Move = enum { init, random, explore, exploit };

    pub const Step = struct {
        /// The point evaluated this step and its objective value (in the caller's sign).
        point: Evaluation,
        move: Move,
        /// Best evaluation seen so far.
        best: Evaluation,
        eval_index: usize,
    };

    pub const StopOptions = struct {
        max_evals: usize,
        target: ?f64 = null,
        patience: ?usize = null,
    };

    /// A function evaluation: a point `x` and its objective value `y` (in the caller's sign).
    ///
    /// Views from `step()`/`best()` borrow the optimizer's memory (valid until the next
    /// `step()`/`deinit()`) — copy `x` if you need it longer, and never `deinit` them. Only an
    /// owned Evaluation — the one returned by `findGlobalOptimum` — should be freed via `deinit`.
    pub const Evaluation = struct {
        x: []const f64,
        y: f64,

        /// Free `x`. Call only on an owned Evaluation (the result of `findGlobalOptimum`), never on
        /// a borrowed view from `step()`/`best()`.
        pub fn deinit(self: *Evaluation, allocator: Allocator) void {
            allocator.free(self.x);
        }
    };

    pub fn init(
        allocator: Allocator,
        dimensions: []const Dimension,
        options: Options,
    ) !GlobalOptimizer {
        if (dimensions.len == 0) return GlobalError.InvalidBounds;
        const dims = dimensions.len;
        for (dimensions) |d| {
            if (!(d.upper > d.lower)) return GlobalError.InvalidBounds;
            if (d.is_integer and (@round(d.lower) != d.lower or @round(d.upper) != d.upper)) {
                return GlobalError.NonIntegralBound;
            }
        }

        var space: std.MultiArrayList(Dimension) = .{};
        errdefer space.deinit(allocator);
        try space.ensureTotalCapacity(allocator, dims);
        for (dimensions) |d| space.appendAssumeCapacity(d);

        const best_x = try allocator.alloc(f64, dims);
        errdefer allocator.free(best_x);
        const last_x = try allocator.alloc(f64, dims);
        errdefer allocator.free(last_x);
        const scratch = try allocator.alloc(f64, dims);
        errdefer allocator.free(scratch);

        const upper_bound: UpperBound = try .init(allocator, dims, .{
            .relative_noise_magnitude = options.relative_noise_magnitude,
        });

        return .{
            .allocator = allocator,
            .space = space,
            .upper_bound = upper_bound,
            .best_x = best_x,
            .best_y = null,
            .last_x = last_x,
            .scratch = scratch,
            .radius = 0,
            .do_trust_region_step = true,
            .evals = 0,
            .prng = .init(options.seed),
            .sign = if (options.policy == .max) 1 else -1,
            .pure_random_probability = options.pure_random_probability,
            .num_random_samples = options.num_random_samples,
            .solver_epsilon = options.solver_epsilon,
        };
    }

    pub fn deinit(self: *GlobalOptimizer) void {
        self.space.deinit(self.allocator);
        self.allocator.free(self.best_x);
        self.allocator.free(self.last_x);
        self.allocator.free(self.scratch);
        self.upper_bound.deinit();
    }

    pub fn best(self: *const GlobalOptimizer) Evaluation {
        return .{ .x = self.best_x, .y = self.sign * (self.best_y orelse -std.math.inf(f64)) };
    }

    /// Record an externally computed `eval` (warm-start, or any prior knowledge). `eval.y` is in
    /// the caller's original sign.
    pub fn addEvaluation(self: *GlobalOptimizer, eval: Evaluation) !void {
        if (eval.x.len != self.space.len) return GlobalError.DimensionMismatch;
        // A warm-start point is a seed, not a trust-region step → treat it like an `.init` move.
        try self.record(eval.x, self.sign * eval.y, .init, 0);
    }

    /// Perform one ask+evaluate+tell iteration and return what happened.
    pub fn step(self: *GlobalOptimizer, objective: anytype) !Step {
        const a = try self.ask();
        const y_raw = callObjective(objective, self.last_x);
        try self.record(self.last_x, self.sign * y_raw, a.move, a.predicted);
        self.evals += 1;
        return .{
            .point = .{ .x = self.last_x, .y = y_raw },
            .move = a.move,
            .best = self.best(),
            .eval_index = self.evals - 1,
        };
    }

    /// Run `step()` until the budget is spent, a target is reached, or improvement stalls.
    pub fn optimize(self: *GlobalOptimizer, objective: anytype, stop: StopOptions) !Evaluation {
        var since_improve: usize = 0;
        var prev_best = self.best_y;
        while (self.evals < stop.max_evals) {
            _ = try self.step(objective);
            const cur = self.best_y.?; // step() always records, so a best now exists
            if (stop.target) |t| {
                if (cur >= self.sign * t) break;
            }
            if (stop.patience) |pat| {
                if (prev_best == null or cur > prev_best.?) {
                    prev_best = cur;
                    since_improve = 0;
                } else {
                    since_improve += 1;
                    if (since_improve >= pat) break;
                }
            }
        }
        return self.best();
    }

    // -----------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------

    // `predicted` carries the trust-region model's predicted improvement (only meaningful for
    // `.exploit`); `move == .exploit` is the single source of truth for "was a TR step".
    const Ask = struct {
        move: Move,
        predicted: f64 = 0,
    };

    /// Choose the next point to evaluate, writing it into `self.last_x`. Port of `get_next_x`.
    fn ask(self: *GlobalOptimizer) !Ask {
        const n = self.upper_bound.numPoints();
        const init_budget = @max(@as(usize, 3), self.space.len);

        // Initial design: first point at the box center, then random until the budget is filled.
        if (n < init_budget) {
            if (n == 0) self.centerVector(self.last_x) else self.randomVector(self.last_x);
            return .{ .move = .init };
        }

        // Exploit: local quadratic trust-region step.
        if (self.do_trust_region_step and n > self.space.len + 1) {
            const predicted = try self.pickTrustRegion();
            if (predicted > self.solver_epsilon) {
                self.do_trust_region_step = false;
                return .{ .move = .exploit, .predicted = predicted };
            }
        }

        // Explore: maximize the Lipschitz upper bound (with a small pure-random probability).
        self.do_trust_region_step = true;
        if (self.prng.random().float(f64) >= self.pure_random_probability) {
            if (self.pickMaxUpperBound()) {
                return .{ .move = .explore };
            }
        }
        self.randomVector(self.last_x);
        return .{ .move = .random };
    }

    /// Tell: incorporate an evaluated point produced by `move`, adapt the trust-region radius,
    /// update the best. Only `.exploit` evaluations drive the radius adaptation.
    fn record(
        self: *GlobalOptimizer,
        x: []const f64,
        y_internal: f64,
        move: Move,
        predicted: f64,
    ) !void {
        try self.upper_bound.add(x, y_internal);

        // self.best_y is still the pre-evaluation best here (updated below), i.e. the TR anchor.
        if (move == .exploit and predicted != 0) {
            if (self.best_y) |anchor| {
                const rho = (y_internal - anchor) / @abs(predicted);
                if (rho < 0.25) {
                    self.radius *= 0.5;
                } else if (rho > 0.75) {
                    self.radius *= 2;
                }
            }
        }

        if (self.best_y == null or y_internal > self.best_y.?) {
            // A non-trust-region jump that lands far from the previous best resets the radius so
            // the next trust-region step re-sizes itself around the new region.
            if (move != .exploit and self.best_y != null and dist(x, self.best_x) > self.radius * 1.001) {
                self.radius = 0;
            }
            @memcpy(self.best_x, x);
            self.best_y = y_internal;
        }
    }

    /// Random search for the point maximizing the upper bound; writes the best into `self.last_x`.
    /// Returns whether that point's bound exceeds the best observed value (i.e. it's worth exploring).
    /// Port of `pick_next_sample_as_max_upper_bound`.
    fn pickMaxUpperBound(self: *GlobalOptimizer) bool {
        // Hoist the SoA columns and RNG handle out of the (num_random_samples-iteration) loop.
        const s = self.space.slice();
        const lower = s.items(.lower);
        const upper = s.items(.upper);
        const is_integer = s.items(.is_integer);
        const r = self.prng.random();

        var best_ub: f64 = -std.math.inf(f64);
        var rounds: usize = 0;
        while (rounds < self.num_random_samples) : (rounds += 1) {
            sampleInBox(self.scratch, lower, upper, is_integer, r);
            const b = self.upper_bound.evaluate(self.scratch);
            if (b > best_ub) {
                best_ub = b;
                @memcpy(self.last_x, self.scratch);
            }
        }
        // self.best_y is the running max of all observed (internal) values == dlib's max ub point y;
        // explore only runs after the initial design, so it is always set here.
        return best_ub > self.best_y.?;
    }

    /// Fit a local quadratic around the best point and solve the bounded trust-region subproblem.
    /// Writes the candidate into `self.last_x`; returns predicted improvement. Port of
    /// `pick_next_sample_using_trust_region` + `find_max_quadraticly_interpolated_vector`.
    fn pickTrustRegion(self: *GlobalOptimizer) !f64 {
        const space = self.space.slice();
        const dims = space.len;
        const lower = space.items(.lower);
        const upper = space.items(.upper);
        const is_integer = space.items(.is_integer);
        @memcpy(self.last_x, self.best_x);

        // Active (continuous) dimensions only — integer variables are held at the best value.
        var da: usize = 0;
        for (0..dims) |k| {
            if (!is_integer[k]) da += 1;
        }
        if (da == 0) return 0;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const active = try a.alloc(usize, da);
        {
            var j: usize = 0;
            for (0..dims) |k| {
                if (!is_integer[k]) {
                    active[j] = k;
                    j += 1;
                }
            }
        }

        const n = self.upper_bound.numPoints();
        const k_full = (da + 1) * (da + 2) / 2;
        const big = @min(n, k_full);

        // N nearest neighbors of best_x (full-space distance).
        const DistIdx = struct { d: f64, idx: usize };
        const dists = try a.alloc(DistIdx, n);
        for (0..n) |i| dists[i] = .{ .d = dist(self.best_x, self.upper_bound.pointX(i)), .idx = i };
        std.mem.sort(DistIdx, dists, {}, struct {
            fn lt(_: void, p: DistIdx, q: DistIdx) bool {
                return p.d < q.d;
            }
        }.lt);

        // anchor = best_x restricted to active dims.
        const anchor = try a.alloc(f64, da);
        for (0..da) |i| anchor[i] = self.best_x[active[i]];

        // X is da x big (column c = neighbor c, active dims, shifted by anchor); Y the values.
        const xbuf = try a.alloc(f64, da * big);
        const ybuf = try a.alloc(f64, big);
        for (0..big) |c| {
            const pt = self.upper_bound.pointX(dists[c].idx);
            for (0..da) |i| xbuf[i * big + c] = pt[active[i]] - anchor[i];
            ybuf[c] = self.upper_bound.pointY(dists[c].idx);
        }

        // Initialize the radius to (just under) the spread of the neighbor cloud, if unset. The
        // active-dim offsets are already materialized in xbuf (= pt - anchor), so reuse them.
        if (self.radius == 0) {
            var maxd: f64 = 0;
            for (0..big) |c| {
                var s: f64 = 0;
                for (0..da) |i| s += xbuf[i * big + c] * xbuf[i * big + c];
                maxd = @max(maxd, @sqrt(s));
            }
            self.radius = 0.95 * maxd;
        }
        if (self.radius <= 0) return 0;

        // Fit Q(p) = 0.5 pᵀHp + gᵀp + c to the shifted points.
        const h = try a.alloc(f64, da * da);
        const g = try a.alloc(f64, da);
        _ = try tr.fitQuadratic(a, xbuf, da, big, ybuf, h, g);

        // Maximize Q in the box-bounded trust region: minimize 0.5 pᵀ(-H)p + (-g)ᵀp.
        const bneg = try a.alloc(f64, da * da);
        const gneg = try a.alloc(f64, da);
        for (0..da * da) |i| bneg[i] = -h[i];
        for (0..da) |i| gneg[i] = -g[i];
        const lo_rel = try a.alloc(f64, da);
        const hi_rel = try a.alloc(f64, da);
        for (0..da) |i| {
            lo_rel[i] = lower[active[i]] - anchor[i];
            hi_rel[i] = upper[active[i]] - anchor[i];
        }
        const p = try a.alloc(f64, da);
        try tr.solveTrustRegionSubproblemBounded(a, bneg, gneg, da, self.radius, lo_rel, hi_rel, p, .{});

        // Never move more than the radius (guards against inaccurate sub-problem solves).
        const pn = norm(p);
        if (pn >= self.radius and pn > 0) {
            const scale = self.radius / pn;
            for (0..da) |i| p[i] *= scale;
        }

        // predicted improvement of the model = Q(p) - Q(0).
        var predicted: f64 = 0;
        for (0..da) |i| {
            predicted += g[i] * p[i];
            for (0..da) |jj| predicted += 0.5 * p[i] * h[i * da + jj] * p[jj];
        }

        // Reinsert active dims into the full candidate (integer dims keep best_x's value).
        for (0..da) |i| {
            const v = anchor[i] + p[i];
            self.last_x[active[i]] = std.math.clamp(v, lower[active[i]], upper[active[i]]);
        }
        return predicted;
    }

    fn randomVector(self: *GlobalOptimizer, buf: []f64) void {
        const s = self.space.slice();
        sampleInBox(buf, s.items(.lower), s.items(.upper), s.items(.is_integer), self.prng.random());
    }

    fn centerVector(self: *GlobalOptimizer, buf: []f64) void {
        const s = self.space.slice();
        for (buf, s.items(.lower), s.items(.upper), s.items(.is_integer)) |*v, lo, hi, is_int| {
            var x = (lo + hi) / 2;
            if (is_int) x = std.math.clamp(@round(x), lo, hi);
            v.* = x;
        }
    }
};

/// Fill `buf` with a uniform random point in the box, snapping integer dimensions.
fn sampleInBox(buf: []f64, lower: []const f64, upper: []const f64, is_integer: []const bool, r: std.Random) void {
    for (buf, lower, upper, is_integer) |*v, lo, hi, is_int| {
        var x = lo + (hi - lo) * r.float(f64);
        if (is_int) x = std.math.clamp(@round(x), lo, hi);
        v.* = x;
    }
}

fn dist(a: []const f64, b: []const f64) f64 {
    var s: f64 = 0;
    for (a, b) |x, y| {
        const d = x - y;
        s += d * d;
    }
    return @sqrt(s);
}

fn norm(a: []const f64) f64 {
    var s: f64 = 0;
    for (a) |x| s += x * x;
    return @sqrt(s);
}

// ---------------------------------------------------------------------------------------
// One-shot convenience wrapper
// ---------------------------------------------------------------------------------------

/// Optimize `objective` over `dimensions` (one `Dimension` per variable) using up to `max_evals`
/// function evaluations. `options` is the same `GlobalOptimizer.Options` the struct API takes — pass
/// `.min_default` or `.max_default` (or a full literal). The returned `Evaluation` owns its `x`;
/// free it via `result.deinit(allocator)`.
pub fn findGlobalOptimum(
    allocator: Allocator,
    objective: anytype,
    dimensions: []const GlobalOptimizer.Dimension,
    max_evals: usize,
    options: GlobalOptimizer.Options,
) !GlobalOptimizer.Evaluation {
    var opt = try GlobalOptimizer.init(allocator, dimensions, options);
    defer opt.deinit();
    const b = try opt.optimize(objective, .{ .max_evals = max_evals });
    const x = try allocator.dupe(f64, b.x);
    return .{ .x = x, .y = b.y };
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

fn negShiftedBowl(x: []const f64) f64 {
    // Maximum 0 at (0.3, -0.4); used to test maximization.
    const a = x[0] - 0.3;
    const b = x[1] + 0.4;
    return -(a * a + b * b);
}

fn shiftedBowl(x: []const f64) f64 {
    // Minimum 0 at (0.3, -0.4); used to test minimization.
    const a = x[0] - 0.3;
    const b = x[1] + 0.4;
    return a * a + b * b;
}

/// A square 2-D continuous search space [lo, hi]^2.
fn box2(lo: f64, hi: f64) [2]GlobalOptimizer.Dimension {
    return .{ .{ .lower = lo, .upper = hi }, .{ .lower = lo, .upper = hi } };
}

test "findGlobalOptimum: shifted bowl (maximize)" {
    const allocator = std.testing.allocator;
    const space = box2(-2, 2);
    var res = try findGlobalOptimum(allocator, negShiftedBowl, &space, 80, .max_default);
    defer res.deinit(allocator);
    try expectApproxEqAbs(@as(f64, 0.3), res.x[0], 1e-2);
    try expectApproxEqAbs(@as(f64, -0.4), res.x[1], 1e-2);
    try expectApproxEqAbs(@as(f64, 0), res.y, 1e-3);
}

test "findGlobalOptimum: shifted bowl (minimize)" {
    const allocator = std.testing.allocator;
    const space = box2(-2, 2);
    var res = try findGlobalOptimum(allocator, shiftedBowl, &space, 80, .min_default);
    defer res.deinit(allocator);
    try expectApproxEqAbs(@as(f64, 0.3), res.x[0], 1e-2);
    try expectApproxEqAbs(@as(f64, -0.4), res.x[1], 1e-2);
    try expectApproxEqAbs(@as(f64, 0), res.y, 1e-3);
}

test "GlobalOptimizer: step() reports progress and is deterministic" {
    const allocator = std.testing.allocator;
    const space = box2(-2, 2);

    var opt = try GlobalOptimizer.init(allocator, &space, .{ .policy = .min, .seed = 7 });
    defer opt.deinit();

    var saw_move = [_]bool{ false, false, false, false };
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const s = try opt.step(shiftedBowl);
        saw_move[@intFromEnum(s.move)] = true;
        try std.testing.expectEqual(i, s.eval_index);
    }
    const b1 = opt.best();
    try std.testing.expect(b1.y < 1e-2);
    // .init and at least one of the search kinds must have occurred.
    try std.testing.expect(saw_move[@intFromEnum(GlobalOptimizer.Move.init)]);

    // Same seed -> same trajectory.
    var opt2 = try GlobalOptimizer.init(allocator, &space, .{ .policy = .min, .seed = 7 });
    defer opt2.deinit();
    i = 0;
    while (i < 60) : (i += 1) _ = try opt2.step(shiftedBowl);
    try expectApproxEqAbs(b1.x[0], opt2.best().x[0], 1e-12);
    try expectApproxEqAbs(b1.x[1], opt2.best().x[1], 1e-12);
}

test "GlobalOptimizer: optimize() with target early-stop" {
    const allocator = std.testing.allocator;
    const space = box2(-5, 5);
    var opt = try GlobalOptimizer.init(allocator, &space, .{ .policy = .min, .seed = 1 });
    defer opt.deinit();
    const b = try opt.optimize(shiftedBowl, .{ .max_evals = 1000, .target = 1e-2 });
    try std.testing.expect(b.y <= 1e-2);
    try std.testing.expect(opt.evals < 1000); // stopped early
}

test "GlobalOptimizer: context-carrying objective via evaluate()" {
    const allocator = std.testing.allocator;
    const Quadratic = struct {
        cx: f64,
        cy: f64,
        fn evaluate(self: @This(), x: []const f64) f64 {
            const a = x[0] - self.cx;
            const b = x[1] - self.cy;
            return a * a + b * b;
        }
    };
    const space = box2(-3, 3);
    var opt = try GlobalOptimizer.init(allocator, &space, .{ .policy = .min, .seed = 3 });
    defer opt.deinit();
    const obj = Quadratic{ .cx = -1.2, .cy = 0.8 };
    const b = try opt.optimize(obj, .{ .max_evals = 90 });
    try expectApproxEqAbs(@as(f64, -1.2), b.x[0], 2e-2);
    try expectApproxEqAbs(@as(f64, 0.8), b.x[1], 2e-2);
}

test "GlobalOptimizer: integer variable converges to integer" {
    const allocator = std.testing.allocator;
    const Obj = struct {
        fn f(x: []const f64) f64 {
            // Minimized at x0 = 3 (integer), x1 = 0.5 (continuous).
            const a = x[0] - 3.0;
            const b = x[1] - 0.5;
            return a * a + b * b;
        }
    };
    const space = [_]GlobalOptimizer.Dimension{
        .{ .lower = 0, .upper = 6, .is_integer = true },
        .{ .lower = -2, .upper = 2 },
    };
    var opt = try GlobalOptimizer.init(allocator, &space, .{
        .policy = .min,
        .seed = 11,
    });
    defer opt.deinit();
    const b = try opt.optimize(Obj.f, .{ .max_evals = 120 });
    try expectApproxEqAbs(@as(f64, 3), b.x[0], 1e-9); // exactly integral
    try expectApproxEqAbs(@as(f64, 0.5), b.x[1], 5e-2);
}

fn rosenbrock(x: []const f64) f64 {
    // Global minimum 0 at (1, 1); narrow curved valley.
    const a = 1.0 - x[0];
    const b = x[1] - x[0] * x[0];
    return a * a + 100.0 * b * b;
}

fn holderTable(x: []const f64) f64 {
    // Multimodal; four global minima ~ -19.2085 on [-10, 10]^2.
    const r = @sqrt(x[0] * x[0] + x[1] * x[1]);
    const e = @exp(@abs(1.0 - r / std.math.pi));
    return -@abs(@sin(x[0]) * @cos(x[1]) * e);
}

test "end-to-end: Rosenbrock valley (minimization)" {
    const allocator = std.testing.allocator;
    const space = box2(-2, 2);
    var opt = try GlobalOptimizer.init(allocator, &space, .{
        .policy = .min,
        .seed = 42,
        .num_random_samples = 600,
    });
    defer opt.deinit();
    const b = try opt.optimize(rosenbrock, .{ .max_evals = 300 });
    try std.testing.expect(b.y < 1e-2);
    try expectApproxEqAbs(@as(f64, 1), b.x[0], 5e-2);
    try expectApproxEqAbs(@as(f64, 1), b.x[1], 5e-2);
}

test "end-to-end: Holder table (multimodal minimization)" {
    const allocator = std.testing.allocator;
    const space = box2(-10, 10);
    var opt = try GlobalOptimizer.init(allocator, &space, .{
        .policy = .min,
        .seed = 1,
        .num_random_samples = 1000,
    });
    defer opt.deinit();
    const b = try opt.optimize(holderTable, .{ .max_evals = 400 });
    // Reach one of the four global minima (~ -19.2085).
    try std.testing.expect(b.y < -19.0);
}

test "GlobalOptimizer: warm-start seeds the model" {
    const allocator = std.testing.allocator;
    const space = box2(-5, 5);
    var opt = try GlobalOptimizer.init(allocator, &space, .{ .policy = .min, .seed = 5 });
    defer opt.deinit();
    // Seed a point near the optimum.
    try opt.addEvaluation(.{ .x = &[_]f64{ 0.35, -0.45 }, .y = shiftedBowl(&[_]f64{ 0.35, -0.45 }) });
    const b = try opt.optimize(shiftedBowl, .{ .max_evals = 60 });
    try std.testing.expect(b.y < 1e-2);
}

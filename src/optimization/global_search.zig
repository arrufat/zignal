//! Derivative-free, bound-constrained global optimization: MaxLIPO + Trust Region.
//!
//! The MaxLIPO+TR method is due to Davis King (dlib's `find_min_global`/`find_max_global`; see his
//! [A Global Optimization Algorithm Worth Using](https://blog.dlib.net/2017/12/a-global-optimization-algorithm-worth.html)),
//! combining the LIPO method of Malherbe & Vayatis (2017) with a trust-region quadratic refinement.
//! This is a port of that dlib implementation; the optimizer alternates between two moves:
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
const Io = std.Io;
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

    // The variables stored as a struct-of-arrays; `variables.items(.lower)` etc. give the
    // per-field columns the hot loops iterate over. `variables.len` is the dimensionality.
    variables: std.MultiArrayList(Variable),

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
    trust_region_eps: f64,
    max_concurrency: usize,

    // Parallel-path state, allocated only when max_concurrency > 1 (empty slices otherwise): one
    // in-flight "slot" per worker, active between dispatch and record. Concurrent asks impute a
    // nearest-neighbor value for active slots so they don't collapse onto one point; `pending_*` packs
    // them for `evaluateWithPending`. Empty on the sequential path, so `ask` scans nothing.
    // The `_x` arrays are flat row-major `max_concurrency * dims` (point i at `[i*dims..][0..dims]`);
    // every other array holds one entry per slot (`max_concurrency`).
    outstanding_x: []f64,
    outstanding_y: []f64,
    outstanding_predicted: []f64,
    outstanding_anchor: []f64,
    outstanding_move: []Move,
    outstanding_active: []bool,
    pending_x: []f64,
    pending_y: []f64,

    /// One optimization variable: its inclusive box bounds and whether it is integer-valued. Define
    /// the search space by passing a `[]const Variable` (one per variable) to `init`/`findGlobalOptimum`.
    pub const Variable = struct {
        lower: f64,
        upper: f64,
        is_integer: bool = false,
    };

    pub const Options = struct {
        policy: OptimizationPolicy,
        seed: u64 = 0,
        /// Configures the Lipschitz upper-bound surrogate (noise model + its QP solver tolerance).
        upper_bound: UpperBound.Options = .default,
        pure_random_probability: f64 = 0.02,
        num_random_samples: usize = 5000,
        /// Minimum trust-region model-predicted improvement required to take an exploit step.
        trust_region_eps: f64 = 0.0,
        /// Maximum number of objective evaluations in flight at once. The default 1 is the plain
        /// sequential algorithm; values > 1 enable a rolling worker pool in `optimize` (which needs a
        /// pooled `Io` to actually run in parallel, and a thread-safe objective).
        max_concurrency: usize = 1,

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
        variables: []const Variable,
        options: Options,
    ) !GlobalOptimizer {
        if (variables.len == 0) return GlobalError.InvalidBounds;
        const dims = variables.len;
        for (variables) |d| {
            if (!(d.upper > d.lower)) return GlobalError.InvalidBounds;
            if (d.is_integer and (@round(d.lower) != d.lower or @round(d.upper) != d.upper)) {
                return GlobalError.NonIntegralBound;
            }
        }

        var soa: std.MultiArrayList(Variable) = .{};
        errdefer soa.deinit(allocator);
        try soa.ensureTotalCapacity(allocator, dims);
        for (variables) |d| soa.appendAssumeCapacity(d);

        const best_x = try allocator.alloc(f64, dims);
        errdefer allocator.free(best_x);
        // best() reads best_x unconditionally; keep it defined for a zero-budget run.
        @memset(best_x, 0);
        const last_x = try allocator.alloc(f64, dims);
        errdefer allocator.free(last_x);
        const scratch = try allocator.alloc(f64, dims);
        errdefer allocator.free(scratch);

        // Allocate the parallel-path slots only when there is parallelism; the sequential path
        // leaves them empty (freeing a zero-length slice in deinit is a no-op).
        const mc = @max(@as(usize, 1), options.max_concurrency);
        const outstanding_x: []f64 = if (mc > 1) try allocator.alloc(f64, mc * dims) else &.{};
        errdefer allocator.free(outstanding_x);
        const outstanding_y: []f64 = if (mc > 1) try allocator.alloc(f64, mc) else &.{};
        errdefer allocator.free(outstanding_y);
        const outstanding_predicted: []f64 = if (mc > 1) try allocator.alloc(f64, mc) else &.{};
        errdefer allocator.free(outstanding_predicted);
        const outstanding_anchor: []f64 = if (mc > 1) try allocator.alloc(f64, mc) else &.{};
        errdefer allocator.free(outstanding_anchor);
        const outstanding_move: []Move = if (mc > 1) try allocator.alloc(Move, mc) else &.{};
        errdefer allocator.free(outstanding_move);
        const outstanding_active: []bool = if (mc > 1) try allocator.alloc(bool, mc) else &.{};
        errdefer allocator.free(outstanding_active);
        @memset(outstanding_active, false);
        const pending_x: []f64 = if (mc > 1) try allocator.alloc(f64, mc * dims) else &.{};
        errdefer allocator.free(pending_x);
        const pending_y: []f64 = if (mc > 1) try allocator.alloc(f64, mc) else &.{};
        errdefer allocator.free(pending_y);

        const upper_bound: UpperBound = try .init(allocator, dims, options.upper_bound);

        return .{
            .allocator = allocator,
            .variables = soa,
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
            .trust_region_eps = options.trust_region_eps,
            .max_concurrency = mc,
            .outstanding_x = outstanding_x,
            .outstanding_y = outstanding_y,
            .outstanding_predicted = outstanding_predicted,
            .outstanding_anchor = outstanding_anchor,
            .outstanding_move = outstanding_move,
            .outstanding_active = outstanding_active,
            .pending_x = pending_x,
            .pending_y = pending_y,
        };
    }

    pub fn deinit(self: *GlobalOptimizer) void {
        self.variables.deinit(self.allocator);
        self.allocator.free(self.best_x);
        self.allocator.free(self.last_x);
        self.allocator.free(self.scratch);
        self.allocator.free(self.outstanding_x);
        self.allocator.free(self.outstanding_y);
        self.allocator.free(self.outstanding_predicted);
        self.allocator.free(self.outstanding_anchor);
        self.allocator.free(self.outstanding_move);
        self.allocator.free(self.outstanding_active);
        self.allocator.free(self.pending_x);
        self.allocator.free(self.pending_y);
        self.upper_bound.deinit();
    }

    pub fn best(self: *const GlobalOptimizer) Evaluation {
        return .{ .x = self.best_x, .y = self.sign * (self.best_y orelse -std.math.inf(f64)) };
    }

    /// Record an externally computed `eval` (warm-start, or any prior knowledge). `eval.y` is in
    /// the caller's original sign.
    pub fn addEvaluation(self: *GlobalOptimizer, eval: Evaluation) !void {
        if (eval.x.len != self.variables.len) return GlobalError.DimensionMismatch;
        // A warm-start point is a seed, not a trust-region step → treat it like an `.init` move.
        try self.record(eval.x, self.sign * eval.y, .init, 0, 0);
    }

    /// Perform one ask+evaluate+tell iteration and return what happened.
    pub fn step(self: *GlobalOptimizer, objective: anytype) !Step {
        const a = try self.ask();
        const y_raw = callObjective(objective, self.last_x);
        try self.record(self.last_x, self.sign * y_raw, a.move, a.predicted, a.anchor);
        self.evals += 1;
        return .{
            .point = .{ .x = self.last_x, .y = y_raw },
            .move = a.move,
            .best = self.best(),
            .eval_index = self.evals - 1,
        };
    }

    /// Run the ask-tell loop until the budget is spent, a target is reached, or improvement stalls.
    ///
    /// `io` runs the objective evaluations: single-threaded inline, or up to `Options.max_concurrency`
    /// in parallel on a pooled `Io`. **With `max_concurrency > 1` the objective is called from several
    /// threads at once (must be thread-safe) and runs are non-deterministic;** `max_concurrency == 1`
    /// is the deterministic sequential path and ignores `io`.
    pub fn optimize(self: *GlobalOptimizer, io: Io, objective: anytype, stop: StopOptions) !Evaluation {
        if (self.max_concurrency <= 1) {
            var state: StopState = .{ .prev_best = self.best_y };
            while (self.evals < stop.max_evals) {
                _ = try self.step(objective);
                if (self.shouldStop(stop, self.best_y.?, &state)) break;
            }
            return self.best();
        }

        // Rolling pool: `max_concurrency` workers each loop ask -> evaluate -> record under one mutex,
        // released only across the objective call so the evaluations run concurrently.
        const obj_arg = switch (@typeInfo(@TypeOf(objective))) {
            .@"fn" => &objective, // bare fn -> *const fn: storable in the worker's args tuple
            else => objective,
        };
        const ObjArg = @TypeOf(obj_arg);

        const Shared = struct {
            mutex: Io.Mutex = .init,
            dispatched: usize = 0,
            stopped: bool = false,
            err: ?anyerror = null,
            state: StopState,
        };

        const Worker = struct {
            fn run(opt: *GlobalOptimizer, w_io: Io, obj: ObjArg, sh: *Shared, slot: usize, st: StopOptions) void {
                const dims = opt.variables.len;
                while (true) {
                    sh.mutex.lockUncancelable(w_io);
                    if (sh.stopped or sh.err != null or sh.dispatched >= st.max_evals) {
                        sh.mutex.unlock(w_io);
                        return;
                    }
                    const a = opt.ask() catch |e| {
                        sh.err = e;
                        sh.mutex.unlock(w_io);
                        return;
                    };
                    const xslot = opt.outstanding_x[slot * dims ..][0..dims];
                    @memcpy(xslot, opt.last_x);
                    opt.outstanding_y[slot] = opt.upper_bound.nearestY(xslot);
                    opt.outstanding_move[slot] = a.move;
                    opt.outstanding_predicted[slot] = a.predicted;
                    opt.outstanding_anchor[slot] = a.anchor;
                    opt.outstanding_active[slot] = true;
                    sh.dispatched += 1;
                    sh.mutex.unlock(w_io);

                    const y_raw = callObjective(obj, xslot); // evaluated without the lock held

                    sh.mutex.lockUncancelable(w_io);
                    opt.outstanding_active[slot] = false;
                    opt.record(xslot, opt.sign * y_raw, opt.outstanding_move[slot], opt.outstanding_predicted[slot], opt.outstanding_anchor[slot]) catch |e| {
                        sh.err = e;
                        sh.mutex.unlock(w_io);
                        return;
                    };
                    opt.evals += 1;
                    if (opt.shouldStop(st, opt.best_y.?, &sh.state)) sh.stopped = true;
                    sh.mutex.unlock(w_io);
                }
            }
        };

        var shared: Shared = .{ .state = .{ .prev_best = self.best_y } };
        var group: Io.Group = .init;
        for (0..self.max_concurrency) |slot| {
            group.async(io, Worker.run, .{ self, io, obj_arg, &shared, slot, stop });
        }
        group.await(io) catch {};
        if (shared.err) |e| return e;
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
        // best_y captured at plan time; rho's reference for radius adaptation.
        anchor: f64 = 0,
    };

    // Patience/target stop bookkeeping, shared by both `optimize` paths and the bindings' hand-driven
    // loop. Seed `prev_best` with the current `best_y` before the loop.
    pub const StopState = struct { prev_best: ?f64, since_improve: usize = 0 };

    /// Whether `cur` (the internal-sign best) trips `stop`'s target or patience, updating `state`.
    pub fn shouldStop(self: *const GlobalOptimizer, stop: StopOptions, cur: f64, state: *StopState) bool {
        if (stop.target) |t| {
            if (cur >= self.sign * t) return true;
        }
        if (stop.patience) |pat| {
            if (state.prev_best == null or cur > state.prev_best.?) {
                state.prev_best = cur;
                state.since_improve = 0;
            } else {
                state.since_improve += 1;
                if (state.since_improve >= pat) return true;
            }
        }
        return false;
    }

    /// Choose the next point to evaluate, writing it into `self.last_x`. Port of `get_next_x`.
    ///
    /// In-flight ("pending") points from concurrent workers count towards the init budget and the
    /// one-trust-region-at-a-time rule, and lower the surrogate near themselves so two asks don't pick
    /// the same spot. With none in flight (the sequential path) this is the original behavior.
    fn ask(self: *GlobalOptimizer) !Ask {
        const dims = self.variables.len;

        // Pack the active in-flight points into `pending_*` and note any outstanding trust-region step.
        var npending: usize = 0;
        var tr_outstanding = false;
        for (0..self.outstanding_active.len) |j| {
            if (!self.outstanding_active[j]) continue;
            @memcpy(self.pending_x[npending * dims ..][0..dims], self.outstanding_x[j * dims ..][0..dims]);
            self.pending_y[npending] = self.outstanding_y[j];
            if (self.outstanding_move[j] == .exploit) tr_outstanding = true;
            npending += 1;
        }

        const real_n = self.upper_bound.numPoints();
        const init_budget = @max(@as(usize, 3), dims);

        // Initial design: box center first, then random until the budget is filled. Pending points
        // count, so concurrent workers don't all flood the box with init samples.
        if (real_n + npending < init_budget) {
            if (real_n + npending == 0) self.centerVector(self.last_x) else self.randomVector(self.last_x);
            return .{ .move = .init };
        }

        // No recorded points yet (only in-flight ones): nothing to fit or bound against, so go random.
        if (real_n == 0) {
            self.randomVector(self.last_x);
            return .{ .move = .random };
        }

        // Exploit: local quadratic trust-region step (skipped if one is already in flight).
        if (self.do_trust_region_step and !tr_outstanding and real_n > dims + 1) {
            const predicted = try self.pickTrustRegion();
            if (predicted > self.trust_region_eps) {
                self.do_trust_region_step = false;
                return .{ .move = .exploit, .predicted = predicted, .anchor = self.best_y orelse 0 };
            }
        }

        // Explore: maximize the Lipschitz upper bound (with a small pure-random probability).
        self.do_trust_region_step = true;
        if (self.prng.random().float(f64) >= self.pure_random_probability) {
            if (self.pickMaxUpperBound(self.pending_x, self.pending_y, npending)) {
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
        anchor: f64,
    ) !void {
        try self.upper_bound.add(x, y_internal);

        // rho measures the step against the best at the time it was planned (`anchor`), not the
        // live best_y — concurrent workers may have improved best_y since this step's `ask`.
        if (move == .exploit and predicted != 0) {
            const rho = (y_internal - anchor) / @abs(predicted);
            if (rho < 0.25) {
                self.radius *= 0.5;
            } else if (rho > 0.75) {
                self.radius *= 2;
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
    /// `pending_x`/`pending_y` are the `npending` in-flight points whose imputed values tighten the
    /// bound near themselves (0 in the sequential case). Port of `pick_next_sample_as_max_upper_bound`.
    fn pickMaxUpperBound(self: *GlobalOptimizer, pending_x: []const f64, pending_y: []const f64, npending: usize) bool {
        // Hoist the SoA columns and RNG handle out of the (num_random_samples-iteration) loop.
        const s = self.variables.slice();
        const lower = s.items(.lower);
        const upper = s.items(.upper);
        const is_integer = s.items(.is_integer);
        const r = self.prng.random();

        var best_ub: f64 = -std.math.inf(f64);
        var rounds: usize = 0;
        while (rounds < self.num_random_samples) : (rounds += 1) {
            sampleInBox(self.scratch, lower, upper, is_integer, r);
            const b = self.upper_bound.evaluateWithPending(self.scratch, pending_x, pending_y, npending);
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
        const vars = self.variables.slice();
        const dims = vars.len;
        const lower = vars.items(.lower);
        const upper = vars.items(.upper);
        const is_integer = vars.items(.is_integer);
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
        const s = self.variables.slice();
        sampleInBox(buf, s.items(.lower), s.items(.upper), s.items(.is_integer), self.prng.random());
    }

    fn centerVector(self: *GlobalOptimizer, buf: []f64) void {
        const s = self.variables.slice();
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

/// Optimize `objective` over the given `variables` (one `Variable` per dimension) using up to `max_evals`
/// function evaluations. `io` runs the evaluations (single-threaded inline, or parallel on a pooled
/// `Io` when `options.max_concurrency > 1`). `options` is the same `GlobalOptimizer.Options` the struct
/// API takes — pass `.min_default` or `.max_default` (or a full literal). The returned `Evaluation`
/// owns its `x`; free it via `result.deinit(allocator)`.
pub fn findGlobalOptimum(
    io: Io,
    allocator: Allocator,
    objective: anytype,
    variables: []const GlobalOptimizer.Variable,
    max_evals: usize,
    options: GlobalOptimizer.Options,
) !GlobalOptimizer.Evaluation {
    var opt = try GlobalOptimizer.init(allocator, variables, options);
    defer opt.deinit();
    const b = try opt.optimize(io, objective, .{ .max_evals = max_evals });
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
fn box2(lo: f64, hi: f64) [2]GlobalOptimizer.Variable {
    return .{ .{ .lower = lo, .upper = hi }, .{ .lower = lo, .upper = hi } };
}

test "findGlobalOptimum: shifted bowl (maximize)" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-2, 2);
    var res = try findGlobalOptimum(io, allocator, negShiftedBowl, &variables, 80, .max_default);
    defer res.deinit(allocator);
    try expectApproxEqAbs(@as(f64, 0.3), res.x[0], 1e-2);
    try expectApproxEqAbs(@as(f64, -0.4), res.x[1], 1e-2);
    try expectApproxEqAbs(@as(f64, 0), res.y, 1e-3);
}

test "findGlobalOptimum: shifted bowl (minimize)" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-2, 2);
    var res = try findGlobalOptimum(io, allocator, shiftedBowl, &variables, 80, .min_default);
    defer res.deinit(allocator);
    try expectApproxEqAbs(@as(f64, 0.3), res.x[0], 1e-2);
    try expectApproxEqAbs(@as(f64, -0.4), res.x[1], 1e-2);
    try expectApproxEqAbs(@as(f64, 0), res.y, 1e-3);
}

test "GlobalOptimizer: step() reports progress and is deterministic" {
    const allocator = std.testing.allocator;
    const variables = box2(-2, 2);

    var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 7 });
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
    var opt2 = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 7 });
    defer opt2.deinit();
    i = 0;
    while (i < 60) : (i += 1) _ = try opt2.step(shiftedBowl);
    try expectApproxEqAbs(b1.x[0], opt2.best().x[0], 1e-12);
    try expectApproxEqAbs(b1.x[1], opt2.best().x[1], 1e-12);
}

test "GlobalOptimizer: optimize() with target early-stop" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-5, 5);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 1 });
    defer opt.deinit();
    const b = try opt.optimize(io, shiftedBowl, .{ .max_evals = 1000, .target = 1e-2 });
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
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-3, 3);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 3 });
    defer opt.deinit();
    const obj = Quadratic{ .cx = -1.2, .cy = 0.8 };
    const b = try opt.optimize(io, obj, .{ .max_evals = 90 });
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
    const variables = [_]GlobalOptimizer.Variable{
        .{ .lower = 0, .upper = 6, .is_integer = true },
        .{ .lower = -2, .upper = 2 },
    };
    const io = Io.Threaded.global_single_threaded.io();
    var opt = try GlobalOptimizer.init(allocator, &variables, .{
        .policy = .min,
        .seed = 11,
    });
    defer opt.deinit();
    const b = try opt.optimize(io, Obj.f, .{ .max_evals = 120 });
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
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-2, 2);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{
        .policy = .min,
        .seed = 42,
        .num_random_samples = 600,
    });
    defer opt.deinit();
    const b = try opt.optimize(io, rosenbrock, .{ .max_evals = 300 });
    try std.testing.expect(b.y < 1e-2);
    try expectApproxEqAbs(@as(f64, 1), b.x[0], 5e-2);
    try expectApproxEqAbs(@as(f64, 1), b.x[1], 5e-2);
}

test "end-to-end: Holder table (multimodal minimization)" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-10, 10);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{
        .policy = .min,
        .seed = 1,
        .num_random_samples = 1000,
    });
    defer opt.deinit();
    const b = try opt.optimize(io, holderTable, .{ .max_evals = 400 });
    // Reach one of the four global minima (~ -19.2085).
    try std.testing.expect(b.y < -19.0);
}

test "GlobalOptimizer: warm-start seeds the model" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-5, 5);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 5 });
    defer opt.deinit();
    // Seed a point near the optimum.
    try opt.addEvaluation(.{ .x = &[_]f64{ 0.35, -0.45 }, .y = shiftedBowl(&[_]f64{ 0.35, -0.45 }) });
    const b = try opt.optimize(io, shiftedBowl, .{ .max_evals = 60 });
    try std.testing.expect(b.y < 1e-2);
}

test "GlobalOptimizer: parallel path with single-threaded Io (graceful fallback)" {
    const allocator = std.testing.allocator;
    // A single-threaded Io runs the workers inline, so max_concurrency > 1 still produces a correct
    // result — it just doesn't run in parallel.
    const io = Io.Threaded.global_single_threaded.io();
    const variables = box2(-2, 2);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 4, .max_concurrency = 4 });
    defer opt.deinit();
    const b = try opt.optimize(io, shiftedBowl, .{ .max_evals = 120 });
    try std.testing.expect(b.y < 1e-2);
    try std.testing.expectEqual(@as(usize, 120), opt.evals);
}

test "GlobalOptimizer: parallel optimize on a thread pool" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{ .async_limit = .limited(8) });
    defer threaded.deinit();
    const io = threaded.io();

    // A thread-safe objective: every concurrent call bumps a shared atomic counter.
    const Counter = struct {
        calls: *std.atomic.Value(usize),
        fn evaluate(self: @This(), x: []const f64) f64 {
            _ = self.calls.fetchAdd(1, .monotonic);
            const a = x[0] - 0.3;
            const b = x[1] + 0.4;
            return a * a + b * b;
        }
    };
    var calls = std.atomic.Value(usize).init(0);
    const obj = Counter{ .calls = &calls };

    const variables = box2(-2, 2);
    var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 9, .max_concurrency = 8 });
    defer opt.deinit();
    const b = try opt.optimize(io, obj, .{ .max_evals = 200 });
    try std.testing.expect(b.y < 1e-2);
    // Exactly max_evals evaluations dispatched and recorded, with no double-counting or races.
    try std.testing.expectEqual(@as(usize, 200), opt.evals);
    try std.testing.expectEqual(@as(usize, 200), calls.load(.monotonic));
}

// test "BENCH parallel speedup" {
//     const allocator = std.testing.allocator;
//     const Expensive = struct {
//         fn evaluate(_: @This(), x: []const f64) f64 {
//             // Simulate a costly objective: ~2M flops of real work, kept by doNotOptimizeAway.
//             var acc: f64 = 0;
//             var i: usize = 0;
//             while (i < 2_000_000) : (i += 1) acc += @sin(@as(f64, @floatFromInt(i)) * 1e-6 + x[0]);
//             std.mem.doNotOptimizeAway(acc);
//             const a = x[0] - 0.3;
//             const b = x[1] + 0.4;
//             return a * a + b * b;
//         }
//     };
//     const obj = Expensive{};
//     const variables =box2(-2, 2);
//     const max_evals = 96;

//     var threaded = Io.Threaded.init(allocator, .{ .async_limit = .limited(8) });
//     defer threaded.deinit();
//     const io = threaded.io();

//     // Serial baseline (max_concurrency = 1 takes the sequential fast-path and ignores the pool).
//     const t0 = Io.Clock.Timestamp.now(io, .awake);
//     {
//         var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 1, .num_random_samples = 100, .max_concurrency = 1 });
//         defer opt.deinit();
//         _ = try opt.optimize(io, obj, .{ .max_evals = max_evals });
//     }
//     const serial_ns = t0.untilNow(io).raw.nanoseconds;

//     // Parallel on the 8-thread pool.
//     const t1 = Io.Clock.Timestamp.now(io, .awake);
//     {
//         var opt = try GlobalOptimizer.init(allocator, &variables, .{ .policy = .min, .seed = 1, .num_random_samples = 100, .max_concurrency = 8 });
//         defer opt.deinit();
//         _ = try opt.optimize(io, obj, .{ .max_evals = max_evals });
//     }
//     const par_ns = t1.untilNow(io).raw.nanoseconds;

//     const serial_ms = @as(f64, @floatFromInt(serial_ns)) / 1e6;
//     const par_ms = @as(f64, @floatFromInt(par_ns)) / 1e6;
//     std.debug.print("\n[BENCH] {d} evals, expensive objective, 8 cores:\n  serial (mc=1):  {d:.1} ms\n  parallel (mc=8): {d:.1} ms\n  speedup: {d:.2}x\n", .{ max_evals, serial_ms, par_ms, serial_ms / par_ms });
// }

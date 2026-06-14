//! Derivative-free global optimization with zignal.
//!
//! This is a Zig port of dlib's `examples/optimization_ex.cpp`, adapted to the routines zignal
//! provides. dlib's example showcases many gradient-based solvers (BFGS, L-BFGS, Newton, trust
//! region) plus the derivative-free BOBYQA and `find_min_global`. zignal ships the derivative-free
//! global optimizer — MaxLIPO + Trust Region (`find_min_global`'s algorithm) — which needs neither
//! derivatives nor a starting point and handles smooth single-optimum functions as well as nasty
//! multimodal ones. So we demonstrate that one solver on the same objectives the dlib example uses.
//!
//! Run with:  zig build run-optimization-example

const std = @import("std");
const Io = std.Io;

const zignal = @import("zignal");
const GlobalOptimizer = zignal.GlobalOptimizer;
const Variable = GlobalOptimizer.Variable;
const findGlobalOptimum = zignal.findGlobalOptimum;

// ----------------------------------------------------------------------------------------
// Objective functions (ported from optimization_ex.cpp)
// ----------------------------------------------------------------------------------------

/// Rosenbrock's function: a curved valley with its global minimum (value 0) at (1, 1).
fn rosen(m: []const f64) f64 {
    const x = m[0];
    const y = m[1];
    return 100.0 * (y - x * x) * (y - x * x) + (1 - x) * (1 - x);
}

/// "Be like target": mean squared distance to a fixed target vector. Smooth, single optimum —
/// the kind of problem dlib solves with BOBYQA. Minimum (value 0) at x == target.
const target = [_]f64{ 3, 5, 1, 7 };
fn beLikeTarget(x: []const f64) f64 {
    var s: f64 = 0;
    for (x, target) |xi, ti| {
        const d = xi - ti;
        s += d * d;
    }
    return s / @as(f64, @floatFromInt(x.len));
}

/// A harder version of the Holder table function: many local optima plus added discontinuities.
/// This is exactly dlib's `complex_holder_table`; its global minimum is about -21.9210397.
fn complexHolderTable(m: []const f64) f64 {
    var x0 = m[0];
    const x1 = m[1];

    // Add discontinuities.
    var sign: f64 = 1;
    var j: f64 = -4;
    while (j < 9) : (j += 0.5) {
        if (j < x0 and x0 < j + 0.5) x0 += sign * 0.25;
        sign *= -1;
    }

    // Holder table tilted towards (10, 10) with extra high-frequency terms.
    const pi = std.math.pi;
    const base = @abs(@sin(x0) * @cos(x1) * @exp(@abs(1 - @sqrt(x0 * x0 + x1 * x1) / pi)));
    return -(base - (x0 + x1) / 10 - @sin(x0 * 10) * @cos(x1 * 10));
}

// ----------------------------------------------------------------------------------------

fn printVec(label: []const u8, v: []const f64) void {
    std.debug.print("{s}[", .{label});
    for (v, 0..) |x, i| {
        if (i != 0) std.debug.print(", ", .{});
        std.debug.print("{d:.6}", .{x});
    }
    std.debug.print("]\n", .{});
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // A thread-pool-backed Io drives the objective evaluations. Pass any std.Io implementation
    // (e.g. Io.Threaded.global_single_threaded.io()) to run them inline instead.
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ------------------------------------------------------------------------------------
    // 1. Rosenbrock — a smooth function whose minimizer we want to recover.
    //    dlib finds this with BFGS; here we find it globally, with no derivatives or start point.
    // ------------------------------------------------------------------------------------
    std.debug.print("== Rosenbrock (global minimum at (1, 1)) ==\n", .{});
    {
        const variables = [_]Variable{ .{ .lower = -5, .upper = 5 }, .{ .lower = -5, .upper = 5 } };
        var res = try findGlobalOptimum(io, gpa, rosen, &variables, 150, .min_default);
        defer res.deinit(gpa);
        printVec("  solution x = ", res.x);
        std.debug.print("  solution y = {d:.6}\n\n", .{res.y});
    }

    // ------------------------------------------------------------------------------------
    // 2. "Be like target" — the smooth single-optimum problem dlib solves with BOBYQA.
    //    A finite box replaces dlib's ±1e100 bounds (the global optimizer needs real bounds).
    // ------------------------------------------------------------------------------------
    std.debug.print("== Be-like-target (BOBYQA's job; optimum at {{3, 5, 1, 7}}) ==\n", .{});
    {
        const variables = [_]Variable{
            .{ .lower = -10, .upper = 10 },
            .{ .lower = -10, .upper = 10 },
            .{ .lower = -10, .upper = 10 },
            .{ .lower = -10, .upper = 10 },
        };
        // `max_concurrency > 1` evaluates several candidates at once on the thread pool above. These
        // toy objectives are too cheap to show a wall-clock win, but a costly thread-safe objective
        // would scale across cores.
        var res = try findGlobalOptimum(io, gpa, beLikeTarget, &variables, 200, .{ .policy = .min, .max_concurrency = 4 });
        defer res.deinit(gpa);
        printVec("  solution x = ", res.x);
        std.debug.print("  solution y = {d:.6}\n\n", .{res.y});
    }

    // ------------------------------------------------------------------------------------
    // 3. Complex Holder table — many local optima + discontinuities. BOBYQA would get stuck in
    //    the nearest local optimum; the global optimizer does not. We drive it one step() at a
    //    time and print progress, which is exactly how you'd hook up a live visualization.
    // ------------------------------------------------------------------------------------
    std.debug.print("== Complex Holder table (multimodal; global y should be about -21.9210397) ==\n", .{});
    {
        const variables = [_]Variable{ .{ .lower = -10, .upper = 10 }, .{ .lower = -10, .upper = 10 } };
        var opt = try GlobalOptimizer.init(gpa, &variables, .{
            .policy = .min,
            .seed = 1,
            .num_random_samples = 500,
        });
        defer opt.deinit();

        const budget = 400;
        while (opt.evals < budget) {
            const s = try opt.step(complexHolderTable);
            if (s.eval_index % 50 == 0 or s.eval_index + 1 == budget) {
                std.debug.print(
                    "  eval {d:>3} [{s:>7}] f(x) = {d:>11.6}   best so far = {d:>11.6}\n",
                    .{ s.eval_index, @tagName(s.move), s.point.y, s.best.y },
                );
            }
        }

        const best = opt.best();
        std.debug.print("\n", .{});
        printVec("  best x = ", best.x);
        std.debug.print("  best y = {d:.6}  (after {d} evaluations)\n", .{ best.y, opt.evals });
    }
}

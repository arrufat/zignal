//! Interactive global optimization in the browser.
//!
//! Exposes zignal's MaxLIPO + Trust Region global optimizer (`GlobalOptimizer`) to JavaScript so a
//! page can drive the search one evaluation at a time and animate it — the way dlib's
//! `find_min_global` blog post visualizes the algorithm. The objective lives in JavaScript: each
//! step the optimizer asks for a point, we hand it to the imported `evaluate` callback (which runs
//! the user-typed function over WASM memory) and record the value it returns.
//!
//! Run with:  zig build  (from examples/), then serve zig-out and open global-optimization.html

const std = @import("std");
const builtin = @import("builtin");
const zignal = @import("zignal");
const GlobalOptimizer = zignal.GlobalOptimizer;
const Variable = GlobalOptimizer.Variable;

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = .info,
};

/// Evaluate the user's objective at the `len`-dimensional point at `ptr`. Implemented in
/// JavaScript: it reads the point straight out of WASM memory, calls the user function and returns
/// the scalar result. Called once per `optimizer_step`.
extern "js" fn evaluate(ptr: [*]const f64, len: usize) f64;

const allocator = std.heap.wasm_allocator;

var optimizer: ?GlobalOptimizer = null;

// Result buffers JS reads back after each step. Allocated by `optimizer_init`, stable for the
// lifetime of a run, freed by `reset`.
var last_x: []f64 = &.{};
var best_x: []f64 = &.{};
var last_y: f64 = 0;
var best_y: f64 = 0;
var last_move: i32 = 0;

fn objective(x: []const f64) f64 {
    return evaluate(x.ptr, x.len);
}

fn reset() void {
    if (optimizer) |*opt| opt.deinit();
    optimizer = null;
    allocator.free(last_x);
    allocator.free(best_x);
    last_x = &.{};
    best_x = &.{};
}

/// Allocate `n` f64s with proper alignment so JS can write a `Float64Array` view over them (used to
/// hand the interleaved bounds buffer to `optimizer_init`). Pair with `free_f64`.
pub export fn alloc_f64(n: usize) [*]f64 {
    const slice = allocator.alloc(f64, n) catch @panic("OOM");
    return slice.ptr;
}

pub export fn free_f64(ptr: [*]f64, n: usize) void {
    allocator.free(ptr[0..n]);
}

/// Create (or recreate) the optimizer over `n` variables.
///
/// `bounds_ptr` points at `2 * n` f64s laid out as `[lo0, hi0, lo1, hi1, ...]`; bit `i` of
/// `int_mask` marks variable `i` as integer-valued (only the low 32 variables can be integers,
/// which is plenty for a demo). `policy` is 0 to minimize, 1 to maximize. Returns 0 on success or a
/// negative error code: -2 invalid bounds (need lower < upper), -3 non-integral integer bound, -1
/// for anything else.
pub export fn optimizer_init(
    bounds_ptr: [*]const f64,
    n: usize,
    int_mask: u32,
    policy: u32,
    seed: u32,
    num_random_samples: u32,
    pure_random_probability: f64,
) i32 {
    reset();

    const vars = allocator.alloc(Variable, n) catch return -1;
    defer allocator.free(vars);
    for (vars, 0..) |*v, i| {
        const is_integer = i < 32 and (int_mask >> @as(u5, @intCast(i))) & 1 != 0;
        v.* = .{
            .lower = bounds_ptr[2 * i],
            .upper = bounds_ptr[2 * i + 1],
            .is_integer = is_integer,
        };
    }

    var opt = GlobalOptimizer.init(allocator, vars, .{
        .policy = if (policy == 1) .max else .min,
        .seed = seed,
        .num_random_samples = num_random_samples,
        .pure_random_probability = pure_random_probability,
    }) catch |err| return switch (err) {
        error.InvalidBounds => -2,
        error.NonIntegralBound => -3,
        else => -1,
    };

    // This function returns a plain status code (not an error union), so `errdefer` would never
    // fire — clean up the partial state by hand on each allocation failure.
    last_x = allocator.alloc(f64, n) catch {
        opt.deinit();
        return -1;
    };
    best_x = allocator.alloc(f64, n) catch {
        allocator.free(last_x);
        last_x = &.{};
        opt.deinit();
        return -1;
    };
    @memset(last_x, 0);
    @memset(best_x, 0);

    optimizer = opt;
    return 0;
}

/// Run one ask/evaluate/record iteration. Returns the 0-based eval index of the point evaluated, or
/// -1 if the optimizer is uninitialized or the step failed. The getters below describe the step.
pub export fn optimizer_step() i32 {
    if (optimizer) |*opt| {
        const s = opt.step(objective) catch return -1;
        const b = opt.best();
        @memcpy(last_x, s.point.x);
        @memcpy(best_x, b.x);
        last_y = s.point.y;
        best_y = b.y;
        last_move = @intFromEnum(s.move);
        return @intCast(s.eval_index);
    }
    return -1;
}

pub export fn get_last_x() [*]const f64 {
    return last_x.ptr;
}

pub export fn get_best_x() [*]const f64 {
    return best_x.ptr;
}

pub export fn get_last_y() f64 {
    return last_y;
}

pub export fn get_best_y() f64 {
    return best_y;
}

/// The move that produced the last point: 0 init, 1 random, 2 explore, 3 exploit (matches
/// `GlobalOptimizer.Move`).
pub export fn get_last_move() i32 {
    return last_move;
}
